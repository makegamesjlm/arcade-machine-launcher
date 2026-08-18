extends Control
## The launcher screen: scans /games, draws a centered row of games that scrolls
## sideways, and hands a chosen game to GameLauncher.

const CARD_SCENE := preload("res://scenes/game_card.tscn")
const BUILD_NUMBER_PATH := "res://BUILD_NUMBER"

## Held-direction auto-repeat. The first step fires immediately, then after a
## pause the selection walks at a steady rate - slow enough to stop on the game
## you meant on a stiff arcade stick.
const REPEAT_DELAY_SECONDS := 0.38
const REPEAT_INTERVAL_SECONDS := 0.11

## How long the row takes to slide the newly selected game to the middle.
const CAROUSEL_SLIDE_SECONDS := 0.18

## A single row now, so only left/right walk it; up/down are inert.
const NAV_ACTIONS := ["nav_left", "nav_right"]

## Buttons are often still held when a game quits back to us. Swallow input
## briefly so the release does not immediately relaunch something.
const RETURN_LOCKOUT_SECONDS := 0.6

const OVERLAY_FADE_SECONDS := 0.22

## The one word the grid ever puts on a tile. Everything earlier in a launch -
## remapping, starting - takes the whole screen instead (see _on_preparing).
const STATUS_RUNNING := "RUNNING"

## How long the volume bar lingers at full opacity after the last change before
## it fades back out, and how long that fade takes.
const VOLUME_VISIBLE_SECONDS := 1.4
const VOLUME_FADE_SECONDS := 0.22

var _games: Array[GameEntry] = []
var _cards: Array[GameCard] = []
var _selected := -1
## Seconds until the next auto-repeat step, per held nav action.
var _repeat_countdown := {}
var _scan_problems := PackedStringArray()
## Last set of problems written to the journal, so a refresh after every game
## does not reprint the same warnings forever.
var _logged_problems := PackedStringArray()
var _launcher: GameLauncher
var _session: SessionController
var _input_locked := false
var _overlay_tween: Tween
var _volume: VolumeControl
var _volume_tween: Tween
## Slides the row so the selected game sits centered; killed and restarted on
## each move. See _center_selected.
var _row_tween: Tween
## Half-viewport-wide fillers on each end of the row, so the first and last
## games can still slide to the middle. Rebuilt with the cards; widths tracked
## on resize. See _make_spacer / _update_spacers.
var _lead_spacer: Control
var _trail_spacer: Control
var _simulated_outcome := GameLauncher.SimulatedOutcome.SUCCESS
## Id of the game whose card is marked RUNNING, or "" if none. Kept separately
## from GameLauncher's own state so a rebuild (_rebuild_cards()) can put the
## mark back on a freshly instantiated card without asking SessionController.
var _running_game_id := ""

@onready var _background: ColorRect = %Background
@onready var _layout: MarginContainer = %Layout
@onready var _row: HBoxContainer = %Row
@onready var _shelf: ScrollContainer = %Shelf
@onready var _game_count: Label = %GameCount
@onready var _build_number: Label = %BuildNumber
@onready var _empty_state: CenterContainer = %EmptyState
@onready var _empty_text: Label = %EmptyText
@onready var _problems: PanelContainer = %Problems
@onready var _problems_text: Label = %ProblemsText
@onready var _detail_name: Label = %DetailName
@onready var _detail_creators: Label = %DetailCreators
@onready var _detail_description: Label = %DetailDescription
@onready var _hints: Label = %Hints
@onready var _overlay: ColorRect = %Overlay
@onready var _overlay_title: Label = %OverlayTitle
@onready var _overlay_sub: Label = %OverlaySub
@onready var _volume_bar: PanelContainer = %VolumeBar
@onready var _volume_label: Label = %VolumeLabel
@onready var _volume_progress: ProgressBar = %VolumeProgress
@onready var _volume_value: Label = %VolumeValue
@onready var _session_node: SessionController = %SessionController


func _ready() -> void:
	# Which display backend Godot actually picked decides whether the launcher
	# can raise its own window over a frozen game at all - see README's
	# "window activation". On Wayland a client cannot raise or un-minimize
	# itself by protocol, so the answer here is the first thing to check when
	# the system overlay does not appear.
	print("[launcher] display server=%s session=%s desktop=%s" % [
		DisplayServer.get_name(),
		OS.get_environment("XDG_SESSION_TYPE"),
		OS.get_environment("XDG_CURRENT_DESKTOP"),
	])

	if Cfg.fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	# Lets the system overlay's dim layer show a frozen game's own window
	# through the launcher's - see set_background_visible(). Requires
	# display/window/size/transparent in project.godot; harmless here
	# otherwise, since the opaque Background ColorRect still covers the
	# window whenever this is not actively being used for that.
	get_window().transparent_bg = true

	# Keep the row centered as its own size (spacers) or the shelf's changes.
	_shelf.resized.connect(_on_shelf_resized)
	_row.sort_children.connect(_on_row_sorted)
	_build_number.text = "BUILD %s" % _read_build_number()

	_launcher = GameLauncher.new()
	_launcher.name = "GameLauncher"
	add_child(_launcher)
	_launcher.preparing.connect(_on_preparing)
	_launcher.started.connect(_on_started)
	_launcher.finished.connect(_on_finished)
	_launcher.failed.connect(_on_failed)

	_volume = VolumeControl.new()

	_session = _session_node
	_session.bind(_launcher, self, _volume)

	if Cfg.simulate_launch:
		_hints.text = ("Arrows: Browse     Enter: Play     Shift+Enter: Fail     "
			+ "Ctrl+Enter: Crash     -/=: Volume     M: Mute     F5: Refresh")

	refresh()


func _read_build_number() -> String:
	var file := FileAccess.open(BUILD_NUMBER_PATH, FileAccess.READ)
	if file == null:
		push_warning("[launcher] Could not read %s" % BUILD_NUMBER_PATH)
		return "—"
	var value := file.get_as_text().strip_edges()
	return value if value.is_valid_int() else "—"


# --- scanning and grid construction ------------------------------------------

func refresh() -> void:
	var result := GameScanner.scan(Cfg.games_dir)
	_games = result.games

	_scan_problems = PackedStringArray()
	# The launcher's own mapping is reapplied on every refresh, so a cabinet
	# whose keymap drifted (a crashed game, a hand-edited file) heals itself -
	# except while any game exists: its keymap has to stay installed, not the
	# launcher's own, or resuming/starting it would hand back the wrong buttons.
	# is_held is not enough: closing a held game to launch a different one fires
	# finished(), whose delayed refresh would otherwise land mid-launch of the
	# new game and clobber the keymap that launch() just installed for it.
	if not _launcher.is_busy:
		var keymap_error := _launcher.apply_launcher_keymap()
		if not keymap_error.is_empty():
			_scan_problems.append("controller mapping: " + keymap_error)
	# Anything wrong with config.json (bad value, unknown key) is surfaced the
	# same way scan and keymap trouble is, so a mistyped timing is visible on
	# the cabinet rather than only in the journal.
	for problem in Cfg.config_problems:
		_scan_problems.append("config: " + problem)
	_scan_problems.append_array(result.errors)
	_scan_problems.append_array(result.warnings())

	_rebuild_cards()
	_update_problems()
	_update_chrome()


func _rebuild_cards() -> void:
	# Refresh runs after every game, so keep the cursor where the player left
	# it rather than throwing them back to the first tile.
	var previous_id := _cards[_selected].game.id if _selected >= 0 else ""

	for child in _row.get_children():
		_row.remove_child(child)
		child.queue_free()
	_cards.clear()
	_lead_spacer = null
	_trail_spacer = null
	_selected = -1

	if _games.is_empty():
		return

	_lead_spacer = _make_spacer()
	_row.add_child(_lead_spacer)
	for game in _games:
		var card: GameCard = CARD_SCENE.instantiate()
		card.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_row.add_child(card)
		card.setup(game)
		card.set_status(STATUS_RUNNING if game.id == _running_game_id else "")
		_cards.append(card)
	_trail_spacer = _make_spacer()
	_row.add_child(_trail_spacer)
	_update_spacers()

	var restored := 0
	for i in _cards.size():
		if _cards[i].game.id == previous_id:
			restored = i
			break
	_select(restored)


## An empty filler control the row uses at each end. Its width is set in
## _update_spacers; it fills vertically so it does not disturb card centering.
func _make_spacer() -> Control:
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_FILL
	return spacer


## Sizes the end spacers to half the shelf width each, so the first and last
## games can slide all the way to the middle like any other - the row is a
## centered carousel, not a left-aligned list.
func _update_spacers() -> void:
	if _lead_spacer == null:
		return
	var half := _shelf.size.x * 0.5
	_lead_spacer.custom_minimum_size.x = half
	_trail_spacer.custom_minimum_size.x = half


func _on_shelf_resized() -> void:
	_update_spacers()
	_center_selected(false)


## Fires after the row (re)lays out its children - a rebuild, or a spacer width
## change. Positions are only real once this has run, so snap the selected game
## to center here rather than animating from stale coordinates.
func _on_row_sorted() -> void:
	_center_selected(false)


# --- SessionController's public surface on this scene --------------------------

## Adds to (true) or removes from (false) the grid's own input lock. This is
## additive with main.gd's own lock/unlock around the plain launch/return
## cycle (_on_preparing/_on_finished/_on_failed below) - an unlock request
## while SessionController still wants the lock held (its own overlay or
## attract mode is on screen) is vetoed, so the two can never fight over
## which one gets to turn the grid back on.
func set_ui_locked(value: bool) -> void:
	if not value and _session.wants_ui_locked():
		return
	_input_locked = value


## Hides this scene's own opaque background (and everything drawn on top of
## it) so a frozen game's own OS-level window - a separate process, sitting
## behind this one - shows through the transparent parts of the launcher's
## window instead. Only meaningful while the system overlay is open over a
## game that was actually running; everywhere else the launcher's normal
## background stays visible behind whatever is on top of it.
func set_background_visible(value: bool) -> void:
	_background.visible = value
	_layout.visible = value


## Marks `game`'s card RUNNING, or clears the grid's mark when `game` is null.
## The mark stays up for as long as the game is open - including while it is
## held, frozen in the background - so the grid always says which game the
## cabinet still has going; only the game actually ending clears it. Public
## because SessionController sees one of those endings (held_game_vanished)
## that the launch lifecycle below never hears about.
func set_running_game(game: GameEntry) -> void:
	_running_game_id = game.id if game != null else ""
	for card in _cards:
		card.set_status(STATUS_RUNNING if card.game.id == _running_game_id else "")
	if game == null:
		# Nothing is open any more, so the detail line goes back to describing
		# the selection.
		update_detail()
	else:
		_detail_description.text = _running_note()


## The wordier half of the RUNNING mark, shown on the detail line under the
## grid. It matters most in simulate mode, where the grid is the only thing on
## screen and something has to say which key ends the session.
func _running_note() -> String:
	if not Cfg.simulate_launch:
		return "Running"
	if _simulated_outcome == GameLauncher.SimulatedOutcome.EARLY_CRASH:
		return "Running (simulated). Simulating an early crash..."
	return "Running (simulated). Press Escape to return successfully."


func _update_chrome() -> void:
	var has_games := not _games.is_empty()
	_shelf.visible = has_games
	_empty_state.visible = not has_games
	_game_count.text = "%d game%s" % [_games.size(), "" if _games.size() == 1 else "s"]

	if not has_games:
		_empty_text.text = "No games found in %s" % Cfg.games_dir
		_detail_name.text = "—"
		_detail_creators.visible = false
		_detail_description.text = "Add a folder with game.json, icon.png and keymap.json, then press the white button to refresh."


func _update_problems() -> void:
	# Tracked even when there is nothing to report, so a problem that is fixed
	# and later reappears gets logged again instead of being deduplicated away.
	if _scan_problems != _logged_problems:
		_logged_problems = _scan_problems.duplicate()
		for problem in _scan_problems:
			push_warning("[launcher] " + problem)

	_problems.visible = not _scan_problems.is_empty()
	if not _problems.visible:
		return

	# Only the first few fit on screen; the rest stay in the journal.
	const SHOWN := 3
	var lines := Array(_scan_problems).slice(0, SHOWN)
	if _scan_problems.size() > SHOWN:
		lines.append("...and %d more (journalctl --user -u arcade-launcher)"
			% (_scan_problems.size() - SHOWN))
	_problems_text.text = "\n".join(lines)


# --- selection ----------------------------------------------------------------

func _select(index: int) -> void:
	if index == _selected or index < 0 or index >= _cards.size():
		return
	if _selected >= 0:
		_cards[_selected].set_selected(false)

	_selected = index
	_cards[_selected].set_selected(true)
	_center_selected()

	update_detail()


## Slides the row so the selected game is centered in the shelf. Never clamps
## short of the ends: the half-viewport spacers (see _update_spacers) give every
## game, first and last included, the room to reach the middle. Snaps instead of
## sliding when `animate` is false - used right after a (re)layout, when there is
## no previous position worth animating from.
func _center_selected(animate := true) -> void:
	# Bail until both the shelf and the row have real sizes; _on_shelf_resized
	# and _on_row_sorted call back in once they do.
	if _selected < 0 or _shelf.size.x <= 0.0 or _row.size.x <= 0.0:
		return
	var card := _cards[_selected]
	var target := int(card.position.x + card.size.x * 0.5 - _shelf.size.x * 0.5)
	target = clampi(target, 0, maxi(0, int(_row.size.x - _shelf.size.x)))

	if _row_tween != null and _row_tween.is_running():
		_row_tween.kill()
	if not animate:
		_shelf.scroll_horizontal = target
		return
	_row_tween = create_tween().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_row_tween.tween_property(_shelf, "scroll_horizontal", target, CAROUSEL_SLIDE_SECONDS)


## Fills the panel under the grid from the selected card. Public because it is
## also how the panel is put back after the launch lifecycle has borrowed the
## description line for a status note (see _status_note): SessionController
## calls it when the grid becomes the surface again with a game still open.
func update_detail() -> void:
	if _selected < 0:
		return
	var game := _cards[_selected].game
	_detail_name.text = game.name
	# Hidden rather than blanked, so an uncredited game does not leave a gap
	# between its name and description.
	_detail_creators.text = game.creators_label()
	_detail_creators.visible = not _detail_creators.text.is_empty()
	_detail_description.text = (game.description if not game.description.is_empty()
		else "No description in game.json.")


## Row movement: left/right walk the games and wrap at the ends.
func _move(action: String) -> void:
	if _cards.size() < 2:
		return
	var count := _cards.size()
	var index := _selected

	match action:
		"nav_left":
			index = posmod(index - 1, count)
		"nav_right":
			index = posmod(index + 1, count)

	_select(index)


# --- input --------------------------------------------------------------------

func _process(delta: float) -> void:
	if _input_locked:
		return
	for action in NAV_ACTIONS:
		if not Input.is_action_pressed(action):
			_repeat_countdown.erase(action)
			continue
		if not _repeat_countdown.has(action):
			_move(action)
			_repeat_countdown[action] = REPEAT_DELAY_SECONDS
			continue
		var remaining: float = _repeat_countdown[action] - delta
		if remaining <= 0.0:
			_move(action)
			remaining = REPEAT_INTERVAL_SECONDS
		_repeat_countdown[action] = remaining


func _unhandled_input(event: InputEvent) -> void:
	# _input_locked already means "the grid is not the active surface" -
	# PLAYING, the system overlay, or attract mode - which is exactly when
	# these raw volume shortcuts must not also fire independently of
	# whichever UI (the game itself, or the overlay's own volume row) is
	# supposed to own them right now.
	if not _input_locked and _handle_volume(event):
		return
	if _input_locked:
		if event.is_action_pressed("nav_back") and _launcher.finish_simulated_session():
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("nav_select"):
		get_viewport().set_input_as_handled()
		_activate(_simulation_outcome_for(event))
	elif event.is_action_pressed("nav_refresh"):
		get_viewport().set_input_as_handled()
		refresh()


## Routes the volume/mute buttons. Returns true when the event was one of them,
## so the caller can stop before it reaches selection or navigation.
func _handle_volume(event: InputEvent) -> bool:
	if event.is_action_pressed("volume_up"):
		_apply_volume(_volume.change(1))
	elif event.is_action_pressed("volume_down"):
		_apply_volume(_volume.change(-1))
	elif event.is_action_pressed("volume_mute"):
		_apply_volume(_volume.toggle_mute())
	else:
		return false
	get_viewport().set_input_as_handled()
	return true


func _apply_volume(state: Dictionary) -> void:
	var muted: bool = state.get("muted", false)
	var percent := int(round(float(state.get("volume", 0.0)) * 100.0))
	_volume_progress.value = percent
	_volume_label.text = "MUTED" if muted else "VOLUME"
	_volume_value.text = "%d%%" % percent
	_flash_volume_bar()


## Fades the bar in, holds it, then fades it out. Called on every change, so a
## fresh press cancels the pending fade and restarts the timer.
func _flash_volume_bar() -> void:
	_volume_bar.visible = true
	if _volume_tween != null and _volume_tween.is_running():
		_volume_tween.kill()
	_volume_tween = create_tween()
	_volume_tween.tween_property(_volume_bar, "modulate:a", 1.0, VOLUME_FADE_SECONDS)
	_volume_tween.tween_interval(VOLUME_VISIBLE_SECONDS)
	_volume_tween.tween_property(_volume_bar, "modulate:a", 0.0, VOLUME_FADE_SECONDS)
	_volume_tween.tween_callback(func() -> void: _volume_bar.visible = false)


func _simulation_outcome_for(event: InputEvent) -> int:
	if not Cfg.simulate_launch or not event is InputEventKey:
		return GameLauncher.SimulatedOutcome.SUCCESS
	var key_event := event as InputEventKey
	if key_event.ctrl_pressed:
		return GameLauncher.SimulatedOutcome.EARLY_CRASH
	if key_event.shift_pressed:
		return GameLauncher.SimulatedOutcome.LAUNCH_FAILURE
	return GameLauncher.SimulatedOutcome.SUCCESS


func _activate(simulated_outcome: int = GameLauncher.SimulatedOutcome.SUCCESS) -> void:
	# A game that is actually running (busy and not held) never gets here -
	# the grid is not the active surface while that is true - but a held one
	# is exactly what this grid is for while HELD_MENU is showing, so it is
	# not part of this guard. request_play() decides whether that means
	# resuming it, or closing it to make room for a different selection.
	if _selected < 0 or (_launcher.is_busy and not _launcher.is_held):
		return
	_cards[_selected].play_press()
	_simulated_outcome = simulated_outcome
	_session.request_play(_cards[_selected].game, simulated_outcome)


# --- launcher lifecycle -------------------------------------------------------

## Remapping and starting take the whole screen. They are the stretch where
## the cabinet is mid-way through something a player must not think they can
## interrupt - the grid still being there, with one tile merely marked, reads
## as an invitation to keep pressing buttons. Once the game is actually up
## (_on_started) the screen goes back to the grid, and the tile carries it
## from there.
func _on_preparing(game: GameEntry) -> void:
	_input_locked = true
	_repeat_countdown.clear()
	_overlay_title.text = game.name
	_overlay_sub.text = ("Applying controller mapping..." if not game.keymap.is_empty()
		else "Starting...")
	_show_overlay(true)


func _on_started(game: GameEntry) -> void:
	_show_overlay(false)
	set_running_game(game)


func _on_finished(_game: GameEntry, _exit_code: int) -> void:
	_show_overlay(false)  # a game that died before it ever started
	set_running_game(null)
	await get_tree().create_timer(RETURN_LOCKOUT_SECONDS).timeout
	# Vetoed (stays locked) if SessionController's own overlay or attract
	# mode has since taken over the screen - e.g. the idle-kill closing a
	# game while attract is already looping right through it.
	set_ui_locked(false)
	# A game may have been installed or removed while we were away.
	refresh()


func _on_failed(game: GameEntry, reason: String) -> void:
	set_running_game(null)
	_overlay_title.text = "Could not start %s" % game.name
	var dismiss_hint := ("Press Escape to go back." if Cfg.simulate_launch
		else "Press the bottom-middle button to go back.")
	_overlay_sub.text = reason + "\n\n" + dismiss_hint
	_show_overlay(true)

	# Wait for an explicit dismissal so the message is not missed, but do not
	# strand the cabinet if nobody is standing at it.
	var timeout := get_tree().create_timer(Cfg.failed_message_seconds)
	while true:
		await get_tree().process_frame
		if Input.is_action_just_pressed("nav_back") or timeout.time_left <= 0.0:
			break

	_show_overlay(false)
	set_ui_locked(false)
	refresh()


## Fades %Overlay, the full-screen card: the launch's pre-game phases while
## they run, and the "could not start" message afterwards if it comes to that.
func _show_overlay(shown: bool) -> void:
	if shown:
		_overlay.visible = true
	if _overlay_tween != null and _overlay_tween.is_running():
		_overlay_tween.kill()
	_overlay_tween = create_tween()
	_overlay_tween.tween_property(_overlay, "modulate:a",
		1.0 if shown else 0.0, OVERLAY_FADE_SECONDS)
	if not shown:
		_overlay_tween.tween_callback(func() -> void: _overlay.visible = false)
