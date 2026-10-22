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
const TOOLS = ["PAN", "TILE", "SMART", "STAMP", "ERASE", "PICK", "WALL", "GROUND", "LINE", "RECT", "FILL", "SELECT", "COPY", "PASTE", "THINGS", "FOE", "ZONE", "PERSON", "ITEM", "DOOR", "EVENT", "MOOD"]
const TOOL_HELP = {
	"PAN": "Drag to move around (or right / middle mouse anywhere, WASD, arrows). Wheel: zoom.",
	"TILE": "Paint the tile chosen on the right onto the chosen LAYER. Ground layer 0, over the heroes 3-4.",
	"STAMP": "Paint a whole cell (all 5 layers and its wall) - pick one with PICK first.",
	"ERASE": "Take the tile away from the chosen LAYER.",
	"PICK": "Click a cell: it becomes the brush (all layers) - then STAMP paints it. Also picks the tile for TILE.",
	"WALL": "Paint where you cannot walk (red when WALLS is on).",
	"GROUND": "Paint where you can walk.",
	"SELECT": "Click a foe, person, treasure or door: change or delete it on the right. Drag to move it.",
	"COPY": "Drag a box: those cells (all layers and walls) go to the clipboard - then PASTE.",
	"PASTE": "Click: the clipboard is laid down there (its top-left corner at the mouse). Move whole places this way.",
	"FILL": "Drag a box: filled with the brush (the tile on the layer, or the picked cell if STAMP was last).",
	"FOE": "Click: a foe of the kind chosen on the right.",
	"PERSON": "Click: a person who says the lines written on the right.",
	"ITEM": "Click: treasure (an item lying there until someone takes it).",
	"DOOR": "Drag the door's box, then click where it takes you (switch maps first with GO TO MAP to arrive elsewhere).",
	"SMART": "PICK the ground first (water, sand, a path...), then paint: when you let go its edges are joined up the way the game's own maps join them.",
	"LINE": "Drag: a straight line of the brush (tile, picked cell, wall or ground - see the right).",
	"RECT": "Drag: a box of the brush, filled or just its outline.",
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
var ui: Control
var tool = "PAN"
var layer = 0
var brush_tile = 1              # TILE tool: a tile id
var brush_cell = [0, 0, 0, 0, 0, 1]   # STAMP: a whole cell + walk
var last_brush = "TILE"
var show_walls = true
var show_changes = false
var _last_look = []              # what the overlay was last drawn for
var _redraw_t = 0.0
var _changes = []          # [[layer name, {"x,y": cell}]] for the CHANGES view
var show_grid = false
var show_objects = true
var sel_from = Vector2.ZERO        # SELECT: where the click began
var keep_ground = false          # PASTE / THINGS: the ground already there stays (the copy's background is left out)
var clipboard = {}              # {w, h, cells: [[6 values]...]}
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
var paint_size = 1               # TILE / STAMP / ERASE / WALL / GROUND: the brush is this many cells across
var paint_last = Vector2i(-1, -1)   # the cell painted last in this drag (the stroke is joined up from it)
var shape_brush = "TILE"     # LINE / RECT paint with: TILE, CELL, WALL, GROUND
var rect_filled = true
var stamps = []              # THINGS: the list shown (saved ones + found in view)
var stamp_i = -1
var minimap: Control
var mini_tex: Texture2D
var layer_shown = [true, true, true, true, true]
const FAR_ZOOM = 0.3          # zoomed out further: the map as one picture (THE WHOLE WORLD), names of the places on it
var world_sprite: Sprite2D
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
		w[i] = int(changes[i][which][5]) & 1
	area["walk"] = w
	var p = Mods.patch(key)
	for i in changes:
		var v = changes[i][which]
		p["cells"]["%d,%d" % [i % tw, i / tw]] = v.duplicate()
		var x = i % tw; var y = i / tw
		for k in 5:
			var tl: TileMapLayer = tiles[k]
			var c = int(v[k])
			var r = Assets.kit_cell(c) if c != 0 else []
			if r.is_empty():
				tl.erase_cell(Vector2i(x, y))
			else:
				tl.set_cell(Vector2i(x, y), r[2], r[0], r[1])

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
	if u.has("cells"):
		_write(u["cells"], side)
		return u
	var p = Mods.patch(key)
	var now = {}
	for k in u["patch"]:
		now[k] = p[k].duplicate(true)
		p[k] = u["patch"][k]
	_rebuild_world()
	return {"patch": now}

func _remember_patch() -> void:
	var p = Mods.patch(key)
	var snap = {}
	for k in ["enemies_add", "enemies_del", "people_add", "people_del", "doors_add", "doors_del", "items"]:
		snap[k] = p[k].duplicate(true)
	undo.append({"patch": snap})
	redo.clear()

## foes, people and doors changed: the world is put together again (the planet's lists, the map's people)
func _rebuild_world() -> void:
	Game.planet.build_land(0, 1)
	if key.begins_with("land/"):
		# people: the game's own again, then the changes
		var parts = key.split("/")
		var fresh = Assets._land_area(key)
		area["people"] = fresh.get("people", [])
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

func save() -> void:
	end_stroke()
	if area.has("library"):
		dirty = false
		return
	Mods.backup()
	var ok = Mods.save_patch(key)
	if area.has("custom"):
		ok = ok and Mods.save_custom(str(area["custom"]), area)
	dirty = false
	_say("Saved to mods/maps (your team's changes stay when the game is imported again)." if ok else "Could not save - is the game folder read-only?")

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
		elif mb.button_index == MOUSE_BUTTON_LEFT and cam.zoom.x < FAR_ZOOM:
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
		"TILE", "STAMP", "ERASE", "WALL", "GROUND":
			_paint_brush(c)
			paint_last = c
		"SMART":
			if int(brush_cell[0]) == 0:
				_say("PICK the ground to paint first (click PICK, then a water / sand / path cell).")
				return
			smart_mask = {}
			_smart_add(c)
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
				_set_tool("STAMP")
				_say("Picked: layers %s, %s. STAMP paints it; TILE paints tile %d." % [str(brush_cell.slice(0, 5)), "walkable" if int(brush_cell[5]) & 1 else "wall", brush_tile])
		"PASTE":
			_paste(c)
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
			_rebuild_world()
			_say("%s placed." % person_name)
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
	match tool:
		"TILE", "STAMP", "ERASE", "WALL", "GROUND":
			for q in _cells_between(paint_last, c):      # a quick mouse skips cells: the line between is painted too
				_paint_brush(q)
			paint_last = c
		"SMART":
			for q in _cells_between(paint_last, c):
				_smart_add(q)
			paint_last = c
		"SELECT":
			if not selected.is_empty():
				selected["drag_to"] = _w
	overlay.queue_redraw()

func _release(c: Vector2i, w: Vector2) -> void:
	paint_last = Vector2i(-1, -1)
	match tool:
		"TILE", "STAMP", "ERASE", "WALL", "GROUND":
			end_stroke()
		"SMART":
			if not smart_mask.is_empty():
				_say("Joining the edges up (learning from the game's maps the first time)...")
				var n = MT.smart_fill(self, smart_mask, brush_cell)
				end_stroke()
				smart_mask = {}
				_say("Painted, %d edge cells joined up. Ctrl+Z undoes." % n)
		"LINE", "RECT":
			if drag_from.x >= 0:
				var cs = MT.line_cells(drag_from, c) if tool == "LINE" else MT.rect_cells(drag_from, c, rect_filled)
				for q in cs:
					_shape_put(q)
				end_stroke()
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
			_copy(drag_from, c)
		"FILL":
			_fill(drag_from, c)
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
		"STAMP":
			v = brush_cell.duplicate()
			last_brush = "STAMP"
		"ERASE":
			v[layer] = 0
		"WALL":
			v[5] = 0
		"GROUND":
			v[5] = 1
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

func _shape_put(q: Vector2i) -> void:
	if not _inside(q.x, q.y):
		return
	var i = q.y * int(area["tw"]) + q.x
	var v = stroke[i][1].duplicate() if stroke.has(i) else cell_at(q.x, q.y)
	match shape_brush:
		"TILE": v[layer] = brush_tile
		"CELL": v = brush_cell.duplicate()
		"WALL": v[5] = 0
		"GROUND": v[5] = 1
	put(q.x, q.y, v)

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

func _paste(c: Vector2i) -> void:
	if clipboard.is_empty():
		_say("Copy something first (COPY).")
		return
	_lay(c, int(clipboard["w"]), clipboard["cells"])
	end_stroke()
	_say("Pasted.")

func _fill(a: Vector2i, b: Vector2i) -> void:
	var r = _box(a, b)
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var v = cell_at(x, y)
			if last_brush == "STAMP":
				v = brush_cell.duplicate()
			else:
				v[layer] = brush_tile
			put(x, y, v)
	end_stroke()
	_say("Filled %d x %d." % [r.size.x, r.size.y])

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
		var own = Mods.patch(key)
		for kz in [["zones", "zone"], ["triggers", "trigger"], ["moods", "mood"]]:
			for z in own[kz[0]]:
				var r: Array = z["rect"]
				if w.x >= float(r[0]) and w.x <= float(r[2]) and w.y >= float(r[1]) and w.y <= float(r[3]):
					best = {"kind": kz[1], "obj": z}
	if best.is_empty():
		for ex in ob["doors"]:
			var r: Array = ex["rect"]
			if w.x >= float(r[0]) - 3 and w.x <= float(r[2]) + 3 and w.y >= float(r[1]) - 3 and w.y <= float(r[3]) + 3:
				best = {"kind": "door", "obj": ex}
				break
	return best

func _delete_selected() -> void:
	if selected.is_empty():
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
	_delete_selected()
	undo.pop_back()    # one undo for the whole move (the delete's own is dropped; the add below records it)
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
	if world_sprite:
		world_sprite.visible = far
	for i in tiles.size():
		tiles[i].visible = not far and layer_shown[i]
	if not far:
		_stream()
	# drawn again only when something to see changed (the walls of a whole screen each frame made it slow)
	var look = [cam.position, cam.zoom, mouse_cell, stroke.size(), undo.size(), redo.size(), tool, selected.size(), show_walls, show_grid, show_changes, show_objects, layer, paint_size, door_rect.size(), selected.get("drag_to", Vector2.ZERO)]
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

func _draw_overlay() -> void:
	if area.is_empty() or tab != "MAP":
		return
	if cam.zoom.x < FAR_ZOOM:
		# the whole world: the places' names; a click goes in there
		var font0 = ThemeDB.fallback_font
		var fs0 = int(10.0 / cam.zoom.x)
		var done = {}
		for pt in area["land"].get("parts", []):
			var nm = str(pt[1])
			if nm == "" or done.has(nm):
				continue
			done[nm] = true
			var c: Vector2 = pt[0].get_center()
			_ov_text(font0, c, nm, HORIZONTAL_ALIGNMENT_CENTER, -1, fs0, Color(1, 1, 0.8))
		var ni0 = _node_index()
		if ni0 >= 0:
			for ex in Game.planet.nodes[ni0]["exits"]:
				var r: Array = ex["rect"]
				overlay.draw_circle(Vector2(float(r[0]), float(r[1])), 2.0 / cam.zoom.x, Color(1, 0.9, 0.2))
		return
	var vs = get_viewport_rect().size / cam.zoom
	var x0 = maxi(0, int((cam.position.x - vs.x / 2) / 8)); var y0 = maxi(0, int((cam.position.y - vs.y / 2) / 8))
	var x1 = mini(int(area["tw"]) - 1, int((cam.position.x + vs.x / 2) / 8) + 1); var y1 = mini(int(area["th"]) - 1, int((cam.position.y + vs.y / 2) / 8) + 1)
	var tw: int = area["tw"]
	var walk: PackedByteArray = area["walk"]
	if show_walls and (x1 - x0) * (y1 - y0) < 40000:
		for y in range(y0, y1 + 1):
			var run_x = -1
			for x in range(x0, x1 + 1):
				var i = y * tw + x
				var wv = int(stroke[i][1][5]) if stroke.has(i) else int(walk[i])
				if not (wv & 1):
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
		if o.has("rect"):
			var r: Array = o["rect"]
			overlay.draw_rect(Rect2(float(r[0]) - 2, float(r[1]) - 2, float(r[2]) - float(r[0]) + 4, float(r[3]) - float(r[1]) + 4), Color(0.3, 1, 0.4), false, 2.0 / cam.zoom.x)
		else:
			overlay.draw_arc(Vector2(float(o["x"]), float(o["y"])), 8, 0, TAU, 20, Color(0.3, 1, 0.4), 2.0 / cam.zoom.x)
		if selected.has("drag_to"):
			overlay.draw_circle(selected["drag_to"], 4, Color(0.3, 1, 0.4, 0.6))
	if door_rect.size() == 4:
		overlay.draw_rect(Rect2(float(door_rect[0]), float(door_rect[1]), float(door_rect[2]) - float(door_rect[0]), float(door_rect[3]) - float(door_rect[1])), Color(0.3, 1, 0.4, 0.5))
	if dragging and tool in ["LINE", "RECT"] and drag_from.x >= 0:
		var cs = MT.line_cells(drag_from, mouse_cell) if tool == "LINE" else MT.rect_cells(drag_from, mouse_cell, rect_filled)
		for q in cs:
			overlay.draw_rect(Rect2(Vector2(q) * 8.0, Vector2(8, 8)), Color(0.4, 0.9, 1, 0.35))
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
	if dragging and tool in ["COPY", "FILL", "DOOR", "ZONE", "EVENT", "MOOD"] and drag_from.x >= 0:
		var a = Vector2(mini(drag_from.x, mouse_cell.x), mini(drag_from.y, mouse_cell.y)) * 8.0
		var b = Vector2(maxi(drag_from.x, mouse_cell.x) + 1, maxi(drag_from.y, mouse_cell.y) + 1) * 8.0
		overlay.draw_rect(Rect2(a, b - a), Color(0.4, 0.9, 1, 0.25))
		overlay.draw_rect(Rect2(a, b - a), Color(0.4, 0.9, 1), false, 1.0 / cam.zoom.x)
	if tool == "PASTE" and not clipboard.is_empty() and mouse_cell.x >= 0:
		overlay.draw_rect(Rect2(Vector2(mouse_cell) * 8.0, Vector2(int(clipboard["w"]), int(clipboard["h"])) * 8.0), Color(0.4, 0.9, 1), false, 1.0 / cam.zoom.x)
	if mouse_cell.x >= 0 and tool in ["TILE", "STAMP", "ERASE", "WALL", "GROUND", "PICK"]:
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
	layer_pick.item_selected.connect(func(i): layer = i)
	bar.add_child(layer_pick)
	for t in [["WALLS", "show_walls"], ["GRID", "show_grid"], ["OBJECTS", "show_objects"], ["CHANGES", "show_changes"]]:
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
	# the little map (click: go there)
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

func _minimap_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT or ev is InputEventMouseMotion and ev.button_mask & MOUSE_BUTTON_MASK_LEFT:
		var r = _mini_rect()
		if r.size.x <= 0:
			return
		var p = (ev.position - r.position) / r.size.x * float(area["w"])
		cam.position = p
		minimap.accept_event()

func _refresh_minimap() -> void:
	if area.is_empty() or minimap == null:
		return
	var img = MT.mini_image(area)
	mini_tex = ImageTexture.create_from_image(img) if img != null else null
	minimap.queue_redraw()
	if world_sprite == null:
		world_sprite = Sprite2D.new(); world_sprite.centered = false; world_sprite.z_index = -60
		world_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		add_child(world_sprite)
	world_sprite.texture = mini_tex
	if mini_tex:
		world_sprite.scale = Vector2.ONE * (float(area["w"]) / mini_tex.get_size().x)

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
		tool_buttons[k].button_pressed = k == t
	if t != "DOOR" and t != "SELECT":
		door_rect = []
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
		"TILE", "FILL", "ERASE", "STAMP", "PICK":
			_lab("Tile %d on LAYER %d. Click a tile below. PICK copies a cell from the map." % [brush_tile & 0xFFFF, layer])
			if tool in ["TILE", "ERASE", "STAMP"]:
				_spin(side, "brush size", 1, 32, paint_size, func(v): paint_size = int(v); overlay.queue_redraw())
			var gsel = OptionButton.new()
			gsel.add_item("TILES: LEGACY OF GOKU II"); gsel.set_item_metadata(0, "")
			for g in Assets.LIB_GAMES:
				if Assets.has_library(g):
					gsel.add_item("TILES: " + Assets.LIB_TITLES[g]); gsel.set_item_metadata(gsel.item_count - 1, g)
					if g == pal_game: gsel.select(gsel.item_count - 1)
			gsel.item_selected.connect(func(j): pal_game = str(gsel.get_item_metadata(j)); _refresh_side())
			side.add_child(gsel)
			palette = preload("res://scripts/dev_palette.gd").new()
			palette.game = pal_game
			palette.custom_minimum_size = Vector2(232, 420)
			palette.chosen = brush_tile
			palette.jump_to(brush_tile & 0xFFFF)      # the list opens at the tile chosen (or PICKed)
			palette.picked.connect(func(t): brush_tile = t; last_brush = "TILE"; _set_tool("TILE") if tool in ["PICK", "STAMP"] else _refresh_side())
			side.add_child(palette)
			var jb = HBoxContainer.new(); side.add_child(jb)
			var sp = SpinBox.new(); sp.min_value = 0; sp.max_value = 65535; sp.value = brush_tile & 0xFFFF; sp.prefix = "tile"
			sp.value_changed.connect(func(v): brush_tile = palette.cell_of(int(v)); palette.chosen = brush_tile; palette.jump_to(int(v)))
			jb.add_child(sp)
		"FOE":
			_lab("Choose the foe (weakest at the top): its look, its moves and its own strength. Then its level (0 = its own) and, if you like, another look (a sprite set; Frieza is 48).")
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
				fl.add_item("LV %d   %d HP" % [int(tab["lvl"]), int(tab["hp"])], icon)
				fl.set_item_metadata(fl.item_count - 1, k)
				if k == foe_type:
					fl.select(fl.item_count - 1)
			fl.item_selected.connect(func(j): foe_type = int(fl.get_item_metadata(j)); _update_preview(); _say("Click the map to put this foe there."))
			side.add_child(fl)
			if fl.get_selected_items().size() > 0:
				fl.ensure_current_is_visible.call_deferred()
			var sp = _spin(side, "kind", 0, 127, foe_type, func(v): foe_type = int(v); _update_preview())
			fl.item_selected.connect(func(j): sp.set_value_no_signal(int(fl.get_item_metadata(j))))      # (the number follows the picture)
			_spin(side, "level", 0, 99, foe_lv, func(v): foe_lv = int(v))
			_spin(side, "look (set)", 0, 3999, foe_look, func(v): foe_look = int(v); _update_preview())
			_preview_box()
			_update_preview()
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
				_lab("Click a foe (red), person (blue), treasure (gold) or door (yellow).")
			else:
				var o: Dictionary = selected["obj"]
				_lab(str(selected["kind"]).to_upper() + ": " + JSON.stringify(o).left(300))
				var db = Button.new(); db.text = "DELETE (Del)"; db.pressed.connect(_delete_selected); side.add_child(db)
				_lab("Drag it to move it.")
		"COPY", "PASTE":
			_lab("COPY: drag a box. PASTE: click where its top-left goes. Clipboard: %s" % ("empty" if clipboard.is_empty() else "%d x %d" % [clipboard["w"], clipboard["h"]]))
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
		"LINE", "RECT":
			var ob = OptionButton.new()
			for b in ["TILE", "CELL", "WALL", "GROUND"]:
				ob.add_item({"TILE": "THE TILE (on the layer)", "CELL": "THE PICKED CELL (all layers)", "WALL": "WALLS", "GROUND": "WALKABLE GROUND"}[b])
				ob.set_item_metadata(ob.item_count - 1, b)
				if b == shape_brush: ob.select(ob.item_count - 1)
			ob.item_selected.connect(func(j): shape_brush = str(ob.get_item_metadata(j)))
			side.add_child(ob)
			if tool == "RECT":
				var cb = CheckBox.new(); cb.text = "FILLED"; cb.button_pressed = rect_filled; cb.toggled.connect(func(on): rect_filled = on); side.add_child(cb)
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
			var fb = Button.new(); fb.text = "FIND THINGS IN VIEW"; side.add_child(fb)
			fb.pressed.connect(func():
				var vs = get_viewport_rect().size / cam.zoom
				var r = Rect2i(Vector2i((cam.position - vs / 2) / 8.0), Vector2i(vs / 8.0)).intersection(Rect2i(0, 0, int(area["tw"]), int(area["th"])))
				var found = MT.find_objects(self, r)
				stamps = MT.list_stamps() + found
				stamp_i = -1
				_say("%d things found here (the saved ones first). Choose one, click the map. To keep one: COPY it, SAVE THE COPY AS A THING." % found.size())
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
		"WALL", "GROUND":
			_lab("Red = wall (WALLS on). Paint walls or walkable ground. The game's own walls are kept exactly; change only what you mean to.")
			_spin(side, "brush size", 1, 32, paint_size, func(v): paint_size = int(v); overlay.queue_redraw())
		_:
			_lab(TOOL_HELP.get(tool, ""))

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
