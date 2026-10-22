extends Node
## Start: import the game once, pick a fighter and a planet, play solo / host / join (LAN or Hamachi).

var ui: Control
var world: Node
var status: Label
var ip_edit: LineEdit
var name_edit: LineEdit
var seed_edit: LineEdit
var char_pick: OptionButton
var adv_pick: OptionButton
var diff_pick: OptionButton
var locals_pick: OptionButton
var char2_pick: OptionButton
var name2_edit: LineEdit
var p2_row: HBoxContainer
var lobby_label: Label
var start_btn: Button
var file_dialog: FileDialog
var music_label: Label
var fetch_ip: LineEdit
var test = {}
## the game's own lands, joined edge to edge (needs the building kit from the import)
const LANDS = [[0, "EARTH - THE WHOLE PLANET"], [4, "WEST CITY & TRICERATOPS JUNGLE"], [8, "NORTHERN MOUNTAINS"], [2, "EAST DISTRICT 439"], [7, "SOUTHERN CONTINENT"],
	[10, "GINGERTOWN"], [3, "NORTHERN WASTELANDS"], [12, "TROPICAL ISLANDS"], [13, "SNOWY HIGHLANDS"], [6, "CAPSULE CORP & NEW NAMEK"]]
var test_t = 0

func _ready() -> void:
	print("[main] ready, import found: ", Assets.base_dir)
	get_window().title = "LoG2 Online"      # the name shown (the project's own name stays: it names the save folder)
	get_window().size_changed.connect(_fit_view)
	_fit_view()
	for a in OS.get_cmdline_user_args():
		var kv = a.trim_prefix("--").split("=")
		test[kv[0]] = kv[1] if kv.size() > 1 else "1"
	if Game.cfg.get("_quit_test", false):       # test aid (--quittest): back here after QUIT TO TITLE
		Game.cfg.erase("_quit_test")
		print("[test] back at the start menu after QUIT TO TITLE")
		test.erase("autotest")
	Game.started.connect(_on_started)
	if OS.has_feature("android"):
		# your own songs in Music/LoG2Coop: Android asks once for "music and audio"
		get_tree().on_request_permissions_result.connect(_on_permission)
		if Assets.audio_allowed():
			_make_music_dirs()
		else:
			OS.request_permissions()
	Game.lobby_changed.connect(_refresh_lobby)
	if test.has("server"):
		_start_server()
		return
	if not Assets.ready_to_play():
		_import_screen()
	else:
		Assets.load_data()
		Assets.start_sharing()   # a phone on the same network can get the game files from this PC
		if test.has("devtools"):
			_dev_tools()
		elif test.has("autotest"):
			_start_test()
		else:
			_menu()
			if test.has("screen"):        # test aid: open one of the menu screens (--screen=_char_screen)
				if str(test["screen"]) in ["_char_screen", "_map_screen", "_name_screen"]:
					if test.has("ch"):
						Game.cfg["character"] = int(test["ch"])
					call(str(test["screen"]), _menu, func(): pass)
					for k in int(test.get("cycle", "0")):      # test aid: the highlighted hero's next outfit, k times
						_outfit_cycle.call(1)
				else:
					call(str(test["screen"]))
			if test.has("lmp"):
				_local_multiplayer()
			elif test.has("gmp"):
				_global_multiplayer()
			elif test.has("find"):
				_find_games()
			if test.has("find"):
				_find_games()

func _on_permission(permission: String, granted: bool) -> void:
	if permission == Assets.ANDROID_AUDIO and granted:
		_make_music_dirs()
		Music.refresh_files()       # songs looked for before are looked for again
		var playing = Music.current
		Music.current = ""
		Music.play(playing)        # (your title song at once)
		Sfx.reload()
		if is_instance_valid(music_label):
			music_label.text = _music_text()

func _make_music_dirs() -> void:
	DirAccess.make_dir_recursive_absolute(Assets.sounds_dir())

func _music_text() -> String:
	if OS.has_feature("android"):
		return "MUSIC: put your own songs in  %s  (Internal storage > Music > LoG2Coop). Name them title.ogg, field.ogg, cave.ogg, lair.ogg, boss.ogg and victory.ogg (or .mp3) to replace those songs in the game. Optional: a file named after an area (the name that pops up when you walk in, like \"west city.ogg\") plays only in that area and takes priority over the base soundtrack. Sound effects go in  %s" % [Assets.music_dir(), Assets.sounds_dir()] + ("" if Assets.audio_allowed() else "  (Allow MUSIC AND AUDIO when Android asks, or in the app's settings.)")
	return "MUSIC: put your own songs in the music folder (title, field, cave, lair, boss, victory .ogg / .mp3, or a place's name like \"west city.ogg\")."

var _screen_gen = 0       # every new screen: a waiting join retry from an older screen gives up
func _clear() -> void:
	_screen_gen += 1
	if ui:
		ui.queue_free()
	ui = Control.new()
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(ui)
	var bg = ColorRect.new()
	bg.color = Color(0.05, 0.06, 0.12)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.add_child(bg)
	if Assets.base_dir != "" and FileAccess.file_exists(Assets.base_dir.path_join("ui/galaxy.png")):
		var g = TextureRect.new()       # the GBA menus' galaxy behind every screen (dimmed a little under the older screens' text)
		g.texture = Assets.texture(Assets.base_dir.path_join("ui/galaxy.png"))
		g.stretch_mode = TextureRect.STRETCH_TILE
		g.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		g.scale = Vector2(1.5, 1.5); g.size = Vector2(2560, 1440)      # (tiled far enough for any screen)
		g.modulate = Color(0.7, 0.7, 0.7)
		ui.add_child(g)

func _box() -> VBoxContainer:
	var v = VBoxContainer.new()
	v.position = Vector2(12, 8)
	v.size = Vector2(456, 254)
	v.add_theme_constant_override("separation", 2)
	ui.add_child(v)
	_old_box = v
	_place_box()
	return v

## the older text screens (first start, ...) grow with the screen like the GBA menus (they sat small in the top-left corner)
var _old_box: Control
var _typing: Callable      # the letter boards: what a typed key does (a letter, "\b" delete, "\n" DONE)
func _place_box() -> void:
	if _old_box == null or not is_instance_valid(_old_box):
		return
	var vp = get_viewport().get_visible_rect().size
	var k = maxf(1.0, floorf(minf(vp.x / 480.0, vp.y / 270.0) * 2.0) / 2.0)      # half steps: the text stays sharp
	_old_box.scale = Vector2(k, k)
	_old_box.position = (((vp - Vector2(480, 270) * k) / 2.0) + Vector2(12, 8) * k).floor()

func _label(parent: Node, t: String, size = 8, col = Color(1, 1, 1)) -> Label:
	var l = Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD
	l.custom_minimum_size = Vector2(450, 0)
	parent.add_child(l)
	return l

func _button(parent: Node, t: String, f: Callable) -> Button:
	var b = Button.new()
	b.text = t
	b.add_theme_font_size_override("font_size", 8)
	b.pressed.connect(f)
	parent.add_child(b)
	return b

# ------------------------------------------------------------------ first start: your game
func _import_screen() -> void:
	_clear()
	var v = _box()
	_label(v, "LEGACY OF GOKU 2 ONLINE", 12, Color(1, 0.85, 0.3))
	if Assets.base_dir != "" and Assets.import_version() < Assets.IMPORT_VERSION:
		_label(v, "NEW IN v44: EARTH comes ready made, the same for everybody. Your game is read once more (a minute or so - longer on a slow computer). Your fighters and settings are kept.", 8, Color(0.6, 1, 0.8))
	_label(v, "First start: choose your own Legacy of Goku II (USA) .gba file. Its pictures, maps and enemies are read from it once (about a minute) - nothing of the game comes with this download.", 8)
	_button(v, "CHOOSE MY GAME...", _pick_rom)
	status = _label(v, "", 8, Color(0.7, 1, 0.7))
	import_bar = Control.new()      # the loading bar: filled as far as the import is, with a light running along it
	import_bar.custom_minimum_size = Vector2(0, 10)
	import_bar.visible = false
	import_bar.draw.connect(_draw_import_bar)
	v.add_child(import_bar)
	# a phone / tablet: the files can also come from your PC (where the game was read and the music recorded)
	_label(v, "OR FROM A PC: open the game on your PC (it must have read your game), connect both to the same Wi-Fi, type the PC's address (shown in the PC's menu) and press GET:", 7, Color(0.75, 0.85, 1))
	var hf = HBoxContainer.new()
	v.add_child(hf)
	fetch_ip = LineEdit.new()
	fetch_ip.placeholder_text = "PC address, e.g. 192.168.1.20"
	fetch_ip.text = str(Game.cfg.get("ip", ""))
	fetch_ip.custom_minimum_size = Vector2(170, 0)
	fetch_ip.add_theme_font_size_override("font_size", 8)
	hf.add_child(fetch_ip)
	_button(hf, "GET THE GAME FILES FROM MY PC", func(): if fetch_ip.text.strip_edges() != "": Assets.start_fetch(fetch_ip.text.strip_edges()))
	if test.has("fetch"):
		Assets.start_fetch(test["fetch"])
	file_dialog = FileDialog.new()
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.filters = PackedStringArray(["*.gba ; GBA game"])
	file_dialog.size = Vector2i(360, 200)
	file_dialog.use_native_dialog = true      # the computer's own file picker (Windows Explorer, the Mac's Finder)
	if OS.has_feature("android"):
		# Android's own file picker (it knows no ".gba" type: every file is shown, the game is checked after)
		file_dialog.use_native_dialog = true
		file_dialog.filters = PackedStringArray()
	file_dialog.file_selected.connect(_rom_chosen)
	ui.add_child(file_dialog)
	# a game file (.gba) next to the program is found by itself
	var d = DirAccess.open(Assets.exe_dir())
	if d:
		for f in d.get_files():
			if f.to_lower().ends_with(".gba"):
				_rom_chosen(Assets.exe_dir().path_join(f))
				return

func _pick_rom() -> void:
	print("[main] CHOOSE MY GAME")
	file_dialog.popup_centered()

var import_bar: Control
var _bar_shown = 0.0
func _draw_import_bar() -> void:
	var r = Rect2(Vector2.ZERO, import_bar.size)
	var t = Time.get_ticks_msec() / 1000.0
	import_bar.draw_rect(r, Color(0.1, 0.12, 0.2))
	var fw = r.size.x * clampf(_bar_shown, 0.0, 1.0)
	var pulse = 0.82 + 0.18 * sin(t * 4.0)      # the fill breathes
	import_bar.draw_rect(Rect2(0, 0, fw, r.size.y), Color(0.25, 0.7, 1.0) * pulse)
	# a light running along the whole bar, round and round
	var band = r.size.x * 0.18
	var bx = fmod(t * r.size.x * 0.45, r.size.x + band) - band
	for i in 12:
		var k = 1.0 - absf(i - 5.5) / 6.0
		var seg = Rect2(bx + band * i / 12.0, 0, band / 12.0 + 1, r.size.y).intersection(r)      # (inside the bar)
		if seg.size.x > 0:
			import_bar.draw_rect(seg, Color(1, 1, 1, 0.22 * k))
	import_bar.draw_rect(r, Color(0.6, 0.8, 1, 0.8), false, 1.0)

func _rom_chosen(path: String) -> void:
	print("[main] game chosen: ", path)
	if OS.has_feature("android"):
		# the picker hands a file the importer cannot open itself: a copy goes into the game's own folder
		var gba = FileAccess.get_file_as_bytes(path)
		print("[main] read ", gba.size(), " bytes (", FileAccess.get_open_error(), ")")
		if gba.size() < 0x100000 or gba.slice(0xA0, 0xAC).get_string_from_ascii().strip_edges() == "":
			status.text = "That file could not be read as a GBA game - choose your Legacy of Goku II (USA) .gba (not a .zip)."
			return
		var copy = Assets.exe_dir().path_join("game.gba")
		if path != copy:
			var fa = FileAccess.open(copy, FileAccess.WRITE)
			if fa == null:
				status.text = "Could not copy the game file into the app's folder."
				return
			fa.store_buffer(gba)
			fa.close()
		path = copy
	status.text = "Reading your game..."
	Assets.start_import(path)
	set_process(true)

func _process(_dt: float) -> void:
	_gal_scroll(_dt)
	if Assets.fetch_thread != null and is_instance_valid(status):
		status.text = Assets.fetch_status
	if Assets.fetch_result >= 0:
		var r = Assets.fetch_result
		Assets.fetch_result = -1
		if r == 0 and Assets.ready_to_play():
			print("[test] fetched the game files: ", Assets.base_dir)
			if test.has("fetch"):
				get_tree().quit()
				return
			Assets.load_data()
			Sfx.reload()
			_menu()
			return
		elif is_instance_valid(status):
			status.text = Assets.fetch_status
	if is_instance_valid(_music_bar) and _music_bar.is_inside_tree():
		_music_bar.queue_redraw()
		_music_lab.text = "RECORDING THE GAME'S SONGS:  %d OF %d" % [mini(Assets.music_done + 1, Assets.music_total), Assets.music_total]
		if Assets.music_thread != null and not Assets.music_thread.is_alive():
			_music_bar = null      # every song tried (one that failed is tried again another time, in the background)
			_music_tried = true
			_menu()
	if Assets.import_thread != null and Assets.import_result < 0 and is_instance_valid(status):
		# the import running: the bar, the step, its count and the time so far (so it never looks stuck)
		var secs = (Time.get_ticks_msec() - Assets.import_ms0) / 1000
		status.text = "%s%s   %d%%   %d:%02d" % [Assets.import_step, ("  -  " + Assets.import_count) if Assets.import_count != "" else "", roundi(Assets.import_frac * 100.0), secs / 60, secs % 60]
		if is_instance_valid(import_bar):
			import_bar.visible = true
			_bar_shown = lerpf(_bar_shown, Assets.import_frac, 0.08)
			import_bar.queue_redraw()
	if Assets.import_thread != null and Assets.import_result >= 0:
		if Assets.import_result == 0:
			Assets.import_thread = null
			Assets.load_data()
			Sfx.reload()
			Assets.start_sharing()
			_menu()
		else:
			status.text = "That did not work: is it the USA Legacy of Goku II game?\n" + Assets.import_log.right(300)
			Assets.import_thread = null

# ------------------------------------------------------------------ the menu
## the PC-style menu from before the GBA menus (kept for reference; not shown)
func _menu_classic() -> void:
	_global_back = Callable()
	_clear()
	Music.play("title")
	Music.prepare(["field", "cave", "lair", "boss", "victory"])
	var v = _box()
	var head = HBoxContainer.new(); head.alignment = BoxContainer.ALIGNMENT_CENTER; v.add_child(head)
	var logo = TextureRect.new(); logo.texture = preload("res://art/puni_logo.png")
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE; logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.custom_minimum_size = Vector2(34, 34); head.add_child(logo)
	var tv = VBoxContainer.new(); head.add_child(tv)
	var tl = _label(tv, "LEGACY OF GOKU 2 ONLINE", 12, Color(1, 0.85, 0.3)); tl.custom_minimum_size = Vector2(0, 0); tl.autowrap_mode = TextServer.AUTOWRAP_OFF
	var by = HBoxContainer.new(); tv.add_child(by)
	var bl = _label(by, "by Puni Puni", 8, Color(0.85, 0.75, 1)); bl.custom_minimum_size = Vector2(0, 0); bl.autowrap_mode = TextServer.AUTOWRAP_OFF
	var yt = Button.new(); yt.text = "YOUTUBE: @PuniPuni2026"; yt.add_theme_font_size_override("font_size", 7)
	yt.add_theme_color_override("font_color", Color(1, 0.45, 0.45)); yt.tooltip_text = "youtube.com/@PuniPuni2026"
	yt.pressed.connect(func(): OS.shell_open("https://www.youtube.com/@PuniPuni2026"))
	by.add_child(yt)
	Game.cfg.erase("story")
	Game.cfg.erase("start_at")
	if not Content.story.is_empty():
		_story_row(v)
	var h = HBoxContainer.new()
	v.add_child(h)
	char_pick = OptionButton.new()
	for i in Assets.CHARACTERS.size():
		char_pick.add_item(Assets.CHARACTERS[i], i)
	char_pick.select(int(Game.cfg["character"]))
	char_pick.add_theme_font_size_override("font_size", 8)
	h.add_child(char_pick)
	adv_pick = OptionButton.new()
	adv_pick.add_item("PLANET GATORRA (adventure)", 0)
	adv_pick.add_item("PLANET DUNARA (adventure)", 1)
	adv_pick.add_item("RANDOM PLANET (seed)", 2)
	if Assets.has_kit():
		var i = 3
		for l in LANDS:
			adv_pick.add_item(("THE ORIGINAL: " if l[0] > 0 else "") + l[1], i)
			i += 1
		adv_pick.select(3)      # EARTH first
	adv_pick.add_theme_font_size_override("font_size", 8)
	adv_pick.fit_to_longest_item = false      # (the longest planet name made the whole menu wider than the screen)
	adv_pick.clip_text = true
	adv_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(adv_pick)
	diff_pick = OptionButton.new()
	for t in ["EASY", "NORMAL", "HARD"]:
		diff_pick.add_item(t)
	diff_pick.select(1)
	diff_pick.custom_minimum_size.x = DIFF_W
	diff_pick.add_theme_font_size_override("font_size", 8)
	h.add_child(diff_pick)
	var mid = HBoxContainer.new()       # (name + seed, players) | PLAY
	v.add_child(mid)
	var left = VBoxContainer.new()
	left.add_theme_constant_override("separation", 2)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.add_child(left)
	var h2 = HBoxContainer.new()
	left.add_child(h2)
	name_edit = LineEdit.new()
	name_edit.text = str(Game.cfg["name"])
	name_edit.placeholder_text = "your name"
	name_edit.custom_minimum_size = Vector2(90, 0)
	name_edit.add_theme_font_size_override("font_size", 8)
	h2.add_child(name_edit)
	seed_edit = LineEdit.new()
	seed_edit.text = str(randi() % 1000000)
	seed_edit.custom_minimum_size = Vector2(70, 0)
	seed_edit.add_theme_font_size_override("font_size", 8)
	h2.add_child(seed_edit)
	seed_edit.placeholder_text = "planet seed"
	seed_edit.tooltip_text = "RANDOM PLANET: the same number always makes the same planet"
	# split screen: a second player on this PC (works online too: 2 here + your friend's PC)
	var h4 = HBoxContainer.new()
	left.add_child(h4)
	var play_place = CenterContainer.new()      # (PLAY in the middle of the room under NORMAL)
	mid.add_child(play_place)
	play_place.add_child(_play_button())
	play_place.custom_minimum_size.x = DIFF_W        # (the NORMAL box's width: PLAY is centred under it)
	locals_pick = OptionButton.new()
	var here = "" if OS.has_feature("mobile") else " ON THIS PC"      # (a handheld: no "PC")
	locals_pick.add_item("1 PLAYER" + here, 0)
	locals_pick.add_item("2 PLAYERS" + here + " (SPLIT SCREEN)", 1)
	locals_pick.select(clampi(int(Game.cfg.get("local_players", 1)) - 1, 0, 1))
	locals_pick.fit_to_longest_item = false      # (only as wide as what it shows)
	locals_pick.add_theme_font_size_override("font_size", 8)
	h4.add_child(locals_pick)
	p2_row = HBoxContainer.new()
	h4.add_child(p2_row)
	char2_pick = OptionButton.new()
	for i in Assets.CHARACTERS.size():
		char2_pick.add_item("P2: " + Assets.CHARACTERS[i], i)
	char2_pick.select(int(Game.cfg.get("character2", 0)))
	char2_pick.add_theme_font_size_override("font_size", 8)
	p2_row.add_child(char2_pick)
	name2_edit = LineEdit.new()
	name2_edit.text = str(Game.cfg.get("name2", "PLAYER 2"))
	name2_edit.custom_minimum_size = Vector2(80, 0)
	name2_edit.add_theme_font_size_override("font_size", 8)
	p2_row.add_child(name2_edit)
	p2_row.visible = locals_pick.selected == 1
	locals_pick.item_selected.connect(func(i): p2_row.visible = i == 1)
	var h3 = HBoxContainer.new()
	left.add_child(h3)
	_button(h3, "LOCAL MULTIPLAYER", _local_multiplayer)
	_button(h3, "GLOBAL MULTIPLAYER", _global_multiplayer)
	_button(h3, "DEV TOOLS", _dev_tools)
	_button(h3, "MODS (%d ON)" % Mods.enabled_names().size(), _mods_screen)
	lobby_label = _label(v, "", 8, Color(0.7, 0.9, 1))
	start_btn = _button(v, "START THE ADVENTURE", func(): _read(); Game.begin())
	start_btn.visible = false
	music_label = _label(v, _music_text(), 7, Color(1, 0.9, 0.55))
	if Assets.share_server != null:
		var ips = []
		for a in IP.get_local_addresses():
			if a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254."):
				ips.append(a)
		if not ips.is_empty():
			_label(v, "PHONE / TABLET: this PC's address is %s - type it on the phone (to get the game files, and to JOIN)." % ", ".join(PackedStringArray(ips)), 7, Color(0.7, 0.85, 1))
	if OS.has_feature("mobile"):
		_label(v, "CONTROLS: d-pad / stick move.  A punch (hold: rushing strike).  B ki blast (hold: your beam).  X special.  Y transform.  L1 item.  R1 next special.  L3 sprints until you stop (and boosts while flying), R2 turns sprint on / off.  START menu.  SELECT map.  MENUS: d-pad + A, or tap.\nLOCAL MULTIPLAYER: play with people on the same Wi-Fi.  GLOBAL MULTIPLAYER: play with anyone over the internet - public games, or private ones with a password.", 7, Color(0.75, 0.75, 0.8))
	else:
		_label(v, "ONE PLAYER: arrows / WASD / pad.  A = Z or J (punch, hold: rushing strike).  B = X or K (ki blast, hold: your beam).  ESC / START: pause.\nTWO ON THIS PC: P1 = WASD + J / K, P2 = arrows + . / (or numpad 1 / 2). With pads: one pad - P1 keyboard, P2 pad; two pads - one each. F2 in the game: player 2 joins / leaves.\nLOCAL MULTIPLAYER: play together with people on the same network - host a game, join one, or host a server. Split screen and multiplayer mix: up to 2 on each PC.", 7, Color(0.75, 0.75, 0.8))

func _read() -> void:
	if char_pick == null or not is_instance_valid(char_pick):
		return      # (the menu is gone: what was read when you left it stays)
	Game.cfg["character"] = char_pick.get_selected_id()
	var aid = adv_pick.get_selected_id()
	Game.cfg["adventure"] = ["gatorra", "dunara", "random"][aid] if aid < 3 else "land:%d" % int(LANDS[aid - 3][0])
	Game.cfg["difficulty"] = diff_pick.selected
	Game.cfg["seed"] = int(seed_edit.text) if seed_edit.text.is_valid_int() else 12345
	Game.cfg["name"] = name_edit.text.strip_edges().to_upper().left(10) if name_edit.text.strip_edges() != "" else "PLAYER"
	Game.cfg["local_players"] = locals_pick.selected + 1
	Game.cfg["character2"] = char2_pick.get_selected_id()
	Game.cfg["name2"] = name2_edit.text.strip_edges().to_upper().left(10) if name2_edit.text.strip_edges() != "" else "PLAYER 2"

## MODS: the mod packages people share - switched on and off here
func _mods_screen() -> void:
	if char_pick and is_instance_valid(char_pick):
		_read()
	var cl = CanvasLayer.new(); cl.layer = 30; add_child(cl)
	var m = load("res://scripts/dev_mods.gd").new()
	m.share = false
	m.font_size = 8
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	cl.add_child(m)
	m.closed.connect(func():
		cl.queue_free()
		Mods.reload()
		_gmods_screen())
	_global_back = func(): m.closed.emit()      # B (or ESC) leaves the mod loader too

## DEV TOOLS: the map, hero, enemy, move, form, blast and mission editors for your team
var dev: Node
func _dev_tools() -> void:
	Game.set_fullscreen(false, false)      # (the DEV TOOLS in a window: their bars are wider than a fullscreen game's view)
	if char_pick and is_instance_valid(char_pick):
		_read()
	if ui:
		ui.queue_free()
		ui = null
	Music.stop()
	Game.cfg["adventure"] = "land:0"
	dev = load("res://scripts/devtools.gd").new()
	add_child(dev)
	if test.has("devdemo") and not _dev_scripted:
		add_child(load("res://scripts/dev_demo.gd").new())
	if test.has("devscript") and not _dev_scripted:       # test aid: another script that drives the tools
		add_child(load(str(test["devscript"])).new())
	_dev_scripted = true
	dev.play_requested.connect(func(at: Dictionary):
		dev.queue_free()
		dev = null
		_fit_view()
		Game.cfg["dev_return"] = at
		Game.cfg["start_at"] = at
		Game.cfg["mode"] = "solo"
		Game.cfg["adventure"] = "land:0"
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://fighters_playtest.json"))   # (a fresh hero each time: events run again)
		Game.begin())
	dev.closed.connect(func():
		dev.queue_free()
		dev = null
		_fit_view()
		_menu())
	dev.tune_requested.connect(func():
		dev.queue_free()
		dev = null
		_fit_view()
		Game.cfg["mode"] = "solo"
		Game.cfg["adventure"] = "land:0"
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://fighters_playtest.json"))   # (a fresh hero each time: events run again)
		Game.begin())

var _dev_scripted = false

## F10 in a play-test: back to the DEV TOOLS where you were
func back_to_tools() -> void:
	if world and is_instance_valid(world):
		if world.has_method("save_all"):
			world.save_all()
		world.queue_free()
		world = null
	Game.leave()
	Game.cfg.erase("start_at")
	_dev_tools()

## a story made in DEV TOOLS - STORY (in your content folder or a mod): its own title, three save slots, PLAY
func _story_row(v: Control) -> void:
	var st: Dictionary = Content.story
	var box = PanelContainer.new()
	var sb = StyleBoxFlat.new(); sb.bg_color = Color(0.12, 0.08, 0.2, 0.9); sb.border_color = Color(1, 0.8, 0.3); sb.set_border_width_all(1); sb.set_content_margin_all(4)
	box.add_theme_stylebox_override("panel", sb)
	v.add_child(box)
	var vv = VBoxContainer.new(); box.add_child(vv)
	var tl = _label(vv, str(st.get("title", "MY STORY")).to_upper(), 11, Color(1, 0.85, 0.35)); tl.custom_minimum_size = Vector2(0, 0)
	if str(st.get("subtitle", "")) != "":
		var stl = _label(vv, str(st["subtitle"]), 7, Color(0.85, 0.85, 1)); stl.custom_minimum_size = Vector2(0, 0)
	var row = HBoxContainer.new(); vv.add_child(row)
	var slot = OptionButton.new(); slot.add_theme_font_size_override("font_size", 8)
	for i in 3:
		var path = "user://fighters_story_%s_%d.json" % [_story_id(), i + 1]
		var txt = "SLOT %d - NEW STORY" % (i + 1)
		if FileAccess.file_exists(path):
			var t = JSON.parse_string(FileAccess.get_file_as_string(path))
			if t is Dictionary and not t.is_empty():
				var d: Dictionary = t.values()[0]
				var ch = clampi(int(d.get("ch", 0)), 0, Assets.CHARACTERS.size() - 1)
				txt = "SLOT %d - %s LV %d" % [i + 1, Assets.CHARACTERS[ch], int(d.get("level", 1))]
		slot.add_item(txt, i)
	row.add_child(slot)
	_button(row, "PLAY THE STORY", func(): _play_story(slot.selected + 1))
	_button(row, "ERASE SLOT", func():
		var d = ConfirmationDialog.new(); d.dialog_text = "Erase slot %d of this story?" % (slot.selected + 1)
		d.confirmed.connect(func():
			DirAccess.remove_absolute(ProjectSettings.globalize_path("user://fighters_story_%s_%d.json" % [_story_id(), slot.selected + 1]))
			_menu())
		add_child(d); d.popup_centered())

func _story_id() -> String:
	var t = str(Content.story.get("title", "story")).to_lower()
	var out = ""
	for ch in t:
		out += ch if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") else "_"
	return out.left(24)

## the story's place and save slot set up (the game is started by whoever calls this: alone, hosting, split screen)
func _story_cfg(slot: int) -> void:
	var st: Dictionary = Content.story
	Game.cfg["adventure"] = "land:0"
	Game.cfg["story"] = "%s_%d" % [_story_id(), slot]
	Game.cfg["start_at"] = {"key": str(st.get("start_map", "land/0/0")), "x": float(st.get("x", 8088)), "y": float(st.get("y", 9632))}

func _play_story(slot: int, story_hero: bool = true) -> void:
	var st: Dictionary = Content.story
	_read()
	Game.cfg["mode"] = "solo"
	Game.cfg["adventure"] = "land:0"
	Game.cfg["story"] = "%s_%d" % [_story_id(), slot]
	Game.cfg["local_players"] = 1
	var ci = Assets.CHARACTERS.find(str(st.get("hero", "GOKU")).to_upper())
	if ci >= 0 and story_hero:
		Game.cfg["character"] = ci
	Game.cfg["start_at"] = {"key": str(st.get("start_map", "land/0/0")), "x": float(st.get("x", 8088)), "y": float(st.get("y", 9632))}
	Game.begin()

func _solo() -> void:
	_read()
	Game.cfg["mode"] = "solo"
	Game.begin()

func _host() -> void:
	_read()
	Game.cfg["mode"] = "host"
	# the world opens at once; friends come in whenever they like (JOIN with your Hamachi IP)
	if Game.host_game():
		Game.begin()
	else:
		lobby_label.text = Game.net_error

## this PC only runs the world (no player): everyone JOINs it, the world stays up while you come and go
func _server_from_menu() -> void:
	_read()
	test["adv"] = Game.cfg["adventure"]
	test["seed"] = str(Game.cfg["seed"])
	test["difficulty"] = str(Game.cfg["difficulty"])
	_start_server()

func _join() -> void:
	_read()
	Game.cfg["mode"] = "join"
	if Game.join_game(str(Game.cfg["ip"])):
		lobby_label.text = "CONNECTING TO %s ..." % Game.cfg["ip"]
	else:
		lobby_label.text = Game.net_error

# ------------------------------------------------------------------ LOCAL MULTIPLAYER (Android port): host, join or serve
## on the same Wi-Fi; the addresses are found and used behind the scenes - nobody types one
## the green of the PLAY button (Steam's), for the big buttons
func _green(b: Button) -> void:
	for st in [["normal", Color(0.44, 0.69, 0.13), Color(0.36, 0.56, 0.1)], ["hover", Color(0.55, 0.8, 0.18), Color(0.44, 0.69, 0.13)],
			["pressed", Color(0.33, 0.52, 0.09), Color(0.27, 0.43, 0.07)], ["focus", Color(0.55, 0.8, 0.18), Color(0.85, 1, 0.55)]]:
		var sb = StyleBoxFlat.new()
		sb.bg_color = st[1]
		sb.border_color = st[2]
		sb.set_border_width_all(1 if st[0] != "focus" else 2)
		sb.set_corner_radius_all(3)
		sb.content_margin_left = 12
		sb.content_margin_right = 12
		b.add_theme_stylebox_override(st[0], sb)
	for k in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(k, Color(1, 1, 1))

## PLAY: big and green (the colour of Steam's play button) with a triangle - the first thing to press (Android port)
const DIFF_W = 110      # the NORMAL box, and the room under it where PLAY stands
func _play_button() -> Button:
	var b = Button.new()
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_green(b)
	# [space][triangle][space][PLAY][space]: the same room everywhere
	const GAP = 9
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", GAP)
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(row)
	var tex = _triangle_icon()
	var tri = TextureRect.new()
	tri.texture = tex
	tri.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	tri.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(tri)
	var lab = Label.new()
	lab.text = "PLAY"
	lab.add_theme_font_size_override("font_size", 14)
	lab.add_theme_color_override("font_color", Color(1, 1, 1))
	lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(lab)
	var word_w = ThemeDB.fallback_font.get_string_size("PLAY", HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
	b.custom_minimum_size = Vector2(GAP * 3 + tex.get_width() + word_w, 32)
	b.pressed.connect(_solo)
	b.add_to_group("first_focus")
	return b

func _triangle_icon() -> ImageTexture:
	var img = Image.create(10, 12, false, Image.FORMAT_RGBA8)
	for y in 12:
		var reach = 6.0 - absf(y - 5.5)          # a play triangle pointing right
		for x in 10:
			if x + 0.5 <= reach * 10.0 / 6.0:
				img.set_pixel(x, y, Color(1, 1, 1))
	return ImageTexture.create_from_image(img)

func _big_button(parent: Node, t: String, f: Callable) -> Button:
	var b = _button(parent, t, f)
	b.add_theme_font_size_override("font_size", 11)
	b.custom_minimum_size = Vector2(0, 22)
	return b

# ------------------------------------------------------------------ GLOBAL MULTIPLAYER (Android port): over the internet
## (embedded ZeroTier + the lobby list: see online.gd). B goes back from every one of these screens.
var _global_back: Callable = Callable()
## a small BACK at the top left and the title; returns the row (more can be added to it)
func _top_bar(v: Control, title_text: String) -> HBoxContainer:
	var top = HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	v.add_child(top)
	_button(top, "BACK", func(): if _global_back.is_valid(): _global_back.call())
	var title = _label(top, title_text, 12, Color(1, 0.85, 0.3))
	title.custom_minimum_size = Vector2(0, 0)
	title.autowrap_mode = TextServer.AUTOWRAP_OFF
	return top

## big green buttons side by side, each with its paragraph under it
func _columns(v: Control, items: Array) -> void:
	var cols = HBoxContainer.new()
	cols.add_theme_constant_override("separation", 12)
	v.add_child(cols)
	for c in items:
		var col = VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_theme_constant_override("separation", 4)
		cols.add_child(col)
		var b = Button.new()
		b.text = c[0]
		b.add_theme_font_size_override("font_size", 12 if items.size() > 2 else 14)
		b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		b.custom_minimum_size = Vector2(0, 28)
		_green(b)
		b.pressed.connect(c[1])
		col.add_child(b)
		var d = _label(col, c[2], 8, Color(0.8, 0.85, 0.95))
		d.custom_minimum_size = Vector2(0, 0)
		d.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

## run f every half second while this screen is up
func _tick(f: Callable) -> void:
	var t = Timer.new()
	t.wait_time = 0.5
	t.autostart = true
	t.timeout.connect(f)
	ui.add_child(t)
	f.call()

## hosting and joining need the internet network up; until then the button says so
func _online_action(f: Callable) -> void:
	if not Online.available():
		lobby_label.text = "GLOBAL MULTIPLAYER needs the Android app."
		return
	if not Online.is_online():
		lobby_label.text = Online.status_text() + " - try again in a moment."
		return
	f.call()

func _host_online(password: String) -> void:
	Game.cfg["mode"] = "host"
	if Game.host_game_online(password):
		_global_back = Callable()
		Game.begin()
	elif is_instance_valid(lobby_label):
		lobby_label.text = Game.net_error

var _pw_edit: LineEdit
func _password_box(v: Control) -> void:
	_pw_edit = LineEdit.new()
	_pw_edit.placeholder_text = "password"
	_pw_edit.max_length = 24
	_pw_edit.custom_minimum_size = Vector2(160, 0)
	_pw_edit.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_pw_edit.add_theme_font_size_override("font_size", 10)
	v.add_child(_pw_edit)

func _pick_online_game(g: Dictionary) -> void:
	if bool(g["private"]):
		_join_password_screen(g)
	else:
		_online_action(func(): _join_online(g, ""))

func _join_online(g: Dictionary, password: String, tries: int = 0) -> void:
	Online.browse(false)
	Game.net_error = ""
	Game.cfg["mode"] = "join"
	_join_retry = [g, password, tries]
	var port = Online.join(g, password)
	if Game.join_game_online(port):
		lobby_label.text = "JOINING ..." if tries == 0 else "STILL CONNECTING ... (TRY %d OF %d)" % [tries + 1, JOIN_TRIES]
	elif tries + 1 < JOIN_TRIES:
		_retry_join()
	else:
		lobby_label.text = Game.net_error

## the internet link can still be coming up (a moment after the app starts): a failed join tries again by itself
const JOIN_TRIES = 6
var _join_retry = []
func _retry_join() -> void:
	if _join_retry.is_empty():
		return
	var r = _join_retry
	_join_retry = []
	Online.stop_joining()
	if Game.multiplayer.has_multiplayer_peer():
		Game.multiplayer.multiplayer_peer = null
	if is_instance_valid(lobby_label):
		lobby_label.text = "STILL CONNECTING ... (TRY %d OF %d)" % [int(r[2]) + 2, JOIN_TRIES]
	var gen = _screen_gen
	await get_tree().create_timer(2.5).timeout
	if gen == _screen_gen and Game.cfg.get("mode", "") == "join" and world == null:
		_join_online(r[0], r[1], int(r[2]) + 1)

# ------------------------------------------------------------------ JOIN GAME: the games on this Wi-Fi
func _join_found(ip: String) -> void:
	Game.lan_scan_stop()
	finding = false
	Game.cfg["ip"] = ip
	Game.cfg["mode"] = "join"
	if Game.join_game(ip):
		lobby_label.text = "JOINING ..."
	else:
		lobby_label.text = Game.net_error

func _refresh_lobby() -> void:
	if Game.net_error == "COULD NOT CONNECT" and not _join_retry.is_empty() and int(_join_retry[2]) + 1 < JOIN_TRIES:
		_retry_join()
		return
	if lobby_label == null or not is_instance_valid(lobby_label):
		return
	if Game.net_error != "":
		lobby_label.text = Game.net_error
		return
	var names = []
	for id in Game.peers:
		names.append("%s (%s)" % [Game.peers[id]["name"], Assets.CHARACTERS[clampi(int(Game.peers[id]["character"]), 0, Assets.CHARACTERS.size() - 1)]])
	if Game.cfg["mode"] == "host":
		lobby_label.text = "HOSTING - people on your Wi-Fi can join. In the game: " + ", ".join(PackedStringArray(names))
	else:
		lobby_label.text = "CONNECTED. Waiting for the host to start... Players: " + ", ".join(PackedStringArray(names))

func _on_started() -> void:
	_global_back = Callable()
	_join_retry = []
	Online.browse(false)
	in_local_mp = false
	finding = false
	Game.lan_scan_stop()
	if Game.cfg["mode"] == "server":
		return
	if world and is_instance_valid(world) and world.has_method("save_all"):
		world.save_all()
	if ui:
		ui.queue_free()
		ui = null
	get_viewport().gui_release_focus()     # a menu button kept in focus must not take the pad's A in the game
	if world:
		world.queue_free()
	world = Node2D.new()
	world.set_script(load("res://scripts/world.gd"))
	add_child(world)

# ------------------------------------------------------------------ the dedicated server (no window, no player)
## LoG2Coop.exe --headless -- --server --adv=gatorra --seed=12345 [--difficulty=1]
## The world lives on this PC: players JOIN with its IP whenever they like, the world is saved every 10 s.
func _start_server() -> void:
	if not Assets.ready_to_play():
		print("[server] no imported folder: start LoG2Online.exe once normally and choose your game first")
		get_tree().quit(1)
		return
	Assets.load_data()
	Game.cfg["mode"] = "server"       # (the server shows as SERVER in the lists; your own name is kept)
	Game.cfg["adventure"] = test.get("adv", "gatorra")
	Game.cfg["seed"] = int(test.get("seed", "12345"))
	Game.cfg["difficulty"] = int(test.get("difficulty", "1"))
	if not (Game.host_game_online("") if test.has("online") else Game.host_game()):
		print("[server] ", Game.net_error)
		get_tree().quit(1)
		return
	Game.begin()
	print("[server] world %s is open on port %d - players JOIN with this PC's (Hamachi) IP" % [Game.world_id(), Game.PORT])
	var srv = Node.new()
	srv.set_script(load("res://scripts/server.gd"))
	add_child(srv)
	if DisplayServer.get_name() != "headless":
		_clear()
		var v = _box()
		_label(v, "LOG2 WORLD SERVER", 12, Color(1, 0.85, 0.3))
		_button(v, "STOP THE SERVER - BACK TO THE MENU", srv.stop)
		srv.status = _label(v, "", 8, Color(0.8, 1, 0.8))

# ------------------------------------------------------------------ test aid (headless runs)
func _start_test() -> void:
	Game.cfg["character"] = int(test.get("ch", "4"))
	Game.cfg["adventure"] = test.get("adv", "gatorra")
	Game.cfg["seed"] = int(test.get("seed", "777"))
	Game.cfg["mode"] = test.get("mode", "solo")
	Game.cfg["name"] = test.get("name", "TEST")
	Game.start_override = int(test.get("start", "-1"))
	Game.cfg["local_players"] = int(test.get("locals", "1"))
	Game.cfg["character2"] = int(test.get("ch2", "0"))
	Game.cfg["name2"] = test.get("name2", "TEST2")
	Game.cfg["respawn_scale"] = float(test.get("respawn", "1"))
	Game.cfg["event_scale"] = float(test.get("events", "1"))
	Game.cfg["wb_node"] = int(test.get("wbnode", "-1"))
	if Game.cfg["mode"] == "host":
		Game.host_game()
		await get_tree().create_timer(float(test.get("wait", "3"))).timeout
		Game.begin()
	elif Game.cfg["mode"] == "wshost":       # test: GLOBAL hosting without ZeroTier (WebSocket on this machine)
		Game.cfg["mode"] = "host"
		Game.host_game_online(test.get("pw", ""))
		if test.has("salt"):        # (a test: a known salt, so the joining copy can make its proof)
			Online.salt = test["salt"]
			Online._proof = Online.proof_of(Online.salt, test.get("pw", ""))
		Game.begin()
	elif Game.cfg["mode"] == "wsjoin":
		Game.cfg["mode"] = "join"
		Online.join_proof = Online.proof_of(test.get("salt", ""), test.get("pw", "")) if test.has("salt") else ""
		Game.join_game_online(Online.PORT)
	elif Game.cfg["mode"] == "join":
		Game.join_game(test.get("ip", "127.0.0.1"))
	else:
		Game.begin()

func _input(ev: InputEvent) -> void:
	# a name / world name / password board with a keyboard: just type (letters, numbers, space, Backspace, Enter = DONE)
	if _typing.is_valid() and world == null and (dev == null or not is_instance_valid(dev)) and ev is InputEventKey and ev.pressed and not ev.ctrl_pressed and not ev.meta_pressed and not ev.alt_pressed:
		var t = ""
		if ev.keycode == KEY_BACKSPACE or ev.keycode == KEY_DELETE:
			t = "\b"
		elif (ev.keycode == KEY_ENTER or ev.keycode == KEY_KP_ENTER) and not ev.echo:
			t = "\n"
		elif ev.unicode > 0:
			var ch = char(ev.unicode).to_upper()
			if ch == " " or "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-".contains(ch):
				t = ch
		if t != "":
			_typing.call(t)
			get_viewport().set_input_as_handled()
			return
	# the GBA menus with a keyboard: Enter / Space / J / Z press the chosen button (the game's A)
	# (not with Control / Command - Control+Z is the map editor's undo - and never in the DEV TOOLS)
	if world == null and (dev == null or not is_instance_valid(dev)) and ev is InputEventKey and ev.pressed and not ev.echo and not ev.alt_pressed and not ev.ctrl_pressed and not ev.meta_pressed and ev.keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE, KEY_J, KEY_Z]:
		var fo = get_viewport().gui_get_focus_owner()
		if fo is BaseButton and fo.is_visible_in_tree() and not fo.disabled:
			fo.pressed.emit()
			get_viewport().set_input_as_handled()
			return
	# fullscreen: F11 or Alt+Enter (the picture stays sharp: whole-number scaling)
	if ev is InputEventKey and ev.pressed and not ev.echo and (ev.keycode == KEY_F11 or (ev.keycode == KEY_ENTER and ev.alt_pressed)):
		Game.toggle_fullscreen()
		get_viewport().set_input_as_handled()
	# CHOOSE YOUR CHARACTER: L / R (bumpers, triggers, Q / E) change the highlighted hero's outfit
	if _outfit_cycle.is_valid() and ui != null and is_instance_valid(ui):
		var step = 0
		if ev is InputEventJoypadButton and ev.pressed:
			if ev.button_index == JOY_BUTTON_LEFT_SHOULDER: step = -1
			elif ev.button_index == JOY_BUTTON_RIGHT_SHOULDER: step = 1
		elif ev is InputEventJoypadMotion and (ev.axis == JOY_AXIS_TRIGGER_LEFT or ev.axis == JOY_AXIS_TRIGGER_RIGHT):
			var down = ev.axis_value > 0.6
			if down and not _trig_prev.get(ev.axis, false):
				step = -1 if ev.axis == JOY_AXIS_TRIGGER_LEFT else 1
			_trig_prev[ev.axis] = down
		elif ev is InputEventKey and ev.pressed and not ev.echo:
			if ev.keycode == KEY_Q: step = -1
			elif ev.keycode == KEY_E: step = 1

		if step != 0:
			_outfit_cycle.call(step)
			get_viewport().set_input_as_handled()
			return
	# GLOBAL MULTIPLAYER screens: B (or ESC) goes back
	if _global_back.is_valid() and ui != null and is_instance_valid(ui) and ((ev is InputEventJoypadButton and ev.pressed and ev.button_index == Game.pad_btn("b")) or (ev is InputEventKey and ev.pressed and not ev.echo and ev.keycode == KEY_ESCAPE)):
		get_viewport().set_input_as_handled()
		_global_back.call()
		return
	# LOCAL MULTIPLAYER / JOIN GAME: B (or ESC) goes back
	if in_local_mp and ui != null and is_instance_valid(ui) and ((ev is InputEventJoypadButton and ev.pressed and ev.button_index == Game.pad_btn("b")) or (ev is InputEventKey and ev.pressed and not ev.echo and ev.keycode == KEY_ESCAPE)):
		get_viewport().set_input_as_handled()
		in_local_mp = false
		_mp_choice()
		return
	if finding and ui != null and is_instance_valid(ui) and ((ev is InputEventJoypadButton and ev.pressed and ev.button_index == Game.pad_btn("b")) or (ev is InputEventKey and ev.pressed and not ev.echo and ev.keycode == KEY_ESCAPE)):
		get_viewport().set_input_as_handled()
		_leave_find()
		return
	# a pad in the menus: the first press puts the focus on the first button (d-pad moves, A presses)
	if ev is InputEventJoypadButton and ev.pressed and ui != null and is_instance_valid(ui) and ui.is_inside_tree():
		var fo = get_viewport().gui_get_focus_owner()
		if fo == null or not fo.is_visible_in_tree():
			var first = get_tree().get_first_node_in_group("first_focus")      # (PLAY on the main menu)
			if first == null or not is_instance_valid(first) or not first.is_visible_in_tree():
				first = _first_focusable(ui)
			if first:
				first.grab_focus()
				get_viewport().set_input_as_handled()

func _first_focusable(n: Node) -> Control:
	for c in n.get_children():
		if c is Control and c.is_visible_in_tree():
			if c.focus_mode == Control.FOCUS_ALL and c is BaseButton and not c.disabled:
				return c
			var r = _first_focusable(c)
			if r:
				return r
	return null

func _physics_process(_dt: float) -> void:
	if test.has("ftime"):
		var now = Time.get_ticks_usec()
		if _ft_last > 0:
			_ft_max = maxi(_ft_max, now - _ft_last)
			if now - _ft_last > 40000: print("[test] slow frame ", Engine.get_physics_frames(), " ", (now - _ft_last) / 1000)
		_ft_last = now
		if Engine.get_physics_frames() % 120 == 0:
			print("[test] worst frame ", _ft_max / 1000.0, " ms")
			_ft_max = 0
	if get_window().size != _fit_size:      # fullscreen, maximise, a new monitor: fit again at once
		_fit_view()
	if test.has("menushot"):
		test_t += 1
		if test_t == 20:
			get_viewport().get_texture().get_image().save_png(test["menushot"])
			get_tree().quit()
		return
	if not test.has("autotest") or world == null:
		return
	test_t += 1
	if test.has("quittest") and test_t == int(test["quittest"]):
		Game.cfg["_quit_test"] = true
		world.call("_option_pick_quit")
		return
	if test.has("gameshot") and test_t == int(test.get("shotat", "400")):
		get_viewport().get_texture().get_image().save_png(test["gameshot"])
	var script: String = test.get("keys", "")
	# keys: "from:to:keys;..." with keys letters u d l r a b (player 1); keys2 the same for player 2; F = toggle player 2
	if test.has("level") and test_t == 2:
		for L in world.locals:
			L.fighter.level = int(test["level"])
			L.fighter.ep = L.fighter.maxep + 60
			L.fighter.maxep += 60
			L.fighter.zeni = 1000
			print("[test] moves ", L.fighter.unlocked_skills().map(func(k): return k["id"]))
			if test.has("skill"):
				L.fighter.skill_i = int(test["skill"])
	if test.has("skill") and test_t == 3:      # test aid: the special to use, by its id
		var tf = world.locals[0].fighter
		var u = tf.unlocked_skills()
		for i in u.size():
			if str(u[i]["id"]) == str(test["skill"]):
				tf.skill_i = i
	if test.has("ko") and test_t == int(test["ko"]):      # test aid: the player is beaten at this frame
		var kf = world.locals[0].fighter
		kf.hp = 1; kf.invuln = 0; kf.flying = false
		kf.take_hit(999, 0.0, 0.0)
	if _script_keys(test.get("keys", "")).has("toggle"):
		world._toggle_player2()
	var tk = []
	for i in world.locals.size():
		var k = _script_keys(test.get("keys" if i == 0 else "keys2", ""))
		k.erase("toggle")
		if test.has("bot") and k.is_empty() and (i == 0 or test.has("bot2")):
			k = _bot_keys(world.locals[i], i)
		tk.append(k if not k.is_empty() else {"none": true})
	world.test_keys = tk
	if test.has("watch") and test_t % 60 == 0:
		for pid in Game.remote_states:
			var st = Game.remote_states[pid]
			print("[test] watch ", pid, " node ", st.get("node"), " at ", int(st["x"]), ",", int(st["y"]), " down ", st.get("down"), " me at ", int(world.locals[0].fighter.x), ",", int(world.locals[0].fighter.y), " help ", world.locals[0].helping)
	if test.has("social") and test["social"] == "net" and not Game.remote_states.is_empty():
		var A = world.locals[0]
		var rp = Game.remote_states.keys()[0]
		var pa = world._my_pid(A)
		if test_t == 200 and Game.is_host():
			world._friend_act(A, {"act": "trade", "pid": rp, "name": "FRIEND"})
			world._friend_act(A, {"act": "duel", "pid": rp, "name": "FRIEND"})
		if test_t == 260 and not Game.is_host():
			print("[test] client rows ", world._friend_rows(A).slice(0, 2))
			world._friend_act(A, world._friend_rows(A)[0])
		if not A.trade.is_empty() and A.trade["mine"].is_empty():
			A.trade["mine"] = {"zeni": 10 if Game.is_host() else 25}
			Game.send_social(rp, pa, A.name, "trade_offer", {"offer": A.trade["mine"]})
		if not A.trade.is_empty() and not A.trade["theirs"].is_empty() and not A.trade["ready_me"] and test_t % 40 == 0:
			A.trade["ready_me"] = true
			Game.send_social(rp, pa, A.name, "trade_ready", {"mine": A.trade["mine"], "theirs": A.trade["theirs"]})
			world._trade_check(A)
		if test_t == 330:
			print("[test] net before host=", Game.is_host(), " zeni ", A.fighter.zeni, " trade ", A.trade)
		if test_t == 450:
			print("[test] net after host=", Game.is_host(), " zeni ", A.fighter.zeni, " trade ", A.trade, " invites ", A.invites)
	if test.has("social") and world.locals.size() > 1:
		var A = world.locals[0]
		var B = world.locals[1]
		var pa = world._my_pid(A)
		var pb = world._my_pid(B)
		match test["social"]:
			"duel":
				if test_t == 30: world._friend_act(A, {"act": "duel", "pid": pb, "name": B.name})
				if test_t == 40: world._friend_act(B, world._friend_rows(B)[0])
				if test_t % 20 == 0 and B.fighter.state == "idle": B.fighter.x = A.fighter.x + 16; B.fighter.y = A.fighter.y
				if test_t % 60 == 0: print("[test] pos A ", int(A.fighter.x), ",", int(A.fighter.y), " ", A.fighter.state, " B ", int(B.fighter.x), ",", int(B.fighter.y), " ", B.fighter.state, " inv ", B.fighter.invuln)
				if test_t % 60 == 0: print("[test] duel A ", A.duel, " hp ", A.fighter.hp, "  B ", B.duel, " hp ", B.fighter.hp, "/", B.fighter.maxhp)
			"tradeview":
				if test_t == 30:
					world._friend_act(A, {"act": "trade", "pid": pb, "name": B.name})
				if test_t == 40:
					world._friend_act(B, world._friend_rows(B)[0])
					A.fighter.add_item("senzu", 2)
				if test_t == 70:
					A.trade["mine"] = {"senzu": 2}; Game.send_social(pb, pa, A.name, "trade_offer", {"offer": A.trade["mine"]})
					A.menu["row"] = 0
				if test_t == 110:
					B.trade["mine"] = {"zeni": 300}; Game.send_social(pa, pb, B.name, "trade_offer", {"offer": B.trade["mine"]})
					B.menu["row"] = 4
				if test_t == 150:
					A.trade["ready_me"] = true; Game.send_social(pb, pa, A.name, "trade_ready", {"mine": A.trade["mine"], "theirs": A.trade["theirs"]})
					A.menu["row"] = 5
			"trade":
				if test_t == 30:
					world._friend_act(A, {"act": "trade", "pid": pb, "name": B.name})
					world._friend_act(A, {"act": "party", "pid": pb, "name": B.name})
				if test_t == 40:
					world._friend_act(B, world._friend_rows(B)[0])
					world._friend_act(B, world._friend_rows(B)[0])
					print("[test] party A ", A.party, " B ", B.party, " trade A ", A.trade, " B ", B.trade)
					A.fighter.add_item("senzu", 2)
				if test_t == 50:
					A.trade["mine"] = {"senzu": 1}; Game.send_social(pb, pa, A.name, "trade_offer", {"offer": A.trade["mine"]})
					B.trade["mine"] = {"zeni": 100}; Game.send_social(pa, pb, B.name, "trade_offer", {"offer": B.trade["mine"]})
					print("[test] before A zeni ", A.fighter.zeni, " senzu ", A.fighter.inv.get("senzu", 0), " B zeni ", B.fighter.zeni, " senzu ", B.fighter.inv.get("senzu", 0))
				if test_t == 60:
					A.trade["ready_me"] = true; Game.send_social(pb, pa, A.name, "trade_ready", {"mine": A.trade["mine"], "theirs": A.trade["theirs"]})
				if test_t == 70:
					B.trade["ready_me"] = true; Game.send_social(pa, pb, B.name, "trade_ready", {"mine": B.trade["mine"], "theirs": B.trade["theirs"]}); world._trade_check(B)
				if test_t == 80:
					print("[test] after A zeni ", A.fighter.zeni, " senzu ", A.fighter.inv.get("senzu", 0), " B zeni ", B.fighter.zeni, " senzu ", B.fighter.inv.get("senzu", 0), " trades ", A.trade, B.trade)
	if test.has("downme") and test_t == int(test["downme"]):
		world.locals[0].fighter.invuln = 0
		world.locals[0].fighter.take_hit(99999, 0, 0)
	if test.has("downme") and test_t % 30 == 0:
		print("[test] me state ", world.locals[0].fighter.state, " hp ", world.locals[0].fighter.hp, " down_t ", world.locals[0].fighter.down_t)
	if test.has("downp2") and test_t == int(test["downp2"]) and world.locals.size() > 1:
		world.locals[1].fighter.invuln = 0
		world.locals[1].fighter.take_hit(99999, 0, 0)
	if test.has("downp2") and test_t % 30 == 0 and world.locals.size() > 1:
		print("[test] P2 state ", world.locals[1].fighter.state, " hp ", world.locals[1].fighter.hp, " down_t ", world.locals[1].fighter.down_t)
	if test.has("say") and test_t == int(test["say"].split(":")[0]):
		Game.say(world.locals[0].name, test["say"].split(":")[1], 0)
	if test.has("pos") and test_t == 5:
		# test aid: put player 1 somewhere (area pixels)
		var xy = str(test["pos"]).split(",")
		world.locals[0].fighter.x = float(xy[0]); world.locals[0].fighter.y = float(xy[1])
	if test.has("touch") and test_t == 2:
		world.touch.shown = true
	if test.has("skill") and test_t == 3:
		for L in world.locals:
			var u = L.fighter.unlocked_skills()
			for i in u.size():
				if str(u[i]["id"]) == test["skill"]:
					L.fighter.skill_i = i
	if test.has("nomusic"):
		Music.volume = 0.0
	if test.has("nohud") and test_t == 2:
		world.hud_draw.visible = false
	if test.has("walkto") and test_t >= 10:
		# trailer aid: player 1 runs a real path (A* over the walkable ground) through the given points
		var L0 = world.locals[0]
		if walk_path.is_empty() and test_t == 10:
			var a: Dictionary = L0.area
			var g = AStarGrid2D.new()
			g.region = Rect2i(0, 0, a["tw"], a["th"])
			g.cell_size = Vector2(8, 8)
			g.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
			g.update()
			var wk: PackedByteArray = a["walk"]
			var tw: int = a["tw"]
			var th: int = a["th"]
			for y in th:
				for x in tw:
					if wk[y * tw + x] == 0:
						g.set_point_solid(Vector2i(x, y), true)
					else:
						# keep a tile away from walls (the fighter is wider than one tile)
						for dy in range(-1, 2):
							for dx in range(-1, 2):
								var xx = clampi(x + dx, 0, tw - 1)
								var yy = clampi(y + dy, 0, th - 1)
								if wk[yy * tw + xx] == 0:
									g.set_point_weight_scale(Vector2i(x, y), 6.0)
			var cur = Vector2i(int(L0.fighter.x / 8), int(L0.fighter.y / 8))
			for q in str(test["walkto"]).split(";", false):
				var v = q.split(",")
				var sp = Game.planet.safe_point(L0.node_i, Vector2(float(v[0]), float(v[1])))
				var to = Vector2i(int(sp.x / 8), int(sp.y / 8))
				var seg = g.get_point_path(cur, to)
				print("[test] walk leg ", cur, " -> ", to, ": ", seg.size(), " steps")
				for pt in seg:
					walk_path.append(pt + Vector2(4, 4))
				cur = to
		if walk_path.size() > 0:
			var me = Vector2(L0.fighter.x, L0.fighter.y)
			while walk_path.size() > 1 and me.distance_to(walk_path[0]) < 7:
				walk_path.pop_front()
				walk_stuck = 0
			walk_stuck += 1
			if walk_stuck > 40 and walk_path.size() > 1:
				walk_path.pop_front()      # caught on a corner: aim at the next step
				walk_stuck = 0
			var dv = walk_path[0] - me
			var k = {"run": true}
			if dv.x > 2: k["right"] = true
			if dv.x < -2: k["left"] = true
			if dv.y > 2: k["down"] = true
			if dv.y < -2: k["up"] = true
			if walk_path.size() == 1 and dv.length() < 4:
				k = {"none": true}
			world.test_keys[0] = k
	if test.has("glide") and test_t >= 10:
		# trailer aid: player 1 flies along a path over the land (walls ignored), the camera follows
		var pts = []
		for q in str(test["glide"]).split(";", false):
			var v = q.split(",")
			pts.append(Vector2(float(v[0]), float(v[1])))
		var sp = float(test.get("glidespeed", "3"))
		var dist = (test_t - 10) * sp
		var p = pts[0]
		var dv = Vector2.ZERO
		for i in range(1, pts.size()):
			var seg = pts[i] - pts[i - 1]
			if dist <= seg.length():
				p = pts[i - 1] + seg.normalized() * dist
				dv = seg
				break
			dist -= seg.length()
			p = pts[i]
		var L0 = world.locals[0]
		L0.fighter.x = p.x
		L0.fighter.y = p.y
		if dv != Vector2.ZERO:
			var d = (3 if dv.x > 0 else 2) if absf(dv.x) > absf(dv.y) else (0 if dv.y > 0 else 1)
			L0.fighter.dir = d
			world.test_keys[0] = {["down", "up", "left", "right"][d]: true, "run": true}
	if test.has("aim") and (world.test_keys[0].has("sp") or world.test_keys[0].has("b")):
		# trailer aid: face the nearest foe before a special / ki blast
		var L0 = world.locals[0]
		var key0: String = Game.planet.nodes[L0.node_i]["key"]
		var bd = 1e9
		var dv = Vector2.ZERO
		for e in Game.area_states.get(key0, []):
			var v = Vector2(float(e[1]) - L0.fighter.x, float(e[2]) - L0.fighter.y)
			if v.length() < bd and (int(e[9]) & 4) == 0:
				bd = v.length(); dv = v
		if dv != Vector2.ZERO:
			L0.fighter.dir = (3 if dv.x > 0 else 2) if absf(dv.x) > absf(dv.y) else (0 if dv.y > 0 else 1)
	if test.has("god"):
		for L in world.locals:
			L.fighter.hp = maxi(L.fighter.hp, L.fighter.maxhp * 2 / 3)
	if test.has("infep"):
		for L in world.locals:
			L.fighter.ep = L.fighter.maxep
	if test.has("clean") and test_t <= 3:
		world.toasts.clear()      # trailer/test aid: no start messages
	if test.has("spawn") and test_t == 30:
		# test aid: foes of the given types (and "b<type>" for a boss of that kind) right next to player 1
		var L0 = world.locals[0]
		var key0: String = Game.planet.nodes[L0.node_i]["key"]
		if Game.sims.has(key0):
			var sim = Game.sims[key0]
			var i = 0
			for tok in str(test["spawn"]).split(",", false):
				var boss = tok.begins_with("b")
				var t = int(tok.trim_prefix("b"))
				var st = Assets.set_for_type(t)
				var pos = sim._open_near(Vector2(L0.fighter.x + float(test.get("spawnd", "70")) + 30 * (i % 3), L0.fighter.y - 30 + 30 * (i / 3)))
				var e = sim.make_enemy(9000 + i, t, st, pos, maxi(1, L0.fighter.level), test.has("elite"), boss)
				sim.enemies.append(e)
				i += 1
	if test.has("warpat") and test_t == int(test["warpat"]):
		world.map_open = true
		var ev = InputEventKey.new()
		ev.pressed = true
		ev.keycode = KEY_ENTER
		print("[test] warp ", world._others())
		world._map_input(ev)
	if test.has("mapshot") and test_t == int(test["mapshot"]):
		world.map_open = true
	if test.has("shots"):
		for s in test["shots"].split(",", false):
			if test_t == int(s):
				var img = get_viewport().get_texture().get_image()
				var path = str(test.get("out", "/tmp")) + "/shot_%05d.png" % test_t
				var err = img.save_png(path) if img else -1
				print("[test] shot ", path, " ", err)
	if test.has("log") and test_t % int(test["log"]) == 0:
		for L in world.locals:
			var key2: String = Game.planet.nodes[L.node_i]["key"]
			if Game.sims.has(key2):
				var ks = {}
				for sh in Game.sims[key2].eshots:
					ks[sh["k"]] = ks.get(sh["k"], 0) + 1
				print("[test] shots ", ks)
				var st = []
				for e in Game.sims[key2].enemies:
					st.append("%d:%s/%s%s@%d,%d hp%d" % [e["id"], e["state"], str(e.get("st", {}).get("id", "")) + "#" + str(e.get("ai_stack", []).map(func(q): return q[1])), "" if e["alive"] else "(dead)", e["x"], e["y"], e["hp"]])
				print("[test] enemies ", st)
			print("[test] alive ", Game.area_states.get(key2, []).size(), " drops ", Game.area_drops.get(key2, []), " hp ", L.fighter.hp, "/", L.fighter.maxhp, " sims ", Game.sims.get(key2).enemies.size() if Game.sims.has(key2) else -1)
			print("[test] t ", test_t, " P", L.k + 1, " node ", L.node_i, " at ", int(L.fighter.x), ",", int(L.fighter.y), " screen ", world.svs[0].size / 2.0 + world.views[L.node_i].offset + Vector2(L.fighter.x, L.fighter.y) - world.cams[world.locals.find(L)].position, " line ", world.line_px, " split ", world.split_now, " dir ", world.split_dir, " views ", world.views.size(), " partners ", Game.remote_states.keys())
	if test_t == int(test.get("frames", "600")):
		for L in world.locals:
			print("[test] music ", Music.current, " made ", Music.made.keys(), " playing ", Music.a.playing, " stream ", Music.a.stream, " sfx ", Sfx.streams.size())
			print("[test] quests P", L.k + 1, " ", L.fighter.quests, " done ", L.fighter.qdone, " equip ", L.fighter.equip)
			print("[test] inv P", L.k + 1, " ", L.fighter.inv, " zeni ", L.fighter.zeni, " quick ", L.fighter.quick)
			print("[test] done at ", test_t, " P", L.k + 1, " node ", L.node_i, " hp ", L.fighter.hp, " lvl ", L.fighter.level, " exp ", L.fighter.exp, " kills ", L.kills, " partners ", Game.remote_states.size(), " enemies here ", Game.area_states.get(Game.planet.nodes[L.node_i]["key"], []).size(), " host ", Game.is_host())
		get_tree().quit()

func _script_keys(script: String) -> Dictionary:
	var k = {}
	for part in script.split(";", false):
		var p = part.split(":")
		if p.size() == 3 and test_t >= int(p[0]) and test_t < int(p[1]):
			for ch in p[2]:
				k[{"u": "up", "d": "down", "l": "left", "r": "right", "a": "a", "b": "b", "F": "toggle", "s": "sp", "t": "tr", "i": "it", "n": "nx", "m": "mn", "g": "run", "y": "fly"}.get(ch, "x")] = true
	return k

# test aid: a tour through a land - A* over its walk grid, from map to map (shows the joined world)
var walk_path = []
var walk_stuck = 0
var tour_grid: AStarGrid2D
var tour_area = ""
var tour_path = []
var tour_goal = 0
func _tour_keys(L) -> Dictionary:
	var f = L.fighter
	var a: Dictionary = L.area
	if tour_area != str(a["key"]):
		tour_area = str(a["key"])
		tour_grid = AStarGrid2D.new()
		tour_grid.region = Rect2i(0, 0, a["tw"], a["th"])
		tour_grid.cell_size = Vector2(8, 8)
		tour_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
		tour_grid.update()
		var walk: PackedByteArray = a["walk"]
		var tw: int = a["tw"]
		for y in a["th"]:
			for x in tw:
				if walk[y * tw + x] == 0:
					tour_grid.set_point_solid(Vector2i(x, y), true)
		# doors and ways to other regions: walk past them, not into them (this tour stays in one region)
		for ex in Game.planet.nodes[L.node_i]["exits"]:
			var r: Array = ex["rect"]
			for y in range(int(r[1]) / 8 - 1, int(r[3]) / 8 + 2):
				for x in range(int(r[0]) / 8 - 1, int(r[2]) / 8 + 2):
					if tour_grid.is_in_boundsv(Vector2i(x, y)):
						tour_grid.set_point_solid(Vector2i(x, y), true)
		tour_path = []
		tour_goal = 0
	if tour_path.is_empty():
		var info = a.get("land", {}).get("info", {})
		var ms: Array = info.get("maps", [])
		if ms.size() <= 1:
			# a house or a small place: back out through the nearest door
			var best = null
			var bd = 1e9
			for ex in Game.planet.nodes[L.node_i]["exits"]:
				var r: Array = ex["rect"]
				var c = Vector2((r[0] + r[2]) / 2.0, (r[1] + r[3]) / 2.0)
				if c.distance_to(Vector2(f.x, f.y)) < bd:
					bd = c.distance_to(Vector2(f.x, f.y)); best = c
			if best == null:
				return {}
			var dv0 = best - Vector2(f.x, f.y)
			var k0 = {}
			if dv0.x > 2: k0["right"] = true
			elif dv0.x < -2: k0["left"] = true
			if dv0.y > 2: k0["down"] = true
			elif dv0.y < -2: k0["up"] = true
			return k0
		var km = Assets.json(Assets.base_dir.path_join("kit/maps.json"))
		for tries in ms.size():
			var m = ms[tour_goal % ms.size()]
			var size = Vector2(320, 240)
			for mm in km["maps"]:
				if mm["key"] == m[0]:
					size = Vector2(int(mm["tw"]) * 8, int(mm["th"]) * 8)
			var goal = Game.planet.safe_point(L.node_i, Vector2(float(m[1]), float(m[2])) + size / 2.0)
			var from = Vector2i(int(f.x) / 8, int(f.y) / 8)
			var to = Vector2i(int(goal.x) / 8, int(goal.y) / 8)
			if tour_grid.is_in_boundsv(from) and tour_grid.is_in_boundsv(to) and not tour_grid.is_point_solid(to):
				tour_grid.set_point_solid(from, false)
				tour_path = Array(tour_grid.get_id_path(from, to))
				if tour_path.size() > 4:
					print("[test] tour to map ", m[0], " (", tour_path.size(), " steps)")
					break
				if tour_path.size() > 0:
					tour_path = []   # already there: the next one
			tour_goal += 1
	if tour_path.is_empty():
		return {}
	var here = Vector2(f.x, f.y)
	while not tour_path.is_empty() and (Vector2(tour_path[0]) * 8 + Vector2(4, 4)).distance_to(here) < 6:
		tour_path.pop_front()
	if tour_path.is_empty():
		tour_goal += 1      # arrived: on to the next map
		return {}
	# knocked off the way (or back on your feet somewhere else): plan again to the same map
	if (Vector2(tour_path[0]) * 8 + Vector2(4, 4)).distance_to(here) > 28:
		tour_path = []
		return {}
	if test.has("nofight"):
		var dv1 = Vector2(tour_path[0]) * 8 + Vector2(4, 4) - here
		var k1 = {}
		if dv1.x > 1.5: k1["right"] = true
		elif dv1.x < -1.5: k1["left"] = true
		if dv1.y > 1.5: k1["down"] = true
		elif dv1.y < -1.5: k1["up"] = true
		return k1
	# a foe right in the way: fight it
	var key2: String = Game.planet.nodes[L.node_i]["key"]
	for e in Game.area_states.get(key2, []):
		var ev = Vector2(float(e[1]), float(e[2])) - here
		var by_door = false
		for ex in Game.planet.nodes[L.node_i]["exits"]:
			var r: Array = ex["rect"]
			if Rect2(r[0] - 40, r[1] - 40, r[2] - r[0] + 80, r[3] - r[1] + 80).has_point(here + ev):
				by_door = true
		if ev.length() < 30 and not (int(e[9]) & 4) and not by_door:
			var kk = {}
			if absf(ev.x) > absf(ev.y):
				kk["right" if ev.x > 0 else "left"] = test_t % 6 == 0
			else:
				kk["down" if ev.y > 0 else "up"] = test_t % 6 == 0
			kk["a"] = test_t % 18 < 3
			return kk
	var dv = Vector2(tour_path[0]) * 8 + Vector2(4, 4) - here
	var k = {}
	if dv.x > 1.5: k["right"] = true
	elif dv.x < -1.5: k["left"] = true
	if dv.y > 1.5: k["down"] = true
	elif dv.y < -1.5: k["up"] = true
	return k

func _bot_keys(L, li: int) -> Dictionary:
	if test.has("tour") and li == 0:
		return _tour_keys(L)
	# test aid: walk to the nearest enemy and fight it (punch chain, now and then a ki blast); no enemy: the next way out
	var f = L.fighter
	var node_i: int = L.node_i
	var key: String = Game.planet.nodes[node_i]["key"]
	var best = null
	var bd = 1e9
	for e in Game.area_states.get(key, []):
		var d = Vector2(float(e[1]) - f.x, float(e[2]) - f.y).length()
		if d < bd:
			bd = d; best = e
	var k = {}
	var target = Vector2.ZERO
	if test.has("explore") or (li == 1 and test.has("explore2")):
		best = null
	if best != null:
		target = Vector2(float(best[1]), float(best[2]))
	else:
		var ex = Game.planet.nodes[node_i]["exits"]
		if ex.is_empty():
			return k
		var pick = ex[(test_t / 700 + node_i + li) % ex.size()]
		var r = pick["rect"]
		target = Vector2((r[0] + r[2]) / 2.0, (r[1] + r[3]) / 2.0)
	var dv = target - Vector2(f.x, f.y)
	if best != null and dv.length() < 26:
		# face it, then hit
		if absf(dv.x) > absf(dv.y):
			k["right" if dv.x > 0 else "left"] = test_t % 6 == 0
		else:
			k["down" if dv.y > 0 else "up"] = test_t % 6 == 0
		k["a"] = test_t % 18 < 3
		return k
	if best != null and dv.length() < 90 and test_t % 120 < 3 and f.ep > 4 and (absf(dv.x) < 8 or absf(dv.y) < 8):
		k["b"] = true
		return k
	if dv.x > 2: k["right"] = true
	elif dv.x < -2: k["left"] = true
	if dv.y > 2: k["down"] = true
	elif dv.y < -2: k["up"] = true
	# stuck: wiggle
	if test_t % 240 > 200:
		k = {"up": test_t % 480 > 440, "down": test_t % 480 <= 440, "right": true}
	return k


## any window, any screen: the picture fills it (no black bars) - a bigger or wider screen shows more of the world,
## the pixels stay sharp (each game pixel is a whole number of screen pixels: 4 on a 1080p screen, 5 on 1440p)
var _fit_size = Vector2i.ZERO
var _ft_last = 0
var _ft_max = 0
func _fit_view() -> void:
	if dev != null and is_instance_valid(dev):
		return      # the DEV TOOLS size the screen themselves
	var win = get_window()
	var ws = win.size
	if ws.x <= 0 or ws.y <= 0:
		return
	var z = int(Game.cfg.get("view_zoom", 0)) if Game.cfg is Dictionary else 0
	# the biggest whole-number pixel size that still leaves the menus their 480 x 270 (a 1366 x 768 laptop: 2x, not 3x
	# - at 3x the menus' edges were cut off); a VIEW SIZE chosen in OPTIONS is held to that too
	var kmax = maxi(1, mini(int(ws.x / 480), int(ws.y / 270)))
	var k = z if z > 0 else kmax      # AUTO: the biggest that leaves the menus room; PIXELS xN: as chosen
	var sz = Vector2i(maxi(240, ws.x / k), maxi(160, ws.y / k))
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	# fractional: the picture always fills the whole window or screen (never a black border), at k x pixels
	win.content_scale_stretch = Window.CONTENT_SCALE_STRETCH_FRACTIONAL
	win.content_scale_size = sz
	_fit_size = ws
	_place_gba.call_deferred()

# ------------------------------------------------------------------ GBA-STYLE MENUS (Android port, v44 "console-like")
## Every screen is drawn in the GBA's own pixels: a 320x180 room scaled 1.5 (whole screen pixels on a 1080p handheld),
## with the title picture, the galaxy and the two fonts read from the player's game file by the importer.
## B (or ESC) goes back on every screen (_global_back).
const GW = 320.0
const GH = 180.0
const G_CYAN = Color(0, 1, 1)
const G_PICK = Color(1, 0.85, 0.2)
var gba: Control
var _gal: TextureRect
var _gal_t = 0.0

## the GBA menus fill the screen: as big as fits (in half steps - the pixel fonts stay sharp), in the middle
## (fixed at 1.5 they sat small in the top-left corner of a bigger view - a laptop window, a big monitor)
var _gal_holder: Control
func _place_gba() -> void:
	_place_box()
	if gba == null or not is_instance_valid(gba):
		return
	var vp = get_viewport().get_visible_rect().size
	# exactly as big as fits (a 16:9 screen: all of it) - or, behind the title picture, as big as covers the screen
	var k = maxf(vp.x / GW, vp.y / GH) if gba.has_meta("cover") else minf(vp.x / GW, vp.y / GH)
	gba.scale = Vector2(k, k)
	gba.position = ((vp - Vector2(GW, GH) * k) / 2.0).floor()
	if _gal_holder != null and is_instance_valid(_gal_holder):
		_gal_holder.scale = Vector2(k, k)
		_gal_holder.position = Vector2.ZERO
		_gal_holder.size = vp / k
		if _gal != null and is_instance_valid(_gal):
			_gal.size = vp / k + Vector2(128, 128)

func _gba_screen(galaxy: bool = true) -> Control:
	_global_back = Callable()
	_outfit_cycle = Callable()
	_typing = Callable()
	in_local_mp = false
	finding = false
	_clear()
	gba = Control.new()
	gba.size = Vector2(GW, GH)
	_place_gba()
	gba.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	Music.play("rom:%d" % Assets.MENU_SONG)      # the game's title song on every menu
	_gal = null
	_gal_holder = null
	set_process(true)
	if galaxy:
		# the galaxy fills the whole screen behind the menu (inside the menu's own box it showed as a second frame)
		var bk2 = ColorRect.new(); bk2.color = Color.BLACK; bk2.set_anchors_preset(Control.PRESET_FULL_RECT); bk2.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ui.add_child(bk2)
		_gal_holder = Control.new(); _gal_holder.clip_contents = true; _gal_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_gal_holder.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		ui.add_child(_gal_holder)
		_gal = TextureRect.new()
		_gal.texture = Assets.texture(Assets.base_dir.path_join("ui/galaxy.png"))
		_gal.stretch_mode = TextureRect.STRETCH_TILE
		_gal.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_gal_holder.add_child(_gal)
		_gal.position = Vector2(-fmod(_gal_t * GAL_SPEED.x, 128.0), -fmod(_gal_t * GAL_SPEED.y, 128.0))
	else:
		gba.set_meta("cover", true)      # the title picture covers the whole screen (a different shape: a sliver trimmed)
		var bk = ColorRect.new(); bk.color = Color.BLACK; bk.size = Vector2(GW, GH); gba.add_child(bk)
	ui.add_child(gba)
	_place_gba()
	lobby_label = _gtext(gba, "", Vector2(0, GH - 14))
	lobby_label.size = Vector2(GW, 14)
	lobby_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return gba

## text in a GBA font (the small menu one, or the italic heading one), with the game's shadow
func _gtext(p: Node, t: String, pos: Vector2, head: bool = false, col: Color = Color.WHITE) -> Label:
	var l = Label.new()
	l.text = t
	var f = Assets.gba_font("font_head" if head else "font_small")
	if f:
		l.add_theme_font_override("font", f)
		l.add_theme_font_size_override("font_size", 16)
	else:
		l.add_theme_font_size_override("font_size", 10)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_shadow_color", Color.BLACK)
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	l.add_theme_constant_override("shadow_outline_size", 0)
	l.position = pos
	p.add_child(l)
	return l

func _gheading(t: String) -> void:
	var l = _gtext(gba, t, Vector2(0, 3), true, G_CYAN)
	l.size = Vector2(GW, 18)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

## a menu choice: a line of text that turns gold when picked (d-pad + A, or a tap)
func _gbutton(p: Node, t: String, f: Callable, head: bool = false, w: float = GW) -> Button:
	var b = Button.new()
	b.text = t
	var fo = Assets.gba_font("font_head" if head else "font_small")
	if fo:
		b.add_theme_font_override("font", fo)
		b.add_theme_font_size_override("font_size", 16)
	var se = StyleBoxEmpty.new()
	se.content_margin_bottom = 6      # the text sits up in its row (the font hangs low: the bottom of a word chose the row below)
	for st in ["normal", "hover", "pressed", "focus", "disabled"]:
		b.add_theme_stylebox_override(st, se)
	b.add_theme_color_override("font_color", Color.WHITE)
	for st in ["font_hover_color", "font_focus_color", "font_pressed_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(st, G_PICK)
	b.add_theme_color_override("font_outline_color", Color.BLACK)
	b.custom_minimum_size = Vector2(w, 15)
	b.size = b.custom_minimum_size
	b.pressed.connect(f)
	p.add_child(b)
	if w >= 60 and not _no_balls:
		_ball_cursor(b, fo)
	return b

## the GBA's little Dragon Balls either side of the picked choice (the title menu's own, from the game file)
var _ball_tex: Texture2D
var _balls_both = false
var _no_balls = false
func _ball_cursor(b: Button, fo: Font) -> void:
	if _ball_tex == null:
		_ball_tex = Assets.texture(Assets.base_dir.path_join("ui/ball.png"))
	if _ball_tex == null or fo == null:
		return
	var balls = []
	for side in ([-1, 1] if _balls_both else [-1]):      # the title: one each side; the galaxy menus: one on the left
		var t = TextureRect.new()
		t.texture = _ball_tex
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		t.visible = false
		b.add_child(t)
		balls.append([t, side])
	var place = func():
		var tw = fo.get_string_size(b.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
		for e in balls:
			var cx = b.size.x / 2.0 + e[1] * (tw / 2.0 + 8.0)
			var lift = b.get_theme_stylebox("normal").content_margin_bottom if b.has_theme_stylebox("normal") else 0.0
			e[0].position = Vector2(roundf(cx - 4.0), roundf((b.size.y - lift) / 2.0 - 4.0))      # (level with the text, which sits up in its row)
	b.focus_entered.connect(func():
		place.call()
		for e in balls: e[0].visible = true)
	b.focus_exited.connect(func():
		for e in balls: e[0].visible = false)

## choices one under the other, centred; the first one has the pad's focus
func _glist(items: Array, y: float, gap: float = 16.0, head: bool = false) -> Array:
	var out = []
	for i in items.size():
		var b = _gbutton(gba, items[i][0], items[i][1], head)
		b.position = Vector2(0, y + i * gap)
		out.append(b)
	_focus_remembered(out)
	return out

## each screen remembers the choice you last pressed (B comes back to it, not to the top)
var _last_pick = {}
func _focus_remembered(out: Array) -> void:
	if out.is_empty():
		return
	var key = out[0].text
	var pick = out[0]
	for b in out:
		b.pressed.connect(func(): _last_pick[key] = b.text)
		if _last_pick.get(key, "") == b.text:
			pick = b
	pick.add_to_group("first_focus")
	pick.grab_focus.call_deferred()

## a long list that scrolls (maps, stories)
func _gscroll(items: Array, y: float, h: float) -> Array:
	var sc = ScrollContainer.new()
	sc.position = Vector2(0, y); sc.size = Vector2(GW, h)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	sc.follow_focus = true
	gba.add_child(sc)
	var v = VBoxContainer.new(); v.add_theme_constant_override("separation", 0); sc.add_child(v)
	var out = []
	for it in items:
		out.append(_gbutton(v, it[0], it[1]))
	_focus_remembered(out)
	return out

func _gpanel(rect: Rect2) -> Panel:
	var p = Panel.new()
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.05, 0.25, 0.85); sb.border_color = Color(0.55, 0.78, 1.0); sb.set_border_width_all(1)
	p.add_theme_stylebox_override("panel", sb)
	p.position = rect.position; p.size = rect.size
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gba.add_child(p)
	return p

## the GBA's box frame (the SELECT GAME slots): blue, light blue, blue, a black line, then the inside; gold when picked
func _gba_frame(picked: bool) -> StyleBoxTexture:
	var c = {"b": Color8(255, 198, 0) if picked else Color8(107, 181, 222), "L": Color8(255, 240, 160) if picked else Color8(181, 222, 239), "k": Color.BLACK}
	var rows = ["..bbbbbbb..", ".bbLLLLLbb.", "bbLbbbbbLbb", "bLbkkkkkbLb", "bLbk...kbLb", "bLbk...kbLb", "bLbk...kbLb", "bLbkkkkkbLb", "bbLbbbbbLbb", ".bbLLLLLbb.", "..bbbbbbb.."]
	var img = Image.create(11, 11, false, Image.FORMAT_RGBA8)
	for y in 11:
		for x in 11:
			if c.has(rows[y][x]):
				img.set_pixel(x, y, c[rows[y][x]])
	var st = StyleBoxTexture.new()
	st.texture = ImageTexture.create_from_image(img)
	st.texture_margin_left = 4; st.texture_margin_right = 4; st.texture_margin_top = 4; st.texture_margin_bottom = 4
	return st

## a hero's standing picture cut to its own pixels (so it sits in the middle of its box)
## the hero walking towards you on the character screen: his walk frames, all cut from one box (no jitter)
func _hero_walk(i: int) -> Array:
	var d = Assets.sprite_set(Assets.character_set(i))
	if d.is_empty() or d["tex"] == null:
		return []
	var slots: Array = d["slots"]
	var s = 4 if slots.size() > 4 and slots[4].size() > 1 else 0
	if slots.size() <= s or slots[s].size() == 0:
		return []
	var cell: int = d["cell"]
	var img: Image = d["img"] if d.has("img") else d["tex"].get_image()
	var u = Rect2i()
	for f in slots[s].size():
		var r = img.get_region(Rect2i(f * cell, s * cell, cell, cell)).get_used_rect()
		if r.size.x > 0:
			u = r if u.size.x == 0 else u.merge(r)
	if u.size.x <= 0:
		return []
	var out = []
	for f in slots[s].size():
		var at = AtlasTexture.new(); at.atlas = d["tex"]; at.region = Rect2(u.position + Vector2i(f * cell, s * cell), u.size)
		out.append(at)
	return out

var _walk_t = 0
func _walk_tick() -> void:
	_walk_t += 1
	for i in _char_cells:
		var c = _char_cells[i]
		if not is_instance_valid(c[2]):
			continue
		var fr = _hero_walk(i) if not c[2].has_meta("walk") or c[2].get_meta("walk_set") != Assets.character_set(i) else c[2].get_meta("walk")
		c[2].set_meta("walk", fr); c[2].set_meta("walk_set", Assets.character_set(i))
		if not fr.is_empty():
			_fit_picture(c[2], fr[_walk_t % fr.size()])

## a hero's name on one line: shrunk to fit its box when it is long (no second line pushing the box down)
func _one_line(l: Label, w: float) -> void:
	# the name is drawn by a label of its own inside this fixed box, shrunk to fit: the box never changes size
	var inner: Label = l.get_node_or_null("inner")
	if inner == null:
		inner = l.duplicate()
		inner.name = "inner"
		inner.custom_minimum_size = Vector2.ZERO
		l.add_child(inner)
		l.add_theme_color_override("font_color", Color(0, 0, 0, 0))
		l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0))
		l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0))
	l.clip_text = true
	inner.autowrap_mode = TextServer.AUTOWRAP_OFF
	inner.text = l.text
	inner.size = Vector2.ZERO
	var tw = inner.get_combined_minimum_size().x
	var k = minf(1.0, (w - 2.0) / maxf(1.0, tw))
	inner.scale = Vector2(k, k)
	inner.size = Vector2(tw, l.custom_minimum_size.y)
	inner.position = Vector2((w - tw * k) * 0.5, l.custom_minimum_size.y * (1.0 - k))

func _hero_picture(i: int) -> Texture2D:
	var d = Assets.sprite_set(Assets.character_set(i))
	if d.is_empty() or d["tex"] == null or d["slots"].size() == 0 or d["slots"][0].size() == 0:
		return null
	var cell: int = d["cell"]
	var img: Image = d["img"] if d.has("img") else d["tex"].get_image()
	var r = img.get_region(Rect2i(0, 0, cell, cell)).get_used_rect()
	if r.size.x <= 0:
		return null
	var at = AtlasTexture.new(); at.atlas = d["tex"]; at.region = Rect2(r)
	return at

## the galaxy drifts every frame and wraps at exactly its own size (128): a seamless loop, as on the GBA
const GAL_SPEED = Vector2(40.0, 20.0)      # GBA pixels a second
func _gal_scroll(dt: float) -> void:
	if _gal != null and is_instance_valid(_gal):
		_gal_t += dt
		_gal.position = Vector2(-fmod(_gal_t * GAL_SPEED.x, 128.0), -fmod(_gal_t * GAL_SPEED.y, 128.0))

# ---- the title picture: the game's own, with its tiny "TM" and copyright line drawn again in sharp white text
var _title_tex: Texture2D
var _title_wide_tex: Texture2D
## wide: the box round the choices drawn wider (SINGLE PLAYER / MULTIPLAYER are longer words than START / OPTIONS)
func _title_texture(wide: bool = false) -> Texture2D:
	if wide and _title_wide_tex:
		return _title_wide_tex
	if not wide and _title_tex:
		return _title_tex
	var img = Assets.image(Assets.base_dir.path_join("ui/title.png"))
	if img == null:
		return null
	img.convert(Image.FORMAT_RGBA8)
	# the old letters are painted out: each column of their band blends from the picture just above to just below
	# the copyright band: only the old letters are filled in from the picture round them - the rest stays as drawn
	_unletter(img, Rect2i(20, 146, 196, 13))
	for r in [Rect2i(204, 68, 8, 5)]:
		for x in range(r.position.x, r.end.x):
			var top = img.get_pixel(x, r.position.y - 1); var bot = img.get_pixel(x, r.end.y)
			for y in range(r.position.y, r.end.y):
				img.set_pixel(x, y, top.lerp(bot, float(y - r.position.y + 1) / (r.size.y + 1)))
	if wide:
		_widen_box(img, 14)
		_title_wide_tex = ImageTexture.create_from_image(img)
		return _title_wide_tex
	_title_tex = ImageTexture.create_from_image(img)
	return _title_tex

## the game's tiny copyright letters (white, edged in neutral grey) taken out of the picture: each letter pixel is filled
## from the picture's own pixels next to it, working inwards, so the art round them is untouched
func _unletter(img: Image, r: Rect2i) -> void:
	var todo = {}
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var c = img.get_pixel(x, y)
			if absf(c.r - c.g) < 0.02 and absf(c.g - c.b) < 0.02 and c.r > 0.35:
				todo[Vector2i(x, y)] = true
	for _pass in 12:
		if todo.is_empty():
			break
		var fill = {}
		for p in todo:
			var sum = Color(0, 0, 0, 0)
			var n = 0
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var q = p + d
				if not todo.has(q) and q.x >= 0 and q.y >= 0 and q.x < img.get_width() and q.y < img.get_height():
					sum += img.get_pixel(q.x, q.y)
					n += 1
			if n > 0:
				fill[p] = sum / n
		for p in fill:
			img.set_pixelv(p, fill[p])
			todo.erase(p)

## the title's box (a one-pixel bevel: light top and left, black bottom and right) painted out and drawn again wider
const BOX_L = 80
const BOX_R = 159
const BOX_T = 104
const BOX_B = 143
func _widen_box(img: Image, by: int) -> void:
	var light = img.get_pixel(100, BOX_T)
	var src: Image = img.duplicate()
	for x in range(BOX_L, BOX_R + 1):          # the old lines take the picture just outside them
		img.set_pixel(x, BOX_T, src.get_pixel(x, BOX_T - 1))
		img.set_pixel(x, BOX_B, src.get_pixel(x, BOX_B + 1))
	for y in range(BOX_T, BOX_B + 1):
		img.set_pixel(BOX_L, y, src.get_pixel(BOX_L - 1, y))
		img.set_pixel(BOX_L + 1, y, src.get_pixel(BOX_L - 1, y) if y >= BOX_B - 2 else img.get_pixel(BOX_L + 1, y))
		img.set_pixel(BOX_R, y, src.get_pixel(BOX_R + 1, y))
		img.set_pixel(BOX_R - 1, y, src.get_pixel(BOX_R + 1, y) if y <= BOX_T + 1 or y >= BOX_B - 1 else img.get_pixel(BOX_R - 1, y))
	var l = BOX_L - by; var r = BOX_R + by
	for x in range(l + 3, r - 1):
		img.set_pixel(x, BOX_T, light)
	for x in range(l + 2, r - 1):
		img.set_pixel(x, BOX_B, Color.BLACK)
	for y in range(BOX_T + 1, BOX_B - 1):
		img.set_pixel(l, y, light)
		img.set_pixel(r, y, Color.BLACK)
	img.set_pixel(r - 1, BOX_T + 1, light)
	img.set_pixel(r - 1, BOX_B - 1, Color.BLACK)
	img.set_pixel(l + 1, BOX_B - 1, Color.BLACK)

## the title stretched over the whole screen (the user's choice: no bars)
const TSX = GW / 240.0
const TSY = GH / 160.0
const TS = TSY
func _title_art(wide: bool = false) -> void:
	var t = TextureRect.new()
	t.texture = _title_texture(wide)
	t.scale = Vector2(TSX, TSY)
	gba.add_child(t)
	# the "TM" and the copyright line in the GBA's own menu letters (white, outlined in black), half size
	var fs = Assets.gba_font("font_small")
	var small = func(text: String, x_center: float, y: float, w: float, k: float = 0.5) -> void:
		var holder = Control.new()
		holder.scale = Vector2(TSX * k, TSY * k)
		holder.position = Vector2((x_center - w * k / 2.0) * TSX, y * TSY)
		gba.add_child(holder)
		for o in [Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1), Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1), Vector2.ZERO]:
			var l = Label.new()
			l.text = text
			if fs:
				l.add_theme_font_override("font", fs)
				l.add_theme_font_size_override("font_size", 16)
			l.add_theme_color_override("font_color", Color.WHITE if o == Vector2.ZERO else Color.BLACK)
			l.position = o
			holder.add_child(l)
	var tw = fs.get_string_size("(C) 2003 BIRD STUDIOS/SHUEISHA, TOEI ANIMATION", HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x if fs else 240.0
	small.call("(C) 2003 BIRD STUDIOS/SHUEISHA, TOEI ANIMATION", 120.0, 145.0, tw, minf(0.7, 232.0 / maxf(1.0, tw)))
	small.call("TM", 207.0, 64.5, 18.0)
	_title_shine()

## the Dragon Ball in "DRAGON" catches the light every few seconds: a soft glint sweeps across it
const SHINE_C = Vector2(91, 44)
const SHINE_R = 9.0
func _title_shine() -> void:
	var c = Control.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.scale = Vector2(TSX, TSY)
	c.size = Vector2(240, 160)
	gba.add_child(c)
	c.draw.connect(func():
		var t = fmod(Time.get_ticks_msec() / 1000.0, 4.0)
		if t > 0.6:
			return
		var p = lerpf(-SHINE_R * 1.6, SHINE_R * 1.6, t / 0.6)       # the band's place along the diagonal
		for dy in range(-int(SHINE_R), int(SHINE_R) + 1):
			for dx in range(-int(SHINE_R), int(SHINE_R) + 1):
				if dx * dx + dy * dy > SHINE_R * SHINE_R:
					continue
				var d = absf((dx + dy) * 0.7071 - p)
				if d < 2.5:
					c.draw_rect(Rect2(SHINE_C.x + dx, SHINE_C.y + dy, 1, 1), Color(1, 1, 1, 0.55 * (1.0 - d / 2.5))))
	var tm = Timer.new(); tm.wait_time = 1.0 / 30.0; tm.autostart = true
	tm.timeout.connect(c.queue_redraw)
	c.add_child(tm)

## START / OPTIONS (and the next pair) inside the title's own box
func _title_choices(items: Array) -> void:
	_balls_both = true
	var bs = _glist(items, 100 * TSY, 18 * TSY)
	_balls_both = false
	for b in bs:
		b.scale = Vector2(TSX, TSY)
		b.custom_minimum_size.x = GW / TSX
		b.size.x = GW / TSX
		b.position.x = 0
		_outline(b)

## a black outline all round a choice's letters (the GBA title's look): the text drawn in black one pixel off each way, behind
func _outline(b: Button) -> void:
	for o in [Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1), Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
		var l = Label.new()
		l.text = b.text
		l.add_theme_font_override("font", b.get_theme_font("font"))
		l.add_theme_font_size_override("font_size", 16)
		l.add_theme_color_override("font_color", Color.BLACK)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		var lift = b.get_theme_stylebox("normal").content_margin_bottom if b.has_theme_stylebox("normal") else 0.0
		l.size = b.size - Vector2(0, lift)      # (level with the text, which sits up in its row)
		l.position = o
		l.show_behind_parent = true
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(l)

## the game's songs are recorded from the cartridge once: on a slow computer that takes a while - ask how
## (in the background with a stand-in tune meanwhile, or all now with a bar); asked once, kept in options
func _music_question() -> bool:
	if Assets.base_dir == "" or Assets.songs_missing() == 0:
		return false
	var mode = Assets.music_mode()
	if mode == "play":
		return false
	if mode == "now" and not _music_tried:
		_music_now_screen()
		return true
	if mode == "now":
		Assets.start_music_render()
		return false
	_gba_screen()
	_gheading("Music")
	var lines = ["THE GAME'S MUSIC IS RECORDED FROM", "YOUR CARTRIDGE NEXT (%d SONGS)." % Assets.songs_missing(), "ON A SLOWER DEVICE IT CAN TAKE A WHILE."]
	for li in lines.size():
		var t = _gtext(gba, lines[li], Vector2(0, 32 + li * 12))
		t.size = Vector2(GW, 12); t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var bs = _glist([["RECORD WHILE I PLAY", func():
		Assets.set_music_mode("play"); Assets.start_music_render(); _menu()],
		["RECORD ALL NOW (WAIT)", func():
		Assets.set_music_mode("now"); _music_now_screen()]], 88, 18)
	var b1 = bs[0]
	for li in 2:
		var n = _gtext(gba, ["WHILE YOU PLAY: A STAND-IN TUNE UNTIL", "EACH SONG IS READY (WHERE YOU ARE: FIRST)"][li], Vector2(0, 132 + li * 12), false, Color(0.75, 0.85, 1))
		n.size = Vector2(GW, 12); n.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b1.grab_focus.call_deferred()
	return true

## RECORD ALL NOW: the bar fills song by song; the title when they are all there
var _music_tried = false
var _music_bar: Control
var _music_lab: Label
func _music_now_screen() -> void:
	_gba_screen()
	_gheading("Recording Music")
	Assets.start_music_render()
	_music_lab = Label.new(); _music_lab.position = Vector2(24, 70); _music_lab.size = Vector2(GW - 48, 20)
	_music_lab.add_theme_font_size_override("font_size", 8); gba.add_child(_music_lab)
	_music_bar = Control.new(); _music_bar.position = Vector2(24, 92); _music_bar.size = Vector2(GW - 48, 8)
	_music_bar.draw.connect(func(): _draw_bar(_music_bar, float(Assets.music_done) / maxf(1.0, float(Assets.music_total))))
	gba.add_child(_music_bar)
	set_process(true)

func _draw_bar(c: Control, frac: float) -> void:
	var r = Rect2(Vector2.ZERO, c.size)
	var t = Time.get_ticks_msec() / 1000.0
	c.draw_rect(r, Color(0.1, 0.12, 0.2))
	c.draw_rect(Rect2(0, 0, r.size.x * clampf(frac, 0.0, 1.0), r.size.y), Color(0.25, 0.7, 1.0) * (0.82 + 0.18 * sin(t * 4.0)))
	var band = r.size.x * 0.18
	var bx = fmod(t * r.size.x * 0.45, r.size.x + band) - band
	for i in 12:
		var seg = Rect2(bx + band * i / 12.0, 0, band / 12.0 + 1, r.size.y).intersection(r)
		if seg.size.x > 0:
			c.draw_rect(seg, Color(1, 1, 1, 0.22 * (1.0 - absf(i - 5.5) / 6.0)))
	c.draw_rect(r, Color(0.6, 0.8, 1, 0.8), false, 1.0)

# ---- start screen: the title with START / OPTIONS in its box
func _menu() -> void:
	if _music_question():
		return
	_gba_screen(false)
	Game.cfg.erase("story")
	Music.play("rom:%d" % Assets.MENU_SONG)
	Game.cfg.erase("start_at")
	Game.cfg.erase("home_at")
	if Mods.story_pack != "":
		Mods.story_pack = ""
		Mods.reload()
	Game.cfg["local_players"] = 1
	Music.prepare(["field", "cave", "lair", "boss", "victory"])
	_title_art()
	_title_choices([["START", _mode_screen], ["OPTIONS", _options_screen]])
	_prewarm_heroes()

## every hero's picture (and each outfit's) made on another thread while you are still on the menus: the character
## screen opens without a hitch
func _prewarm_heroes() -> void:
	if Assets.base_dir == "":
		return
	var ids = []
	for i in Assets.CHARACTERS.size():
		ids.append(Assets.character_set(i))
		for o in Assets.outfits(i):
			if int(o.get("set", -1)) >= 0:
				ids.append(int(o["set"]))
	Assets.prewarm_sets(ids)

func _mode_screen() -> void:
	_gba_screen(false)
	_global_back = _menu
	_title_art(true)
	_title_choices([["SINGLE PLAYER", _single_screen], ["MULTIPLAYER", _mp_kind]])

func _single_screen() -> void:
	_gba_screen()
	_global_back = _mode_screen
	_gheading("Single Player")
	_mp_flow = false
	_mp_story_slot = 0
	Game.cfg["mode"] = "solo"
	if Mods.story_pack != "":       # (back from a story: its mod is put away before FREE PLAY)
		Mods.story_pack = ""
		Mods.reload()
	_glist([["FREE PLAY", func(): _map_screen(_single_screen, func(): _char_screen(func(): _map_screen(_single_screen, Callable()), func(): _gload(_solo)))],
		["STORY MODE", _story_screen]], 70, 22, true)

# ---- SELECT MAP: the planets and the game's own lands; difficulty on the last line
const G_MAPS = [["EARTH", "land:0"], ["GOKU'S HOUSE", "land:0", {"key": "land/0/0", "x": 13230, "y": 22972}], ["PLANET GATORRA", "gatorra"], ["PLANET DUNARA", "dunara"], ["WEST CITY & TRICERATOPS JUNGLE", "land:4"], ["NORTHERN MOUNTAINS", "land:8"],
	["SOUTHERN CONTINENT", "land:7"], ["GINGERTOWN", "land:10"], ["NORTHERN WASTELANDS", "land:3"], ["TROPICAL ISLANDS", "land:12"],
	["SNOWY HIGHLANDS", "land:13"], ["CAPSULE CORP & NEW NAMEK", "land:6"], ["RANDOM PLANET", "random"]]
var _map_then: Callable
var _map_back: Callable
func _map_screen(back: Callable, then: Callable) -> void:
	if then.is_valid():
		_map_then = then
	_map_back = back
	_gba_screen()
	_global_back = back
	_gheading("Select Map")
	var items = []
	for m in G_MAPS:
		if str(m[1]).begins_with("land:") and not Assets.has_kit():
			continue
		items.append([m[0], _map_chosen.bind(m[1], m[2] if m.size() > 2 else {})])
	var diffs = ["EASY", "NORMAL", "HARD"]
	_gscroll(items, 22, 128)
	var d = _gbutton(gba, "DIFFICULTY: " + diffs[clampi(int(Game.cfg.get("difficulty", 1)), 0, 2)], func(): pass)
	d.position = Vector2(0, 152)
	d.pressed.connect(func():
		Game.cfg["difficulty"] = (int(Game.cfg.get("difficulty", 1)) + 1) % 3
		d.text = "DIFFICULTY: " + diffs[int(Game.cfg["difficulty"])])

func _map_chosen(adv: String, start: Dictionary = {}) -> void:
	Game.cfg["adventure"] = adv
	if start.is_empty():      # GOKU'S HOUSE: EARTH, starting in Gohan's bedroom (Goku's Home) - and beaten, back there
		Game.cfg.erase("start_at")
		Game.cfg.erase("home_at")
	else:
		Game.cfg["start_at"] = start
		Game.cfg["home_at"] = start
	Game.cfg["seed"] = randi() % 1000000
	_map_then.call()

# ---- CHOOSE YOUR CHARACTER: each hero standing in a blue box, the name above, the level on this map below
func _char_screen(back: Callable, then: Callable, who: int = 1) -> void:
	_gba_screen()
	_global_back = back
	_gheading("Choose Your Character" if who == 1 else "Player 2: Your Character")
	var ckey = "character" if who == 1 else "character2"
	var levels = {}       # FREE PLAY heroes grow on every map alike (Game.shared_entry)
	for i in Assets.CHARACTERS.size():
		var e = Game.shared_entry(str(i))
		if not e.is_empty():
			levels[str(i)] = e
	var cells = {}
	_outfit_shoulders(cells)
	var sc = ScrollContainer.new(); sc.position = Vector2(9, 26); sc.size = Vector2(GW - 9, GH - 28)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED; sc.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_char_sc = sc
	_char_top = 0
	gba.add_child(sc)
	var grid = GridContainer.new(); grid.columns = 5
	grid.add_theme_constant_override("h_separation", 3); grid.add_theme_constant_override("v_separation", 4)
	sc.add_child(grid)
	var first: Button = null
	for i in Assets.CHARACTERS.size():
		var cell = VBoxContainer.new(); cell.add_theme_constant_override("separation", 0)
		cell.custom_minimum_size = Vector2(58, 0)
		grid.add_child(cell)
		var name_l = _gtext(cell, Assets.hero_shown_name(i), Vector2.ZERO)
		name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_l.custom_minimum_size = Vector2(58, 14)
		name_l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		_one_line(name_l, 58)
		var b = Button.new()
		b.custom_minimum_size = Vector2(44, 44)
		b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		var sb = _gba_frame(false); var sf = _gba_frame(true)
		for st in ["normal", "disabled"]: b.add_theme_stylebox_override(st, sb)
		for st in ["hover", "pressed", "focus"]: b.add_theme_stylebox_override(st, sf)
		b.pressed.connect(func():
			if _hero_locked(i, levels):      # not earned yet: a beep, nothing else
				Sfx.play("error")
				return
			Game.cfg[ckey] = i; _name_screen(func(): _char_screen(back, then, who), then, who))
		cell.add_child(b)
		var tr = TextureRect.new()
		tr.set_anchors_preset(Control.PRESET_FULL_RECT); tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_fit_picture(tr, _hero_picture(i))
		b.add_child(tr)
		cells[i] = [name_l, b, tr]
		b.focus_entered.connect(func(): _char_focus = i; _char_page.call_deferred(i))
		var lv = "NEW"
		if levels.has(str(i)) and levels[str(i)] is Dictionary:
			lv = "LV %d" % int(levels[str(i)].get("level", 1))
		if _hero_locked(i, levels):
			lv = "LOCKED"
		var lv_l = _gtext(cell, lv, Vector2.ZERO, false, Color(0.75, 0.9, 1))
		lv_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lv_l.custom_minimum_size = Vector2(58, 13)
		if i == int(Game.cfg.get(ckey, 0)):
			first = b
			_char_focus = i
	if first:
		first.add_to_group("first_focus")
		first.grab_focus.call_deferred()
	# L / R (bumpers or triggers, Q / E on a keyboard, or a tap on the corners): the highlighted hero's next outfit
	_char_cells = cells
	# up / down between the rows by hand: the row out of sight would not be found by the automatic search
	var keys = cells.keys()
	keys.sort()
	for n in keys.size():
		var bt: Button = cells[keys[n]][1]
		if n + 5 < keys.size():
			bt.focus_neighbor_bottom = cells[keys[n + 5]][1].get_path()
		if n - 5 >= 0:
			bt.focus_neighbor_top = cells[keys[n - 5]][1].get_path()
	var ids = []
	for i in Assets.CHARACTERS.size():      # every outfit's picture made ahead, off the screen's thread
		for o in Assets.outfits(i):
			if int(o.get("set", -1)) >= 0:
				ids.append(int(o["set"]))
	Assets.prewarm_sets(ids)
	var wt = Timer.new(); wt.wait_time = 0.16; wt.autostart = true
	wt.timeout.connect(_walk_tick)
	gba.add_child(wt)
	_outfit_cycle = func(step: int):
		var i = _char_focus
		if not cells.has(i) or Assets.outfits(i).size() < 2:
			return
		Assets.set_outfit(i, Assets.outfit_index(i) + step)
		cells[i][0].text = Assets.hero_shown_name(i)
		_one_line(cells[i][0], 58)
		_fit_picture(cells[i][2], _hero_picture(i))
		_walk_tick()

## the GBA's grey shoulder buttons in the top corners, "< OUTFIT >" under each (a tap works too)
## heroes to earn: the level any of your other heroes must reach first (-1: not playable yet at all). Locked: "LOCKED", A beeps
const LOCKED_HEROES = {"KING COLD": -1}
func _hero_locked(i: int, levels: Dictionary) -> bool:
	var need = int(LOCKED_HEROES.get(Assets.CHARACTERS[i], 0))
	if need == 0:
		return false
	if need < 0:
		return true
	var best = 0
	for k in levels:      # the best of the heroes you can always play (a villain does not unlock himself)
		var ki = int(k)
		if ki >= 0 and ki < Assets.CHARACTERS.size() and not LOCKED_HEROES.has(Assets.CHARACTERS[ki]) and levels[k] is Dictionary:
			best = maxi(best, int(levels[k].get("level", 1)))
	return best < need
var _char_focus = 0
## two whole rows at a time (names and levels with them): the list moves a row when the cursor leaves the two shown
var _char_sc: ScrollContainer
var _char_top = 0
func _char_page(i: int) -> void:
	if _char_sc == null or not is_instance_valid(_char_sc) or _char_sc.get_child_count() == 0:
		return
	var grid: GridContainer = _char_sc.get_child(0)
	if grid.get_child_count() == 0:
		return
	var rh = grid.get_child(0).size.y + grid.get_theme_constant("v_separation")
	var r = i / grid.columns
	if r < _char_top:
		_char_top = r
	elif r > _char_top + 1:
		_char_top = r - 1
	_char_sc.scroll_vertical = int(_char_top * rh)
var _char_cells = {}
var _outfit_cycle: Callable = Callable()
var _trig_prev = {}
func _outfit_shoulders(cells: Dictionary) -> void:
	for side in [-1, 1]:
		var b = Button.new()
		b.icon = _shoulder_icon(side < 0)
		for st in ["normal", "focus", "disabled", "hover", "pressed"]: b.add_theme_stylebox_override(st, StyleBoxEmpty.new())
		b.focus_mode = Control.FOCUS_NONE
		b.position = Vector2(4, 1) if side < 0 else Vector2(GW - 32, 1)
		b.size = Vector2(28, 10)
		b.pressed.connect(func(): if _outfit_cycle.is_valid(): _outfit_cycle.call(side))
		gba.add_child(b)
		var t = _gtext(gba, "< OUTFITS" if side < 0 else "OUTFITS >", Vector2(1, 12) if side < 0 else Vector2(GW - 61, 12), false, Color(0.8, 0.85, 0.95))
		t.size = Vector2(60, 10)
		t.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if side < 0 else HORIZONTAL_ALIGNMENT_RIGHT

## a hero's picture in its box: pixel for pixel, or shrunk to fit when bigger than the box (King Cold, Cell...)
func _fit_picture(tr: TextureRect, pic: Texture2D) -> void:
	tr.texture = pic
	var big = pic != null and (pic.get_width() > 36 or pic.get_height() > 36)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE if big else TextureRect.EXPAND_KEEP_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED if big else TextureRect.STRETCH_KEEP_CENTERED
	tr.offset_left = 4 if big else 0; tr.offset_top = 4 if big else 0; tr.offset_right = -4 if big else 0; tr.offset_bottom = -4 if big else 0

## a GBA shoulder button: a grey cap with a rounded outer corner and its letter
func _shoulder_icon(left: bool) -> ImageTexture:
	var rows = [
		"....kkkkkkkkkkkkkkkkkkkkkkkk",
		"..kkwwwwwwwwwwwwwwwwwwwwwwwk",
		".kwwggggggggggggggggggggggwk",
		"kwggggggggggggggggggggggggdk",
		"kwggggggggggkggggggggggggddk",
		"kwggggggggggkggggggggggggddk",
		"kwggggggggggkggggggggggggddk",
		"kwggggggggggkkkggggggggggddk",
		"kddddddddddddddddddddddddddk",
		"kkkkkkkkkkkkkkkkkkkkkkkkkkkk"]
	var letter_r = ["kkk", "k.k", "kkk", "kk.", "k.k"]
	var img = Image.create(28, 10, false, Image.FORMAT_RGBA8)
	var c = {"k": Color(0.12, 0.12, 0.16), "w": Color(0.88, 0.88, 0.92), "g": Color(0.6, 0.6, 0.66), "d": Color(0.38, 0.38, 0.44)}
	for y in 10:
		for x in 28:
			var ch = rows[y][x]
			if c.has(ch):
				img.set_pixel(x, y, c[ch])
	if not left:
		img.flip_x()
		# the letter R over the flipped L
		for y in range(3, 8):
			for x in range(12, 17):
				img.set_pixel(x, y, c["g"])
		for y in 5:
			for x in 3:
				if letter_r[y][x] == "k":
					img.set_pixel(13 + x, 3 + y, c["k"])
	return ImageTexture.create_from_image(img)

# ---- the loading screen: shown while the world is built (the game is busy for a moment)
func _gload(f: Callable) -> void:
	_gba_screen()
	_gheading("Loading")
	_gpanel(Rect2(60, 84, 200, 12))
	var fill = ColorRect.new(); fill.color = G_CYAN; fill.position = Vector2(62, 86); fill.size = Vector2(0, 8); gba.add_child(fill)
	Music.preload_game_songs()        # every song of the game read now: no song is read while you play
	var t0 = Time.get_ticks_msec()
	var k = 0
	while Music.preloading() and Time.get_ticks_msec() - t0 < 8000:
		k += 1
		fill.size.x = 196.0 * minf(0.8, k / 120.0)
		await get_tree().process_frame
	for j in 4:
		fill.size.x = 196.0 * (0.8 + 0.05 * (j + 1))
		await get_tree().process_frame
	f.call()

# ---- STORY MODE: the stories in the mods, and the original story (still to come)
func _story_screen() -> void:
	_gba_screen()
	_global_back = _mp_kind if _mp_flow else _single_screen
	_gheading("Story Mode")
	var items = []
	for p in Mods.installed_packs():
		var sp = Mods.packs_dir().path_join(str(p["folder"])).path_join("content/story.json")
		if not FileAccess.file_exists(sp):
			continue
		var t = Mods.read_json(sp)
		if t is Dictionary and t.get("story") is Dictionary and str(t["story"].get("title", "")) != "":
			items.append([str(t["story"]["title"]).to_upper(), _story_pick.bind(str(p["folder"]))])
	items.append(["ORIGINAL STORY", _original_story])
	_gscroll(items, 30, 120)

func _original_story() -> void:
	_gba_screen()
	_global_back = _story_screen
	_gheading("Original Story")
	Music.play("rom:7")      # Era of Darkness: the story's own song
	var l = _gtext(gba, "THE ORIGINAL STORY IS STILL BEING REBUILT IN GODOT.\n\nCOME BACK IN A LATER UPDATE!\n\n\nB: BACK", Vector2(10, 50))
	l.size = Vector2(GW - 20, 100)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

## a mod's story: its pack is switched on (it holds the story), then its three save slots
func _story_pick(folder: String) -> void:
	Mods.story_pack = folder       # (only for this story: back at the start menu it is put away again)
	Mods.reload()
	_story_slots()

func _story_slots() -> void:
	_gba_screen()
	_global_back = _story_screen
	_gheading("Select Game")
	var items = []
	for i in 3:
		var path = "user://fighters_story_%s_%d.json" % [_story_id(), i + 1]
		var txt = "NEW GAME"
		var saved = -1
		if FileAccess.file_exists(path):
			var t = JSON.parse_string(FileAccess.get_file_as_string(path))
			if t is Dictionary and not t.is_empty():
				var d: Dictionary = t.values()[0]
				saved = clampi(int(d.get("ch", 0)), 0, Assets.CHARACTERS.size() - 1)
				txt = "%s  LV %d" % [Assets.CHARACTERS[saved], int(d.get("level", 1))]
		var slot = i + 1
		if _mp_flow:
			items.append([txt, func(): _mp_story_slot = slot; _mp_choice()])
		elif saved >= 0:
			items.append([txt, func(): Game.cfg["character"] = saved; _gload(_play_story.bind(slot, false))])
		else:
			items.append([txt, func(): _char_screen(_story_slots, func(): _gload(_play_story.bind(slot, false)))])
	_glist(items, 50, 24, true)
	var st = _gtext(gba, str(Content.story.get("title", "")).to_upper(), Vector2(0, 130), false, Color(0.75, 0.9, 1))
	st.size = Vector2(GW, 14); st.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

# ---- MULTIPLAYER: FREE PLAY or STORY MODE first, then over the internet, on this Wi-Fi or split screen
var _mp_flow = false        # the story screens are on the way to MULTIPLAYER (a slot leads to GLOBAL / LOCAL / SPLIT SCREEN)
var _mp_story_slot = 0      # 0: FREE PLAY; 1-3: the story slot everyone plays together
func _mp_kind() -> void:
	_gba_screen()
	_global_back = _mode_screen
	_gheading("Multiplayer")
	_mp_flow = true
	_mp_story_slot = 0
	Game.cfg.erase("story")
	if Mods.story_pack != "":
		Mods.story_pack = ""
		Mods.reload()
	_glist([["FREE PLAY", func(): _mp_story_slot = 0; Game.cfg.erase("story"); _mp_choice()],
		["STORY MODE", _story_screen]], 70, 22, true)

func _mp_choice() -> void:
	_gba_screen()
	_global_back = _mp_kind if _mp_story_slot == 0 else _story_slots
	_gheading("Story Co-op" if _mp_story_slot > 0 else "Multiplayer")
	_no_balls = true      # (the pictures beside these choices: the gold letters show the pick)
	var bs = _glist([["GLOBAL", _global_multiplayer], ["LOCAL", _local_multiplayer], ["SPLIT SCREEN", _split_screen]], 26, 50, true)
	_no_balls = false
	bs[0].icon = _globe_icon(); bs[1].icon = _wifi_icon(); bs[2].icon = _split_icon()
	for b in bs:
		b.add_theme_constant_override("h_separation", 6)
		b.custom_minimum_size = Vector2(0, 30)
		b.size = b.get_combined_minimum_size()
		b.position.x = (GW - b.size.x) / 2
	var a = _gtext(gba, "PLAY WITH ANYONE OVER THE INTERNET", Vector2(0, 58), false, Color(0.75, 0.9, 1))
	a.size = Vector2(GW, 12); a.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var b2 = _gtext(gba, "PLAY WITH PEOPLE ON YOUR WI-FI", Vector2(0, 108), false, Color(0.75, 0.9, 1))
	b2.size = Vector2(GW, 12); b2.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var c3 = _gtext(gba, "TWO PLAYERS ON THIS DEVICE (A SECOND CONTROLLER)", Vector2(0, 158), false, Color(0.75, 0.9, 1))
	c3.size = Vector2(GW, 12); c3.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

## small pixel pictures: a globe, and Wi-Fi waves over two handhelds
func _pix_icon(rows: Array, cols: Dictionary) -> ImageTexture:
	var img = Image.create(rows[0].length(), rows.size(), false, Image.FORMAT_RGBA8)
	for y in rows.size():
		for x in rows[y].length():
			var ch = rows[y][x]
			if cols.has(ch):
				img.set_pixel(x, y, cols[ch])
	img.resize(img.get_width() * 2, img.get_height() * 2, Image.INTERPOLATE_NEAREST)
	return ImageTexture.create_from_image(img)

func _globe_icon() -> ImageTexture:
	return _pix_icon([
		"....kkkkkk....", "..kkbgggbbkk..", ".kbbgggbbbbbk.", ".kbggggbbbgbk.", "kbbbggbbbggggk", "kbbbbbbbbggggk", "kbbbbgbbbbggbk",
		"kbbbbggbbbbbbk", "kbbbbgggbbbbbk", ".kbbbggbbbbbk.", ".kbbbbgbbbbbk.", "..kkbbbbbbkk..", "....kkkkkk....", ".............."],
		{"k": Color(0, 0, 0), "b": Color(0.2, 0.45, 1), "g": Color(0.25, 0.85, 0.3)})

func _wifi_icon() -> ImageTexture:
	# a big Wi-Fi signal over two of the game's own purple GBAs (the one on a table in a West City home)
	var gba = _game_handheld()
	var w = 40; var h = 32
	var img = Image.create(w, h, false, Image.FORMAT_RGBA8)
	var cx = w / 2.0; var cy = 15.0
	for r in [3.0, 7.0, 11.0]:          # three arcs and a dot, like the signal on a phone
		for k in 200:
			var ang = deg_to_rad(-135.0 + 90.0 * k / 199.0)
			for t in [0.0, 0.8]:
				var px = int(roundf(cx + cos(ang) * (r + t))); var py = int(roundf(cy + sin(ang) * (r + t)))
				if px >= 0 and px < w and py >= 0 and py < h:
					img.set_pixel(px, py, Color(0.6, 0.9, 1))
	for dy in 2:
		for dx in 2:
			img.set_pixel(int(cx) - 1 + dx, int(cy) - 1 + dy, Color(0.6, 0.9, 1))
	if gba != null:
		img.blend_rect(gba, Rect2i(Vector2i.ZERO, gba.get_size()), Vector2i(0, 16))
		img.blend_rect(gba, Rect2i(Vector2i.ZERO, gba.get_size()), Vector2i(w - 10, 16))
	return ImageTexture.create_from_image(img)       # (its own size: the game's pixels as they are)

## the purple GBA lying on a table in a West City home (map 4_33): cut out of the player's own import
func _game_handheld() -> Image:
	var src = Assets.image(Assets.base_dir.path_join("maps/4_33/layer2.png"))
	if src == null or src.get_width() < 162 or src.get_height() < 160:
		return null
	src.convert(Image.FORMAT_RGBA8)
	var out = Image.create(10, 16, false, Image.FORMAT_RGBA8)
	for y in 16:
		for x in 10:
			var c = src.get_pixel(152 + x, 144 + y)
			var r8 = c.r8; var g8 = c.g8; var b8 = c.b8
			var purple = b8 >= 240 and r8 < 235 and g8 < 215
			var screen = (r8 == g8 and g8 == b8) and (r8 == 40 or r8 == 88 or r8 == 120)
			if c.a > 0 and (purple or screen):
				out.set_pixel(x, y, c)
	return out

## host flows: SELECT MAP, then CHOOSE YOUR CHARACTER, then go (B goes back to where it started)
func _pick_map_char(back: Callable, go: Callable) -> void:
	if _mp_story_slot > 0:      # a story together: the story says where it starts
		_story_cfg(_mp_story_slot)
		_char_screen(back, go)
		return
	_map_screen(back, func(): _char_screen(func(): _map_screen(back, Callable()), go))

# ---- OPTIONS: mods (and your own music), credits
func _options_screen() -> void:
	_gba_screen()
	_global_back = _menu
	_gheading("Options")
	var items = [["OPTIONS", _game_options_screen], ["MODS", _gmods_screen], ["SAVE FILES", _saves_screen], ["CREDITS", _credits_screen]]
	if not OS.has_feature("android"):
		items.append(["DEV TOOLS", _dev_tools])
	items.append(["QUIT GAME", func(): Game.save_options(); get_tree().quit()])
	_glist(items, 46, 22, true)

## OPTIONS - SAVE FILES: see and delete your saves - STORY MODE (each story's 3 slots) and FREE PLAY (each hero)
func _saves_screen() -> void:
	_gba_screen()
	_global_back = _options_screen
	_gheading("Save Files")
	_glist([["STORY MODE", _story_saves_screen], ["FREE PLAY", _free_saves_screen]], 60, 22, true)

func _save_label(e: Variant) -> String:
	if not (e is Dictionary):
		return "?"
	var ch = clampi(int(e.get("ch", 0)), 0, Assets.CHARACTERS.size() - 1)
	return "%s  LV %d" % [Assets.CHARACTERS[ch], int(e.get("level", 1))]

func _story_saves_screen() -> void:
	_gba_screen()
	_global_back = _saves_screen
	_gheading("Story Mode")
	var items = []
	var files = Array(DirAccess.get_files_at("user://"))
	files.sort()
	for fn in files:
		if not fn.begins_with("fighters_story_") or not fn.ends_with(".json"):
			continue
		var id = fn.trim_prefix("fighters_story_").trim_suffix(".json")
		var cut = id.rfind("_")
		var story = id.left(cut).replace("_", " ").strip_edges().to_upper() if cut > 0 else id.to_upper()
		var slot = id.substr(cut + 1) if cut > 0 else "1"
		var t = JSON.parse_string(FileAccess.get_file_as_string("user://" + fn))
		var who = _save_label(t.values()[0]) if t is Dictionary and not t.is_empty() else "EMPTY"
		var txt = "%s  SLOT %s  %s" % [story.left(14), slot, who]
		items.append([txt, _confirm_delete.bind(txt, func(): DirAccess.remove_absolute("user://" + fn), _story_saves_screen)])
	if items.is_empty():
		var l = _gtext(gba, "NO STORY SAVES YET", Vector2(0, 70), false, Color(0.75, 0.85, 1))
		l.size = Vector2(GW, 12); l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		return
	_gscroll(items, 30, 120)

## free play: every hero's shared save (and any copy of it in the older one-file-per-map saves, or it comes back)
func _free_play_files() -> Array:
	var out = []
	for fn in DirAccess.get_files_at("user://"):
		if fn.begins_with("fighters_") and fn.ends_with(".json") and not fn.begins_with("fighters_story") and fn != "fighters_playtest.json":
			out.append("user://" + fn)
	return out

func _free_saves_screen() -> void:
	_gba_screen()
	_global_back = _saves_screen
	_gheading("Free Play")
	var best = {}
	for path in _free_play_files():
		var t = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not (t is Dictionary):
			continue
		for key in t:
			if t[key] is Dictionary and t[key].has("level") and (not best.has(key) or int(t[key].get("level", 1)) > int(best[key].get("level", 1)) or path == Game.SHARED_SAVE):
				best[key] = t[key]
	var keys = best.keys()
	keys.sort_custom(func(x, y): return int(x.get_slice("_", 0)) * 10 + int(x.get_slice("_p", 1)) < int(y.get_slice("_", 0)) * 10 + int(y.get_slice("_p", 1)))
	var items = []
	for key in keys:
		var txt = _save_label(best[key]) + ("  (PLAYER %s)" % key.get_slice("_p", 1) if "_p" in key else "")
		items.append([txt, _confirm_delete.bind(txt, _delete_free_hero.bind(key), _free_saves_screen)])
	if items.is_empty():
		var l = _gtext(gba, "NO FREE PLAY SAVES YET", Vector2(0, 70), false, Color(0.75, 0.85, 1))
		l.size = Vector2(GW, 12); l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		return
	_gscroll(items, 30, 120)

func _delete_free_hero(key: String) -> void:
	for path in _free_play_files():
		var t = JSON.parse_string(FileAccess.get_file_as_string(path))
		if t is Dictionary and t.has(key):
			t.erase(key)
			var fa = FileAccess.open(path, FileAccess.WRITE)
			if fa:
				fa.store_string(JSON.stringify(t)); fa.close()

func _confirm_delete(what: String, del: Callable, back: Callable) -> void:
	_gba_screen()
	_global_back = back
	_gheading("Delete?")
	var l = _gtext(gba, what, Vector2(0, 50), false, Color(1, 0.85, 0.4))
	l.size = Vector2(GW, 12); l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var w = _gtext(gba, "THIS CANNOT BE UNDONE", Vector2(0, 64), false, Color(1, 0.5, 0.5))
	w.size = Vector2(GW, 12); w.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var bs = _glist([["NO, KEEP IT", back], ["YES, DELETE", func(): del.call(); back.call()]], 90, 22, true)
	bs[0].grab_focus.call_deferred()

## OPTIONS - OPTIONS: the game's own options (the same as in the game's menu), before you play. A changes a row.
var _opt_row = 0
func _game_options_screen() -> void:
	_gba_screen()
	_global_back = _options_screen
	_gheading("Options")
	var zoom = int(Game.cfg.get("view_zoom", 0))
	var rows = [["MUSIC  %d%%" % roundi(Music.volume * 100), func(): _opt_set(0)],
		["SOUND  %d%%" % roundi(Sfx.volume * 100), func(): _opt_set(1)],
		["VIEW SIZE  " + ("AUTO" if zoom == 0 else "PIXELS X%d" % zoom), func(): _opt_set(2)],
		["ON-SCREEN BUTTONS  " + {"auto": "AUTO", "on": "ON", "off": "OFF"}.get(str(Game.cfg.get("touch_mode", "auto")), "AUTO"), func(): _opt_set(3)],
		["A/B BUTTONS  " + ("NINTENDO" if Game.pad_layout() == "nintendo" else "XBOX"), func(): _opt_set(4)]]
	if not OS.has_feature("mobile"):
		rows.append(["FULLSCREEN  " + ("ON" if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN else "OFF"), func(): _opt_set(5)])
	var out = _glist(rows, 30, 16, true)
	out[clampi(_opt_row, 0, out.size() - 1)].grab_focus.call_deferred()
	# what VIEW SIZE means, in plain numbers: your screen, and how much of the world fits on it
	var ws = get_window().size
	var kmax = maxi(1, mini(int(ws.x / 480), int(ws.y / 270)))
	var k = zoom if zoom > 0 else kmax
	var info = "YOUR SCREEN %d X %d - %s" % [ws.x, ws.y, "AUTO FITS IT" if zoom == 0 else "EACH GAME PIXEL %dX BIGGER" % k]
	var info2 = "YOU SEE %d X %d OF THE WORLD" % [maxi(240, ws.x / k), maxi(160, ws.y / k)]
	for i in 2:
		var l = _gtext(gba, [info, info2][i], Vector2(0, 30 + rows.size() * 16 + 4 + i * 10), false, Color(0.75, 0.85, 1))
		l.size = Vector2(GW, 10); l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var hint = _gtext(gba, "A: CHANGE   B: BACK", Vector2(0, GH - 14), false, Color(0.7, 0.75, 0.9))
	hint.size = Vector2(GW, 10); hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

func _opt_set(row: int) -> void:
	_opt_row = row
	match row:
		0:
			Music.volume = 0.0 if Music.volume > 0.95 else clampf(snappedf(Music.volume + 0.1, 0.1), 0.0, 1.0)
		1:
			Sfx.volume = 0.0 if Sfx.volume > 0.95 else clampf(snappedf(Sfx.volume + 0.1, 0.1), 0.0, 1.0)
			Sfx.play("menu")
		2:
			var zs = [0, 2, 3, 4, 5, 6]
			Game.cfg["view_zoom"] = zs[(zs.find(int(Game.cfg.get("view_zoom", 0))) + 1) % zs.size()]
			_fit_view()      # at once, not only when the game starts
		3:
			var tm = ["auto", "on", "off"]
			Game.cfg["touch_mode"] = tm[(tm.find(str(Game.cfg.get("touch_mode", "auto"))) + 1) % tm.size()]
		4:
			Game.cfg["pad_layout"] = "xbox" if Game.pad_layout() == "nintendo" else "nintendo"
			Game.apply_pad_layout()
		5:
			Game.toggle_fullscreen()
	Game.save_options()
	_game_options_screen()

func _gmods_screen() -> void:
	_gba_screen()
	_global_back = _options_screen
	_gheading("Mods")
	_glist([["MOD LOADER", _mods_screen], ["MY OWN MUSIC", _music_screen]], 50, 22, true)

func _credits_screen() -> void:
	_gba_screen()
	_global_back = _options_screen
	_gheading("Credits")
	# one list that scrolls (UP / DOWN): the lines, the two YouTube links (A opens them), then the art credits
	var none = func(): pass
	var W = Color.WHITE
	var G = Color(0.85, 0.85, 0.9)
	var Y = Color(1, 0.45, 0.45)
	var A = Color(0.75, 0.9, 1)
	var rows = [
		["GODOT REBUILD BY PUNI PUNI AND DIVINAKRA", none, W],
		["ORIGINAL GAME BY WEBFOOT TECHNOLOGIES,", none, W], ["PUBLISHED BY ATARI", none, W],
		["DRAGON BALL Z (C) BIRD STUDIO / SHUEISHA,", none, G], ["TOEI ANIMATION", none, G],
		["YOUTUBE: @PUNIPUNI2026", func(): OS.shell_open("https://www.youtube.com/@PuniPuni2026"), Y],
		["YOUTUBE: @DIVINAKRACREATIONS", func(): OS.shell_open("https://www.youtube.com/@DivinakraCreations"), Y],
		["SPRITE ART", none, Color(1, 0.85, 0.35)],
		["FIXED CELL WALKING ANIMATION BY CHRIS RUOK", none, A],
		["MECHA FRIEZA REDESIGN BY DIVINAKRA", none, A],
		["SUPERNOVA, DEATH BALL, DEATH BEAM, DESTRUCTO DISK", none, A],
		["AND DARKNESS EYE BEAM ANIMATIONS BY DIVINAKRA", none, A],
		["FLYING LEFT AND RIGHT ANIMATIONS FOR COOLER,", none, A],
		["MR. SATAN AND TEEN TRUNKS BY DIVINAKRA", none, A]]
	var bs = _gscroll(rows.map(func(r): return [r[0], r[1]]), 24, GH - 28)
	for k in bs.size():
		bs[k].add_theme_color_override("font_color", rows[k][2])

# ---- MY OWN MUSIC: the game's own songs play everywhere; any one of them can be replaced by a song of yours
var _song_dialog: FileDialog
var _song_path = ""
var _song_target = ""
func _music_screen() -> void:
	_gba_screen()
	_global_back = _gmods_screen
	_gheading("My Own Music")
	var l = Label.new()
	l.text = "The game's own songs play everywhere, read from your game file (the first time, they are made in the background - a few minutes). Pick one of them below to replace it with a song of yours (.mp3 or .ogg), or bring a replaced one back."
	l.add_theme_font_size_override("font_size", 6)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD
	l.position = Vector2(14, 26); l.size = Vector2(GW - 28, 60)
	gba.add_child(l)
	_glist([["REPLACE A SONG...", _song_list_screen], ["USE THE GAME'S OWN SONG...", _song_reset_screen]], 96, 18)
	_song_dialog = FileDialog.new()
	_song_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_song_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_song_dialog.filters = PackedStringArray(["*.ogg, *.mp3 ; Songs"])
	_song_dialog.size = Vector2i(360, 200)
	_song_dialog.use_native_dialog = true
	if OS.has_feature("android"):
		_song_dialog.use_native_dialog = true
		_song_dialog.filters = PackedStringArray()
	_song_dialog.file_selected.connect(func(p): _song_path = p; _song_copy(_song_target))
	ui.add_child(_song_dialog)

## the songs with no place of their own, by their names
const SONG_TITLES = {16: "LET'S VISIT KING YAMMA AGAIN!", 17: "ETERNAL DRAGON", 18: "TIME TO GO HOME", 20: "SUPER SAIYAN RAGE", 21: "THE EYE OF THE LION", 22: "A SAIYAN DOWN", 24: "EXPLOSION IS NEAR", 27: "EVIL TRIUMPH", 28: "THE GREEN MENACE", 32: "HERCULE DAY PARADE", 34: "PICCOLO THEME", 36: "MASTER ROSHI'S ISLAND", 37: "PEACEFUL DAY"}
## a game song's name: where the game plays it (the title, or the place most of its maps are)
var _song_names = {}
func _song_label(n: int) -> String:
	if _song_names.is_empty():
		var cnt = {}
		var km = Assets.json(Assets.base_dir.path_join("kit/maps.json"))
		if km != null:
			for mm in km["maps"]:
				var sg = int(mm.get("song", -1)); var nm = str(mm.get("name", "")).strip_edges()
				if sg < 0 or nm == "" or nm.begins_with("*"):
					continue
				if not cnt.has(sg):
					cnt[sg] = {}
				cnt[sg][nm] = cnt[sg].get(nm, 0) + 1
		for sg in cnt:
			var best = ""; var bn = 0
			for nm in cnt[sg]:
				if cnt[sg][nm] > bn:
					bn = cnt[sg][nm]; best = nm
			_song_names[sg] = best.to_upper()
		_song_names[Assets.MENU_SONG] = "TITLE & MENUS"
		_song_names[7] = "ERA OF DARKNESS (INTRO)"
		for k in SONG_TITLES:
			_song_names[k] = SONG_TITLES[k]
	return "%02d  %s" % [n, _song_names.get(n, "SONG")]

func _song_file(slot: String) -> String:
	for e in ["ogg", "mp3"]:
		var f = Assets.picked_music_dir().path_join("%s.%s" % [slot, e])
		if FileAccess.file_exists(f):
			return f
	return ""

func _song_list_screen() -> void:
	_gba_screen()
	_global_back = _music_screen
	_gheading("Replace A Song")
	var items = []
	for n in 44:
		var slot = "rom_%d" % n
		items.append([_song_label(n) + ("  (YOURS)" if _song_file(slot) != "" else ""), func(): _song_target = slot; _song_dialog.popup_centered()])
	_gscroll(items, 24, 140)
	_music_dialog_only()      # a new picker every time: the old one went with the screen before (a click did nothing)

func _music_dialog_only() -> void:
	_song_dialog = FileDialog.new()
	_song_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_song_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_song_dialog.filters = PackedStringArray(["*.ogg, *.mp3 ; Songs"])
	_song_dialog.size = Vector2i(360, 200)
	_song_dialog.use_native_dialog = true
	if OS.has_feature("android"):
		_song_dialog.use_native_dialog = true
		_song_dialog.filters = PackedStringArray()
	_song_dialog.file_selected.connect(func(p): _song_path = p; _song_copy(_song_target))
	ui.add_child(_song_dialog)

## the replaced songs: picking one brings the game's own song back
func _song_reset_screen() -> void:
	_gba_screen()
	_global_back = _music_screen
	_gheading("Game's Own Song")
	var items = []
	for n in 44:
		var slot = "rom_%d" % n
		if _song_file(slot) != "":
			items.append([_song_label(n), _song_reset.bind(slot)])
	if items.is_empty():
		var l = _gtext(gba, "NO SONGS ARE REPLACED", Vector2(0, 80), false, Color(0.75, 0.9, 1))
		l.size = Vector2(GW, 14); l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		return
	_gscroll(items, 24, 140)

func _song_reset(slot: String) -> void:
	for e in ["ogg", "mp3"]:
		DirAccess.remove_absolute(Assets.picked_music_dir().path_join("%s.%s" % [slot, e]))
	_replay_music()
	_music_screen()
	lobby_label.text = "BACK TO THE GAME'S OWN SONG"

func _replay_music() -> void:
	Music.refresh_files()
	Music.made.clear()
	var c = Music.current
	Music.current = ""
	Music.play(c)

func _song_copy(slot: String) -> void:
	if slot == "":
		return
	var data = FileAccess.get_file_as_bytes(_song_path)
	var ext = "ogg" if data.size() > 4 and data.slice(0, 4).get_string_from_ascii() == "OggS" else "mp3"
	var msg = ""
	var test_stream = AudioStreamOggVorbis.load_from_buffer(data) if ext == "ogg" else AudioStreamMP3.load_from_buffer(data)
	if data.size() < 1000:
		msg = "THAT FILE COULD NOT BE READ."
	elif test_stream == null or test_stream.get_length() <= 0.0:
		msg = "THAT SONG CAN'T BE PLAYED - USE AN MP3 OR OGG FILE."     # (nothing replaced: the old song stays)
	else:
		var md = Assets.picked_music_dir()
		DirAccess.make_dir_recursive_absolute(md)
		for e in ["ogg", "mp3"]:
			DirAccess.remove_absolute(md.path_join("%s.%s" % [slot, e]))
		var fa = FileAccess.open(md.path_join("%s.%s" % [slot, ext]), FileAccess.WRITE)
		if fa:
			fa.store_buffer(data); fa.close()
			_replay_music()
			msg = "SONG REPLACED"
		else:
			msg = "COULD NOT SAVE THE SONG (%d)." % FileAccess.get_open_error()
	_music_screen()
	lobby_label.text = msg

# ---- NAME YOUR HERO: a GBA-style letter board (d-pad + A, or tap); no phone keyboard
func _name_screen(back: Callable, then: Callable, who: int = 1) -> void:
	_gba_screen()
	_global_back = back
	_gheading("Your Name" if who == 1 else "Player 2: Name")
	var nkey = "name" if who == 1 else "name2"
	var cur = str(Game.cfg.get(nkey, "PLAYER" if who == 1 else "PLAYER 2")).to_upper().left(10)
	if cur == "SERVER":
		cur = "PLAYER" if who == 1 else "PLAYER 2"
	if cur == "PLAYER" or cur == "PLAYER 2":
		cur = ""
	_gpanel(Rect2(100, 22, 120, 18))
	var shown = _gtext(gba, cur + "_", Vector2(100, 23), true, G_CYAN)
	shown.size = Vector2(120, 16); shown.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var grid = GridContainer.new(); grid.columns = 10
	grid.add_theme_constant_override("h_separation", 0); grid.add_theme_constant_override("v_separation", 0)
	grid.position = Vector2(40, 46)
	gba.add_child(grid)
	var keys = []
	for ch in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-":
		keys.append(ch)
	var name_ref = [cur]
	var first: Button = null
	for k in keys:
		var b = _gbutton(grid, k, func():
			if name_ref[0].length() < 10:
				name_ref[0] += k
			shown.text = name_ref[0] + "_", true, 24)
		b.custom_minimum_size = Vector2(24, 18)
		if first == null:
			first = b
	var row = HBoxContainer.new(); row.position = Vector2(40, 134); row.add_theme_constant_override("separation", 0); gba.add_child(row)
	_gbutton(row, "SPACE", func():
		if name_ref[0].length() < 10 and name_ref[0] != "":
			name_ref[0] += " "
		shown.text = name_ref[0] + "_", false, 80)
	_gbutton(row, "DELETE", func():
		name_ref[0] = name_ref[0].left(-1)
		shown.text = name_ref[0] + "_", false, 80)
	var done = _gbutton(row, "DONE", func():
		Game.cfg[nkey] = name_ref[0].strip_edges() if name_ref[0].strip_edges() != "" else ("PLAYER" if who == 1 else "PLAYER 2")
		Game.save_options()
		then.call(), false, 80)
	_typing = func(t: String):
		if t == "\n":
			done.pressed.emit()
			return
		if t == "\b":
			name_ref[0] = name_ref[0].left(-1)
		elif name_ref[0].length() < 10 and not (t == " " and name_ref[0] == ""):
			name_ref[0] += t
		shown.text = name_ref[0] + "_"
	# a name already there (the one you used before): the cursor waits on DONE - A, and you are in
	var start_on = done if cur != "" else first
	start_on.add_to_group("first_focus")
	start_on.grab_focus.call_deferred()

# ---- SPLIT SCREEN: two players on this device - a map, then each player's hero and name
func _split_screen() -> void:
	Game.cfg["mode"] = "solo"
	Game.cfg["local_players"] = 2
	var p2 = func(): _char_screen(func(): _split_screen(), func(): _gload(_solo), 2)
	if _mp_story_slot > 0:
		_story_cfg(_mp_story_slot)
		_char_screen(func(): Game.cfg["local_players"] = 1; _mp_choice(), p2)
		return
	_map_screen(func(): Game.cfg["local_players"] = 1; _mp_choice(), func(): _char_screen(func(): _map_screen(_mp_choice, Callable()), p2))

## a television with its picture split in two (one player each side)
func _split_icon() -> ImageTexture:
	return _pix_icon([
		"kkkkkkkkkkkkkk", "kbbbbbkwkggggk".left(14), "kbbbbbkwkggggk", "kbbbbbkwkggggk", "kbbbbbkwkggggk", "kbbbbbkwkggggk", "kbbbbbkwkggggk",
		"kbbbbbkwkggggk", "kbbbbbkwkggggk", "kkkkkkkkkkkkkk", ".....kkkk.....", "....kkkkkk....", "..............", ".............."],
		{"k": Color(0.15, 0.15, 0.2), "b": Color(0.3, 0.5, 1), "g": Color(0.35, 0.85, 0.4), "w": Color(1, 1, 1)})

# ---- MULTIPLAYER screens in the GBA's look (the same workings as before underneath)
## a choice with its line of explanation under it
func _gchoices(items: Array, y: float, gap: float) -> Array:
	var bs = _glist(items.map(func(it): return [it[0], it[1]]), y, gap)
	for i in items.size():
		var d = _gtext(gba, items[i][2], Vector2(0, y + i * gap + 21), false, Color(0.55, 0.75, 0.95))
		d.size = Vector2(GW, 12); d.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return bs

var in_local_mp = false
func _local_multiplayer() -> void:
	_gba_screen()
	_global_back = _mp_choice
	_gheading("Local Multiplayer")
	_gchoices([["HOST GAME", func(): _pick_map_char(_local_multiplayer, _host), "ONLY PEOPLE ON YOUR WI-FI CAN JOIN"],
		["JOIN GAME", func(): _char_screen(_local_multiplayer, _find_games), "JOIN A GAME ON YOUR WI-FI"],
		["HOST SERVER WITHOUT PLAYING", func(): _map_screen(_local_multiplayer, _server_from_menu), "THIS DEVICE RUNS THE WORLD, OTHERS JOIN IT"]], 40, 38)

var _online_label: Label
func _global_multiplayer() -> void:
	Online.start()
	Online.browse(false)
	_gba_screen()
	_global_back = _mp_choice
	_gheading("Global Multiplayer")
	_online_label = _gtext(gba, "", Vector2(0, 19), false, Color(0.6, 1, 0.7))
	_online_label.size = Vector2(GW, 12); _online_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_gchoices([["HOST PUBLIC GAME", func(): _world_name_screen(func(): _pick_map_char(_global_multiplayer, func(): _online_action(func(): _host_online("")))), "ANYONE IN THE WORLD CAN JOIN"],
		["HOST PRIVATE GAME", _private_password_screen, "ONLY PEOPLE WITH YOUR PASSWORD CAN JOIN"],
		["JOIN GAME", func(): _char_screen(_global_multiplayer, _online_games), "SEE THE GAMES PEOPLE ARE PLAYING ONLINE"],
		["HOST SERVER WITHOUT PLAYING", func(): _world_name_screen(func(): _map_screen(_global_multiplayer, func(): _online_action(func(): _global_back = Callable(); test["online"] = "1"; _server_from_menu()))), "THIS DEVICE RUNS AN ONLINE WORLD"]], 36, 34)
	_tick(_show_online_state)

func _show_online_state() -> void:
	if is_instance_valid(_online_label):
		_online_label.text = Online.status_text().to_upper()

## the GBA letter board for a word (a world's name, a password): d-pad + A or taps; done() answers "" or what is wrong
func _gboard(title: String, initial: String, maxlen: int, back: Callable, done: Callable) -> void:
	_gba_screen()
	_global_back = back
	_gheading(title)
	_gpanel(Rect2(70, 22, 180, 18))
	var word = [initial.to_upper().left(maxlen)]
	var shown = _gtext(gba, word[0] + "_", Vector2(70, 23), true, G_CYAN)
	shown.size = Vector2(180, 16); shown.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var grid = GridContainer.new(); grid.columns = 10
	grid.add_theme_constant_override("h_separation", 0); grid.add_theme_constant_override("v_separation", 0)
	grid.position = Vector2(40, 44)
	gba.add_child(grid)
	var first: Button = null
	for ch in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-":
		var k = ch
		var b = _gbutton(grid, k, func():
			if word[0].length() < maxlen:
				word[0] += k
			shown.text = word[0] + "_", true, 24)
		b.custom_minimum_size = Vector2(24, 18)
		if first == null:
			first = b
	var row = HBoxContainer.new(); row.position = Vector2(40, 130); row.add_theme_constant_override("separation", 0); gba.add_child(row)
	_gbutton(row, "SPACE", func():
		if word[0].length() < maxlen and word[0] != "":
			word[0] += " "
		shown.text = word[0] + "_", false, 80)
	_gbutton(row, "DELETE", func():
		word[0] = word[0].left(-1)
		shown.text = word[0] + "_", false, 80)
	var ok = _gbutton(row, "DONE", func():
		var err = str(done.call(word[0].strip_edges()))
		if err != "" and is_instance_valid(lobby_label):
			lobby_label.text = err, false, 80)
	_typing = func(t: String):
		if t == "\n":
			ok.pressed.emit()
			return
		if t == "\b":
			word[0] = word[0].left(-1)
		elif word[0].length() < maxlen and not (t == " " and word[0] == ""):
			word[0] += t
		shown.text = word[0] + "_"
	first.add_to_group("first_focus")
	first.grab_focus.call_deferred()

func _world_name_screen(then: Callable) -> void:
	_gboard("World Name", Online.world_name, 16, _global_multiplayer, func(t: String) -> String:
		if t.length() < 2:
			return "THE NAME NEEDS 2 OR MORE LETTERS"
		Online.world_name = t
		then.call()
		return "")

func _private_password_screen() -> void:
	_gboard("Your Password", "", 12, _global_multiplayer, func(t: String) -> String:
		if t.length() < 4:
			return "THE PASSWORD NEEDS 4 OR MORE LETTERS"
		_pick_map_char(_global_multiplayer, func(): _online_action(func(): _host_online(t)))
		return "")

func _join_password_screen(g: Dictionary) -> void:
	Online.browse(false)
	_gboard("Password", "", 12, _online_games, func(t: String) -> String:
		_online_action(func(): _join_online(g, t))
		return "")

## a list of games that refreshes itself (online or on this Wi-Fi)
var _game_list: VBoxContainer
var _game_sig = "-"
func _games_screen(title: String, back: Callable, refresh: Callable) -> void:
	_gba_screen()
	_global_back = back
	_gheading(title)
	_online_label = _gtext(gba, "", Vector2(0, 19), false, Color(0.6, 1, 0.7))
	_online_label.size = Vector2(GW, 12); _online_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var sc = ScrollContainer.new(); sc.position = Vector2(0, 34); sc.size = Vector2(GW, 128)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED; sc.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER; sc.follow_focus = true
	gba.add_child(sc)
	_game_list = VBoxContainer.new(); _game_list.add_theme_constant_override("separation", 2); sc.add_child(_game_list)
	_game_sig = "-"
	_tick(refresh)

func _fill_games(sig: String, rows: Array, empty_text: String) -> void:
	if not is_instance_valid(_game_list) or sig == _game_sig:
		return
	_game_sig = sig
	var fo = get_viewport().gui_get_focus_owner()
	var had = fo == null or _game_list.is_ancestor_of(fo)
	for c in _game_list.get_children():
		c.queue_free()
	if rows.is_empty():
		var l = _gtext(_game_list, empty_text, Vector2.ZERO, false, Color(0.75, 0.75, 0.85))
		l.custom_minimum_size = Vector2(GW, 30); l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; l.autowrap_mode = TextServer.AUTOWRAP_WORD
		return
	var first: Button = null
	for r in rows:
		var b = _gbutton(_game_list, r[0], r[1])
		if first == null:
			first = b
	if had and first:
		first.grab_focus.call_deferred()

func _online_games() -> void:
	Online.start()
	Online.browse(true)
	_games_screen("Join Game", func(): Online.browse(false); _global_multiplayer(), _refresh_online_games)

func _refresh_online_games() -> void:
	_show_online_state()
	var sig = Online.list_error
	var rows = []
	for g in Online.lobbies:
		sig += "%s|%s|%s|%d|%s;" % [g["id"], g["character"], g["planet"], g["players"], g["private"]]
		rows.append(["%s - %s  (%d/%d)%s" % [str(g["character"]), str(g["planet"]), int(g["players"]), int(g["max"]), "  PRIVATE" if g["private"] else ""], _pick_online_game.bind(g)])
	_fill_games(sig, rows, Online.list_error.to_upper() if Online.list_error != "" else "LOOKING FOR GAMES... NOBODY IS HOSTING ONE ONLINE RIGHT NOW")

var finding = false
func _find_games() -> void:
	Game.lan_scan_start()
	_games_screen("Join Game", _leave_find, _refresh_find)
	finding = true
	_global_back = _leave_find

func _refresh_find() -> void:
	if not is_instance_valid(_game_list):
		return
	if is_instance_valid(_online_label):
		_online_label.text = "GAMES ON YOUR WI-FI"
	var ips = Game.lan_found.keys()
	ips.sort()
	var sig = ""
	var rows = []
	for ip in ips:
		var g: Dictionary = Game.lan_found[ip]
		sig += "%s|%s|%s;" % [ip, g.get("character", ""), g.get("planet", "")]
		rows.append(["%s - %s" % [str(g.get("character", g.get("name", "?"))), str(g.get("planet", ""))], _join_found.bind(ip)])
	_fill_games(sig, rows, "LOOKING FOR GAMES... SOMEONE ON YOUR WI-FI HAS TO HOST ONE")

func _leave_find() -> void:
	Game.lan_scan_stop()
	finding = false
	_local_multiplayer()
