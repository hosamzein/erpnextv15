#!/usr/bin/env bash
set -euo pipefail

# ====== Settings (as requested) ======
SITE_NAME="erpsite"

FRAPPE_USER="frappe"
FRAPPE_PASS="frappe"          # password = username

DB_ROOT_USER="root"
DB_ROOT_PASS="frappeDB"       # requested

ERP_ADMIN_USER="Administrator"
ERP_ADMIN_PASS="${SITE_NAME}" # requested earlier

BENCH_FOLDER="frappe-bench"

# ====== Helpers ======
run_as_frappe() {
  # Always start in frappe HOME to avoid permission errors (e.g., /home/admin1/.yarnrc). [web:208]
  sudo -H -u "${FRAPPE_USER}" bash -lc "cd ~ && $*"
}

echo "== 0) Must run as root (sudo) =="
if [ "$(id -u)" -ne 0 ]; then
  echo "Run: sudo bash $0"
  exit 1
fi

echo "== 1) Update Ubuntu + cleanup =="
apt-get update -y
apt-get upgrade -y
apt-get autoremove -y

echo "== 2) Create frappe user + set password =="
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

echo "== 4) Yarn (global) =="
npm install -g yarn

echo "== 5) Enable services =="
systemctl enable --now mariadb redis-server nginx supervisor

echo "== 6) MariaDB utf8mb4 config =="
cat >/etc/mysql/mariadb.conf.d/99-erpnext-utf8mb4.cnf <<'EOF'
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4
EOF
systemctl restart mariadb

echo "== 7) Set MariaDB root password (${DB_ROOT_PASS}) =="
# Try to set root password even if root currently authenticates via unix_socket.
mariadb -u root <<SQL
FLUSH PRIVILEGES;
ALTER USER '${DB_ROOT_USER}'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
FLUSH PRIVILEGES;
SQL

echo "== 8) Install NVM + Node 18 for frappe user =="
run_as_frappe 'curl -fsSL https://raw.githubusercontent.com/creationix/nvm/master/install.sh | bash'
run_as_frappe 'source ~/.profile || true; export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; nvm install 18; nvm use 18; node -v; npm -v'

echo "== 9) Install Frappe Bench (pip3 method) =="
pip3 install --break-system-packages frappe-bench

echo "== 10) Ensure frappe can run bench (PATH) =="
# If bench was installed under /usr/local/bin, it should already be in PATH; this just validates.
run_as_frappe 'command -v bench && bench --version'

echo "== 11) bench init v15 =="
run_as_frappe "if [ -d ~/${BENCH_FOLDER} ]; then echo 'Bench exists, skipping init'; else bench init --frappe-branch version-15 ${BENCH_FOLDER}; fi"

echo "== 12) Create site + install ERPNext + HRMS =="
run_as_frappe "
  cd ~/${BENCH_FOLDER}

  # Your optional permission step
  sudo chmod -R o+rx /home/${FRAPPE_USER}

  # Drop site if it exists
  if bench list-sites 2>/dev/null | grep -qx '${SITE_NAME}'; then
    bench drop-site '${SITE_NAME}' --force
  fi

  # Create site non-interactively (DB + Admin passwords)
  bench new-site '${SITE_NAME}' \
    --db-root-username '${DB_ROOT_USER}' \
    --db-root-password '${DB_ROOT_PASS}' \
    --admin-password '${ERP_ADMIN_PASS}'

  bench get-app erpnext --branch version-15 https://github.com/frappe/erpnext
  bench get-app hrms --branch version-15

  bench --site '${SITE_NAME}' install-app erpnext
  bench --site '${SITE_NAME}' install-app hrms

  bench use '${SITE_NAME}'
  bench --site '${SITE_NAME}' enable-scheduler
  bench --site '${SITE_NAME}' set-maintenance-mode off
"

echo "== 13) Production setup (Supervisor + NGINX) =="
# Production setup is done via `sudo bench setup production <user>` in Frappe docs. [web:55]
run_as_frappe "
  cd ~/${BENCH_FOLDER}
  sudo bench setup production ${FRAPPE_USER}
  bench setup nginx
"

echo "== 14) Reload NGINX + restart Supervisor =="
nginx -t
systemctl reload nginx
supervisorctl restart all

SERVER_IP="$(hostname -I | awk '{print $1}')"

echo "============================="
echo "ERPNext v15 installed"
echo "URL: http://${SERVER_IP}/"
echo "Linux user: ${FRAPPE_USER}"
echo "Linux password: ${FRAPPE_PASS}"
echo "MariaDB root user: ${DB_ROOT_USER}"
echo "MariaDB root password: ${DB_ROOT_PASS}"
echo "ERPNext user: ${ERP_ADMIN_USER}"
echo "ERPNext password: ${ERP_ADMIN_PASS}"
echo "Site name: ${SITE_NAME}"
echo "============================="
