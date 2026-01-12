#!/bin/bash
# Uninstall script for Linux Network Load Balancer

if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root."
  exit 1
fi

SERVICE_NAME="net_balancer.service"
SCRIPT_NAME="net_autobalance.sh"
INSTALL_PATH="/usr/local/bin/$SCRIPT_NAME"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"

echo "[-] Linux Network Load Balancer - Uninstall Script"
echo ""

# Check current status
echo "[-] Checking current installation status..."
if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo "    Service is currently running"
else
    echo "    Service is not running"
fi

if [ -f "$SERVICE_PATH" ]; then
    echo "    Service file exists: $SERVICE_PATH"
else
    echo "    Service file not found"
fi

if [ -f "$INSTALL_PATH" ]; then
    echo "    Script exists: $INSTALL_PATH"
else
    echo "    Script not found"
fi

echo ""

# Check if anything is installed
if [ ! -f "$INSTALL_PATH" ] && [ ! -f "$SERVICE_PATH" ]; then
    echo "[-] No installation detected. Nothing to uninstall."
    exit 0
fi

echo "[-] Starting uninstallation..."

# 1. Stop the service
echo "    Stopping $SERVICE_NAME..."
systemctl stop "$SERVICE_NAME" 2>/dev/null || true

# 2. Disable the service
echo "    Disabling $SERVICE_NAME..."
systemctl disable "$SERVICE_NAME" 2>/dev/null || true

# 3. Reload systemd
echo "    Reloading systemd daemon..."
systemctl daemon-reload

# 4. Remove service file
if [ -f "$SERVICE_PATH" ]; then
    echo "    Removing service file: $SERVICE_PATH"
    rm -f "$SERVICE_PATH"
fi

# 5. Remove script
if [ -f "$INSTALL_PATH" ]; then
    echo "    Removing script: $INSTALL_PATH"
    rm -f "$INSTALL_PATH"
fi

# 6. Clean up routing and firewall rules
echo "    Cleaning up routing rules and tables..."

# Remove load balancing rules
ip rule del pref 90 2>/dev/null || true

# Flush load balancing table
ip route flush table 200 2>/dev/null || true

# Clean up per-interface tables (100-110)
for i in {100..110}; do
    ip route flush table $i 2>/dev/null || true
    while ip rule show | grep -q "lookup $i"; do
        ip rule del table $i 2>/dev/null || true
    done
done

# Clean up session affinity tables (201-210)
for i in {201..210}; do
    ip route flush table $i 2>/dev/null || true
    while ip rule show | grep -q "lookup $i"; do
        ip rule del table $i 2>/dev/null || true
    done
done

# Remove nftables rules
echo "    Cleaning up nftables rules..."
nft delete table ip loadbalancing 2>/dev/null || true

# Clear route cache
echo "    Flushing route cache..."
ip route flush cache

# 7. Remove metrics files
METRICS_FILE="/var/run/load_balancer_metrics.prom"
if [ -f "$METRICS_FILE" ]; then
    echo "    Removing metrics file: $METRICS_FILE"
    rm -f "$METRICS_FILE"
fi

# 8. Final status check
echo ""
echo "[-] Uninstallation complete."
echo ""
echo "[-] Final status check:"
if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo "    ⚠️  Service is still running (manual cleanup may be needed)"
else
    echo "    ✅ Service stopped"
fi

if [ -f "$SERVICE_PATH" ]; then
    echo "    ⚠️  Service file still exists: $SERVICE_PATH"
else
    echo "    ✅ Service file removed"
fi

if [ -f "$INSTALL_PATH" ]; then
    echo "    ⚠️  Script still exists: $INSTALL_PATH"
else
    echo "    ✅ Script removed"
fi

# Check for remaining rules
REMAINING_RULES=$(ip rule show | grep -E "(lookup (200|20[0-9]|1[0-9][0-9]))|pref 90" | wc -l)
if [ "$REMAINING_RULES" -gt 0 ]; then
    echo "    ⚠️  Some routing rules may remain (manual cleanup may be needed)"
else
    echo "    ✅ Routing rules cleaned up"
fi

# Check for remaining nftables
if nft list tables 2>/dev/null | grep -q "loadbalancing"; then
    echo "    ⚠️  Some nftables rules may remain (manual cleanup may be needed)"
else
    echo "    ✅ Nftables rules cleaned up"
fi

echo ""
echo "[-] Uninstallation finished successfully!"
echo "    Your system should now be restored to its pre-installation state."