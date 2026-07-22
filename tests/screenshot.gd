extends Node
## Dev-only harness: renders the launcher and writes a PNG, so the layout can be
## eyeballed without standing at the cabinet.
##
##   godot --path . --resolution 1920x1080 res://tests/screenshot.tscn -- \
##       --no-fullscreen --games-dir=dev/games --shot=/tmp/launcher.png
##
## Repeat --shot to capture more than one frame; --nav <action> steps the
## selection between captures, e.g. --nav nav_right --shot=b.png

const SETTLE_FRAMES := 20


func _ready() -> void:
	add_child(load("res://scenes/main.tscn").instantiate())
	await _settle()

	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			await _capture(arg.trim_prefix("--shot="))
		elif arg.begins_with("--nav="):
			_send_action(arg.trim_prefix("--nav="))
			await _settle()
		elif arg.begins_with("--wait="):
			await get_tree().create_timer(float(arg.trim_prefix("--wait="))).timeout

	get_tree().quit()


func _settle() -> void:
	for i in SETTLE_FRAMES:
		await get_tree().process_frame


func _capture(path: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(path)
	print("[shot] %s -> %s" % [path, "ok" if error == OK else error_string(error)])


func _send_action(action: String) -> void:
	if not InputMap.has_action(action):
		printerr("[shot] no such action: %s" % action)
		return
	var press := InputEventAction.new()
	press.action = action
	press.pressed = true
	Input.parse_input_event(press)
	await get_tree().process_frame
	var release := InputEventAction.new()
	release.action = action
	release.pressed = false
	Input.parse_input_event(release)
