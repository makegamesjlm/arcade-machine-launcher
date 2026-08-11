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
- `"dpad"` — digital d-pad (useful for fighting and retro games)

Omit `joystick` to retain the default `"left_stick"` behavior. The other keys
map the cabinet's physical buttons.

A game with no `keymap.json` runs with the launcher's own mapping. A keymap that
names an unknown button is **rejected whole** — the game still appears and is
still playable, but the launcher will not install a mapping it knows the service
would choke on, and says so in the amber strip at the bottom of the screen.

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
| Bottom-right button | Play the selected game |
| Bottom-middle button | Dismiss an error |
| Top-left / Top-right button | System volume down / up |
| Top-middle button | Mute toggle |
| White button | Rescan the games folder |

Either controller can drive the menu. Volume and mute work only on the menu
screen; once a game is running it owns the controller.

## What happens on select

1. The game's `keymap.json` is validated and installed at
   `/etc/shanwan-remap/keymap.json`.
2. The launcher waits 2.2s for the remap service to hot-reload, so the game's
   first frame already has the right buttons.
3. The launcher minimizes, drops to 5 FPS, and starts the executable fullscreen
   inside Gamescope. Gamescope hides the mouse cursor immediately for the whole
   game session. If Gamescope is unavailable, the executable is started directly
   and a warning is written to the journal.
4. It polls twice a second until the process is gone.
5. The launcher's own keymap is restored, the window comes back to the
   foreground, and the games folder is rescanned.

A game that exits non-zero within 2 seconds is reported as a failed launch
rather than a finished session.

## Development

The launcher can run on a desktop against fake games. Paths are overridable:

```bash
godot --path . -- --no-fullscreen --games-dir=dev/games --keymap-path=/tmp/keymap.json
```

`--games-dir`, `--keymap-path` and `--no-fullscreen` also read from
`ARCADE_GAMES_DIR` and `ARCADE_KEYMAP_PATH`.

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

Covers the scanner, keymap validation, atomic install, and all three simulated
launch outcomes. Exits non-zero on failure.

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
| `scripts/game_launcher.gd` | The launch → play → return cycle |
| `scripts/main.gd` | Grid, navigation, overlays |
| `scenes/` | `main.tscn`, `game_card.tscn` |
| `scripts/setup-arcade.sh` | One-time cabinet permissions setup |
| `systemd/` | User unit and install notes |
