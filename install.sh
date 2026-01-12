#!/bin/bash
# Install/Update script for Linux Network Load Balancer

if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root."
  exit 1
fi

SERVICE_NAME="net_balancer.service"
SCRIPT_NAME="net_autobalance.sh"
INSTALL_PATH="/usr/local/bin/$SCRIPT_NAME"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"

# Detect if installed
if [ -f "$INSTALL_PATH" ] || [ -f "$SERVICE_PATH" ]; then
    MODE="Update"
    echo "[-] Detected existing installation. Updating..."
else
    MODE="Install"
    echo "[-] Performing fresh installation..."
fi

# 1. Install/Update Script
echo "    Copying $SCRIPT_NAME to /usr/local/bin/..."
cp "$SCRIPT_NAME" "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"

# 2. Install/Update Service
echo "    Copying $SERVICE_NAME to /etc/systemd/system/..."
cp "$SERVICE_NAME" "$SERVICE_PATH"

# 3. Reload systemd
echo "    Reloading systemd daemon..."
systemctl daemon-reload

# 4. Enable (only needed for install, but safe to run on update usually, 
#    though we can skip it to respect if user disabled it manually but wants to update binary)
if [ "$MODE" == "Install" ]; then
    echo "    Enabling $SERVICE_NAME..."
    systemctl enable "$SERVICE_NAME"
fi

# 5. Restart to apply changes
echo "    Restarting $SERVICE_NAME..."
systemctl restart "$SERVICE_NAME"

echo "[-] $MODE complete."
systemctl status "$SERVICE_NAME" --no-pager