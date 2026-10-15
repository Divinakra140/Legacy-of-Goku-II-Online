extends Node
## YOUR TEAM'S EDITS - everything the DEV TOOLS change lives in the "mods" folder next to LoG2Coop.exe
## (and in "content" for characters, moves and missions), so a new import of the game never loses it:
##   mods/maps/<map>.json        changes to one of the game's maps: tiles, walls, foes, people, doors, items
##   mods/maps/custom/<name>.bin  a map your team made (its tiles and walls)  + <name>.json (its name, doors...)
## A map key is the game's own: "land/0/0" is EARTH; "custom/<name>" a map of your own.

var _patches = {}

## a JSON file (null if missing, empty or broken - never an error box)
static func read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return parse_json(FileAccess.get_file_as_string(path))

static func parse_json(txt: String) -> Variant:
	if txt.strip_edges() == "":
		return null
	var j = JSON.new()
	if j.parse(txt) != OK:
		printerr("[mods] bad JSON: line %d %s" % [j.get_error_line(), j.get_error_message()])
		return null
	return j.data

func dir() -> String:
	return Assets.exe_dir().path_join("mods")

func maps_dir() -> String:
	return dir().path_join("maps")

func custom_dir() -> String:
	return maps_dir().path_join("custom")

static func file_key(key: String) -> String:
	return key.replace("/", "_")

## the changes to one map (an empty set if none)
func patch(key: String) -> Dictionary:
	if _patches.has(key):
		return _patches[key]
	var p = {}
	var f = maps_dir().path_join(file_key(key) + ".json")
	if FileAccess.file_exists(f):
		var t = read_json(f)
		if t is Dictionary:
			p = t
	_fill_patch(p)
	_patches[key] = p
	return p

const PATCH_KEYS = ["cells", "enemies_add", "enemies_del", "people_add", "people_del", "doors_add", "doors_del", "items", "items_del", "zones", "triggers", "moods"]
static func _fill_patch(p: Dictionary) -> void:
	for k in PATCH_KEYS:
		if not p.has(k):
			p[k] = {} if k == "cells" else []

# ------------------------------------------------------------------ MOD PACKAGES (modpacks/<folder>/: mod.json, maps/, content/)
## The mods people share: each one a folder in "modpacks" next to LoG2Coop.exe (a .zip dropped there is
## unpacked the first time). The ones switched on (modpacks/enabled.json, in that order) are laid over the
## game, then your own edits (mods/ and content/) over all of them.
func packs_dir() -> String:
	return Assets.exe_dir().path_join("modpacks")

func installed_packs() -> Array:
	_unpack_dropped()
	var out = []
	var en = enabled_names()
	var d = DirAccess.open(packs_dir())
	if d == null:
		return out
	for f in d.get_directories():
		var mj = packs_dir().path_join(f).path_join("mod.json")
		var m = {}
		if FileAccess.file_exists(mj):
			var t = read_json(mj)
			if t is Dictionary:
				m = t
		m["folder"] = f
		m["enabled"] = en.has(f)
		out.append(m)
	out.sort_custom(func(a, b):
		var ia = en.find(a["folder"]); var ib = en.find(b["folder"])
		if ia < 0: ia = 9999
		if ib < 0: ib = 9999
		return ia < ib if ia != ib else str(a["folder"]) < str(b["folder"]))
	return out

func enabled_names() -> Array:
	var f = packs_dir().path_join("enabled.json")
	if FileAccess.file_exists(f):
		var t = read_json(f)
		if t is Array:
			return t.filter(func(x): return DirAccess.dir_exists_absolute(packs_dir().path_join(str(x))))
	return []

func set_enabled(names: Array) -> void:
	DirAccess.make_dir_recursive_absolute(packs_dir())
	var fa = FileAccess.open(packs_dir().path_join("enabled.json"), FileAccess.WRITE)
	if fa:
		fa.store_string(JSON.stringify(names))
		fa.close()
	reload()

## a mod that holds a story (content/story.json) only counts while its story is played (STORY MODE): its dark park,
## people and doors stay out of FREE PLAY
var story_pack = ""

## every layer under your own edits: the switched-on packs, first = lowest
func pack_dirs() -> Array:
	var out = []
	var names = enabled_names()
	if story_pack != "" and not names.has(story_pack):
		names.append(story_pack)
	for n in names:
		var d = packs_dir().path_join(str(n))
		if str(n) != story_pack and FileAccess.file_exists(d.path_join("content/story.json")):
			continue
		out.append(d)
	return out

## all the files of a content kind, lowest first: the packs', then yours
func content_paths(file: String) -> Array:
	var out = []
	for d in pack_dirs():
		var f = d.path_join("content/%s.json" % file)
		if FileAccess.file_exists(f):
			out.append(f)
	out.append(Assets.exe_dir().path_join("content/%s.json" % file))
	return out

## forget everything read (after switching packs on or off)
func reload() -> void:
	_patches.clear()
	_merged.clear()
	Assets._areas.clear()
	load_heroes()
	Assets.load_colors()
	Content.reload()

var _merged = {}
## one map's changes from every pack switched on and your own (yours last: they win)
func merged(key: String) -> Dictionary:
	var m = {}
	_fill_patch(m)
	var layers = []
	for d in pack_dirs():
		var f = d.path_join("maps").path_join(file_key(key) + ".json")
		if FileAccess.file_exists(f):
			var t = read_json(f)
			if t is Dictionary:
				_fill_patch(t)
				layers.append(t)
	layers.append(patch(key))
	for p in layers:
		for c in p["cells"]:
			m["cells"][c] = p["cells"][c]
		for k in PATCH_KEYS:
			if k != "cells":
				m[k] = m[k] + p[k]
	return m

## the cells each layer changes on a map: [[layer name, {"x,y": true}], ...] (for the CHANGES view)
func changed_cells(key: String) -> Array:
	var out = []
	for d in pack_dirs():
		var f = d.path_join("maps").path_join(file_key(key) + ".json")
		if FileAccess.file_exists(f):
			var t = read_json(f)
			if t is Dictionary and t.get("cells") is Dictionary:
				out.append([d.get_file(), t["cells"]])
	out.append(["yours", patch(key)["cells"]])
	return out

## where packs (and your edits) change the same things: shown in the MODS list
func conflicts() -> Array:
	var out = []
	var owners = {}        # "map|x,y" -> [names]
	var vals = {}          # "map|x,y" -> the cell (or "*" when they differ)
	var ids = {}           # "file:id" -> [names]
	var layers = []
	for d in pack_dirs():
		layers.append([d.get_file(), d])
	layers.append(["YOUR EDITS", Assets.exe_dir()])
	for L in layers:
		var mdir = (L[1] as String).path_join("mods/maps") if L[0] == "YOUR EDITS" else (L[1] as String).path_join("maps")
		var da = DirAccess.open(mdir)
		if da:
			for f in da.get_files():
				if not f.ends_with(".json"):
					continue
				var t = read_json(mdir.path_join(f))
				if t is Dictionary and t.get("cells") is Dictionary:
					for c in t["cells"]:
						var k = f.get_basename() + "|" + str(c)
						if not owners.has(k):
							owners[k] = []
							vals[k] = str(t["cells"][c])
						elif vals[k] != str(t["cells"][c]):
							vals[k] = "*"          # (only a real difference counts)
						if not owners[k].has(L[0]):
							owners[k].append(L[0])
		var cdir = (L[1] as String).path_join("content")
		var dc = DirAccess.open(cdir)
		if dc and L[0] != "YOUR EDITS":
			for f in dc.get_files():
				if not f.ends_with(".json"):
					continue
				var t = read_json(cdir.path_join(f))
				if not t is Dictionary:
					continue
				for kk in t:
					if t[kk] is Array:
						for e in t[kk]:
							if e is Dictionary and e.has("id"):
								var k = f.get_basename() + ":" + str(e["id"])
								if not ids.has(k):
									ids[k] = []
								if not ids[k].has(L[0]):
									ids[k].append(L[0])
	var per = {}
	for k in owners:
		if owners[k].size() > 1 and vals[k] == "*":
			var mk = k.split("|")[0] + " - " + " / ".join(PackedStringArray(owners[k]))
			per[mk] = per.get(mk, 0) + 1
	for mk in per:
		out.append("%d tiles changed by more than one: %s (the last one wins)" % [per[mk], mk])
	for k in ids:
		if ids[k].size() > 1:
			out.append("%s is in %s (the last one wins)" % [k, " and ".join(PackedStringArray(ids[k]))])
	return out

## a .zip dropped in modpacks: unpacked into a folder of its own (the zip is kept, renamed .installed)
func _unpack_dropped() -> void:
	var d = DirAccess.open(packs_dir())
	if d == null:
		return
	for f in d.get_files():
		if f.to_lower().ends_with(".zip"):
			import_pack(packs_dir().path_join(f))
			d.rename(f, f + ".installed")

## put a mod package (.zip) in: unpacked into modpacks/<its name>/ and switched on
func import_pack(zip_path: String) -> String:
	var z = ZIPReader.new()
	if z.open(zip_path) != OK:
		return "Could not open " + zip_path.get_file()
	var files = z.get_files()
	var root = ""
	for f in files:
		if f.get_file() == "mod.json":
			root = f.get_base_dir()
			break
	if not files.has(root.path_join("mod.json") if root != "" else "mod.json"):
		z.close()
		return "%s is not a LoG2 Co-op mod (no mod.json in it)" % zip_path.get_file()
	var meta = parse_json(z.read_file(root.path_join("mod.json") if root != "" else "mod.json").get_string_from_utf8())
	var name = _safe(str(meta.get("name", zip_path.get_file().get_basename())) if meta is Dictionary else zip_path.get_file().get_basename())
	var dest = packs_dir().path_join(name)
	for f in files:
		if f.ends_with("/"):
			continue
		var rel = f.substr(root.length() + 1) if root != "" else f
		if rel == "" or ".." in rel:
			continue
		# only what a mod may hold: its description, maps and content (no programs)
		if not (rel == "mod.json" or rel.begins_with("maps/") or rel.begins_with("content/") or rel.begins_with("sprites/")):
			continue
		var ext = rel.get_extension().to_lower()
		if not ext in ["json", "bin", "png", "txt"]:
			continue
		DirAccess.make_dir_recursive_absolute(dest.path_join(rel).get_base_dir())
		var fa = FileAccess.open(dest.path_join(rel), FileAccess.WRITE)
		if fa:
			fa.store_buffer(z.read_file(f))
			fa.close()
	z.close()
	var en = enabled_names()
	if not en.has(name):
		en.append(name)
	set_enabled(en)
	return "Mod %s added and switched on." % name

static func _safe(n: String) -> String:
	var out = ""
	for ch in n.strip_edges():
		out += ch if (ch.is_valid_identifier() or ch.is_valid_int() or ch in "-_ ") else "_"
	return out.strip_edges().replace(" ", "_").left(48) if out.strip_edges() != "" else "mod"

## your own edits as a mod package anybody can drop in their modpacks folder: modpacks_made/<name>.zip
## (only what differs from the game: your map changes and maps, and the content files you changed)
func export_pack(meta: Dictionary) -> String:
	var outdir = Assets.exe_dir().path_join("modpacks_made")
	DirAccess.make_dir_recursive_absolute(outdir)
	var path = outdir.path_join(_safe(str(meta.get("name", "mymod"))) + ".zip")
	var zp = ZIPPacker.new()
	if zp.open(path) != OK:
		return ""
	meta["game"] = "LoG2Coop"
	meta["made"] = Time.get_datetime_string_from_system()
	zp.start_file("mod.json"); zp.write_file(JSON.stringify(meta, "  ").to_utf8_buffer()); zp.close_file()
	var n = 0
	n += _zip_dir(zp, maps_dir(), "maps")
	var cdir = Assets.exe_dir().path_join("content")
	var dc = DirAccess.open(cdir)
	if dc:
		for f in dc.get_files():
			if not f.ends_with(".json"):
				continue
			var mine = FileAccess.get_file_as_string(cdir.path_join(f))
			var orig = FileAccess.get_file_as_string("res://content/" + f) if FileAccess.file_exists("res://content/" + f) else ""
			if mine.strip_edges() == orig.strip_edges():
				continue      # the game's own file, unchanged
			zp.start_file("content/" + f); zp.write_file(mine.to_utf8_buffer()); zp.close_file()
			n += 1
	# imported sprite sets (DEV TOOLS - SPRITES) go with it
	n += _zip_dir(zp, Assets.exe_dir().path_join("content/sprites"), "sprites")
	zp.close()
	return path

func _zip_dir(zp: ZIPPacker, dir: String, as_dir: String) -> int:
	var n = 0
	var d = DirAccess.open(dir)
	if d == null:
		return 0
	for f in d.get_files():
		var b = FileAccess.get_file_as_bytes(dir.path_join(f))
		zp.start_file(as_dir + "/" + f); zp.write_file(b); zp.close_file()
		n += 1
	for sub in d.get_directories():
		n += _zip_dir(zp, dir.path_join(sub), as_dir + "/" + sub)
	return n

func save_patch(key: String) -> bool:
	DirAccess.make_dir_recursive_absolute(maps_dir())
	var fa = FileAccess.open(maps_dir().path_join(file_key(key) + ".json"), FileAccess.WRITE)
	if fa == null:
		return false
	fa.store_string(JSON.stringify(patch(key)))
	fa.close()
	return true

## lay a map's changed tiles and walls over the game's (called when a map is read)
func apply_cells(key: String, a: Dictionary) -> void:
	if not a.has("land"):
		return
	var p = merged(key)
	var cells: Array = a["land"]["cells"]
	var walk: PackedByteArray = a["walk"]
	a["walk"] = PackedByteArray()      # (one copy of each array for all the changes, not one per tile)
	var tw: int = a["tw"]
	# the changes as (index, values) once, then each layer changed in place
	var idx = []
	var vals = []
	for k in p["cells"]:
		var xy = str(k).split(",")
		var x = int(xy[0]); var y = int(xy[1])
		if x < 0 or y < 0 or x >= tw or y >= int(a["th"]):
			continue
		idx.append(y * tw + x)
		vals.append(p["cells"][k])
	for l in 5:
		var L: PackedInt32Array = cells[l]
		cells[l] = PackedInt32Array()
		for j in idx.size():
			L[idx[j]] = int(vals[j][l])
		cells[l] = L
	for j in idx.size():
		walk[idx[j]] = int(vals[j][5]) & 1
	a["walk"] = walk
	# people added / taken away
	var ppl: Array = a.get("people", [])
	for d in p["people_del"]:
		var q = Vector2(float(d[0]), float(d[1]))
		ppl = ppl.filter(func(pp): return Vector2(float(pp["x"]), float(pp["y"])).distance_to(q) > 6.0)
	for pa in p["people_add"]:
		ppl.append(pa.duplicate())
	a["people"] = ppl

# ------------------------------------------------------------------ maps of your own
func custom_maps() -> Array:
	var out = []
	for dd in [custom_dir()] + pack_dirs().map(func(x): return x.path_join("maps/custom")):
		var d = DirAccess.open(dd)
		if d == null:
			continue
		for f in d.get_files():
			if f.ends_with(".json") and not out.has(f.get_basename()):
				out.append(f.get_basename())
	out.sort()
	return out

## a map of your own's file: yours, or the (last) pack that has it
func custom_file(name: String, ext: String) -> String:
	var mine = custom_dir().path_join(name + ext)
	if FileAccess.file_exists(mine):
		return mine
	var dirs = pack_dirs()
	dirs.reverse()
	for d in dirs:
		var f = d.path_join("maps/custom").path_join(name + ext)
		if FileAccess.file_exists(f):
			return f
	return mine

func custom_meta(name: String) -> Dictionary:
	var f = custom_file(name, ".json")
	if not FileAccess.file_exists(f):
		return {}
	var t = read_json(f)
	return t if t is Dictionary else {}

## a new map: tw x th tiles, every cell the given one (5 layers) and walkable
func create_custom(name: String, tw: int, th: int, cell: Array) -> bool:
	DirAccess.make_dir_recursive_absolute(custom_dir())
	var n = tw * th
	var b = PackedByteArray()
	b.resize(8 + n * 21)
	b[0] = 76; b[1] = 75; b[2] = 82; b[3] = 50      # "LKR2"
	b.encode_u16(4, tw); b.encode_u16(6, th)
	for l in 5:
		var o = 8 + l * n * 4
		var v = int(cell[l]) if l < cell.size() else 0
		if v != 0:
			for i in n:
				b.encode_u32(o + i * 4, v)
	var wo = 8 + 20 * n
	for i in n:
		b[wo + i] = 1
	var fa = FileAccess.open(custom_dir().path_join(name + ".bin"), FileAccess.WRITE)
	if fa == null:
		return false
	fa.store_buffer(b)
	fa.close()
	var meta = {"name": name.to_upper(), "tw": tw, "th": th, "arrival": [tw * 4, th * 4], "song": "cave"}
	var fm = FileAccess.open(custom_dir().path_join(name + ".json"), FileAccess.WRITE)
	fm.store_string(JSON.stringify(meta))
	fm.close()
	return true

## write a custom map's tiles and walls back to its file (the editor paints the area in memory)
func save_custom(name: String, a: Dictionary) -> bool:
	var tw: int = a["tw"]; var th: int = a["th"]
	var n = tw * th
	var b = PackedByteArray()
	b.resize(8)
	b[0] = 76; b[1] = 75; b[2] = 82; b[3] = 50
	b.encode_u16(4, tw); b.encode_u16(6, th)
	for l in 5:
		var L: PackedInt32Array = a["land"]["cells"][l]
		b.append_array(L.to_byte_array())
	var w: PackedByteArray = a["walk"]
	b.append_array(w)
	DirAccess.make_dir_recursive_absolute(custom_dir())
	if not FileAccess.file_exists(custom_dir().path_join(name + ".json")):
		var mf = FileAccess.open(custom_dir().path_join(name + ".json"), FileAccess.WRITE)
		if mf:
			mf.store_string(JSON.stringify(custom_meta(name)))
			mf.close()
	var fa = FileAccess.open(custom_dir().path_join(name + ".bin"), FileAccess.WRITE)
	if fa == null:
		return false
	fa.store_buffer(b)
	fa.close()
	return true

## a map of another game (read-only: copy from it, or make it a map of your own)
func lib_area(key: String) -> Dictionary:
	var parts = key.split("/")
	if parts.size() < 3:
		return {}
	var data = FileAccess.get_file_as_bytes(Assets.base_dir.path_join("lib/%s/maps/%s.bin" % [parts[1], parts[2]]))
	if data.size() < 8:
		return {}
	var tw = data.decode_u16(4)
	var th = data.decode_u16(6)
	var nm = "%s %s" % [Assets.LIB_TITLES.get(parts[1], parts[1].to_upper()), parts[2].replace("_", "-")]
	return _lkr2_area(key, data, {"name": nm, "arrival": [tw * 4, th * 4]}, "")

## a library map copied whole into a map of your own
func custom_from_lib(name: String, lib_key: String) -> bool:
	var parts = lib_key.split("/")
	var src = Assets.base_dir.path_join("lib/%s/maps/%s.bin" % [parts[1], parts[2]])
	var data = FileAccess.get_file_as_bytes(src)
	if data.size() < 8:
		return false
	DirAccess.make_dir_recursive_absolute(custom_dir())
	var tw = data.decode_u16(4)
	var th = data.decode_u16(6)
	# the game's walk bits: 1 = you may walk (as this game's maps)
	var n = tw * th
	for i in n:
		data[8 + 20 * n + i] = data[8 + 20 * n + i] & 1
	var fa = FileAccess.open(custom_dir().path_join(name + ".bin"), FileAccess.WRITE)
	if fa == null:
		return false
	fa.store_buffer(data)
	fa.close()
	var meta = {"name": name.to_upper(), "tw": tw, "th": th, "arrival": [tw * 4, th * 4], "song": "cave", "from": lib_key}
	var fm = FileAccess.open(custom_dir().path_join(name + ".json"), FileAccess.WRITE)
	fm.store_string(JSON.stringify(meta))
	fm.close()
	return true

func custom_area(name: String) -> Dictionary:
	var meta = custom_meta(name)
	var data = FileAccess.get_file_as_bytes(custom_file(name, ".bin"))
	if meta.is_empty() or data.size() < 8:
		return {}
	var a = _lkr2_area("custom/" + name, data, meta, name)
	apply_cells("custom/" + name, a)
	return a

func _lkr2_area(key: String, data: PackedByteArray, meta: Dictionary, name: String) -> Dictionary:
	var tw = data.decode_u16(4)
	var th = data.decode_u16(6)
	var n = tw * th
	var cells = []
	var o = 8
	for k in 5:
		cells.append(data.slice(o, o + n * 4).to_int32_array())
		o += n * 4
	var walk: PackedByteArray = data.slice(o, o + n)
	var km = Assets.json(Assets.base_dir.path_join("kit/maps.json"))
	var bd = km["backdrop"] if km != null else [0, 0, 0]
	var info = {"name": str(meta.get("name", name)), "maps": [], "exits": [], "enemies": [], "arrival": meta.get("arrival", [tw * 4, th * 4])}
	var a = {"key": key, "meta": {"tw": tw, "th": th, "pri": [0, 0, 0, 0], "name": info["name"], "exits": [], "arrival": info["arrival"], "backdrop": bd, "objects": []},
		"dir": "", "tw": tw, "th": th, "w": tw * 8, "h": th * 8, "layers": [null, null, null, null], "walk": walk, "anim": [], "anim_tex": null,
		"land": {"zone": -1, "region": 0, "cells": cells, "info": info, "parts": [[Rect2(0, 0, tw * 8, th * 8), info["name"], -1]]}, "people": []}
	if name != "":
		a["custom"] = name
	else:
		a["library"] = true
	for i in walk.size():
		walk[i] = walk[i] & 1
	a["walk"] = walk
	return a

# ------------------------------------------------------------------ the world: foes, doors and maps of your own put in
## called once the planet is built: every map's own changes (foes, doors) and every map of your own
func apply_to_planet(pl) -> void:
	# maps of your own become places of the world (reached by the doors your team puts in)
	for nm in custom_maps():
		var meta = custom_meta(nm)
		pl.nodes.append({"key": "custom/" + nm, "name": str(meta.get("name", nm)).to_upper(), "kind": 1, "chapter": 0, "gx": 0, "gy": 0, "hidden": true,
			"exits": [], "spec": {"fixed": [], "count": 0, "level": 1, "elite": 5, "seed": 7}})
	var index = {}
	for i in pl.nodes.size():
		index[str(pl.nodes[i]["key"])] = i
	for i in pl.nodes.size():
		var nd: Dictionary = pl.nodes[i]
		var key = str(nd["key"])
		var p = merged(key)
		var spec: Dictionary = nd["spec"]
		var fixed: Array = spec.get("fixed", [])
		for d in p["enemies_del"]:
			var q = Vector2(float(d[0]), float(d[1]))
			fixed = fixed.filter(func(f): return Vector2(float(f["x"]), float(f["y"])).distance_to(q) > 8.0)
		for e in p["enemies_add"]:
			var t = int(e[0])
			var st = int(e[1])
			if st < 0:
				st = Rules.kind_to_type_set(t)[1]
			var lv = int(e[4]) if e.size() > 4 else int(Assets.data["enemies"][clampi(t, 0, 127)]["lvl"])
			fixed.append({"type": t, "set": st, "x": float(e[2]), "y": float(e[3]), "lv": lv})
		# foe zones (DEV TOOLS - ZONE): their foes spread over the box, coming back after their own time
		var zr = RandomNumberGenerator.new()
		for z in p["zones"]:
			var r: Array = z["rect"]
			zr.seed = hash(str(r)) + 17
			var kinds: Array = z.get("kinds", [8])
			for n in int(z.get("count", 4)):
				var t = int(kinds[zr.randi_range(0, maxi(0, kinds.size() - 1))]) if not kinds.is_empty() else 8
				var ts = Rules.kind_to_type_set(t)
				var lv = int(z.get("level", 0))
				if lv <= 0:
					lv = int(Assets.data["enemies"][clampi(t, 0, 127)]["lvl"])
				fixed.append({"type": t, "set": ts[1], "x": zr.randf_range(float(r[0]) + 6, float(r[2]) - 6), "y": zr.randf_range(float(r[1]) + 8, float(r[3]) - 4),
					"lv": lv, "respawn_s": int(z.get("respawn", 30)), "zone": true})
		spec["fixed"] = fixed
		spec["count"] = fixed.size()
		spec["triggers"] = p["triggers"]
		spec["moods"] = p["moods"]
		var its: Array = p["items"]
		for d in p["items_del"]:
			var q = Vector2(float(d[0]), float(d[1]))
			its = its.filter(func(it): return Vector2(float(it["x"]), float(it["y"])).distance_to(q) > 4.0)
		spec["items"] = its
		var exits: Array = nd["exits"]
		for d in p["doors_del"]:
			var q = Vector2(float(d[0]), float(d[1]))
			exits = exits.filter(func(ex): return Vector2((float(ex["rect"][0]) + float(ex["rect"][2])) / 2.0, (float(ex["rect"][1]) + float(ex["rect"][3])) / 2.0).distance_to(q) > 6.0)
		for d in p["doors_add"]:
			var to_key = str(d.get("to", key))
			if to_key == "":
				to_key = key
			if not index.has(to_key):
				continue
			var ex = {"rect": d["rect"], "to": int(index[to_key]), "arrive": d["arrive"], "role": exits.size(), "to_role": 0}
			for nk in ["need_item", "need_flag", "need_level", "locked_msg", "take_item"]:
				if d.has(nk) and str(d[nk]) != "" and str(d[nk]) != "0":
					ex[nk] = d[nk]
			exits.append(ex)
		nd["exits"] = exits

# ------------------------------------------------------------------ characters of your own (content/heroes.json)
## heroes.json: {"heroes": [{"id": "BARDOCK", "name": "BARDOCK", "base": "GOKU", "set": 60, "stats": {"maxhp": 90, ...},
##   "inherit": true}]}  base: the hero it plays like (moves, forms); an entry with the id of a game hero changes that hero
var heroes = []

func load_heroes() -> void:
	heroes = []
	var paths = content_paths("heroes")
	if not FileAccess.file_exists(paths[-1]) and FileAccess.file_exists("res://content/heroes.json"):
		paths.append("res://content/heroes.json")
	paths.push_front(Assets.builtin_dir().path_join("heroes.json"))
	for f in paths:
		if not FileAccess.file_exists(f):
			continue
		var t = read_json(f)
		if t is Dictionary and t.get("heroes") is Array:
			for h in t["heroes"]:
				heroes = heroes.filter(func(x): return str(x.get("id", "")) != str(h.get("id", "")))
				heroes.append(h)

func hero_entry(name: String) -> Dictionary:
	for h in heroes:
		if str(h.get("id", "")) == name:
			return h
	return {}

# ------------------------------------------------------------------ HISTORY: a copy of your edits at every save
## backups/<date time>.zip: the mods and content folders as they were (the newest 40 are kept)
func backups_dir() -> String:
	return Assets.exe_dir().path_join("backups")

var _last_backup_ms = -1000000
func backup(force: bool = false) -> String:
	var now = Time.get_ticks_msec()
	if not force and now - _last_backup_ms < 120000:
		return ""        # (one every two minutes is plenty)
	_last_backup_ms = now
	DirAccess.make_dir_recursive_absolute(backups_dir())
	var nm = Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var path = backups_dir().path_join(nm + ".zip")
	var n = 2
	while FileAccess.file_exists(path):          # (two in the same second)
		path = backups_dir().path_join("%s-%d.zip" % [nm, n])
		n += 1
	nm = path.get_file().get_basename()
	var zp = ZIPPacker.new()
	if zp.open(path) != OK:
		return ""
	_zip_dir(zp, dir(), "mods")
	_zip_dir(zp, Assets.exe_dir().path_join("content"), "content")
	zp.close()
	var all = list_backups()
	while all.size() > 40:
		DirAccess.remove_absolute(backups_dir().path_join(all.pop_back() + ".zip"))
	return nm

## newest first
func list_backups() -> Array:
	var out = []
	var d = DirAccess.open(backups_dir())
	if d == null:
		return out
	for f in d.get_files():
		if f.ends_with(".zip"):
			out.append(f.get_basename())
	out.sort()
	out.reverse()
	return out

## everything back as it was then (what is there now is backed up first)
func restore(nm: String) -> String:
	var path = backups_dir().path_join(nm + ".zip")
	var z = ZIPReader.new()
	if z.open(path) != OK:
		return "Could not open that backup."
	backup(true)
	_wipe(dir())
	_wipe(Assets.exe_dir().path_join("content"), true)
	for f in z.get_files():
		if f.ends_with("/") or ".." in f or not (f.begins_with("mods/") or f.begins_with("content/")):
			continue
		var dest = Assets.exe_dir().path_join(f)
		DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
		var fa = FileAccess.open(dest, FileAccess.WRITE)
		if fa:
			fa.store_buffer(z.read_file(f))
			fa.close()
	z.close()
	reload()
	Assets.reload_sets()
	return "Back to %s (what you had just now is a backup too)." % nm

func _wipe(d: String, keep_readme: bool = false) -> void:
	var da = DirAccess.open(d)
	if da == null:
		return
	for f in da.get_files():
		if keep_readme and f == "README.txt":
			continue
		da.remove(f)
	for sub in da.get_directories():
		_wipe(d.path_join(sub))
		da.remove(sub)
