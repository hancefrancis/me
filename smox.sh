#!/bin/bash

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Use sudo." >&2
    exit 1
fi

# Ask for hostname
read -p "Enter the hostname (e.g., mail.example.com): " HOSTNAME
hostnamectl set-hostname "$HOSTNAME"

# Disable IPv6
echo "Disabling IPv6..."
cat <<EOF >> /etc/sysctl.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sysctl -p

# Update and install required packages
echo "Updating system and installing packages..."
apt update && apt upgrade -y
apt install -y postfix dovecot-core dovecot-imapd dovecot-pop3d opendkim opendkim-tools mailutils apache2

# Configure Postfix
echo "Configuring Postfix..."
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = ipv4"
postconf -e "myhostname = $HOSTNAME"
postconf -e "mydestination = \$myhostname, localhost, localhost.localdomain"
postconf -e "mynetworks = 127.0.0.0/8"
postconf -e "home_mailbox = Maildir/"
postconf -e "smtpd_tls_cert_file=/etc/ssl/certs/ssl-cert-snakeoil.pem"
postconf -e "smtpd_tls_key_file=/etc/ssl/private/ssl-cert-snakeoil.key"
postconf -e "smtpd_use_tls=yes"
postconf -e "smtpd_sasl_auth_enable=yes"
postconf -e "smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination"
postconf -e "smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination"

systemctl restart postfix

# Configure Dovecot
echo "Configuring Dovecot..."
sed -i 's/^#disable_plaintext_auth = yes/disable_plaintext_auth = no/' /etc/dovecot/conf.d/10-auth.conf
sed -i 's/^#mail_location = mbox:~/mail:INBOX=~/mail/\nmail_location = maildir:~\/Maildir\//g' /etc/dovecot/conf.d/10-mail.conf

systemctl restart dovecot

# Configure OpenDKIM
echo "Configuring OpenDKIM..."
mkdir -p /etc/opendkim/keys/$HOSTNAME
echo "Domain $HOSTNAME
KeyFile /etc/opendkim/keys/$HOSTNAME/mail.private
Selector mail
Socket inet:8891@localhost" > /etc/opendkim.conf
echo "SOCKET=inet:8891@localhost" >> /etc/default/opendkim
opendkim-genkey -b 2048 -d $HOSTNAME -s mail -D /etc/opendkim/keys/$HOSTNAME
chown -R opendkim:opendkim /etc/opendkim/keys
systemctl restart opendkim

# Generate SPF, DKIM, and DMARC records
SPF_RECORD="v=spf1 mx -all"
DKIM_RECORD="$(cat /etc/opendkim/keys/$HOSTNAME/mail.txt | grep -o '".*"' | tr -d '"')"
DMARC_RECORD="v=DMARC1; p=quarantine; rua=mailto:admin@$HOSTNAME; ruf=mailto:admin@$HOSTNAME; pct=100"

echo "\nDNS Records to add to your domain:\n"
echo "SPF Record: $SPF_RECORD"
echo "DKIM Record: mail._domainkey TXT $DKIM_RECORD"
echo "DMARC Record: _dmarc TXT $DMARC_RECORD"

echo "\nMail server setup is complete!"
