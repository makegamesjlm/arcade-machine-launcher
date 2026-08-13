# Delivering a game to the JLM arcade

Send one ZIP containing one folder for your game:

```text
neon-drift/
  game.json          required
  icon.png           recommended
  keymap.json        optional
  game.x86_64         64-bit Linux executable
  ...                 all other build files
```

Use a short folder name with lowercase letters and hyphens. Include the entire
Linux build output: executable, assets, libraries, and data directories. The
game runs with this folder as its working directory.

## `game.json`

```json
{
  "name": "Neon Drift",
  "description": "Two-player top-down racing.",
  "executable": "game.x86_64",
  "players": 2
}
```

- `executable` is required and must exactly match the filename, including case.
- `name`, `description`, and `players` are shown in the launcher. `players`
  defaults to `1`.
- Optional `args` may contain an array of command-line arguments.

## `icon.png`

- Recommended: **768 x 512 pixels**, 3:2 landscape, under 1 MB.
- Keep it readable at small size; avoid small text and fine detail.
- The filename must be exactly `icon.png`. If omitted, a placeholder is shown.

## `keymap.json` (optional)

To remap the arcade buttons, include a `keymap.json` file with the following structure:
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
The mapping above is the default, so the file can be omitted if these controls work for
your game. Add the file only if you need a different button layout.

Cabinet buttons: `top_left`, `top_middle`, `top_right`, `bottom_left`,
`bottom_middle`, `bottom_right`, `white`.

Allowed mappings: `A`, `B`, `X`, `Y`, `LB`, `RB`, `LT`, `RT`, `Back`,
`Start`, `Guide` (Xbox/Home), `LS` (left-stick click), and `RS` (right-stick
click). Do not map two cabinet buttons to the same value.

The optional top-level `joystick` key sets what each cabinet joystick reports
as. It is separate from the cabinet-button mappings above and accepts exactly
one of these values:

- `"left_stick"` — Xbox left analog stick (default; suitable for most games)
- `"right_stick"` — Xbox right analog stick
- `"dpad"` — digital d-pad, compatible with standard gamepad APIs including SDL and Unity's `Gamepad.dpad`

Omit `joystick` to retain the default `"left_stick"` behavior.

## Before sending

- Test an equivalent Windows build with an Xbox-style controller.
- Test both controllers if the game supports two players.
- Make sure the game needs no keyboard or mouse and has a clear way to exit.
- ZIP the game folder itself, not only the files inside it.
