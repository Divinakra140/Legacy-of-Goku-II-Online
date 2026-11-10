extends RefCounted
## THE HERO OF EARTH (a story: modpacks/Dragon_Ball_Hunt): the event step {"do": "dragonballs"} hides the 7 Dragon
## Balls round EARTH - each on plain open ground (walked on, not HIGH GROUND, nothing drawn over the hero, not the
## sea, not a wall, outdoors) and far apart. Walk up to one and it is yours: its big picture on the screen, the count
## in the top right corner (var "dragonballs"). The pictures are the game's own (the importer: kit/dragonballs.png).
## Kept in the player's own story flags: "db:on", "var:db_x<i>" / "var:db_y<i>", "db:got:<i>", "var:dragonballs".

const N = 7
const REACH = 18.0         # this near (px) and it is picked up
const APART = 1600.0       # no two closer than this
const EARTH = "land/0/0"

var world
var tex: Array = []        # the 7 balls (1 to 7 stars), 16 x 16 each
var sprites = {}           # "node:i" -> Sprite2D in that view
var big_t = 0              # the big picture on the screen: ticks left
var big_n = 0

func _init(w) -> void:
	world = w
	var p = Assets.base_dir.path_join("kit/dragonballs.png")
	var img = Image.load_from_file(p) if FileAccess.file_exists(p) else null
	if img != null:
		var it = ImageTexture.create_from_image(img)
		for i in N:
			var at = AtlasTexture.new()
			at.atlas = it
			at.region = Rect2(0, i * 16, 16, 16)
			tex.append(at)

## the event step: hide them (a new hunt; a hunt already on is left as it is)
static func scatter(f) -> void:
	if f.flags.get("db:on", false):
		return
	var a: Dictionary = Assets.area(EARTH)
	if a.is_empty():
		return
	var tw: int = a["tw"]
	var th: int = a["th"]
	var ph = mini(th, int(a.get("land", {}).get("info", {}).get("planet_h", th)))
	var cells: Array = a["land"]["cells"]
	var walk: PackedByteArray = a["walk"]
	var ok = func(cx: int, cy: int) -> bool:
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				var x = cx + dx; var y = cy + dy
				if x < 2 or y < 2 or x >= tw - 2 or y >= ph - 2:
					return false
				var i = y * tw + x
				if (walk[i] & 1) == 0 or (walk[i] & 4) != 0:
					return false      # a wall, the sea, or HIGH GROUND
				if cells[3][i] != 0 or cells[4][i] != 0:
					return false      # something drawn over the hero (roofs, tree tops, OVER tiles)
		return true
	var rng = RandomNumberGenerator.new()
	rng.randomize()
	var got = []
	var tries = 0
	while got.size() < N and tries < 60000:
		tries += 1
		var cx = rng.randi_range(4, tw - 5)
		var cy = rng.randi_range(4, ph - 5)
		if not ok.call(cx, cy):
			continue
		var p = Vector2(cx * 8 + 4, cy * 8 + 4)
		var far = true
		for q in got:
			if (q as Vector2).distance_to(p) < (APART if tries < 40000 else APART * 0.4):
				far = false
				break
		if far:
			got.append(p)
	for i in got.size():
		f.flags["var:db_x%d" % i] = got[i].x
		f.flags["var:db_y%d" % i] = got[i].y
		f.flags.erase("db:got:%d" % i)
	f.flags["var:dragonballs"] = 0
	f.flags["db:on"] = true

static func on(f) -> bool:
	return f.flags.get("db:on", false)

static func count(f) -> int:
	return int(f.flags.get("var:dragonballs", 0))

## each tick, a player here: a ball close enough is picked up
func step(L) -> void:
	var f = L.fighter
	if not on(f) or L.node_i < 0 or str(Game.planet.nodes[L.node_i]["key"]) != EARTH:
		return
	for i in N:
		if f.flags.get("db:got:%d" % i, false) or not f.flags.has("var:db_x%d" % i):
			continue
		var p = Vector2(float(f.flags["var:db_x%d" % i]), float(f.flags["var:db_y%d" % i]))
		if f.flying:
			continue      # (flying over one: you have to land and go and get it)
		if Vector2(f.x, f.y - 6.0).distance_to(p) < REACH:
			f.flags["db:got:%d" % i] = true
			f.flags["var:dragonballs"] = count(f) + 1
			big_t = 150
			big_n = i
			Sfx.play("item")
			world.toasts.append(["DRAGON BALL %d / %d!" % [count(f), N], Color(1, 0.8, 0.3), 160])
			if count(f) >= N:
				world.toasts.append(["ALL 7! TAKE THEM BACK TO DENDE", Color(1, 0.95, 0.6), 260])

## the balls on the ground: the ones the players here have still to find
func sync() -> void:
	var want = {}
	for L in world.locals:
		var f = L.fighter
		if not on(f) or L.node_i < 0 or not world.views.has(L.node_i) or str(Game.planet.nodes[L.node_i]["key"]) != EARTH:
			continue
		for i in N:
			if not f.flags.get("db:got:%d" % i, false) and f.flags.has("var:db_x%d" % i):
				want["%d:%d" % [L.node_i, i]] = [L.node_i, i, Vector2(float(f.flags["var:db_x%d" % i]), float(f.flags["var:db_y%d" % i]))]
	for k in sprites.keys():
		if not want.has(k) or not is_instance_valid(sprites[k]):
			if is_instance_valid(sprites[k]):
				sprites[k].queue_free()
			sprites.erase(k)
	for k in want:
		if sprites.has(k) or tex.is_empty():
			continue
		var w: Array = want[k]
		var s = Sprite2D.new()
		s.texture = tex[int(w[1])]
		s.position = w[2]
		s.offset = Vector2(0, -6)
		world.views[int(w[0])].ents.add_child(s)
		sprites[k] = s
	# a little bob, as something to pick up
	var t = Time.get_ticks_msec() / 1000.0
	for k in sprites:
		sprites[k].offset = Vector2(0, -6 - 2.0 * absf(sin(t * 3.0)))

## the HUD: the count in the top right corner, and the big picture of the ball just found
func draw(c: Control, vs: Vector2) -> void:
	if world.locals.is_empty() or tex.is_empty():
		return
	var f = world.locals[0].fighter
	if not on(f):
		return
	var font = ThemeDB.fallback_font
	# (the HUD's own scale: the minimap's box starts at y 20 in it - the count sits on top of it, right-aligned)
	var at = Vector2(vs.x - 58, 4)
	c.draw_rect(Rect2(at, Vector2(52, 15)), Color(0, 0, 0, 0.6))
	c.draw_texture_rect(tex[mini(N - 1, maxi(0, count(f) - 1))], Rect2(at + Vector2(2, 1), Vector2(13, 13)), false)
	c.draw_string(font, at + Vector2(18, 11), "%d / %d" % [count(f), N], HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(1, 0.85, 0.35))

## the big picture of the ball just found, in the middle of the screen (drawn at the screen's own size)
func draw_big(c: Control, vs: Vector2) -> void:
	if world.locals.is_empty() or tex.is_empty() or big_t <= 0:
		return
	if big_t > 0:
		big_t -= 1
		var a = clampf(big_t / 30.0, 0.0, 1.0)
		var grow = clampf((150 - big_t) / 12.0, 0.0, 1.0)
		var sz = 112.0 * (0.6 + 0.4 * grow)
		var cen = vs / 2.0 - Vector2(0, 20)
		c.draw_circle(cen, sz * 0.75, Color(1, 0.8, 0.3, 0.25 * a))
		c.draw_texture_rect(tex[big_n], Rect2(cen - Vector2(sz, sz) / 2.0, Vector2(sz, sz)), false, Color(1, 1, 1, a))
