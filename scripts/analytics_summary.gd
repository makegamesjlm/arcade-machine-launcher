class_name AnalyticsSummary
extends RefCounted
## Renders `summary.txt` from the JSONL event logs beside it - the readable half
## of what Analytics records, so the question "what gets played" can be answered
## by opening one file in the synced folder rather than by parsing anything.
##
## Derived, never accumulated: every call re-reads every .jsonl in the directory
## and rewrites the file from scratch. That costs nothing at cabinet volumes (a
## year of heavy use is a few thousand short lines, parsed at the moment a game
## exits, when nothing on screen is time-critical) and buys three things worth
## more than the cycles - the two files can never drift apart, a mistake in the
## arithmetic here is a code fix rather than lost history, and a session left
## dangling by a power cut is simply skipped on the next pass instead of
## poisoning a running total forever.
##
## The write is atomic (temp file, then rename), same as KeymapWriter's, so a
## cabinet that loses power mid-write still has the previous summary rather than
## half of a new one.

const FILENAME := "summary.txt"

# The reason vocabulary lives on Analytics, which is an autoload - a scene-tree
# node, not a compile-time class - so it cannot be const-folded into a `const`
# table here. These are plain static functions instead, called a handful of
# times per render, which keeps the strings defined in exactly one place.

## Sessions whose reason is one of these never actually ran, so they are not
## plays. They are counted as problems instead - see the NEEDS ATTENTION block.
static func _never_ran() -> Array:
	return [Analytics.REASON_LAUNCH_FAILED]


## How each recorded reason reads in the endings breakdown, in the order it is
## listed there: the good outcome first, the merely uninformative last. Any
## reason missing from this table still counts, under its raw name, so adding
## one to Analytics without touching this file degrades rather than breaks.
static func _reason_labels() -> Dictionary:
	return {
		Analytics.REASON_QUIT: "Finished on their own",
		Analytics.REASON_CLOSED_FROM_OVERLAY: "Closed from the menu",
		Analytics.REASON_REPLACED: "Swapped for another game",
		Analytics.REASON_IDLE_KILLED: "Timed out, nobody there",
		Analytics.REASON_CRASHED_EARLY: "Crashed on startup",
		Analytics.REASON_EXITED_NONZERO: "Exited with an error",
		Analytics.REASON_LAUNCH_FAILED: "Failed to launch",
		Analytics.REASON_VANISHED: "Disappeared unexpectedly",
		Analytics.REASON_HARD_RESET: "Ended by a hard reset",
		Analytics.REASON_LAUNCHER_EXIT: "Open when the launcher quit",
	}


## The three per-game columns. Deliberately not exhaustive and deliberately not
## made to sum to 100%: they are the three endings that say something about the
## game itself. Everything else is in the endings breakdown below the table.
static func _finished_reasons() -> Array:
	return [Analytics.REASON_QUIT]


static func _early_reasons() -> Array:
	return [Analytics.REASON_CLOSED_FROM_OVERLAY, Analytics.REASON_REPLACED]


static func _timed_out_reasons() -> Array:
	return [Analytics.REASON_IDLE_KILLED]

## A game paused more often than this is usually one with no obvious way to
## quit, so players white-button out of it instead. Worth an operator's
## attention; below it, it is just somebody taking a break.
const HOLD_RATE_NOTABLE := 0.25

## The trailing window given its own table, alongside the all-time one. Lifetime
## popularity and what is being played this week are different questions, and at
## an event it is the second one that matters.
const RECENT_DAYS := 30

const SECONDS_PER_DAY := 86400.0


## Reads every log in `dir` and rewrites `dir/summary.txt`. Returns "" on
## success, or a message explaining what went wrong.
static func write(dir: String) -> String:
	var sessions := _read_sessions(dir)
	return _write_atomic(dir.path_join(FILENAME), render(sessions))


## Every completed session in the directory, oldest first. Simulated sessions
## and sessions whose game never started are filtered by the callers that care;
## dangling opens (a power cut, a still-running game) never appear at all, since
## only game_close lines carry an outcome to summarise.
static func _read_sessions(dir: String) -> Array[Dictionary]:
	var sessions: Array[Dictionary] = []
	var access := DirAccess.open(dir)
	if access == null:
		return sessions

	var names := access.get_files()
	names.sort()  # YYYY-MM sorts chronologically as text
	for name in names:
		if not name.ends_with(".jsonl"):
			continue
		for line in FileAccess.get_file_as_string(dir.path_join(name)).split("\n", false):
			var parsed: Variant = JSON.parse_string(line)
			if typeof(parsed) != TYPE_DICTIONARY:
				continue  # a torn last line from a power cut, or hand-editing
			var event: Dictionary = parsed
			if event.get("event") != "game_close" or event.get("simulated", false):
				continue
			sessions.append(event)
	return sessions


static func render(sessions: Array[Dictionary]) -> String:
	# Sorted here rather than assumed. The logs are written in order and read in
	# order, so this is normally a no-op - but everything below takes "oldest
	# first" for granted (the date range, which name is a game's current one),
	# and a hand-merged or hand-edited file should still summarise sanely rather
	# than reporting a nonsense span.
	var ordered: Array[Dictionary] = sessions.duplicate()
	ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return _unix_of(a) < _unix_of(b))

	var lines := PackedStringArray()
	lines.append("Arcade analytics - updated %s" % Time.get_datetime_string_from_system(true, true))

	var played := _played(ordered)
	if played.is_empty():
		lines.append("")
		lines.append("No games played yet.")
		# "No plays" and "nothing happened" are not the same thing: a cabinet
		# where every launch failed has no plays and a great deal to say, so the
		# problem block still runs.
		var failures := _attention(ordered)
		if not failures.is_empty():
			lines.append("")
			lines.append("NEEDS ATTENTION")
			lines.append_array(failures)
		lines.append("")
		return "\n".join(lines) + "\n"

	var first := _day_of(played[0])
	var last := _day_of(played[played.size() - 1])
	var days := _days_between(played[0], played[played.size() - 1]) + 1
	lines.append("Covering %s to %s (%d day%s)" % [first, last, days, "" if days == 1 else "s"])

	lines.append("")
	lines.append("TOTAL")
	lines.append("  Plays              %s" % _count(played.size()))
	lines.append("  Playtime           %s      (actual play, excludes paused time)"
		% _duration(_total_active(played)))
	lines.append("  Plays per day      %s" % ("%.1f" % (float(played.size()) / float(days))))

	lines.append("")
	lines.append_array(_game_table("BY GAME", played))

	var recent := _within_last_days(played, RECENT_DAYS)
	# Only worth a second table once there is a meaningfully longer history to
	# contrast it with; on a two-week-old cabinet it would just repeat the first.
	if days > RECENT_DAYS and not recent.is_empty():
		lines.append("")
		lines.append_array(_game_table("LAST %d DAYS" % RECENT_DAYS, recent))

	lines.append("")
	lines.append_array(_endings(ordered))

	var attention := _attention(ordered)
	if not attention.is_empty():
		lines.append("")
		lines.append("NEEDS ATTENTION")
		lines.append_array(attention)

	lines.append("")
	return "\n".join(lines) + "\n"


# --- the per-game table ----------------------------------------------------------

## The name column is sized to the longest game name actually present, so a
## cabinet with short names does not get a table of mostly whitespace, with a
## floor that keeps the widest section heading fitting above it.
const NAME_MIN_WIDTH := 22

## Widths of the six numeric columns, in order. Shared by the header and the
## rows so the two cannot drift apart.
const COLUMN_WIDTHS := [8, 11, 10, 11, 13, 12]


static func _game_table(title: String, played: Array[Dictionary]) -> PackedStringArray:
	var by_game := {}
	for session in played:
		var id: String = session.get("game", "")
		if not by_game.has(id):
			# Typed, so the buckets can be handed straight to the Array[Dictionary]
			# helpers below without a conversion error.
			var bucket: Array[Dictionary] = []
			by_game[id] = bucket
		by_game[id].append(session)

	var ids := by_game.keys()
	# Most-played first: the ordering this table exists to show. Ties break on
	# name so the file does not reshuffle two equal games on every rewrite.
	ids.sort_custom(func(a: String, b: String) -> bool:
		var count_a: int = by_game[a].size()
		var count_b: int = by_game[b].size()
		if count_a != count_b:
			return count_a > count_b
		return a.naturalnocasecmp_to(b) < 0)

	var width := NAME_MIN_WIDTH
	for id: String in ids:
		width = maxi(width, _display_name(by_game[id]).length())

	var lines := PackedStringArray()
	lines.append(_row(title, width,
		["plays", "playtime", "typical", "finished", "quit early", "timed out"]))
	for id: String in ids:
		var group: Array[Dictionary] = by_game[id]
		lines.append(_row(_display_name(group), width, [
			_count(group.size()),
			_duration(_total_active(group)),
			_duration(_median(_actives(group))),
			_percent(_share(group, _finished_reasons())),
			_percent(_share(group, _early_reasons())),
			_percent(_share(group, _timed_out_reasons())),
		]))
	return lines


## One fixed-width table line: a left-aligned label, then right-aligned cells.
static func _row(label: String, width: int, cells: Array) -> String:
	var text := "  " + label.rpad(width)
	for i in cells.size():
		text += String(cells[i]).lpad(COLUMN_WIDTHS[i])
	return text


## What to call this game in the table. Taken from the most recent session, so
## renaming a game in its game.json is reflected without orphaning its history -
## the folder id stays the grouping key throughout.
static func _display_name(group: Array) -> String:
	var latest: Dictionary = group[group.size() - 1]
	var name := String(latest.get("name", ""))
	return name if not name.is_empty() else String(latest.get("game", ""))


# --- the endings breakdown --------------------------------------------------------

## Counts every recorded session, including the ones that never ran - this is
## the block that must add up to the whole picture, so "failed to launch" and
## "ended by a hard reset" belong here even though they are not plays.
static func _endings(sessions: Array[Dictionary]) -> PackedStringArray:
	var real := _real(sessions)
	var counts := {}
	for session in real:
		var reason: String = session.get("reason", "unknown")
		counts[reason] = int(counts.get(reason, 0)) + 1

	var labels := _reason_labels()
	var lines := PackedStringArray()
	lines.append("HOW SESSIONS ENDED")
	# Labelled order first, so the good outcome leads and the block reads the
	# same way every time; anything unlabelled follows, under its raw name.
	var ordered := labels.keys()
	for reason: String in counts:
		if not ordered.has(reason):
			ordered.append(reason)
	for reason: String in ordered:
		if not counts.has(reason):
			continue
		var count := int(counts[reason])
		lines.append("  %s %s   %s"
			% [
				String(labels.get(reason, reason)).rpad(26),
				_count(count).lpad(6),
				_percent(float(count) / float(real.size())).lpad(4),
			])
	return lines


# --- the problem block ------------------------------------------------------------

## Only rendered when it has something in it. Launch failures per game make a
## broken deploy - an executable that lost its +x bit in the sync, a keymap the
## remapper will not take - obvious without reading the journal.
static func _attention(sessions: Array[Dictionary]) -> PackedStringArray:
	var never_ran := _never_ran()
	var by_game := {}
	for session in _real(sessions):
		var id: String = session.get("game", "")
		if not by_game.has(id):
			by_game[id] = {"failed": 0, "crashed": 0, "plays": 0, "held": 0, "sessions": []}
		var stats: Dictionary = by_game[id]
		stats["sessions"].append(session)
		var reason: String = session.get("reason", "")
		if reason == Analytics.REASON_LAUNCH_FAILED:
			stats["failed"] += 1
		elif reason == Analytics.REASON_CRASHED_EARLY:
			stats["crashed"] += 1
		if not never_ran.has(reason):
			stats["plays"] += 1
			if int(session.get("hold_count", 0)) > 0:
				stats["held"] += 1

	var ids := by_game.keys()
	ids.sort()

	var lines := PackedStringArray()
	for id: String in ids:
		var stats: Dictionary = by_game[id]
		var notes := PackedStringArray()
		if int(stats["failed"]) > 0:
			notes.append("%d launch failure%s"
				% [stats["failed"], "" if int(stats["failed"]) == 1 else "s"])
		if int(stats["crashed"]) > 0:
			notes.append("%d early crash%s"
				% [stats["crashed"], "" if int(stats["crashed"]) == 1 else "es"])
		var plays := int(stats["plays"])
		if plays > 0 and float(stats["held"]) / float(plays) >= HOLD_RATE_NOTABLE:
			notes.append("paused mid-game in %s of sessions"
				% _percent(float(stats["held"]) / float(plays)))
		if not notes.is_empty():
			lines.append("  %s %s"
				% [_display_name(stats["sessions"]).rpad(NAME_MIN_WIDTH), ", ".join(notes)])
	return lines


# --- selecting and measuring ------------------------------------------------------

## Sessions that count as somebody playing: a real run (not simulated) of a game
## that actually started.
static func _played(sessions: Array[Dictionary]) -> Array[Dictionary]:
	var never_ran := _never_ran()
	var out: Array[Dictionary] = []
	for session in _real(sessions):
		if not never_ran.has(session.get("reason", "")):
			out.append(session)
	return out


## Every real session, including the ones that never ran. Simulated sessions are
## already filtered when reading, but render() is also called directly by the
## tests, so the guard lives here too rather than only at the file boundary.
static func _real(sessions: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for session in sessions:
		if not session.get("simulated", false):
			out.append(session)
	return out


static func _within_last_days(played: Array[Dictionary], days: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if played.is_empty():
		return out
	var newest := _unix_of(played[played.size() - 1])
	var cutoff := newest - float(days) * SECONDS_PER_DAY
	for session in played:
		if _unix_of(session) >= cutoff:
			out.append(session)
	return out


static func _actives(sessions: Array[Dictionary]) -> Array[float]:
	var out: Array[float] = []
	for session in sessions:
		out.append(float(session.get("active_seconds", 0.0)))
	return out


static func _total_active(sessions: Array[Dictionary]) -> float:
	var total := 0.0
	for session in sessions:
		total += float(session.get("active_seconds", 0.0))
	return total


## The share of `sessions` that ended for one of `reasons`.
static func _share(sessions: Array[Dictionary], reasons: Array) -> float:
	if sessions.is_empty():
		return 0.0
	var matched := 0
	for session in sessions:
		if reasons.has(session.get("reason", "")):
			matched += 1
	return float(matched) / float(sessions.size())


## The middle session, not the mean: one player who wandered off and left a game
## running until the idle-kill would drag an average badly, and the number is
## meant to answer "what does a normal go at this look like".
static func _median(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	var middle := floori(sorted.size() / 2.0)
	if sorted.size() % 2 == 1:
		return sorted[middle]
	return (sorted[middle - 1] + sorted[middle]) * 0.5


# --- time and formatting -----------------------------------------------------------

## The "Z" Analytics writes is correct and is what makes the log unambiguous,
## but Godot's ISO parser does not accept it, so it comes off here.
static func _unix_of(session: Dictionary) -> float:
	return Time.get_unix_time_from_datetime_string(
		String(session.get("time", "")).trim_suffix("Z"))


static func _day_of(session: Dictionary) -> String:
	return String(session.get("time", "")).split("T")[0]


static func _days_between(first: Dictionary, last: Dictionary) -> int:
	return int(floor((_unix_of(last) - _unix_of(first)) / SECONDS_PER_DAY))


## "92h 14m" / "3m 51s" / "45s" - two units at most, since a third never
## changes what anyone does about the number.
static func _duration(seconds: float) -> String:
	var total := int(round(seconds))
	if total >= 3600:
		return "%dh %02dm" % [floori(total / 3600.0), floori(float(total % 3600) / 60.0)]
	if total >= 60:
		return "%dm %02ds" % [floori(total / 60.0), total % 60]
	return "%ds" % total


## Thousands separators, because these are numbers an operator reads at a
## glance rather than computes with.
static func _count(value: int) -> String:
	var text := str(value)
	var out := ""
	var digits := 0
	for i in range(text.length() - 1, -1, -1):
		out = text[i] + out
		digits += 1
		if digits % 3 == 0 and i > 0:
			out = "," + out
	return out


static func _percent(share: float) -> String:
	return "%d%%" % int(round(share * 100.0))


## Temp file then rename, so the previous summary survives a power cut mid-write.
static func _write_atomic(path: String, text: String) -> String:
	var dir := path.get_base_dir()
	var tmp_path := dir.path_join(".%s.tmp" % path.get_file())
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		return "cannot write %s (%s)" % [tmp_path, error_string(FileAccess.get_open_error())]
	file.store_string(text)
	file.close()

	var rename_err := DirAccess.rename_absolute(tmp_path, path)
	if rename_err != OK:
		DirAccess.remove_absolute(tmp_path)
		return "cannot replace %s (%s)" % [path, error_string(rename_err)]
	return ""
