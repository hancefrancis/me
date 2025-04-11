#!/bin/bash
# This script installs and configures a mail server and a demo website.
# It now includes a choice of 5 Bootstrap templates and ensures that
# the HELO value in Postfix matches the static domain.

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Use sudo." >&2
    exit 1
fi

# Ask for hostname (must be a real, pointed domain for SSL)
read -p "Enter the hostname (e.g., mail.example.com): " HOSTNAME
hostnamectl set-hostname "$HOSTNAME"
echo "127.0.1.1 $HOSTNAME" >> /etc/hosts

# Disable IPv6
echo "Disabling IPv6..."
cat <<EOF >> /etc/sysctl.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sysctl -p

# Update system & install base packages
echo "Updating and installing base packages..."
apt update && apt upgrade -y
apt install -y apache2 git unzip curl software-properties-common

# Allow Apache through firewall if ufw is active
if command -v ufw &>/dev/null && ufw status | grep -q active; then
    ufw allow "Apache Full"
fi

# Set Apache's ServerName to the hostname to prevent warnings and to help Certbot
echo "Configuring Apache with ServerName..."
echo "ServerName $HOSTNAME" > /etc/apache2/conf-available/servername.conf
a2enconf servername
systemctl reload apache2

# Install Certbot (Let's Encrypt)
echo "Installing Certbot for SSL..."
apt install -y certbot python3-certbot-apache

# Prompt for Bootstrap template selection
echo "Select a Bootstrap template to deploy:"
echo "1) Freelancer"
echo "2) Agency"
echo "3) Clean Blog"
echo "4) Creative"
echo "5) Grayscale"
read -p "Enter the number (1-5): " template_choice

case "$template_choice" in
    1) TEMPLATE_REPO="https://github.com/StartBootstrap/startbootstrap-freelancer.git" ;;
    2) TEMPLATE_REPO="https://github.com/StartBootstrap/startbootstrap-agency.git" ;;
    3) TEMPLATE_REPO="https://github.com/StartBootstrap/startbootstrap-clean-blog.git" ;;
    4) TEMPLATE_REPO="https://github.com/StartBootstrap/startbootstrap-creative.git" ;;
    5) TEMPLATE_REPO="https://github.com/StartBootstrap/startbootstrap-grayscale.git" ;;
    *) echo "Invalid selection, defaulting to Freelancer template." ; TEMPLATE_REPO="https://github.com/StartBootstrap/startbootstrap-freelancer.git" ;;
esac

# Clone and build the selected Bootstrap template
echo "Installing Bootstrap demo website using template from: $TEMPLATE_REPO"
TMP_DIR="/tmp/bootstrap-demo"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
cd "$TMP_DIR" || exit 1
git clone "$TEMPLATE_REPO" template
cd template || exit 1

# Install Node.js if needed, build if possible, else copy files directly.
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt install -y nodejs

# If package.json exists, assume a build step is defined.
if [ -f package.json ]; then
    npm install
    npm run build || cp -r * dist/
else
    # No build steps; copy files directly into a dist/ folder
    mkdir -p dist && cp -r ./* dist/
fi

# Deploy to Apache web root
rm -rf /var/www/html/*
cp -r dist/* /var/www/html/
chown -R www-data:www-data /var/www/html

# Enable required Apache modules
a2enmod rewrite ssl
systemctl restart apache2

# Get SSL certificate using Certbot
echo "Obtaining SSL certificate with Certbot for domain: $HOSTNAME..."
certbot --apache -d "$HOSTNAME" --non-interactive --agree-tos -m admin@"$HOSTNAME" --redirect

# Install Mail Server packages
echo "Installing mail server packages..."
apt install -y postfix dovecot-core dovecot-imapd dovecot-pop3d opendkim opendkim-tools

# Configure Postfix
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = ipv4"
postconf -e "myhostname = $HOSTNAME"
postconf -e "mydestination = \$myhostname, localhost, localhost.localdomain"
postconf -e "mynetworks = 127.0.0.0/8"
postconf -e "home_mailbox = Maildir/"
postconf -e "smtpd_tls_cert_file=/etc/letsencrypt/live/$HOSTNAME/fullchain.pem"
postconf -e "smtpd_tls_key_file=/etc/letsencrypt/live/$HOSTNAME/privkey.pem"
postconf -e "smtpd_use_tls=yes"
postconf -e "smtpd_sasl_auth_enable=yes"
postconf -e "smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination"
postconf -e "smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination"
postconf -e "milter_protocol = 2"
postconf -e "milter_default_action = accept"
postconf -e "smtpd_milters = inet:127.0.0.1:8891"
postconf -e "non_smtp_milters = \$smtp_milters"
# Ensure the HELO value matches the configured hostname
postconf -e "smtp_helo_name = $HOSTNAME"

systemctl restart postfix

# Configure Dovecot
sed -i 's/^#disable_plaintext_auth = yes/disable_plaintext_auth = no/' /etc/dovecot/conf.d/10-auth.conf
sed -i 's|^#mail_location = mbox:~/mail:INBOX=~/mail|mail_location = maildir:~/Maildir|' /etc/dovecot/conf.d/10-mail.conf
echo "listen = *" > /etc/dovecot/dovecot.conf

systemctl restart dovecot

# Configure OpenDKIM
mkdir -p /etc/opendkim/keys/$HOSTNAME

cat <<EOF > /etc/opendkim.conf
Domain                  $HOSTNAME
KeyFile                 /etc/opendkim/keys/$HOSTNAME/mail.private
Selector                mail
Socket                  inet:8891@localhost
UserID                  opendkim:opendkim
Mode                    sv
PidFile                 /var/run/opendkim/opendkim.pid
UMask                   002
EOF

echo "SOCKET=inet:8891@localhost" > /etc/default/opendkim

# Generate DKIM key pair
opendkim-genkey -b 2048 -d "$HOSTNAME" -s mail -D /etc/opendkim/keys/$HOSTNAME
chown -R opendkim:opendkim /etc/opendkim/keys
chmod 600 /etc/opendkim/keys/$HOSTNAME/mail.private

# Convert DKIM private key to public PEM format
openssl rsa -in /etc/opendkim/keys/$HOSTNAME/mail.private -pubout -out /etc/opendkim/keys/$HOSTNAME/mail.public 2>/dev/null

# Extract DKIM TXT value only (adjust this extraction if necessary)
DKIM_RECORD=$(awk 'BEGIN{ORS=""} /v=DKIM1;/{gsub(/"/,""); print}' /etc/opendkim/keys/$HOSTNAME/mail.txt)

# DNS Records
DMARC_RECORD="v=DMARC1; p=quarantine; rua=mailto:admin@$HOSTNAME; ruf=mailto:admin@$HOSTNAME; pct=100"

echo -e "\n✅ DNS Records to add:\n"
echo "DKIM Record: mail._domainkey TXT \"$DKIM_RECORD\""
echo "DMARC Record: _dmarc TXT $DMARC_RECORD"
echo -e "\n🌐 Visit your secure site at: https://$HOSTNAME"

echo -e "\nMail server and demo site setup complete!"
