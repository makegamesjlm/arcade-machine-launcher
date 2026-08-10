extends Control
## The launcher screen: scans /games, draws the grid, and hands a chosen game
## to GameLauncher.

const CARD_SCENE := preload("res://scenes/game_card.tscn")
const COLUMNS := 4

## Held-direction auto-repeat. The first step fires immediately, then after a
## pause the selection walks at a steady rate - slow enough to stop on the game
## you meant on a stiff arcade stick.
const REPEAT_DELAY_SECONDS := 0.38
const REPEAT_INTERVAL_SECONDS := 0.11

const NAV_ACTIONS := ["nav_left", "nav_right", "nav_up", "nav_down"]

## Buttons are often still held when a game quits back to us. Swallow input
## briefly so the release does not immediately relaunch something.
const RETURN_LOCKOUT_SECONDS := 0.6

const OVERLAY_FADE_SECONDS := 0.22

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
var _input_locked := false
var _overlay_tween: Tween
var _volume: VolumeControl
var _volume_tween: Tween
var _simulated_outcome := GameLauncher.SimulatedOutcome.SUCCESS

@onready var _grid: GridContainer = %Grid
@onready var _shelf: ScrollContainer = %Shelf
@onready var _game_count: Label = %GameCount
@onready var _empty_state: CenterContainer = %EmptyState
@onready var _empty_text: Label = %EmptyText
@onready var _problems: PanelContainer = %Problems
@onready var _problems_text: Label = %ProblemsText
@onready var _detail_name: Label = %DetailName
@onready var _detail_description: Label = %DetailDescription
@onready var _hints: Label = %Hints
@onready var _overlay: ColorRect = %Overlay
@onready var _overlay_title: Label = %OverlayTitle
@onready var _overlay_sub: Label = %OverlaySub
@onready var _volume_bar: PanelContainer = %VolumeBar
@onready var _volume_label: Label = %VolumeLabel
@onready var _volume_progress: ProgressBar = %VolumeProgress
@onready var _volume_value: Label = %VolumeValue


func _ready() -> void:
	if Cfg.fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN

	_grid.columns = COLUMNS

	_launcher = GameLauncher.new()
	_launcher.name = "GameLauncher"
	add_child(_launcher)
	_launcher.preparing.connect(_on_preparing)
	_launcher.started.connect(_on_started)
	_launcher.finished.connect(_on_finished)
	_launcher.failed.connect(_on_failed)

	_volume = VolumeControl.new()

	if Cfg.simulate_launch:
		_hints.text = ("Arrows: Browse     Enter: Play     Shift+Enter: Fail     "
			+ "Ctrl+Enter: Crash     -/=: Volume     M: Mute     F5: Refresh")

	refresh()


# --- scanning and grid construction ------------------------------------------

func refresh() -> void:
	var result := GameScanner.scan(Cfg.games_dir)
	_games = result.games

	_scan_problems = PackedStringArray()
	# The launcher's own mapping is reapplied on every refresh, so a cabinet
	# whose keymap drifted (a crashed game, a hand-edited file) heals itself.
	var keymap_error := _launcher.apply_launcher_keymap()
	if not keymap_error.is_empty():
		_scan_problems.append("controller mapping: " + keymap_error)
	_scan_problems.append_array(result.errors)
	_scan_problems.append_array(result.warnings())

	_rebuild_cards()
	_update_problems()
	_update_chrome()


func _rebuild_cards() -> void:
	# Refresh runs after every game, so keep the cursor where the player left
	# it rather than throwing them back to the first tile.
	var previous_id := _cards[_selected].game.id if _selected >= 0 else ""

	for card in _cards:
		_grid.remove_child(card)
		card.queue_free()
	_cards.clear()
	_selected = -1

	for game in _games:
		var card: GameCard = CARD_SCENE.instantiate()
		_grid.add_child(card)
		card.setup(game)
		_cards.append(card)

	if _cards.is_empty():
		return
	var restored := 0
	for i in _cards.size():
		if _cards[i].game.id == previous_id:
			restored = i
			break
	_select(restored)


func _update_chrome() -> void:
	var has_games := not _games.is_empty()
	_shelf.visible = has_games
	_empty_state.visible = not has_games
	_game_count.text = "%d game%s" % [_games.size(), "" if _games.size() == 1 else "s"]

	if not has_games:
		_empty_text.text = "No games found in %s" % Cfg.games_dir
		_detail_name.text = "—"
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
	var card := _cards[_selected]
	card.set_selected(true)
	# The card has not been laid out yet on the first frame, so let the
	# container settle before asking the shelf to scroll to it.
	_shelf.ensure_control_visible.call_deferred(card)

	var game := card.game
	_detail_name.text = game.name
	_detail_description.text = (game.description if not game.description.is_empty()
		else "No description in game.json.")


## Grid movement. Left/right walk the flat list and wrap at the ends; up/down
## move a row and wrap between top and bottom. The last row is often short, so
## moving down into it lands on the last game rather than refusing to move.
@warning_ignore("integer_division")
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
		"nav_up":
			if index >= COLUMNS:
				index -= COLUMNS
			else:
				# Wrap to the lowest row that actually has this column.
				index = (count - 1) - posmod(count - 1 - index, COLUMNS)
		"nav_down":
			if index / COLUMNS < (count - 1) / COLUMNS:
				index = mini(index + COLUMNS, count - 1)
			else:
				index = index % COLUMNS

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
	# Once launch begins, the controller belongs exclusively to the game. The
	# launcher stays alive in the background and can still receive joypad events,
	# so explicitly ignore its volume bindings until the session has finished.
	if not _launcher.is_busy and _handle_volume(event):
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
	if _selected < 0 or _launcher.is_busy:
		return
	_cards[_selected].play_press()
	_simulated_outcome = simulated_outcome
	_launcher.launch(_cards[_selected].game, simulated_outcome)


# --- launcher lifecycle -------------------------------------------------------

func _on_preparing(game: GameEntry) -> void:
	_input_locked = true
	_repeat_countdown.clear()
	_overlay_title.text = game.name
	_overlay_sub.text = ("Applying controller mapping..." if not game.keymap.is_empty()
		else "Starting...")
	_show_overlay(true)


func _on_started(_game: GameEntry) -> void:
	if not Cfg.simulate_launch:
		_overlay_sub.text = "Running"
	elif _simulated_outcome == GameLauncher.SimulatedOutcome.EARLY_CRASH:
		_overlay_sub.text = "Running (simulated)\n\nSimulating an early crash..."
	else:
		_overlay_sub.text = "Running (simulated)\n\nPress Escape to return successfully."


func _on_finished(_game: GameEntry, _exit_code: int) -> void:
	_show_overlay(false)
	await get_tree().create_timer(RETURN_LOCKOUT_SECONDS).timeout
	_input_locked = false
	# A game may have been installed or removed while we were away.
	refresh()


func _on_failed(game: GameEntry, reason: String) -> void:
	_overlay_title.text = "Could not start %s" % game.name
	var dismiss_hint := ("Press Escape to go back." if Cfg.simulate_launch
		else "Press the bottom-middle button to go back.")
	_overlay_sub.text = reason + "\n\n" + dismiss_hint
	_show_overlay(true)

	# Wait for an explicit dismissal so the message is not missed, but do not
	# strand the cabinet if nobody is standing at it.
	var timeout := get_tree().create_timer(15.0)
	while true:
		await get_tree().process_frame
		if Input.is_action_just_pressed("nav_back") or timeout.time_left <= 0.0:
			break

	_show_overlay(false)
	_input_locked = false
	refresh()


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
