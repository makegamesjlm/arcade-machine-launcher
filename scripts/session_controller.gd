class_name SessionController
extends Node
## Single place that sequences mode/freeze/window changes for the system
## overlay, attract mode, held games, and the launch splash. Everything else - the grid, the
## launch lifecycle's own messaging - stays in main.gd; this
## owns only the states layered on top of it. The grid's RUNNING mark follows
## the game's whole life, not the screen, so it is main.gd's to clear on
## finished/failed; the one ending that never reaches those handlers
## (held_game_vanished) is cleared from here.
##
## States:
##   MENU      - the grid, nothing held, nothing playing
##   LAUNCHING - a game was just picked: the launch splash is playing while it
##               loads underneath (see _run_launch_splash)
##   PLAYING   - a game owns the screen (main.gd behind or below it)
##   OVERLAY   - the system overlay is open, over a frozen game or the menu
##   HELD_MENU - the grid is showing, with a game held frozen in the background
##   ATTRACT   - the idle video, with or without a game held behind it
##
## Invariant: the control channel's gate is BLOCKED exactly when a game
## exists and is frozen - HELD_MENU, OVERLAY-with-a-game, and
## ATTRACT-with-a-game. It is PASS in MENU, PLAYING, OVERLAY-over-the-menu,
## and ATTRACT-with-no-game. Freezing a game and
## marking it "held" (GameLauncher.hold()) always happen together here, for
## exactly the same reason: is_held is what this whole invariant and the
## one-held-game-ever rule both key off.
##
## The one exception is the launch splash (LAUNCHING), which gates a game that
## is running but not yet on screen - it is part of starting the game, not a
## parked session, so nothing is held - and keys the gate off _splash_blocking
## instead. That stays BLOCKED until the game has been revealed, so nothing
## reaches it before it can be seen.
##
## Idle.playing is centralized in _set_state(). The grid's ui-lock is not:
## main.gd still owns locking for its own plain launch/return cycle (with
## its own RETURN_LOCKOUT_SECONDS swallow timing, unrelated to any of this),
## so this only ever *adds* a lock on top - via _lock_ui()/_unlock_ui() at
## the specific transitions that need it - and main.gd's own unlock calls
## are routed through wants_ui_locked() (see main.gd's set_ui_locked) so
## they cannot undo a lock this owns, e.g. main.gd finishing its own
## post-game lockout while attract mode has since taken over the screen.

enum State { MENU, LAUNCHING, PLAYING, OVERLAY, HELD_MENU, ATTRACT }

## How long a freshly started game gets to bring up its window - noticed as it
## taking focus from the launcher - before the splash reveals it regardless.
## Counted from the click, so it only ever adds to a load that outlasts the
## splash's own animation.
const GAME_WINDOW_TIMEOUT_SECONDS := 8.0
## Frame rate while the splash plays. GameLauncher drops to a near-idle rate
## once a game starts, which would stutter the video; this is as fast as it
## plays, without competing any harder than that with the game's loading.
const SPLASH_FPS := 60
## How long the launcher's window gets to come back to the front after the
## game's new window has covered it, before the splash carries on regardless.
const SPLASH_RAISE_SECONDS := 1.0
## How long KWin gets to bring the game's window back in front of the
## launcher's after the splash before falling back to minimizing the launcher
## (see _step_aside_for_game). The splash (or its last frame) stays up meanwhile.
const GAME_RAISE_TIMEOUT_SECONDS := 2.0
## How long after stepping aside the splash (its held frame, if there was no
## wipe-out) is taken down and the launcher's background restored - long after
## the game's window has covered the launcher's (or the launcher was
## minimized), so the launcher is never drawn in between.
const SPLASH_CLEANUP_SECONDS := 1.5

var _state: int = State.MENU
## Which of MENU/PLAYING/HELD_MENU the overlay was opened from, so Continue
## and Send Pause know where to return to.
var _overlay_return_state: int = State.MENU

var _launcher: GameLauncher
var _main: Control
var _volume: VolumeControl
var _router: InputRouter

## True between a white press and its release. Set false when the hold reaches
## the hard-reset threshold, so the release it eventually gets is a no-op rather
## than also firing the tap action. See _handle_white.
var _white_held := false
## One-shot, started on every white press and stopped on release. If it ever
## fires, white was held long enough (Cfg.hard_reset_seconds) to mean a hard
## reset rather than a tap.
var _hard_reset_timer: Timer
## True while the keyboard stand-in for white (the `system_button` action, F1)
## is down. Tracked apart from _white_held so losing window focus mid-hold -
## an RDP client minimized or disconnected before the key-up arrives - can
## cancel a keyboard hold without ever touching a real white-button hold.
var _white_key_down := false
## Bumped to cancel a launch splash sequence in flight; each step of
## _run_launch_splash() checks it is still the current one after every await.
var _launch_serial := 0
## True while the launch splash has the gate BLOCKED (from the click until the
## game has been revealed - see _run_launch_splash). Kept apart from GameLauncher.is_held
## on purpose: a held game is a parked session (Analytics counts each one, and
## leaves the time out of playtime), and a splash is not.
var _splash_blocking := false

@onready var _overlay_ui: SystemOverlay = %SystemOverlay
@onready var _attract_ui: AttractScreen = %AttractScreen
@onready var _splash: SplashScreen = %SplashScreen


func _ready() -> void:
	_router = InputRouter.new()
	add_child(_router)

	_hard_reset_timer = Timer.new()
	_hard_reset_timer.one_shot = true
	_hard_reset_timer.timeout.connect(_on_hard_reset_due)
	add_child(_hard_reset_timer)

	Bus.button.connect(_on_bus_button)
	Idle.attract_due.connect(_on_attract_due)
	Idle.kill_due.connect(_on_kill_due)

	_overlay_ui.item_activated.connect(_on_overlay_item)
	_attract_ui.woken.connect(_on_attract_woken)


## Wires this to the GameLauncher, root Control, and VolumeControl main.gd
## already owns. Must be called once, right after all three exist.
func bind(launcher: GameLauncher, main: Control, volume: VolumeControl) -> void:
	_launcher = launcher
	_main = main
	_volume = volume
	_launcher.started.connect(_on_game_started)
	_launcher.finished.connect(_on_game_ended)
	_launcher.failed.connect(_on_game_ended)
	_launcher.held_game_vanished.connect(_on_held_game_vanished)


## Called by main.gd instead of GameLauncher.launch() directly, so it can
## resume a held game or make room by closing a different one - only one is
## ever held, so a public cabinet can never be un-startable by someone who
## does not understand what the grid's RUNNING mark means.
func request_play(game: GameEntry, simulated_outcome: int = GameLauncher.SimulatedOutcome.SUCCESS) -> void:
	if _launcher.is_held and _launcher.held_game.id == game.id:
		_resume_held_game()
		return
	if _launcher.is_held:
		Analytics.note_close_reason(Analytics.REASON_REPLACED)
		await _launcher.close_held()
		Bus.set_mode(Bus.MODE_PASS)
	if runs_launch_splash():
		_run_launch_splash(game, simulated_outcome)
	else:
		_launcher.launch(game, simulated_outcome)


# --- entering / leaving PLAYING --------------------------------------------

## Whether a game that starts now gets the launch splash. A simulated game has
## no window for it to reveal.
func runs_launch_splash() -> bool:
	return _splash.is_ready and not Cfg.simulate_launch


func _on_game_started(_game: GameEntry) -> void:
	if _state == State.LAUNCHING:
		# The splash is already playing (_run_launch_splash()), and the game is
		# loading under it. Keep the video smooth rather than at the near-idle
		# rate GameLauncher just dropped to.
		Engine.max_fps = SPLASH_FPS
		return
	_set_state(State.PLAYING)


## Covers both finished(game, exit_code) and failed(game, reason) - only the
## state transition matters here; main.gd's own handlers show the actual
## finished/failed messaging. A game gone mid-splash (or before the splash's
## cleanup) takes the splash down with it, or the launcher would come back
## covered by it.
func _on_game_ended(_game, _detail = null) -> void:
	_cancel_launch_splash()
	if _state == State.PLAYING or _state == State.LAUNCHING:
		_set_state(State.MENU)


# --- the launch splash -------------------------------------------------------

## Launches `game` behind the splash, so the player sees the splash the
## instant they pick a game and the game loads while it plays:
##
##   1. the splash starts over the grid, input to the game is gated, and the
##      game's keymap is written and its process started straight away -
##      no "Applying controller mapping" card, no waiting out the remapper's
##      reload window first (the gate covers that; see below)
##   2. whenever the game's window comes up (focus leaves the launcher - the
##      compositor activates every new window), the launcher's is raised back
##      over it, so the game keeps loading underneath, unseen
##   3. the splash's middle stretch keeps looping until the window has come up
##      (or GAME_WINDOW_TIMEOUT_SECONDS from the click has passed), and for at
##      least long enough to make the splash Cfg.splash_seconds long; then it
##      plays on to its last opaque frame (SplashScreen.finish_loop()) - a game
##      quicker than that never waits, a slower one is still covered
##   4. with the game underneath, the launcher's background is hidden and the
##      wipe-out plays, uncovering it; then its window is brought back in
##      front of the launcher's (_step_aside_for_game) for input focus
##
## The game is never frozen: it runs from the start, so it is ready when it
## is revealed. Its input stays gated (_splash_blocking) until it is fully
## revealed, and never for less than Cfg.keymap_reload_seconds after its keymap
## was written, so it never sees the launcher's mapping.
##
## Anything that ends the game meanwhile cancels this (see _on_game_ended);
## nothing else can start in LAUNCHING, since white, attract and the grid all
## ignore it.
func _run_launch_splash(game: GameEntry, simulated_outcome: int) -> void:
	_launch_serial += 1
	var serial := _launch_serial

	Bus.set_mode(Bus.MODE_BLOCKED)
	_splash_blocking = true
	_set_state(State.LAUNCHING)
	Engine.max_fps = SPLASH_FPS
	_splash.play()

	var clicked_msec := Time.get_ticks_msec()
	var watch_focus := get_window().has_focus()
	if not watch_focus:
		push_warning("[session] launcher was not focused at launch; cannot see the game's "
			+ "window arrive, so the splash loops for up to %ss" % GAME_WINDOW_TIMEOUT_SECONDS)
	# Not awaited: with no reload wait it runs straight through to started (or
	# failed) on the spot.
	_launcher.launch(game, simulated_outcome, false)
	if serial != _launch_serial:
		return  # it failed on the pad; _on_game_ended took the splash down

	# Steps 2-3: the animation loops while the game loads.
	var window_up := false
	var window_deadline := clicked_msec + int(GAME_WINDOW_TIMEOUT_SECONDS * 1000.0)
	while serial == _launch_serial:
		if window_up or Time.get_ticks_msec() >= window_deadline:
			_splash.finish_loop()  # only the first call counts
			if not _splash.is_playing:
				break  # on its last opaque frame now
		if watch_focus and not get_window().has_focus():
			window_up = true
			await _raise_over_game(serial)
		else:
			await get_tree().process_frame
	if serial != _launch_serial:
		return
	if not window_up:
		push_warning("[session] %s did not bring up a window within %ss; revealing it anyway"
			% [game.name, GAME_WINDOW_TIMEOUT_SECONDS])
		_launcher.return_to_foreground()  # in case it came up without taking focus
		Engine.max_fps = SPLASH_FPS

	# Step 4: the game is directly under the launcher's window now.
	_main.set_background_visible(false)
	_splash.play_outro()  # no-op without a wipe-out: the held frame stays up
	await _splash.wait_until_done()
	if serial != _launch_serial:
		return
	await _step_aside_for_game(serial)
	if serial != _launch_serial:
		return

	if not game.keymap.is_empty():
		var reload_left := clicked_msec + int(Cfg.keymap_reload_seconds * 1000.0) - Time.get_ticks_msec()
		if reload_left > 0:
			await get_tree().create_timer(reload_left / 1000.0).timeout
			if serial != _launch_serial:
				return
	Bus.set_mode(Bus.MODE_PASS)
	_splash_blocking = false
	_set_state(State.PLAYING)

	await get_tree().create_timer(SPLASH_CLEANUP_SECONDS).timeout
	if serial != _launch_serial:
		return
	_splash.dismiss()
	_main.set_background_visible(true)


## The game's window has just come up over the launcher's, mid-splash: raises
## the launcher's back over it and waits (briefly) for that to land, so the
## caller does not mistake the same arrival for a second one.
func _raise_over_game(serial: int) -> void:
	_launcher.return_to_foreground()
	Engine.max_fps = SPLASH_FPS  # return_to_foreground() lifts the cap entirely
	var deadline := Time.get_ticks_msec() + int(SPLASH_RAISE_SECONDS * 1000.0)
	while (serial == _launch_serial and not get_window().has_focus()
			and Time.get_ticks_msec() < deadline):
		await get_tree().process_frame
	if serial == _launch_serial and not get_window().has_focus():
		push_warning("[session] could not bring the launcher back over the game's window "
			+ "within %ss" % SPLASH_RAISE_SECONDS)


## Puts the game's window back in front of the launcher's. Preferably by having
## KWin activate the game (GameLauncher.activate_game_window()), which leaves
## the launcher mapped directly underneath - so when the game later quits, the
## launcher is already there, not the desktop. Confirmed by the launcher's
## window losing focus; if that does not happen within GAME_RAISE_TIMEOUT_SECONDS
## (no gdbus, not a KWin session, the script failed), falls back to minimizing
## the launcher the way Continue does (reveal_resumed_game()), which always
## works but shows the desktop for a moment when the game quits.
func _step_aside_for_game(serial: int) -> void:
	# Focus is how success is noticed, so without it there is nothing to watch.
	if get_window().has_focus() and _launcher.activate_game_window():
		var deadline := Time.get_ticks_msec() + int(GAME_RAISE_TIMEOUT_SECONDS * 1000.0)
		while (serial == _launch_serial and get_window().has_focus()
				and Time.get_ticks_msec() < deadline):
			await get_tree().process_frame
		if serial != _launch_serial:
			return
		if not get_window().has_focus():
			_launcher.go_to_background()  # under the game now; just stop drawing
			return
		push_warning("[session] KWin did not bring the game's window forward within %ss; "
			% GAME_RAISE_TIMEOUT_SECONDS + "minimizing the launcher instead")
	_launcher.reveal_resumed_game()


## Stops a launch splash sequence wherever it is and takes the splash down.
## Safe to call when none is running.
func _cancel_launch_splash() -> void:
	_launch_serial += 1
	_splash.dismiss()
	_main.set_background_visible(true)
	if _splash_blocking:
		_splash_blocking = false
		Bus.set_mode(Bus.MODE_PASS)


func _on_held_game_vanished(_game: GameEntry) -> void:
	# The only death that never reaches main.gd's finished/failed handlers, so
	# the tile it left saying RUNNING has to be cleared from here.
	_main.set_running_game(null)
	# Re-derive _router.active either way: is_held just went false, and
	# _set_state() is the only thing that re-reads it (see _gate_is_blocked).
	_set_state(State.MENU if _state != State.ATTRACT else State.ATTRACT)


func _resume_held_game() -> void:
	var game := _launcher.held_game  # cleared by resume_held() below
	_launcher.resume_held()
	Bus.set_mode(Bus.MODE_PASS)
	_main.set_running_game(game)  # already marked; this restores the note too
	_launcher.reveal_resumed_game()  # its window is already there, behind ours
	_set_state(State.PLAYING)
	_lock_ui()  # no launch() call happens here, so nothing else will


# --- the white button --------------------------------------------------------

## White is the system button (long-press aside, see _handle_white); every other
## button only matters here for waking attract mode - "PRESS ANY BUTTON TO
## BEGIN". Both arrive on the control-channel feed whether or not a game has the
## controller, so this works in the launcher and in a game alike.
func _on_bus_button(_pad: int, pos: String, _xbox_name, pressed: bool) -> void:
	if pos == "white":
		_handle_white(pressed)
		return
	if pressed and _state == State.ATTRACT:
		_on_attract_woken()


## A quick white tap does the state-dependent thing (open/continue the overlay,
## or wake attract); holding it for Cfg.hard_reset_seconds is a hard reset. So
## the tap fires on *release*, and only if the hold never reached the reset
## threshold - otherwise every reset-hold would flash the overlay open first,
## and, from PLAYING, needlessly freeze the game a moment before killing it.
func _handle_white(pressed: bool) -> void:
	if pressed:
		_white_held = true
		_hard_reset_timer.start(Cfg.hard_reset_seconds)
	elif _white_held:
		_white_held = false
		_hard_reset_timer.stop()
		_on_white_tap()


## Keyboard stand-in for white, for testing over remote desktop where no
## cabinet button can be pressed. F1 drives the exact same tap/hold logic as
## the real button. It only reaches Godot while the launcher window has focus,
## so unlike the real white it cannot interrupt a running game. Key repeat is
## ignored: an echoed press would restart the hard-reset timer every few
## frames and a hold would never reach it.
func _input(event: InputEvent) -> void:
	if event.is_action_pressed("system_button"):
		_white_key_down = true
		_handle_white(true)
	elif event.is_action_released("system_button") and _white_key_down:
		_white_key_down = false
		_handle_white(false)
	else:
		return
	get_viewport().set_input_as_handled()


## A key-up lost to a focus change would otherwise leave the hard-reset timer
## running and quit the launcher a few seconds later. Cancels the hold
## outright - neither a tap nor a reset.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT and _white_key_down:
		_white_key_down = false
		_white_held = false
		_hard_reset_timer.stop()


func _on_white_tap() -> void:
	if _state == State.ATTRACT:
		_on_attract_woken()
		return
	# LAUNCHING is deliberately not handled: the overlay would fight the splash
	# sequence over the game's freeze and the launcher's window.
	match _state:
		State.PLAYING, State.MENU, State.HELD_MENU:
			_open_overlay(_state)
		State.OVERLAY:
			_continue_overlay()


func _on_hard_reset_due() -> void:
	_white_held = false  # so the release still to come is a no-op, not a tap
	_hard_reset()


## Quits the launcher. On the cabinet it runs as a systemd user service with
## Restart=always and KillMode=control-group (see systemd/arcade-launcher.service),
## so quitting restarts it from a clean slate and takes any running game - a
## child in the same cgroup - down with it: a full hard reset from one held
## button, in the launcher or mid-game. It doubles as the manual "rescan games"
## action, since the fresh start re-scans. Off the cabinet (dev) there is no
## systemd to bring it back; it simply exits.
func _hard_reset() -> void:
	print("[session] hard reset: white held %ss - quitting for a clean restart"
		% Cfg.hard_reset_seconds)
	# Any open game dies with us in the cgroup, so its exit is never collected
	# and no finished/failed signal is coming. Recorded here, before the quit,
	# rather than left to teardown - see Analytics.close_open_session().
	Analytics.close_open_session(Analytics.REASON_HARD_RESET)
	get_tree().quit()


# --- the system overlay -------------------------------------------------------

## Hides the launcher's own opaque background exactly when a running game
## was just frozen for this - see main.gd's set_background_visible() doc
## comment for why that is the only case that needs it. Restored to visible
## by _close_overlay_ui() the moment the overlay closes, on every path.
func _open_overlay(from_state: int) -> void:
	_overlay_return_state = from_state
	if from_state == State.PLAYING:
		_cancel_launch_splash()  # its held frame may not be cleaned up yet
		Bus.set_mode(Bus.MODE_BLOCKED)
		_launcher.hold()
		_launcher.return_to_foreground()
		_main.set_background_visible(false)
	_lock_ui()  # already locked if from_state == PLAYING; freshly locked otherwise
	var context: int = (SystemOverlay.Context.PLAYING if from_state == State.PLAYING
		else (SystemOverlay.Context.MENU_HELD if _launcher.is_held else SystemOverlay.Context.MENU_IDLE))
	_overlay_ui.open(context)
	_refresh_volume_readout()
	_set_state(State.OVERLAY)


func _continue_overlay() -> void:
	_close_overlay_ui()
	if _overlay_return_state == State.PLAYING:
		_resume_for_playing()
	else:
		# MENU or HELD_MENU - the grid is the surface again, but not instantly
		# interactive: the very nav_select that chose Continue must not also land
		# on the grid and launch whatever tile is focused. See _swallow_then_unlock.
		_set_state(_overlay_return_state)
		_swallow_then_unlock()


func _resume_for_playing() -> void:
	var game := _launcher.held_game  # cleared by resume_held() below
	_launcher.resume_held()
	Bus.set_mode(Bus.MODE_PASS)
	_main.set_running_game(game)  # already marked; this restores the note too
	_launcher.reveal_resumed_game()  # its window is already there, behind ours
	_set_state(State.PLAYING)


func _on_overlay_item(item: int) -> void:
	match item:
		SystemOverlay.Item.CONTINUE:
			_continue_overlay()
		SystemOverlay.Item.SEND_PAUSE:
			_send_pause()
		SystemOverlay.Item.BACK_TO_LAUNCHER:
			_back_to_launcher()
		SystemOverlay.Item.CLOSE_GAME:
			_close_game()
		SystemOverlay.Item.SLEEP:
			_enter_attract()
		SystemOverlay.Item.MUTE:
			_apply_volume(_volume.toggle_mute())
		SystemOverlay.Item.VOLUME_DOWN:
			_apply_volume(_volume.change(-1))
		SystemOverlay.Item.VOLUME_UP:
			_apply_volume(_volume.change(1))


func _apply_volume(state: Dictionary) -> void:
	var muted: bool = state.get("muted", false)
	var percent := int(round(float(state.get("volume", 0.0)) * 100.0))
	_overlay_ui.set_volume_readout(("MUTED " if muted else "") + "%d%%" % percent)


func _refresh_volume_readout() -> void:
	_apply_volume(_volume.read())


## Resumes the game and unblocks the gate first, then - after a short delay
## for the game to actually be scheduled and reading its controller again,
## not still waking up from SIGSTOP - injects white through whatever the
## game's own keymap currently maps it to. This is the only way white ever
## reaches a game.
func _send_pause() -> void:
	_close_overlay_ui()
	_resume_for_playing()
	await get_tree().create_timer(Cfg.send_pause_delay_seconds).timeout
	Bus.inject("white")


## The game stays held, frozen, gate still blocked - deliberately: this is
## exactly the case where menu navigation would otherwise queue up on the
## game's controller fd and replay the instant it resumes.
func _back_to_launcher() -> void:
	_close_overlay_ui()
	# The tile keeps saying RUNNING - the game is still open, just parked in
	# the background - but the grid is the surface again, so the line under it
	# goes back to describing whatever is selected.
	_main.update_detail()
	_set_state(State.HELD_MENU)
	_swallow_then_unlock()  # same as Continue: don't let this press hit the grid


## Returns the grid to interactive, but only after a short lockout that swallows
## the very button press that dismissed the overlay. Without it, the nav_select
## that activated Continue (or Back to Launcher) keeps propagating - directly, or
## as a control-channel feed event a frame or two later - and lands on the grid,
## which reads it as "launch the focused tile". Mirrors the wake-from-attract
## swallow in _on_attract_woken, and is safe against a re-lock during the window:
## set_ui_locked(false) is vetoed by wants_ui_locked() if an overlay or attract
## has meanwhile taken the screen again.
func _swallow_then_unlock() -> void:
	await get_tree().create_timer(Cfg.WAKE_LOCKOUT_SECONDS).timeout
	_unlock_ui()


## Closing (whether the game was running or held) always fires GameLauncher's
## finished/failed signal, which drives main.gd's own overlay-fade + refresh
## + (veto-guarded) unlock - nothing further to do here for that half.
func _close_game() -> void:
	_close_overlay_ui()
	Analytics.note_close_reason(Analytics.REASON_CLOSED_FROM_OVERLAY)
	if _launcher.is_held:
		await _launcher.close_held()
	else:
		await _launcher.close()
	Bus.set_mode(Bus.MODE_PASS)
	_set_state(State.MENU)


func _enter_attract() -> void:
	_close_overlay_ui()
	_attract_ui.play()
	_set_state(State.ATTRACT)  # stays locked - already was, for the overlay


# --- attract mode --------------------------------------------------------------

func _on_attract_due() -> void:
	match _state:
		State.OVERLAY, State.ATTRACT:
			return  # already showing something on top, or already there
		State.LAUNCHING:
			return  # only seconds long; the game is about to own the screen
		State.PLAYING:
			_cancel_launch_splash()  # its held frame may not be cleaned up yet
			Bus.set_mode(Bus.MODE_BLOCKED)
			_launcher.hold()
			_launcher.return_to_foreground()
		State.MENU, State.HELD_MENU:
			pass  # gate is already right for either: pass, or blocked-and-held
	_lock_ui()  # no-op if already locked (from PLAYING); fresh lock otherwise
	_attract_ui.play()
	_set_state(State.ATTRACT)


## Always lands on the launcher - the menu, or the held-menu if a game is
## parked - never back into a game, per spec. A short lockout swallows the
## waking press so it cannot also select whatever the grid happens to focus.
func _on_attract_woken() -> void:
	_attract_ui.stop()
	_main.set_background_visible(true)
	_main.update_detail()  # the grid is the surface again - same as above
	_set_state(State.HELD_MENU if _launcher.is_held else State.MENU)
	await get_tree().create_timer(Cfg.WAKE_LOCKOUT_SECONDS).timeout
	_unlock_ui()


# --- idle kill -----------------------------------------------------------------

## Kills whatever game exists - running or held - and nothing else: no
## blanking, and if attract is already looping it keeps looping right
## through this, exactly as specified (the state check below is what keeps
## it that way - MENU is only entered if we were not already in ATTRACT).
## Closing fires GameLauncher's finished/failed signal same as _close_game()
## - main.gd's own handler does the refresh; nothing further needed here for
## the non-attract case either.
func _on_kill_due() -> void:
	if not _launcher.is_busy:
		return
	Analytics.note_close_reason(Analytics.REASON_IDLE_KILLED)
	if _launcher.is_held:
		await _launcher.close_held()
	else:
		await _launcher.close()
	Bus.set_mode(Bus.MODE_PASS)
	# Re-derive _router.active either way: is_held just went false, and
	# _set_state() is the only thing that re-reads it (see _gate_is_blocked).
	_set_state(State.MENU if _state != State.ATTRACT else State.ATTRACT)


# --- state -----------------------------------------------------------------

## The single source of truth for whether InputRouter should be synthesizing
## input at all. It must mirror the gate exactly: while the gate is `pass`
## the pad already drives Godot directly, so turning the router on too would
## fire every nav action twice (once for real, once synthesized from the
## feed, which is broadcast regardless of gate mode) - with wrapping
## navigation, a double-step in a short row looks exactly like the opposite
## direction. This used to be set ad hoc at each call site and drifted out
## of sync at least twice (opening the overlay from the menu, and returning
## from it to a still-held-menu); centralizing it here is what keeps it
## honest going forward.
func _set_state(state: int) -> void:
	_state = state
	Idle.playing = (state == State.PLAYING)
	_router.active = _gate_is_blocked()


func _gate_is_blocked() -> bool:
	match _state:
		State.HELD_MENU:
			# A game is held by definition here, so the gate is always blocked.
			return true
		State.OVERLAY, State.ATTRACT:
			# Blocked only when a game is actually frozen behind them. Opened
			# over the plain menu (no held game) the gate stays PASS - see
			# _open_overlay, which blocks it only from PLAYING - so the router
			# must stay off, or every nav action fires twice: once for real,
			# once synthesized from the feed. In the overlay's short wrapping
			# rows that double-step reads as a move in the opposite direction.
			return _launcher.is_held
		State.LAUNCHING:
			# Blocked only while the splash is still covering the game.
			return _splash_blocking
		_:
			return false


## Whether something above the grid still needs the input lock, regardless
## of what GameLauncher's own signals think - main.gd's set_ui_locked(false)
## checks this so it can never undo a lock this owns (see the class doc
## comment for why that matters).
func wants_ui_locked() -> bool:
	return _state == State.OVERLAY or _state == State.ATTRACT or _state == State.LAUNCHING


func _lock_ui() -> void:
	_main.set_ui_locked(true)


func _unlock_ui() -> void:
	_main.set_ui_locked(false)


func _close_overlay_ui() -> void:
	_overlay_ui.close()
	_main.set_background_visible(true)
