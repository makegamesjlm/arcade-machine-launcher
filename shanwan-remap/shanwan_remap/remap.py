#!/usr/bin/env python3
"""
shanwan-remap: Remap the SHANWAN PS3/PC Gamepad joystick to the left stick,
right stick, or one of two dpad representations, and remap buttons from
cabinet.json + keymap.json.

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

DPAD_AXIS_BUTTONS = {
    ecodes.ABS_HAT0X: (ecodes.BTN_DPAD_LEFT, ecodes.BTN_DPAD_RIGHT),
    ecodes.ABS_HAT0Y: (ecodes.BTN_DPAD_UP, ecodes.BTN_DPAD_DOWN),
}
DPAD_BUTTONS = {
    button
    for axis_buttons in DPAD_AXIS_BUTTONS.values()
    for button in axis_buttons
}

CONFIG_DIR = Path("/etc/shanwan-remap")
CABINET_FILE = CONFIG_DIR / "cabinet.json"
KEYMAP_FILE = CONFIG_DIR / "keymap.json"

# Xbox 360 controller IDs
XBOX360_VENDOR = 0x045e
XBOX360_PRODUCT = 0x028e

# Xbox button name → evdev code
XBOX_NAME_TO_CODE = {
    "A":     ecodes.BTN_SOUTH,   # 304
    "B":     ecodes.BTN_EAST,    # 305
    "X":     ecodes.BTN_NORTH,   # 307
    "Y":     ecodes.BTN_WEST,    # 308
    "LB":    ecodes.BTN_TL,      # 310
    "RB":    ecodes.BTN_TR,      # 311
    "LT":    ecodes.BTN_TL2,     # 312
    "RT":    ecodes.BTN_TR2,     # 313
    "Back":  ecodes.BTN_SELECT,  # 314
    "Start": ecodes.BTN_START,   # 315
    "Guide": ecodes.BTN_MODE,    # 316
    "LS":    ecodes.BTN_THUMBL,  # 317
    "RS":    ecodes.BTN_THUMBR,  # 318
}


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
        if position == "joystick":
            continue  # handled separately as joystick mode
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


def build_capabilities(dev, button_map):
    """Build output device capabilities with all possible axes for hot-switching joystick mode."""
    STICK_INFO = AbsInfo(value=127, min=0, max=255, fuzz=0, flat=15, resolution=0)
    HAT_INFO = AbsInfo(value=0, min=-1, max=1, fuzz=0, flat=0, resolution=0)

    caps = {}
    for etype, ecodes_list in dev.capabilities(absinfo=True).items():
        if etype == 0:
            continue
        if etype == ecodes.EV_ABS:
            new_abs = []
            # Track which axes we've seen so we don't duplicate
            seen_codes = set()
            for code, info in ecodes_list:
                if code in (ecodes.ABS_HAT0X, ecodes.ABS_HAT0Y,
                            ecodes.ABS_X, ecodes.ABS_Y):
                    continue  # We'll add all of these ourselves below
                else:
                    new_abs.append((code, info))
                    seen_codes.add(code)
            # Always advertise all axes so we can hot-switch modes
            new_abs.append((ecodes.ABS_X, STICK_INFO))       # left stick
            new_abs.append((ecodes.ABS_Y, STICK_INFO))
            if ecodes.ABS_RX not in seen_codes:
                new_abs.append((ecodes.ABS_RX, STICK_INFO))  # right stick
            if ecodes.ABS_RY not in seen_codes:
                new_abs.append((ecodes.ABS_RY, STICK_INFO))
            new_abs.append((ecodes.ABS_HAT0X, HAT_INFO))     # dpad
            new_abs.append((ecodes.ABS_HAT0Y, HAT_INFO))
            caps[etype] = new_abs
        elif etype == ecodes.EV_KEY:
            mapped_buttons = set(DPAD_BUTTONS)
            for code in ecodes_list:
                if code in button_map:
                    mapped_buttons.add(button_map[code])
                else:
                    mapped_buttons.add(code)
            for dst in button_map.values():
                mapped_buttons.add(dst)
            caps[etype] = sorted(mapped_buttons)
        else:
            caps[etype] = ecodes_list
    return caps


def write_dpad_buttons(ui, axis, value):
    """Write canonical dpad-button events for one physical hat axis."""
    negative_button, positive_button = DPAD_AXIS_BUTTONS[axis]
    ui.write(ecodes.EV_KEY, negative_button, int(value < 0))
    ui.write(ecodes.EV_KEY, positive_button, int(value > 0))


def reset_joystick_outputs(ui):
    """Return every possible joystick output to its neutral state."""
    for axis in (ecodes.ABS_X, ecodes.ABS_Y, ecodes.ABS_RX, ecodes.ABS_RY):
        ui.write(ecodes.EV_ABS, axis, 127)
    for axis in (ecodes.ABS_HAT0X, ecodes.ABS_HAT0Y):
        ui.write(ecodes.EV_ABS, axis, 0)
    for button in DPAD_BUTTONS:
        ui.write(ecodes.EV_KEY, button, 0)
    ui.syn()


class KeymapWatcher:
    """Watches keymap.json for changes and recomposes the button map + joystick mode."""

    # Joystick mode constants
    LEFT_STICK = "left_stick"
    RIGHT_STICK = "right_stick"
    DPAD = "dpad"
    DPAD_LEGACY = "dpad-legacy"

    def __init__(self, cabinet):
        self.cabinet = cabinet
        keymap = load_keymap()
        self.button_map = compose_button_map(cabinet, keymap)
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

    def get_joystick_mode(self):
        with self._lock:
            return self.joystick_mode

    def _reload(self):
        keymap = load_keymap()
        new_map = compose_button_map(self.cabinet, keymap)
        new_mode = keymap.get("joystick", self.LEFT_STICK)
        with self._lock:
            self.button_map = new_map
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

    button_map = watcher.get_button_map()
    caps = build_capabilities(dev, button_map)

    ui = UInput(caps, name=name, vendor=XBOX360_VENDOR, product=XBOX360_PRODUCT)
    LOG.info("Created virtual device: %s", name)
    previous_joy_mode = watcher.get_joystick_mode()

    try:
        for event in dev.read_loop():
            current_map = watcher.get_button_map()
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
                    elif joy_mode == KeymapWatcher.DPAD_LEGACY:
                        write_dpad_buttons(ui, event.code, event.value)
                        ui.syn()
                elif event.code in (ecodes.ABS_X, ecodes.ABS_Y):
                    continue  # drop original unused axes
                else:
                    ui.write(event.type, event.code, event.value)
                    ui.syn()
            elif event.type == ecodes.EV_KEY:
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
