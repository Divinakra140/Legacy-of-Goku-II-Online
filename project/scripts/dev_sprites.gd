extends Control
## DEV TOOLS - SPRITES: IMPORT a picture sheet your team drew as a sprite set of its own (4000 and up), and the
## ANIMATION editor: every pose of any set - frames in order, where each sits, frames taken from other sets.
## Saved in content/sprites (a mod made with SHARE takes them along).

var tools
var built = false
var mode = "IMPORT"
var body: VBoxContainer
var info: Label
var preview: ActorView
var prev_holder: Control
var prev_t = 0
# import
var sheet: Image
var sheet_path = ""
var opt = {"fw": 32, "fh": 32, "feet": 2, "gba": true, "colours": 0, "mirror_left": false, "id": 4000}
# animate
var set_id = 60
var slots = []            # [[{x,y,w,h, img: Image}]]
var anim = 1
var dir = 0
var frame_i = 0
var src = {"set": 1010, "anim": 1, "dir": 0, "frame": 0}

func show_editor() -> void:
	if not built:
		_build()
	_rebuild()

func _build() -> void:
	built = true
	var bg = ColorRect.new(); bg.color = Color(0.07, 0.08, 0.13); bg.set_anchors_preset(Control.PRESET_FULL_RECT); add_child(bg)
	var h = HBoxContainer.new(); h.set_anchors_preset(Control.PRESET_FULL_RECT); h.offset_top = 4; h.offset_left = 4; h.offset_right = -4; h.offset_bottom = -4
	add_child(h)
	var left = VBoxContainer.new(); left.size_flags_horizontal = Control.SIZE_EXPAND_FILL; h.add_child(left)
	var tb = HBoxContainer.new(); left.add_child(tb)
	for m in ["IMPORT", "ANIMATIONS"]:
		var b = Button.new(); b.text = m; b.toggle_mode = true; b.button_pressed = m == mode
		b.pressed.connect(func():
			mode = m
			for c in tb.get_children():
				c.button_pressed = c.text == m
			_rebuild())
		tb.add_child(b)
	info = Label.new(); info.autowrap_mode = TextServer.AUTOWRAP_WORD; info.add_theme_font_size_override("font_size", 10)
	info.add_theme_color_override("font_color", Color(1, 0.9, 0.55)); left.add_child(info)
	var sc = ScrollContainer.new(); sc.size_flags_vertical = Control.SIZE_EXPAND_FILL; sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(sc)
	body = VBoxContainer.new(); body.size_flags_horizontal = Control.SIZE_EXPAND_FILL; sc.add_child(body)
	var rv = VBoxContainer.new(); rv.custom_minimum_size = Vector2(220, 0); h.add_child(rv)
	prev_holder = Control.new(); prev_holder.custom_minimum_size = Vector2(220, 220); rv.add_child(prev_holder)
	var pbg = ColorRect.new(); pbg.color = Color(0.2, 0.32, 0.2); pbg.size = Vector2(220, 220); prev_holder.add_child(pbg)
	preview = ActorView.new(); preview.position = Vector2(110, 170); preview.scale = Vector2(3, 3); prev_holder.add_child(preview)
	var pl = Label.new(); pl.text = "The preview turns and plays the pose."; pl.autowrap_mode = TextServer.AUTOWRAP_WORD; pl.add_theme_font_size_override("font_size", 9); rv.add_child(pl)

func _process(_dt: float) -> void:
	if not visible or preview == null:
		return
	prev_t += 1
	var a = anim if mode == "ANIMATIONS" else 1
	var d = dir if mode == "ANIMATIONS" else (prev_t / 120) % 4
	var fr = preview.frames_of(a, d)
	preview.show_frame(a, d, (prev_t / 8) % maxi(1, fr.size()))

func _lab(t: String, size: int = 10, col: Color = Color(0.9, 0.92, 1)) -> Label:
	var l = Label.new(); l.text = t; l.autowrap_mode = TextServer.AUTOWRAP_WORD; l.add_theme_font_size_override("font_size", size); l.add_theme_color_override("font_color", col)
	body.add_child(l)
	return l

func _spin(parent: Control, label: String, lo: float, hi: float, v: float, cb: Callable) -> SpinBox:
	var r = HBoxContainer.new(); parent.add_child(r)
	var l = Label.new(); l.text = label; l.custom_minimum_size = Vector2(150, 0); l.add_theme_font_size_override("font_size", 10); r.add_child(l)
	var s = SpinBox.new(); s.min_value = lo; s.max_value = hi; s.value = v; s.value_changed.connect(cb); r.add_child(s)
	return s

func _btn(parent: Control, t: String, cb: Callable) -> Button:
	var b = Button.new(); b.text = t; b.add_theme_font_size_override("font_size", 10); b.pressed.connect(cb); parent.add_child(b)
	return b

func _rebuild() -> void:
	for c in body.get_children():
		c.queue_free()
	if mode == "IMPORT":
		_build_import()
	else:
		_build_anim()

# ------------------------------------------------------------------ IMPORT
func _build_import() -> void:
	info.text = "IMPORT: a PNG sheet your team drew. Each ROW is one pose in one direction, in the game's order: pose 0 down, up, left, right, then pose 1 (walking) down, up, left, right... Frames go left to right. A sheet of the game's own (a set's PNG you recoloured or drew over): choose SAME LAYOUT AS SET and its number - every frame lands where the game's has it. Pose 0 stands, 1 walks, 2-4 punches, see DEV TOOLS.txt."
	var hb = HBoxContainer.new(); body.add_child(hb)
	_btn(hb, "CHOOSE THE PNG", _choose_png)
	var pathl = Label.new(); pathl.text = sheet_path.get_file() if sheet_path != "" else "(none yet)"; pathl.add_theme_font_size_override("font_size", 10); hb.add_child(pathl)
	if sheet != null:
		var tr = TextureRect.new(); tr.texture = ImageTexture.create_from_image(sheet); tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE; tr.custom_minimum_size = Vector2(300, 150); tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		body.add_child(tr)
	var lh = HBoxContainer.new(); body.add_child(lh)
	var lc = CheckBox.new(); lc.text = "SAME LAYOUT AS SET"; lc.button_pressed = not layout.is_empty(); lh.add_child(lc)
	var ls = SpinBox.new(); ls.min_value = 0; ls.max_value = 4999; ls.value = int(layout.get("set", 60)); lh.add_child(ls)
	var use_layout = func():
		var j = Assets.json(Assets.set_path(int(ls.value), "json"))
		if j is Dictionary and j.get("slots") is Array:
			layout = j.duplicate(true); layout["set"] = int(ls.value)
			opt["fw"] = int(j["cell"]); opt["fh"] = int(j["cell"])
			info.text = "The layout of set %d: %d poses, each frame where the game has it. MAKE THE SPRITE SET." % [int(ls.value), j["slots"].size() / 4]
		else:
			layout = {}
			info.text = "Set %d is not there." % int(ls.value)
	lc.toggled.connect(func(on):
		if on:
			use_layout.call()
		else:
			layout = {}
			info.text = "Your own layout: one row per pose and direction.")
	ls.value_changed.connect(func(_v):
		if lc.button_pressed:
			use_layout.call())
	if not layout.is_empty():
		_lab("  Using the game's layout (set %s): frame sizes and places come from it." % str(layout.get("set", "?")), 9, Color(0.6, 1, 0.6))
	_spin(body, "frame width (px)", 8, 64, opt["fw"], func(v): opt["fw"] = int(v))
	_spin(body, "frame height (px)", 8, 64, opt["fh"], func(v): opt["fh"] = int(v))
	_spin(body, "feet above the bottom", 0, 32, opt["feet"], func(v): opt["feet"] = int(v))
	var c1 = CheckBox.new(); c1.text = "GBA COLOURS (5 bits a colour, like the game)"; c1.button_pressed = opt["gba"]; c1.toggled.connect(func(on): opt["gba"] = on); body.add_child(c1)
	_spin(body, "at most colours (0: any)", 0, 255, opt["colours"], func(v): opt["colours"] = int(v))
	var c2 = CheckBox.new(); c2.text = "ONLY DOWN, UP, RIGHT ROWS (LEFT = RIGHT MIRRORED)"; c2.button_pressed = opt["mirror_left"]; c2.toggled.connect(func(on): opt["mirror_left"] = on); body.add_child(c2)
	if int(opt["id"]) < 4000 or FileAccess.file_exists(Assets.exe_dir().path_join("content/sprites/set_%d.json" % int(opt["id"]))):
		opt["id"] = _free_id()
	_spin(body, "its sprite set number", 4000, 4999, opt["id"], func(v): opt["id"] = int(v))
	_btn(body, "MAKE THE SPRITE SET", _make_set)

func _free_id() -> int:
	var n = 4000
	while FileAccess.file_exists(Assets.exe_dir().path_join("content/sprites/set_%d.json" % n)):
		n += 1
	return n

func _choose_png() -> void:
	var fd = FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.filters = PackedStringArray(["*.png ; PNG pictures"])
	fd.size = Vector2i(700, 420)
	fd.use_native_dialog = true      # the computer's own file picker
	fd.file_selected.connect(func(p): load_sheet(p); fd.queue_free())
	fd.canceled.connect(func(): fd.queue_free())
	add_child(fd)
	fd.popup_centered()

var layout = {}           # the game's own layout of a sheet (its set_N.json next to the PNG): taken as it is
func load_sheet(p: String) -> void:
	sheet = Image.load_from_file(p)
	sheet_path = p
	layout = {}
	if sheet:
		sheet.convert(Image.FORMAT_RGBA8)
		# a sheet saved by the game (a set's PNG, recoloured or drawn over): its .json tells every frame
		var jp = p.get_basename() + ".json"
		if FileAccess.file_exists(jp):
			var j = Mods.read_json(jp)
			if j is Dictionary and j.get("slots") is Array and int(j.get("cell", 0)) > 0:
				layout = j
				layout["set"] = int(j.get("set", -1))
				opt["fw"] = int(j["cell"]); opt["fh"] = int(j["cell"])
		elif sheet.get_width() % 64 == 0 and sheet.get_height() % 256 == 0 and sheet.get_height() >= 512:
			opt["fw"] = 64; opt["fh"] = 64      # (looks like the game's own sheet: 64 x 64 cells)
	_rebuild()

## the picture's colours: GBA's 32 levels a channel, and at most n colours (k-means), the corner colour see-through
static func reduce_colours(img: Image, gba: bool, n: int) -> Image:
	var out: Image = img.duplicate()
	var w = out.get_width(); var h = out.get_height()
	var key = out.get_pixel(0, 0)
	var cols = []
	for y in h:
		for x in w:
			var c = out.get_pixel(x, y)
			if c.a < 0.5 or (key.a > 0.5 and c.is_equal_approx(key)):
				out.set_pixel(x, y, Color(0, 0, 0, 0))
				continue
			if gba:
				c = Color(roundf(c.r * 31) / 31.0, roundf(c.g * 31) / 31.0, roundf(c.b * 31) / 31.0, 1)
				out.set_pixel(x, y, c)
			cols.append(c)
	if n <= 0 or cols.is_empty():
		return out
	# k-means: n centres from the colours used
	var centres = []
	var step = maxi(1, cols.size() / n)
	for i in n:
		centres.append(cols[mini(i * step, cols.size() - 1)])
	for it in 8:
		var sums = []; var cnt = []
		for i in n:
			sums.append(Vector3.ZERO); cnt.append(0)
		for c in cols:
			var bi = 0; var bd = 99.0
			for i in n:
				var d = Vector3(c.r - centres[i].r, c.g - centres[i].g, c.b - centres[i].b).length_squared()
				if d < bd: bd = d; bi = i
			sums[bi] += Vector3(c.r, c.g, c.b); cnt[bi] += 1
		for i in n:
			if cnt[i] > 0:
				var m = sums[i] / cnt[i]
				centres[i] = Color(m.x, m.y, m.z, 1)
	for y in h:
		for x in w:
			var c = out.get_pixel(x, y)
			if c.a < 0.5:
				continue
			var bi = 0; var bd = 99.0
			for i in n:
				var d = Vector3(c.r - centres[i].r, c.g - centres[i].g, c.b - centres[i].b).length_squared()
				if d < bd: bd = d; bi = i
			out.set_pixel(x, y, centres[bi])
	return out

func _make_set() -> void:
	if sheet == null:
		info.text = "Choose a PNG first."
		return
	if FileAccess.file_exists(Assets.exe_dir().path_join("content/sprites/set_%d.json" % int(opt["id"]))):
		_confirm("Sprite set %d is yours already - make the new one over it?\n(A copy of the old one goes to CHECK - HISTORY.)" % int(opt["id"]), func():
			Mods.backup(true)
			_make_set_now())
		return
	_make_set_now()

func _make_set_now() -> void:
	var img = reduce_colours(sheet, opt["gba"], int(opt["colours"]))
	if not layout.is_empty():
		_make_from_layout(img)
		return
	var fw: int = opt["fw"]; var fh: int = opt["fh"]
	var rows = img.get_height() / fh
	var cols = img.get_width() / fw
	var out_slots = []
	var r = 0
	while r < rows:
		var dirs = [r, r + 1, -1, r + 2] if opt["mirror_left"] else [r, r + 1, r + 2, r + 3]
		for d in 4:
			var row = dirs[d]
			var mirror = false
			if row < 0:
				row = dirs[3]; mirror = true
			var frames = []
			if row < rows:
				for c in cols:
					var fr = img.get_region(Rect2i(c * fw, row * fh, fw, fh))
					if fr.is_invisible():
						continue          # (an empty cell is skipped, the frames after it still count)
					if mirror:
						fr.flip_x()
					frames.append({"x": -fw / 2, "y": -fh + int(opt["feet"]), "w": fw, "h": fh, "img": fr})
			out_slots.append(frames)
		r += 3 if opt["mirror_left"] else 4
	var id: int = opt["id"]
	if save_set(id, out_slots):
		Assets.reload_sets()
		preview.set_sprite_set(Assets.sprite_set(id))
		info.text = "Sprite set %d made (%d poses) in content/sprites. Give it to a hero (HEROES set), a foe kind (ENEMIES set) or a person (PERSON tool)." % [id, out_slots.size() / 4]
		opt["id"] = _free_id()

## a sheet in the game's own layout: every frame where the .json says, with its own place at the feet
func _make_from_layout(img: Image) -> void:
	var C = int(layout["cell"])
	var out_slots = []
	for k in layout["slots"].size():
		var frames = []
		for n in layout["slots"][k].size():
			var f: Dictionary = layout["slots"][k][n]
			var w = clampi(int(f["w"]), 1, C); var h = clampi(int(f["h"]), 1, C)
			if (n + 1) * C > img.get_width() or (k + 1) * C > img.get_height():
				continue
			frames.append({"x": int(f["x"]), "y": int(f["y"]), "w": w, "h": h, "img": img.get_region(Rect2i(n * C, k * C, w, h))})
		out_slots.append(frames)
	var id: int = opt["id"]
	if save_set(id, out_slots):
		Assets.reload_sets()
		preview.set_sprite_set(Assets.sprite_set(id))
		info.text = "Sprite set %d made in the game's own layout (%d poses, every frame where it was). Give it to a hero, a foe kind or a person." % [id, out_slots.size() / 4]
		opt["id"] = _free_id()

## a set from frames with their pictures: content/sprites/set_N.png + .json, like the import's
static func save_set(id: int, sl: Array) -> bool:
	var C = 64
	var maxf = 1
	for s in sl:
		maxf = maxi(maxf, s.size())
	var img = Image.create_empty(C * maxf, C * maxi(1, sl.size()), false, Image.FORMAT_RGBA8)
	var js_slots = []
	for k in sl.size():
		var row = []
		for n in sl[k].size():
			var f: Dictionary = sl[k][n]
			var fi: Image = f["img"]
			img.blit_rect(fi, Rect2i(0, 0, mini(C, fi.get_width()), mini(C, fi.get_height())), Vector2i(n * C, k * C))
			row.append({"x": int(f["x"]), "y": int(f["y"]), "w": mini(C, int(f["w"])), "h": mini(C, int(f["h"]))})
		js_slots.append(row)
	var dir = Assets.exe_dir().path_join("content/sprites")
	DirAccess.make_dir_recursive_absolute(dir)
	if img.save_png(dir.path_join("set_%d.png" % id)) != OK:
		return false
	var fa = FileAccess.open(dir.path_join("set_%d.json" % id), FileAccess.WRITE)
	if fa == null:
		return false
	fa.store_string(JSON.stringify({"set": id, "cell": C, "header": [], "slots": js_slots}))
	fa.close()
	return true

# ------------------------------------------------------------------ ANIMATIONS
## a set's frames, each with its picture (from its sheet)
static func load_frames(id: int) -> Array:
	var j = Assets.json(Assets.set_path(id, "json"))
	var img = Image.load_from_file(Assets.set_path(id, "png")) if FileAccess.file_exists(Assets.set_path(id, "png")) else null
	if j == null or img == null:
		return []
	img.convert(Image.FORMAT_RGBA8)
	var C = int(j["cell"])
	var out = []
	for k in j["slots"].size():
		var row = []
		for n in j["slots"][k].size():
			var f: Dictionary = j["slots"][k][n]
			var w = int(f["w"]); var h = int(f["h"])
			var fr = img.get_region(Rect2i(n * C, k * C, maxi(1, mini(w, C)), maxi(1, mini(h, C))))
			row.append({"x": int(f["x"]), "y": int(f["y"]), "w": w, "h": h, "img": fr})
		out.append(row)
	return out

func _build_anim() -> void:
	info.text = "ANIMATIONS: open a set; choose the pose and direction; change where each frame sits, their order, take frames from other sets. SAVE writes your version to content/sprites (the game's own set stays as it is in the import)."
	var hb = HBoxContainer.new(); body.add_child(hb)
	var sp = _spin(hb, "sprite set", 0, 4999, set_id, func(v): set_id = int(v))
	_btn(hb, "OPEN", func(): slots = load_frames(set_id); frame_i = 0; _apply_preview(); _rebuild())
	if slots.is_empty():
		_lab("Open a set (this game's 0-299, Buu's Fury 1000+, Legacy of Goku 2000+, yours 4000+).")
		return
	var nanim = slots.size() / 4
	var hb2 = HBoxContainer.new(); body.add_child(hb2)
	_spin(hb2, "pose", 0, maxi(0, nanim - 1), anim, func(v): anim = int(v); frame_i = 0; _rebuild())
	var pl = Label.new(); pl.text = POSE_NAMES.get(anim, ""); pl.add_theme_color_override("font_color", Color(1, 0.85, 0.35)); pl.add_theme_font_size_override("font_size", 10); hb2.add_child(pl)
	var dp = OptionButton.new()
	for d in ["DOWN", "UP", "LEFT", "RIGHT"]:
		dp.add_item(d)
	dp.select(dir)
	dp.item_selected.connect(func(i): dir = i; frame_i = 0; _rebuild())
	hb2.add_child(dp)
	var s = anim * 4 + dir
	var frames: Array = slots[s] if s < slots.size() else []
	var il = ItemList.new(); il.max_columns = 12; il.fixed_icon_size = Vector2i(48, 48); il.icon_mode = ItemList.ICON_MODE_TOP
	il.custom_minimum_size = Vector2(400, 90)
	for n in frames.size():
		il.add_item(str(n), ImageTexture.create_from_image(frames[n]["img"]))
	if frame_i < frames.size():
		il.select(frame_i)
	il.item_selected.connect(func(i): frame_i = i; _rebuild())
	body.add_child(il)
	if frame_i < frames.size():
		var f: Dictionary = frames[frame_i]
		_spin(body, "frame %d: x from the feet" % frame_i, -64, 64, f["x"], func(v): f["x"] = int(v); _apply_preview())
		_spin(body, "frame %d: y from the feet" % frame_i, -96, 32, f["y"], func(v): f["y"] = int(v); _apply_preview())
		# the same place for many frames at once
		var cx = HBoxContainer.new(); body.add_child(cx)
		_btn(cx, "COPY X,Y", func(): clip_xy = Vector2i(int(f["x"]), int(f["y"])); has_clip = true; info.text = "Copied x %d, y %d - now PASTE it where you want." % [clip_xy.x, clip_xy.y]; _rebuild())
		if has_clip:
			var pxl = Label.new(); pxl.text = "PASTE x %d y %d TO:" % [clip_xy.x, clip_xy.y]; pxl.add_theme_font_size_override("font_size", 10); cx.add_child(pxl)
			for t in [["ALL FRAMES OF THIS POSE", "pose"], ["THIS POSE, ALL 4 DIRECTIONS", "dirs"], ["EVERY FRAME OF THE SET", "set"]]:
				var tt = t[1]
				_btn(cx, t[0], func(): _apply_xy(tt, false, clip_xy))
		var mv = HBoxContainer.new(); body.add_child(mv)
		var ml = Label.new(); ml.text = "MOVE BY"; ml.add_theme_font_size_override("font_size", 10); mv.add_child(ml)
		var sdx = SpinBox.new(); sdx.min_value = -32; sdx.max_value = 32; sdx.value = nudge.x; sdx.prefix = "x"; sdx.value_changed.connect(func(v): nudge.x = int(v)); mv.add_child(sdx)
		var sdy = SpinBox.new(); sdy.min_value = -32; sdy.max_value = 32; sdy.value = nudge.y; sdy.prefix = "y"; sdy.value_changed.connect(func(v): nudge.y = int(v)); mv.add_child(sdy)
		for t in [["THIS POSE", "pose"], ["ALL 4 DIRECTIONS", "dirs"], ["WHOLE SET", "set"]]:
			var tt2 = t[1]
			_btn(mv, t[0], func(): _apply_xy(tt2, true, nudge))
		var hb3 = HBoxContainer.new(); body.add_child(hb3)
		_btn(hb3, "◀ EARLIER", func(): _move_frame(frames, -1))
		_btn(hb3, "LATER ▶", func(): _move_frame(frames, 1))
		_btn(hb3, "DOUBLE IT", func(): frames.insert(frame_i + 1, _dup(frames[frame_i])); _apply_preview(); _rebuild())
		_btn(hb3, "DELETE", func(): _confirm("Delete frame %d of this pose?" % frame_i, func():
			if frame_i < frames.size():
				frames.remove_at(frame_i)
			frame_i = maxi(0, frame_i - 1); _apply_preview(); _rebuild()))
		_btn(hb3, "MIRROR", func(): (frames[frame_i]["img"] as Image).flip_x(); _apply_preview(); _rebuild())
	var hbp = HBoxContainer.new(); body.add_child(hbp)
	_btn(hbp, "TAKE FRAMES FROM A SET (PICK THEM)...", func(): _picker(frames))
	if frame_i < frames.size():
		_lab("  (click the frames you want - from this set or any other - then ADD or REPLACE)", 9, Color(0.7, 0.8, 0.9))
	var hb4 = HBoxContainer.new(); body.add_child(hb4)
	_btn(hb4, "SAVE", func():
		if save_set(set_id, slots):
			Assets.reload_sets()
			info.text = "Saved: content/sprites/set_%d - the game uses your version now." % set_id
		else:
			info.text = "Could not save.")
	_btn(hb4, "BACK TO THE GAME'S OWN", func(): _confirm("Throw away your version of set %d and go back to the game's own?\nAll your changes to this set are lost (a copy goes to CHECK - HISTORY first)." % set_id, func():
		Mods.backup(true)
		DirAccess.remove_absolute(Assets.exe_dir().path_join("content/sprites/set_%d.png" % set_id))
		DirAccess.remove_absolute(Assets.exe_dir().path_join("content/sprites/set_%d.json" % set_id))
		Assets.reload_sets()
		slots = load_frames(set_id)
		_apply_preview(); _rebuild()
		info.text = "Your version of set %d is gone - the original again (CHECK - HISTORY has a copy)." % set_id))

const POSE_NAMES = {0: "STAND (2nd frame: blink)", 1: "WALK", 2: "HURT", 3: "KNOCKED DOWN", 4: "CHARGE KI", 5: "KI BLAST",
	6: "PUNCH 1", 7: "PUNCH 2", 8: "KICK", 9: "TRANSFORM", 11: "ARMS UP", 12: "LYING", 14: "BORED (standing a while)",
	16: "RUSH", 17: "DEAD", 18: "BEAM CHARGE (kamehameha...)", 19: "BEAM FIRE", 20: "SPIN / FLY BACK"}

## the picker: every pose of a set as pictures - click frames, then ADD them after the chosen frame or REPLACE it
var pick_set = -1
var pick_dir = 0
var picked = []            # [[anim, frame]] in the order clicked
func _picker(frames: Array) -> void:
	if pick_set < 0:
		pick_set = set_id
	pick_dir = dir
	var d = AcceptDialog.new(); d.title = "TAKE FRAMES FROM A SET"; d.ok_button_text = "CLOSE"
	d.size = Vector2i(900, 500)
	var v = VBoxContainer.new(); d.add_child(v)
	var top = HBoxContainer.new(); v.add_child(top)
	var l = Label.new(); l.text = "sprite set"; top.add_child(l)
	var sb = SpinBox.new(); sb.min_value = 0; sb.max_value = 4999; sb.value = pick_set; top.add_child(sb)
	var dp = OptionButton.new()
	for dn in ["DOWN", "UP", "LEFT", "RIGHT"]:
		dp.add_item(dn)
	dp.select(pick_dir); top.add_child(dp)
	var status = Label.new(); status.add_theme_color_override("font_color", Color(1, 0.9, 0.55)); status.add_theme_font_size_override("font_size", 10)
	var sc = ScrollContainer.new(); sc.custom_minimum_size = Vector2(860, 330); sc.size_flags_vertical = Control.SIZE_EXPAND_FILL; v.add_child(sc)
	var rows = VBoxContainer.new(); rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL; sc.add_child(rows)
	var lists = []
	var fill = func():
		for c in rows.get_children():
			c.queue_free()
		lists.clear()
		picked.clear()
		var o = load_frames(pick_set)
		if o.is_empty():
			status.text = "Set %d is not there." % pick_set
			return
		status.text = "Set %d, facing %s. Click frames (Ctrl / Shift: several), then ADD or REPLACE." % [pick_set, ["DOWN", "UP", "LEFT", "RIGHT"][pick_dir]]
		for a in o.size() / 4:
			var fr: Array = o[a * 4 + pick_dir]
			if fr.is_empty():
				continue
			var r = HBoxContainer.new(); rows.add_child(r)
			var nl = Label.new(); nl.text = "pose %d\n%s" % [a, POSE_NAMES.get(a, "")]; nl.custom_minimum_size = Vector2(170, 0)
			nl.add_theme_font_size_override("font_size", 10); r.add_child(nl)
			var il = ItemList.new(); il.max_columns = 0; il.icon_mode = ItemList.ICON_MODE_TOP; il.fixed_icon_size = Vector2i(48, 48)
			il.custom_minimum_size = Vector2(660, 74); il.select_mode = ItemList.SELECT_MULTI; il.auto_height = true
			for n in fr.size():
				il.add_item(str(n), ImageTexture.create_from_image(fr[n]["img"]))
			il.set_meta("anim", a)
			il.multi_selected.connect(func(_i, _sel): _collect(lists, status))
			r.add_child(il)
			lists.append(il)
	sb.value_changed.connect(func(x): pick_set = int(x); fill.call())
	dp.item_selected.connect(func(i): pick_dir = i; fill.call())
	v.add_child(status)
	var bh = HBoxContainer.new(); v.add_child(bh)
	var add = Button.new(); add.text = "ADD AFTER THE CHOSEN FRAME"; bh.add_child(add)
	var rep = Button.new(); rep.text = "REPLACE THE CHOSEN FRAME"; bh.add_child(rep)
	var put = func(replace: bool):
		if picked.is_empty():
			status.text = "Click a frame first."
			return
		var o = load_frames(pick_set)
		var at = mini(frame_i + (0 if replace else 1), frames.size())
		if replace and frame_i < frames.size():
			frames.remove_at(frame_i)
		for pk in picked:
			frames.insert(at, _dup(o[int(pk[0]) * 4 + pick_dir][int(pk[1])]))
			at += 1
		frame_i = mini(at - 1, frames.size() - 1)
		status.text = "%d frame(s) %s. Pick more, or CLOSE and SAVE." % [picked.size(), "put in its place" if replace else "added"]
		_apply_preview(); _rebuild()
	add.pressed.connect(func(): put.call(false))
	rep.pressed.connect(func(): put.call(true))
	d.confirmed.connect(func(): d.queue_free())
	d.canceled.connect(func(): d.queue_free())
	add_child(d)
	fill.call()
	d.popup_centered()

func _collect(lists: Array, status: Label) -> void:
	picked.clear()
	for il in lists:
		if not is_instance_valid(il):
			continue
		for i in il.get_selected_items():
			picked.append([int(il.get_meta("anim")), i])
	status.text = "Picked: " + ", ".join(PackedStringArray(picked.map(func(p): return "pose %d frame %d" % [p[0], p[1]])))

## x,y for many frames: "pose" = this pose and direction, "dirs" = this pose in all 4 directions, "set" = every frame.
## relative: move them all by v (each keeps its own offset); else: put them all at v
var clip_xy = Vector2i.ZERO
var has_clip = false
var nudge = Vector2i.ZERO
func _apply_xy(where: String, relative: bool, v: Vector2i) -> void:
	var ks = []
	match where:
		"pose": ks = [anim * 4 + dir]
		"dirs": ks = [anim * 4, anim * 4 + 1, anim * 4 + 2, anim * 4 + 3]
		_: ks = range(slots.size())
	var n = 0
	for k in ks:
		if k >= slots.size():
			continue
		for fr in slots[k]:
			if relative:
				fr["x"] = int(fr["x"]) + v.x; fr["y"] = int(fr["y"]) + v.y
			else:
				fr["x"] = v.x; fr["y"] = v.y
			n += 1
	info.text = "%d frames %s. SAVE to keep it (or OPEN the set again to undo)." % [n, ("moved by x %d y %d" % [v.x, v.y]) if relative else ("put at x %d y %d" % [v.x, v.y])]
	_apply_preview(); _rebuild()

## ask first (for what can't be undone)
func _confirm(text: String, then: Callable) -> void:
	var d = ConfirmationDialog.new()
	d.title = "ARE YOU SURE?"; d.dialog_text = text
	d.ok_button_text = "YES"; d.cancel_button_text = "NO, KEEP IT"
	d.confirmed.connect(func():
		then.call()
		d.queue_free())
	d.canceled.connect(func(): d.queue_free())
	add_child(d)
	d.popup_centered()

static func _dup(f: Dictionary) -> Dictionary:
	var c = f.duplicate()
	c["img"] = (f["img"] as Image).duplicate()
	return c

func _move_frame(frames: Array, d: int) -> void:
	var j = clampi(frame_i + d, 0, frames.size() - 1)
	if j == frame_i:
		return
	var f = frames[frame_i]
	frames.remove_at(frame_i)
	frames.insert(j, f)
	frame_i = j
	_apply_preview()
	_rebuild()

## the preview shows the frames being edited (not yet saved)
func _apply_preview() -> void:
	if slots.is_empty():
		return
	var C = 64
	var maxf = 1
	for s in slots:
		maxf = maxi(maxf, s.size())
	var img = Image.create_empty(C * maxf, C * slots.size(), false, Image.FORMAT_RGBA8)
	var js = []
	for k in slots.size():
		var row = []
		for n in slots[k].size():
			var f: Dictionary = slots[k][n]
			var fi: Image = f["img"]
			img.blit_rect(fi, Rect2i(0, 0, mini(C, fi.get_width()), mini(C, fi.get_height())), Vector2i(n * C, k * C))
			row.append({"x": f["x"], "y": f["y"], "w": mini(C, int(f["w"])), "h": mini(C, int(f["h"]))})
		js.append(row)
	preview.set_sprite_set({"tex": ImageTexture.create_from_image(img), "cell": C, "slots": js})
