extends Node
## Exercises the three interactive --simulate-launch outcomes without opening a
## window or starting a platform-specific process.

var _events: Array[String] = []
var _failures := 0


func _ready() -> void:
	Cfg.simulate_launch = true
	Cfg.keymap_path = ProjectSettings.globalize_path("res://dev/keymap.json")

	var game := _find_fixture("neon-drift")
	if game == null:
		_failures += 1
		printerr("FAIL could not load the neon-drift fixture")
		get_tree().quit(1)
		return

	var launcher := GameLauncher.new()
	add_child(launcher)
	launcher.started.connect(func(_game: GameEntry) -> void: _events.append("started"))
	launcher.finished.connect(func(_game: GameEntry, _code: int) -> void:
		_events.append("finished"))
	launcher.failed.connect(func(_game: GameEntry, _reason: String) -> void:
		_events.append("failed"))

	launcher.launch(game, GameLauncher.SimulatedOutcome.LAUNCH_FAILURE)
	await get_tree().create_timer(0.6).timeout
	_check(_events == ["failed"], "launch failure emits only failed")

	_events.clear()
	launcher.launch(game, GameLauncher.SimulatedOutcome.EARLY_CRASH)
	await get_tree().create_timer(1.6).timeout
	_check(_events == ["started", "failed"], "early crash starts and then fails")

	_events.clear()
	launcher.launch(game, GameLauncher.SimulatedOutcome.SUCCESS)
	await get_tree().create_timer(0.6).timeout
	_check(_events == ["started"] and launcher.is_busy,
		"successful simulation waits for an explicit finish")
	_check(JSON.parse_string(FileAccess.get_file_as_string(Cfg.keymap_path)) == game.keymap,
		"the game keymap stays installed while the simulation runs")
	_check(launcher.finish_simulated_session(), "successful simulation can be finished")
	_check(_events == ["started", "finished"] and not launcher.is_busy,
		"explicit finish emits finished and clears the busy state")
	_check(JSON.parse_string(FileAccess.get_file_as_string(Cfg.keymap_path)) == Cfg.LAUNCHER_KEYMAP,
		"finishing restores the launcher keymap")

	# Held-game state is meaningless under the simulator - there is no real
	# process to freeze, and simulated sessions finish through
	# finish_simulated_session() rather than the poll loop hold()/close()
	# assume - but it must still report sane defaults rather than whatever a
	# previous real session left behind.
	_check(not launcher.is_held and launcher.held_game == null,
		"a finished simulated session is never held")

	print("%d simulated-launch checks failed" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)


func _find_fixture(id: String) -> GameEntry:
	var fixtures := ProjectSettings.globalize_path("res://dev/games")
	for game in GameScanner.scan(fixtures).games:
		if game.id == id:
			return game
	return null


func _check(passed: bool, label: String) -> void:
	if passed:
		print("  ok   %s" % label)
	else:
		_failures += 1
		printerr("  FAIL %s" % label)
