class_name SplashScreen
extends CanvasLayer
## The JLM Arcade splash animation, shown every time a game is launched.
##
## Purely the picture: SessionController (see _run_launch_splash()) owns the
## sequencing. Played straight from the artist's PNG sequence (Cfg.splash_frames,
## a zip or a folder of frames with alpha), so its transparency is the PNGs'
## own.
##
## The artwork has a stretch in the middle that repeats a short cycle several
## times over (found automatically - see _find_loop()). That cycle is cut out
## and looped, which is what sets the splash's length and lets it cover a game
## that takes longer to load than usual:
##
##   play()         the wipe-in, then the loop, over and over, started the moment
##                  a game is picked, over the grid, while the game loads
##                  underneath.
##   finish_loop()  the game is ready: once the loop has run enough times to
##                  make the splash last Cfg.splash_seconds, it leaves the loop
##                  at the end of a cycle and plays on to the last fully opaque
##                  frame, where it stops (`done`), still covering everything.
##   play_outro()   the wipe-out after it, played once the game's window is
##                  sitting under the launcher's - it uncovers the game. With no
##                  transparent tail, the held frame simply stays up until
##                  dismiss(), and the game is revealed by raising its window.
##
## Artwork with no repeating stretch just plays straight through to its last
## opaque frame and holds there until play_outro().
##
## Every frame is shown for 1 / Cfg.splash_fps seconds (config.json).
##
## Frames are decoded once, on a background thread at startup, and kept on the
## GPU, since decoding a 1080p PNG takes longer than a frame lasts. Repeated
## frames (the artwork holds many) are stored once. Each is block-compressed
## (S3TC/DXT5) when this build can do that, and otherwise halved in size and
## drawn back up with nearest-neighbour filtering, which suits the pixel art -
## either way about a quarter of the memory of raw full-size frames.
##
## Degrades rather than blocking anything: until the frames are ready, or if
## the file is missing or unreadable, is_ready is false and launches skip the
## splash.

signal done
## The frames have finished loading (is_ready is true from now on).
signal loaded

enum Part { NONE, INTRO, OUTRO }

## True once the frames are loaded and a launch can use the splash.
var is_ready: bool:
	get: return not _sequence.is_empty()

## Whether the animation has a transparent tail to play with play_outro().
var has_outro: bool:
	get: return is_ready and _hold_index < _sequence.size() - 1

## True while either part is actually animating (between play()/play_outro()
## and `done`).
var is_playing: bool:
	get: return _part != Part.NONE

## One texture per distinct frame.
var _textures: Array[Texture2D] = []
## For each frame of the sequence, in order, its index into _textures.
var _sequence := PackedInt32Array()
## The last fully opaque frame: where the intro ends and holds, and the outro
## starts.
var _hold_index := 0
## The repeating stretch: one cycle is _loop_period frames from _loop_start,
## and the artwork itself repeats it until _loop_end. _loop_period 0 means
## there is none, and the sequence plays straight through.
var _loop_start := 0
var _loop_period := 0
var _loop_end := 0
## Cycles the loop runs at least, so the whole splash lasts about
## Cfg.splash_seconds.
var _min_loops := 1
## Timeline frame (counted from play()) at which the intro leaves the loop, or
## -1 while it should keep looping (finish_loop() not called yet).
var _exit_at := -1

var _part: int = Part.NONE
## Sequence frame the current part starts from, and when it started.
var _part_first := 0
var _part_last := 0
var _part_started_usec := 0
var _loader: Thread

@onready var _frame: TextureRect = %SplashFrame


func _ready() -> void:
	visible = false
	set_process(false)
	var path := Cfg.splash_frames
	if path.is_empty() or not (FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path)):
		print("[splash] no splash frames at %s; launching games without a splash" % path)
		return
	_loader = Thread.new()
	_loader.start(_load_frames.bind(path))


func _exit_tree() -> void:
	if _loader != null and _loader.is_started():
		_loader.wait_to_finish()


## Starts the animation from the beginning. Does nothing until the frames are
## loaded.
func play() -> void:
	if not is_ready:
		return
	dismiss()  # anything left over from a previous launch
	visible = true
	_exit_at = -1
	if _loop_period > 0:
		# Everything but the loop, up to the frame the splash holds on, plus the
		# wipe-out after it.
		var fixed := _loop_start + (_sequence.size() - _loop_end)
		_min_loops = maxi(1, roundi((Cfg.splash_seconds * Cfg.splash_fps - fixed) / _loop_period))
	_start_part(Part.INTRO, 0, _hold_index)


## Lets the intro leave its loop, once it has looped enough times to make the
## splash last Cfg.splash_seconds, at the end of the cycle it is in - so it
## never cuts a cycle short. It then plays on to the last opaque frame and
## emits `done`. Without a loop this does nothing: the intro was going to stop
## there anyway. Safe to call more than once; only the first call counts.
func finish_loop() -> void:
	if _part != Part.INTRO or _loop_period == 0 or _exit_at >= 0:
		return
	var cycles_done := maxi(0, _timeline_frame() - _loop_start) / _loop_period
	_exit_at = _loop_start + maxi(_min_loops, cycles_done + 1) * _loop_period


## Plays the wipe-out over the held frame. Only meaningful once play() has
## finished; does nothing without a transparent tail (the held frame then stays
## up until dismiss()).
func play_outro() -> void:
	if not has_outro or _part != Part.NONE or not visible:
		return
	_start_part(Part.OUTRO, _hold_index, _sequence.size() - 1)


## Returns once the part playing now is over, or straight away if none is.
func wait_until_done() -> void:
	if _part != Part.NONE:
		await done


## Takes everything down immediately. Safe to call at any time; also releases
## anything waiting in wait_until_done().
func dismiss() -> void:
	var was_playing := _part != Part.NONE
	_part = Part.NONE
	set_process(false)
	visible = false
	_frame.texture = null
	if was_playing:
		done.emit()


func _start_part(part: int, first: int, last: int) -> void:
	_part = part
	_part_first = first
	_part_last = last
	_part_started_usec = Time.get_ticks_usec()
	_show_frame(first)
	set_process(true)


## Advances by the clock rather than by frames drawn, so a hitch while the game
## loads skips frames instead of stretching the animation.
func _process(_delta: float) -> void:
	if _part == Part.NONE:
		set_process(false)
		return
	var index := _sequence_index(_timeline_frame())
	if index < _part_last:
		_show_frame(index)
		return

	_show_frame(_part_last)
	var finished := _part
	_part = Part.NONE
	set_process(false)
	if finished == Part.OUTRO:
		# The last frame of the wipe-out is clear; nothing left to show.
		visible = false
		_frame.texture = null
	# After the intro, its last frame - fully opaque - stays up.
	done.emit()


## Frames elapsed since the current part started.
func _timeline_frame() -> int:
	return int((Time.get_ticks_usec() - _part_started_usec) / 1_000_000.0 * Cfg.splash_fps)


## Which frame of the sequence to show `frame` frames into the current part.
## The outro is straight; the intro loops between _loop_start and _loop_end
## until _exit_at, then carries on from _loop_end exactly as the artwork does
## after its last repeat.
func _sequence_index(frame: int) -> int:
	if _part != Part.INTRO or _loop_period == 0 or frame < _loop_start:
		return _part_first + frame
	if _exit_at < 0 or frame < _exit_at:
		return _loop_start + (frame - _loop_start) % _loop_period
	return _loop_end + (frame - _exit_at)


func _show_frame(index: int) -> void:
	_frame.texture = _textures[_sequence[index]]


# --- loading -------------------------------------------------------------------

## Runs on _loader. Reads every frame, decodes each distinct one once, finds
## the hold frame, and hands the results back to the main thread.
func _load_frames(path: String) -> void:
	var started := Time.get_ticks_msec()
	var files := _read_pngs(path)  # [name, bytes] pairs, in name order
	if files.is_empty():
		_finish_loading.call_deferred([], PackedInt32Array(), 0, Vector3i.ZERO, "no PNG frames found in %s" % path)
		return

	var images: Array[Image] = []
	var sequence := PackedInt32Array()
	var by_hash := {}  # PNG bytes' hash -> index into images
	var opaque := PackedByteArray()  # per distinct image: 1 if fully opaque
	var compress := RenderingServer.has_os_feature("s3tc")
	for file in files:
		var bytes: PackedByteArray = file[1]
		var key := _hash(bytes)
		if by_hash.has(key):
			sequence.append(by_hash[key])
			continue
		var image := Image.new()
		if image.load_png_from_buffer(bytes) != OK:
			_finish_loading.call_deferred([], PackedInt32Array(), 0, Vector3i.ZERO,
				"could not decode %s in %s" % [file[0], path])
			return
		opaque.append(1 if image.detect_alpha() == Image.ALPHA_NONE else 0)
		if compress and image.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_SRGB) != OK:
			compress = false  # this build has no compressor; halve the rest instead
			push_warning("[splash] cannot block-compress frames in this build; halving them instead")
		if not image.is_compressed():
			image.resize(image.get_width() >> 1, image.get_height() >> 1, Image.INTERPOLATE_NEAREST)
		by_hash[key] = images.size()
		sequence.append(images.size())
		images.append(image)

	var hold := sequence.size() - 1
	while hold >= 0 and opaque[sequence[hold]] == 0:
		hold -= 1
	if hold < 0:
		_finish_loading.call_deferred([], PackedInt32Array(), 0, Vector3i.ZERO,
			"no fully opaque frame in %s to hold on while the game loads" % path)
		return

	var loop := _find_loop(sequence)
	if loop.y > 0 and loop.x + loop.y * loop.z > hold:
		push_warning("[splash] the repeating stretch in %s runs past its last opaque frame; "
			% path + "playing it straight through instead of looping")
		loop = Vector3i.ZERO
	var loop_note := ("no repeating stretch to loop" if loop.y == 0
		else "loops frames %d-%d (repeated %d times in the artwork)"
			% [loop.x, loop.x + loop.y - 1, loop.z])

	print("[splash] decoded %d frames (%d distinct, %s) from %s in %d ms; holds on frame %d; %s"
		% [sequence.size(), images.size(),
			"S3TC" if images[0].is_compressed() else "half size",
			path, Time.get_ticks_msec() - started, hold, loop_note])
	_finish_loading.call_deferred(images, sequence, hold, loop, "")


## Main thread: turns the decoded images into textures, a few per frame so the
## launcher never stalls on the upload, then makes the splash available.
func _finish_loading(images: Array, sequence: PackedInt32Array, hold: int, loop: Vector3i,
		error: String) -> void:
	_loader.wait_to_finish()
	_loader = null
	if not error.is_empty():
		push_warning("[splash] %s; launching games without a splash" % error)
		return
	var textures: Array[Texture2D] = []
	for i in images.size():
		textures.append(ImageTexture.create_from_image(images[i]))
		images[i] = null  # its pixels live on the GPU now
		if i % 8 == 7:
			await get_tree().process_frame
	_textures = textures
	_hold_index = hold
	_loop_start = loop.x
	_loop_period = loop.y
	_loop_end = loop.x + loop.y * loop.z
	_sequence = sequence  # last: is_ready keys off it
	loaded.emit()


## Finds the stretch of `sequence` (frames as distinct-image ids) that repeats
## a cycle most: returns (first frame, cycle length, full cycles), or all zeros
## if nothing repeats at least twice. A cycle must show at least two different
## images, so a single frame held for a while does not count as a loop. Of the
## periods covering the same stretch (24, 48, ...) the shortest wins, since it
## is found first and a longer one never covers more.
static func _find_loop(sequence: PackedInt32Array) -> Vector3i:
	var n := sequence.size()
	var best := Vector3i.ZERO
	var best_frames := 0
	for period in range(2, n / 2 + 1):
		var i := 0
		while i + period < n:
			if sequence[i] != sequence[i + period]:
				i += 1
				continue
			var start := i
			while i + period < n and sequence[i] == sequence[i + period]:
				i += 1
			var frames := i - start + period  # how much of the sequence repeats
			var cycles := frames / period
			if cycles >= 2 and frames > best_frames and _distinct(sequence, start, period) >= 2:
				best_frames = frames
				best = Vector3i(start, period, cycles)
	return best


static func _distinct(sequence: PackedInt32Array, from: int, count: int) -> int:
	var seen := {}
	for i in range(from, from + count):
		seen[sequence[i]] = true
	return seen.size()


## Every *.png in `path` - a zip archive or a folder, searched recursively -
## as [name, bytes] pairs sorted by name. Empty if there are none or the path
## cannot be read.
func _read_pngs(path: String) -> Array:
	var found := {}  # name -> bytes
	if DirAccess.dir_exists_absolute(path):
		_collect_dir(path, found)
	else:
		var zip := ZIPReader.new()
		if zip.open(path) != OK:
			push_warning("[splash] could not open %s as a zip" % path)
			return []
		for entry in zip.get_files():
			# Skips macOS resource forks (__MACOSX/._image006.png), which are not PNGs.
			if entry.to_lower().ends_with(".png") and not entry.get_file().begins_with("._"):
				found[entry] = zip.read_file(entry)
		zip.close()
	var names := found.keys()
	names.sort()
	var files := []
	for entry in names:
		files.append([entry, found[entry]])
	return files


func _collect_dir(dir_path: String, found: Dictionary) -> void:
	for file_name in DirAccess.get_files_at(dir_path):
		if file_name.to_lower().ends_with(".png"):
			var full := dir_path.path_join(file_name)
			found[full] = FileAccess.get_file_as_bytes(full)
	for sub in DirAccess.get_directories_at(dir_path):
		_collect_dir(dir_path.path_join(sub), found)


func _hash(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(bytes)
	return ctx.finish().hex_encode()
