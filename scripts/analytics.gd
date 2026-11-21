extends Node
## Records one line per game open and one per game close, so the cabinet can
## answer "what actually gets played". Autoloaded as `Analytics`.
##
## Files live in Cfg.analytics_dir (`~/Nextcloud/Arcade/analytics` by default),
## beside config.json and the attract video, so play data leaves the cabinet the
## same way games arrive on it - Nextcloud carries it, no server, no network
## code here:
##
##   2026-09.jsonl   append-only, one JSON object per line, rotated monthly
##   summary.txt     plain-text totals, rewritten after every session
##
## The JSONL is the source of truth; summary.txt is derived from it by
## AnalyticsSummary and may be deleted or regenerated at any time.
##
## A session is not simply launch -> exit. SessionController freezes the game
## and parks it in the background for the system overlay, attract mode, and a
## return to the grid (GameLauncher.hold()), then thaws it again, so a game can
## be *open* for half an hour having been *played* for four minutes. The frozen
## stretches are measured here and subtracted, which is the difference between
## `wall_seconds` and `active_seconds`; without it every attract timeout would
## silently inflate a play.
##
## Nothing here may take the cabinet down. Every filesystem failure disables
## further recording for the run and is surfaced through `problems`, which
## main.gd folds into the on-screen problem strip beside scan and config
## trouble - play data quietly not being recorded is exactly the sort of thing
## nobody notices until they go looking for it.

## How a session ended. The first three are the endings only SessionController
## can tell apart (see note_close_reason); the rest are derived from
## GameLauncher's own signals. Constants rather than bare strings so the call
## sites in session_controller.gd cannot drift from the readers here and in
## AnalyticsSummary.
const REASON_CLOSED_FROM_OVERLAY := "closed_from_overlay"
const REASON_REPLACED := "replaced"
const REASON_IDLE_KILLED := "idle_killed"
const REASON_HARD_RESET := "hard_reset"
## The game exited on its own, which on a cabinet means the player chose to
## leave it - the ending worth having a lot of.
const REASON_QUIT := "quit"
const REASON_EXITED_NONZERO := "exited_nonzero"
const REASON_CRASHED_EARLY := "crashed_early"
const REASON_LAUNCH_FAILED := "launch_failed"
const REASON_VANISHED := "vanished"
const REASON_LAUNCHER_EXIT := "launcher_exit"

## Anything wrong with recording - an unwritable folder, a summary that would
## not render. Empty when all is well. Read by main.gd on every refresh.
var problems: PackedStringArray = PackedStringArray()

## Set on the first write failure. A cabinet whose Nextcloud folder has gone
## missing must report that once, not push a warning for every session for the
## rest of the day.
var _disabled := false
## Tracked separately from _disabled: a summary that will not render does not
## stop event logging, since the JSONL is the half that matters and the summary
## can always be rebuilt from it later.
var _summary_failed := false

## Distinguishes runs, and - together with uptime_ms on every line - keeps
## events orderable even if the wall clock jumps when NTP settles some way into
## a boot.
var _boot_id := ""

## The session currently open, or "" between sessions. The display name rides
## along on both lines so each one stands on its own when read directly, and so
## the summary can title a game without cross-referencing its open line.
var _game_id := ""
var _game_name := ""
## Ticks at `started`, or -1 for a launch that never got that far. Also what
## tells launch_failed from crashed_early.
var _started_at_msec := -1
## Total frozen (held) milliseconds so far this session, and the tick the
## current frozen stretch began, or -1 while the game is actually running.
var _frozen_msec := 0
var _frozen_since_msec := -1
var _hold_count := 0
## Set by note_close_reason() and consumed by the close it describes.
var _pending_reason := ""


func _ready() -> void:
	_boot_id = "%08x" % randi()


## Wires this to the GameLauncher main.gd owns. Everything below is observed
## from that one object's signals, so no part of the launch lifecycle has to
## know analytics exists; SessionController's note_close_reason() calls are the
## single exception, and only because it knows things the signals cannot say.
func bind(launcher: GameLauncher) -> void:
	launcher.preparing.connect(_on_preparing)
	launcher.started.connect(_on_started)
	launcher.finished.connect(_on_finished)
	launcher.failed.connect(_on_failed)
	launcher.held_game_vanished.connect(_on_vanished)
	launcher.held.connect(_on_held)
	launcher.resumed.connect(_on_resumed)


## Tells the next close what kind of ending it was. By the time `finished`
## fires there is nothing left to distinguish a player quitting the game from
## the inside from an attendant closing it out of the system overlay, or from
## the idle-kill reaping it at 3am - only SessionController knows, and only
## before it asks for the close.
func note_close_reason(reason: String) -> void:
	_pending_reason = reason


# --- the session lifecycle -----------------------------------------------------

## Opened at `preparing`, not `started`, so a launch that dies on the pad (a
## keymap that will not install, a binary that will not execute) still produces
## a matched open/close pair. Every session therefore has exactly one of each,
## which is what keeps the analysis simple; the ones that never ran are the
## ones with reason launch_failed and wall_seconds 0.
func _on_preparing(game: GameEntry) -> void:
	_game_id = game.id
	_game_name = game.name
	_started_at_msec = -1
	_frozen_msec = 0
	_frozen_since_msec = -1
	_hold_count = 0
	_pending_reason = ""
	_write({"event": "game_open", "game": game.id, "name": game.name})


## Timing starts here rather than at `preparing`, so the documented
## keymap_reload_seconds wait before a game with its own mapping is never
## counted as somebody playing it.
func _on_started(_game: GameEntry) -> void:
	_started_at_msec = Time.get_ticks_msec()


func _on_held(_game: GameEntry) -> void:
	if _frozen_since_msec >= 0:
		return
	_hold_count += 1
	_frozen_since_msec = Time.get_ticks_msec()


func _on_resumed(_game: GameEntry) -> void:
	_bank_frozen_time()


func _on_finished(_game: GameEntry, exit_code: int) -> void:
	var derived := REASON_QUIT if exit_code == 0 else REASON_EXITED_NONZERO
	_close(derived, exit_code)


## Never having reached `started` means it died on the launch pad; anything
## after that is GameLauncher's CRASH_WINDOW_SECONDS verdict on a game that
## came up and fell straight over.
func _on_failed(_game: GameEntry, _reason: String) -> void:
	_close(REASON_CRASHED_EARLY if _started_at_msec >= 0 else REASON_LAUNCH_FAILED)


## A held game whose process disappeared on its own. Unambiguous, so it ignores
## any pending reason: a deliberate close sets GameLauncher's own _closing flag
## and comes back through finished/failed instead, never through here.
func _on_vanished(_game: GameEntry) -> void:
	_close(REASON_VANISHED, -1, true)


## Closes the open session now, for a caller that knows the launcher is about to
## go away and that no finished/failed signal is coming - the hard reset, whose
## game dies with us in the systemd cgroup and whose exit is therefore never
## collected. Called *before* get_tree().quit() rather than left to _exit_tree()
## below, because that runs during teardown, where the order autoloads are freed
## in is not guaranteed and Cfg may already be gone.
func close_open_session(reason: String) -> void:
	_close(reason, -1, true)


## Best-effort backstop for the exits nothing announces - a plain quit in
## development, a SIGTERM from systemd. Deliberately not relied on for the hard
## reset (see close_open_session). A power cut is the one ending nothing can
## catch at all: it leaves a game_open with no game_close, which is exactly what
## an abandoned session should look like in the data.
func _exit_tree() -> void:
	if is_instance_valid(Cfg):
		_close(REASON_LAUNCHER_EXIT)


## `forced` ignores any reason SessionController had pending, for the endings
## that are certain from the signal alone.
func _close(derived_reason: String, exit_code: int = -1, forced := false) -> void:
	if _game_id.is_empty():
		return  # nothing open: a second signal for one session, or a close with no launch

	_bank_frozen_time()  # still frozen when it ended, e.g. the idle-kill
	var wall_msec := 0 if _started_at_msec < 0 else Time.get_ticks_msec() - _started_at_msec
	var reason := derived_reason if forced or _pending_reason.is_empty() else _pending_reason

	var game_id := _game_id
	var game_name := _game_name
	# Cleared before the write, so a failure in there cannot leave a session
	# half-open and get it closed a second time by _exit_tree().
	_game_id = ""
	_game_name = ""
	_pending_reason = ""

	_write({
		"event": "game_close",
		"game": game_id,
		"name": game_name,
		"reason": reason,
		"exit_code": exit_code,
		"wall_seconds": snappedf(wall_msec / 1000.0, 0.01),
		"active_seconds": snappedf(maxi(0, wall_msec - _frozen_msec) / 1000.0, 0.01),
		"hold_count": _hold_count,
	})
	_refresh_summary()


func _bank_frozen_time() -> void:
	if _frozen_since_msec < 0:
		return
	_frozen_msec += Time.get_ticks_msec() - _frozen_since_msec
	_frozen_since_msec = -1


# --- writing --------------------------------------------------------------------

## Every line carries the same three-field header: a UTC timestamp for humans
## and for grouping by day, uptime for ordering within a boot when the clock
## cannot be trusted, and the boot id that scopes it.
func _write(fields: Dictionary) -> void:
	if _disabled:
		return
	var line := {
		"time": Time.get_datetime_string_from_system(true) + "Z",
		"uptime_ms": Time.get_ticks_msec(),
		"boot": _boot_id,
	}
	line.merge(fields)
	if Cfg.simulate_launch:
		# Tagged rather than dropped, so the writer can be exercised on a dev
		# machine without fake sessions reaching the summary.
		line["simulated"] = true
	_append(JSON.stringify(line, "", false) + "\n")


## One file per month, so a cabinet that runs for years does not grow a single
## unbounded log and a season can be archived by moving one file out.
func _log_path() -> String:
	var now := Time.get_datetime_dict_from_system(true)
	return Cfg.analytics_dir.path_join("%04d-%02d.jsonl" % [now["year"], now["month"]])


## Opens and closes the file per line. Holding the handle open across a session
## would keep the last line unflushed exactly when a cabinet is most likely to
## lose power, and would leave Nextcloud syncing a file with a live writer on
## it. A few lines a minute makes the cost irrelevant.
func _append(text: String) -> void:
	if not _ensure_dir():
		return
	var path := _log_path()
	var file := FileAccess.open(path,
		FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	if file == null:
		_disable("cannot write %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		return
	file.seek_end()
	file.store_string(text)
	file.close()


## setup-arcade.sh creates ~/Nextcloud/Games but nothing under ~/Nextcloud/Arcade
## - that folder arrives with the first synced config or attract video, and on a
## fresh cabinet may not exist at all - so this makes the whole chain rather than
## one level.
func _ensure_dir() -> bool:
	if DirAccess.dir_exists_absolute(Cfg.analytics_dir):
		return true
	var err := DirAccess.make_dir_recursive_absolute(Cfg.analytics_dir)
	if err != OK:
		_disable("cannot create %s (%s)" % [Cfg.analytics_dir, error_string(err)])
		return false
	return true


func _refresh_summary() -> void:
	if _disabled or _summary_failed:
		return
	var error := AnalyticsSummary.write(Cfg.analytics_dir)
	if error.is_empty():
		return
	_summary_failed = true
	problems.append("summary: " + error)
	push_warning("[analytics] summary: " + error)


func _disable(message: String) -> void:
	_disabled = true
	problems.append(message + " - not recording")
	push_warning("[analytics] " + message + " - recording disabled for this run")
