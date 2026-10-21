class_name Planet
extends RefCounted
## The world the players walk: a hand-made adventure (Gatorra, Dunara) or a random planet made of
## the game's own areas. nodes[i] = {key, name, kind, chapter, exits:[{rect,to,to_exit}], spec, gx, gy}

var title = ""
var lore = ""
var nodes = []
var start = 0
var lair = -1
var seed = 1

func node_of(key: String) -> int:
	for i in nodes.size():
		if nodes[i]["key"] == key:
			return i
	return -1

static func _side(rect: Array, w: int, h: int) -> int:
	if int(rect[0]) <= 12: return 0
	if int(rect[2]) >= w - 12: return 1
	if int(rect[1]) <= 12: return 2
	if int(rect[3]) >= h - 12: return 3
	var cx = (int(rect[0]) + int(rect[2])) / 2.0
	var cy = (int(rect[1]) + int(rect[3])) / 2.0
	var d = [cx, w - cx, cy, h - cy]
	var best = 0
	for i in 4:
		if d[i] < d[best]:
			best = i
	return best

## inside the map, a little way in from an exit (where you arrive through it)
static func arrival_for(a: Dictionary, rect: Array) -> Vector2:
	var w: int = a["w"]
	var h: int = a["h"]
	var cx = (int(rect[0]) + int(rect[2])) / 2.0
	var cy = (int(rect[1]) + int(rect[3])) / 2.0
	var side = _side(rect, w, h)
	var p = Vector2(cx, cy)
	var step = Vector2([1, -1, 0, 0][side], [0, 0, 1, -1][side])
	p += step * (abs(rect[2] - rect[0]) / 2.0 + 14.0 if side < 2 else abs(rect[3] - rect[1]) / 2.0 + 18.0)
	for i in 40:
		if Assets.walkable(a, p.x, p.y) and Assets.walkable(a, p.x - 5, p.y) and Assets.walkable(a, p.x + 4, p.y):
			return p
		p += step * 4.0
	return Vector2(cx, cy)

func build_adventure(name: String, s: int) -> bool:
	seed = s
	var route = Assets.json(Assets.base_dir.path_join("floors/%s/route.json" % name))
	if route == null:
		return false
	title = "PLANET " + str(route["planet"])
	lore = str(route["lore"])
	nodes.clear()
	var rn: Array = route["nodes"]
	for i in rn.size():
		var n: Dictionary = rn[i]
		var key = "floors/%s/%d_%d" % [name, int(n["zone"]), int(n["area"])]
		var a = Assets.area(key)
		var kind = int(n["kind"])
		var chapter = int(n["chapter"])
		var lv = 1 + chapter * 4 + (1 if i % 2 == 1 else 0) + (2 if kind >= 3 else 0)
		var spec = {"kinds": n["kinds"], "count": (8 if kind == 0 else 6), "level": lv, "elite": int(n["elite"]), "look": int(n["look"]), "seed": s * 31 + i}
		if kind == 2:
			spec["count"] = 3
			spec["boss_kind"] = int(route["boss_kind"])
			spec["boss_name"] = str(route["boss_name"])
			spec["level"] = 14
			lair = i
		nodes.append({"key": key, "name": str(n["name"]), "kind": kind, "chapter": chapter, "gx": int(n["gx"]), "gy": int(n["gy"]),
			"to": n["to"], "to_role": n["to_role"], "dir": n["dir"], "spec": spec, "exits": []})
	# the ways: role r of node i (its side dir[r]) -> node to[r], arriving at that node's way to_role[r]
	for i in nodes.size():
		var n: Dictionary = nodes[i]
		var a = Assets.area(n["key"])
		if a.is_empty():
			continue
		var rects: Array = a["meta"].get("exits", [])
		var used = {}
		for r in 3:
			var t = int(n["to"][r])
			if t < 0:
				continue
			var side = int(n["dir"][r])
			var pick = -1
			for k in rects.size():
				if used.has(k):
					continue
				if side < 0 or _side(rects[k]["rect"], a["w"], a["h"]) == side:
					pick = k
					break
			if pick < 0:
				for k in rects.size():
					if not used.has(k):
						pick = k
						break
			if pick < 0:
				continue
			used[pick] = true
			n["exits"].append({"rect": rects[pick]["rect"], "to": t, "role": r, "to_role": int(n["to_role"][r])})
	return true

## where you arrive in node t when you come through its way with role `role`
func arrival(t: int, role: int) -> Vector2:
	var a = Assets.area(nodes[t]["key"])
	if str(nodes[t]["key"]).begins_with("land/"):
		var arr0 = a["meta"].get("arrival", [a["w"] / 2, a["h"] / 2])
		var p0 = Vector2(arr0[0], arr0[1])
		for r in range(0, 400, 8):
			for k in 16:
				var q = p0 + Vector2(cos(k * PI / 8.0), sin(k * PI / 8.0)) * r
				if Assets.walkable(a, q.x, q.y) and Assets.walkable(a, q.x - 5, q.y) and Assets.walkable(a, q.x + 4, q.y):
					return q
		return p0
	for ex in nodes[t]["exits"]:
		if int(ex["role"]) == role:
			return arrival_for(a, ex["rect"])
	var arr = a["meta"].get("arrival", [a["w"] / 2, a["h"] / 2])
	return Vector2(arr[0], arr[1])

func start_point() -> Vector2:
	if str(nodes[start]["key"]).begins_with("land/"):
		return arrival(start, 0)
	var a = Assets.area(nodes[start]["key"])
	var arr = a["meta"].get("arrival", [a["w"] / 2, a["h"] / 2])
	var p = Vector2(arr[0], arr[1])
	if not Assets.walkable(a, p.x, p.y):
		for r in range(0, 300, 8):
			for k in 16:
				var q = p + Vector2(cos(k * PI / 8.0), sin(k * PI / 8.0)) * r
				if Assets.walkable(a, q.x, q.y) and Assets.walkable(a, q.x - 5, q.y) and Assets.walkable(a, q.x + 4, q.y):
					return q
	return p

## a random planet: one land (zone) of the game, its own areas joined into a road with side places
func build_random(s: int) -> void:
	seed = s
	var r = RandomNumberGenerator.new()
	r.seed = s
	var zones = [2, 3, 4, 6, 7, 8, 10, 12, 13]
	var d = DirAccess.open(Assets.base_dir.path_join("maps"))
	if d == null:
		return
	var dirs = d.get_directories()
	# the seed's land first; a land with too few fit maps (some have none: an empty planet, a grey screen) gives
	# way to the next, and if none has enough, maps from every land together
	var order = zones.duplicate()
	for i in range(order.size() - 1, 0, -1):
		var j = r.randi_range(0, i)
		var tmp = order[i]; order[i] = order[j]; order[j] = tmp
	var pool = []
	for zone in order + [-1]:
		pool = []
		for f in dirs:
			var parts = f.split("_")
			if parts.size() != 2 or (zone >= 0 and int(parts[0]) != zone) or (zone < 0 and not zones.has(int(parts[0]))):
				continue
			var a = Assets.area("maps/" + f)
			if a.is_empty() or a["w"] < 320 or a["h"] < 240:
				continue
			var ex: Array = a["meta"].get("exits", [])
			var en = 0
			for o in a["meta"].get("objects", []):
				if o["kind"] == "enemy":
					en += 1
			if ex.size() >= 2 and en >= 2:
				pool.append(f)
		if pool.size() >= 3:
			break
	pool.sort()
	for i in range(pool.size() - 1, 0, -1):
		var j = r.randi_range(0, i)
		var tmp = pool[i]; pool[i] = pool[j]; pool[j] = tmp
	var n = mini(9, pool.size())
	title = "PLANET %s" % _planet_name(r)
	lore = "A WORLD OF ITS OWN - SEED %d" % s
	nodes.clear()
	for i in n:
		var key: String = "maps/" + pool[i]
		var a = Assets.area(key)
		var objs = []
		for o in a["meta"].get("objects", []):
			if o["kind"] == "enemy" and Rules.TYPE_SET.has(int(o["type"])):
				objs.append(o)
		var spec = {"objects": objs, "count": maxi(4, mini(10, objs.size() + 2)), "level": 1 + i * 2, "elite": 4 + i, "seed": s * 31 + i}
		var name = Assets.area_name(a)
		if name == "":
			name = "LAND %d" % (i + 1)
		var ex: Array = a["meta"]["exits"]
		var exits = []
		if i > 0:
			exits.append({"rect": ex[0]["rect"], "to": i - 1, "role": 0, "to_role": 1})
		if i < n - 1:
			exits.append({"rect": ex[1]["rect"], "to": i + 1, "role": 1, "to_role": 0})
		nodes.append({"key": key, "name": name, "kind": 2 if i == n - 1 else 0, "chapter": i / 3, "gx": i, "gy": 0, "exits": exits, "spec": spec})
	if n > 0:
		lair = n - 1
		var big = [41, 42, 43, 39, 40, 29, 30, 31, 44]
		nodes[lair]["spec"]["boss_kind"] = big[r.randi_range(0, big.size() - 1)]
		nodes[lair]["spec"]["boss_name"] = "THE WARLORD OF " + title.substr(7)
		nodes[lair]["spec"]["level"] = 1 + n * 2 + 2

func _planet_name(r: RandomNumberGenerator) -> String:
	var a = ["KA", "RO", "ZU", "MI", "TA", "NE", "VO", "SHI", "GA", "DO", "RA", "PU", "KE", "LO"]
	var s = ""
	for i in r.randi_range(2, 3):
		s += a[r.randi_range(0, a.size() - 1)]
	return s

## one of the game's own lands: its maps joined edge to edge into seamless regions (houses and caves behind doors)
func build_land(z: int, s: int) -> bool:
	seed = s
	var L = Assets.land(z)
	if L.is_empty():
		return false
	nodes.clear()
	var regs: Array = L["regions"]
	var gx = 0
	for r in regs.size():
		var reg: Dictionary = regs[r]
		var out = str(reg["kind"]) == "out"
		var en: Array = reg["enemies"]
		var lv_sum = 0
		var fixed = []
		for e in en:
			var t = int(e[0])
			var ts = Rules.kind_to_type_set(t)
			var st = ts[1] if ts[1] >= 0 else int(e[1])
			if st < 0:
				continue
			var tl = int(Assets.data["enemies"][clampi(t, 0, 127)]["lvl"])
			fixed.append({"type": t, "set": st, "x": float(e[2]), "y": float(e[3]), "lv": tl})
			lv_sum += tl
		var lv = maxi(1, lv_sum / maxi(1, fixed.size()))
		if L.get("earth", false):
			lv = 1      # the planet: each foe as strong as its own kind (the north is not the south)
		var exits = []
		var ex: Array = reg["exits"]
		for i in ex.size():
			# a door's box covers the whole door: the game's is often one tile wide at its left edge (doors are 3 tiles)
			var rc: Array = ex[i]["rect"].duplicate()
			if float(rc[2]) - float(rc[0]) < 24.0:
				rc[2] = float(rc[0]) + 24.0
			exits.append({"rect": rc, "to": int(ex[i]["to"]), "arrive": ex[i]["arrive"], "role": i, "to_role": 0})
		var nm = str(reg["name"])
		if nm == "":
			nm = "INSIDE" if not out else "THE WILDS"
		nodes.append({"key": "land/%d/%d" % [z, r], "name": nm.to_upper(), "kind": 0 if out else 1, "chapter": 0,
			"gx": (gx % 6) if out else 0, "gy": (gx / 6) if out else 0, "hidden": not out, "exits": exits,
			"spec": {"fixed": fixed, "count": fixed.size(), "level": lv, "elite": 5, "seed": s * 31 + r}})
		if out:
			gx += 1
	start = int(L["start"])
	lair = -1
	title = "EARTH"      # the game's lands are all Earth; the place you are in shows on its own
	lore = "THE GAME'S OWN MAPS, JOINED INTO ONE WORLD - WALK ON, NO LOADING"
	Mods.apply_to_planet(self)      # your team's foes, doors and maps (DEV TOOLS)
	return true

## a point you can stand on, as near as possible to p (an arrival on a map's very edge is walked inward)
func safe_point(t: int, p: Vector2) -> Vector2:
	var a = Assets.area(nodes[t]["key"])
	if a.is_empty():
		return p
	var ok = func(q: Vector2) -> bool:
		return Assets.walkable(a, q.x, q.y) and Assets.walkable(a, q.x - 5, q.y) and Assets.walkable(a, q.x + 4, q.y) and Assets.walkable(a, q.x, q.y - 4)
	var cl = Vector2(clampf(p.x, 8, a["w"] - 8), clampf(p.y, 12, a["h"] - 8))
	if ok.call(cl) and cl.distance_to(p) < 1.0:
		return p
	for r in range(4, 200, 4):
		for k in 24:
			var q = cl + Vector2(cos(k * PI / 12.0), sin(k * PI / 12.0)) * r
			if ok.call(q):
				return q
	return cl
