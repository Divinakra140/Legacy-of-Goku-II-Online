extends Control
## MODS: the mod packages people share (modpacks folder) - switch them on and off, put them in order, add one
## from a .zip; and (in the DEV TOOLS) SHARE YOUR WORK: your team's edits made into one mod file.

signal changed
signal closed

var share = true          # the DEV TOOLS show the "make a mod" part too
var rows: VBoxContainer
var warn: Label
var msg: Label
var fields = {}
var font_size = 10

func _ready() -> void:
	var bg = ColorRect.new(); bg.color = Color(0.07, 0.08, 0.13, 0.97); bg.set_anchors_preset(Control.PRESET_FULL_RECT); add_child(bg)
	var sc = ScrollContainer.new(); sc.set_anchors_preset(Control.PRESET_FULL_RECT); sc.offset_left = 8; sc.offset_top = 6; sc.offset_right = -8; sc.offset_bottom = -6
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(sc)
	var v = VBoxContainer.new(); v.size_flags_horizontal = Control.SIZE_EXPAND_FILL; sc.add_child(v)
	var top = HBoxContainer.new(); v.add_child(top)
	_lab(top, "MODS - switched on ones are laid over the game in this order (the lowest wins); your own edits go over all of them.", 11, Color(1, 0.85, 0.35))
	if not share:
		var cb = Button.new(); cb.text = "BACK"; cb.pressed.connect(func(): closed.emit()); top.add_child(cb)
	var bar = HBoxContainer.new(); v.add_child(bar)
	_btn(bar, "ADD A MOD (.zip)", _add)
	if not OS.has_feature("android"):      # (Android: the folder is inside the app - no file manager can open it)
		_btn(bar, "OPEN THE MODS FOLDER", func(): DirAccess.make_dir_recursive_absolute(Mods.packs_dir()); OS.shell_open(Mods.packs_dir()))
	_btn(bar, "REFRESH", refresh)
	rows = VBoxContainer.new(); v.add_child(rows)
	warn = Label.new(); warn.autowrap_mode = TextServer.AUTOWRAP_WORD; warn.add_theme_font_size_override("font_size", font_size)
	warn.add_theme_color_override("font_color", Color(1, 0.6, 0.4)); v.add_child(warn)
	msg = Label.new(); msg.autowrap_mode = TextServer.AUTOWRAP_WORD; msg.add_theme_font_size_override("font_size", font_size)
	msg.add_theme_color_override("font_color", Color(0.6, 1, 0.7)); v.add_child(msg)
	if share:
		v.add_child(HSeparator.new())
		_lab(v, "SHARE YOUR WORK - your map changes, maps, characters, moves, missions, events, colours and sprites in one file anybody can add with ADD A MOD:", 11, Color(1, 0.85, 0.35))
		var g = GridContainer.new(); g.columns = 2; v.add_child(g)
		for f in [["name", "MY MOD"], ["author", ""], ["version", "1.0"], ["description", "What it adds"]]:
			_lab(g, f[0].to_upper(), font_size, Color(0.85, 0.9, 1))
			var e = LineEdit.new(); e.text = f[1]; e.custom_minimum_size = Vector2(320, 0); g.add_child(e)
			fields[f[0]] = e
		var b2 = HBoxContainer.new(); v.add_child(b2)
		_btn(b2, "MAKE THE MOD FILE", _export)
		_btn(b2, "OPEN THE FOLDER", func(): DirAccess.make_dir_recursive_absolute(Assets.exe_dir().path_join("modpacks_made")); OS.shell_open(Assets.exe_dir().path_join("modpacks_made")))
	refresh()

func _lab(p: Control, t: String, size: int, col: Color) -> Label:
	var l = Label.new(); l.text = t; l.autowrap_mode = TextServer.AUTOWRAP_WORD; l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_font_size_override("font_size", size); l.add_theme_color_override("font_color", col); p.add_child(l)
	return l

func _btn(p: Control, t: String, cb: Callable) -> Button:
	var b = Button.new(); b.text = t; b.add_theme_font_size_override("font_size", font_size); b.pressed.connect(cb); p.add_child(b)
	return b

func refresh() -> void:
	for c in rows.get_children():
		c.queue_free()
	var packs = Mods.installed_packs()
	if packs.is_empty():
		_lab(rows, "No mods yet. ADD A MOD, or drop a mod's .zip in the modpacks folder next to the game.", font_size, Color(0.8, 0.8, 0.8))
	for i in packs.size():
		var m: Dictionary = packs[i]
		var h = HBoxContainer.new(); rows.add_child(h)
		var cb = CheckBox.new(); cb.button_pressed = m["enabled"]; h.add_child(cb)
		cb.toggled.connect(func(on): _toggle(str(m["folder"]), on))
		_lab(h, "%s %s  by %s - %s" % [str(m.get("name", m["folder"])), str(m.get("version", "")), str(m.get("author", "?")), str(m.get("description", ""))], font_size, Color(1, 1, 1) if m["enabled"] else Color(0.6, 0.6, 0.65))
		if m["enabled"]:
			_btn(h, "▲", func(): _move(str(m["folder"]), -1))
			_btn(h, "▼", func(): _move(str(m["folder"]), 1))
	var c = Mods.conflicts()
	warn.text = "" if c.is_empty() else "OVERLAPS:\n" + "\n".join(PackedStringArray(c.slice(0, 12))) + ("\n..." if c.size() > 12 else "")

func _toggle(folder: String, on: bool) -> void:
	var en = Mods.enabled_names()
	if on and not en.has(folder):
		en.append(folder)
	if not on:
		en.erase(folder)
	Mods.set_enabled(en)
	msg.text = "%s %s." % [folder, "switched on" if on else "switched off"]
	changed.emit()
	refresh()

func _move(folder: String, d: int) -> void:
	var en = Mods.enabled_names()
	var i = en.find(folder)
	var j = clampi(i + d, 0, en.size() - 1)
	if i < 0 or i == j:
		return
	en.remove_at(i)
	en.insert(j, folder)
	Mods.set_enabled(en)
	changed.emit()
	refresh()

func _add() -> void:
	var fd = FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.filters = PackedStringArray(["*.zip ; Mod packages"])
	if OS.has_feature("android"):
		fd.use_native_dialog = true      # Android's own file picker (Godot's is tiny there and B cannot leave it)
		fd.filters = PackedStringArray()
	fd.title = "Choose a mod (.zip)"
	fd.size = Vector2i(700, 420)
	fd.file_selected.connect(func(p):
		if OS.has_feature("android"):     # the picker hands a file a zip reader cannot open: a copy in the app's folder first
			var tmp = Assets.exe_dir().path_join("mod_picked.zip")
			var fa = FileAccess.open(tmp, FileAccess.WRITE)
			if fa:
				fa.store_buffer(FileAccess.get_file_as_bytes(p)); fa.close(); p = tmp
		msg.text = Mods.import_pack(p)
		changed.emit()
		refresh()
		fd.queue_free())
	fd.canceled.connect(func(): fd.queue_free())
	add_child(fd)
	fd.popup_centered()

func _export() -> void:
	var meta = {}
	for k in fields:
		meta[k] = fields[k].text.strip_edges()
	if meta["name"] == "":
		msg.text = "Give it a name first."
		return
	if tools_ref and tools_ref.has_method("save"):
		tools_ref.save()
	var p = Mods.export_pack(meta)
	msg.text = ("Made %s - send it to anybody: they add it with MODS - ADD A MOD." % p) if p != "" else "Could not write the mod file."

var tools_ref = null
