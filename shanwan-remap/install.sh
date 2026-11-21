#!/bin/bash
set -e

INSTALL_DIR="/opt/shanwan-remap"
VENV_DIR="$INSTALL_DIR/venv"
# Private interpreter the venv is built on - see step 2 for why.
PYTHON_DIR="$INSTALL_DIR/python"
PYTHON_VERSION="3.14"
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

# Install build deps on regular Fedora. Bazzite and other Fedora Atomic hosts
# expose a dnf compatibility/helper command even though packages are managed by
# rpm-ostree. Invoking that helper can open a documentation page and block this
# installer until the browser closes. The cabinet image already includes the
# Python tooling needed below, so do not invoke dnf on an immutable host.
if command -v rpm-ostree &>/dev/null; then
    echo "[0/5] Immutable rpm-ostree host detected; skipping dnf dependencies."
elif command -v dnf &>/dev/null; then
    echo "[0/5] Ensuring build dependencies..."
    dnf install -y python3-pip python3-devel gcc 2>/dev/null || true
fi

# Create install directory
echo "[1/5] Creating install directory..."
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/src"
cp -r . "$INSTALL_DIR/src"

# Create virtual environment on a pinned, private Python.
#
# The venv must NOT be built on the system python3. A venv is not
# self-contained: it points at the interpreter and standard library it was
# made with, and on Bazzite those come with the OS image. An automatic image
# update that bumps the Python minor version (3.14 -> 3.15 in Nov 2026) leaves
# the venv's packages under the old version's site-packages, and the service
# dies on `ModuleNotFoundError: No module named 'shanwan_remap'` - taking the
# white button with it. `python3 -m venv --copies` does not help, because the
# standard library still lives in the image.
#
# Instead, uv downloads a standalone CPython into $PYTHON_DIR, which OS updates
# never touch.
#
# Re-running this installer downloads nothing unless something is missing or
# out of date:
#   - Python is fetched only when there is none yet, or when PYTHON_VERSION
#     has been changed. Only then is uv bootstrapped, in a throwaway venv made
#     with the system python3.
#   - The venv is rebuilt only when it is missing or not on the pinned Python
#     (e.g. one left over from an install that used the system python3).
#   - The package is then reinstalled from the local source. Dependencies that
#     are already installed are not fetched again, and the build uses the
#     venv's own setuptools (--no-build-isolation), so nothing is downloaded
#     for the build either.
echo "[2/5] Setting up pinned Python $PYTHON_VERSION and virtual environment..."
PYTHON_MARKER="$PYTHON_DIR/pinned-python"
PINNED_PYTHON=""
if [ -f "$PYTHON_MARKER" ]; then
    PINNED_PYTHON="$(cat "$PYTHON_MARKER")"
fi
if [ -n "$PINNED_PYTHON" ] && "$PINNED_PYTHON" -c \
        "import sys; sys.exit('%d.%d' % sys.version_info[:2] != '$PYTHON_VERSION')" 2>/dev/null; then
    echo "      Python $PYTHON_VERSION already installed; not downloading."
else
    echo "      Downloading Python $PYTHON_VERSION..."
    UV_BOOTSTRAP="$(mktemp -d)"
    trap 'rm -rf "$UV_BOOTSTRAP"' EXIT
    python3 -m venv "$UV_BOOTSTRAP"
    "$UV_BOOTSTRAP/bin/pip" install --quiet --disable-pip-version-check uv
    UV="$UV_BOOTSTRAP/bin/uv"
    export UV_PYTHON_INSTALL_DIR="$PYTHON_DIR"
    "$UV" python install --no-bin "$PYTHON_VERSION"
    PINNED_PYTHON="$("$UV" python find --managed-python "$PYTHON_VERSION")"
    echo "$PINNED_PYTHON" > "$PYTHON_MARKER"
fi
echo "      Using $PINNED_PYTHON"

if [ "$(readlink -f "$VENV_DIR/bin/python" 2>/dev/null)" = "$(readlink -f "$PINNED_PYTHON")" ]; then
    echo "      Reusing existing virtual environment."
else
    echo "      Creating virtual environment..."
    rm -rf "$VENV_DIR"
    "$PINNED_PYTHON" -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install --disable-pip-version-check setuptools
fi
"$VENV_DIR/bin/pip" install --disable-pip-version-check --no-build-isolation "$INSTALL_DIR/src"
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
