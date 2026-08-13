# shanwan-remap

Remaps SHANWAN PS3/PC Gamepad for arcade cabinets. Fixes the dpad-as-stick issue and provides per-game button remapping.

## What it does

- Remaps the physical joystick to the left stick, right stick, or digital dpad
- Identifies as Xbox 360 controller so all games recognize it
- Per-game button remapping via simple JSON keymaps
- Hot-reloads keymaps without service restart (for arcade launcher integration)
- Reserves the `white` cabinet button as a system button: it is never forwarded to a game
  on its own, no matter what a keymap says. The launcher owns it via the control channel
  below.
- Exposes a live control channel the launcher uses to see every physical press, gate all
  physical input off a game while it is frozen, and inject a single synthetic press (see
  "Control channel" below).

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

The virtual device always advertises the full, fixed 11-button set a real
wired Xbox 360 pad has (plus both analog triggers), no matter which of them a
given keymap actually uses. SDL and the gamepad APIs built on it (including
Unity's) assign button *indices* by scanning the device's capabilities in
order and looking up each index in a mapping table baked in for the Xbox 360;
advertising a different set of buttons than a real pad shifts every button
after the gap into the wrong index. `LT`/`RT` are emitted as full analog
trigger pulls rather than key events, since a real Xbox 360 pad has no
digital trigger buttons either.

## Launcher integration

The arcade launcher swaps keymaps by writing to `/etc/shanwan-remap/keymap.json`. The service detects the change within 2 seconds and applies it automatically — no restart needed.

```
1. Launcher writes game's keymap.json → /etc/shanwan-remap/keymap.json
2. Service detects change, reloads button mapping
3. Launcher starts the game
4. Game exits → launcher can write a different keymap for the next game
```

## Control channel

A second, live channel for anything a 2-second file poll is too slow for: opening the
system overlay on `white`, freezing a game's input while the launcher's own UI is on
screen, and injecting a single button press. TCP, loopback-only, newline-delimited JSON,
`127.0.0.1:47811`. The remapper is the server; the launcher (or `nc`/any TCP client, for
debugging) is the client.

**Feed — every message the service sends, unprompted, for every physical event:**

```
{"t":"btn","pad":1,"pos":"bottom_right","xbox":"A","v":1}
{"t":"btn","pad":1,"pos":"white","xbox":null,"v":1}
{"t":"hat","pad":1,"axis":"x","v":-1}
```

`pos` is the `cabinet.json` position name, independent of whichever keymap is currently
installed. `white` always reports `"xbox":null` — it is a system position now, not a game
button, whatever a keymap might say.

**Commands — sent by the client, one JSON object per line:**

| Command | Effect |
| --- | --- |
| `{"c":"hello"}` | Handshake. Replies with `{"ok":true,"proto":1,"has_white":true\|false}`. |
| `{"c":"mode","m":"pass"}` | Normal forwarding — the default. |
| `{"c":"mode","m":"blocked"}` | Every physical button and axis is neutralized (all buttons released, sticks/hat centered) and then dropped — nothing reaches the virtual pad until `pass` is restored. |
| `{"c":"inject","pos":"white"}` | Writes one press+release of `pos`, through whatever the *current* keymap maps it to. This is the only way `white` ever reaches a game. |

Every command gets one JSON reply line, `{"ok":true,...}` or `{"ok":false,"error":"..."}`.

**Failure handling built in, not bolted on:**

- If the client that requested `blocked` disconnects (or never reconnects after the
  service restarts), the gate reverts to `pass` on its own — a crashed launcher can never
  leave a game permanently deaf to its own controller.
- The service restarts (and the gate resets to `pass`) whenever a controller is unplugged
  or replugged, per the udev rule below. A reconnecting client is expected to push its
  desired mode again rather than assume it stuck.

## Tests

```bash
pip install -e .[dev]
pytest
```

Pure-logic coverage only (the gate, the compose/feed helpers with a fake uinput, and the
control protocol over a real loopback socket on an OS-assigned port) — nothing here opens
a physical device, so it needs no cabinet hardware, but it does need Linux (the package
imports `evdev` at module load).

## Uninstall

```bash
sudo ./uninstall.sh
```
