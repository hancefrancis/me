#!/bin/bash

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Use sudo." >&2
    exit 1
fi

# Ask for hostname
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

# Update and install required packages
echo "Updating system and installing packages..."
apt update && apt upgrade -y
apt install -y postfix dovecot-core dovecot-imapd dovecot-pop3d opendkim opendkim-tools apache2

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
sed -i 's|^#mail_location = mbox:~/mail:INBOX=~/mail|mail_location = maildir:~/Maildir|' /etc/dovecot/conf.d/10-mail.conf

# Ensure Dovecot listens only on IPv4
echo "listen = *" > /etc/dovecot/dovecot.conf
sed -i '/service imap-login {/a \ \ \ \ inet_listener imap { address = 0.0.0.0 }\n \ \ \ \ inet_listener imaps { address = 0.0.0.0 }' /etc/dovecot/conf.d/10-master.conf
sed -i '/service pop3-login {/a \ \ \ \ inet_listener pop3 { address = 0.0.0.0 }\n \ \ \ \ inet_listener pop3s { address = 0.0.0.0 }' /etc/dovecot/conf.d/10-master.conf

systemctl restart dovecot

# Configure OpenDKIM
echo "Configuring OpenDKIM..."
mkdir -p /etc/opendkim/keys/$HOSTNAME
echo "Domain $HOSTNAME
KeyFile /etc/opendkim/keys/$HOSTNAME/mail.private
Selector mail
Socket inet:8891@localhost
UserID opendkim:opendkim
Mode sv
PidFile /var/run/opendkim/opendkim.pid
UMask 002" > /etc/opendkim.conf

# Ensure OpenDKIM service is properly configured
echo "SOCKET=inet:8891@localhost" > /etc/default/opendkim

# Generate DKIM keys
opendkim-genkey -b 2048 -d $HOSTNAME -s mail -D /etc/opendkim/keys/$HOSTNAME
chown -R opendkim:opendkim /etc/opendkim/keys
chmod 600 /etc/opendkim/keys/$HOSTNAME/mail.private

systemctl restart opendkim

# Generate SPF, DKIM, and DMARC records
SPF_RECORD="v=spf1 mx -all"
DKIM_RECORD="$(grep -o '".*"' /etc/opendkim/keys/$HOSTNAME/mail.txt | tr -d '"')"
DMARC_RECORD="v=DMARC1; p=quarantine; rua=mailto:admin@$HOSTNAME; ruf=mailto:admin@$HOSTNAME; pct=100"

echo -e "\nDNS Records to add to your domain:\n"
echo "SPF Record: $SPF_RECORD"
echo "DKIM Record: mail._domainkey TXT $DKIM_RECORD"
echo "DMARC Record: _dmarc TXT $DMARC_RECORD"

echo -e "\nMail server setup is complete!"
