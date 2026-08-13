extends Node
## Headless checks for the non-UI half of the launcher.
##
##   godot --headless --path . res://tests/test_core.tscn
##
## Exits non-zero when anything fails, so it can gate a build.

var _failures := 0
var _checks := 0


func _ready() -> void:
	var fixtures := ProjectSettings.globalize_path("res://dev/games")
	_test_scanner(fixtures)
	_test_keymap_validation()
	_test_keymap_install()
	_test_volume_input_mapping()
	_test_volume_parsing()

	print("\n%d checks, %d failed" % [_checks, _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _test_scanner(fixtures: String) -> void:
	print("\n-- scanner")
	var result := GameScanner.scan(fixtures)

	var ids := []
	var names := []
	for game in result.games:
		ids.append(game.id)
		names.append(game.name)

	# Asserted as a set rather than a count, so adding a fixture does not
	# break the test for the wrong reason.
	for playable in ["neon-drift", "cavern-brawl", "bad-keymap"]:
		_check(ids.has(playable), "%s is launchable, got %s" % [playable, ids])
	for broken in ["broken-manifest", "missing-exe"]:
		_check(not ids.has(broken), "%s is not launchable, got %s" % [broken, ids])

	var sorted_names := names.duplicate()
	sorted_names.sort_custom(func(a: String, b: String) -> bool:
		return a.naturalnocasecmp_to(b) < 0)
	_check(names == sorted_names, "sorted by display name, got %s" % [names])

	_check(result.errors.size() == 2, "2 unloadable fixtures, got %s" % [result.errors])
	_check(_any_contains(result.errors, "broken-manifest") and _any_contains(result.errors, "JSON"),
		"broken-manifest is reported as bad JSON")
	_check(_any_contains(result.errors, "missing-exe") and _any_contains(result.errors, "not found"),
		"missing-exe is reported as a missing binary")

	var by_id := {}
	for game in result.games:
		by_id[game.id] = game

	var neon: GameEntry = by_id["neon-drift"]
	_check(neon.players == 2, "neon-drift is 2 players, got %d" % neon.players)
	_check(neon.players_label() == "2 players", "player label reads '%s'" % neon.players_label())
	_check(neon.keymap.get("top_left") == "LB", "neon-drift keymap loaded, got %s" % [neon.keymap])
	_check(neon.icon_path.ends_with("icon.png"), "neon-drift found its icon")
	_check(neon.executable.ends_with("game.x86_64"), "neon-drift resolved its executable")
	_check(neon.warnings.is_empty(), "a complete game has no warnings, got %s" % [neon.warnings])

	var bad: GameEntry = by_id["bad-keymap"]
	_check(bad.keymap.is_empty(), "an invalid keymap is not loaded, got %s" % [bad.keymap])
	_check(_any_contains(bad.warnings, "L1"), "the rejected Xbox name is named in the warning")
	_check(_any_contains(bad.warnings, "middle_left"), "the unknown cabinet button is named too")
	_check(_any_contains(bad.warnings, "icon"), "the missing icon is a warning, not an error")

	var missing_dir := GameScanner.scan(fixtures.path_join("does-not-exist"))
	_check(missing_dir.games.is_empty() and missing_dir.errors.size() == 1,
		"a missing games dir is one clean error, got %s" % [missing_dir.errors])


func _test_keymap_validation() -> void:
	print("\n-- keymap validation")
	_check(KeymapWriter.validate(Cfg.LAUNCHER_KEYMAP).is_empty(),
		"the launcher's own keymap is valid")
	_check(KeymapWriter.validate({"joystick": "dpad", "white": "Start"}).is_empty(),
		"the hat-axis dpad mode is valid")
	_check(KeymapWriter.validate({"joystick": "dpad-legacy", "white": "Start"}).is_empty(),
		"the dpad-button mode is valid")

	_check(_any_contains(KeymapWriter.validate({"white": "Turbo"}), "Turbo"),
		"an unknown Xbox name is rejected")
	_check(_any_contains(KeymapWriter.validate({"joystick": "trackball"}), "trackball"),
		"an unknown joystick mode is rejected")
	_check(_any_contains(KeymapWriter.validate({"joystick": "dpad1"}), "dpad1"),
		"an obsolete numbered dpad mode is rejected")
	_check(_any_contains(KeymapWriter.validate({"joystick": 3}), "not a string"),
		"a non-string joystick mode is rejected")
	_check(_any_contains(KeymapWriter.validate({"middle": "A"}), "middle"),
		"an unknown cabinet button is rejected")
	_check(_any_contains(KeymapWriter.validate({"white": 3}), "not a string"),
		"a non-string target is rejected")
	_check(_any_contains(KeymapWriter.validate({"white": "A", "top_left": "A"}), "both map to A"),
		"two buttons mapped to one output is flagged")
	_check(not KeymapWriter.validate({}).is_empty(), "an empty keymap is rejected")

	# Cabinet order, not insertion or alphabetical order. bottom_* sorts before
	# top_* alphabetically, so this pair tells the two apart.
	var json := KeymapWriter.to_json({"bottom_left": "RB", "top_left": "LB"})
	_check(json.find("top_left") < json.find("bottom_left"),
		"serialization follows the cabinet layout, got %s" % json)
	var joystick_json := KeymapWriter.to_json({"white": "Start", "joystick": "dpad"})
	_check(joystick_json.find("joystick") < joystick_json.find("white"),
		"joystick mode is serialized before button mappings, got %s" % joystick_json)

	var full := KeymapWriter.to_json(Cfg.LAUNCHER_KEYMAP)
	var order := []
	for button in Cfg.CABINET_BUTTONS:
		order.append(full.find("\"%s\"" % button))
	var sorted_order := order.duplicate()
	sorted_order.sort()
	_check(order == sorted_order and not order.has(-1),
		"every cabinet button is emitted in layout order, got %s" % [order])


func _test_keymap_install() -> void:
	print("\n-- keymap install")
	var dir := OS.get_cache_dir().path_join("arcade-launcher-test")
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("keymap.json")
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

	var error := KeymapWriter.install(Cfg.LAUNCHER_KEYMAP, path)
	_check(error.is_empty(), "install succeeds, got '%s'" % error)

	var written: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	_check(written == Cfg.LAUNCHER_KEYMAP, "the file round-trips, got %s" % [written])

	var leftovers := DirAccess.open(dir).get_files()
	_check(leftovers == PackedStringArray(["keymap.json"]),
		"the atomic temp file is cleaned up, dir holds %s" % [leftovers])

	_check(not KeymapWriter.install({"white": "Nope"}, path).is_empty(),
		"an invalid keymap is never written")
	_check(JSON.parse_string(FileAccess.get_file_as_string(path)) == Cfg.LAUNCHER_KEYMAP,
		"the previous keymap survives a rejected install")

	var missing := KeymapWriter.install(Cfg.LAUNCHER_KEYMAP, dir.path_join("nope/keymap.json"))
	_check(missing.contains("setup-arcade.sh"),
		"a missing target dir points at the setup script, got '%s'" % missing)


func _test_volume_input_mapping() -> void:
	print("\n-- volume input mapping")

	# These must agree with Cfg.LAUNCHER_KEYMAP: top-left emits LB, top-right X,
	# and top-middle Y through the cabinet remapper.
	var expected_buttons := {
		"volume_down": JOY_BUTTON_LEFT_SHOULDER,
		"volume_up": JOY_BUTTON_X,
		"volume_mute": JOY_BUTTON_Y,
	}
	for action: String in expected_buttons:
		var button := int(expected_buttons[action])
		var matched := false
		for event in InputMap.action_get_events(action):
			if event is InputEventJoypadButton and event.button_index == button:
				matched = true
				break
		_check(matched, "%s is bound to joypad button %d" % [action, button])


func _test_volume_parsing() -> void:
	print("\n-- volume parsing")

	var wp := VolumeControl.parse_wpctl("Volume: 0.65")
	_check(absf(float(wp["volume"]) - 0.65) < 0.001 and not wp["muted"],
		"wpctl volume is read, got %s" % [wp])

	var wp_muted := VolumeControl.parse_wpctl("Volume: 0.40 [MUTED]")
	_check(absf(float(wp_muted["volume"]) - 0.40) < 0.001 and wp_muted["muted"],
		"wpctl mute flag is read, got %s" % [wp_muted])

	_check(absf(float(VolumeControl.parse_wpctl("nonsense")["volume"])) < 0.001,
		"unparseable wpctl output is a safe zero")

	var pactl_line := "Volume: front-left: 42152 /  64% / -12.00 dB,   front-right: 42152 /  64% / -12.00 dB"
	_check(absf(VolumeControl.parse_pactl_volume(pactl_line) - 0.64) < 0.001,
		"pactl channel percentage is read, got %f" % VolumeControl.parse_pactl_volume(pactl_line))

	_check(VolumeControl.parse_pactl_mute("Mute: yes") and not VolumeControl.parse_pactl_mute("Mute: no"),
		"pactl mute state is read")


func _any_contains(haystack: PackedStringArray, needle: String) -> bool:
	for line in haystack:
		if line.contains(needle):
			return true
	return false


func _check(passed: bool, label: String) -> void:
	_checks += 1
	if passed:
		print("  ok   %s" % label)
	else:
		_failures += 1
		printerr("  FAIL %s" % label)
