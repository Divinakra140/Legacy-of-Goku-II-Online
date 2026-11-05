extends Control
## DEV TOOLS - EVENTS: scenes and story without programming. An event starts when someone talks to a person,
## walks into a box (EVENT tool on the map), enters a map, the game starts or a foe is beaten; then its steps run:
## lines to read, choices that branch, story flags, rewards, missions, warps, bosses... Saved in content/events.json.

var tools
var events = []
var cur = -1
var step_i = -1
var list: ItemList
var steps_list: ItemList
var form: VBoxContainer
var step_box: VBoxContainer
var info: Label
var add_pick: OptionButton
var built = false

const STEP_TYPES = ["say", "choice", "label", "goto", "if_flag", "flag", "give", "take", "zeni", "exp", "heal", "quest", "finish_quest",
	"wait", "fade", "warp", "spawn", "shop", "sound", "music", "toast", "unlock_form", "lock_form", "transform", "revert", "state",
	"move", "face", "pose", "camera", "camera_back", "shake", "show_person", "hide_person", "emote", "boss_fight", "fight_on",
	"var", "if_var", "timer", "if_timer", "companion", "switch_hero", "open_area", "close_area", "save", "the_end", "story", "end"]
const STEP_HELP = {
	"say": "A line in the text box (who speaks, what). %s = the player's name.", "choice": "A question with answers: each answer goes to a LABEL (empty: goes on).",
	"story": "One of LoG2's own scenes, read from your game: table = its index (hex), from = the first entry; table INTRO = the whole opening. It plays instead of the rest of this event.", "label": "A place to jump to.", "goto": "Jump to a LABEL.", "if_flag": "If the flag is set, jump to the LABEL.", "flag": "Set (on) or clear a story flag.",
	"give": "Give an item.", "take": "Take an item away.", "zeni": "Give (or take, minus) zeni.", "exp": "Give EXP.", "heal": "Full health and ki.",
	"quest": "Start a mission.", "finish_quest": "Finish a mission (its reward).", "wait": "Wait (60 = one second).", "fade": "Fade in.",
	"warp": "Send the player to a map (key, like land/0/0 or custom/mymap) at x, y.", "spawn": "A foe (or boss) appears (x, y; -1 = next to the player).",
	"shop": "Open a shop.", "sound": "Play a sound.", "music": "Play a song (title, field, cave, lair, boss, victory, or a file's name).",
	"toast": "A message at the bottom.", "end": "Stop here.",
	"unlock_form": "Give a transformation: from now on it is on the TRANSFORM button (forms with unlock = reward, or another hero's).",
	"lock_form": "Take a transformation away again.", "transform": "Transform right now (any form, unlocked or not - a story moment).",
	"revert": "Back to normal.",
	"move": "Walk someone (a person's name, or PLAYER) to x, y. speed 1 = walking. wait: the next step waits until they are there.",
	"face": "Turn someone (name or PLAYER) to down / up / left / right.", "pose": "Play a pose on someone (name or PLAYER): see SPRITES for the numbers (19 = beam, 4 = powering up). loop: again and again. pose -1: stop.",
	"camera": "Move the camera to x, y (or to who: a name / PLAYER) over frames, zoom 1 = normal, 2 = closer. wait: until it is there.",
	"camera_back": "The camera goes back to the player.", "shake": "Shake the screen.",
	"show_person": "Someone appears at x, y (name, sprite set, facing). They stay (saved with the story).", "hide_person": "Someone goes away (saved with the story).",
	"emote": "A bubble over someone: ! ? ... !! <3 zZ (who: a name or PLAYER).",
	"boss_fight": "A story boss: kind, level (0 = yours), x, y (-1 = next to you), name, hp (x, 1 = normal). The doors lock until it ends: WIN label when it is beaten, LOSE label when you are knocked out. phases: 0.5:label,0.25:label2 - at that much health left the event jumps there (say lines, a transformation...) and FIGHT ON goes back to the fight.",
	"fight_on": "Back to the boss fight (after a phase).",
	"var": "A number: set / add / sub / mul / random (value to max). Show it in a line with {var:name}.", "if_var": "If the number compares (= != < <= > >=) to the value, jump to the label.",
	"timer": "A countdown (seconds), shown on screen if show.", "if_timer": "If the countdown has run out, jump to the label.",
	"companion": "Someone fights beside you (who: a hero name or a sprite set number, name, level 0 = yours). leave: they go.",
	"switch_hero": "Play as another hero from now on (each keeps their own level and things; story flags carry over).",
	"open_area": "Make a box of the map walkable and take away what stands there (a rock broken, a gate opened). Saved with the story.",
	"close_area": "Make a box of the map a wall (a door shut, a cave caved in). Saved with the story.",
	"save": "Save the story (a save point).", "the_end": "THE END: the credits roll (DEV TOOLS - STORY), then back to the title.", "state": "Put a state on (poison, rage...; seconds -1 = its own length, 0 = until taken away) or take it off (off; id all = every state)."}
const STEP_FIELDS = {
	"say": [["who", "text"], ["text", "long"], ["face", "int"]], "choice": [["who", "text"], ["text", "long"], ["options", "options"], ["face", "int"]],
	"label": [["name", "text"]], "goto": [["label", "text"]], "if_flag": [["name", "text"], ["goto", "text"]], "flag": [["name", "text"], ["on", "bool"]],
	"give": [["item", "item"], ["count", "int"]], "take": [["item", "item"], ["count", "int"]], "zeni": [["amount", "int"]], "exp": [["amount", "int"]],
	"story": [["table", "text"], ["from", "int"]], "heal": [], "quest": [["id", "quest"]], "finish_quest": [["id", "quest"]], "wait": [["frames", "int"]], "fade": [],
	"warp": [["map", "text"], ["x", "int"], ["y", "int"]], "spawn": [["kind", "int"], ["level", "int"], ["boss", "bool"], ["x", "int"], ["y", "int"]],
	"shop": [["id", "shop"]], "sound": [["name", "text"]], "music": [["name", "text"]], "toast": [["text", "text"]], "end": [],
	"unlock_form": [["id", "form"]], "lock_form": [["id", "form"]], "transform": [["id", "form"]], "revert": [],
	"state": [["id", "state"], ["seconds", "int"], ["off", "bool"]],
	"move": [["who", "text"], ["x", "int"], ["y", "int"], ["speed", "num"], ["wait", "bool"]], "face": [["who", "text"], ["dir", "text"]],
	"pose": [["who", "text"], ["pose", "int"], ["loop", "bool"]],
	"camera": [["who", "text"], ["x", "int"], ["y", "int"], ["zoom", "num"], ["frames", "int"], ["wait", "bool"]], "camera_back": [], "shake": [["amount", "int"]],
	"show_person": [["name", "text"], ["set", "int"], ["x", "int"], ["y", "int"], ["dir", "text"]], "hide_person": [["who", "text"]],
	"emote": [["who", "text"], ["kind", "text"]],
	"boss_fight": [["kind", "int"], ["level", "int"], ["x", "int"], ["y", "int"], ["name", "text"], ["hp", "num"], ["win", "text"], ["lose", "text"], ["phases", "text"], ["lock", "bool"]],
	"fight_on": [],
	"var": [["name", "text"], ["op", "text"], ["value", "num"], ["max", "num"]], "if_var": [["name", "text"], ["cmp", "text"], ["value", "num"], ["goto", "text"]],
	"timer": [["name", "text"], ["seconds", "int"], ["show", "bool"]], "if_timer": [["name", "text"], ["goto", "text"]],
	"companion": [["who", "text"], ["name", "text"], ["level", "int"], ["leave", "bool"]], "switch_hero": [["hero", "text"]],
	"open_area": [["x0", "int"], ["y0", "int"], ["x1", "int"], ["y1", "int"], ["id", "text"]], "close_area": [["x0", "int"], ["y0", "int"], ["x1", "int"], ["y1", "int"], ["id", "text"]],
	"save": [], "the_end": []}
const TRIGGERS = [["talk", "WHEN SOMEONE TALKS TO", "person's name"], ["area", "WHEN WALKING INTO A BOX (EVENT tool on the map)", ""],
	["enter", "WHEN ENTERING A MAP", "map key (land/0/0, custom/mymap)"], ["start", "WHEN THE GAME STARTS", ""], ["defeat", "WHEN A FOE IS BEATEN", "foe number 0-127"],
	["none", "NOT BY ITSELF (a person's EVENT, the STORY intro, F7 TEST)", ""]]

func show_editor() -> void:
	if not built:
		_build()
	events = Content.events.duplicate(true)
	_fill()
	if events.size() > 0 and cur < 0:
		_choose(0)
	elif cur >= 0 and cur < events.size():
		_choose(cur)

func _build() -> void:
	built = true
	var bg = ColorRect.new(); bg.color = Color(0.07, 0.08, 0.13); bg.set_anchors_preset(Control.PRESET_FULL_RECT); add_child(bg)
	var h = HBoxContainer.new(); h.set_anchors_preset(Control.PRESET_FULL_RECT); h.offset_top = 4; h.offset_left = 4; h.offset_right = -4; h.offset_bottom = -4
	add_child(h)
	var lv = VBoxContainer.new(); lv.custom_minimum_size = Vector2(170, 0); h.add_child(lv)
	var bb = HBoxContainer.new(); lv.add_child(bb)
	for t in [["NEW", _new], ["COPY", _copy], ["DELETE", _delete]]:
		var b = Button.new(); b.text = t[0]; b.add_theme_font_size_override("font_size", 10); b.pressed.connect(t[1]); bb.add_child(b)
	list = ItemList.new(); list.size_flags_vertical = Control.SIZE_EXPAND_FILL; list.add_theme_font_size_override("font_size", 10)
	list.item_selected.connect(_choose)
	lv.add_child(list)
	var mid = VBoxContainer.new(); mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL; h.add_child(mid)
	info = Label.new(); info.autowrap_mode = TextServer.AUTOWRAP_WORD; info.add_theme_font_size_override("font_size", 10)
	info.add_theme_color_override("font_color", Color(1, 0.9, 0.55))
	info.text = "EVENTS: what starts it, when it may (flags, level...), then its steps. TEST IN THE GAME plays it right away."
	mid.add_child(info)
	var sb = HBoxContainer.new(); mid.add_child(sb)
	var save = Button.new(); save.text = "SAVE"; save.pressed.connect(_save); sb.add_child(save)
	var test = Button.new(); test.text = "TEST IN THE GAME"; test.pressed.connect(_test); sb.add_child(test)
	var sc = ScrollContainer.new(); sc.size_flags_vertical = Control.SIZE_EXPAND_FILL; sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	mid.add_child(sc)
	form = VBoxContainer.new(); form.size_flags_horizontal = Control.SIZE_EXPAND_FILL; sc.add_child(form)
	# right: the steps
	var rv = VBoxContainer.new(); rv.custom_minimum_size = Vector2(330, 0); h.add_child(rv)
	var l = Label.new(); l.text = "STEPS (in order)"; l.add_theme_font_size_override("font_size", 10); rv.add_child(l)
	steps_list = ItemList.new(); steps_list.custom_minimum_size = Vector2(320, 190); steps_list.add_theme_font_size_override("font_size", 9)
	steps_list.item_selected.connect(_choose_step)
	rv.add_child(steps_list)
	var ab = HBoxContainer.new(); rv.add_child(ab)
	add_pick = OptionButton.new(); add_pick.add_theme_font_size_override("font_size", 9)
	for t in STEP_TYPES:
		add_pick.add_item(t.to_upper())
	ab.add_child(add_pick)
	for t in [["ADD", _add_step], ["UP", func(): _move_step(-1)], ["DOWN", func(): _move_step(1)], ["DEL", _del_step]]:
		var b = Button.new(); b.text = t[0]; b.add_theme_font_size_override("font_size", 9); b.pressed.connect(t[1]); ab.add_child(b)
	var ss = ScrollContainer.new(); ss.size_flags_vertical = Control.SIZE_EXPAND_FILL; ss.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	rv.add_child(ss)
	step_box = VBoxContainer.new(); step_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL; ss.add_child(step_box)

func _fill() -> void:
	list.clear()
	for e in events:
		list.add_item("%s  %s" % [str(e.get("id", "")), str(e.get("name", ""))])

func _ev() -> Dictionary:
	return events[cur] if cur >= 0 and cur < events.size() else {}

func _choose(i: int) -> void:
	cur = i
	if i < list.item_count:
		list.select(i)
	step_i = -1
	_build_form()
	_fill_steps()
	_build_step()

# ------------------------------------------------------------------ the event's own fields
func _row(parent: Control, label: String) -> HBoxContainer:
	var r = HBoxContainer.new(); parent.add_child(r)
	var l = Label.new(); l.text = label; l.custom_minimum_size = Vector2(110, 0); l.add_theme_font_size_override("font_size", 10); r.add_child(l)
	return r

func _edit(parent: Control, label: String, v: String, cb: Callable) -> LineEdit:
	var r = _row(parent, label)
	var e = LineEdit.new(); e.text = v; e.size_flags_horizontal = Control.SIZE_EXPAND_FILL; e.text_changed.connect(cb); r.add_child(e)
	return e

func _build_form() -> void:
	for c in form.get_children():
		c.queue_free()
	var e = _ev()
	if e.is_empty():
		return
	_edit(form, "ID", str(e.get("id", "")), func(t): e["id"] = t.strip_edges(); _fill_title())
	_edit(form, "NAME", str(e.get("name", "")), func(t): e["name"] = t; _fill_title())
	var oc = CheckBox.new(); oc.text = "ONLY ONCE (per hero)"; oc.button_pressed = bool(e.get("once", true)); oc.toggled.connect(func(on): e["once"] = on); form.add_child(oc)
	var t: Dictionary = e.get("trigger", {"type": "talk"})
	e["trigger"] = t
	var tr = _row(form, "STARTS")
	var tp = OptionButton.new(); tp.add_theme_font_size_override("font_size", 9)
	for i in TRIGGERS.size():
		tp.add_item(TRIGGERS[i][1])
		if TRIGGERS[i][0] == str(t.get("type", "talk")): tp.select(i)
	tr.add_child(tp)
	var param = _edit(form, "   ...", _trig_param(t), func(v): _set_trig_param(t, v))
	tp.item_selected.connect(func(i): t["type"] = TRIGGERS[i][0]; param.placeholder_text = TRIGGERS[i][2]; param.editable = TRIGGERS[i][2] != "")
	param.placeholder_text = TRIGGERS[tp.selected][2]
	param.editable = TRIGGERS[tp.selected][2] != ""
	var c: Dictionary = e.get("if", {})
	e["if"] = c
	var l = Label.new(); l.text = "ONLY WHEN (leave empty: always)"; l.add_theme_font_size_override("font_size", 10); l.add_theme_color_override("font_color", Color(0.7, 0.9, 1)); form.add_child(l)
	_edit(form, "flags set", ",".join(PackedStringArray(c.get("flags", []))), func(v): c["flags"] = _list(v))
	_edit(form, "flags NOT set", ",".join(PackedStringArray(c.get("not_flags", []))), func(v): c["not_flags"] = _list(v))
	_edit(form, "level at least", str(c.get("level", "")), func(v): _set_int(c, "level", v))
	_edit(form, "mission done", str(c.get("quest_done", "")), func(v): c["quest_done"] = v.strip_edges())
	_edit(form, "has item", str(c.get("has_item", "")), func(v): c["has_item"] = v.strip_edges())
	_edit(form, "has state", str(c.get("has_state", "")), func(v): c["has_state"] = v.strip_edges())
	_edit(form, "in form", str(c.get("in_form", "")), func(v): c["in_form"] = v.strip_edges())
	_edit(form, "has form (given)", str(c.get("has_form", "")), func(v): c["has_form"] = v.strip_edges())
	var hl = Label.new(); hl.autowrap_mode = TextServer.AUTOWRAP_WORD; hl.add_theme_font_size_override("font_size", 9)
	hl.text = "Tips: a door that opens later = an AREA event that warps you, only when a flag is set. A person with a story = a TALK event with SAY steps; give them their next lines with flags. Story flags are kept per hero."
	form.add_child(hl)

static func _set_int(d: Dictionary, k: String, v: String) -> void:
	if v.strip_edges().is_valid_int():
		d[k] = int(v)
	else:
		d.erase(k)

static func _list(v: String) -> Array:
	var out = []
	for x in v.split(",", false):
		if x.strip_edges() != "":
			out.append(x.strip_edges())
	return out

func _trig_param(t: Dictionary) -> String:
	match str(t.get("type", "")):
		"talk": return str(t.get("person", ""))
		"enter": return str(t.get("map", ""))
		"defeat": return str(t.get("kind", ""))
	return ""

func _set_trig_param(t: Dictionary, v: String) -> void:
	match str(t.get("type", "")):
		"talk": t["person"] = v.strip_edges().to_upper()
		"enter": t["map"] = v.strip_edges()
		"defeat": t["kind"] = int(v) if v.is_valid_int() else -1

func _fill_title() -> void:
	if cur >= 0:
		list.set_item_text(cur, "%s  %s" % [str(_ev().get("id", "")), str(_ev().get("name", ""))])

# ------------------------------------------------------------------ steps
static func summary(st: Dictionary) -> String:
	var d = str(st.get("do", ""))
	match d:
		"say": return "SAY %s: %s" % [str(st.get("who", "")), str(st.get("text", "")).left(40)]
		"choice": return "CHOICE %s  [%s]" % [str(st.get("text", "")).left(24), ", ".join(PackedStringArray(st.get("options", []).map(func(o): return "%s>%s" % [o[0], o[1]])))]
		"label": return ":: " + str(st.get("name", ""))
		"goto": return "GOTO " + str(st.get("label", ""))
		"if_flag": return "IF %s GOTO %s" % [str(st.get("name", "")), str(st.get("goto", ""))]
		"flag": return "FLAG %s %s" % [str(st.get("name", "")), "ON" if bool(st.get("on", true)) else "OFF"]
		"give", "take": return "%s %s x%d" % [d.to_upper(), str(st.get("item", "")), int(st.get("count", 1))]
	var parts = []
	for f in STEP_FIELDS.get(d, []):
		parts.append("%s=%s" % [f[0], str(st.get(f[0], ""))])
	return d.to_upper() + " " + " ".join(PackedStringArray(parts))

func _fill_steps() -> void:
	steps_list.clear()
	var e = _ev()
	if e.is_empty():
		return
	for st in e.get("steps", []):
		steps_list.add_item(summary(st))
	if step_i >= 0 and step_i < steps_list.item_count:
		steps_list.select(step_i)

func _choose_step(i: int) -> void:
	step_i = i
	_build_step()

func _add_step() -> void:
	var e = _ev()
	if e.is_empty():
		return
	if not e.has("steps"):
		e["steps"] = []
	var d = STEP_TYPES[add_pick.selected]
	var st = {"do": d}
	for f in STEP_FIELDS[d]:
		st[f[0]] = {"text": "", "long": "", "int": 0, "bool": true, "item": "senzu", "quest": "", "shop": "", "form": "", "state": "poison", "num": 1.0, "options": [["YES", ""], ["NO", ""]]}[f[1]]
	match d:
		"say": st["who"] = "GOKU"; st["text"] = "Hello!"; st["face"] = -1
		"choice": st["face"] = -1
		"give", "take": st["count"] = 1
		"wait": st["frames"] = 60
		"story": st["table"] = "intro"; st["from"] = 0
		"spawn": st["kind"] = 8; st["level"] = 5; st["boss"] = false; st["x"] = -1; st["y"] = -1
		"warp": st["map"] = "land/0/0"
		"state": st["seconds"] = -1; st["off"] = false
		"move": st["who"] = "PLAYER"; st["speed"] = 1.0; st["wait"] = true
		"face": st["who"] = "PLAYER"; st["dir"] = "down"
		"pose": st["who"] = "PLAYER"; st["pose"] = 4; st["loop"] = false
		"camera": st["who"] = ""; st["zoom"] = 1.0; st["frames"] = 45; st["wait"] = true
		"shake": st["amount"] = 4
		"show_person": st["name"] = "SOMEONE"; st["set"] = 54; st["dir"] = "down"
		"emote": st["who"] = "PLAYER"; st["kind"] = "!"
		"boss_fight": st["kind"] = 40; st["level"] = 0; st["x"] = -1; st["y"] = -1; st["name"] = "THE BOSS"; st["hp"] = 1.0; st["win"] = "won"; st["lose"] = "lost"; st["phases"] = ""; st["lock"] = true
		"var": st["name"] = "count"; st["op"] = "add"; st["value"] = 1.0; st["max"] = 10.0
		"if_var": st["name"] = "count"; st["cmp"] = ">="; st["value"] = 3.0
		"timer": st["name"] = "escape"; st["seconds"] = 60; st["show"] = true
		"if_timer": st["name"] = "escape"
		"companion": st["who"] = "PICCOLO"; st["name"] = "PICCOLO"; st["level"] = 0; st["leave"] = false
		"switch_hero": st["hero"] = "GOHAN"
		"unlock_form", "lock_form", "transform": st["id"] = str(Content.forms[0]["id"]) if not Content.forms.is_empty() else ""
	var at = step_i + 1 if step_i >= 0 else e["steps"].size()
	e["steps"].insert(at, st)
	step_i = at
	_fill_steps()
	_build_step()

func _move_step(d: int) -> void:
	var e = _ev()
	if e.is_empty() or step_i < 0:
		return
	var j = clampi(step_i + d, 0, e["steps"].size() - 1)
	var st = e["steps"][step_i]
	e["steps"].remove_at(step_i)
	e["steps"].insert(j, st)
	step_i = j
	_fill_steps()

func _del_step() -> void:
	var e = _ev()
	if e.is_empty() or step_i < 0:
		return
	e["steps"].remove_at(step_i)
	step_i = mini(step_i, e["steps"].size() - 1)
	_fill_steps()
	_build_step()

func _build_step() -> void:
	for c in step_box.get_children():
		c.queue_free()
	var e = _ev()
	if e.is_empty() or step_i < 0 or step_i >= e.get("steps", []).size():
		return
	var st: Dictionary = e["steps"][step_i]
	var d = str(st.get("do", ""))
	var l = Label.new(); l.text = d.to_upper() + ": " + STEP_HELP.get(d, ""); l.autowrap_mode = TextServer.AUTOWRAP_WORD; l.add_theme_font_size_override("font_size", 10)
	l.add_theme_color_override("font_color", Color(1, 0.9, 0.55)); step_box.add_child(l)
	var warn = Label.new(); warn.autowrap_mode = TextServer.AUTOWRAP_WORD; warn.add_theme_font_size_override("font_size", 10); warn.add_theme_color_override("font_color", Color(1, 0.55, 0.4))
	for f in STEP_FIELDS.get(d, []):
		var k = str(f[0])
		match str(f[1]):
			"long":
				var te = TextEdit.new(); te.text = str(st.get(k, "")); te.custom_minimum_size = Vector2(300, 70); te.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
				te.text_changed.connect(func(): st[k] = te.text; _refresh_step(st, warn))
				step_box.add_child(te)
			"num":
				var rn = _row(step_box, k)
				var spn = SpinBox.new(); spn.min_value = -99999; spn.max_value = 999999; spn.step = 0.05; spn.value = float(st.get(k, 0)); spn.value_changed.connect(func(v): st[k] = v; _refresh_step(st, warn)); rn.add_child(spn)
			"int":
				var r = _row(step_box, k)
				var sp = SpinBox.new(); sp.min_value = -99999; sp.max_value = 999999; sp.value = float(st.get(k, 0)); sp.value_changed.connect(func(v): st[k] = int(v); _refresh_step(st, warn)); r.add_child(sp)
			"bool":
				var cb = CheckBox.new(); cb.text = k; cb.button_pressed = bool(st.get(k, true)); cb.toggled.connect(func(on): st[k] = on; _refresh_step(st, warn)); step_box.add_child(cb)
			"item", "quest", "shop", "form", "state":
				var r = _row(step_box, k)
				var ob = OptionButton.new(); ob.add_theme_font_size_override("font_size", 9)
				var src = Content.items + Content.gear if f[1] == "item" else (Content.quests if f[1] == "quest" else (Content.shops if f[1] == "shop" else (Content.forms if f[1] == "form" else Content.states)))
				for it in src:
					ob.add_item(("%s  (%s%s)" % [str(it.get("name", it["id"])), str(it["id"]), (", " + str(it.get("who", ""))) if f[1] == "form" else ""]) if f[1] in ["form", "state"] else str(it.get("name", it["id"]))); ob.set_item_metadata(ob.item_count - 1, str(it["id"]))
					if str(it["id"]) == str(st.get(k, "")): ob.select(ob.item_count - 1)
				ob.item_selected.connect(func(j): st[k] = str(ob.get_item_metadata(j)); _refresh_step(st, warn))
				r.add_child(ob)
			"options":
				var ol = Label.new(); ol.text = "Answers, one a line: ANSWER > LABEL"; ol.add_theme_font_size_override("font_size", 9); step_box.add_child(ol)
				var te2 = TextEdit.new(); te2.custom_minimum_size = Vector2(300, 60)
				te2.text = "\n".join(PackedStringArray(st.get(k, []).map(func(o): return "%s > %s" % [o[0], o[1]])))
				te2.text_changed.connect(func():
					var opts = []
					for line in te2.text.split("\n", false):
						var pr = line.split(">")
						opts.append([pr[0].strip_edges().to_upper(), pr[1].strip_edges() if pr.size() > 1 else ""])
					st[k] = opts
					_refresh_step(st, warn))
				step_box.add_child(te2)
			_:
				_edit(step_box, k, str(st.get(k, "")), func(v): st[k] = v.to_upper() if k == "who" else v; _refresh_step(st, warn))
	step_box.add_child(warn)
	if d in ["say", "choice"]:
		var lb = Button.new(); lb.text = "LINES FROM THE GAME..."; lb.tooltip_text = "Every line of Legacy of Goku II read from your game: search, click one"
		lb.pressed.connect(func(): _line_library(st)); step_box.add_child(lb)
	if STEP_FIELDS.get(d, []).any(func(ff): return ff[0] == "x") or d in ["open_area", "close_area"]:
		var mb = Button.new(); mb.text = "X, Y FROM THE MAP VIEW (its middle)"
		mb.tooltip_text = "Go to the MAP tab, look at the spot, come back and press this"
		mb.pressed.connect(func():
			if tools == null:
				return
			var c0: Vector2 = tools.cam.position
			if d in ["open_area", "close_area"]:
				st["x0"] = int(c0.x) - 16; st["y0"] = int(c0.y) - 16; st["x1"] = int(c0.x) + 16; st["y1"] = int(c0.y) + 16
			else:
				st["x"] = int(c0.x); st["y"] = int(c0.y)
				if st.has("who") and d == "camera":
					st["who"] = ""
			_build_step()
			_refresh_step(st, warn))
		step_box.add_child(mb)
	if d == "say":
		var sb = Button.new(); sb.text = "SPLIT INTO BOXES THAT FIT"; sb.pressed.connect(func(): _split_say(st)); step_box.add_child(sb)
	_refresh_step(st, warn)

## does the line fit the game's text box (3 lines of 8-pixel letters, 308 pixels wide)?
static func box_lines(text: String) -> int:
	var font = ThemeDB.fallback_font
	var sz = font.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, 308, 8)
	return maxi(1, int(ceil(sz.y / maxf(1.0, font.get_height(8)))))

func _refresh_step(st: Dictionary, warn: Label) -> void:
	if step_i >= 0 and step_i < steps_list.item_count:
		steps_list.set_item_text(step_i, summary(st))
	warn.text = ""
	if str(st.get("do", "")) in ["say", "choice"]:
		var n = box_lines(str(st.get("text", "")))
		if n > 3:
			warn.text = "TOO LONG FOR ONE TEXT BOX (%d lines, 3 fit): SPLIT it, or it is cut off." % n
	if str(st.get("do", "")) in ["goto", "if_flag"]:
		var lab = str(st.get("label", st.get("goto", "")))
		if lab != "" and not _ev().get("steps", []).any(func(x): return str(x.get("do", "")) == "label" and str(x.get("name", "")) == lab):
			warn.text = "There is no LABEL %s in this event." % lab

## a long line as several SAY steps, each fitting the box
func _split_say(st: Dictionary) -> void:
	var words = str(st.get("text", "")).split(" ", false)
	var parts = []
	var cur_t = ""
	for wd in words:
		var t = (cur_t + " " + wd).strip_edges()
		if box_lines(t) > 3 and cur_t != "":
			parts.append(cur_t)
			cur_t = wd
		else:
			cur_t = t
	if cur_t != "":
		parts.append(cur_t)
	if parts.size() <= 1:
		return
	var e = _ev()
	st["text"] = parts[0]
	for j in range(1, parts.size()):
		e["steps"].insert(step_i + j, {"do": "say", "who": str(st.get("who", "")), "text": parts[j]})
	_fill_steps()
	_build_step()
	info.text = "Split into %d boxes." % parts.size()

# ------------------------------------------------------------------ list, save, test
func _new() -> void:
	var n = events.size() + 1
	while events.any(func(x): return str(x.get("id", "")) == "event%d" % n):
		n += 1
	events.append({"id": "event%d" % n, "name": "NEW EVENT", "once": true, "trigger": {"type": "talk", "person": "TRAVELLER"}, "if": {},
		"steps": [{"do": "say", "who": "TRAVELLER", "text": "Hello, %s!"}, {"do": "give", "item": "senzu", "count": 1}]})
	_fill()
	_choose(events.size() - 1)

func _copy() -> void:
	var e = _ev()
	if e.is_empty():
		return
	var c = e.duplicate(true)
	c["id"] = str(c["id"]) + "_copy"
	events.append(c)
	_fill()
	_choose(events.size() - 1)

func _delete() -> void:
	if cur < 0:
		return
	events.remove_at(cur)
	cur = mini(cur, events.size() - 1)
	_fill()
	if cur >= 0:
		_choose(cur)
	else:
		_build_form(); _fill_steps(); _build_step()

func _save() -> bool:
	Mods.backup()
	var path = Assets.exe_dir().path_join("content/events.json")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		info.text = "Could not save content/events.json."
		return false
	f.store_string(JSON.stringify({"_help": "Events (DEV TOOLS - EVENTS): trigger, if, once, steps.", "events": events}, "  "))
	f.close()
	Content.reload()
	info.text = "Saved (content/events.json). The game uses them now."
	return true

func _test() -> void:
	var e = _ev()
	if e.is_empty() or not _save():
		return
	Game.cfg["test_event"] = str(e["id"])
	tools.play_here(tools.cam.position, {"god": true})


## the lines of the game (Legacy of Goku II, read from your game at the import): search and pick one
func _line_library(st: Dictionary) -> void:
	var all = Assets.json(Assets.base_dir.path_join("data/strings.json"))
	var lines = []
	# what the game's people say (all of LoG2's towns), then its other texts
	var ppl = Assets.json(Assets.base_dir.path_join("data/people.json"))
	if ppl is Dictionary:
		var seen = {}
		for k in ppl:
			for pp in ppl[k]:
				for l in pp.get("lines", []):
					var tl = str(l)
					if tl.length() >= 6 and not seen.has(tl):
						seen[tl] = true
						lines.append(tl)
	if all is Array:
		for t in all:
			var tt = str(t)
			if tt.length() >= 12 and tt.count(" ") >= 2:
				lines.append(tt)
	var d = AcceptDialog.new(); d.title = "LINES FROM THE GAME"; d.ok_button_text = "CLOSE"
	d.size = Vector2i(760, 460)
	var v = VBoxContainer.new(); d.add_child(v)
	var q = LineEdit.new(); q.placeholder_text = "search (a word, a name: GOKU, senzu, Cell...)"; v.add_child(q)
	var il = ItemList.new(); il.custom_minimum_size = Vector2(720, 340); il.add_theme_font_size_override("font_size", 9); v.add_child(il)
	var info = Label.new(); info.add_theme_font_size_override("font_size", 9); info.add_theme_color_override("font_color", Color(1, 0.9, 0.55)); v.add_child(info)
	var fill = func():
		il.clear()
		var w = q.text.strip_edges().to_lower()
		var n = 0
		for t in lines:
			if w == "" or t.to_lower().contains(w):
				il.add_item(t.left(150))
				il.set_item_metadata(il.item_count - 1, t)
				n += 1
				if n >= 400:
					break
		info.text = "%d lines%s. Click one: it goes into the step (the speaker too, when the line has one)." % [n, " (the first 400)" if n >= 400 else ""]
	q.text_changed.connect(func(_t): fill.call())
	il.item_selected.connect(func(i):
		var t = str(il.get_item_metadata(i))
		while t.length() > 0 and t[0] in ["?", "+", "-", "*", "#", "@", "!"]:
			t = t.substr(1)
		var c = t.find(": ")
		if c > 0 and c < 20 and t.substr(0, c) == t.substr(0, c).to_upper():
			st["who"] = t.substr(0, c)
			t = t.substr(c + 2)
		st["text"] = t.strip_edges()
		_build_step()
		_fill_steps()
		d.queue_free())
	d.confirmed.connect(func(): d.queue_free())
	d.canceled.connect(func(): d.queue_free())
	add_child(d)
	fill.call()
	if lines.is_empty():
		info.text = "No lines found - import your game first (the game reads them from it)."
	d.popup_centered()
