#!/usr/bin/env bash

# Exit immediately on errors, unset variables, and pipeline failures
set -euo pipefail

# Usage message
usage() {
  echo "Usage: $0 <domain>"
  echo "Installs Moodle on the specified domain using Nginx, MariaDB, PHP, and Certbot."
  exit 1
}

# Check for domain argument
if [[ $# -lt 1 ]]; then
  usage
fi

# Variables (customize static values if needed)
DOMAIN="$1"
MOODLE_DIR="/var/www/html/moodle"
MOODLEDATA_DIR="/var/www/moodledata"
PHP_VERSION="8.3"
CRON_USER="www-data"
ADMIN_EMAIL="amit@justuju.in"

# Update & install system packages
apt update && apt upgrade -y
apt install -y nginx mariadb-server \
  php-fpm php-intl php-mysql php-curl php-cli php-zip php-xml php-gd php-common \
  php-mbstring php-xmlrpc php-json php-sqlite3 php-soap certbot python3-certbot-nginx

# Enable services
systemctl enable nginx
systemctl enable mariadb

# Clone Moodle if not present
cd /var/www/html
if [[ ! -d "moodle" ]]; then
  git clone https://github.com/moodle/moodle.git
  cd moodle
  git checkout origin/MOODLE_500_STABLE
  git config pull.ff only
else
  echo "Moodle directory already exists at ${MOODLE_DIR}, skipping clone."
fi

# Setup moodledata directory
mkdir -p "${MOODLEDATA_DIR}"
chown -R ${CRON_USER}:${CRON_USER} "${MOODLEDATA_DIR}"
find "${MOODLEDATA_DIR}" -type d -exec chmod 700 {} \;
find "${MOODLEDATA_DIR}" -type f -exec chmod 600 {} \;

# Set permissions on Moodle code
chown -R ${CRON_USER}:${CRON_USER} "${MOODLE_DIR}"
find "${MOODLE_DIR}" -type d -exec chmod 755 {} \;
find "${MOODLE_DIR}" -type f -exec chmod 644 {} \;

# PHP configuration tuning
for SAPI in fpm cli; do
  PHP_INI="/etc/php/${PHP_VERSION}/${SAPI}/php.ini"
  sed -i 's/.*max_input_vars =.*/max_input_vars = 5000/' "${PHP_INI}"
  sed -i 's/.*post_max_size =.*/post_max_size = 256M/' "${PHP_INI}"
  sed -i 's/.*upload_max_filesize =.*/upload_max_filesize = 256M/' "${PHP_INI}"
done
systemctl restart php${PHP_VERSION}-fpm

# Setup cron for Moodle
(
  crontab -u "${CRON_USER}" -l 2>/dev/null || true
  echo "* * * * * /usr/bin/php ${MOODLE_DIR}/admin/cli/cron.php >/dev/null"
) | crontab -u "${CRON_USER}" -

# Create Moodle database and user
CREATOR="${SUDO_USER:-$(logname)}"
MYSQL_MOODLEUSER_PASSWORD=$(openssl rand -base64 12)
DB_CREDS_FILE="/home/${CREATOR}/moodlePasswords.txt"

echo "DB moodleuser password: ${MYSQL_MOODLEUSER_PASSWORD}" | tee "${DB_CREDS_FILE}"

mysql -e "CREATE DATABASE moodle DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -e "CREATE USER 'moodleuser'@'localhost' IDENTIFIED BY '${MYSQL_MOODLEUSER_PASSWORD}';"
mysql -e "GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, CREATE TEMPORARY TABLES, DROP, INDEX, ALTER ON moodle.* TO 'moodleuser'@'localhost';"

# Nginx configuration
NGINX_CONF="/etc/nginx/sites-available/moodle.conf"
cat > "${NGINX_CONF}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    root ${MOODLE_DIR};
    index index.php;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location /dataroot/ {
        internal;
        alias ${MOODLEDATA_DIR}/;
    }

    location ~ \.php(/|$) {
        fastcgi_split_path_info ^(.+\.php)(/.*)$;
        set \$path_info \$fastcgi_path_info;
        try_files \$fastcgi_script_name \$fastcgi_script_name/ =404;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        include fastcgi_params;
        fastcgi_param PATH_INFO \$path_info;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT \$realpath_root;
    }

    location ~ (/vendor/|/node_modules/|composer\.json|/readme|/READ.*|upgrade\.txt|/UPGRADING\.md|db/install\.xml) {
        deny all;
        return 404;
    }
}
EOF

# Enable site and reload Nginx
rm -f /etc/nginx/sites-enabled/default
ln -sf "${NGINX_CONF}" /etc/nginx/sites-enabled/moodle.conf
nginx -t
systemctl reload nginx

certbot --nginx --non-interactive --agree-tos --email "devs@justuju.in" -d "${DOMAIN}"

# Generate admin password and run Moodle CLI installer
MOODLE_ADMIN_PASSWORD=$(openssl rand -base64 12)
CREATOR="${SUDO_USER:-$(logname)}"
echo "Moodle Admin Password: ${MOODLE_ADMIN_PASSWORD}" | tee -a "/home/${CREATOR}/moodlePasswords.txt"

sudo -u ${CRON_USER} \
  php "${MOODLE_DIR}/admin/cli/install.php" \
    --non-interactive \
    --lang=en \
    --wwwroot="https://${DOMAIN}" \
    --dataroot="${MOODLEDATA_DIR}" \
    --dbtype=mariadb \
    --dbhost=localhost \
    --dbname=moodle \
    --dbuser=moodleuser \
    --dbpass="${MYSQL_MOODLEUSER_PASSWORD}" \
    --fullname="Moodle Dev Server" \
    --shortname="dev-server" \
    --adminuser=admin \
    --adminpass="${MOODLE_ADMIN_PASSWORD}" \
    --adminemail="${ADMIN_EMAIL}" \
    --agree-license

echo "Moodle CLI installation complete. Admin user: admin, password stored in /home/${CREATOR}/moodlePasswords.txt."

