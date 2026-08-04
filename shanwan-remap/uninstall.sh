#!/bin/bash
set -e

INSTALL_DIR="/opt/shanwan-remap"
BIN_DIR="/usr/local/bin"

echo "=== shanwan-remap uninstaller ==="
echo ""

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo ./uninstall.sh"
    exit 1
fi

echo "[1/4] Stopping service..."
systemctl stop shanwan-remap.service 2>/dev/null || true
systemctl disable shanwan-remap.service 2>/dev/null || true

echo "[2/4] Removing systemd service..."
rm -f /etc/systemd/system/shanwan-remap.service
systemctl daemon-reload

echo "[3/4] Removing udev rule..."
rm -f /etc/udev/rules.d/99-shanwan-remap.rules
udevadm control --reload-rules

echo "[4/4] Removing files..."
rm -f "$BIN_DIR/shanwan-remap"
rm -f "$BIN_DIR/shanwan-configure"
rm -rf "$INSTALL_DIR"
rm -rf /etc/shanwan-remap

echo ""
echo "=== Uninstalled! ==="
