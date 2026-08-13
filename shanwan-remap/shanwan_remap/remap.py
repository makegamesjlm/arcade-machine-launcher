#!/usr/bin/env python3
"""
shanwan-remap: Remap the SHANWAN PS3/PC Gamepad joystick to the left stick,
right stick, or dpad, and remap buttons from cabinet.json + keymap.json.

Two config files:
  cabinet.json — maps physical button positions to evdev codes (set once per cabinet)
  keymap.json  — maps position names to Xbox button names (swapped per game by launcher)

The service composes them: position → source code (cabinet) → dest code (keymap).
Watches keymap.json for changes and hot-reloads without restart.
"""
import json
import sys
import signal
import logging
import threading
from pathlib import Path
from evdev import InputDevice, UInput, ecodes, AbsInfo

LOG = logging.getLogger("shanwan-remap")

HAT_TO_AXIS = {-1: 0, 0: 127, 1: 255}

CONFIG_DIR = Path("/etc/shanwan-remap")
CABINET_FILE = CONFIG_DIR / "cabinet.json"
KEYMAP_FILE = CONFIG_DIR / "keymap.json"

# Xbox 360 controller IDs
XBOX360_VENDOR = 0x045e
XBOX360_PRODUCT = 0x028e
# Match the standard Linux SDL Xbox 360 mapping. python-evdev's default version
# of 1 selects an old mapping whose dpad directions are rotated/reversed.
XBOX360_VERSION = 0x0114

# Xbox button name → evdev code. This is exactly the 11 digital buttons a
# real wired Xbox 360 pad has — deliberately excluding LT/RT, which are
# analog-only on real hardware (see XBOX_NAME_TO_TRIGGER_AXIS below). SDL
# (and anything built on it, like Godot's and Unity's gamepad APIs) assigns
# button *indices* by scanning the virtual device's advertised EV_KEY
# capabilities in ascending code order, then looks up index N in a mapping
# table baked in for this vendor/product/version. That table only makes
# sense if the advertised codes are exactly this set — see build_capabilities.
XBOX_NAME_TO_CODE = {
    "A":     ecodes.BTN_SOUTH,   # 304
    "B":     ecodes.BTN_EAST,    # 305
    "X":     ecodes.BTN_NORTH,   # 307
    "Y":     ecodes.BTN_WEST,    # 308
    "LB":    ecodes.BTN_TL,      # 310
    "RB":    ecodes.BTN_TR,      # 311
    "Back":  ecodes.BTN_SELECT,  # 314
    "Start": ecodes.BTN_START,   # 315
    "Guide": ecodes.BTN_MODE,    # 316
    "LS":    ecodes.BTN_THUMBL,  # 317
    "RS":    ecodes.BTN_THUMBR,  # 318
}

# The exact EV_KEY capability set the virtual device must always advertise —
# see the comment on XBOX_NAME_TO_CODE above for why.
XBOX360_BUTTON_CODES = sorted(XBOX_NAME_TO_CODE.values())

# LT/RT have no digital button on real Xbox 360 hardware — they're reported as
# full-range analog triggers (ABS_Z/ABS_RZ). A cabinet button mapped to "LT"
# or "RT" is emitted as a full trigger pull instead of a key event, so it
# never adds an extra code to the EV_KEY set above and never shifts any other
# button's index.
XBOX_NAME_TO_TRIGGER_AXIS = {
    "LT": ecodes.ABS_Z,
    "RT": ecodes.ABS_RZ,
}
TRIGGER_MAX = 255


def load_cabinet():
    """Load cabinet.json: position name → evdev source code."""
    if not CABINET_FILE.exists():
        LOG.info("No cabinet.json found, using default passthrough")
        return {}
    try:
        data = json.loads(CABINET_FILE.read_text())
        cabinet = {pos: int(code) for pos, code in data.items()}
        LOG.info("Loaded cabinet config: %d positions", len(cabinet))
        return cabinet
    except (json.JSONDecodeError, IOError, ValueError) as e:
        LOG.warning("Failed to load cabinet.json: %s", e)
        return {}


def load_keymap():
    """Load keymap.json: position name → Xbox button name."""
    if not KEYMAP_FILE.exists():
        LOG.info("No keymap.json found, using default passthrough")
        return {}
    try:
        data = json.loads(KEYMAP_FILE.read_text())
        LOG.info("Loaded keymap: %d mappings", len(data))
        return data
    except (json.JSONDecodeError, IOError) as e:
        LOG.warning("Failed to load keymap.json: %s", e)
        return {}


def compose_button_map(cabinet, keymap):
    """Compose cabinet + keymap into {source_evdev_code: dest_evdev_code}."""
    if not cabinet or not keymap:
        return {}
    button_map = {}
    for position, xbox_name in keymap.items():
        if position == "joystick" or xbox_name in XBOX_NAME_TO_TRIGGER_AXIS:
            continue  # joystick mode / LT & RT are handled separately
        source_code = cabinet.get(position)
        dest_code = XBOX_NAME_TO_CODE.get(xbox_name)
        if source_code is not None and dest_code is not None:
            button_map[source_code] = dest_code
        elif source_code is None:
            LOG.warning("Position '%s' not found in cabinet.json, skipping", position)
        elif dest_code is None:
            LOG.warning("Xbox button '%s' not recognized, skipping", xbox_name)
    LOG.info("Composed button map: %d remappings", len(button_map))
    return button_map


def compose_trigger_map(cabinet, keymap):
    """Compose cabinet + keymap into {source_evdev_code: dest_abs_axis} for LT/RT."""
    if not cabinet or not keymap:
        return {}
    trigger_map = {}
    for position, xbox_name in keymap.items():
        axis = XBOX_NAME_TO_TRIGGER_AXIS.get(xbox_name)
        if axis is None:
            continue
        source_code = cabinet.get(position)
        if source_code is not None:
            trigger_map[source_code] = axis
        else:
            LOG.warning("Position '%s' not found in cabinet.json, skipping", position)
    LOG.info("Composed trigger map: %d remappings", len(trigger_map))
    return trigger_map


def find_shanwan_devices():
    """Find all SHANWAN PS3/PC Gamepad event devices."""
    import glob
    devices = []
    for path in sorted(glob.glob("/dev/input/event*")):
        try:
            dev = InputDevice(path)
            if "SHANWAN" in dev.name and "PS3" in dev.name:
                devices.append(path)
                dev.close()
            else:
                dev.close()
        except (PermissionError, OSError):
            continue
    return devices


def build_capabilities(dev):
    """Build output device capabilities that always exactly match a real wired
    Xbox 360 pad, for hot-switching joystick mode and remapping buttons."""
    STICK_INFO = AbsInfo(value=127, min=0, max=255, fuzz=0, flat=15, resolution=0)
    HAT_INFO = AbsInfo(value=0, min=-1, max=1, fuzz=0, flat=0, resolution=0)
    TRIGGER_INFO = AbsInfo(value=0, min=0, max=255, fuzz=0, flat=0, resolution=0)

    caps = {}
    for etype, ecodes_list in dev.capabilities(absinfo=True).items():
        if etype == 0:
            continue
        if etype == ecodes.EV_ABS:
            new_abs = []
            for code, info in ecodes_list:
                if code in (ecodes.ABS_HAT0X, ecodes.ABS_HAT0Y,
                            ecodes.ABS_X, ecodes.ABS_Y,
                            ecodes.ABS_RX, ecodes.ABS_RY,
                            ecodes.ABS_Z, ecodes.ABS_RZ):
                    continue  # We'll add all of these ourselves below
                else:
                    new_abs.append((code, info))
            # Always advertise all axes so we can hot-switch modes and remap
            # LT/RT, regardless of what the physical SHANWAN pad reports.
            new_abs.append((ecodes.ABS_X, STICK_INFO))       # left stick
            new_abs.append((ecodes.ABS_Y, STICK_INFO))
            new_abs.append((ecodes.ABS_RX, STICK_INFO))      # right stick
            new_abs.append((ecodes.ABS_RY, STICK_INFO))
            new_abs.append((ecodes.ABS_HAT0X, HAT_INFO))     # dpad
            new_abs.append((ecodes.ABS_HAT0Y, HAT_INFO))
            new_abs.append((ecodes.ABS_Z, TRIGGER_INFO))     # LT
            new_abs.append((ecodes.ABS_RZ, TRIGGER_INFO))    # RT
            caps[etype] = new_abs
        elif etype == ecodes.EV_KEY:
            # Always advertise exactly these 11 codes - never more, never
            # fewer - regardless of which of them this cabinet's keymap
            # actually uses and regardless of what raw buttons the physical
            # SHANWAN pad happens to report. See the comment on
            # XBOX_NAME_TO_CODE for why any deviation breaks SDL/Unity's
            # button mapping (this is what made "Start" never register).
            caps[etype] = XBOX360_BUTTON_CODES
        else:
            caps[etype] = ecodes_list
    return caps


def reset_joystick_outputs(ui):
    """Return every possible joystick output to its neutral state."""
    for axis in (ecodes.ABS_X, ecodes.ABS_Y, ecodes.ABS_RX, ecodes.ABS_RY):
        ui.write(ecodes.EV_ABS, axis, 127)
    for axis in (ecodes.ABS_HAT0X, ecodes.ABS_HAT0Y):
        ui.write(ecodes.EV_ABS, axis, 0)
    ui.syn()


class KeymapWatcher:
    """Watches keymap.json for changes and recomposes the button map + joystick mode."""

    # Joystick mode constants
    LEFT_STICK = "left_stick"
    RIGHT_STICK = "right_stick"
    DPAD = "dpad"

    def __init__(self, cabinet):
        self.cabinet = cabinet
        keymap = load_keymap()
        self.button_map = compose_button_map(cabinet, keymap)
        self.trigger_map = compose_trigger_map(cabinet, keymap)
        self.joystick_mode = keymap.get("joystick", self.LEFT_STICK)
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._last_mtime = self._get_mtime()

    def _get_mtime(self):
        try:
            return KEYMAP_FILE.stat().st_mtime
        except (OSError, IOError):
            return 0

    def get_button_map(self):
        with self._lock:
            return dict(self.button_map)

    def get_trigger_map(self):
        with self._lock:
            return dict(self.trigger_map)

    def get_joystick_mode(self):
        with self._lock:
            return self.joystick_mode

    def _reload(self):
        keymap = load_keymap()
        new_map = compose_button_map(self.cabinet, keymap)
        new_trigger_map = compose_trigger_map(self.cabinet, keymap)
        new_mode = keymap.get("joystick", self.LEFT_STICK)
        with self._lock:
            self.button_map = new_map
            self.trigger_map = new_trigger_map
            self.joystick_mode = new_mode
        LOG.info("Keymap reloaded: %d button remappings, joystick=%s", len(new_map), new_mode)

    def watch(self):
        """Poll keymap.json for changes every 2 seconds."""
        LOG.info("Watching %s for changes", KEYMAP_FILE)
        while not self._stop.is_set():
            self._stop.wait(2)
            mtime = self._get_mtime()
            if mtime != self._last_mtime:
                self._last_mtime = mtime
                LOG.info("Keymap file changed, reloading...")
                self._reload()

    def start(self):
        t = threading.Thread(target=self.watch, daemon=True)
        t.start()
        return t

    def stop(self):
        self._stop.set()


def remap_single(event_path, name, watcher):
    """Remap a single controller. Blocks until interrupted or device disconnected."""
    dev = InputDevice(event_path)
    LOG.info("Opened %s (%s)", dev.name, event_path)

    dev.grab()
    LOG.info("Grabbed %s", event_path)

    caps = build_capabilities(dev)

    ui = UInput(
        caps,
        name=name,
        vendor=XBOX360_VENDOR,
        product=XBOX360_PRODUCT,
        version=XBOX360_VERSION,
    )
    LOG.info("Created virtual device: %s", name)
    previous_joy_mode = watcher.get_joystick_mode()

    try:
        for event in dev.read_loop():
            current_map = watcher.get_button_map()
            current_trigger_map = watcher.get_trigger_map()
            joy_mode = watcher.get_joystick_mode()

            if joy_mode != previous_joy_mode:
                reset_joystick_outputs(ui)
                previous_joy_mode = joy_mode

            if event.type == ecodes.EV_ABS:
                if event.code in (ecodes.ABS_HAT0X, ecodes.ABS_HAT0Y):
                    if joy_mode == KeymapWatcher.LEFT_STICK:
                        axis = ecodes.ABS_X if event.code == ecodes.ABS_HAT0X else ecodes.ABS_Y
                        ui.write(ecodes.EV_ABS, axis, HAT_TO_AXIS.get(event.value, 127))
                        ui.syn()
                    elif joy_mode == KeymapWatcher.RIGHT_STICK:
                        axis = ecodes.ABS_RX if event.code == ecodes.ABS_HAT0X else ecodes.ABS_RY
                        ui.write(ecodes.EV_ABS, axis, HAT_TO_AXIS.get(event.value, 127))
                        ui.syn()
                    elif joy_mode == KeymapWatcher.DPAD:
                        ui.write(ecodes.EV_ABS, event.code, event.value)
                        ui.syn()
                elif event.code in (ecodes.ABS_X, ecodes.ABS_Y):
                    continue  # drop original unused axes
                else:
                    ui.write(event.type, event.code, event.value)
                    ui.syn()
            elif event.type == ecodes.EV_KEY:
                trigger_axis = current_trigger_map.get(event.code)
                if trigger_axis is not None:
                    ui.write(ecodes.EV_ABS, trigger_axis, TRIGGER_MAX if event.value else 0)
                    ui.syn()
                else:
                    out_code = current_map.get(event.code, event.code)
                    ui.write(ecodes.EV_KEY, out_code, event.value)
                    ui.syn()
            elif event.type != ecodes.EV_SYN:
                ui.write(event.type, event.code, event.value)
                ui.syn()
    except (OSError, IOError) as e:
        LOG.warning("Device disconnected or error: %s", e)
    finally:
        try:
            dev.ungrab()
        except (OSError, IOError):
            pass
        ui.close()
        LOG.info("Stopped remapping %s", name)


def remap_all():
    """Find all SHANWAN controllers and remap them."""
    devices = find_shanwan_devices()
    if not devices:
        LOG.error("No SHANWAN PS3/PC Gamepad devices found.")
        sys.exit(1)

    cabinet = load_cabinet()
    watcher = KeymapWatcher(cabinet)
    watcher.start()

    LOG.info("Found %d SHANWAN device(s): %s", len(devices), ", ".join(devices))

    threads = []
    for i, path in enumerate(devices, 1):
        name = f"Remapped Controller {i}"
        t = threading.Thread(target=remap_single, args=(path, name, watcher), daemon=True)
        t.start()
        threads.append(t)
        LOG.info("Started remapping thread for %s -> %s", path, name)

    for t in threads:
        t.join()

    watcher.stop()


def main():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
    )

    def shutdown(sig, frame):
        LOG.info("Received signal %d, shutting down...", sig)
        sys.exit(0)

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    if len(sys.argv) == 3:
        cabinet = load_cabinet()
        watcher = KeymapWatcher(cabinet)
        watcher.start()
        remap_single(sys.argv[1], sys.argv[2], watcher)
    elif len(sys.argv) == 1:
        remap_all()
    else:
        print("Usage:")
        print(f"  {sys.argv[0]}                              Auto-detect and remap all")
        print(f"  {sys.argv[0]} /dev/input/eventXX \"Name\"    Remap a specific device")
        sys.exit(1)


if __name__ == "__main__":
    main()
