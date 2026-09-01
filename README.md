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
  "creators": ["Ada Lovelace", "Grace Hopper"],
  "executable": "game.x86_64",
  "players": 2
}
```

| Key | Required | Notes |
| --- | --- | --- |
| `name` | no | Falls back to the folder name |
| `description` | no | Shown under the grid for the selected game |
| `creators` | no | Name or array of names, credited under the game's title |
| `executable` | **yes** | Relative to the game folder, or an absolute path |
| `players` | no | Defaults to `1` |
| `args` | no | Array of extra arguments for the executable |
| `hide` | no | `true` keeps the game out of the launcher entirely (see below) |

The game runs with its own folder as the working directory.

Set `"hide": true` to keep a folder in the games directory but out of the
launcher — a work in progress, a title parked for later, or a helper binary
that ships alongside the games but should not be picked. A hidden game is
skipped silently: it does not appear in the row and is not listed as a problem.
It must still be a valid, launchable folder; `hide` is not a way to park a
broken one.

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
directory writable by a new `arcade` group, adds your user to it, seeds a
starting keymap, installs the transparent cursor theme, and turns off KWin's
focus stealing prevention so the launcher can raise its own window over a
running game (see "Window activation" below — the system overlay does not work
without it). Log out and back in afterwards so the group membership takes
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
3. The launcher drops to 5 FPS and starts the executable, staying on screen
   until the game's own window comes up over it (it does not minimize here —
   see below).
4. It polls twice a second until the process is gone.
5. The launcher's own keymap is restored, the window comes back to the
   foreground, and the games folder is rescanned.

A game that exits non-zero within 2 seconds is reported as a failed launch
rather than a finished session. (Steps 4-5 do not run for a game that is
merely held rather than actually finished — see below.)

## The white button and the system overlay

White is a system button, not a game button: shanwan-remap never writes it to
the virtual pad, so a game never sees it on its own, no matter what any
keymap says. A quick **tap** opens a two-row overlay over whatever was on
screen (the game keeps running, but freezes for the duration — see below);
**holding it** for `hard_reset_seconds` (5s by default) is a hard reset — see
[Hard reset](#hard-reset). The tap acts on release, so a reset-hold never
flashes the overlay open first.

Row 1 (varies by context):

| Context | Items |
| --- | --- |
| A game is running | Continue · Send pause · Back to launcher · Close game · Sleep |
| Menu, nothing held | Continue · Sleep |
| Menu, a game held | Continue · Close game · Sleep |

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

There is no Refresh item: the hard reset restarts the launcher, which re-scans
the games folder, so it doubles as the manual "rescan" action.

Navigation is by joystick; the bottom-right button confirms, exactly like the
main grid.

## Hard reset

Holding the white button for `hard_reset_seconds` (5s by default), in the
launcher or mid-game, quits the launcher. On the cabinet it runs as a systemd
user service with `Restart=always` and `KillMode=control-group`, so quitting
restarts it from a clean slate and takes any running game — a child in the same
control group — down with it: a full reset from one held button, no matter what
state the cabinet got itself into. It also re-scans the games folder on the way
back up, which is why there is no separate Refresh.

## Held games

Only one game is ever held. Selecting a different game while one is held
closes the held one first — a public cabinet must not become un-startable by
someone who does not understand the grid's marks. A held game is not marked
as anything separate: its tile reads **RUNNING**, the same as it did while it
was on screen, because from the player's side it is still open. Selecting it
resumes it where it was left.

## Timings (`config.json`)

The behavioural timings below live in `~/Nextcloud/Arcade/config.json`, next to
the attract video, so they sync onto the cabinet and can be retuned by editing
one file - no rebuild or redeploy, the same story as games and the video
(override the path with `--config-path` / `ARCADE_CONFIG_PATH`). The file is
optional: every value has a sane default, and a fresh cabinet with no file runs
on those. Copy [`config.example.json`](config.example.json) to get started.

| Key | Default | What it controls |
| --- | --- | --- |
| `attract_menu_seconds` | 120 | Idle on the menu before the attract/sleep video starts |
| `attract_game_seconds` | 300 | Idle while a game is being played before attract starts |
| `idle_kill_seconds` | 1800 | Idle before a running or held game is force-closed |
| `keymap_reload_seconds` | 2.2 | Wait for the remap service to pick up a new keymap before a game starts |
| `close_grace_seconds` | 2.0 | Grace between `SIGTERM` and `SIGKILL` when closing a game |
| `send_pause_delay_seconds` | 0.25 | Delay after resuming a game before "Send pause" injects the white press |
| `failed_message_seconds` | 15 | How long a "could not start" message waits before returning to the grid |
| `hard_reset_seconds` | 5 | How long the white button must be held to hard-reset (close any game + restart the launcher) |

Each value must be a positive number. Anything missing, mistyped, or out of
range falls back to its default and is shown as a `config:` problem on the grid
(and logged), rather than stranding the cabinet. Only the keys above are
recognised; any other key is reported and ignored.

## Attract mode

A looping, silent idle video plays after `attract_menu_seconds` on the menu, or
`attract_game_seconds` while a game is being played (so a player thinking about
a puzzle is not yanked out after two minutes) - either way pulled from
`~/Nextcloud/Arcade/attract.ogv` (override with `--attract-video` /
`ARCADE_ATTRACT_VIDEO`), Ogg Theora only, since that is all Godot 4 decodes.
A missing or unreadable file falls back to a built-in static screen. Content
is specified in `screensaver-brief.md`.

Pressing any button always wakes it back to the launcher - the menu, or the
held-menu if a game is parked - never back into a game. If a game was
running when attract started, it stays alive, held, in the background.

## Idle kill

After `idle_kill_seconds` (30 minutes by default) with no input at all,
whatever game is running or held is killed, so the cabinet does not run
unattended overnight. Nothing else
happens at that mark: no display blanking, and the attract video (if already
looping) keeps looping right through it.

## Analytics

Every game session is recorded into `~/Nextcloud/Arcade/analytics/` (override
with `--analytics-dir` / `ARCADE_ANALYTICS_DIR`), beside `config.json` and the
attract video - so the data leaves the cabinet by the same route games arrive
on it. No server and no network code. The folder is created on first write.

```
~/Nextcloud/Arcade/analytics/
├── 2026-09.jsonl   one JSON object per line, rotated monthly
└── summary.txt     plain-text totals, rewritten after every session
```

`summary.txt` is the one to read: plays per game, total plays, typical session
length, how sessions ended, and a "needs attention" block listing games that
failed to launch or that players keep pausing out of. It is derived from the
JSONL on every session close, so it can be deleted at any time and will be
rebuilt from the logs.

The JSONL is the detail underneath it - two lines per session:

```json
{"time":"2026-09-01T18:22:04Z","uptime_ms":19834,"boot":"a3f1c2","event":"game_open","game":"neon-drift","name":"Neon Drift"}
{"time":"2026-09-01T18:28:56Z","uptime_ms":431201,"boot":"a3f1c2","event":"game_close","game":"neon-drift","name":"Neon Drift","reason":"quit","exit_code":0,"wall_seconds":412.3,"active_seconds":388.1,"hold_count":1}
```

`wall_seconds` is how long the game was open; `active_seconds` subtracts every
stretch it spent frozen in the background behind the system overlay or the
attract loop (see "Held games"), so it is the real playtime. `hold_count` is
how many times that happened. `uptime_ms` and `boot` order events within a run
even if the clock jumps when NTP settles after boot.

`reason` is the useful field - how the session ended:

| `reason` | What happened |
| --- | --- |
| `quit` | The game exited on its own. On a cabinet, the player chose to leave |
| `exited_nonzero` | Exited with an error code |
| `crashed_early` | Started, then died inside the crash window |
| `launch_failed` | Never ran: bad keymap, or the binary would not execute |
| `closed_from_overlay` | Closed from the white-button menu |
| `replaced` | Closed to make room for a different game |
| `idle_killed` | Reaped by the idle kill - nobody was there |
| `vanished` | A held game's process disappeared on its own |
| `hard_reset` | Open when the white button forced a restart |
| `launcher_exit` | Open when the launcher quit for any other reason |

A `game_open` with no matching `game_close` means the cabinet lost power
mid-session; the summary skips those rather than guessing at them.

Recording can never take the cabinet down. A folder that cannot be written
disables logging for the run and reports itself on the amber problem strip
alongside scan and config trouble.

## Cursor hiding

There is no mouse during arcade play, but one may still get plugged in for
maintenance, so none of this blinds the desktop session permanently. It takes
two settings, because a cursor on screen can come from two different places.

**Cursors a client draws.** `setup-arcade.sh` installs a fully transparent
Xcursor theme (`arcade-blank`) for the arcade user; only
`XCURSOR_THEME=arcade-blank` in the launcher's own environment (and every
game's, inherited through it) points at it. A file manager or terminal opened
from the normal desktop session never sees that variable and keeps the
system's normal cursor. See `setup-arcade.sh`'s "cursor hiding" section for
why this was chosen over routing games through a nested compositor such as
Gamescope (tried once, reverted; see git history).

**The cursor KWin draws itself.** The theme above cannot touch this one, and on
Wayland the compositor owns the pointer until a surface claims it — so from the
moment a game's window is mapped until the game gets far enough into its own
startup to set a cursor for it, KWin renders its default arrow. That gap is the
arrow that used to flash on screen on every launch. No client-side setting can
reach it: not the theme, and not Godot's `MOUSE_MODE_HIDDEN` in
`scripts/main.gd`, which only ever applied to the launcher's own window.

KWin's built-in **Hide Cursor** effect (Plasma 6.2+) is the one thing that can.
`setup-arcade.sh` enables it and sets a five second inactivity timeout, so the
compositor stops rendering a pointer at all after five seconds with no real
pointer input — on a cabinet with no mouse, that means a few seconds after
login and then forever, covering the mapping gap that nothing else could. It
does not blind maintenance the way the session-wide cursor theme an earlier
version of the script set did: the cursor returns the instant a plugged-in
mouse moves, and only fades again after the same few seconds of it sitting
still. Cabinet buttons cannot bring it back — keyboard input in that effect
only ever hides the cursor, never shows it.

## Window activation

Showing the system overlay over a running game means the launcher has to raise
its own window. **That is a compositor policy decision, not something the
launcher can do on its own**, and getting it wrong is invisible from inside the
application — which is what made the "white button freezes the game but the
overlay never appears" bug so hard to place.

KWin's *focus stealing prevention* does not let an application activate itself.
It does not fail the request either: it downgrades it to a "demands attention"
hint, so the window stays exactly where it was and its task manager entry glows
orange. Everything else in the path works — the gate blocks, the game takes its
`SIGSTOP`, the overlay opens — on a window that is never brought forward.

`setup-arcade.sh` turns it off for the arcade user:

```
kwriteconfig6 --file kwinrc --group Windows --key FocusStealingPreventionLevel 0
```

Off wholesale rather than via a per-window rule: this is a single-purpose
kiosk, the launcher *is* the shell, and there is no other application whose
focus needs protecting from it. KDE's default is `1` ("Low"), which is what to
restore if it ever needs undoing.

**The tell:** the launcher's task manager entry glows orange when white is
pressed, and manually alt-tabbing to the launcher once makes the overlay work
for the rest of the session — a user-initiated activation is the one kind
focus stealing prevention always allows.

### Launching minimizes nothing; resuming minimizes

Getting out of a game's way is two different problems depending on whether the
game's window already exists, and the launcher treats them separately.

**Launching** (`GameLauncher.go_to_background()`) does not minimize. The game
maps a brand new fullscreen window, which the compositor stacks on top and
activates on its own — guaranteed, since focus stealing prevention is set to
"none", where new windows always activate. Minimizing here would unmap the
launcher *before* the game has drawn anything, leaving the bare desktop on
screen for the second or so the game takes to come up. Staying put means the
player keeps looking at the launcher until the game replaces it.

**Resuming** (`GameLauncher.reveal_resumed_game()`) does minimize, and has to.
Resuming a held game or picking Continue in the system overlay only sends
`SIGCONT` — that thaws the process but re-maps and re-activates nothing, and
the launcher was deliberately raised above the game's window to show the
overlay in the first place. Without the minimize, Continue leaves the grid
sitting on top of a running, invisible game. Here minimizing is free: the
game's window is already mapped directly underneath, so it is what appears the
instant the launcher goes away — no gap, no desktop flash.

That a client cannot un-minimize itself on Wayland (`xdg-shell` has
`xdg_toplevel.set_minimized` and no matching unset) does not matter: the
compositor restores the window as part of honouring the activation request,
which is exactly what focus stealing prevention being off buys.

`main.gd` logs the display backend at startup (`display server=… session=…`).
Check it first if window behaviour is ever in question, since none of the X11
escape hatches — `wmctrl`, `_NET_WM_STATE_ABOVE`, self-raising — exist under
Wayland.

## Development

The launcher can run on a desktop against fake games. Paths are overridable:

```bash
godot --path . -- --no-fullscreen --games-dir=dev/games --keymap-path=/tmp/keymap.json
```

`--games-dir`, `--keymap-path`, `--attract-video`, `--config-path`,
`--analytics-dir` and `--no-fullscreen` also read from `ARCADE_GAMES_DIR`,
`ARCADE_KEYMAP_PATH`, `ARCADE_ATTRACT_VIDEO`, `ARCADE_CONFIG_PATH` and
`ARCADE_ANALYTICS_DIR`. Point `--analytics-dir` somewhere temporary on a dev
box so test runs do not land in the real log; sessions started with
`--simulate-launch` are tagged `"simulated": true` and are ignored by the
summary either way.

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
| `scripts/analytics.gd` | Per-session open/close event log (autoload `Analytics`) |
| `scripts/analytics_summary.gd` | Renders `summary.txt` from those logs |
| `scripts/session_controller.gd` | State machine for the system overlay, attract mode, held games |
| `scripts/system_overlay.gd`, `scripts/attract_screen.gd` | The two on top of everything else |
| `scripts/volume_control.gd` | System volume/mute via `wpctl`/`pactl` |
| `scripts/main.gd` | Grid, navigation, the launch takeover and the running tile's mark, volume HUD |
| `scenes/` | `main.tscn`, `game_card.tscn`, `system_overlay.tscn`, `attract.tscn` |
| `scripts/setup-arcade.sh` | One-time cabinet permissions, keymap seed, cursor hiding, KWin settings |
| `scripts/install-cabinet.sh` | Runs setup, shanwan-remap install, the build, and the service in order |
| `scripts/install-git-hooks.sh`, `.ps1` | Enables the build-number pre-commit hook |
| `systemd/` | User unit and install notes |
| `theme/fonts/` | Handjet font variations used by the UI |
| `assets/fonts/` | Bundled Handjet variable font and its license |

## Credits

UI text is set in [Handjet](https://github.com/rosettatype/Handjet), licensed
under the SIL Open Font License 1.1 (see `assets/fonts/OFL.txt`).
