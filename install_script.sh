#!/bin/bash

# ERPNext v15 Installation Script for Ubuntu 22.04
# Usage: sudo bash install_erpnext_v15.sh

set -e  # Exit on error

FRAPPE_USER="frappe"
SITE_NAME="erpsite"
BENCH_DIR="frappe-bench"

echo "=== ERPNext v15 Installation Started ==="

# Install Frappe Bench
echo "Installing Frappe Bench..."
sudo pip3 install --break-system-packages frappe-bench

# Initialize Frappe Bench with v15
echo "Initializing Frappe Bench v15..."
bench init --frappe-branch version-15 $BENCH_DIR

# Navigate to bench directory
cd ~/$BENCH_DIR

# Add node-sass package (if needed)
yarn add node-sass

# Grant permissions
echo "Setting permissions..."
sudo chmod -R o+rx /home/$FRAPPE_USER

# Create new site or drop existing
echo "Creating site: $SITE_NAME..."
if bench list-sites | grep -q "$SITE_NAME"; then
    echo "Site exists, dropping it..."
    bench drop-site $SITE_NAME --force
fi
bench new-site $SITE_NAME

# Download and install ERPNext
echo "Getting ERPNext app..."
bench get-app erpnext --branch version-15 https://github.com/frappe/erpnext

# Download and install HRMS
echo "Getting HRMS app..."
bench get-app hrms --branch version-15

# Install apps on site
echo "Installing ERPNext on site..."
bench --site $SITE_NAME install-app erpnext

echo "Installing HRMS on site..."
bench --site $SITE_NAME install-app hrms

# Set default site
bench use $SITE_NAME

# Enable scheduler
bench --site $SITE_NAME enable-scheduler

# Disable maintenance mode
bench --site $SITE_NAME set-maintenance-mode off

# Setup production
echo "Setting up production environment..."
sudo bench setup production $FRAPPE_USER --yes

# Setup NGINX
bench setup nginx
sudo nginx -t
sudo systemctl reload nginx

# Restart supervisor
sudo supervisorctl restart all

echo "=== Installation Complete ==="
echo "Access ERPNext at: http://$(hostname -I | awk '{print $1}')"
echo "Username: Administrator"
echo "Password: $SITE_NAME"
