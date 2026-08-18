class_name GameScanner
extends RefCounted
## Reads the /games folder into GameEntry objects.
##
## A folder is only skipped when it cannot possibly be launched (no game.json,
## no executable). Everything softer - a missing icon, a keymap the remap
## service would reject - becomes a warning on the entry so the cabinet still
## boots into a usable menu.

class ScanResult:
	extends RefCounted
	var games: Array[GameEntry] = []
	## Folders that could not be loaded at all, one message each.
	var errors: PackedStringArray = PackedStringArray()

	func warnings() -> PackedStringArray:
		var all := PackedStringArray()
		for game in games:
			for warning in game.warnings:
				all.append("%s: %s" % [game.id, warning])
		return all


static func scan(root: String) -> ScanResult:
	var result := ScanResult.new()

	var dir := DirAccess.open(root)
	if dir == null:
		result.errors.append("cannot open %s (%s)"
			% [root, error_string(DirAccess.get_open_error())])
		return result

	var folder_names := dir.get_directories()
	folder_names.sort()
	for folder_name in folder_names:
		if folder_name.begins_with("."):
			continue
		var game := _load_game(root.path_join(folder_name), folder_name, result.errors)
		if game != null:
			result.games.append(game)

	result.games.sort_custom(func(a: GameEntry, b: GameEntry) -> bool:
		return a.name.naturalnocasecmp_to(b.name) < 0)
	return result


## Returns null and appends to `errors` when the folder is not launchable.
static func _load_game(dir_path: String, id: String, errors: PackedStringArray) -> GameEntry:
	var manifest_path := dir_path.path_join("game.json")
	if not FileAccess.file_exists(manifest_path):
		errors.append("%s: no game.json" % id)
		return null

	var text := FileAccess.get_file_as_string(manifest_path)
	if text.is_empty() and FileAccess.get_open_error() != OK:
		errors.append("%s: cannot read game.json (%s)"
			% [id, error_string(FileAccess.get_open_error())])
		return null

	var json := JSON.new()
	if json.parse(text) != OK:
		errors.append("%s: game.json is not valid JSON - %s on line %d"
			% [id, json.get_error_message(), json.get_error_line()])
		return null
	if typeof(json.data) != TYPE_DICTIONARY:
		errors.append("%s: game.json must contain a JSON object" % id)
		return null

	var manifest: Dictionary = json.data

	# A game may opt out of the launcher entirely with "hide": true - a work in
	# progress, a seasonal title parked for later, a helper binary that ships in
	# the games folder but is not meant to be picked. It is deliberately absent,
	# not broken, so it is skipped silently: no entry, and no error or warning
	# either (returning null without touching `errors`). Only a real boolean
	# true hides; a stray string or number is ignored rather than trusted.
	if manifest.get("hide", false) == true:
		return null

	var game := GameEntry.new()
	game.id = id
	game.dir_path = dir_path
	game.name = str(manifest.get("name", "")).strip_edges()
	if game.name.is_empty():
		game.name = id.replace("-", " ").replace("_", " ").capitalize()
		game.warnings.append("game.json has no \"name\", using the folder name")
	game.description = str(manifest.get("description", "")).strip_edges()
	game.creators = _read_creators(manifest)
	game.players = maxi(1, int(manifest.get("players", 1)))

	for arg in manifest.get("args", []):
		game.args.append(str(arg))

	game.executable = _resolve_executable(manifest, dir_path, id, errors, game)
	if game.executable.is_empty():
		return null

	_load_icon_path(game)
	_load_keymap(game)
	return game


## "creators" is either a list of names or a single string, because a one-person
## game written by hand will reach for the string form. Blank entries are
## dropped so a stray "" does not turn into an empty name in the credit line.
static func _read_creators(manifest: Dictionary) -> PackedStringArray:
	var names := PackedStringArray()
	var value: Variant = manifest.get("creators", [])
	var raw: Array = value if typeof(value) == TYPE_ARRAY else [value]
	for entry in raw:
		var name := str(entry).strip_edges()
		if not name.is_empty():
			names.append(name)
	return names


static func _resolve_executable(manifest: Dictionary, dir_path: String, id: String,
		errors: PackedStringArray, game: GameEntry) -> String:
	var declared := str(manifest.get("executable", "")).strip_edges()
	if declared.is_empty():
		errors.append("%s: game.json has no \"executable\"" % id)
		return ""

	# Relative paths are the normal case and resolve inside the game folder;
	# an absolute path is allowed so a folder can point at a system binary.
	var path := declared if declared.is_absolute_path() else dir_path.path_join(declared)
	path = path.simplify_path()
	if not FileAccess.file_exists(path):
		errors.append("%s: executable \"%s\" not found" % [id, declared])
		return ""

	if OS.has_feature("linux"):
		var mode := FileAccess.get_unix_permissions(path)
		if mode > 0 and (mode & FileAccess.UNIX_EXECUTE_OWNER) == 0:
			game.warnings.append("%s is not executable - run chmod +x on it" % declared)

	return path


static func _load_icon_path(game: GameEntry) -> void:
	var path := game.dir_path.path_join("icon.png")
	if FileAccess.file_exists(path):
		game.icon_path = path
	else:
		game.warnings.append("no icon.png, showing a placeholder")


static func _load_keymap(game: GameEntry) -> void:
	var path := game.dir_path.path_join("keymap.json")
	if not FileAccess.file_exists(path):
		game.warnings.append("no keymap.json, the launcher mapping will stay active")
		return

	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK:
		game.warnings.append("keymap.json is not valid JSON - %s on line %d"
			% [json.get_error_message(), json.get_error_line()])
		return
	if typeof(json.data) != TYPE_DICTIONARY:
		game.warnings.append("keymap.json must contain a JSON object")
		return

	var problems := KeymapWriter.validate(json.data)
	if not problems.is_empty():
		game.warnings.append("keymap.json rejected: " + ", ".join(problems))
		return

	game.keymap = json.data
