extends Control
## DEV TOOLS: the editors for HEROES (and new heroes), ENEMIES, MOVES, FORMS, BLASTS and MISSIONS.
## A list on the left, the chosen entry's fields in the middle (numbers, words, on/off; lists as JSON),
## a picture of it on the right. SAVE writes the file into the "content" folder next to LoG2Coop.exe -
## the game reads it from there at the next start (and the DEV TOOLS use it at once).

var tools
var kind = ""
var entries = []
var cur = -1
var list: ItemList
var form: VBoxContainer
var prev: ActorView
var prev_anim = 1
var prev_dir = 0
var prev_t = 0
var info: Label
var built = false
var tune_btn: Button
var build_btn: Button
var defaults = []      # ENEMIES: the game's own values (only what your team changes is written)

const TEMPLATES = {
	"MOVES": {"id": "new_move", "name": "NEW MOVE", "who": ["GOKU"], "level": 1, "ep": 4, "cooldown": 60, "type": "blast", "power": 2.0, "stat": "pwr", "speed": 4.0, "range": 200, "width": 8, "color": "ffd27f", "sfx": "beam", "info": "What it does."},
	"FORMS": {"id": "new_form", "name": "NEW FORM", "who": "GOKU", "level": 10, "unlock": "level", "set": -1, "str": 1.2, "pwr": 1.2, "end": 1.0, "speed": 1.1, "drain_ticks": 60, "tint": "ffffff", "aura": "ffff80"},
	"MISSIONS": {"id": "new_mission", "name": "NEW MISSION", "info": "Beat 10 foes.", "type": "kill", "target": "any", "count": 10, "level": 1, "reward": {"zeni": 100, "exp": 0.5, "items": {}, "forms": [], "states": []}},
	"SHOPS": {"id": "new_shop", "name": "NEW SHOP", "info": "Welcome!", "items": [{"id": "senzu", "price": 150}, {"id": "power_pill", "price": 60}]},
	"LOOT": {"id": "8", "name": "FOE 8", "replace": false, "drops": [{"item": "senzu", "chance": 0.05, "count": 1}], "zeni": 0},
	"STORY": {"id": "story", "title": "MY STORY", "subtitle": "A LEGACY OF GOKU ADVENTURE", "hero": "GOKU", "start_map": "land/0/0", "x": 8088, "y": 9632, "intro_event": "", "credits": ["MY STORY", "", "MADE WITH LOG2 ONLINE DEV TOOLS", "", "THANKS FOR PLAYING!"], "credits_music": "victory"},
	"STATES": {"id": "new_state", "name": "NEW STATE", "msg": "SOMETHING HAPPENED!", "seconds": 10, "hp_per_sec": 0, "speed": 1.0, "str": 1.0, "pwr": 1.0, "end": 1.0, "color": "ffffff"},
	"HEROES": {"id": "NEWHERO", "name": "NEWHERO", "base": "GOKU", "set": 60, "inherit": true, "stats": {"maxhp": 90, "maxep": 22, "str": 4.0, "pwr": 4.0, "end": 4.0}},
}

const HELP = {
	"HEROES": "The game's six heroes and your own. base = the hero yours plays like (its moves and forms, with inherit on). set = the sprite set it wears (the picture on the right: change it and look). stats = its numbers at level 1. NEW makes a new playable hero - it shows in the character list at the next start.",
	"ENEMIES": "Every kind of foe in the game (0-127): its level, hp, atk, exp, w8 (which of the game's behaviour scripts it runs), set (its sprite set) and style (how a boss of that kind fights). + FIELD inflict {\"state\": \"poison\", \"chance\": 0.3}: its blows put that state on you (STATES).",
	"MOVES": "Special moves: who has it, from which level, the ki it costs (ep), power, range, speed... 'rom' = one of the game's own drawn attacks (see BLASTS). + FIELD: then_form (transform when the move ends), self_state (a state on you: rage...), inflict {\"state\": \"poison\", \"chance\": 0.5} (on foes it hits).",
	"FORMS": "Transformations: who, from which level, the sprite set (-1 keeps the normal one), how much stronger (str / pwr / end / speed), how fast it drains ki. unlock: level (at its level), reward (a MISSION reward 'forms' or an event's UNLOCK FORM step gives it - Universal Blue, SSJ4 Limit Breaker...), event (never on the button: only events, a move's then_form or a state's form put you in it).",
	"STORY": "Make it a game of its own. With a title here, the main menu shows your story with 3 save slots. hero (who you play), start_map + x, y (where it starts: X, Y from the MAP tab), intro_event (an EVENTS id that runs at the start of a new game), credits (lines shown by the THE_END event step), credits_music. Only one story: the first entry is used.",
	"STATES": "States on a fighter for a while (RPG-style): poison, blind, slow... seconds (0 = until an event or item takes it off), hp_per_sec / ep_per_sec (minus hurts; can_kill), str / pwr / end / speed (x), blind, stun, no_ki, no_transform, confuse, form (turned into it while the state lasts), tint, aura, msg. Given by: events (STATE step), moves (self_state on you, inflict {state, chance} on foes hit), foe kinds (ENEMIES 'inflict' {state, chance}), items (state; cure: all or [ids]), mission rewards (states). Foes feel poison/regeneration, stun and slow.",
	"BLASTS": "The heroes' own drawn attacks. Every offset is [x, y] from the hero's feet for each direction [down, up, left, right]. Easiest: TUNE IN THE GAME - fire the blast and move it with the arrow keys until it sits right.",
	"SHOPS": "Shops: a name, a greeting (info) and what it sells: items [{id, price}]. Give a shop to a person: PERSON tool - shop. (The Capsule Corp delivery in the menu stays as well.)",
	"LOOT": "What a kind of foe drops: id = the foe number (0-127), drops [{item, chance 0-1, count}], zeni = extra zeni. replace true: only these (no usual drops).",
	"MISSIONS": "Missions: kill (target: any, elite, boss, human, animal, robot, big, or a foe number), visit (where: part of a place's name), level, talk (who). reward: zeni, exp (1.0 = a whole level), items {id: count}. from: a person who gives it.",
}

func show_editor(k: String) -> void:
	if not built:
		_build()
	kind = k
	_load()
	_fill_list()
	info.text = HELP.get(kind, "")
	if entries.size() > 0:
		_choose(0)
	else:
		cur = -1
		for c in form.get_children():
			c.queue_free()        # (nothing here yet: not the last list's fields)
		var l = Label.new(); l.text = "Nothing here yet - NEW makes one."; l.add_theme_font_size_override("font_size", 11); form.add_child(l)

func _build() -> void:
	built = true
	var bg = ColorRect.new(); bg.color = Color(0.07, 0.08, 0.13); bg.set_anchors_preset(Control.PRESET_FULL_RECT); add_child(bg)
	var h = HBoxContainer.new(); h.set_anchors_preset(Control.PRESET_FULL_RECT); h.offset_top = 4; h.offset_left = 4; h.offset_right = -4; h.offset_bottom = -4
	add_child(h)
	var lv = VBoxContainer.new(); lv.custom_minimum_size = Vector2(190, 0); h.add_child(lv)
	var bb = HBoxContainer.new(); lv.add_child(bb)
	for t in [["NEW", _new], ["COPY", _copy], ["DELETE", _delete]]:
		var b = Button.new(); b.text = t[0]; b.add_theme_font_size_override("font_size", 10); b.pressed.connect(t[1]); bb.add_child(b)
	list = ItemList.new(); list.size_flags_vertical = Control.SIZE_EXPAND_FILL; list.add_theme_font_size_override("font_size", 10)
	list.item_selected.connect(_choose)
	lv.add_child(list)
	var mid = VBoxContainer.new(); mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL; h.add_child(mid)
	info = Label.new(); info.autowrap_mode = TextServer.AUTOWRAP_WORD; info.add_theme_font_size_override("font_size", 10)
	info.add_theme_color_override("font_color", Color(1, 0.9, 0.55))
	mid.add_child(info)
	var sb = HBoxContainer.new(); mid.add_child(sb)
	var save = Button.new(); save.text = "SAVE"; save.pressed.connect(_save); sb.add_child(save)
	var tune = Button.new(); tune.text = "TUNE IN THE GAME (F9)"; tune.pressed.connect(_tune); sb.add_child(tune); tune_btn = tune
	var addf = Button.new(); addf.text = "+ FIELD"; addf.pressed.connect(_add_field); sb.add_child(addf)
	build_btn = Button.new(); build_btn.text = "BUILD A MOVE"; build_btn.pressed.connect(_move_builder); sb.add_child(build_btn)
	var sc = ScrollContainer.new(); sc.size_flags_vertical = Control.SIZE_EXPAND_FILL; sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	mid.add_child(sc)
	form = VBoxContainer.new(); form.size_flags_horizontal = Control.SIZE_EXPAND_FILL; sc.add_child(form)
	var rv = VBoxContainer.new(); rv.custom_minimum_size = Vector2(200, 0); h.add_child(rv)
	var holder = Control.new(); holder.custom_minimum_size = Vector2(200, 200); rv.add_child(holder)
	var pbg = ColorRect.new(); pbg.color = Color(0.2, 0.32, 0.2); pbg.size = Vector2(200, 200); holder.add_child(pbg)
	prev = ActorView.new(); prev.position = Vector2(100, 150); prev.scale = Vector2(3, 3); holder.add_child(prev)
	var pb = HBoxContainer.new(); rv.add_child(pb)
	for t in [["TURN", func(): prev_dir = (prev_dir + 1) % 4], ["POSE", func(): prev_anim = (prev_anim + 1) % 20]]:
		var b = Button.new(); b.text = t[0]; b.pressed.connect(t[1]); pb.add_child(b)
	var pl = Label.new(); pl.name = "poselabel"; pl.add_theme_font_size_override("font_size", 10); rv.add_child(pl)

func _process(_dt: float) -> void:
	if not visible or prev == null:
		return
	prev_t += 1
	var fr = prev.frames_of(prev_anim, prev_dir)
	prev.show_frame(prev_anim, prev_dir, (prev_t / 8) % maxi(1, fr.size()))

# ------------------------------------------------------------------ the data
func _user(file: String) -> String:
	return Assets.exe_dir().path_join("content/%s.json" % file)

func _load() -> void:
	entries = []
	match kind:
		"HEROES":
			for i in Assets.CHARACTERS.size():
				var nm = Assets.CHARACTERS[i]
				var h = Mods.hero_entry(nm)
				var st = Assets.hero_stats(i)
				var e = {"id": nm, "name": str(h.get("name", nm)), "base": Assets.BASE_HEROES[Assets.hero_base(i)], "set": Assets.character_set(i), "inherit": bool(h.get("inherit", true)),
					"stats": {"maxhp": int(st["maxhp"]), "maxep": int(st["maxep"]), "str": float(st["str"]), "pwr": float(st["pwr"]), "end": float(st["end"])}}
				entries.append(e)
		"ENEMIES":
			defaults = []
			for t in 128:
				var r: Dictionary = Assets._rom_enemies[t] if t < Assets._rom_enemies.size() else Assets.data["enemies"][t]
				defaults.append({"lvl": int(r["lvl"]), "hp": int(r["hp"]), "atk": int(r["atk"]), "exp": int(r["exp"]), "w8": int(r.get("w8", 0)), "set": Assets.set_for_type(t)})
				var d: Dictionary = Assets.data["enemies"][t]
				var e = {"type": t, "lvl": int(d["lvl"]), "hp": int(d["hp"]), "atk": int(d["atk"]), "exp": int(d["exp"]), "w8": int(d.get("w8", 0)),
					"set": int(Content.enemy_types.get(t, {}).get("set", Assets.set_for_type(t)))}
				if Content.enemy_types.get(t, {}).has("style"):
					e["style"] = Content.enemy_types[t]["style"]
				if Content.enemy_types.get(t, {}).has("inflict"):
					e["inflict"] = Content.enemy_types[t]["inflict"]
				entries.append(e)
		"MOVES":
			entries = Content.skills.duplicate(true)
		"FORMS":
			entries = Content.forms.duplicate(true)
		"MISSIONS":
			entries = Content.quests.duplicate(true)
		"SHOPS":
			entries = Content.shops.duplicate(true)
		"LOOT":
			entries = Content.loot.duplicate(true)
		"STATES":
			entries = Content.states.duplicate(true)
		"STORY":
			entries = [Content.story.duplicate(true)] if not Content.story.is_empty() else []
		"BLASTS":
			for k in Content.rom_specials:
				if str(k).begins_with("_"):
					continue
				var e: Dictionary = Content.rom_specials[k].duplicate(true)
				e["id"] = k
				entries.append(e)
	tune_btn.visible = kind in ["BLASTS", "MOVES", "HEROES"]
	build_btn.visible = kind == "MOVES"

func _title(e: Dictionary) -> String:
	match kind:
		"ENEMIES":
			return "%3d  lv %d  set %d" % [int(e["type"]), int(e["lvl"]), int(e["set"])]
		"HEROES":
			return str(e["id"]) + ("" if Assets.BASE_HEROES.has(str(e["id"])) else "  (YOURS)")
	return "%s  %s" % [str(e.get("id", "")), str(e.get("name", e.get("who", "")))]

func _fill_list() -> void:
	list.clear()
	for e in entries:
		list.add_item(_title(e))

func _choose(i: int) -> void:
	cur = i
	list.select(i)
	for c in form.get_children():
		c.queue_free()
	if i < 0 or i >= entries.size():
		return
	var e: Dictionary = entries[i]
	for k in e:
		_field(e, k)
	_update_preview()

func _field(e: Dictionary, k: String) -> void:
	var h = HBoxContainer.new(); form.add_child(h)
	var l = Label.new(); l.text = k; l.custom_minimum_size = Vector2(110, 0); l.add_theme_font_size_override("font_size", 10); h.add_child(l)
	var v = e[k]
	if (k == "id" and kind == "ENEMIES") or (k == "type" and kind == "ENEMIES"):
		var lb = Label.new(); lb.text = str(v); h.add_child(lb)
		return
	if v is bool:
		var cb = CheckBox.new(); cb.button_pressed = v
		cb.toggled.connect(func(on): e[k] = on)
		h.add_child(cb)
	elif v is int or v is float:
		var s = SpinBox.new(); s.min_value = -99999; s.max_value = 99999; s.allow_greater = true; s.allow_lesser = true
		s.step = 0.01 if (v is float and fmod(float(v), 1.0) != 0.0) or k in ["power", "str", "pwr", "end", "speed", "exp"] else 1
		s.value = float(v)
		s.custom_minimum_size = Vector2(120, 0)
		s.value_changed.connect(func(nv): e[k] = int(nv) if s.step == 1 else nv; _changed(k))
		h.add_child(s)
	elif v is String:
		var le = LineEdit.new(); le.text = v; le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		le.text_changed.connect(func(t): e[k] = t; _changed(k))
		h.add_child(le)
	else:
		var le = LineEdit.new(); le.text = JSON.stringify(v); le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		le.text_changed.connect(func(t):
			var p = JSON.parse_string(t)
			if p == null and t.strip_edges() != "null":
				le.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
			else:
				le.remove_theme_color_override("font_color")
				e[k] = p
				_changed(k))
		h.add_child(le)

func _changed(k: String) -> void:
	if k in ["set", "base", "who", "type"]:
		_update_preview()
	list.set_item_text(cur, _title(entries[cur]))

func _update_preview() -> void:
	if cur < 0 or cur >= entries.size():
		return
	var e: Dictionary = entries[cur]
	var st = -1
	match kind:
		"HEROES", "ENEMIES":
			st = int(e.get("set", -1))
		"FORMS":
			st = int(e.get("set", -1))
			if st < 0:
				st = _hero_set(str(e.get("who", "GOKU")))
		"MOVES", "BLASTS":
			var w = e.get("who", "GOKU")
			st = _hero_set(str(w[0]) if w is Array and w.size() > 0 else str(w))
			if kind == "BLASTS" and e.has("pose_fire"):
				prev_anim = int(e["pose_fire"][prev_dir][0])
	if st >= 0:
		prev.set_sprite_set(Assets.sprite_set(st))

func _hero_set(nm: String) -> int:
	var i = Assets.CHARACTERS.find(nm)
	return Assets.character_set(i) if i >= 0 else 60

func _new() -> void:
	var t: Dictionary = TEMPLATES.get(kind, {})
	if t.is_empty():
		tools._say("Copy an entry instead (COPY).")
		return
	var e = t.duplicate(true)
	e["id"] = str(e["id"]) + str(entries.size())
	if kind == "HEROES":
		e["name"] = e["id"]
	entries.append(e)
	_fill_list()
	_choose(entries.size() - 1)

func _copy() -> void:
	if cur < 0 or kind == "ENEMIES":
		return
	var e: Dictionary = entries[cur].duplicate(true)
	e["id"] = str(e.get("id", "copy")) + "_2"
	if kind == "HEROES":
		e["id"] = str(e["id"]).to_upper().replace("_", "")
		e["name"] = e["id"]
	entries.append(e)
	_fill_list()
	_choose(entries.size() - 1)

func _delete() -> void:
	if cur < 0 or kind == "ENEMIES" or (kind == "HEROES" and Assets.BASE_HEROES.has(str(entries[cur]["id"]))):
		return
	entries.remove_at(cur)
	_fill_list()
	_choose(mini(cur, entries.size() - 1))

func _add_field() -> void:
	if cur < 0:
		return
	var d = AcceptDialog.new(); d.title = "A NEW FIELD"
	var v = VBoxContainer.new(); d.add_child(v)
	var nk = LineEdit.new(); nk.placeholder_text = "name"; v.add_child(nk)
	var nv = LineEdit.new(); nv.placeholder_text = "value (a number, \"words\", true, [1,2])"; v.add_child(nv)
	d.confirmed.connect(func():
		var p = JSON.parse_string(nv.text)
		entries[cur][nk.text.strip_edges()] = p if p != null else nv.text
		_choose(cur)
		d.queue_free())
	add_child(d)
	d.popup_centered(Vector2i(320, 120))

func _write(file: String, d: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(Assets.exe_dir().path_join("content"))
	var f = FileAccess.open(_user(file), FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(d, " "))
	f.close()
	return true

func _help_of(file: String) -> String:
	var b = Content._load("res://content/%s.json" % file)
	return str(b.get("_help", ""))

func _save() -> void:
	Mods.backup()
	var ok = false
	match kind:
		"HEROES":
			var out = []
			for e in entries:
				var c: Dictionary = e.duplicate(true)
				c["id"] = str(c["id"]).to_upper()
				out.append(c)
			ok = _write("heroes", {"_help": "Heroes: the game's own (their numbers and sprite set) and your team's (id, name, base = the hero it plays like, inherit = gets the base hero's moves and forms, set = sprite set, stats). New heroes show in the character list.", "heroes": out})
		"ENEMIES":
			var cur_file = Content._load(_user("enemies"))
			if cur_file.is_empty():
				cur_file = Content._load("res://content/enemies.json")
			var out = []
			for e in entries:
				var t = int(e["type"])
				var dd = {"type": t}
				for k in e:
					if k == "type":
						continue
					if k == "style" or not defaults[t].has(k) or defaults[t][k] != e[k]:
						dd[k] = e[k]
				if dd.size() > 1:
					out.append(dd)
			cur_file["types"] = out
			ok = _write("enemies", cur_file)
		"MOVES":
			ok = _write("skills", {"_help": _help_of("skills"), "skills": entries})
		"FORMS":
			ok = _write("forms", {"_help": _help_of("forms"), "forms": entries})
		"MISSIONS":
			ok = _write("quests", {"_help": _help_of("quests"), "quests": entries})
		"SHOPS":
			ok = _write("shops", {"_help": HELP["SHOPS"], "shops": entries})
		"LOOT":
			for e in entries:
				e["id"] = str(e["id"])
			ok = _write("loot", {"_help": HELP["LOOT"], "loot": entries})
		"STATES":
			ok = _write("states", {"_help": HELP["STATES"], "states": entries})
		"STORY":
			ok = _write("story", {"_help": HELP["STORY"], "story": entries[0] if not entries.is_empty() else {}})
		"BLASTS":
			var d = {"_help": str(Content.rom_specials.get("_help", "")), "_sets": Content.rom_specials.get("_sets", {})}
			for e in entries:
				var c: Dictionary = e.duplicate(true)
				var id = str(c["id"])
				c.erase("id")
				d[id] = c
			ok = _write("rom_specials", d)
	Content.reload()
	Assets.apply_enemy_overrides()
	tools._say("Saved into the content folder - the game uses it at the next start." if ok else "Could not save (is the game folder read-only?)")
	info.text = ("SAVED. " if ok else "NOT SAVED. ") + HELP.get(kind, "")

## MOVES: a new move from its kind and numbers, with a moving preview
func _move_builder() -> void:
	var d = preload("res://scripts/dev_movebuilder.gd").new()
	d.built.connect(func(m):
		while entries.any(func(x): return str(x.get("id", "")) == str(m["id"])):
			m["id"] = str(m["id"]) + "_2"
		entries.append(m)
		_fill_list()
		_choose(entries.size() - 1)
		info.text = "%s made - SAVE to keep it, TUNE IN THE GAME to try it." % m["name"]
		d.queue_free())
	d.canceled.connect(func(): d.queue_free())
	add_child(d)
	d.popup_centered()

## BLASTS: play the game with the blast tuner (F9) on, with the chosen hero
func _tune() -> void:
	_save()
	var who = "GOKU"
	if cur >= 0:
		var e: Dictionary = entries[cur]
		if kind == "HEROES":
			who = str(e["id"])
		else:
			var w = e.get("who", "GOKU")
			who = str(w[0]) if w is Array and w.size() > 0 else str(w)
	Game.cfg["character"] = maxi(0, Assets.CHARACTERS.find(who))
	Game.cfg["blast_tune"] = str(entries[cur].get("id", "")) if kind == "BLASTS" else ""
	tools.start_tuning()
