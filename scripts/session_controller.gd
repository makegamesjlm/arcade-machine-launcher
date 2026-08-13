class_name SessionController
extends Node
## Single place that sequences mode/freeze/window changes for the system
## overlay, attract mode, and held games. Everything else - the grid, the
## launch-progress overlay (`%Overlay` in main.tscn), the volume HUD - stays
## in main.gd; this owns only the states layered on top of it.
##
## States:
##   MENU      - the grid, nothing held, nothing playing
##   PLAYING   - a game owns the screen (main.gd minimized)
##   OVERLAY   - the system overlay is open, over a frozen game or the menu
##   HELD_MENU - the grid is showing, with a game held frozen in the background
##   ATTRACT   - the idle video, with or without a game held behind it
##
## Invariant: the control channel's gate is BLOCKED exactly when a game
## exists and is frozen - OVERLAY, HELD_MENU, and ATTRACT-with-a-game. It is
## PASS in MENU, PLAYING, and ATTRACT-with-no-game. Freezing a game and
## marking it "held" (GameLauncher.hold()) always happen together here, for
## exactly the same reason: is_held is what this whole invariant, and the
## grid's held badge, and the one-held-game-ever rule, all key off.
##
## Idle.playing is centralized in _set_state(). The grid's ui-lock is not:
## main.gd still owns locking for its own plain launch/return cycle (with
## its own RETURN_LOCKOUT_SECONDS swallow timing, unrelated to any of this),
## so this only ever *adds* a lock on top - via _lock_ui()/_unlock_ui() at
## the specific transitions that need it - and main.gd's own unlock calls
## are routed through wants_ui_locked() (see main.gd's set_ui_locked) so
## they cannot undo a lock this owns, e.g. main.gd finishing its own
## post-game lockout while attract mode has since taken over the screen.

enum State { MENU, PLAYING, OVERLAY, HELD_MENU, ATTRACT }

var _state: int = State.MENU
## Which of MENU/PLAYING/HELD_MENU the overlay was opened from, so Continue
## and Send Pause know where to return to.
var _overlay_return_state: int = State.MENU

var _launcher: GameLauncher
var _main: Control
var _volume: VolumeControl
var _router: InputRouter

@onready var _overlay_ui: SystemOverlay = %SystemOverlay
@onready var _attract_ui: AttractScreen = %AttractScreen


func _ready() -> void:
	_router = InputRouter.new()
	add_child(_router)

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
## does not understand the badge.
func request_play(game: GameEntry, simulated_outcome: int = GameLauncher.SimulatedOutcome.SUCCESS) -> void:
	if _launcher.is_held and _launcher.held_game.id == game.id:
		_resume_held_game()
		return
	if _launcher.is_held:
		await _launcher.close_held()
		Bus.set_mode(Bus.MODE_PASS)
		_main.set_held_game(null)
	_launcher.launch(game, simulated_outcome)


# --- entering / leaving PLAYING --------------------------------------------

func _on_game_started(_game: GameEntry) -> void:
	_set_state(State.PLAYING)


## Covers both finished(game, exit_code) and failed(game, reason) - only the
## state transition matters here; main.gd's own handlers show the actual
## finished/failed messaging.
func _on_game_ended(_game, _detail = null) -> void:
	if _state == State.PLAYING:
		_set_state(State.MENU)


func _on_held_game_vanished(_game: GameEntry) -> void:
	_main.set_held_game(null)
	# Re-derive _router.active either way: is_held just went false, and
	# _set_state() is the only thing that re-reads it (see _gate_is_blocked).
	_set_state(State.MENU if _state != State.ATTRACT else State.ATTRACT)


func _resume_held_game() -> void:
	_main.set_held_game(null)
	_launcher.resume_held()
	Bus.set_mode(Bus.MODE_PASS)
	_launcher.go_to_background()
	_set_state(State.PLAYING)
	_lock_ui()  # no launch() call happens here, so nothing else will


# --- the white button --------------------------------------------------------

## Any button wakes attract mode - "PRESS ANY BUTTON TO BEGIN" - but only
## white opens or continues the system overlay everywhere else.
func _on_bus_button(_pad: int, pos: String, _xbox_name, pressed: bool) -> void:
	if not pressed:
		return
	if _state == State.ATTRACT:
		_on_attract_woken()
		return
	if pos != "white":
		return
	match _state:
		State.PLAYING, State.MENU, State.HELD_MENU:
			_open_overlay(_state)
		State.OVERLAY:
			_continue_overlay()


# --- the system overlay -------------------------------------------------------

## Hides the launcher's own opaque background exactly when a running game
## was just frozen for this - see main.gd's set_background_visible() doc
## comment for why that is the only case that needs it. Restored to visible
## by _close_overlay_ui() the moment the overlay closes, on every path.
func _open_overlay(from_state: int) -> void:
	_overlay_return_state = from_state
	if from_state == State.PLAYING:
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
		_set_state(_overlay_return_state)
		_unlock_ui()  # MENU or HELD_MENU - the grid is interactive again


func _resume_for_playing() -> void:
	_launcher.resume_held()
	Bus.set_mode(Bus.MODE_PASS)
	_launcher.go_to_background()
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
		SystemOverlay.Item.REFRESH:
			_main.refresh()
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
	await get_tree().create_timer(Cfg.SEND_PAUSE_DELAY_SECONDS).timeout
	Bus.inject("white")


## The game stays held, frozen, gate still blocked - deliberately: this is
## exactly the case where menu navigation would otherwise queue up on the
## game's controller fd and replay the instant it resumes.
func _back_to_launcher() -> void:
	_close_overlay_ui()
	_main.set_held_game(_launcher.held_game)
	_set_state(State.HELD_MENU)
	_unlock_ui()


## Closing (whether the game was running or held) always fires GameLauncher's
## finished/failed signal, which drives main.gd's own overlay-fade + refresh
## + (veto-guarded) unlock - nothing further to do here for that half.
func _close_game() -> void:
	_close_overlay_ui()
	if _launcher.is_held:
		await _launcher.close_held()
	else:
		await _launcher.close()
	Bus.set_mode(Bus.MODE_PASS)
	_main.set_held_game(null)
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
		State.PLAYING:
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
	_main.set_held_game(_launcher.held_game)
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
	if _launcher.is_held:
		await _launcher.close_held()
	else:
		await _launcher.close()
	Bus.set_mode(Bus.MODE_PASS)
	_main.set_held_game(null)
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
		State.OVERLAY, State.HELD_MENU:
			return true
		State.ATTRACT:
			return _launcher.is_held
		_:
			return false


## Whether something above the grid still needs the input lock, regardless
## of what GameLauncher's own signals think - main.gd's set_ui_locked(false)
## checks this so it can never undo a lock this owns (see the class doc
## comment for why that matters).
func wants_ui_locked() -> bool:
	return _state == State.OVERLAY or _state == State.ATTRACT


func _lock_ui() -> void:
	_main.set_ui_locked(true)


func _unlock_ui() -> void:
	_main.set_ui_locked(false)


func _close_overlay_ui() -> void:
	_overlay_ui.close()
	_main.set_background_visible(true)
