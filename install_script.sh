#!/usr/bin/env bash
set -euo pipefail

SITE_NAME="erpsite"
FRAPPE_USER="frappe"
BENCH_DIR="/home/${FRAPPE_USER}/frappe-bench"

echo "== 1) Update OS and cleanup =="
sudo apt-get update -y && sudo apt-get upgrade -y && sudo apt-get autoremove -y

echo "== 2) Create frappe user (sudo) if missing =="
if ! id -u "${FRAPPE_USER}" >/dev/null 2>&1; then
  sudo adduser "${FRAPPE_USER}"
fi
sudo usermod -aG sudo "${FRAPPE_USER}"

echo "== 3) Install base prerequisites =="
sudo apt-get install -y \
  git software-properties-common \
  python3-dev python3-setuptools python3-pip python3-venv \
  mariadb-server \
  redis-server \
  nginx supervisor \
  npm curl \
  xvfb libfontconfig wkhtmltopdf

echo "== 4) yarn (global) =="
sudo npm install -g yarn

echo "== 5) MariaDB secure install (interactive) =="
echo "NOTE: mysql_secure_installation is interactive. Follow prompts."
sudo mysql_secure_installation

echo "== 6) MariaDB charset config (edit file) =="
echo "NOTE: Ensure /etc/mysql/my.cnf includes utf8mb4 settings then restart MariaDB."
echo "Recommended sections:"
echo "[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4"
echo "MariaDB charset/collation config is commonly required to avoid encoding issues."  # info only
sudo systemctl restart mariadb

echo "== 7) Setup NVM + Node 18 for frappe user =="
# Install nvm under frappe user home and load it for the same non-interactive run
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

echo "== 8) Install frappe-bench (pip) =="
sudo pip3 install --break-system-packages frappe-bench

echo "== 9) bench init v15 =="
sudo -H -u "${FRAPPE_USER}" bash -lc "
  set -e
  cd ~
  bench init --frappe-branch version-15 frappe-bench
"

echo "== 10) Create site + install apps (ERPNext + HRMS) =="
sudo -H -u "${FRAPPE_USER}" bash -lc "
  set -e
  cd ~/frappe-bench

  # Optional: allow traverse permissions (as in your steps)
  sudo chmod -R o+rx /home/${FRAPPE_USER}

  # Create site (drop if exists)
  if bench list-sites 2>/dev/null | grep -q \"^${SITE_NAME}$\"; then
    bench drop-site ${SITE_NAME} --force
  fi

  bench new-site ${SITE_NAME}

  bench get-app erpnext --branch version-15 https://github.com/frappe/erpnext
  bench get-app hrms --branch version-15

  bench --site ${SITE_NAME} install-app erpnext
  bench --site ${SITE_NAME} install-app hrms

  bench use ${SITE_NAME}
  bench --site ${SITE_NAME} enable-scheduler
  bench --site ${SITE_NAME} set-maintenance-mode off
"

echo "== 11) Production setup (Supervisor + NGINX) =="
# Frappe docs: 'sudo bench setup production' automates supervisor+nginx config. [web:55]
sudo -H -u "${FRAPPE_USER}" bash -lc "
  set -e
  cd ~/frappe-bench
  sudo bench setup production ${FRAPPE_USER}
  bench setup nginx
"

echo "== 12) Reload services =="
sudo nginx -t
sudo systemctl reload nginx
sudo supervisorctl restart all

echo "== DONE =="
echo "Open: http://<server-ip>/"
echo "Login: Administrator / password: ${SITE_NAME}"
