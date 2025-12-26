#!/usr/bin/env bash
set -euo pipefail

SITE_NAME="erpsite"

FRAPPE_USER="frappe"
FRAPPE_PASS="${FRAPPE_USER}"     # as requested

DB_ROOT_USER="root"
DB_ROOT_PASS="frappeDB"          # as requested

ADMIN_USER="Administrator"
ADMIN_PASS="${SITE_NAME}"        # keep your previous behavior

BENCH_FOLDER="frappe-bench"

echo "== Must run as root =="
if [ "$(id -u)" -ne 0 ]; then
  echo "Run: sudo bash $0"
  exit 1
fi

echo "== 1) Update system =="
apt-get update -y && apt-get upgrade -y && apt-get autoremove -y

echo "== 2) Create frappe user (sudo) + set password =="
if ! id -u "${FRAPPE_USER}" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "${FRAPPE_USER}"
fi
echo "${FRAPPE_USER}:${FRAPPE_PASS}" | chpasswd
usermod -aG sudo "${FRAPPE_USER}"

echo "== 3) Install prerequisites =="
apt-get install -y \
  git software-properties-common \
  python3-dev python3-setuptools python3-pip python3-venv \
  mariadb-server mariadb-client \
  redis-server \
  nginx supervisor \
  curl npm \
  xvfb libfontconfig wkhtmltopdf

echo "== 4) Yarn =="
npm install -g yarn

echo "== 5) Enable services =="
systemctl enable --now mariadb redis-server nginx supervisor

echo "== 6) Configure MariaDB utf8mb4 =="
cat >/etc/mysql/mariadb.conf.d/99-erpnext-utf8mb4.cnf <<'EOF'
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4
EOF
systemctl restart mariadb

echo "== 7) Set MariaDB root password to ${DB_ROOT_PASS} =="
# Set password for root@localhost (works if root uses unix_socket OR already has a password)
mariadb -u root <<SQL
FLUSH PRIVILEGES;
ALTER USER '${DB_ROOT_USER}'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
FLUSH PRIVILEGES;
SQL

echo "== 8) Install NVM + Node 18 for frappe user =="
sudo -H -u "${FRAPPE_USER}" bash -lc '
  set -e
  curl -fsSL https://raw.githubusercontent.com/creationix/nvm/master/install.sh | bash
  source ~/.profile || true
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  nvm install 18
  nvm use 18
  node -v
  npm -v
  yarn -v
'

echo "== 9) Install frappe-bench (pip3, your method) =="
pip3 install --break-system-packages frappe-bench

echo "== 10) bench init v15 =="
sudo -H -u "${FRAPPE_USER}" bash -lc "
  set -e
  cd ~
  bench init --frappe-branch version-15 ${BENCH_FOLDER}
"

echo "== 11) Create site (non-interactive passwords) + install apps =="
# bench new-site supports passing db root password + admin password. [web:199]
sudo -H -u "${FRAPPE_USER}" bash -lc "
  set -e
  cd ~/${BENCH_FOLDER}

  # Drop existing site if exists
  if bench list-sites 2>/dev/null | grep -qx '${SITE_NAME}'; then
    bench drop-site '${SITE_NAME}' --force
  fi

  bench new-site '${SITE_NAME}' \
    --db-root-username '${DB_ROOT_USER}' \
    --db-root-password '${DB_ROOT_PASS}' \
    --admin-password '${ADMIN_PASS}'

  bench get-app erpnext --branch version-15 https://github.com/frappe/erpnext
  bench get-app hrms --branch version-15

  bench --site '${SITE_NAME}' install-app erpnext
  bench --site '${SITE_NAME}' install-app hrms

  bench use '${SITE_NAME}'
  bench --site '${SITE_NAME}' enable-scheduler
  bench --site '${SITE_NAME}' set-maintenance-mode off
"

echo "== 12) Production setup (Supervisor + NGINX) =="
sudo -H -u "${FRAPPE_USER}" bash -lc "
  set -e
  cd ~/${BENCH_FOLDER}
  sudo bench setup production ${FRAPPE_USER}
  bench setup nginx
"

echo "== 13) Reload NGINX + restart Supervisor =="
nginx -t
systemctl reload nginx
supervisorctl restart all

SERVER_IP="$(hostname -I | awk '{print $1}')"

echo "============================="
echo "ERPNext installation finished"
echo "URL: http://${SERVER_IP}/"
echo "Linux user: ${FRAPPE_USER}"
echo "Linux password: ${FRAPPE_PASS}"
echo "MariaDB root user: ${DB_ROOT_USER}"
echo "MariaDB root password: ${DB_ROOT_PASS}"
echo "ERPNext user: ${ADMIN_USER}"
echo "ERPNext password: ${ADMIN_PASS}"
echo "Site name: ${SITE_NAME}"
echo "============================="
