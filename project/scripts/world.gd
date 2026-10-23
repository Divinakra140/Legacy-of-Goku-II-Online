extends Node2D
## The world on this PC: one or two local players (split screen) plus the partners online.
## Every area someone here stands in is built once and laid out far apart in ONE shared 2D world;
## each local player has their own camera (a SubViewport looking into that world). When both stand
## close together the screen is one picture; when they move apart it splits along the line between
## them (and turns as they move round each other); in different places it is a left/right split.
## No GBA screen: the view is wider, sprites and colours have no limits, nothing flickers.

const AREA_GAP = 16384.0
const CHUNK = 16
const SPLIT_SHADER = """
shader_type canvas_item;
uniform sampler2D view1 : filter_nearest;
uniform sampler2D view2 : filter_nearest;
uniform bool split = false;
uniform vec2 dir = vec2(1.0, 0.0);
uniform vec2 line_px = vec2(240.0, 135.0);
uniform vec2 size = vec2(480.0, 270.0);
uniform float fade1 = 0.0;
uniform float fade2 = 0.0;
void fragment() {
	vec2 px = UV * size;
	float s = dot(px - line_px, dir);
	vec3 c;
	if (!split || s < 0.0) {
		c = texture(view1, UV).rgb * (1.0 - fade1);
	} else {
		c = texture(view2, UV).rgb * (1.0 - fade2);
	}
	if (split) {
		float a = abs(s);
		if (a < 1.0) { c = vec3(0.02, 0.02, 0.05); }
		else if (a < 2.0) { c = mix(c, vec3(1.0, 0.95, 0.7), 0.7); }
	}
	COLOR = vec4(c, 1.0);
}
"""

class Local:
	var k = 0
	var fighter = FighterSim.new()
	var node_i = -1
	var area = {}
	var fade = 1.0
	var fade_dir = -1
	var pending = {}
	var exits_armed = false
	var banner = ""
	var banner_t = 0
	var kills = 0
	var send_t = 0
	var cam = Vector2.ZERO        # where this player's camera looks (area coordinates)
	var shake = 0.0
	var asked = {}                # orbs this player has reached (asked the host for)
	var menu = {}                 # open menu: {tab, row, mode, act, target, amount}
	var mprev = {}                # menu buttons last tick
	var shown_set = -1
	var was_down = false
	var helping = {}              # downed friend's player id -> ticks spent helping
	var cam_snap = true
	var name = "PLAYER"
	var place = ""                # the original area you are standing in (inside a land)
	var talk = {}                 # talking with someone: {i, line, t}
	var cut_cam = {}              # a story scene's camera: {from, to, t, n, zoom}
	var comps = []                # companions fighting beside you: [{name, set, lv, x, y, dir, t, cool, v}]
	var mood = {}                 # the MOOD box you stand in (darkness, weather, music)
	var talk_hold = false         # A still held from a talk press (it must not punch)
	var near_npc = -1             # the person close enough to talk with (-1: nobody)
	var near_save = false         # standing on a Capsule Corp save point
	var mouse_ok = false          # the menu: a mouse click (A) / right click (B) waiting
	var mouse_back = false
	var pvp_ask = false           # R2 on a save point: "ENTER PVP MODE?" waiting for A / B
	var run_toggle = false        # R2 (off a save point): sprint stays on until R2 again
	var party = {}                # player id -> name: your party (shares exp and kills across the world)
	var invites = []              # asked by others: [kind, player id, name, ticks left]
	var duel = {}                 # a friendly duel: {with, name, t (countdown), over}
	var trade = {}                # a trade: {with, name, mine, theirs, ready_me, ready_them}
	var ev = {}                   # an event running (DEV TOOLS - EVENTS)
	var in_trig = {}              # event boxes this player stands in

class AreaView:
	var node_i = 0
	var root: Node2D
	var ents: Node2D
	var shots_view: Node2D
	var back_shots_view: Node2D      # under the fighters: an eye beam fired upward starts behind the head
	var pops_view: Node2D
	var offset = Vector2.ZERO
	var area = {}
	var enemy_views = {}
	var remote_views = {}
	var local_views = {}
	var anim_layers = []
	var tiles = []               # a land: its TileMapLayers (0 ground .. 4 over the fighters)
	var chunks = {}              # a land: chunks drawn now (Vector2i -> true)
	var pops = []                # [text, pos, ticks, color]
	var sparks = []              # [pos, ticks, color]
	var spawn_seen = {}          # enemy id -> ticks shown while it comes back (fade in)
	var npc_views = []           # the people standing here (ActorView per person of area["people"])
	var npc_done = false

var locals = []                  # Local
var views = {}                   # node index -> AreaView
var world_root: Node2D
var svs = []                     # SubViewport per local player
var cams = []
var screen: TextureRect
var mat: ShaderMaterial
var hud: CanvasLayer
var hud_draw: Control
var toasts = []                  # [text, color, ticks]
var victory_t = 0
var victory_text = ""
var paused = false
var save_t = 0
var test_keys = []               # test aid: scripted input per local player
var levels = []
var split_now = false
var split_dir = Vector2(1, 0)
var line_px = Vector2.ZERO
var base_cam = Vector2.ZERO
var base_snap = true
var chat_box: LineEdit
var chat_open = false
var chat_log = []                # [text, color, ticks]
var bubbles = {}                 # player id -> [text, ticks]
var map_open = false
var map_pick = 0
var ready_done = false
## HUD / MINIMAP: kept in the options (OPTIONS in the menu, or OPTIONS - OPTIONS before you play)
var minimap_on: bool:
	get: return bool(Game.cfg.get("minimap_on", true))
	set(v): Game.cfg["minimap_on"] = v
var show_controls = false     # START - OPTIONS - SHOW CONTROLS: the keys and buttons, under the options
## WORDS ON SCREEN (OPTIONS): off hides the game's words - names over heads, the other players' lines, ONLINE,
## place names, messages - for a quieter screen; speech, chat and the menus stay
var words_on: bool:
	get: return bool(Game.cfg.get("words_on", true))
	set(v): Game.cfg["words_on"] = v
var hud_on: bool:
	get: return bool(Game.cfg.get("hud_on", true))
	set(v): Game.cfg["hud_on"] = v
var _hud_vs = Vector2(480, 270)     # the screen in the HUD's own (scaled) units
var _hs = 1.0                        # the HUD's scale while it is being drawn (1 outside it)
## the HUD box the same size on the screen at any VIEW SIZE: at PIXELS x2 it was tiny, at x6 it covered the screen
func _hud_scale(vs: Vector2) -> float:
	var ws = Vector2(get_window().size)
	if ws.x <= 0 or vs.x <= 0:
		return 1.0
	var kmax = maxf(1.0, minf(floorf(ws.x / 480.0), floorf(ws.y / 270.0)))      # what AUTO would use
	return clampf(kmax * vs.x / ws.x, 0.25, 6.0)
var preload_q = []               # areas next door, read ahead a little each tick (no wait at a way out)

var touch                     # on-screen controls (phones, tablets) - scripts/touch.gd
var touch_prev = {}

var events_rt

func _ready() -> void:
	events_rt = preload("res://scripts/events.gd").new(self)
	touch = preload("res://scripts/touch.gd").new()
	add_child(touch)
	levels = Assets.data["levels"]
	Game.toast.connect(func(t, c): toasts.append([t, c, 180]))
	Game.exp_gained.connect(_on_exp)
	Game.hurt.connect(_on_hurt)
	Game.victory.connect(_on_victory)
	# the shared world and the first camera
	var sv0 = _make_viewport()
	world_root = Node2D.new()
	sv0.add_child(world_root)
	screen = TextureRect.new()
	screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	screen.stretch_mode = TextureRect.STRETCH_SCALE
	screen.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mat = ShaderMaterial.new()
	var sh = Shader.new()
	sh.code = SPLIT_SHADER
	mat.shader = sh
	screen.material = mat
	var bottom = CanvasLayer.new()
	bottom.layer = 0
	add_child(bottom)
	bottom.add_child(screen)
	hud = CanvasLayer.new()
	hud.layer = 1
	add_child(hud)
	hud_draw = Control.new()
	hud_draw.set_anchors_preset(Control.PRESET_FULL_RECT)
	hud_draw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_draw.draw.connect(_draw_hud)
	# DEV TOOLS: the blast tuner (F9)
	var tuner = load("res://scripts/blast_tuner.gd").new()
	tuner.world = self
	add_child(tuner)
	hud.add_child(hud_draw)
	chat_box = LineEdit.new()
	chat_box.visible = false
	chat_box.placeholder_text = "SAY SOMETHING (ENTER: SEND, R3 OR B: CANCEL)" if OS.has_feature("android") else "SAY SOMETHING (ENTER: SEND, ESC: CANCEL)"
	chat_box.max_length = 80
	chat_box.add_theme_font_size_override("font_size", 8)
	chat_box.position = Vector2(6, 200)
	chat_box.size = Vector2(300, 14)
	chat_box.text_submitted.connect(_chat_send)
	hud.add_child(chat_box)
	Game.chat.connect(_on_chat)
	Game.item_got.connect(_on_item)
	Game.gift.connect(_on_gift)
	Game.social.connect(_on_social)
	Game.revived.connect(_on_revived)
	get_viewport().size_changed.connect(_on_resize)
	var p = Game.planet
	_add_local(0, int(Game.cfg["character"]), str(Game.cfg["name"]), p.start_point())
	if int(Game.cfg.get("local_players", 1)) >= 2:
		_add_local(1, int(Game.cfg.get("character2", 0)), str(Game.cfg.get("name2", "PLAYER 2")), p.start_point() + Vector2(18, 0))
	toasts.append([p.title, Color(1, 0.85, 0.3), 300])
	for line in p.lore.split("\n"):
		if line != "":
			toasts.append([line, Color(0.9, 0.95, 1), 300])
	_on_resize()
	ready_done = true
	for L in locals:
		var te = str(Game.cfg.get("test_event", ""))
		if te != "" and L.k == 0:
			L.fighter.flags.erase("event:" + te)
			events_rt.start(L, te)      # DEV TOOLS - EVENTS: TEST
		elif Game.cfg.has("story") and L.k == 0 and not L.fighter.flags.has("story:started") and str(Content.story.get("intro_event", "")) != "":
			L.fighter.flags["story:started"] = true          # a story of your own: its intro, once
			events_rt.start(L, str(Content.story["intro_event"]))
		else:
			events_rt.on_start(L)
	Game.cfg.erase("test_event")

func _make_viewport() -> SubViewport:
	var sv = SubViewport.new()
	sv.size = Vector2i(get_viewport().get_visible_rect().size)
	sv.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.snap_2d_transforms_to_pixel = true
	sv.snap_2d_vertices_to_pixel = true
	sv.disable_3d = true
	add_child(sv)
	if not svs.is_empty():
		sv.world_2d = svs[0].world_2d
	var cam = Camera2D.new()
	sv.add_child(cam)
	cam.make_current()
	svs.append(sv)
	cams.append(cam)
	return sv

func _on_resize() -> void:
	var vs = get_viewport().get_visible_rect().size
	for sv in svs:
		sv.size = Vector2i(vs)
	mat.set_shader_parameter("size", vs)
	if chat_box:
		chat_box.position = Vector2(6, vs.y - 52)
	screen.texture = svs[0].get_texture()    # (a TextureRect draws - and runs its shader - only with a texture)
	mat.set_shader_parameter("view1", svs[0].get_texture())
	mat.set_shader_parameter("view2", svs[mini(1, svs.size() - 1)].get_texture())

# ------------------------------------------------------------------ local players
func _add_local(k: int, ch: int, nm: String, pos: Vector2) -> void:
	var L = Local.new()
	L.k = k
	L.name = nm
	L.fighter.setup(ch, levels)
	Game.load_fighter(L.fighter, k)
	locals.append(L)
	if svs.size() < locals.size():
		_make_viewport()
		_on_resize()
	var n = Game.planet.start if locals.size() == 1 else locals[0].node_i
	var at = pos if locals.size() == 1 else Vector2(locals[0].fighter.x + 18, locals[0].fighter.y)
	# back after a dropped connection: where you were; joining a running world: next to a friend
	var w = Game.session_where.get(k)
	var sp = Game.cfg.get("spawn")
	if w != null and str(w.get("world", "")) == Game.world_id() and (k == 0 or not ready_done):
		n = int(w["node"]); at = Vector2(float(w["x"]), float(w["y"]))
	elif sp != null and k == 0 and Game.cfg["mode"] == "join":
		n = int(sp["node"]); at = Vector2(float(sp["x"]) + 16, float(sp["y"]))
		toasts.append(["YOU JOIN YOUR FRIENDS", Color(0.7, 1, 0.8), 200])
	var sa = Game.cfg.get("start_at")
	var fw: Dictionary = L.fighter.where if L.fighter.where is Dictionary else {}
	if Game.cfg.has("story") and k == 0 and not ready_done and fw.has("key"):
		sa = {"key": fw["key"], "x": fw.get("x", 0), "y": fw.get("y", 0)}       # (a story: back where you saved)
	if sa != null and k == 0 and not ready_done:
		# PLAY HERE (DEV TOOLS): right where the editor was
		for ni in Game.planet.nodes.size():
			if str(Game.planet.nodes[ni]["key"]) == str(sa["key"]):
				n = ni; at = Vector2(float(sa["x"]), float(sa["y"]))
				break
	if n < 0 or n >= Game.planet.nodes.size():
		n = Game.planet.start; at = Game.planet.start_point()
	var a = Assets.area(Game.planet.nodes[n]["key"])
	if not Assets.walkable(a, at.x, at.y):
		if sa != null and k == 0:
			at = Game.planet.safe_point(n, at)
		else:
			at = at - Vector2(16, 0) if Assets.walkable(a, at.x - 16, at.y) else Game.planet.arrival(n, 0)
	_enter(L, n, at)
	if Game.cfg.has("dev_return") and k == 0:
		var pt: Dictionary = Game.cfg.get("playtest", {})
		var want = int(pt.get("level", 0))
		if want > L.fighter.level and levels.size() > 0:
			var target_exp = int(levels[clampi(want - 1, 0, levels.size() - 1)])
			if target_exp > L.fighter.exp:
				L.fighter.add_exp(target_exp - L.fighter.exp, levels)
		toasts.append(["PLAY-TEST - F10: BACK TO THE DEV TOOLS", Color(0.5, 1, 0.8), 600])
	if k > 0:
		toasts.append([("%s JOINS" if OS.has_feature("mobile") else "%s JOINS ON THIS PC") % nm, Color(0.6, 1, 0.9), 200])

func _remove_local(k: int) -> void:
	for i in locals.size():
		var L: Local = locals[i]
		if L.k == k:
			_remember(L)
			Game.save_fighter(L.fighter, k)
			Game.local_gone(k)
			locals.remove_at(i)
			var old = L.node_i
			L.node_i = -1
			_release_view(old)
			break
	while svs.size() > maxi(1, locals.size()):
		var sv = svs.pop_back()
		cams.pop_back()
		sv.queue_free()
	_on_resize()

func _local_of(k: int) -> Local:
	for L in locals:
		if L.k == k:
			return L
	return null

# ------------------------------------------------------------------ areas
func _view_for(n: int) -> AreaView:
	if views.has(n):
		return views[n]
	var av = AreaView.new()
	av.node_i = n
	av.offset = Vector2(n * AREA_GAP, 0)
	var key: String = Game.planet.nodes[n]["key"]
	av.area = Assets.area(key)
	av.root = Node2D.new()
	av.root.position = av.offset
	world_root.add_child(av.root)
	var meta: Dictionary = av.area["meta"]
	var bg = ColorRect.new()
	var bd: Array = meta.get("backdrop", [0, 0, 0])
	bg.color = Color8(int(bd[0]), int(bd[1]), int(bd[2]))
	# the backdrop colour under the map itself; past the map's edge a wide black border, like the GBA (no other places show)
	bg.size = Vector2(av.area["w"], av.area["h"])
	bg.z_index = -100
	av.root.add_child(bg)
	var edge = ColorRect.new()
	edge.color = Color.BLACK
	edge.position = Vector2(-1200, -1200)
	edge.size = Vector2(av.area["w"] + 2400, av.area["h"] + 2400)
	edge.z_index = -101
	av.root.add_child(edge)
	var pri: Array = meta.get("pri", [0, 0, 0, 0])
	var order = [0, 1, 2, 3]
	order.sort_custom(func(a, b): return int(pri[a]) > int(pri[b]) if int(pri[a]) != int(pri[b]) else a > b)
	var z = -50
	if av.area.has("land"):
		# a land: tile layers, filled chunk by chunk around the players (no picture of the whole thing in memory)
		var ts = Assets.tileset()
		for k in 5:
			var tl = TileMapLayer.new()
			tl.navigation_enabled = false      # (no navigation: the game does not use it)
			tl.collision_enabled = false
			tl.tile_set = ts
			tl.z_index = [-50, -45, -40, 70, 72][k]
			tl.rendering_quadrant_size = 32
			av.root.add_child(tl)
			av.tiles.append(tl)
		order = []
	for k in order:
		var front = int(pri[k]) <= 1 and int(pri[k]) < int(pri[order[0]])
		var tex: Texture2D = av.area["layers"][k]
		var zz = (20 + z + 60) if front else z
		if tex != null:
			var s = Sprite2D.new()
			s.texture = tex
			s.centered = false
			s.z_index = zz
			av.root.add_child(s)
		var at = AnimTiles.new()
		at.setup(av.area, k)
		at.z_index = zz
		av.root.add_child(at)
		av.anim_layers.append(at)
		z += 5
	av.ents = Node2D.new()
	av.ents.y_sort_enabled = true
	av.root.add_child(av.ents)
	av.shots_view = Node2D.new()
	av.shots_view.z_index = 15
	av.shots_view.draw.connect(_draw_shots.bind(av))
	av.root.add_child(av.shots_view)
	av.back_shots_view = Node2D.new()
	av.back_shots_view.z_index = -1
	av.back_shots_view.draw.connect(_draw_shots.bind(av, true))
	av.root.add_child(av.back_shots_view)
	av.pops_view = Node2D.new()
	av.pops_view.z_index = 90
	av.pops_view.draw.connect(_draw_pops.bind(av))
	av.root.add_child(av.pops_view)
	views[n] = av
	return av

## a land: draw the chunks around the players in it, forget the far ones
func _stream(av: AreaView, all_now: bool = false) -> void:
	if av.tiles.is_empty():
		return
	var tw: int = av.area["tw"]
	var th: int = av.area["th"]
	# how many chunks the screen needs round each player (a bigger screen sees further), nearest first;
	# a few small chunks a frame, and far ones forgotten a few at a time - never a hitch while walking
	var vs = get_viewport().get_visible_rect().size
	var rx = int(ceil(vs.x / 2.0 / (CHUNK * 8))) + 1
	var ry = int(ceil(vs.y / 2.0 / (CHUNK * 8))) + 1
	var need = []
	for L in locals:
		if L.node_i != av.node_i:
			continue
		var c = Vector2i(int(L.fighter.x) / (CHUNK * 8), int(L.fighter.y) / (CHUNK * 8))
		for dy in range(-ry, ry + 1):
			for dx in range(-rx, rx + 1):
				var q = c + Vector2i(dx, dy)
				if q.x >= 0 and q.y >= 0 and q.x * CHUNK < tw and q.y * CHUNK < th and not av.chunks.has(q) and not need.has(q):
					need.append(q)
		if need.size() > 1:
			need.sort_custom(func(a, b): return (a - c).length_squared() < (b - c).length_squared())
	var budget = 9999 if all_now else 6
	for q in need:
		if budget <= 0:
			break
		budget -= 1
		_fill_chunk(av, q, true)
		av.chunks[q] = true
	var drop = 9999 if all_now else 3
	for q in av.chunks.keys():
		if drop <= 0:
			break
		var far = true
		for L in locals:
			if L.node_i == av.node_i:
				var c = Vector2i(int(L.fighter.x) / (CHUNK * 8), int(L.fighter.y) / (CHUNK * 8))
				if absi(q.x - c.x) <= rx + 3 and absi(q.y - c.y) <= ry + 3:
					far = false
		if far:
			drop -= 1
			_fill_chunk(av, q, false)
			av.chunks.erase(q)

func _fill_chunk(av: AreaView, q: Vector2i, on: bool) -> void:
	var tw: int = av.area["tw"]
	var th: int = av.area["th"]
	var cells: Array = av.area["land"]["cells"]
	var x0 = q.x * CHUNK
	var y0 = q.y * CHUNK
	for k in 5:
		var tl: TileMapLayer = av.tiles[k]
		var L: PackedInt32Array = cells[k]
		for y in range(y0, mini(y0 + CHUNK, th)):
			var row = y * tw
			for x in range(x0, mini(x0 + CHUNK, tw)):
				var c = L[row + x]
				if c == 0:
					continue
				if on:
					var r = Assets.kit_cell(c)
					if not r.is_empty():
						tl.set_cell(Vector2i(x, y), r[2], r[0], r[1])
				else:
					tl.erase_cell(Vector2i(x, y))

func _release_view(n: int) -> void:
	if n < 0 or not views.has(n):
		return
	for L in locals:
		if L.node_i == n:
			return
	views[n].root.queue_free()
	views.erase(n)

func _enter(L: Local, n: int, pos: Vector2) -> void:
	var old = L.node_i
	L.node_i = n
	Game.local_nodes[L.k] = n
	print("[world] P%d enter node %d %s at %d,%d" % [L.k + 1, n, Game.planet.nodes[n]["name"], pos.x, pos.y])
	var av = _view_for(n)
	if old != n:
		_release_view(old)
	L.area = av.area
	L.fighter.area = av.area
	L.fighter.place_at(pos.x, pos.y)
	L.fighter.shots.clear()
	L.exits_armed = false
	L.cam_snap = true
	base_snap = true
	_story_world(L, av)
	_stream(av, true)
	L.banner = Game.planet.nodes[n]["name"]
	L.banner_t = 180
	L.fade = 1.0
	L.fade_dir = -1
	_remember(L)
	L.asked.clear()
	_quest_event(L, "visit", {"name": str(Game.planet.nodes[n]["name"])})
	if old != n:
		events_rt.on_enter(L, str(Game.planet.nodes[n]["key"]))
	# read the places next door ahead of time
	for ex in Game.planet.nodes[n]["exits"]:
		var key2: String = Game.planet.nodes[int(ex["to"])]["key"]
		if not preload_q.has(key2):
			preload_q.append(key2)

func _remember(L: Local) -> void:
	if L.node_i >= 0:
		Game.session_where[L.k] = {"world": Game.world_id(), "node": L.node_i, "x": snappedf(L.fighter.x, 0.1), "y": snappedf(L.fighter.y, 0.1)}
		L.fighter.where = {"key": str(Game.planet.nodes[L.node_i]["key"]), "x": snappedf(L.fighter.x, 0.1), "y": snappedf(L.fighter.y, 0.1)}

func save_all() -> void:
	for L in locals:
		_remember(L)
		Game.save_fighter(L.fighter, L.k)

func _go(L: Local, to: int, role: int) -> void:
	L.pending = {"to": to, "role": role}
	L.fade_dir = 1

## travel straight to a place and point (going to a friend from the world map)
## a door to somewhere on the same map (EARTH: every house and cave is on it): straight through, no fade, no loading
func _hop(L: Local, pos: Vector2) -> void:
	var p = Game.planet.safe_point(L.node_i, pos)
	L.fighter.place_at(p.x, p.y)
	L.fighter.shots.clear()
	L.exits_armed = false
	L.cam_snap = true
	base_snap = true
	_stream(views[L.node_i], true)
	_remember(L)

func _warp(L: Local, to: int, pos: Vector2) -> void:
	L.pending = {"to": to, "pos": pos}
	L.fade_dir = 1

# ------------------------------------------------------------------ input
## who uses what: one player - every key and every pad. Two players - with two pads each has a pad
## (and a half of the keyboard); with one pad P1 has the keyboard and P2 the pad; with none the keyboard is split.
## buttons: up down left right, a (punch), b (ki), sp (special move), tr (transform), it (item),
## nx (next special), mn (menu)
const KEYS_LEFT = {"up": [KEY_W], "down": [KEY_S], "left": [KEY_A], "right": [KEY_D], "a": [KEY_J], "b": [KEY_K],
	"sp": [KEY_L], "tr": [KEY_I], "it": [KEY_U], "nx": [KEY_O], "mn": [KEY_H, KEY_ESCAPE], "run": [KEY_SPACE]}
const KEYS_RIGHT = {"up": [KEY_UP], "down": [KEY_DOWN], "left": [KEY_LEFT], "right": [KEY_RIGHT], "a": [KEY_PERIOD, KEY_KP_1],
	"b": [KEY_SLASH, KEY_KP_2], "sp": [KEY_SEMICOLON, KEY_KP_3], "tr": [KEY_APOSTROPHE, KEY_KP_5], "it": [KEY_BRACKETLEFT, KEY_KP_6],
	"nx": [KEY_BRACKETRIGHT, KEY_KP_4], "mn": [KEY_BACKSLASH, KEY_KP_0, KEY_BACKSPACE], "run": [KEY_ENTER, KEY_KP_ENTER]}
const KEYS_SOLO_EXTRA = {"a": [KEY_Z], "b": [KEY_X], "sp": [KEY_C], "tr": [KEY_V], "it": [KEY_F], "nx": [KEY_E], "run": [KEY_SHIFT], "fly": [KEY_G]}
## (A/B/X/Y by their labels: OPTIONS - A/B BUTTONS picks the pad's layout)
func _pad() -> Dictionary:
	return {"a": Game.pad_btn("a"), "b": Game.pad_btn("b"), "sp": Game.pad_btn("x"), "tr": Game.pad_btn("y"), "it": JOY_BUTTON_LEFT_SHOULDER,
		"nx": JOY_BUTTON_RIGHT_SHOULDER, "mn": JOY_BUTTON_START}

## who uses what: one player - every key and every pad. Two players - with two pads each has a pad
## (and a half of the keyboard); with one pad P1 has the keyboard and P2 the pad; with none the keyboard is split.
func _input_for(L: Local) -> Dictionary:
	var i = locals.find(L)
	if i < test_keys.size() and not test_keys[i].is_empty():
		return test_keys[i]
	var pads = Input.get_connected_joypads()
	var sets = []
	var my_pads = _pads_of(i)
	if locals.size() == 1:
		sets = [KEYS_LEFT, KEYS_RIGHT, KEYS_SOLO_EXTRA]
	elif pads.size() == 1:
		sets = [KEYS_LEFT, KEYS_RIGHT] if i == 0 else []
	else:
		sets = [KEYS_LEFT] if i == 0 else [KEYS_RIGHT]
	var typing = chat_open
	var k = {}
	var PAD = _pad()
	for b in ["up", "down", "left", "right", "a", "b", "sp", "tr", "it", "nx", "mn", "run", "fly"]:
		var on = false
		if not typing:
			for st in sets:
				for key in st.get(b, []):
					if _keys_down.get(key, false):
						on = true
		for p in my_pads:
			if PAD.has(b) and Input.is_joy_button_pressed(p, PAD[b]):
				on = true
		k[b] = on
	for p in my_pads:
		k["up"] = k["up"] or Input.is_joy_button_pressed(p, JOY_BUTTON_DPAD_UP) or Input.get_joy_axis(p, JOY_AXIS_LEFT_Y) < -0.5
		k["down"] = k["down"] or Input.is_joy_button_pressed(p, JOY_BUTTON_DPAD_DOWN) or Input.get_joy_axis(p, JOY_AXIS_LEFT_Y) > 0.5
		k["left"] = k["left"] or Input.is_joy_button_pressed(p, JOY_BUTTON_DPAD_LEFT) or Input.get_joy_axis(p, JOY_AXIS_LEFT_X) < -0.5
		k["right"] = k["right"] or Input.is_joy_button_pressed(p, JOY_BUTTON_DPAD_RIGHT) or Input.get_joy_axis(p, JOY_AXIS_LEFT_X) > 0.5
		k["l3"] = k.get("l3", false) or Input.is_joy_button_pressed(p, JOY_BUTTON_LEFT_STICK)      # L3 clicked: sprint until you stop
		k["runt"] = k.get("runt", false) or Input.get_joy_axis(p, JOY_AXIS_TRIGGER_RIGHT) > 0.5      # R2: sprint on / off
		k["fly"] = k["fly"] or Input.get_joy_axis(p, JOY_AXIS_TRIGGER_LEFT) > 0.5      # L2: fly / land (FREE PLAY)
	if i == 0 and not typing:
		k["ok"] = _keys_down.get(KEY_ENTER, false) or _keys_down.get(KEY_KP_ENTER, false) or _keys_down.get(KEY_SPACE, false)      # (the menu: OK)
	if i == 0 and touch != null and touch.shown and not map_open:
		for b in touch.keys:
			k[b] = k.get(b, false) or touch.keys[b]
	return k

## the on-screen controls: MAP opens the map, and in the map the stick picks and A travels
func _touch_tick() -> void:
	if touch == null or not touch.shown:
		return
	var tk: Dictionary = touch.keys
	var tapped_map = touch.take_map_tap()
	var edge = func(b): return tk.get(b, false) and not touch_prev.get(b, false)
	if map_open:
		var key = -1
		if tapped_map or edge.call("b") or edge.call("mn"):
			key = KEY_TAB
		elif edge.call("left") or edge.call("up"):
			key = KEY_LEFT
		elif edge.call("right") or edge.call("down"):
			key = KEY_RIGHT
		elif edge.call("a"):
			key = KEY_ENTER
		if key != -1:
			var ev = InputEventKey.new()
			ev.keycode = key
			ev.pressed = true
			_map_input(ev)
	elif tapped_map and not _any_menu():
		map_open = true
		map_pick = 0
	touch_prev = tk.duplicate()

## the menu with the mouse (Windows / Mac): pointing chooses the row, a click is A, a right click B, a tab is clicked
var menu_hits = {}
func _menu_mouse(ev: InputEvent) -> bool:
	if not (ev is InputEventMouseButton or ev is InputEventMouseMotion):
		return false
	for i in locals.size():
		var L: Local = locals[i]
		if L.menu.is_empty() or not menu_hits.has(i):
			continue
		var h: Dictionary = menu_hits[i]
		var c: Control = h["c"]
		if not is_instance_valid(c):
			continue
		var p = c.get_local_mouse_position() / float(h.get("s", 1.0))
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_RIGHT:
			L.mouse_back = true
			return true
		for t in h["tabs"].size():
			if (h["tabs"][t] as Rect2).has_point(p) and ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
				L.menu["tab"] = t; L.menu["row"] = 0; L.menu["mode"] = ""; Sfx.play("move")
				return true
		for hr in h["rows"]:
			if (hr[0] as Rect2).has_point(p):
				if int(L.menu["row"]) != int(hr[1]):
					L.menu["row"] = int(hr[1])
				if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
					L.mouse_ok = true
				return true
	return false

var perf_on = false
## the keyboard's keys as this game has seen them pressed and let go (not Input.is_key_pressed): a phone's
## on-screen keyboard sends letters as key presses - chat's "d" stayed "held" and the hero walked right by himself
var _keys_down = {}
func _input(ev: InputEvent) -> void:
	if ev is InputEventKey and not ev.echo and not chat_open:
		_keys_down[ev.keycode] = ev.pressed
	# chat open: R3 again (or B) closes it - here, before the chat box: the box took the pad's buttons and R3 did nothing,
	# leaving you stuck typing until you sent something
	if chat_open and ev is InputEventJoypadButton and ev.pressed and (ev.button_index == JOY_BUTTON_RIGHT_STICK or ev.button_index == Game.pad_btn("b")):
		_chat_close()
		get_viewport().set_input_as_handled()

func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo and ev.keycode == KEY_F3:
		perf_on = not perf_on
	if _menu_mouse(ev):
		get_viewport().set_input_as_handled()
		return
	if ev is InputEventKey and ev.pressed and not ev.echo and ev.keycode == KEY_F8:
		debug_on = not debug_on       # the EVENT DEBUGGER: flags, numbers, timers, states, the running event
	if ev is InputEventKey and ev.pressed and not ev.echo and ev.keycode == KEY_F7 and debug_on and not locals.is_empty() and not locals[0].ev.is_empty():
		var L0: Local = locals[0]
		L0.ev["wait"] = 0; L0.ev["say"] = {}; L0.ev["choice"] = []; L0.ev["until"] = ""
		events_rt._run(L0)          # (F7: go on to the next step now)
	# Android: R3 (click the right stick) opens the chat with the phone keyboard, and R3 again closes it (Enter sends)
	if OS.has_feature("android") and ev is InputEventJoypadButton and ev.pressed and ev.button_index == JOY_BUTTON_RIGHT_STICK:
		if chat_open:
			_chat_close()
			get_viewport().set_input_as_handled()
			return
		if not _any_menu() and not map_open:
			_chat_open()
			get_viewport().set_input_as_handled()
			return
	if chat_open:
		if ev is InputEventKey and ev.pressed and ev.keycode == KEY_ESCAPE:
			_chat_close()
			get_viewport().set_input_as_handled()
		return
	if map_open and _map_input(ev):
		get_viewport().set_input_as_handled()
		return
	if ev is InputEventKey and ev.pressed and not ev.echo and ev.keycode == KEY_T and not _any_menu():
		_chat_open()
		get_viewport().set_input_as_handled()
		return
	if (ev is InputEventKey and ev.pressed and not ev.echo and (ev.keycode == KEY_TAB or ev.keycode == KEY_M)) or (ev is InputEventJoypadButton and ev.pressed and ev.button_index == JOY_BUTTON_BACK and Input.get_connected_joypads().size() >= 1 and ev.device == Input.get_connected_joypads()[0]):
		map_open = not map_open
		map_pick = 0
		return
	if ev is InputEventKey and ev.pressed and not ev.echo and ev.keycode == KEY_F10 and Game.cfg.has("dev_return"):
		get_viewport().set_input_as_handled()
		get_parent().call_deferred("back_to_tools")
		return
	if ev is InputEventKey and ev.pressed and not ev.echo and ev.keycode == KEY_F2:
		_toggle_player2()
	elif ev is InputEventJoypadButton and ev.pressed and ev.button_index == JOY_BUTTON_BACK and locals.size() == 1 and Input.get_connected_joypads().size() >= 1 and ev.device != Input.get_connected_joypads()[0]:
		_toggle_player2()

## drop in / drop out: a second player on this PC joins or leaves during the game (F2, or BACK on a second pad)
func _toggle_player2() -> void:
	if locals.size() >= 2:
		_remove_local(1)
		toasts.append(["PLAYER 2 LEFT - ONE SCREEN AGAIN", Color(0.8, 0.8, 1), 160])
	else:
		_add_local(1, int(Game.cfg.get("character2", 0)), str(Game.cfg.get("name2", "PLAYER 2")), Vector2.ZERO)
		_on_resize()

# ------------------------------------------------------------------ the tick
func _physics_process(_dt: float) -> void:
	_chat_poll()
	_touch_tick()
	if Engine.get_physics_frames() % 600 == 0:
		var nowf = Engine.get_physics_frames()
		for k in eshot_seen.keys():
			if nowf - int(eshot_seen[k]) > 600:
				eshot_seen.erase(k)
	# alone and in the menu: the world waits (with a friend online it keeps going)
	paused = _any_menu() and locals.size() == 1 and Game.remote_states.is_empty() and Game.cfg["mode"] == "solo"
	if paused:
		_menu_step(locals[0], _input_for(locals[0]))
		hud_draw.queue_redraw()
		return
	_pick_music()
	var states = []
	for L in locals:
		Game.local_levels[L.k] = L.fighter.level
		_step_local(L)
		states.append({"k": L.k, "node": L.node_i, "st": L.fighter.snapshot()})
	if Game.is_host():
		for e in Game.host_step(states):
			_on_hurt(int(e["k"]), e["atk"], e["kx"], e["ky"], str(e.get("st", "")))
	for s in states:
		var L: Local = _local_of(s["k"])
		L.send_t += 1
		if L.send_t >= 2:
			L.send_t = 0
			Game.send_state(L.k, L.node_i, s["st"], L.name)
	for n in views:
		var av: AreaView = views[n]
		_stream(av)
		for at in av.anim_layers:
			at.tick()
		_update_view(av)
		for pp in av.pops:
			pp[2] -= 1
			pp[1].y -= 0.4
		av.pops = av.pops.filter(func(pp): return pp[2] > 0)
		var akey: String = Game.planet.nodes[n]["key"]
		if Game.area_pops.has(akey):
			for pp in Game.area_pops[akey]:
				av.pops.append([str(pp[2]), Vector2(float(pp[0]), float(pp[1]) - 30), 60, Content.color(str(pp[3]))])
			Game.area_pops.erase(akey)
		if Game.area_fx.has(akey):
			for fx in Game.area_fx[akey]:
				fx[4] += 1
				if fx[4] == 1:
					Sfx.play("boom", 0.8)
					for L in locals:
						if L.node_i == n and Vector2(L.fighter.x - fx[1], L.fighter.y - fx[2]).length() < 200:
							L.shake = maxf(L.shake, 3.0)
			Game.area_fx[akey] = Game.area_fx[akey].filter(func(fx): return fx[4] < 24)
		# what foes throw: its sound when it appears (and a bump of the screen for a blast close by)
		for sh in Game.area_eshots.get(akey, []):
			var sid = "%s:%d" % [akey, int(sh[7])] if sh.size() > 7 else ""
			if sid == "" or eshot_seen.has(sid):
				continue
			eshot_seen[sid] = Engine.get_physics_frames()
			var q = Vector2(float(sh[0]), float(sh[1]))
			var close = 1e9
			for L in locals:
				if L.node_i == n:
					close = minf(close, q.distance_to(Vector2(L.fighter.x, L.fighter.y)))
			if close > 320:
				continue
			var vol = clampf(1.2 - close / 320.0, 0.3, 1.0)
			match int(sh[2]):
				1: Sfx.play("laser", vol)
				2: Sfx.play("fireball", vol * 0.8)
				3: Sfx.play("throw", vol)
				4: Sfx.play("stomp", vol)
				5: Sfx.play("beam", vol)
				6: Sfx.play("beam_charge", vol)
				13:
					Sfx.play("boom", vol * 0.9)
				14:
					Sfx.play(["punch", "hit", "throw", "laser", "stomp", "dash"][clampi(int(float(sh[5])), 0, 5)], vol)
				7:
					Sfx.play("boom", vol * 0.9)
					for L in locals:
						if L.node_i == n and q.distance_to(Vector2(L.fighter.x, L.fighter.y)) < 90:
							L.shake = maxf(L.shake, 3.0)
		for sp in av.sparks:
			sp[1] -= 1
		av.sparks = av.sparks.filter(func(sp): return sp[1] > 0)
		av.shots_view.queue_redraw()
		av.back_shots_view.queue_redraw()
		av.pops_view.queue_redraw()
	save_t += 1
	if save_t >= 600:
		save_t = 0
		save_all()
	if not preload_q.is_empty():
		Assets.area(preload_q.pop_front())
	for pid in bubbles.keys():
		bubbles[pid][1] -= 1
		if bubbles[pid][1] <= 0:
			bubbles.erase(pid)
	for c in chat_log:
		c[2] -= 1
	chat_log = chat_log.filter(func(c): return c[2] > 0)
	for t in toasts:
		t[2] -= 1
	toasts = toasts.filter(func(t): return t[2] > 0)
	if victory_t > 0:
		victory_t -= 1
	_update_cameras()
	for i in locals.size():
		var L: Local = locals[i]
		cams[i].offset = Vector2(randf_range(-L.shake, L.shake), randf_range(-L.shake, L.shake)).round()
		L.shake = L.shake * 0.85 if L.shake > 0.3 else 0.0
	if Engine.get_physics_frames() % 30 == 0:
		for L in locals:
			_remember(L)
	hud_draw.queue_redraw()

func _step_local(L: Local) -> void:
	var f: FighterSim = L.fighter
	if Game.cfg.has("dev_return") and bool(Game.cfg.get("playtest", {}).get("god", false)):
		f.hp = maxi(f.hp, f.maxhp / 2)      # PLAY-TEST: can't be beaten
	if (not L.ev.is_empty() and str(L.ev.get("until", "")) != "fight") or not L.talk.is_empty():
		f.invuln = maxi(f.invuln, 4)        # talking or in an event: foes can't hit you meanwhile (4: not the blink)
	if L.fade_dir != 0:
		L.fade = clampf(L.fade + 0.2 * L.fade_dir, 0.0, 1.0)
		if L.fade_dir > 0 and L.fade >= 1.0:
			var to: int = L.pending["to"]
			_enter(L, to, Game.planet.safe_point(to, L.pending["pos"]) if L.pending.has("pos") else Game.planet.arrival(to, int(L.pending["role"])))
			L.pending = {}
		elif L.fade_dir < 0 and L.fade <= 0.0:
			L.fade_dir = 0
	if L.banner_t > 0:
		L.banner_t -= 1
	var av: AreaView = views[L.node_i]
	var key: String = Game.planet.nodes[L.node_i]["key"]
	var snap: Array = Game.area_states.get(key, [])
	var elist = []
	for e in snap:
		elist.append({"id": int(e[0]), "x": float(e[1]), "y": float(e[2]), "alive": (int(e[9]) & 4) == 0, "big": (int(e[9]) & 16) != 0})
	_social_tick(L, elist)
	var raw = {} if (L.fade_dir > 0 or ((chat_open or map_open) and L.k == 0 and test_keys.is_empty())) else _input_for(L)
	var inp = raw
	if not L.ev.is_empty() and L.menu.is_empty():
		if events_rt.tick(L, raw):
			inp = {}
			raw = {}
	if not L.menu.is_empty():
		_menu_step(L, raw)
		inp = {}
	elif raw.get("mn", false) and not L.mprev.get("mn", false):
		_menu_open(L)
		inp = {}
	inp = _talk_step(L, raw, inp, elist)
	inp = _save_step(L, raw, inp, elist)
	if not L.near_save and L.menu.is_empty() and _pressed(L, raw, "runt"):
		L.run_toggle = not L.run_toggle
		toasts.append(["%s: SPRINT %s" % [L.name, "ON (R2 AGAIN: OFF)" if L.run_toggle else "OFF"], Color(0.7, 0.9, 1), 90])
	if L.run_toggle and not inp.is_empty():
		inp = inp.duplicate()
		inp["run"] = true
	L.mprev = raw.duplicate()
	f.can_fly = not Game.cfg.has("story")      # flying is a FREE PLAY thing (stories keep their walls)
	f.step(inp, elist)
	_bump(L)
	_step_comps(L, elist)
	if Engine.get_physics_frames() % 10 == L.k:
		_find_mood(L)
	var tag = (L.name + ": ") if locals.size() > 1 else ""
	for ev in f.events:
		match ev["type"]:
			"hit":
				if int(ev["enemy"]) == DUEL_ID:
					_duel_hit_out(L, ev)
					continue
				if int(ev["enemy"]) <= PVP_ID:
					_pvp_hit_out(L, PVP_ID - int(ev["enemy"]), ev)
					continue
				Game.hit_enemy(L.node_i, ev["enemy"], ev["dmg"], ev["kx"], ev["ky"], ev["crit"], int(ev.get("stun", 12)), ev.get("inflict", {}) if ev.get("inflict") is Dictionary else {})
				for e in elist:
					if e["id"] == ev["enemy"]:
						if int(ev["dmg"]) > 0:
							av.pops.append([str(ev["dmg"]), Vector2(e["x"], e["y"] - 30), 40, Color(1, 0.4, 0.3) if ev["crit"] else Color(1, 1, 1)])
							av.sparks.append([Vector2(e["x"], e["y"] - 14), 10, Color(1, 0.9, 0.5) if not ev["crit"] else Color(1, 0.5, 0.3)])
							Sfx.play("crit" if ev["crit"] else "hit", 0.8)
						else:
							av.pops.append(["DAZED", Vector2(e["x"], e["y"] - 30), 50, Color(1, 1, 0.6)])
						if ev["crit"]:
							L.shake = maxf(L.shake, 2.5)
			"sfx":
				Sfx.play(str(ev["name"]))
			"msg":
				toasts.append([tag + str(ev["text"]), Color(1, 0.95, 0.7), 120])
			"pop":
				av.pops.append([str(ev["text"]), Vector2(f.x, f.y - 36), 70, ev.get("color", Color(1, 1, 1))])
			"shake":
				L.shake = maxf(L.shake, float(ev["amount"]))
	# orbs: walk over one to take it (the host gives it to whoever reaches it first)
	if f.state != "down":
		for d in Game.area_drops.get(key, []):
			if Vector2(float(d[2]) - f.x, float(d[3]) - f.y).length() < 14.0 and not L.asked.has(int(d[0])):
				L.asked[int(d[0])] = true
				Game.try_pickup(L.node_i, int(d[0]), L.k)
	if f.state == "down" and not L.was_down:
		L.was_down = true
		if not Game.remote_states.is_empty() or locals.size() > 1:
			f.down_t = 600      # 10 seconds for a friend to come and help you up
			toasts.append(["%s IS DOWN! STAND NEXT TO THEM TO HELP THEM UP" % L.name, Color(1, 0.5, 0.4), 240])
	if f.state != "down":
		L.was_down = false
	_help_friends(L)
	if Engine.get_physics_frames() % 4 == L.k and L.fade_dir == 0:
		events_rt.check_area(L)
	if f.state == "down" and f.down_t <= 0:
		var back = Game.planet.arrival(L.node_i, 0) if L.node_i != Game.planet.start else Game.planet.start_point()
		var home = Game.cfg.get("home_at")      # a map that starts in a room of its own (GOKU'S HOUSE: Gohan's room)
		if home is Dictionary and str(Game.planet.nodes[L.node_i]["key"]) == str(home.get("key", "")):
			back = Vector2(float(home["x"]), float(home["y"]))
		var sp: Dictionary = f.save_spot
		var sn = -1
		for ni in Game.planet.nodes.size():
			if not sp.is_empty() and str(Game.planet.nodes[ni]["key"]) == str(sp.get("key", "")):
				sn = ni
				break
		if sn >= 0:
			# the last Capsule Corp pad you saved at this session (on this map or another)
			back = Vector2(float(sp["x"]), float(sp["y"]))
			f.revive(back.x, back.y)
			if sn != L.node_i:
				_warp(L, sn, back)
			toasts.append(["%s: KNOCKED OUT! BACK AT YOUR LAST SAVE POINT" % L.name, Color(1, 0.6, 0.5), 150])
		else:
			f.revive(back.x, back.y)
			toasts.append(["%s: KNOCKED OUT! BACK ON YOUR FEET" % L.name, Color(1, 0.6, 0.5), 150])
	# walking from one of the original areas into another inside a land: its name shows
	if L.area.has("land") and Engine.get_physics_frames() % 20 == L.k:
		for pt in L.area["land"]["parts"]:
			if pt[0].has_point(Vector2(f.x, f.y)):
				if pt[1] != "":
					L.place = pt[1]
				if pt[1] != "" and pt[1] != L.banner:
					L.banner = pt[1]
					L.banner_t = 150
				break
	# ways out
	if L.fade_dir == 0 and f.state != "down" and not (L.ev.has("fight") and bool(L.ev["fight"].get("lock", true))):
		var inside = false
		for ex in Game.planet.nodes[L.node_i]["exits"]:
			var r: Array = ex["rect"]
			if f.flying and r[0] > 16 and r[1] > 16 and r[2] < int(L.area["tw"]) * 8 - 16 and r[3] < int(L.area["th"]) * 8 - 16:
				continue      # flying: no going in through a door (the map's edges still lead on)
			if f.x >= r[0] - 2 and f.x <= r[2] + 2 and f.y >= r[1] - 2 and f.y <= r[3] + 2:
				inside = true
				if L.exits_armed and not _door_open(L, ex):
					L.exits_armed = false
					break
				if L.exits_armed:
					if ex.has("arrive") and int(ex["to"]) == L.node_i:
						_hop(L, Vector2(float(ex["arrive"][0]), float(ex["arrive"][1])))
					elif ex.has("arrive"):
						_warp(L, int(ex["to"]), Vector2(float(ex["arrive"][0]), float(ex["arrive"][1])))
					else:
						_go(L, int(ex["to"]), int(ex["to_role"]))
					break
		if not inside:
			L.exits_armed = true

## the people: stand next to one and press A to hear what they say (A goes on to their next line)
func _talk_step(L: Local, raw: Dictionary, inp: Dictionary, elist: Array) -> Dictionary:
	var f: FighterSim = L.fighter
	var people: Array = L.area.get("people", [])
	L.near_npc = -1
	if not people.is_empty() and f.state != "down" and L.menu.is_empty() and L.fade_dir == 0:
		var best = float(Content.people_cfg.get("talk_range", 26))
		for i in people.size():
			var d = Vector2(float(people[i]["x"]) - f.x, float(people[i]["y"]) - f.y).length()
			if d < best:
				best = d
				L.near_npc = i
	if not L.talk.is_empty():
		L.talk["t"] -= 1
		var ti = int(L.talk["i"])
		var far = ti >= people.size() or Vector2(float(people[ti]["x"]) - f.x, float(people[ti]["y"]) - f.y).length() > float(Content.people_cfg.get("talk_range", 26)) * 2.5
		if far or L.talk["t"] <= 0 or f.state == "down":
			L.talk = {}
	var a_now = bool(raw.get("a", false))
	if L.talk_hold:
		if a_now:
			inp = inp.duplicate()
			inp["a"] = false
			return inp
		L.talk_hold = false
	if not a_now or L.mprev.get("a", false) or L.near_npc < 0 or not L.menu.is_empty():
		return inp
	for e in elist:
		if e["alive"] and Vector2(e["x"] - f.x, e["y"] - f.y).length() < 44.0:
			return inp      # a foe right here: A punches
	if L.talk.is_empty() or int(L.talk["i"]) != L.near_npc:
		var person: Dictionary = people[L.near_npc]
		if events_rt.on_talk(L, person):
			_talked(L, str(person["name"]))
			Sfx.play("move", 0.8)
			L.talk_hold = true
			inp = inp.duplicate(); inp["a"] = false
			return inp
		if str(person.get("shop", "")) != "":
			_talked(L, str(person["name"]))
			_open_shop(L, str(person["shop"]))
			L.talk_hold = true
			inp = inp.duplicate(); inp["a"] = false
			return inp
	var lines: Array = people[L.near_npc]["lines"]
	if not L.talk.is_empty() and int(L.talk["i"]) == L.near_npc:
		L.talk["line"] += 1
		L.talk["t"] = 600
		if int(L.talk["line"]) >= lines.size():
			L.talk = {}
	else:
		L.talk = {"i": L.near_npc, "line": 0, "t": 600}
		_talked(L, str(people[L.near_npc]["name"]))
	Sfx.play("move", 0.8)
	L.talk_hold = true
	inp = inp.duplicate()
	inp["a"] = false
	return inp

## a Capsule Corp save point: stand on the pad and press A - the game is saved and your health and ki fill up
## (Android port; the pads were only scenery before)
func _save_step(L: Local, raw: Dictionary, inp: Dictionary, elist: Array) -> Dictionary:
	var f: FighterSim = L.fighter
	var saves: Array = L.area.get("saves", [])
	var near = false
	var on_pad = false
	if not saves.is_empty() and f.state != "down" and L.menu.is_empty() and L.fade_dir == 0 and L.ev.is_empty():
		for p in saves:
			# the whole pad counts: 8 x 7 cells round its middle tile (3 to the left and up, 4 right, 3 down)
			var pad = Rect2((p as Vector2) + Vector2(-24, -24), Vector2(64, 56))
			var at = Vector2(f.x, f.y)
			if pad.grow(6.0).has_point(at):
				near = true
				on_pad = on_pad or pad.has_point(at)
				break
	if near and not L.near_save:
		toasts.append(["CAPSULE CORP SAVE POINT - A: SAVE AND HEAL   R2: PVP MODE", Color(0.6, 0.85, 1), 150])
	L.near_save = near
	if L.pvp_ask:
		if not near or _pressed(L, raw, "b"):
			L.pvp_ask = false
			toasts.append(["PVP MODE: NOTHING CHANGED", Color(0.8, 0.85, 1), 120])
		elif _pressed(L, raw, "a"):
			L.pvp_ask = false
			f.pvp = not f.pvp
			toasts.append(["%s: PVP MODE %s" % [L.name, "ON - OTHER PVP PLAYERS CAN HIT YOU, AND YOU THEM" if f.pvp else "OFF - NO PLAYER CAN HURT YOU"], Color(1, 0.6, 0.4) if f.pvp else Color(0.6, 1, 0.7), 240])
			Sfx.play("levelup" if f.pvp else "menu", 0.7)
			L.talk_hold = true
		inp = inp.duplicate()
		inp["a"] = false; inp["b"] = false
		return inp
	if near and _pressed(L, raw, "runt"):
		L.pvp_ask = true
		toasts.append(["%s PVP MODE?   A: YES   B: NO" % ("LEAVE" if f.pvp else "ENTER"), Color(1, 0.85, 0.4), 600])
		Sfx.play("menu", 0.7)
		inp = inp.duplicate()
		inp["run"] = false
		return inp
	if not near or not inp.get("a", false) or not _pressed(L, raw, "a"):
		return inp
	for e in elist:
		if not on_pad and e["alive"] and Vector2(e["x"] - f.x, e["y"] - f.y).length() < 44.0:
			return inp      # a foe right here and you are not on the pad itself: A punches (the farm's animals no longer stop a save)
	f.hp = f.maxhp
	f.ep = f.maxep
	f.save_spot = {"key": str(Game.planet.nodes[L.node_i]["key"]), "x": f.x, "y": f.y}      # knocked out: back here
	save_all()
	print("[world] game saved at a save point: ", L.name, " hp ", f.hp, "/", f.maxhp, " ki ", f.ep, "/", f.maxep)
	toasts.append(["%s: GAME SAVED - HEALTH AND KI RESTORED" % L.name, Color(0.6, 1, 0.7), 180])
	Sfx.play("levelup", 0.6)
	L.talk_hold = true          # (A held on must not punch)
	inp = inp.duplicate()
	inp["a"] = false
	return inp

## people stand their ground: you walk around them, not through them (and a duel's two fighters don't merge)
func _bump(L: Local) -> void:
	var f: FighterSim = L.fighter
	if f.state == "down" or f.flying:
		return
	var others = []
	for p in L.area.get("people", []):
		others.append([Vector2(float(p["x"]), float(p["y"])), 9.0])
	if not L.duel.is_empty():
		var q = _pos_of_pid(int(L.duel["with"]))
		if q != null:
			others.append([Vector2(q["x"], q["y"]), 12.0])
	var me = Vector2(f.x, f.y)
	for o in others:
		var d: Vector2 = me - o[0]
		var r: float = o[1]
		if d.length() < r and absf(d.y) < r:
			var push = (d.normalized() if d.length() > 0.1 else Vector2(1, 0)) * (r - d.length())
			var to = me + push
			if Assets.walkable(L.area, to.x, to.y):
				me = to
	f.x = me.x
	f.y = me.y

## talking with someone: a mission that asks for it is done, and the missions they give open up
func _talked(L: Local, who: String) -> void:
	var f: FighterSim = L.fighter
	_quest_event(L, "talk", {"name": who})
	for q in Content.quests:
		var id = str(q["id"])
		if str(q.get("from", "")) == who and not f.quests.has(id) and not f.qdone.has(id) and f.level >= int(q.get("level", 1)):
			f.quests[id] = 0
			toasts.append(["NEW MISSION FROM %s: %s" % [who, q["name"]], Color(0.6, 1, 0.7), 240])
			toasts.append([str(q.get("info", "")), Color(0.85, 0.95, 0.85), 240])
			Sfx.play("levelup", 0.5)

func _update_people(av: AreaView) -> void:
	var people: Array = av.area.get("people", [])
	if not av.npc_done:
		av.npc_done = true
		for p in people:
			var v = ActorView.new()
			v.set_sprite_set(Assets.sprite_set(int(p["set"])))
			v.position = Vector2(roundf(float(p["x"])), roundf(float(p["y"])))
			v.show_frame(0, 0, 0)
			av.ents.add_child(v)
			av.npc_views.append(v)
	while av.npc_views.size() < people.size():
		var p2: Dictionary = people[av.npc_views.size()]
		var v2 = ActorView.new()
		v2.set_sprite_set(Assets.sprite_set(int(p2["set"])))
		v2.show_frame(0, 0, 0)
		av.ents.add_child(v2)
		av.npc_views.append(v2)
	for i in av.npc_views.size():
		var v: ActorView = av.npc_views[i]
		if i >= people.size():
			v.visible = false
			continue
		var pd: Dictionary = people[i]
		v.visible = not pd.get("hidden", false)
		var want = Vector2(roundf(float(pd["x"])), roundf(float(pd["y"])))
		if v.position != want:
			v.position = want
		if pd.has("cut_dir") or pd.has("cut_pose") or pd.get("cut_walk", false) or pd.has("emote"):
			# a story scene moves this person: its own facing, walk, pose and emotion
			var cd = int(pd.get("cut_dir", 0))
			var an = 0
			var fr = 0
			var now = Engine.get_physics_frames()
			if pd.get("cut_walk", false):
				an = 1; fr = (now / 8) % maxi(1, v.frames_of(1, cd).size())
			elif pd.get("cut_pose", []).size() == 3:
				var cpz: Array = pd["cut_pose"]
				an = int(cpz[0])
				var nfr = maxi(1, v.frames_of(an, cd).size())
				var k = (now - int(cpz[2])) / 6
				fr = k % nfr if bool(cpz[1]) else mini(k, nfr - 1)
			var bub2 = ""
			if pd.has("emote"):
				var em: Array = pd["emote"]
				if now < int(em[1]):
					bub2 = str(em[0])
				else:
					pd.erase("emote")
			v.label = ""
			v.bubble = bub2
			v.show_frame(an, cd, fr)
			continue
		var best = 70.0
		var who: Local = null
		for L in locals:
			if L.node_i != av.node_i:
				continue
			var d = Vector2(L.fighter.x, L.fighter.y).distance_to(v.position)
			if not L.talk.is_empty() and int(L.talk["i"]) == i:
				d = 0.0
			if d < best:
				best = d
				who = L
		var dir = 0
		var lab = ""
		var bub = ""
		if who != null:
			var dv = Vector2(who.fighter.x, who.fighter.y) - v.position
			if absf(dv.x) > absf(dv.y):
				dir = 3 if dv.x > 0 else 2
			else:
				dir = 0 if dv.y > 0 else 1
			if who.near_npc == i:
				lab = str(people[i]["name"])
				if who.talk.is_empty():
					bub = "A: TALK"
		v.label_color = Color(1, 0.95, 0.7)
		if v.dir != dir or v.label != lab or v.bubble != bub:
			v.label = lab
			v.bubble = bub
			v.show_frame(0, dir, 0)
			v.queue_redraw()

## what the person you talk with says, in a box at the bottom of your part of the screen
func _draw_talk(c: Control, L: Local, i: int) -> void:
	if not L.ev.is_empty():
		events_rt.draw(c, L, i)
		return
	if L.talk.is_empty():
		return
	var people: Array = L.area.get("people", [])
	var ti = int(L.talk["i"])
	if ti >= people.size():
		return
	var p: Dictionary = people[ti]
	var lines: Array = p["lines"]
	if lines.is_empty():
		return
	var ln = lines[clampi(int(L.talk["line"]), 0, lines.size() - 1)]
	var who = str(p["name"])
	if ln is Array:
		# (a line the DEV TOOLS PERSON tool wrote: [face, who, text])
		if ln.size() >= 2 and str(ln[ln.size() - 2]) != "":
			who = str(ln[ln.size() - 2])
		ln = ln.back() if not ln.is_empty() else ""
	var t = str(ln).replace("%s", L.name)
	var vs = c.get_viewport_rect().size
	var font = ThemeDB.fallback_font
	var w = minf(320.0, vs.x - 16) if locals.size() == 1 else minf(232.0, vs.x / 2 - 8)
	var x = (vs.x - w) / 2.0 if locals.size() == 1 else (4.0 if i == 0 else vs.x - w - 4)
	var h = 44.0
	var y = vs.y - h - 8 - 11 * toasts.size()
	c.draw_rect(Rect2(x, y, w, h), Color(0.03, 0.04, 0.12, 0.88))
	c.draw_rect(Rect2(x, y, w, h), Color(0.95, 0.85, 0.5, 0.9), false, 1.0)
	_ds(c, font, Vector2(x + 6, y + 10), who, HORIZONTAL_ALIGNMENT_LEFT, w - 12, 8, Color(1, 0.85, 0.35))
	c.draw_multiline_string(font, Vector2(x + 6, y + 20), t, HORIZONTAL_ALIGNMENT_LEFT, w - 12, 8, 3, Color(1, 1, 1))
	var more = "A: MORE" if int(L.talk["line"]) < lines.size() - 1 else "A: BYE"
	_ds(c, font, Vector2(x + 6, y + h - 3), more, HORIZONTAL_ALIGNMENT_RIGHT, w - 12, 6, Color(0.7, 0.8, 1))

func _update_view(av: AreaView) -> void:
	_update_people(av)
	var key: String = Game.planet.nodes[av.node_i]["key"]
	var snap: Array = Game.area_states.get(key, [])
	# the local fighters here
	var mine = {}
	for L in locals:
		if L.node_i != av.node_i:
			continue
		mine[L.k] = true
		var v: ActorView = av.local_views.get(L.k)
		if v == null:
			v = ActorView.new()
			v.set_sprite_set(Assets.sprite_set(L.fighter.set_id))
			av.ents.add_child(v)
			av.local_views[L.k] = v
		var f: FighterSim = L.fighter
		var shown = f.shape_set if f.shape_set >= 0 else f.set_id
		if v.set_id != shown:
			v.set_id = shown
			v.set_sprite_set(Assets.sprite_set(shown))
		var au = f.aura()
		v.aura = Color.hex(au) if au != 0 else Color(0, 0, 0, 0)
		v.tint = f.tint()
		v.size_scale = f.size_scale()
		v.label = ("P%d" % (L.k + 1)) if locals.size() > 1 else ""
		if f.state == "down" and (locals.size() > 1 or not Game.remote_states.is_empty()):
			v.label = "DOWN %d" % ceili(f.down_t / 60.0)
		v.label_color = Color(1, 0.9, 0.4) if L.k == 0 else Color(0.5, 1, 0.6)
		v.hero = true
		v.position = Vector2(roundf(f.x) + f.draw_dx, roundf(f.y))
		v.z_index = 110 if f.flying else 0      # flying: above the trees and roofs
		if f.flying and f.dir >= 2 and not Assets.has_side_fly(f.set_id):
			v.show_frame(Rules.A_WALK, f.dir, f.frame % maxi(1, v.frames_of(Rules.A_WALK, f.dir).size()))
		else:
			v.show_frame(f.anim, f.dir, f.frame)
		v.concealed = f.invuln > 0 and (f.invuln / 3) % 2 == 0 and f.state != "down" and f.state != "transform" and f.state != "skill"
		var b = bubbles.get(Game.pid_of(Game.my_id(), L.k))
		v.bubble = b[0] if b != null else ""
		v.queue_redraw()
	for k in av.local_views.keys():
		if not mine.has(k):
			av.local_views[k].queue_free()
			av.local_views.erase(k)
	# the enemies (the host's picture)
	var seen = {}
	for e in snap:
		var id = int(e[0])
		seen[id] = true
		var v: ActorView = av.enemy_views.get(id)
		var target = Vector2(float(e[1]), float(e[2]))
		if v == null:
			v = ActorView.new()
			v.set_sprite_set(Assets.sprite_set(int(e[6])))
			av.ents.add_child(v)
			av.enemy_views[id] = v
			v.position = target
		v.position = target if Game.is_host() else v.position.lerp(target, 0.5)
		var flags = int(e[9])
		v.show_frame(int(e[3]), int(e[4]), int(e[5]))
		v.tint = Color(1.0, 0.85, 0.35) if flags & 3 else Color(1, 1, 1)
		v.size_scale = 1.0      # elites and bosses keep the game's own size (scaled-up sprites looked blurry); gold tint + name show them
		v.flash = (flags & 8) != 0
		if flags & 4 and not av.spawn_seen.has(-id - 1):
			av.spawn_seen[-id - 1] = 1
			Sfx.play("die", 0.7)
		elif not flags & 4:
			av.spawn_seen.erase(-id - 1)
		if flags & 32:
			av.spawn_seen[id] = int(av.spawn_seen.get(id, 0)) + 1
			v.modulate.a = clampf(av.spawn_seen[id] / 45.0, 0.1, 0.9)
		else:
			av.spawn_seen.erase(id)
			v.modulate.a = 0.5 if flags & 4 else 1.0
		v.label = str(e[10]) if flags & 2 else ""
		v.hp_frac = float(e[7]) / maxf(1.0, float(e[8]))
		v.queue_redraw()
	for id in av.enemy_views.keys():
		if not seen.has(id):
			av.enemy_views[id].queue_free()
			av.enemy_views.erase(id)
	# partners online here
	var here = {}
	for pid in Game.remote_states:
		var st: Dictionary = Game.remote_states[pid]
		if int(st.get("node", -1)) != av.node_i:
			continue
		here[pid] = true
		var v: ActorView = av.remote_views.get(pid)
		if v == null:
			v = ActorView.new()
			v.set_sprite_set(Assets.sprite_set(Assets.character_set(int(st["ch"]))))
			v.hero = true
			v.label_color = Color(0.6, 0.9, 1)
			av.ents.add_child(v)
			av.remote_views[pid] = v
			v.position = Vector2(st["x"], st["y"])
		var rs = int(st.get("set", -1))
		if rs > 0 and v.set_id != rs:
			v.set_id = rs
			v.set_sprite_set(Assets.sprite_set(rs))
		var rau = int(st.get("aura", 0))
		v.aura = Color.hex(rau) if rau != 0 else Color(0, 0, 0, 0)
		v.tint = Color.hex(int(st.get("tint", -1))) if st.has("tint") else Color(1, 1, 1)
		v.size_scale = float(st.get("scale", 1.0))
		v.label = "%s LV%d" % [str(st.get("name", "P2")), int(st.get("lvl", 1))]
		if st.get("down", false):
			v.label = str(st.get("name", "P2")) + " - DOWN! HELP!"
		var b = bubbles.get(pid)
		v.bubble = b[0] if b != null else ""
		v.hp_frac = float(st.get("hp", 1)) / maxf(1.0, float(st.get("maxhp", 1)))
		v.position = v.position.lerp(Vector2(float(st["x"]) + float(st.get("dx", 0)), st["y"]), 0.5)
		v.z_index = 110 if st.get("fly", false) else 0
		if st.get("fly", false) and int(st["dir"]) >= 2 and not Assets.has_side_fly(int(st.get("set", 0))):
			v.show_frame(Rules.A_WALK, int(st["dir"]), int(st["frame"]) % maxi(1, v.frames_of(Rules.A_WALK, int(st["dir"])).size()))
		else:
			v.show_frame(int(st["anim"]), int(st["dir"]), int(st["frame"]))
		v.queue_redraw()
	for pid in av.remote_views.keys():
		if not here.has(pid):
			av.remote_views[pid].queue_free()
			av.remote_views.erase(pid)

# ------------------------------------------------------------------ the cameras and the split
## the camera point for a view of size `half` (half extents) inside an area: the map fills the view;
## a map smaller than the view sits in the middle
func _clamp_point(a: Dictionary, p: Vector2, half: Vector2) -> Vector2:
	var w = float(a["w"]); var h = float(a["h"])
	var q = p
	q.x = w / 2.0 if w <= half.x * 2.0 else clampf(p.x, half.x, w - half.x)
	# the top of the screen holds the HUD: the camera may look 48 px past the top of the map so nobody stands under it
	q.y = h / 2.0 if h + 48.0 <= half.y * 2.0 else clampf(p.y, half.y - 48.0, h - half.y)
	return q

func _eye(L: Local) -> Vector2:
	return Vector2(L.fighter.x, L.fighter.y - 12)

func _update_cameras() -> void:
	var vs = Vector2(svs[0].size)
	var centre = vs / 2.0
	if locals.size() == 1:
		var L: Local = locals[0]
		var t = _clamp_point(L.area, _eye(L), vs / 2.0)
		var zt = 1.0
		if not L.cut_cam.is_empty():
			var cc: Dictionary = L.cut_cam
			cc["t"] = mini(int(cc["t"]) + 1, int(cc["n"]))
			var k = float(cc["t"]) / float(cc["n"])
			k = k * k * (3.0 - 2.0 * k)
			zt = float(cc.get("zoom", 1.0))
			t = _clamp_point(L.area, (cc["from"] as Vector2).lerp(cc["to"], k), vs / 2.0 / zt)
			L.cam = t
		else:
			L.cam = t if L.cam_snap else L.cam.lerp(t, 0.2)
		L.cam_snap = false
		cams[0].zoom = cams[0].zoom.lerp(Vector2.ONE * zt, 0.15) if absf(cams[0].zoom.x - zt) > 0.005 else Vector2.ONE * zt
		cams[0].position = views[L.node_i].offset + L.cam
		split_now = false
		_shader(false, Vector2(1, 0), centre, L.fade, L.fade)
		return
	var A: Local = locals[0]
	var B: Local = locals[1]
	var pa = _eye(A)
	var pb = _eye(B)
	if A.node_i == B.node_i:
		# one place: one picture while both fit, then a split along the line between them (it turns as they move)
		var d = pb - pa
		var M = (pa + pb) / 2.0
		var dir = d.normalized() if d.length() > 0.5 else split_dir
		var E = minf(vs.x / 2.0 / maxf(absf(dir.x), 0.0001), vs.y / 2.0 / maxf(absf(dir.y), 0.0001))
		var R = E * 0.5
		var Mc = _clamp_point(A.area, M, vs / 2.0)
		var off = (M - Mc).clamp(-vs * 0.22, vs * 0.22)
		var base = M - off
		base_cam = base if (base_snap or A.cam_snap or B.cam_snap) else base_cam.lerp(base, 0.25)
		base_snap = false
		A.cam_snap = false
		B.cam_snap = false
		var sm = base_cam - base      # the smoothing lag, shared by both views so the split stays true
		var o = views[A.node_i].offset
		if d.length() / 2.0 <= R:
			A.cam = base_cam; B.cam = base_cam
			split_now = false
			_shader(false, dir, centre, maxf(A.fade, B.fade), maxf(A.fade, B.fade))
		else:
			var lp = centre + off - sm
			A.cam = _edge_clamp(A, base_cam + (pa - M) + dir * R, pa, -dir, lp, vs)
			B.cam = _edge_clamp(B, base_cam + (pb - M) - dir * R, pb, dir, lp, vs)
			split_now = true
			_shader(true, dir, lp, A.fade, B.fade)
		split_dir = dir
		cams[0].position = o + A.cam
		cams[1].position = o + B.cam
	else:
		# different places: left and right halves, each player in the middle of theirs
		var half = Vector2(vs.x / 4.0, vs.y / 2.0)
		var ta = _clamp_point(A.area, pa, half) + Vector2(vs.x / 4.0, 0)
		var tb = _clamp_point(B.area, pb, half) - Vector2(vs.x / 4.0, 0)
		A.cam = ta if A.cam_snap else A.cam.lerp(ta, 0.2)
		B.cam = tb if B.cam_snap else B.cam.lerp(tb, 0.2)
		A.cam_snap = false
		B.cam_snap = false
		base_snap = true
		split_now = true
		split_dir = Vector2(1, 0)
		cams[0].position = views[A.node_i].offset + A.cam
		cams[1].position = views[B.node_i].offset + B.cam
		_shader(true, Vector2(1, 0), centre, A.fade, B.fade)

## a split view keeps to the map as far as it can while its player stays well on their own side of the line
func _edge_clamp(L: Local, cam: Vector2, eye: Vector2, side: Vector2, lp: Vector2, vs: Vector2) -> Vector2:
	var cc = _clamp_point(L.area, cam, vs / 2.0)
	if cc.is_equal_approx(cam):
		return cam
	var lo = 0.0
	var hi = 1.0
	if _view_ok(cam + (cc - cam), eye, side, lp, vs):
		return cc
	for i in 12:
		var mid = (lo + hi) / 2.0
		if _view_ok(cam + (cc - cam) * mid, eye, side, lp, vs):
			lo = mid
		else:
			hi = mid
	return cam + (cc - cam) * lo

func _view_ok(cam: Vector2, eye: Vector2, side: Vector2, lp: Vector2, vs: Vector2) -> bool:
	var sp = vs / 2.0 + eye - cam
	return (sp - lp).dot(side) >= 28.0 and sp.x >= 24.0 and sp.x <= vs.x - 24.0 and sp.y >= 70.0 and sp.y <= vs.y - 20.0

func _shader(split: bool, dir: Vector2, lp: Vector2, f1: float, f2: float) -> void:
	line_px = lp
	mat.set_shader_parameter("split", split)
	mat.set_shader_parameter("dir", dir)
	mat.set_shader_parameter("line_px", lp)
	mat.set_shader_parameter("fade1", f1)
	mat.set_shader_parameter("fade2", f2 if split else f1)

## where a player's own part of the screen is (for their banner)
## where a fighter is on the screen (the light round them in the dark, blind)
func _light_centre(i: int) -> Vector2:
	if locals.size() == 1 and i == 0 and not cams.is_empty():
		var L: Local = locals[0]
		var vs = Vector2(svs[0].size)
		var q = (_eye(L) - L.cam) * cams[0].zoom.x + vs / 2.0
		var hs = hud_draw.get_viewport_rect().size
		return q * (hs / vs)
	return _side_centre(i)

var _dark_tex: Texture2D
## the screen dark but a soft round light of radius r at cen
func _draw_dark(c: Control, cen: Vector2, r: float, col: Color, vs: Vector2) -> void:
	if _dark_tex == null:
		var img = Image.create_empty(128, 128, false, Image.FORMAT_RGBA8)
		for y in 128:
			for x in 128:
				var d = Vector2(x - 63.5, y - 63.5).length() / 64.0
				var a = clampf((d - 0.72) / 0.28, 0.0, 1.0)
				img.set_pixel(x, y, Color(1, 1, 1, a * a * (3.0 - 2.0 * a)))
		_dark_tex = ImageTexture.create_from_image(img)
	if locals.size() == 1 and not cams.is_empty():
		r *= cams[0].zoom.x       # (a story camera's zoom: the light grows with it)
	var R = r * 1.3
	var box = Rect2(cen - Vector2(R, R), Vector2(R, R) * 2.0)
	c.draw_texture_rect(_dark_tex, box, false, col)
	var full = Rect2(Vector2.ZERO, vs)
	# the four sides round the light's box
	c.draw_rect(Rect2(0, 0, vs.x, maxf(0, box.position.y)).intersection(full), col)
	c.draw_rect(Rect2(0, box.end.y, vs.x, maxf(0, vs.y - box.end.y)).intersection(full), col)
	c.draw_rect(Rect2(0, box.position.y, maxf(0, box.position.x), box.size.y).intersection(full), col)
	c.draw_rect(Rect2(box.end.x, box.position.y, maxf(0, vs.x - box.end.x), box.size.y).intersection(full), col)

func _side_centre(i: int) -> Vector2:
	var vs = get_viewport().get_visible_rect().size
	if not split_now:
		return vs / 2.0
	var s = -1.0 if i == 0 else 1.0
	return line_px + split_dir * s * minf(vs.x, vs.y) * 0.45

# ------------------------------------------------------------------ events from the game
func _on_exp(k: int, lv: int, mult: float, info: Dictionary = {}) -> void:
	var L: Local = _local_of(k)
	if L == null:
		return
	# about 18 ordinary foes of your own level make a level; stronger ones give more, much weaker almost none
	var f: FighterSim = L.fighter
	L.kills += 1
	var Lv = clampi(f.level, 1, levels.size() - 1)
	var need = float(int(levels[Lv]) - int(levels[Lv - 1]))
	var diff = clampf(1.0 + 0.15 * (lv - f.level), 0.1, 2.0)
	if lv <= f.level - 5:
		diff = 0.05
	var n = maxi(1, roundi(need / 18.0 * mult * diff * f.exp_mult()))
	var up = f.add_exp(n, levels)
	_quest_event(L, "kill", info)
	if info.has("type"):
		events_rt.on_defeat(L, int(info["type"]))
	if not info.get("party", false) and not L.party.is_empty():
		for pid in L.party:
			if _node_of_pid(pid) != L.node_i:
				Game.send_social(pid, _my_pid(L), L.name, "party_exp", {"lv": lv, "mult": mult * float(Content.social_cfg.get("party", {}).get("share", 0.5))})
	if views.has(L.node_i):
		views[L.node_i].pops.append(["+%d EXP" % n, Vector2(f.x, f.y - 34), 70, Color(0.6, 1, 0.6)])
	if up:
		toasts.append(["%s LEVEL UP! LEVEL %d" % [f.name, f.level], Color(1, 1, 0.4), 180])
		Sfx.play("levelup")
		_quest_event(L, "level", {})
		for sk in f.skills:
			if int(sk.get("level", 1)) == f.level:
				toasts.append(["NEW SPECIAL MOVE: %s  (MENU - SPECIALS)" % sk["name"], Color(0.6, 1, 1), 300])
		for fm in f.forms:
			if int(fm.get("level", 1)) == f.level and f.form_open(fm):
				toasts.append(["NEW TRANSFORMATION: %s  (TRANSFORM BUTTON)" % fm["name"], Color(1, 0.85, 0.3), 300])
		Game.save_fighter(f, k)

func _on_hurt(k: int, atk: float, kx: float, ky: float, st: String = "") -> void:
	var L: Local = _local_of(k)
	if L == null:
		return
	var f: FighterSim = L.fighter
	if f.invuln > 0 or f.state == "down":
		return
	var d = Rules.taken_damage(atk, f.eff_end(), f.rng)
	Sfx.play("hurt", 0.9)
	f.take_hit(d, kx, ky)
	if st != "" and f.state != "down":
		f.add_state(st)        # (a foe kind's "inflict": poison, slow, blind...)
	L.shake = 4.0
	for p in _pads_of(locals.find(L)):
		Input.start_joy_vibration(p, 0.4, 0.6, 0.18)
	if views.has(L.node_i):
		views[L.node_i].pops.append([str(d), Vector2(f.x, f.y - 30), 40, Color(1, 0.3, 0.3)])

func _pads_of(i: int) -> Array:
	var pads = Input.get_connected_joypads()
	if locals.size() == 1:
		return pads
	if pads.size() >= 2:
		return [pads[i]] if i < 2 else []
	if pads.size() == 1:
		return [] if i == 0 else [pads[0]]
	return []

func _on_item(k: int, kind: String, n: int) -> void:
	var L: Local = _local_of(k)
	if L == null:
		return
	var f: FighterSim = L.fighter
	var txt = ""
	var col = Color(1, 1, 1)
	match kind:
		"orb_hp":
			var h = maxi(1, roundi(f.maxhp * 0.35)); f.hp = mini(f.maxhp, f.hp + h); txt = "+%d HP" % h; col = Color(0.4, 1, 0.5)
			Sfx.play("pickup")
		"orb_ep":
			var e = maxi(1, roundi(f.maxep * 0.6)); f.ep = mini(f.maxep, f.ep + e); txt = "+%d EP" % e; col = Color(0.5, 0.8, 1)
			Sfx.play("pickup")
		"zeni":
			f.zeni += n; txt = "+%d ZENI" % n; col = Color(1, 0.9, 0.4)
			Sfx.play("zeni")
		_:
			var it = Content.item(kind)
			if it.is_empty():
				return
			if f.add_item(kind, n) > 0:
				txt = "GOT %s" % it["name"]
				col = Content.color(it.get("color", "ffffff"))
				toasts.append([("%s GOT " % L.name if locals.size() > 1 else "GOT ") + str(it["name"]) + "  (ITEM BUTTON TO USE)", col, 160])
			else:
				txt = "%s: BAG FULL" % it["name"]
			Sfx.play("item")
	if views.has(L.node_i):
		views[L.node_i].pops.append([txt, Vector2(f.x, f.y - 36), 70, col])

func _on_gift(k: int, kind: String, n: int, from: String) -> void:
	var L: Local = _local_of(k)
	if L == null:
		return
	var f: FighterSim = L.fighter
	var nm = "%d ZENI" % n if kind == "zeni" else ("%s x%d" % [Content.item(kind).get("name", kind), n])
	if kind == "zeni":
		f.zeni += n
	else:
		var got = f.add_item(kind, n)
		if got < n:
			nm += " (%d DID NOT FIT)" % (n - got)
	toasts.append(["%s GAVE %s %s" % [from, L.name, nm], Color(0.6, 1, 0.8), 240])
	Sfx.play("item")
	Game.save_fighter(f, k)

# ------------------------------------------------------------------ helping a downed friend up
var help_show = {}       # player id -> [node, x, y, 0..1] (a ring over the friend being helped)

func _help_friends(L: Local) -> void:
	var f: FighterSim = L.fighter
	if f.state == "down":
		return
	var near = {}
	var cands = []
	for pid in Game.remote_states:
		var st: Dictionary = Game.remote_states[pid]
		if st.get("down", false) and int(st.get("node", -1)) == L.node_i:
			cands.append([int(pid), Vector2(float(st["x"]), float(st["y"])), str(st.get("name", "?"))])
	for o in locals:
		if o != L and o.node_i == L.node_i and o.fighter.state == "down":
			cands.append([Game.pid_of(Game.my_id(), o.k), Vector2(o.fighter.x, o.fighter.y), o.name])
	for c in cands:
		if Vector2(f.x, f.y).distance_to(c[1]) < 34.0:
			near[c[0]] = true
			L.helping[c[0]] = int(L.helping.get(c[0], 0)) + 1
			help_show[c[0]] = [L.node_i, c[1].x, c[1].y, L.helping[c[0]] / 90.0]
			if L.helping[c[0]] >= 90:
				Game.revive(c[0], L.name)
				toasts.append(["YOU HELPED %s UP!" % c[2], Color(0.6, 1, 0.7), 160])
				Sfx.play("heal")
				L.helping.erase(c[0])
				help_show.erase(c[0])
	# stepping away (or being knocked back) only slowly loses the progress
	for pid in L.helping.keys():
		if not near.has(pid):
			L.helping[pid] = int(L.helping[pid]) - 1
			if L.helping[pid] <= 0:
				L.helping.erase(pid)
				help_show.erase(pid)
			elif help_show.has(pid):
				help_show[pid][3] = L.helping[pid] / 90.0

func _on_revived(k: int, from: String) -> void:
	var L: Local = _local_of(k)
	if L == null or L.fighter.state != "down":
		return
	L.fighter.revive_here()
	toasts.append(["%s HELPED %s UP!" % [from, L.name], Color(0.6, 1, 0.7), 200])
	Sfx.play("heal")

# ------------------------------------------------------------------ missions
func _quest_event(L: Local, kind: String, info: Dictionary) -> void:
	var f: FighterSim = L.fighter
	for q in Content.quests:
		var id = str(q["id"])
		if f.level < int(q.get("level", 1)) or f.qdone.has(id):
			continue
		if q.has("from") and not f.quests.has(id):
			continue      # someone gives this one: talk to them first
		var t = str(q.get("type", "kill"))
		var cnt = int(q.get("count", 1))
		var before = int(f.quests.get(id, 0))
		var now = before
		match t:
			"kill":
				if kind != "kill":
					continue
				var tg = str(q.get("target", "any"))
				var ok = tg == "any" or (tg == "elite" and info.get("elite", false)) or (tg == "boss" and info.get("boss", false)) \
					or (tg == "worldboss" and info.get("wboss", false)) or tg == str(info.get("group", "")) or (tg.is_valid_int() and int(tg) == int(info.get("type", -1)))
				if not ok:
					continue
				now = before + 1
			"visit":
				if kind != "visit" or str(info.get("name", "")).find(str(q.get("where", "?"))) < 0:
					continue
				now = cnt
			"level":
				now = f.level
				cnt = int(q.get("count", 10))
			"talk":
				if kind != "talk" or str(info.get("name", "")) != str(q.get("who", "?")):
					continue
				now = cnt
		if now == before:
			continue
		f.quests[id] = now
		if now >= cnt:
			_quest_done(L, q)
		elif t == "kill" and (now % maxi(1, cnt / 5) == 0 or cnt - now <= 2):
			toasts.append(["%s  %d / %d" % [q["name"], now, cnt], Color(0.8, 0.9, 1), 90])

func _quest_done(L: Local, q: Dictionary) -> void:
	var f: FighterSim = L.fighter
	var id = str(q["id"])
	var rw: Dictionary = q.get("reward", {})
	var got = []
	if rw.has("zeni"):
		f.zeni += int(rw["zeni"])
		got.append("%d ZENI" % int(rw["zeni"]))
	if rw.has("exp"):
		var Lv = clampi(f.level, 1, levels.size() - 1)
		var n = roundi((int(levels[Lv]) - int(levels[Lv - 1])) * float(rw["exp"]))
		f.add_exp(maxi(1, n), levels)
		got.append("%d EXP" % n)
	for it in rw.get("items", {}):
		if f.add_item(str(it), int(rw["items"][it])) > 0:
			got.append(str(Content.item(str(it)).get("name", it)))
	for fid in rw.get("forms", []):
		if f.unlock_form(str(fid)):
			var fm = Content.form_by_id(str(fid))
			got.append(str(fm.get("name", fid)))
			toasts.append(["NEW TRANSFORMATION: %s  (TRANSFORM BUTTON%s)" % [fm.get("name", fid), "" if f.level >= int(fm.get("level", 1)) else ", FROM LEVEL %d" % int(fm.get("level", 1))], Color(1, 0.85, 0.3), 320])
	for sid in rw.get("states", []):
		if f.add_state(str(sid)):
			got.append(str(Content.state(str(sid)).get("name", sid)))
	if q.get("repeat", false):
		f.quests[id] = 0
	else:
		f.qdone.append(id)
		f.quests.erase(id)
	toasts.append(["MISSION COMPLETE: %s!" % q["name"], Color(1, 0.85, 0.3), 260])
	toasts.append(["REWARD: " + ", ".join(PackedStringArray(got)), Color(1, 0.95, 0.7), 260])
	Sfx.play("levelup")
	Game.save_fighter(f, L.k)

func _quest_rows(f: FighterSim) -> Array:
	var out = []
	for q in Content.quests:
		if f.level >= int(q.get("level", 1)) and not f.qdone.has(str(q["id"])) and (not q.has("from") or f.quests.has(str(q["id"]))):
			out.append(q)
	return out

# ------------------------------------------------------------------ chat
func _chat_send(t: String) -> void:
	Game.say(locals[0].name, t, 0)
	_chat_close()

## Android: the phone keyboard never full screen over the game, and closed for sure (LoG2Keyboard.java - its grey
## layer stayed over the game after a message now and then)
func _android_keyboard(what: String) -> void:
	if not (Engine.has_singleton("AndroidRuntime") and Engine.has_singleton("JavaClassWrapper")):
		return
	var act = Engine.get_singleton("AndroidRuntime").getActivity()
	var kb = Engine.get_singleton("JavaClassWrapper").wrap("com.godot.game.LoG2Keyboard")
	if act == null or kb == null:
		return
	if what == "setup":
		kb.setup(act)
	else:
		kb.hide(act)

var _chat_asking = null      # (the phone's chat box is open: its answer is taken in _process)
func _chat_poll() -> void:
	if _chat_asking == null:
		return
	var r = str(_chat_asking.take())
	if r == "":
		return
	_chat_asking = null
	_keys_down.clear()
	if r.begins_with("S:") and r.substr(2).strip_edges() != "" and not locals.is_empty():
		Game.say(locals[0].name, r.substr(2).strip_edges().left(80), 0)

func _chat_open() -> void:
	_keys_down.clear()
	if OS.has_feature("android") and Engine.has_singleton("AndroidRuntime") and Engine.has_singleton("JavaClassWrapper"):
		# a phone: a little "say something" box of the app's own (LoG2Keyboard.ask - one line, Enter sends, B or R3
		# cancels); with the game's hidden text box the keyboard got stuck (a grey layer, R3 never reached the game)
		var kb = Engine.get_singleton("JavaClassWrapper").wrap("com.godot.game.LoG2Keyboard")
		if kb != null:
			kb.ask(Engine.get_singleton("AndroidRuntime").getActivity(), "SAY SOMETHING")
			_chat_asking = kb
			return
	chat_open = true
	chat_box.visible = true
	chat_box.text = ""
	chat_box.grab_focus()
	if OS.has_feature("android"):
		_android_keyboard("setup")
		DisplayServer.virtual_keyboard_show("")

func _chat_close() -> void:
	_keys_down.clear()      # (what was typed must not stay "held" - see _keys_down)
	chat_open = false
	chat_box.visible = false
	chat_box.release_focus()
	if OS.has_feature("android"):
		DisplayServer.virtual_keyboard_hide()
		_android_keyboard("hide")

func _on_chat(from: String, text: String, pid: int) -> void:
	bubbles[pid] = [text, 300]
	chat_log.append(["%s: %s" % [from, text], Color(1, 1, 1) if pid / 8 == Game.my_id() else Color(0.6, 0.9, 1), 720])
	if chat_log.size() > 6:
		chat_log.pop_front()

# ------------------------------------------------------------------ the world map
## everyone else in the world (online and on this PC) you can travel to: [name, node, pos]
func _others() -> Array:
	var out = []
	for pid in Game.remote_states:
		var st: Dictionary = Game.remote_states[pid]
		out.append([str(st.get("name", "?")), int(st.get("node", 0)), Vector2(float(st["x"]), float(st["y"]))])
	for i in range(1, locals.size()):
		out.append([locals[i].name, locals[i].node_i, Vector2(locals[i].fighter.x, locals[i].fighter.y)])
	return out

## where the world map can take you: friends first, then every outdoor place of this world (fast travel)
func _map_targets() -> Array:
	var out = _others()
	var nodes: Array = Game.planet.nodes
	for i in nodes.size():
		if nodes[i].get("hidden", false) or i == locals[0].node_i:
			continue
		out.append([str(nodes[i]["name"]), i, Game.planet.arrival(i, 0) if str(nodes[i]["key"]).begins_with("land/") else Game.planet.start_point() if i == Game.planet.start else Game.planet.arrival(i, 0), true])
	# a whole land is one world now: its places (each of the game's areas in it) to fly to
	for i in nodes.size():
		if nodes[i].get("hidden", false) or not str(nodes[i]["key"]).begins_with("land/") or int(nodes[i]["kind"]) != 0:
			continue
		var a = Assets.area(nodes[i]["key"])
		if a.is_empty() or not a.has("land"):
			continue
		var seen = {}
		for pt in a["land"]["parts"]:
			var nm: String = pt[1]
			if nm == "" or seen.has(nm) or nm == str(nodes[i]["name"]):
				continue
			seen[nm] = true
			var r: Rect2 = pt[0]
			out.append([nm, i, Game.planet.safe_point(i, r.get_center()), true])
	return out

func _map_input(ev: InputEvent) -> bool:
	var o = _map_targets()
	var key = -1
	if ev is InputEventKey and ev.pressed and not ev.echo:
		key = ev.keycode
	elif ev is InputEventJoypadButton and ev.pressed:
		key = {JOY_BUTTON_DPAD_LEFT: KEY_LEFT, JOY_BUTTON_DPAD_RIGHT: KEY_RIGHT, Game.pad_btn("a"): KEY_ENTER, JOY_BUTTON_BACK: KEY_TAB, Game.pad_btn("b"): KEY_ESCAPE}.get(ev.button_index, -1)
	if key in [KEY_TAB, KEY_M, KEY_ESCAPE]:
		map_open = false
		return true
	if o.is_empty():
		return key != -1 and key != KEY_F2 and key != KEY_F11
	if key in [KEY_LEFT, KEY_A, KEY_UP, KEY_W]:
		map_pick = (map_pick - 1 + o.size()) % o.size()
		return true
	if key in [KEY_RIGHT, KEY_D, KEY_DOWN, KEY_S]:
		map_pick = (map_pick + 1) % o.size()
		return true
	if key in [KEY_ENTER, KEY_J, KEY_Z, KEY_SPACE]:
		var t = o[clampi(map_pick, 0, o.size() - 1)]
		var L: Local = locals[0]
		var a = Assets.area(Game.planet.nodes[int(t[1])]["key"])
		var p: Vector2 = t[2] if t.size() > 3 else t[2] + Vector2(16, 0)
		if not Assets.walkable(a, p.x, p.y):
			p = Game.planet.safe_point(int(t[1]), t[2])
		_warp(L, int(t[1]), p)
		toasts.append(["TRAVELLING TO %s" % t[0], Color(0.7, 0.9, 1), 120])
		map_open = false
		return true
	return false

func _draw_map(c: Control) -> void:
	var font = ThemeDB.fallback_font
	var vs = c.get_viewport_rect().size
	var nodes: Array = Game.planet.nodes
	c.draw_rect(Rect2(Vector2.ZERO, vs), Color(0.02, 0.03, 0.08, 0.88))
	_ds(c, font, Vector2(0, 16), Game.planet.title + " - THE WORLD", HORIZONTAL_ALIGNMENT_CENTER, vs.x, 10, Color(1, 0.85, 0.3))
	var mn = Vector2(1e9, 1e9)
	var mx = Vector2(-1e9, -1e9)
	for n in nodes:
		if n.get("hidden", false):
			continue
		var g = Vector2(n["gx"], n["gy"])
		mn = Vector2(minf(mn.x, g.x), minf(mn.y, g.y))
		mx = Vector2(maxf(mx.x, g.x), maxf(mx.y, g.y))
	var span = (mx - mn) + Vector2(1, 1)
	var cell = minf((vs.x - 40) / span.x, (vs.y - 90) / span.y)
	cell = minf(cell, 70.0)
	var org = Vector2((vs.x - span.x * cell) / 2.0, 28 + (vs.y - 90 - span.y * cell) / 2.0)
	var pos_of = func(i: int) -> Vector2:
		return org + (Vector2(nodes[i]["gx"], nodes[i]["gy"]) - mn + Vector2(0.5, 0.5)) * cell
	for i in nodes.size():
		if nodes[i].get("hidden", false):
			continue
		for ex in nodes[i]["exits"]:
			if not nodes[int(ex["to"])].get("hidden", false):
				c.draw_line(pos_of.call(i), pos_of.call(int(ex["to"])), Color(0.4, 0.5, 0.7), 1.0)
	for i in nodes.size():
		if nodes[i].get("hidden", false):
			continue
		var p: Vector2 = pos_of.call(i)
		var kind = int(nodes[i]["kind"])
		var col = Color(0.25, 0.45, 0.3) if kind == 0 else (Color(0.55, 0.2, 0.2) if kind == 2 else Color(0.3, 0.35, 0.55))
		var half = Vector2(cell * 0.36, cell * 0.24)
		c.draw_rect(Rect2(p - half, half * 2), col)
		c.draw_rect(Rect2(p - half, half * 2), Color(0.8, 0.85, 1, 0.6), false, 1.0)
		_ds(c, font, p + Vector2(-cell / 2, -half.y - 2), str(nodes[i]["name"]), HORIZONTAL_ALIGNMENT_CENTER, cell, 6, Color(0.85, 0.9, 1))
	# who is where
	var dots = {}
	for L in locals:
		dots[L.node_i] = dots.get(L.node_i, []) + [[L.name, Color(1, 0.9, 0.4) if L.k == 0 else Color(0.5, 1, 0.6)]]
	var o = _others()
	for pid in Game.remote_states:
		var st: Dictionary = Game.remote_states[pid]
		var nd = int(st.get("node", -1))
		if nd >= 0 and nd < nodes.size():
			dots[nd] = dots.get(nd, []) + [[str(st.get("name", "?")), Color(0.6, 0.9, 1)]]
	for nd in dots:
		if nodes[int(nd)].get("hidden", false):
			continue
		var p: Vector2 = pos_of.call(int(nd))
		var lst: Array = dots[nd]
		for j in lst.size():
			var q = p + Vector2(-cell * 0.3 + j * 7, 2)
			c.draw_circle(q, 3, lst[j][1])
			c.draw_arc(q, 3, 0, TAU, 12, Color(0, 0, 0), 1.0)
	var y = vs.y - 46
	var tg = _map_targets()
	if tg.is_empty():
		_ds(c, font, Vector2(0, y), "NOWHERE ELSE TO GO", HORIZONTAL_ALIGNMENT_CENTER, vs.x, 8, Color(0.8, 0.8, 0.9))
	else:
		var t = tg[clampi(map_pick, 0, tg.size() - 1)]
		var what = ("FLY TO " + str(t[0])) if t.size() > 3 else "GO TO %s  (%s)" % [t[0], nodes[int(t[1])]["name"]]
		_ds(c, font, Vector2(0, y), "<  %s  >" % what, HORIZONTAL_ALIGNMENT_CENTER, vs.x, 9, Color(0.6, 1, 0.8))
		var tp: Vector2 = pos_of.call(int(t[1]))
		c.draw_arc(tp, cell * 0.45, 0, TAU, 20, Color(1, 1, 0.4), 1.5)
		_ds(c, font, Vector2(0, y + 12), "LEFT / RIGHT: FRIENDS AND PLACES    ENTER / A: TRAVEL THERE", HORIZONTAL_ALIGNMENT_CENTER, vs.x, 7, Color(0.75, 0.8, 0.9))
	_ds(c, font, Vector2(0, vs.y - 18), "TAB / M / ESC: CLOSE", HORIZONTAL_ALIGNMENT_CENTER, vs.x, 7, Color(0.6, 0.6, 0.7))

func _on_victory(t: String) -> void:
	victory_t = 900
	victory_text = t + " IS FREE!"
	for L in locals:
		var f: FighterSim = L.fighter
		f.add_exp(Rules.level_of(f.exp, levels) * 40, levels)
		f.hp = f.maxhp
		Game.save_fighter(f, L.k)

# ------------------------------------------------------------------ drawing
const CHARGE_FX = ["rfx", "xcharge", "glow", "gather"]
func _draw_shots(av: AreaView, back: bool = false) -> void:
	var n: Node2D = av.back_shots_view if back else av.shots_view
	var ki = Assets.fx("kiblast")
	var all = []
	var fxs = []
	var back_fx = []
	for L in locals:
		if L.node_i == av.node_i:
			for e in L.fighter.snapshot()["shots"]:
				all.append(e)
			if L.fighter.dir == 1:
				back_fx.append_array(L.fighter.fx.filter(func(x): return str(x[0]) in CHARGE_FX))
				fxs.append_array(L.fighter.fx.filter(func(x): return not str(x[0]) in CHARGE_FX))
			else:
				fxs.append_array(L.fighter.fx)
	for pid in Game.remote_states:
		var st: Dictionary = Game.remote_states[pid]
		if int(st.get("node", -1)) == av.node_i:
			for e in st.get("shots", []):
				all.append(e)
			if int(st.get("dir", 0)) == 1:
				back_fx.append_array(st.get("fx", []).filter(func(x): return str(x[0]) in CHARGE_FX))
				fxs.append_array(st.get("fx", []).filter(func(x): return not str(x[0]) in CHARGE_FX))
			else:
				fxs.append_array(st.get("fx", []))
	var tt = Engine.get_physics_frames()
	var fr = (tt / 8) % 4
	for e in all:
		var kind = int(e[3]) if e.size() > 3 else 0
		var col = Color.hex(int(e[4])) if e.size() > 4 and int(e[4]) != 0 else Color(1, 1, 1)
		var p = Vector2(float(e[0]), float(e[1]))
		var look = str(e[9]) if e.size() > 9 else ""
		if back != ((kind == 1 or kind == 5) and int(e[2]) == 1):
			continue      # (a beam fired upward is drawn under the fighters - it leaves from behind the head - everything else over them)
		if kind == 5:
			_draw_rom_beam(n, e)
			continue
		if kind == 6:
			if float(e[5]) > 0:
				# a ball grown with the levels: a glow of its colour around the game's own ball
				var hc = Vector2(float(e[0]) + float(e[6]), float(e[1]) + float(e[7]))
				var hr = float(e[5]) * (1.0 + 0.06 * sin(tt * 0.9))
				n.draw_circle(hc, hr * 1.25, Color(col.r, col.g, col.b, 0.22))
				n.draw_circle(hc, hr, Color(col.r, col.g, col.b, 0.5))
				n.draw_circle(hc, hr * 0.6, Color(1, 1, 1, 0.35))
			_efx_tl(n, look, int(e[8]), Vector2(roundf(float(e[0])), roundf(float(e[1]))))
			continue
		if kind == 1 and look != "" and _beam_sprite(n, e, look, tt):
			continue
		if kind == 2 and look != "" and _ball_sprite(n, e, look, tt):
			continue
		if kind == 1:
			# a beam: glow, colour, white-hot core, streaks racing along it, a blazing head, a flash at the hands
			var o = Vector2(float(e[6]), float(e[7]))
			var w = float(e[5])
			if w < 0.5:
				continue
			var wob = 1.0 + 0.1 * sin(tt * 1.3)
			var dirv = (p - o).normalized() if p.distance_to(o) > 1 else Vector2(1, 0)
			var side = Vector2(-dirv.y, dirv.x)
			n.draw_line(o, p, Color(col.r, col.g, col.b, 0.18), w * 2.6 * wob)
			n.draw_line(o, p, Color(col.r, col.g, col.b, 0.4), w * 1.7 * wob)
			n.draw_line(o, p, col, w * wob)
			n.draw_line(o, p, Color(1, 1, 1, 0.95), maxf(1.0, w * 0.45))
			var L = o.distance_to(p)
			for k in 6:
				var u = fmod(float(tt * 9 + k * 37), maxf(1.0, L)) / maxf(1.0, L)
				var q = o.lerp(p, u) + side * sin(tt * 0.7 + k) * w * 0.35
				n.draw_line(q, q + dirv * 10.0, Color(1, 1, 1, 0.8), 1.5)
			var hr = w * (1.15 + 0.15 * sin(tt * 1.7))
			n.draw_circle(p, hr * 1.7, Color(col.r, col.g, col.b, 0.25))
			n.draw_circle(p, hr, col)
			n.draw_circle(p, hr * 0.6, Color(1, 1, 1))
			for k in 8:
				var a = k * TAU / 8.0 + tt * 0.25
				n.draw_line(p + Vector2.from_angle(a) * hr * 0.9, p + Vector2.from_angle(a) * hr * (1.5 + 0.4 * sin(tt + k)), Color(1, 1, 1, 0.7), 1.0)
			if look != "eyes":
				n.draw_circle(o, w * 0.9, Color(1, 1, 1, 0.85))
				n.draw_circle(o, w * 1.4, Color(col.r, col.g, col.b, 0.3))
			if w > 15.0:      # a great beam (the Tri Beam): sparks thrown off all along it
				for k2 in 14:
					var u2 = fmod(float(tt * 5 + k2 * 53), maxf(1.0, L)) / maxf(1.0, L)
					var q2 = o.lerp(p, u2) + side * (w * 0.7 + float((k2 * 7 + tt) % 9)) * (1.0 if k2 % 2 == 0 else -1.0)
					n.draw_line(q2, q2 + Vector2.from_angle(float(k2) * 1.7 + tt * 0.3) * 4.0, Color(1, 0.9, 0.4, 0.9), 1.5)
			else:
				# an eye beam: a half-round flare opening forward from the eye - nothing drawn back over the face
				var fr0 = w * (1.5 + 0.2 * sin(tt * 1.9))
				for ring in [[1.0, Color(col.r, col.g, col.b, 0.45)], [0.7, col], [0.4, Color(1, 1, 1, 0.95)]]:
					var pts = PackedVector2Array()
					for k in 13:
						pts.append(o + dirv.rotated(-PI / 2 + PI * k / 12.0) * fr0 * float(ring[0]))
					n.draw_colored_polygon(pts, ring[1])
		elif kind == 2:
			var r = maxf(4.0, float(e[8]))
			n.draw_circle(p, r * 1.5, Color(col.r, col.g, col.b, 0.3))
			n.draw_circle(p, r, col)
			n.draw_circle(p + Vector2(-r * 0.3, -r * 0.3), r * 0.4, Color(1, 1, 1, 0.85))
		elif not ki.is_empty():
			# the game's own ki blast: the whole frame (flame tail included), coloured for a move's own blasts
			var cell: int = ki["cell"]
			var src = Rect2(fr * cell, int(e[2]) * cell, cell, cell)
			var tint = Color(1, 1, 1) if (e.size() <= 4 or int(e[4]) == 0) else col.lerp(Color(1, 1, 1), 0.35)
			n.draw_texture_rect_region(ki["tex"], Rect2(p - Assets.ki_core(int(e[2]), fr), Vector2(cell, cell)), src, tint)
		else:
			n.draw_circle(p, 6, Color(col.r, col.g, col.b, 0.35))
			n.draw_circle(p, 3.5, col)
	if back:
		for e in back_fx:      # charging while facing up: the glow is in front of the hero, so behind him on screen
			_draw_fx(n, e)
		return
	for e in fxs:
		_draw_fx(n, e)
	var key: String = Game.planet.nodes[av.node_i]["key"]
	for sh in Game.area_eshots.get(key, []):
		_draw_eshot(n, sh)
	for fx in Game.area_fx.get(key, []):
		# a slam: the game's own dust cloud bursting out where the blow lands
		var q = Vector2(float(fx[1]), float(fx[2]))
		if Assets.efx("e_smoke").is_empty():
			_draw_fx(n, ["boom", fx[1], fx[2], fx[3], Color(1, 0.6, 0.3).to_rgba32(), fx[4], 24])
		else:
			_efx(n, "e_smoke", clampi(int(fx[4]) / 6, 0, 3), q, clampf(float(fx[3]) / 22.0, 1.0, 3.0))
	for pid in help_show:
		var hs: Array = help_show[pid]
		if int(hs[0]) == av.node_i:
			var q = Vector2(float(hs[1]), float(hs[2]) - 14)
			n.draw_arc(q, 14, -PI / 2, -PI / 2 + TAU * clampf(float(hs[3]), 0, 1), 24, Color(0.5, 1, 0.6), 2.5)
	# warnings: a foe getting ready to leap shows "!", one about to slam shows the red circle it will hit
	for e in Game.area_states.get(key, []):
		if int(e[9]) & 64:
			var q = Vector2(float(e[1]), float(e[2]))
			var prog = float(e[12]) / 100.0 if e.size() > 12 else 0.5
			if e.size() > 11 and int(e[11]) > 0:
				var rr = float(e[11])
				n.draw_circle(q, rr, Color(1, 0.15, 0.1, 0.12 + 0.18 * prog))
				n.draw_arc(q, rr, 0, TAU, 36, Color(1, 0.2, 0.1, 0.8), 1.5)
				n.draw_arc(q, rr * prog, 0, TAU, 36, Color(1, 0.8, 0.3, 0.9), 1.0)
			else:
				n.draw_string(ThemeDB.fallback_font, q + Vector2(-4, -40), "!", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 0.3, 0.2))

## effects: [type, x, y, r, color, t, life (, dir)]
# ------------------------------------------------------------------ what foes throw: the game's own sprites
## one frame of an imported attack sheet (fx/e_*.png), its offset point at p
## a frame of an effect sheet with its top-left corner at tl, 1:1 (as the game puts it on the screen)
func _efx_tl(n: Node2D, name: String, i: int, tl: Vector2) -> void:
	var fx = Assets.efx(name)
	if fx.is_empty() or i < 0 or i >= fx["frames"].size():
		return
	var f: Dictionary = fx["frames"][i]
	if int(f["w"]) <= 0:
		return
	n.draw_texture_rect_region(fx["tex"], Rect2(tl, Vector2(f["w"], f["h"])), Rect2(i * int(fx["cell"]), 0, f["w"], f["h"]))

const RDIR = [Vector2(0, 1), Vector2(0, -1), Vector2(-1, 0), Vector2(1, 0)]
## a beam of the game's own (Kamehameha, Special Beam Cannon): tail at the hands, 8-pixel body pieces, the head
func _draw_rom_beam(n: Node2D, e: Array) -> void:
	var R: Dictionary = Content.rom_specials.get(str(e[9]), {})
	if R.is_empty():
		return
	var d = clampi(int(e[2]), 0, 3)
	var P = Vector2(roundf(float(e[0])), roundf(float(e[1])))
	var t = int(e[4])
	var L = float(e[5])
	var r = float(e[8])
	var v: Vector2 = RDIR[d]
	var g = int(R.get("group", 8)) * d
	var F: Dictionary = R["frames"]
	var alt = ((t - 1) / 3) % 2 == 1
	var sheet = str(R["sheet"])
	var b0: Array = R["body"][d]
	var off = maxf(0.0, r)
	while off < L:
		_efx_tl(n, sheet, g + int(F["body"]), P + Vector2(b0[0], b0[1]) + v * off)
		off += 8.0
	var h0: Array = R["head"][d]
	_efx_tl(n, sheet, g + int(F["head2"] if alt and F.has("head2") else F["head"]), P + Vector2(h0[0], h0[1]) + v * (L - float(R.get("len0", 8))))
	if r < 0:
		var t0: Array = R["tail"][d]
		_efx_tl(n, sheet, g + int(F["tail2"] if alt and F.has("tail2") else F["tail"]), P + Vector2(t0[0], t0[1]))
	elif F.has("tailend"):
		var te: Array = R["tailend"][d]
		_efx_tl(n, sheet, g + int(F["tailend"]), P + Vector2(te[0], te[1]) + v * r)

func _efx(n: Node2D, name: String, i: int, p: Vector2, sc: float = 1.0, col: Color = Color(1, 1, 1), fh: bool = false, fv: bool = false) -> void:
	sc = 1.0      # 1:1, as on the GBA
	var fx = Assets.efx(name)
	if fx.is_empty() or i < 0 or i >= fx["frames"].size():
		return
	var f: Dictionary = fx["frames"][i]
	var w = float(f["w"]); var h = float(f["h"])
	if w <= 0:
		return
	var src = Rect2(i * int(fx["cell"]), 0, w, h)
	var ox = float(f["ox"]); var oy = float(f["oy"])
	if fh:
		ox = w - ox
	if fv:
		oy = h - oy
	var dst = Rect2(p.x - ox * sc, p.y - oy * sc, w * sc, h * sc)
	if fh or fv:
		n.draw_set_transform(dst.position + dst.size / 2.0, 0.0, Vector2(-1 if fh else 1, -1 if fv else 1))
		n.draw_texture_rect_region(fx["tex"], Rect2(-dst.size / 2.0, dst.size), src, col)
		n.draw_set_transform(Vector2.ZERO)
	else:
		n.draw_texture_rect_region(fx["tex"], dst, src, col)

## [x, y, kind, dir, t, a, b, id]: kind 1 laser, 2 fire, 3 bomb, 4 ring, 5 beam, 6 charge, 7 boom, 8 burn
func _draw_eshot(n: Node2D, sh: Array) -> void:
	var p = Vector2(float(sh[0]), float(sh[1]))
	var k = int(sh[2]); var d = int(sh[3]); var t = int(sh[4]); var a = float(sh[5]); var b = float(sh[6])
	if k >= 9 and OS.get_environment("LOG2_ESDBG") != "": print("[es] ", sh)
	if t <= 0:
		return
	const DV = [Vector2(0, 1), Vector2(0, -1), Vector2(-1, 0), Vector2(1, 0)]
	var v: Vector2 = DV[clampi(d, 0, 3)]
	match k:
		1:      # the robots' zig-zag laser, 8 px pieces from the head back
			var horiz = d >= 2
			var segs = int(a / 8.0)
			for i in segs + 1:
				_efx(n, "e_laser", ((t / 2 + i) % 4) + (4 if horiz else 0), p - v * (i * 8.0), 1.0, Color(1, 1, 1), d == 2, d == 1)
		2:      # a fireball
			var fl = 1.0 + 0.06 * sin(t * 1.3)
			_efx(n, "e_fire", clampi(d, 0, 3) * 4, p, fl)
		3:      # a lit bomb: up in the air, then on the ground with the fuse burning
			n.draw_set_transform(p, 0.0, Vector2(1.0, 0.45))
			n.draw_circle(Vector2.ZERO, 6.0, Color(0, 0, 0, 0.35))
			n.draw_set_transform(Vector2.ZERO)
			var blink = b >= 0 and b > 60 and (t / 3) % 2 == 0
			_efx(n, "e_bomb", (t / 5) % 3, p - Vector2(0, a + 4), 1.0, Color(1, 0.45, 0.4) if blink else Color(1, 1, 1))
			if b >= 0:
				var rr = 30.0
				n.draw_arc(p, rr, 0, TAU, 32, Color(1, 0.3, 0.2, 0.25 + 0.5 * b / 100.0), 1.0)
				n.draw_arc(p, rr * (1.0 - b / 100.0), 0, TAU, 32, Color(1, 0.7, 0.3, 0.6), 1.0)
		4:      # the shock ring running outward
			# the game's ring (its first frames as it starts), then the same thin white outline running wider
			var al = clampf(1.5 - a / 70.0, 0.35, 1.0)
			if a < 15:
				_efx(n, "e_ring", 0 if a < 5 else (1 if a < 9 else 2), p, 1.0, Color(1, 1, 1, al))
			else:
				n.draw_arc(p, a, 0, TAU, maxi(24, int(a)), Color(1, 1, 1, al), 2.0)
				n.draw_arc(p, a - 3.0, 0, TAU, maxi(24, int(a)), Color(1, 1, 1, al * 0.35), 1.0)
		5:      # a boss's beam: the body piece over and over, an orb where it leaves, a burst where it ends
			var horiz = d >= 2
			var body = 14 if horiz else 2
			var sc = 1.5
			var segs = int(a / (8.0 * sc))
			for i in segs:
				_efx(n, "e_beam", body, p + v * ((i + 0.5) * 8.0 * sc), sc, Color(1, 1, 1, 0.95))
			_efx(n, "e_charge", 2, p, 1.2 + 0.1 * sin(t * 0.9))
			var end = p + v * a
			var burst = (15 + (t / 3) % 2) if horiz else (3 + (t / 3) % 2)
			_efx(n, "e_beam", burst, end, 1.2, Color(1, 1, 1), d == 2, d == 0)
		6:      # the orb a boss gathers before its beam
			var fi = 0 if a < 33 else (1 if a < 66 else 2)
			_efx(n, "e_charge", fi, p, 1.0 + a / 90.0 + 0.08 * sin(t * 0.8))
			if (t / 4) % 2 == 0:
				n.draw_circle(p, 6.0 + a / 8.0, Color(1, 0.9, 0.6, 0.15))
		7:      # a burst of fire (bombs, fireballs)
			var fi = 1 if t < 8 else (2 if t < 16 else 3)
			_efx(n, "e_fire", fi, p, clampf(a / 16.0, 0.8, 2.2))
		8:      # burning ground
			var al = clampf(1.0 - t / 150.0 + 0.3, 0.2, 1.0)
			_efx(n, "e_fire", 0, p + Vector2(0, -2), 0.55 + 0.05 * sin(t * 0.7), Color(1, 1, 1, al))
		9:      # a missile (the soldiers' bazooka): one frame per direction
			_efx_obj(n, "e_missile", clampi(d, 0, 3), p)
		10:     # a foe's ki blast: the game's ki blast sprite
			var ki = Assets.fx("kiblast")
			if not ki.is_empty():
				var cell: int = ki["cell"]
				var fr = (t / 4) % 4
				n.draw_texture_rect_region(ki["tex"], Rect2(p - Assets.ki_core(clampi(d, 0, 3), fr), Vector2(cell, cell)), Rect2(fr * cell, clampi(d, 0, 3) * cell, cell, cell))
		11:     # a laser piece (the Destroyer's stream)
			_efx_c(n, "e_laser", ((t / 2) % 4) + (4 if d >= 2 else 0), p)
		12:     # a laser beam (the ladybugs'): 8-pixel pieces from the muzzle out
			var segs = int(a / 8.0)
			for i in segs:
				_efx_c(n, "e_laser", ((t / 2 + i) % 4) + (4 if d >= 2 else 0), p + v * (i * 8.0 + 4.0))
		13:     # the burst where a missile lands
			_efx_obj(n, "e_smoke", clampi(t / 8, 0, 3), p)
		14:
			pass
		15:     # a ninja's throwing star, spinning
			_efx_obj(n, "e_star", (t / 2) % 2, p)
		16:     # a lobbed bomb (the bandits'), up in the air on its arc
			_efx_obj(n, "e_bomb", ((t >> 2) & 3) if ((t >> 2) & 3) != 3 else 1, p)
		_:
			n.draw_circle(p, 4.0, Color(1, 0.6, 0.3))

## a frame of an attack sheet placed as the game places it: the sheet's hot spot on the object's point, 1:1
func _efx_obj(n: Node2D, name: String, i: int, p: Vector2) -> void:
	var fx = Assets.efx(name)
	if fx.is_empty() or i < 0 or i >= fx["frames"].size():
		return
	var f: Dictionary = fx["frames"][i]
	if int(f["w"]) <= 0:
		return
	var tl = Vector2(floorf(p.x) - float(f["ox"]), floorf(p.y) - float(f["oy"]))
	n.draw_texture_rect_region(fx["tex"], Rect2(tl, Vector2(f["w"], f["h"])), Rect2(i * int(fx["cell"]), 0, f["w"], f["h"]))

# ------------------------------------------------------------------ the heroes' own special effects (from the game)
## one frame, centred on p (the special-move sheets are drawn around their middle)
func _efx_c(n: Node2D, name: String, i: int, p: Vector2, sc: float = 1.0, col: Color = Color(1, 1, 1), fh: bool = false, fv: bool = false) -> bool:
	sc = 1.0      # the game's sprites are never stretched: 1:1, as on the GBA
	var fx = Assets.efx(name)
	if fx.is_empty() or i < 0 or i >= fx["frames"].size():
		return false
	var f: Dictionary = fx["frames"][i]
	var w = float(f["w"]); var h = float(f["h"])
	if w <= 0:
		return false
	var src = Rect2(i * int(fx["cell"]), 0, w, h)
	var size = Vector2(w, h) * sc
	n.draw_set_transform(p, 0.0, Vector2(-1 if fh else 1, -1 if fv else 1))
	n.draw_texture_rect_region(fx["tex"], Rect2(-size / 2.0, size), src, col)
	n.draw_set_transform(Vector2.ZERO)
	return true

const BEAM_LOOKS = {
	# sheet, body (vertical, horizontal), end burst (vertical pair, horizontal pair), orb at the hands, tint
	"blue": ["p_beam_blue", [2, 14], [3, 4, 15, 16], ["p_ball_blue", 2], Color(1, 1, 1)],
	"yellow": ["e_beam", [2, 14], [3, 4, 15, 16], ["e_charge", 2], Color(1, 1, 1)],
	"purple": ["p_beam_blue", [2, 14], [3, 4, 15, 16], ["p_ball_blue", 2], Color(0.85, 0.55, 1.0)],
	"red": ["p_beam_red", [4, 14], [7, 8, 12, 13], ["p_beam_red", 0], Color(1, 1, 1)],
}
## a beam with the game's own pieces: the body piece over and over, the orb at the hands, the burst at the end
func _beam_sprite(n: Node2D, e: Array, look: String, tt: int) -> bool:
	if not BEAM_LOOKS.has(look) or Assets.efx(BEAM_LOOKS[look][0]).is_empty():
		return false
	var lk: Array = BEAM_LOOKS[look]
	var p = Vector2(float(e[0]), float(e[1]))
	var o = Vector2(float(e[6]), float(e[7]))
	var w = float(e[5])
	if w < 0.5:
		return true
	var d = int(e[2])
	var horiz = d >= 2
	var dv = (p - o).normalized() if p.distance_to(o) > 1 else Rules.dir_vec(d)
	var sc = clampf(w / 5.0, 1.0, 3.0)
	var step = 6.0                   # the game's beam pieces are drawn 1:1 (8 px): overlapping, never a gap
	var L = o.distance_to(p)
	var body: int = lk[1][1 if horiz else 0]
	var tint: Color = lk[4]
	var lanes = maxi(1, int(w / 10.0))     # a very wide beam (Solar Kamehameha): more rows of pieces side by side
	var across = Vector2(-dv.y, dv.x)
	for ln in lanes:
		var off = across * (ln - (lanes - 1) * 0.5) * 6.0
		var i = 0.0
		while i < L:
			_efx_c(n, lk[0], body, o + dv * i + off, sc, tint)
			i += step
	if look == "red":
		# the Special Beam Cannon's spiral: sparks winding round the beam
		var side = Vector2(-dv.y, dv.x)
		var k = 0.0
		while k < L:
			var q2 = o + dv * k + side * sin(k * 0.25 + tt * 0.5) * 6.0 * sc
			_efx_c(n, "p_beam_red", (tt / 3 + int(k)) % 2, q2, 0.5, Color(1, 1, 1, 0.85))
			k += 14.0
	# the orb at the hands
	_efx_c(n, lk[3][0], lk[3][1], o, sc * (1.0 + 0.1 * sin(tt * 1.3)), tint)
	# the end bursts
	var pair: int = 2 if horiz else 0
	var bi: int = lk[2][pair + (tt / 3) % 2]
	_efx_c(n, lk[0], bi, p, sc * 1.1, tint, d == 2, d == 0)
	return true

## how strongly a ball's sphere of colour shows: always for a huge ball; for a smaller one only as it grows with
## the levels (from nothing when learned to full at a third bigger) - the game's ball itself is drawn 1:1
func _sphere_alpha(size: float, base: float) -> float:
	if base <= 0.0:
		return 1.0 if size > 14.0 else 0.0
	if base > 14.0:
		return 1.0
	return clampf((size - base) / (base * 0.33), 0.0, 1.0)

## balls drawn by our artists (data/builtin/sprites): rows of [y, cell size, frames] - charge, flying, burst
const SHEET_LOOKS = {"deathball": {"file": "fx_death_ball.png", "rows": [[0, 32, 3], [32, 32, 4], [64, 48, 4]]},
	"disk": {"file": "fx_destructo_disk.png", "rows": [[0, 32, 3], [32, 32, 4], [64, 48, 4]]},
	"supernova": {"file": "fx_supernova.png", "rows": [[0, 128, 3], [128, 128, 4], [256, 192, 4]], "icon": [0, 0], "grow": 14}}
## a charge that grows smoothly (the Supernova): "grow" steps made from the artist's charge frames, each one scaled from its
## own size up to the next frame's, the first starting at a quarter
var _sheet_area = {}
func _charge_grow(n: Node2D, look: String, k: float, p: Vector2) -> bool:
	var L: Dictionary = SHEET_LOOKS[look]
	var tex = Assets.texture(Assets.builtin_dir().path_join("sprites/" + str(L["file"])))
	if tex == null:
		return false
	var rw: Array = L["rows"][0]
	var c = int(rw[1]); var nf = int(rw[2])
	if not _sheet_area.has(look):      # how big each charge frame looks: the square root of its solid pixels
		var img: Image = tex.get_image()
		var sizes = []
		for f in nf:
			var cnt = 0
			for y in c:
				for x in c:
					if img.get_pixel(f * c + x, int(rw[0]) + y).a > 0.5:
						cnt += 1
			sizes.append(sqrt(float(maxi(1, cnt))))
		_sheet_area[look] = sizes
	var sz: Array = _sheet_area[look]
	var steps = int(L["grow"])
	var st = clampi(int(k * steps), 0, steps - 1)
	var u = float(st) / float(steps - 1) * float(nf - 1)      # where this step lies between the drawn frames
	var f = mini(int(u), nf - 1)
	var t = u - f
	var sc: float
	if f >= nf - 1:
		sc = 1.0
	else:
		var start = 0.25 if f == 0 else 1.0
		sc = lerpf(start, float(sz[f + 1]) / float(sz[f]), t)
	var d = Vector2(c, c) * sc
	n.draw_texture_rect_region(tex, Rect2(p.round() - d * 0.5, d), Rect2(f * c, int(rw[0]), c, c))
	return true
func _disk_draw(n: Node2D, p: Vector2, r: float, tt: int, col: Color) -> void:
	var w = r * (1.0 + 0.12 * sin(tt * 0.8))
	n.draw_set_transform(p, 0.0, Vector2(1.0, 0.35))
	n.draw_circle(Vector2.ZERO, w * 1.3, Color(col.r, col.g, col.b, 0.3))
	n.draw_circle(Vector2.ZERO, w, col)
	n.draw_circle(Vector2.ZERO, w * 0.55, Color(1, 1, 1, 0.9))
	n.draw_arc(Vector2.ZERO, w * 0.8, tt * 0.6, tt * 0.6 + 2.0, 12, Color(1, 1, 1), 1.0)
	n.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
func _sheet_draw(n: Node2D, look: String, row: int, i: int, p: Vector2, d: int = -1) -> bool:
	if not SHEET_LOOKS.has(look):
		return false
	var tex = Assets.texture(Assets.builtin_dir().path_join("sprites/" + str(SHEET_LOOKS[look]["file"])))
	if tex == null:
		return false
	var rw: Array = SHEET_LOOKS[look]["rows"][row]
	var c = int(rw[1])
	var fi = clampi(i, 0, int(rw[2]) - 1)
	# a sheet drawn for flying right (the Destructo Disk): mirrored going left, a quarter turn going up or down
	var ang = {0: PI / 2, 1: -PI / 2}.get(d, 0.0)
	var sx = -1.0 if d == 2 else 1.0
	n.draw_set_transform(p.round(), ang, Vector2(sx, 1.0))
	n.draw_texture_rect_region(tex, Rect2(-Vector2(c, c) * 0.5, Vector2(c, c)), Rect2(fi * c, int(rw[0]), c, c))
	n.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	return true

const BALL_LOOKS = {"spirit": "p_spirit", "bigbang": "p_ball_yellow", "orange": "e_charge", "present": "e_bomb", "cyan": "p_ball_cyan"}
## a thrown ball: the Spirit Bomb in flight, Big Bang, Burning Attack, Mr. Satan's present
func _ball_sprite(n: Node2D, e: Array, look: String, tt: int) -> bool:
	if _sheet_draw(n, look, 1, (tt / 4) % 4, Vector2(float(e[0]), float(e[1])), int(e[2]) if look == "disk" else -1):
		return true
	if look == "disk":
		_disk_draw(n, Vector2(float(e[0]), float(e[1])), maxf(4.0, float(e[8])), tt, Color.hex(int(e[4])))
		return true
	var tint = Color(1, 1, 1)
	if look.ends_with("_tint"):      # the game's ball in the move's own colour (Frieza's dark purple Death Ball)
		look = look.trim_suffix("_tint")
		tint = Color.hex(int(e[4])).lightened(0.25)
	var sheet: String = BALL_LOOKS.get(look, "")
	if sheet == "" or Assets.efx(sheet).is_empty():
		return false
	var p = Vector2(float(e[0]), float(e[1]))
	var size = maxf(4.0, float(e[8]))
	var sa = _sphere_alpha(size, float(e[10]) if e.size() > 10 else 0.0)
	if sa > 0.0:                     # a huge ball (a Supernova, or one grown with the levels): a burning sphere of its colour
		var bc = Color.hex(int(e[4]))
		var rr = size * 1.6 * (1.0 + 0.05 * sin(tt * 0.6))
		n.draw_circle(p, rr * 1.25, Color(bc.r, bc.g, bc.b, 0.25 * sa))
		n.draw_circle(p, rr, Color(bc.r, bc.g, bc.b, 0.85 * sa))
		var lc = bc.lightened(0.45)
		n.draw_circle(p, rr * 0.6, Color(lc.r, lc.g, lc.b, sa))
	match look:
		"spirit":
			_efx_c(n, "p_spirit", 4, p, clampf(size / 14.0, 0.7, 6.0) * (1.0 + 0.05 * sin(tt * 0.8)), tint)
		"present":
			_efx_c(n, "e_bomb", (tt / 5) % 3, p, 1.0)
		_:
			var fx = Assets.efx(sheet)
			_efx_c(n, sheet, fx["frames"].size() - 1, p, clampf(size / 8.0, 0.8, 6.0) * (1.0 + 0.08 * sin(tt * 1.1)), tint)
	return true

## charging (k 0..1): the orb that grows at the hands / over the head
func _draw_xcharge(n: Node2D, e: Array) -> void:
	var p = Vector2(float(e[1]), float(e[2]))
	var k = clampf(float(e[3]), 0.0, 1.0)
	var look = str(e[7]) if e.size() > 7 else ""
	var tt = Engine.get_physics_frames()
	if SHEET_LOOKS.has(look) and SHEET_LOOKS[look].has("grow") and _charge_grow(n, look, k, p):
		return
	if _sheet_draw(n, look, 0, int(k * 3.0), p):
		return
	if look == "disk":
		_disk_draw(n, p, maxf(2.0, float(e[8]) * k), tt, Color.hex(int(e[4])))
		return
	var tint = Color(1, 1, 1)
	if look.ends_with("_tint"):
		look = look.trim_suffix("_tint")
		tint = Color.hex(int(e[4])).lightened(0.25)
	var big = maxf(1.0, float(e[8]) / 12.0) if e.size() > 8 else 1.0      # a huge ball grows huge while it gathers
	var sa = _sphere_alpha(float(e[8]), float(e[9]) if e.size() > 9 else 0.0) if e.size() > 8 else 0.0
	if sa > 0.0:
		var bc = Color.hex(int(e[4]))
		var rr = float(e[8]) * 1.6 * k
		n.draw_circle(p, rr * 1.25, Color(bc.r, bc.g, bc.b, 0.25 * sa))
		n.draw_circle(p, rr, Color(bc.r, bc.g, bc.b, 0.85 * sa))
		var lc = bc.lightened(0.45)
		n.draw_circle(p, rr * 0.6, Color(lc.r, lc.g, lc.b, sa))
	match look:
		"spirit":
			_efx_c(n, "p_spirit", clampi(int(k * 5.0), 0, 4), p, (1.0 + 0.04 * sin(tt * 0.7)) * lerpf(1.0, big, k), tint)
		"bigbang":
			_efx_c(n, "p_ball_yellow", clampi(int(k * 3.0), 0, 2), p, (1.0 + k) * lerpf(1.0, big, k), tint)
		"orange":
			_efx_c(n, "e_charge", clampi(int(k * 3.0), 0, 2), p, (1.0 + k * 0.6) * lerpf(1.0, big, k), tint)
		"present":
			_efx_c(n, "e_bomb", (tt / 5) % 3, p, 1.0)
		"red":
			_efx_c(n, "p_beam_red", (tt / 3) % 2, p, 0.6 + k * 0.6)
		_:
			var lk: Array = BEAM_LOOKS.get(look, BEAM_LOOKS["blue"])
			_efx_c(n, lk[3][0], clampi(int(k * 3.0), 0, 2), p, 0.8 + k * 0.6, lk[4])

## a ball going off: the game's own explosions
func _draw_xboom(n: Node2D, e: Array) -> void:
	var p = Vector2(float(e[1]), float(e[2]))
	var r = float(e[3])
	var k = float(e[5]) / maxf(1.0, float(e[6]))
	var look = str(e[7]) if e.size() > 7 else ""
	if _sheet_draw(n, look, 2, int(k * 4.0), p, int(e[8]) if e.size() > 8 else -1):
		return
	match look:
		"spirit":
			_efx_c(n, "e_ring", clampi(int(k * 4.0), 0, 3), p, r / 16.0 * (0.4 + k), Color(1, 1, 1, 1.0 - k * 0.6))
			_efx_c(n, "e_spark", clampi(int(k * 6.0), 0, 5), p, r / 14.0)
		"present":
			_efx_c(n, "e_smoke", clampi(int(k * 4.0), 0, 3), p, r / 18.0)
		"orange":
			_efx_c(n, "e_fire", 1 + clampi(int(k * 3.0), 0, 2), p, r / 16.0)
		_:
			_efx_c(n, "p_boom", clampi(int(k * 3.0), 0, 2), p, r / 12.0)
			_efx_c(n, "p_ring", clampi(int(k * 2.0), 0, 1), p, r / 14.0 * (0.5 + k), Color(1, 1, 1, 1.0 - k))

func _draw_fx(n: Node2D, e: Array) -> void:
	if str(e[0]) == "rfx":      # a sprite of the game's own at its exact place (the glow at the hands)
		_efx_tl(n, str(e[3]), int(e[4]), Vector2(roundf(float(e[1])) + float(e[7]), roundf(float(e[2])) + float(e[8])))
		return
	if str(e[0]) == "xcharge":
		_draw_xcharge(n, e)
		return
	if str(e[0]) == "xboom":
		_draw_xboom(n, e)
		return
	var p = Vector2(float(e[1]), float(e[2]))
	var r = float(e[3])
	var col = Color.hex(int(e[4]))
	var k = float(e[5]) / maxf(1.0, float(e[6]))
	match str(e[0]):
		"dome":         # solid over the body first, then spreading out and fading (e[7]: the body's size)
			var cover = float(e[7]) if e.size() > 7 else 16.0
			var rr: float; var al: float
			if k < 0.3:
				rr = cover * (0.15 + 0.85 * k / 0.3); al = 1.0
			else:
				var q = (k - 0.3) / 0.7
				rr = lerpf(cover, r, q); al = 1.0 - q * 0.85
			n.draw_circle(p, rr, Color(col.r, col.g, col.b, al))
			n.draw_circle(p, rr * 0.7, Color(col.lightened(0.4).r, col.lightened(0.4).g, col.lightened(0.4).b, al))
			n.draw_arc(p, rr, 0, TAU, 48, Color(1, 1, 1, al), 2.0)
		"ring":
			n.draw_arc(p, r * (0.3 + 0.7 * k), 0, TAU, 40, Color(col.r, col.g, col.b, 1.0 - k), 3.0)
			n.draw_circle(p, r * (0.3 + 0.7 * k), Color(col.r, col.g, col.b, 0.18 * (1.0 - k)))
		"flash":
			n.draw_circle(p, r * (0.2 + 0.8 * k), Color(col.r, col.g, col.b, 0.55 * (1.0 - k)))
			n.draw_arc(p, r * (0.2 + 0.8 * k), 0, TAU, 40, Color(1, 1, 1, 1.0 - k), 2.0)
		"boom":
			n.draw_circle(p, r * (0.4 + 0.6 * k), Color(col.r, col.g, col.b, 0.5 * (1.0 - k)))
			n.draw_circle(p, r * 0.5 * (1.0 - k), Color(1, 1, 0.9, 0.8 * (1.0 - k)))
			for i in 8:
				var dv = Vector2.from_angle(i * TAU / 8 + 0.3)
				n.draw_line(p + dv * r * 0.3 * (1 + k), p + dv * r * (0.6 + 0.6 * k), Color(1, 0.9, 0.6, 1.0 - k), 2.0)
		"glow":
			n.draw_circle(p, r * 1.6, Color(col.r, col.g, col.b, 0.3))
			n.draw_circle(p, r, col)
			n.draw_circle(p, r * 0.45, Color(1, 1, 1))
		"trail":
			n.draw_circle(p + Vector2(0, -14), 9 * (1.0 - k), Color(col.r, col.g, col.b, 0.45 * (1.0 - k)))
		"arc", "line":
			var d = int(e[7]) if e.size() > 7 else 0
			var fwd = Rules.dir_vec(d)
			if str(e[0]) == "arc":
				var a0 = fwd.angle()
				n.draw_arc(p, r * 0.8, a0 - 1.1, a0 + 1.1, 16, Color(col.r, col.g, col.b, 1.0 - k), 4.0)
				n.draw_arc(p, r * 0.6, a0 - 0.9, a0 + 0.9, 16, Color(1, 1, 1, 0.8 * (1.0 - k)), 2.0)
			else:
				var reach = r * minf(1.0, k * 3.0)
				n.draw_line(p, p + fwd * reach, Color(col.r * 0.7, col.g * 0.7, col.b * 0.7), 4.0)
				n.draw_circle(p + fwd * reach, 4, col)
		"gather":
			# sparks drawn in toward the charging hands
			var seed = int(e[7]) if e.size() > 7 else 0
			for i in 5:
				var a = (seed * 0.7 + i * TAU / 5.0)
				var rr = r * (1.0 - k)
				var q = p + Vector2.from_angle(a) * rr
				n.draw_line(q, q + (p - q).normalized() * 4.0, Color(col.r, col.g, col.b, 0.9), 1.2)
				n.draw_circle(q, 1.0, Color(1, 1, 1, 0.9))
		"sparkle":
			var q = p + Vector2(0, -k * 10)
			n.draw_line(q - Vector2(r, 0), q + Vector2(r, 0), Color(col.r, col.g, col.b, 1.0 - k), 1.0)
			n.draw_line(q - Vector2(0, r), q + Vector2(0, r), Color(col.r, col.g, col.b, 1.0 - k), 1.0)

func _draw_pops(av: AreaView) -> void:
	var font = ThemeDB.fallback_font
	var n: Node2D = av.pops_view
	var key: String = Game.planet.nodes[av.node_i]["key"]
	var tt = Engine.get_physics_frames()
	for d in Game.area_drops.get(key, []):
		var p = Vector2(float(d[2]), float(d[3]) - 6 + sin((tt + int(d[0]) * 17) * 0.08) * 2.0)
		var col = [Color(0.3, 1, 0.4), Color(0.4, 0.7, 1), Color(1, 0.85, 0.2)][clampi(int(d[1]), 0, 2)]
		n.draw_circle(Vector2(float(d[2]), float(d[3])), 4, Color(0, 0, 0, 0.3))
		n.draw_circle(p, 6, Color(col.r, col.g, col.b, 0.25))
		if int(d[1]) == 2:
			n.draw_circle(p + Vector2(-1.5, 0), 2.5, col)
			n.draw_circle(p + Vector2(1.5, 0), 2.5, col)
		else:
			n.draw_circle(p, 3.5, col)
			n.draw_circle(p + Vector2(-1, -1), 1.2, Color(1, 1, 1, 0.9))
	for sp in av.sparks:
		var r = (10 - sp[1]) * 1.6 + 3
		for i in 6:
			var dv = Vector2.from_angle(i * TAU / 6 + sp[1] * 0.2)
			n.draw_line(sp[0] + dv * r * 0.4, sp[0] + dv * r, sp[2], 1.5)
	for pp in av.pops:
		var p: Vector2 = pp[1]
		av.pops_view.draw_string_outline(font, p + Vector2(-20, 0), pp[0], HORIZONTAL_ALIGNMENT_CENTER, 40, 8, 2, Color(0, 0, 0, 0.8))
		av.pops_view.draw_string(font, p + Vector2(-20, 0), pp[0], HORIZONTAL_ALIGNMENT_CENTER, 40, 8, pp[3])

func _bar(c: Control, x: float, y: float, w: float, v: float, mx: float, col: Color) -> void:
	c.draw_rect(Rect2(x - 1, y - 1, w + 2, 6), Color(0, 0, 0, 0.7))
	c.draw_rect(Rect2(x, y, w * clampf(v / maxf(1.0, mx), 0.0, 1.0), 4), col)

## the GBA's own bars: a dark metal frame, health in red and ki in green (three slanted rows each, in chevron
## segments of two shades), and a thin bar for the experience to the next level
const HUD_LEN = 62
const HP_COLS = [[Color8(248, 72, 72), Color8(168, 8, 16)], [Color8(248, 112, 112), Color8(208, 16, 40)]]
const KI_COLS = [[Color8(48, 248, 72), Color8(0, 120, 8)], [Color8(112, 248, 144), Color8(0, 168, 24)]]
func _gba_bars(c: Control, x0: float, y0: float, hp: float, ki: float, xp: float, sk: Dictionary = {}, ready: bool = true, set_id: int = -1) -> void:
	var px = func(xx: float, yy: float, col: Color): c.draw_rect(Rect2(x0 + xx, y0 + yy, 1, 1), col)
	var IW = 24      # the special's window at the right, inside the same metal frame
	var FW = HUD_LEN + 10 + IW + 3
	c.draw_rect(Rect2(x0 + 1, y0, FW, 22), Color8(32, 32, 64))
	c.draw_rect(Rect2(x0 + 3, y0, FW - 2, 1), Color8(112, 112, 112))
	c.draw_rect(Rect2(x0 + 3, y0 + 21, FW - 2, 1), Color8(88, 88, 88))
	c.draw_rect(Rect2(x0 + FW, y0 + 1, 1, 20), Color8(88, 88, 88))
	c.draw_rect(Rect2(x0 + 4, y0 + 1, HUD_LEN + 5, 13), Color.BLACK)
	for k in 22:      # the slanted metal cap at the left
		px.call(maxf(0, 2 - k * 0.2), k, Color8(192, 192, 192) if k < 3 else Color8(112, 112, 112))
		px.call(maxf(1, 3 - k * 0.2), k, Color8(144, 144, 144))
	var rows = [[hp, HP_COLS, 2], [ki, KI_COLS, 7]]
	for b in rows:
		var n = int(roundf(HUD_LEN * clampf(float(b[0]), 0.0, 1.0)))
		for r in 3:
			var sx = 5 + r
			for i in HUD_LEN:
				var col = Color.BLACK
				if i < n and (i % 16) != 15:
					var seg = (i / 16) % 2
					col = b[1][seg][0] if r == 0 else b[1][seg][1]
				px.call(sx + i, b[2] + r, col)
		c.draw_rect(Rect2(x0 + 5, y0 + b[2] + 3, HUD_LEN + 2, 1), Color8(88, 88, 88))
	# experience: a thin blue bar inside the frame, under the health and ki
	c.draw_rect(Rect2(x0 + 4, y0 + 15, HUD_LEN + 5, 5), Color.BLACK)
	c.draw_rect(Rect2(x0 + 5, y0 + 16, HUD_LEN + 3, 3), Color8(24, 24, 48))
	c.draw_rect(Rect2(x0 + 5, y0 + 17, (HUD_LEN + 3) * xp, 1), Color8(72, 128, 232))
	# the special's window
	var wx = x0 + HUD_LEN + 11
	c.draw_rect(Rect2(wx - 1, y0 + 1, 1, 20), Color8(112, 112, 112))
	c.draw_rect(Rect2(wx, y0 + 2, IW, 18), Color.BLACK)
	if not sk.is_empty():
		_skill_icon(c, sk, Rect2(wx + 1, y0 + 3, IW - 2, 16), ready, set_id)

## a little snapshot of the special in the HUD's window, drawn the way the move looks (dim while it cannot be used)
func _skill_icon(c: Control, sk: Dictionary, r: Rect2, ready: bool, set_id: int = -1) -> void:
	var dim = Color(1, 1, 1) if ready else Color(0.4, 0.4, 0.45)
	var look = str(sk.get("look", "")).trim_suffix("_tint")
	var col = Content.color(sk.get("color", "ffffff"))
	var kind = str(sk.get("type", ""))
	var mid = r.get_center()
	match kind:
		"beam":
			if not _icon_beam(c, sk, look, r, dim):
				var w = clampf(float(sk.get("width", 8)) * 0.35, 1.5, r.size.y * 0.32)
				c.draw_line(Vector2(r.position.x + 2, mid.y), Vector2(r.end.x - 4, mid.y), Color(col.r, col.g, col.b, 0.35) * dim, w * 2.2)
				c.draw_line(Vector2(r.position.x + 2, mid.y), Vector2(r.end.x - 4, mid.y), col * dim, w)
				c.draw_line(Vector2(r.position.x + 2, mid.y), Vector2(r.end.x - 4, mid.y), Color(1, 1, 1) * dim, maxf(1.0, w * 0.4))
				c.draw_circle(Vector2(r.end.x - 4, mid.y), w * 1.1, col * dim)
				c.draw_circle(Vector2(r.end.x - 4, mid.y), w * 0.55, Color(1, 1, 1) * dim)
				if sk.get("sparks", false):
					for k in 6:
						var q = Vector2(r.position.x + 3 + k * 3.2, mid.y + (w + 2.0) * (1.0 if k % 2 == 0 else -1.0))
						c.draw_rect(Rect2(q, Vector2(1, 1)), Color(1, 0.9, 0.4) * dim)
			return
		"dash":
			var sid = int(sk.get("shape_set", set_id))
			var anim = int(sk.get("shape_anim", 1)) if sk.has("shape_set") else 16
			if _icon_sprite(c, sid, anim, 3, r, dim):
				return
		"slash":      # the sword in its sheath, cut from Trunks' back in the player's own game file
			var sw = _sword_icon()
			if sw != null:
				_icon_fit(c, sw, Rect2(Vector2.ZERO, sw.get_size()), r, dim)
				return
		"flash":
			for k in 8:
				var v = Vector2.from_angle(k * TAU / 8.0)
				c.draw_line(mid + v * 2.0, mid + v * r.size.y * 0.48, Color(1, 0.95, 0.6) * dim, 1.0)
			c.draw_circle(mid, r.size.y * 0.28, Color(1, 1, 0.85) * dim)
			c.draw_circle(mid, r.size.y * 0.16, Color(1, 1, 1) * dim)
			return
		"volley":
			for k in 4:
				var q = r.position + Vector2(4 + k * 5, r.size.y - 4 - k * 3)
				c.draw_circle(q, 2.2, Color(col.r, col.g, col.b, 0.5) * dim)
				c.draw_circle(q, 1.2, Color(1, 1, 1) * dim)
			return
		"buff", "heal":
			var ac = Content.color(sk.get("aura", sk.get("color", "ffffff")))
			c.draw_circle(mid, r.size.y * 0.45, Color(ac.r, ac.g, ac.b, 0.35) * dim)
			c.draw_arc(mid, r.size.y * 0.42, 0, TAU, 20, ac * dim, 1.0)
			if set_id >= 0 and _icon_sprite(c, set_id, 0, 0, r.grow(-2), dim):
				return
			c.draw_circle(mid, r.size.y * 0.2, ac.lightened(0.4) * dim)
			return
		"wave":
			for k in 3:
				c.draw_arc(mid, r.size.y * (0.18 + 0.15 * k), 0, TAU, 20, col * dim, 1.0)
			return
	# a ball (and anything else): the artist's sheet, the game's own ball, or a ball of the move's colour
	var tex: Texture2D = null
	var src = Rect2()
	var tint = dim
	if SHEET_LOOKS.has(look):
		tex = Assets.texture(Assets.builtin_dir().path_join("sprites/" + str(SHEET_LOOKS[look]["file"])))
		var ic: Array = SHEET_LOOKS[look].get("icon", [1, 0])      # (row, frame) shown in the HUD: a flying frame unless the sheet says
		var rw: Array = SHEET_LOOKS[look]["rows"][int(ic[0])]
		src = Rect2(int(ic[1]) * int(rw[1]), int(rw[0]), int(rw[1]), int(rw[1]))
	if tex == null:
		var name = ""
		if sk.has("rom"):
			var R: Dictionary = Content.rom_specials.get(str(sk["rom"]), {})
			name = str(R.get("charge_sheet", ""))
		elif BALL_LOOKS.has(look):
			name = BALL_LOOKS[look]
		var fx = Assets.efx(name) if name != "" else {}
		if not fx.is_empty():
			var fi = fx["frames"].size() - 1
			var f: Dictionary = fx["frames"][fi]
			tex = fx["tex"]; src = Rect2(fi * int(fx["cell"]), 0, f["w"], f["h"])
			if str(sk.get("look", "")).ends_with("_tint"):
				tint *= col.lightened(0.25)
	if tex == null or src.size.x <= 0:
		c.draw_circle(mid, r.size.y * 0.42, Color(col.r, col.g, col.b, 0.35) * dim)
		c.draw_circle(mid, r.size.y * 0.3, col * dim)
		c.draw_circle(mid, r.size.y * 0.14, Color(1, 1, 1) * dim)
		return
	_icon_fit(c, tex, src, r, tint)

var _sword_tex: Texture2D = null
func _sword_icon() -> Texture2D:
	if _sword_tex != null:
		return _sword_tex
	var st = Assets.sprite_set(128)      # future Trunks, standing seen from behind: the sword across his back
	if st.is_empty() or st["tex"] == null:
		return null
	var src: Image = st["img"] if st.has("img") else st["tex"].get_image()
	var cell: int = st["cell"]
	var a = Vector2(15, 11)
	var b = Vector2(5, 21.5)
	var out = Image.create(32, 32, false, Image.FORMAT_RGBA8)
	for y in 32:
		for x in 32:
			var col = src.get_pixel(x, cell + y)      # (row 1: facing up)
			if col.a < 0.5:
				continue
			var p = Vector2(x, y)
			var t = (p - a).dot(b - a) / (b - a).length_squared()
			if t < -0.08 or t > 1.05 or absf((p - a).cross(b - a)) / (b - a).length() > 1.9:
				continue
			if (col.h > 0.6 and col.h < 0.95 and col.s > 0.3):      # his jacket and hair, not the sword
				continue
			out.set_pixel(x, y, col)
	var u = out.get_used_rect()
	if u.size.x <= 0:
		return null
	_sword_tex = ImageTexture.create_from_image(out.get_region(u))
	return _sword_tex

func _icon_fit(c: Control, tex: Texture2D, src: Rect2, r: Rect2, tint: Color) -> void:
	# only the picture's own pixels count (the cell round it is empty): centred, as big as the window allows
	var img: Image = tex.get_image()
	if img != null:
		var u = img.get_region(Rect2i(src)).get_used_rect()
		if u.size.x > 0:
			src = Rect2(src.position + Vector2(u.position), Vector2(u.size))
	var k = minf(r.size.x / src.size.x, r.size.y / src.size.y)
	var d = src.size * k
	c.draw_texture_rect_region(tex, Rect2(r.get_center() - d * 0.5, d), src, tint)

## a frame of a sprite set (the hero dashing, Yamcha's wolf), fitted to the window
func _icon_sprite(c: Control, sid: int, anim: int, d: int, r: Rect2, tint: Color) -> bool:
	if sid < 0:
		return false
	var st = Assets.sprite_set(sid)
	if st.is_empty() or st["tex"] == null:
		return false
	var slots: Array = st["slots"]
	var s = anim * 4 + d
	if s >= slots.size() or slots[s].is_empty():
		s = 4 * 1 + d
		if s >= slots.size() or slots[s].is_empty():
			return false
	var f: Dictionary = slots[s][0]
	var cell: int = st["cell"]
	_icon_fit(c, st["tex"], Rect2(0, s * cell, f["w"], f["h"]), r, tint)
	return true

## a beam of the game's own pieces across the window, going right (the Kamehameha, Special Beam Cannon, coloured beams)
func _icon_beam(c: Control, sk: Dictionary, look: String, r: Rect2, tint: Color) -> bool:
	var sheet = ""
	var body = -1
	var head = -1
	if sk.has("rom"):
		var R: Dictionary = Content.rom_specials.get(str(sk["rom"]), {})
		if str(R.get("kind", "")) != "beam":
			# the game's own blast thrown straight ahead (the Galick Gun): its flying frame, going right
			var bfx = Assets.efx(str(R.get("sheet", "")))
			if bfx.is_empty():
				return false
			var fly: Array = R.get("fly", [0])
			var fi = int(fly[0]) + (4 * 3 if int(R.get("group", 0)) == 4 else 0)
			fi = clampi(fi, 0, bfx["frames"].size() - 1)
			var bf: Dictionary = bfx["frames"][fi]
			_icon_fit(c, bfx["tex"], Rect2(fi * int(bfx["cell"]), 0, bf["w"], bf["h"]), r, tint)
			return true
		sheet = str(R.get("sheet", ""))
		var g = int(R.get("group", 8)) * 3
		var F: Dictionary = R.get("frames", {})
		body = g + int(F.get("body", 0)); head = g + int(F.get("head", 0))
	elif BEAM_LOOKS.has(look):
		var lk: Array = BEAM_LOOKS[look]
		sheet = lk[0]; body = int(lk[1][1]); head = int(lk[2][2])
		tint *= lk[4]
	else:
		return false
	var fx = Assets.efx(sheet)
	if fx.is_empty() or body >= fx["frames"].size() or head >= fx["frames"].size():
		return false
	var cell: int = fx["cell"]
	var fb: Dictionary = fx["frames"][body]
	var fh: Dictionary = fx["frames"][head]
	var bh = float(fb["h"])
	var y = r.get_center().y - bh * 0.5
	var x = r.position.x
	while x < r.end.x - float(fh["w"]) * 0.6:
		var w = minf(float(fb["w"]), r.end.x - x)
		c.draw_texture_rect_region(fx["tex"], Rect2(x, y, w, bh), Rect2(body * cell, 0, w, bh), tint)
		x += maxf(4.0, float(fb["w"]) - 2.0)
	var hw = minf(float(fh["w"]), r.size.x * 0.6)
	var hh = float(fh["h"]) * hw / float(fh["w"])
	c.draw_texture_rect_region(fx["tex"], Rect2(r.end.x - hw, r.get_center().y - hh * 0.5, hw, hh), Rect2(head * cell, 0, fh["w"], fh["h"]), tint)
	return true

func _player_hud(c: Control, L: Local, right: bool) -> void:
	var vs = _hud_vs      # (the HUD is drawn scaled: see _hud_scale)
	var f: FighterSim = L.fighter
	var S = 1.5      # the GBA's bars, a size up
	var w = (HUD_LEN + 38) * S
	var x = vs.x - w - 6.0 if right else 6.0
	var nxt0 = int(levels[mini(f.level, levels.size() - 1)]) if f.level < levels.size() else f.exp
	var prev0 = int(levels[mini(f.level - 1, levels.size() - 1)]) if f.level >= 1 and f.level - 1 < levels.size() else 0
	var sk = f.current_skill()
	var ready = true
	if not sk.is_empty():
		ready = int(f.cooldowns.get(str(sk["id"]), 0)) == 0 and f.ep >= int(sk.get("ep", 0))
	# (on top of the HUD's own scale: setting a plain transform here undid it - the box stayed big and the minimap,
	# drawn after, went off the screen)
	c.draw_set_transform(Vector2(x, 4) * _hs, 0.0, Vector2(S, S) * _hs)
	_gba_bars(c, 0, 0, f.hp / maxf(1.0, f.maxhp), f.ep / maxf(1.0, f.maxep), clampf(float(f.exp - prev0) / maxf(1.0, float(nxt0 - prev0)), 0.0, 1.0), sk, ready, f.set_id)
	c.draw_set_transform(Vector2.ZERO, 0.0, Vector2(_hs, _hs))
	if locals.size() > 1:      # split screen: whose bars these are
		_ds(c, ThemeDB.fallback_font, Vector2(x, 4 + 24 * S + 8), "P%d" % (L.k + 1), HORIZONTAL_ALIGNMENT_LEFT, 30, 8, Color(1, 0.9, 0.4) if L.k == 0 else Color(0.5, 1, 0.6))

## a small map of the place in the corner: friends, foes, the boss, ways out
func _minimap(c: Control, L: Local, i: int) -> void:
	var vs = _hud_vs
	var a: Dictionary = L.area
	if a.is_empty():
		return
	var w = float(a["w"]); var h = float(a["h"])
	var vr = Rect2(0, 0, w, h)
	if a.has("mini") and (w > 700 or h > 500):
		# a big land: the part around you
		var fc = Vector2(L.fighter.x, L.fighter.y)
		vr = Rect2(clampf(fc.x - 320, 0, maxf(0, w - 640)), clampf(fc.y - 220, 0, maxf(0, h - 440)), minf(640, w), minf(440, h))
	var sc = minf(84.0 / vr.size.x, 58.0 / vr.size.y)
	var size = vr.size * sc
	var org = Vector2(vs.x - size.x - 6, 22) if (locals.size() == 1 or i == 1) else Vector2(6, 56)
	if locals.size() > 1 and i == 1:
		org.y = 56
	c.draw_rect(Rect2(org - Vector2(2, 2), size + Vector2(4, 4)), Color(0, 0, 0, 0.55))
	var meta: Dictionary = a["meta"]
	var pri: Array = meta.get("pri", [0, 0, 0, 0])
	var order = [0, 1, 2, 3]
	order.sort_custom(func(x, y): return int(pri[x]) > int(pri[y]) if int(pri[x]) != int(pri[y]) else x > y)
	if a.get("mini") != null:
		c.draw_texture_rect_region(a["mini"], Rect2(org, size), Rect2(vr.position / 8.0, vr.size / 8.0), Color(1, 1, 1, 0.9))
	else:
		for k in order:
			var tex: Texture2D = a["layers"][k]
			if tex != null:
				c.draw_texture_rect(tex, Rect2(org, size), false, Color(1, 1, 1, 0.85))
	c.draw_rect(Rect2(org, size), Color(1, 1, 1, 0.35), false, 1.0)
	var to_map = func(x: float, y: float) -> Vector2:
		return org + (Vector2(clampf(x, vr.position.x, vr.end.x), clampf(y, vr.position.y, vr.end.y)) - vr.position) * sc
	for ex in Game.planet.nodes[L.node_i]["exits"]:
		var r: Array = ex["rect"]
		# only the part of a way out inside the minimap's view (a big or far one used to draw long yellow bars down the screen)
		var er = Rect2(float(r[0]), float(r[1]), float(r[2] - r[0]), float(r[3] - r[1])).intersection(vr)
		if er.size.x <= 0.0 and er.size.y <= 0.0 and not vr.has_point(Vector2(r[0], r[1])):
			continue
		c.draw_rect(Rect2(org + (er.position - vr.position) * sc, Vector2(maxf(2, er.size.x * sc), maxf(2, er.size.y * sc))), Color(1, 0.9, 0.3, 0.9))
	var key: String = Game.planet.nodes[L.node_i]["key"]
	for e in Game.area_states.get(key, []):
		var fl = int(e[9])
		if fl & 4:
			continue
		var q: Vector2 = to_map.call(float(e[1]), float(e[2]))
		if fl & 2:
			c.draw_circle(q, 2.5, Color(1, 0.75, 0.2))
			c.draw_arc(q, 3.5, 0, TAU, 10, Color(1, 0.2, 0.1), 1.0)
		else:
			c.draw_rect(Rect2(q - Vector2(1, 1), Vector2(2, 2)), Color(1, 0.85, 0.3) if fl & 1 else Color(1, 0.3, 0.25))
	for pid in Game.remote_states:
		var st: Dictionary = Game.remote_states[pid]
		if int(st.get("node", -1)) == L.node_i:
			c.draw_circle(to_map.call(float(st["x"]), float(st["y"])), 2.0, Color(0.4, 0.9, 1))
	for o in locals:
		if o.node_i == L.node_i:
			var q2: Vector2 = to_map.call(o.fighter.x, o.fighter.y)
			c.draw_circle(q2, 2.2 if o == L else 2.0, Color(1, 0.95, 0.4) if o.k == 0 else Color(0.5, 1, 0.6))
			if o == L:
				c.draw_arc(q2, 3.5, 0, TAU, 10, Color(1, 1, 1, 0.8), 1.0)

# ------------------------------------------------------------------ the game's own letters
## every word on the game's screen (names, the HUD's lines, messages, the START menu) in the cartridge's own small
## font, drawn pixel by pixel on whole screen pixels - a modern smooth font did not look like a GBA game.
## Sizes: speech 1 font pixel = 1 game pixel ("4x" on a handheld); everything else 3/4 of that ("3x"); big words 2.
var _pf_tex: Texture2D
var _pf_glyph = {}
var _pf_top = 0
var _pf_h = 8
var _pf_tried = false
var _txt_scale = 1.0       # the drawing's own scale just now (the HUD box, the START menu)
func _pf_ok() -> bool:
	if not _pf_tried:
		_pf_tried = true
		var img = Assets.image(Assets.base_dir.path_join("ui/font_small.png"))
		var j = Assets.json(Assets.base_dir.path_join("ui/font_small.json"))
		if img != null and j is Dictionary and j.get("glyphs") is Dictionary:
			var r = img.get_used_rect()
			_pf_top = r.position.y
			_pf_h = maxi(1, r.size.y)
			_pf_glyph = j["glyphs"]
			_pf_tex = ImageTexture.create_from_image(img)
	return _pf_tex != null

## screen pixels for one game pixel here
func _pf_game_px() -> float:
	var ws = Vector2(get_window().size)
	var vs = get_viewport().get_visible_rect().size
	return maxf(1.0, ws.x / maxf(1.0, vs.x))

## the drawing units for one font pixel: frac of a game pixel, rounded to whole screen pixels (crisp)
func _pf_unit(frac: float) -> float:
	# (in proportion to what it is drawn in - the START menu, the HUD box - which grow and shrink with VIEW SIZE:
	# kept the same on the screen, the words were tiny at x2 and ran out of the menu at x6)
	var g = _pf_game_px() * _txt_scale
	return maxf(1.0, roundf(g * frac)) / g

func _pf_width(t: String, u: float) -> float:
	var w = 0.0
	for ch in t:
		var gl = _pf_glyph.get(str(ch.unicode_at(0)), _pf_glyph.get(str(ch.to_upper().unicode_at(0)), [0, 3]))
		w += (float(gl[1]) + 1.0) * u
	return maxf(0.0, w - u)

## text with its top-left at pos (snapped to whole screen pixels); a thin dark edge for light letters
func _pf_draw(c: Control, pos: Vector2, t: String, col: Color, u: float, edge: bool) -> void:
	var px = 1.0 / (_pf_game_px() * _txt_scale)
	var x0 = roundf(pos.x / px) * px
	var y0 = roundf(pos.y / px) * px
	var passes = []
	if edge:
		var e = Color(0, 0, 0, 0.75 * col.a)
		passes = [[Vector2(-u, 0), e], [Vector2(u, 0), e], [Vector2(0, -u), e], [Vector2(0, u), e]]
	passes.append([Vector2.ZERO, col])
	for pp in passes:
		var x = x0
		for ch in t:
			var gl = _pf_glyph.get(str(ch.unicode_at(0)), _pf_glyph.get(str(ch.to_upper().unicode_at(0)), [0, 3]))
			var gw = float(gl[1])
			if ch != " ":
				c.draw_texture_rect_region(_pf_tex, Rect2(Vector2(x, y0) + pp[0], Vector2(gw, _pf_h) * u), Rect2(float(gl[0]), _pf_top, gw, _pf_h), pp[1])
			x += (gw + 1.0) * u

## a line that is too long for the room it has, cut into lines at spaces (the START menu's controls ran off the menu)
func _wrap_line(t: String, room: float, size: int) -> Array:
	var u = _pf_unit(2.0 if size >= 14 else 0.75) if _pf_ok() else 0.0
	var wf = func(x: String) -> float: return _pf_width(x, u) if _pf_ok() else ThemeDB.fallback_font.get_string_size(x, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	if room <= 0 or wf.call(t) <= room:
		return [t]
	var out = []
	var cur = ""
	for w in t.split(" "):
		var nxt = w if cur == "" else cur + " " + w
		if cur != "" and wf.call(nxt) > room:
			out.append(cur)
			cur = w
		else:
			cur = nxt
	if cur != "":
		out.append(cur)
	return out

## draw_string's stand-in (same arguments): pos is the baseline, as with a font
func _ds(c: Control, font: Font, pos: Vector2, t: String, align: int = HORIZONTAL_ALIGNMENT_LEFT, width: float = -1.0, size: int = 16, col: Color = Color.WHITE) -> void:
	if not _pf_ok():
		c.draw_string(font, pos, t, align, width, size, col)
		return
	var u = _pf_unit(2.0 if size >= 14 else 0.75)
	var tw = _pf_width(t, u)
	var x = pos.x
	if width > 0 and align == HORIZONTAL_ALIGNMENT_CENTER:
		x += (width - tw) / 2.0
	elif width > 0 and align == HORIZONTAL_ALIGNMENT_RIGHT:
		x += width - tw
	var light = col.r * 0.3 + col.g * 0.59 + col.b * 0.11 > 0.45
	_pf_draw(c, Vector2(x, pos.y - _pf_h * u), t, col, u, light)

## draw_string_outline's stand-in: the game's letters bring their own edge
func _dso(c: Control, font: Font, pos: Vector2, t: String, align: int = HORIZONTAL_ALIGNMENT_LEFT, width: float = -1.0, size: int = 16, outline: int = 1, col: Color = Color.WHITE) -> void:
	if not _pf_ok():
		c.draw_string_outline(font, pos, t, align, width, size, outline, col)

## the names over people's heads and their speech bubbles, drawn here on the screen's own layer (full sharpness, like
## the HUD's words) - in the small world picture that is then enlarged they were blurry or broken. One screen only:
## split screen keeps them in the picture.
func _draw_names(c: Control) -> void:
	ActorView.labels_outside = not split_now
	if split_now or locals.is_empty() or not views.has(locals[0].node_i) or svs.is_empty():
		return
	var avn = views[locals[0].node_i]
	var ct: Transform2D = svs[0].get_canvas_transform()
	var font = ThemeDB.fallback_font
	for v in avn.ents.get_children():
		if not (v is ActorView) or not v.is_visible_in_tree():
			continue
		var gt: Transform2D = ct * v.get_global_transform()
		var a = v.modulate.a
		if v.label != "" and words_on:
			var p = gt * Vector2(0, v.label_y)
			_dso(c, font, Vector2(p.x - 70, p.y), v.label, HORIZONTAL_ALIGNMENT_CENTER, 140, 8, 2, Color(0, 0, 0, 0.7 * a))
			_ds(c, font, Vector2(p.x - 70, p.y), v.label, HORIZONTAL_ALIGNMENT_CENTER, 140, 8, Color(v.label_color, v.label_color.a * a))
		if v.bubble != "":
			# speech: the game's font at a game pixel to a font pixel (4x on a handheld), dark on the white bubble
			var b = gt * Vector2(0, v.bubble_y)
			var u = _pf_unit(1.0) if _pf_ok() else 1.0
			var tw = _pf_width(v.bubble, u) if _pf_ok() else font.get_string_size(v.bubble, HORIZONTAL_ALIGNMENT_LEFT, -1, 8).x
			var bh = (_pf_h + 4) * u if _pf_ok() else 12.0
			var w = tw + 4 * u
			c.draw_rect(Rect2(b.x - w / 2, b.y - bh - 2, w, bh), Color(1, 1, 1, 0.92 * a))
			c.draw_rect(Rect2(b.x - w / 2, b.y - bh - 2, w, bh), Color(0, 0, 0, 0.9 * a), false, maxf(1.0, u))
			if _pf_ok():
				_pf_draw(c, Vector2(b.x - tw / 2, b.y - bh - 2 + 2 * u), v.bubble, Color(0.05, 0.05, 0.1, a), u, false)      # (inside the box, 2 font pixels down)
			else:
				c.draw_string(font, Vector2(b.x - w / 2 + 4, b.y - 5), v.bubble, HORIZONTAL_ALIGNMENT_LEFT, w - 6, 8, Color(0.05, 0.05, 0.1, a))

func _draw_hud() -> void:
	var c = hud_draw
	var font = ThemeDB.fallback_font
	var vs = c.get_viewport_rect().size
	# a MOOD box: darkness (a light round each fighter), weather
	for i in locals.size():
		var Lm: Local = locals[i]
		var dk = float(Lm.mood.get("dark", 0))
		if dk > 0.01:
			_draw_dark(c, _light_centre(i), float(Lm.mood.get("light", 70)), Color(0, 0, 0.04, dk), vs)
		var wt = str(Lm.mood.get("weather", ""))
		if wt != "" and (i == 0 or split_now):
			_draw_weather(c, wt, vs)
	# blind: only a little round the fighter can be seen
	for i in locals.size():
		var Lb: Local = locals[i]
		if Lb.fighter.has_state_flag("blind"):
			_draw_dark(c, _light_centre(i), 46.0, Color(0, 0, 0, 0.93), vs)
	_draw_names(c)
	# the HUD box (bars, special, EXP, minimap, partners) at the same size on the screen whatever the VIEW SIZE
	var hs = _hud_scale(vs)
	var vs_real = vs
	vs = vs / hs
	_hud_vs = vs
	_hs = hs
	_txt_scale = hs
	c.draw_set_transform(Vector2.ZERO, 0.0, Vector2(hs, hs))
	for i in locals.size():
		if hud_on:
			_player_hud(c, locals[i], i == 1)
		if minimap_on:
			_minimap(c, locals[i], i)
		# the states on you, under your bars
		var Ls: Local = locals[i]
		if hud_on and not Ls.fighter.states.is_empty():
			var sx = vs.x - 182.0 if i == 1 else 6.0
			for id in Ls.fighter.states:
				var stt = Content.state(id)
				var left = int(Ls.fighter.states[id])
				var lab = str(stt.get("name", id)) + ("" if left < 0 else " %d" % ceili(left / 60.0))
				var tw = (_pf_width(lab, _pf_unit(0.75)) if _pf_ok() else font.get_string_size(lab, HORIZONTAL_ALIGNMENT_LEFT, -1, 6).x) + 6
				c.draw_rect(Rect2(sx - 1, 51, tw, 9), Color(0, 0, 0, 0.6))
				_ds(c, font, Vector2(sx + 2, 58), lab, HORIZONTAL_ALIGNMENT_LEFT, -1, 6, Content.color(stt.get("color", "ffffff")))
				sx += tw + 2
	if locals.size() == 1 and hud_on and words_on:
		_ds(c, font, Vector2(vs.x - 190, 10), Game.planet.title, HORIZONTAL_ALIGNMENT_RIGHT, 184, 8, Color(1, 0.9, 0.5))
	# partners online
	var py = 64 if not (minimap_on and locals.size() > 1) else 124
	for pid in (Game.remote_states if hud_on and words_on else {}):
		var st: Dictionary = Game.remote_states[pid]
		var where = "?"
		var nd = int(st.get("node", -1))
		if nd >= 0 and nd < Game.planet.nodes.size():
			where = Game.planet.nodes[nd]["name"]
		var ptag = ""
		for Lp in locals:
			if Lp.party.has(pid):
				ptag = "[PARTY] "
		_ds(c, font, Vector2(6, py), ptag + ("%s LV %d - %s" % [str(st.get("name", "P2")), int(st.get("lvl", 1)), where] if str(st.get("name", "")) == Assets.CHARACTERS[clampi(int(st.get("ch", 0)), 0, Assets.CHARACTERS.size() - 1)] else "%s (%s) LV %d - %s" % [str(st.get("name", "P2")), Assets.CHARACTERS[clampi(int(st.get("ch", 0)), 0, Assets.CHARACTERS.size() - 1)], int(st.get("lvl", 1)), where]), HORIZONTAL_ALIGNMENT_LEFT, -1, 7, Color(0.6, 0.9, 1))
		_bar(c, 6, py + 2, 50, float(st.get("hp", 0)), float(st.get("maxhp", 1)), Color(0.2, 0.8, 0.9))
		py += 14
	c.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	_hs = 1.0
	_txt_scale = 1.0
	vs = vs_real
	# each player's place name, on their own part of the screen
	for i in locals.size():
		var L: Local = locals[i]
		if L.banner_t > 0 and words_on:
			var sc = _side_centre(i)
			var bx = clampf(sc.x, 112, vs.x - 112)
			var by = 72.0 if not split_now else clampf(sc.y - 70, 72, vs.y - 60)
			c.draw_rect(Rect2(bx - 110, by - 12, 220, 16), Color(0, 0, 0, 0.6))
			_ds(c, font, Vector2(bx - 110, by), L.banner, HORIZONTAL_ALIGNMENT_CENTER, 220, 9, Color(1, 1, 0.8))
	for i in locals.size():
		_draw_talk(c, locals[i], i)
		var Ld: Local = locals[i]
		var same_pc = not Ld.duel.is_empty() and int(Ld.duel["with"]) / 8 == Game.my_id()
		if not Ld.duel.is_empty() and not (same_pc and i == 1 and not split_now):
			var sc2 = _side_centre(i)
			var t2 = int(Ld.duel["t"])
			var txt = ("%d" % ceili(t2 / 60.0)) if t2 >= 60 else ("FIGHT!" if t2 > 0 else ("DUEL: %s VS %s" % [Ld.name, Ld.duel["name"]] if same_pc and not split_now else "DUEL: %s" % Ld.duel["name"]))
			var big = 18 if t2 > 0 else 7
			var yy = sc2.y - 40 if t2 > 0 else 84.0
			_dso(c, font, Vector2(sc2.x - 100, yy), txt, HORIZONTAL_ALIGNMENT_CENTER, 200, big, 3, Color(0, 0, 0, 0.8))
			_ds(c, font, Vector2(sc2.x - 100, yy), txt, HORIZONTAL_ALIGNMENT_CENTER, 200, big, Color(1, 0.55, 0.35))
	var ty = vs.y - 14
	for i in (range(toasts.size() - 1, -1, -1) if words_on else []):
		var t = toasts[i]
		_dso(c, font, Vector2(0, ty), t[0], HORIZONTAL_ALIGNMENT_CENTER, vs.x, 8, 3, Color(0, 0, 0, 0.8))
		_ds(c, font, Vector2(0, ty), t[0], HORIZONTAL_ALIGNMENT_CENTER, vs.x, 8, t[1])
		ty -= 11
	var cy = vs.y - 60
	for i in range(chat_log.size() - 1, -1, -1):
		var cl = chat_log[i]
		_dso(c, font, Vector2(6, cy), cl[0], HORIZONTAL_ALIGNMENT_LEFT, 300, 7, 3, Color(0, 0, 0, 0.8))
		_ds(c, font, Vector2(6, cy), cl[0], HORIZONTAL_ALIGNMENT_LEFT, 300, 7, cl[1])
		cy -= 9
	if (Game.cfg["mode"] != "solo" or not Game.remote_states.is_empty()) and words_on:
		var online = 1 + Game.remote_states.size()
		var tag = "ONLINE - %d IN THE WORLD" % (online + locals.size() - 1)
		if Game.reconnect_tries > 0:
			tag = "RECONNECTING..."
		_ds(c, font, Vector2(vs.x / 2 - 60, vs.y - 3), tag, HORIZONTAL_ALIGNMENT_CENTER, 120, 6, Color(0.6, 0.9, 1) if Game.reconnect_tries == 0 else Color(1, 0.6, 0.4))
	if map_open:
		_draw_map(c)
	_draw_timers(c, vs)
	if debug_on:
		_draw_debug(c, vs)
	if perf_on:      # F3: how fast it runs here (for slow computers: what to make lighter)
		var pl = ["%d FPS   frame %.1f ms   logic %.1f ms" % [Engine.get_frames_per_second(), 1000.0 / maxf(1.0, Engine.get_frames_per_second()), Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0 + Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0],
			"draw calls %d   objects drawn %d   nodes %d" % [Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME), Performance.get_monitor(Performance.OBJECT_NODE_COUNT)],
			"%s - %s" % [RenderingServer.get_current_rendering_driver_name(), RenderingServer.get_video_adapter_name()]]
		c.draw_rect(Rect2(4, vs.y - 44, 300, 40), Color(0, 0, 0, 0.7))
		for k in pl.size():
			_ds(c, font, Vector2(8, vs.y - 32 + k * 11), pl[k], HORIZONTAL_ALIGNMENT_LEFT, 296, 7, Color(0.6, 1, 0.6))
	if credits_t >= 0:
		_draw_credits(c, vs)
	if victory_t > 0:
		c.draw_rect(Rect2(vs.x / 2 - 130, vs.y / 2 - 40, 260, 80), Color(0, 0, 0.1, 0.85))
		_ds(c, font, Vector2(vs.x / 2 - 130, vs.y / 2 - 18), victory_text, HORIZONTAL_ALIGNMENT_CENTER, 260, 11, Color(1, 0.85, 0.3))
		var kills = 0
		var lv = []
		for L in locals:
			kills += L.kills
			lv.append(str(L.fighter.level))
		_ds(c, font, Vector2(vs.x / 2 - 130, vs.y / 2 + 2), "FOES BEATEN %d   LEVEL %s" % [kills, " / ".join(PackedStringArray(lv))], HORIZONTAL_ALIGNMENT_CENTER, 260, 8, Color(1, 1, 1))
		_ds(c, font, Vector2(vs.x / 2 - 130, vs.y / 2 + 20), "THE PLANET STAYS OPEN", HORIZONTAL_ALIGNMENT_CENTER, 260, 8, Color(0.6, 1, 0.6))
	for i in locals.size():
		if not locals[i].menu.is_empty():
			_draw_menu(c, locals[i], i)
	if paused:
		_ds(c, font, Vector2(0, vs.y - 6), "THE WORLD WAITS WHILE YOUR MENU IS OPEN", HORIZONTAL_ALIGNMENT_CENTER, vs.x, 6, Color(0.7, 0.7, 0.8))

func _exit_tree() -> void:
	ActorView.labels_outside = false      # (the map editor draws its own)
	# closing the game keeps your fighter (level, stats, EXP) - on your own PC
	save_all()

# ------------------------------------------------------------------ music
var eshot_seen = {}           # foes' throws already heard (by id)
var music_test = -1
const MUSIC_SLOTS = ["title", "field", "cave", "lair", "boss", "victory"]
var sound_test = -1
var music_test_hold = 0
func _pick_music() -> void:
	if locals.is_empty() or Engine.get_physics_frames() % 30 != 0:
		return
	if music_test_hold > 0:      # a song picked in MUSIC TEST plays on for a minute
		music_test_hold -= 30
		return
	if victory_t > 760:
		Music.play("victory")
		return
	var L: Local = locals[0]
	var nd: Dictionary = Game.planet.nodes[L.node_i]
	var song = "field"
	if int(nd["kind"]) == 2:
		song = "lair"
		for e in Game.area_states.get(str(nd["key"]), []):
			if int(e[9]) & 2 and Vector2(float(e[1]) - L.fighter.x, float(e[2]) - L.fighter.y).length() < 260:
				song = "boss"
	elif int(nd["kind"]) != 0:
		song = "cave"
	# your own song for this very place, if you put one in the music folder ("west city.ogg")
	if song != "boss" and L.place != "" and Music.file_for(L.place) != "":
		song = L.place.to_lower()
	if str(L.mood.get("music", "")) != "" and song != "boss":
		song = str(L.mood["music"])       # a MOOD box's own song
	if L.ev.has("fight"):
		song = "boss"
	# the game's own song for this place (what the GBA plays here), unless a song of yours is set for it
	if not (str(L.mood.get("music", "")) != "" or (L.place != "" and Music.file_for(L.place) != "")):
		if not ((song == "boss" or song == "lair") and Music.file_for(song) != ""):
			var n = Assets.area_song(L.area, Vector2(L.fighter.x, L.fighter.y)) if not L.area.is_empty() else -1
			if n >= 0:
				song = "rom:%d" % n
	Music.play(song)

# ------------------------------------------------------------------ the menu (each player has their own)
const TABS = ["STATUS", "MISSIONS", "SPECIALS", "ITEMS", "GEAR", "SHOP", "FRIENDS", "SAY", "OPTIONS"]
const TABS_SHORT = ["STAT", "MISS", "SPEC", "ITEM", "GEAR", "SHOP", "FRND", "SAY", "OPT"]
const PHRASES = ["HELLO!", "FOLLOW ME!", "WAIT FOR ME!", "HELP!", "THANKS!", "GOOD JOB!", "LET'S FIGHT THE BOSS!",
	"WORLD BOSS - LET'S GO!", "I NEED A SENZU BEAN", "WANT TO TRADE?", "BACK IN A MINUTE", "GOOD GAME!"]

func _any_menu() -> bool:
	for L in locals:
		if not L.menu.is_empty():
			return true
	return false

func _shop(id: String) -> Dictionary:
	if id == "":
		return {}
	for s in Content.shops:
		if str(s.get("id", "")) == id:
			return s
	return {}

## a shopkeeper (or an event) opens their shop
func _open_shop(L: Local, id: String) -> void:
	L.menu = {"tab": TABS.find("SHOP"), "row": 0, "mode": "", "act": 0, "target": 0, "amount": 1, "shop": id}
	Sfx.play("menu")

func _menu_open(L: Local) -> void:
	L.menu = {"tab": 0, "row": 0, "mode": "", "act": 0, "target": 0, "amount": 1}
	Sfx.play("menu")

func _menu_close(L: Local) -> void:
	L.menu = {}
	Sfx.play("menu")

func _pressed(L: Local, raw: Dictionary, b: String) -> bool:
	return raw.get(b, false) and not L.mprev.get(b, false)

func _menu_rows(L: Local) -> Array:
	var f: FighterSim = L.fighter
	match TABS[int(L.menu["tab"])]:
		"STATUS":
			return f.forms
		"MISSIONS":
			return _quest_rows(f)
		"SPECIALS":
			return f.skills
		"ITEMS":
			var out = []
			for it in Content.items + Content.gear:
				if int(f.inv.get(str(it["id"]), 0)) > 0:
					out.append(it)
			out.append({"id": "zeni", "name": "ZENI"})
			return out
		"GEAR":
			return Content.SLOTS
		"SHOP":
			var out = []
			var sh = _shop(str(L.menu.get("shop", "")))
			if not sh.is_empty():
				# a shopkeeper's own goods (DEV TOOLS - SHOPS)
				for e in sh.get("items", []):
					var it: Dictionary = Content.item(str(e.get("id", ""))).duplicate()
					if it.is_empty():
						continue
					it["price"] = int(e.get("price", it.get("price", 10)))
					out.append(it)
				return out
			for it in Content.items + Content.gear:
				if int(it.get("price", 0)) > 0:
					out.append(it)
			return out
		"FRIENDS":
			if not L.trade.is_empty():
				return _trade_rows(L)
			return _friend_rows(L)
		"SAY":
			return PHRASES
		"OPTIONS":
			return ["MUSIC", "SOUND", "FULLSCREEN", "VIEW SIZE", "HUD / MINIMAP", "MUSIC TEST", "SOUND TEST", "SHOW CONTROLS", "ON-SCREEN BUTTONS", "A/B BUTTONS", "WORDS ON SCREEN", "QUIT TO TITLE AND SAVE GAME"]
	return []

func _menu_step(L: Local, raw: Dictionary) -> void:
	var m: Dictionary = L.menu
	if m.is_empty():
		return
	var f: FighterSim = L.fighter
	var up = _pressed(L, raw, "up")
	var down = _pressed(L, raw, "down")
	var left = _pressed(L, raw, "left")
	var right = _pressed(L, raw, "right")
	var ok = _pressed(L, raw, "a") or _pressed(L, raw, "ok") or L.mouse_ok
	var back = _pressed(L, raw, "b") or _pressed(L, raw, "mn") or L.mouse_back
	L.mouse_ok = false; L.mouse_back = false
	if paused:
		L.mprev = raw.duplicate()
	var rows = _menu_rows(L)
	var tab: String = TABS[int(m["tab"])]
	if tab == "FRIENDS" and not L.trade.is_empty():
		_trade_step(L, rows, up, down, left, right, ok, back)
		return
	if m["mode"] == "act":
		var acts = _item_acts(L)
		if up: m["act"] = (int(m["act"]) - 1 + acts.size()) % acts.size(); Sfx.play("move")
		if down: m["act"] = (int(m["act"]) + 1) % acts.size(); Sfx.play("move")
		if back: m["mode"] = ""; Sfx.play("menu")
		if ok:
			var it: Dictionary = rows[clampi(int(m["row"]), 0, rows.size() - 1)]
			match acts[int(m["act"])]:
				"USE":
					f.use_item(str(it["id"]))
					m["mode"] = ""
				"PUT ON ITEM BUTTON":
					f.quick = str(it["id"])
					toasts.append(["ITEM BUTTON: " + str(it["name"]), Color(0.8, 1, 0.8), 120])
					m["mode"] = ""
				"GIVE TO A FRIEND":
					if _gift_targets(L).is_empty():
						toasts.append(["NOBODY ELSE IN THE WORLD TO GIVE TO", Color(1, 0.7, 0.6), 140])
						Sfx.play("error")
						m["mode"] = ""
					else:
						m["mode"] = "give"; m["target"] = 0; m["amount"] = 10 if str(it["id"]) == "zeni" else 1
				_:
					m["mode"] = ""
			Sfx.play("menu")
		return
	if m["mode"] == "give":
		var tg = _gift_targets(L)
		var it: Dictionary = rows[clampi(int(m["row"]), 0, rows.size() - 1)]
		var id = str(it["id"])
		var have = f.zeni if id == "zeni" else int(f.inv.get(id, 0))
		var step = 10 if id == "zeni" else 1
		if tg.is_empty():
			m["mode"] = ""
			return
		if left: m["target"] = (int(m["target"]) - 1 + tg.size()) % tg.size(); Sfx.play("move")
		if right: m["target"] = (int(m["target"]) + 1) % tg.size(); Sfx.play("move")
		if up: m["amount"] = mini(have, int(m["amount"]) + step); Sfx.play("move")
		if down: m["amount"] = maxi(mini(have, step), int(m["amount"]) - step); Sfx.play("move")
		m["amount"] = clampi(int(m["amount"]), 0, have)
		if back: m["mode"] = ""; Sfx.play("menu")
		if ok and int(m["amount"]) > 0:
			var t = tg[clampi(int(m["target"]), 0, tg.size() - 1)]
			var n = int(m["amount"])
			if id == "zeni":
				f.zeni -= n
			else:
				f.inv[id] = int(f.inv[id]) - n
				if f.inv[id] <= 0:
					f.inv.erase(id)
			Game.give(int(t[1]), id, n, L.name)
			toasts.append(["YOU GAVE %s %s" % [t[0], ("%d ZENI" % n) if id == "zeni" else "%s x%d" % [it["name"], n]], Color(0.7, 1, 0.8), 160])
			Sfx.play("item")
			Game.save_fighter(f, L.k)
			m["mode"] = ""
		return
	# tabs and rows
	if left:
		m["tab"] = (int(m["tab"]) - 1 + TABS.size()) % TABS.size(); m["row"] = 0; Sfx.play("move")

	if right:
		m["tab"] = (int(m["tab"]) + 1) % TABS.size(); m["row"] = 0; Sfx.play("move")
	if rows.size() > 0:
		if up: m["row"] = (int(m["row"]) - 1 + rows.size()) % rows.size(); Sfx.play("move")
		if down: m["row"] = (int(m["row"]) + 1) % rows.size(); Sfx.play("move")
	if back:
		_menu_close(L)
		return
	if not ok or rows.is_empty():
		return
	var row = rows[clampi(int(m["row"]), 0, rows.size() - 1)]
	match tab:
		"STATUS":
			pass
		"SPECIALS":
			var u = f.unlocked_skills()
			var idx = u.find(row)
			if idx >= 0:
				f.skill_i = idx
				toasts.append(["SPECIAL: " + str(row["name"]), Color(0.7, 1, 1), 120])
				Sfx.play("menu")
			else:
				toasts.append(["%s - AT LEVEL %d" % [row["name"], int(row.get("level", 1))], Color(1, 0.8, 0.6), 120])
				Sfx.play("error")
		"ITEMS":
			m["mode"] = "act"; m["act"] = 0
			Sfx.play("menu")
		"GEAR":
			# the next piece you own for this slot (or nothing)
			var sl: String = row
			var owned = []
			for g in Content.gear:
				if str(g["slot"]) == sl and int(f.inv.get(str(g["id"]), 0)) > 0:
					owned.append(str(g["id"]))
			if owned.is_empty():
				if f.equip.has(sl):
					f.take_off(sl)
					toasts.append(["TOOK OFF THE " + sl.to_upper(), Color(0.8, 0.8, 1), 120])
				else:
					toasts.append(["NO %s GEAR YET - FOES DROP IT, THE SHOP SELLS SOME" % sl.to_upper(), Color(1, 0.8, 0.6), 150])
					Sfx.play("error")
			else:
				var msg = f.wear(owned[0])
				toasts.append([msg, Color(0.8, 1, 0.8), 140])
			Game.save_fighter(f, L.k)
		"SHOP":
			var price = int(row.get("price", 0))
			if f.zeni < price:
				toasts.append(["NOT ENOUGH ZENI (%d NEEDED)" % price, Color(1, 0.7, 0.6), 120])
				Sfx.play("error")
			elif f.add_item(str(row["id"]), 1) <= 0:
				toasts.append(["YOU CAN'T CARRY MORE", Color(1, 0.7, 0.6), 120])
				Sfx.play("error")
			else:
				f.zeni -= price
				toasts.append(["BOUGHT " + str(row["name"]), Color(0.8, 1, 0.8), 120])
				Sfx.play("zeni")
				Game.save_fighter(f, L.k)
		"FRIENDS":
			_friend_act(L, row)
		"SAY":
			Game.say(L.name, str(row), L.k)
			_menu_close(L)
		"OPTIONS":
			match int(m["row"]):
				0, 1:
					_option_adjust(int(m["row"]), 0.1)
				2:
					Game.toggle_fullscreen()
				3:      # how big the game's pixels are: AUTO fits the screen; smaller = see more of the world
					var zs = [0, 2, 3, 4, 5, 6]
					Game.cfg["view_zoom"] = zs[(zs.find(int(Game.cfg.get("view_zoom", 0))) + 1) % zs.size()]
					Game.save_options()
					if get_tree().root.has_node("Main"): get_tree().root.get_node("Main")._fit_view()
				4:
					# HUD / MINIMAP: both on - no minimap - no HUD - neither
					var st = (0 if hud_on else 2) + (0 if minimap_on else 1)
					st = (st + 1) % 4
					hud_on = st < 2
					minimap_on = st % 2 == 0
					Game.save_options()
				5:      # the songs, one after another (A: next)
					music_test = (music_test + 1) % MUSIC_SLOTS.size()
					music_test_hold = 3600
					Music.play(MUSIC_SLOTS[music_test])
				6:      # the game's own sound samples
					sound_test = (sound_test + 1) % 64
					var st = Sfx.sample(sound_test)
					if st != null:
						Sfx.play_stream(st)
				8:      # the touch controls: AUTO / ON / OFF
					var tm = ["auto", "on", "off"]
					Game.cfg["touch_mode"] = tm[(tm.find(str(Game.cfg.get("touch_mode", "auto"))) + 1) % tm.size()]
					Game.save_options()
					if touch != null:
						touch.apply_mode()
				9:      # which face button is A: the labels of a Nintendo-style pad (Retroid) or an Xbox one
					Game.cfg["pad_layout"] = "xbox" if Game.pad_layout() == "nintendo" else "nintendo"
					Game.save_options()
					Game.apply_pad_layout()
				7:
					show_controls = not show_controls
				10:
					words_on = not words_on
					Game.save_options()
				11:
					_option_pick_quit()

## QUIT TO TITLE AND SAVE GAME: everything saved, back to the start menu (the app stays open)
func _option_pick_quit() -> void:
	save_all()
	Game.leave()
	set_physics_process(false); set_process(false)
	get_tree().paused = false
	# after this frame is done: tearing down split screen's views in the middle of a step crashed Android's renderer
	get_tree().reload_current_scene.call_deferred()

func _option_adjust(row: int, d: float) -> void:
	# A steps up 10%, after 100% back to 0 (off)
	if row == 0:
		Music.volume = 0.0 if Music.volume > 0.95 else clampf(snappedf(Music.volume + d, 0.1), 0.0, 1.0)
	else:
		Sfx.volume = 0.0 if Sfx.volume > 0.95 else clampf(snappedf(Sfx.volume + d, 0.1), 0.0, 1.0)
		Sfx.play("menu")
	Game.save_options()

func _item_acts(L: Local) -> Array:
	var rows = _menu_rows(L)
	var it: Dictionary = rows[clampi(int(L.menu["row"]), 0, rows.size() - 1)]
	if str(it["id"]) == "zeni":
		return ["GIVE TO A FRIEND", "BACK"]
	if Content.is_gear(str(it["id"])):
		return ["USE", "GIVE TO A FRIEND", "BACK"]
	return ["USE", "PUT ON ITEM BUTTON", "GIVE TO A FRIEND", "BACK"]

## everyone you can give to: [name, player id]
func _gift_targets(L: Local) -> Array:
	var out = []
	for pid in Game.remote_states:
		out.append([str(Game.remote_states[pid].get("name", "?")), int(pid)])
	for o in locals:
		if o != L:
			out.append([o.name, Game.pid_of(Game.my_id(), o.k)])
	return out

# ------------------------------------------------------------------ friends: party, friendly duels, trading
const DUEL_ID = -1000

func _my_pid(L: Local) -> int:
	return Game.pid_of(Game.my_id(), L.k)

func _node_of_pid(pid: int) -> int:
	if pid / 8 == Game.my_id():
		var o = _local_of(pid % 8)
		return o.node_i if o != null else -1
	return int(Game.remote_states.get(pid, {}).get("node", -1))

func _pos_of_pid(pid: int):
	if pid / 8 == Game.my_id():
		var o = _local_of(pid % 8)
		return null if o == null else {"x": o.fighter.x, "y": o.fighter.y, "down": o.fighter.state == "down"}
	var st = Game.remote_states.get(pid)
	if st == null:
		return null
	return {"x": float(st.get("x", 0)), "y": float(st.get("y", 0)), "down": bool(st.get("down", false))}

func _pid_exists(pid: int) -> bool:
	return _node_of_pid(pid) >= 0

func _friend_rows(L: Local) -> Array:
	var out = []
	for iv in L.invites:
		var what = {"party": "JOIN %s'S PARTY", "duel": "ACCEPT %s'S DUEL", "trade": "TRADE WITH %s"}[iv[0]] % iv[2]
		out.append({"act": "accept", "kind": iv[0], "pid": iv[1], "name": iv[2], "label": "> " + what})
	for t in _gift_targets(L):
		var pid = int(t[1])
		var nm = str(t[0])
		if L.party.has(pid):
			out.append({"act": "leave", "pid": pid, "name": nm, "label": "%s - LEAVE THE PARTY" % nm})
		else:
			out.append({"act": "party", "pid": pid, "name": nm, "label": "%s - INVITE TO YOUR PARTY" % nm})
		out.append({"act": "duel", "pid": pid, "name": nm, "label": "%s - CHALLENGE TO A DUEL" % nm})
		out.append({"act": "trade", "pid": pid, "name": nm, "label": "%s - TRADE" % nm})
	if out.is_empty():
		out.append({"act": "", "label": "NOBODY ELSE IN THE WORLD YET"})
	return out

func _friend_act(L: Local, row: Dictionary) -> void:
	var act = str(row.get("act", ""))
	if act == "":
		return
	var pid = int(row["pid"])
	var nm = str(row["name"])
	match act:
		"accept":
			L.invites = L.invites.filter(func(iv): return not (iv[0] == row["kind"] and iv[1] == pid))
			match str(row["kind"]):
				"party":
					L.party[pid] = nm
					Game.send_social(pid, _my_pid(L), L.name, "party_yes", {})
					toasts.append(["%s JOINED A PARTY WITH %s - EXP AND KILLS ARE SHARED" % [L.name, nm], Color(0.6, 1, 0.8), 220])
				"duel":
					if _node_of_pid(pid) != L.node_i:
						toasts.append(["GO TO %s FIRST - A DUEL IS IN ONE PLACE" % nm, Color(1, 0.7, 0.6), 160]); Sfx.play("error"); return
					Game.send_social(pid, _my_pid(L), L.name, "duel_go", {})
					_duel_start(L, pid, nm)
					_menu_close(L)
				"trade":
					Game.send_social(pid, _my_pid(L), L.name, "trade_go", {})
					_trade_start(L, pid, nm)
		"party":
			Game.send_social(pid, _my_pid(L), L.name, "party_ask", {})
			toasts.append(["PARTY INVITE SENT TO %s" % nm, Color(0.8, 0.9, 1), 140])
		"leave":
			L.party.erase(pid)
			Game.send_social(pid, _my_pid(L), L.name, "party_leave", {})
			toasts.append(["%s LEFT THE PARTY WITH %s" % [L.name, nm], Color(0.9, 0.9, 1), 140])
		"duel":
			if _node_of_pid(pid) != L.node_i:
				toasts.append(["%s IS SOMEWHERE ELSE - A DUEL IS IN ONE PLACE" % nm, Color(1, 0.7, 0.6), 160]); Sfx.play("error"); return
			if not L.duel.is_empty():
				return
			Game.send_social(pid, _my_pid(L), L.name, "duel_ask", {})
			toasts.append(["YOU CHALLENGED %s TO A DUEL" % nm, Color(1, 0.8, 0.5), 140])
		"trade":
			if not L.trade.is_empty():
				return
			Game.send_social(pid, _my_pid(L), L.name, "trade_ask", {})
			toasts.append(["TRADE OFFER SENT TO %s" % nm, Color(0.8, 0.9, 1), 140])
	Sfx.play("menu")

func _on_social(k: int, from: int, nm: String, kind: String, data: Dictionary) -> void:
	var L: Local = _local_of(k)
	if L == null:
		return
	match kind:
		"party_ask", "duel_ask", "trade_ask":
			var kd = kind.split("_")[0]
			L.invites = L.invites.filter(func(iv): return not (iv[0] == kd and iv[1] == from))
			L.invites.append([kd, from, nm, 1800])
			var msg = {"party": "%s INVITES %s TO A PARTY", "duel": "%s CHALLENGES %s TO A DUEL!", "trade": "%s WANTS TO TRADE WITH %s"}[kd] % [nm, L.name]
			toasts.append([msg + " - MENU > FRIENDS", Color(1, 0.9, 0.5), 300])
			Sfx.play("menu")
		"party_yes":
			L.party[from] = nm
			toasts.append(["%s JOINED %s'S PARTY - EXP AND KILLS ARE SHARED" % [nm, L.name], Color(0.6, 1, 0.8), 220])
		"party_leave":
			L.party.erase(from)
			toasts.append(["%s LEFT THE PARTY" % nm, Color(0.9, 0.9, 1), 160])
		"party_exp":
			if L.party.has(from):
				_on_exp(k, int(data.get("lv", 1)), clampf(float(data.get("mult", 0.5)), 0.0, 3.0), {"party": true})
		"duel_go":
			_duel_start(L, from, nm)
		"duel_hit":
			_duel_hit_in(L, from, data)
		"pvp_hit":
			_pvp_hit_in(L, data)
		"duel_won":
			if not L.duel.is_empty() and int(L.duel["with"]) == from:
				_duel_end(L, "%s WINS THE DUEL AGAINST %s!" % [L.name, nm], true)
		"duel_off":
			if not L.duel.is_empty() and int(L.duel["with"]) == from:
				_duel_end(L, "THE DUEL WITH %s IS OFF" % nm, false)
		"trade_go":
			_trade_start(L, from, nm)
		"trade_offer":
			if not L.trade.is_empty() and int(L.trade["with"]) == from:
				L.trade["theirs"] = _clean_offer(data.get("offer", {}))
				L.trade["ready_me"] = false
				L.trade["ready_them"] = false
		"trade_ready":
			if not L.trade.is_empty() and int(L.trade["with"]) == from:
				# they agree to exactly what both sides see
				L.trade["ready_them"] = _offer_key(_clean_offer(data.get("mine", {}))) == _offer_key(L.trade["theirs"]) and _offer_key(_clean_offer(data.get("theirs", {}))) == _offer_key(L.trade["mine"])
				_trade_check(L)
		"trade_off":
			if not L.trade.is_empty() and int(L.trade["with"]) == from:
				L.trade = {}
				toasts.append(["%s CALLED OFF THE TRADE" % nm, Color(1, 0.8, 0.6), 160])

## each tick: invites run out, a duel's foe stands in your list of things to hit
func _social_tick(L: Local, elist: Array) -> void:
	for iv in L.invites:
		iv[3] -= 1
	L.invites = L.invites.filter(func(iv): return iv[3] > 0)
	for pid in L.party.keys():
		if not _pid_exists(pid):
			L.party.erase(pid)
	if not L.trade.is_empty() and not _pid_exists(int(L.trade["with"])):
		L.trade = {}
		toasts.append(["THE TRADE IS OFF - YOUR FRIEND LEFT", Color(1, 0.8, 0.6), 160])
	_pvp_targets(L, elist)
	if L.duel.is_empty():
		return
	var pid = int(L.duel["with"])
	if _node_of_pid(pid) != L.node_i:
		_duel_end(L, "THE DUEL WITH %s IS OFF" % L.duel["name"], false)
		return
	if L.duel["t"] > 0:
		L.duel["t"] -= 1
		if L.duel["t"] % 60 == 0:
			Sfx.play("menu" if L.duel["t"] > 0 else "levelup", 0.8)
		return
	var p = _pos_of_pid(pid)
	if p != null:
		elist.append({"id": DUEL_ID, "x": p["x"], "y": p["y"], "alive": not p["down"], "big": false})

# PVP (set on a Capsule Corp save point with R2): players who both have it on can hurt each other for real
const PVP_ID = -2000          # PVP_ID - pid: another player, as something to hit
func _pvp_targets(L: Local, elist: Array) -> void:
	if not L.fighter.pvp:
		return
	for o in locals:
		if o != L and o.node_i == L.node_i and o.fighter.pvp:
			elist.append({"id": PVP_ID - _my_pid(o), "x": o.fighter.x, "y": o.fighter.y, "alive": o.fighter.state != "down", "big": false})
	for pid in Game.remote_states:
		var st: Dictionary = Game.remote_states[pid]
		if int(st.get("node", -1)) == L.node_i and bool(st.get("pvp", false)):
			elist.append({"id": PVP_ID - int(pid), "x": float(st.get("x", 0)), "y": float(st.get("y", 0)), "alive": not bool(st.get("down", false)), "big": false})

func _pvp_hit_out(L: Local, pid: int, ev: Dictionary) -> void:
	if not L.fighter.pvp:
		return
	Game.send_social(pid, _my_pid(L), L.name, "pvp_hit", {"dmg": int(ev["dmg"]), "kx": float(ev["kx"]), "ky": float(ev["ky"]), "crit": bool(ev["crit"])})
	var p = _pos_of_pid(pid)
	if p != null and views.has(L.node_i):
		views[L.node_i].sparks.append([Vector2(p["x"], p["y"] - 14), 10, Color(1, 0.6, 0.4)])
		Sfx.play("crit" if ev["crit"] else "hit", 0.8)

func _pvp_hit_in(L: Local, data: Dictionary) -> void:
	var f: FighterSim = L.fighter
	if not f.pvp or f.invuln > 0 or f.state == "down":
		return      # not in PVP mode: no player can hurt you
	var d = maxi(1, roundi(float(data.get("dmg", 1)) * 0.6))
	Sfx.play("hurt", 0.9)
	L.shake = 3.0
	if views.has(L.node_i):
		views[L.node_i].pops.append([str(d), Vector2(f.x, f.y - 30), 40, Color(1, 0.4, 0.3)])
	f.take_hit(d, float(data.get("kx", 0)), float(data.get("ky", 0)))

func _duel_start(L: Local, pid: int, nm: String) -> void:
	L.duel = {"with": pid, "name": nm, "t": 60 * int(Content.social_cfg.get("duel", {}).get("countdown", 3)) + 59}
	L.invites = L.invites.filter(func(iv): return not (iv[0] == "duel" and iv[1] == pid))
	if not (pid / 8 == Game.my_id() and L.k != 0):      # two players on this PC: say it once
		toasts.append(["DUEL: %s AGAINST %s! NOBODY GETS HURT FOR REAL" % [L.name, nm], Color(1, 0.6, 0.4), 200])

func _duel_end(L: Local, msg: String, won: bool) -> void:
	L.duel = {}
	var f: FighterSim = L.fighter
	f.hp = f.maxhp
	toasts.append([msg, Color(1, 0.85, 0.3) if won else Color(0.9, 0.9, 1), 260])
	if won:
		Sfx.play("levelup")

func _duel_hit_out(L: Local, ev: Dictionary) -> void:
	if L.duel.is_empty() or L.duel["t"] > 0:
		return
	Game.send_social(int(L.duel["with"]), _my_pid(L), L.name, "duel_hit", {"dmg": int(ev["dmg"]), "kx": float(ev["kx"]), "ky": float(ev["ky"]), "crit": bool(ev["crit"])})
	var p = _pos_of_pid(int(L.duel["with"]))
	if p != null and views.has(L.node_i):
		views[L.node_i].sparks.append([Vector2(p["x"], p["y"] - 14), 10, Color(1, 0.9, 0.5)])
		Sfx.play("crit" if ev["crit"] else "hit", 0.8)

func _duel_hit_in(L: Local, from: int, data: Dictionary) -> void:
	if L.duel.is_empty() or int(L.duel["with"]) != from or L.duel["t"] > 0:
		return
	var f: FighterSim = L.fighter
	if f.invuln > 0 or f.state == "down":
		return
	var cfg: Dictionary = Content.social_cfg.get("duel", {})
	var d = clampi(roundi(float(data.get("dmg", 1)) * float(cfg.get("damage", 0.4))), 1, maxi(1, roundi(f.maxhp * float(cfg.get("max_hit", 0.2)))))
	Sfx.play("hurt", 0.9)
	L.shake = 3.0
	if views.has(L.node_i):
		views[L.node_i].pops.append([str(d), Vector2(f.x, f.y - 30), 40, Color(1, 0.5, 0.3)])
	if f.hp - d <= 0:
		var nm = str(L.duel["name"])
		Game.send_social(from, _my_pid(L), L.name, "duel_won", {})
		_duel_end(L, "%s WINS THE DUEL AGAINST %s!" % [nm, L.name], false)
		return
	f.take_hit(d, float(data.get("kx", 0)), float(data.get("ky", 0)))

# trading: both put in what they give, both press READY on the same offer, then it swaps
func _trade_start(L: Local, pid: int, nm: String) -> void:
	L.trade = {"with": pid, "name": nm, "mine": {}, "theirs": {}, "ready_me": false, "ready_them": false}
	L.invites = L.invites.filter(func(iv): return not (iv[0] == "trade" and iv[1] == pid))
	if L.menu.is_empty():
		_menu_open(L)
	L.menu["tab"] = TABS.find("FRIENDS")
	L.menu["row"] = 0
	L.menu["mode"] = ""
	toasts.append(["TRADING WITH %s" % nm, Color(0.8, 0.95, 1), 140])

static func _clean_offer(o) -> Dictionary:
	var out = {}
	if o is Dictionary:
		for k in o:
			var n = int(o[k])
			if n > 0:
				out[str(k)] = clampi(n, 0, 999999)
	return out

static func _offer_key(o: Dictionary) -> String:
	var ks = o.keys()
	ks.sort()
	var t = ""
	for k in ks:
		t += "%s=%d;" % [k, int(o[k])]
	return t

func _trade_rows(L: Local) -> Array:
	var f: FighterSim = L.fighter
	var out = []
	for it in Content.items + Content.gear:
		if int(f.inv.get(str(it["id"]), 0)) > 0:
			out.append({"id": str(it["id"]), "name": str(it["name"]), "have": int(f.inv[str(it["id"])])})
	out.append({"id": "zeni", "name": "ZENI", "have": f.zeni})
	out.append({"id": "_ready", "name": "READY"})
	out.append({"id": "_cancel", "name": "CALL IT OFF"})
	return out

func _trade_step(L: Local, rows: Array, up: bool, down: bool, left: bool, right: bool, ok: bool, back: bool) -> void:
	var m: Dictionary = L.menu
	var tr: Dictionary = L.trade
	if up: m["row"] = (int(m["row"]) - 1 + rows.size()) % rows.size(); Sfx.play("move")
	if down: m["row"] = (int(m["row"]) + 1) % rows.size(); Sfx.play("move")
	var row: Dictionary = rows[clampi(int(m["row"]), 0, rows.size() - 1)]
	var id = str(row["id"])
	if back or (ok and id == "_cancel"):
		Game.send_social(int(tr["with"]), _my_pid(L), L.name, "trade_off", {})
		L.trade = {}
		toasts.append(["TRADE CALLED OFF", Color(0.9, 0.9, 1), 120])
		Sfx.play("menu")
		return
	if ok and id == "_ready":
		tr["ready_me"] = not tr["ready_me"]
		if tr["ready_me"]:
			Game.send_social(int(tr["with"]), _my_pid(L), L.name, "trade_ready", {"mine": tr["mine"], "theirs": tr["theirs"]})
		else:
			Game.send_social(int(tr["with"]), _my_pid(L), L.name, "trade_offer", {"offer": tr["mine"]})
		Sfx.play("menu")
		_trade_check(L)
		return
	if (left or right or ok) and not id.begins_with("_"):
		var step = 10 if id == "zeni" else 1
		var n = int(tr["mine"].get(id, 0)) + (step if (right or ok) else -step)
		n = clampi(n, 0, int(row["have"]))
		if n > 0:
			tr["mine"][id] = n
		else:
			tr["mine"].erase(id)
		tr["ready_me"] = false
		tr["ready_them"] = false
		Game.send_social(int(tr["with"]), _my_pid(L), L.name, "trade_offer", {"offer": tr["mine"]})
		Sfx.play("move")

func _trade_check(L: Local) -> void:
	var tr: Dictionary = L.trade
	if tr.is_empty() or not tr["ready_me"] or not tr["ready_them"]:
		return
	var f: FighterSim = L.fighter
	for id in tr["mine"]:
		var n = int(tr["mine"][id])
		if id == "zeni":
			f.zeni = maxi(0, f.zeni - n)
		else:
			f.inv[id] = int(f.inv.get(id, 0)) - n
			if int(f.inv[id]) <= 0:
				f.inv.erase(id)
				for sl in f.equip.keys():
					if str(f.equip[sl]) == id:
						f.take_off(sl)
	var got = []
	for id in tr["theirs"]:
		var n = int(tr["theirs"][id])
		if id == "zeni":
			f.zeni += n
			got.append("%d ZENI" % n)
		else:
			f.add_item(id, n)
			got.append("%s x%d" % [Content.item(id).get("name", id), n])
	toasts.append(["TRADE DONE WITH %s%s" % [tr["name"], (": GOT " + ", ".join(PackedStringArray(got))) if not got.is_empty() else ""], Color(0.6, 1, 0.8), 240])
	Sfx.play("item")
	L.trade = {}
	Game.save_fighter(f, L.k)

func _draw_trade(L: Local, line: Callable) -> void:
	var tr: Dictionary = L.trade
	var rows = _trade_rows(L)
	var row = clampi(int(L.menu["row"]), 0, rows.size() - 1)
	line.call("TRADING WITH %s" % tr["name"], Color(1, 0.85, 0.3))
	for j in rows.size():
		var r: Dictionary = rows[j]
		var id = str(r["id"])
		if id == "_ready":
			line.call("READY%s" % ("  (YOU ARE READY)" if tr["ready_me"] else ""), Color(0.6, 1, 0.6) if tr["ready_me"] else Color(1, 1, 1), j == row)
		elif id == "_cancel":
			line.call("CALL IT OFF", Color(1, 0.7, 0.6), j == row)
		else:
			line.call("%s   GIVE %d / %d" % [r["name"], int(tr["mine"].get(id, 0)), int(r["have"])], Color(1, 1, 1) if int(tr["mine"].get(id, 0)) > 0 else Color(0.7, 0.7, 0.8), j == row)
	var th = []
	for id in tr["theirs"]:
		th.append(("%d ZENI" % int(tr["theirs"][id])) if id == "zeni" else "%s x%d" % [Content.item(id).get("name", id), int(tr["theirs"][id])])
	line.call("%s GIVES: %s%s" % [tr["name"], ", ".join(PackedStringArray(th)) if not th.is_empty() else "NOTHING YET", "  (READY)" if tr["ready_them"] else ""], Color(0.6, 0.9, 1))
	line.call("LEFT/RIGHT: HOW MANY   READY: AGREE TO THE DEAL", Color(0.6, 0.65, 0.8))

## how much bigger the menu is drawn: as the screen allows (the GBA's 480 x 270 a step)
## the START menu: the same size on the screen at any VIEW SIZE (like the HUD), and always small enough to fit -
## at PIXELS x6 the screen is smaller than the menu and its edges were cut off
func _menu_scale() -> float:
	var vs = get_viewport().get_visible_rect().size
	return clampf(minf(_hud_scale(vs), minf(vs.x / 480.0, vs.y / 270.0)), 0.25, 6.0)

func _menu_rect(i: int) -> Rect2:
	var vs = get_viewport().get_visible_rect().size / _menu_scale()
	if locals.size() > 1:
		var w = vs.x / 2.0
		return Rect2(w * i + 6, 38, w - 12, vs.y - 52)
	return Rect2(vs.x / 2.0 - 190, 40, 380, vs.y - 56)

func _draw_menu(c: Control, L: Local, i: int) -> void:
	var ms = _menu_scale()
	c.draw_set_transform(Vector2.ZERO, 0.0, Vector2(ms, ms))
	_txt_scale = ms
	_draw_menu_at(c, L, i)
	_txt_scale = 1.0
	c.draw_set_transform(Vector2.ZERO)
	if menu_hits.has(i):
		menu_hits[i]["s"] = ms

func _draw_menu_at(c: Control, L: Local, i: int) -> void:
	var font = ThemeDB.fallback_font
	var r = _menu_rect(i)
	var m: Dictionary = L.menu
	var f: FighterSim = L.fighter
	c.draw_rect(r, Color(0.03, 0.04, 0.1, 1.0))
	c.draw_rect(r, Color(1, 0.85, 0.3, 0.8), false, 1.0)
	# tabs
	var tw = r.size.x / TABS.size()
	for t in TABS.size():
		var on = t == int(m["tab"])
		if on:
			c.draw_rect(Rect2(r.position.x + t * tw, r.position.y, tw, 12), Color(1, 0.85, 0.3, 0.25))
		_ds(c, font, Vector2(r.position.x + t * tw, r.position.y + 9), TABS[t] if tw >= 52 else TABS_SHORT[t], HORIZONTAL_ALIGNMENT_CENTER, tw, 6, Color(1, 0.9, 0.4) if on else Color(0.6, 0.65, 0.8))
	var x0 = r.position.x + 6
	var Y = [r.position.y + 24]
	var W = r.size.x - 12
	var rows = _menu_rows(L)
	var row = clampi(int(m["row"]), 0, maxi(0, rows.size() - 1))
	var tab: String = TABS[int(m["tab"])]
	menu_hits[i] = {"c": c, "rows": [], "tabs": []}
	for t2 in TABS.size():
		menu_hits[i]["tabs"].append(Rect2(r.position.x + t2 * tw, r.position.y, tw, 12))
	var line = func(t: String, col: Color, sel: bool = false, size: int = 7, ri: int = -1) -> void:
		if ri >= 0:      # a row you can pick: where it is, for the mouse
			menu_hits[i]["rows"].append([Rect2(x0 - 3, Y[0] - 8, W + 6, 10), ri])
		if sel:
			c.draw_rect(Rect2(x0 - 3, Y[0] - 8, W + 6, 10), Color(1, 1, 1, 0.12))
		for part in _wrap_line(t, W, size):      # (a long line goes on under itself, inside the menu)
			_ds(c, font, Vector2(x0, Y[0]), part, HORIZONTAL_ALIGNMENT_LEFT, W, size, col)
			Y[0] += 10
	match tab:
		"STATUS":
			line.call("%s   LEVEL %d   EXP %d" % [f.name, f.level, f.exp], Color(1, 0.9, 0.5), false, 8)
			line.call("HP %d / %d    EP %d / %d    ZENI %d" % [f.hp, f.maxhp, f.ep, f.maxep, f.zeni], Color(1, 1, 1))
			line.call("STRENGTH %.1f   POWER %.1f   ENDURANCE %.1f   SPEED x%.2f" % [f.eff_str(), f.eff_pwr(), f.eff_end(), f.speed() / Rules.WALK_SPEED], Color(0.8, 0.95, 1))
			var bl = []
			for k in f.buffs:
				bl.append("%s x%.1f (%ds)" % [k.to_upper(), float(f.buffs[k][0]), int(f.buffs[k][1]) / 60])
			if bl.size() > 0:
				line.call("POWER-UPS: " + ", ".join(PackedStringArray(bl)), Color(0.7, 1, 0.7))
			Y[0] += 4
			line.call("TRANSFORMATIONS (TRANSFORM BUTTON: NEXT FORM / BACK TO NORMAL)", Color(1, 0.85, 0.3))
			if rows.is_empty():
				line.call("  none", Color(0.6, 0.6, 0.7))
			for j in rows.size():
				var fm: Dictionary = rows[j]
				var have = f.level >= int(fm.get("level", 1))
				var now = j == f.form_i
				line.call("%s %s  - LEVEL %d   STR x%.1f  POW x%.1f  END x%.1f   %s" % [">" if now else " ", fm["name"], int(fm.get("level", 1)), float(fm.get("str", 1)), float(fm.get("pwr", 1)), float(fm.get("end", 1)), "ACTIVE" if now else ("READY" if have else "LOCKED")],
					Color(1, 1, 0.6) if now else (Color(1, 1, 1) if have else Color(0.5, 0.5, 0.6)), j == row, 7, j)
		"MISSIONS":
			line.call("MISSIONS - FRIENDS IN THE SAME PLACE SHARE EVERY KILL", Color(1, 0.85, 0.3))
			for j in rows.size():
				var q: Dictionary = rows[j]
				var cnt = int(q.get("count", 1))
				var pr = int(f.quests.get(str(q["id"]), 0)) if str(q.get("type", "")) != "level" else f.level
				line.call("%s  %d / %d%s" % [q["name"], mini(pr, cnt), cnt, "  (AGAIN AND AGAIN)" if q.get("repeat", false) else ""], Color(1, 1, 1), j == row, 7, j)
			if rows.size() > 0:
				Y[0] += 2
				var q2: Dictionary = rows[row]
				line.call(str(q2.get("info", "")), Color(0.85, 0.85, 0.7))
				var rw: Dictionary = q2.get("reward", {})
				var rl = []
				if rw.has("zeni"): rl.append("%d ZENI" % int(rw["zeni"]))
				if rw.has("exp"): rl.append("EXP")
				for it in rw.get("items", {}):
					rl.append(str(Content.item(str(it)).get("name", it)))
				for fid in rw.get("forms", []):
					rl.append(str(Content.form_by_id(str(fid)).get("name", fid)) + " (FORM)")
				line.call("REWARD: " + ", ".join(PackedStringArray(rl)), Color(1, 0.9, 0.5))
			else:
				line.call("ALL DONE FOR NOW - MORE AT HIGHER LEVELS", Color(0.7, 0.7, 0.8))
			line.call("DONE: %d" % f.qdone.size(), Color(0.6, 0.65, 0.8))
		"GEAR":
			line.call("STR +%d  POW +%d  END +%d  SPEED +%d%%  EXP +%d%%" % [int(f.gear_bonus("str")), int(f.gear_bonus("pwr")), int(f.gear_bonus("end")), roundi(f.gear_bonus("speed") * 100), roundi(f.gear_bonus("exp") * 100)], Color(0.8, 1, 0.8))
			for j in rows.size():
				var sl: String = rows[j]
				var gid = str(f.equip.get(sl, ""))
				var g = Content.item(gid)
				line.call("%s:  %s" % [sl.to_upper(), g.get("name", "-")], Content.color(g.get("color", "888899")), j == row, 7, j)
			Y[0] += 2
			var sel: String = rows[row]
			var gsel = Content.item(str(f.equip.get(sel, "")))
			if not gsel.is_empty():
				line.call(Content.gear_text(gsel), Color(0.85, 0.85, 0.7))
			var spare = []
			for g in Content.gear:
				if str(g["slot"]) == sel and int(f.inv.get(str(g["id"]), 0)) > 0:
					spare.append(str(g["name"]))
			line.call("IN THE BAG: " + (", ".join(PackedStringArray(spare)) if spare.size() > 0 else "nothing"), Color(0.7, 0.75, 0.9))
			line.call("A: WEAR THE NEXT ONE (OR TAKE IT OFF)", Color(0.6, 0.65, 0.8))
		"SPECIALS":
			var curs = f.current_skill()
			for j in rows.size():
				var sk: Dictionary = rows[j]
				var have = f.level >= int(sk.get("level", 1))
				var on = not curs.is_empty() and str(curs["id"]) == str(sk["id"])
				line.call("%s %s   %d EP   LEVEL %d%s" % [">" if on else " ", sk["name"], int(sk.get("ep", 0)), int(sk.get("level", 1)), "" if have else "  (LOCKED)"],
					Color(0.6, 1, 1) if on else (Color(1, 1, 1) if have else Color(0.5, 0.5, 0.6)), j == row, 7, j)
			if rows.size() > 0:
				Y[0] += 4
				line.call(str(rows[row].get("info", "")), Color(0.85, 0.85, 0.7))
				line.call("A: PUT ON THE SPECIAL BUTTON", Color(0.6, 0.65, 0.8))
		"ITEMS":
			for j in rows.size():
				var it: Dictionary = rows[j]
				var id = str(it["id"])
				var cnt = f.zeni if id == "zeni" else int(f.inv.get(id, 0))
				var qk = " [ITEM BUTTON]" if id == f.quick else ""
				line.call("%s  x%d%s" % [it["name"], cnt, qk], Content.color(it.get("color", "ffd040")), j == row, 7, j)
			if rows.size() > 0:
				Y[0] += 2
				line.call(str(rows[row].get("info", "Give zeni to a friend.")), Color(0.85, 0.85, 0.7))
			if m["mode"] == "act":
				var acts = _item_acts(L)
				Y[0] += 2
				for j in acts.size():
					line.call("   " + acts[j], Color(1, 1, 0.7) if j == int(m["act"]) else Color(0.7, 0.7, 0.8), j == int(m["act"]))
			elif m["mode"] == "give":
				var tg = _gift_targets(L)
				if not tg.is_empty():
					var t = tg[clampi(int(m["target"]), 0, tg.size() - 1)]
					Y[0] += 2
					line.call("GIVE %d TO  < %s >" % [int(m["amount"]), t[0]], Color(0.6, 1, 0.8), true, 8)
					line.call("LEFT/RIGHT: WHO   UP/DOWN: HOW MANY   A: GIVE   B: BACK", Color(0.6, 0.65, 0.8))
		"SHOP":
			var shd = _shop(str(L.menu.get("shop", "")))
			line.call(("%s - %s - YOU HAVE %d ZENI" % [str(shd.get("name", "SHOP")), str(shd.get("info", "")), f.zeni]) if not shd.is_empty() else ("CAPSULE CORP DELIVERY - YOU HAVE %d ZENI" % f.zeni), Color(1, 0.9, 0.5))
			for j in rows.size():
				var it: Dictionary = rows[j]
				line.call("%s   %d ZENI   (HAVE %d)" % [it["name"], int(it["price"]), int(f.inv.get(str(it["id"]), 0))], Content.color(it.get("color", "ffffff")) if f.zeni >= int(it["price"]) else Color(0.5, 0.5, 0.6), j == row, 7, j)
			if rows.size() > 0:
				line.call(str(rows[row].get("info", "")), Color(0.85, 0.85, 0.7))
		"FRIENDS":
			if not L.trade.is_empty():
				_draw_trade(L, line)
			else:
				line.call("PARTY: SHARE EXP AND KILLS ANYWHERE   DUEL: A FRIENDLY FIGHT   TRADE: SWAP ITEMS", Color(1, 0.85, 0.3))
				if not L.party.is_empty():
					line.call("YOUR PARTY: " + ", ".join(PackedStringArray(L.party.values())), Color(0.6, 1, 0.8))
				for j in rows.size():
					var fr: Dictionary = rows[j]
					line.call(str(fr["label"]), Color(1, 0.9, 0.5) if str(fr.get("act", "")) == "accept" else Color(1, 1, 1), j == row, 7, j)
		"SAY":
			line.call("QUICK CHAT - OVER YOUR HEAD AND ON EVERY SCREEN (KEYBOARD: T TO TYPE" + (", R3 ON A HANDHELD" if OS.has_feature("android") else "") + ")", Color(1, 0.85, 0.3))
			for j in rows.size():
				line.call(str(rows[j]), Color(1, 1, 1), j == row, 7, j)
		"OPTIONS":
			var vals = ["%d%%  (A: LOUDER)" % roundi(Music.volume * 100), "%d%%  (A: LOUDER)" % roundi(Sfx.volume * 100),
				"ON" if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN else "OFF",
				("AUTO (FILLS THE SCREEN)" if int(Game.cfg.get("view_zoom", 0)) == 0 else "PIXELS x%d" % int(Game.cfg["view_zoom"])) + "  %dx%d" % [int(get_viewport().get_visible_rect().size.x), int(get_viewport().get_visible_rect().size.y)],
				("HUD ON" if hud_on else "HUD OFF") + ", " + ("MINIMAP ON" if minimap_on else "MINIMAP OFF"),
				("%s%s  (A: NEXT)" % [MUSIC_SLOTS[music_test].to_upper(), " - YOUR FILE" if Music.file_for(MUSIC_SLOTS[music_test]) != "" else " - BUILT-IN TUNE"]) if music_test >= 0 else "(A: PLAY THE SONGS)",
				("SAMPLE %d  (A: NEXT)" % sound_test) if sound_test >= 0 else "(A: PLAY THE GAME'S SOUNDS)", "ON" if show_controls else "OFF",
				{"auto": "AUTO (HIDDEN WITH A PAD)", "on": "ON", "off": "OFF"}.get(str(Game.cfg.get("touch_mode", "auto")), "AUTO"),
				"NINTENDO / RETROID (A ON THE RIGHT)" if Game.pad_layout() == "nintendo" else "XBOX (A AT THE BOTTOM)",
				"ON" if words_on else "OFF  (ONLY SPEECH AND CHAT)", ""]
			for j in rows.size():
				line.call("%s   %s" % [rows[j], vals[j]], Color(1, 1, 1), j == row, 7, j)
			Y[0] += 4
			if show_controls:
				for t in _controls_text(L):
					line.call(t, Color(0.7, 0.75, 0.9))
	_ds(c, font, Vector2(r.position.x, r.end.y - 4), "LEFT/RIGHT: PAGE   UP/DOWN: CHOOSE   A: OK   B / MENU: BACK", HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 6, Color(0.55, 0.6, 0.75))

func _controls_text(L: Local) -> Array:
	var i = locals.find(L)
	var pads = Input.get_connected_joypads()
	var pad = "PAD: A punch  B ki (hold: beam)  X special  Y transform  LB item  RB next  L3: sprint until you stop  RT: sprint on/off  LT: fly / land (flying: B lands, Y or L3 boosts)  START menu  BACK map"
	if OS.has_feature("mobile") and locals.size() == 1:
		return ["CONTROLS: A punch  B ki (hold: beam)  X special  Y transform  L1 item  R1 next special", "L3: sprint until you stop  R2: sprint on/off  L2: fly / land (flying: B lands, Y or L3 boosts)  R3: chat  START menu  SELECT map"]
	if locals.size() == 1:
		return ["KEYS: WASD/arrows move, hold SHIFT/SPACE to run (or tap twice), J/Z punch, K/X ki (hold: beam), L/C special,", "I/V transform, U/F item, O/E next special, G fly / land (flying: K lands, I boosts), H/ESC menu, T chat,", "TAB/M map, F2 player 2, F11 fullscreen", pad]
	if i == 0 and pads.size() != 1:
		return ["KEYS: WASD move, SPACE run, J punch, K ki, L special, I transform, U item, O next, H menu", pad]
	if i == 0:
		return ["KEYS: WASD/arrows move, J punch, K ki, L special, I transform, U item, O next, H menu"]
	if pads.size() >= 1:
		return [pad]
	return ["KEYS: arrows move, ENTER run, . punch, / ki, ; special, ' transform, [ item, ] next, \\ menu", "(or numpad 1 2 3 5 6 4, 0 menu)"]

# ------------------------------------------------------------------ story tools (EVENTS: scenes, companions, heroes, areas)
var debug_on = false
var credits_t = -1
var credits_lines = []

## a door that needs something (DEV TOOLS - DOOR: need item / flag / level): false and a word if it is shut
func _door_open(L: Local, ex: Dictionary) -> bool:
	var f: FighterSim = L.fighter
	var why = ""
	var ukey = "unlocked:%s:%s" % [str(Game.planet.nodes[L.node_i]["key"]), str(ex["rect"])]
	if f.flags.get(ukey, false):
		return true          # (opened with its key before: stays open)
	if ex.has("need_level") and f.level < int(ex["need_level"]):
		why = "YOU NEED LEVEL %d" % int(ex["need_level"])
	if ex.has("need_flag") and not f.flags.get(str(ex["need_flag"]), false):
		why = "IT WON'T OPEN YET"
	if ex.has("need_item") and int(f.inv.get(str(ex["need_item"]), 0)) <= 0:
		why = "YOU NEED: " + str(Content.item(str(ex["need_item"])).get("name", ex["need_item"]))
	if why != "":
		if Engine.get_physics_frames() - int(L.mood.get("door_t", -999)) > 90:
			L.mood["door_t"] = Engine.get_physics_frames()
			toasts.append([str(ex.get("locked_msg", why)) if str(ex.get("locked_msg", "")) != "" else why, Color(1, 0.75, 0.5), 150])
			Sfx.play("error", 0.6)
		return false
	if ex.has("take_item") and bool(ex["take_item"]) and ex.has("need_item"):
		var id = str(ex["need_item"])
		f.inv[id] = int(f.inv.get(id, 0)) - 1
		if int(f.inv[id]) <= 0:
			f.inv.erase(id)
		f.flags[ukey] = true        # (used up: the door stays open, also after saving)
	return true

## a place as the story left it: opened passages, people shown or sent away, companions along
func _story_world(L: Local, av: AreaView) -> void:
	var key = str(Game.planet.nodes[L.node_i]["key"])
	var f: FighterSim = L.fighter
	var ppl: Array = av.area.get("people", [])
	for fk in f.flags.keys():
		var sk = str(fk)
		var v = f.flags[fk]
		if sk.begins_with("open:") and v is Dictionary and str(v.get("key", "")) == key:
			apply_open(key, v.get("rect", [0, 0, 0, 0]), bool(v.get("walk", true)))
		elif sk.begins_with("shown:%s:" % key) and v is Dictionary:
			var have = false
			var vp = Vector2(float(v.get("x", 0)), float(v.get("y", 0)))
			for pp in ppl:
				if str(pp.get("name", "")).to_upper() == str(v.get("name", "")).to_upper() and Vector2(float(pp["x"]), float(pp["y"])).distance_to(vp) < 200:
					have = true
					pp.erase("hidden")
			if not have:
				ppl.append(v.duplicate())
		elif sk.begins_with("hidden:%s:" % key):
			var nm = sk.substr(("hidden:%s:" % key).length())
			var best = null
			var bd = 64.0
			for pp in ppl:
				if str(pp.get("name", "")).to_upper() == nm:
					if not (v is Array):
						pp["hidden"] = true          # (every one of that name)
						continue
					var d = Vector2(float(pp["x"]), float(pp["y"])).distance_to(Vector2(float(v[0]), float(v[1])))
					if d < bd:
						bd = d; best = pp
			if best != null:
				best["hidden"] = true
		elif sk.begins_with("comp:") and v is Dictionary:
			var cn = sk.substr(5)
			if not L.comps.any(func(c): return str(c["name"]) == cn):
				_comp_add(L, v)
	for c in L.comps:
		c["x"] = f.x - 14; c["y"] = f.y + 6
		if not is_instance_valid(c["v"]) or c["v"].is_queued_for_deletion():
			var nv = ActorView.new()
			nv.set_sprite_set(Assets.sprite_set(int(c["set"])))
			nv.label = str(c["name"]); nv.label_color = Color(0.6, 1, 0.8)
			c["v"] = nv
		elif c["v"].get_parent():
			c["v"].get_parent().remove_child(c["v"])
		av.ents.add_child(c["v"])

## OPEN AREA / CLOSE AREA: walkable (and the things standing there gone) or a wall, in a box of the map
func apply_open(key: String, r: Array, walk: bool) -> void:
	var a = Assets.area(key)
	if a.get("walk") == null:
		return
	if not a.has("land"):
		# (a map without editable tiles: only where you can walk changes)
		var tw0 = int(a["tw"]); var th0 = int(a["th"])
		var w0: PackedByteArray = a["walk"]
		for y in range(clampi(int(float(r[1]) / 8), 0, th0 - 1), clampi(int(float(r[3]) / 8), 0, th0 - 1) + 1):
			for x in range(clampi(int(float(r[0]) / 8), 0, tw0 - 1), clampi(int(float(r[2]) / 8), 0, tw0 - 1) + 1):
				w0[y * tw0 + x] = (1 if w0[y * tw0 + x] == 0 else w0[y * tw0 + x]) if walk else 0
		a["walk"] = w0
		return
	var tw = int(a["tw"]); var th = int(a["th"])
	var x0 = clampi(int(float(r[0]) / 8), 0, tw - 1); var x1 = clampi(int(float(r[2]) / 8), 0, tw - 1)
	var y0 = clampi(int(float(r[1]) / 8), 0, th - 1); var y1 = clampi(int(float(r[3]) / 8), 0, th - 1)
	var w: PackedByteArray = a["walk"]
	var cells: Array = a["land"]["cells"]
	var ls = []
	for k in 5:
		ls.append(cells[k])
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var i = y * tw + x
			w[i] = (1 if w[i] == 0 else w[i]) if walk else 0
			if walk:
				for k in range(1, 3):
					var L2: PackedInt32Array = ls[k]
					L2[i] = 0
					ls[k] = L2
	a["walk"] = w
	for k in 5:
		cells[k] = ls[k]
	for n in views:
		if str(Game.planet.nodes[n]["key"]) == key:
			var av: AreaView = views[n]
			for k in range(1, 3):
				if k < av.tiles.size():
					for y in range(y0, y1 + 1):
						for x in range(x0, x1 + 1):
							if walk:
								av.tiles[k].erase_cell(Vector2i(x, y))

func emote_player(L: Local, kind: String) -> void:
	if views.has(L.node_i):
		views[L.node_i].pops.append([kind, Vector2(L.fighter.x, L.fighter.y - 40), 100, Color(1, 1, 0.7)])

# ---- companions
func companion_join(L: Local, who: String, nm: String, lv: int) -> void:
	var st = -1
	var ci = Assets.CHARACTERS.find(who.to_upper())
	if ci >= 0:
		st = Assets.character_set(ci)
	elif who.is_valid_int():
		st = int(who)
	if st < 0:
		st = 104
	if nm == "":
		nm = who.to_upper()
	var d = {"name": nm, "set": st, "lv": lv if lv > 0 else L.fighter.level}
	L.fighter.flags["comp:" + nm] = d
	companion_leave(L, nm, true)
	_comp_add(L, d)
	toasts.append(["%s JOINS YOU!" % nm, Color(0.6, 1, 0.8), 200])

func companion_leave(L: Local, nm: String, quiet: bool = false) -> void:
	for c in L.comps.duplicate():
		if str(c["name"]).to_upper() == nm.to_upper() or nm == "":
			if is_instance_valid(c["v"]):
				c["v"].queue_free()
			L.comps.erase(c)
			if not quiet:
				L.fighter.flags.erase("comp:" + str(c["name"]))
				toasts.append(["%s LEAVES" % c["name"], Color(0.8, 0.85, 1), 160])

func _comp_add(L: Local, d: Dictionary) -> void:
	var v = ActorView.new()
	v.set_sprite_set(Assets.sprite_set(int(d["set"])))
	v.label = str(d["name"])
	v.label_color = Color(0.6, 1, 0.8)
	if views.has(L.node_i):
		views[L.node_i].ents.add_child(v)
	L.comps.append({"name": str(d["name"]), "set": int(d["set"]), "lv": int(d.get("lv", 1)), "x": L.fighter.x - 14, "y": L.fighter.y + 6, "dir": 0, "t": 0, "cool": 0, "hit": 0, "v": v})

## a companion: keeps near you, runs at the nearest foe close by and hits it
func _step_comps(L: Local, elist: Array) -> void:
	var f: FighterSim = L.fighter
	for c in L.comps:
		c["t"] = int(c["t"]) + 1
		c["cool"] = maxi(0, int(c["cool"]) - 1)
		var me = Vector2(float(c["x"]), float(c["y"]))
		var tgt = null
		var best = 110.0
		for e in elist:
			if not e["alive"]:
				continue
			var d = Vector2(float(e["x"]), float(e["y"])).distance_to(me)
			var dp = Vector2(float(e["x"]), float(e["y"])).distance_to(Vector2(f.x, f.y))
			if d < best and dp < 160.0:
				best = d; tgt = e
		var goal = Vector2(f.x - 16 + (6 if f.dir == 2 else 0), f.y + 8)
		var moving = false
		if tgt != null:
			goal = Vector2(float(tgt["x"]) + (14 if me.x > float(tgt["x"]) else -14), float(tgt["y"]))
		var dv = goal - me
		if me.distance_to(Vector2(f.x, f.y)) > 260:
			me = Vector2(f.x - 14, f.y + 6)       # (left far behind: catches up)
		elif dv.length() > 3:
			var sp = 1.4 if tgt == null else 1.6
			var step = dv.normalized() * minf(sp, dv.length())
			if f.can_stand(me.x + step.x, me.y):
				me.x += step.x
			if f.can_stand(me.x, me.y + step.y):
				me.y += step.y
			moving = true
			c["dir"] = (3 if dv.x > 0 else 2) if absf(dv.x) > absf(dv.y) else (0 if dv.y > 0 else 1)
		c["x"] = me.x; c["y"] = me.y
		if tgt != null and best < 22.0 and int(c["cool"]) == 0:
			c["cool"] = 40
			c["hit"] = 16
			var dmg = maxi(1, roundi(2.0 + float(c["lv"]) * 1.3))
			var kv = (Vector2(float(tgt["x"]), float(tgt["y"])) - me).normalized() * 3.0
			Game.hit_enemy(L.node_i, int(tgt["id"]), dmg, kv.x, kv.y, false, 14)
			if views.has(L.node_i):
				views[L.node_i].pops.append([str(dmg), Vector2(float(tgt["x"]), float(tgt["y"]) - 30), 40, Color(0.7, 1, 0.8)])
		c["hit"] = maxi(0, int(c["hit"]) - 1)
		var v: ActorView = c["v"]
		if is_instance_valid(v):
			v.position = Vector2(roundf(me.x), roundf(me.y))
			var an = 6 if int(c["hit"]) > 0 else (1 if moving else 0)
			var nfr = maxi(1, v.frames_of(an, int(c["dir"])).size())
			v.show_frame(an, int(c["dir"]), (int(c["t"]) / 6) % nfr if an != 6 else mini(3 - int(c["hit"]) / 5, nfr - 1))

## SWITCH HERO: play as another of the heroes (each keeps their own level and things; the story goes on)
func switch_hero(L: Local, hero: String) -> void:
	var ch = Assets.CHARACTERS.find(hero.to_upper())
	if ch < 0 or ch == L.fighter.ch:
		return
	var old: FighterSim = L.fighter
	Game.save_fighter(old, L.k)
	var nf = FighterSim.new()
	nf.setup(ch, levels)
	Game.load_fighter(nf, L.k)
	nf.flags.merge(old.flags, true)
	nf.area = L.area
	nf.place_at(old.x, old.y)
	nf.dir = old.dir
	L.fighter = nf
	if L.k == 0:
		Game.cfg["character"] = ch
	else:
		Game.cfg["character2"] = ch
	toasts.append(["NOW PLAYING: " + Assets.CHARACTERS[ch], Color(1, 0.85, 0.3), 200])

# ---- moods: darkness, weather, music in a box of the map (DEV TOOLS - MOOD tool)
func _find_mood(L: Local) -> void:
	var moods: Array = Game.planet.nodes[L.node_i]["spec"].get("moods", [])
	var m = {}
	for md in moods:
		var r: Array = md.get("rect", [0, 0, 0, 0])
		if L.fighter.x >= float(r[0]) and L.fighter.x <= float(r[2]) and L.fighter.y >= float(r[1]) and L.fighter.y <= float(r[3]):
			m = md
	var keep_t = L.mood.get("door_t", -999)
	L.mood = m.duplicate()
	L.mood["door_t"] = keep_t

func _draw_weather(c: Control, wt: String, vs: Vector2) -> void:
	var t = Engine.get_physics_frames()
	var rng = RandomNumberGenerator.new()
	rng.seed = 7
	match wt:
		"rain":
			for i in 140:
				var x = fmod(rng.randf() * vs.x * 1.3 + t * 1.6, vs.x * 1.3) - vs.x * 0.15
				var y = fmod(rng.randf() * vs.y + t * (5.0 + rng.randf() * 2.0), vs.y)
				c.draw_line(Vector2(x, y), Vector2(x - 3, y + 9), Color(0.7, 0.8, 1, 0.45), 1.0)
			c.draw_rect(Rect2(Vector2.ZERO, vs), Color(0.1, 0.12, 0.2, 0.18))
		"snow":
			for i in 110:
				var sp = 0.4 + rng.randf() * 0.8
				var x = fmod(rng.randf() * vs.x + sin((t + i * 13) / 40.0) * 12.0 + t * 0.2, vs.x)
				var y = fmod(rng.randf() * vs.y + t * sp, vs.y)
				c.draw_rect(Rect2(x, y, 2, 2), Color(1, 1, 1, 0.8))
		"ash":
			for i in 90:
				var x = fmod(rng.randf() * vs.x + t * 0.3 + sin((t + i * 7) / 50.0) * 10.0, vs.x)
				var y = fmod(rng.randf() * vs.y + t * (0.3 + rng.randf() * 0.4), vs.y)
				c.draw_rect(Rect2(x, y, 2, 1), Color(0.35, 0.33, 0.32, 0.8))
			c.draw_rect(Rect2(Vector2.ZERO, vs), Color(0.3, 0.2, 0.15, 0.12))
		"dust":
			for i in 70:
				var x = fmod(rng.randf() * vs.x + t * (2.0 + rng.randf() * 2.0), vs.x)
				var y = rng.randf() * vs.y + sin((t + i * 11) / 30.0) * 4.0
				c.draw_rect(Rect2(x, y, 2, 1), Color(0.9, 0.8, 0.55, 0.6))
			c.draw_rect(Rect2(Vector2.ZERO, vs), Color(0.6, 0.45, 0.2, 0.1))

func _draw_timers(c: Control, vs: Vector2) -> void:
	if locals.is_empty():
		return
	var font = ThemeDB.fallback_font
	var y = 62.0
	for fk in locals[0].fighter.flags:
		var sk = str(fk)
		var v = locals[0].fighter.flags[fk]
		if sk.begins_with("timer:") and v is Dictionary and bool(v.get("show", true)):
			var left = int(v.get("end", 0)) - int(Time.get_unix_time_from_system() * 1000.0)
			if left <= 0:
				continue        # (run out: IF TIMER sees it)
			var txt = "%s  %d:%02d" % [sk.substr(6).to_upper(), left / 60000, (left / 1000) % 60]
			_dso(c, font, Vector2(0, y), txt, HORIZONTAL_ALIGNMENT_CENTER, vs.x, 10, 3, Color(0, 0, 0, 0.8))
			_ds(c, font, Vector2(0, y), txt, HORIZONTAL_ALIGNMENT_CENTER, vs.x, 10, Color(1, 0.85, 0.4) if left > 10000 else Color(1, 0.4, 0.3))
			y += 12

## F8: what the story knows right now
func _draw_debug(c: Control, vs: Vector2) -> void:
	if locals.is_empty():
		return
	var font = ThemeDB.fallback_font
	var L: Local = locals[0]
	var f: FighterSim = L.fighter
	var lines = ["EVENT DEBUGGER (F8 close, F7 next step)"]
	if L.ev.is_empty():
		lines.append("no event running")
	else:
		var e = events_rt.find(str(L.ev["id"]))
		var pc = int(L.ev["pc"])
		var steps: Array = e.get("steps", [])
		lines.append("event %s  step %d / %d  %s" % [L.ev["id"], pc, steps.size(), ("waiting: " + str(L.ev.get("until", ""))) if str(L.ev.get("until", "")) != "" else ""])
		if pc - 1 >= 0 and pc - 1 < steps.size():
			lines.append("  now: " + JSON.stringify(steps[pc - 1]).left(90))
		if pc < steps.size():
			lines.append("  next: " + JSON.stringify(steps[pc]).left(90))
	var fl = []; var vr = []; var ot = []
	for fk in f.flags:
		var sk = str(fk)
		if sk.begins_with("var:"):
			vr.append("%s=%s" % [sk.substr(4), str(f.flags[fk])])
		elif sk.begins_with("event:"):
			ot.append(sk.substr(6))
		elif not sk.contains(":"):
			fl.append(sk)
	lines.append("flags: " + ", ".join(PackedStringArray(fl)))
	lines.append("numbers: " + ", ".join(PackedStringArray(vr)))
	lines.append("states: " + ", ".join(PackedStringArray(f.states.keys())) + "   form: " + str(f.form().get("id", "-")))
	lines.append("events done: " + ", ".join(PackedStringArray(ot)).left(120))
	lines.append("map %s  x %d  y %d  level %d" % [Game.planet.nodes[L.node_i]["key"], int(f.x), int(f.y), f.level])
	var h = 10 + lines.size() * 10
	c.draw_rect(Rect2(4, vs.y - h - 70, minf(vs.x - 8, 470), h), Color(0, 0, 0.08, 0.85))
	for i in lines.size():
		_ds(c, font, Vector2(8, vs.y - h - 60 + i * 10), lines[i], HORIZONTAL_ALIGNMENT_LEFT, minf(vs.x - 16, 462), 7, Color(0.7, 1, 0.8) if i == 0 else Color(0.9, 0.92, 1))

## THE END: the credits roll, then back to the title
func show_credits() -> void:
	var st: Dictionary = Content.story
	credits_lines = [str(st.get("title", "THE END")).to_upper(), ""]
	for l in st.get("credits", ["THANK YOU FOR PLAYING"]):
		credits_lines.append(str(l))
	credits_lines += ["", "", "THE END"]
	credits_t = 0
	Music.play(str(st.get("credits_music", "victory")))

func _draw_credits(c: Control, vs: Vector2) -> void:
	credits_t += 1
	var font = ThemeDB.fallback_font
	c.draw_rect(Rect2(Vector2.ZERO, vs), Color(0, 0, 0, minf(1.0, credits_t / 60.0)))
	var y0 = vs.y + 20 - credits_t * 0.45
	for i in credits_lines.size():
		var y = y0 + i * 16
		if y > -20 and y < vs.y + 20:
			_ds(c, font, Vector2(0, y), str(credits_lines[i]), HORIZONTAL_ALIGNMENT_CENTER, vs.x, 12 if i == 0 or i == credits_lines.size() - 1 else 9, Color(1, 0.85, 0.35) if i == 0 else Color(1, 1, 1))
	if y0 + credits_lines.size() * 16 < vs.y / 2 - 30 and credits_t > 300:
		credits_t = -1
		save_all()
		Game.leave()
		get_tree().reload_current_scene()
