# Arcade machine launcher

A fullscreen, controller-only game launcher for a two-player arcade cabinet
running Bazzite. It scans `~/Nextcloud/Games`, shows a grid, and on selection
installs that game's controller mapping before starting it.

Built with Godot 4.7.

## How a game is installed

One folder per game under `~/Nextcloud/Games` (Nextcloud syncs new titles onto
the cabinet). The location is the launcher's default; override it with
`--games-dir` or `ARCADE_GAMES_DIR`.

```
~/Nextcloud/Games/
  neon-drift/
    game.json      required - name, description, executable, player count
    icon.png       optional - shown in the grid
    keymap.json    optional - button mapping applied while this game runs
    game.x86_64    the binary
```

### game.json

```json
{
  "name": "Neon Drift",
  "description": "Two-player top-down racing through a rain-slick city.",
  "executable": "game.x86_64",
  "players": 2
}
```

| Key | Required | Notes |
| --- | --- | --- |
| `name` | no | Falls back to the folder name |
| `description` | no | Shown under the grid for the selected game |
| `executable` | **yes** | Relative to the game folder, or an absolute path |
| `players` | no | Defaults to `1` |
| `args` | no | Array of extra arguments for the executable |

The game runs with its own folder as the working directory.

### keymap.json

Maps the cabinet's physical buttons to the Xbox names the `shanwan-remap`
service understands:

```json
{
  "joystick": "left_stick",
  "top_left": "LB",
  "top_middle": "Y",
  "top_right": "X",
  "bottom_left": "RB",
  "bottom_middle": "B",
  "bottom_right": "A",
  "white": "Start"
}
```

Cabinet buttons: `top_left`, `top_middle`, `top_right`, `bottom_left`,
`bottom_middle`, `bottom_right`, `white`.

Xbox names: `A`, `B`, `X`, `Y`, `LB`, `RB`, `LT`, `RT`, `Back`, `Start`,
`Guide`, `LS`, `RS`.

The optional `joystick` key controls what each cabinet joystick reports as:

- `"left_stick"` — Xbox left analog stick (default; suitable for most games)
- `"right_stick"` — Xbox right analog stick
- `"dpad"` — digital d-pad, compatible with standard gamepad APIs including SDL and Unity's `Gamepad.dpad`

Omit `joystick` to retain the default `"left_stick"` behavior. The other keys
map the cabinet's physical buttons.

A game with no `keymap.json` runs with the launcher's own mapping. A keymap that
names an unknown button is **rejected whole** — the game still appears and is
still playable, but the launcher will not install a mapping it knows the service
would choke on, and says so in the amber strip at the bottom of the screen.

`white` is reserved: shanwan-remap never forwards it to a game in any mode,
whatever a keymap says (see "The white button and the system overlay" below).
Mapping it to `Start` here is still worth doing — it is what a game's own pause
menu opens on when the player picks **Send pause** from the system overlay.

## Cabinet setup

On a fresh cabinet, one script runs every step below in order — permissions, the
remap service, the build, and the launcher service. Run it as your normal user
(it escalates the steps that need root itself):

```bash
./scripts/install-cabinet.sh
```

`--skip-setup`, `--skip-remap` and `--skip-build` re-run just part of it; see
`./scripts/install-cabinet.sh --help`. The individual steps are documented below
if you would rather do them by hand.

```bash
sudo ./scripts/setup-arcade.sh
```

This creates `/etc/shanwan-remap` and `~/Nextcloud/Games`, makes the keymap
directory writable by a new `arcade` group, adds your user to it, and seeds a
starting keymap. Log out and back in afterwards so the group membership takes
effect.

The launcher then writes `/etc/shanwan-remap/keymap.json` directly, with no
`sudo` in the loop. The write is atomic — a temp file in the same directory
followed by a rename — so the polling service never reads a half-written file.

Then build and install the service: [systemd/README-service.md](systemd/README-service.md).

## Controls

| Input | Action |
| --- | --- |
| Joystick / d-pad | Move around the grid |
| Bottom-right button | Play the selected game, or confirm in the system overlay |
| Bottom-middle button | Dismiss an error, or Continue in the system overlay |
| Top-left / Top-right button | System volume down / up |
| Top-middle button | Mute toggle |
| White button | Open the system overlay |

Either controller can drive the menu. Volume, mute, and the plain shortcuts
above all work only while the grid is the active surface — not while a game
is running, the system overlay is open, or attract mode is showing.

## What happens on select

1. The game's `keymap.json` is validated and installed at
   `/etc/shanwan-remap/keymap.json`.
2. The launcher waits 2.2s for the remap service to hot-reload, so the game's
   first frame already has the right buttons.
3. The launcher minimizes, drops to 5 FPS, and starts the executable.
4. It polls twice a second until the process is gone.
5. The launcher's own keymap is restored, the window comes back to the
   foreground, and the games folder is rescanned.

A game that exits non-zero within 2 seconds is reported as a failed launch
rather than a finished session. (Steps 4-5 do not run for a game that is
merely held rather than actually finished — see below.)

## The white button and the system overlay

White is a system button, not a game button: shanwan-remap never writes it to
the virtual pad, so a game never sees it on its own, no matter what any
keymap says. Pressing it always opens a two-row overlay over whatever was on
screen (the game keeps running, but freezes for the duration — see below):

Row 1 (varies by context):

| Context | Items |
| --- | --- |
| A game is running | Continue · Send pause · Back to launcher · Close game · Sleep |
| Menu, nothing held | Continue · Refresh · Sleep |
| Menu, a game held | Continue · Close game · Refresh · Sleep |

Row 2 is always **Mute · Volume down · Volume up**, and acts immediately
without closing the overlay.

- **Continue** resumes the game (or closes the overlay on the menu) exactly
  where it was.
- **Send pause** resumes the game and then sends the white press through to
  it, so the game's own keymap-mapped pause/settings menu opens.
- **Back to launcher** leaves the game held, frozen, in the background and
  shows the grid; selecting that game again resumes it.
- **Close game** shuts it down completely.
- **Sleep** enters attract mode immediately.
- The bottom-middle button and a second white press both mean Continue.

Navigation is by joystick; the bottom-right button confirms, exactly like the
main grid.

## Held games

Only one game is ever held. Selecting a different game while one is held
closes the held one first — a public cabinet must not become un-startable by
someone who does not understand the badge. The grid marks a held game with a
badge and its detail text says it will resume rather than restart.

## Attract mode

A looping, silent idle video plays after 120 seconds on the menu, or 300
seconds while a game is being played (so a player thinking about a puzzle
is not yanked out after two minutes) - either way pulled from
`~/Nextcloud/Arcade/attract.ogv` (override with `--attract-video` /
`ARCADE_ATTRACT_VIDEO`), Ogg Theora only, since that is all Godot 4 decodes.
A missing or unreadable file falls back to a built-in static screen. Content
is specified in `screensaver-brief.md`.

Pressing any button always wakes it back to the launcher - the menu, or the
held-menu if a game is parked - never back into a game. If a game was
running when attract started, it stays alive, held, in the background.

## Idle kill

After 30 minutes with no input at all, whatever game is running or held is
killed, so the cabinet does not run unattended overnight. Nothing else
happens at that mark: no display blanking, and the attract video (if already
looping) keeps looping right through it.

## Cursor hiding

There is no mouse during arcade play, but one may still get plugged in for
maintenance, so this is scoped to the launcher and games only, not the whole
desktop session. `setup-arcade.sh` installs a fully transparent Xcursor
theme (`arcade-blank`) for the arcade user; only `XCURSOR_THEME=arcade-blank`
in the launcher's own environment (and every game's, inherited through it)
points at it. A file manager or terminal opened from the normal desktop
session never sees that variable and keeps the system's normal cursor. See
`setup-arcade.sh`'s "cursor hiding" section for why this was chosen over
routing games through a nested compositor such as Gamescope (tried once,
reverted; see git history).

## Development

The launcher can run on a desktop against fake games. Paths are overridable:

```bash
godot --path . -- --no-fullscreen --games-dir=dev/games --keymap-path=/tmp/keymap.json
```

`--games-dir`, `--keymap-path`, `--attract-video` and `--no-fullscreen` also
read from `ARCADE_GAMES_DIR`, `ARCADE_KEYMAP_PATH` and `ARCADE_ATTRACT_VIDEO`.

The system overlay, attract mode, and held games all depend on
shanwan-remap's control channel (see shanwan-remap/README.md), which has
nothing to connect to on a dev box. Without it the launcher falls back to
plain Godot input for the grid and skips those features rather than hanging;
they can only be exercised on the cabinet.

`dev/games/` holds fixtures, including deliberately broken ones (invalid JSON,
missing binary, a keymap with bad button names) to exercise the error paths.

On Windows, add `--simulate-launch` and use a keymap path inside the project:

```powershell
godot --path . -- --no-fullscreen --games-dir=dev/games --keymap-path=dev/keymap.json --simulate-launch
```

This runs the real UI and keymap-writing flow without attempting to execute the
Linux fixture binaries. Arrow keys navigate and F5 refreshes. Enter starts a
simulated game; press Escape to finish it successfully. Shift+Enter simulates a
failure before the game starts, and Ctrl+Enter simulates a game that starts and
then crashes immediately.

### Build number

The current build number lives in `BUILD_NUMBER` and is shown beside the
launcher title. Enable the repository's Git hooks once after cloning:

```powershell
./scripts/install-git-hooks.ps1
```

On Linux, run `bash scripts/install-git-hooks.sh` instead.

The pre-commit hook increments and stages `BUILD_NUMBER` for every commit made
on `master`. Commits on other branches leave it unchanged.

### Tests

```bash
godot --headless --path . res://tests/test_core.tscn
godot --headless --path . res://tests/test_simulated_launch.tscn
```

Covers the scanner, keymap validation, atomic install, the Xbox-to-joypad
button table InputRouter depends on, the system overlay's navigation, and all
three simulated launch outcomes. Exits non-zero on failure. shanwan-remap has
its own `pytest` suite - see shanwan-remap/README.md.

### Screenshots

```bash
godot --path . --resolution 1920x1080 res://tests/screenshot.tscn -- --no-fullscreen --games-dir=dev/games --keymap-path=/tmp/keymap.json --shot=/tmp/grid.png --nav=nav_down --shot=/tmp/moved.png
```

## Layout

| Path | What |
| --- | --- |
| `scripts/cfg.gd` | Autoloaded paths and constants, including the launcher's own keymap |
| `scripts/game_scanner.gd` | `/games` → `GameEntry` objects, with errors and warnings |
| `scripts/keymap_writer.gd` | Keymap validation and the atomic install |
| `scripts/game_launcher.gd` | The launch → play → return cycle, plus freeze/hold/close |
| `scripts/arcade_bus.gd` | Client for shanwan-remap's control channel (autoload `Bus`) |
| `scripts/input_router.gd` | Feeds control-channel events into Godot's Input while blocked |
| `scripts/idle_tracker.gd` | Attract/idle-kill thresholds (autoload `Idle`) |
| `scripts/session_controller.gd` | State machine for the system overlay, attract mode, held games |
| `scripts/system_overlay.gd`, `scripts/attract_screen.gd` | The two on top of everything else |
| `scripts/volume_control.gd` | System volume/mute via `wpctl`/`pactl` |
| `scripts/main.gd` | Grid, navigation, the launch-progress overlay, volume HUD |
| `scenes/` | `main.tscn`, `game_card.tscn`, `system_overlay.tscn`, `attract.tscn` |
| `scripts/setup-arcade.sh` | One-time cabinet permissions, keymap seed, cursor theme |
| `scripts/install-cabinet.sh` | Runs setup, shanwan-remap install, the build, and the service in order |
| `scripts/install-git-hooks.sh`, `.ps1` | Enables the build-number pre-commit hook |
| `systemd/` | User unit and install notes |
| `theme/fonts/` | Handjet font variations used by the UI |
| `assets/fonts/` | Bundled Handjet variable font and its license |

## Credits

UI text is set in [Handjet](https://github.com/rosettatype/Handjet), licensed
under the SIL Open Font License 1.1 (see `assets/fonts/OFL.txt`).
