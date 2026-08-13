class_name VolumeControl
extends RefCounted
## Adjusts the cabinet's system output volume from the launcher menu.
##
## The menu is the only place this can run: while a game is on screen the
## launcher is covered and the controller belongs to the game. On the cabinet
## (PipeWire on Bazzite) the level goes through `wpctl`, with `pactl` as a
## fallback. On a dev box that has neither, a simulated level is kept so the
## on-screen bar can still be exercised.

## Percentage points moved per button press.
const STEP := 5

## wpctl caps a raise at this fraction so a player leaning on the button can
## never push the sink past 100% into software clipping.
const MAX_FRACTION := 1.0

enum Backend { NONE, WPCTL, PACTL }

var _backend := Backend.NONE
var _sink := ""
# Fallback state for a machine with no audio tooling, so the bar still moves.
var _sim_volume := 0.5
var _sim_muted := false


func _init() -> void:
	_backend = _detect_backend()
	match _backend:
		Backend.WPCTL:
			_sink = "@DEFAULT_AUDIO_SINK@"
		Backend.PACTL:
			_sink = "@DEFAULT_SINK@"


## True when a real system mixer was found. False on a dev box, where changes
## only move the simulated level behind the on-screen bar.
func is_available() -> bool:
	return _backend != Backend.NONE


## Current level without changing anything: {volume: 0..1, muted: bool}.
func read() -> Dictionary:
	return _read_state()


## Steps the volume by one notch. `direction` is +1 to raise or -1 to lower.
## Returns the resulting {volume, muted}.
func change(direction: int) -> Dictionary:
	match _backend:
		Backend.WPCTL:
			var delta := "%d%%%s" % [STEP, "+" if direction > 0 else "-"]
			var args := PackedStringArray(["set-volume"])
			if direction > 0:
				# Only a raise needs a ceiling; lowering can never overshoot.
				args.append_array(["-l", str(MAX_FRACTION)])
			args.append_array([_sink, delta])
			OS.execute("wpctl", args)
		Backend.PACTL:
			var delta := "%s%d%%" % ["+" if direction > 0 else "-", STEP]
			OS.execute("pactl", ["set-sink-volume", _sink, delta])
		Backend.NONE:
			_sim_volume = clampf(_sim_volume + direction * STEP / 100.0, 0.0, 1.0)
	return _read_state()


## Flips mute on or off. Returns the resulting {volume, muted}.
func toggle_mute() -> Dictionary:
	match _backend:
		Backend.WPCTL:
			OS.execute("wpctl", ["set-mute", _sink, "toggle"])
		Backend.PACTL:
			OS.execute("pactl", ["set-sink-mute", _sink, "toggle"])
		Backend.NONE:
			_sim_muted = not _sim_muted
	return _read_state()


func _read_state() -> Dictionary:
	match _backend:
		Backend.WPCTL:
			var out := []
			if OS.execute("wpctl", ["get-volume", _sink], out) == 0 and out.size() > 0:
				return parse_wpctl(out[0])
		Backend.PACTL:
			var vol_out := []
			var mute_out := []
			OS.execute("pactl", ["get-sink-volume", _sink], vol_out)
			OS.execute("pactl", ["get-sink-mute", _sink], mute_out)
			return {
				"volume": parse_pactl_volume(vol_out[0] if vol_out.size() > 0 else ""),
				"muted": parse_pactl_mute(mute_out[0] if mute_out.size() > 0 else ""),
			}
	return {"volume": _sim_volume, "muted": _sim_muted}


func _detect_backend() -> int:
	if not OS.has_feature("linux"):
		return Backend.NONE
	if _has_command("wpctl"):
		return Backend.WPCTL
	if _has_command("pactl"):
		return Backend.PACTL
	return Backend.NONE


func _has_command(command: String) -> bool:
	return OS.execute("which", [command], []) == 0


# --- output parsing (static so the test suite can exercise it) ----------------

## `wpctl get-volume` prints e.g. "Volume: 0.65" or "Volume: 0.65 [MUTED]".
static func parse_wpctl(output: String) -> Dictionary:
	var volume := 0.0
	var found := RegEx.create_from_string("Volume:\\s*([0-9]*\\.?[0-9]+)").search(output)
	if found:
		volume = clampf(found.get_string(1).to_float(), 0.0, 1.0)
	return {"volume": volume, "muted": output.contains("MUTED")}


## `pactl get-sink-volume` prints a long line with per-channel "NN%" readings;
## the channels match, so the first percentage is enough.
static func parse_pactl_volume(output: String) -> float:
	var found := RegEx.create_from_string("([0-9]+)%").search(output)
	return clampf(found.get_string(1).to_float() / 100.0, 0.0, 1.0) if found else 0.0


## `pactl get-sink-mute` prints "Mute: yes" or "Mute: no".
static func parse_pactl_mute(output: String) -> bool:
	return output.to_lower().contains("yes")
