extends Node
## Music: YOUR OWN songs - music/<song>.ogg or .mp3 next to LoG2Coop.exe. Songs are "title", "field", "cave",
## "lair", "boss", "victory", or a place's name ("west city.ogg" plays in West City). Without a file, a little
## tune the game writes itself from content/music.json plays. Songs fade into each other.

const RATE = 22050
var volume = 0.55
var current = ""
var made = {}            # song -> AudioStream
var a: AudioStreamPlayer
var b: AudioStreamPlayer
var fade_t = 0.0
var thread: Thread
var queue = []
var mutex = Mutex.new()
var waiting = ""

func _ready() -> void:
	a = AudioStreamPlayer.new()
	b = AudioStreamPlayer.new()
	add_child(a)
	add_child(b)
	a.volume_db = -80
	b.volume_db = -80

func play(song: String) -> void:
	if song == current:
		return
	current = song
	var st = _stream(song)
	if st == null:
		waiting = song
		return
	waiting = ""
	# the new song on the quiet player, then cross-fade
	var t = a
	a = b
	b = t
	a.stream = st
	a.volume_db = -40
	a.play()
	fade_t = 1.0

func stop() -> void:
	current = ""
	fade_t = 1.0
	var t = a
	a = b
	b = t
	a.stop()

func _process(dt: float) -> void:
	var target = linear_to_db(maxf(0.0001, volume))
	if fade_t > 0.0:
		fade_t = maxf(0.0, fade_t - dt)
		a.volume_db = lerpf(target, -40.0, fade_t) if a.playing else -80.0
		b.volume_db = lerpf(-40.0, target, fade_t)
		if fade_t <= 0.0:
			b.stop()
	elif a.playing:
		a.volume_db = target
	# the game's song is ready now (it was being made): it takes over from the little tune
	if _fallback_for != "":
		_check_t += dt
		if _check_t > 1.0:
			_check_t = 0.0
			if _fallback_for != current:
				_fallback_for = ""
			elif Assets.game_song_ready(int(current.substr(4))):
				var c = current
				_fallback_for = ""
				current = ""
				play(c)
	# songs read on threads: the finished threads put away
	for t in _load_threads.duplicate():
		if not t.is_alive():
			t.wait_to_finish()
			_load_threads.erase(t)
	# a song written in the background is ready
	if waiting != "":
		mutex.lock()
		var ready_now = made.has(waiting)
		mutex.unlock()
		if ready_now and waiting == current:
			var c = waiting
			current = ""
			play(c)

## your own song file for this song or place ("" = none)
func file_for(song: String) -> String:
	if song == "" or Assets.exe_dir() == "":
		return ""
	if _files.has(song):
		return _files[song]
	var f = ""
	var nm = song.to_lower().replace(":", "_")      # (a game song "rom:15": your file rom_15.ogg replaces it)
	if _dir_files.is_empty():
		_list_dirs()
	for ext in ["ogg", "mp3"]:
		if f == "" and _dir_files.has("%s.%s" % [nm, ext]):
			f = _dir_files["%s.%s" % [nm, ext]]
	if f != "":
		print("[music] your song for ", song, ": ", f)
	_files[song] = f
	return f
var _files = {}
## the song folders listed once (on Android each file looked for in the shared Music folder takes a while - asked
## while you walk into a new place, that was a hitch): name -> path, your picked songs first
var _dir_files = {}
func _list_dirs() -> void:
	_dir_files = {"-": ""}
	for d in [Assets.music_dir(), Assets.picked_music_dir()]:
		var da = DirAccess.open(d)
		if da == null:
			continue
		for fn in da.get_files():
			_dir_files[fn.to_lower()] = d.path_join(fn)

## your songs changed (a pick, a reset, a permission): looked for again
func refresh_files() -> void:
	_files.clear()
	_dir_files.clear()

## the game's own songs read ahead (the loading screen): none is read while you play; true when all are in
var _preload_thread: Thread
func preload_game_songs() -> void:
	if _preload_thread != null:
		if _preload_thread.is_alive():
			return
		_preload_thread.wait_to_finish()
	_preload_thread = Thread.new()
	_preload_thread.start(func():
		for n in 44:
			var key = "rom:%d" % n
			mutex.lock()
			var have = made.has(key)
			mutex.unlock()
			if have or not Assets.game_song_ready(n):
				continue
			var w = _game_song(n)
			mutex.lock()
			if w != null:
				made[key] = w
			mutex.unlock())

func preloading() -> bool:
	return _preload_thread != null and _preload_thread.is_alive()

func _stream(song: String) -> AudioStream:
	var p = file_for(song)
	if p != "":
		if made.has(p):
			return made[p]
		var st: AudioStream = null
		if p.ends_with(".ogg"):
			var o = AudioStreamOggVorbis.load_from_file(p)
			if o:
				o.loop = song != "victory"
			st = o
		else:
			var m = AudioStreamMP3.new()
			m.data = FileAccess.get_file_as_bytes(p)
			m.loop = song != "victory"
			st = m
		made[p] = st
		return st
	if song.begins_with("rom:"):
		var n = int(song.substr(4))
		mutex.lock()
		var g = made.get(song)
		mutex.unlock()
		if g != null:
			return g
		if Assets.game_song_ready(n):
			_load_game_song(n)          # read on a thread (a big file): the song playing now goes on until it is ready
			return null
		_fallback_for = song           # not played from your game yet (it is being made): a little tune meanwhile
		Assets.want_song(n)            # (and it is made next)
		return _stream("title" if n == Assets.MENU_SONG else "field")
	mutex.lock()
	var have = made.get(song)
	mutex.unlock()
	if have != null:
		return have
	if not Content.songs.has(song):
		return null
	# write it in the background (a second or two), it starts when ready
	if not queue.has(song):
		queue.append(song)
		if thread == null or not thread.is_alive():
			if thread != null:
				thread.wait_to_finish()
			thread = Thread.new()
			thread.start(_worker)
	return null

## the game's own song n (made from your game file in the background): looping as the game loops it
var _fallback_for = ""
var _check_t = 0.0
var _loading = {}
var _load_threads = []
func _load_game_song(n: int) -> void:
	var key = "rom:%d" % n
	if _loading.has(key):
		return
	_loading[key] = true
	var t = Thread.new()
	_load_threads.append(t)
	t.start(func():
		var w = _game_song(n)
		mutex.lock()
		if w != null:
			made[key] = w
		_loading.erase(key)
		mutex.unlock())

func _game_song(n: int) -> AudioStream:
	if not Assets.game_song_ready(n):
		return null
	var base = Assets.game_music_dir().path_join("song_%02d" % n)
	var info = JSON.parse_string(FileAccess.get_file_as_string(base + ".json"))
	var data = FileAccess.get_file_as_bytes(base + ".qoa")
	if not info is Dictionary or data.size() < 16:
		return null
	var w = AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_QOA
	w.stereo = true
	w.mix_rate = int(info.get("rate", 15978))
	w.data = data
	if int(info.get("loop_begin", -1)) >= 0:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = int(info["loop_begin"])
		w.loop_end = int(info["loop_end"])
	return w

func prepare(songs: Array) -> void:
	for s in songs:
		_stream(s)

func _worker() -> void:
	while true:
		mutex.lock()
		if queue.is_empty():
			mutex.unlock()
			return
		var song: String = queue.pop_front()
		mutex.unlock()
		var w = render(Content.songs[song], song != "victory")
		mutex.lock()
		made[song] = w
		mutex.unlock()

# ------------------------------------------------------------------ the little synthesizer
static func _midi(n: String) -> int:
	var names = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
	if n.length() < 2 or not names.has(n[0]):
		return -1
	var k = names[n[0]]
	var i = 1
	if n[1] == "#":
		k += 1; i = 2
	elif n[1] == "b":
		k -= 1; i = 2
	return 12 * (int(n.substr(i)) + 1) + k

static func _steps(track: String) -> Array:
	var out = []
	for tok in track.replace("|", " ").split(" ", false):
		out.append(tok)
	return out

static func render(song: Dictionary, loop: bool) -> AudioStreamWAV:
	var bpm = float(song.get("bpm", 120))
	var step = int(RATE * 60.0 / bpm / 4.0)
	var lead = _steps(str(song.get("lead", "")))
	var bass = _steps(str(song.get("bass", "")))
	var drums = _steps(str(song.get("drums", "")))
	var n_steps = maxi(lead.size(), maxi(bass.size(), drums.size()))
	if n_steps == 0:
		return null
	var total = n_steps * step
	var buf = PackedFloat32Array()
	buf.resize(total)
	_voice(buf, lead, n_steps, step, str(song.get("lead_wave", "square")), 0.16, true)
	_voice(buf, bass, n_steps, step, str(song.get("bass_wave", "triangle")), 0.2, false)
	_drums(buf, drums, n_steps, step)
	var data = PackedByteArray()
	data.resize(total * 2)
	for i in total:
		data.encode_s16(i * 2, clampi(int(buf[i] * 30000.0), -32767, 32767))
	var w = AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.data = _padded(data)
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = total
	return w

static func _voice(buf: PackedFloat32Array, track: Array, n_steps: int, step: int, wave: String, amp: float, vibrato: bool) -> void:
	if track.is_empty():
		return
	var i = 0
	while i < n_steps:
		var tok: String = track[i % track.size()]
		var m = _midi(tok)
		if m < 0:
			i += 1
			continue
		var len = 1
		while i + len < n_steps and track[(i + len) % track.size()] == ".":
			len += 1
		var f = 440.0 * pow(2.0, (m - 69) / 12.0)
		var start = i * step
		var cnt = len * step
		var ph = 0.0
		for j in cnt:
			var t = float(j) / RATE
			var ff = f * (1.0 + (0.006 * sin(t * 34.0) if vibrato and t > 0.15 else 0.0))
			ph += ff / RATE
			var x = fmod(ph, 1.0)
			var v = 0.0
			match wave:
				"triangle": v = 4.0 * absf(x - 0.5) - 1.0
				"saw": v = x * 2.0 - 1.0
				"sine": v = sin(ph * TAU)
				"pulse": v = 1.0 if x < 0.25 else -1.0
				_: v = 1.0 if x < 0.5 else -1.0
			var env = minf(1.0, j / 60.0) * (0.55 + 0.45 * exp(-t * 6.0)) * minf(1.0, (cnt - j) / 300.0)
			var k = start + j
			if k < buf.size():
				buf[k] += v * env * amp
		i += len

static func _drums(buf: PackedFloat32Array, track: Array, n_steps: int, step: int) -> void:
	if track.is_empty():
		return
	var r = RandomNumberGenerator.new()
	r.seed = 7
	for i in n_steps:
		var tok: String = track[i % track.size()]
		var start = i * step
		match tok:
			"k":
				var ph = 0.0
				for j in mini(step * 2, 3000):
					var t = float(j) / RATE
					ph += lerpf(130.0, 40.0, minf(1.0, t * 12.0)) / RATE
					if start + j < buf.size():
						buf[start + j] += sin(ph * TAU) * exp(-t * 18.0) * 0.4
			"s":
				for j in mini(step * 2, 2600):
					var t = float(j) / RATE
					if start + j < buf.size():
						buf[start + j] += r.randf_range(-1, 1) * exp(-t * 22.0) * 0.16
			"h":
				var last = 0.0
				for j in mini(step, 900):
					var t = float(j) / RATE
					var nz = r.randf_range(-1, 1)
					if start + j < buf.size():
						buf[start + j] += (nz - last) * exp(-t * 60.0) * 0.06
					last = nz

func _exit_tree() -> void:
	# let a song being written finish before the game closes
	mutex.lock()
	queue.clear()
	mutex.unlock()
	if thread != null and thread.is_started():
		thread.wait_to_finish()
	for t in _load_threads:
		t.wait_to_finish()
	if _preload_thread != null:
		_preload_thread.wait_to_finish()


## silence after the end: Godot 4.7's mixer on Android reads a little past a sound's last sample (a crash there)
static func _padded(d: PackedByteArray) -> PackedByteArray:
	var p = d.duplicate()
	p.resize(d.size() + 1024)
	return p
