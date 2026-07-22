#!/usr/bin/env bash
# One-time cabinet setup: lets the launcher (running as an unprivileged user)
# install keymaps into /etc/shanwan-remap without sudo.
#
#   sudo ./scripts/setup-arcade.sh [username]
#
# Defaults to the user who invoked sudo. Safe to re-run.

set -euo pipefail

KEYMAP_DIR=/etc/shanwan-remap
KEYMAP_FILE="$KEYMAP_DIR/keymap.json"
GAMES_DIR=/games
GROUP=arcade

if [[ $EUID -ne 0 ]]; then
	echo "error: run this with sudo" >&2
	exit 1
fi

ARCADE_USER="${1:-${SUDO_USER:-}}"
if [[ -z "$ARCADE_USER" ]]; then
	echo "error: could not work out which user runs the launcher." >&2
	echo "       pass it explicitly: sudo $0 <username>" >&2
	exit 1
fi
if ! id "$ARCADE_USER" >/dev/null 2>&1; then
	echo "error: no such user: $ARCADE_USER" >&2
	exit 1
fi

echo "Setting up the cabinet for user '$ARCADE_USER'."

# A dedicated group is the whole trick: root still owns the directory, but the
# launcher's user may write in it. setgid (2775) makes files created there
# inherit the group, so the atomic rename the launcher does keeps working.
groupadd -f "$GROUP"
usermod -aG "$GROUP" "$ARCADE_USER"

install -d -o root -g "$GROUP" -m 2775 "$KEYMAP_DIR"
install -d -o "$ARCADE_USER" -g "$GROUP" -m 2775 "$GAMES_DIR"

# Reassert the permissions on every boot. Bazzite is an rpm-ostree system: /etc
# and /var are writable and persist, but this keeps an image update or a manual
# poke from quietly leaving the directory read-only.
cat > /etc/tmpfiles.d/arcade-launcher.conf <<EOF
# Managed by arcade-machine-launcher setup-arcade.sh
d $KEYMAP_DIR 2775 root $GROUP -
EOF
systemd-tmpfiles --create /etc/tmpfiles.d/arcade-launcher.conf

# Seed a mapping so the cabinet is usable before the launcher first runs. This
# must match Cfg.LAUNCHER_KEYMAP in scripts/cfg.gd.
if [[ ! -e "$KEYMAP_FILE" ]]; then
	cat > "$KEYMAP_FILE" <<'EOF'
{
  "top_left": "LB",
  "top_middle": "Y",
  "top_right": "X",
  "bottom_left": "RB",
  "bottom_middle": "B",
  "bottom_right": "A",
  "white": "Start"
}
EOF
	chown root:"$GROUP" "$KEYMAP_FILE"
	chmod 664 "$KEYMAP_FILE"
	echo "Wrote a starting keymap to $KEYMAP_FILE"
else
	# Existing file must be group-writable too, or the rename lands on a file
	# the launcher cannot replace.
	chown root:"$GROUP" "$KEYMAP_FILE"
	chmod 664 "$KEYMAP_FILE"
	echo "Kept the existing $KEYMAP_FILE"
fi

echo
echo "Done."
echo "  keymap dir : $KEYMAP_DIR (group $GROUP, group-writable)"
echo "  games dir  : $GAMES_DIR"
echo
echo "Group membership only applies to new logins - log $ARCADE_USER out and"
echo "back in (or reboot) before starting the launcher."
echo
echo "Next: install the launcher and its service, see systemd/README-service.md"
