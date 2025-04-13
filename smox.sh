#!/bin/bash
# This script installs and configures a mail server and a demo website.
# It offers the option to install Certbot and choose from 20 different Bootstrap templates.
# After deployment, the script replaces default text and email addresses in HTML files 
# with the static domain (hostname) entered by the user.
# It also extracts a complete, well-formatted DKIM TXT record for use in DNS.

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Use sudo." >&2
    exit 1
fi

# Ask for hostname (must be a real, pointed domain for SSL if Certbot is used)
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

# Set Apache's ServerName to the hostname to prevent warnings and help Certbot
echo "Configuring Apache with ServerName..."
echo "ServerName $HOSTNAME" > /etc/apache2/conf-available/servername.conf
a2enconf servername
systemctl reload apache2

# Prompt whether to install Certbot for SSL
read -p "Do you want to install Certbot and obtain an SSL certificate? (y/n): " INSTALL_CERTBOT
if [[ $INSTALL_CERTBOT =~ ^[Yy]$ ]]; then
    echo "Installing Certbot for SSL..."
    apt install -y certbot python3-certbot-apache
    CERTBOT_INSTALLED="yes"
else
    echo "Skipping Certbot installation. You will need to configure SSL manually."
    CERTBOT_INSTALLED="no"
fi

# --- Template Selection ---
# Define 20 templates with corresponding GitHub repository URLs.
templates=(
    "Freelancer"
    "Agency"
    "Clean Blog"
    "Creative"
    "Grayscale"
    "New Age"
    "One Page Wonder"
    "Landing Page"
    "Business Frontpage"
    "Modern Business"
    "Stylish Portfolio"
    "Coming Soon"
    "Resume"
    "Small Business"
    "Shop Homepage"
    "Business Casual"
    "Full Width Pics"
    "SB Admin 2"
    "SB Admin"
    "Placeholder Template"
)

repos=(
    "https://github.com/StartBootstrap/startbootstrap-freelancer.git"
    "https://github.com/StartBootstrap/startbootstrap-agency.git"
    "https://github.com/StartBootstrap/startbootstrap-clean-blog.git"
    "https://github.com/StartBootstrap/startbootstrap-creative.git"
    "https://github.com/StartBootstrap/startbootstrap-grayscale.git"
    "https://github.com/StartBootstrap/startbootstrap-new-age.git"
    "https://github.com/StartBootstrap/startbootstrap-one-page-wonder.git"
    "https://github.com/StartBootstrap/startbootstrap-landing-page.git"
    "https://github.com/StartBootstrap/startbootstrap-business-frontpage.git"
    "https://github.com/StartBootstrap/startbootstrap-modern-business.git"
    "https://github.com/StartBootstrap/startbootstrap-stylish-portfolio.git"
    "https://github.com/StartBootstrap/startbootstrap-coming-soon.git"
    "https://github.com/StartBootstrap/startbootstrap-resume.git"
    "https://github.com/StartBootstrap/startbootstrap-small-business.git"
    "https://github.com/StartBootstrap/startbootstrap-shop-homepage.git"
    "https://github.com/StartBootstrap/startbootstrap-business-casual.git"
    "https://github.com/StartBootstrap/startbootstrap-full-width-pics.git"
    "https://github.com/startbootstrap/startbootstrap-sb-admin-2.git"
    "https://github.com/startbootstrap/startbootstrap-sb-admin.git"
    "https://github.com/StartBootstrap/placeholder-template.git"
)

# Display the menu
echo "Select a Bootstrap template to deploy:"
for i in "${!templates[@]}"; do
    index=$((i+1))
    echo "$index) ${templates[$i]}"
done
read -p "Enter the number (1-20): " template_choice

# Validate input and set the repository URL
if ! [[ "$template_choice" =~ ^[0-9]+$ ]] || [ "$template_choice" -lt 1 ] || [ "$template_choice" -gt 20 ]; then
    echo "Invalid selection, defaulting to the first template: ${templates[0]}"
    template_choice=1
fi
# Arrays are zero-indexed:
selected_repo="${repos[$((template_choice-1))]}"
echo "You selected: ${templates[$((template_choice-1))]}."
echo "Template repository: $selected_repo"

# Clone and build the selected template
echo "Installing Bootstrap demo website using template from: $selected_repo"
TMP_DIR="/tmp/bootstrap-demo"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
cd "$TMP_DIR" || exit 1
git clone "$selected_repo" template
cd template || exit 1

# Install Node.js if needed and build if possible; else copy files directly.
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt install -y nodejs

if [ -f package.json ]; then
    npm install
    npm run build || mkdir -p dist && cp -r * dist/
else
    mkdir -p dist && cp -r ./* dist/
fi

# Deploy to Apache web root
rm -rf /var/www/html/*
cp -r dist/* /var/www/html/
chown -R www-data:www-data /var/www/html

# Replace default template values.
# 1. Replace any occurrence of "Start Bootstrap" with the static domain ($HOSTNAME)
# 2. Replace default email addresses that start with "info@" so that the domain is your hostname.
echo "Customizing deployed HTML files with your domain and email..."
find /var/www/html -type f -name "*.html" -exec sed -i "s/Start Bootstrap/$HOSTNAME/g" {} \;
find /var/www/html -type f -name "*.html" -exec sed -Ei "s/(info@)[a-zA-Z0-9.-]+\b/\1$HOSTNAME/g" {} \;

# Enable required Apache modules
a2enmod rewrite ssl
systemctl restart apache2

# If Certbot was chosen, obtain the SSL certificate and configure Apache redirection.
if [ "$CERTBOT_INSTALLED" = "yes" ]; then
    echo "Obtaining SSL certificate with Certbot for domain: $HOSTNAME..."
    certbot --apache -d "$HOSTNAME" --non-interactive --agree-tos -m admin@"$HOSTNAME" --redirect
fi

# --- Mail Server Installation ---
echo "Installing mail server packages..."
apt install -y postfix dovecot-core dovecot-imapd dovecot-pop3d opendkim opendkim-tools

# Configure Postfix
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = ipv4"
postconf -e "myhostname = $HOSTNAME"
postconf -e "mydestination = \$myhostname, localhost, localhost.localdomain"
postconf -e "mynetworks = 127.0.0.0/8"
postconf -e "home_mailbox = Maildir/"

# Set certificate paths for Postfix only if Certbot was installed
if [ "$CERTBOT_INSTALLED" = "yes" ]; then
    postconf -e "smtpd_tls_cert_file=/etc/letsencrypt/live/$HOSTNAME/fullchain.pem"
    postconf -e "smtpd_tls_key_file=/etc/letsencrypt/live/$HOSTNAME/privkey.pem"
    postconf -e "smtpd_use_tls=yes"
fi

postconf -e "smtpd_sasl_auth_enable=yes"
postconf -e "smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination"
postconf -e "smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination"
postconf -e "milter_protocol = 2"
postconf -e "milter_default_action = accept"
postconf -e "non_smtp_milters = \$smtp_milters"
# Ensure the HELO value matches the configured hostname
postconf -e "smtp_helo_name = $HOSTNAME"

systemctl restart postfix

# Configure Dovecot
sed -i 's/^#disable_plaintext_auth = yes/disable_plaintext_auth = no/' /etc/dovecot/conf.d/10-auth.conf
sed -i 's|^#mail_location = mbox:~/mail:INBOX=~/mail|mail_location = maildir:~/Maildir|' /etc/dovecot/conf.d/10-mail.conf
echo "listen = *" > /etc/dovecot/dovecot.conf

systemctl restart dovecot

# --- OpenDKIM Configuration ---
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

# Extract the complete DKIM TXT record.
# This method reads the mail.txt file generated by opendkim-genkey,
# removes newlines, and then uses sed to extract the content within the quotes.
DKIM_RAW=$(tr -d '\n' < /etc/opendkim/keys/$HOSTNAME/mail.txt)
DKIM_RECORD=$(echo "$DKIM_RAW" | sed -e 's/.*("\(.*\)").*/\1/')
if [ -z "$DKIM_RECORD" ]; then
    echo "⚠️  DKIM record extraction failed."
else
    echo -e "\n✅ DNS Records to add:\n"
    DMARC_RECORD="v=DMARC1; p=quarantine; rua=mailto:admin@$HOSTNAME; ruf=mailto:postmaster@$HOSTNAME; pct=100"
    echo "DKIM Record: mail._domainkey TXT \"$DKIM_RECORD\""
    echo "DMARC Record: _dmarc TXT $DMARC_RECORD"
fi

echo -e "\n🌐 Visit your secure site at: https://$HOSTNAME"
echo -e "\nMail server and demo site setup complete!"
