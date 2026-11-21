class_name AttractScreen
extends CanvasLayer
## Looping silent idle screen (content per screensaver-brief.md). Mostly
## passive by design: SessionController decides when to show/hide it and
## reacts to Bus.button itself for the normal wake path, since every
## cabinet button - including white - always reaches Bus regardless of
## Godot's own input/focus state, which is exactly what lets this wake on
## ANY button as the bottom bar promises, not just the ones bound to a
## Godot action.
##
## The things this handles directly are keyboard wakes (always - the
## cabinet has no keyboard, so a key press means someone testing over remote
## desktop) and a joypad fallback wake for when the control channel is
## unavailable altogether (Windows dev, or a cabinet whose remapper is not
## running) - in that world Bus never fires at all, so this listens for a
## real Godot input event instead. Harmless overlap: whichever path fires
## first wins, and stop() hiding this makes the other a no-op here.

signal woken

@onready var _video: VideoStreamPlayer = %AttractVideo
@onready var _fallback: Control = %Fallback


func _ready() -> void:
	visible = false
	_load_video()


func play() -> void:
	visible = true
	if _video.visible:
		_video.play()


func stop() -> void:
	visible = false
	_video.stop()


## Godot 4's VideoStreamPlayer decodes Ogg Theora only - see Cfg.attract_video
## and its doc comment. A missing, unreadable, or wrong-format file falls
## back to the built-in static screen rather than showing black.
func _load_video() -> void:
	if Cfg.attract_video.is_empty() or not FileAccess.file_exists(Cfg.attract_video):
		_use_fallback()
		return
	var stream: VideoStream = load(Cfg.attract_video)
	if stream == null:
		push_warning("[attract] could not load %s as a video stream; showing the fallback screen"
			% Cfg.attract_video)
		_use_fallback()
		return
	_video.stream = stream
	_video.loop = true
	_video.show()
	_fallback.hide()


func _use_fallback() -> void:
	_video.hide()
	_fallback.show()


## Any keyboard key wakes it, always - including on the cabinet, so it can be
## woken over remote desktop. The one exception is the white stand-in
## (`system_button`), which SessionController turns into a white tap on
## release, and that wakes attract the same way the real white button does.
## Waking here on its press would leave the release to open the overlay over
## the freshly woken menu.
##
## Joypad input only counts as the dev-mode / no-remapper fallback (see the
## class doc comment). On the cabinet a real button press is caught by
## SessionController via Bus.button.
func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey:
		if event.is_pressed() and not event.is_action("system_button"):
			woken.emit()
		return
	if Bus.is_live:
		return
	if event is InputEventJoypadMotion:
		if absf(event.axis_value) > 0.5:
			woken.emit()
		return
	if event is InputEventJoypadButton and event.is_pressed():
		woken.emit()
