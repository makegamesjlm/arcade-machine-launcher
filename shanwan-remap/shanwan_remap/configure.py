#!/usr/bin/env python3
"""
Interactive cabinet configurator for shanwan-remap.
Walks through each button position and detects the evdev code.
Saves to /etc/shanwan-remap/cabinet.json.
"""
import json
import os
import sys
import select
import time
from pathlib import Path
from evdev import InputDevice, ecodes

CONFIG_DIR = Path("/etc/shanwan-remap")
CABINET_FILE = CONFIG_DIR / "cabinet.json"

# Button positions to configure, in order
POSITIONS = [
    ("top_left",      "Top-Left button"),
    ("top_middle",    "Top-Middle button"),
    ("top_right",     "Top-Right button"),
    ("bottom_left",   "Bottom-Left button"),
    ("bottom_middle", "Bottom-Middle button"),
    ("bottom_right",  "Bottom-Right button"),
    ("white",         "White / Start button"),
]

# Reverse lookup: code -> name
EVDEV_BTN_NAMES = {}
for name in dir(ecodes):
    if name.startswith("BTN_"):
        code = getattr(ecodes, name)
        if isinstance(code, int) and code not in EVDEV_BTN_NAMES:
            EVDEV_BTN_NAMES[code] = name


def find_shanwan_devices():
    """Find all SHANWAN PS3/PC Gamepad event devices."""
    import glob
    devices = []
    for path in sorted(glob.glob("/dev/input/event*")):
        try:
            dev = InputDevice(path)
            if "SHANWAN" in dev.name and "PS3" in dev.name:
                devices.append((path, dev.name))
                dev.close()
            else:
                dev.close()
        except (PermissionError, OSError):
            continue
    return devices


def drain_events(dev):
    """Drain any pending events."""
    while select.select([dev.fd], [], [], 0)[0]:
        for _ in dev.read():
            pass


def wait_release(dev):
    """Wait until all buttons are released."""
    time.sleep(0.2)
    drain_events(dev)


def get_button_display_name(code):
    return EVDEV_BTN_NAMES.get(code, f"CODE_{code}")


def print_header():
    print()
    print("=" * 56)
    print("  shanwan-remap — Cabinet Configurator")
    print("=" * 56)
    print()


def print_cabinet_table(cabinet):
    """Print the current cabinet mapping."""
    print()
    print("  ┌─────────────────────────┬─────────────────────────┐")
    print("  │ Position                │ Button Code             │")
    print("  ├─────────────────────────┼─────────────────────────┤")
    for pos_id, pos_label in POSITIONS:
        code = cabinet.get(pos_id)
        code_str = f"{get_button_display_name(code)} ({code})" if code is not None else "—"
        print(f"  │ {pos_label:<23} │ {code_str:<23} │")
    print("  └─────────────────────────┴─────────────────────────┘")
    print()


def configure(dev_path):
    """Run interactive configuration for a device."""
    dev = InputDevice(dev_path)
    print(f"  Using: {dev.name} ({dev_path})")
    print()
    print("  For each position, press the button on your cabinet.")
    print("  Press Enter to skip a position.")
    print("  Press Ctrl+C to cancel.")
    print()

    cabinet = {}
    used_codes = set()

    for pos_id, pos_label in POSITIONS:
        prompt = f"  Press [{pos_label}]: "
        print(prompt, end="", flush=True)

        while True:
            stdin_ready, _, _ = select.select([sys.stdin], [], [], 0)
            if stdin_ready:
                line = sys.stdin.readline()
                if line.strip() == "":
                    print(f"  → Skipped")
                    break

            r, _, _ = select.select([dev.fd], [], [], 0.1)
            if r:
                for event in dev.read():
                    if event.type == ecodes.EV_KEY and event.value == 1:
                        code = event.code

                        if code in used_codes:
                            print(f"\n  ⚠ {get_button_display_name(code)} already assigned! Press a different button.")
                            print(prompt, end="", flush=True)
                            wait_release(dev)
                            continue

                        cabinet[pos_id] = code
                        used_codes.add(code)
                        print(f"  → {get_button_display_name(code)} (code {code})")
                        wait_release(dev)
                        break
                else:
                    continue
                break

    dev.close()
    return cabinet


def save_cabinet(cabinet):
    """Save the cabinet mapping."""
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    CABINET_FILE.write_text(json.dumps(cabinet, indent=2) + "\n")
    print(f"  Saved to {CABINET_FILE}")


def load_cabinet():
    """Load existing cabinet config."""
    if not CABINET_FILE.exists():
        return None
    try:
        return json.loads(CABINET_FILE.read_text())
    except (json.JSONDecodeError, IOError):
        return None


def main():
    print_header()

    if os.geteuid() != 0:
        print("  Please run as root: sudo shanwan-configure")
        sys.exit(1)

    devices = find_shanwan_devices()
    if not devices:
        print("  No SHANWAN PS3/PC Gamepad found. Is it plugged in?")
        print("  Make sure to stop the remap service first:")
        print("    sudo systemctl stop shanwan-remap")
        sys.exit(1)

    existing = load_cabinet()
    if existing:
        print("  Current cabinet mapping:")
        print_cabinet_table(existing)
        resp = input("  Reconfigure? [y/N] ").strip().lower()
        if resp != "y":
            print("  Keeping current config.")
            return

    dev_path = devices[0][0]
    print()

    try:
        cabinet = configure(dev_path)
    except KeyboardInterrupt:
        print("\n\n  Cancelled.")
        sys.exit(1)

    if not cabinet:
        print("\n  No buttons mapped. Config not saved.")
        sys.exit(1)

    print_cabinet_table(cabinet)

    resp = input("  Save this cabinet mapping? [Y/n] ").strip().lower()
    if resp in ("", "y", "yes"):
        save_cabinet(cabinet)
        print()
        print("  Next steps:")
        print("    1. Create a keymap.json for your game (see README)")
        print("    2. Restart the service: sudo systemctl restart shanwan-remap")
        print()
    else:
        print("  Discarded.")


if __name__ == "__main__":
    main()
