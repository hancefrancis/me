#!/bin/bash

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
apt install -y apache2 git unzip software-properties-common

# Allow Apache through firewall if ufw is active
if command -v ufw &>/dev/null && ufw status | grep -q active; then
    ufw allow "Apache Full"
fi

# Install Certbot (Let's Encrypt)
echo "Installing Certbot for SSL..."
add-apt-repository ppa:certbot/certbot -y
apt update
apt install -y certbot python3-certbot-apache

# Bootstrap Website Setup
echo "Installing Bootstrap demo website..."
TMP_DIR="/tmp/bootstrap-demo"
rm -rf $TMP_DIR
git clone https://github.com/StartBootstrap/startbootstrap-freelancer.git $TMP_DIR
cd $TMP_DIR && npm install && npm run build || cp -r $TMP_DIR/* $TMP_DIR/dist/

# Deploy to Apache web root
rm -rf /var/www/html/*
cp -r $TMP_DIR/dist/* /var/www/html/
chown -R www-data:www-data /var/www/html

# Enable required Apache modules
a2enmod rewrite ssl

# Get SSL certificate
echo "Obtaining SSL certificate with Certbot..."
certbot --apache -d $HOSTNAME --non-interactive --agree-tos -m admin@$HOSTNAME

# Mail Server Installation
echo "Installing mail server packages..."
apt install -y postfix dovecot-core dovecot-imapd dovecot-pop3d opendkim opendkim-tools openssl

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

systemctl restart postfix

# Configure Dovecot
sed -i 's/^#disable_plaintext_auth = yes/disable_plaintext_auth = no/' /etc/dovecot/conf.d/10-auth.conf
sed -i 's|^#mail_location = mbox:~/mail:INBOX=~/mail|mail_location = maildir:~/Maildir|' /etc/dovecot/conf.d/10-mail.conf
echo "listen = *" > /etc/dovecot/dovecot.conf
sed -i '/service imap-login {/a \ \ \ \ inet_listener imap { address = 0.0.0.0 }\n \ \ \ \ inet_listener imaps { address = 0.0.0.0 }' /etc/dovecot/conf.d/10-master.conf
sed -i '/service pop3-login {/a \ \ \ \ inet_listener pop3 { address = 0.0.0.0 }\n \ \ \ \ inet_listener pop3s { address = 0.0.0.0 }' /etc/dovecot/conf.d/10-master.conf

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
opendkim-genkey -b 2048 -d $HOSTNAME -s mail -D /etc/opendkim/keys/$HOSTNAME
chown -R opendkim:opendkim /etc/opendkim/keys
chmod 600 /etc/opendkim/keys/$HOSTNAME/mail.private

# Convert DKIM private key to public PEM format
openssl rsa -in /etc/opendkim/keys/$HOSTNAME/mail.private -pubout -out /etc/opendkim/keys/$HOSTNAME/mail.public 2>/dev/null

# Extract DKIM TXT value only
DKIM_RECORD=$(awk 'BEGIN{ORS=""} /"v=DKIM1;/{gsub(/"/,""); print}' /etc/opendkim/keys/$HOSTNAME/mail.txt)

# DNS Records
SPF_RECORD="v=spf1 mx -all"
DMARC_RECORD="v=DMARC1; p=quarantine; rua=mailto:admin@$HOSTNAME; ruf=mailto:admin@$HOSTNAME; pct=100"

echo -e "\n✅ DNS Records to add:\n"
echo "SPF Record: $SPF_RECORD"
echo "DKIM Record: mail._domainkey TXT \"$DKIM_RECORD\""
echo "DMARC Record: _dmarc TXT $DMARC_RECORD"
echo -e "\n🌐 Visit your secure site at: https://$HOSTNAME"
