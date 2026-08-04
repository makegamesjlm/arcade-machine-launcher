#!/usr/bin/env bash
# First-time cabinet install: takes a fresh clone of this repo to a running
# launcher. Run it ON THE CABINET, as the user that owns the graphical session
# (NOT with sudo - it escalates the individual steps that need root itself):
#
#   ./scripts/install-cabinet.sh
#
# What it does, in order:
#   1. cabinet permissions and directories   (scripts/setup-arcade.sh, root)
#   2. the SHANWAN controller remap service   (shanwan-remap/install.sh, root)
#   3. build the launcher binary              (godot export, this user)
#   4. install the binary and its user service and enable it
#
# Safe to re-run. Skip stages you have already done with the flags below.
#
# Flags:
#   --skip-setup     don't run scripts/setup-arcade.sh
#   --skip-remap     don't (re)install the shanwan-remap service
#   --skip-build     reuse an existing build/arcade-launcher instead of exporting
#
# The Godot editor plus the Linux export templates for the matching version must
# be installed for the build stage. Point at a specific binary with GODOT=...
# (e.g. GODOT=godot4, or an absolute path to a Godot AppImage).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPT_DIR=/opt/arcade-launcher
BUILD_OUT="$REPO_ROOT/build/arcade-launcher"
UNIT=arcade-launcher.service
USER_UNIT_DIR="$HOME/.config/systemd/user"

SKIP_SETUP=0
SKIP_REMAP=0
SKIP_BUILD=0
for arg in "$@"; do
	case "$arg" in
		--skip-setup) SKIP_SETUP=1 ;;
		--skip-remap) SKIP_REMAP=1 ;;
		--skip-build) SKIP_BUILD=1 ;;
		-h|--help) sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
		*) echo "error: unknown argument '$arg' (try --help)" >&2; exit 1 ;;
	esac
done

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
note() { printf '    %s\n' "$1"; }

if [[ $EUID -eq 0 ]]; then
	echo "error: run this as your normal user, not with sudo." >&2
	echo "       the launcher is a systemd --user service and the build uses your" >&2
	echo "       Godot templates; both break when this whole script runs as root." >&2
	echo "       It will ask for sudo on the steps that actually need it." >&2
	exit 1
fi

# Prime the sudo timestamp once so the root stages below don't each stop to ask.
step "Checking privileges"
if ! sudo -v; then
	echo "error: this script needs sudo access for the system stages." >&2
	exit 1
fi
note "ok"

# --- 1. cabinet permissions and directories ----------------------------------

if [[ $SKIP_SETUP -eq 0 ]]; then
	step "Cabinet permissions and directories (setup-arcade.sh)"
	# Called through bash so it runs even if the clone did not preserve the
	# executable bit (this repo tracks these scripts as non-executable).
	sudo bash "$REPO_ROOT/scripts/setup-arcade.sh"
else
	step "Cabinet permissions and directories - skipped (--skip-setup)"
fi

# --- 2. controller remap service ---------------------------------------------

if [[ $SKIP_REMAP -eq 0 ]]; then
	step "SHANWAN remap service (shanwan-remap/install.sh)"
	if command -v shanwan-remap >/dev/null 2>&1; then
		read -r -p "    shanwan-remap is already installed. Reinstall it? [y/N] " reply || true
		if [[ "${reply:-}" =~ ^[Yy] ]]; then
			( cd "$REPO_ROOT/shanwan-remap" && sudo bash ./install.sh )
		else
			note "kept the existing install."
		fi
	else
		( cd "$REPO_ROOT/shanwan-remap" && sudo bash ./install.sh )
	fi

	# Mapping physical buttons to evdev codes needs a human pressing them, so it
	# cannot be automated. Offer to run it now while a terminal is attached.
	if [[ ! -f /etc/shanwan-remap/cabinet.json ]]; then
		echo
		note "The cabinet's buttons have not been mapped yet (no cabinet.json)."
		read -r -p "    Run 'shanwan-configure' now to map them? [Y/n] " reply || true
		if [[ ! "${reply:-}" =~ ^[Nn] ]]; then
			sudo systemctl stop shanwan-remap
			sudo shanwan-configure
			sudo systemctl start shanwan-remap
		else
			note "Skipped. Run it later: sudo systemctl stop shanwan-remap &&"
			note "  sudo shanwan-configure && sudo systemctl start shanwan-remap"
		fi
	fi
else
	step "SHANWAN remap service - skipped (--skip-remap)"
fi

# --- 3. build the launcher ---------------------------------------------------

if [[ $SKIP_BUILD -eq 0 ]]; then
	step "Building the launcher (Godot export)"
	GODOT="${GODOT:-}"
	if [[ -z "$GODOT" ]]; then
		if command -v godot >/dev/null 2>&1; then GODOT=godot
		elif command -v godot4 >/dev/null 2>&1; then GODOT=godot4
		fi
	fi
	if [[ -z "$GODOT" ]] || ! command -v "$GODOT" >/dev/null 2>&1; then
		echo "error: no Godot binary found." >&2
		echo "       install the Godot editor, or set GODOT to its path:" >&2
		echo "       GODOT=/path/to/godot $0 --skip-setup --skip-remap" >&2
		exit 1
	fi
	note "using: $GODOT"

	mkdir -p "$REPO_ROOT/build"
	# The export fails clearly on its own if the Linux export templates for this
	# Godot version are missing - that is the usual first-run stumble.
	"$GODOT" --headless --path "$REPO_ROOT" --export-release "Linux" "$BUILD_OUT"

	if [[ ! -s "$BUILD_OUT" ]]; then
		echo "error: the export did not produce $BUILD_OUT." >&2
		echo "       most often the Linux export templates are not installed for" >&2
		echo "       this Godot version (Editor > Manage Export Templates)." >&2
		exit 1
	fi
	note "built $BUILD_OUT"
else
	step "Building the launcher - skipped (--skip-build)"
	if [[ ! -s "$BUILD_OUT" ]]; then
		echo "error: --skip-build was given but $BUILD_OUT does not exist." >&2
		exit 1
	fi
fi

# --- 4. install the binary and the user service ------------------------------

step "Installing the binary to $OPT_DIR"
sudo install -d -m 0755 "$OPT_DIR"
sudo install -m 0755 "$BUILD_OUT" "$OPT_DIR/arcade-launcher"
# An embedded-pck export (this repo's preset) is a single file; copy a sidecar
# .pck too if a non-embedded build ever produces one.
if [[ -f "$BUILD_OUT.pck" ]]; then
	sudo install -m 0644 "$BUILD_OUT.pck" "$OPT_DIR/"
fi
note "installed $OPT_DIR/arcade-launcher"

step "Installing the launcher service"
mkdir -p "$USER_UNIT_DIR"
install -m 0644 "$REPO_ROOT/systemd/$UNIT" "$USER_UNIT_DIR/"
systemctl --user daemon-reload
# Enable, but don't --now: the unit is PartOf graphical-session.target, and the
# arcade group added in stage 1 only applies to a fresh login. A reboot starts
# it cleanly with the right group and display.
systemctl --user enable "$UNIT"
note "enabled $UNIT (starts with the graphical session)"

# --- 5. audio tooling for the volume buttons ---------------------------------

# The launcher's volume/mute buttons drive the system mixer through wpctl
# (PipeWire, standard on Bazzite), falling back to pactl. With neither present
# the buttons still show the on-screen bar but change nothing, so warn rather
# than fail - everything else on the cabinet still works.
step "Audio tooling for the volume buttons"
if command -v wpctl >/dev/null 2>&1; then
	note "found wpctl - volume buttons will control the system volume."
elif command -v pactl >/dev/null 2>&1; then
	note "found pactl - volume buttons will control the system volume (via pactl)."
else
	printf '    \033[1;33mwarning:\033[0m neither wpctl nor pactl was found.\n'
	note "The volume/mute buttons will show the on-screen bar but not change the"
	note "actual volume. On Bazzite install PipeWire's utils, e.g.:"
	note "  rpm-ostree install wireplumber   # provides wpctl (then reboot)"
fi

# --- done --------------------------------------------------------------------

step "Done"
note "Reboot to finish: the 'arcade' group membership and the launcher service"
note "both take effect on the next login."
echo
read -r -p "    Reboot now? [y/N] " reply || true
if [[ "${reply:-}" =~ ^[Yy] ]]; then
	sudo reboot
else
	note "Reboot later with: sudo reboot"
	note "Check the service:  systemctl --user status $UNIT"
fi
