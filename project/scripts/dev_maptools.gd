extends RefCounted
## DEV TOOLS map helpers: the SMART brush (edges that join up, learned from the game's own maps), object STAMPS
## (whole houses, trees, fences - cut from any map, or saved by your team), LINE / RECT, and the little map.

# ------------------------------------------------------------------ SMART brush
## what the game's maps show around a kind of ground: every cell seen near its edges and which cells stand next
## to which (right / below), learned from this map, EARTH and (for another game's tiles) that game's maps
var _libs = {}

static func ckey(v: Array) -> String:
	return "%d,%d,%d,%d,%d,%d" % [int(v[0]), int(v[1]), int(v[2]), int(v[3]), int(v[4]), int(v[5]) & 1]

func learn(dev, inside: Array) -> Dictionary:
	var k = ckey(inside)
	if _libs.has(k):
		return _libs[k]
	var lib = {"cells": [], "index": {}, "freq": [], "right": {}, "down": {}, "left": {}, "up": {},
		"g_right": {}, "g_down": {}, "g_left": {}, "g_up": {}, "by_ground": {}}
	var sources = [dev.area]
	var e = Assets.area("land/0/0")
	if not e.is_empty() and e != dev.area:
		sources.append(e)
	var v0 = int(inside[0])
	if v0 & (1 << 20):
		var g = ""
		for gg in Assets.LIB_GAMES:
			if int(Assets.LIB_GAMES[gg]) == ((v0 >> 21) & 7):
				g = gg
		for m in Assets.library_maps():
			if str(m["key"]).begins_with("lib/%s/" % g):
				var a = Assets.area(str(m["key"]))
				if not a.is_empty():
					sources.append(a)
	var budget = 6000
	for a in sources:
		if budget <= 0:
			break
		budget -= _learn_from(a, v0, lib, mini(budget, 3000))
	_libs[k] = lib
	return lib

func _id(lib: Dictionary, v: Array) -> int:
	var k = ckey(v)
	if lib["index"].has(k):
		var i = lib["index"][k]
		lib["freq"][i] += 1
		return i
	var i = lib["cells"].size()
	lib["cells"].append(v.duplicate())
	lib["index"][k] = i
	lib["freq"].append(1)
	var g = int(v[0])
	if not lib["by_ground"].has(g):
		lib["by_ground"][g] = []
	lib["by_ground"][g].append(i)
	return i

static func _cell(a: Dictionary, i: int) -> Array:
	var c: Array = a["land"]["cells"]
	return [c[0][i], c[1][i], c[2][i], c[3][i], c[4][i], int(a["walk"][i]) & 1]

## around up to n edge cells of the ground v0: the 5 x 5 cells, and their neighbours
func _learn_from(a: Dictionary, v0: int, lib: Dictionary, n: int) -> int:
	if not a.has("land"):
		return 0
	var L0: PackedInt32Array = a["land"]["cells"][0]
	var tw: int = a["tw"]; var th: int = a["th"]
	var found = 0
	var i = L0.find(v0)
	var hits = 0
	while i >= 0 and found < n:
		hits += 1
		var x = i % tw; var y = i / tw
		if x > 2 and y > 2 and x < tw - 3 and y < th - 3:
			var edge = L0[i - 1] != v0 or L0[i + 1] != v0 or L0[i - tw] != v0 or L0[i + tw] != v0
			if edge and hits % 2 == 0:
				found += 1
				var ids = {}
				for dy in range(-2, 3):
					for dx in range(-2, 3):
						var j = (y + dy) * tw + x + dx
						ids[Vector2i(dx, dy)] = _id(lib, _cell(a, j))
				for dy in range(-2, 3):
					for dx in range(-2, 3):
						var me = ids[Vector2i(dx, dy)]
						var gme = int(lib["cells"][me][0])
						if dx < 2:
							var o = ids[Vector2i(dx + 1, dy)]
							_pair(lib, me, o, "right", "left")
							_pair(lib, gme, int(lib["cells"][o][0]), "g_right", "g_left")
						if dy < 2:
							var o = ids[Vector2i(dx, dy + 1)]
							_pair(lib, me, o, "down", "up")
							_pair(lib, gme, int(lib["cells"][o][0]), "g_down", "g_up")
		i = L0.find(v0, i + 1)
	return found

static func _pair(lib: Dictionary, a: int, b: int, d: String, back: String) -> void:
	var m: Dictionary = lib[d]
	if not m.has(a):
		m[a] = {}
	m[a][b] = m[a].get(b, 0) + 1
	var n: Dictionary = lib[back]
	if not n.has(b):
		n[b] = {}
	n[b][a] = n[b].get(a, 0) + 1

const DIRS = [[Vector2i(1, 0), "right"], [Vector2i(-1, 0), "left"], [Vector2i(0, 1), "down"], [Vector2i(0, -1), "up"]]

## the painted cells become the ground; their edges (one cell in, one cell out) are chosen so every cell
## stands next to cells it stands next to somewhere in the game's maps
func smart_fill(dev, mask: Dictionary, inside: Array) -> int:
	var lib = learn(dev, inside)
	if lib["cells"].is_empty():
		for c in mask:
			dev.put(c.x, c.y, inside)
		return 0
	var inner = {}
	var outer = {}
	for c in mask:
		for d in DIRS:
			var n: Vector2i = c + d[0]
			if not mask.has(n):
				inner[c] = true
				if dev._inside(n.x, n.y):
					outer[n] = true
	var cur = {}      # cell -> library id or -1 (unknown)
	var vals = {}     # cell -> values now
	var get_val = func(p: Vector2i) -> Array:
		if vals.has(p):
			return vals[p]
		if mask.has(p):
			return inside
		var i = p.y * int(dev.area["tw"]) + p.x
		return dev.stroke[i][1] if dev.stroke.has(i) else dev.cell_at(p.x, p.y)
	for c in mask:
		vals[c] = inside
	var free = []
	for c in inner:
		free.append(c)
	for c in outer:
		free.append(c)
	var lid = func(v: Array) -> int:
		return lib["index"].get(ckey(v), -1)
	# two passes: each free cell takes the cell that fits best with its four neighbours
	for sweep in 2:
		free.sort_custom(func(a, b): return _fixed_count(a, mask, inner, outer) > _fixed_count(b, mask, inner, outer))
		for p in free:
			var cands = {}
			var nbr = []
			for d in DIRS:
				var q: Vector2i = p + d[0]
				if not dev._inside(q.x, q.y):
					continue
				var qv = get_val.call(q)
				var qi = lid.call(qv)
				var qg = int(qv[0])
				nbr.append([d[1], qi, qg])
				var back = {"right": "left", "left": "right", "down": "up", "up": "down"}[d[1]]
				if qi >= 0:
					# cells seen on this side of the neighbour
					for c in lib[back].get(qi, {}):
						cands[c] = true
				else:
					# a neighbour never seen whole: the cells whose ground was seen next to its ground
					var n = 0
					for g in lib["g_" + back].get(qg, {}):
						for c in lib["by_ground"].get(g, []):
							cands[c] = true
							n += 1
							if n > 60:
								break
			var own = lid.call(get_val.call(p))
			if own >= 0:
				cands[own] = true
			if inner.has(p):
				var ii = lid.call(inside)
				if ii >= 0:
					cands[ii] = true
			var best = -1
			var bs = -1e9
			for c in cands:
				var s = 0.0
				var cg = int(lib["cells"][c][0])
				for nb in nbr:
					var seen = int(lib[nb[0]].get(c, {}).get(nb[1], 0)) if nb[1] >= 0 else 0
					if seen > 0:
						s += 3.0 + minf(2.0, seen * 0.2)
						continue
					var gseen = int(lib["g_" + nb[0]].get(cg, {}).get(nb[2], 0))
					if gseen > 0:
						s += 1.5 + minf(1.0, gseen * 0.05)
					elif lib["by_ground"].has(nb[2]):
						s -= 4.0
				s += minf(1.0, lib["freq"][c] * 0.01)
				if c == own:
					s += 0.5
				if s > bs:
					bs = s; best = c
			if best >= 0:
				vals[p] = lib["cells"][best]
	var n = 0
	for p in vals:
		dev.put(p.x, p.y, vals[p])
		n += 1
	return n

static func _fixed_count(p: Vector2i, mask: Dictionary, inner: Dictionary, outer: Dictionary) -> int:
	var n = 0
	for d in DIRS:
		var q: Vector2i = p + d[0]
		if not inner.has(q) and not outer.has(q):
			n += 1
	return n

# ------------------------------------------------------------------ LINE and RECT
static func line_cells(a: Vector2i, b: Vector2i) -> Array:
	var out = []
	var n = maxi(absi(b.x - a.x), absi(b.y - a.y))
	for i in n + 1:
		var t = 0.0 if n == 0 else float(i) / n
		out.append(Vector2i(roundi(lerpf(a.x, b.x, t)), roundi(lerpf(a.y, b.y, t))))
	return out

static func rect_cells(a: Vector2i, b: Vector2i, filled: bool) -> Array:
	var out = []
	for y in range(mini(a.y, b.y), maxi(a.y, b.y) + 1):
		for x in range(mini(a.x, b.x), maxi(a.x, b.x) + 1):
			if filled or x == a.x or x == b.x or y == a.y or y == b.y:
				out.append(Vector2i(x, y))
	return out

# ------------------------------------------------------------------ STAMPS
## content/stamps/<name>.json: {"name", "w", "h", "cells": [[6 values]...], "mask": [0/1...]} - a whole thing
func stamps_dir() -> String:
	return Assets.exe_dir().path_join("content/stamps")

func list_stamps() -> Array:
	var out = []
	var dirs = [Assets.builtin_dir().path_join("stamps"), stamps_dir()]      # the port's own (SAVE POINT) first
	for d in Mods.pack_dirs():
		dirs.append(d.path_join("content/stamps"))
	for dd in dirs:
		var d = DirAccess.open(dd)
		if d == null:
			continue
		for f in d.get_files():
			if f.ends_with(".json"):
				var t = Mods.read_json(dd.path_join(f))
				if t is Dictionary and t.has("cells"):
					t["file"] = dd.path_join(f)
					out.append(t)
	out.sort_custom(func(a, b): return str(a.get("name", "")) < str(b.get("name", "")))
	return out

func save_stamp(name: String, clip: Dictionary) -> String:
	DirAccess.make_dir_recursive_absolute(stamps_dir())
	var st = clip.duplicate(true)
	st["name"] = name
	if not st.has("mask"):
		st["mask"] = _object_mask(st)
	var f = stamps_dir().path_join(Mods._safe(name) + ".json")
	var fa = FileAccess.open(f, FileAccess.WRITE)
	if fa == null:
		return ""
	fa.store_string(JSON.stringify(st))
	fa.close()
	return f

## which cells of a box belong to the thing (anything over the ground, or a wall) - the rest is left alone
static func _object_mask(st: Dictionary) -> Array:
	var m = []
	for v in st["cells"]:
		m.append(1 if (int(v[1]) != 0 or int(v[2]) != 0 or int(v[3]) != 0 or int(v[4]) != 0 or (int(v[5]) & 1) == 0) else 0)
	return m

## the things in a box of the map: each group of touching cells with something over the ground, as a stamp
func find_objects(dev, r: Rect2i) -> Array:
	var tw: int = dev.area["tw"]
	var seen = {}
	var out = []
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var p = Vector2i(x, y)
			if seen.has(p) or not _is_obj(dev.cell_at(x, y)):
				continue
			var stack = [p]; var comp = []
			seen[p] = true
			while not stack.is_empty() and comp.size() < 2000:
				var q: Vector2i = stack.pop_back()
				comp.append(q)
				for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var n: Vector2i = q + d
					if seen.has(n) or not r.has_point(n) or not _is_obj(dev.cell_at(n.x, n.y)):
						continue
					seen[n] = true
					stack.append(n)
			if comp.size() < 4:
				continue
			var x0 = 99999; var y0 = 99999; var x1 = -1; var y1 = -1
			for q in comp:
				x0 = mini(x0, q.x); y0 = mini(y0, q.y); x1 = maxi(x1, q.x); y1 = maxi(y1, q.y)
			var inset = {}
			for q in comp:
				inset[q] = true
			var cells = []; var mask = []
			for yy in range(y0, y1 + 1):
				for xx in range(x0, x1 + 1):
					cells.append(dev.cell_at(xx, yy))
					mask.append(1 if inset.has(Vector2i(xx, yy)) else 0)
			out.append({"name": "THING %d,%d" % [x0, y0], "w": x1 - x0 + 1, "h": y1 - y0 + 1, "cells": cells, "mask": mask})
	return out

static func _is_obj(v: Array) -> bool:
	return int(v[1]) != 0 or int(v[2]) != 0 or int(v[3]) != 0 or int(v[4]) != 0

## a stamp laid down with its top-left at c: only its own cells (the ground around stays)
static func place_stamp(dev, st: Dictionary, c: Vector2i) -> void:
	dev._lay(c, int(st["w"]), st["cells"], st.get("mask", []), bool(st.get("keep_ground", false)))

## a small picture of a stamp (its top-most tiles)
static func stamp_image(st: Dictionary, cell_px: int = 4) -> Image:
	var w: int = st["w"]; var h: int = st["h"]
	var img = Image.create_empty(maxi(1, w * cell_px), maxi(1, h * cell_px), false, Image.FORMAT_RGBA8)
	var cells: Array = st["cells"]
	for j in cells.size():
		var col = cell_color(cells[j])
		img.fill_rect(Rect2i((j % w) * cell_px, (j / w) * cell_px, cell_px, cell_px), col)
	return img

# ------------------------------------------------------------------ the little map
static var _tile_col = {}
static var _src_img = {}
static func tile_color(cell: int) -> Color:
	if cell == 0:
		return Color(0, 0, 0, 0)
	var id = cell & 0x1FFFFF & ~(3 << 16)
	if _tile_col.has(id):
		return _tile_col[id]
	var col = Color(0.5, 0.5, 0.5)
	var r = Assets.kit_cell(cell)
	if not r.is_empty():
		if not _src_img.has(r[2]):
			var src = Assets.tileset().get_source(r[2]) as TileSetAtlasSource
			_src_img[r[2]] = src.texture.get_image() if src and src.texture else null
		var img: Image = _src_img[r[2]]
		if img != null:
			var at: Vector2i = r[0]
			var acc = Color(0, 0, 0, 0); var n = 0
			for yy in range(1, 8, 3):
				for xx in range(1, 8, 3):
					var c = img.get_pixel(at.x * 8 + xx, at.y * 8 + yy)
					if c.a > 0.5:
						acc += c; n += 1
			if n > 0:
				col = acc / n
				col.a = 1.0
	_tile_col[id] = col
	return col

## the minimap's colour of a cell as the importer draws it: a wall at half brightness (walkable ground shows lighter
## - painting a changed cell without this lost the difference, e.g. a path made walkable under trees)
static func mini_color(v: Array, walk: int) -> Color:
	var c = cell_color(v)
	if not (walk & 1):
		c = Color(c.r * 0.5, c.g * 0.5, c.b * 0.5)
	c.a = 1.0
	return c

static func cell_color(v: Array) -> Color:
	for l in [4, 3, 2, 1, 0]:
		if int(v[l]) != 0 and not (int(v[l]) & (1 << 18)):
			var c = tile_color(int(v[l]))
			if c.a > 0:
				return c
	return Color(0, 0, 0)

## one pixel per `step` tiles (EARTH has its own picture from the import)
static func mini_image(a: Dictionary, max_px: int = 220) -> Image:
	if str(a.get("key", "")) == "land/0/0":
		var p = Assets.base_dir.path_join("kit/lands/0/0_mini.png")
		if FileAccess.file_exists(p):
			var im = Image.load_from_file(p)
			im.convert(Image.FORMAT_RGBA8)
			var ch: Dictionary = Mods.merged("land/0/0")["cells"]      # the changes drawn in (the picture is the import's)
			for k in ch:
				var xy = str(k).split(",")
				var x = int(xy[0]); var y = int(xy[1])
				if x >= 0 and y >= 0 and x < im.get_width() and y < im.get_height():
					var cv: Array = ch[k]
					im.set_pixel(x, y, mini_color(cv, int(cv[5]) if cv.size() > 5 else 1))
			return im
	var tw: int = a["tw"]; var th: int = a["th"]
	var step = maxi(1, int(ceil(maxf(tw, th) / float(max_px))))
	var w = maxi(1, tw / step); var h = maxi(1, th / step)
	var img = Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	var cells: Array = a["land"]["cells"]
	for y in h:
		for x in w:
			var i = (y * step) * tw + x * step
			img.set_pixel(x, y, cell_color([cells[0][i], cells[1][i], cells[2][i], cells[3][i], cells[4][i], 1]))
	return img
