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
GROUP=arcade
# Games live under the arcade user's home (synced there via Nextcloud). Bazzite
# has a read-only ostree root, so a top-level /games cannot be created; a home
# path can. Resolved once we know the user, below. Must match Cfg's default in
# scripts/cfg.gd.
GAMES_SUBDIR="Nextcloud/Games"

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

ARCADE_HOME="$(getent passwd "$ARCADE_USER" | cut -d: -f6)"
if [[ -z "$ARCADE_HOME" ]]; then
	echo "error: could not find a home directory for $ARCADE_USER" >&2
	exit 1
fi
GAMES_DIR="$ARCADE_HOME/$GAMES_SUBDIR"

echo "Setting up the cabinet for user '$ARCADE_USER'."

# A dedicated group is the whole trick: root still owns the directory, but the
# launcher's user may write in it. setgid (2775) makes files created there
# inherit the group, so the atomic rename the launcher does keeps working.
groupadd -f "$GROUP"
usermod -aG "$GROUP" "$ARCADE_USER"

install -d -o root -g "$GROUP" -m 2775 "$KEYMAP_DIR"

# Create the games dir AS the arcade user, so any parent it makes (~/Nextcloud
# if the Nextcloud client has not set it up yet) is owned by the user rather
# than root, which would otherwise lock the client out of its own folder.
sudo -u "$ARCADE_USER" mkdir -p "$GAMES_DIR"
chgrp "$GROUP" "$GAMES_DIR"
chmod 2775 "$GAMES_DIR"

# Reassert the permissions on every boot. Bazzite is an rpm-ostree system: /etc
# and /var are writable and persist, but this keeps an image update or a manual
# poke from quietly leaving the directory read-only.
cat > /etc/tmpfiles.d/arcade-launcher.conf <<EOF
# Managed by arcade-machine-launcher setup-arcade.sh
d $KEYMAP_DIR 2775 root $GROUP -
EOF
systemd-tmpfiles --create /etc/tmpfiles.d/arcade-launcher.conf

# Seed a mapping so the cabinet is usable before the launcher first runs. This
# must match Cfg.LAUNCHER_KEYMAP in scripts/cfg.gd. `white` is deliberately
# absent - it is the system button now, read only via shanwan-remap's control
# channel, and never forwarded to a game by the remapper regardless of what
# any keymap says (see shanwan-remap/README.md, "Control channel").
if [[ ! -e "$KEYMAP_FILE" ]]; then
	cat > "$KEYMAP_FILE" <<'EOF'
{
  "top_left": "LB",
  "top_middle": "Y",
  "top_right": "X",
  "bottom_left": "RB",
  "bottom_middle": "B",
  "bottom_right": "A"
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

# --- KWin settings ------------------------------------------------------------
#
# Two things below - the compositor's own cursor, and window activation - are
# KWin policy rather than anything the launcher can decide for itself, so both
# are written into the arcade user's kwinrc. Collected behind one helper and
# one live reload at the end, so neither section has to repeat the availability
# check or the DBus dance.
if command -v kwriteconfig6 >/dev/null 2>&1; then
	HAVE_KWIN_CONFIG=1
else
	HAVE_KWIN_CONFIG=0
	echo
	echo "warning: kwriteconfig6 not found - skipping both KWin settings." >&2
	echo "         Without them KDE's own cursor flashes on screen every time" >&2
	echo "         a game's window opens, and the system overlay will not" >&2
	echo "         appear over a running game (the launcher's window only" >&2
	echo "         glows in the task manager). Set them by hand in System" >&2
	echo "         Settings > Window Management > Desktop Effects > Hide" >&2
	echo "         Cursor, and > Window Behavior > Focus > Focus stealing" >&2
	echo "         prevention: None." >&2
fi

kwin_write() {
	[[ "$HAVE_KWIN_CONFIG" == 1 ]] || return 0
	sudo -u "$ARCADE_USER" kwriteconfig6 --file kwinrc --group "$1" --key "$2" "$3"
}

# --- cursor hiding ------------------------------------------------------------
#
# The cabinet has no mouse during arcade play, but a mouse may well get
# plugged back in for maintenance (a file manager, a terminal, ...), so this
# must hide the cursor for the launcher and games ONLY - not for the whole
# desktop session. A session-wide cursor theme (KWin's own default, or GTK's)
# would blind every other application too; earlier versions of this script
# did exactly that and it was wrong. Instead, only the launcher's own
# process - and every game, which inherits its environment through the shell
# wrapper - gets XCURSOR_THEME=arcade-blank set (see systemd/arcade-launcher.service;
# every game inherits it automatically, since OS.create_process does not
# clear the environment before exec). A file manager launched from the
# normal desktop session never sees that variable and keeps the system's
# normal cursor.
#
# Installed per-user rather than system-wide: /usr is read-only on Bazzite's
# ostree root, but ~/.local/share/icons is exactly where Xcursor already looks
# first, and it is the arcade user's own home, so no permission dance is
# needed beyond running as that user - same reasoning as the games dir above.
CURSOR_THEME=arcade-blank
CURSOR_THEME_DIR="$ARCADE_HOME/.local/share/icons/$CURSOR_THEME"
CURSOR_FILE="$CURSOR_THEME_DIR/cursors/blank"

# Every name a Wayland/X11 client might ask for. Games and toolkits are not
# consistent about which one they use, so all of them point at the same
# single transparent image.
CURSOR_NAMES=(
	default left_ptr arrow x-cursor pointer hand2 hand1 crosshair
	text xterm ibeam wait watch progress
	move fleur size_all size_hor size_ver size_bdiag size_fdiag
	sb_h_double_arrow sb_v_double_arrow
	col-resize row-resize
	e-resize w-resize n-resize s-resize
	ne-resize nw-resize se-resize sw-resize
	not-allowed no-drop copy alias grab grabbing
	all-scroll zoom-in zoom-out help question_arrow
)

echo
echo "Installing a transparent cursor theme for user '$ARCADE_USER'..."

sudo -u "$ARCADE_USER" mkdir -p "$CURSOR_THEME_DIR/cursors"

# A single 1x1 fully-transparent (alpha=0) Xcursor image, written directly in
# the on-disk Xcursor binary format (little-endian uint32 fields: a file
# header, one table-of-contents entry, one image chunk, one ARGB32 pixel).
# Generated here rather than committed as a binary asset, so nothing depends
# on xcursorgen being installed and there is no risk of a binary file getting
# mangled by this repo's `* text=auto` .gitattributes rule on the way to disk.
sudo -u "$ARCADE_USER" python3 - "$CURSOR_FILE" <<'PYEOF'
import struct
import sys

path = sys.argv[1]
CURSOR_IMAGE_TYPE = 0xfffd0002
toc_position = 16 + 12  # file header, then this file's one TOC entry

data = b"Xcur"
data += struct.pack("<III", 16, 0x00010000, 1)  # header size, version, ntoc
data += struct.pack("<III", CURSOR_IMAGE_TYPE, 1, toc_position)  # toc: type, nominal size, position
data += struct.pack("<IIII", 36, CURSOR_IMAGE_TYPE, 1, 1)  # chunk header size, type, subtype, version
data += struct.pack("<IIIII", 1, 1, 0, 0, 0)  # width, height, xhot, yhot, delay
data += struct.pack("<I", 0x00000000)  # one fully transparent ARGB32 pixel

with open(path, "wb") as f:
	f.write(data)
PYEOF

for name in "${CURSOR_NAMES[@]}"; do
	sudo -u "$ARCADE_USER" ln -sf blank "$CURSOR_THEME_DIR/cursors/$name"
done

sudo -u "$ARCADE_USER" tee "$CURSOR_THEME_DIR/index.theme" > /dev/null <<EOF
[Icon Theme]
Name=Arcade Blank
Comment=Fully transparent cursor for the MakeGamesJLM arcade cabinet
Inherits=
EOF

# Undo a session-wide cursor theme set by an earlier version of this script.
# Deliberately narrow: only removes settings that hold exactly our theme
# name, so it cannot clobber a value that was customized for some other
# reason before or after this script last ran.
if command -v kwriteconfig6 >/dev/null 2>&1; then
	current_theme="$(sudo -u "$ARCADE_USER" kreadconfig6 --file kcminputrc --group Mouse --key cursorTheme 2>/dev/null || true)"
	if [[ "$current_theme" == "$CURSOR_THEME" ]]; then
		sudo -u "$ARCADE_USER" kwriteconfig6 --file kcminputrc --group Mouse --key cursorTheme --delete
		echo "Removed the session-wide cursor theme this script set previously - restart the session (log out/in) to see the cursor again on the desktop."
	fi
fi
for gtk_dir in gtk-3.0 gtk-4.0; do
	settings_file="$ARCADE_HOME/.config/$gtk_dir/settings.ini"
	if [[ -f "$settings_file" ]]; then
		sudo -u "$ARCADE_USER" sed -i "/^gtk-cursor-theme-name=$CURSOR_THEME\$/d" "$settings_file"
	fi
done

# The transparent theme above only covers a cursor a *client* draws. It cannot
# touch the one KWin draws itself, and on Wayland the compositor owns the
# pointer until a surface claims it: from the moment a game's window is mapped
# until that game gets far enough into its own startup to set a cursor for it,
# KWin renders its default arrow. That gap is the cursor that flashes on screen
# on every launch, and no client-side setting can reach it - not the theme, not
# Godot's own MOUSE_MODE_HIDDEN, which only ever applied to the launcher's own
# window anyway.
#
# KWin's built-in "Hide Cursor" effect (Plasma 6.2+) is the one thing that can:
# it stops the compositor rendering a pointer at all after CURSOR_HIDE_SECONDS
# with no real pointer input, which on a cabinet with no mouse means "a few
# seconds after login, and then forever". Being compositor-level, it covers the
# mapping gap that nothing else could.
#
# Unlike the session-wide cursor theme this script used to set, this does not
# blind maintenance: the cursor comes straight back the instant a plugged-in
# mouse actually moves, and only fades again after the same few seconds of it
# sitting still. That is the whole reason the timeout is seconds rather than
# near-zero - long enough to work with a mouse comfortably, short enough that
# the cabinet is clean well before anyone walks up to it.
#
# HideOnTyping is set for completeness rather than effect: keyboard input in
# that effect only ever *hides* the cursor, never shows it, so cabinet buttons
# can never undo this - but most of them map to arrows and Enter, which the
# effect classes as functional keys and deliberately ignores. The inactivity
# timeout is what actually does the work here.
CURSOR_HIDE_SECONDS=5

echo "Hiding KWin's own cursor after ${CURSOR_HIDE_SECONDS}s without mouse input..."
kwin_write Plugins hidecursorEnabled true
kwin_write Effect-hidecursor InactivityDuration "$CURSOR_HIDE_SECONDS"
kwin_write Effect-hidecursor HideOnTyping true

# --- window activation --------------------------------------------------------
#
# The system overlay has to come up over a running game, so the launcher calls
# window_move_to_foreground() after freezing it. KWin refuses that by default:
# focus-stealing prevention does not let an application activate itself, and
# instead downgrades the request to a "demands attention" hint - the window
# stays exactly where it was and its task manager entry just glows orange.
# That was the "white button freezes the game but the overlay never appears"
# bug, and no amount of application-side code can override it, because the
# decision is the compositor's and not the client's.
#
# Turned off wholesale rather than through a per-window rule. This is a
# single-purpose kiosk: the launcher IS the shell, there is no other
# application whose focus needs protecting from it, and a global setting has
# no window-matching to get wrong (the launcher's Wayland app_id is not
# something this script should have to predict). Level 0 is "None" - see
# System Settings > Window Management > Window Behavior > Focus. KDE's own
# default is 1 ("Low"), which is what to restore if this ever needs undoing.
FSP_LEVEL=0

echo "Allowing the launcher to raise its own window (KWin focus stealing prevention)..."
kwin_write Windows FocusStealingPreventionLevel "$FSP_LEVEL"

# Best-effort live reload, covering every kwinrc change above. Usually fails
# from here, because reaching the user's session bus needs
# DBUS_SESSION_BUS_ADDRESS and this script runs as root; the log out / reboot
# below covers that case, so a failure is not worth stopping for.
if [[ "$HAVE_KWIN_CONFIG" == 1 ]]; then
	if sudo -u "$ARCADE_USER" dbus-send --session --type=method_call \
		--dest=org.kde.KWin /KWin org.kde.KWin.reconfigure >/dev/null 2>&1; then
		echo "  KWin settings applied to the running session."
	else
		echo "  KWin settings will apply when $ARCADE_USER next logs in."
	fi
fi

echo
echo "Done."
echo "  keymap dir   : $KEYMAP_DIR (group $GROUP, group-writable)"
echo "  games dir    : $GAMES_DIR"
echo "  cursor theme : $CURSOR_THEME_DIR"
echo "  cursor hide  : KWin hides its own after ${CURSOR_HIDE_SECONDS}s idle"
echo "  kwin focus   : stealing prevention = $FSP_LEVEL (none)"
echo
echo "Group membership only applies to new logins - log $ARCADE_USER out and"
echo "back in (or reboot) before starting the launcher."
echo
echo "Next: install the launcher and its service, see systemd/README-service.md"
