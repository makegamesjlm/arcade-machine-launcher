extends Node
## Global paths and constants. Autoloaded as `Cfg`.
##
## Every path can be overridden at runtime so the launcher can be exercised on a
## dev machine that has neither the games dir nor /etc/shanwan-remap:
##
##   godot --games-dir=./dev/games --keymap-path=./dev/keymap.json
##
## or via the ARCADE_GAMES_DIR / ARCADE_KEYMAP_PATH environment variables.
## Command line wins over environment, environment wins over the defaults.

## Games live in the arcade user's Nextcloud folder so new titles sync onto the
## cabinet. Bazzite is an immutable ostree system with a read-only root, so a
## top-level dir like /games cannot be created there; a home path can. The
## leading ~ is expanded at runtime (see _normalize_dir).
const DEFAULT_GAMES_DIR := "~/Nextcloud/Games"
const DEFAULT_KEYMAP_PATH := "/etc/shanwan-remap/keymap.json"

## The attract-mode loop lives outside the export, next to the games, so it
## updates the same way a new game does: drop a new file in Nextcloud, no
## rebuild or redeploy. Must be Ogg Theora; Godot 4's VideoStreamPlayer
## decodes nothing else. A missing or unreadable file falls back to a
## built-in static screen (see scenes/attract.tscn) rather than showing black.
const DEFAULT_ATTRACT_VIDEO := "~/Nextcloud/Arcade/attract.ogv"

## Operator-tunable timings (see the "Operator-tunable timings" section below)
## live in a JSON file next to the attract video, so cabinet behaviour syncs and
## updates the same way games and the video do. A missing file is fine - every
## value has a sane default. See config.example.json for the documented shape.
const DEFAULT_CONFIG_PATH := "~/Nextcloud/Arcade/config.json"

## Play analytics are written into the same synced folder, so the data leaves
## the cabinet by exactly the route games arrive on it - no server and no
## network code in the launcher. Created on first write if it is not there.
## See scripts/analytics.gd.
const DEFAULT_ANALYTICS_DIR := "~/Nextcloud/Arcade/analytics"

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

## Ways shanwan-remap can expose each cabinet joystick to games.
const JOYSTICK_MODES: Array[String] = [
	"left_stick", "right_stick", "dpad",
]

## Mapping restored whenever the launcher is on screen. It has to agree with the
## joypad buttons bound in the project input map: nav_select is joypad button 0
## (A) and nav_back is button 1 (B), so the bottom-right button confirms and the
## bottom-middle button goes back.
##
## `white` is deliberately absent. It is the system button now: shanwan-remap
## never forwards it to a game in any mode (see shanwan-remap/README.md,
## "Control channel"), and the launcher itself reads it only via the control
## channel feed, not through this keymap or the project input map.
const LAUNCHER_KEYMAP := {
	"bottom_right": "A",
	"bottom_middle": "B",
	"top_right": "X",
	"top_middle": "Y",
	"top_left": "LB",
	"bottom_left": "RB",
}

## Xbox button name -> the Godot joypad button index it shows up as, on the
## virtual pad shanwan-remap creates. Used by InputRouter to translate a
## cabinet position (by way of LAUNCHER_KEYMAP) into a synthetic Godot
## joypad event while navigation is being routed around a blocked/frozen
## game, and must stay in sync with [input] in project.godot.
const XBOX_TO_JOY_BUTTON := {
	"A": JOY_BUTTON_A,
	"B": JOY_BUTTON_B,
	"X": JOY_BUTTON_X,
	"Y": JOY_BUTTON_Y,
	"LB": JOY_BUTTON_LEFT_SHOULDER,
	"RB": JOY_BUTTON_RIGHT_SHOULDER,
	"LT": JOY_BUTTON_LEFT_STICK,
	"RT": JOY_BUTTON_RIGHT_STICK,
	"Back": JOY_BUTTON_BACK,
	"Start": JOY_BUTTON_START,
	"Guide": JOY_BUTTON_GUIDE,
	"LS": JOY_BUTTON_LEFT_STICK,
	"RS": JOY_BUTTON_RIGHT_STICK,
}

## How often to check whether the running game has exited.
const PROCESS_POLL_SECONDS := 0.5

## shanwan-remap's control channel (see shanwan-remap/README.md). Loopback
## only - launcher and remapper always run on the same box.
const CONTROL_HOST := "127.0.0.1"
const CONTROL_PORT := 47811
## Must match shanwan_remap.control.PROTOCOL_VERSION. A remapper reporting a
## different version is refused overlay/attract features and surfaced as a
## problem, rather than silently misbehaving.
const CONTROL_PROTOCOL_VERSION := 1
const CONTROL_RECONNECT_SECONDS := 2.0

## Swallows the button that dismissed a full-screen surface so it can't also
## select whatever the grid happens to be focused on: the press that wakes the
## attract screen, or the one that chose Continue / Back to Launcher in the
## system overlay. Mirrors RETURN_LOCKOUT_SECONDS in game_launcher.gd.
const WAKE_LOCKOUT_SECONDS := 0.4


# --- Operator-tunable timings --------------------------------------------------
#
# These are read from config.json in the Nextcloud folder (DEFAULT_CONFIG_PATH,
# next to the attract video), so cabinet behaviour can be retuned by editing one
# synced file - no rebuild or redeploy, the same story as games and the attract
# video. Each falls back to the DEFAULT_ constant beside it when the file is
# absent, the key is missing, or the value is not a positive number; every such
# fallback is surfaced through config_problems (shown on the grid) rather than
# hidden. See config.example.json for the documented shape and _load_config().

## How long the shanwan-remap service is documented to take to pick up a new
## keymap. The launcher waits this out before starting the game so the first
## frame of gameplay already has the right mapping. Not paid while a held
## game resumes - its keymap never left, so InputRouter's mapping (which
## goes through LAUNCHER_KEYMAP, not whatever is on disk) is all that
## matters until it does.
const DEFAULT_KEYMAP_RELOAD_SECONDS := 2.2
var keymap_reload_seconds := DEFAULT_KEYMAP_RELOAD_SECONDS

## Idle thresholds. Menu (including a held-menu or an open overlay - nobody
## is actually playing in either) is short; mid-game is long, so a player
## thinking about a puzzle is not yanked out after two minutes. Idle-kill is
## independent of attract mode entirely: it fires at its own mark whether or
## not the video is already looping, and does nothing else when it does. A
## config that inverts the expected order (menu < game < kill) still loads,
## but is flagged in config_problems.
const DEFAULT_ATTRACT_MENU_SECONDS := 120.0
const DEFAULT_ATTRACT_GAME_SECONDS := 300.0
const DEFAULT_IDLE_KILL_SECONDS := 1800.0
var attract_menu_seconds := DEFAULT_ATTRACT_MENU_SECONDS
var attract_game_seconds := DEFAULT_ATTRACT_GAME_SECONDS
var idle_kill_seconds := DEFAULT_IDLE_KILL_SECONDS

## Grace period between SIGTERM and SIGKILL when closing a game outright, so a
## well-behaved game gets a moment to save and exit before it is forced.
const DEFAULT_CLOSE_GRACE_SECONDS := 2.0
var close_grace_seconds := DEFAULT_CLOSE_GRACE_SECONDS

## How long "Send pause" waits after resuming the game before injecting the
## white press, so the game is actually scheduled and reading its controller
## again rather than still waking up from SIGSTOP.
const DEFAULT_SEND_PAUSE_DELAY_SECONDS := 0.25
var send_pause_delay_seconds := DEFAULT_SEND_PAUSE_DELAY_SECONDS

## How long the "could not start <game>" screen waits for a deliberate dismissal
## before returning to the grid on its own - long enough that a failure is not
## missed, short enough that an unattended cabinet is not stranded on it.
const DEFAULT_FAILED_MESSAGE_SECONDS := 15.0
var failed_message_seconds := DEFAULT_FAILED_MESSAGE_SECONDS

## How long the white button must be held for a hard reset: closing any open
## game and quitting the launcher, which systemd restarts from a clean slate
## (see SessionController._hard_reset). Long enough not to fire on an ordinary
## press, short enough to be a deliberate "get me out of here" for an attendant.
## Also the manual "rescan games" path, since a fresh start re-scans.
const DEFAULT_HARD_RESET_SECONDS := 5.0
var hard_reset_seconds := DEFAULT_HARD_RESET_SECONDS

## The keys config.json may contain, each pointing at its default. Drives both
## the unknown-key check and the per-key fallback in _load_config().
const TIMING_DEFAULTS := {
	"keymap_reload_seconds": DEFAULT_KEYMAP_RELOAD_SECONDS,
	"attract_menu_seconds": DEFAULT_ATTRACT_MENU_SECONDS,
	"attract_game_seconds": DEFAULT_ATTRACT_GAME_SECONDS,
	"idle_kill_seconds": DEFAULT_IDLE_KILL_SECONDS,
	"close_grace_seconds": DEFAULT_CLOSE_GRACE_SECONDS,
	"send_pause_delay_seconds": DEFAULT_SEND_PAUSE_DELAY_SECONDS,
	"failed_message_seconds": DEFAULT_FAILED_MESSAGE_SECONDS,
	"hard_reset_seconds": DEFAULT_HARD_RESET_SECONDS,
}

var games_dir: String = DEFAULT_GAMES_DIR
var keymap_path: String = DEFAULT_KEYMAP_PATH
var attract_video: String = DEFAULT_ATTRACT_VIDEO
var config_path: String = DEFAULT_CONFIG_PATH
var analytics_dir: String = DEFAULT_ANALYTICS_DIR

## Anything wrong with config.json - a bad value that fell back to its default,
## an unknown key, a file that would not parse. Empty when the config is clean
## or simply absent. main.gd folds these into the on-screen problem list.
var config_problems: PackedStringArray = PackedStringArray()

## Set by --no-fullscreen, for debugging on a desktop.
var fullscreen: bool = true

## Runs the launch lifecycle without starting a platform-specific game binary.
## This is explicit rather than inferred from the OS, so real Windows exports
## can still be launched and Linux development can use the same simulator.
var simulate_launch: bool = false


func _ready() -> void:
	_apply_environment()
	_apply_command_line()
	_load_config()
	print("[cfg] games_dir=%s keymap_path=%s attract_video=%s config_path=%s analytics_dir=%s simulate_launch=%s"
		% [games_dir, keymap_path, attract_video, config_path, analytics_dir, simulate_launch])


func _apply_environment() -> void:
	var env_games := OS.get_environment("ARCADE_GAMES_DIR")
	if not env_games.is_empty():
		games_dir = env_games
	var env_keymap := OS.get_environment("ARCADE_KEYMAP_PATH")
	if not env_keymap.is_empty():
		keymap_path = env_keymap
	var env_attract := OS.get_environment("ARCADE_ATTRACT_VIDEO")
	if not env_attract.is_empty():
		attract_video = env_attract
	var env_config := OS.get_environment("ARCADE_CONFIG_PATH")
	if not env_config.is_empty():
		config_path = env_config
	var env_analytics := OS.get_environment("ARCADE_ANALYTICS_DIR")
	if not env_analytics.is_empty():
		analytics_dir = env_analytics


func _apply_command_line() -> void:
	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	for arg in args:
		if arg.begins_with("--games-dir="):
			games_dir = arg.trim_prefix("--games-dir=")
		elif arg.begins_with("--keymap-path="):
			keymap_path = arg.trim_prefix("--keymap-path=")
		elif arg.begins_with("--attract-video="):
			attract_video = arg.trim_prefix("--attract-video=")
		elif arg.begins_with("--config-path="):
			config_path = arg.trim_prefix("--config-path=")
		elif arg.begins_with("--analytics-dir="):
			analytics_dir = arg.trim_prefix("--analytics-dir=")
		elif arg == "--no-fullscreen":
			fullscreen = false
		elif arg == "--simulate-launch":
			simulate_launch = true
	games_dir = _normalize_path(games_dir)
	attract_video = _normalize_path(attract_video)
	config_path = _normalize_path(config_path)
	analytics_dir = _normalize_path(analytics_dir)


## Overlays the operator-tunable timings from config.json onto their defaults.
## Absent file: nothing to do, defaults stand (a fresh cabinet legitimately has
## no config yet). Present but broken - unparseable, not an object, a bad value:
## the launcher still comes up on defaults, with the specifics in config_problems
## so they show on the grid rather than stranding the cabinet on a hard error.
func _load_config() -> void:
	config_problems = PackedStringArray()
	# Start from the defaults every time, so this reads as "defaults, then
	# overlay the file" on every path - including the early returns below, and
	# any future re-read of a changed config, not just the single startup call.
	keymap_reload_seconds = DEFAULT_KEYMAP_RELOAD_SECONDS
	attract_menu_seconds = DEFAULT_ATTRACT_MENU_SECONDS
	attract_game_seconds = DEFAULT_ATTRACT_GAME_SECONDS
	idle_kill_seconds = DEFAULT_IDLE_KILL_SECONDS
	close_grace_seconds = DEFAULT_CLOSE_GRACE_SECONDS
	send_pause_delay_seconds = DEFAULT_SEND_PAUSE_DELAY_SECONDS
	failed_message_seconds = DEFAULT_FAILED_MESSAGE_SECONDS
	hard_reset_seconds = DEFAULT_HARD_RESET_SECONDS

	if not FileAccess.file_exists(config_path):
		return

	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(config_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		config_problems.append(
			"config at %s is not a JSON object - keeping default timings" % config_path)
		return

	for key in parsed:
		if not TIMING_DEFAULTS.has(key):
			config_problems.append("unknown config key \"%s\" - ignored" % key)

	keymap_reload_seconds = _read_seconds(parsed, "keymap_reload_seconds")
	attract_menu_seconds = _read_seconds(parsed, "attract_menu_seconds")
	attract_game_seconds = _read_seconds(parsed, "attract_game_seconds")
	idle_kill_seconds = _read_seconds(parsed, "idle_kill_seconds")
	close_grace_seconds = _read_seconds(parsed, "close_grace_seconds")
	send_pause_delay_seconds = _read_seconds(parsed, "send_pause_delay_seconds")
	failed_message_seconds = _read_seconds(parsed, "failed_message_seconds")
	hard_reset_seconds = _read_seconds(parsed, "hard_reset_seconds")

	# The values still load, but flag an inversion: idle-kill firing before an
	# attract timeout, or the menu timeout outlasting the in-game one, is almost
	# always a typo rather than an intent.
	if not (attract_menu_seconds < attract_game_seconds
			and attract_game_seconds < idle_kill_seconds):
		config_problems.append(
			("attract/idle timings are out of order (expected attract_menu < "
			+ "attract_game < idle_kill; got %s < %s < %s)")
				% [attract_menu_seconds, attract_game_seconds, idle_kill_seconds])


## Reads one timing key, keeping its default when the key is absent, non-numeric,
## or not positive. JSON has no integer/float distinction to rely on, so both are
## accepted and coerced to float.
func _read_seconds(cfg: Dictionary, key: String) -> float:
	var fallback: float = TIMING_DEFAULTS[key]
	if not cfg.has(key):
		return fallback
	var value: Variant = cfg[key]
	if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
		config_problems.append("\"%s\" must be a number - keeping %s" % [key, fallback])
		return fallback
	var seconds := float(value)
	if seconds <= 0.0:
		config_problems.append("\"%s\" must be greater than 0 - keeping %s" % [key, fallback])
		return fallback
	return seconds


## Turns a possibly-relative directory or file path into an absolute one
## without a trailing slash, so path joins (and file-existence checks) below
## stay predictable. Used for games_dir, attract_video and config_path;
## keymap_path is left alone (it is meant to point straight at
## /etc/shanwan-remap on the cabinet).
func _normalize_path(path: String) -> String:
	var result := path
	# Expand a leading ~ to the running user's home. Godot leaves it literal, and
	# it must happen before the is_relative_path check below, which would
	# otherwise treat "~/..." as relative and glue it onto res://.
	if result == "~" or result.begins_with("~/"):
		var home := OS.get_environment("HOME")
		if home.is_empty():
			home = OS.get_environment("USERPROFILE")  # dev on Windows
		if not home.is_empty():
			result = home.path_join(result.trim_prefix("~").trim_prefix("/"))
	if result.is_relative_path():
		result = ProjectSettings.globalize_path("res://").path_join(result)
	return result.simplify_path().trim_suffix("/")
