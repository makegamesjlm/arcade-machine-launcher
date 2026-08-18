extends Node
## Tracks how long it has been since anyone touched the cabinet, and fires
## the two idle behaviours that depend on it. Autoloaded as `Idle`.
##
## Fed from two sources so it works whether or not a game currently has the
## controller: Bus.activity (every physical event reported by shanwan-remap's
## control channel, which keeps arriving even while a game is frozen and
## blocked and Godot's own joypad input has gone silent) and Godot's own
## `_input()` (every keyboard/mouse/joypad event Godot sees directly - the
## normal path while nothing is blocked, and the only path at all when the
## control channel is unavailable, e.g. Windows dev).
##
## `attract_due` and `kill_due` are edge-triggered: each fires once when its
## threshold is crossed, not once a frame for as long as the machine stays
## idle. Entering attract mode does not by itself reset the clock - the 30
## minute kill is measured from the same last real touch, so it lands 1500
## seconds into an attract loop that started at the 300-second mark, exactly
## as specified.

signal attract_due
signal kill_due

## Set by SessionController: true only while a game is actually being
## played (state PLAYING). Everywhere else - the menu, a held-game menu, an
## open system overlay, attract mode itself - nobody is mid-session, so the
## shorter menu threshold applies even if a game happens to be held.
var playing: bool = false

var _last_activity_msec: int = 0
var _attract_fired := false
var _kill_fired := false


func _ready() -> void:
	_last_activity_msec = Time.get_ticks_msec()
	Bus.activity.connect(_on_activity)
	set_process(true)


func _input(_event: InputEvent) -> void:
	_on_activity()


func _process(_delta: float) -> void:
	var idle := idle_seconds()
	var attract_threshold: float = Cfg.attract_game_seconds if playing else Cfg.attract_menu_seconds
	if idle >= attract_threshold and not _attract_fired:
		_attract_fired = true
		attract_due.emit()
	if idle >= Cfg.idle_kill_seconds and not _kill_fired:
		_kill_fired = true
		kill_due.emit()


func idle_seconds() -> float:
	return (Time.get_ticks_msec() - _last_activity_msec) / 1000.0


func _on_activity() -> void:
	_last_activity_msec = Time.get_ticks_msec()
	_attract_fired = false
	_kill_fired = false
