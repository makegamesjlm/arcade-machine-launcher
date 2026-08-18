class_name SystemOverlay
extends CanvasLayer
## The white-button system menu: two rows of items over a dimmed background,
## navigated by position (not Godot's focus system) exactly like the main
## grid in main.gd - the same reasoning applies here: this has to work
## identically whether a press arrived as a real joypad event (gate=pass,
## opened from the plain menu) or as a synthetic one from InputRouter
## (gate=blocked, opened over a frozen game).
##
## Row 1 depends on context; row 2 (volume) never does. SessionController
## owns *when* this opens/closes and what each item actually does - this
## scene only renders the two rows for a given Context and reports which
## item was activated.

signal item_activated(item: Item)

enum Item {
	CONTINUE, SEND_PAUSE, BACK_TO_LAUNCHER, CLOSE_GAME, SLEEP,
	MUTE, VOLUME_DOWN, VOLUME_UP,
}

## Which row 1 is shown. PLAYING: a game is running and was just frozen for
## this. MENU_IDLE: the plain menu, nothing held. MENU_HELD: the menu, with
## a different game already parked in the background.
enum Context { PLAYING, MENU_IDLE, MENU_HELD }

const ROW1_BY_CONTEXT := {
	Context.PLAYING: [Item.CONTINUE, Item.SEND_PAUSE, Item.BACK_TO_LAUNCHER, Item.CLOSE_GAME, Item.SLEEP],
	Context.MENU_IDLE: [Item.CONTINUE, Item.SLEEP],
	Context.MENU_HELD: [Item.CONTINUE, Item.CLOSE_GAME, Item.SLEEP],
}
const ROW2 := [Item.MUTE, Item.VOLUME_DOWN, Item.VOLUME_UP]

const LABELS := {
	Item.CONTINUE: "Continue",
	Item.SEND_PAUSE: "Send Pause",
	Item.BACK_TO_LAUNCHER: "Back to Launcher",
	Item.CLOSE_GAME: "Close Game",
	Item.SLEEP: "Sleep",
	Item.MUTE: "Mute",
	Item.VOLUME_DOWN: "Volume −",
	Item.VOLUME_UP: "Volume +",
}

@onready var _row1: HBoxContainer = %Row1
@onready var _row2: HBoxContainer = %Row2
@onready var _volume_readout: Label = %VolumeReadout

## Array[Array[Item]], one inner array per row. Row 2 is always ROW2; row 1
## varies with the Context passed to open().
var _rows: Array = [[], ROW2]
## Array[Array[Button]], mirrors _rows one-to-one.
var _buttons: Array = [[], []]
var _row := 0
var _col := 0


func _ready() -> void:
	visible = false
	for item in ROW2:
		_buttons[1].append(_make_button(item, _row2))


## Rebuilds row 1 for `context`, shows the menu, and focuses its first item.
## Always Continue at (0, 0) in every context, so the safe/expected action
## is always one press away regardless of how the overlay was reached.
func open(context: Context) -> void:
	for child in _row1.get_children():
		child.queue_free()
	_buttons[0].clear()

	var row1_items: Array = ROW1_BY_CONTEXT[context]
	_rows[0] = row1_items
	for item in row1_items:
		_buttons[0].append(_make_button(item, _row1))

	visible = true
	_focus(0, 0)


func close() -> void:
	visible = false


## `dx`/`dy` are -1/0/1. Left/right wrap within the current row; up/down
## move between rows and clamp (not wrap) the column, since the two rows
## are rarely the same length and wrapping would jump unpredictably.
func move(dx: int, dy: int) -> void:
	var new_row := _row
	var new_col := _col
	if dy != 0:
		new_row = clampi(_row + dy, 0, _rows.size() - 1)
		new_col = clampi(_col, 0, _rows[new_row].size() - 1)
	elif dx != 0:
		new_col = posmod(_col + dx, _rows[_row].size())
	_focus(new_row, new_col)


func activate() -> void:
	item_activated.emit(_rows[_row][_col])


## The bottom-middle button and a second white press both mean Continue,
## regardless of what is currently focused.
func continue_shortcut() -> void:
	item_activated.emit(Item.CONTINUE)


func set_volume_readout(text: String) -> void:
	_volume_readout.text = text


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("nav_left"):
		move(-1, 0)
	elif event.is_action_pressed("nav_right"):
		move(1, 0)
	elif event.is_action_pressed("nav_up"):
		move(0, -1)
	elif event.is_action_pressed("nav_down"):
		move(0, 1)
	elif event.is_action_pressed("nav_select"):
		activate()
	elif event.is_action_pressed("nav_back"):
		continue_shortcut()
	else:
		return
	get_viewport().set_input_as_handled()


func _make_button(item: Item, parent: Node) -> Button:
	var button := Button.new()
	button.text = LABELS[item]
	button.focus_mode = Control.FOCUS_NONE  # navigated by position, not Godot focus
	button.toggle_mode = true  # repurposed below as a lightweight "focused" indicator
	button.custom_minimum_size = Vector2(160, 64)
	parent.add_child(button)
	return button


func _focus(row: int, col: int) -> void:
	_row = row
	_col = col
	for r in _rows.size():
		for c in _buttons[r].size():
			_buttons[r][c].button_pressed = (r == _row and c == _col)
