class_name GameLauncher
extends Node
## Owns the launch -> play -> return cycle for one game at a time, plus
## freezing it in the background (held) instead of ending the session.
##
## Normal sequence:
##   1. install the game's keymap.json at Cfg.keymap_path
##   2. wait out the remap service's reload window
##   3. start the executable and step out of the way (covered, near-idle)
##   4. poll until the process is gone
##   5. restore the launcher's own keymap and come back to the foreground
##
## SessionController (see session_controller.gd) is the only caller and owns
## the surrounding sequencing - gating physical input through Bus.set_mode()
## before freeze()/hold() and after thaw()/resume_held(), so nothing queued
## on the game's controller fd replays the instant it resumes. GameLauncher
## itself only touches the process; it never touches the control channel.
##
## One nuance left to SessionController: closing a *held* game to make room
## for a different selection (see hold()) still runs through close_held(),
## which still fires `finished`/`failed` once the process actually exits.
## That is convenient for keymap/state cleanup (see _poll_process()) but
## means a caller that is about to launch a different game right afterwards
## should not also run whatever UI transition normally accompanies "a game
## session ended", or the two will visibly collide.

signal preparing(game: GameEntry)
signal started(game: GameEntry)
## The game ran and is now gone. `exit_code` is -1 when it could not be read.
signal finished(game: GameEntry, exit_code: int)
## The game never got as far as running, or died on the launch pad.
signal failed(game: GameEntry, reason: String)
## A *held* game's process disappeared on its own - the compositor or the
## OOM killer took it, not a deliberate close_held(). Survivable: state is
## already cleared by the time this fires, same as finished/failed.
signal held_game_vanished(game: GameEntry)

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

## Grace period between SIGTERM and SIGKILL when closing a game outright.
const CLOSE_GRACE_SECONDS := 2.0

var is_busy: bool:
	get: return _current != null

## True while the current game's process exists but is frozen (SIGSTOP'd)
## and parked in the background - see hold(). The poll timer keeps running
## the whole time, so a held game that disappears on its own is still
## noticed (held_game_vanished) rather than silently forgotten.
var is_held: bool:
	get: return _held

## The held game, or null if nothing is held. Distinct from is_busy, which
## is also true for a game that is actually running in the foreground.
var held_game: GameEntry:
	get: return _current if _held else null

var _current: GameEntry = null
var _pid: int = -1
var _started_at_msec: int = 0
var _poll_timer: Timer
var _simulated_can_finish := false
var _held := false
## Set by close()/close_held() before signalling the process, so the poll
## loop can tell a deliberate shutdown apart from a held game that vanished
## on its own (see held_game_vanished).
var _closing := false


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
	go_to_background()

	var pid := OS.create_process(_process_path(game), _process_arguments(game))
	if pid < 0:
		return_to_foreground()
		_fail("cannot execute %s" % game.executable)
		return

	_pid = pid
	_started_at_msec = Time.get_ticks_msec()
	_poll_timer.start()
	started.emit(game)


## Games expect to run with their own folder as the working directory (that is
## where their pck and assets live), but OS.create_process always inherits ours.
## On Linux a tiny shell wrapper fixes that; `exec` means the pid we poll is the
## game itself rather than a shell that outlives it.
func _process_path(_game: GameEntry) -> String:
	return "/bin/sh" if OS.has_feature("linux") else _game.executable


func _process_arguments(game: GameEntry) -> PackedStringArray:
	if not OS.has_feature("linux"):
		return game.args

	const SCRIPT := "cd -- \"$1\" || exit 127\nexe=\"$2\"\nshift 2\nexec \"$exe\" \"$@\""
	var argv := PackedStringArray(["-c", SCRIPT, "arcade-launcher", game.dir_path, game.executable])
	argv.append_array(game.args)
	return argv


## OS.is_process_running() is true for a stopped-but-not-exited process too
## (SIGSTOP does not end it), so polling needs no special case for a held
## game: this only ever fires once the process has actually gone away,
## whether that is a normal exit, a deliberate close(), or a held game that
## vanished on its own.
func _poll_process() -> void:
	if _pid < 0 or OS.is_process_running(_pid):
		return

	_poll_timer.stop()
	var exit_code := OS.get_process_exit_code(_pid)
	var ran_for_msec := Time.get_ticks_msec() - _started_at_msec
	var game := _current
	var was_held := _held
	var was_closing := _closing

	_pid = -1
	_current = null
	_held = false
	_closing = false

	if was_held and not was_closing:
		apply_launcher_keymap()
		held_game_vanished.emit(game)
		return

	return_to_foreground()
	var keymap_error := apply_launcher_keymap()
	if not keymap_error.is_empty():
		push_error("[launcher] could not restore the launcher keymap: " + keymap_error)

	if ran_for_msec < int(CRASH_WINDOW_SECONDS * 1000.0) and exit_code != 0:
		failed.emit(game, "%s exited immediately with code %d" % [game.name, exit_code])
	else:
		finished.emit(game, exit_code)


## Sends SIGSTOP to the game's own process. Signals the pid directly, never
## a process group: OS.create_process does not setsid, so the game shares
## the launcher's group, and `kill -STOP -<pgid>` would freeze the launcher
## along with it. A game that forks helper processes only has its main
## process frozen - a documented limitation, not a bug, for the
## single-binary indie builds GAME_SUBMISSION.md asks for.
func freeze() -> void:
	if _pid >= 0:
		OS.execute("kill", ["-STOP", str(_pid)])


func thaw() -> void:
	if _pid >= 0:
		OS.execute("kill", ["-CONT", str(_pid)])


## Parks the current game, frozen, in the background, and marks it held. The
## caller (SessionController) is responsible for the surrounding sequence -
## blocking physical input before this, and for bringing the launcher's own
## window back to the foreground, which this does not touch.
func hold() -> void:
	if _current == null:
		return
	freeze()
	_held = true


## Un-freezes the held game. Does not touch window mode or FPS - the caller
## is expected to bring the game back to the foreground itself, exactly as
## it would for a freshly launched one.
func resume_held() -> void:
	if not _held:
		return
	_held = false
	thaw()


## Shuts the current game down completely, whether it is running or held
## frozen, and waits for it to actually be gone - state cleanup, the keymap
## restore, and the finished/failed signal all happen before this returns,
## so a caller that awaits close_held() and then immediately launch()es a
## different game never trips launch()'s is_busy guard.
func close() -> void:
	await _terminate_current()


## Same as close(), but only acts if a game is actually held - so a caller
## that just wants to make room for a different selection can call this
## unconditionally without checking is_held first.
func close_held() -> void:
	if _held:
		await _terminate_current()


## SIGCONT before SIGTERM - a stopped process never runs its terminate
## handler - then SIGKILL after a grace period if it still has not exited.
## Polls in short slices rather than sleeping the whole grace period, since
## most games die well before it: SIGTERM is nearly always enough.
func _terminate_current() -> void:
	if _pid < 0:
		return
	_closing = true
	var pid := _pid
	OS.execute("kill", ["-CONT", str(pid)])
	OS.execute("kill", ["-TERM", str(pid)])

	var elapsed := 0.0
	while elapsed < CLOSE_GRACE_SECONDS and OS.is_process_running(pid):
		await get_tree().create_timer(0.1).timeout
		elapsed += 0.1
	if OS.is_process_running(pid):
		OS.execute("kill", ["-KILL", str(pid)])
		await get_tree().create_timer(0.1).timeout  # let it land

	# Short-circuit the poll timer rather than waiting up to
	# PROCESS_POLL_SECONDS more for it to notice on its own; _poll_process()
	# is idempotent (it no-ops once _pid has already been cleared), so it is
	# safe to call here even if the timer's own tick fires around the same
	# moment.
	_poll_process()


## Steps out of the way of a game that is about to own the screen. Public:
## also used by SessionController around the overlay/attract cycle (resuming
## into PLAYING), not just internally around the launch/return cycle.
##
## Deliberately does NOT minimize, which is what it used to do and what made
## the system overlay impossible to show over a running game. On Wayland -
## which is what the cabinet runs, KDE Plasma 6 on Bazzite - minimizing is a
## one-way door. xdg-shell has `xdg_toplevel.set_minimized` and no matching
## unset; the protocol says outright that there is no way to unset
## minimization on a surface, and no way to even ask whether it is minimized.
## Only the compositor can restore a minimized window. So the launcher
## minimized itself the moment a game started and could never bring itself
## back, no matter what return_to_foreground() tried - the overlay was being
## opened, correctly, on a window nobody could ever see again. (Freezing the
## game still worked, which is exactly why the symptom looked like a drawing
## or stacking problem rather than a window-state one.)
##
## Staying mapped is enough to get out of the way: the game maps its own
## fullscreen window and the compositor stacks it on top, covering this one,
## and a covered window is not composited. BACKGROUND_MAX_FPS already handles
## not competing for the GPU, which was the other reason to minimize.
func go_to_background() -> void:
	Engine.max_fps = BACKGROUND_MAX_FPS


## Brings the launcher back over whatever is on screen, including a game that
## was just frozen but is still mapped and still fullscreen.
##
## This only works because go_to_background() no longer minimizes: a mapped
## window can be raised, an iconified one cannot restore itself at all on
## Wayland. Manually alt-tabbing to the launcher once was the workaround for
## exactly this - it is the compositor doing the un-minimize that the client
## is not allowed to do - and alt-tabbing back into the game restacks without
## re-minimizing, which is why the overlay kept working for the rest of that
## session.
func return_to_foreground() -> void:
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
