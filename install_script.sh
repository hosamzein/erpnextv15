#!/usr/bin/env bash
# Exit immediately if any command fails (-e), if a variable is unset (-u),
# or if any command in a pipeline fails (-o pipefail).
set -euo pipefail

# ==========================================
# CONFIGURATION VARIABLES
# ==========================================
SITE_NAME="erpsite"             # The name of the ERPNext site to create

FRAPPE_USER="frappe"            # Linux system user that will run the application
FRAPPE_PASS="frappe"            # Password for the 'frappe' Linux user

DB_ROOT_USER="root"             # MariaDB root username
DB_ROOT_PASS="frappeDB"         # MariaDB root password (for database creation)

ERP_ADMIN_USER="Administrator"  # ERPNext web login username
ERP_ADMIN_PASS="${SITE_NAME}"   # ERPNext web login password (defaults to site name)

BENCH_FOLDER="frappe-bench"     # Folder name where Frappe environment lives

# ==========================================
# HELPER FUNCTION
# ==========================================
# This function runs commands as the 'frappe' user.
# It solves the "Permission Denied" errors by forcing the shell
# to switch to the user's home directory (cd ~) before running anything.
run_as_frappe() {
  sudo -H -u "${FRAPPE_USER}" bash -lc "cd ~ && $*"
}

# ==========================================
# PRE-FLIGHT CHECKS
# ==========================================
echo "== 0) Checking root permissions =="
if [ "$(id -u)" -ne 0 ]; then
  echo "Error: This script must be run as root. Use: sudo bash $0"
  exit 1
fi

# ==========================================
# SYSTEM SETUP
# ==========================================
echo "== 1) Updating Ubuntu packages =="
apt-get update -y
apt-get upgrade -y
apt-get autoremove -y

echo "== 2) Creating '${FRAPPE_USER}' system user =="
# Create user only if it doesn't exist
if ! id -u "${FRAPPE_USER}" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "${FRAPPE_USER}"
fi
# Set the password for the user
echo "${FRAPPE_USER}:${FRAPPE_PASS}" | chpasswd
# Add user to sudo group (required for production setup later)
usermod -aG sudo "${FRAPPE_USER}"

echo "== 3) Installing system prerequisites =="
# Install Python, MariaDB, Redis, NGINX, Supervisor, and PDF tools
apt-get install -y \
  git software-properties-common \
  python3-dev python3-setuptools python3-pip python3-venv \
  mariadb-server mariadb-client \
  redis-server \
  nginx supervisor \
  curl npm \
  xvfb libfontconfig wkhtmltopdf

echo "== 4) Installing Yarn (globally) =="
# Needed for building frontend assets
npm install -g yarn

echo "== 5) Enabling system services =="
# Ensure database and web servers start on boot
systemctl enable --now mariadb redis-server nginx supervisor

# ==========================================
# DATABASE CONFIGURATION
# ==========================================
echo "== 6) Configuring MariaDB for UTF-8 (utf8mb4) =="
# ERPNext requires utf8mb4 character set for emojis and special characters.
# We write a custom config file to ensure this persists.
cat >/etc/mysql/mariadb.conf.d/99-erpnext-utf8mb4.cnf <<'EOF'
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4
EOF
# Restart MariaDB to apply changes
systemctl restart mariadb

echo "== 7) Setting MariaDB root password =="
# Set the root password so bench can create databases later.
# We use SQL commands to force the password update safely.
mariadb -u root <<SQL
FLUSH PRIVILEGES;
ALTER USER '${DB_ROOT_USER}'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
FLUSH PRIVILEGES;
SQL

# ==========================================
# USER ENVIRONMENT SETUP
# ==========================================
echo "== 8) Installing Node.js 18 for '${FRAPPE_USER}' =="
# We use NVM (Node Version Manager) to install Node 18 specifically for the frappe user.
# This keeps the Node environment isolated and clean.
run_as_frappe 'curl -fsSL https://raw.githubusercontent.com/creationix/nvm/master/install.sh | bash'
run_as_frappe 'source ~/.profile || true; export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; nvm install 18; nvm use 18; node -v; npm -v'

echo "== 9) Installing Frappe Bench CLI =="
# We check the pip version because Ubuntu 22.04's pip is old and doesn't support
# the "--break-system-packages" flag, while newer Ubuntu versions require it.
PIP_VERSION=$(pip3 --version | awk '{print $2}' | cut -d. -f1)
if [ "$PIP_VERSION" -ge 23 ]; then
  # Newer pip (Ubuntu 23.04+) requires this flag
  pip3 install --break-system-packages frappe-bench
else
  # Older pip (Ubuntu 22.04) works without it
  pip3 install frappe-bench
fi

echo "== 10) Verifying Bench installation =="
# Confirm bench is installed and accessible to the frappe user
run_as_frappe 'command -v bench && bench --version'

# ==========================================
# FRAPPE & ERPNEXT INSTALLATION
# ==========================================
echo "== 11) Initializing Frappe Framework (v15) =="
# Downloads the core Frappe framework into the bench folder
run_as_frappe "if [ -d ~/${BENCH_FOLDER} ]; then echo 'Bench exists, skipping init'; else bench init --frappe-branch version-15 ${BENCH_FOLDER}; fi"

echo "== 12) Creating Site and Installing ERPNext + HRMS =="
run_as_frappe "
  cd ~/${BENCH_FOLDER}
  
  # Fix permissions so NGINX/Supervisor can read the files later
  sudo chmod -R o+rx /home/${FRAPPE_USER}

  # Check if site exists, drop it if forcing a reinstall
  if bench list-sites 2>/dev/null | grep -qx '${SITE_NAME}'; then
    bench drop-site '${SITE_NAME}' --force
  fi

  # Create a new site. We pass DB credentials here so it's non-interactive.
  bench new-site '${SITE_NAME}' \
    --db-root-username '${DB_ROOT_USER}' \
    --db-root-password '${DB_ROOT_PASS}' \
    --admin-password '${ERP_ADMIN_PASS}'

  # Download the Apps (ERPNext and HRMS) from GitHub
  bench get-app erpnext --branch version-15 https://github.com/frappe/erpnext
  bench get-app hrms --branch version-15

  # Install the Apps onto our specific site
  bench --site '${SITE_NAME}' install-app erpnext
  bench --site '${SITE_NAME}' install-app hrms

  # Set this site as default
  bench use '${SITE_NAME}'
  
  # Enable background jobs (Scheduler)
  bench --site '${SITE_NAME}' enable-scheduler
  bench --site '${SITE_NAME}' set-maintenance-mode off
"

# ==========================================
# PRODUCTION CONFIGURATION
# ==========================================
echo "== 13) specificing Production Setup (NGINX + Supervisor) =="
# This command generates NGINX and Supervisor config files automatically.
# It tells the system how to run ERPNext as a service.
run_as_frappe "
  cd ~/${BENCH_FOLDER}
  sudo bench setup production ${FRAPPE_USER}
  bench setup nginx
"

echo "== 14) Reloading Services =="
# Test NGINX config and restart services to apply changes
nginx -t
systemctl reload nginx
supervisorctl restart all

# ==========================================
# COMPLETION SUMMARY
# ==========================================
SERVER_IP="$(hostname -I | awk '{print $1}')"

echo "=================================================="
echo "   INSTALLATION COMPLETE!"
echo "=================================================="
echo "Access ERPNext at : http://${SERVER_IP}/"
echo ""
echo "--- System Credentials ---"
echo "Linux User        : ${FRAPPE_USER}"
echo "Linux Password    : ${FRAPPE_PASS}"
echo "MariaDB Root Pass : ${DB_ROOT_PASS}"
echo ""
echo "--- ERPNext Credentials ---"
echo "URL               : http://${SERVER_IP}/"
echo "Username          : ${ERP_ADMIN_USER}"
echo "Password          : ${ERP_ADMIN_PASS}"
echo "=================================================="
