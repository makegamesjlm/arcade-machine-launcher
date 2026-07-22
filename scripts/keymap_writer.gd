class_name KeymapWriter
extends RefCounted
## Validates cabinet keymaps and installs them where shanwan-remap watches.
##
## The write is atomic: the JSON goes to a dot-file in the same directory and is
## then renamed over the target. The remap service polls that file, so a
## non-atomic write could hand it a half-finished document.

## Checks a keymap without touching the filesystem. Returns human-readable
## problems; an empty array means the keymap is good.
static func validate(keymap: Dictionary) -> PackedStringArray:
	var problems := PackedStringArray()
	if keymap.is_empty():
		problems.append("keymap is empty")
		return problems

	var seen_targets := {}
	for key in keymap:
		if typeof(key) != TYPE_STRING:
			problems.append("button name %s is not a string" % [key])
			continue
		if not Cfg.CABINET_BUTTONS.has(key):
			problems.append("unknown cabinet button \"%s\" (expected one of: %s)"
				% [key, ", ".join(Cfg.CABINET_BUTTONS)])
			continue

		var target: Variant = keymap[key]
		if typeof(target) != TYPE_STRING:
			problems.append("\"%s\" maps to %s, which is not a string" % [key, target])
			continue
		if not Cfg.XBOX_BUTTONS.has(target):
			problems.append("\"%s\" maps to unknown Xbox button \"%s\" (expected one of: %s)"
				% [key, target, ", ".join(Cfg.XBOX_BUTTONS)])
			continue

		if seen_targets.has(target):
			problems.append("\"%s\" and \"%s\" both map to %s"
				% [seen_targets[target], key, target])
		seen_targets[target] = key

	return problems


## Serializes in cabinet-layout order so the installed file stays readable when
## someone inspects it over SSH.
static func to_json(keymap: Dictionary) -> String:
	var ordered := {}
	for button in Cfg.CABINET_BUTTONS:
		if keymap.has(button):
			ordered[button] = keymap[button]
	for button in keymap:
		if not ordered.has(button):
			ordered[button] = keymap[button]
	# sort_keys must be off or JSON.stringify alphabetizes and the layout is lost.
	return JSON.stringify(ordered, "  ", false) + "\n"


## Installs `keymap` at `path`. Returns "" on success, or a message explaining
## what went wrong and what the operator should do about it.
static func install(keymap: Dictionary, path: String) -> String:
	var problems := validate(keymap)
	if not problems.is_empty():
		return "refusing to install an invalid keymap: " + ", ".join(problems)

	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		return "%s does not exist - run scripts/setup-arcade.sh on the cabinet" % dir

	var tmp_path := dir.path_join(".%s.tmp" % path.get_file())
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		var err := FileAccess.get_open_error()
		if err == ERR_FILE_NO_PERMISSION:
			return ("no permission to write in %s - run scripts/setup-arcade.sh "
				+ "to grant the arcade user access") % dir
		return "cannot write %s (%s)" % [tmp_path, error_string(err)]

	file.store_string(to_json(keymap))
	file.close()

	var rename_err := DirAccess.rename_absolute(tmp_path, path)
	if rename_err != OK:
		DirAccess.remove_absolute(tmp_path)
		return "cannot replace %s (%s)" % [path, error_string(rename_err)]

	return ""
