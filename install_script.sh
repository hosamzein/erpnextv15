#!/usr/bin/env bash
set -euo pipefail

SITE_NAME="erpsite"
FRAPPE_USER="frappe"
BENCH_FOLDER="frappe-bench"
BENCH_PATH="/home/${FRAPPE_USER}/${BENCH_FOLDER}"

echo "== 0) Must run as root (sudo) =="
if [ "$(id -u)" -ne 0 ]; then
  echo "Run: sudo bash $0"
  exit 1
fi

echo "== 1) Update OS and cleanup =="
apt-get update -y
apt-get upgrade -y
apt-get autoremove -y

echo "== 2) Create frappe user (sudo) if missing =="
if ! id -u "${FRAPPE_USER}" >/dev/null 2>&1; then
  adduser "${FRAPPE_USER}"
fi
usermod -aG sudo "${FRAPPE_USER}"

echo "== 3) Install prerequisites (system) =="
apt-get install -y \
  git software-properties-common \
  python3-dev python3-setuptools python3-pip python3-venv \
  mariadb-server mariadb-client \
  redis-server \
  nginx supervisor \
  curl \
  xvfb libfontconfig wkhtmltopdf \
  npm

echo "== 4) Yarn (global) =="
npm install -g yarn

echo "== 5) Enable core services =="
systemctl enable --now mariadb redis-server nginx supervisor

echo "== 6) MariaDB secure installation (interactive) =="
echo "NOTE: This step is interactive."
mysql_secure_installation

echo "== 7) MariaDB utf8mb4 config =="
cat >/etc/mysql/mariadb.conf.d/99-erpnext-utf8mb4.cnf <<'EOF'
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4
EOF
systemctl restart mariadb

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

echo "== 9) Ensure bench will be in frappe PATH (~/.local/bin) =="
sudo -H -u "${FRAPPE_USER}" bash -lc '
  set -e
  # Ensure ~/.local/bin is on PATH (common location for pip --user scripts). [web:161]
  if ! grep -q "HOME/.local/bin" ~/.bashrc 2>/dev/null; then
    echo "export PATH=\"$HOME/.local/bin:\$PATH\"" >> ~/.bashrc
  fi
  source ~/.bashrc || true
'

echo "== 10) Install frappe-bench as frappe user (NOT root) =="
# Install as user so bench executable lives under /home/frappe/.local/bin (and is on PATH). [web:161]
sudo -H -u "${FRAPPE_USER}" bash -lc '
  set -e
  python3 -m pip install --user --break-system-packages frappe-bench
  source ~/.bashrc || true
  which bench
  bench --version
'

echo "== 11) bench init v15 =="
sudo -H -u "${FRAPPE_USER}" bash -lc "
  set -e
  source ~/.bashrc || true
  cd ~
  if [ -d ~/${BENCH_FOLDER} ]; then
    echo 'Bench already exists, skipping init.'
  else
    bench init --frappe-branch version-15 ${BENCH_FOLDER}
  fi
"

echo "== 12) Create site + install ERPNext + HRMS =="
sudo -H -u "${FRAPPE_USER}" bash -lc "
  set -e
  source ~/.bashrc || true
  cd ~/${BENCH_FOLDER}

  # Optional (your step): allow traverse permissions
  sudo chmod -R o+rx /home/${FRAPPE_USER}

  if bench list-sites 2>/dev/null | grep -qx '${SITE_NAME}'; then
    bench drop-site '${SITE_NAME}' --force
  fi

  bench new-site '${SITE_NAME}'

  bench get-app erpnext --branch version-15 https://github.com/frappe/erpnext
  bench get-app hrms --branch version-15

  bench --site '${SITE_NAME}' install-app erpnext
  bench --site '${SITE_NAME}' install-app hrms

  bench use '${SITE_NAME}'
  bench --site '${SITE_NAME}' enable-scheduler
  bench --site '${SITE_NAME}' set-maintenance-mode off
"

echo "== 13) Production setup (Supervisor + NGINX) =="
# 'bench setup production' is the documented production approach. [web:55]
sudo -H -u "${FRAPPE_USER}" bash -lc "
  set -e
  source ~/.bashrc || true
  cd ~/${BENCH_FOLDER}
  sudo bench setup production ${FRAPPE_USER}
  bench setup nginx
"

echo "== 14) Reload NGINX + restart Supervisor =="
nginx -t
systemctl reload nginx
supervisorctl restart all

echo "== DONE =="
echo "Open: http://<server-ip>/"
echo "Login: Administrator"
echo "Password: ${SITE_NAME}"
