#!/usr/bin/env bash
# ==============================================================================
# ERPNext v15 + HRMS Auto-Installer for Ubuntu 22.04
# ==============================================================================
# This script executes the exact sequence of instructions requested,
# while handling user switching, environment variables, and permissions correctly.
set -euo pipefail

# ====== Settings ======
SITE_NAME="erpsite"
FRAPPE_USER="frappe"
FRAPPE_PASS="frappe"          # Password matching username (requested)
DB_ROOT_USER="root"
DB_ROOT_PASS="frappeDB"       # Requested database root password
ERP_ADMIN_USER="Administrator"
ERP_ADMIN_PASS="${SITE_NAME}" # Default admin password
BENCH_FOLDER="frappe-bench"

# ====== Helper: Run as frappe user ======
# Ensures NVM is loaded and we are in the home directory to prevent "permission denied"
run_as_frappe() {
  sudo -H -u "${FRAPPE_USER}" bash -lc "
    export NVM_DIR=\"\$HOME/.nvm\"
    [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"
    cd ~ && $*
  "
}

echo "== 0) Checking root permissions =="
if [ "$(id -u)" -ne 0 ]; then
  echo "Error: Run as root (sudo bash $0)"
  exit 1
fi

echo "== 1) Updating Ubuntu & Removing conflicting Node v12 =="
sudo apt-get update -y && sudo apt-get upgrade -y && sudo apt-get autoremove -y
# Remove default Ubuntu Node v12 to prevent conflicts with NVM
sudo apt-get remove -y nodejs npm libnode-dev || true
sudo apt-get autoremove -y

echo "== 2) Creating '${FRAPPE_USER}' user =="
if ! id -u "${FRAPPE_USER}" >/dev/null 2>&1; then
  sudo adduser --disabled-password --gecos "" "${FRAPPE_USER}"
fi
echo "${FRAPPE_USER}:${FRAPPE_PASS}" | sudo chpasswd
sudo usermod -aG sudo "${FRAPPE_USER}"

echo "== 3) Installing system prerequisites =="
# Note: running these as root (sudo) as requested
sudo apt-get install git -y && sudo apt-get install python3-dev -y && sudo apt-get install python3-setuptools python3-pip -y && sudo apt install python3-venv -y && sudo apt-get install software-properties-common -y

echo "== 4) Installing & Configuring MariaDB =="
sudo apt install mariadb-server -y
# Note: mysql_secure_installation is interactive; we automate the root password setting below instead.

# Write custom config
sudo bash -c "cat > /etc/mysql/mariadb.conf.d/99-erpnext-utf8mb4.cnf <<EOF
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4
EOF"
sudo systemctl restart mariadb

# Set MariaDB Root Password to 'frappeDB'
sudo mariadb -u root <<SQL
FLUSH PRIVILEGES;
ALTER USER '${DB_ROOT_USER}'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
FLUSH PRIVILEGES;
SQL

echo "== 5) Installing Redis & Node tools =="
sudo apt-get install redis-server -y
# We install curl but NOT npm from apt (to avoid Node v12). We install Yarn via NVM's npm later.
sudo apt install curl -y

echo "== 6) Installing NVM + Node 18 + Yarn (as frappe user) =="
# This block runs as 'frappe' to set up the user environment
run_as_frappe '
  curl -o- https://raw.githubusercontent.com/creationix/nvm/master/install.sh | bash
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  nvm install 18
  nvm use 18
  nvm alias default 18
  npm install -g yarn
  node -v
  yarn -v
'

echo "== 7) Installing PDF tools =="
sudo apt-get install xvfb libfontconfig wkhtmltopdf -y

echo "== 8) Installing Frappe Bench CLI =="
# Check pip version to handle flag differences (Ubuntu 22.04 vs 23+)
PIP_VERSION=$(pip3 --version | awk '{print $2}' | cut -d. -f1)
if [ "$PIP_VERSION" -ge 23 ]; then
  sudo pip3 install --break-system-packages frappe-bench
else
  sudo pip3 install frappe-bench
fi

echo "== 9) Initializing Bench & Installing Apps (as frappe user) =="
run_as_frappe "
  # Initialize Bench
  if [ -d ~/${BENCH_FOLDER} ]; then 
    echo 'Bench exists, skipping init'
  else 
    bench init --frappe-branch version-15 ${BENCH_FOLDER}
  fi
  
  cd ~/${BENCH_FOLDER}
  
  # Fix permissions (requested step)
  sudo chmod -R o+rx /home/${FRAPPE_USER}

  # Create Site
  if bench list-sites 2>/dev/null | grep -qx '${SITE_NAME}'; then
    bench drop-site '${SITE_NAME}' --force
  fi

  bench new-site '${SITE_NAME}' \
    --db-root-username '${DB_ROOT_USER}' \
    --db-root-password '${DB_ROOT_PASS}' \
    --admin-password '${ERP_ADMIN_PASS}'

  # Get & Install Apps
  bench get-app erpnext --branch version-15 https://github.com/frappe/erpnext
  bench get-app hrms --branch version-15

  bench --site '${SITE_NAME}' install-app erpnext
  bench --site '${SITE_NAME}' install-app hrms

  # Setup Site
  bench use '${SITE_NAME}'
  bench --site '${SITE_NAME}' enable-scheduler
  bench --site '${SITE_NAME}' set-maintenance-mode off
"

echo "== 10) Configuring Production (Nginx + Supervisor) =="
run_as_frappe "
  cd ~/${BENCH_FOLDER}
  sudo bench setup production ${FRAPPE_USER}
  bench setup nginx
"

echo "== 11) Finalizing Services =="
sudo nginx -t
sudo systemctl reload nginx

# Fix 'no such group' error by reloading supervisor configuration
sudo service supervisor reload
sudo supervisorctl update
sudo supervisorctl restart all

SERVER_IP="$(hostname -I | awk '{print $1}')"

echo "=================================================="
echo "   INSTALLATION COMPLETE!"
echo "=================================================="
echo "Open Browser URL  : http://${SERVER_IP}/"
echo ""
echo "--- System Access ---"
echo "Linux User        : ${FRAPPE_USER}"
echo "Linux Password    : ${FRAPPE_PASS}"
echo "MariaDB Root Pass : ${DB_ROOT_PASS}"
echo ""
echo "--- ERPNext Login ---"
echo "Username          : ${ERP_ADMIN_USER}"
echo "Password          : ${ERP_ADMIN_PASS}"
echo "=================================================="
