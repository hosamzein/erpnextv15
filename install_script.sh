#!/usr/bin/env bash
# ==============================================================================
# ERPNext v15 + HRMS Auto-Installer for Ubuntu 22.04 (Production)
# ==============================================================================

set -euo pipefail

# ====== Settings ======
SITE_NAME="erpsite"
FRAPPE_USER="frappe"
FRAPPE_PASS="frappe"          # Linux user password
DB_ROOT_USER="root"
DB_ROOT_PASS="frappeDB"       # MariaDB root password
ERP_ADMIN_USER="Administrator"
ERP_ADMIN_PASS="${SITE_NAME}" # ERPNext Administrator password
BENCH_FOLDER="frappe-bench"

# ====== Helper: Run as frappe user with NVM loaded ======
run_as_frappe() {
  sudo -H -u "${FRAPPE_USER}" bash -lc "
    export NVM_DIR=\"\$HOME/.nvm\"
    [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"
    cd ~ && $*
  "
}

echo '== 0) Ensure script is run as root =='
if [ "$(id -u)" -ne 0 ]; then
  echo "Error: run with sudo: sudo bash $0"
  exit 1
fi

# ------------------------------------------------------------------------------
# 1) Ubuntu updates & cleanup
# ------------------------------------------------------------------------------
echo '== 1) Ubuntu update / upgrade / autoremove =='
sudo apt-get update -y && sudo apt-get upgrade -y && sudo apt-get autoremove -y

# Remove conflicting system Node v12 (so we only use NVM Node 18) [web:251]
sudo apt-get remove -y nodejs npm libnode-dev || true
sudo apt-get autoremove -y

# ------------------------------------------------------------------------------
# 2) Create frappe user (sudo)
# ------------------------------------------------------------------------------
echo "== 2) Create '${FRAPPE_USER}' user and add to sudo =="
if ! id -u "${FRAPPE_USER}" >/dev/null 2>&1; then
  sudo adduser --disabled-password --gecos "" "${FRAPPE_USER}"
fi
echo "${FRAPPE_USER}:${FRAPPE_PASS}" | sudo chpasswd
sudo usermod -aG sudo "${FRAPPE_USER}"

# ------------------------------------------------------------------------------
# 3) Install Git, Python, venv, tools
# ------------------------------------------------------------------------------
echo '== 3) Install Git / Python / venv / misc =='
sudo apt-get install git -y
sudo apt-get install python3-dev -y
sudo apt-get install python3-setuptools python3-pip -y
sudo apt-get install python3-venv -y
sudo apt-get install software-properties-common -y

# ------------------------------------------------------------------------------
# 4) MariaDB install & config
# ------------------------------------------------------------------------------
echo '== 4) Install MariaDB =='
sudo apt install mariadb-server -y

echo '== 5) Configure MariaDB utf8mb4 =='
sudo bash -c "cat > /etc/mysql/mariadb.conf.d/99-erpnext-utf8mb4.cnf <<EOF
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4
EOF"
sudo systemctl restart mariadb

echo "== 6) Set MariaDB root password to '${DB_ROOT_PASS}' =="
sudo mariadb -u root <<SQL
FLUSH PRIVILEGES;
ALTER USER '${DB_ROOT_USER}'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
FLUSH PRIVILEGES;
SQL

# ------------------------------------------------------------------------------
# 5) Redis, curl (no apt npm to avoid Node 12)
# ------------------------------------------------------------------------------
echo '== 7) Install Redis & curl =='
sudo apt-get install redis-server -y
sudo apt install curl -y

# ------------------------------------------------------------------------------
# 6) NVM + Node 18 + Yarn (as frappe user)
# ------------------------------------------------------------------------------
echo '== 8) Install NVM, Node 18, Yarn for frappe user =='
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

# ------------------------------------------------------------------------------
# 7) wkhtmltopdf & prerequisites
# ------------------------------------------------------------------------------
echo '== 9) Install wkhtmltopdf and related libs =='
sudo apt-get install xvfb libfontconfig wkhtmltopdf -y

# ------------------------------------------------------------------------------
# 8) Install frappe-bench CLI
# ------------------------------------------------------------------------------
echo '== 10) Install frappe-bench using pip3 =='
PIP_MAJOR=$(pip3 --version | awk '{print $2}' | cut -d. -f1)
if [ "${PIP_MAJOR}" -ge 23 ]; then
  sudo pip3 install --break-system-packages frappe-bench
else
  sudo pip3 install frappe-bench
fi

echo '== 11) Verify bench for frappe user =='
run_as_frappe 'bench --version'

# ------------------------------------------------------------------------------
# 9) Bench init, site creation, apps (as frappe user)
# ------------------------------------------------------------------------------
echo '== 12) bench init --frappe-branch version-15 frappe-bench =='
run_as_frappe "
  if [ -d ~/${BENCH_FOLDER} ]; then
    echo 'Bench folder exists, skipping init'
  else
    bench init --frappe-branch version-15 ${BENCH_FOLDER}
  fi
"

echo '== 13) Site creation and ERPNext/HRMS install =='
run_as_frappe "
  cd ~/${BENCH_FOLDER}

  # Permissions as per your original instructions
  sudo chmod -R o+rx /home/${FRAPPE_USER}

  # Drop existing site if present for clean reinstall
  if bench list-sites 2>/dev/null | grep -qx '${SITE_NAME}'; then
    bench drop-site '${SITE_NAME}' --force
  fi

  # Create new site with DB and admin passwords
  bench new-site '${SITE_NAME}' \
    --db-root-username '${DB_ROOT_USER}' \
    --db-root-password '${DB_ROOT_PASS}' \
    --admin-password '${ERP_ADMIN_PASS}'

  # Install ERPNext and HRMS apps
  bench get-app erpnext --branch version-15 https://github.com/frappe/erpnext
  bench get-app hrms --branch version-15

  bench --site '${SITE_NAME}' install-app erpnext
  bench --site '${SITE_NAME}' install-app hrms

  bench use '${SITE_NAME}'
  bench --site '${SITE_NAME}' enable-scheduler
  bench --site '${SITE_NAME}' set-maintenance-mode off
"

# ------------------------------------------------------------------------------
# 10) Production setup & NGINX
# ------------------------------------------------------------------------------
echo '== 14) Production setup (first pass) =='
run_as_frappe "
  cd ~/${BENCH_FOLDER}
  sudo bench setup production ${FRAPPE_USER}
  bench setup nginx
"

echo '== 15) Test and reload NGINX =='
sudo nginx -t
sudo systemctl reload nginx

echo '== 16) Run sudo bench setup production frappe (as requested) =='
sudo bench setup production frappe

# ------------------------------------------------------------------------------
# 11) Supervisor reload & restart
# ------------------------------------------------------------------------------
echo '== 17) Reload supervisor and restart all processes =='
sudo service supervisor reload
sudo supervisorctl update
sudo supervisorctl restart all

# ------------------------------------------------------------------------------
# 12) Final info
# ------------------------------------------------------------------------------
SERVER_IP="$(hostname -I | awk '{print $1}')"

echo "=================================================="
echo "   ERPNext v15 Installation COMPLETE"
echo "=================================================="
echo "Open in browser : http://${SERVER_IP}/"
echo ""
echo "--- System Access ---"
echo "Linux user       : ${FRAPPE_USER}"
echo "Linux password   : ${FRAPPE_PASS}"
echo "MariaDB root pass: ${DB_ROOT_PASS}"
echo ""
echo "--- ERPNext Login ---"
echo "Username         : ${ERP_ADMIN_USER}"
echo "Password         : ${ERP_ADMIN_PASS}"
echo "Site name        : ${SITE_NAME}"
echo "=================================================="
