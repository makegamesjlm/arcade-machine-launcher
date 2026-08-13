class_name GameEntry
extends RefCounted
## One installed game, built from a /games/<id>/ folder.

## Folder name, e.g. "my-game". Unique, and used as a stable sort key fallback.
var id: String = ""
## Absolute path of the game's folder.
var dir_path: String = ""

var name: String = ""
var description: String = ""
## Who made the game, from the optional "creators" key. Empty when the manifest
## does not credit anyone.
var creators: PackedStringArray = PackedStringArray()
## Absolute path of the binary to run.
var executable: String = ""
## Extra arguments passed to the executable, from the optional "args" key.
var args: PackedStringArray = PackedStringArray()
var players: int = 1
## Absolute path of icon.png, or "" when the folder has none.
var icon_path: String = ""
## Contents of the game's keymap.json. Empty means "keep the launcher default".
var keymap: Dictionary = {}

## Non-fatal problems found while loading, e.g. a missing icon or a keymap entry
## the remap service will not understand. The game is still playable; the
## launcher shows these so a broken install is visible instead of silent.
var warnings: PackedStringArray = PackedStringArray()


func players_label() -> String:
	return "1 player" if players <= 1 else "%d players" % players


## "By Ada, Grace", or "" when nobody is credited.
func creators_label() -> String:
	if creators.is_empty():
		return ""
	return "By " + ", ".join(creators)


func _to_string() -> String:
	return "GameEntry(%s at %s)" % [id, dir_path]
