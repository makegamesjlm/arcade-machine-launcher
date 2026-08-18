# Installing the launcher on the cabinet

Run these on the cabinet, as the user that owns the graphical session.

> For a fresh cabinet, `./scripts/install-cabinet.sh` does everything on this
> page (plus the permissions and remap-service setup) in one pass. The steps
> below are the manual equivalent, useful for rebuilding or reinstalling just
> the launcher.

## 1. Build the binary

On a machine with the Godot editor and the Linux export templates installed:

```bash
godot --headless --path . --export-release "Linux" build/arcade-launcher
```

## 2. Copy it into place

```bash
sudo install -d -m 0755 /opt/arcade-launcher
sudo install -m 0755 build/arcade-launcher /opt/arcade-launcher/arcade-launcher
sudo install -m 0644 build/arcade-launcher.pck /opt/arcade-launcher/
```

The `.pck` is only present if the export was not configured to embed it. An
embedded build is a single file and is the easier thing to ship.

## 3. Install the service

```bash
mkdir -p ~/.config/systemd/user
install -m 0644 systemd/arcade-launcher.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now arcade-launcher.service
```

## 4. Watch it

```bash
systemctl --user status arcade-launcher.service
journalctl --user -u arcade-launcher.service -f
```

Scan problems (a game folder with no `game.json`, a keymap naming a button the
remap service does not know) are printed here as warnings, and the first few
also appear in the amber strip at the bottom of the launcher screen.

## Deploying a game

Games live in `~/Nextcloud/Games`, so dropping a game folder into that Nextcloud
directory (on any synced machine) copies it onto the cabinet. Game archives will
usually have been created on Windows, so do not assume the Linux executable bit
survived. After the folder has synced, make the executable named by `game.json`
runnable:

```bash
chmod +x ~/Nextcloud/Games/neon-drift/game.x86_64
```

Keep the executable and all engine-generated data directories, shared
libraries, content packs, and other runtime files together. Then check the
installation:

```bash
test -f ~/Nextcloud/Games/neon-drift/game.json
test -x ~/Nextcloud/Games/neon-drift/game.x86_64
```

Hold the white button for a hard reset (~5s) to restart the launcher, which
re-scans the games folder on the way back up; the service itself does not need
to be restarted by hand. Launch the game
through the arcade launcher for the smoke test, then verify that it reaches
its menu, accepts both cabinet controllers as appropriate, fills the display,
shows no mouse cursor at any point, and exits cleanly back to the launcher.
Check `journalctl --user -u arcade-launcher.service` if it does not appear or
start.

While it is running, also smoke-test the system overlay itself: press white,
confirm the game's frame freezes and stays visible under the dim overlay,
that the game never sees the white press or any overlay navigation, and that
each of Continue / Send pause / Back to launcher / Close game / Sleep does
what it says (see the main README's "The white button and the system
overlay"). Confirm a game held via Back to launcher still reads RUNNING on
its grid tile and resumes instantly when reselected.

## Notes

- The unit is `PartOf=graphical-session.target`, so it starts and stops with the
  desktop session. It is not a system unit and must not be installed as one —
  it needs the session's display and its access to `/dev/input`.
- `Restart=always` makes the launcher the shell of the machine. To stop it for
  maintenance, use `systemctl --user stop arcade-launcher.service` rather than
  killing the process, or systemd will simply start it again.
- Restarting the unit while a game is running kills the game too. That is
  deliberate; see the comment in the unit file.
