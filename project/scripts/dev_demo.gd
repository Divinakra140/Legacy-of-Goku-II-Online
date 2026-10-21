extends Node
## The DEV TOOLS tutorial: drives the tools by itself (a pointer moves, clicks and drags) with captions,
## for the tutorial video of v34 (LoG2Coop.exe -- --devtools --devdemo).

var dev
var cap: Label
var sub: Label
var cursor: Polygon2D
var click_ring = 0.0
var layer: CanvasLayer

func _ready() -> void:
	layer = CanvasLayer.new(); layer.layer = 50; add_child(layer)
	var band = ColorRect.new(); band.color = Color(0, 0, 0, 0.72); band.name = "band"
	band.anchor_left = 0; band.anchor_right = 1; band.anchor_top = 1; band.anchor_bottom = 1; band.offset_top = -70; band.offset_bottom = -24
	layer.add_child(band)
	cap = Label.new(); cap.add_theme_font_size_override("font_size", 18); cap.add_theme_color_override("font_color", Color(1, 0.88, 0.35))
	cap.anchor_left = 0; cap.anchor_right = 1; cap.anchor_top = 1; cap.anchor_bottom = 1; cap.offset_top = -68; cap.offset_left = 12
	layer.add_child(cap)
	sub = Label.new(); sub.add_theme_font_size_override("font_size", 12); sub.add_theme_color_override("font_color", Color(0.9, 0.95, 1))
	sub.anchor_left = 0; sub.anchor_right = 1; sub.anchor_top = 1; sub.anchor_bottom = 1; sub.offset_top = -44; sub.offset_left = 12
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD
	layer.add_child(sub)
	cursor = Polygon2D.new()
	cursor.polygon = PackedVector2Array([Vector2(0, 0), Vector2(0, 16), Vector2(4, 12), Vector2(8, 19), Vector2(10, 18), Vector2(7, 11), Vector2(12, 11)])
	cursor.color = Color(1, 1, 1)
	var outline = Line2D.new(); outline.points = cursor.polygon; outline.closed = true; outline.width = 1.5; outline.default_color = Color(0, 0, 0)
	cursor.add_child(outline)
	cursor.position = Vector2(400, 300)
	layer.add_child(cursor)
	_run()

func _process(_dt: float) -> void:
	if click_ring > 0:
		click_ring -= 1

func w(frames: int) -> void:
	for i in frames:
		await get_tree().process_frame

## move the caption band up (negative) or back to the bottom (0)
func band_y(dy: float) -> void:
	var band = layer.get_node("band")
	band.offset_top = -70 + dy; band.offset_bottom = -24 + dy
	cap.offset_top = -68 + dy; cap.offset_bottom = cap.offset_top + 24
	sub.offset_top = -44 + dy; sub.offset_bottom = sub.offset_top + 20

func say(a: String, b: String = "") -> void:
	if OS.get_environment("DEMO_NOCAP") != "":      # (trailer footage: no captions)
		layer.get_node("band").visible = false; cap.visible = false; sub.visible = false
		return
	cap.text = a
	sub.text = b

## the pointer glides to a screen point
func move_to(p: Vector2, frames: int = 24) -> void:
	var s = cursor.position
	for i in frames:
		var k = float(i + 1) / frames
		k = k * k * (3 - 2 * k)
		cursor.position = s.lerp(p, k)
		await get_tree().process_frame

## a map cell's place on the screen
func scr(cell: Vector2) -> Vector2:
	return dev.get_canvas_transform() * (cell * 8.0 + Vector2(4, 4))

func click_button(text: String) -> void:
	var b = _find_button(dev.ui, text)
	if b == null:
		b = _find_button(dev.editors, text)
	if b == null:
		return
	await move_to(b.get_global_rect().get_center(), 18)
	await w(6)
	b.emit_signal("pressed") if not b.toggle_mode else b.emit_signal("pressed")
	if b.toggle_mode:
		b.button_pressed = true
	await w(10)

func _find_button(n: Node, text: String) -> Button:
	if n is Button and n.text == text and n.is_visible_in_tree():
		return n
	for c in n.get_children():
		var r = _find_button(c, text)
		if r:
			return r
	return null

func pan_to(world_p: Vector2, frames: int = 60) -> void:
	var s = dev.cam.position
	for i in frames:
		var k = float(i + 1) / frames
		k = k * k * (3 - 2 * k)
		dev.cam.position = s.lerp(world_p, k)
		await get_tree().process_frame

## the pointer drags from one cell to another (the box or line shows as it goes)
func drag_cells(a: Vector2, b: Vector2, frames: int = 24) -> void:
	await move_to(scr(a), 14)
	dev.dragging = true; dev.drag_from = Vector2i(a)
	for i in frames:
		var c = a.lerp(b, float(i + 1) / frames)
		cursor.position = scr(c)
		dev.mouse_cell = Vector2i(c)
		await w(1)
	dev.dragging = false

func zoom_to(z: float, frames: int = 30) -> void:
	var s = dev.cam.zoom.x
	for i in frames:
		var k = float(i + 1) / frames
		k = k * k * (3 - 2 * k)
		dev.cam.zoom = Vector2.ONE * lerpf(s, z, k)
		await w(1)

func button_at(text: String) -> Vector2:
	var b = _find_button(dev.ui, text)
	return b.get_global_rect().get_center() if b else cursor.position

func _run() -> void:
	await w(5)
	Game.cfg["dev_view"] = Vector2i(960, 540)      # the video: 960 x 540 pixels, shown at 1080p
	get_parent().dev._fit()
	await w(25)
	dev = get_parent().dev
	var start = Vector2(8088, 9632)
	var p0 = Vector2(8200, 9500)
	dev.cam.position = start
	dev.cam.zoom = Vector2(2, 2)
	dev.show_walls = false
	say("DEV TOOLS - WHAT'S NEW IN v34", "Make maps, events, shops, characters and mods for LoG2 Online. No programming. Main menu - DEV TOOLS.")
	await w(150)

	# ---------------------------------------------------------------- help
	say("NEW HERE? HELP > FIRST MAP", "A guide walks you through your first map, step by step. Each step ticks itself off when you do it.")
	await move_to(button_at("HELP"), 30)
	await w(15)
	dev.start_tutorial()
	await w(150)
	say("TIPS", "A tip shows each time you open the tools - and every tool explains itself when you point at it.")
	dev._tip()
	await w(110)
	if is_instance_valid(dev.tutorial):
		dev.tutorial.queue_free()
	await w(10)

	# ---------------------------------------------------------------- the whole world
	say("THE WHOLE WORLD", "VIEW > THE WHOLE WORLD (or zoom far out): all of Earth with the place names. Click a place to go there.")
	await move_to(button_at("VIEW ▾"), 20)
	await w(10)
	dev._world_view()
	await w(130)
	await move_to(scr(start / 8.0), 30)
	await w(20)
	for i in 60:
		var k = float(i + 1) / 60.0
		k = k * k * (3 - 2 * k)
		dev.cam.zoom = Vector2.ONE * lerpf(dev.cam.zoom.x, 2.0, k * 0.35)
		dev.cam.position = dev.cam.position.lerp(start, k * 0.35)
		await w(1)
	dev.cam.position = start; dev.cam.zoom = Vector2(2, 2)
	await w(30)
	say("SEE UNDER THE ROOFS", "VIEW > SHOW LAYER: hide the layers drawn over the heroes (3 and 4) to work under roofs and tree tops.")
	dev.layer_shown[3] = false; dev.layer_shown[4] = false
	await w(90)
	dev.layer_shown[3] = true; dev.layer_shown[4] = true
	await w(30)

	# ---------------------------------------------------------------- smart brush, line, rect
	var lake = Vector2(1206, 1393) * 8.0
	dev.cam.position = lake; dev.cam.zoom = Vector2(1, 1)
	var a0 = dev.area
	var tw = int(a0["tw"])
	var wi = 1000 * tw + 2079
	dev.brush_cell = dev.cell_at(wi % tw, wi / tw)
	say("SMART BRUSH", "Paint water, sand or a path - when you let go it picks the game's own edge pieces so everything joins up.")
	await click_button("SMART")
	await w(20)
	var c0 = Vector2(1222, 1386)
	await move_to(scr(c0), 20)
	dev.drag_from = Vector2i(c0)
	dev._press(Vector2i(c0), c0 * 8.0)
	for dy in 5:
		for dx in 8:
			var c = c0 + Vector2(dx if dy % 2 == 0 else 7 - dx, dy)
			cursor.position = scr(c)
			dev._drag(Vector2i(c), Vector2.ZERO)
			await w(1)
	dev._release(Vector2i(c0 + Vector2(7, 4)), Vector2.ZERO)
	await w(90)
	say("LINE AND RECT", "Straight lines and boxes of tiles, whole cells, walls or ground - filled or just the edge.")
	dev.show_walls = true
	await click_button("RECT")
	dev.shape_brush = "WALL"; dev.rect_filled = false
	await drag_cells(c0 + Vector2(-3, -3), c0 + Vector2(12, 8))
	dev._release(Vector2i(c0 + Vector2(12, 8)), Vector2.ZERO)
	await w(60)
	dev.show_walls = false
	await w(20)

	# ---------------------------------------------------------------- things
	dev.cam.position = start; dev.cam.zoom = Vector2(1.5, 1.5)
	say("THINGS", "Whole trees, houses, rocks, fences - FIND THINGS IN VIEW cuts them from the map, one click sets one down.")
	await click_button("THINGS")
	await w(20)
	await click_button("FIND THINGS IN VIEW")
	await w(40)
	var tc = Vector2(int(start.x / 8) - 30, int(start.y / 8) + 14)
	for k in mini(3, dev.stamps.size()):
		dev.stamp_i = k
		dev._refresh_side()
		await w(25)
		var c = tc + Vector2(k * 12, 0)
		await move_to(scr(c), 16)
		dev._press(Vector2i(c), c * 8.0)
		await w(30)
	await w(30)

	# ---------------------------------------------------------------- events
	say("EVENTS", "Little scripts with no programming: who starts it, then the steps - talk, choices, gifts, missions, warps...")
	await click_button("EVENTS")
	await w(30)
	var ed = dev.panels["EVENTS"]
	ed._new()
	var e = ed._ev()
	e["id"] = "old_man"; e["name"] = "THE OLD MAN"
	e["trigger"] = {"type": "talk", "person": "OLD MAN"}
	e["steps"] = []
	ed._choose(ed.cur)
	await w(40)
	var steps = [
		{"do": "say", "who": "OLD MAN", "text": "Ah, %s! I have waited a long time for someone strong to come by. The foes in the field keep coming back every night, and my old legs cannot run from them any more. The whole village is afraid."},
		{"do": "choice", "who": "OLD MAN", "text": "Will you help an old man?", "options": [["YES", "yes"], ["NO", "no"]]},
		{"do": "label", "name": "yes"}, {"do": "give", "item": "senzu", "count": 2}, {"do": "zeni", "amount": 100},
		{"do": "say", "who": "OLD MAN", "text": "Take these. Good luck!"}, {"do": "end"},
		{"do": "label", "name": "no"}, {"do": "say", "who": "OLD MAN", "text": "Come back when you are ready."}]
	for i in steps.size():
		e["steps"].append(steps[i])
		ed._fill_steps()
		ed._choose_step(i)
		await w(22 if i > 0 else 60)
	say("TOO LONG FOR THE TEXT BOX?", "Every line is checked: SPLIT INTO BOXES THAT FIT cuts it into boxes the game can show.")
	ed._choose_step(0)
	await w(70)
	await move_to(button_at("SPLIT INTO BOXES THAT FIT"), 18)
	await w(8)
	ed._split_say(e["steps"][0])
	ed._fill_steps()
	ed._choose_step(0)
	await w(60)
	ed._save()
	await w(20)
	say("SHOPS AND LOOT", "A shop: what it sells and the price - give it to a person. LOOT: what each kind of foe drops.")
	await click_button("SHOPS")
	await w(80)
	await click_button("LOOT")
	await w(70)

	# ---------------------------------------------------------------- people, zones, event boxes
	await click_button("MAP")
	dev.cam.position = p0; dev.cam.zoom = Vector2(2, 2)
	await w(20)
	say("PEOPLE WITH EVENTS AND SHOPS", "PERSON: a name, a look, their lines - and an EVENT that starts when you talk, or a SHOP they keep.")
	await click_button("PERSON")
	dev.person_name = "OLD MAN"; dev.person_set = 54; dev.person_event = "old_man"; dev.person_shop = ""
	dev._refresh_side()
	await w(50)
	var pc = (p0 + Vector2(20, 0)) / 8.0
	await move_to(scr(pc), 16)
	dev._press(Vector2i(pc), p0 + Vector2(20, 0))
	await w(30)
	dev.person_name = "MERCHANT"; dev.person_event = ""; dev.person_shop = "kame_shop"
	dev._refresh_side()
	await w(40)
	var pc2 = (p0 + Vector2(-30, 0)) / 8.0
	await move_to(scr(pc2), 16)
	dev._press(Vector2i(pc2), p0 + Vector2(-30, 0))
	dev.person_shop = ""
	await w(40)
	say("ZONES", "ZONE: a field where foes keep coming back - which kinds, how many, their level, how fast they return.")
	await click_button("ZONE")
	dev.zone_cfg = {"kinds": "8", "count": 3, "level": 3, "respawn": 20}
	dev._refresh_side()
	await w(30)
	var za = p0 / 8.0 + Vector2(-10, 6)
	var zb = p0 / 8.0 + Vector2(10, 14)
	await drag_cells(za, zb)
	dev._release(Vector2i(zb), p0)
	await w(60)
	say("EVENT BOXES", "EVENT: walking into the box starts an event - a cutscene at a door, a trap, a warning.")
	await click_button("EVENT")
	dev.event_id = "old_man"
	dev._refresh_side()
	await w(20)
	var ea = p0 / 8.0 + Vector2(-14, -8)
	var eb = p0 / 8.0 + Vector2(-9, -4)
	await drag_cells(ea, eb, 16)
	dev._release(Vector2i(eb), eb * 8.0)
	await w(50)
	await click_button("SAVE")
	await w(30)

	# ---------------------------------------------------------------- play here
	say("PLAY HERE", "Try it at once: the game starts right where you are looking. F10 brings you back to the same spot.")
	await move_to(button_at("PLAY HERE"), 20)
	await w(30)
	dev.play_here(p0, {"god": true, "level": 10})
	band_y(-150)         # in the game: the captions up top, the game's own text box stays free
	await w(70)
	var world = get_parent().world
	if world and world.locals.size() > 0:
		var L = world.locals[0]
		var people = L.area["people"]
		var ti = -1
		for i in people.size():
			if str(people[i]["name"]) == "OLD MAN":
				ti = i
		say("YOUR EVENT IN THE GAME", "Talk to the old man: his lines, the choice, the gifts - just as you made them.")
		await w(40)
		if ti >= 0:
			world.events_rt.on_talk(L, people[ti])
			for k in 140:
				var press = k % 30 == 29
				world.events_rt.tick(L, {"a": press})
				if L.ev.is_empty():
					break
				await w(1)
		await w(60)
		say("...AND THE SHOP", "The merchant keeps the shop you gave him.")
		world._open_shop(L, "kame_shop")
		await w(110)
		world._menu_close(L)
		await w(20)
	say("BACK TO THE TOOLS", "F10: back in the tools, right where you were.")
	await w(30)
	get_parent().back_to_tools()
	band_y(0)
	await w(40)
	dev = get_parent().dev
	await w(40)

	# ---------------------------------------------------------------- sprites
	say("SPRITES: YOUR OWN CHARACTERS", "IMPORT a PNG: one row per pose and direction. GBA colours make it look like the game. It becomes a sprite set.")
	await click_button("SPRITES")
	await w(30)
	var sp = dev.panels["SPRITES"]
	sp.load_sheet("/LoG2_Godot_Coop/fighter_sheet.png")
	await w(60)
	sp.opt["colours"] = 12
	await click_button("MAKE THE SPRITE SET")
	await w(120)
	say("ANIMATIONS", "Fix any animation frame by frame - move a frame, reorder, double, mirror, take frames from other sets.")
	sp.mode = "ANIMATIONS"; sp.set_id = 60
	sp.slots = sp.load_frames(60); sp.anim = 1; sp.dir = 0; sp.frame_i = 0
	sp._apply_preview(); sp._rebuild()
	await w(130)

	# ---------------------------------------------------------------- colours, moves
	say("COLOUR PRESETS", "One click for a whole new look - NIGHT, AUTUMN, SNOW, NAMEK, GHOST... for any sprite set or the tiles.")
	await click_button("COLORS")
	await w(20)
	var ce = dev.panels["COLORS"]
	ce.set_spin.value = 4000
	ce._open_set()
	await w(30)
	for k in range(1, mini(6, ce.preset_pick.item_count)):
		ce.preset_pick.select(k)
		ce._apply_preset()
		await w(40)
	say("BUILD A MOVE", "MOVES > BUILD A MOVE: a beam, a ball, a volley, a dash... its numbers and colour, with a moving preview.")
	await click_button("MOVES")
	await w(20)
	await click_button("BUILD A MOVE")
	await w(20)
	var mbs = dev.editors.get_children().filter(func(c): return c is AcceptDialog)
	if mbs.size() > 0:
		var d = mbs[-1]
		for k in ["beam", "volley", "wave", "bomb"]:
			d.mv["type"] = k
			d.mv["color"] = {"beam": "7fd8ff", "volley": "ffd27f", "wave": "b07fff", "bomb": "ff7f7f"}[k]
			d.desc.text = d.KINDS[k]
			await w(70)
		d.queue_free()
	await w(20)

	# ---------------------------------------------------------------- check and history
	var bad = Vector2.ZERO
	for r in range(10, 300, 6):
		for k in 24:
			var q = p0 + Vector2.from_angle(k * TAU / 24.0) * r
			if not Assets.walkable(dev.area, q.x, q.y):
				bad = q
				break
		if bad != Vector2.ZERO:
			break
	Mods.patch("land/0/0")["enemies_add"].append([8, 0, snappedf(bad.x, 1), snappedf(bad.y, 1), 3])
	say("CHECK", "CHECK EVERYTHING finds mistakes before others do: doors into walls, foes stuck in walls, missing things...")
	await click_button("CHECK")
	await w(30)
	await click_button("CHECK EVERYTHING")
	await w(80)
	var ck = dev.panels["CHECK"]
	say("GO THERE", "Choose one and GO THERE - the map opens right on it.")
	if ck.list.item_count > 0:
		ck.list.select(0)
		await w(30)
		await click_button("GO THERE")
		await w(90)
	await click_button("CHECK")
	say("HISTORY", "Every SAVE keeps a copy. RESTORE goes back if something went wrong - and that can be undone too.")
	await w(20)
	await click_button("BACK UP NOW")
	await w(80)

	# ---------------------------------------------------------------- mods
	say("SHARE: MAKE A MOD", "Name it, and MAKE THE MOD FILE - only what your team changed goes into the .zip. Send it to anyone.")
	await click_button("SHARE")
	await w(30)
	var sh = dev.panels["SHARE"]
	if sh.fields.has("name"):
		sh.fields["name"].text = "Old Man's Field"
		sh.fields["author"].text = "our team"
	await w(50)
	await click_button("MAKE THE MOD FILE")
	await w(80)
	say("MODS STACK", "ADD A MOD, switch mods on and off, choose their order. Three example mods come with the game to learn from.")
	await w(130)

	# ---------------------------------------------------------------- together
	await click_button("MAP")
	dev.cam.position = p0 + Vector2(0, 40); dev.cam.zoom = Vector2(2, 2)
	await w(20)
	say("TOGETHER", "Build the same world with friends at the same time over LAN or Hamachi: HOST, the others JOIN.")
	await move_to(button_at("TOGETHER"), 20)
	await w(10)
	dev._together_dialog()
	var co = dev.coedit
	co.my_id = 1
	co.people = {1: co._person("YOU", 0), 2: co._person("KAI", 1), 3: co._person("MIRA", 2)}
	co.people[2]["key"] = dev.key; co.people[3]["key"] = dev.key
	co.state = "Hosting on port 7778. Editing together with 2 others."
	co.changed.emit()
	await w(120)
	for c in dev.get_children():
		if c is AcceptDialog:
			c.queue_free()
	say("SEE EACH OTHER WORK", "Everyone's pointer with their name, and every change the moment it is made.")
	var base = (p0 + Vector2(0, 40)) / 8.0
	var tw2 = int(dev.area["tw"])
	for k in 120:
		var f2 = base + Vector2(-14 + k * 0.2, 4 + sin(k * 0.1) * 2)
		var f3 = base + Vector2(10 - k * 0.1, -6 + cos(k * 0.08) * 3)
		co.people[2]["x"] = f2.x * 8; co.people[2]["y"] = f2.y * 8; co.people[2]["tool"] = "WALL"; co.people[2]["seen"] = Time.get_ticks_msec()
		co.people[3]["x"] = f3.x * 8; co.people[3]["y"] = f3.y * 8; co.people[3]["tool"] = "PERSON"; co.people[3]["seen"] = Time.get_ticks_msec()
		if k % 6 == 0:
			var ci = int(f2.y) * tw2 + int(f2.x)
			var v = dev.cell_at(int(f2.x), int(f2.y)); v[5] = 0
			co._got_cells(dev.key, {ci: v})
		cursor.position = scr(base + Vector2(sin(k * 0.05) * 6, 8))
		co.cursors.visible = true
		co.cursors.queue_redraw()
		await w(1)
	dev.show_walls = true
	co.cursors.queue_redraw()
	await w(40)
	co.people.clear()
	co.cursors.queue_redraw()
	dev.show_walls = false

	# ---------------------------------------------------------------- the end
	dev.cam.position = start; dev.cam.zoom = Vector2(2, 2)
	say("THAT'S v34", "Read DEV TOOLS.txt for every tool. Start with HELP > FIRST MAP - and have fun building!")
	await w(180)
	get_tree().quit()
