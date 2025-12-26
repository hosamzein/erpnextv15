#!/usr/bin/env bash
set -euo pipefail

# ====== Settings ======
SITE_NAME="erpsite"
FRAPPE_USER="frappe"
FRAPPE_PASS="frappe"          
DB_ROOT_USER="root"
DB_ROOT_PASS="frappeDB"       
ERP_ADMIN_USER="Administrator"
ERP_ADMIN_PASS="${SITE_NAME}" 
BENCH_FOLDER="frappe-bench"

# ====== Helper: Run as frappe user with NVM loaded ======
run_as_frappe() {
  # We explicity load NVM before running the command to ensure we use Node 18, not system Node 12
  sudo -H -u "${FRAPPE_USER}" bash -lc "
    export NVM_DIR=\"\$HOME/.nvm\"
    [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"
    cd ~ && $*
  "
}

echo "== 0) Must run as root (sudo) =="
if [ "$(id -u)" -ne 0 ]; then
  echo "Run: sudo bash $0"
  exit 1
fi

echo "== 1) Update Ubuntu & REMOVE conflicting system Node.js =="
apt-get update -y
apt-get upgrade -y
# Important: Remove Ubuntu's default Node 12 to prevent conflicts
apt-get remove -y nodejs npm libnode-dev || true
apt-get autoremove -y

echo "== 2) Create frappe user =="
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
  curl \
  xvfb libfontconfig wkhtmltopdf

# Note: We do NOT install 'npm' from apt here because it brings back Node 12.
# We will use NVM's npm instead.

echo "== 4) Enable services =="
systemctl enable --now mariadb redis-server nginx supervisor

echo "== 5) MariaDB utf8mb4 config =="
cat >/etc/mysql/mariadb.conf.d/99-erpnext-utf8mb4.cnf <<'EOF'
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4
EOF
systemctl restart mariadb

echo "== 6) Set MariaDB root password (${DB_ROOT_PASS}) =="
mariadb -u root <<SQL
FLUSH PRIVILEGES;
ALTER USER '${DB_ROOT_USER}'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
FLUSH PRIVILEGES;
SQL

echo "== 7) Install NVM + Node 18 + Yarn for frappe user =="
# We install NVM, then immediately install Node 18 and Yarn
run_as_frappe '
  curl -fsSL https://raw.githubusercontent.com/creationix/nvm/master/install.sh | bash
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  nvm install 18
  nvm use 18
  nvm alias default 18
  npm install -g yarn
  node -v
  yarn -v
'

echo "== 8) Install Frappe Bench (Ubuntu 22.04 compatible) =="
PIP_VERSION=$(pip3 --version | awk '{print $2}' | cut -d. -f1)
if [ "$PIP_VERSION" -ge 23 ]; then
  pip3 install --break-system-packages frappe-bench
else
  pip3 install frappe-bench
fi

echo "== 9) Ensure bench is ready =="
run_as_frappe 'bench --version'

echo "== 10) bench init v15 =="
# This will now use the NVM Node version because of our helper function
run_as_frappe "if [ -d ~/${BENCH_FOLDER} ]; then echo 'Bench exists, skipping init'; else bench init --frappe-branch version-15 ${BENCH_FOLDER}; fi"

echo "== 11) Create site + install ERPNext + HRMS =="
run_as_frappe "
  cd ~/${BENCH_FOLDER}
  sudo chmod -R o+rx /home/${FRAPPE_USER}

  if bench list-sites 2>/dev/null | grep -qx '${SITE_NAME}'; then
    bench drop-site '${SITE_NAME}' --force
  fi

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

echo "== 12) Production setup =="
run_as_frappe "
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
echo "ERPNext v15 installed successfully"
echo "URL: http://${SERVER_IP}/"
echo "Linux user: ${FRAPPE_USER}"
echo "Linux password: ${FRAPPE_PASS}"
echo "MariaDB root user: ${DB_ROOT_USER}"
echo "MariaDB root password: ${DB_ROOT_PASS}"
echo "ERPNext user: ${ERP_ADMIN_USER}"
echo "ERPNext password: ${ERP_ADMIN_PASS}"
echo "Site name: ${SITE_NAME}"
echo "============================="
