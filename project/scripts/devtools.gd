extends Node2D
## DEV TOOLS - your team works on the game here, no programming: the MAP EDITOR (tiles on all 5 layers,
## walls, foes, people, treasure, doors, copy and paste of whole places, maps of your own) and the editors for
## HEROES, ENEMIES, MOVES, FORMS, BLASTS and MISSIONS. Everything is saved in the "mods" and "content" folders
## next to LoG2Coop.exe (a new import of the game never loses it). See "DEV TOOLS.txt".

signal closed
signal tune_requested
signal play_requested(at: Dictionary)

const CHUNK = 16
const TABS = ["MAP", "HEROES", "ENEMIES", "MOVES", "FORMS", "BLASTS", "MISSIONS", "EVENTS", "SHOPS", "LOOT", "STATES", "STORY", "SPRITES", "COLORS", "CHECK", "SHARE"]
## the tabs with a panel of their own (the others use the list editor)
const PANELS = {"COLORS": "res://scripts/dev_colors.gd", "SHARE": "res://scripts/dev_mods.gd", "EVENTS": "res://scripts/dev_events.gd",
	"SPRITES": "res://scripts/dev_sprites.gd", "CHECK": "res://scripts/dev_check.gd"}
var panels = {}
const TOOLS = ["PAN", "ERASE", "PICK", "WALL", "GROUND", "UNDER", "OVER", "SELECT", "COPY", "PASTE", "MOVE", "GUIDE", "THINGS", "ROCK", "BIOME", "SMART", "FOE", "ZONE", "PERSON", "ITEM", "DOOR", "EVENT", "MOOD"]
const TOOL_HELP = {
	"PAN": "Drag to move around (or right / middle mouse anywhere, WASD, arrows). Wheel: zoom.",
	"STAMP": "Stamping the cell you PICKed (all 5 layers and its wall). Click PICK to pick another.",
	"ERASE": "Take the tile away from the chosen LAYER.",
	"PICK": "Click a cell to see what it is (its tiles on each layer, walkable or not). STAMP on (on the right): the cell you click is stamped wherever you click or drag next - all its layers and its wall.",
	"WALL": "Paint where you cannot walk (red when WALLS is on).",
	"GROUND": "Paint where you can walk.",
	"UNDER": "UNDER HERO: tiles painted with this tool are drawn under the hero - the hero is drawn over them, so whatever he walks onto is hidden behind him. (Tick OVER HERO in the top bar to see which tiles are drawn over him.) Ctrl+Z undoes.",
	"OVER": "OVER HERO: tiles painted with this tool are drawn over the hero - he walks behind them and they hide him, like leaves or a roof edge. The ground itself (layer 0) is never moved. Ctrl+Z undoes.",
	"SELECT": "Click a foe, person, treasure or door: change or delete it on the right. Drag to move it. PLACES: every place of the game shows as a box with its name, its number in the game (one name can be several of the game's maps: a farm, a maze, a lair) and its song (\u266A). The box is where that name shows, that music plays and its own people stand: click a name to choose it, drag to move the place, Delete to take it away (a place whose land is gone). Ctrl+Z undoes.",
	"COPY": "Drag a box: those cells (all layers and walls) go to the clipboard - then PASTE. LASSO (on the right): draw any shape instead.",
	"PASTE": "Click: the clipboard is laid down there (its top-left corner at the mouse). Move whole places this way.",
	"MOVE": "Everything comes along - all layers and walls, foes, people, treasure, doors (and doors leading in), zones, moods, event boxes, the places' names and music.",
	"GUIDE": "A picture of your own laid faintly over the map (the game's world map, say) to line places up with: CHOOSE A PICTURE on the right, then drag it into place; BIGGER / SMALLER, FIT TO THE MAP. Only you see it, only here.",
	"FOE": "Click: a foe of the kind chosen on the right.",
	"PERSON": "Click: a person who says the lines written on the right.",
	"ITEM": "Click: treasure (an item lying there until someone takes it).",
	"DOOR": "Drag the door's box, then click where it takes you (switch maps first with GO TO MAP to arrive elsewhere).",
	"SMART": "PICK the ground first (water, sand, a path...), then paint: when you let go its edges are joined up the way the game's own maps join them.",
	"BIOME": "Paint the land with natural ground - grass, snow, sand, water... (chosen on the right, with the brush size): each patch is a piece of the real thing picked at random, so it never looks like one tile again and again. MAKE A BIOME FROM A BOX: drag a box round any good patch of the map to add your own.",
	"ROCK": "Rocks to smash (and the game's other breakables): choose one on the right, its hits and what it drops, then click to set it down. SELECT a rock to change, drag or delete it (the game's own too). MOVE takes them along.",
	"THINGS": "Whole things - houses, trees, fences - to set down with one click. FIND THINGS IN VIEW cuts them from the map you see (any game's), or save a COPY as one.",
	"ZONE": "Drag a box: foes come and go there by themselves (which kinds, how many, their level, how soon they come back - on the right).",
	"MOOD": "Drag a box: the place feels different in it - dark (a light round you), rain, snow, ash or dust, its own music. SELECT (click inside) to delete it.",
	"EVENT": "Drag a box: walking into it starts an EVENT (made in the EVENTS tab) - a scene, a door that opens later, a boss.",
}

var key = "land/0/0"
var area = {}
var tiles = []
var chunks = {}
var cam: Camera2D
var overlay: Node2D
var rock_layer: Node2D      # the rocks' pictures: over the ground, under the trees' tops (z 70) as in the game
var ui: Control
var tool = "PAN"
var layer = 0
var brush_tile = 1              # TILE tool: a tile id
var brush_cell = [0, 0, 0, 0, 0, 1]   # STAMP: a whole cell + walk
var last_brush = "TILE"
var rock_b = preload("res://scripts/breakables.gd").new(null)      # the breakables (the game's own and yours)
var rock_cache = null           # rock_b.rock_list of this map, made again after a change
var rock_like = ""              # ROCK: the picture chosen ("place:n" of a game rock)
var rock_hits = 1               # ROCK: hits it takes
var rock_drops = 1              # ROCK: its drop table (breakables.DROP_TABLES)
var biomes = null               # BIOME: [{name, w, h, cells: [[l0..l4, walk]...]}] (content/biomes.json)
var biome_i = 0
var biome_size = 6              # BIOME: the brush (cells across)
var biome_grab = false          # BIOME: the next box dragged on the map becomes a new biome
var biome_icons = {}            # name -> its little picture
var biome_newname = "MY GROUND"
var pick_stamp = false       # PICK: STAMP on - a picked cell is then stamped where you click / drag
var show_walls = true
var show_over = false     # OVER HERO: walkable cells with tiles drawn over the hero, tinted blue
var high_ground = false   # GROUND - HIGH GROUND: blue cells become platform tops (purple): a wall from the ground, ground once landed on
var under_full = 0
var show_changes = false
var _last_look = []              # what the overlay was last drawn for
var _redraw_t = 0.0
var _changes = []          # [[layer name, {"x,y": cell}]] for the CHANGES view
var show_grid = false
var show_objects = true
var sel_from = Vector2.ZERO        # SELECT: where the click began
var keep_ground = false          # PASTE / THINGS: the ground already there stays (the copy's background is left out)
var clipboard = {}              # {w, h, cells: [[6 values]...]}
var move_box = Rect2i()         # MOVE: the part picked up (cells); empty: drag a box first
var move_swap = false           # MOVE: what is where it lands goes to where it came from (else it is covered)
var move_lasso = false          # MOVE: LASSO - draw any shape round what to pick up (not just a box)
var copy_lasso = false          # COPY: its own LASSO (off unless ticked there)
var lasso_pts = []              # MOVE: LASSO - the cells the line went through while drawing it
var move_mask = {}              # MOVE: LASSO - the cells picked up (Vector2i -> true); empty: the whole move_box
var move_place = {}             # MOVE: a whole place being dragged by its name {key, box (cells), grab}
var guide = {}                  # GUIDE: {"path", "x", "y", "w", "h", "alpha", "on"} (user://map_guide.json)
var guide_tex: Texture2D = null
var guide_grab = Vector2.ZERO
var drag_from = Vector2i(-1, -1)
var dragging = false
var pan_drag = false
var pan_last = Vector2.ZERO
var stroke = {}                 # index -> [old6, new6] while painting
var undo = []
var redo = []                   # steps undone, newest last (a new edit forgets them)
var dirty = false
var selected = {}               # {kind, ...}
var door_rect = []              # DOOR: the box drawn, waiting for its arrival click
var door_to = ""
var status: Label
var help: Label
var side: VBoxContainer
var tool_buttons = {}
var map_pick: OptionButton
var layer_pick: OptionButton
var palette: Control
var pal_scroll = 0
var foe_type = 8
var foe_look = 0                # FOE: a sprite set to wear (0 = the kind's own look)
var foe_lv = 0
var person_name = "TRAVELLER"
var person_set = 54
var person_lines = "Hello there!\nThe world is big."
var last_person = {}      # the person just placed with PERSON (its name, look and lines can still be saved to it)
var last_person_key = ""
var person_shop = ""
var person_event = ""
var item_id = "senzu"
var item_n = 1
var tab = "MAP"
var editors: Control
var mouse_cell = Vector2i(-1, -1)
var preview: ActorView
var MT = preload("res://scripts/dev_maptools.gd").new()
var smart_mask = {}
var smart_size = 1
var edges = null                # SMART - EDGE: content/edges.json's edges (beach, lake, waterfall)
var edge_i = -1                 # SMART - EDGE chosen (-1: SMART's own painting)
var edge_size = 4               # SMART - EDGE: the brush (cells across)
var paint_size = 1               # TILE / STAMP / ERASE / WALL / GROUND: the brush is this many cells across
var paint_last = Vector2i(-1, -1)   # the cell painted last in this drag (the stroke is joined up from it)
var stamps = []              # THINGS: the list shown (saved ones + found in view)
var stamp_i = -1
var minimap: Control
var mini_dirty = false           # cells were painted: the picture is sent again (at most once a frame)
var mini_img: Image          # the minimap's picture (a MOVE repaints only the cells it touched)
var mini_tex: Texture2D
var layer_shown = [true, true, true, true, true]
const PAINT_FAR = ["BIOME", "SMART", "ERASE", "WALL", "GROUND", "STAMP"]      # tools that paint zoomed right out too (else a click there zooms in)
const FAR_ZOOM = 0.3          # zoomed out further: the map as one picture (THE WHOLE WORLD), names of the places on it
var world_sprite: Sprite2D
var backdrop: ColorRect          # under the map: the game's backdrop colour (black on EARTH), not the window's grey
var mini_step = 1
var zone_cfg = {"kinds": "8", "count": 4, "level": 0, "respawn": 30}
var event_id = ""
var event_attack = false        # EVENT: only an attack landing in the box starts it (a rock to break, a switch)
var door_need = {"need_item": "", "need_flag": "", "need_level": 0, "locked_msg": "", "take_item": false}
var mood_cfg = {"dark": 0.7, "light": 70, "weather": "", "music": ""}
var mine_button: Button
var colors_ed: Control
var coedit                      # TOGETHER (dev_coedit.gd) once used
var pal_game = ""               # the palette's tiles: "" this game's, "bf" Buu's Fury's

func _ready() -> void:
	_fit()
	get_window().size_changed.connect(_fit)
	Assets.tileset()
	if Game.planet == null or Game.planet.nodes.is_empty() or not str(Game.planet.nodes[0]["key"]).begins_with("land/0/"):
		Game.planet = Planet.new()
		Game.planet.build_land(0, 1)
	cam = Camera2D.new()
	add_child(cam)
	cam.make_current()
	overlay = Node2D.new()
	overlay.z_index = 200
	add_child(overlay)
	overlay.draw.connect(_draw_overlay)
	rock_layer = Node2D.new()
	add_child(rock_layer)
	rock_layer.draw.connect(_draw_rocks)
	_build_ui()
	load_map("land/0/0")
	if Game.cfg.has("dev_return"):
		# back from a play-test: where you were
		var r: Dictionary = Game.cfg["dev_return"]
		Game.cfg.erase("dev_return")
		if str(r.get("key", key)) != key:
			load_map(str(r["key"]))
		cam.position = Vector2(float(r.get("cx", r["x"])), float(r.get("cy", r["y"])))
		cam.zoom = Vector2.ONE * float(r.get("zoom", 1.0))
		_fill_maps()
		_say("Back from the play-test.")
	else:
		_tip()

func _exit_tree() -> void:
	if _save_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_save_task)      # (closing or going to play: a save being written finishes first)
		_save_task = -1
	if get_window().size_changed.is_connected(_fit):
		get_window().size_changed.disconnect(_fit)

## the tools want room: twice the game's pixels (at least 960 x 540 on a big screen)
func _fit() -> void:
	if is_queued_for_deletion() or not is_inside_tree():
		return
	var win = get_window()
	var ws = win.size
	var k = maxi(1, int(ws.y / 540))
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	win.content_scale_stretch = Window.CONTENT_SCALE_STRETCH_FRACTIONAL
	var want = Vector2i(maxi(640, ws.x / k), maxi(360, ws.y / k))
	if Game.cfg.has("dev_view"):
		want = Game.cfg["dev_view"]
	if win.content_scale_size != want:
		win.content_scale_size = want

# ------------------------------------------------------------------ the map
func load_map(k: String) -> void:
	key = k
	for t in tiles:
		t.queue_free()
	tiles.clear()
	chunks.clear()
	area = Assets.area(key)
	if area.is_empty():
		_say("That map could not be read.")
		return
	if backdrop == null:
		backdrop = ColorRect.new()
		backdrop.z_index = -100
		backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(backdrop)
	var bd: Array = area.get("meta", {}).get("backdrop", [0, 0, 0])
	backdrop.color = Color8(int(bd[0]), int(bd[1]), int(bd[2]))
	backdrop.size = Vector2(float(area["w"]), float(area["h"]))
	for i in 5:
		var tl = TileMapLayer.new()
		tl.navigation_enabled = false      # (no navigation: the game does not use it)
		tl.collision_enabled = false
		tl.tile_set = Assets.tileset()
		tl.z_index = [-50, -45, -40, 70, 72][i]
		tl.rendering_quadrant_size = 32
		add_child(tl)
		tiles.append(tl)
	var arr = area["meta"].get("arrival", [area["w"] / 2, area["h"] / 2])
	cam.position = Vector2(float(arr[0]), float(arr[1]))
	cam.zoom = Vector2(1, 1)
	selected = {}
	undo.clear()
	redo.clear()
	_changes = []
	_stream(true)
	call_deferred("_refresh_minimap")
	if mine_button:
		mine_button.visible = area.has("library")
	if map_pick:
		for i in map_pick.item_count:
			if str(map_pick.get_item_metadata(i)) == key:
				map_pick.select(i)
	if area.has("library"):
		_say("%s - another game's map. PICK or COPY from it and PASTE on your map, or MAKE IT MY MAP." % area["meta"]["name"])
	_refresh_side()

func _node_index() -> int:
	for i in Game.planet.nodes.size():
		if str(Game.planet.nodes[i]["key"]) == key:
			return i
	return -1

func _stream(all_now: bool = false) -> void:
	if area.is_empty():
		return
	var tw: int = area["tw"]; var th: int = area["th"]
	var vs = get_viewport_rect().size / cam.zoom
	var c0 = Vector2i(int((cam.position.x - vs.x / 2) / (CHUNK * 8)) - 1, int((cam.position.y - vs.y / 2) / (CHUNK * 8)) - 1)
	var c1 = Vector2i(int((cam.position.x + vs.x / 2) / (CHUNK * 8)) + 1, int((cam.position.y + vs.y / 2) / (CHUNK * 8)) + 1)
	var budget = 9999 if all_now else 10
	for cy in range(maxi(0, c0.y), mini(c1.y, (th - 1) / CHUNK) + 1):
		for cx in range(maxi(0, c0.x), mini(c1.x, (tw - 1) / CHUNK) + 1):
			var q = Vector2i(cx, cy)
			if chunks.has(q):
				continue
			if budget <= 0:
				return
			budget -= 1
			_fill_chunk(q, true)
			chunks[q] = true
	var drop = 6
	for q in chunks.keys():
		if q.x < c0.x - 3 or q.x > c1.x + 3 or q.y < c0.y - 3 or q.y > c1.y + 3:
			_fill_chunk(q, false)
			chunks.erase(q)
			drop -= 1
			if drop <= 0:
				break

func _fill_chunk(q: Vector2i, on: bool) -> void:
	var tw: int = area["tw"]; var th: int = area["th"]
	var cells: Array = area["land"]["cells"]
	for k in 5:
		var tl: TileMapLayer = tiles[k]
		var L: PackedInt32Array = cells[k]
		for y in range(q.y * CHUNK, mini(q.y * CHUNK + CHUNK, th)):
			for x in range(q.x * CHUNK, mini(q.x * CHUNK + CHUNK, tw)):
				if not on:
					tl.erase_cell(Vector2i(x, y))
					continue
				var c = L[y * tw + x]
				if c == 0:
					continue
				var r = Assets.kit_cell(c)
				if not r.is_empty():
					tl.set_cell(Vector2i(x, y), r[2], r[0], r[1])


func cell_at(x: int, y: int) -> Array:
	var i = y * int(area["tw"]) + x
	var out = []
	for k in 5:
		out.append(int(area["land"]["cells"][k][i]))
	out.append(int(area["walk"][i]))
	return out

func _inside(x: int, y: int) -> bool:
	return not area.is_empty() and x >= 0 and y >= 0 and x < int(area["tw"]) and y < int(area["th"])

## change one cell (shown at once; the map's arrays are written when the stroke ends)
func put(x: int, y: int, v: Array) -> void:
	if not _inside(x, y):
		return
	var i = y * int(area["tw"]) + x
	var old = stroke[i][0] if stroke.has(i) else cell_at(x, y)
	if stroke.has(i) and stroke[i][1] == v:
		return
	stroke[i] = [old, v.duplicate()]
	if mini_img != null and key == "land/0/0" and x < mini_img.get_width() and y < mini_img.get_height():      # (the whole-world picture too: seen zoomed out)
		mini_img.set_pixel(x, y, MT.mini_color(v, int(v[5])))
		mini_dirty = true
	for k in 5:
		var tl: TileMapLayer = tiles[k]
		var c = int(v[k])
		var r = Assets.kit_cell(c) if c != 0 else []
		if r.is_empty():
			tl.erase_cell(Vector2i(x, y))
		else:
			tl.set_cell(Vector2i(x, y), r[2], r[0], r[1])

## the stroke ends: into the map (one copy per layer), the changes list and the undo list
func end_stroke() -> void:
	if stroke.is_empty():
		return
	_write(stroke, 1)
	_changes = []
	undo.append({"cells": stroke})
	redo.clear()
	if coedit:
		coedit.sent_cells(key, stroke)
	if undo.size() > 60:
		undo.pop_front()
	stroke = {}
	dirty = true

func _write(changes: Dictionary, which: int) -> void:
	var tw: int = area["tw"]
	var cells: Array = area["land"]["cells"]
	for k in 5:
		var L: PackedInt32Array = cells[k]
		cells[k] = PackedInt32Array()
		for i in changes:
			L[i] = int(changes[i][which][k])
		cells[k] = L
	var w: PackedByteArray = area["walk"]
	area["walk"] = PackedByteArray()
	for i in changes:
		w[i] = _walk_bits(int(changes[i][which][5]))      # (&1 alone turned a painted platform top red)
	area["walk"] = w
	var p = Mods.patch(key)
	for i in changes:
		var v = changes[i][which]
		p["cells"]["%d,%d" % [i % tw, i / tw]] = v.duplicate()
		var x = i % tw; var y = i / tw
		if mini_img != null and key == "land/0/0" and x < mini_img.get_width() and y < mini_img.get_height():      # (undo / redo: the whole-world picture too)
			mini_img.set_pixel(x, y, MT.mini_color(v, int(v[5])))
			mini_dirty = true
		for k in 5:
			var tl: TileMapLayer = tiles[k]
			var c = int(v[k])
			var r = Assets.kit_cell(c) if c != 0 else []
			if r.is_empty():
				tl.erase_cell(Vector2i(x, y))
			else:
				tl.set_cell(Vector2i(x, y), r[2], r[0], r[1])

## the guide as it is, as an undo step (before a drag, BIGGER / SMALLER, FIT, see-through, show)
func _guide_undo_point() -> void:
	if guide.is_empty():
		return
	undo.append({"guide": guide.duplicate()})
	redo.clear()

func do_undo() -> void:
	if undo.is_empty():
		_say("Nothing to undo.")
		return
	var u: Dictionary = undo.pop_back()
	redo.append(_flip(u, 0))
	dirty = true
	_say("Undone. (REDO / Control+Y puts it back.)")

func do_redo() -> void:
	if redo.is_empty():
		_say("Nothing to redo.")
		return
	undo.append(_flip(redo.pop_back(), 1))
	dirty = true
	_say("Redone.")

## undo (side 0) or redo (side 1) one step; gives back the step that turns it round again
func _flip(u: Dictionary, side: int) -> Dictionary:
	if u.has("thing_gone"):      # a saved THING deleted: put back / deleted again
		return _thing_gone(str(u["thing_gone"]))
	if u.has("thing_back"):
		var f = MT.save_stamp(str(u["thing_back"].get("name", "THING")), u["thing_back"])
		stamps = MT.list_stamps(); stamp_i = -1
		_refresh_side()
		return {"thing_gone": f}
	if u.has("resize"):      # the map's size (saved at once, as RESIZE WHOLE MAP is)
		return _set_size(u["resize"], u["cut"])
	if u.has("guide"):      # the guide picture's place and look (kept on this computer, not in the map)
		var now_g = guide.duplicate()
		guide = u["guide"]
		_guide_save()
		overlay.queue_redraw()
		return {"guide": now_g}
	if u.has("biomes"):      # the biomes list (made or deleted)
		var now_b = biomes.duplicate()
		biomes = u["biomes"]
		biome_i = clampi(biome_i, 0, maxi(0, biomes.size() - 1))
		_biomes_save()
		_refresh_side()
		return {"biomes": now_b}
	if u.has("cells"):
		_write(u["cells"], side)
		if not u.has("patch"):
			return u
	var p = Mods.patch(key)
	var now = {}
	for k in u["patch"]:
		now[k] = p[k].duplicate(true)
		p[k] = u["patch"][k]
	if u["patch"].has("places") and key.begins_with("land/"):
		Assets.reset_land(int(key.split("/")[1]))
	_rebuild_world()
	if u.has("cells"):
		_refresh_minimap()
		return {"cells": u["cells"], "patch": now}
	return {"patch": now}

## a saved THING's file deleted; gives back the undo step that saves it again
func _thing_gone(f: String) -> Dictionary:
	var st = Assets.json(f)
	DirAccess.remove_absolute(f)
	stamps = MT.list_stamps(); stamp_i = -1
	_refresh_side()
	if st is Dictionary:
		st.erase("file")
		return {"thing_back": st}
	return {}

func _remember_patch() -> void:
	var p = Mods.patch(key)
	var snap = {}
	for k in ["enemies_add", "enemies_del", "people_add", "people_del", "doors_add", "doors_del", "items", "places", "rocks_add", "rocks_del"]:
		snap[k] = p[k].duplicate(true)
	undo.append({"patch": snap})
	redo.clear()

## foes, people and doors changed: the world is put together again (the planet's lists, the map's people)
func _rebuild_world() -> void:
	rock_cache = null
	for k in ["rocks", "rock_places", "blocks", "opened"]:      # (the game's state of them: built again from the edits)
		area.erase(k)
	Game.planet.build_land(0, 1)
	if key.begins_with("land/"):
		# people: the game's own again, then the changes
		var parts = key.split("/")
		var fresh = Assets.land_parts(key)
		area["people"] = fresh["people"]
		if area.has("land"):
			area["land"]["parts"] = fresh["parts"]      # (places' names and songs: MOVE moves them)
	else:
		area["people"] = []
	var p = Mods.merged(key, false)
	var ppl: Array = area["people"]
	for d in p["people_del"]:
		var q = Vector2(float(d[0]), float(d[1]))
		ppl = ppl.filter(func(pp): return Vector2(float(pp["x"]), float(pp["y"])).distance_to(q) > 6.0)
	for pa in p["people_add"]:
		ppl.append(pa.duplicate())
	area["people"] = ppl
	dirty = true
	if coedit:
		coedit.sent_objects(key)

var _save_task = -1
func save() -> void:
	end_stroke()
	if area.has("library"):
		dirty = false
		return
	if area.has("custom"):
		Mods.backup()
		var ok = Mods.save_patch(key) and Mods.save_custom(str(area["custom"]), area)
		dirty = false
		_say("Saved to mods/maps (your team's changes stay when the game is imported again)." if ok else "Could not save - is the game folder read-only?")
		return
	# the map's file as it was copied aside (quick), the new one written, then "Saved" - the backup (a zip of all your
	# edits, the copy standing for this map) is made in the background afterwards and needs nothing more of you
	if _save_task >= 0 and not WorkerThreadPool.is_task_completed(_save_task):
		WorkerThreadPool.wait_for_task_completion(_save_task)      # (one backup at a time)
	var path = Mods.maps_dir().path_join(Mods.file_key(key) + ".json")
	var before = path + ".before_save"
	if FileAccess.file_exists(path):
		DirAccess.copy_absolute(path, before)
	var ok = Mods.save_patch(key)
	dirty = false
	_say("Saved to mods/maps (your team's changes stay when the game is imported again)." if ok else "Could not save - is the game folder read-only?")
	_save_task = WorkerThreadPool.add_task(func():
		Mods.backup(false, {path: before} if FileAccess.file_exists(before) else {})
		if FileAccess.file_exists(before):
			DirAccess.remove_absolute(before))

# ------------------------------------------------------------------ input
## undo / redo for the map first (a number box on the side - the brush size - kept Control+Z for itself, and the
## map's undo did nothing); typing in a text field keeps its own. Command works as Control on a Mac.
## the map's labels (names, numbers, door names) drawn at the size they really have on screen: drawn small and then
## zoomed by the camera they came out blurry
func _ov_text(font: Font, pos: Vector2, text: String, align: int, width: float, size: int, color: Color) -> void:
	var z = maxf(0.05, overlay.get_global_transform_with_canvas().get_scale().x)
	overlay.draw_set_transform(pos, 0.0, Vector2.ONE / z)
	overlay.draw_string(font, Vector2.ZERO, text, align, width * z if width > 0 else -1.0, maxi(1, int(round(size * z))), color)
	overlay.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _input(ev: InputEvent) -> void:
	if tab != "MAP" or area.is_empty() or not (ev is InputEventKey) or not ev.pressed or ev.echo:
		return
	var kk: InputEventKey = ev
	var fo = get_viewport().gui_get_focus_owner()
	# J, Z, Space and Enter also mean "press the chosen button" (the menus' A): on the map they are the map's
	# (J: go where a door leads) - a side button clicked earlier must not take them
	# Command (Mac) counts as Control - asked several ways, as a Mac can report it differently
	var cmd = kk.ctrl_pressed or kk.meta_pressed or kk.is_command_or_control_pressed() or Input.is_key_pressed(KEY_META) or Input.is_key_pressed(KEY_CTRL)
	var key_z = kk.keycode == KEY_Z or kk.physical_keycode == KEY_Z
	var key_y = kk.keycode == KEY_Y or kk.physical_keycode == KEY_Y
	if fo is BaseButton and not cmd and not kk.alt_pressed and kk.keycode in [KEY_J, KEY_Z, KEY_SPACE, KEY_ENTER, KEY_KP_ENTER]:
		fo.release_focus()
		return
	if not cmd or not (key_z or key_y):
		return
	if (fo is LineEdit and not fo.get_parent() is SpinBox and fo.editable) or (fo is TextEdit and fo.editable):
		return
	if key_y or kk.shift_pressed:
		do_redo()
	else:
		do_undo()
	get_viewport().set_input_as_handled()

func _unhandled_input(ev: InputEvent) -> void:
	if tab != "MAP" or area.is_empty():
		return
	if ev is InputEventMouseButton:
		var mb: InputEventMouseButton = ev
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			cam.zoom = (cam.zoom * 1.25).clamp(Vector2(0.02, 0.02), Vector2(6, 6))
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			cam.zoom = (cam.zoom / 1.25).clamp(Vector2(0.02, 0.02), Vector2(6, 6))
		elif mb.button_index == MOUSE_BUTTON_RIGHT or mb.button_index == MOUSE_BUTTON_MIDDLE or (mb.button_index == MOUSE_BUTTON_LEFT and tool == "PAN"):
			pan_drag = mb.pressed
			pan_last = mb.position
		elif mb.button_index == MOUSE_BUTTON_LEFT and cam.zoom.x < FAR_ZOOM and not tool in ["MOVE", "GUIDE", "SELECT"] and not tool in PAINT_FAR:
			if mb.pressed:
				cam.position = _world_of(mb.position)
				cam.zoom = Vector2(1, 1)
				_say("Zoomed in there.")
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			var c = _cell_of(mb.position)
			if mb.pressed:
				dragging = true
				drag_from = c
				_press(c, _world_of(mb.position))
			else:
				dragging = false
				_release(c, _world_of(mb.position))
	elif ev is InputEventMouseMotion:
		var mm: InputEventMouseMotion = ev
		mouse_cell = _cell_of(mm.position)
		if pan_drag:
			cam.position -= (mm.position - pan_last) / cam.zoom
			pan_last = mm.position
		elif dragging:
			_drag(mouse_cell, _world_of(mm.position))
	elif ev is InputEventKey and ev.pressed and not ev.echo:
		var kk: InputEventKey = ev
		if kk.ctrl_pressed and (kk.keycode == KEY_Y or (kk.keycode == KEY_Z and kk.shift_pressed)):
			do_redo()
		elif kk.ctrl_pressed and kk.keycode == KEY_Z:
			do_undo()
		elif kk.keycode == KEY_G and not kk.ctrl_pressed and tool in ["COPY", "PASTE", "THINGS"]:
			keep_ground = not keep_ground
			_say("Keep the ground there: %s." % ("ON - only the thing itself is laid down" if keep_ground else "OFF - the whole box is laid down"))
			_refresh_side()
		elif (kk.keycode == KEY_X or kk.keycode == KEY_Y) and not kk.ctrl_pressed and tool in ["COPY", "PASTE"]:
			mirror_clipboard(kk.keycode == KEY_X)
		elif kk.keycode == KEY_J and not kk.ctrl_pressed and not selected.is_empty() and selected["obj"].has("arrive"):
			var so: Dictionary = selected["obj"]      # J: jump to where the chosen door leads (J again: back to the door)
			var at = Vector2(float(so["arrive"][0]), float(so["arrive"][1]))
			var rc: Array = so["rect"]
			var door_c = Vector2((float(rc[0]) + float(rc[2])) / 2.0, (float(rc[1]) + float(rc[3])) / 2.0)
			cam.position = door_c if cam.position.distance_to(at) < 16.0 else at
			_say("J: jumped to where the door leads (J again: back to the door).")
			overlay.queue_redraw()
		elif kk.ctrl_pressed and kk.keycode == KEY_S:
			save()
		elif (kk.keycode == KEY_DELETE or kk.keycode == KEY_BACKSPACE) and not selected.is_empty():      # (a Mac keyboard has only Backspace)
			_delete_selected()
		elif kk.keycode >= KEY_0 and kk.keycode <= KEY_4 and not kk.ctrl_pressed:
			layer = kk.keycode - KEY_0
			layer_pick.select(layer)
			_refresh_side()

func _world_of(p: Vector2) -> Vector2:
	return get_canvas_transform().affine_inverse() * p

func _cell_of(p: Vector2) -> Vector2i:
	var w = _world_of(p)
	return Vector2i(int(floor(w.x / 8.0)), int(floor(w.y / 8.0)))

func _press(c: Vector2i, w: Vector2) -> void:
	if area.has("library") and not tool in ["PAN", "PICK", "COPY", "SELECT"]:
		_say("This is another game's map: look, PICK and COPY here, then PASTE on your map - or MAKE IT MY MAP to change it.")
		return
	match tool:
		"TILE", "STAMP", "ERASE", "WALL", "GROUND", "UNDER", "OVER":
			if tool == "UNDER" or tool == "OVER":
				under_full = 0
			_paint_brush(c)
			paint_last = c
		"SMART" when edge_i >= 0:
			_edge_brush(c)
			paint_last = c
		"SMART":
			if int(brush_cell[0]) == 0:
				_say("PICK the ground to paint first (click PICK, then a water / sand / path cell).")
				return
			smart_mask = {}
			_smart_add(c)
			paint_last = c
		"ROCK":
			_place_rock(w)
		"BIOME":
			if not biome_grab:
				_biome_brush(c)
				paint_last = c
		"THINGS":
			if stamp_i >= 0 and stamp_i < stamps.size():
				MT.place_stamp(self, stamps[stamp_i], c)
				end_stroke()
				_say("%s set down." % str(stamps[stamp_i].get("name", "THING")))
			else:
				_say("Choose a thing on the right first.")
		"PICK":
			if _inside(c.x, c.y):
				brush_cell = cell_at(c.x, c.y)
				var t = int(brush_cell[layer]) & ~(1 << 18)
				if t > 0:
					brush_tile = t
				dragging = false      # the same click must not paint with the STAMP it switches to
				paint_last = Vector2i(-1, -1)
				last_brush = "STAMP"
				if pick_stamp:
					_set_tool("STAMP")
				_say("Picked: layers %s, %s.%s" % [str(brush_cell.slice(0, 5)), "walkable" if int(brush_cell[5]) & 1 else "wall", " Click or drag to stamp it (PICK again for another)." if pick_stamp else " (STAMP on the right: stamp it.)"])
		"PASTE":
			_paste(c)
		"MOVE":
			if move_box.size.x > 0:
				_move_area(move_box, c, "", move_mask)
				move_box = Rect2i()
				move_mask = {}
				_refresh_side()
				drag_from = Vector2i(-1, -1)      # (letting go of this click must not start a new box)
			else:
				var pl = _place_label_at(w)
				if not pl.is_empty():
					var pr: Rect2 = pl[0]
					var pb = Rect2i(int(roundf(pr.position.x / 8.0)), int(roundf(pr.position.y / 8.0)), int(roundf(pr.size.x / 8.0)), int(roundf(pr.size.y / 8.0)))
					move_place = {"key": str(pl[3]), "name": str(pl[1]), "box": pb, "grab": c - pb.position}
					drag_from = Vector2i(-1, -1)
		"GUIDE":
			guide_grab = w
			_guide_undo_point()
		"FOE":
			_remember_patch()
			var ts = Rules.kind_to_type_set(foe_type)
			Mods.patch(key)["enemies_add"].append([foe_type, foe_look if foe_look > 0 else ts[1], snappedf(w.x, 1), snappedf(w.y, 1), foe_lv if foe_lv > 0 else int(Assets.data["enemies"][clampi(foe_type, 0, 127)]["lvl"])])
			_rebuild_world()
			_say("Foe %d placed. SAVE to keep it." % foe_type)
		"PERSON":
			_remember_patch()
			var lines = []
			for l in person_lines.split("\n"):
				if l.strip_edges() != "":
					lines.append(["", person_name, l.strip_edges()])
			var pd = {"x": snappedf(w.x, 1), "y": snappedf(w.y, 1), "set": person_set, "name": person_name, "lines": lines}
			if person_shop != "": pd["shop"] = person_shop
			if person_event != "": pd["event"] = person_event
			Mods.patch(key)["people_add"].append(pd)
			last_person = pd
			last_person_key = key
			_rebuild_world()
			_refresh_side()
			_say("%s placed. Change the name or lines on the right and press SAVE TO THE PERSON JUST PLACED, or SAVE the map." % person_name)
		"ITEM":
			_remember_patch()
			Mods.patch(key)["items"].append({"x": snappedf(w.x, 1), "y": snappedf(w.y, 1), "id": item_id, "count": item_n})
			_rebuild_world()
			_say("Treasure %s x%d placed." % [item_id, item_n])
		"SELECT":
			selected = _pick_object(w)
			sel_from = w      # a move only when dragged a little way (a hand's shake on the click is no move)
			_refresh_side()
		"DOOR":
			if door_rect.size() == 4:
				# the arrival click
				_remember_patch()
				var from_key = str(door_to.split("|")[1]) if "|" in door_to else key
				var p = Mods.patch(from_key)
				var nd = {"rect": door_rect, "to": key, "arrive": [snappedf(w.x, 1), snappedf(w.y, 1)]}
				for nk in door_need:
					if str(door_need[nk]) != "" and str(door_need[nk]) != "0" and str(door_need[nk]) != "false":
						nd[nk] = door_need[nk]
				p["doors_add"].append(nd)
				Mods.save_patch(from_key)
				door_rect = []
				door_to = ""
				drag_from = Vector2i(-1, -1)      # letting go of this click must not start a new door box
				_rebuild_world()
				_say("Door made. (Make one back the same way if you want to return.)")

func _drag(c: Vector2i, _w: Vector2) -> void:
	if tool == "BIOME" and not biome_grab:
		for q in _cells_between(paint_last, c):
			_biome_brush(q)
		paint_last = c
		return
	if drag_from.x >= 0 and ((tool == "COPY" and copy_lasso) or (tool == "MOVE" and move_lasso and move_box.size.x == 0 and move_place.is_empty())):
		if lasso_pts.is_empty():
			lasso_pts = [drag_from]
		for q in _cells_between(lasso_pts.back(), c):
			if q != lasso_pts.back():
				lasso_pts.append(q)
		return
	match tool:
		"TILE", "STAMP", "ERASE", "WALL", "GROUND", "UNDER", "OVER":
			for q in _cells_between(paint_last, c):      # a quick mouse skips cells: the line between is painted too
				_paint_brush(q)
			paint_last = c
		"SMART":
			for q in _cells_between(paint_last, c):
				if edge_i >= 0:
					_edge_brush(q)
				else:
					_smart_add(q)
			paint_last = c
		"SELECT":
			if not selected.is_empty():
				selected["drag_to"] = _w
		"GUIDE":
			if not guide.is_empty():
				guide["x"] = float(guide["x"]) + _w.x - guide_grab.x
				guide["y"] = float(guide["y"]) + _w.y - guide_grab.y
				guide_grab = _w
	overlay.queue_redraw()

func _release(c: Vector2i, w: Vector2) -> void:
	paint_last = Vector2i(-1, -1)
	match tool:
		"BIOME":
			if biome_grab and drag_from.x >= 0:
				_biome_new(_box(drag_from, c))
			else:
				end_stroke()
		"TILE", "STAMP", "ERASE", "WALL", "GROUND", "UNDER", "OVER":
			end_stroke()
			if tool == "UNDER" and under_full > 0:
				_say("%d cells could not go under the hero: both lower layers are used and the tile has see-through parts (something under it would show). ERASE a lower layer there first if you want." % under_full)
			elif tool == "OVER" and under_full > 0:
				_say("%d cells could not go over the hero: nothing there could be lifted (both top layers used, or only a see-through floor tile)." % under_full)
		"SMART" when edge_i >= 0:
			edge_extra = {}
			end_stroke()
		"SMART":
			if not smart_mask.is_empty():
				_say("Joining the edges up (learning from the game's maps the first time)...")
				var n = MT.smart_fill(self, smart_mask, brush_cell)
				end_stroke()
				smart_mask = {}
				_say("Painted, %d edge cells joined up. Ctrl+Z undoes." % n)
		"ZONE":
			if drag_from.x >= 0:
				_remember_patch()
				var kinds = []
				for t in zone_cfg["kinds"].split(",", false):
					if t.strip_edges().is_valid_int():
						kinds.append(int(t))
				if kinds.is_empty():
					kinds = [8]
				var a = Vector2(mini(drag_from.x, c.x) * 8, mini(drag_from.y, c.y) * 8)
				var b = Vector2((maxi(drag_from.x, c.x) + 1) * 8, (maxi(drag_from.y, c.y) + 1) * 8)
				Mods.patch(key)["zones"].append({"rect": [a.x, a.y, b.x, b.y], "kinds": kinds, "count": int(zone_cfg["count"]), "level": int(zone_cfg["level"]), "respawn": int(zone_cfg["respawn"])})
				_rebuild_world()
				_say("Foe zone made: %d foes of %s. SAVE to keep it." % [int(zone_cfg["count"]), str(kinds)])
		"EVENT":
			if drag_from.x >= 0:
				if event_id == "":
					_say("Choose the event it starts on the right (make one in the EVENTS tab).")
				else:
					_remember_patch()
					var a = Vector2(mini(drag_from.x, c.x) * 8, mini(drag_from.y, c.y) * 8)
					var b = Vector2((maxi(drag_from.x, c.x) + 1) * 8, (maxi(drag_from.y, c.y) + 1) * 8)
					var tg = {"rect": [a.x, a.y, b.x, b.y], "event": event_id}
					if event_attack:
						tg["attack"] = true
					Mods.patch(key)["triggers"].append(tg)
					_rebuild_world()
					_say(("An attack landing in there starts event %s. SAVE to keep it." if event_attack else "Walking in there starts event %s. SAVE to keep it.") % event_id)
		"MOOD":
			if drag_from.x >= 0:
				_remember_patch()
				var a = Vector2(mini(drag_from.x, c.x) * 8, mini(drag_from.y, c.y) * 8)
				var b = Vector2((maxi(drag_from.x, c.x) + 1) * 8, (maxi(drag_from.y, c.y) + 1) * 8)
				var md = {"rect": [a.x, a.y, b.x, b.y]}
				for mk in mood_cfg:
					if str(mood_cfg[mk]) != "" and not (mk == "dark" and float(mood_cfg[mk]) <= 0.0):
						md[mk] = mood_cfg[mk]
				if not md.has("dark"):
					md.erase("light")
				Mods.patch(key)["moods"].append(md)
				_rebuild_world()
				_say("Mood box made. SAVE to keep it. PLAY HERE to feel it.")
		"COPY":
			if copy_lasso:
				_copy_lasso()
			else:
				_copy(drag_from, c)
		"MOVE":
			if not move_place.is_empty():
				var mb2: Rect2i = move_place["box"]
				var to2: Vector2i = c - move_place["grab"]
				var mk = str(move_place["key"])
				move_place = {}
				if to2 != mb2.position:
					_move_area(mb2, to2, mk)
			elif drag_from.x >= 0 and move_box.size.x == 0 and move_lasso:
				_lasso_pick()
			elif drag_from.x >= 0 and move_box.size.x == 0:
				move_box = _box(drag_from, c)
				_say("Picked up %d x %d cells and everything on them. Click where its top-left corner goes (Esc or another tool: never mind)." % [move_box.size.x, move_box.size.y])
				_refresh_side()      # (the panel shows what is picked up and NEVER MIND)
		"GUIDE":
			_guide_save()
		"DOOR":
			if door_rect.is_empty() and drag_from.x >= 0:
				var a = Vector2(mini(drag_from.x, c.x) * 8, mini(drag_from.y, c.y) * 8)
				var b = Vector2((maxi(drag_from.x, c.x) + 1) * 8, (maxi(drag_from.y, c.y) + 1) * 8)
				door_rect = [a.x, a.y, b.x, b.y]
				door_to = "from|" + key
				_say("Door box drawn. Now click where it takes you (GO TO MAP first to arrive on another map).")
		"SELECT":
			if selected.has("drag_to"):
				if (selected["drag_to"] as Vector2).distance_to(sel_from) * cam.zoom.x >= 6.0:
					_move_selected(selected["drag_to"])
				else:
					selected.erase("drag_to")      # only a shake: it stays chosen where it is
	drag_from = Vector2i(-1, -1)

func _paint(c: Vector2i) -> void:
	if not _inside(c.x, c.y):
		return
	var v = cell_at(c.x, c.y)
	var i = c.y * int(area["tw"]) + c.x
	if stroke.has(i):
		v = stroke[i][1].duplicate()
	match tool:
		"TILE":
			v[layer] = brush_tile
			last_brush = "TILE"
		"STAMP":      # (PICK's STAMP: the picked cell, or a tile chosen on the right onto its layer)
			if last_brush == "TILE":
				v[layer] = brush_tile
			else:
				v = brush_cell.duplicate()
		"ERASE":
			v[layer] = 0
		"WALL":
			# a wall from the ground; HIGH GROUND stays (a roof's front: no walking in, but you can land on top)
			v[5] = 4 if _hg(int(v[5])) else 0
		"GROUND":
			if high_ground:
				# HIGH GROUND keeps what is underneath: walkable stays walkable (walk behind it), a wall stays a wall
				v[5] = (1 if int(v[5]) & 1 else 0) | 4
			else:
				v[5] = 1
		"UNDER":
			# the top layers (drawn over the hero) go down into the free lower layers, in the same order - what was on
			# top stays on top (ground on 3 and a pillar on 4 had the pillar put under the ground)
			var tops = []
			for l in [3, 4]:
				if int(v[l]) != 0:
					tops.append(int(v[l]))
			# free lower layers above everything already there (a tile put under one already there would be hidden)
			var hi = 2 if int(v[2]) != 0 else (1 if int(v[1]) != 0 else 0)
			var free = []
			for l in [1, 2]:
				if l > hi:
					free.append(l)
			# no room, and the tile going down is solid (not one see-through pixel): what is under it can't be seen anyway,
			# so a hidden lower tile (sand under a rock) makes room - layer 0 is never touched
			while not tops.is_empty() and free.size() < tops.size() and hi > 0 and Assets.tile_solid(tops[0]):
				v[hi] = 0
				hi = 2 if int(v[2]) != 0 else (1 if int(v[1]) != 0 else 0)
				free = []
				for l in [1, 2]:
					if l > hi:
						free.append(l)
			if not tops.is_empty():
				if free.size() < tops.size():
					under_full += 1
				else:
					var slots = free.slice(free.size() - tops.size())      # the highest free ones, in order
					for k in tops.size():
						v[slots[k]] = tops[k]
					v[3] = 0
					v[4] = 0
		"OVER":
			# the lower layers 1-2 go up into a free top layer (drawn over the hero); layer 0, the ground, stays -
			# unless it is all there is and its tile is solid (a room's table top drawn into the floor layer): then it
			# goes up whole (it covers its square, so nothing changes to the eye; the hero now walks behind it).
			if int(v[1]) == 0 and int(v[2]) == 0 and int(v[0]) != 0 and Assets.tile_solid(int(v[0])):
				if int(v[3]) == 0:      # (into 3 only: put on 4 it would come out above what is on 3)
					v[3] = v[0]
					v[0] = 0
				else:
					under_full += 1
			elif int(v[1]) == 0 and int(v[2]) == 0:
				under_full += 1
			# No room on top for what's coming up from 1/2 (copied-in tiles already using both 3 and 4)? Overwrite
			# rather than refuse - once a building covers a cell for good, nobody ever sees what used to be on top.
			# Two incoming tiles with nowhere free go to different layers so the second doesn't erase the first.
			var used_fallback = false
			for l in [2, 1]:
				if int(v[l]) == 0:
					continue
				var to = 3 if int(v[3]) == 0 else (4 if int(v[4]) == 0 else -1)
				if to < 0:
					to = 4 if not used_fallback else 3
					used_fallback = true
				v[to] = v[l]
				v[l] = 0
	put(c.x, c.y, v)

## the brush: paint_size x paint_size cells round c
func _paint_brush(c: Vector2i) -> void:
	var o = (paint_size - 1) / 2
	for dy in paint_size:
		for dx in paint_size:
			_paint(c + Vector2i(dx - o, dy - o))

## every cell on the straight line from a to b (b included; a too when it is the first)
func _cells_between(a: Vector2i, b: Vector2i) -> Array:
	if a.x < 0:
		return [b]
	var out = []
	var n = maxi(absi(b.x - a.x), absi(b.y - a.y))
	for i in range(1, n + 1):
		out.append(Vector2i(roundi(lerpf(a.x, b.x, float(i) / n)), roundi(lerpf(a.y, b.y, float(i) / n))))
	return out

func _smart_add(c: Vector2i) -> void:
	for dy in range(-(smart_size - 1), smart_size):
		for dx in range(-(smart_size - 1), smart_size):
			var q = c + Vector2i(dx, dy)
			if _inside(q.x, q.y) and not smart_mask.has(q):
				smart_mask[q] = true
				put(q.x, q.y, brush_cell)

func _box(a: Vector2i, b: Vector2i) -> Rect2i:
	var x0 = clampi(mini(a.x, b.x), 0, int(area["tw"]) - 1); var y0 = clampi(mini(a.y, b.y), 0, int(area["th"]) - 1)
	var x1 = clampi(maxi(a.x, b.x), 0, int(area["tw"]) - 1); var y1 = clampi(maxi(a.y, b.y), 0, int(area["th"]) - 1)
	return Rect2i(x0, y0, x1 - x0 + 1, y1 - y0 + 1)

func _copy(a: Vector2i, b: Vector2i) -> void:
	var r = _box(a, b)
	var cs = []
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			cs.append(cell_at(x, y))
	clipboard = {"w": r.size.x, "h": r.size.y, "cells": cs}
	_set_tool("PASTE")
	_say("Copied %d x %d cells. Click to lay them down (PASTE)." % [r.size.x, r.size.y])

## COPY with the LASSO: the cells inside the shape (the rest of its box is left out when it is pasted)
func _copy_lasso() -> void:
	var sh = _lasso_shape()
	if sh.is_empty():
		return
	var r: Rect2i = sh["box"]
	var cs = []
	var mk = []
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			cs.append(cell_at(x, y))
			mk.append(1 if sh["mask"].has(Vector2i(x, y)) else 0)
	clipboard = {"w": r.size.x, "h": r.size.y, "cells": cs, "mask": mk}
	_set_tool("PASTE")
	_say("Copied %d cells (LASSO). Click to lay them down (PASTE)." % sh["mask"].size())

## the clipboard turned over: across = left-right (the X key), else upside down (the Y key)
func mirror_clipboard(across: bool) -> void:
	if clipboard.is_empty():
		_say("Copy something first (COPY), then mirror it.")
		return
	var w: int = clipboard["w"]; var h: int = clipboard["h"]
	var src: Array = clipboard["cells"]
	var out = []
	var bit = (1 << 16) if across else (1 << 17)      # each tile drawn turned over too
	for y in h:
		for x in w:
			var v: Array = src[y * w + (w - 1 - x)] if across else src[(h - 1 - y) * w + x]
			v = v.duplicate()
			for k in 5:
				if int(v[k]) != 0:
					v[k] = int(v[k]) ^ bit
			out.append(v)
	if clipboard.has("mask"):
		var mk: Array = clipboard["mask"]
		var om = []
		for y in h:
			for x in w:
				om.append(mk[y * w + (w - 1 - x)] if across else mk[(h - 1 - y) * w + x])
		clipboard["mask"] = om
	clipboard["cells"] = out
	_say("Clipboard mirrored %s. Click to PASTE it." % ("left-right" if across else "upside down"))

## cells laid down with their top-left at c. With keep_ground, the copy's background (the ground tiles
## round its edge) is left out: the ground there stays, only the rest (a pad, a tree, its walls) is laid on it
func _lay(c: Vector2i, w: int, cells: Array, mask: Array = [], own_ground: bool = false) -> void:
	var keep = keep_ground or own_ground     # own_ground: a thing drawn to go over any ground (SAVE POINT)
	var h = cells.size() / maxi(1, w)
	var bg = {}
	if keep:
		for j in cells.size():
			var x = j % w; var y = j / w
			if x == 0 or y == 0 or x == w - 1 or y == h - 1:
				bg[int(cells[j][0])] = true
	for j in cells.size():
		if mask.size() > j and int(mask[j]) == 0:
			continue
		var q = Vector2i(c.x + j % w, c.y + j / w)
		var v: Array = cells[j]
		if not keep:
			put(q.x, q.y, v)
			continue
		if not _inside(q.x, q.y):
			continue
		var i = q.y * int(area["tw"]) + q.x
		var out: Array = (stroke[i][1] if stroke.has(i) else cell_at(q.x, q.y)).duplicate()
		var is_bg = bg.has(int(v[0]))
		var has_obj = false
		for k in range(1, 5):
			if int(v[k]) != 0:
				has_obj = true
		for k in range(1, 5):
			if int(v[k]) != 0 or not is_bg or (own_ground and has_obj):      # nothing of the old place stays on the thing (no flower on the pad)
				out[k] = v[k]
		if is_bg and not has_obj:
			continue
		if not is_bg:
			out[0] = v[0]
		out[5] = v[5]
		put(q.x, q.y, out)

## LASSO let go: the line closed back to where it began; every cell inside it (and on it) picked up
func _lasso_pick() -> void:
	var sh = _lasso_shape()
	if sh.is_empty():
		return
	move_mask = sh["mask"]
	move_box = sh["box"]
	_say("Picked up %d cells and everything on them. Click where it goes (Esc or another tool: never mind)." % move_mask.size())
	_refresh_side()

## the LASSO's line closed back to where it began: {box (cells), mask (Vector2i -> true): the cells inside and on it}
func _lasso_shape() -> Dictionary:
	var pts = lasso_pts
	lasso_pts = []
	if pts.size() < 3:
		_say("Draw round what you want (a bigger shape).")
		return {}
	var poly = PackedVector2Array()
	var lo = pts[0]; var hi = pts[0]
	for q in pts:
		poly.append(Vector2(q) + Vector2(0.5, 0.5))
		lo = Vector2i(mini(lo.x, q.x), mini(lo.y, q.y)); hi = Vector2i(maxi(hi.x, q.x), maxi(hi.y, q.y))
	var m = {}
	for q in pts:
		m[q] = true
	for q in _cells_between(pts.back(), pts[0]):      # (the closing line)
		m[q] = true
	for y in range(lo.y, hi.y + 1):
		for x in range(lo.x, hi.x + 1):
			if Geometry2D.is_point_in_polygon(Vector2(x + 0.5, y + 0.5), poly):
				m[Vector2i(x, y)] = true
	return {"box": Rect2i(lo, hi - lo + Vector2i.ONE), "mask": m}

# ------------------------------------------------------------------ MOVE: a whole part of the map, everything on it
## the box r (cells) laid down with its top-left at `to`, and everything on it with it: the cells (all layers and
## walls), foes, people, treasure, zones, moods, event boxes, doors (theirs moved; doors elsewhere that lead into it
## arrive at the new spot), and the game's places whose corner is in it (their names, songs, own people, story
## warps). The game's own things are taken away and put back moved (as SELECT's drag does); your own are moved.
## SWAP (move_swap): what was where it lands goes to where it came from, everything on it too (nothing is lost);
## COVER: it is covered, and what is left behind becomes the ground round it (_natural_fill). One undo for all.
## (only_place: a place dragged by its name - only it moves as a place; a neighbour overlapping it stays where it is,
## and whatever lies in the overlap goes with the one dragged, like everything else in its box)
## (mask: LASSO - only these cells of the box (Vector2i -> true) and what is on them move; empty: the whole box)
func _move_area(r: Rect2i, to: Vector2i, only_place: String = "", mask: Dictionary = {}) -> void:
	var tw: int = area["tw"]; var th: int = area["th"]
	var d = to - r.position
	if d == Vector2i.ZERO:
		return
	if to.x < 0 or to.y < 0 or to.x + r.size.x > tw or to.y + r.size.y > th:
		_say("It does not fit there: part of it would be off the map. Drop it a little further in.")
		return
	var dest = Rect2i(to, r.size)
	var swap = move_swap and not dest.intersects(r)      # (a box moved onto part of itself can only cover)
	_say("Moving %d x %d cells..." % [r.size.x, r.size.y])
	end_stroke()
	var dp = Vector2(d) * 8.0
	var box = Rect2(Vector2(r.position) * 8.0, Vector2(r.size) * 8.0)
	var box2 = Rect2(Vector2(dest.position) * 8.0, Vector2(dest.size) * 8.0)
	# where a spot goes: in the box picked up +dp; (SWAP) in the box it lands on -dp; else nowhere (null)
	var in_mask = func(v: Vector2, off: Vector2i) -> bool:
		return mask.is_empty() or mask.has(Vector2i(int(floor(v.x / 8.0)), int(floor(v.y / 8.0))) - off)
	var shift = func(x, y):
		var v = Vector2(float(x), float(y))
		if box.has_point(v) and in_mask.call(v, Vector2i.ZERO):
			return dp
		if swap and box2.has_point(v) and in_mask.call(v, d):
			return -dp
		return null
	# 1. the cells: all read first (the old and the new box can overlap)
	var src = []
	var dst = []
	var at_src = []
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			if not mask.is_empty() and not mask.has(Vector2i(x, y)):
				continue
			at_src.append(Vector2i(x, y))
			src.append(cell_at(x, y))
			if swap:
				dst.append(cell_at(x + d.x, y + d.y))
	if swap:
		for j in dst.size():
			put(at_src[j].x, at_src[j].y, dst[j])
	else:
		var covered = {}
		for q in mask:
			covered[q + d] = true
		var fill = _natural_fill(r, dest, mask, covered)
		for at in fill:
			put(at.x, at.y, fill[at])
	for j in src.size():
		put(at_src[j].x + d.x, at_src[j].y + d.y, src[j])
	end_stroke()
	var cell_step: Dictionary = undo.pop_back() if not undo.is_empty() and undo.back().has("cells") else {}
	# 2. everything on it
	var p = Mods.patch(key)
	var snap = {}
	for k in ["enemies_add", "enemies_del", "people_add", "people_del", "doors_add", "doors_del", "items", "items_del", "zones", "triggers", "moods", "places", "rocks_add", "rocks_del"]:
		snap[k] = p[k].duplicate(true)
	var ob = _objects()
	var counts = {"foes": 0, "people": 0, "doors": 0, "things": 0, "places": 0}
	# the game's places whose corner is in a box: their own people come with them by themselves
	var moved_places = {}
	var base_people = []
	if key.begins_with("land/"):
		var kp = key.split("/")
		var L = Assets.land(int(kp[1]))
		var regs: Array = L.get("regions", [])
		if int(kp[2]) < regs.size():
			for m in regs[int(kp[2])].get("maps", []):
				var sv = shift.call(m[1], m[2])
				if only_place != "" and str(m[0]) != only_place:
					sv = null
				if sv != null:
					p["places"][str(m[0])] = [float(m[1]) + sv.x, float(m[2]) + sv.y]
					moved_places[str(m[0])] = sv
					counts["places"] += 1
		base_people = Assets.land_parts(key)["people"]
	var place_of = func(o: Dictionary) -> String: return str(o.get("id", "")).get_slice(":", 0)
	var used = {}
	# foes (a zone's own come with the zone)
	for f in ob["foes"]:
		var sv = shift.call(f["x"], f["y"])
		if f.get("zone", false) or sv == null:
			continue
		var fp = Vector2(float(f["x"]), float(f["y"]))
		var hit = -1
		var ea: Array = p["enemies_add"]
		for i in ea.size():
			if not used.has("e%d" % i) and Vector2(float(ea[i][2]), float(ea[i][3])).distance_to(fp) <= 1.0:
				hit = i; break
		if hit >= 0:
			ea[hit][2] = float(ea[hit][2]) + sv.x; ea[hit][3] = float(ea[hit][3]) + sv.y
			used["e%d" % hit] = true
		else:
			p["enemies_del"].append([fp.x, fp.y])
			ea.append([int(f["type"]), int(f["set"]), fp.x + sv.x, fp.y + sv.y, int(f.get("lv", 1))])
			used["e%d" % (ea.size() - 1)] = true
		counts["foes"] += 1
	# people
	for q in ob["people"]:
		var sv = shift.call(q["x"], q["y"])
		if sv == null:
			continue
		var qp = Vector2(float(q["x"]), float(q["y"]))
		var hit = -1
		var pa: Array = p["people_add"]
		for i in pa.size():
			if not used.has("p%d" % i) and Vector2(float(pa[i]["x"]), float(pa[i]["y"])).distance_to(qp) <= 1.0:
				hit = i; break
		if hit >= 0:
			pa[hit]["x"] = float(pa[hit]["x"]) + sv.x; pa[hit]["y"] = float(pa[hit]["y"]) + sv.y
			used["p%d" % hit] = true
		elif not moved_places.has(place_of.call(q)):
			p["people_del"].append([qp.x, qp.y])
			var nq: Dictionary = q.duplicate(true)
			nq["x"] = qp.x + sv.x; nq["y"] = qp.y + sv.y
			pa.append(nq)
			used["p%d" % (pa.size() - 1)] = true
		counts["people"] += 1
	# people taken away from a place that moved: taken away at its new spot too
	for dl in p["people_del"]:
		for bq in base_people:
			var bk = place_of.call(bq)
			if moved_places.has(bk) and Vector2(float(bq["x"]), float(bq["y"])).distance_to(Vector2(float(dl[0]), float(dl[1]))) <= 6.0:
				var sv2: Vector2 = moved_places[bk]
				dl[0] = float(dl[0]) + sv2.x; dl[1] = float(dl[1]) + sv2.y
				break
	# treasure, zones, moods, event boxes (all your own)
	for it in p["items"]:
		var sv = shift.call(it["x"], it["y"])
		if sv != null:
			it["x"] = float(it["x"]) + sv.x; it["y"] = float(it["y"]) + sv.y
			counts["things"] += 1
	for kz in ["zones", "triggers", "moods"]:
		for z in p[kz]:
			var zr: Array = z["rect"]
			var sv = shift.call((float(zr[0]) + float(zr[2])) / 2.0, (float(zr[1]) + float(zr[3])) / 2.0)
			if sv != null:
				z["rect"] = [float(zr[0]) + sv.x, float(zr[1]) + sv.y, float(zr[2]) + sv.x, float(zr[3]) + sv.y]
				counts["things"] += 1
	# rocks: yours moved; the game's own (unless their whole place moved - they go with it) taken away and put back as yours
	var ra: Array = p["rocks_add"]
	var new_rocks = []
	for rr in _rocks():
		var rc: Vector2 = (rr["pic"] as Rect2).get_center()
		var sv = shift.call(rc.x, rc.y)
		if sv == null or (not bool(rr["own"]) and moved_places.has(str(rr["place"]))):
			continue
		if bool(rr["own"]):
			if int(rr["i"]) < ra.size():
				ra[int(rr["i"])]["x"] = float(ra[int(rr["i"])]["x"]) + sv.x; ra[int(rr["i"])]["y"] = float(ra[int(rr["i"])]["y"]) + sv.y
		else:
			p["rocks_del"].append([str(rr["place"]), int(rr["n"])])
			new_rocks.append(_rock_entry(rr, (rr["pic"] as Rect2).position + sv))
		counts["things"] += 1
	ra.append_array(new_rocks)
	# doors: in a box (moved), or anywhere on this map leading into one (they arrive at its new spot)
	for ex in ob["doors"]:
		var rc: Array = ex["rect"]
		var c = Vector2((float(rc[0]) + float(rc[2])) / 2.0, (float(rc[1]) + float(rc[3])) / 2.0)
		var to_key = str(Game.planet.nodes[int(ex["to"])]["key"]) if ex.has("to") else key
		var ar: Array = ex.get("arrive", [])
		var cs = shift.call(c.x, c.y)
		var as_ = shift.call(ar[0], ar[1]) if to_key == key and ar.size() >= 2 else null
		if cs == null and as_ == null:
			continue
		var nrect = [float(rc[0]) + cs.x, float(rc[1]) + cs.y, float(rc[2]) + cs.x, float(rc[3]) + cs.y] if cs != null else rc.duplicate()
		var narr = [float(ar[0]) + as_.x, float(ar[1]) + as_.y] if as_ != null else ar.duplicate()
		var hit = -1
		var da: Array = p["doors_add"]
		for i in da.size():
			var drc: Array = da[i]["rect"]
			if not used.has("d%d" % i) and Vector2((float(drc[0]) + float(drc[2])) / 2.0, (float(drc[1]) + float(drc[3])) / 2.0).distance_to(c) <= 1.0:
				hit = i; break
		if hit >= 0:
			da[hit]["rect"] = nrect; da[hit]["arrive"] = narr
			used["d%d" % hit] = true
		else:
			p["doors_del"].append([c.x, c.y])
			var nd = {"rect": nrect, "to": to_key, "arrive": narr}
			for nk in ["need_item", "need_flag", "need_level", "locked_msg", "take_item"]:
				if ex.has(nk):
					nd[nk] = ex[nk]
			da.append(nd)
			used["d%d" % (da.size() - 1)] = true
		counts["doors"] += 1
	if counts["places"] > 0 and key.begins_with("land/"):
		Assets.reset_land(int(key.split("/")[1]))
	_rebuild_world()
	_mini_paint([r, dest])
	var step = {"patch": snap}
	if cell_step.has("cells"):
		step["cells"] = cell_step["cells"]
	undo.append(step)
	redo.clear()
	dirty = true
	_say("%s %d x %d cells with %d foes, %d people, %d doors, %d other things and %d of the game's places. SAVE to keep it - Ctrl+Z undoes it all." % [
		"Swapped" if swap else "Moved", r.size.x, r.size.y, counts["foes"], counts["people"], counts["doors"], counts["things"], counts["places"]])

## what a moved part leaves behind: the ground round it, as it is there - patches of the plain ground near the box
## (nothing on the upper layers, walked on or not like round the box, its ground tiles among those at the box's
## edge) copied in, 16 x 16 cells each, picked at random and kept on the game's 2-cell grid (so the grass mixes as
## the map's own does, not one tile again and again). Smaller patches if there is little room; one cell at worst.
## (covered: with LASSO, the cells the moved shape lands on - every other cell of it is filled; else the box it lands on)
func _natural_fill(r: Rect2i, dest: Rect2i, mask: Dictionary = {}, covered: Dictionary = {}) -> Dictionary:
	var tw: int = area["tw"]; var th: int = area["th"]
	var cells: Array = area["land"]["cells"]
	var walk: PackedByteArray = area["walk"]
	var out = {}
	var todo = []
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var q = Vector2i(x, y)
			if not mask.is_empty():
				if mask.has(q) and not covered.has(q):
					todo.append(q)
			elif not dest.has_point(q):
				todo.append(q)
	if todo.is_empty():
		return out
	# what is round the box: its plain ground's tiles (4 cells deep), and whether that ground is walked on
	var wn = [0, 0]
	var ground = {}
	for y in range(r.position.y - 4, r.end.y + 4):
		for x in range(r.position.x - 4, r.end.x + 4):
			if x < 0 or y < 0 or x >= tw or y >= th or r.has_point(Vector2i(x, y)):
				continue
			var i = y * tw + x
			if (cells[1][i] == 0 or cells[1][i] & (1 << 19)) and cells[2][i] == 0 and cells[3][i] == 0 and cells[4][i] == 0:      # (plain: a moving layer over it - the sea's waves - is plain too)
				ground[cells[0][i]] = true
				wn[walk[i] & 1] += 1      # (the plain ground's own: trees and cliffs round it are walls, the grass is not)
	var wb = 1 if wn[1] >= wn[0] else 0
	# the plain ground near the box (96 cells round it), as a summed table: a patch is good if all of it is plain
	var band = Rect2i(r.position - Vector2i(96, 96), r.size + Vector2i(192, 192)).intersection(Rect2i(0, 0, tw, th))
	var bw = band.size.x; var bh = band.size.y
	var sat = PackedInt32Array(); sat.resize((bw + 1) * (bh + 1))
	for y in bh:
		var row = 0
		for x in bw:
			var gx = band.position.x + x; var gy = band.position.y + y
			var i = gy * tw + gx
			var ok = 0
			if not r.has_point(Vector2i(gx, gy)) and (walk[i] & 1) == wb and ground.has(cells[0][i]) and (cells[1][i] == 0 or cells[1][i] & (1 << 19)) and cells[2][i] == 0 and cells[3][i] == 0 and cells[4][i] == 0:
				ok = 1
			row += ok
			sat[(y + 1) * (bw + 1) + x + 1] = sat[y * (bw + 1) + x + 1] + row
	var rng = RandomNumberGenerator.new()
	rng.seed = hash(str(r))
	for size in [16, 8, 4, 2]:
		var spots = []
		for y in range(0, bh - size + 1, 2):
			for x in range(0, bw - size + 1, 2):
				if ((band.position.x + x) - r.position.x) % 2 != 0 or ((band.position.y + y) - r.position.y) % 2 != 0:
					continue
				var s = sat[(y + size) * (bw + 1) + x + size] - sat[y * (bw + 1) + x + size] - sat[(y + size) * (bw + 1) + x] + sat[y * (bw + 1) + x]
				if s == size * size:
					spots.append(Vector2i(band.position.x + x, band.position.y + y))
					if spots.size() >= 600:
						break
			if spots.size() >= 600:
				break
		if spots.is_empty():
			continue
		var pick = {}
		for at in todo:
			var blk = Vector2i((at.x - r.position.x) / size, (at.y - r.position.y) / size)
			if not pick.has(blk):
				pick[blk] = spots[rng.randi_range(0, spots.size() - 1)]
			var src: Vector2i = pick[blk] + Vector2i((at.x - r.position.x) % size, (at.y - r.position.y) % size)
			out[at] = cell_at(src.x, src.y)
		return out
	var one = _ring_cell(r)
	for at in todo:
		out[at] = one
	return out

## the cell seen most often just round a box (what a moved part leaves behind when there is no plain ground near)
func _ring_cell(r: Rect2i) -> Array:
	var n = {}
	var best = []
	var bn = 0
	for x in range(r.position.x - 1, r.end.x + 1):
		for y in [r.position.y - 1, r.end.y]:
			if _inside(x, y):
				var v = cell_at(x, y); var k = str(v); n[k] = int(n.get(k, 0)) + 1
				if n[k] > bn: bn = n[k]; best = v
	for y in range(r.position.y, r.end.y):
		for x in [r.position.x - 1, r.end.x]:
			if _inside(x, y):
				var v = cell_at(x, y); var k = str(v); n[k] = int(n.get(k, 0)) + 1
				if n[k] > bn: bn = n[k]; best = v
	return best if not best.is_empty() else [0, 0, 0, 0, 0, 0]

## the map resized (kept in the map's changes; the game reads it too): 8 to 5000 cells each way. Bigger: new room
## right and below (sea beside the planet, black beside the rooms). Smaller: cut off right and below - only when
## nothing is there that is hard to find again (places, doors or doors leading there, foes, people, treasure, zones,
## moods, event boxes); else it says what and where, and nothing changes. Land there is cut off with it (it says how
## much). Ctrl+Z puts the old size back, with the edited cells that were cut off
func _resize_map(w: int, h: int) -> void:
	var tw: int = area["tw"]; var th: int = area["th"]
	w = clampi(w, 8, 5000); h = clampi(h, 8, 5000)
	if w == tw and h == th:
		_say("It is already %d x %d cells." % [tw, th])
		return
	end_stroke()
	if w < tw or h < th:
		var keep = Rect2(0, 0, w * 8, h * 8)
		var found = []
		var out_pt = func(x, y) -> bool: return not keep.has_point(Vector2(float(x), float(y)))
		var out_rc = func(r: Rect2) -> bool: return r.end.x > keep.end.x or r.end.y > keep.end.y
		var pl = []
		for pt in area["land"].get("parts", []):
			if pt.size() > 3 and out_rc.call(pt[0]):
				pl.append("%s %s" % [str(pt[1]), str(pt[3])])
		if not pl.is_empty():
			found.append("%d places (%s%s)" % [pl.size(), ", ".join(pl.slice(0, 4)), "..." if pl.size() > 4 else ""])
		var ob = _objects()
		var nf = 0
		for f in ob["foes"]:
			if not f.get("zone", false) and out_pt.call(f["x"], f["y"]): nf += 1
		var np = 0
		for q in ob["people"]:
			if out_pt.call(q["x"], q["y"]): np += 1
		var ni = 0
		for it in ob["items"]:
			if out_pt.call(it["x"], it["y"]): ni += 1
		var nd = 0
		for ex in ob["doors"]:
			var rc: Array = ex["rect"]; var ar: Array = ex.get("arrive", [])
			if out_pt.call(rc[2], rc[3]) or (ar.size() >= 2 and out_pt.call(ar[0], ar[1])): nd += 1
		var nz = 0
		var pp = Mods.patch(key)
		for kz in ["zones", "triggers", "moods"]:
			for z in pp[kz]:
				if out_pt.call(z["rect"][2], z["rect"][3]): nz += 1
		for c in [["foes", nf], ["people", np], ["treasures", ni], ["doors (or doors leading there)", nd], ["zones / moods / event boxes", nz]]:
			if int(c[1]) > 0:
				found.append("%d %s" % [int(c[1]), c[0]])
		if not found.is_empty():
			_say("Not resized - the part that would be cut off still has: %s. Move or clear them first." % "; ".join(found))
			return
	# land cut off with it: ground walked on, or anything on the upper layers (sea and black are not counted)
	var nl = 0
	if w < tw or h < th:
		var cells: Array = area["land"]["cells"]
		var walk: PackedByteArray = area["walk"]
		for y in th:
			var x0 = w if y < h else 0
			for x in range(x0, tw):
				var i = y * tw + x
				if (walk[i] & 1) or cells[2][i] != 0 or cells[3][i] != 0 or cells[4][i] != 0:
					nl += 1
	Mods.backup()      # (as SAVE does: the map as it was can be put back)
	undo.append(_set_size([w, h], {}))
	redo.clear()
	_say("The map is %d x %d cells now (saved - a backup of before is kept).%s Ctrl+Z puts it back." % [w, h, (" %d cells of land were cut off with it." % nl) if nl > 0 else ""])

## the map's size set ([]: the map's own), the edited cells past it taken out and the given ones put back; saved
## at once, the map read again (the undo and redo lists kept). Gives back the undo step: the size before and the
## cells taken out
func _set_size(size: Array, restore: Dictionary) -> Dictionary:
	var p = Mods.patch(key)
	var before: Array = p["size"].duplicate()
	p["size"] = size.duplicate()
	var cut = {}
	if not size.is_empty():
		for ck in p["cells"].keys():      # (changes to cells that are cut off go too - kept in the undo step)
			var xy = str(ck).split(",")
			if int(xy[0]) >= int(size[0]) or int(xy[1]) >= int(size[1]):
				cut[ck] = p["cells"][ck]
				p["cells"].erase(ck)
	for ck in restore:
		p["cells"][ck] = restore[ck]
	Mods.save_patch(key)
	Assets._areas.erase(key)
	if key.begins_with("land/"):
		Assets.reset_land(int(key.split("/")[1]))
	var keep_cam = [cam.position, cam.zoom]
	var keep_undo = [undo.duplicate(), redo.duplicate()]
	load_map(key)
	undo = keep_undo[0]; redo = keep_undo[1]
	Game.planet.build_land(0, 1)
	cam.position = keep_cam[0]; cam.zoom = keep_cam[1]
	_refresh_side()
	return {"resize": before, "cut": cut}

# ------------------------------------------------------------------ GUIDE: a picture of your own over the map
func _guide_load() -> void:
	guide = {}
	guide_tex = null
	var j = Assets.json("user://map_guide.json")
	if j is Dictionary and FileAccess.file_exists(str(j.get("path", ""))):
		guide = j
		var img = Image.load_from_file(str(j["path"]))
		if img != null:
			guide_tex = ImageTexture.create_from_image(img)

func _guide_save() -> void:
	if guide.is_empty():
		return
	var f = FileAccess.open("user://map_guide.json", FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(guide))

func _guide_choose() -> void:
	var fd = FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.filters = PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp ; Pictures"])
	fd.title = "A picture to line the map up with"
	fd.use_native_dialog = true      # the computer's own file picker (the Mac's Finder, Windows Explorer)
	ui.add_child(fd)
	fd.file_selected.connect(func(path):
		var img = Image.load_from_file(path)
		if img == null:
			_say("That picture could not be read.")
			return
		guide_tex = ImageTexture.create_from_image(img)
		guide = {"path": path, "x": 0.0, "y": 0.0, "w": float(area["w"]), "h": float(area["w"]) * img.get_height() / maxf(1.0, img.get_width()), "alpha": 0.4, "on": true}
		_guide_save()
		_refresh_side()
		_say("Guide laid over the map. Drag it with GUIDE; BIGGER / SMALLER on the right."))
	fd.canceled.connect(fd.queue_free)
	fd.popup_centered_ratio(0.7)

func _guide_scale(f: float) -> void:
	if guide.is_empty():
		return
	_guide_undo_point()
	var cx = float(guide["x"]) + float(guide["w"]) / 2.0; var cy = float(guide["y"]) + float(guide["h"]) / 2.0
	guide["w"] = float(guide["w"]) * f; guide["h"] = float(guide["h"]) * f
	guide["x"] = cx - float(guide["w"]) / 2.0; guide["y"] = cy - float(guide["h"]) / 2.0
	_guide_save()
	overlay.queue_redraw()

## SELECT: every place of the game - its box (what its name, music and own people cover), its name, its number in
## the game (places with one name are the game's separate maps: a farm, a maze, a lair) and its song; the one
## chosen thick, and where it goes while dragged
## does a story scene of the game go to this place (zone_area)? (the opening's places, for now)
func _story_uses(pk: String) -> bool:
	for s in Story.event("story:intro").get("steps", []):
		if str(s.get("do", "")) == "warp":
			for pt in area["land"].get("parts", []):
				if pt.size() > 3 and str(pt[3]) == pk and (pt[0] as Rect2).has_point(Vector2(float(s["x"]), float(s["y"]))):
					return true
	return false

## a place's name (as _draw_places writes it, at its box's top left) under a spot: [rect, name, song, key] or []
func _place_label_at(w: Vector2) -> Array:
	var font = ThemeDB.fallback_font
	var fs = int(clampf(9.0 / cam.zoom.x, 6, 160))
	var best = []
	var ba = INF
	for pt in area["land"].get("parts", []):
		if pt.size() < 4:
			continue
		var rc: Rect2 = pt[0]
		var tag = "%s  %s%s" % [str(pt[1]) if str(pt[1]) != "" else "?", str(pt[3]), ("  \u266A%d" % int(pt[2])) if int(pt[2]) >= 0 else ""]
		var band = Rect2(rc.position, Vector2(font.get_string_size(tag, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + 4.0 / cam.zoom.x, fs * 1.6))
		if band.has_point(w) and rc.get_area() < ba:      # (overlapping names: the smaller place)
			ba = rc.get_area(); best = pt
	return best

func _draw_places() -> void:
	var font = ThemeDB.fallback_font
	var fs = int(clampf(9.0 / cam.zoom.x, 6, 160))
	var lw = 1.0 / cam.zoom.x
	var sel_key = str(selected.get("obj", {}).get("key", "")) if str(selected.get("kind", "")) == "place" else ""
	for pt in area["land"].get("parts", []):
		if pt.size() < 4:
			continue
		var rc: Rect2 = pt[0]
		var nm = str(pt[1]) if str(pt[1]) != "" else "?"
		var col = Color.from_hsv(float(hash(nm) % 360) / 360.0, 0.55, 1.0)
		var mine = str(pt[3]) == sel_key
		overlay.draw_rect(rc, Color(col.r, col.g, col.b, 0.22 if mine else 0.06))
		overlay.draw_rect(rc, col if not mine else Color(1, 1, 0.3), false, lw * (3.0 if mine else 1.0))
		var tag = "%s  %s%s" % [nm, str(pt[3]), ("  \u266A%d" % int(pt[2])) if int(pt[2]) >= 0 else ""]
		_ov_text(font, rc.position + Vector2(2 * lw, fs + 2 * lw), tag, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
	if not move_place.is_empty() and mouse_cell.x >= 0:      # MOVE: the place being dragged, where it would land
		var mbx: Rect2i = move_place["box"]
		overlay.draw_rect(Rect2(Vector2(mouse_cell - move_place["grab"]) * 8.0, Vector2(mbx.size) * 8.0), Color(0.4, 1, 0.5, 0.15))
		overlay.draw_rect(Rect2(Vector2(mouse_cell - move_place["grab"]) * 8.0, Vector2(mbx.size) * 8.0), Color(0.4, 1, 0.5), false, lw * 2.0)
	if sel_key != "" and selected.has("drag_to"):
		var r0: Rect2 = selected["obj"]["rect"]
		var at: Vector2 = selected["drag_to"]
		overlay.draw_rect(Rect2(at - r0.size / 2.0, r0.size), Color(1, 1, 0.3), false, lw * 2.0)

func _draw_move_and_guide() -> void:
	if guide_tex != null and bool(guide.get("on", true)):
		overlay.draw_texture_rect(guide_tex, Rect2(float(guide["x"]), float(guide["y"]), float(guide["w"]), float(guide["h"])), false, Color(1, 1, 1, float(guide.get("alpha", 0.4))))
	if tool != "MOVE":
		return
	var lw = 1.5 / cam.zoom.x
	if not move_mask.is_empty() and move_box.size.x > 0:      # LASSO: the cells picked up, and where they would land
		var off = Vector2(mouse_cell - move_box.position) * 8.0 if mouse_cell.x >= 0 else Vector2.ZERO
		for q in move_mask:
			overlay.draw_rect(Rect2(Vector2(q) * 8.0, Vector2(8, 8)), Color(1, 0.6, 0.2, 0.3))
			if mouse_cell.x >= 0:
				overlay.draw_rect(Rect2(Vector2(q) * 8.0 + off, Vector2(8, 8)), Color(0.4, 1, 0.5, 0.3))
		return
	if move_lasso and dragging and lasso_pts.size() > 1:      # LASSO: the line being drawn
		var pts = PackedVector2Array()
		for q in lasso_pts:
			pts.append(Vector2(q) * 8.0 + Vector2(4, 4))
		pts.append(pts[0])
		overlay.draw_polyline(pts, Color(1, 0.6, 0.2), lw * 2.0)
		return
	if move_box.size.x > 0:
		var a = Rect2(Vector2(move_box.position) * 8.0, Vector2(move_box.size) * 8.0)
		overlay.draw_rect(a, Color(1, 0.6, 0.2, 0.18))
		overlay.draw_rect(a, Color(1, 0.6, 0.2), false, lw)
		if mouse_cell.x >= 0:
			overlay.draw_rect(Rect2(Vector2(mouse_cell) * 8.0, a.size), Color(0.4, 1, 0.5), false, lw)
	elif dragging and drag_from.x >= 0:
		var a2 = Vector2(mini(drag_from.x, mouse_cell.x), mini(drag_from.y, mouse_cell.y)) * 8.0
		var b2 = Vector2(maxi(drag_from.x, mouse_cell.x) + 1, maxi(drag_from.y, mouse_cell.y) + 1) * 8.0
		overlay.draw_rect(Rect2(a2, b2 - a2), Color(1, 0.6, 0.2, 0.18))
		overlay.draw_rect(Rect2(a2, b2 - a2), Color(1, 0.6, 0.2), false, lw)

func _paste(c: Vector2i) -> void:
	if clipboard.is_empty():
		_say("Copy something first (COPY).")
		return
	_lay(c, int(clipboard["w"]), clipboard["cells"], clipboard.get("mask", []))
	end_stroke()
	_say("Pasted.")

# ------------------------------------------------------------------ foes, people, treasure, doors
func _objects() -> Dictionary:
	var out = {"foes": [], "people": [], "items": [], "doors": []}
	var ni = _node_index()
	if ni >= 0:
		var nd: Dictionary = Game.planet.nodes[ni]
		out["foes"] = nd["spec"].get("fixed", [])
		out["doors"] = nd["exits"]
	out["people"] = area.get("people", [])
	var mp = Mods.merged(key, false)
	var its: Array = mp["items"]
	for d in mp["items_del"]:
		its = its.filter(func(it): return Vector2(float(it["x"]), float(it["y"])).distance_to(Vector2(float(d[0]), float(d[1]))) > 4.0)
	out["items"] = its
	return out

# ------------------------------------------------------------------ SMART - EDGE: the game's shores built where water meets land
## content/edges.json - for each edge (beach, lake, waterfall, foam) the game's own pieces for it, picked from one place
## where the game has that shore clean: in rings from where water meets land (l1, l2 the land's first and second row,
## w1, w2 the water's), each by which of the 8 ways the other kind lies (the sides; a corner only when neither side next
## to it has the other kind: an outside corner) - "<ring>:<ways>". What is water: rule "walls" (not walked on: the sea),
## "ground" (its own ground tiles: a lake's), "anim" (its own moving tiles: a waterfall's). Cut from EARTH; the editor
## only reads it
var edge_extra = {}             # cells this stroke made water (a jutting bit of land filled in)
var edge_bits = PackedByteArray()      # how many bits are set in 0..8191 (5 x 5 patterns compared fast)
const EDGE_WAYS = [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1)]
func _edges() -> void:
	if edges != null:
		return
	var j = Assets.json(Assets.exe_dir().path_join("content/edges.json"))
	edges = j.get("edges", []) if j is Dictionary else []
	for e in edges:
		var g = {}
		for t in e.get("water_ground", []):
			g[int(t)] = true
		var a = {}
		for t in e.get("water_anim", []):
			a[int(t)] = true
		e["ground_set"] = g
		e["anim_set"] = a
		var fs = {}
		for t in e.get("fall", []):
			fs[int(t)] = true
		e["fall_set"] = fs
		var ks = {}
		for k in e.get("keys", []):
			ks[int(k)] = true
		e["key_set"] = ks
	edge_bits.resize(8192)
	for v in 8192:
		var c = 0; var x = v
		while x:
			c += x & 1; x >>= 1
		edge_bits[v] = c

## that edge's water here (as it was before this stroke)
func _edge_water(e: Dictionary, q: Vector2i) -> bool:
	if edge_extra.has(q):
		return true
	var tw: int = area["tw"]
	var qx = clampi(q.x, 0, tw - 1); var qy = clampi(q.y, 0, int(area["th"]) - 1)
	var i = qy * tw + qx
	var v: Array = stroke[i][0] if stroke.has(i) else cell_at(qx, qy)
	match str(e.get("rule", "walls")):
		"match":      # (its own water biome's cells, or water's moving tiles / the ground water lies on)
			if e["key_set"].has(((int(v[0]) & 0x8FFFF) << 20) | (int(v[1]) & 0x8FFFF)):
				return true
			return e["anim_set"].has(int(v[1]) & 0x8FFFF) or e["ground_set"].has(int(v[0]) & 0x8FFFF)
		"ground":
			return e["ground_set"].has(int(v[0]) & 0xFFFF)
		"anim":
			return e["anim_set"].has(int(v[1]) & 0x8FFFF)
	return (int(v[5]) & 1) == 0

## the 8 ways as the pieces are kept: sides as they are, a corner only when neither side next to it has the other kind
static func _edge_ways(m: int) -> int:
	var n = (m >> 1) & 1; var w = (m >> 3) & 1; var e = (m >> 4) & 1; var s = (m >> 6) & 1
	var k = m & 0b01011010
	if not n and not w: k |= m & 1
	if not n and not e: k |= m & 4
	if not s and not w: k |= m & 32
	if not s and not e: k |= m & 128
	return k

## the brush: each cell within the edge's rings (how many rows from where water meets land, on its side) takes the
## game's piece for its ring and the ways the other kind lies - the often-used ones more often; a shape the game has no
## piece for: the nearest it has. The cells chosen first, then laid (a laid one must not change its neighbours' choice)
func _edge_brush(c: Vector2i) -> void:
	if edges == null or edge_i < 0 or edge_i >= edges.size():
		return
	var e: Dictionary = edges[edge_i]
	if e.has("lib"):
		_edge_brush_match(c, e)
		return
	if str(e.get("rule", "")) == "fall":
		_edge_brush_fall(c, e)
		return
	if str(e.get("rule", "")) == "foam":
		_edge_brush_foam(c, e)
		return
	var pieces: Dictionary = e["pieces"]
	var far_land = int(e.get("land", 2)); var far_water = int(e.get("water", 2))
	var rr = edge_size / 2.0
	var picks = {}
	for dy in range(-int(ceil(rr)), int(ceil(rr)) + 1):
		for dx in range(-int(ceil(rr)), int(ceil(rr)) + 1):
			if Vector2(dx, dy).length() > rr:
				continue
			var q = c + Vector2i(dx, dy)
			if not _inside(q.x, q.y):
				continue
			var wet = _edge_water(e, q)
			if not wet and bool(e.get("rock_only", false)):      # (a lake's edge is the foot of a cliff: grass beside it stays)
				var qi = q.y * int(area["tw"]) + q.x
				var qv: Array = stroke[qi][0] if stroke.has(qi) else cell_at(q.x, q.y)
				if int(qv[5]) & 1:
					continue
			var far = far_water if wet else far_land
			var d = 0; var m = 0
			for dd in range(1, far + 1):
				for b in 8:
					for t in range(1, dd + 1):
						if _edge_water(e, q + EDGE_WAYS[b] * t) != wet:
							m |= 1 << b
							break
				if m != 0:
					d = dd
					break
			if d == 0:
				continue
			var pre = "%s%d:" % ["w" if wet else "l", d]
			var key2 = pre + str(_edge_ways(m))
			if not pieces.has(key2):
				var best = 99
				var want = _edge_ways(m)
				for k in pieces:
					if not str(k).begins_with(pre):
						continue
					var x2 = int(str(k).get_slice(":", 1)) ^ want
					var n = 0
					while x2:
						n += x2 & 1; x2 >>= 1
					if n < best:
						best = n; key2 = k
				if not pieces.has(key2):
					continue
			var opts: Array = pieces[key2]
			var tot = 0
			for o in opts:
				tot += int(o[1])
			var r = absi(hash([q.x, q.y])) % maxi(1, tot)
			for o in opts:
				r -= int(o[1])
				if r < 0:
					var cv: Array = (o[0] as Array).map(func(v): return int(v))
					if pre.left(2) in e.get("overlay", []):      # (only its moving layer over your cell - a splash on your own rock)
						var qi = q.y * int(area["tw"]) + q.x
						var own: Array = (stroke[qi][0] if stroke.has(qi) else cell_at(q.x, q.y)).duplicate()
						own[1] = cv[1]
						cv = own
					picks[q] = cv
					break
	for q in picks:
		put(q.x, q.y, picks[q])

## an edge kept as a library ("lib": the lake's): the game's cells from one place, each with which of the 5 x 5 round
## it are water (25 bits); each cell near the shore on the water side takes the one whose pattern is nearest its own
## (the one the game used most among them - next to each other they agree). Too unlike any: untouched
func _edge_brush_match(c: Vector2i, e: Dictionary) -> void:
	var lib: Array = e["lib"]
	var far_land = int(e.get("land", 0)); var far_water = int(e.get("water", 2))
	var rr = edge_size / 2.0
	var picks = {}
	# a lone bit of land jutting into the water (water on 5 or more of its 8 sides): water too, so the shore runs smooth
	var tw: int = area["tw"]
	for dy in range(-int(ceil(rr)), int(ceil(rr)) + 1):
		for dx in range(-int(ceil(rr)), int(ceil(rr)) + 1):
			var q = c + Vector2i(dx, dy)
			if Vector2(dx, dy).length() > rr or not _inside(q.x, q.y) or _edge_water(e, q):
				continue
			var n = 0; var like = Vector2i(-1, -1)
			for w in EDGE_WAYS:
				var wq = q + w
				var wv: Array = stroke[wq.y * tw + wq.x][0] if stroke.has(wq.y * tw + wq.x) else cell_at(clampi(wq.x, 0, tw - 1), clampi(wq.y, 0, int(area["th"]) - 1))
				if _edge_water(e, wq) and (int(wv[0]) & 0xFFFF) >= 365 and (int(wv[0]) & 0xFFFF) <= 377:      # (open water only - not a rim already laid)
					n += 1
					if like.x < 0: like = q + w
			if n >= 5:
				var li = like.y * tw + like.x
				var lv: Array = stroke[li][0] if stroke.has(li) else cell_at(like.x, like.y)
				put(q.x, q.y, lv.duplicate())
				edge_extra[q] = true      # (counted as water from now on in this stroke)
	for dy in range(-int(ceil(rr)), int(ceil(rr)) + 1):
		for dx in range(-int(ceil(rr)), int(ceil(rr)) + 1):
			if Vector2(dx, dy).length() > rr:
				continue
			var q = c + Vector2i(dx, dy)
			if not _inside(q.x, q.y):
				continue
			var m = 0; var b = 0
			for yy in range(-2, 3):
				for xx in range(-2, 3):
					if _edge_water(e, q + Vector2i(xx, yy)):
						m |= 1 << b
					b += 1
			var wet = (m >> 12) & 1
			# more cliff on its right than its left: done as its mirror image (the left's piece, turned over) - both
			# sides of a lake then alike (the game's own lakes have few pieces for rock on the right)
			var flip = false
			if bool(e.get("mirror", false)):
				var ll = 0; var lr = 0
				for yy in 5:
					for xx in [0, 1]:
						if not ((m >> (yy * 5 + xx)) & 1): ll += 1
						if not ((m >> (yy * 5 + 4 - xx)) & 1): lr += 1
				if lr > ll:
					flip = true
					var mm = 0
					for b2 in 25:
						if (m >> b2) & 1: mm |= 1 << ((b2 / 5) * 5 + 4 - b2 % 5)
					m = mm
			# (and more rock below than above: done upside down - the bottom of a lake a reflection of its top; a test)
			var vflip = false
			if bool(e.get("mirror_v", false)):
				var lt = 0; var lb = 0
				for yy in [0, 1]:
					for xx in 5:
						if not ((m >> (yy * 5 + xx)) & 1): lt += 1
						if not ((m >> ((4 - yy) * 5 + xx)) & 1): lb += 1
				if lb > lt:
					vflip = true
					var mv = 0
					for b3 in 25:
						if (m >> b3) & 1: mv |= 1 << ((4 - b3 / 5) * 5 + b3 % 5)
					m = mv
			var d = 0
			for yy in range(-2, 3):
				for xx in range(-2, 3):
					if ((m >> ((yy + 2) * 5 + xx + 2)) & 1) != wet:
						var dd = maxi(absi(xx), absi(yy))
						d = dd if d == 0 else mini(d, dd)
			if d == 0 or d > (far_water if wet else far_land):
				continue
			var best = 99; var top = []
			for o in lib:
				var p = int(o[0])
				if ((p >> 12) & 1) != wet:
					continue
				var x2 = p ^ m
				var n = edge_bits[x2 & 8191] + edge_bits[x2 >> 13]
				var g = int(o[1][0]) & 0xFFFF
				const RING = (1 << 6) | (1 << 7) | (1 << 8) | (1 << 11) | (1 << 13) | (1 << 16) | (1 << 17) | (1 << 18)
				if g >= 40 and g <= 200 and ((~p & RING) & (m & RING)) != 0:
					continue      # (a piece with the cliff's rock in it: only where every cell next to it the piece has as rock is rock - else rock juts into the water)
				if n < best or (n == best and int(o[2]) > int(top[2])):
					best = n; top = o
			var plain = top.is_empty() or best > 8 or (int(top[1][0]) & 0xFFFF in range(365, 378))
			var above = Vector2i(0, 1) if vflip else Vector2i(0, -1)
			if wet and plain and not _edge_water(e, q + above) and (_edge_water(e, q + Vector2i(-1, 0)) or _edge_water(e, q + Vector2i(1, 0))) and e.has("flat_top"):
				top = [0, e["flat_top"], 1]      # (cliff straight above: the game's straight-top rim - the flat bits of a steep shore)
				flip = not _edge_water(e, q + Vector2i(1, 0))      # (rock on its right: turned over - it slopes up to the left there)
			elif top.is_empty() or best > 8:
				continue
			var cv: Array = (top[1] as Array).map(func(v): return int(v))
			if flip:
				for k in 5:
					if cv[k] != 0:
						cv[k] = cv[k] ^ (1 << 16)
			if vflip:
				for k in 5:
					if cv[k] != 0:
						cv[k] = cv[k] ^ (1 << 17)
			picks[q] = cv
	for q in picks:
		put(q.x, q.y, picks[q])

## a waterfall's falling water here (its moving tiles on layer 1 - as it was before this stroke)
func _is_fall(e: Dictionary, q: Vector2i) -> bool:
	if not _inside(q.x, q.y):
		return false
	var i = q.y * int(area["tw"]) + q.x
	var v: Array = stroke[i][0] if stroke.has(i) else cell_at(q.x, q.y)
	return (int(v[1]) & (1 << 19)) != 0 and e["fall_set"].has(int(v[1]) & 0xFFFF)

## WATERFALL EDGE - the game's own waterfall (the big one by the lake): its outermost column on each side is one of its
## soft side pictures (mirrored on the left), the second from the left its own soft column, which follows the falling
## water's 3-row cycle (the cell's own picture's place in it). The rock under it stays
func _edge_brush_fall(c: Vector2i, e: Dictionary) -> void:
	var rr = edge_size / 2.0
	var sides: Array = e["sides"]
	var phase: Dictionary = e["phase"]
	for dy in range(-int(ceil(rr)), int(ceil(rr)) + 1):
		for dx in range(-int(ceil(rr)), int(ceil(rr)) + 1):
			var q = c + Vector2i(dx, dy)
			if Vector2(dx, dy).length() > rr or not _is_fall(e, q):
				continue
			var i = q.y * int(area["tw"]) + q.x
			var v: Array = (stroke[i][1] if stroke.has(i) else cell_at(q.x, q.y)).duplicate()
			var left = _is_fall(e, q + Vector2i(-1, 0)); var right = _is_fall(e, q + Vector2i(1, 0))
			var pick = absi(hash([q.x, q.y])) % sides.size()
			if not left:
				v[1] = int(sides[pick]) | (1 << 19) | (1 << 16)
			elif not right:
				v[1] = int(sides[pick]) | (1 << 19)
			elif not _is_fall(e, q + Vector2i(-2, 0)):
				var ph = int(phase.get(str(int(v[1]) & 0xFFFF), posmod(q.y, 3)))
				v[1] = int(e["inner_left"][ph])
			else:
				continue
			put(q.x, q.y, v)

## foam may go here: water or rock (a splash shows in front of the cliff) - not the fall itself, nor ground walked on
func _foam_ok(e: Dictionary, q: Vector2i) -> bool:
	if not _inside(q.x, q.y) or _is_fall(e, q):
		return false
	var i = q.y * int(area["tw"]) + q.x
	var v: Array = stroke[i][0] if stroke.has(i) else cell_at(q.x, q.y)
	return (int(v[5]) & 1) == 0

## water below a fall (as it was before this stroke): not walked on, something on layer 1 that is not the fall itself (a
## lake's water is moving or still there) - a lake, the sea, foam; never bare rock
func _foam_water(e: Dictionary, q: Vector2i) -> bool:
	if not _inside(q.x, q.y):
		return false
	var i = q.y * int(area["tw"]) + q.x
	var v: Array = stroke[i][0] if stroke.has(i) else cell_at(q.x, q.y)
	return int(v[1]) != 0 and not e["fall_set"].has(int(v[1]) & 0xFFFF) and (int(v[5]) & 1) == 0

## FOAM EDGE - where a waterfall's bottom meets the water below: the game's own foam (its big waterfall's): its band
## under the fall, lined up with the fall's lowest point, and its own shoulders of foam each side
func _edge_brush_foam(c: Vector2i, e: Dictionary) -> void:
	var rr = edge_size / 2.0
	var band: Array = e["band"]
	var bw: int = (band[0] as Array).size()
	var nrow: int = band.size()
	var tw: int = area["tw"]
	var done = {}
	for dy in range(-int(ceil(rr)) - 8, int(ceil(rr)) + 1):
		for dx in range(-int(ceil(rr)), int(ceil(rr)) + 1):
			var q = c + Vector2i(dx, dy)
			if not _is_fall(e, q) or _is_fall(e, q + Vector2i(0, 1)) or not _foam_water(e, q + Vector2i(0, 1)):
				continue      # (a cell of the fall's bottom, with water below it - not a step in its side over rock)
			# its whole width - a ragged bottom (one column ending higher) is still the one fall
			var near = func(x: int) -> bool:
				for k in 4:
					if _is_fall(e, Vector2i(x, q.y - k)) or _is_fall(e, Vector2i(x, q.y + k)):
						return true
				return false
			var l = q.x; var r = q.x
			while near.call(l - 1) and q.x - l < 64: l -= 1
			while near.call(r + 1) and r - q.x < 64: r += 1
			if done.has(l):
				continue
			done[l] = true
			var bottoms = {}; var base = q.y
			for x in range(l, r + 1):
				var y = q.y
				while _is_fall(e, Vector2i(x, y + 1)) and y - q.y < 16: y += 1
				while not _is_fall(e, Vector2i(x, y)) and y > q.y - 16: y -= 1
				if _is_fall(e, Vector2i(x, y)):
					bottoms[x] = y
					base = maxi(base, y)
			var high = base
			for x in bottoms:
				high = mini(high, int(bottoms[x]))
			# the cloud: under the fall and three past each side, shallower towards its ends (round); only over water
			var soft_bottom = nrow - 1
			var cloud = {}
			for x in range(l - 3, r + 4):
				var out = maxi(l - x, x - r)      # cells beside the fall (0 under it)
				var top = (bottoms[x] + 1) if bottoms.has(x) else high + out
				var bottom = base + nrow - maxi(0, out - 1)
				for y in range(top, bottom + 1):
					var t = Vector2i(x, y)
					if _foam_water(e, t) and not _is_fall(e, t):
						cloud[t] = true
			# each cell's piece by what is round it: soft at its bottom; at a top that is not the fall full foam with the
			# soft spray (turned upside down) in the water above it; foam inside - no lake showing through
			for t in cloud:
				var col = 1 + posmod(t.x - l, bw - 2)
				var cv: Array
				if not cloud.has(t + Vector2i(0, 1)):
					cv = (band[soft_bottom][col] as Array).map(func(v): return int(v))
				elif not cloud.has(t + Vector2i(0, -1)) and not _is_fall(e, t + Vector2i(0, -1)):
					cv = (band[0][col] as Array).map(func(v): return int(v))
					var up = t + Vector2i(0, -1)
					if _foam_water(e, up):
						var sv: Array = (band[soft_bottom][col] as Array).map(func(v): return int(v))
						for k in 5:
							if sv[k] != 0:
								sv[k] = sv[k] ^ (1 << 17)
						put(up.x, up.y, sv)
				else:
					var depth = 0
					while cloud.has(t - Vector2i(0, depth + 1)) and depth < nrow:
						depth += 1
					cv = (band[clampi(depth, 0, nrow - 2)][col] as Array).map(func(v): return int(v))
				put(t.x, t.y, cv)

## an edge's little picture: 6 x 6 cells of the game's own edge, kept in its file (the map changes)
func _edge_icon(e: Dictionary) -> Texture2D:
	var cells: Array = e.get("icon", [])
	var im = Image.create_empty(48, 48, false, Image.FORMAT_RGBA8)
	for j in mini(36, cells.size()):
		for k in 5:
			var t = _cell_image(int(cells[j][k]))
			if t != null:
				im.blend_rect(t, Rect2i(0, 0, 8, 8), Vector2i((j % 6) * 8, (j / 6) * 8))
	return ImageTexture.create_from_image(im)

# ------------------------------------------------------------------ BIOME: natural ground painted on
## the starting biomes come with the game (builtin/biomes.json: clean patches of the game's own ground, as tile numbers -
## cut once from EARTH, so moving places about never changes them); yours are content/biomes.json. Ones there named
## like the starting ones (copies an earlier editor made from the map) are left out
const OLD_DEFAULT_NAMES = ["GREEN GRASS", "GREEN GRASS (DEEP)", "GRASS AND FLOWERS", "AUTUMN GRASS", "DIRT", "SNOW", "SNOWDRIFTS",
	"STONE PAVING", "CITY TILES", "WASTELAND", "DESERT SAND", "BEACH SAND", "CROPS", "SEA", "LAKE WATER", "WATERFALL",
	"WATERFALL FOAM", "NAMEK GRASS", "NAMEK WATER", "CLIFF"]
var biome_builtin = 0           # how many of biomes are the game's own (the first ones)

func _biomes_path() -> String:
	return Assets.exe_dir().path_join("content/biomes.json")

func _biomes() -> void:
	if biomes != null:
		return
	var bj = Assets.json(Assets.builtin_dir().path_join("biomes.json"))
	biomes = (bj.get("biomes", []) if bj is Dictionary else []).duplicate()
	biome_builtin = biomes.size()
	var names = {}
	for b in biomes:
		names[str(b["name"])] = true
	var j = Assets.json(_biomes_path())
	for b in (j.get("biomes", []) if j is Dictionary else []):
		if not names.has(str(b["name"])) and not str(b["name"]) in OLD_DEFAULT_NAMES:
			biomes.append(b)

func _biomes_save() -> void:
	DirAccess.make_dir_recursive_absolute(_biomes_path().get_base_dir())
	var f = FileAccess.open(_biomes_path(), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"biomes": biomes.slice(biome_builtin)}))

## a box of the map as a biome: its cells (every layer and the walls)
func _biome_from(r: Rect2i) -> Dictionary:
	var cs = []
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			cs.append(cell_at(x, y))
	return {"w": r.size.x, "h": r.size.y, "cells": cs}

func _biome_new(r: Rect2i) -> void:
	biome_grab = false
	if r.size.x < 4 or r.size.y < 4:
		_say("Drag a bigger box (16 x 16 cells or more looks best).")
		_refresh_side()
		return
	var b = _biome_from(r)
	var nm = biome_newname.strip_edges().to_upper()
	b["name"] = nm if nm != "" and nm != "MY GROUND" else "MY GROUND %d" % (biomes.size() + 1)
	undo.append({"biomes": biomes.duplicate()}); redo.clear()
	biomes.append(b)
	biome_i = biomes.size() - 1
	_biomes_save()
	_refresh_side()
	_say("Biome %s made from %d x %d cells - paint with it now." % [b["name"], r.size.x, r.size.y])

## a round brush of the biome: each 16 x 16 block of the map takes its own piece of the patch, picked at random (the
## same piece every time for that block - painting over it again keeps it), kept on the game's 2-cell grid
func _biome_brush(c: Vector2i) -> void:
	if biomes == null or biome_i >= biomes.size():
		return
	var b: Dictionary = biomes[biome_i]
	var bw: int = b["w"]; var bh: int = b["h"]
	var cs: Array = b["cells"]
	var rr = biome_size / 2.0
	for dy in range(-int(ceil(rr)), int(ceil(rr)) + 1):
		for dx in range(-int(ceil(rr)), int(ceil(rr)) + 1):
			if Vector2(dx, dy).length() > rr:
				continue
			var q = c + Vector2i(dx, dy)
			if not _inside(q.x, q.y):
				continue
			var blk = Vector2i(floori(q.x / 16.0), floori(q.y / 16.0))
			var h = absi(hash([blk.x, blk.y, biome_i]))
			var ox = (h % maxi(1, bw / 2)) * 2; var oy = ((h / 7919) % maxi(1, bh / 2)) * 2
			var sx = posmod(q.x - blk.x * 16 + ox, bw); var sy = posmod(q.y - blk.y * 16 + oy, bh)
			put(q.x, q.y, (cs[sy * bw + sx] as Array).duplicate())

## a biome's little picture (16 x 16 of its cells, every layer; water and the like as their first picture)
func _biome_icon(b: Dictionary) -> Texture2D:
	if biome_icons.has(b["name"]):
		return biome_icons[b["name"]]
	var n = mini(16, mini(int(b["w"]), int(b["h"])))
	var im = Image.create_empty(n * 8, n * 8, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			for k in 5:
				var t = _cell_image(int(b["cells"][y * int(b["w"]) + x][k]))
				if t != null:
					im.blend_rect(t, Rect2i(0, 0, 8, 8), Vector2i(x * 8, y * 8))
	var tx = ImageTexture.create_from_image(im)
	biome_icons[b["name"]] = tx
	return tx

## one tile of a cell as an 8 x 8 picture, from the tile set the map is drawn with (an animated one: its first picture)
var _src_imgs = {}
func _cell_image(v: int) -> Image:
	var r = Assets.kit_cell(v) if v != 0 else []
	if r.is_empty():
		return null
	var si = int(r[2])
	var src = Assets.tileset().get_source(si) as TileSetAtlasSource
	if src == null or src.texture == null:
		return null
	var tk = src.texture.get_rid().get_id()      # (the strips share big textures: one copy each, the strip's tiles at its margin)
	if not _src_imgs.has(tk):
		var si_img: Image = src.texture.get_image()
		if si_img != null:
			si_img.convert(Image.FORMAT_RGBA8)
		_src_imgs[tk] = si_img
	var img: Image = _src_imgs[tk]
	if img == null:
		return null
	var at: Vector2i = r[0]
	var t = img.get_region(Rect2i(src.margins + at * 8, Vector2i(8, 8)))
	if int(r[1]) & TileSetAtlasSource.TRANSFORM_TRANSPOSE:
		var tt = Image.create_empty(8, 8, false, Image.FORMAT_RGBA8)
		for yy in 8:
			for xx in 8:
				tt.set_pixel(yy, xx, t.get_pixel(xx, yy))
		t = tt
	if int(r[1]) & TileSetAtlasSource.TRANSFORM_FLIP_H: t.flip_x()
	if int(r[1]) & TileSetAtlasSource.TRANSFORM_FLIP_V: t.flip_y()
	return t

## this map's breakables (made once, again after a change)
func _rocks() -> Array:
	if rock_cache == null:
		rock_cache = rock_b.rock_list(area) if area.has("land") else []
	return rock_cache

## ROCK: one of yours set down where you clicked (the picture's middle there)
func _place_rock(w: Vector2) -> void:
	var rk = rock_b.like_rock(rock_like)
	if rk.is_empty():
		_say("Choose a rock on the right first.")
		return
	_remember_patch()
	Mods.patch(key)["rocks_add"].append({"x": snappedf(w.x - float(rk["w"]) / 2.0, 1), "y": snappedf(w.y - float(rk["h"]) / 2.0, 1), "like": rock_like,
		"hits": rock_hits, "drops": rock_b.DROP_TABLES[rock_drops][1]})
	_rebuild_world()
	_say("Rock set down (%d hit%s, drops: %s). SAVE to keep it." % [rock_hits, "" if rock_hits == 1 else "s", rock_b.DROP_TABLES[rock_drops][0]])

## a rock taken away: yours out of the list, the game's own remembered as gone (rocks_del)
func _rock_remove(p: Dictionary, o: Dictionary) -> void:
	if bool(o["own"]):
		var ra: Array = p["rocks_add"]
		for i in ra.size():
			if absf(float(ra[i]["x"]) - o["pic"].position.x) < 0.5 and absf(float(ra[i]["y"]) - o["pic"].position.y) < 0.5:
				ra.remove_at(i)
				return
	else:
		p["rocks_del"].append([str(o["place"]), int(o["n"])])

## a rock as one of yours (a game rock moved or changed becomes one): its entry for rocks_add, at the picture's top left
func _rock_entry(o: Dictionary, at: Vector2) -> Dictionary:
	var rk: Dictionary = o["rk"]
	return {"x": snappedf(at.x, 1), "y": snappedf(at.y, 1), "like": str(o["id"]) if not bool(o["own"]) else str(Mods.patch(key)["rocks_add"][int(o["i"])].get("like", "")) if int(o["i"]) < Mods.patch(key)["rocks_add"].size() else "",
		"hits": int(rk.get("hits", 1)), "drops": rk.get("drops", [])}.merged({"scene": rk["scene"]} if rk.has("scene") else {})      # (a story rock moved: its scene goes with it)

## the drop table a rock has, as the ROCK tool's choice (-1: its own, none of those)
func _drops_i(drops) -> int:
	var norm = func(t) -> String:      # (numbers read from a file are 40.0, not 40)
		return JSON.stringify((t if t is Array else []).map(func(b): return [int(b[0]), str(b[1]), int(b[2])]))
	for i in rock_b.DROP_TABLES.size():
		if norm.call(rock_b.DROP_TABLES[i][1]) == norm.call(drops):
			return i
	return -1

## SELECT on a rock: its hits and drops to change (the game's own become yours, on the same spot - one Ctrl+Z)
func _rock_editor(o: Dictionary) -> void:
	var rk: Dictionary = o["rk"]
	_lab("ROCK%s: %d hit%s. %s" % ["" if bool(o["own"]) else " (the game's, place %s)" % str(o["place"]), int(rk.get("hits", 1)), "" if int(rk.get("hits", 1)) == 1 else "s",
		"A story scene plays when it breaks." if rk.has("scene") else ""])
	var hs = _spin(side, "hits it takes", 1, 3, int(rk.get("hits", 1)), func(_v): pass)
	var dob = OptionButton.new(); dob.clip_text = true; dob.custom_minimum_size = Vector2(230, 0); dob.add_theme_font_size_override("font_size", 11)
	var di = _drops_i(rk.get("drops", []))
	for t in rock_b.DROP_TABLES:
		dob.add_item(str(t[0]))
	if di < 0:
		dob.add_item("ITS OWN"); di = dob.item_count - 1
	dob.select(di)
	side.add_child(dob)
	var sv = Button.new(); sv.text = "SAVE CHANGES"; side.add_child(sv)
	sv.pressed.connect(func():
		var e = _rock_entry(o, (o["pic"] as Rect2).position)
		e["hits"] = int(hs.value)
		if dob.selected < rock_b.DROP_TABLES.size():
			e["drops"] = rock_b.DROP_TABLES[dob.selected][1]
		selected["entry"] = e
		_move_selected((o["pic"] as Rect2).get_center())
		_say("Rock changed. SAVE to keep it (Ctrl+Z undoes)."))

func _pick_object(w: Vector2) -> Dictionary:
	var ob = _objects()
	var best = {}
	var bd = 12.0 / cam.zoom.x + 4.0
	for f in ob["foes"]:
		var d = Vector2(float(f["x"]), float(f["y"])).distance_to(w)
		if d < bd: bd = d; best = {"kind": "foe", "obj": f}
	for p in ob["people"]:
		var d = Vector2(float(p["x"]), float(p["y"])).distance_to(w)
		if d < bd: bd = d; best = {"kind": "person", "obj": p}
	for it in ob["items"]:
		var d = Vector2(float(it["x"]), float(it["y"])).distance_to(w)
		if d < bd: bd = d; best = {"kind": "item", "obj": it}
	if best.is_empty():
		for rr in _rocks():
			if (rr["pic"] as Rect2).has_point(w) and (rr["rect"] as Rect2).grow(6.0).has_point(w):
				best = {"kind": "rock", "obj": rr}
	if best.is_empty():
		var own = Mods.patch(key)
		for kz in [["zones", "zone"], ["triggers", "trigger"], ["moods", "mood"]]:
			for z in own[kz[0]]:
				var r: Array = z["rect"]
				if w.x >= float(r[0]) and w.x <= float(r[2]) and w.y >= float(r[1]) and w.y <= float(r[3]):
					best = {"kind": kz[1], "obj": z}
	if best.is_empty() or cam.zoom.x < FAR_ZOOM:      # a place's label (its name in the middle of it): drag it to move the place
		var bl = 40.0 / cam.zoom.x                    # (zoomed right out the labels come first)
		var lab = {}
		for pt in area["land"].get("parts", []):
			if pt.size() > 3 and str(pt[1]) != "":
				var d = (pt[0] as Rect2).get_center().distance_to(w)
				if d < bl:
					bl = d; lab = {"kind": "place", "obj": {"key": str(pt[3]), "name": str(pt[1]), "rect": pt[0]}}
		if not lab.is_empty():
			best = lab
	if best.is_empty():
		for ex in ob["doors"]:
			var r: Array = ex["rect"]
			if w.x >= float(r[0]) - 3 and w.x <= float(r[2]) + 3 and w.y >= float(r[1]) - 3 and w.y <= float(r[3]) + 3:
				best = {"kind": "door", "obj": ex}
				break
	return best

## SELECT on a person: their name, look and lines to change (the game's own people too: they are taken away and put
## back changed, on the same spot - one Ctrl+Z undoes it)
## the person just placed with PERSON, found by their spot on the map (-1: gone, or another map)
func _last_person_i() -> int:
	if last_person.is_empty() or last_person_key != key:
		return -1
	var pa: Array = Mods.patch(key)["people_add"]
	for i in pa.size():
		if Vector2(float(pa[i]["x"]), float(pa[i]["y"])).distance_to(Vector2(float(last_person["x"]), float(last_person["y"]))) < 1.0:
			return i
	return -1

func _person_editor(o: Dictionary) -> void:
	_lab("PERSON - change and press SAVE CHANGES:")
	var nm = _line(side, "name", str(o.get("name", "")), func(_t): pass)
	var st = _spin(side, "sprite set", 0, 3999, int(o.get("set", 0)), func(_v): pass)
	_lab("What they say (one line each, A goes to the next):")
	var txt = []
	for l in o.get("lines", []):
		var t = str(l[2]) if l is Array and l.size() > 2 else str(l)
		if t.strip_edges() != "":
			txt.append(t.strip_edges())
	var te = TextEdit.new(); te.text = "\n".join(PackedStringArray(txt)); te.custom_minimum_size = Vector2(230, 110)
	side.add_child(te)
	var sv = Button.new(); sv.text = "SAVE CHANGES"; side.add_child(sv)
	sv.pressed.connect(func():
		var e: Dictionary = o.duplicate(true)
		var pname = nm.text.strip_edges().to_upper()
		e["name"] = pname
		e["set"] = int(st.value)
		var lines = []
		for l in te.text.split("\n"):
			if l.strip_edges() != "":
				lines.append(["", pname, l.strip_edges()])
		e["lines"] = lines
		selected["obj"] = e
		_move_selected(Vector2(float(e["x"]), float(e["y"])))
		selected = {"kind": "person", "obj": e}
		_refresh_side()
		_say("%s changed. SAVE to keep it (Ctrl+Z undoes)." % pname))

func _delete_selected() -> void:
	if selected.is_empty():
		return
	if str(selected["kind"]) == "place":
		_remember_patch()
		var o0: Dictionary = selected["obj"]
		Mods.patch(key)["places"][str(o0["key"])] = []
		if key.begins_with("land/"):
			Assets.reset_land(int(key.split("/")[1]))
		var warn = ""
		if Story.ready() and _story_uses(str(o0["key"])):
			warn = " (Note: a story scene goes to this place - it will need a new spot.)"
		selected = {}
		_rebuild_world()
		_refresh_side()
		_say("%s (%s) deleted: no name, music or people of its own there now. SAVE to keep it, Ctrl+Z to bring it back.%s" % [str(o0["name"]), str(o0["key"]), warn])
		return
	_remember_patch()
	var p = Mods.patch(key)
	var o: Dictionary = selected["obj"]
	match str(selected["kind"]):
		"foe":
			var before = p["enemies_add"].size()
			p["enemies_add"] = p["enemies_add"].filter(func(e): return Vector2(float(e[2]), float(e[3])).distance_to(Vector2(float(o["x"]), float(o["y"]))) > 1.0)
			if p["enemies_add"].size() == before:
				p["enemies_del"].append([o["x"], o["y"]])
		"person":
			var before = p["people_add"].size()
			p["people_add"] = p["people_add"].filter(func(e): return Vector2(float(e["x"]), float(e["y"])).distance_to(Vector2(float(o["x"]), float(o["y"]))) > 1.0)
			if p["people_add"].size() == before:
				p["people_del"].append([o["x"], o["y"]])
		"rock":
			_rock_remove(p, o)
		"zone":
			p["zones"].erase(o)
		"trigger":
			p["triggers"].erase(o)
		"mood":
			p["moods"].erase(o)
		"item":
			var before = p["items"].size()
			p["items"] = p["items"].filter(func(e): return Vector2(float(e["x"]), float(e["y"])).distance_to(Vector2(float(o["x"]), float(o["y"]))) > 1.0)
			if p["items"].size() == before:
				p["items_del"].append([o["x"], o["y"]])
		"door":
			var r: Array = o["rect"]
			var c = Vector2((float(r[0]) + float(r[2])) / 2.0, (float(r[1]) + float(r[3])) / 2.0)
			var before = p["doors_add"].size()
			p["doors_add"] = p["doors_add"].filter(func(d): return Vector2((float(d["rect"][0]) + float(d["rect"][2])) / 2.0, (float(d["rect"][1]) + float(d["rect"][3])) / 2.0).distance_to(c) > 1.0)
			if p["doors_add"].size() == before:
				p["doors_del"].append([c.x, c.y])
	selected = {}
	_rebuild_world()
	_refresh_side()
	_say("Deleted. SAVE to keep it (Ctrl+Z undoes).")

func _move_selected(to: Vector2) -> void:
	var o: Dictionary = selected["obj"].duplicate(true)
	var kind = str(selected["kind"])
	if kind == "place":      # a place of the game: its name, song, own people and story warps (one Ctrl+Z)
		_remember_patch()
		var pr: Rect2 = o["rect"]
		var pk = str(o["key"])
		var np = Vector2(snappedf(to.x - pr.size.x / 2.0, 8), snappedf(to.y - pr.size.y / 2.0, 8))
		var dv = np - pr.position
		var pp = Mods.patch(key)
		# its people you changed or took away (kept by their spot) go with it too
		var base_people = Assets.land_parts(key)["people"] if key.begins_with("land/") else []
		for dl in pp["people_del"]:
			for bq in base_people:
				if str(bq.get("id", "")).get_slice(":", 0) == pk and Vector2(float(bq["x"]), float(bq["y"])).distance_to(Vector2(float(dl[0]), float(dl[1]))) <= 6.0:
					dl[0] = float(dl[0]) + dv.x; dl[1] = float(dl[1]) + dv.y
					break
		for pa in pp["people_add"]:
			if str(pa.get("id", "")).get_slice(":", 0) == pk:
				pa["x"] = float(pa["x"]) + dv.x; pa["y"] = float(pa["y"]) + dv.y
		pp["places"][pk] = [np.x, np.y]
		if key.begins_with("land/"):
			Assets.reset_land(int(key.split("/")[1]))
		_rebuild_world()
		selected = {}
		_refresh_side()
		_say("%s moved (its name, music, own people and story warps go with it). SAVE to keep it." % str(o["name"]))
		return
	var rock_e = {}
	if kind == "rock":      # (worked out before it is taken away: yours are found by their place in the list)
		rock_e = selected["entry"] if selected.has("entry") else _rock_entry(o, (to - (o["pic"] as Rect2).size / 2.0).round())
	_delete_selected()      # (its snapshot of the map's lists, taken before, is the whole move's one undo step)
	var p = Mods.patch(key)
	match kind:
		"foe":
			p["enemies_add"].append([int(o["type"]), int(o["set"]), snappedf(to.x, 1), snappedf(to.y, 1), int(o.get("lv", 1))])
		"person":
			o["x"] = snappedf(to.x, 1); o["y"] = snappedf(to.y, 1)
			p["people_add"].append(o)
		"item":
			o["x"] = snappedf(to.x, 1); o["y"] = snappedf(to.y, 1)
			p["items"].append(o)
		"rock":
			p["rocks_add"].append(rock_e)
		"zone", "trigger", "mood":
			var r: Array = o["rect"]
			var dw = float(r[2]) - float(r[0]); var dh = float(r[3]) - float(r[1])
			o["rect"] = [snappedf(to.x - dw / 2, 8), snappedf(to.y - dh / 2, 8), snappedf(to.x - dw / 2, 8) + dw, snappedf(to.y - dh / 2, 8) + dh]
			p[{"zone": "zones", "trigger": "triggers", "mood": "moods"}[kind]].append(o)
		"door":
			var r: Array = o["rect"]
			var dw = float(r[2]) - float(r[0]); var dh = float(r[3]) - float(r[1])
			var to_key = str(Game.planet.nodes[int(o["to"])]["key"]) if o.has("to") else key
			var nd2 = {"rect": [to.x - dw / 2, to.y - dh / 2, to.x + dw / 2, to.y + dh / 2], "to": to_key, "arrive": o["arrive"]}
			for nk in ["need_item", "need_flag", "need_level", "locked_msg", "take_item"]:
				if o.has(nk):
					nd2[nk] = o[nk]
			p["doors_add"].append(nd2)
	_rebuild_world()
	selected = {}
	_refresh_side()
	_say("Moved.")

# ------------------------------------------------------------------ drawing
func _process(_dt: float) -> void:
	if tab != "MAP":
		return
	var sp = 600.0 / cam.zoom.x * _dt
	if not _typing():
		if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT): cam.position.x -= sp
		if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT): cam.position.x += sp
		if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP): cam.position.y -= sp
		if Input.is_key_pressed(KEY_S) and not Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_DOWN): cam.position.y += sp
	var far = cam.zoom.x < FAR_ZOOM
	if mini_dirty and mini_tex != null:
		mini_dirty = false
		(mini_tex as ImageTexture).update(mini_img)
		if minimap: minimap.queue_redraw()
	if world_sprite:
		world_sprite.visible = far
	for i in tiles.size():
		tiles[i].visible = not far and layer_shown[i]
	if not far:
		_stream()
	# drawn again only when something to see changed (the walls of a whole screen each frame made it slow)
	var look = [cam.position, cam.zoom, mouse_cell, stroke.size(), undo.size(), redo.size(), tool, selected.size(), show_walls, show_over, show_grid, show_changes, show_objects, layer, paint_size, door_rect.size(), selected.get("drag_to", Vector2.ZERO)]
	_redraw_t += _dt
	if look != _last_look or dragging or _redraw_t > 0.25:      # (and a few times a second anyway, for anything else that changed)
		_last_look = look
		_redraw_t = 0.0
		overlay.queue_redraw()
		if minimap:
			minimap.queue_redraw()
	if status and _inside(mouse_cell.x, mouse_cell.y):
		var v = cell_at(mouse_cell.x, mouse_cell.y)
		var nm = ""
		var wp = Vector2(mouse_cell) * 8.0
		for pt in area["land"].get("parts", []):
			if pt[0].has_point(wp):
				nm = str(pt[1]); break
		status.text = "%s   tile %d,%d (px %d,%d)   layers %s   %s   zoom %.2f   %s%s" % [nm, mouse_cell.x, mouse_cell.y, mouse_cell.x * 8, mouse_cell.y * 8,
			str(v.slice(0, 5)), "WALK" if int(v[5]) & 1 else "WALL", cam.zoom.x, "LAYER %d" % layer, "   (not saved)" if dirty else ""]

func _typing() -> bool:
	var f = get_viewport().gui_get_focus_owner()
	return f is LineEdit or f is TextEdit or f is SpinBox

## the rocks as the game draws them: above the ground, below the trees' tops and roofs
func _draw_rocks() -> void:
	if area.is_empty() or tab != "MAP" or cam.zoom.x < FAR_ZOOM:
		return
	if rock_b.atlas == null and not rock_b._ready_data():
		return
	var vs = get_viewport_rect().size / cam.zoom
	var rview = Rect2(cam.position - vs / 2 - Vector2(64, 64), vs + Vector2(128, 128))
	for rr in _rocks():
		var pr: Rect2 = rr["pic"]
		if rview.intersects(pr):
			var rk: Dictionary = rr["rk"]
			rock_layer.draw_texture_rect_region(rock_b.atlas, pr, Rect2(float(rk["at"][0]), float(rk["at"][1]), float(rk["w"]), float(rk["h"])))
func _draw_overlay() -> void:
	rock_layer.queue_redraw()
	if area.is_empty() or tab != "MAP":
		return
	_draw_move_and_guide()
	if tool == "SELECT" or tool == "MOVE":
		_draw_places()
	if cam.zoom.x < FAR_ZOOM:
		# the whole world: the places' names; a click goes in there
		var font0 = ThemeDB.fallback_font
		var fs0 = int(10.0 / cam.zoom.x)
		var done = {}
		for pt in area["land"].get("parts", []):
			var nm = str(pt[1])
			if nm == "" or done.has(nm) or tool == "SELECT" or tool == "MOVE":      # (SELECT / MOVE draw every place's own, with its box)
				continue
			done[nm] = true
			var c: Vector2 = pt[0].get_center()
			_ov_text(font0, c, nm, HORIZONTAL_ALIGNMENT_CENTER, -1, fs0, Color(1, 1, 0.8))
		var ni0 = _node_index()
		if ni0 >= 0:
			for ex in Game.planet.nodes[ni0]["exits"]:
				var r: Array = ex["rect"]
				overlay.draw_circle(Vector2(float(r[0]), float(r[1])), 2.0 / cam.zoom.x, Color(1, 0.9, 0.2))
		if mouse_cell.x >= 0 and tool in PAINT_FAR:      # the brush, zoomed right out too
			var bs = {"BIOME": biome_size, "SMART": edge_size if edge_i >= 0 else smart_size * 2 - 1}.get(tool, paint_size)
			overlay.draw_circle(Vector2(mouse_cell) * 8.0 + Vector2(4, 4), maxf(bs * 4.0, 3.0 / cam.zoom.x), Color(1, 1, 1, 0.9), false, 2.0 / cam.zoom.x)
		return
	var vs = get_viewport_rect().size / cam.zoom
	var x0 = maxi(0, int((cam.position.x - vs.x / 2) / 8)); var y0 = maxi(0, int((cam.position.y - vs.y / 2) / 8))
	var x1 = mini(int(area["tw"]) - 1, int((cam.position.x + vs.x / 2) / 8) + 1); var y1 = mini(int(area["th"]) - 1, int((cam.position.y + vs.y / 2) / 8) + 1)
	var tw: int = area["tw"]
	var walk: PackedByteArray = area["walk"]
	if show_over and (x1 - x0) * (y1 - y0) < 40000 and area.has("land"):
		# where you can walk and something is drawn over the hero (layers 3-4): leaves you walk under are fine,
		# grass, ledges or rocks there want the UNDER HERO brush
		var lc: Array = area["land"]["cells"]
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				var i = y * tw + x
				var cv = stroke[i][1] if stroke.has(i) else null
				var t3 = int(cv[3]) if cv != null else int(lc[3][i])
				var t4 = int(cv[4]) if cv != null else int(lc[4][i])
				var hw = int(stroke[i][1][5]) if stroke.has(i) else int(area["walk"][i])
				if (t3 != 0 or t4 != 0) and not _hg(hw):      # (high ground hides whoever walks behind it by itself: one violet, OVER or not)
					overlay.draw_rect(Rect2(x * 8, y * 8, 8, 8), Color(0.15, 0.4, 1.0, 0.45))
	if show_walls and (x1 - x0) * (y1 - y0) < 40000:
		for y in range(y0, y1 + 1):
			var run_x = -1
			for x in range(x0, x1 + 1):
				var i = y * tw + x
				var wv = int(stroke[i][1][5]) if stroke.has(i) else int(walk[i])
				if _hg(wv) and show_over:
					# a platform top you made (HIGH GROUND): bold violet, only with OVER HERO (otherwise not shown at all -
					# in red it looked like a wall you had painted)
					overlay.draw_rect(Rect2(x * 8, y * 8, 8, 8), Color(0.55, 0.15, 1.0, 0.8))
				if not (_walk_bits(wv) & 1):
					if run_x < 0:
						run_x = x
				elif run_x >= 0:
					overlay.draw_rect(Rect2(run_x * 8, y * 8, (x - run_x) * 8, 8), Color(1, 0.1, 0.1, 0.28))
					run_x = -1
			if run_x >= 0:      # a row's walls in one strip, not a square each
				overlay.draw_rect(Rect2(run_x * 8, y * 8, (x1 + 1 - run_x) * 8, 8), Color(1, 0.1, 0.1, 0.28))
	if show_grid and cam.zoom.x >= 1.0:
		for x in range(x0, x1 + 2):
			overlay.draw_line(Vector2(x * 8, y0 * 8), Vector2(x * 8, (y1 + 1) * 8), Color(1, 1, 1, 0.12), 1.0 / cam.zoom.x)
		for y in range(y0, y1 + 2):
			overlay.draw_line(Vector2(x0 * 8, y * 8), Vector2((x1 + 1) * 8, y * 8), Color(1, 1, 1, 0.12), 1.0 / cam.zoom.x)
	if show_changes:
		# what your edits (yellow) and each mod switched on (blue, green...) change here
		if _changes.is_empty():
			_changes = Mods.changed_cells(key)
		var cols = [Color(0.3, 0.8, 1), Color(0.4, 1, 0.5), Color(1, 0.5, 1), Color(1, 0.6, 0.3)]
		for li in _changes.size():
			var col = Color(1, 0.95, 0.2) if _changes[li][0] == "yours" else cols[li % cols.size()]
			for c in _changes[li][1]:
				var xy = str(c).split(",")
				var x = int(xy[0]); var y = int(xy[1])
				if x < x0 or x > x1 or y < y0 or y > y1:
					continue
				overlay.draw_rect(Rect2(x * 8 + 0.5, y * 8 + 0.5, 7, 7), col, false, 1.0 / cam.zoom.x)
	var font = ThemeDB.fallback_font
	var fs = int(clampf(8.0 / cam.zoom.x, 6, 24))
	# the breakables (rocks): their pictures are on rock_layer; here, with the objects shown, their hits ("2x") and yours marked +
	if rock_b.atlas != null or rock_b._ready_data():
		var rview = Rect2(cam.position - vs / 2 - Vector2(64, 64), vs + Vector2(128, 128))
		for rr in _rocks():
			var pr: Rect2 = rr["pic"]
			if not rview.intersects(pr):
				continue
			var rk: Dictionary = rr["rk"]
			if selected.get("kind", "") == "rock" and str(selected["obj"]["id"]) == str(rr["id"]):
				overlay.draw_rect(rr["rect"], Color(1, 1, 0.3), false, 2.0 / cam.zoom.x)
			elif show_objects:
				_ov_text(font, Vector2(pr.end.x - 2, pr.position.y + fs), "%dx%s" % [int(rk.get("hits", 1)), "+" if bool(rr["own"]) else ""], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.85, 0.85, 0.85))
	if show_objects:
		var ob = _objects()
		var view = Rect2(cam.position - vs / 2 - Vector2(40, 40), vs + Vector2(80, 80))
		for f in ob["foes"]:
			var p = Vector2(float(f["x"]), float(f["y"]))
			if not view.has_point(p): continue
			overlay.draw_circle(p, 4, Color(1, 0.3, 0.2, 0.85))
			_ov_text(font, p + Vector2(5, -4), "%d" % int(f["type"]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 0.8, 0.7))
		for pp in ob["people"]:
			var p = Vector2(float(pp["x"]), float(pp["y"]))
			if not view.has_point(p): continue
			overlay.draw_circle(p, 4, Color(0.3, 0.6, 1, 0.9))
			_ov_text(font, p + Vector2(5, -4), str(pp.get("name", "")), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.7, 0.85, 1))
		for it in ob["items"]:
			var p = Vector2(float(it["x"]), float(it["y"]))
			overlay.draw_rect(Rect2(p - Vector2(3, 3), Vector2(6, 6)), Color(1, 0.85, 0.2))
			_ov_text(font, p + Vector2(5, -4), str(it.get("id", "")), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 0.9, 0.5))
		for ex in ob["doors"]:
			var r: Array = ex["rect"]
			var rr = Rect2(float(r[0]), float(r[1]), float(r[2]) - float(r[0]), float(r[3]) - float(r[1]))
			var chosen = selected.get("obj") == ex
			if chosen and int(ex["to"]) == _node_index():
				# the chosen door: its line and where it leads stay drawn however far you pan (J jumps there)
				var arr0 = Vector2(float(ex["arrive"][0]), float(ex["arrive"][1]))
				overlay.draw_line(rr.get_center(), arr0, Color(1, 0.9, 0.2, 0.9), 2.0 / cam.zoom.x)
				overlay.draw_circle(arr0, 6.0 / cam.zoom.x, Color(0.3, 1, 0.4, 0.9))
				_ov_text(font, arr0 + Vector2(8, -6) / cam.zoom.x, "ARRIVES HERE", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.6, 1, 0.7))
			if not view.intersects(rr): continue
			overlay.draw_rect(rr, Color(1, 0.9, 0.2, 0.35))
			overlay.draw_rect(rr, Color(1, 0.9, 0.2), false, 1.0 / cam.zoom.x)
			if int(ex["to"]) == _node_index():
				var arr = Vector2(float(ex["arrive"][0]), float(ex["arrive"][1]))
				if view.has_point(arr) or (selected.get("obj") == ex):
					overlay.draw_line(rr.get_center(), arr, Color(1, 0.9, 0.2, 0.6), 1.0 / cam.zoom.x)
			else:
				_ov_text(font, rr.position + Vector2(0, -2), "TO " + str(Game.planet.nodes[int(ex["to"])]["name"]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 0.95, 0.6))
	if not selected.is_empty():
		var o: Dictionary = selected["obj"]
		if o.get("rect") is Rect2:      # (a rock, a place)
			overlay.draw_rect((o["rect"] as Rect2).grow(2.0), Color(0.3, 1, 0.4), false, 2.0 / cam.zoom.x)
		elif o.has("rect"):
			var r: Array = o["rect"]
			overlay.draw_rect(Rect2(float(r[0]) - 2, float(r[1]) - 2, float(r[2]) - float(r[0]) + 4, float(r[3]) - float(r[1]) + 4), Color(0.3, 1, 0.4), false, 2.0 / cam.zoom.x)
		else:
			overlay.draw_arc(Vector2(float(o["x"]), float(o["y"])), 8, 0, TAU, 20, Color(0.3, 1, 0.4), 2.0 / cam.zoom.x)
		if selected.has("drag_to"):
			overlay.draw_circle(selected["drag_to"], 4, Color(0.3, 1, 0.4, 0.6))
	if door_rect.size() == 4:
		overlay.draw_rect(Rect2(float(door_rect[0]), float(door_rect[1]), float(door_rect[2]) - float(door_rect[0]), float(door_rect[3]) - float(door_rect[1])), Color(0.3, 1, 0.4, 0.5))
	if show_objects:
		var mp = Mods.merged(key, false)
		for z in mp["zones"]:
			var r: Array = z["rect"]
			var rr = Rect2(float(r[0]), float(r[1]), float(r[2]) - float(r[0]), float(r[3]) - float(r[1]))
			overlay.draw_rect(rr, Color(1, 0.3, 0.2, 0.12))
			overlay.draw_rect(rr, Color(1, 0.35, 0.25), false, 1.0 / cam.zoom.x)
			_ov_text(ThemeDB.fallback_font, rr.position + Vector2(2, 8 / cam.zoom.x + 2), "FOES %s x%d" % [str(z.get("kinds", [])), int(z.get("count", 0))], HORIZONTAL_ALIGNMENT_LEFT, -1, int(clampf(8.0 / cam.zoom.x, 6, 24)), Color(1, 0.7, 0.6))
		for t in mp["triggers"]:
			var r: Array = t["rect"]
			var rr = Rect2(float(r[0]), float(r[1]), float(r[2]) - float(r[0]), float(r[3]) - float(r[1]))
			overlay.draw_rect(rr, Color(0.8, 0.4, 1, 0.15))
			overlay.draw_rect(rr, Color(0.85, 0.5, 1), false, 1.0 / cam.zoom.x)
			_ov_text(ThemeDB.fallback_font, rr.position + Vector2(2, 8 / cam.zoom.x + 2), "EVENT " + str(t.get("event", "")), HORIZONTAL_ALIGNMENT_LEFT, -1, int(clampf(8.0 / cam.zoom.x, 6, 24)), Color(0.9, 0.75, 1))
		for md in mp["moods"]:
			var r: Array = md["rect"]
			var rr = Rect2(float(r[0]), float(r[1]), float(r[2]) - float(r[0]), float(r[3]) - float(r[1]))
			overlay.draw_rect(rr, Color(0.1, 0.1, 0.3, 0.25 * float(md.get("dark", 0.3)) + 0.08))
			overlay.draw_rect(rr, Color(0.5, 0.6, 1), false, 1.0 / cam.zoom.x)
			var mt = "MOOD"
			if float(md.get("dark", 0)) > 0: mt += " DARK"
			if str(md.get("weather", "")) != "": mt += " " + str(md["weather"]).to_upper()
			if str(md.get("music", "")) != "": mt += " MUSIC " + str(md["music"]).to_upper()
			_ov_text(ThemeDB.fallback_font, rr.position + Vector2(2, 8 / cam.zoom.x + 2), mt, HORIZONTAL_ALIGNMENT_LEFT, -1, int(clampf(8.0 / cam.zoom.x, 6, 24)), Color(0.7, 0.8, 1))
	if tool == "THINGS" and stamp_i >= 0 and stamp_i < stamps.size() and mouse_cell.x >= 0:
		overlay.draw_rect(Rect2(Vector2(mouse_cell) * 8.0, Vector2(int(stamps[stamp_i]["w"]), int(stamps[stamp_i]["h"])) * 8.0), Color(0.4, 1, 0.6), false, 1.0 / cam.zoom.x)
	if dragging and tool == "COPY" and copy_lasso and lasso_pts.size() > 1:      # LASSO: the line being drawn
		var lp = PackedVector2Array()
		for q in lasso_pts:
			lp.append(Vector2(q) * 8.0 + Vector2(4, 4))
		lp.append(lp[0])
		overlay.draw_polyline(lp, Color(0.4, 0.9, 1), 2.0 / cam.zoom.x)
	elif dragging and ((tool == "BIOME" and biome_grab) or tool in ["COPY", "DOOR", "ZONE", "EVENT", "MOOD"]) and drag_from.x >= 0:
		var a = Vector2(mini(drag_from.x, mouse_cell.x), mini(drag_from.y, mouse_cell.y)) * 8.0
		var b = Vector2(maxi(drag_from.x, mouse_cell.x) + 1, maxi(drag_from.y, mouse_cell.y) + 1) * 8.0
		overlay.draw_rect(Rect2(a, b - a), Color(0.4, 0.9, 1, 0.25))
		overlay.draw_rect(Rect2(a, b - a), Color(0.4, 0.9, 1), false, 1.0 / cam.zoom.x)
	if tool == "PASTE" and clipboard.has("mask") and mouse_cell.x >= 0:      # a LASSO copy: its shape
		var cw: int = clipboard["w"]
		var cm: Array = clipboard["mask"]
		for j in cm.size():
			if int(cm[j]) != 0:
				overlay.draw_rect(Rect2(Vector2(mouse_cell + Vector2i(j % cw, j / cw)) * 8.0, Vector2(8, 8)), Color(0.4, 0.9, 1, 0.3))
	elif tool == "PASTE" and not clipboard.is_empty() and mouse_cell.x >= 0:
		overlay.draw_rect(Rect2(Vector2(mouse_cell) * 8.0, Vector2(int(clipboard["w"]), int(clipboard["h"])) * 8.0), Color(0.4, 0.9, 1), false, 1.0 / cam.zoom.x)
	if mouse_cell.x >= 0 and tool == "SMART" and edge_i >= 0:
		overlay.draw_circle(Vector2(mouse_cell) * 8.0 + Vector2(4, 4), edge_size * 4.0, Color(0.6, 0.9, 1, 0.9), false, 1.0 / cam.zoom.x)
	if mouse_cell.x >= 0 and tool == "BIOME" and not biome_grab:
		overlay.draw_circle(Vector2(mouse_cell) * 8.0 + Vector2(4, 4), biome_size * 4.0, Color(1, 1, 1, 0.8), false, 1.0 / cam.zoom.x)
	if mouse_cell.x >= 0 and tool in ["TILE", "STAMP", "ERASE", "WALL", "GROUND", "UNDER", "OVER", "PICK"]:
		var bs = 1 if tool == "PICK" else paint_size
		overlay.draw_rect(Rect2(Vector2(mouse_cell - Vector2i((bs - 1) / 2, (bs - 1) / 2)) * 8.0, Vector2(bs, bs) * 8.0), Color(1, 1, 1, 0.8), false, 1.0 / cam.zoom.x)

# ------------------------------------------------------------------ the panels
func _build_ui() -> void:
	var cl = CanvasLayer.new()
	cl.layer = 20
	add_child(cl)
	ui = Control.new()
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cl.add_child(ui)
	var top = VBoxContainer.new()
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	ui.add_child(top)
	var bg = StyleBoxFlat.new()
	bg.bg_color = Color(0.06, 0.07, 0.12, 0.92)
	var tabs = HBoxContainer.new()
	var tp = PanelContainer.new(); tp.add_theme_stylebox_override("panel", bg); tp.add_child(tabs); top.add_child(tp)
	for t in TABS:
		var b = Button.new(); b.text = t; b.toggle_mode = true; b.button_pressed = t == "MAP"
		b.add_theme_font_size_override("font_size", 9)
		b.pressed.connect(_show_tab.bind(t))
		tabs.add_child(b)
	var sp = Control.new(); sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL; tabs.add_child(sp)
	var lg = TextureRect.new(); lg.texture = preload("res://art/puni_logo.png"); lg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	lg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED; lg.custom_minimum_size = Vector2(16, 16); lg.tooltip_text = "LoG2 Online by Puni Puni"; tabs.add_child(lg)
	var ytb = Button.new(); ytb.text = "YOUTUBE"; ytb.add_theme_font_size_override("font_size", 9); ytb.add_theme_color_override("font_color", Color(1, 0.45, 0.45))
	ytb.tooltip_text = "Puni Puni on YouTube: @PuniPuni2026"; ytb.pressed.connect(func(): OS.shell_open("https://www.youtube.com/@PuniPuni2026")); tabs.add_child(ytb)
	var lg2 = TextureRect.new(); lg2.texture = preload("res://art/divinakra_logo.png"); lg2.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	lg2.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED; lg2.custom_minimum_size = Vector2(16, 16); lg2.tooltip_text = "Divinakra Creations"; tabs.add_child(lg2)
	var ytb2 = Button.new(); ytb2.text = "YOUTUBE"; ytb2.add_theme_font_size_override("font_size", 9); ytb2.add_theme_color_override("font_color", Color(1, 0.45, 0.45))
	ytb2.tooltip_text = "Divinakra Creations on YouTube: @DivinakraCreations"; ytb2.pressed.connect(func(): OS.shell_open("https://www.youtube.com/@DivinakraCreations")); tabs.add_child(ytb2)
	var tg = Button.new(); tg.text = "TOGETHER"; tg.tooltip_text = "Edit the same world with friends over LAN or Hamachi"
	tg.pressed.connect(_together_dialog); tabs.add_child(tg)
	var hb = MenuButton.new(); hb.text = "HELP"; hb.flat = false; tabs.add_child(hb)
	var hm = hb.get_popup()
	hm.add_item("HOW THE MAP WORKS", 0); hm.add_item("FIRST MAP - STEP BY STEP", 1); hm.add_item("A TIP", 2)
	hm.id_pressed.connect(_help_menu)
	var xb = Button.new(); xb.text = "BACK"; xb.pressed.connect(_close); tabs.add_child(xb)
	# the map editor's bar
	var bar = HBoxContainer.new()
	var bp = PanelContainer.new(); bp.add_theme_stylebox_override("panel", bg); bp.add_child(bar); top.add_child(bp)
	bp.name = "mapbar"
	map_pick = OptionButton.new()
	map_pick.add_theme_font_size_override("font_size", 10)
	map_pick.item_selected.connect(func(i): _go_map(map_pick.get_item_metadata(i)))
	bar.add_child(map_pick)
	_fill_maps()
	var nb = Button.new(); nb.text = "NEW MAP"; nb.pressed.connect(_new_map_dialog); bar.add_child(nb)
	var sb = Button.new(); sb.text = "SAVE"; sb.pressed.connect(save); bar.add_child(sb)
	var ub = Button.new(); ub.text = "UNDO"; ub.pressed.connect(do_undo); bar.add_child(ub)
	var rb = Button.new(); rb.text = "REDO"; rb.pressed.connect(do_redo); bar.add_child(rb)
	var pb = Button.new(); pb.text = "PLAY HERE"; pb.tooltip_text = "Play right here (saves first). In the game F10 brings you back."
	pb.pressed.connect(_play_dialog); bar.add_child(pb)
	var og = Button.new(); og.text = "OTHER GAMES"; og.tooltip_text = "Read Buu's Fury and The Legacy of Goku from your own cartridges: their maps and characters to use here"
	og.pressed.connect(_other_games); bar.add_child(og)
	mine_button = Button.new(); mine_button.text = "MAKE IT MY MAP"; mine_button.visible = false
	mine_button.pressed.connect(_make_mine); bar.add_child(mine_button)
	layer_pick = OptionButton.new()
	for i in 5:
		layer_pick.add_item(["LAYER 0 GROUND", "LAYER 1", "LAYER 2", "LAYER 3 OVER", "LAYER 4 OVER"][i], i)
	layer_pick.item_selected.connect(func(i): layer = i; _refresh_side())
	bar.add_child(layer_pick)
	for t in [["WALLS", "show_walls"], ["OVER HERO", "show_over"], ["GRID", "show_grid"], ["OBJECTS", "show_objects"], ["CHANGES", "show_changes"]]:
		var cb = CheckBox.new(); cb.text = t[0]; cb.button_pressed = get(t[1])
		cb.toggled.connect(func(on): set(t[1], on))
		bar.add_child(cb)
	var vm = MenuButton.new(); vm.text = "VIEW ▾"; vm.add_theme_font_size_override("font_size", 10); bar.add_child(vm)
	var pm = vm.get_popup()
	pm.add_check_item("LITTLE MAP", 100); pm.set_item_checked(0, true)
	for i in 5:
		pm.add_check_item("SHOW LAYER %d" % i, i); pm.set_item_checked(i + 1, true)
	pm.add_separator()
	pm.add_item("THE WHOLE WORLD (zoom out)", 200)
	pm.id_pressed.connect(func(id):
		if id == 200:
			_world_view()
			return
		var ix = pm.get_item_index(id)
		var on = not pm.is_item_checked(ix)
		pm.set_item_checked(ix, on)
		if id == 100:
			minimap.visible = on
		else:
			layer_shown[id] = on
			if id < tiles.size():
				tiles[id].visible = on)
	var tools = HBoxContainer.new()
	var tlp = PanelContainer.new(); tlp.add_theme_stylebox_override("panel", bg); tlp.add_child(tools); top.add_child(tlp)
	tlp.name = "toolbar"
	for t in TOOLS:
		var b = Button.new(); b.text = t; b.toggle_mode = true
		b.add_theme_font_size_override("font_size", 10)
		b.pressed.connect(_set_tool.bind(t))
		b.tooltip_text = str(TOOL_HELP.get(t, ""))
		tools.add_child(b)
		tool_buttons[t] = b
	for c in top.get_children():
		for b in c.get_children():
			for x in b.get_children():
				if x is Control:
					x.add_theme_font_size_override("font_size", 10)
	# the side panel
	var sidep = PanelContainer.new()
	sidep.name = "side"
	sidep.add_theme_stylebox_override("panel", bg)
	sidep.anchor_left = 1.0; sidep.anchor_right = 1.0; sidep.anchor_top = 0.0; sidep.anchor_bottom = 1.0
	sidep.offset_left = -250; sidep.offset_top = 96; sidep.offset_bottom = -22
	ui.add_child(sidep)
	var ss = ScrollContainer.new(); ss.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sidep.add_child(ss)
	side = VBoxContainer.new(); side.custom_minimum_size = Vector2(236, 0)
	ss.add_child(side)
	# the little map (shows where you are; clicks do nothing)
	minimap = Control.new()
	minimap.anchor_top = 1.0; minimap.anchor_bottom = 1.0
	minimap.offset_left = 4; minimap.offset_top = -200; minimap.offset_right = 184; minimap.offset_bottom = -26
	minimap.mouse_filter = Control.MOUSE_FILTER_STOP
	minimap.draw.connect(_draw_minimap)
	minimap.gui_input.connect(_minimap_input)
	ui.add_child(minimap)
	# the status line and help
	var stp = PanelContainer.new(); stp.add_theme_stylebox_override("panel", bg)
	stp.anchor_top = 1.0; stp.anchor_bottom = 1.0; stp.anchor_right = 1.0; stp.offset_top = -22
	ui.add_child(stp)
	var sv = VBoxContainer.new(); stp.add_child(sv)
	status = Label.new(); status.add_theme_font_size_override("font_size", 10); sv.add_child(status)
	help = Label.new()
	help.add_theme_font_size_override("font_size", 11)
	help.add_theme_color_override("font_color", Color(1, 0.9, 0.5))
	help.position = Vector2(8, 100)
	help.size = Vector2(560, 40)
	help.autowrap_mode = TextServer.AUTOWRAP_WORD
	ui.add_child(help)
	# the other editors (heroes, enemies, moves, forms, blasts, missions)
	editors = preload("res://scripts/dev_editors.gd").new()
	editors.set_anchors_preset(Control.PRESET_FULL_RECT)
	editors.offset_top = 30
	editors.visible = false
	editors.tools = self
	ui.add_child(editors)
	for t in PANELS:
		if not ResourceLoader.exists(PANELS[t]):
			continue
		var pnl = load(PANELS[t]).new()
		pnl.set_anchors_preset(Control.PRESET_FULL_RECT)
		pnl.offset_top = 30
		pnl.visible = false
		if "tools" in pnl:
			pnl.tools = self
		if "tools_ref" in pnl:
			pnl.tools_ref = self
		ui.add_child(pnl)
		panels[t] = pnl
		if pnl.has_signal("changed"):
			pnl.changed.connect(_packs_changed)
	colors_ed = panels.get("COLORS")
	_set_tool("PAN")

func _mini_rect() -> Rect2:
	if mini_tex == null:
		return Rect2()
	var box = minimap.size
	var ts = mini_tex.get_size()
	var k = minf(box.x / ts.x, box.y / ts.y)
	return Rect2(Vector2(0, box.y - ts.y * k), ts * k)

func _draw_minimap() -> void:
	if mini_tex == null or tab != "MAP":
		return
	var r = _mini_rect()
	minimap.draw_rect(r.grow(2), Color(0, 0, 0, 0.7))
	minimap.draw_texture_rect(mini_tex, r, false)
	var vs = get_viewport_rect().size / cam.zoom
	var sc = r.size.x / (float(area["w"]))
	var vr = Rect2(r.position + (cam.position - vs / 2) * sc, vs * sc)
	minimap.draw_rect(vr, Color(1, 1, 0.3), false, 1.0)

## the little map only shows where you are: a click on it does nothing (it moved the view there, and a click while
## painting drew a streak of wall or ground across the whole map) - and it never reaches the map under it
func _minimap_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton or ev is InputEventMouseMotion:
		minimap.accept_event()

func _refresh_minimap() -> void:
	if area.is_empty() or minimap == null:
		return
	var img = MT.mini_image(area)
	mini_img = img
	mini_tex = ImageTexture.create_from_image(img) if img != null else null
	minimap.queue_redraw()
	if world_sprite == null:
		world_sprite = Sprite2D.new(); world_sprite.centered = false; world_sprite.z_index = -60
		world_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		add_child(world_sprite)
	world_sprite.texture = mini_tex
	if mini_tex:
		world_sprite.scale = Vector2.ONE * (float(area["w"]) / mini_tex.get_size().x)

## the minimap's cells in these boxes (cells) drawn again as they are now - not the whole picture (EARTH's took
## seconds: every one of your changes drawn in again)
func _mini_paint(boxes: Array) -> void:
	if mini_img == null or mini_tex == null or key != "land/0/0" or mini_img.get_size() != Vector2i(int(area["tw"]), int(area["th"])):
		_refresh_minimap()
		return
	for b in boxes:
		var bx: Rect2i = (b as Rect2i).intersection(Rect2i(Vector2i.ZERO, mini_img.get_size()))
		for y in range(bx.position.y, bx.end.y):
			for x in range(bx.position.x, bx.end.x):
				var cv = cell_at(x, y)
				mini_img.set_pixel(x, y, MT.mini_color(cv, int(cv[5])))
	(mini_tex as ImageTexture).update(mini_img)
	minimap.queue_redraw()

## the whole world at a glance: zoomed right out (EARTH is big: the planet as one picture)
func _world_view() -> void:
	var vs = get_viewport_rect().size
	var z = minf(vs.x / float(area["w"]), vs.y / float(area["h"]))
	cam.zoom = Vector2.ONE * clampf(z, 0.02, 6)
	cam.position = Vector2(float(area["w"]), float(area["h"])) / 2.0
	_say("The whole map. Wheel: zoom in where you want to work.")

func _fill_maps() -> void:
	map_pick.clear()
	map_pick.add_item("EARTH (THE WHOLE PLANET)")
	map_pick.set_item_metadata(0, "land/0/0")
	for nm in Mods.custom_maps():
		map_pick.add_item("MY MAP: " + nm.to_upper())
		map_pick.set_item_metadata(map_pick.item_count - 1, "custom/" + nm)
	# the other games' maps (OTHER GAMES reads them from your cartridges)
	for m in Assets.library_maps():
		map_pick.add_item(str(m["name"]) + "  (%dx%d)" % [int(m["tw"]), int(m["th"])])
		map_pick.set_item_metadata(map_pick.item_count - 1, str(m["key"]))
	for i in map_pick.item_count:
		if str(map_pick.get_item_metadata(i)) == key:
			map_pick.select(i)

func _go_map(k: String) -> void:
	if dirty:
		save()
	var keep_door = door_rect.duplicate()
	var keep_to = door_to
	load_map(k)
	door_rect = keep_door
	door_to = keep_to
	if door_rect.size() == 4:
		_say("Now click where the door takes you on this map.")

## the colours changed (COLORS - SAVE): the map's tiles and the previews again
func colors_changed() -> void:
	for tl in tiles:
		tl.tile_set = Assets.tileset()
	chunks.clear()
	for tl in tiles:
		tl.clear()
	_stream(true)

## mods switched on or off (SHARE): the world and this map again
func _packs_changed() -> void:
	Game.planet.build_land(0, 1)
	var k = key
	var at = cam.position; var z = cam.zoom
	load_map(k)
	cam.position = at; cam.zoom = z         # (stay where you were looking)
	_fill_maps()

## PLAY HERE: the game at this spot (the map under the mouse, or the middle of the screen)
var play_level = 0
var play_god = true
func _play_dialog() -> void:
	if area.has("library"):
		_say("This is another game's map - MAKE IT MY MAP first to play on it.")
		return
	var d = AcceptDialog.new()
	d.title = "PLAY HERE"
	var v = VBoxContainer.new(); d.add_child(v)
	var hp = OptionButton.new()
	for i in Assets.CHARACTERS.size():
		hp.add_item(Assets.CHARACTERS[i], i)
	hp.select(clampi(int(Game.cfg.get("character", 4)), 0, Assets.CHARACTERS.size() - 1))
	v.add_child(hp)
	var lv = SpinBox.new(); lv.min_value = 0; lv.max_value = 99; lv.value = play_level; lv.prefix = "level (0: as saved)"; v.add_child(lv)
	var gd = CheckBox.new(); gd.text = "CAN'T BE BEATEN"; gd.button_pressed = play_god; v.add_child(gd)
	var l = Label.new(); l.text = "In the game: F10 comes back here."; v.add_child(l)
	d.confirmed.connect(func():
		play_level = int(lv.value); play_god = gd.button_pressed
		Game.cfg["character"] = hp.selected
		play_here(cam.position, {"level": play_level, "god": play_god})
		d.queue_free())
	d.canceled.connect(func(): d.queue_free())
	ui.add_child(d)
	d.popup_centered()

func play_here(p: Vector2, opts: Dictionary = {}) -> void:
	if dirty:
		save()
	Game.cfg["playtest"] = opts
	play_requested.emit({"key": key, "x": p.x, "y": p.y, "cx": cam.position.x, "cy": cam.position.y, "zoom": cam.zoom.x})

## read the other games (Buu's Fury, The Legacy of Goku) from the cartridges found
func _other_games() -> void:
	_say("Reading the other games... (a few seconds)")
	await get_tree().process_frame
	await get_tree().process_frame
	var r = Assets.import_library(false)
	for tl in tiles:
		tl.tile_set = Assets.tileset()
	_fill_maps()
	_stream(true)
	_refresh_side()
	_say(r.replace("\n", "   ") + "   - their maps are in the map list, their characters are sprite sets 1000+ (Buu's Fury) and 2000+ (Legacy of Goku).")

## a map of another game, copied whole as a map of your own (then paint it, put foes and doors in it)
func _make_mine() -> void:
	if not area.has("library"):
		return
	var n = "from_" + key.replace("lib/", "").replace("/", "_")
	var k = 2
	while Mods.custom_maps().has(n):
		n = "from_" + key.replace("lib/", "").replace("/", "_") + "_%d" % k
		k += 1
	if Mods.custom_from_lib(n, key):
		Game.planet.build_land(0, 1)
		_fill_maps()
		_go_map("custom/" + n)
		_fill_maps()
		_say("Map %s made from it - yours to change. Make a DOOR to it from EARTH to walk in." % n)

func _set_tool(t: String) -> void:
	tool = t
	for k in tool_buttons:
		tool_buttons[k].button_pressed = k == t or (k == "PICK" and t == "STAMP")      # (stamping is PICK's)
	if t != "DOOR" and t != "SELECT":
		door_rect = []
	if t != "MOVE":
		move_box = Rect2i()
		move_mask = {}
		lasso_pts = []
	if t == "GUIDE" and guide.is_empty():
		_guide_load()
	help.text = t + ": " + TOOL_HELP.get(t, "")
	_refresh_side()

func _say(s: String) -> void:
	if help:
		help.text = s
	print("[dev] ", s)

func _show_help() -> void:
	_say("MAP: pick a tool on the second bar, then click / drag on the map. Right mouse drag or WASD: move. Wheel: zoom. 0-4: layer. Ctrl+Z undo, Ctrl+S save, Delete: delete the chosen thing. Everything is kept in the mods and content folders next to the game.")

func _show_tab(t: String) -> void:
	tab = t
	for c in ui.get_children():
		if c is PanelContainer and c.get_child_count() > 0:
			pass
	var top: VBoxContainer = ui.get_child(0)
	for b in top.get_child(0).get_child(0).get_children():
		if b is Button and b.toggle_mode:
			b.button_pressed = b.text == t
	var on_map = t == "MAP"
	top.get_node("mapbar").visible = on_map
	top.get_node("toolbar").visible = on_map
	ui.get_node("side").visible = on_map
	help.visible = on_map
	for tl in tiles:
		tl.visible = on_map
	overlay.visible = on_map
	editors.visible = not on_map and not panels.has(t)
	for k in panels:
		panels[k].visible = k == t
	if panels.has(t):
		if panels[t].has_method("show_editor"):
			panels[t].show_editor()
		elif panels[t].has_method("refresh"):
			panels[t].refresh()
	elif not on_map:
		editors.show_editor(t)

func start_tuning() -> void:
	if dirty:
		save()
	tune_requested.emit()

func _close() -> void:
	if dirty:
		save()
	Content.reload()
	closed.emit()

func _refresh_side() -> void:
	if side == null:
		return
	for c in side.get_children():
		c.queue_free()
	preview = null
	var title = Label.new(); title.text = tool; title.add_theme_font_size_override("font_size", 13); side.add_child(title)
	match tool:
		"PICK", "STAMP":
			var ps = CheckBox.new(); ps.text = "STAMP"; ps.button_pressed = pick_stamp; side.add_child(ps)
			ps.toggled.connect(func(on):
				pick_stamp = on
				if on and ((last_brush == "STAMP" and int(brush_cell[0]) != 0) or last_brush == "TILE"):
					_set_tool("STAMP")
				elif not on and tool == "STAMP":
					_set_tool("PICK"))
			_lab("STAMP on: click a cell to pick it, then click or drag to stamp it (all its layers and its wall). Or choose a tile below: it is stamped onto the LAYER chosen under the game. Click the PICK button to pick another.")
			if tool == "STAMP":
				_lab("Stamping: %s" % ("tile %d onto LAYER %d" % [brush_tile & 0xFFFF, layer] if last_brush == "TILE" else "the picked cell (all layers)"))
				_spin(side, "brush size", 1, 32, paint_size, func(v): paint_size = int(v); overlay.queue_redraw())
			var gsel = OptionButton.new()
			gsel.add_item("TILES: LEGACY OF GOKU II"); gsel.set_item_metadata(0, "")
			for g in Assets.LIB_GAMES:
				if Assets.has_library(g):
					gsel.add_item("TILES: " + Assets.LIB_TITLES[g]); gsel.set_item_metadata(gsel.item_count - 1, g)
					if g == pal_game: gsel.select(gsel.item_count - 1)
			gsel.item_selected.connect(func(j): pal_game = str(gsel.get_item_metadata(j)); _refresh_side())
			side.add_child(gsel)
			# the layer a tile is picked from / stamped onto (the same as the bar's at the top)
			var lsel = OptionButton.new()
			for i in 5:
				lsel.add_item(["LAYER 0 GROUND", "LAYER 1", "LAYER 2", "LAYER 3 OVER THE HERO", "LAYER 4 OVER THE HERO"][i], i)
			lsel.select(layer)
			lsel.item_selected.connect(func(i):
				layer = i
				layer_pick.select(i)
				if tool == "PICK" or tool == "STAMP":
					var t2 = int(brush_cell[layer]) & ~(1 << 18)
					if last_brush != "TILE" and t2 > 0:
						brush_tile = t2
				_refresh_side())
			side.add_child(lsel)
			palette = preload("res://scripts/dev_palette.gd").new()
			palette.game = pal_game
			palette.custom_minimum_size = Vector2(232, 420)
			palette.chosen = brush_tile
			palette.jump_to(brush_tile & 0xFFFF)      # the list opens at the tile chosen (or PICKed)
			palette.picked.connect(func(t):
				brush_tile = t
				last_brush = "TILE"
				if pick_stamp:
					_set_tool("STAMP")
				_refresh_side()
				_say("Tile %d chosen for LAYER %d.%s" % [t & 0xFFFF, layer, " Click or drag to stamp it." if pick_stamp else " (STAMP on the right: stamp it.)"]))
			side.add_child(palette)
			var jb = HBoxContainer.new(); side.add_child(jb)
			var sp = SpinBox.new(); sp.min_value = 0; sp.max_value = 65535; sp.value = brush_tile & 0xFFFF; sp.prefix = "tile"
			sp.value_changed.connect(func(v): brush_tile = palette.cell_of(int(v)); palette.chosen = brush_tile; palette.jump_to(int(v)))
			jb.add_child(sp)
		"ERASE":
			_lab("Takes the tile away from LAYER %d." % layer)
			_spin(side, "brush size", 1, 32, paint_size, func(v): paint_size = int(v); overlay.queue_redraw())
		"FOE":
			_lab("KIND is how a foe fights (its moves and strength); LOOK is the sprite set it wears. Pick a kind from the list (weakest at the top), set its level (0 = its own) and, if you like, another look: the two pictures below show the kind's own look and the one you picked, and which kinds normally wear it.")
			# every foe of the game with a picture, weakest first: the original level and health on each line
			var fl = ItemList.new(); fl.custom_minimum_size = Vector2(230, 240); fl.fixed_icon_size = Vector2i(40, 40)
			fl.max_columns = 1
			var kinds = []
			for k in 128:
				if Rules.kind_to_type_set(k)[1] >= 0 and Assets.data.get("enemies") is Array and k < Assets.data["enemies"].size():
					kinds.append(k)
			kinds.sort_custom(func(x, y): return int(Assets.data["enemies"][x]["hp"]) < int(Assets.data["enemies"][y]["hp"]))
			for k in kinds:
				var tab: Dictionary = Assets.data["enemies"][k]
				var ss: Dictionary = Assets.sprite_set(Rules.kind_to_type_set(k)[1])
				var icon: Texture2D = null
				if ss.get("tex") is Texture2D:
					var at = AtlasTexture.new(); at.atlas = ss["tex"]
					at.region = Rect2(0, 0, int(ss.get("cell", 64)), int(ss.get("cell", 64)))
					icon = at
				fl.add_item("KIND %d · SET %d   LV %d   %d HP" % [k, _kind_set(k), int(tab["lvl"]), int(tab["hp"])], icon)
				fl.set_item_metadata(fl.item_count - 1, k)
				if k == foe_type:
					fl.select(fl.item_count - 1)
			fl.item_selected.connect(func(j): foe_type = int(fl.get_item_metadata(j)); _update_preview(); _say("Click the map to put this foe there."))
			side.add_child(fl)
			if fl.get_selected_items().size() > 0:
				fl.ensure_current_is_visible.call_deferred()
			var sp = _spin(side, "kind", 0, 127, foe_type, func(v): foe_type = int(v); _update_foe_previews())
			fl.item_selected.connect(func(j): sp.set_value_no_signal(int(fl.get_item_metadata(j))); _update_foe_previews())      # (the number follows the picture)
			_spin(side, "level", 0, 99, foe_lv, func(v): foe_lv = int(v))
			_spin(side, "look (set)", 0, 3999, foe_look, func(v): foe_look = int(v); _update_foe_previews())
			_foe_previews()
			_update_foe_previews()
		"PERSON":
			_line(side, "name", person_name, func(t): person_name = t.to_upper())
			_spin(side, "sprite set", 0, 3999, person_set, func(v): person_set = int(v); _update_preview())
			_lab("Sprite sets: this game's 0-299; Buu's Fury 1000+; Legacy of Goku 2000+ (OTHER GAMES reads them); colour variants 3000+ (COLORS).")
			var so = OptionButton.new(); so.add_item("NO SHOP"); so.set_item_metadata(0, "")
			for sh in Content.shops:
				so.add_item("SHOP: " + str(sh.get("name", sh["id"]))); so.set_item_metadata(so.item_count - 1, str(sh["id"]))
				if str(sh["id"]) == person_shop: so.select(so.item_count - 1)
			so.item_selected.connect(func(j): person_shop = str(so.get_item_metadata(j)))
			side.add_child(so)
			var eo = OptionButton.new(); eo.add_item("NO EVENT (just the lines)"); eo.set_item_metadata(0, "")
			for e in Content.events:
				eo.add_item("EVENT: " + str(e.get("name", e["id"]))); eo.set_item_metadata(eo.item_count - 1, str(e["id"]))
				if str(e["id"]) == person_event: eo.select(eo.item_count - 1)
			eo.item_selected.connect(func(j): person_event = str(eo.get_item_metadata(j)))
			side.add_child(eo)
			_lab("What they say (one line each, A goes to the next):")
			var te = TextEdit.new(); te.text = person_lines; te.custom_minimum_size = Vector2(230, 110)
			te.text_changed.connect(func(): person_lines = te.text)
			side.add_child(te)
			_lab("A click on the map places them with these lines.")
			if _last_person_i() >= 0:
				var ab = Button.new(); ab.text = "SAVE TO THE PERSON JUST PLACED"; side.add_child(ab)
				ab.pressed.connect(func():
					var i = _last_person_i()
					if i < 0:
						return
					_remember_patch()
					last_person = Mods.patch(key)["people_add"][i]      # (by its spot: an undo leaves a copy in the list)
					var lines = []
					for l in person_lines.split("\n"):
						if l.strip_edges() != "":
							lines.append(["", person_name, l.strip_edges()])
					last_person["name"] = person_name
					last_person["set"] = person_set
					last_person["lines"] = lines
					if person_shop != "": last_person["shop"] = person_shop
					else: last_person.erase("shop")
					if person_event != "": last_person["event"] = person_event
					else: last_person.erase("event")
					_rebuild_world()
					_say("%s saved with %d line(s). SAVE the map to keep it (Ctrl+Z undoes)." % [person_name, lines.size()]))
			_preview_box()
			_update_preview()
		"ITEM":
			var ob = OptionButton.new()
			var i = 0
			for it in Content.items + Content.gear:
				ob.add_item(str(it.get("name", it["id"])), i)
				ob.set_item_metadata(i, str(it["id"]))
				if str(it["id"]) == item_id: ob.select(i)
				i += 1
			ob.item_selected.connect(func(j): item_id = str(ob.get_item_metadata(j)))
			side.add_child(ob)
			_spin(side, "how many", 1, 99, item_n, func(v): item_n = int(v))
		"DOOR":
			_lab("1. Drag the door's box on this map.\n2. Switch with the map list above if it should lead to another map.\n3. Click where you arrive.\nA door to EARTH or a map of your own works the same way.")
			_lab("LOCKED DOOR (leave empty for an open one):")
			var io = OptionButton.new(); io.add_item("NEEDS NO ITEM"); io.set_item_metadata(0, "")
			io.fit_to_longest_item = false; io.clip_text = true; io.custom_minimum_size = Vector2(230, 0)
			for it in Content.items + Content.gear:
				io.add_item("NEEDS: " + str(it.get("name", it["id"]))); io.set_item_metadata(io.item_count - 1, str(it["id"]))
				if str(it["id"]) == str(door_need["need_item"]): io.select(io.item_count - 1)
			io.item_selected.connect(func(j): door_need["need_item"] = str(io.get_item_metadata(j)))
			side.add_child(io)
			var tk = CheckBox.new(); tk.text = "ITEM USED UP"; tk.button_pressed = bool(door_need["take_item"]); tk.toggled.connect(func(on): door_need["take_item"] = on); side.add_child(tk)
			_line(side, "needs flag", str(door_need["need_flag"]), func(t): door_need["need_flag"] = t.strip_edges())
			_lab("(a flag an event sets, e.g. event:my_event or a FLAG step's name)")
			_spin(side, "needs level", 0, 99, int(door_need["need_level"]), func(v): door_need["need_level"] = int(v))
			_line(side, "locked text", str(door_need["locked_msg"]), func(t): door_need["locked_msg"] = t.to_upper())
		"SELECT":
			if selected.is_empty():
				_lab("Click a foe (red), person (blue), treasure (gold) or door (yellow) - or a place's name (its box).")
			else:
				var o: Dictionary = selected["obj"]
				if str(selected["kind"]) == "place":
					var pr: Rect2 = o["rect"]
					var song = -1
					for pt in area["land"].get("parts", []):
						if pt.size() > 3 and str(pt[3]) == str(o["key"]): song = int(pt[2])
					_lab("PLACE: %s  (the game's map %s)" % [str(o["name"]), str(o["key"])])
					_lab("Box: %d x %d cells at cell %d, %d. Music: %s." % [int(pr.size.x / 8), int(pr.size.y / 8), int(pr.position.x / 8), int(pr.position.y / 8), ("the game's song %d" % song) if song >= 0 else "the land's own"])
					_lab("Drag it to move it (name, music, its own people and story warps go with it).")
					var dbp = Button.new(); dbp.text = "DELETE THIS PLACE (Del)"; dbp.pressed.connect(_delete_selected); side.add_child(dbp)
					return
				if str(selected["kind"]) == "person":
					_person_editor(o)
				elif str(selected["kind"]) == "rock":
					_rock_editor(o)
				else:
					_lab(str(selected["kind"]).to_upper() + ": " + JSON.stringify(o).left(300))
				var db = Button.new(); db.text = "DELETE (Del)"; db.pressed.connect(_delete_selected); side.add_child(db)
				_lab("Drag it to move it.")
		"BIOME":
			_biomes()
			var bl = ItemList.new(); bl.custom_minimum_size = Vector2(230, 300); bl.fixed_icon_size = Vector2i(40, 40)
			for b in biomes:
				bl.add_item(str(b["name"]), _biome_icon(b))
			if biome_i < bl.item_count:
				bl.select(biome_i)
			bl.item_selected.connect(func(j): biome_i = j; biome_grab = false)
			side.add_child(bl)
			_spin(side, "brush size", 1, 64, biome_size, func(v): biome_size = int(v); overlay.queue_redraw())
			var gb = Button.new(); gb.text = "MAKE A BIOME FROM A BOX" if not biome_grab else "DRAG A BOX ON THE MAP... (click to stop)"; side.add_child(gb)
			gb.pressed.connect(func(): biome_grab = not biome_grab; _refresh_side())
			_line(side, "its name", biome_newname, func(t): biome_newname = t)
			if biome_i >= biome_builtin and biome_i < biomes.size():      # (only yours: the game's own stay)
				var db = Button.new(); db.text = "DELETE THIS BIOME"; side.add_child(db)
				db.pressed.connect(func():
					undo.append({"biomes": biomes.duplicate()}); redo.clear()
					biomes.remove_at(biome_i); biome_i = 0; _biomes_save(); _refresh_side())
			_lab("Paints every layer and its walls (water stays water). Ctrl+Z undoes a stroke. Make one from a box of 16 x 16 cells or more for the best look.")
		"ROCK":
			_lab("Choose what to set down, then click on the map.")
			var rl = ItemList.new(); rl.custom_minimum_size = Vector2(230, 200); rl.max_columns = 5; rl.icon_mode = ItemList.ICON_MODE_TOP      # (5 a row: wider pushed the panel off the screen)
			rl.fixed_icon_size = Vector2i(32, 32); rl.same_column_width = true
			var ks = rock_b.kinds()
			for k in ks:
				var rk2: Dictionary = k["rk"]
				var tx = AtlasTexture.new(); tx.atlas = rock_b.atlas
				tx.region = Rect2(float(rk2["at"][0]), float(rk2["at"][1]), float(rk2["w"]), float(rk2["h"]))
				rl.add_icon_item(tx)
				rl.set_item_metadata(rl.item_count - 1, k["like"])
				if str(k["like"]) == rock_like: rl.select(rl.item_count - 1)
			if rock_like == "" and not ks.is_empty():
				rock_like = str(ks[0]["like"]); rl.select(0)
			rl.item_selected.connect(func(j): rock_like = str(rl.get_item_metadata(j)))
			side.add_child(rl)
			_spin(side, "hits it takes", 1, 3, rock_hits, func(v): rock_hits = int(v))
			_lab("What it drops (the game's own choices): food heals HP, ki fills EP - each only while that is not full, unless EVEN IF FULL. Small, medium and large give back 10, 20 and 30%.")
			var dob = OptionButton.new(); dob.clip_text = true; dob.custom_minimum_size = Vector2(230, 0); dob.add_theme_font_size_override("font_size", 11)
			for t in rock_b.DROP_TABLES:
				dob.add_item(str(t[0]))
			dob.select(rock_drops)
			dob.item_selected.connect(func(j): rock_drops = j)
			side.add_child(dob)
			_lab("SELECT a rock to change, drag or delete it. Rocks in front of a cave door are left out in the game for now.")
		"MOVE":
			var sw = CheckBox.new(); sw.text = "SWAP"; sw.button_pressed = move_swap; side.add_child(sw)      # (a checkbox's text does not wrap: kept short)
			sw.toggled.connect(func(on): move_swap = on)
			var ls = CheckBox.new(); ls.text = "LASSO"; ls.button_pressed = move_lasso; side.add_child(ls)
			ls.toggled.connect(func(on): move_lasso = on; move_box = Rect2i(); move_mask = {}; lasso_pts = []; _refresh_side())
			_lab("LASSO on: press and draw round what you want, any shape - let go and it closes back to where you started. Every cell inside is picked up.")
			_lab("SWAP on: what's there goes where yours was. Off (COVER): what's there is covered, and the ground round fills the spot you left.")
			if move_box.size.x > 0:
				_lab(("Picked up: %d cells (LASSO). Click where it goes (the green shape)." % move_mask.size()) if not move_mask.is_empty() else ("Picked up: %d x %d cells. Click where its top-left corner goes (the green box)." % [move_box.size.x, move_box.size.y]))
				var cb = Button.new(); cb.text = "NEVER MIND"; cb.pressed.connect(func(): move_box = Rect2i(); move_mask = {}; _refresh_side()); side.add_child(cb)
			else:
				_lab("Press on a place's name and drag to move the whole place - or drag a box round any part (zoom right out for big parts).")
			_lab("Then SAVE. Ctrl+Z undoes the whole move.")
			if key.begins_with("land/"):
				_lab("MAP SIZE (now %d x %d cells). Bigger: new room on the right and at the bottom (sea). Smaller: cut off on the right and at the bottom, land and all - not while places, foes, people, doors, treasure or zones are still there. Ctrl+Z puts it back." % [int(area["tw"]), int(area["th"])])
				var gw = _line(side, "width", str(int(area["tw"])), func(_t): pass)
				var gh = _line(side, "height", str(int(area["th"])), func(_t): pass)
				var gbt = Button.new(); gbt.text = "RESIZE WHOLE MAP"; side.add_child(gbt)
				gbt.pressed.connect(func(): _resize_map(int(gw.text), int(gh.text)))
		"GUIDE":
			var gb = Button.new(); gb.text = "CHOOSE A PICTURE"; gb.pressed.connect(_guide_choose); side.add_child(gb)
			if not guide.is_empty():
				var sh = CheckBox.new(); sh.text = "SHOW IT"; sh.button_pressed = bool(guide.get("on", true)); side.add_child(sh)
				sh.toggled.connect(func(on): _guide_undo_point(); guide["on"] = on; _guide_save(); overlay.queue_redraw())
				_lab("How strong it shows")
				var sl = HSlider.new(); sl.min_value = 0.05; sl.max_value = 1.0; sl.step = 0.05; sl.value = float(guide.get("alpha", 0.4)); side.add_child(sl)
				sl.value_changed.connect(func(v): guide["alpha"] = v; _guide_save(); overlay.queue_redraw())
				var bg = Button.new(); bg.text = "BIGGER"; bg.pressed.connect(_guide_scale.bind(1.05)); side.add_child(bg)
				var sm = Button.new(); sm.text = "SMALLER"; sm.pressed.connect(_guide_scale.bind(1.0 / 1.05)); side.add_child(sm)
				var ft = Button.new(); ft.text = "FIT TO THE MAP"; side.add_child(ft)
				ft.pressed.connect(func():
					_guide_undo_point()
					guide["x"] = 0.0; guide["y"] = 0.0
					var ar = float(guide["h"]) / maxf(1.0, float(guide["w"]))
					guide["w"] = float(area["w"]); guide["h"] = float(area["w"]) * ar
					if guide["h"] > float(area["h"]):
						guide["h"] = float(area["h"]); guide["w"] = float(area["h"]) / maxf(0.001, ar)
					_guide_save(); overlay.queue_redraw())
				_lab("Drag on the map to move it. Kept for next time (only on this computer).")
		"COPY", "PASTE":
			_lab("COPY: drag a box. PASTE: click where its top-left goes. Clipboard: %s" % ("empty" if clipboard.is_empty() else "%d x %d" % [clipboard["w"], clipboard["h"]]))
			var lc = CheckBox.new(); lc.text = "LASSO"; lc.button_pressed = copy_lasso; side.add_child(lc)
			lc.toggled.connect(func(on): copy_lasso = on; lasso_pts = [])
			_lab("LASSO on: COPY by drawing any shape round it (let go: it closes back to where you started) - only that shape is pasted.")
			var kg = CheckBox.new(); kg.text = "KEEP THE GROUND THERE (G)"; kg.button_pressed = keep_ground
			kg.toggled.connect(func(on): keep_ground = on); side.add_child(kg)
			if not clipboard.is_empty():
				var mh = Button.new(); mh.text = "MIRROR LEFT-RIGHT (X)"; mh.pressed.connect(mirror_clipboard.bind(true)); side.add_child(mh)
				var mv = Button.new(); mv.text = "MIRROR UPSIDE DOWN (Y)"; mv.pressed.connect(mirror_clipboard.bind(false)); side.add_child(mv)
				var sn = _line(side, "thing name", "MY THING", func(_t): pass)
				var sb = Button.new(); sb.text = "SAVE THE COPY AS A THING"; side.add_child(sb)
				sb.pressed.connect(func():
					var f = MT.save_stamp(sn.text.strip_edges().to_upper(), clipboard)
					stamps = []
					_say("Saved as a THING (content/stamps): set it down with the THINGS tool." if f != "" else "Could not save it."))
		"SMART":
			_lab("Ground to paint: %s. PICK another one first if you want (water, sand, a path, snow...)." % ("none yet" if int(brush_cell[0]) == 0 else str(brush_cell.slice(0, 5))))
			_spin(side, "brush size", 1, 6, smart_size, func(v): smart_size = int(v))
			_lab("Paint the shape; when you let go the edges are chosen from the game's own maps so they join up (like the game's lakes, beaches and paths). Ctrl+Z undoes.")
			_edges()
			var et = Label.new(); et.text = "EDGE"; et.add_theme_font_size_override("font_size", 13); side.add_child(et)
			_lab("Brush along where water meets land: the game's own shore is built there, piece by piece, following its bends - BEACH: sea against sand (wet sand and foam); LAKE: lake water against a cliff's foot (its rim); WATERFALL: a waterfall's soft sides; FOAM: under a waterfall's bottom where it falls into water (paint the fall's bottom straight). Choose one (OFF: SMART's own painting).")
			var el = ItemList.new(); el.custom_minimum_size = Vector2(230, 150); el.fixed_icon_size = Vector2i(40, 40)
			el.add_item("OFF")
			for e in edges:
				el.add_item(str(e["name"]), _edge_icon(e))
			el.select(edge_i + 1)
			el.item_selected.connect(func(j): edge_i = j - 1)
			side.add_child(el)
			_spin(side, "edge brush", 1, 12, edge_size, func(v): edge_size = int(v); overlay.queue_redraw())
		"THINGS":
			if stamps.is_empty():
				stamps = MT.list_stamps()
			var kg2 = CheckBox.new(); kg2.text = "KEEP THE GROUND THERE (G)"; kg2.button_pressed = keep_ground
			kg2.toggled.connect(func(on): keep_ground = on); side.add_child(kg2)
			var il = ItemList.new(); il.custom_minimum_size = Vector2(230, 260); il.fixed_icon_size = Vector2i(40, 40)
			il.max_columns = 1
			for st in stamps:
				var img = MT.stamp_image(st, 3)
				il.add_item("%s  %dx%d" % [str(st.get("name", "THING")), int(st["w"]), int(st["h"])], ImageTexture.create_from_image(img))
			if stamp_i >= 0 and stamp_i < stamps.size():
				il.select(stamp_i)
			il.item_selected.connect(func(j): stamp_i = j; _say("Click the map: %s goes there (its top-left at the mouse)." % str(stamps[j].get("name", ""))))
			side.add_child(il)
			# the chosen thing (one FIND THINGS IN VIEW found, or a saved one) kept under a name of your own
			var tn = LineEdit.new(); tn.placeholder_text = "its name"; tn.custom_minimum_size = Vector2(230, 0); side.add_child(tn)
			var tsb = Button.new(); tsb.text = "SAVE THIS THING"; side.add_child(tsb)
			tsb.pressed.connect(func():
				if stamp_i < 0 or stamp_i >= stamps.size():
					_say("Choose a thing in the list first.")
					return
				var nm = tn.text.strip_edges().to_upper()
				if nm == "":
					_say("Give it a name first.")
					return
				var f = MT.save_stamp(nm, stamps[stamp_i])
				if f == "":
					_say("Could not save it.")
					return
				stamps[stamp_i]["name"] = nm
				_say("Saved as %s: it is in THINGS from now on (SAVED THINGS ONLY lists them)." % nm)
				_refresh_side())
			var fb = Button.new(); fb.text = "FIND THINGS IN VIEW"; side.add_child(fb)
			fb.pressed.connect(func():
				var vs = get_viewport_rect().size / cam.zoom
				var r = Rect2i(Vector2i((cam.position - vs / 2) / 8.0), Vector2i(vs / 8.0)).intersection(Rect2i(0, 0, int(area["tw"]), int(area["th"])))
				var found = MT.find_objects(self, r)
				stamps = MT.list_stamps() + found
				stamp_i = -1
				_say("%d things found here (the saved ones first). Choose one, click the map. To keep one: give it a name, SAVE THIS THING." % found.size())
				_refresh_side())
			var tdb = Button.new(); tdb.text = "DELETE THIS SAVED THING"; side.add_child(tdb)
			tdb.pressed.connect(func():
				if stamp_i < 0 or stamp_i >= stamps.size() or not stamps[stamp_i].has("file"):
					_say("Choose one of your saved things in the list first.")
					return
				var nm = str(stamps[stamp_i].get("name", ""))
				var stp = _thing_gone(str(stamps[stamp_i]["file"]))
				if not stp.is_empty():
					undo.append(stp)
					redo.clear()
				stamps = MT.list_stamps(); stamp_i = -1
				_say("%s deleted. Ctrl+Z brings it back." % nm)
				_refresh_side())
			var rb = Button.new(); rb.text = "SAVED THINGS ONLY"; side.add_child(rb)
			rb.pressed.connect(func(): stamps = MT.list_stamps(); stamp_i = -1; _refresh_side())
		"ZONE":
			_line(side, "foe kinds", zone_cfg["kinds"], func(t): zone_cfg["kinds"] = t)
			_lab("(the game's foe numbers 0-127, with commas: 8,9,12)")
			_spin(side, "how many", 1, 30, zone_cfg["count"], func(v): zone_cfg["count"] = int(v))
			_spin(side, "level (0 own)", 0, 99, zone_cfg["level"], func(v): zone_cfg["level"] = int(v))
			_spin(side, "back after s", 5, 600, zone_cfg["respawn"], func(v): zone_cfg["respawn"] = int(v))
			_lab("Drag a box on the map. SELECT a zone (click inside it) to delete it.")
		"EVENT":
			var ob = OptionButton.new(); ob.fit_to_longest_item = false; ob.clip_text = true; ob.custom_minimum_size = Vector2(230, 0)
			ob.add_item("(choose an event)"); ob.set_item_metadata(0, "")
			for e in Content.events:
				ob.add_item(str(e.get("name", e["id"]))); ob.set_item_metadata(ob.item_count - 1, str(e["id"]))
				if str(e["id"]) == event_id: ob.select(ob.item_count - 1)
			ob.item_selected.connect(func(j): event_id = str(ob.get_item_metadata(j)))
			side.add_child(ob)
			var ab = CheckBox.new(); ab.text = "ONLY BY AN ATTACK"; ab.button_pressed = event_attack
			ab.toggled.connect(func(on): event_attack = on); side.add_child(ab)
			_lab("ONLY BY AN ATTACK: a rock to break, a switch to hit - a punch or a blast landing in the box starts it.")
			_lab("Drag a box: walking into it (or hitting it) starts the event. Make events in the EVENTS tab. SELECT (click inside) to delete it.")
		"MOOD":
			_spin(side, "darkness %", 0, 95, roundf(float(mood_cfg["dark"]) * 100), func(v): mood_cfg["dark"] = v / 100.0)
			_spin(side, "light size", 20, 200, int(mood_cfg["light"]), func(v): mood_cfg["light"] = int(v))
			var wo = OptionButton.new()
			for wv in ["", "rain", "snow", "ash", "dust"]:
				wo.add_item("NO WEATHER" if wv == "" else wv.to_upper()); wo.set_item_metadata(wo.item_count - 1, wv)
				if wv == str(mood_cfg["weather"]): wo.select(wo.item_count - 1)
			wo.item_selected.connect(func(j): mood_cfg["weather"] = str(wo.get_item_metadata(j)))
			side.add_child(wo)
			_line(side, "music", str(mood_cfg["music"]), func(t): mood_cfg["music"] = t.strip_edges().to_lower())
			_lab("(music: empty = the place's own; field, cave, lair, boss, title, or a song file from your music folder)")
			_lab("Drag a box: in it the place is dark (a light round each fighter), has weather or its own music. SELECT (click inside) to delete.")
		"UNDER", "OVER":
			_lab(TOOL_HELP[tool])
			_spin(side, "brush size", 1, 32, paint_size, func(v): paint_size = int(v); overlay.queue_redraw())
		"GROUND":
			var hg = CheckBox.new(); hg.text = "HIGH GROUND"; hg.button_pressed = high_ground
			_big_check(hg)
			hg.toggled.connect(func(on): high_ground = on)
			side.add_child(hg)
			_lab("HIGH GROUND - the tops of platforms and roofs you can land on. Tick HIGH GROUND and paint them (seen with OVER HERO ticked). A hero who flies there and lands stands on top and is drawn over it - he cannot walk off it, only fly off.")
			_hg_sample("VIOLET - high ground you can walk behind. What hides you there are its tiles drawn over the hero (blue with OVER HERO) - the game's roofs, trees and cliffs already are. On a thing whose tiles are all on the ground layers, paint them with OVER.", false)
			_hg_sample("MAGENTA - wall painted on violet: high ground that is a wall nobody can walk behind.", true)
			_lab("Untick HIGH GROUND and paint GROUND to make it normal ground again.")
			_spin(side, "brush size", 1, 32, paint_size, func(v): paint_size = int(v); overlay.queue_redraw())
		"WALL":
			_lab("Red = wall (WALLS on). Paint walls or walkable ground. The game's own walls are kept exactly; change only what you mean to.")
			_spin(side, "brush size", 1, 32, paint_size, func(v): paint_size = int(v); overlay.queue_redraw())
		_:
			_lab(TOOL_HELP.get(tool, ""))

## a big, clear tick box (the theme's was tiny and blurry): a white box, a thick green tick when on
static var _check_icons = []
## walk bits: 1 = walkable from the ground, 2 = the game's own upper level, 4 = HIGH GROUND (land on it, stand on top)
static func _hg(w: int) -> bool:
	return (w & 4) != 0

## (cells painted earlier today as 6 / 7 were meant to be walked behind: walkable)
static func _walk_bits(w: int) -> int:
	w = w & 7
	return w | 1 if (w & 6) == 6 else w

func _big_check(cb: CheckBox) -> void:
	if _check_icons.is_empty():
		for on in [false, true]:
			var n = 22
			var img = Image.create(n, n, false, Image.FORMAT_RGBA8)
			img.fill(Color(0, 0, 0, 0))
			for i in n:
				for t in 2:
					img.set_pixel(i, t, Color.WHITE); img.set_pixel(i, n - 1 - t, Color.WHITE)
					img.set_pixel(t, i, Color.WHITE); img.set_pixel(n - 1 - t, i, Color.WHITE)
			if on:
				var pts = []
				for k in 6:
					pts.append(Vector2i(5 + k, 11 + k))      # down stroke
				for k in 10:
					pts.append(Vector2i(10 + k, 16 - k))     # up stroke
				for p in pts:
					for dx in range(-1, 2):
						for dy in range(-1, 2):
							var q = p + Vector2i(dx, dy)
							if q.x > 1 and q.y > 1 and q.x < n - 2 and q.y < n - 2:
								img.set_pixel(q.x, q.y, Color(0.35, 1.0, 0.45))
			_check_icons.append(ImageTexture.create_from_image(img))
	for nm in ["unchecked", "unchecked_disabled"]:
		cb.add_theme_icon_override(nm, _check_icons[0])
	for nm in ["checked", "checked_disabled"]:
		cb.add_theme_icon_override(nm, _check_icons[1])
	cb.add_theme_font_size_override("font_size", 14)

## HIGH GROUND's help: a sample of the colour the map shows (violet - or magenta, violet with the wall's red over it,
## drawn the same way over the same ground) and what it means, a gap above it
func _hg_sample(t: String, wall: bool) -> void:
	var gap = Control.new(); gap.custom_minimum_size = Vector2(0, 6); side.add_child(gap)
	var h = HBoxContainer.new(); side.add_child(h)
	var sw = Control.new(); sw.custom_minimum_size = Vector2(22, 22)
	sw.draw.connect(func():
		sw.draw_rect(Rect2(0, 0, 22, 22), Color(0.62, 0.58, 0.28))      # (a grass-like ground under it)
		sw.draw_rect(Rect2(0, 0, 22, 22), Color(0.55, 0.15, 1.0, 0.8))
		if wall:
			sw.draw_rect(Rect2(0, 0, 22, 22), Color(1, 0.1, 0.1, 0.28)))
	h.add_child(sw)
	var l = Label.new(); l.text = t; l.autowrap_mode = TextServer.AUTOWRAP_WORD; l.custom_minimum_size = Vector2(200, 0)
	l.add_theme_font_size_override("font_size", 10)
	h.add_child(l)
	var gap2 = Control.new(); gap2.custom_minimum_size = Vector2(0, 6); side.add_child(gap2)

func _lab(t: String) -> Label:
	var l = Label.new(); l.text = t; l.autowrap_mode = TextServer.AUTOWRAP_WORD; l.custom_minimum_size = Vector2(230, 0)
	l.add_theme_font_size_override("font_size", 10)
	side.add_child(l)
	return l

func _spin(parent: Control, label: String, lo: float, hi: float, v: float, cb: Callable) -> SpinBox:
	var h = HBoxContainer.new(); parent.add_child(h)
	var l = Label.new(); l.text = label; l.custom_minimum_size = Vector2(80, 0); l.add_theme_font_size_override("font_size", 10); h.add_child(l)
	var s = SpinBox.new(); s.min_value = lo; s.max_value = hi; s.value = v; s.value_changed.connect(cb); h.add_child(s)
	return s

func _line(parent: Control, label: String, v: String, cb: Callable) -> LineEdit:
	var h = HBoxContainer.new(); parent.add_child(h)
	var l = Label.new(); l.text = label; l.custom_minimum_size = Vector2(80, 0); l.add_theme_font_size_override("font_size", 10); h.add_child(l)
	var e = LineEdit.new(); e.text = v; e.custom_minimum_size = Vector2(140, 0); e.text_changed.connect(cb); h.add_child(e)
	return e

func _preview_box() -> void:
	var holder = Control.new(); holder.custom_minimum_size = Vector2(230, 110)
	side.add_child(holder)
	preview = ActorView.new()
	preview.position = Vector2(115, 90)
	preview.scale = Vector2(2, 2)
	holder.add_child(preview)

## FOE: the kind's own look and the look picked, side by side - each with what it is (which kinds normally wear a set)
var foe_prev_kind: ActorView
var foe_prev_look: ActorView
var foe_lab_kind: Label
var foe_lab_look: Label
func _foe_previews() -> void:
	preview = null
	var row = HBoxContainer.new(); side.add_child(row)
	var made = []
	for i in 2:
		var col = VBoxContainer.new(); col.custom_minimum_size = Vector2(115, 0); row.add_child(col)
		var holder = Control.new(); holder.custom_minimum_size = Vector2(115, 100); col.add_child(holder)
		var av = ActorView.new(); av.position = Vector2(57, 84); av.scale = Vector2(2, 2); holder.add_child(av)
		var lb = Label.new(); lb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; lb.custom_minimum_size = Vector2(110, 0)
		lb.add_theme_font_size_override("font_size", 10); col.add_child(lb)
		made.append([av, lb])
	foe_prev_kind = made[0][0]; foe_lab_kind = made[0][1]
	foe_prev_look = made[1][0]; foe_lab_look = made[1][1]

func _update_foe_previews() -> void:
	if foe_prev_kind == null or not is_instance_valid(foe_prev_kind):
		return
	var ks = _kind_set(foe_type)
	foe_prev_kind.set_sprite_set(Assets.sprite_set(ks)); foe_prev_kind.show_frame(1, 0, 0)
	var kb = _boss_name(ks)
	if ks < 0:
		foe_lab_kind.text = "KIND %d\nNOT USED BY THE GAME\n(PICK A LOOK)" % foe_type
	else:
		foe_lab_kind.text = "KIND %d%s\nITS OWN LOOK: SET %d%s" % [foe_type, " · BOSS" if kb != "" else "", ks, ("\n" + kb) if kb != "" else ""]
	var ls = foe_look if foe_look > 0 else ks
	foe_prev_look.set_sprite_set(Assets.sprite_set(ls)); foe_prev_look.show_frame(1, 0, 0)
	if foe_look <= 0:
		foe_lab_look.text = "LOOK 0\nTHE KIND'S OWN"
	else:
		var users = _kinds_for_set(foe_look)
		var lb = _boss_name(foe_look)
		var who = ("NORMALLY USED BY KIND " + ", ".join(PackedStringArray(users.map(func(x): return str(x))))) if not users.is_empty() else ("NO KIND WEARS IT IN THE GAME" if lb != "" else "NO FOE'S OWN LOOK (A HERO OR A PERSON)")
		foe_lab_look.text = "LOOK: SET %d%s\n%s%s" % [foe_look, " · BOSS" if lb != "" else "", who, ("\n" + lb) if lb != "" else ""]

## a boss look: a villain's set (or one of its outfits) - a foe wearing it fights as that villain, with its beams and
## specials (brawl.gd - HERO FOES). "" for any other look
func _boss_name(s: int) -> String:
	if s < 0:
		return ""
	var fh = {9: "ANDROID 17", 11: "ANDROID 18", 30: "CELL", 34: "COOLER", 48: "FRIEZA", 76: "KRILLIN", 121: "TIEN", 156: "YAMCHA"}
	if fh.has(s):
		return "FIGHTS AS %s (BEAMS, SPECIALS)" % fh[s]
	for ch in Assets.CHARACTERS.size():
		if not Rules.is_villain(ch):
			continue
		var hh = Mods.hero_entry(Assets.CHARACTERS[ch])
		var nm = ""
		if int(hh.get("set", -1)) == s:
			nm = str(hh.get("name", Assets.CHARACTERS[ch]))
		for o in Assets.outfits(ch):
			if nm == "" and o is Dictionary and int(o.get("set", -1)) == s:
				nm = str(o.get("name", Assets.CHARACTERS[ch]))
		if nm != "":
			return "FIGHTS AS %s (BEAMS, SPECIALS)" % nm
	return ""

## the look a kind wears in the game: your team's (DEV TOOLS - ENEMIES) or the game's own
func _kind_set(k: int) -> int:
	var t: Dictionary = Content.enemy_types.get(k, {})
	if t.has("set") and int(t["set"]) >= 0:
		return int(t["set"])
	return int(Rules.kind_to_type_set(k)[1])

func _kinds_for_set(s: int) -> Array:
	var out = []
	for k in 128:
		if _kind_set(k) == s:
			out.append(k)
	return out

func _update_preview() -> void:
	if preview == null:
		return
	var st = person_set if tool == "PERSON" else (foe_look if foe_look > 0 else Rules.kind_to_type_set(foe_type)[1])
	preview.set_sprite_set(Assets.sprite_set(st))
	preview.show_frame(1, 0, 0)

func _new_map_dialog() -> void:
	var d = AcceptDialog.new()
	d.title = "A NEW MAP OF YOUR OWN"
	var v = VBoxContainer.new(); d.add_child(v)
	var nm = LineEdit.new(); nm.placeholder_text = "name (letters, no spaces)"; nm.text = "mymap%d" % (Mods.custom_maps().size() + 1); v.add_child(nm)
	var w = SpinBox.new(); w.min_value = 30; w.max_value = 1024; w.value = 80; w.prefix = "width (tiles)"; v.add_child(w)
	var h = SpinBox.new(); h.min_value = 20; h.max_value = 1024; h.value = 60; h.prefix = "height (tiles)"; v.add_child(h)
	var l = Label.new(); l.text = "It starts all one ground: the cell picked last with PICK (or tile %d)." % brush_tile; v.add_child(l)
	d.confirmed.connect(func():
		var n = nm.text.strip_edges().to_lower().replace(" ", "_")
		if n == "":
			return
		var cell = brush_cell.slice(0, 5) if int(brush_cell[0]) != 0 else [brush_tile, 0, 0, 0, 0]
		if Mods.create_custom(n, int(w.value), int(h.value), cell):
			Game.planet.build_land(0, 1)
			_fill_maps()
			_go_map("custom/" + n)
			_fill_maps()
			_say("Map %s made. Paint it, then make a DOOR to it from EARTH (DOOR on Earth, switch to this map, click the arrival)." % n)
		d.queue_free())
	ui.add_child(d)
	d.popup_centered(Vector2i(320, 200))

## TOGETHER: host or join, who is here
func _together_dialog() -> void:
	if coedit == null:
		coedit = preload("res://scripts/dev_coedit.gd").new()
		coedit.dev = self
		add_child(coedit)
	var d = AcceptDialog.new(); d.title = "EDIT TOGETHER"; d.ok_button_text = "CLOSE"
	var v = VBoxContainer.new(); v.custom_minimum_size = Vector2(420, 0); d.add_child(v)
	var info = Label.new(); info.autowrap_mode = TextServer.AUTOWRAP_WORD; info.add_theme_font_size_override("font_size", 10)
	info.text = "One of you HOSTS, the others JOIN with the host's address (LAN or Hamachi IPv4, port 7778). Everyone sees the others' mouse and every change as it happens. Events, shops, sprites and your own maps go across when they are saved. Everyone presses SAVE for their own copy. Joining gives you the host's world (yours goes to CHECK > HISTORY first)."
	v.add_child(info)
	var nm = LineEdit.new(); nm.placeholder_text = "your name"; nm.text = Game.lobby_name() if coedit.my_name == "MAKER" else coedit.my_name; v.add_child(nm)
	var hb = HBoxContainer.new(); v.add_child(hb)
	var hostb = Button.new(); hostb.text = "HOST"; hb.add_child(hostb)
	var ip = LineEdit.new(); ip.placeholder_text = "host address, e.g. 25.12.34.56"; ip.text = str(Game.cfg.get("dev_join_ip", "")); ip.size_flags_horizontal = Control.SIZE_EXPAND_FILL; hb.add_child(ip)
	var joinb = Button.new(); joinb.text = "JOIN"; hb.add_child(joinb)
	var leaveb = Button.new(); leaveb.text = "LEAVE"; hb.add_child(leaveb)
	var st = Label.new(); st.autowrap_mode = TextServer.AUTOWRAP_WORD; st.add_theme_font_size_override("font_size", 10); st.add_theme_color_override("font_color", Color(1, 0.9, 0.55)); v.add_child(st)
	var who = ItemList.new(); who.custom_minimum_size = Vector2(0, 120); v.add_child(who)
	var show = func():
		if not is_instance_valid(st):
			return
		st.text = coedit.state if coedit.state != "" else "Not connected."
		who.clear()
		for id in coedit.people:
			var p: Dictionary = coedit.people[id]
			who.add_item("%s%s   %s" % [str(p["name"]), "  (you)" if int(id) == coedit.my_id else "", str(p.get("key", ""))])
			who.set_item_custom_fg_color(who.item_count - 1, coedit.COLORS[int(p.get("color", 0)) % coedit.COLORS.size()])
	coedit.changed.connect(show)
	hostb.pressed.connect(func(): coedit.host(nm.text))
	joinb.pressed.connect(func():
		Game.cfg["dev_join_ip"] = ip.text.strip_edges()
		coedit.join(ip.text, nm.text))
	leaveb.pressed.connect(func(): coedit.leave())
	d.confirmed.connect(func(): d.queue_free())
	d.canceled.connect(func(): d.queue_free())
	d.tree_exiting.connect(func():
		if coedit.changed.is_connected(show):
			coedit.changed.disconnect(show))
	add_child(d)
	show.call()
	d.popup_centered()

## HELP - FIRST MAP: the step by step guide (bottom left, over the little map)
var tutorial: Control
func start_tutorial() -> void:
	if is_instance_valid(tutorial):
		tutorial.queue_free()
	_show_tab("MAP")
	tutorial = preload("res://scripts/dev_tutorial.gd").new()
	tutorial.dev = self
	ui.add_child(tutorial)
	tutorial.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	tutorial.grow_vertical = Control.GROW_DIRECTION_BEGIN
	tutorial.position = Vector2(8, ui.size.y - 8 - 200)
	tutorial.resized.connect(func():
		if is_instance_valid(tutorial):
			tutorial.position.y = ui.size.y - 8 - tutorial.size.y)

const TIPS = [
	"New here? HELP > FIRST MAP walks you through making a map, step by step.",
	"Right mouse drag or WASD moves around, the wheel zooms. VIEW > THE WHOLE WORLD shows all of Earth.",
	"SMART paints ground and fits the edges to what is around it - try it on grass next to a path.",
	"PICK takes the tile under the mouse into your brush. THINGS has trees, houses and rocks to stamp.",
	"LINE and RECT draw straight lines and boxes of tiles or walls.",
	"ZONE makes a field where foes keep coming back - set the kinds, how many and how fast.",
	"EVENT boxes start an event when someone walks in. Make the event in the EVENTS tab.",
	"PLAY HERE puts you in the game right where you are looking. F10 in the game comes back.",
	"CHECK looks over everything for mistakes - doors into walls, missing items, events with broken jumps.",
	"Every SAVE is kept in CHECK > HISTORY. RESTORE goes back if something went wrong.",
	"SHARE turns your work into a mod .zip that others drop into their modpacks folder.",
	"TOGETHER: friends can build the same world with you over LAN or Hamachi, live.",
	"CHANGES on the top bar shows every cell your team changed. Mods that touch the same cells are listed in SHARE.",
	"SPRITES imports your own character sheets (PNG) and lets you fix each frame of an animation.",
	"COLORS recolours any sprite set or the tiles - and makes new looks from old ones, like a night-time version.",
	"MOVES > BUILD A MOVE makes a new special move with a moving preview.",
	"Talking people can run shops: make one in SHOPS, then pick it with the PERSON tool.",
	"OTHER GAMES reads Buu's Fury and The Legacy of Goku maps from your own cartridges - copy from them.",
]
func _help_menu(i: int) -> void:
	if i == 0:
		_show_help()
	elif i == 1:
		start_tutorial()
	else:
		_tip()

func _tip() -> void:
	_say("TIP: " + TIPS[randi() % TIPS.size()])
