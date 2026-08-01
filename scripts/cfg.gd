extends Node
## Global paths and constants. Autoloaded as `Cfg`.
##
## Every path can be overridden at runtime so the launcher can be exercised on a
## dev machine that has neither /games nor /etc/shanwan-remap:
##
##   godot --games-dir=./dev/games --keymap-path=./dev/keymap.json
##
## or via the ARCADE_GAMES_DIR / ARCADE_KEYMAP_PATH environment variables.
## Command line wins over environment, environment wins over the defaults.

const DEFAULT_GAMES_DIR := "/games"
const DEFAULT_KEYMAP_PATH := "/etc/shanwan-remap/keymap.json"

## Physical buttons on the cabinet, in the order they are laid out:
##   [top_left]    [top_middle]    [top_right]
##   [bottom_left] [bottom_middle] [bottom_right]
##   [white]
const CABINET_BUTTONS: Array[String] = [
	"top_left", "top_middle", "top_right",
	"bottom_left", "bottom_middle", "bottom_right",
	"white",
]

## Names the shanwan-remap service accepts on the right-hand side of a keymap.
const XBOX_BUTTONS: Array[String] = [
	"A", "B", "X", "Y", "LB", "RB", "LT", "RT",
	"Back", "Start", "Guide", "LS", "RS",
]

## Mapping restored whenever the launcher is on screen. It has to agree with the
## joypad buttons bound in the project input map: nav_select is joypad button 0
## (A) and nav_back is button 1 (B), so the bottom-right button confirms and the
## bottom-middle button goes back.
const LAUNCHER_KEYMAP := {
	"bottom_right": "A",
	"bottom_middle": "B",
	"top_right": "X",
	"top_middle": "Y",
	"top_left": "LB",
	"bottom_left": "RB",
	"white": "Start",
}

## How long the shanwan-remap service is documented to take to pick up a new
## keymap. The launcher waits this out before starting the game so the first
## frame of gameplay already has the right mapping.
const KEYMAP_RELOAD_SECONDS := 2.2

## How often to check whether the running game has exited.
const PROCESS_POLL_SECONDS := 0.5

var games_dir: String = DEFAULT_GAMES_DIR
var keymap_path: String = DEFAULT_KEYMAP_PATH

## Set by --no-fullscreen, for debugging on a desktop.
var fullscreen: bool = true

## Runs the launch lifecycle without starting a platform-specific game binary.
## This is explicit rather than inferred from the OS, so real Windows exports
## can still be launched and Linux development can use the same simulator.
var simulate_launch: bool = false


func _ready() -> void:
	_apply_environment()
	_apply_command_line()
	print("[cfg] games_dir=%s keymap_path=%s simulate_launch=%s"
		% [games_dir, keymap_path, simulate_launch])


func _apply_environment() -> void:
	var env_games := OS.get_environment("ARCADE_GAMES_DIR")
	if not env_games.is_empty():
		games_dir = env_games
	var env_keymap := OS.get_environment("ARCADE_KEYMAP_PATH")
	if not env_keymap.is_empty():
		keymap_path = env_keymap


func _apply_command_line() -> void:
	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	for arg in args:
		if arg.begins_with("--games-dir="):
			games_dir = arg.trim_prefix("--games-dir=")
		elif arg.begins_with("--keymap-path="):
			keymap_path = arg.trim_prefix("--keymap-path=")
		elif arg == "--no-fullscreen":
			fullscreen = false
		elif arg == "--simulate-launch":
			simulate_launch = true
	games_dir = _normalize_dir(games_dir)


## Turns a possibly-relative directory into an absolute one without a trailing
## slash, so path joins below stay predictable.
func _normalize_dir(path: String) -> String:
	var result := path
	if result.is_relative_path():
		result = ProjectSettings.globalize_path("res://").path_join(result)
	return result.simplify_path().trim_suffix("/")
