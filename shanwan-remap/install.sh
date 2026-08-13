#!/bin/bash
set -e

INSTALL_DIR="/opt/shanwan-remap"
VENV_DIR="$INSTALL_DIR/venv"
BIN_DIR="/usr/local/bin"

echo "=== shanwan-remap v2 installer ==="
echo ""

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo ./install.sh"
    exit 1
fi

if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "  Detected: $PRETTY_NAME"
fi

if ! command -v python3 &>/dev/null; then
    echo "  ERROR: python3 not found."
    exit 1
fi

# Install build deps on regular Fedora
if command -v dnf &>/dev/null; then
    echo "[0/5] Ensuring build dependencies..."
    dnf install -y python3-pip python3-devel gcc 2>/dev/null || true
fi

# Create install directory
echo "[1/5] Creating install directory..."
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/src"
cp -r . "$INSTALL_DIR/src"

# Create virtual environment
echo "[2/5] Setting up Python virtual environment..."
python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --upgrade pip 2>/dev/null || true
"$VENV_DIR/bin/pip" install "$INSTALL_DIR/src"
echo "      Installed to $INSTALL_DIR"

# Create wrapper scripts
echo "[3/5] Creating commands..."
mkdir -p "$BIN_DIR"

cat > "$BIN_DIR/shanwan-remap" << EOF
#!/bin/bash
exec "$VENV_DIR/bin/shanwan-remap" "\$@"
EOF
chmod +x "$BIN_DIR/shanwan-remap"

cat > "$BIN_DIR/shanwan-configure" << EOF
#!/bin/bash
exec "$VENV_DIR/bin/shanwan-configure" "\$@"
EOF
chmod +x "$BIN_DIR/shanwan-configure"

# Create config directory
mkdir -p /etc/shanwan-remap

# Install systemd service and udev rule
echo "[4/5] Installing systemd service and udev rule..."
cat > /etc/systemd/system/shanwan-remap.service << EOF
[Unit]
Description=Remap SHANWAN PS3/PC Gamepad for arcade cabinet
After=multi-user.target

[Service]
Type=simple
ExecStart=$VENV_DIR/bin/shanwan-remap
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

cp "$INSTALL_DIR/src/99-shanwan-remap.rules" /etc/udev/rules.d/
udevadm control --reload-rules
udevadm trigger

# Enable and activate the newly installed code. `start` is a no-op when the
# service is already running, so reinstalls must explicitly restart it.
echo "[5/5] Enabling and starting service..."
systemctl enable shanwan-remap.service
if systemctl is-active --quiet shanwan-remap.service; then
    systemctl restart shanwan-remap.service
else
    systemctl start shanwan-remap.service
fi

echo ""
echo "=== Done! ==="
echo ""
echo "Setup steps:"
echo "  1. Stop the service:  sudo systemctl stop shanwan-remap"
echo "  2. Configure cabinet: sudo shanwan-configure"
echo "  3. Start the service: sudo systemctl start shanwan-remap"
echo ""
echo "Per-game keymaps go in /etc/shanwan-remap/keymap.json"
echo "(the launcher will swap this automatically)"
echo ""
echo "Commands:"
echo "  sudo shanwan-configure                 # Map cabinet buttons"
echo "  sudo systemctl status shanwan-remap    # Check status"
echo "  sudo systemctl restart shanwan-remap   # Restart"
echo "  sudo journalctl -u shanwan-remap -f    # View logs"
echo "  sudo ./uninstall.sh                    # Uninstall"
