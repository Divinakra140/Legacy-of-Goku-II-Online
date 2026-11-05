class_name Breakables
extends RefCounted
## The game's breakable things - rocks, pots, fences, crates (Outside Pepper Town's three in the training): read from
## your game at import (data/breakables.json, kit/breakables.png - each map's list 1 of breakables, 348 in all; the
## map's other pictures - doors, signs, save points - never break and are not put up). As in the game (0x0800EEA8,
## 0x0800F1AE, 0x0800F2B6):
## - the part that is solid and is hit is the picture's own (not see-through) pixels, its lower half;
## - it takes its own number of hits (1 to 3), shaking at each one short of that; at the last it goes up in smoke
##   (the game's smoke picture, the one bombs leave) with pebbles thrown off;
## - the game keeps no mark of a broken one (only its live record turns off) and builds a map's breakables anew each
##   time you go in. EARTH is all the game's maps as one, its places small: here they stand again when you come back
##   to EARTH (no timer).
## Kept once on the map (a["rocks"]), shared by every view of it. Its walls are a["blocks"] (cells - while it stands)
## and a["opened"] (cells - once broken: walkable), kept apart from the map's walk: the editor never sees or saves them.
## What it does when it breaks: a scene (story.gd), or the game's drop script (food, ki - _drop).

const SHAKE = 23        # frames a hit one shakes (the game's 0x17)
const SMOKE = 40        # frames of the smoke (4 pictures)

var world
var data = {}            # place key -> {rocks: [{r: [x0, y0, x1, y1], w, h, hits, how, at, scene | script}]}
var atlas: Texture2D = null
var atlas_img: Image = null
var boxes = {}           # "x,y" in the atlas -> its solid box in the picture (Rect2), worked out once
var tried = false

func _init(w) -> void:
	world = w

func _ready_data() -> bool:
	if not tried:
		tried = true
		var j = Assets.json(Assets.base_dir.path_join("data/breakables.json"))
		if j is Dictionary:
			data = j.get("maps", {})
		atlas_img = Assets.image(Assets.base_dir.path_join("kit/breakables.png"))
		if atlas_img != null:
			atlas = ImageTexture.create_from_image(atlas_img)
	return not data.is_empty() and atlas != null

## the picture's solid box, as the game works it out: round its pixels that show, then only the lower half
func _box(rk: Dictionary) -> Rect2:
	var key = "%d,%d" % [int(rk["at"][0]), int(rk["at"][1])]
	if boxes.has(key):
		return boxes[key]
	var ax = int(rk["at"][0]); var ay = int(rk["at"][1]); var w = int(rk["w"]); var h = int(rk["h"])
	var x0 = w; var y0 = h; var x1 = 0; var y1 = 0
	for y in h:
		for x in w:
			if atlas_img.get_pixel(ax + x, ay + y).a > 0.0:
				x0 = mini(x0, x); y0 = mini(y0, y); x1 = maxi(x1, x + 1); y1 = maxi(y1, y + 1)
	var b = Rect2()
	if x1 > x0:
		var top = (y0 + y1) >> 1
		b = Rect2(x0, top, x1 - x0, y1 - top)
	boxes[key] = b
	return b

## the map's breakables (the editor's too): the game's own where their places are now - less the ones taken away
## (your edits' rocks_del: [place, its number]) and those in front of a door (doors: Rect2s) - and your own
## (rocks_add: {x, y (the picture's top left), like: "place:n" (whose picture), hits, drops}).
## Each {id, place ("" your own), area (Rect2: its place, or round it), n, pic, rect (the solid box), rk, own, i}
func rock_list(a: Dictionary, doors: Array = []) -> Array:
	var out = []
	if not _ready_data() or not a.has("land"):
		return out
	var mp = Mods.merged(str(a.get("key", "")), false)
	var gone = {}
	for d in mp.get("rocks_del", []):
		gone["%s:%d" % [str(d[0]), int(d[1])]] = true
	for pt in a["land"].get("parts", []):
		if pt.size() < 4 or not data.has(str(pt[3])):
			continue
		var at: Vector2 = (pt[0] as Rect2).position
		var rocks: Array = data[str(pt[3])].get("rocks", [])
		for i in rocks.size():
			var rk: Dictionary = rocks[i]
			if gone.has("%s:%d" % [str(pt[3]), i]):
				continue
			var r = (rk["r"] as Array).map(func(v): return float(int(v) - 0x100000000 if int(v) >= 0x80000000 else int(v)))      # (signed: one can stand a little past the map's top)
			if absf(r[2] - r[0]) > 256 or absf(r[3] - r[1]) > 256:
				continue
			var pic = Rect2(at.x + r[0], at.y + r[1], float(rk["w"]), float(rk["h"]))
			var b = _box(rk)
			if b.size.x <= 0:
				continue
			var hit = Rect2(pic.position + b.position, b.size)
			if _at_door(doors, hit):
				continue
			out.append({"id": "%s:%d" % [str(pt[3]), i], "place": str(pt[3]), "area": pt[0], "n": i, "pic": pic, "rect": hit, "rk": rk, "own": false})
	var adds: Array = mp.get("rocks_add", [])
	for i in adds.size():
		var o: Dictionary = adds[i]
		var like = like_rock(str(o.get("like", "")))
		if like.is_empty():
			continue
		var rk: Dictionary = like.duplicate()
		rk.erase("scene"); rk.erase("script"); rk.erase("drops")
		rk["hits"] = clampi(int(o.get("hits", 1)), 1, 3)
		if o.has("scene"):
			rk["scene"] = str(o["scene"])      # (one of the game's story rocks, moved)
		if o.get("drops", []) is Array and not o.get("drops", []).is_empty():
			rk["drops"] = o["drops"]
		var pic = Rect2(float(o["x"]), float(o["y"]), float(rk["w"]), float(rk["h"]))
		var b = _box(rk)
		if b.size.x <= 0:
			continue
		var round_it = pic.grow(48.0)
		if rk.has("scene"):      # (a story rock moved: its scene still plays where its place is - the people in it)
			for pt in a["land"].get("parts", []):
				if pt.size() > 3 and str(pt[3]) == str(o.get("like", "")).get_slice(":", 0):
					round_it = pt[0]
		out.append({"id": "own:%d" % i, "place": "", "area": round_it, "n": i, "pic": pic, "rect": Rect2(pic.position + b.position, b.size), "rk": rk, "own": true, "i": i})
	return out

## a rock of the game by "place:n" (its picture, hits, what it does) - {} if there is none
func like_rock(like: String) -> Dictionary:
	if not _ready_data() or like.get_slice_count(":") != 2:
		return {}
	var rocks: Array = data.get(like.get_slice(":", 0), {}).get("rocks", [])
	var n = int(like.get_slice(":", 1))
	return rocks[n] if n >= 0 and n < rocks.size() else {}

## each different picture of the game's breakables once: [{like: "place:n", rk}] (the editor's ROCK tool)
var _kinds = null
func kinds() -> Array:
	if _kinds != null:
		return _kinds
	var out = []
	if not _ready_data():
		return out
	var seen = {}
	for place in data:
		var rocks: Array = data[place].get("rocks", [])
		for i in rocks.size():
			var rk: Dictionary = rocks[i]
			var k = atlas_img.get_region(Rect2i(int(rk["at"][0]), int(rk["at"][1]), int(rk["w"]), int(rk["h"]))).get_data().hex_encode().sha256_text()      # (the same picture once, wherever the game keeps copies)
			if seen.has(k) or _box(rk).size.x <= 0:
				continue
			seen[k] = true
			out.append({"like": "%s:%d" % [place, i], "rk": rocks[i]})
	_kinds = out
	return out

## the game's drop tables (the drop scripts most of its rocks run - breakables._drop): the ROCK tool's choice
const DROP_TABLES = [
	["NOTHING", []],
	["SMALL FOOD OR KI", [[50, "ep", 14], [100, "hp", 11]]],
	["SMALL OR MEDIUM FOOD OR KI", [[25, "ep", 14], [50, "hp", 11], [75, "ep", 15], [100, "hp", 12]]],
	["ANY SIZE FOOD OR KI", [[15, "ep", 14], [32, "hp", 11], [49, "ep", 15], [66, "hp", 12], [83, "ep", 16], [100, "hp", 13]]],
	["FOOD OR KI, EVEN IF FULL", [[40, "", 11], [80, "", 14]]],
]

## a map view's breakables: kept once on the map (every view of it shares them - one broken is broken for all), each
## view only draws them; each where the game has it (each place of the map moved where it is now), solid
func attach(av) -> void:
	if not _ready_data() or not av.area.has("land"):
		return
	var a: Dictionary = av.area
	if not a.has("rocks"):
		var list = []
		var places = {}
		var doors = []
		if Game.planet != null and av.node_i >= 0 and av.node_i < Game.planet.nodes.size():
			for ex in Game.planet.nodes[av.node_i].get("exits", []):
				var xr: Array = ex["rect"]
				doors.append(Rect2(float(xr[0]), float(xr[1]), float(xr[2]) - float(xr[0]), float(xr[3]) - float(xr[1])))
		a["blocks"] = {}
		a["opened"] = {}
		var tw = int(a["tw"]); var size = int(a["tw"]) * int(a["th"])
		for e in rock_list(a, doors):
			e["cells"] = _cells(tw, size, e["rect"])
			e["gone"] = true; e["hp"] = 0; e["shake"] = 0
			_stand(a, e)
			list.append(e)
			if e["place"] != "":
				if not places.has(e["place"]):
					places[e["place"]] = {"area": e["area"], "rocks": []}
				places[e["place"]]["rocks"].append(e)
		a["rocks"] = list
		a["rock_places"] = places
	else:
		var shown = false      # no other view of the map left: everyone had gone - back, its broken ones stand again
		for v in world.views.values():
			if v != av and is_same(v.area, a):
				shown = true
		if not shown:
			for e in a["rocks"]:
				if e["gone"]:
					_stand(a, e)
	var sprites = []
	for e in a["rocks"]:
		var rk: Dictionary = e["rk"]
		var s = Sprite2D.new()
		var tex = AtlasTexture.new()
		tex.atlas = atlas
		tex.region = Rect2(float(rk["at"][0]), float(rk["at"][1]), float(rk["w"]), float(rk["h"]))
		s.texture = tex
		s.centered = false
		s.position = Vector2(e["pic"].position.x, e["pic"].end.y)      # (drawn in depth order by its foot)
		s.offset = Vector2(0, -float(rk["h"]))
		s.visible = not e["gone"]
		av.ents.add_child(s)
		sprites.append(s)
	av.root.set_meta("rock_sprites", sprites)

## round them the game's own collision of their place (maps/<place>/walk.png), read the first time a player is in it:
## building EARTH closed cells round some rocks that the game leaves open (walls left after one broke) - opened
## (a["opened"]). Read on another thread: read here, a disk gone to sleep held the whole game still for seconds
func _game_walk(a: Dictionary) -> void:
	for key in a["rock_places"]:
		var pl: Dictionary = a["rock_places"][key]
		if pl.has("walked"):
			if pl.has("task") and WorkerThreadPool.is_task_completed(int(pl["task"])):
				WorkerThreadPool.wait_for_task_completion(int(pl["task"]))
				pl.erase("task")
				if pl.get("img") != null:
					_open_round(a, pl, pl["img"])
				pl.erase("img")
			continue
		var inside = false
		for P in world.locals:
			if is_same(P.fighter.area, a) and (pl["area"] as Rect2).has_point(Vector2(P.fighter.x, P.fighter.y)):
				inside = true
				break
		if not inside:
			continue
		pl["walked"] = true
		var path = Assets.base_dir.path_join("maps/%s/walk.png" % key)
		pl["task"] = WorkerThreadPool.add_task(func(): pl["img"] = Assets.image(path))

func _open_round(a: Dictionary, pl: Dictionary, im: Image) -> void:
	var at: Vector2 = (pl["area"] as Rect2).position
	var tw = int(a["tw"]); var th = int(a["th"])
	for e in pl["rocks"]:
		var pic: Rect2 = e["pic"]
		for y in range(int(floor(pic.position.y / 8.0)) - 2, int(ceil(pic.end.y / 8.0)) + 2):
			for x in range(int(floor(pic.position.x / 8.0)) - 2, int(ceil(pic.end.x / 8.0)) + 2):
				var mx = x - int(at.x) / 8; var my = y - int(at.y) / 8
				if x < 0 or y < 0 or x >= tw or y >= th or mx < 0 or my < 0 or mx >= im.get_width() or my >= im.get_height():
					continue
				if a["walk"][y * tw + x] == 0 and im.get_pixel(mx, my).r > 0.0:
					a["opened"][y * tw + x] = true

## the ones in front of a door (a cave's way in) are left out for now: in the story they keep a place shut until you
## are strong enough (not ported yet) - standing, they shut you in or out
static func _at_door(doors: Array, hit: Rect2) -> bool:
	for d in doors:
		if hit.grow(24.0).intersects(d):
			return true
	return false

## one put up again: its hits, and the cells its solid box touches walls while it stands (the game, 0x080063E0:
## the map's walk bits cleared over the box rounded out to whole cells)
func _stand(a: Dictionary, e: Dictionary) -> void:
	e["gone"] = false
	e["hp"] = maxi(1, int(e["rk"].get("hits", 1)))
	e["shake"] = 0
	var bl: Dictionary = a["blocks"]
	for c in e["cells"]:
		bl[c] = int(bl.get(c, 0)) + 1

## broken: its cells walked over again - the game sets them walkable whatever the map had there (a["opened"])
func _unblock(a: Dictionary, e: Dictionary) -> void:
	var bl: Dictionary = a["blocks"]
	for c in e["cells"]:
		var k = int(bl.get(c, 0)) - 1
		if k > 0:
			bl[c] = k
		else:
			bl.erase(c)
		a["opened"][c] = true

## its cells (their places in the map's walk list)
static func _cells(tw: int, size: int, r: Rect2) -> Array:
	var out = []
	for y in range(int(floor(r.position.y / 8.0)), int(ceil(r.end.y / 8.0))):
		for x in range(int(floor(r.position.x / 8.0)), int(ceil(r.end.x / 8.0))):
			var i = y * tw + x
			if x >= 0 and x < tw and i >= 0 and i < size:
				out.append(i)
	return out

## every tick, for a player: a hit on one counts down its hits; the last breaks it
func check(L) -> void:
	if not world.views.has(L.node_i):
		return
	var av = world.views[L.node_i]
	var a: Dictionary = av.area
	var list: Array = a.get("rocks", [])
	if list.is_empty():
		return
	var f = Engine.get_physics_frames()
	if a.get("rocks_f", -1) != f:      # (once a frame for the map, however many players and views are on it)
		a["rocks_f"] = f
		_game_walk(a)
		for e in list:
			if not e["gone"] and e["shake"] > 0:
				e["shake"] -= 1
		_show(a, list)
	for e in list:
		if e["gone"] or e["shake"] > 0:      # (a shaking one takes no more hits from the same blow)
			continue
		var r: Rect2 = e["rect"]
		if not world.events_rt._attack_in(L.fighter, [r.position.x, r.position.y, r.end.x, r.end.y]):
			continue
		var c = r.get_center()
		for sh in L.fighter.shots:      # the plain ki blast (B): the game's purple spark where it strikes, as on a foe
			if int(sh.get("kind", -1)) == 0 and r.grow(4).has_point(Vector2(float(sh.get("x", -9999)), float(sh.get("y", -9999)))):
				av.sparks.append([Vector2(float(sh["x"]), float(sh["y"])), 14, "kihit", 14])
				break
		for k in 4:      # pebbles thrown off at each hit
			av.sparks.append([c + Vector2(randf_range(-4, 4), randf_range(-4, 2)), 18, "pebble", Vector2(randf_range(-1.6, 1.6), randf_range(-2.2, -0.8))])
		e["hp"] -= 1
		if e["hp"] > 0:
			e["shake"] = SHAKE
			Sfx.play("hit")
			return
		e["gone"] = true
		_unblock(a, e)
		_show(a, list)
		av.sparks.append([c, SMOKE, "e_smoke", SMOKE])
		Sfx.play("hit")
		_broke(L, e)
		return

## every view of the map draws them as they are: standing or not, shaking
func _show(a: Dictionary, list: Array) -> void:
	for v in world.views.values():
		if not is_same(v.area, a):
			continue
		var sprites: Array = v.root.get_meta("rock_sprites", [])
		for i in mini(sprites.size(), list.size()):
			var e = list[i]
			var s: Sprite2D = sprites[i]
			s.visible = not e["gone"]
			s.offset.x = (2.0 if (e["shake"] / 2) % 2 == 0 else -2.0) if e["shake"] > 0 else 0.0

## its drop script, as the game runs it (0x0800F9A3): r = a random 0-99, then its brackets [T, check, item] in order -
## the first with r < T whose check holds (hp / ep: the one who broke it is not full) drops its item, where it stood;
## none: nothing. Items 11-13 food (10 / 20 / 30 % of max HP), 14-16 ki (the same of max EP)
func _drop(L, e: Dictionary) -> void:
	var f = L.fighter
	var r = randi() % 100
	for b in e["rk"]["drops"]:
		var ok = str(b[1]) == "" or (str(b[1]) == "hp" and f.hp < f.maxhp) or (str(b[1]) == "ep" and f.ep < f.maxep)
		if r < int(b[0]) and ok:
			var item = int(b[2])
			if item >= 11 and item <= 16:
				var box: Rect2 = e["rect"]
				Game.rock_drop(L.node_i, box.get_center().x, box.end.y, "food" if item <= 13 else "ki", (item - 10 if item <= 13 else item - 13) * 10)
			return

## what the game does when one breaks: a scene (its group, played with the player's story flags)
func _broke(L, e: Dictionary) -> void:
	var rk: Dictionary = e["rk"]
	if rk.has("drops"):
		_drop(L, e)
		return
	if not rk.has("scene") or not L.ev.is_empty():
		return
	var off = (e["area"] as Rect2).position
	var flags = {}
	for k in L.fighter.flags:
		if str(k).begins_with("story:"):
			flags[k] = true
	var sc = Story.scene(("0x" + str(rk["scene"])).hex_to_int(), 0, flags, {"at": off})
	if not sc.is_empty():
		world.events_rt.start(L, str(sc["id"]))
