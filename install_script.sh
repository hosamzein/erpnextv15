#!/usr/bin/env bash
set -euo pipefail

# ---- Variables (edit if needed) ----
BENCH_USER="frappe"
BENCH_DIR="/home/${BENCH_USER}/frappe-bench"
SITE_NAME="erpsite"
ADMIN_PASSWORD="frappe"     # ERPNext login: Administrator
DB_ROOT_PASS="frappeDB"     # MariaDB root password
FRAPPE_BRANCH="version-15"
ERPNEXT_BRANCH="version-15"
HRMS_BRANCH="version-15"

# ---- 0) Basic packages ----
sudo apt-get update -y
sudo apt-get install -y git curl python3-venv mariadb-client nginx supervisor

# ---- 1) Optional: set Linux user password = username (NOT recommended) ----
echo "${BENCH_USER}:${BENCH_USER}" | sudo chpasswd

# ---- 2) Install Bench using pipx ----
sudo apt-get install -y pipx
pipx ensurepath || true

# Ensure pipx bin is available in this shell session
export PATH="$HOME/.local/bin:$PATH"

# Install bench if not present
if ! command -v bench >/dev/null 2>&1; then
  pipx install frappe-bench
fi

# Bench init currently needs 'uv' on some setups
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

# ---- 3) Create bench (if not already created) ----
if [ ! -d "${BENCH_DIR}" ]; then
  cd "/home/${BENCH_USER}"
  bench init --frappe-branch "${FRAPPE_BRANCH}" frappe-bench
fi

cd "${BENCH_DIR}"

# ---- 4) Ensure process manager for dev (optional) ----
# If you want to use "bench start", ensure honcho exists
pipx inject frappe-bench honcho || true

# ---- 5) Drop site if it exists, then create it ----
if [ -d "sites/${SITE_NAME}" ]; then
  bench drop-site "${SITE_NAME}" --force --no-backup --db-root-password "${DB_ROOT_PASS}" || true
fi

bench new-site "${SITE_NAME}" --admin-password "${ADMIN_PASSWORD}" --db-root-password "${DB_ROOT_PASS}"

# ---- 6) Get apps ----
bench get-app erpnext --branch "${ERPNEXT_BRANCH}" https://github.com/frappe/erpnext
bench get-app hrms --branch "${HRMS_BRANCH}" https://github.com/frappe/hrms

# ---- 7) Install apps on site ----
bench --site "${SITE_NAME}" install-app erpnext
bench --site "${SITE_NAME}" install-app hrms

# ---- 8) Set default site ----
bench use "${SITE_NAME}"

# ---- 9) Production prep ----
bench --site "${SITE_NAME}" enable-scheduler
bench --site "${SITE_NAME}" set-maintenance-mode off

# Production setup (run bench with sudo; ensure sudo sees bench)
BENCH_BIN="$(command -v bench)"
sudo "${BENCH_BIN}" setup production "${BENCH_USER}"

bench setup nginx
sudo nginx -t
sudo systemctl reload nginx
sudo supervisorctl restart all

echo
echo "Done."
echo "Open: http://<SERVER_IP>/"
echo "Login: Administrator"
echo "Password: ${ADMIN_PASSWORD}"
