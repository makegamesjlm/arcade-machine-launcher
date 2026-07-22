# Installing the launcher on the cabinet

Run these on the cabinet, as the user that owns the graphical session.

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

## Notes

- The unit is `PartOf=graphical-session.target`, so it starts and stops with the
  desktop session. It is not a system unit and must not be installed as one —
  it needs the session's display and its access to `/dev/input`.
- `Restart=always` makes the launcher the shell of the machine. To stop it for
  maintenance, use `systemctl --user stop arcade-launcher.service` rather than
  killing the process, or systemd will simply start it again.
- Restarting the unit while a game is running kills the game too. That is
  deliberate; see the comment in the unit file.
