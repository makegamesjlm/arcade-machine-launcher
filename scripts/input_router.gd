class_name InputRouter
extends Node
## Translates ArcadeBus feed events into synthetic Godot joypad input, so the
## launcher's existing navigation code (main.gd's _move()/_select(), the
## system overlay's own navigation, ...) works unchanged whether a press
## arrived through the OS's normal joypad path or through the control
## channel.
##
## Only matters while `active`. In `pass` mode the virtual pad is a normal
## joypad and Godot already receives its events directly - enabling this at
## the same time would double every press. It exists for exactly the state
## where that path goes silent: the gate is `blocked`, so shanwan-remap has
## stopped writing to the pad, but the physical buttons are still live on
## the feed and the launcher still needs to navigate (the system overlay
## itself, or the grid while a game is held).
##
## Deliberately goes through Cfg.LAUNCHER_KEYMAP rather than each feed
## message's own `xbox` field: that field reflects whatever keymap the
## *game* installed, which is irrelevant to launcher navigation and, while
## a game is held, may never have been swapped back out at all.
##
## White is never routed here - it is the system button, handled directly
## by whoever owns the overlay/attract state, not a navigation input.

## Enabled/disabled by SessionController as the gate flips blocked/pass.
var active: bool = false:
	set(value):
		active = value
		if not value:
			_release_all()

var _held: Dictionary = {}  # joy button index (int) -> true
var _hat_x := 0
var _hat_y := 0


func _ready() -> void:
	Bus.button.connect(_on_button)
	Bus.hat.connect(_on_hat)


func _on_button(_pad: int, pos: String, _xbox_name, pressed: bool) -> void:
	if not active or pos == "white":
		return
	var xbox_name = Cfg.LAUNCHER_KEYMAP.get(pos)
	if xbox_name == null:
		return  # e.g. bottom_left/RB, which the menu has never bound
	var button_index = Cfg.XBOX_TO_JOY_BUTTON.get(xbox_name)
	if button_index != null:
		_set_button(button_index, pressed)


func _on_hat(_pad: int, axis: String, value: int) -> void:
	if not active:
		return
	if axis == "x":
		_apply_axis(JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_DPAD_RIGHT, _hat_x, value)
		_hat_x = value
	else:
		_apply_axis(JOY_BUTTON_DPAD_UP, JOY_BUTTON_DPAD_DOWN, _hat_y, value)
		_hat_y = value


func _apply_axis(negative_button: int, positive_button: int, previous_value: int, value: int) -> void:
	if previous_value == -1 and value != -1:
		_set_button(negative_button, false)
	if previous_value == 1 and value != 1:
		_set_button(positive_button, false)
	if value == -1:
		_set_button(negative_button, true)
	elif value == 1:
		_set_button(positive_button, true)


func _set_button(button_index: int, pressed: bool) -> void:
	if pressed == _held.has(button_index):
		return  # already in that state; avoid a duplicate press/release
	if pressed:
		_held[button_index] = true
	else:
		_held.erase(button_index)
	var event := InputEventJoypadButton.new()
	event.button_index = button_index
	event.pressed = pressed
	Input.parse_input_event(event)


## Releases everything this router is currently holding down. Called when
## `active` goes false, so a game does not resume with a synthetic input
## routed from the overlay stuck "held" in Godot's own input state (this is
## about Godot's Input singleton, separate from - and in addition to - the
## remapper's own neutralize-before-block step on the virtual pad itself).
func _release_all() -> void:
	for button_index in _held.keys():
		var event := InputEventJoypadButton.new()
		event.button_index = button_index
		event.pressed = false
		Input.parse_input_event(event)
	_held.clear()
	_hat_x = 0
	_hat_y = 0
