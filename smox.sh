#!/bin/bash
###############################################################################
# WordPress + Mail‑server auto‑installer  (Ubuntu 20.04)
# ‑ Optional Let’s Encrypt SSL
# ‑ Postfix + Dovecot + OpenDKIM
# ‑ 20 free WP themes to choose
###############################################################################
set -e

### 0. Root check #############################################################
if [ "$(id -u)" -ne 0 ]; then
  echo "❌  This script must be run as root (sudo …)" >&2
  exit 1
fi

### 1. Hostname ###############################################################
read -rp "Enter the FQDN hostname (e.g. mail.example.com): " HOSTNAME
hostnamectl set-hostname "$HOSTNAME"
echo "127.0.1.1 $HOSTNAME" >> /etc/hosts

### 2. Disable IPv6 (optional) ################################################
echo "Disabling IPv6…"
cat <<EOF >> /etc/sysctl.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sysctl -p

### 3. Base packages ##########################################################
echo "Updating system…"
apt update && apt -y upgrade

echo "Installing LAMP stack packages…"
apt install -y apache2 mariadb-server \
               php php-mysql php-gd php-xml php-curl php-zip php-mbstring \
               git unzip curl software-properties-common

# Allow Apache through ufw (if ufw is active)
if command -v ufw &>/dev/null && ufw status | grep -q active; then
  ufw allow "Apache Full"
fi

# Apache ServerName helps Certbot + removes startup warning
echo "ServerName $HOSTNAME" >/etc/apache2/conf-available/servername.conf
a2enconf servername
systemctl reload apache2

### 4. Certbot (optional) #####################################################
read -rp "Install Certbot & obtain HTTPS certificate now? (y/n): " CERT_CHOICE
if [[ $CERT_CHOICE =~ ^[Yy]$ ]]; then
  apt install -y certbot python3-certbot-apache
  CERTBOT=yes
else
  CERTBOT=no
fi

### 5. WordPress installation #################################################
# 5‑a) MariaDB – create WP database & user
echo "Configuring MariaDB…"
systemctl enable --now mariadb

WP_DB="wordpress"
WP_USER="wpuser"
WP_PASS=$(openssl rand -base64 16)

mysql -e "CREATE DATABASE $WP_DB DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -e "CREATE USER '$WP_USER'@'localhost' IDENTIFIED BY '$WP_PASS';"
mysql -e "GRANT ALL PRIVILEGES ON $WP_DB.* TO '$WP_USER'@'localhost'; FLUSH PRIVILEGES;"

# 5‑b) Install WP‑CLI
echo "Installing WP‑CLI…"
curl -sSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp
chmod +x /usr/local/bin/wp

# 5‑c) WordPress core download & install
DOCROOT=/var/www/html
rm -rf "$DOCROOT"/*
mkdir -p "$DOCROOT"

# *** FIX: give ownership to www‑data BEFORE running WP‑CLI ***
chown -R www-data:www-data "$DOCROOT"

sudo -u www-data wp core download --path="$DOCROOT"

sudo -u www-data wp config create \
      --dbname="$WP_DB" --dbuser="$WP_USER" --dbpass="$WP_PASS" \
      --dbhost=localhost --path="$DOCROOT" --skip-check

ADMIN_PW=$(openssl rand -base64 12)

sudo -u www-data wp core install \
      --url="https://$HOSTNAME" --title="My Site" \
      --admin_user=admin --admin_password="$ADMIN_PW" \
      --admin_email="admin@$HOSTNAME" --skip-email \
      --path="$DOCROOT"

### 6. Theme picker (20 free themes) ##########################################
theme_names=(
  "Astra" "OceanWP" "Neve" "Hestia" "Zakra"
  "ColorMag" "Spacious" "Sydney" "GeneratePress" "Storefront"
  "Kadence" "Blocksy" "Hello Elementor" "Poseidon" "Customizr"
  "Rife Free" "Ashe" "Phlox" "Twenty Twenty‑Four" "Twenty Twenty‑Three"
)
theme_slugs=(
  astra oceanwp neve hestia zakra
  colormag spacious sydney generatepress storefront
  kadence blocksy hello-elementor poseidon customizr
  rife-free ashe phlox twentytwentyfour twentytwentythree
)

echo
echo "Choose a WordPress theme:"
for i in "${!theme_names[@]}"; do printf "%2d) %s\n" $((i+1)) "${theme_names[$i]}"; done
read -rp "Theme number (1‑20): " N
if ! [[ $N =~ ^[0-9]+$ ]] || (( N<1 || N>20 )); then N=1; fi
THEME_SLUG="${theme_slugs[$((N-1))]}"
THEME_NAME="${theme_names[$((N-1))]}"

echo "Installing theme $THEME_NAME…"
sudo -u www-data wp theme install "$THEME_SLUG" --activate --path="$DOCROOT"

### 7. HTTPS with Certbot #####################################################
if [ "$CERTBOT" = yes ]; then
  certbot --apache -d "$HOSTNAME" --non-interactive \
          --agree-tos -m admin@"$HOSTNAME" --redirect
fi

a2enmod rewrite ssl
systemctl restart apache2

### 8. Mail stack (Postfix / Dovecot / OpenDKIM) ##############################
echo "Installing Postfix, Dovecot, OpenDKIM…"
apt install -y postfix dovecot-core dovecot-imapd dovecot-pop3d \
               opendkim opendkim-tools

postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = ipv4"
postconf -e "myhostname = $HOSTNAME"
postconf -e "mydestination = \$myhostname, localhost, localhost.localdomain"
postconf -e "mynetworks = 127.0.0.0/8"
postconf -e "home_mailbox = Maildir/"
postconf -e "smtp_helo_name = $HOSTNAME"

if [ "$CERTBOT" = yes ]; then
  postconf -e "smtpd_tls_cert_file = /etc/letsencrypt/live/$HOSTNAME/fullchain.pem"
  postconf -e "smtpd_tls_key_file  = /etc/letsencrypt/live/$HOSTNAME/privkey.pem"
  postconf -e "smtpd_use_tls = yes"
fi

postconf -e "smtpd_sasl_auth_enable = yes"
postconf -e "smtpd_relay_restrictions = permit_mynetworks,permit_sasl_authenticated,reject_unauth_destination"
postconf -e "milter_protocol = 2"
postconf -e "milter_default_action = accept"
postconf -e "non_smtp_milters = \$smtp_milters"
systemctl restart postfix

# Dovecot
sed -i 's/^#disable_plaintext_auth = yes/disable_plaintext_auth = no/' \
       /etc/dovecot/conf.d/10-auth.conf
sed -i 's|^#mail_location .*|mail_location = maildir:~/Maildir|' \
       /etc/dovecot/conf.d/10-mail.conf
echo "listen = *" >/etc/dovecot/dovecot.conf
systemctl restart dovecot

# OpenDKIM
mkdir -p /etc/opendkim/keys/"$HOSTNAME"
cat <<EOF >/etc/opendkim.conf
Domain    $HOSTNAME
KeyFile   /etc/opendkim/keys/$HOSTNAME/mail.private
Selector  mail
Socket    inet:8891@localhost
UserID    opendkim:opendkim
Mode      sv
PidFile   /run/opendkim/opendkim.pid
UMask     002
EOF
echo "SOCKET=inet:8891@localhost" >/etc/default/opendkim

opendkim-genkey -b 2048 -d "$HOSTNAME" -s mail \
                -D /etc/opendkim/keys/"$HOSTNAME"
chown -R opendkim:opendkim /etc/opendkim/keys
chmod 600 /etc/opendkim/keys/"$HOSTNAME"/mail.private

systemctl restart opendkim postfix

# DKIM TXT extraction (single line)
DKIM_TXT=$(tr -d '\n' </etc/opendkim/keys/"$HOSTNAME"/mail.txt | \
           sed 's/.*"\(.*\)".*/\1/')
DMARC="v=DMARC1; p=quarantine; rua=mailto:admin@$HOSTNAME; ruf=mailto:admin@$HOSTNAME; pct=100"

### 9. Summary ###############################################################
cat <<EOF

──────────────────────────────────────────────────────────────────────────────
🎉  All done!

🌐  WordPress : https://$HOSTNAME
    admin / $ADMIN_PW

🎨  Theme     : $THEME_NAME

📧  DNS records to add:
    DKIM  ➜  mail._domainkey TXT  "$DKIM_TXT"
    DMARC ➜  _dmarc          TXT  $DMARC

Enjoy your new WordPress + mail server!
──────────────────────────────────────────────────────────────────────────────
EOF
