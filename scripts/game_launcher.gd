class_name GameLauncher
extends Node
## Owns the launch -> play -> return cycle for one game at a time.
##
## Sequence:
##   1. install the game's keymap.json at Cfg.keymap_path
##   2. wait out the remap service's reload window
##   3. start the executable and step out of the way (minimized, near-idle)
##   4. poll until the process is gone
##   5. restore the launcher's own keymap and come back to the foreground

signal preparing(game: GameEntry)
signal started(game: GameEntry)
## The game ran and is now gone. `exit_code` is -1 when it could not be read.
signal finished(game: GameEntry, exit_code: int)
## The game never got as far as running, or died on the launch pad.
signal failed(game: GameEntry, reason: String)

## Outcomes available to the interactive development simulator. Ignored unless
## Cfg.simulate_launch was enabled explicitly on the command line.
enum SimulatedOutcome {
	SUCCESS,
	LAUNCH_FAILURE,
	EARLY_CRASH,
}

## A game that dies faster than this almost certainly failed to start rather
## than being played and quit, so it is reported as a failure.
const CRASH_WINDOW_SECONDS := 2.0

## Frame rate to idle at while a game has the screen. The launcher stays alive
## to poll the process but must not compete for the GPU.
const BACKGROUND_MAX_FPS := 5

## Long enough for the preparing state to be visible without reproducing the
## cabinet service's full 2.2 second reload delay on every simulated launch.
const SIMULATED_PREPARE_SECONDS := 0.45
const SIMULATED_CRASH_SECONDS := 1.0

var is_busy: bool:
	get: return _current != null

var _current: GameEntry = null
var _pid: int = -1
var _started_at_msec: int = 0
var _poll_timer: Timer
var _simulated_can_finish := false


func _ready() -> void:
	_poll_timer = Timer.new()
	_poll_timer.wait_time = Cfg.PROCESS_POLL_SECONDS
	_poll_timer.timeout.connect(_poll_process)
	add_child(_poll_timer)


## Restores the launcher's own button mapping. Called on startup and after every
## game, so the cabinet buttons always drive the menu when the menu is showing.
func apply_launcher_keymap() -> String:
	return KeymapWriter.install(Cfg.LAUNCHER_KEYMAP, Cfg.keymap_path)


func launch(game: GameEntry, simulated_outcome: int = SimulatedOutcome.SUCCESS) -> void:
	if is_busy:
		push_warning("ignoring launch of %s, %s is already running" % [game.id, _current.id])
		return

	_current = game
	preparing.emit(game)

	if not game.keymap.is_empty():
		var error := KeymapWriter.install(game.keymap, Cfg.keymap_path)
		if not error.is_empty():
			_fail("could not apply the controller mapping - " + error)
			return

	if Cfg.simulate_launch:
		await get_tree().create_timer(SIMULATED_PREPARE_SECONDS).timeout
		if _current != game:
			return
		_start_simulated(game, simulated_outcome)
		return

	if not game.keymap.is_empty():
		# The service polls for changes; give it the documented window so the
		# game's first frame already sees the right buttons.
		await get_tree().create_timer(Cfg.KEYMAP_RELOAD_SECONDS).timeout
		if _current != game:
			return  # cancelled while we were waiting

	_start_process(game)


func _start_simulated(game: GameEntry, outcome: int) -> void:
	match outcome:
		SimulatedOutcome.LAUNCH_FAILURE:
			_fail("simulated launch failure: cannot execute %s" % game.executable)
		SimulatedOutcome.EARLY_CRASH:
			started.emit(game)
			await get_tree().create_timer(SIMULATED_CRASH_SECONDS).timeout
			if _current == game:
				_fail("%s exited immediately with code 1 (simulated)" % game.name)
		_:
			_simulated_can_finish = true
			started.emit(game)


## Ends a successful simulated game session. Returns true only while such a
## session is actually waiting for the developer to press Back/Escape.
func finish_simulated_session() -> bool:
	if not Cfg.simulate_launch or not _simulated_can_finish or _current == null:
		return false

	var game := _current
	_current = null
	_simulated_can_finish = false
	var keymap_error := apply_launcher_keymap()
	if not keymap_error.is_empty():
		push_error("[launcher] could not restore the launcher keymap: " + keymap_error)
	finished.emit(game, 0)
	return true


func _start_process(game: GameEntry) -> void:
	_go_to_background()

	var pid := OS.create_process(_process_path(game), _process_arguments(game))
	if pid < 0:
		_return_to_foreground()
		_fail("cannot execute %s" % game.executable)
		return

	_pid = pid
	_started_at_msec = Time.get_ticks_msec()
	_poll_timer.start()
	started.emit(game)


## Games expect to run with their own folder as the working directory (that is
## where their pck and assets live), but OS.create_process always inherits ours.
## On Linux a tiny shell wrapper fixes that and starts the game inside Gamescope,
## whose compositor can keep the cursor hidden even though the game is a separate
## process. `exec` means the pid we poll is Gamescope (or the direct fallback),
## rather than a shell that outlives it.
func _process_path(_game: GameEntry) -> String:
	return "/bin/sh" if OS.has_feature("linux") else _game.executable


func _process_arguments(game: GameEntry) -> PackedStringArray:
	if not OS.has_feature("linux"):
		return game.args

	const SCRIPT := ("cd -- \"$1\" || exit 127\n"
		+ "exe=\"$2\"\nwidth=\"$3\"\nheight=\"$4\"\nshift 4\n"
		+ "if command -v gamescope >/dev/null 2>&1; then\n"
		+ "  exec gamescope -f --expose-wayland -W \"$width\" -H \"$height\" "
		+ "-w \"$width\" -h \"$height\" --hide-cursor-delay 0 -- \"$exe\" \"$@\"\n"
		+ "fi\n"
		+ "echo '[launcher] warning: gamescope was not found; game cursor cannot be hidden' >&2\n"
		+ "exec \"$exe\" \"$@\"")
	var screen_size := DisplayServer.screen_get_size()
	var argv := PackedStringArray([
		"-c", SCRIPT, "arcade-launcher", game.dir_path, game.executable,
		str(screen_size.x), str(screen_size.y),
	])
	argv.append_array(game.args)
	return argv


func _poll_process() -> void:
	if _pid < 0 or OS.is_process_running(_pid):
		return

	_poll_timer.stop()
	var exit_code := OS.get_process_exit_code(_pid)
	var ran_for_msec := Time.get_ticks_msec() - _started_at_msec
	_pid = -1

	_return_to_foreground()
	var keymap_error := apply_launcher_keymap()
	if not keymap_error.is_empty():
		push_error("[launcher] could not restore the launcher keymap: " + keymap_error)

	var game := _current
	_current = null

	if ran_for_msec < int(CRASH_WINDOW_SECONDS * 1000.0) and exit_code != 0:
		failed.emit(game, "%s exited immediately with code %d" % [game.name, exit_code])
	else:
		finished.emit(game, exit_code)


func _go_to_background() -> void:
	Engine.max_fps = BACKGROUND_MAX_FPS
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)


func _return_to_foreground() -> void:
	Engine.max_fps = 0
	DisplayServer.window_set_mode(
		DisplayServer.WINDOW_MODE_FULLSCREEN if Cfg.fullscreen
		else DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_move_to_foreground()


func _fail(reason: String) -> void:
	var game := _current
	_current = null
	_simulated_can_finish = false
	var keymap_error := apply_launcher_keymap()
	if not keymap_error.is_empty():
		push_error("[launcher] could not restore the launcher keymap: " + keymap_error)
	failed.emit(game, reason)
