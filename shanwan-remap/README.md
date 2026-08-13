# shanwan-remap

Remaps SHANWAN PS3/PC Gamepad for arcade cabinets. Fixes the dpad-as-stick issue and provides per-game button remapping.

## What it does

- Remaps the physical joystick to the left stick, right stick, or digital dpad
- Identifies as Xbox 360 controller so all games recognize it
- Per-game button remapping via simple JSON keymaps
- Hot-reloads keymaps without service restart (for arcade launcher integration)

## Requirements

- Linux (Fedora, Bazzite, or similar)
- Python 3.8+
- python3-devel and gcc (for building evdev — can be removed after install)

## Install

```bash
tar xzf shanwan-remap.tar.gz
cd shanwan-remap
sudo ./install.sh
```

## Cabinet setup (one-time)

```bash
sudo systemctl stop shanwan-remap
sudo shanwan-configure
sudo systemctl start shanwan-remap
```

This creates `/etc/shanwan-remap/cabinet.json` mapping your physical button positions to evdev codes.

## Per-game keymaps

Each game gets a `keymap.json` using position names and Xbox button names:

```json
{
  "joystick": "left_stick",
  "bottom_right": "A",
  "bottom_middle": "B",
  "top_right": "X",
  "top_middle": "Y",
  "top_left": "LB",
  "bottom_left": "RB",
  "white": "Start"
}
```

### Joystick modes

- `"left_stick"` — joystick acts as left analog stick (default, most games)
- `"right_stick"` — joystick acts as right analog stick
- `"dpad"` — digital dpad, compatible with standard gamepad APIs including SDL and Unity's `Gamepad.dpad`

The dpad is emitted as Linux hat axes (`ABS_HAT0X/Y`) using the standard Xbox
360 SDL mapping.

### Position names

```
  [top_left]     [top_middle]     [top_right]
  [bottom_left]  [bottom_middle]  [bottom_right]

  [white]  (small button)
```

### Xbox button names

`A`, `B`, `X`, `Y`, `LB`, `RB`, `LT`, `RT`, `Back`, `Start`, `Guide`, `LS`, `RS`

## Launcher integration

The arcade launcher swaps keymaps by writing to `/etc/shanwan-remap/keymap.json`. The service detects the change within 2 seconds and applies it automatically — no restart needed.

```
1. Launcher writes game's keymap.json → /etc/shanwan-remap/keymap.json
2. Service detects change, reloads button mapping
3. Launcher starts the game
4. Game exits → launcher can write a different keymap for the next game
```

## Uninstall

```bash
sudo ./uninstall.sh
```
