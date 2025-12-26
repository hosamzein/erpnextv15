#!/usr/bin/env bash
# ==============================================================================
# ERPNext v15 + HRMS Auto-Installer for Ubuntu 22.04
# ==============================================================================
# This script automates the installation of a production-ready ERPNext system.
# It handles dependencies, user creation, database setup, and Nginx configuration.
#
# Flags used:
#   set -e : Exit immediately if any command exits with a non-zero status.
#   set -u : Treat unset variables as an error.
#   set -o pipefail : Return the exit status of the last command in the pipe that failed.
set -euo pipefail

# ==============================================================================
# 1. CONFIGURATION VARIABLES
# ==============================================================================
SITE_NAME="erpsite"             # The name of your ERPNext site (and folder name in sites/)

FRAPPE_USER="frappe"            # The system user that will own the Bench files
FRAPPE_PASS="frappe"            # Password for the system user

DB_ROOT_USER="root"             # MariaDB root username
DB_ROOT_PASS="frappeDB"         # Password for MariaDB root user (used to create app databases)

ERP_ADMIN_USER="Administrator"  # The built-in ERPNext Administrator username
ERP_ADMIN_PASS="${SITE_NAME}"   # Password for the ERPNext Administrator (defaulting to site name)

BENCH_FOLDER="frappe-bench"     # The directory name for the Frappe environment

# ==============================================================================
# 2. HELPER FUNCTION: RUN AS FRAPPE USER
# ==============================================================================
# This function is critical. It runs commands as the 'frappe' user but ensures
# the environment (NVM, PATH, Home Directory) is set up correctly every time.
#
# Why is this needed?
# When you use 'sudo -u', it doesn't automatically load the user's .bashrc profile.
# This means NVM (Node Version Manager) isn't loaded, so 'node' or 'yarn' commands fail
# or revert to the wrong system version (v12).
#
# This function:
#   1. Loads NVM manually (source nvm.sh).
#   2. Switches to the user's home directory (cd ~) to avoid permission errors.
#   3. Runs the passed command ($*).
run_as_frappe() {
  sudo -H -u "${FRAPPE_USER}" bash -lc "
    export NVM_DIR=\"\$HOME/.nvm\"
    [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"
    cd ~ && $*
  "
}

# ==============================================================================
# 3. ROOT CHECK
# ==============================================================================
echo "== 0) Checking root permissions =="
if [ "$(id -u)" -ne 0 ]; then
  echo "Error: This script must be run as root. Please use: sudo bash $0"
  exit 1
fi

# ==============================================================================
# 4. SYSTEM CLEANUP & UPDATES
# ==============================================================================
echo "== 1) Updating Ubuntu & Removing conflicting Node versions =="
apt-get update -y
apt-get upgrade -y

# IMPORTANT: Ubuntu 22.04 ships with Node v12 by default. ERPNext v15 requires Node v18.
# If v12 is present, Bench might accidentally use it and fail. We remove it here.
apt-get remove -y nodejs npm libnode-dev || true
apt-get autoremove -y

# ==============================================================================
# 5. USER CREATION
# ==============================================================================
echo "== 2) Creating '${FRAPPE_USER}' system user =="
# Check if user exists; if not, create it with no password prompt
if ! id -u "${FRAPPE_USER}" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "${FRAPPE_USER}"
fi
# Set the password explicitly
echo "${FRAPPE_USER}:${FRAPPE_PASS}" | chpasswd
# Add user to sudo group so it can restart services later (production setup)
usermod -aG sudo "${FRAPPE_USER}"

# ==============================================================================
# 6. SYSTEM PREREQUISITES
# ==============================================================================
echo "== 3) Installing system packages =="
# Install Python build tools, database clients, redis, web server, and PDF generator
apt-get install -y \
  git software-properties-common \
  python3-dev python3-setuptools python3-pip python3-venv \
  mariadb-server mariadb-client \
  redis-server \
  nginx supervisor \
  curl \
  xvfb libfontconfig wkhtmltopdf

# Note: We purposely do NOT install 'npm' here to avoid re-installing Node v12.

# ==============================================================================
# 7. SERVICE CONFIGURATION
# ==============================================================================
echo "== 4) Enabling services =="
# Ensure services start automatically on reboot
systemctl enable --now mariadb redis-server nginx supervisor

echo "== 5) Configuring MariaDB (utf8mb4) =="
# ERPNext requires the 'utf8mb4' character set (for emojis, etc.)
# We create a custom config file that overrides the defaults.
cat >/etc/mysql/mariadb.conf.d/99-erpnext-utf8mb4.cnf <<'EOF'
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4
EOF
systemctl restart mariadb

echo "== 6) Setting MariaDB root password =="
# We set the MariaDB root password so Bench can automate database creation.
mariadb -u root <<SQL
FLUSH PRIVILEGES;
ALTER USER '${DB_ROOT_USER}'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
FLUSH PRIVILEGES;
SQL

# ==============================================================================
# 8. NODE.JS SETUP (USER LEVEL)
# ==============================================================================
echo "== 7) Installing NVM, Node 18, and Yarn for '${FRAPPE_USER}' =="
# We install Node.js using NVM (Node Version Manager) specifically for the frappe user.
# This isolates the environment and ensures we get the exact version we need (v18).
run_as_frappe '
  # Install NVM
  curl -fsSL https://raw.githubusercontent.com/creationix/nvm/master/install.sh | bash
  
  # Load NVM immediately for this session
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  
  # Install and use Node 18
  nvm install 18
  nvm use 18
  nvm alias default 18
  
  # Install Yarn (package manager used by Bench)
  npm install -g yarn
  
  # Verify versions
  node -v
  yarn -v
'

# ==============================================================================
# 9. BENCH INSTALLATION
# ==============================================================================
echo "== 8) Installing Frappe Bench CLI =="
# We check the pip version to handle flag differences between Ubuntu versions.
# Ubuntu 22.04 (older pip) -> No flag needed.
# Ubuntu 23.04+ (newer pip) -> Needs --break-system-packages.
PIP_VERSION=$(pip3 --version | awk '{print $2}' | cut -d. -f1)
if [ "$PIP_VERSION" -ge 23 ]; then
  pip3 install --break-system-packages frappe-bench
else
  pip3 install frappe-bench
fi

echo "== 9) Verifying Bench =="
# Ensure the 'frappe' user can see the 'bench' command
run_as_frappe 'bench --version'

# ==============================================================================
# 10. SITE & APP SETUP
# ==============================================================================
echo "== 10) Initializing Bench (Downloading Frappe Framework) =="
# 'bench init' downloads the core framework.
# We skip if the folder already exists to allow re-running the script.
run_as_frappe "if [ -d ~/${BENCH_FOLDER} ]; then echo 'Bench exists, skipping init'; else bench init --frappe-branch version-15 ${BENCH_FOLDER}; fi"

echo "== 11) Creating Site and Installing ERPNext + HRMS =="
run_as_frappe "
  cd ~/${BENCH_FOLDER}
  
  # Fix home directory permissions so Nginx can access static files
  sudo chmod -R o+rx /home/${FRAPPE_USER}

  # If the site exists, drop it (CLEAN INSTALL)
  if bench list-sites 2>/dev/null | grep -qx '${SITE_NAME}'; then
    bench drop-site '${SITE_NAME}' --force
  fi

  # Create the new site
  # We pass the DB root password so it doesn't ask interactively.
  # We set the Administrator password here as well.
  bench new-site '${SITE_NAME}' \
    --db-root-username '${DB_ROOT_USER}' \
    --db-root-password '${DB_ROOT_PASS}' \
    --admin-password '${ERP_ADMIN_PASS}'

  # Download the Apps
  bench get-app erpnext --branch version-15 https://github.com/frappe/erpnext
  bench get-app hrms --branch version-15

  # Install Apps on the Site
  bench --site '${SITE_NAME}' install-app erpnext
  bench --site '${SITE_NAME}' install-app hrms

  # Set Default Site
  bench use '${SITE_NAME}'
  
  # Enable Scheduler (background jobs) & disable maintenance mode
  bench --site '${SITE_NAME}' enable-scheduler
  bench --site '${SITE_NAME}' set-maintenance-mode off
"

# ==============================================================================
# 11. PRODUCTION CONFIGURATION
# ==============================================================================
echo "== 12) Configuring Production (Nginx + Supervisor) =="
# This generates the Nginx config (for web access) and Supervisor config (for process management)
# and links them to the system directories.
run_as_frappe "
  cd ~/${BENCH_FOLDER}
  sudo bench setup production ${FRAPPE_USER}
  bench setup nginx
"

echo "== 13) Reloading Web Server =="
# Test config syntax and restart
nginx -t
systemctl reload nginx
supervisorctl restart all

# ==============================================================================
# 12. FINISH
# ==============================================================================
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
