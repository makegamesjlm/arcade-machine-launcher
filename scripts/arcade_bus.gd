extends Node
## Client for the shanwan-remap control channel (see
## shanwan-remap/README.md, "Control channel"). Autoloaded as `Bus`.
##
## Two things this gives the rest of the launcher:
##   - `button`/`hat` signals: every physical event, straight off the
##     cabinet's controllers, independent of whichever keymap happens to be
##     installed. This is what lets the launcher see input at all while a
##     game is frozen and blocked (behind a game, or navigating the system
##     overlay) - Godot's own joypad input goes silent in that state, since
##     the remapper has stopped writing to the virtual pad.
##   - `set_mode()` / `inject()`: flip the remapper's OutputGate, or send one
##     synthetic press through the currently-installed keymap (used for
##     "Send pause").
##
## If the remapper is unreachable at all - Windows dev, or a cabinet whose
## shanwan-remap predates this feature - `is_live` stays false forever and
## every command is a no-op. Callers must check it rather than assume the
## bus works; SessionController falls back to plain Godot input and skips
## the parts of the design that need the control channel (see its class
## doc comment) when it does.

## Gate modes accepted by set_mode() - must match shanwan_remap.gate.PASS/BLOCKED.
const MODE_PASS := "pass"
const MODE_BLOCKED := "blocked"

signal button(pad: int, pos: String, xbox_name, pressed: bool)
signal hat(pad: int, axis: String, value: int)
## Fired on every feed message, press or release. IdleTracker's activity
## clock listens here so a game frozen behind the overlay still resets the
## idle timer on input the Godot side of the launcher never sees directly.
signal activity
signal connected
signal lost

## True once the socket is connected AND the remapper has handshaken with a
## protocol version this launcher understands. False also counts as "no
## control channel" for every purpose above.
var is_live: bool:
	get: return _handshake_ok and _socket != null \
		and _socket.get_status() == StreamPeerTCP.STATUS_CONNECTED

## Whether cabinet.json defines a `white` position, reported by the
## remapper's hello reply. False means the cabinet has not been configured
## for the system button at all - surfaced by the caller as a problem
## rather than silently doing nothing when white is pressed.
var has_white: bool = false

var _socket: StreamPeerTCP = null
var _sent_hello := false
var _handshake_ok := false
var _read_buffer := PackedByteArray()
var _reconnect_countdown := 0.0
## Re-sent every time we (re)connect, so a remapper restart (controller
## hotplug) or a dropped connection does not silently leave a game blocked
## forever with nobody re-asserting the mode it should be in.
var _desired_mode := "pass"


func _ready() -> void:
	_try_connect()


func _process(delta: float) -> void:
	if _socket == null:
		_reconnect_countdown -= delta
		if _reconnect_countdown <= 0.0:
			_try_connect()
		return

	_socket.poll()
	match _socket.get_status():
		StreamPeerTCP.STATUS_CONNECTED:
			if not _sent_hello:
				_sent_hello = true
				_send({"c": "hello"})
			_drain_incoming()
		StreamPeerTCP.STATUS_CONNECTING:
			pass
		_:
			_on_disconnected()


## Requests the gate be switched to "pass" (normal forwarding) or "blocked"
## (nothing physical reaches the virtual pad). No-op while not live; the
## desired mode is remembered and re-sent the moment a connection lands, so
## a reconnect during a blocked session re-asserts it rather than leaving
## the remapper defaulting back to pass underneath a still-frozen game.
func set_mode(mode: String) -> void:
	_desired_mode = mode
	_send_desired_mode()


## Writes one synthetic press+release of `pos` through the game's current
## keymap - the only way the white/system button ever reaches a game (see
## "Send pause"). No-op while not live; callers are expected to have
## already checked is_live before relying on this.
func inject(pos: String) -> void:
	if is_live:
		_send({"c": "inject", "pos": pos})


func _send_desired_mode() -> void:
	if is_live:
		_send({"c": "mode", "m": _desired_mode})


func _try_connect() -> void:
	_socket = StreamPeerTCP.new()
	var error := _socket.connect_to_host(Cfg.CONTROL_HOST, Cfg.CONTROL_PORT)
	if error != OK:
		_socket = null
		_reconnect_countdown = Cfg.CONTROL_RECONNECT_SECONDS
		return
	_sent_hello = false


func _drain_incoming() -> void:
	var available := _socket.get_available_bytes()
	if available > 0:
		var result: Array = _socket.get_partial_data(available)
		if result[0] == OK:
			_read_buffer.append_array(result[1])
	while true:
		var newline_index := _find_byte(_read_buffer, 10)  # '\n'
		if newline_index < 0:
			break
		var line := _read_buffer.slice(0, newline_index)
		_read_buffer = _read_buffer.slice(newline_index + 1)
		_handle_line(line.get_string_from_utf8())


## PackedByteArray has no single-byte find(); scan for it directly. Lines are
## short JSON objects, so this never runs over more than a few dozen bytes.
func _find_byte(buffer: PackedByteArray, value: int) -> int:
	for i in range(buffer.size()):
		if buffer[i] == value:
			return i
	return -1


func _handle_line(text: String) -> void:
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var message: Dictionary = parsed

	var msg_type = message.get("t")
	if msg_type == "btn":
		activity.emit()
		button.emit(int(message.get("pad", 0)), String(message.get("pos", "")),
			message.get("xbox"), int(message.get("v", 0)) == 1)
		return
	if msg_type == "hat":
		activity.emit()
		hat.emit(int(message.get("pad", 0)), String(message.get("axis", "")), int(message.get("v", 0)))
		return

	if message.get("reply") == "hello":
		_on_hello_reply(message)


func _on_hello_reply(message: Dictionary) -> void:
	has_white = bool(message.get("has_white", false))
	var proto := int(message.get("proto", 0))
	if message.get("ok") != true or proto != Cfg.CONTROL_PROTOCOL_VERSION:
		push_warning("[bus] shanwan-remap protocol mismatch (got %d, need %d); overlay/attract features disabled"
			% [proto, Cfg.CONTROL_PROTOCOL_VERSION])
		return
	var was_live := _handshake_ok
	_handshake_ok = true
	if not was_live:
		connected.emit()
	_send_desired_mode()


func _send(message: Dictionary) -> void:
	if _socket == null or _socket.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	_socket.put_data((JSON.stringify(message) + "\n").to_utf8_buffer())


func _on_disconnected() -> void:
	var was_live := _handshake_ok
	_socket = null
	_sent_hello = false
	_handshake_ok = false
	_read_buffer = PackedByteArray()
	_reconnect_countdown = Cfg.CONTROL_RECONNECT_SECONDS
	if was_live:
		lost.emit()
