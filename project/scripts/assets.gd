extends Node
## Everything the game shows comes from the player's own game, turned into an "imported" folder
## by godot_export(.exe) the first time (nothing of the game is shipped).

var _json_lock: Mutex      # (the outfits are made ahead on another thread: the JSON cache is shared; made on first use)
var _built_lock: Mutex
var base_dir = ""
var _json = {}
var _tex = {}
var _sets = {}
var _areas = {}
var data = {}            # enemies, forms, fighters, levels, strings, items
var import_thread: Thread
var import_result = -1
var import_log = ""
# the loading bar (import screen): how far, which step, and that step's count
var import_frac = 0.0
var import_step = ""
var import_count = ""
var import_ms0 = 0
## the importer's steps: their part of the bar (measured: the maps take half the time) and what the bar says
const IMPORT_STEPS = {"start": [0.0, 0.0, "Starting"], "sprites": [0.0, 0.18, "Reading the characters"],
	"maps": [0.18, 0.73, "Reading the maps"], "data": [0.73, 0.74, "Reading foes and people"],
	"kit": [0.74, 0.77, "Sorting the map pieces"], "lands": [0.77, 0.87, "Joining the lands"],
	"earth": [0.87, 0.99, "Laying out Earth"], "ui": [0.99, 1.0, "Menus and fonts"], "done": [1.0, 1.0, "Done"]}

const BASE_HEROES = ["GOHAN", "PICCOLO", "VEGETA", "TRUNKS", "GOKU", "MR. SATAN"]
var CHARACTERS = ["GOHAN", "PICCOLO", "VEGETA", "TRUNKS", "GOKU", "MR. SATAN"]   # + your team's own (content/heroes.json)

## the game's heroes and your own: a hero of your own plays like its "base" (moves, forms, numbers) unless changed
func refresh_heroes() -> void:
	Mods.load_heroes()
	load_colors()
	CHARACTERS = BASE_HEROES.duplicate()
	for h in Mods.heroes:
		var id = str(h.get("id", "")).to_upper()
		if id != "" and not CHARACTERS.has(id):
			CHARACTERS.append(id)

## OUTFITS (the character screen's L / R): a hero's looks; the level and the save stay the hero's
func outfits(ch: int) -> Array:
	if ch < 0 or ch >= CHARACTERS.size():
		return []
	var o = Mods.hero_entry(CHARACTERS[ch]).get("outfits", [])
	return o if o is Array else []

func outfit_index(ch: int) -> int:
	var n = outfits(ch).size()
	if n == 0:
		return 0
	var picks = Game.cfg.get("outfit", {})
	return clampi(int(picks.get(CHARACTERS[ch], 0)) if picks is Dictionary else 0, 0, n - 1)

func outfit_of(ch: int) -> Dictionary:
	var o = outfits(ch)
	return o[outfit_index(ch)] if not o.is_empty() and o[outfit_index(ch)] is Dictionary else {}

## the name the character screen shows: the outfit's, or the hero's own
func hero_shown_name(ch: int) -> String:
	var o = outfit_of(ch)
	if o.has("name"):
		return str(o["name"])
	return str(Mods.hero_entry(CHARACTERS[ch]).get("name", CHARACTERS[ch]))

func set_outfit(ch: int, i: int) -> void:
	var n = outfits(ch).size()
	if n == 0:
		return
	var picks = Game.cfg.get("outfit", {})
	if not picks is Dictionary:
		picks = {}
	picks[CHARACTERS[ch]] = posmod(i, n)
	Game.cfg["outfit"] = picks
	Game.save_options()

## the game hero a hero plays like (itself for the game's own)
func hero_base(ch: int) -> int:
	if ch < BASE_HEROES.size():
		return maxi(0, ch)
	var h = Mods.hero_entry(CHARACTERS[ch]) if ch < CHARACTERS.size() else {}
	var b = BASE_HEROES.find(str(h.get("base", "GOKU")).to_upper())
	return b if b >= 0 else 4

## a hero's numbers: the game's own, with your team's changes on top
func hero_stats(ch: int) -> Dictionary:
	var f: Dictionary = data["fighters"][hero_base(ch)].duplicate()
	var h = Mods.hero_entry(CHARACTERS[ch]) if ch < CHARACTERS.size() else {}
	for k in h.get("stats", {}):
		f[k] = h["stats"][k]
	return f

func _ready() -> void:
	base_dir = find_import_dir()

func exe_dir() -> String:
	var ov = OS.get_environment("LOG2_EXE_DIR")     # (testing: a second copy's folder)
	if ov != "":
		return ov
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://").get_base_dir()
	if OS.has_feature("android"):
		return _android_dir()
	var ep = OS.get_executable_path()
	if OS.get_name() == "macOS" and ep.contains(".app/Contents/MacOS"):
		return ep.substr(0, ep.find(".app/Contents/MacOS")).get_base_dir()      # the folder the app is in (its data sits beside it)
	return ep.get_base_dir()

## Android: no folder next to the program - the game's folders (content, modpacks, imported...) come packed in
## the APK (res://bundle/gamedata.pack, made by tools/make_pack.py) and are unpacked into the app's own folder
## on the first start: [8 bytes: index length][index JSON: [{"p", "s"}...]][the files, in that order]
const BUNDLE_VERSION = "v44-53"
var _android_root = ""
func _remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for d in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(d))
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)

func _android_dir() -> String:
	if _android_root != "":
		return _android_root
	_android_root = ProjectSettings.globalize_path("user://game")
	var mark = _android_root.path_join("bundle_version.txt")
	if FileAccess.file_exists(mark) and FileAccess.get_file_as_string(mark).strip_edges() == BUNDLE_VERSION:
		return _android_root
	var src = FileAccess.open("res://bundle/gamedata.pack", FileAccess.READ)
	if src == null:
		printerr("[assets] no res://bundle/gamedata.pack")
		return _android_root
	var index = JSON.parse_string(src.get_buffer(src.get_64()).get_string_from_utf8())
	if not index is Array:
		printerr("[assets] the game data's index is broken")
		return _android_root
	for gone in ["modpacks/Example_NewHero"]:      # shipped by an older version, no longer (Shadow Goku is an outfit now)
		_remove_tree(_android_root.path_join(gone))
	print("[assets] unpacking ", index.size(), " files into ", _android_root)
	var t0 = Time.get_ticks_msec()
	for e in index:
		var dest = _android_root.path_join(str(e["p"]))
		DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
		var fa = FileAccess.open(dest, FileAccess.WRITE)
		var left = int(e["s"])
		while left > 0:
			var chunk = src.get_buffer(mini(left, 4194304))
			if chunk.is_empty():
				printerr("[assets] the game data ends too soon at ", e["p"])
				return _android_root
			if fa:
				fa.store_buffer(chunk)
			left -= chunk.size()
		if fa:
			fa.close()
	src.close()
	print("[assets] game data ready in ", Time.get_ticks_msec() - t0, " ms")
	var mf = FileAccess.open(mark, FileAccess.WRITE)
	if mf:
		mf.store_string(BUNDLE_VERSION)
		mf.close()
	return _android_root

## does a sprite set have a sideways pose of its own in the flying row (12)? Some heroes' row 12 is another pose
## (Mr. Satan's dazed one) whose left and right frames are the front frame again: those fly sideways in their walk
var _side_fly = {}
func has_side_fly(set_id: int) -> bool:
	if _side_fly.has(set_id):
		return _side_fly[set_id]
	var ok = true
	var d = sprite_set(set_id)
	if not d.is_empty() and d["tex"] != null and d["slots"].size() > 51 and d["slots"][48].size() > 0 and d["slots"][50].size() > 0:
		var img: Image = d["tex"].get_image()
		var c: int = d["cell"]
		ok = img.get_region(Rect2i(0, 48 * c, c, c)).get_data() != img.get_region(Rect2i(0, 50 * c, c, c)).get_data()
	_side_fly[set_id] = ok
	return ok

## the GBA menus' own fonts, read from the player's game file by the importer (ui/font_head, ui/font_small):
## a pixel font Labels and Buttons can use at font size 16 (draw with a 1-pixel shadow down-right, like the game)
var _gba_fonts = {}
func gba_font(name: String) -> FontFile:
	if _gba_fonts.has(name):
		return _gba_fonts[name]
	var f: FontFile = null
	var img = image(base_dir.path_join("ui/%s.png" % name))
	var j = json(base_dir.path_join("ui/%s.json" % name))
	if img != null and j is Dictionary:
		f = FontFile.new()
		f.fixed_size = 16
		f.fixed_size_scale_mode = TextServer.FIXED_SIZE_SCALE_INTEGER_ONLY
		f.antialiasing = TextServer.FONT_ANTIALIASING_NONE
		var sz = Vector2i(16, 0)
		f.set_texture_image(0, sz, 0, img)
		f.set_cache_ascent(0, 16, 13.0)
		f.set_cache_descent(0, 16, 3.0)
		var glyphs: Dictionary = j.get("glyphs", {})
		for k in glyphs:
			var c = int(k); var x = float(glyphs[k][0]); var w = float(glyphs[k][1])
			f.set_glyph_advance(0, 16, c, Vector2(w + 1.0, 0))
			f.set_glyph_offset(0, sz, c, Vector2(0, -13))
			f.set_glyph_size(0, sz, c, Vector2(w, 16))
			f.set_glyph_uv_rect(0, sz, c, Rect2(x, 0, w, 16))
			f.set_glyph_texture_idx(0, sz, c, 0)
	_gba_fonts[name] = f
	return f

## heroes and looks that come with this port (Shadow Goku, Puni Puni's Super Saiyan Gokus): under everything else
func builtin_dir() -> String:
	return exe_dir().path_join("builtin")

func find_import_dir() -> String:
	var env = OS.get_environment("LOG2_IMPORT")
	if env != "" and FileAccess.file_exists(env.path_join("version.txt")):
		return env
	var d = exe_dir().path_join("imported")
	if FileAccess.file_exists(d.path_join("version.txt")):
		return d
	d = ProjectSettings.globalize_path("user://imported")
	if FileAccess.file_exists(d.path_join("version.txt")):
		return d
	return ""

const IMPORT_VERSION = 36    # 36 EARTH comes with the game (only its minimap drawn on import), 35 rooms behind doors have black round them (no mirrored copies), 34 grass mixed round the game's own buildings too, no wall in small trees' leaves, 33 the green country's grass mixed, field tree trunks block, 32 tree trunks under whole-tree canopies block again, fluffy trees' shading opens, 31 the Northern Mountains' grass mixed like its forests', 30 the clothes on the ground east of Gingertown walked over, 29 you walk under the trees' leaves (only trunks block), 28 grass patches in the snowy country made snow, 27 the neon-green grass laid again with the game's yellow-green grass, 26 Krillin's flying frames (his set read past a longer gap), 25 rows of flowers and bigger grass clumps walked over (invisible-wall patches up to 48 cells), 24 the title menu's little Dragon Ball (the menus' cursor), 23 same Earth for everyone + the GBA menus' title, galaxy and fonts (Android port), 22 grass tufts and clumps of them walked over (Android port), 21 invisible walls opened everywhere: lone walls with nothing on them that stands out from the ground (Android port), 20 flowers and the like on the new land are walked over (Android port), 19 no doors into story scenes' backdrops (they showed as a jumble of tiles), 18 the sea is the game's own water, 2 kit and lands, 3 songs, 4 foes' attacks, 5 grown land, 6 heroes' effects + one world per land, 7 people, 8 smoother grown land, 9 recorded songs mended, 10 ledges opened (the lands join up), calmer city edges, 11 the heroes' own attacks, 12 the foes' own behaviour scripts + attack animations, 13 EARTH: the whole planet as one map, 14 every place on it (doors without loading), 15 collision mended (no invisible walls, nothing walked through), 16 the country between places built the way the game builds its maps, 17 the game's own collision kept
func ready_to_play() -> bool:
	return base_dir != "" and import_version() >= IMPORT_VERSION

func import_version() -> int:
	if base_dir == "":
		return 0
	var t = FileAccess.get_file_as_string(base_dir.path_join("version.txt")).strip_edges()
	return int(t) if t.is_valid_int() else 1

func load_data() -> void:
	for k in ["enemies", "forms", "fighters", "levels", "strings", "items", "ai"]:
		data[k] = json(base_dir.path_join("data/%s.json" % k))
	# the levels: the game's own 50 (past 50 the table read on into other data)
	if data.get("levels") is Array and data["levels"].size() >= MAX_LEVEL:
		var lv = []
		for i in MAX_LEVEL:
			lv.append(int(data["levels"][i]))
		data["levels"] = lv
	_rom_enemies = data["enemies"].duplicate(true) if data.get("enemies") != null else []
	apply_enemy_overrides()
	start_music_render()

# ------------------------------------------------------------------ the game's own songs
## played by the game's own sound engine from your game file (the importer's "music" job, run in the background
## after the import): imported/music/song_NN.qoa with its loop in song_NN.json. The menus' song comes first.
const MENU_SONG = 15
const MAX_LEVEL = 50      # as in the original game
var music_thread: Thread
func game_music_dir() -> String:
	return base_dir.path_join("music")

## the music question's answer ("play": record while playing, "now": all first, "": not asked yet) - kept with this
## copy's songs (not in the settings every copy shares), so a new copy or a new read of your game asks once
func music_mode() -> String:
	var f = game_music_dir().path_join("music_mode.txt") if base_dir != "" else ""
	return FileAccess.get_file_as_string(f).strip_edges() if f != "" and FileAccess.file_exists(f) else ""

func set_music_mode(m: String) -> void:
	if base_dir == "":
		return
	DirAccess.make_dir_recursive_absolute(game_music_dir())
	var fa = FileAccess.open(game_music_dir().path_join("music_mode.txt"), FileAccess.WRITE)
	if fa:
		fa.store_string(m)
		fa.close()

func game_song_ready(n: int) -> bool:
	return base_dir != "" and FileAccess.file_exists(game_music_dir().path_join("song_%02d.json" % n))

## songs still to record (the menus' first, then the ones the most places use); 0 = all there
func songs_missing() -> int:
	return _song_order().filter(func(s): return not game_song_ready(int(s))).size()

func _song_order() -> Array:
	var order = [MENU_SONG]
	var cnt = {}
	var km = json(base_dir.path_join("kit/maps.json")) if base_dir != "" else null
	if km != null:
		for mm in km["maps"]:
			var s = int(mm.get("song", -1))
			if s >= 0:
				cnt[s] = cnt.get(s, 0) + 1
	var used = cnt.keys()
	used.sort_custom(func(x, y): return cnt[x] > cnt[y])
	for s in used + range(44):
		if not order.has(s):
			order.append(s)
	return order

## the song of the place you walk into: recorded next (you hear it in seconds, not at its turn)
var music_want = -1
var music_done = 0
var music_total = 0
func want_song(n: int) -> void:
	music_want = n

func start_music_render() -> void:
	if base_dir == "" or (music_thread != null and music_thread.is_alive()):
		return
	if music_mode() == "":
		return      # not chosen yet: the menu asks (record while playing, or all now)
	var rom = FileAccess.get_file_as_string("user://rom_path.txt").strip_edges() if FileAccess.file_exists("user://rom_path.txt") else ""
	if rom == "" or not FileAccess.file_exists(rom):
		var g = exe_dir().path_join("game.gba")
		rom = g if FileAccess.file_exists(g) else ""
	if rom == "":
		return
	# the menus' song, then the songs the most places use, then the rest
	var todo = _song_order().filter(func(s): return not game_song_ready(int(s)))
	if todo.is_empty():
		return
	if music_thread != null:
		music_thread.wait_to_finish()
	music_thread = Thread.new()
	music_thread.start(_music_worker.bind(rom, todo))

## one song at a time (the recorder lowers its own priority: the game comes first), the wanted one first
func _music_worker(rom: String, todo: Array) -> void:
	DirAccess.make_dir_recursive_absolute(game_music_dir())
	music_total = todo.size()
	music_done = 0
	print("[assets] the game's songs: ", todo.size(), " to play and keep")
	while not todo.is_empty() and not _quitting:
		var s = todo[0]
		if music_want >= 0 and todo.has(music_want):
			s = music_want
		music_want = -1
		todo.erase(s)
		if not game_song_ready(int(s)):
			# its own process, checked every 0.1 s, so quitting the game stops it at once
			var pid = OS.create_process(importer_path(), ["music", rom, game_music_dir(), str(s)])
			while pid > 0 and OS.is_process_running(pid):
				if _quitting:
					OS.kill(pid)
					DirAccess.remove_absolute(game_music_dir().path_join("song_%02d.json" % int(s)))   # half-written
					break
				OS.delay_msec(100)
		music_done += 1
	print("[assets] songs done")

## your team's numbers for each kind of foe (content/enemies.json "types": lvl, hp, atk, exp, w8) over the game's
var _rom_enemies = []
func apply_enemy_overrides() -> void:
	if _rom_enemies.is_empty():
		return
	data["enemies"] = _rom_enemies.duplicate(true)
	for t in Content.enemy_types:
		var o: Dictionary = Content.enemy_types[t]
		if int(t) < 0 or int(t) >= data["enemies"].size():
			continue
		for k in ["lvl", "hp", "atk", "exp", "w8"]:
			if o.has(k):
				data["enemies"][int(t)][k] = o[k]

# ------------------------------------------------------------------ your own songs and sounds
## next to the program - on Android in the device's Music folder (Music/LoG2Coop, sounds in Music/LoG2Coop/sounds):
## a place you reach with a file manager or over USB that the game may read (it asks for "music and audio")
const ANDROID_AUDIO = "android.permission.READ_MEDIA_AUDIO"
func music_dir() -> String:
	if OS.has_feature("android"):
		return OS.get_system_dir(OS.SYSTEM_DIR_MUSIC).path_join("LoG2Coop")
	return exe_dir().path_join("music")

## songs picked in OPTIONS - MODS - MY OWN MUSIC: kept in the app's own folder (Android lets an app write there freely;
## the shared Music folder refuses files the app did not make itself). Looked in before the Music folder.
func picked_music_dir() -> String:
	return exe_dir().path_join("music_picked")

func sounds_dir() -> String:
	if OS.has_feature("android"):
		return music_dir().path_join("sounds")
	return exe_dir().path_join("sounds")

func audio_allowed() -> bool:
	return not OS.has_feature("android") or OS.get_granted_permissions().has(ANDROID_AUDIO)

# ------------------------------------------------------------------ import (first start)
## the game importer: next to the program - on Android it comes in the APK as lib/arm64-v8a/libgodot_export.so
## (Android unpacks it beside the engine's own library, the one place an app may run a program from)
func importer_path() -> String:
	if OS.has_feature("android"):
		# (where that is: the engine's library in this process's memory map - /proc files read as empty through FileAccess)
		var out = []
		OS.execute("/system/bin/cat", ["/proc/%d/maps" % OS.get_process_id()], out)
		for line in "".join(PackedStringArray(out)).split("\n"):
			var i = line.find("/libgodot_android.so")
			if i >= 0:
				var p = line.substr(line.find("/"), i - line.find("/"))
				return p.path_join("libgodot_export.so")
		printerr("[assets] the importer was not found")
		return ""
	return exe_dir().path_join("godot_export.exe" if OS.get_name() == "Windows" else "godot_export")

func start_import(rom_path: String) -> void:
	import_result = -1
	import_frac = 0.0
	import_step = "Starting"
	import_count = ""
	import_ms0 = Time.get_ticks_msec()
	import_thread = Thread.new()
	import_thread.start(_import_worker.bind(rom_path))

func _import_worker(rom_path: String) -> void:
	# remembered for the music (the game's own songs are recorded from the game in the background)
	var rf = FileAccess.open("user://rom_path.txt", FileAccess.WRITE)
	if rf:
		rf.store_string(rom_path)
		rf.close()
	var tool = importer_path()
	var out_dir = exe_dir().path_join("imported")
	var adv = exe_dir().path_join("adventures")
	var output = []
	print("[assets] importer: ", tool, " ", rom_path, " -> ", out_dir)
	var code = _run_importer(tool, _import_args(rom_path, out_dir, adv), output)
	print("[assets] importer exit ", code, ": ", "\n".join(PackedStringArray(output)).right(400))
	import_log = "\n".join(PackedStringArray(output))
	if code != 0 or not FileAccess.file_exists(out_dir.path_join("version.txt")):
		# a folder we may not write to: the user folder instead
		out_dir = ProjectSettings.globalize_path("user://imported")
		output.clear()
		code = _run_importer(tool, _import_args(rom_path, out_dir, adv), output)
		import_log += "\n".join(PackedStringArray(output))
	# the other games found next to it (Buu's Fury, The Legacy of Goku): for the DEV TOOLS
	if code == 0:
		var roms = library_roms()
		for g in roms:
			import_step = "Reading your other games (%s)" % str(g).to_upper()
			import_count = ""
			OS.execute(tool, ["library", roms[g], out_dir], [], true)
	call_deferred("_import_done", code)

## the importer's words; EARTH comes with the game (builtin/earth): written in first, so the importer only
## draws its minimap ("noearth" - growing the country took most of the import's time and memory)
func _import_args(rom_path: String, out_dir: String, adv: String) -> Array:
	var args = [rom_path, out_dir, adv]
	var src = builtin_dir().path_join("earth/earth_base.gz")
	var lj = builtin_dir().path_join("earth/lands.json")
	if not FileAccess.file_exists(src) or not FileAccess.file_exists(lj):
		return args
	var zd = out_dir.path_join("kit/lands/0")
	DirAccess.make_dir_recursive_absolute(zd)
	var body = FileAccess.get_file_as_bytes(src).decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
	var f = FileAccess.open(zd.path_join("0.bin"), FileAccess.WRITE)
	if f == null or body.size() < 8:
		return args
	f.store_buffer(body)
	f.close()
	body = PackedByteArray()
	DirAccess.copy_absolute(lj, zd.path_join("lands.json"))
	# laid in already: the game need not do it again
	var ver = FileAccess.get_file_as_string(builtin_dir().path_join("earth/version.txt")).strip_edges()
	var sf = FileAccess.open(zd.path_join("earth_base.txt"), FileAccess.WRITE)
	if sf:
		sf.store_string("%s|%d" % [ver, FileAccess.get_modified_time(zd.path_join("0.bin"))])
		sf.close()
	args.append("noearth")
	return args

## the importer run with its words read as they come (the loading bar moves with them); its exit code
func _run_importer(tool: String, args: Array, output: Array) -> int:
	var p: Dictionary = OS.execute_with_pipe(tool, PackedStringArray(args))
	if p.is_empty():
		return OS.execute(tool, args, output, true)      # (no pipes here: all at the end)
	var err: FileAccess = p["stderr"]
	var lines = []
	while true:
		var l = err.get_line()
		if err.get_error() != OK and l == "":
			break
		lines.append(l)
		var w = l.split(" ")
		if w.size() >= 4 and w[0] == "[progress]" and IMPORT_STEPS.has(w[1]):
			var st: Array = IMPORT_STEPS[w[1]]
			var of = maxi(1, int(w[3]))
			import_frac = lerpf(float(st[0]), float(st[1]), clampf(float(w[2]) / of, 0.0, 1.0))
			import_step = str(st[2])
			import_count = "%d of %d" % [mini(int(w[2]) + 1, of), of] if of > 1 else ""
	var pid = int(p["pid"])
	while OS.is_process_running(pid):
		OS.delay_msec(20)
	output.append("\n".join(PackedStringArray(lines.filter(func(x): return not str(x).begins_with("[progress]")))))
	return OS.get_process_exit_code(pid)

func _import_done(code: int) -> void:
	import_thread.wait_to_finish()
	base_dir = find_import_dir()
	import_result = 0 if base_dir != "" else (code if code != 0 else 1)

# ------------------------------------------------------------------ the other games (DEV TOOLS library)
## Buu's Fury and The Legacy of Goku: their maps and characters, read from the player's own cartridges
## (a .gba or its .zip next to the game, in "games", in Downloads or next to the LoG2 game)
const LIB_VERSION = {"bf": 1, "log1": 2}     # log1 2: its maps too
func has_library(g: String) -> bool:
	if base_dir == "" or not FileAccess.file_exists(base_dir.path_join("lib/%s/done.txt" % g)):
		return false
	var t = FileAccess.get_file_as_string(base_dir.path_join("lib/%s/done.txt" % g)).strip_edges()
	return (int(t) if t.is_valid_int() else 1) >= int(LIB_VERSION.get(g, 1))

func _rom_code(path: String) -> String:
	if path.to_lower().ends_with(".zip"):
		var z = ZIPReader.new()
		if z.open(path) != OK:
			return ""
		for f in z.get_files():
			if f.to_lower().ends_with(".gba"):
				var b = z.read_file(f)
				z.close()
				if b.size() >= 0x200000:
					var code = b.slice(0xAC, 0xB0).get_string_from_ascii()
					var out = ProjectSettings.globalize_path("user://lib_rom_%s.gba" % code)
					var fa = FileAccess.open(out, FileAccess.WRITE)
					if fa:
						fa.store_buffer(b)
						fa.close()
						_unzipped[code] = out
					return code
				return ""
		z.close()
		return ""
	var fh = FileAccess.open(path, FileAccess.READ)
	if fh == null or fh.get_length() < 0x200000:
		return ""
	fh.seek(0xAC)
	return fh.get_buffer(4).get_string_from_ascii()

var _unzipped = {}
func library_roms() -> Dictionary:
	var found = {}
	var dirs = [exe_dir(), exe_dir().path_join("games"), OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS), OS.get_system_dir(OS.SYSTEM_DIR_DESKTOP)]
	if FileAccess.file_exists("user://rom_path.txt"):
		dirs.append(FileAccess.get_file_as_string("user://rom_path.txt").strip_edges().get_base_dir())
	for d in dirs:
		var da = DirAccess.open(d)
		if da == null:
			continue
		for f in da.get_files():
			var lf = f.to_lower()
			if not (lf.ends_with(".gba") or lf.ends_with(".zip")):
				continue
			if lf.ends_with(".zip") and not ("buu" in lf or "legacy" in lf or "goku" in lf or "dbz" in lf or "dragon" in lf):
				continue
			var code = _rom_code(d.path_join(f))
			var g = "bf" if code == "BG3E" else ("log1" if code.begins_with("ALG") else "")
			if g != "" and not found.has(g):
				found[g] = _unzipped.get(code, d.path_join(f))
	return found

## read the other games found (or again with force); returns what happened, for the screen
func import_library(force: bool = false) -> String:
	var tool = importer_path()
	var roms = library_roms()
	var said = []
	for g in roms:
		if has_library(g) and not force:
			said.append("%s: already read" % LIB_TITLES[g])
			continue
		var out = []
		var code = OS.execute(tool, ["library", roms[g], base_dir], out, true)
		said.append("%s: %s" % [LIB_TITLES[g], "read" if code == 0 else "could not be read"])
	if roms.is_empty():
		said.append("No Buu's Fury or Legacy of Goku game found (put the .gba or .zip next to the game or in a \"games\" folder)")
	_tileset = null
	_sets.clear()
	_json.clear()
	return "\n".join(PackedStringArray(said))

## the library's maps: [{key: "lib/bf/Z_A", name, tw, th}]
func library_maps() -> Array:
	var out = []
	for g in LIB_GAMES:
		var lj = json(base_dir.path_join("lib/%s/maps.json" % g))
		if lj == null:
			continue
		for m in lj["maps"]:
			out.append({"key": "lib/%s/%s" % [g, m["key"]], "name": "%s %s" % [LIB_TITLES[g], str(m["key"]).replace("_", "-")], "tw": m["tw"], "th": m["th"], "arrival": m.get("arrival", [m["tw"] * 4, m["th"] * 4])})
	return out

## every sprite set: the game's own and the other games' (DEV TOOLS pickers)
func library_sets(g: String) -> Array:
	var lj = json(base_dir.path_join("lib/%s/sets.json" % g))
	var out = []
	if lj != null:
		for e in lj["sets"]:
			out.append(int(e["id"]))
	return out

# ------------------------------------------------------------------ files
func json(path: String) -> Variant:
	if _json_lock == null:
		_json_lock = Mutex.new()
	_json_lock.lock()
	if _json.has(path):
		var c = _json[path]
		_json_lock.unlock()
		return c
	_json_lock.unlock()
	var f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var v = JSON.parse_string(f.get_as_text())
	_json_lock.lock()
	_json[path] = v
	_json_lock.unlock()
	return v

func texture(path: String) -> Texture2D:
	if _tex.has(path):
		return _tex[path]
	var t: Texture2D = null
	if FileAccess.file_exists(path):
		var img = Image.load_from_file(path)
		if img != null:
			t = ImageTexture.create_from_image(img)
	_tex[path] = t
	return t

func image(path: String) -> Image:
	if FileAccess.file_exists(path):
		return Image.load_from_file(path)
	return null

# ------------------------------------------------------------------ sprite sets
## {tex, cell, slots: [[{x,y,w,h}...]...]}
## the outfits' pictures made ahead on another thread (the character screen): switching outfits does not hitch
var _built = {}
func prewarm_sets(ids: Array) -> void:
	if _built_lock == null:
		_built_lock = Mutex.new()
	var todo = []
	for n in ids:
		if int(n) >= 0 and not _sets.has(int(n)) and not todo.has(int(n)):
			todo.append(int(n))
	if todo.is_empty():
		return
	var lk: Mutex = _built_lock      # (the thread keeps its own hold on the lock and the results: safe at quit)
	var built: Dictionary = _built
	_prewarm_task = WorkerThreadPool.add_task(func():
		for n in todo:
			if _quitting:
				return
			lk.lock(); var have = built.has(n); lk.unlock()
			if have:
				continue
			var r = _build_set(n)
			lk.lock(); built[n] = r; lk.unlock())

var _prewarm_task = -1
var _quitting = false
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE or what == NOTIFICATION_WM_CLOSE_REQUEST:
		_quitting = true
		if music_thread != null and music_thread.is_started():
			music_thread.wait_to_finish()
		if _prewarm_task >= 0:
			WorkerThreadPool.wait_for_task_completion(_prewarm_task)
			_prewarm_task = -1

func sprite_set(n: int) -> Dictionary:
	if _sets.has(n):
		return _sets[n]
	if _built_lock == null:
		_built_lock = Mutex.new()
	_built_lock.lock()
	var r = _built.get(n, {})
	_built.erase(n)
	_built_lock.unlock()
	if r.is_empty():
		r = _build_set(n)
	var d = {}
	if r.has("j"):
		var j: Dictionary = r["j"]
		var rule: Dictionary = r["rule"]
		var tex: Texture2D = texture(r["path"]) if r["img"] == null else ImageTexture.create_from_image(r["img"])
		d = {"tex": tex, "cell": int(j["cell"]), "slots": j["slots"]}
		if r["img"] != null:
			d["img"] = r["img"]      # kept: the menus cut pictures from it without reading the texture back
		if rule.get("villain_fx", false):       # a villain played as a hero: red when hit, smoke when beaten (actor_view)
			d["villain_fx"] = true
			d["smoke_down"] = rule.get("smoke_down", false)
		if rule.get("hand_band") is Array:      # where the hands can be (King Cold: his cape reaches out further at the hips)
			d["hand_band"] = rule["hand_band"]
	_sets[n] = d
	return d

## a set's picture worked out (colours, made poses, overlay, frame boxes): no textures, so it can run on another thread
func _build_set(n: int) -> Dictionary:
	var b = set_base(n)
	var j = json(set_path(b, "json"))
	if j == null:
		return {}
	var rule = color_rule_for_set(n)
	var path = set_path(b, "png")
	var out_img: Image = null
	if true:
		if not rule.is_empty():
			var img = image(path)
			if img != null:
				img = recolor(img, rule)
				if rule.get("canvas") is Array:      # a sheet with more frames or poses than the game's set (a new hero's): room made first
					var cw = maxi(img.get_width(), int(rule["canvas"][0])); var chh = maxi(img.get_height(), int(rule["canvas"][1]))
					if cw != img.get_width() or chh != img.get_height():
						var big = Image.create(cw, chh, false, Image.FORMAT_RGBA8)
						img.convert(Image.FORMAT_RGBA8)
						big.blit_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i.ZERO)
						img = big
				if rule.get("make") is Dictionary:      # poses the set never had, made from its own frames (a recipe)
					img = make_poses(img, rule["make"], int(j["cell"]))
				if str(rule.get("overlay", "")) != "":
					img = apply_overlay(img, str(rule.get("_dir", "")).path_join(str(rule["overlay"])))
					j = j.duplicate(true)      # drawn pixels may reach past the base set's frames (an outline): 2 more each way right and down
					for sl in j["slots"]:
						for f in sl:
							f["w"] = int(f["w"]) + 2; f["h"] = int(f["h"]) + 2
				if rule.get("frames") is Dictionary:       # new poses drawn in their own boxes (Mr. Satan flying sideways)
					j = j.duplicate(true)
					for sk in rule["frames"]:
						var si = int(sk)
						while j["slots"].size() <= si:
							j["slots"].append([])
						j["slots"][si] = rule["frames"][sk].duplicate(true)
				out_img = img
	return {"j": j, "rule": rule, "path": path, "img": out_img}

## a sprite set's file: your team's own (content/sprites: made or changed in DEV TOOLS - SPRITES), a mod's, or the import's
func set_path(n: int, ext: String) -> String:
	var own = exe_dir().path_join("content/sprites/set_%d.%s" % [n, ext])
	if FileAccess.file_exists(own):
		return own
	var dirs = Mods.pack_dirs()
	dirs.reverse()
	for d in dirs:
		var f = d.path_join("sprites/set_%d.%s" % [n, ext])
		if FileAccess.file_exists(f):
			return f
	return base_dir.path_join("sprites/set_%d.%s" % [n, ext])

## forget the sprite sets read (after one was changed in the tools)
func reload_sets() -> void:
	_sets.clear()
	_imgs.clear()
	_hands.clear()
	_charges.clear()
	for k in _tex.keys():
		if "sprites/set_" in str(k):
			_tex.erase(k)
	for k in _json.keys():
		if "sprites/set_" in str(k):
			_json.erase(k)

# ------------------------------------------------------------------ colours (DEV TOOLS - COLORS: content/colors.json)
## {"sets": {"60": rule}, "variants": [{"id": 3000, "base": 60, "name": "...", rule...}], "tiles": {"kit": rule, "bf": rule, "log1": rule}}
## rule: {"hue": degrees, "sat": x, "val": x, "swaps": {"rrggbb": "rrggbb"}}
var colors = {"sets": {}, "variants": [], "tiles": {}}
const VARIANT_BASE = 3000
func load_colors() -> void:
	colors = {"sets": {}, "variants": [], "tiles": {}}
	for f in [builtin_dir().path_join("colors.json")] + Mods.content_paths("colors"):
		if not FileAccess.file_exists(f):
			continue
		var t = Mods.read_json(f)
		if not t is Dictionary:
			continue
		for k in ["sets", "tiles"]:
			if t.get(k) is Dictionary:
				for sk in t[k]:
					if t[k][sk] is Dictionary and t[k][sk].has("overlay"):
						t[k][sk]["_dir"] = f.get_base_dir().path_join("sprites")
				colors[k].merge(t[k], true)
		if t.get("variants") is Array:
			for v in t["variants"]:
				if v is Dictionary and v.has("overlay"):
					v["_dir"] = f.get_base_dir().path_join("sprites")
				colors["variants"] = colors["variants"].filter(func(x): return int(x.get("id", -1)) != int(v.get("id", -2)))
				colors["variants"].append(v)
	_sets.clear()
	_sheets.clear()
	_imgs.clear()
	_tileset = null

func variant(n: int) -> Dictionary:
	for v in colors["variants"]:
		if int(v.get("id", -1)) == n:
			return v
	return {}

## the sprite set a set's pictures come from (a colour variant: its base set)
func set_base(n: int) -> int:
	if n >= VARIANT_BASE:
		var v = variant(n)
		if not v.is_empty():
			return int(v.get("base", 0))
	return n

func color_rule_for_set(n: int) -> Dictionary:
	if n >= VARIANT_BASE:
		var v = variant(n)
		if not v.is_empty():
			return v
	return colors["sets"].get(str(n), {})

static func rule_is_plain(rule: Dictionary) -> bool:
	return absf(float(rule.get("hue", 0.0))) < 0.01 and absf(float(rule.get("sat", 1.0)) - 1.0) < 0.001 and absf(float(rule.get("val", 1.0)) - 1.0) < 0.001 and rule.get("swaps", {}).is_empty()

## a picture with its colours changed: exact colours swapped first, then hue / saturation / brightness
func recolor(src: Image, rule: Dictionary) -> Image:
	if rule.is_empty() or rule_is_plain(rule):
		return src
	var img: Image = src.duplicate()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var swaps = {}
	for k in rule.get("swaps", {}):
		var a = Color.html(str(k)); var b = Color.html(str(rule["swaps"][k]))
		swaps[_c32(a)] = _c32(b)
	var hue = float(rule.get("hue", 0.0)) / 360.0
	var sat = float(rule.get("sat", 1.0)); var val = float(rule.get("val", 1.0))
	var hsv = absf(hue) > 0.0001 or absf(sat - 1.0) > 0.001 or absf(val - 1.0) > 0.001
	var px: PackedInt32Array = img.get_data().to_int32_array()
	var memo = {}
	for i in px.size():
		var v = px[i]
		if (v >> 24) & 0xFF == 0:
			continue
		if memo.has(v):
			px[i] = memo[v]
			continue
		var o = (v & 0xFFFFFF) | 0xFF000000      # (unsigned, as the swap list keeps them: a pixel read back is signed)
		var w = swaps.get(o, o)
		if hsv:
			var c = Color8(w & 0xFF, (w >> 8) & 0xFF, (w >> 16) & 0xFF)
			c = Color.from_hsv(fposmod(c.h + hue, 1.0), clampf(c.s * sat, 0.0, 1.0), clampf(c.v * val, 0.0, 1.0))
			w = _c32(c)
		w = (w & 0x00FFFFFF) | (v & 0xFF000000)
		memo[v] = w
		px[i] = w
	return Image.create_from_data(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8, px.to_byte_array())

## POSES FROM A RECIPE: {"slot": [{"from": [slot, frame], "ops": [["mirror"], ["shift", dx, dy], ["bright", k],
## ["rot", quarter], ["tilt", t]]}, ...]} - each frame made from one of the set's own frames (so nothing of the game ships)
func make_poses(src: Image, recipe: Dictionary, cell: int) -> Image:
	var rows = 0
	for k in recipe:
		rows = maxi(rows, int(k) + 1)
	var img = Image.create(maxi(src.get_width(), 7 * cell), maxi(src.get_height(), rows * cell), false, Image.FORMAT_RGBA8)
	var s2 = src.duplicate()
	s2.convert(Image.FORMAT_RGBA8)
	img.blit_rect(s2, Rect2i(Vector2i.ZERO, s2.get_size()), Vector2i.ZERO)
	for k in recipe:
		var slot = int(k)
		var list: Array = recipe[k]
		# the slot's old pictures go (a side that was only the front again)
		img.fill_rect(Rect2i(0, slot * cell, img.get_width(), cell), Color(0, 0, 0, 0))
		for f in list.size():
			var r: Dictionary = list[f]
			var fr = r.get("from", [0, 0])
			var c = s2.get_region(Rect2i(int(fr[1]) * cell, int(fr[0]) * cell, cell, cell)) if int(fr[0]) * cell < s2.get_height() else Image.create(cell, cell, false, Image.FORMAT_RGBA8)
			for o in r.get("ops", []):
				c = _pose_op(c, o, cell)
			img.blit_rect(c, Rect2i(0, 0, cell, cell), Vector2i(f * cell, slot * cell))
	return img

func _pose_op(c: Image, o: Array, cell: int) -> Image:
	var used = c.get_used_rect()
	match str(o[0]):
		"mirror":         # turned round where it stands
			if used.size.x > 0:
				var fig = c.get_region(used); fig.flip_x()
				var out = Image.create(cell, cell, false, Image.FORMAT_RGBA8)
				out.blit_rect(fig, Rect2i(Vector2i.ZERO, fig.get_size()), used.position)
				return out
		"shift":
			var out = Image.create(cell, cell, false, Image.FORMAT_RGBA8)
			out.blit_rect(c, Rect2i(0, 0, cell, cell), Vector2i(int(o[1]), int(o[2])))
			return out
		"bright":
			var out = c.duplicate()
			var k = float(o[1]) / 255.0
			for y in cell:
				for x in cell:
					var p = out.get_pixel(x, y)
					if p.a > 0:
						out.set_pixel(x, y, Color(minf(1, p.r + k), minf(1, p.g + k), minf(1, p.b + k), p.a))
			return out
		"rot":            # a quarter turn, keeping the lowest middle where it was
			if used.size.x > 0:
				var fig = c.get_region(used)
				fig.rotate_90(COUNTERCLOCKWISE if int(o[1]) > 0 else CLOCKWISE)
				var out = Image.create(cell, cell, false, Image.FORMAT_RGBA8)
				var cx = used.position.x + used.size.x / 2
				var nx = clampi(cx - fig.get_width() / 2, 0, cell - fig.get_width())
				var ny = clampi(used.end.y - fig.get_height(), 0, cell - fig.get_height())
				out.blit_rect(fig, Rect2i(Vector2i.ZERO, fig.get_size()), Vector2i(nx, ny))
				return out
		"tilt":           # leaning over: each row slides a little more the higher it is
			if used.size.x > 0:
				var out = Image.create(cell, cell, false, Image.FORMAT_RGBA8)
				for y in range(used.position.y, used.end.y):
					var off = int(roundf((used.end.y - y) * 0.6 * float(o[1])))
					out.blit_rect(c, Rect2i(0, y, cell, 1), Vector2i(off, y))
				return out
	return c

## a variant's own pixels laid over its base set (pictures redrawn by hand, shipped as only the pixels that differ):
## an opaque pixel replaces the set's, a half-transparent one (alpha 128) clears it, a clear one keeps it
func apply_overlay(src: Image, path: String) -> Image:
	var ov = image(path)
	if ov == null:
		printerr("[assets] no overlay ", path)
		return src
	var img: Image = src.duplicate()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	if ov.get_format() != Image.FORMAT_RGBA8:
		ov.convert(Image.FORMAT_RGBA8)
	if ov.get_size() != img.get_size():
		printerr("[assets] overlay ", path, " is not the size of its set")
		return img
	var px: PackedInt32Array = img.get_data().to_int32_array()
	var op: PackedInt32Array = ov.get_data().to_int32_array()
	for i in px.size():
		var a = (op[i] >> 24) & 0xFF
		if a == 255:
			px[i] = op[i]
		elif a == 128:
			px[i] = 0
	return Image.create_from_data(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8, px.to_byte_array())

static func _c32(c: Color) -> int:
	return (c.r8 & 0xFF) | ((c.g8 & 0xFF) << 8) | ((c.b8 & 0xFF) << 16) | (0xFF << 24)

## a tile sheet with your team's colours: "kit" (this game) or a library game
var _sheets = {}
func sheet_image(game: String) -> Image:
	if _sheets.has(game):
		return _sheets[game]
	_sheets[game] = _sheet_image(game)
	return _sheets[game]

func _sheet_image(game: String) -> Image:
	var path = base_dir.path_join("kit/tiles.png") if game == "" or game == "kit" else base_dir.path_join("lib/%s/tiles.png" % game)
	if not FileAccess.file_exists(path):
		return null
	var img = Image.load_from_file(path)
	var rule = colors["tiles"].get("kit" if game == "" else game, {})
	if img == null:
		return null
	if rule.get("only") is Array:      # colours swapped in these tiles alone (the neon-green grass made like the grass beside it)
		img.convert(Image.FORMAT_RGBA8)
		var cols = img.get_width() / 8
		for t in rule["only"]:
			var r = Rect2i((int(t) % cols) * 8, (int(t) / cols) * 8, 8, 8)
			if r.end.y > img.get_height():
				continue
			var part = recolor(img.get_region(r), {"swaps": rule.get("swaps", {})})
			img.blit_rect(part, Rect2i(Vector2i.ZERO, r.size), r.position)
		return img
	return recolor(img, rule)

func fx(name: String) -> Dictionary:
	var key = "fx_" + name
	if _sets.has(key):
		return _sets[key]
	var j = json(base_dir.path_join("fx/%s.json" % name))
	var d = {}
	if j != null:
		d = {"tex": texture(base_dir.path_join("fx/%s.png" % name)), "cell": int(j["cell"]), "slots": j["slots"]}
	_sets[key] = d
	return d

## a foe-attack sheet (fx/e_*.png): {tex, cell, frames: [{w, h, ox, oy}]}
func efx(name: String) -> Dictionary:
	var key = "efx_" + name
	if _sets.has(key):
		return _sets[key]
	var j = json(base_dir.path_join("fx/%s.json" % name))
	var d = {}
	if j != null and j.has("frames"):
		d = {"tex": texture(base_dir.path_join("fx/%s.png" % name)), "cell": int(j["cell"]), "frames": j["frames"]}
	_sets[key] = d
	return d

## how big a set's fighter stands (its first standing frame's own pixels): for moves made for someone smaller or bigger
var _body = {}
func body_size(set_id: int) -> Vector2:
	if _body.has(set_id):
		return _body[set_id]
	var r = Vector2(16, 30)
	var d = sprite_set(set_id)
	if not d.is_empty() and d["tex"] != null:
		var img = _set_image(set_id, d)
		var c: int = d["cell"]
		if img != null and img.get_height() >= c:
			var u = img.get_region(Rect2i(0, 0, c, c)).get_used_rect()
			if u.size.y > 0:
				r = Vector2(u.size)
	_body[set_id] = r
	return r

## the set's finished picture (its outfit's colours, the poses a recipe added): what the hand and the charge are read from
func _set_image(set_id: int, d: Dictionary) -> Image:
	if not d.is_empty() and d["tex"] != null:
		return d["tex"].get_image()
	return image(set_path(set_base(set_id), "png"))

## where the hand is in a pose (offset from the feet): the furthest pixel toward where the fighter faces,
## read from the fighter's own sprite (so a blast leaves exactly from the hand, for every fighter and form)
var _hands = {}
var _imgs = {}
func hand_point(set_id: int, anim: int, dir: int) -> Vector2:
	var key = "%d_%d_%d" % [set_id, anim, dir]
	if _hands.has(key):
		return _hands[key]
	var fallback = [Vector2(0, -12), Vector2(0, -22), Vector2(-12, -16), Vector2(12, -16)][clampi(dir, 0, 3)]
	var d = sprite_set(set_id)
	var res = fallback
	if not d.is_empty():
		var slots: Array = d["slots"]
		var s = anim * 4 + dir
		if s < slots.size() and slots[s].size() > 0:
			var fi = slots[s].size() - 1
			var f: Dictionary = slots[s][fi]
			if not _imgs.has(set_id):
				_imgs[set_id] = _set_image(set_id, d)
			var img: Image = _imgs[set_id]
			if img != null and (s + 1) * int(d["cell"]) > img.get_height():
				img = null          # (a pose the picture does not have: the usual hand place)
			if img != null and dir >= 2:
				var cell: int = d["cell"]
				var ox = fi * cell
				var oy = s * cell
				var best_x = -1
				var ys = []
				var w = int(f["w"]); var h = int(f["h"])
				var xr = range(w - 1, -1, -1) if dir == 3 else range(0, w)
				var y0 = 0
				var y1 = h - 6
				if d.has("hand_band"):
					var u = img.get_region(Rect2i(ox, oy, mini(w, cell), mini(h, cell))).get_used_rect()
					y0 = u.position.y + int(u.size.y * float(d["hand_band"][0]))
					y1 = mini(y1, u.position.y + int(u.size.y * float(d["hand_band"][1])))
				for x in xr:
					for y in range(y0, y1):
						if img.get_pixel(ox + x, oy + y).a > 0.5:
							ys.append(y)
					if not ys.is_empty():
						best_x = x
						break
				if best_x >= 0:
					var my = 0.0
					for y in ys:
						my += y
					my /= ys.size()
					res = Vector2(float(f["x"]) + best_x + (2 if dir == 3 else -2), float(f["y"]) + my)
	_hands[key] = res
	return res

## where the eyes are in a pose (offset from the feet): the red eye pixels in the top half of the figure (Cooler's red
## eye); without any, a third of the way down from the top of the figure, toward where the fighter faces
var _eyes = {}
func eye_point(set_id: int, anim: int, dir: int) -> Vector2:
	var key = "%d_%d_%d" % [set_id, anim, dir]
	if _eyes.has(key):
		return _eyes[key]
	var b = body_size(set_id)
	var res = Vector2({2: -0.3, 3: 0.3}.get(dir, 0.0) * b.x, -b.y * 0.66)
	var d = sprite_set(set_id)
	if not d.is_empty():
		var slots: Array = d["slots"]
		var s = anim * 4 + dir
		if s < slots.size() and slots[s].size() > 0:
			var f: Dictionary = slots[s][0]
			if not _imgs.has(set_id):
				_imgs[set_id] = _set_image(set_id, d)
			var img: Image = _imgs[set_id]
			var cell: int = d["cell"]
			if img != null and (s + 1) * cell <= img.get_height():
				var u = img.get_region(Rect2i(0, s * cell, cell, cell)).get_used_rect()
				if u.size.y > 0:
					var top = u.position.y
					var hgt = u.size.y
					var n = 0
					var sum = Vector2.ZERO
					for y in range(top, top + hgt / 2 if dir != 1 else top):      # (facing up the eyes are hidden: the middle of the head)
						for x in range(u.position.x, u.end.x):
							var c = img.get_pixel(x, s * cell + y)
							if c.a > 0.5 and c.r > 0.55 and c.g < 0.3 and c.b < 0.3:
								sum += Vector2(x, y); n += 1
					var ep = sum / n
					if n == 0:
						# no eye to see: the middle of the head itself (the tail must not pull it over a shoulder)
						var hx = 0.0
						var hn = 0
						for y in range(top + int(hgt * 0.12), top + int(hgt * 0.3)):
							for x in range(u.position.x, u.end.x):
								if img.get_pixel(x, s * cell + y).a > 0.5:
									hx += x; hn += 1
						var mid = hx / hn if hn > 0 else u.position.x + u.size.x * 0.5
						ep = Vector2(mid + u.size.x * {2: -0.15, 3: 0.15}.get(dir, 0.0), top + hgt * 0.34)
					res = Vector2(float(f["x"]) + ep.x, float(f["y"]) + ep.y)
	_eyes[key] = res
	return res

## where the energy gathers in a charge pose: the blue energy ball drawn in the pose's first frame
## (Goku's cupped hands at the hip for the Kamehameha); without one, the middle of the body
var _charges = {}
func charge_point(set_id: int, anim: int, dir: int) -> Vector2:
	var key = "%d_%d_%d" % [set_id, anim, dir]
	if _charges.has(key):
		return _charges[key]
	var res = Vector2(0, -12)
	var d = sprite_set(set_id)
	if not d.is_empty():
		var slots: Array = d["slots"]
		var s = anim * 4 + dir
		if s < slots.size() and slots[s].size() > 0:
			var f: Dictionary = slots[s][0]
			if not _imgs.has(set_id):
				_imgs[set_id] = _set_image(set_id, d)
			var img: Image = _imgs[set_id]
			if img != null and (s + 1) * int(d["cell"]) > img.get_height():
				img = null
			if img != null:
				var cell: int = d["cell"]
				var sx = 0.0; var sy = 0.0; var n = 0
				for y in int(f["h"]):
					for x in int(f["w"]):
						var c = img.get_pixel(x, s * cell + y)
						if c.a > 0.5 and c.b > 0.65 and c.r < 0.55 and c.b > c.r + 0.25:
							sx += x; sy += y; n += 1
				if n >= 2:
					res = Vector2(float(f["x"]) + sx / n, float(f["y"]) + sy / n)
				else:
					res = Vector2(float(f["x"]) + int(f["w"]) / 2.0, float(f["y"]) + int(f["h"]) * 0.55)
	_charges[key] = res
	return res

## the bright middle of the game's ki blast frame (dir row, frame): drawn so this point sits on the blast
var _cores = {}
func ki_core(dir: int, frame: int) -> Vector2:
	var key = dir * 16 + frame
	if _cores.has(key):
		return _cores[key]
	var res = Vector2(16, 16)
	var k = fx("kiblast")
	if not k.is_empty():
		if not _imgs.has("ki"):
			_imgs["ki"] = image(base_dir.path_join("fx/kiblast.png"))
		var img: Image = _imgs["ki"]
		var cell: int = k["cell"]
		var sx = 0.0; var sy = 0.0; var n = 0
		for y in cell:
			for x in cell:
				var c = img.get_pixel(frame * cell + x, dir * cell + y)
				if c.a > 0.5 and c.r > 0.9 and c.g > 0.9 and c.b > 0.85:
					sx += x; sy += y; n += 1
		if n > 0:
			res = Vector2(sx / n, sy / n)
	_cores[key] = res
	return res

func character_set(ch: int) -> int:
	var f = data.get("fighters")
	var forms = data.get("forms")
	if ch >= 0 and ch < CHARACTERS.size():
		var hh = Mods.hero_entry(CHARACTERS[ch])
		var o = outfit_of(ch)
		if not o.is_empty():
			if int(o.get("set", -1)) >= 0:
				return int(o["set"])
		elif hh.has("set") and int(hh["set"]) >= 0:
			return int(hh["set"])
	ch = hero_base(ch)
	if f == null or forms == null or ch < 0 or ch >= f.size():
		return 60
	var over: Dictionary = Content.rom_specials.get("_sets", {})
	if ch < CHARACTERS.size() and over.has(CHARACTERS[ch]):
		return int(over[CHARACTERS[ch]])      # the outfit the game itself shows (rom_specials.json "_sets")
	var form = int(f[ch]["form"])
	return int(forms[form][1])

# ------------------------------------------------------------------ areas
## key: "maps/Z_A" or "floors/gatorra/Z_A"
func area(key: String) -> Dictionary:
	if _areas.has(key):
		return _areas[key]
	if key.begins_with("land/"):
		_areas[key] = _land_area(key)
		if not _areas[key].is_empty():
			Mods.apply_cells(key, _areas[key])      # your team's changes (DEV TOOLS)
		return _areas[key]
	if key.begins_with("custom/"):
		_areas[key] = Mods.custom_area(key.substr(7))
		return _areas[key]
	if key.begins_with("lib/"):        # a map of another game (DEV TOOLS library): to look at and copy from
		_areas[key] = Mods.lib_area(key)
		return _areas[key]
	var dir = base_dir.path_join(key)
	var meta = json(dir.path_join("meta.json"))
	if meta == null:
		return {}
	var a = {"key": key, "meta": meta, "dir": dir, "tw": int(meta["tw"]), "th": int(meta["th"])}
	a["w"] = a["tw"] * 8
	a["h"] = a["th"] * 8
	var layers = []
	for k in 4:
		layers.append(texture(dir.path_join("layer%d.png" % k)))
	a["layers"] = layers
	var walk = PackedByteArray()
	var img = image(dir.path_join("walk.png"))
	walk.resize(a["tw"] * a["th"])
	if img != null:
		img.convert(Image.FORMAT_L8)
		var raw = img.get_data()
		for i in min(raw.size(), walk.size()):
			walk[i] = 1 if ((int(raw[i]) + 42) / 85) & 1 else 0      # bit 1: ground (the export opens ledges you may cross)
	a["walk"] = walk
	var anim = json(dir.path_join("anim.json"))
	a["anim"] = anim if anim != null else []
	a["anim_tex"] = texture(dir.path_join("anim.png")) if anim != null else null
	a["people"] = people(key.get_file()) if key.begins_with("maps/") else []
	_areas[key] = a
	return a

# ------------------------------------------------------------------ the people (villagers, friends, shopkeepers) with their lines
var _people = null
var _speaker_re: RegEx
var _name_re: RegEx
var _cont_re: RegEx

## the people of one of the game's maps ("Z_A"): [{x, y, set, name, lines}] in that map's pixels
func people(map_key: String) -> Array:
	if _people == null:
		_people = _read_people()
	return _people.get(map_key, [])

## one line of the game's text -> [code, name, text]; code "" = no speaker mark; null = leave it out
func _parse_line(l: String, heroes: Dictionary):
	if l.begins_with("@^") or l.begins_with("%s") or l.length() < 4:
		return null
	var m = _name_re.search(l)
	if m != null and heroes.has(m.get_string(1)):
		return null      # the player's own words
	m = _speaker_re.search(l)
	if m != null:
		var nm = m.get_string(2).strip_edges()
		var fix: Dictionary = Content.people_cfg.get("fix_names", {})
		if fix.has(nm):     # no mark: the first letter was part of the name
			nm = str(fix[nm])
			if heroes.has(nm):
				return null
			return ["", nm, m.get_string(3)]
		return [m.get_string(1), nm, m.get_string(3)]
	m = _cont_re.search(l)
	if m != null:
		return [m.get_string(1), "", l.substr(1)]
	return ["", "", l]

func _read_people() -> Dictionary:
	_speaker_re = RegEx.create_from_string("^([^A-Za-z0-9\\s]|[A-Za-z0-9])([A-Z][A-Z .'\\-]{1,22}): (.*)$")
	_name_re = RegEx.create_from_string("^([A-Z][A-Z .'\\-]{1,22}): ")
	_cont_re = RegEx.create_from_string("^([^A-Za-z0-9\\s\"*.]|[a-z])[A-Z\"]")
	var raw = json(base_dir.path_join("data/people.json"))
	var cfg: Dictionary = Content.people_cfg
	var heroes = {}
	for h in cfg.get("heroes", []):
		heroes[str(h)] = true
	var out = {}
	if not raw is Dictionary:
		raw = {}
	# 1. every line parsed; a speaker's mark carries their name to the lines that only have the mark
	var names = {}      # mark -> name
	var parsed = {}     # map -> [[code, name, text] per line] per person
	for mk in raw:
		var pl = []
		for p in raw[mk]:
			var ls = []
			for l in p.get("lines", []):
				var q = _parse_line(str(l), heroes)
				if q == null:
					continue
				if q[1] != "":
					names[q[0]] = q[1]
				ls.append(q)
			pl.append(ls)
		parsed[mk] = pl
	# 2. which mark belongs to which look: the scripts near a person also hold their neighbours' lines,
	#    but a look and its own mark keep turning up together
	var together = {}   # "set|mark" -> people
	var mark_n = {}
	for mk in raw:
		for i in raw[mk].size():
			var seen = {}
			for q in parsed[mk][i]:
				if q[0] != "" and not seen.has(q[0]):
					seen[q[0]] = true
					var k = "%d|%s" % [int(raw[mk][i]["set"]), q[0]]
					together[k] = int(together.get(k, 0)) + 1
					mark_n[q[0]] = int(mark_n.get(q[0], 0)) + 1
	var best_mark = {}
	var best_score = {}
	for k in together:
		var sp = k.split("|")
		var st = int(sp[0])
		var sc = float(together[k]) / sqrt(float(mark_n[sp[1]]))
		if sc > float(best_score.get(st, 0.0)):
			best_score[st] = sc
			best_mark[st] = sp[1]
	# which looks each learned name belongs to (KRILLIN: one look; a townsfolk name: often several)
	var owner = {}
	for st0 in best_mark:
		var on = str(names.get(best_mark[st0], ""))
		if on != "":
			if not owner.has(on):
				owner[on] = []
			owner[on].append(int(st0))
	# 3. each person: their own lines
	var quiet: Dictionary = cfg.get("quiet", {})
	var set_names: Dictionary = cfg.get("names", {})
	var looks: Dictionary = cfg.get("looks", {})
	var over: Dictionary = cfg.get("lines", {})
	var hide = {}
	for h in cfg.get("hide", []):
		hide[str(h)] = true
	for mk in raw:
		var list = []
		var spots = {}
		for i in raw[mk].size():
			if hide.has("%s:%d" % [mk, i]):
				continue
			var p: Dictionary = raw[mk][i]
			var st = int(p["set"])
			var ls: Array = parsed[mk][i]
			var mark = str(best_mark.get(st, ""))
			var has = false
			for q in ls:
				if q[0] == mark and mark != "":
					has = true
			var nm = ""
			var own_mark = str(best_mark.get(st, ""))
			var own_nm = str(names.get(own_mark, "")) if own_mark != "" else ""
			var sure = own_nm != "" and owner.get(own_nm, []).size() == 1      # a name only this look has (KRILLIN, CHI-CHI)
			if not has:
				mark = ""
				for q in ls:
					if q[0] != "":
						mark = q[0]
						break
				# the line next to them is another character's own (GOKU's line beside KRILLIN: the game shows only
				# some of a scene's people at a time): they stay themselves, with nothing of the other's to say
				var other = ""      # the name written in that line (a mark can belong to several people)
				for q in ls:
					if mark != "" and q[0] == mark and q[1] != "":
						other = str(q[1])
						break
				if sure and other != "" and other != own_nm and owner.has(other) and not owner[other].has(st):
					nm = own_nm
					mark = "-"
			# a look that is always one person (PICCOLO's): never the name in a line beside them (HERCULE's)
			if looks.has(str(st)):
				nm = str(looks[str(st)])
				mark = "-"
			# one look can stand for several people (the same face for BILLY and FERNANDO): the first name under the mark is theirs
			for q in ls:
				if mark != "" and q[0] == mark and q[1] != "":
					nm = q[1]
					break
			var lines = []
			var cur = ""
			for q in ls:
				if q[0] == mark and q[1] != "":
					cur = q[1]
				if (mark != "" and q[0] == mark and (nm == "" or cur == nm or (q[1] == "" and cur == ""))) or (mark == "" and q[0] == ""):
					var t = str(q[2]).strip_edges()
					if t != "" and not lines.has(t):
						lines.append(t)
			lines = lines.slice(0, 6)
			if nm == "" and mark != "":
				nm = str(names.get(mark, ""))
			if nm == "":
				nm = str(set_names.get(str(st), ""))
			if nm == "" and sure and ls.is_empty():
				nm = own_nm      # nothing to say at all: still CHI-CHI, not a VILLAGER
			if over.has("%s:%d" % [mk, i]):
				lines = over["%s:%d" % [mk, i]]
			if lines.is_empty():
				lines = quiet.get(nm, quiet.get("default", ["..."]))
			# the game parks a scene's whole cast on one spot until the scene plays: stand them around it
			var x = float(p["x"])
			var y = float(p["y"])
			var sk = "%d,%d" % [int(x), int(y)]
			var n = int(spots.get(sk, 0))
			spots[sk] = n + 1
			if n > 0:
				var ang = n * 2.3
				x += cos(ang) * (14.0 + n * 3.0)
				y += sin(ang) * (10.0 + n * 2.0)
			list.append({"x": x, "y": y, "set": st, "name": nm if nm != "" else "VILLAGER", "lines": lines, "id": "%s:%d" % [mk, i]})
		out[mk] = list
	var add: Dictionary = cfg.get("add", {})
	for mk in add:
		if not out.has(mk):
			out[mk] = []
		var j = 0
		for p in add[mk]:
			if p is Dictionary:
				out[mk].append({"x": float(p.get("x", 0)), "y": float(p.get("y", 0)), "set": int(p.get("set", 80)), "name": str(p.get("name", "VILLAGER")),
					"lines": p.get("lines", ["..."]), "id": "%s:+%d" % [mk, j]})
				j += 1
	return out

# ------------------------------------------------------------------ the lands (the game's maps joined edge to edge)
var _lands = {}
var _tileset: TileSet
var _anim_rows = {}      # animated tile id -> {row, frames, durations}
var kit_tiles = 0

func has_kit() -> bool:
	return FileAccess.file_exists(base_dir.path_join("kit/maps.json"))

func land(z: int) -> Dictionary:
	if _lands.has(z):
		return _lands[z]
	var j = json(base_dir.path_join("kit/lands/%d/lands.json" % z))
	_lands[z] = j if j != null else {}
	# EARTH's roaming foes: the same list for everybody (the importer's grown country differs a little per system)
	var ef = builtin_dir().path_join("earth/earth_enemies.json")
	if z == 0 and FileAccess.file_exists(ef) and _lands[z].has("regions") and _lands[z]["regions"].size() > 0:
		var en = json(ef)
		if en is Array:
			_lands[z]["regions"][0]["enemies"] = en
	return _lands[z]

## EARTH as it ships (builtin/earth: tile numbers and walls, no picture of the game) laid over this
## machine's own import once - everybody walks the same Earth, edits and all (tools/bake_earth.py)
func _earth_base(bin_path: String) -> void:
	var src = builtin_dir().path_join("earth/earth_base.gz")
	if not FileAccess.file_exists(src) or not FileAccess.file_exists(bin_path):
		return
	var ver = FileAccess.get_file_as_string(builtin_dir().path_join("earth/version.txt")).strip_edges()
	var stamp_path = bin_path.get_base_dir().path_join("earth_base.txt")
	var stamp = "%s|%d" % [ver, FileAccess.get_modified_time(bin_path)]
	if FileAccess.file_exists(stamp_path) and FileAccess.get_file_as_string(stamp_path).strip_edges() == stamp:
		return      # laid in already (a new import or a new Earth lays it again)
	var body = FileAccess.get_file_as_bytes(src).decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
	var head = FileAccess.get_file_as_bytes(bin_path).slice(0, 8)
	if body.size() < 8 or body.slice(0, 8) != head:
		print("[assets] the shipped Earth does not fit this import: left out")
		return
	var f = FileAccess.open(bin_path, FileAccess.WRITE)
	if f == null:
		return
	f.store_buffer(body)
	f.close()
	# the minimap: the cells the edits changed drawn in (the picture is the import's)
	var mini_path = bin_path.get_base_dir().path_join("0_mini.png")
	var img = Image.load_from_file(mini_path) if FileAccess.file_exists(mini_path) else null
	var chp = builtin_dir().path_join("earth/earth_changed.gz")
	if img != null and FileAccess.file_exists(chp):
		img.convert(Image.FORMAT_RGBA8)
		var idx = FileAccess.get_file_as_bytes(chp).decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP).to_int32_array()
		var tw = body.decode_u16(4)
		var n = tw * body.decode_u16(6)
		var ls = []
		for k in 5:
			ls.append(body.slice(8 + k * n * 4, 8 + (k + 1) * n * 4).to_int32_array())
		var MT = preload("res://scripts/dev_maptools.gd")
		var iw = img.get_width(); var ih = img.get_height()
		for i in idx:
			var x = i % tw; var y = i / tw
			if x < iw and y < ih:
				var col: Color = MT.cell_color([ls[0][i], ls[1][i], ls[2][i], ls[3][i], ls[4][i]]); col.a = 1.0
				img.set_pixel(x, y, col)
		img.save_png(mini_path)
		_tex.erase(mini_path)
	var sf = FileAccess.open(stamp_path, FileAccess.WRITE)
	if sf:
		sf.store_string("%s|%d" % [ver, FileAccess.get_modified_time(bin_path)])
		sf.close()
	print("[assets] Earth laid in: ", ver)

## every tile of the game in one TileSet (tiles are made the first time a map uses them)
const SRC_ROWS = 16      # the tile sheet cut in strips of 64 x 16 tiles: one atlas each

func tileset() -> TileSet:
	if _tileset != null:
		return _tileset
	var km = json(base_dir.path_join("kit/maps.json"))
	kit_tiles = int(km["tiles"]) if km != null else 0
	var aj = json(base_dir.path_join("kit/anim.json"))
	if aj != null:
		for a in aj:
			_anim_rows[int(a["id"])] = a
	_tileset = TileSet.new()
	_tileset.tile_size = Vector2i(8, 8)
	# every tile made once, here, before the tile set is used (a tile made while you walk made every
	# tile layer redo itself: the game hitched each time new ground came into view). Small strips: fast.
	var sheet: Image = sheet_image("kit")
	if sheet == null:
		return _tileset
	var rows = sheet.get_height() / 8
	var anim_at = {}      # strip -> [[local row, anim]]
	for id in _anim_rows:
		var a: Dictionary = _anim_rows[id]
		var r = int(a["row"])
		if not anim_at.has(r / SRC_ROWS):
			anim_at[r / SRC_ROWS] = []
		anim_at[r / SRC_ROWS].append([r % SRC_ROWS, a])
	var nsrc = int(ceil(rows / float(SRC_ROWS)))
	for si in nsrc:
		var y0 = si * SRC_ROWS * 8
		var h = mini(SRC_ROWS * 8, sheet.get_height() - y0)
		var src = TileSetAtlasSource.new()
		src.texture = ImageTexture.create_from_image(sheet.get_region(Rect2i(0, y0, sheet.get_width(), h)))
		src.texture_region_size = Vector2i(8, 8)
		var anim_rows_here = {}
		for e in anim_at.get(si, []):
			var at = Vector2i(0, int(e[0]))
			var a: Dictionary = e[1]
			var n = int(a["frames"])
			src.create_tile(at)
			if n > 1:
				src.set_tile_animation_columns(at, 0)
				src.set_tile_animation_frames_count(at, n)
				for f in n:
					src.set_tile_animation_frame_duration(at, f, maxf(1.0, float(a["durations"][f])) / 60.0)
			anim_rows_here[int(e[0])] = true
		for ly in h / 8:
			if anim_rows_here.has(ly):
				continue
			for lx in 64:
				var id = (si * SRC_ROWS + ly) * 64 + lx
				if id <= 0 or id >= kit_tiles:
					continue
				src.create_tile(Vector2i(lx, ly))
		_tileset.add_source(src, si)
	# the other games' tiles (DEV TOOLS library: Buu's Fury...), each its own strips after the kit's
	var next_src = nsrc
	for g in LIB_GAMES:
		var lj = json(base_dir.path_join("lib/%s/maps.json" % g))
		var lsheet: Image = sheet_image(g) if lj != null else null
		if lsheet == null:
			continue
		var nt = int(lj.get("tiles", 0))
		_lib_src[LIB_GAMES[g]] = [next_src, nt]
		var lrows = lsheet.get_height() / 8
		for li in int(ceil(lrows / float(SRC_ROWS))):
			var ly0 = li * SRC_ROWS * 8
			var lh = mini(SRC_ROWS * 8, lsheet.get_height() - ly0)
			var ls = TileSetAtlasSource.new()
			ls.texture = ImageTexture.create_from_image(lsheet.get_region(Rect2i(0, ly0, lsheet.get_width(), lh)))
			ls.texture_region_size = Vector2i(8, 8)
			for ly in lh / 8:
				for lx in 64:
					var id = (li * SRC_ROWS + ly) * 64 + lx
					if id > 0 and id < nt:
						ls.create_tile(Vector2i(lx, ly))
			_tileset.add_source(ls, next_src + li)
		next_src += int(ceil(lrows / float(SRC_ROWS)))
	return _tileset

## the other games the DEV TOOLS can take pieces from: folder -> number in a cell (bits 21-23)
const LIB_GAMES = {"bf": 1, "log1": 2}
const LIB_TITLES = {"bf": "BUU'S FURY", "log1": "LEGACY OF GOKU"}
var _lib_src = {}        # game number -> [first atlas source, tiles]

## a cell of the kit -> [atlas coords, alternative (flips), atlas source]; [] for nothing
func kit_cell(cell: int) -> Array:
	if cell == 0 or cell & (1 << 18):
		return []
	tileset()
	var id = cell & 0xFFFF
	var at: Vector2i
	var si: int
	if cell & (1 << 20):     # a tile of another game (the DEV TOOLS library)
		var ls = _lib_src.get((cell >> 21) & 7, null)
		if ls == null or id <= 0 or id >= int(ls[1]):
			return []
		at = Vector2i(id % 64, (id / 64) % SRC_ROWS)
		si = int(ls[0]) + (id / 64) / SRC_ROWS
	elif cell & (1 << 19) and _anim_rows.has(id):
		var r = int(_anim_rows[id]["row"])
		at = Vector2i(0, r % SRC_ROWS)
		si = r / SRC_ROWS
	else:
		if id <= 0 or id >= kit_tiles:
			return []
		at = Vector2i(id % 64, (id / 64) % SRC_ROWS)
		si = (id / 64) / SRC_ROWS
	var alt = 0
	if cell & (1 << 16):
		alt |= TileSetAtlasSource.TRANSFORM_FLIP_H
	if cell & (1 << 17):
		alt |= TileSetAtlasSource.TRANSFORM_FLIP_V
	return [at, alt, si]

## a region of a land as an area: "land/Z/R"
func _land_area(key: String) -> Dictionary:
	var parts = key.split("/")
	var z = int(parts[1])
	var r = int(parts[2])
	var L = land(z)
	if L.is_empty() or r >= L["regions"].size():
		return {}
	var reg: Dictionary = L["regions"][r]
	# EARTH: the places behind doors are the lands' own files
	var fz = z
	var fr = r
	if reg.has("src"):
		fz = int(reg["src"][0])
		fr = int(reg["src"][1])
	if fz == 0 and fr == 0:
		_earth_base(base_dir.path_join("kit/lands/0/0.bin"))
	var data = FileAccess.get_file_as_bytes(base_dir.path_join("kit/lands/%d/%d.bin" % [fz, fr]))
	if data.size() < 8:
		return {}
	var tw = data.decode_u16(4)
	var th = data.decode_u16(6)
	var n = tw * th
	var cells = []
	var o = 8
	for k in 5:
		cells.append(data.slice(o, o + n * 4).to_int32_array())
		o += n * 4
	var walk: PackedByteArray = data.slice(o, o + n)
	var ready = data[3] == 50     # "LKR2": the ground is written ready to use
	data = PackedByteArray()
	if walk.size() < n:
		walk.resize(n)
	if not ready:
		for i in n:      # an older import: only bit 1 is ground
			walk[i] = walk[i] & 1
	var km = json(base_dir.path_join("kit/maps.json"))
	var bd = km["backdrop"] if km != null else [0, 0, 0]
	var meta = {"tw": tw, "th": th, "pri": [0, 0, 0, 0], "name": reg["name"], "exits": [], "arrival": reg["arrival"], "backdrop": bd, "objects": []}
	var a = {"key": key, "meta": meta, "dir": "", "tw": tw, "th": th, "w": tw * 8, "h": th * 8, "layers": [null, null, null, null],
		"walk": walk, "anim": [], "anim_tex": null, "land": {"zone": int(reg.get("land", z)), "region": r, "cells": cells, "info": reg}}
	a["mini"] = texture(base_dir.path_join("kit/lands/%d/%d_mini.png" % [fz, fr]))
	# the original areas inside this region (to name the place you walk into)
	var parts2 = []
	var ppl = []
	var byk = {}
	if km != null:
		for mm in km["maps"]:
			byk[str(mm["key"])] = mm
	for m in reg["maps"]:
		var mm = byk.get(str(m[0]), {})
		var nm2 = str(mm.get("name", ""))
		if nm2 == "":
			nm2 = str(mm.get("place", ""))
		parts2.append([Rect2(float(m[1]), float(m[2]), int(mm.get("tw", 40)) * 8, int(mm.get("th", 30)) * 8), nm2.to_upper(), int(mm.get("song", -1))])
		for p in people(str(m[0])):
			var q: Dictionary = p.duplicate()
			q["x"] = float(p["x"]) + float(m[1])
			q["y"] = float(p["y"]) + float(m[2])
			ppl.append(q)
	a["land"]["parts"] = parts2
	a["people"] = ppl
	a["saves"] = save_points(cells, tw)
	return a

## the Capsule Corp save points: the round pad with the C. Its middle tile (the game's own, always the same one)
## marks the spot; any layer, mirrored or not (Android port)
const SAVE_PAD_TILE = 7263
func save_points(cells: Array, tw: int) -> Array:
	var out = []
	for c in cells:
		var layer: PackedInt32Array = c
		for v in [SAVE_PAD_TILE, SAVE_PAD_TILE | (1 << 16), SAVE_PAD_TILE | (2 << 16), SAVE_PAD_TILE | (3 << 16)]:
			var i = layer.find(v)
			while i >= 0:
				out.append(Vector2((i % tw) * 8, (i / tw) * 8))
				i = layer.find(v, i + 1)
	return out

## the collision value under a point: 0 wall, 1 ground, 2 raised ground (bridges, cliff tops), 3 both (where you step up)
func walk_at(a: Dictionary, x: float, y: float) -> int:
	var cx = int(floor(x / 8.0))
	var cy = int(floor(y / 8.0))
	if cx < 0 or cy < 0 or cx >= a["tw"] or cy >= a["th"]:
		return 0
	return a["walk"][cy * a["tw"] + cx]

func walkable(a: Dictionary, x: float, y: float) -> bool:
	var cx = int(floor(x / 8.0))
	var cy = int(floor(y / 8.0))
	if cx < 0 or cy < 0 or cx >= a["tw"] or cy >= a["th"]:
		return false
	return a["walk"][cy * a["tw"] + cx] != 0

func area_name(a: Dictionary) -> String:
	return str(a["meta"].get("name", ""))

# ------------------------------------------------------------------ music: which of the game's songs plays where
var _zone_song = {}
## the song the original plays at this spot (an index into the game's song table), -1 = none known
func area_song(a: Dictionary, p: Vector2) -> int:
	if a.is_empty():
		return -1
	var s = -1
	var z = -1
	if a.has("land"):
		z = int(a["land"]["zone"])
		for pt in a["land"]["parts"]:
			if pt.size() > 2 and pt[0].has_point(p):
				s = int(pt[2])
				break
		if s < 0 and z == 0:      # EARTH: out in the country, the song of the nearest place
			var bd = INF
			for pt in a["land"]["parts"]:
				if pt.size() > 2 and int(pt[2]) >= 0:
					var r: Rect2 = pt[0]
					var d = Vector2(maxf(0.0, maxf(r.position.x - p.x, p.x - r.end.x)), maxf(0.0, maxf(r.position.y - p.y, p.y - r.end.y))).length_squared()
					if d < bd:
						bd = d
						s = int(pt[2])
		if s < 0:      # between the original areas, or a map whose song a script picks: the region's usual one
			var cnt = {}
			for pt in a["land"]["parts"]:
				if pt.size() > 2 and int(pt[2]) >= 0:
					cnt[int(pt[2])] = cnt.get(int(pt[2]), 0) + 1
			var best = 0
			for k in cnt:
				if cnt[k] > best:
					best = cnt[k]
					s = k
	elif a.has("meta"):
		s = int(a["meta"].get("song", -1))
		var key = str(a.get("key", ""))
		if key.begins_with("maps/"):
			z = int(key.substr(5).split("_")[0])
	if s < 0 and z >= 0:
		s = zone_song(z)
	return s

## the song most of a land's outdoor maps play
func zone_song(z: int) -> int:
	if _zone_song.has(z):
		return _zone_song[z]
	var km = json(base_dir.path_join("kit/maps.json"))
	var cnt = {}
	if km != null:
		for mm in km["maps"]:
			if int(mm.get("zone", -1)) == z and int(mm.get("song", -1)) >= 0:
				var k = int(mm["song"])
				cnt[k] = cnt.get(k, 0) + 1
	var s = -1
	var best = 0
	for k in cnt:
		if cnt[k] > best:
			best = cnt[k]
			s = k
	_zone_song[z] = s
	return s

## the sprite set the game uses for an enemy type (from the maps that place it)
var _type_set = {}
func set_for_type(t: int) -> int:
	if _type_set.is_empty():
		var km = json(base_dir.path_join("kit/maps.json"))
		if km != null:
			for mm in km["maps"]:
				for o in mm.get("objects", []):
					if o["kind"] == "enemy" and not _type_set.has(int(o["type"])):
						_type_set[int(o["type"])] = int(o["set"])
	return int(_type_set.get(t, 18))

# ------------------------------------------------------------------ sharing the game files with a phone
## A PC that has imported its game hands the "imported" folder to a phone or tablet on the same network
## (or over Tailscale / ZeroTier): the phone can't run the importer or the music recorder itself.
## Port 7778 (TCP). Only files inside the imported folder are ever sent; nothing comes in.
const SHARE_PORT = 7778
var share_server: TCPServer
var _share_threads = []
var fetch_thread: Thread
var fetch_status = ""          # what the phone shows while it downloads
var fetch_done = 0             # bytes
var fetch_total = 0
var fetch_result = -1          # -1 working / 0 ok / 1 failed

func start_sharing() -> void:
	if share_server != null or base_dir == "" or OS.has_feature("mobile"):
		return
	share_server = TCPServer.new()
	if share_server.listen(SHARE_PORT) != OK:
		share_server = null

func _process(_dt: float) -> void:
	if share_server != null and share_server.is_connection_available():
		var peer = share_server.take_connection()
		var th = Thread.new()
		th.start(_share_serve.bind(peer, th))
		_share_threads.append(th)
	for th in _share_threads.duplicate():
		if not th.is_alive():
			th.wait_to_finish()
			_share_threads.erase(th)

static func _list_files(root: String, rel: String, out: Array) -> void:
	var d = DirAccess.open(root.path_join(rel))
	if d == null:
		return
	for f in d.get_files():
		var p = rel.path_join(f) if rel != "" else f
		var fa = FileAccess.open(root.path_join(p), FileAccess.READ)
		if fa:
			out.append({"p": p, "s": fa.get_length()})
	for sub in d.get_directories():
		_list_files(root, rel.path_join(sub) if rel != "" else sub, out)

static func _read_line(peer: StreamPeerTCP, limit_ms: int) -> String:
	var line = PackedByteArray()
	var t0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < limit_ms:
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return ""
		if peer.get_available_bytes() > 0:
			var r = peer.get_data(1)
			if r[0] != OK:
				return ""
			if r[1][0] == 10:
				return line.get_string_from_utf8()
			line.append(r[1][0])
		else:
			OS.delay_msec(2)
	return ""

func _share_serve(peer: StreamPeerTCP, _th: Thread) -> void:
	peer.set_no_delay(true)
	var root = base_dir
	while true:
		var req = _read_line(peer, 60000)
		if req == "":
			break
		if req == "LIST":
			var files = []
			_list_files(root, "", files)
			peer.put_data((JSON.stringify(files) + "\n").to_utf8_buffer())
		elif req.begins_with("GET "):
			var rel = req.substr(4)
			# only inside the imported folder
			if rel.begins_with("/") or rel.contains("..") or rel.contains(":"):
				break
			var data = FileAccess.get_file_as_bytes(root.path_join(rel))
			var hdr = PackedByteArray()
			hdr.resize(8)
			hdr.encode_s64(0, data.size())
			peer.put_data(hdr)
			var o = 0
			while o < data.size():
				var n = mini(65536, data.size() - o)
				if peer.put_data(data.slice(o, o + n)) != OK:
					return
				o += n
		else:
			break
	peer.disconnect_from_host()

## the phone: fetch every file from the PC at ip into user://imported
func start_fetch(ip: String) -> void:
	fetch_result = -1
	fetch_done = 0
	fetch_total = 0
	fetch_status = "Connecting to %s..." % ip
	fetch_thread = Thread.new()
	fetch_thread.start(_fetch_worker.bind(ip))

func _fetch_worker(ip: String) -> void:
	var peer = StreamPeerTCP.new()
	if peer.connect_to_host(ip, SHARE_PORT) != OK:
		_fetch_end(1, "Could not reach %s." % ip)
		return
	var t0 = Time.get_ticks_msec()
	while peer.get_status() == StreamPeerTCP.STATUS_CONNECTING and Time.get_ticks_msec() - t0 < 8000:
		peer.poll()
		OS.delay_msec(20)
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_fetch_end(1, "No answer from %s. Is the game open on the PC (with its game read), on the same Wi-Fi?" % ip)
		return
	peer.put_data("LIST\n".to_utf8_buffer())
	var files = JSON.parse_string(_read_line(peer, 30000))
	if not files is Array or files.is_empty():
		_fetch_end(1, "The PC sent no files - start the game on the PC once and choose your game there first.")
		return
	for f in files:
		fetch_total += int(f["s"])
	var dest = ProjectSettings.globalize_path("user://imported_new")
	DirAccess.make_dir_recursive_absolute(dest)
	# the picture files first, the music last (you can play while it ends? no: all of it, then play)
	files.sort_custom(func(x, y): return (1 if str(x["p"]).begins_with("music/") else 0) < (1 if str(y["p"]).begins_with("music/") else 0))
	for f in files:
		var rel = str(f["p"])
		fetch_status = "Getting the game files from your PC: %d of %d MB" % [fetch_done / 1048576, fetch_total / 1048576]
		peer.put_data(("GET " + rel + "\n").to_utf8_buffer())
		var need = 8
		var hdr = _recv(peer, 8)
		if hdr.size() != 8:
			_fetch_end(1, "The connection dropped.")
			return
		need = hdr.decode_s64(0)
		var body = _recv(peer, need)
		if body.size() != need:
			_fetch_end(1, "The connection dropped.")
			return
		DirAccess.make_dir_recursive_absolute(dest.path_join(rel).get_base_dir())
		var fa = FileAccess.open(dest.path_join(rel), FileAccess.WRITE)
		if fa:
			fa.store_buffer(body)
			fa.close()
		fetch_done += need
	peer.disconnect_from_host()
	# swap the new folder in (an old one goes away)
	var old = ProjectSettings.globalize_path("user://imported")
	if DirAccess.dir_exists_absolute(old):
		_rm_tree(old)
	DirAccess.rename_absolute(dest, old)
	_fetch_end(0, "Done!")

func _recv(peer: StreamPeerTCP, n: int) -> PackedByteArray:
	var out = PackedByteArray()
	var t0 = Time.get_ticks_msec()
	while out.size() < n and Time.get_ticks_msec() - t0 < 30000:
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			break
		var av = peer.get_available_bytes()
		if av > 0:
			var r = peer.get_data(mini(av, n - out.size()))
			if r[0] != OK:
				break
			out.append_array(r[1])
			t0 = Time.get_ticks_msec()
			fetch_done += 0
		else:
			OS.delay_msec(1)
	return out

static func _rm_tree(path: String) -> void:
	var d = DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		d.remove(f)
	for sub in d.get_directories():
		_rm_tree(path.path_join(sub))
	DirAccess.remove_absolute(path)

func _fetch_end(code: int, msg: String) -> void:
	fetch_status = msg
	call_deferred("_fetch_finish", code)

func _fetch_finish(code: int) -> void:
	if fetch_thread != null:
		fetch_thread.wait_to_finish()
		fetch_thread = null
	base_dir = find_import_dir()
	_json.clear(); _tex.clear(); _sets.clear(); _areas.clear()
	fetch_result = code if code != 0 or base_dir != "" else 1
