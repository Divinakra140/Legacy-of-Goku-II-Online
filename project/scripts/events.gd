extends RefCounted
## EVENTS in the game (made in DEV TOOLS - EVENTS, content/events.json): scenes, talks with choices, story flags,
## rewards, doors that open later, bosses. One event runs per player at a time; while it runs it has the buttons.
##
## event: {"id", "name", "trigger": {"type": "talk"|"area"|"enter"|"start"|"defeat", "person", "map", "kind"},
##         "if": {"flags": [...], "not_flags": [...], "level": n, "quest_done": id, "has_item": id}, "once": true,
##         "steps": [{"do": ...}, ...]}
## steps: say {who, text}  choice {text, options: [[label, goto]]}  label {name}  goto {label}  if_flag {name, goto}
##        flag {name, on}  give {item, count}  take {item, count}  zeni {amount}  exp {amount}  heal
##        quest {id}  finish_quest {id}  wait {frames}  fade  warp {map, x, y}  spawn {kind, level, boss, x, y}
##        shop {id}  sound {name}  music {name}  toast {text}  end
##  scenes: move {who, x, y, speed, wait}  face {who, dir}  pose {who, pose, loop}  camera {x, y | who, zoom, frames, wait}
##          camera_back  shake {amount}  show_person {name, set, x, y, dir}  hide_person {who}  emote {who, kind}
##          say {face: sprite set}  boss_fight {kind, level, x, y, name, win, lose, phases "0.5:label"}  fight_on
##  logic:  var {name, op, value, max}  if_var {name, cmp, value, goto}  timer {name, seconds, show}  if_timer {name, goto}
##  cartridge: story {table, from} (one of LoG2's own scenes - story.gd)
##  story:  companion {who, name, level, leave}  switch_hero {hero}  open_area / close_area {x0, y0, x1, y1, id}  save  the_end

var world

func _init(w) -> void:
	world = w

func find(id: String) -> Dictionary:
	if id.begins_with("story:"):
		return Story.event(id)
	for e in Content.events:
		if str(e.get("id", "")) == id:
			return e
	return {}

## may this event start for this player now?
func allowed(L, e: Dictionary) -> bool:
	var f = L.fighter
	if e.is_empty():
		return false
	if bool(e.get("once", true)) and f.flags.has("event:" + str(e["id"])):
		return false
	var c: Dictionary = e.get("if", {})
	for fl in c.get("flags", []):
		if not f.flags.get(str(fl), false):
			return false
	for fl in c.get("not_flags", []):
		if f.flags.get(str(fl), false):
			return false
	if int(c.get("level", 0)) > f.level:
		return false
	if str(c.get("quest_done", "")) != "" and not f.qdone.has(str(c["quest_done"])):
		return false
	if str(c.get("has_item", "")) != "" and int(f.inv.get(str(c["has_item"]), 0)) <= 0:
		return false
	if str(c.get("has_state", "")) != "" and not f.states.has(str(c["has_state"])):
		return false
	if str(c.get("in_form", "")) != "" and str(f.form().get("id", "")) != str(c["in_form"]):
		return false
	if str(c.get("has_form", "")) != "" and not f.flags.has("form:" + str(c["has_form"])):
		return false
	return true

func start(L, id: String) -> bool:
	var e = find(id)
	if e.is_empty() or not L.ev.is_empty() or not allowed(L, e):
		return false
	L.ev = {"id": id, "pc": 0, "wait": 0, "sel": 0, "say": {}, "choice": [], "hold": true}
	L.fighter.flags["event:" + id] = true
	L.talk = {}
	_run(L)
	return true

## the triggers
func on_talk(L, person: Dictionary) -> bool:
	if str(person.get("event", "")) != "" and start(L, str(person["event"])):
		return true
	var nm = str(person.get("name", ""))
	for e in Content.events:
		var t: Dictionary = e.get("trigger", {})
		if str(t.get("type", "")) == "talk" and str(t.get("person", "")).to_upper() == nm.to_upper() and allowed(L, e):
			return start(L, str(e["id"]))
	return false

func on_enter(L, key: String) -> void:
	for e in Content.events:
		var t: Dictionary = e.get("trigger", {})
		if str(t.get("type", "")) == "enter" and str(t.get("map", "")) == key and allowed(L, e):
			start(L, str(e["id"]))
			return

func on_start(L) -> void:
	for e in Content.events:
		if str(e.get("trigger", {}).get("type", "")) == "start" and allowed(L, e):
			start(L, str(e["id"]))
			return

func on_defeat(L, kind: int) -> void:
	for e in Content.events:
		var t: Dictionary = e.get("trigger", {})
		if str(t.get("type", "")) == "defeat" and int(t.get("kind", -1)) == kind and allowed(L, e):
			start(L, str(e["id"]))
			return

## walking into an event box of the map (DEV TOOLS - EVENT tool)
func check_area(L) -> void:
	if not L.ev.is_empty():
		return
	var trig: Array = Game.planet.nodes[L.node_i]["spec"].get("triggers", [])
	var inside = {}
	for t in trig:
		var r: Array = t["rect"]
		if bool(t.get("attack", false)):
			# (a rock to break, a switch to hit: only an attack landing in the box starts it)
			if _attack_in(L.fighter, r) and allowed(L, find(str(t["event"]))):
				start(L, str(t["event"]))
				return
			continue
		if L.fighter.x >= float(r[0]) and L.fighter.x <= float(r[2]) and L.fighter.y >= float(r[1]) and L.fighter.y <= float(r[3]):
			inside[str(t["event"])] = true
			if not L.in_trig.has(str(t["event"])):
				start(L, str(t["event"]))
	L.in_trig = inside

# ------------------------------------------------------------------ running
## one tick: true while the event has the buttons
func tick(L, raw: Dictionary) -> bool:
	if L.ev.is_empty():
		_step_moves(L)      # (people a scene sent walking keep going after it: Gohan off to the boulders)
		return false
	var ev: Dictionary = L.ev
	var a = bool(raw.get("a", false))
	var a_new = a and not ev.get("a_prev", true)
	var up_new = bool(raw.get("up", false)) and not ev.get("up_prev", true)
	var dn_new = bool(raw.get("down", false)) and not ev.get("dn_prev", true)
	ev["a_prev"] = a; ev["up_prev"] = bool(raw.get("up", false)); ev["dn_prev"] = bool(raw.get("down", false))
	_step_moves(L)
	# a foe held still while the scene talks (hold_foe), the player kept down (a lost fight's scene), the effects
	if ev.has("held") and not ev.has("fight"):
		var he = _foe_at(ev["held"])
		if not he.is_empty():
			he["hold"] = 3
	if ev.get("down_hold", false):
		L.fighter.down_t = maxi(L.fighter.down_t, 10)
	if ev.has("orb"):
		ev["orb"]["t"] = int(ev["orb"]["t"]) + 1
	if ev.has("big"):
		ev["big"]["t"] = int(ev["big"]["t"]) + 1
	if ev.has("fight"):
		var fr = _step_fight(L)
		if fr == "go":
			_run(L)
			return not L.ev.is_empty() and str(L.ev.get("until", "")) != "fight"
		if str(ev.get("until", "")) == "fight":
			return false          # (the fight goes on: the player has the buttons)
		_hold_boss(L)
	var u = str(ev.get("until", ""))
	if u == "moves":
		if L.get_meta("moves", []).is_empty():
			ev["until"] = ""
			_run(L)
		return true
	if u == "camera":
		if L.cut_cam.is_empty() or int(L.cut_cam.get("t", 0)) >= int(L.cut_cam.get("n", 1)):
			ev["until"] = ""
			_run(L)
		return true
	if int(ev["wait"]) > 0:
		ev["wait"] -= 1
		if ev["wait"] <= 0:
			_run(L)
		return true
	if not ev["choice"].is_empty():
		if up_new:
			ev["sel"] = (int(ev["sel"]) + ev["choice"].size() - 1) % ev["choice"].size(); Sfx.play("move", 0.6)
		if dn_new:
			ev["sel"] = (int(ev["sel"]) + 1) % ev["choice"].size(); Sfx.play("move", 0.6)
		if a_new:
			var to = str(ev["choice"][int(ev["sel"])][1])
			ev["choice"] = []
			ev["say"] = {}
			Sfx.play("menu", 0.7)
			if to != "":
				_goto(L, to)
			_run(L)
		return true
	if not ev["say"].is_empty():
		if a_new and ev["say"].has("t0") and _typed(ev["say"]) < str(ev["say"]["text"]).length():
			ev["say"]["t0"] = -100000      # A while the letters come: all of them at once (as in the game)
			return true
		if a_new and not ev.get("pages", []).is_empty():
			ev["say"]["text"] = ev["pages"].pop_front()
			ev["say"]["t0"] = Engine.get_physics_frames()
			Sfx.play("move", 0.7)
			return true
		if a_new:
			ev["say"] = {}
			Sfx.play("move", 0.7)
			_run(L)
		return true
	_run(L)
	return not L.ev.is_empty()

func _goto(L, label: String) -> void:
	var e = find(str(L.ev["id"]))
	var steps: Array = e.get("steps", [])
	for i in steps.size():
		if str(steps[i].get("do", "")) == "label" and str(steps[i].get("name", "")) == label:
			L.ev["pc"] = i + 1
			return
	L.ev["pc"] = steps.size()

## run steps until one waits (a line to read, a choice, a pause) or the event ends
func _run(L) -> void:
	var guard = 0
	while not L.ev.is_empty() and guard < 200:
		guard += 1
		var e = find(str(L.ev["id"]))
		var steps: Array = e.get("steps", [])
		var pc = int(L.ev["pc"])
		if pc >= steps.size():
			L.ev = {}
			break
		var st: Dictionary = steps[pc]
		L.ev["pc"] = pc + 1
		var f = L.fighter
		match str(st.get("do", "")):
			"say":
				L.ev["say"] = {"who": str(st.get("who", "")), "text": _text(L, str(st.get("text", ""))), "face": int(st.get("face", -1)), "portrait": int(st.get("portrait", -1)), "narrate": bool(st.get("narrate", false)), "black": bool(st.get("black", false)), "t0": Engine.get_physics_frames(), "mine": bool(st.get("mine", Story.box_style(int(st.get("speaker", 0)), f.ch) == 1)), "gface": Story.face_for(int(st.get("speaker", 0)), f.set_id), "speaker": int(st.get("speaker", 0)), "hero_ch": f.ch, "at": str(st.get("at", ""))}      # (the game's own face and box for the line's speaker)
				var gba_box = str(L.ev.get("id", "")).begins_with("story:") and Assets.gba_font("font_talk") != null
				L.ev["say"]["gba"] = gba_box and not L.ev["say"]["narrate"]
				if L.ev["say"]["gba"] and str(L.ev["say"]["who"]) != "":
					L.ev["say"]["text"] = str(L.ev["say"]["who"]) + ": " + str(L.ev["say"]["text"])      # (the game writes the name in the line)
				if (L.ev["say"]["narrate"] or L.ev["say"]["gba"]) and gba_box:
					# the game's boxes hold 4 lines: a longer text goes on in the next box (A)
					var ls = _narration_lines(str(L.ev["say"]["text"]))
					var pages = []
					for k in range(0, ls.size(), 4):
						pages.append(" ".join(ls.slice(k, k + 4)))
					L.ev["say"]["text"] = pages[0] if not pages.is_empty() else ""
					L.ev["pages"] = pages.slice(1)
				return
			"choice":
				L.ev["say"] = {"who": str(st.get("who", "")), "text": _text(L, str(st.get("text", ""))), "face": int(st.get("face", -1))}
				L.ev["choice"] = st.get("options", [["OK", ""]])
				L.ev["sel"] = 0
				return
			"label":
				pass
			"goto":
				_goto(L, str(st.get("label", "")))
			"if_flag":
				if f.flags.get(str(st.get("name", "")), false):
					_goto(L, str(st.get("goto", "")))
			"flag":
				if bool(st.get("on", true)):
					f.flags[str(st.get("name", ""))] = true
				else:
					f.flags.erase(str(st.get("name", "")))
			"give":
				var n = f.add_item(str(st.get("item", "senzu")), int(st.get("count", 1)))
				if n > 0:
					world.toasts.append(["GOT %s x%d" % [str(Content.item(str(st.get("item", ""))).get("name", st.get("item", ""))), n], Color(0.7, 1, 0.8), 160])
			"take":
				var id = str(st.get("item", ""))
				f.inv[id] = maxi(0, int(f.inv.get(id, 0)) - int(st.get("count", 1)))
			"zeni":
				f.zeni = maxi(0, f.zeni + int(st.get("amount", 0)))
				world.toasts.append(["%+d ZENI" % int(st.get("amount", 0)), Color(1, 0.9, 0.5), 140])
			"exp":
				var up = f.add_exp(maxi(1, int(st.get("amount", 0))), world.levels)
				world.toasts.append(["+%d EXP%s" % [int(st.get("amount", 0)), "  LEVEL UP!" if up else ""], Color(0.6, 1, 0.6), 160])
			"heal":
				f.hp = f.maxhp; f.ep = f.maxep
			"unlock_form":
				var fid = str(st.get("id", ""))
				if f.unlock_form(fid):
					world.toasts.append(["NEW TRANSFORMATION: %s  (TRANSFORM BUTTON)" % str(Content.form_by_id(fid).get("name", fid)), Color(1, 0.85, 0.3), 300])
			"lock_form":
				f.lock_form(str(st.get("id", "")))
			"transform":
				f.force_form(str(st.get("id", "")))
			"revert":
				if f.form_i >= 0:
					f._revert()
			"state":
				if bool(st.get("off", false)):
					if str(st.get("id", "")) == "all":
						f.clear_states()
					else:
						f.remove_state(str(st.get("id", "")))
				else:
					f.add_state(str(st.get("id", "")), float(st.get("seconds", -1)))
			"quest":
				var qid = str(st.get("id", ""))
				if not f.quests.has(qid) and not f.qdone.has(qid):
					f.quests[qid] = 0
					world.toasts.append(["NEW MISSION: " + str(_quest_name(qid)), Color(0.6, 1, 0.7), 200])
			"finish_quest":
				var qid2 = str(st.get("id", ""))
				for q in Content.quests:
					if str(q["id"]) == qid2 and f.quests.has(qid2):
						world._quest_done(L, q)
			"wait":
				L.ev["wait"] = int(st.get("frames", 60))
				return
			"fade":
				L.fade = 1.0; L.fade_dir = -1
				L.ev.erase("dim")
			"warp":
				L.ev.erase("dim")      # (a story fade to black ends with the next place)
				var key = str(st.get("map", ""))
				for ni in Game.planet.nodes.size():
					if str(Game.planet.nodes[ni]["key"]) == key:
						world._warp(L, ni, Vector2(float(st.get("x", 0)), float(st.get("y", 0))))
						break
			"spawn":
				var sim = Game.sims.get(str(Game.planet.nodes[L.node_i]["key"]))
				if sim:
					var t = int(st.get("kind", 8))
					var p = Vector2(float(st.get("x", f.x + 60)), float(st.get("y", f.y)))
					if float(st.get("x", -1)) < 0:
						p = Vector2(f.x + 60, f.y)
					var e2 = sim.make_enemy(8000 + sim.enemies.size(), t, Assets.set_for_type(t), sim._open_near(p), maxi(1, int(st.get("level", f.level))), false, bool(st.get("boss", false)))
					e2["respawn_ms"] = 1 << 40
					e2["minion"] = true
					sim.enemies.append(e2)
			"shop":
				world._open_shop(L, str(st.get("id", "")))
			"sound":
				if st.has("id"):      # one of the game's own sounds by number (story scenes)
					var smp = Sfx.sample(int(st["id"]))
					if smp:
						Sfx.play_stream(smp)
				else:
					Sfx.play(str(st.get("name", "menu")))
			"music":
				L.ev["music"] = str(st.get("name", "field"))      # (it stays while the event runs: world.gd _pick_music)
				Music.play(L.ev["music"])
			"honor":      # an honor the hero keeps in every mode ("halo": THE HERO OF EARTH)
				f.honors[str(st.get("name", "halo"))] = true
			"hold_foe":      # a placed foe held still while the scene talks (it can't walk, punch or shoot): kind, x, y, take
				var hf = _take(L, st)
				if not hf.is_empty():
					L.ev["held"] = [_key(L), int(hf["id"])]
					hf["hold"] = 3
			"foe_pose":      # the held foe in one of its poses (anim: 11 VICTORY...)
				var pf = _foe_at(L.ev.get("held", []))
				if not pf.is_empty():
					pf["anim"] = int(st.get("anim", 11)); pf["frame"] = int(st.get("frame", 0)); pf["dir"] = int(st.get("dir", 0)); pf["state"] = "idle"
					pf["pose"] = int(st.get("anim", 11))      # (a hero foe standing in for it takes the same pose)
			"orb_up":      # a huge ball of energy grown over the held foe's head, then thrown up off the screen (a Supernova)
				var of = _foe_at(L.ev.get("held", []))
				var op = _foe_pos(L.ev.get("held", []), of) if not of.is_empty() else Vector2(f.x, f.y)
				L.ev["orb"] = {"x": op.x, "y": op.y - 40.0, "t": 0, "col": str(st.get("color", "ff7a20"))}
				Sfx.play("charge")
			"big_text":      # big words in the middle of the screen (GAME OVER)
				L.ev["big"] = {"text": str(st.get("text", "")), "t": 0, "col": str(st.get("color", "ff3030"))}
			"revive_at":      # back on your feet somewhere else (map, x, y): the held foe let go and healed, the effects gone
				var rf = _foe_at(L.ev.get("held", []))
				if not rf.is_empty():
					rf["hold"] = 0; rf["hp"] = rf["maxhp"]; rf["anim"] = 0; rf["state"] = "idle"
					rf.erase("pose")
					world.brawl.drop_rival(str(L.ev["held"][0]), int(rf["id"]))
				for k2 in ["held", "down_hold", "orb", "big"]:
					L.ev.erase(k2)
				f.revive(float(st.get("x", f.x)), float(st.get("y", f.y)))
				var rkey = str(st.get("map", _key(L)))
				for ni in Game.planet.nodes.size():
					if str(Game.planet.nodes[ni]["key"]) == rkey:
						world._warp(L, ni, Vector2(float(st.get("x", f.x)), float(st.get("y", f.y))))
						break
			"dragonballs":      # THE HERO OF EARTH: the 7 hidden round EARTH (dragonballs.gd)
				world.db_rt.scatter(f)
			"toast":
				world.toasts.append([_text(L, str(st.get("text", ""))), Color(1, 0.95, 0.7), 200])
			"shake":      # a nearby blast (story scenes) - the same camera shake a crit uses, it decays on its own
				L.shake = maxf(L.shake, float(st.get("amount", 3.0)))
			"blast_hit":      # an unseen attacker's blast lands on someone (Gohan's death at Outside Pepper Town) -
				# the same ki-hit spark and shake a PVP blast uses; whoever it's on plays their own flinch pose next
				var bw = str(st.get("who", "PLAYER"))
				var bx = f.x; var by = f.y
				if bw.to_upper() != "PLAYER":
					var bp = _person(L, bw)
					if not bp.is_empty():
						bx = float(bp["x"]); by = float(bp["y"])
				world.ki_spark(L.node_i, Vector2(bx, by), 0.0, -1.0)
				Sfx.play("hit", 0.9)
				L.shake = maxf(L.shake, 2.5)
			"end":
				L.ev = {}
				break
			"story":
				# one of LoG2's own scenes (story.gd): it plays instead of the rest of this event
				var tb = str(st.get("table", "083b725c")).to_lower().strip_edges()
				var sid = "story:intro" if tb == "intro" else "story:%s:%d" % [tb, int(st.get("from", 0))]
				if not Story.event(sid).is_empty():
					L.ev["id"] = sid
					L.ev["pc"] = 0
			# ---------------------------------------------------- scenes
			"move":
				var who = str(st.get("who", "PLAYER"))
				if not L.has_meta("moves"):
					L.set_meta("moves", [])      # (kept on the player, not the event: a walk may outlast its scene)
				L.get_meta("moves").append({"who": who, "x": float(st.get("x", f.x)), "y": float(st.get("y", f.y)), "speed": maxf(0.2, float(st.get("speed", 1.0))), "fly": bool(st.get("fly", false))})
				if bool(st.get("wait", true)):
					L.ev["until"] = "moves"
					return
			"face":
				_face(L, str(st.get("who", "PLAYER")), _dir_of(st.get("dir", "down")))
			"npc_set":      # a map person's own look changes for a scene (Future Gohan: flying/fallen frames, look 3208)
				var pw3 = _person(L, str(st.get("who", "")))
				if not pw3.is_empty():
					pw3["set"] = int(st.get("set", pw3.get("set", 0)))
			"place":      # someone is put at x, y at once (story scenes)
				var pw2 = str(st.get("who", "PLAYER"))
				if pw2.to_upper() == "PLAYER":
					f.place_at(float(st.get("x", f.x)), float(st.get("y", f.y)))
				else:
					var pp2 = _person(L, pw2)
					if not pp2.is_empty():
						pp2["x"] = float(st.get("x", pp2["x"])); pp2["y"] = float(st.get("y", pp2["y"]))
			"fade_out":      # the screen slowly goes black over `frames` (story scenes: the fire picture fades away)
				L.ev["dim"] = [Engine.get_physics_frames(), maxi(1, int(st.get("frames", 60)))]
				L.ev["wait"] = int(st.get("frames", 60))
				return
			"hide_player":      # the player not shown (a story picture)
				L.ev["hide_player"] = bool(st.get("on", true))
			"pose":
				var pw = str(st.get("who", "PLAYER"))
				var pz = int(st.get("pose", 0))
				if pw.to_upper() == "PLAYER":
					f.scene_pose = pz if pz >= 0 else -1
					f.scene_t = 0; f.scene_loop = bool(st.get("loop", false))
				else:
					var pp = _person(L, pw)
					if not pp.is_empty():
						pp["cut_pose"] = [pz, bool(st.get("loop", false)), Engine.get_physics_frames()] if pz >= 0 else []
			"camera":
				var to = Vector2(float(st.get("x", f.x)), float(st.get("y", f.y)))
				var cw = str(st.get("who", ""))
				if cw != "":
					if cw.to_upper() == "PLAYER":
						to = Vector2(f.x, f.y)
					else:
						var cp = _person(L, cw)
						if not cp.is_empty():
							to = Vector2(float(cp["x"]), float(cp["y"]))
				L.cut_cam = {"from": L.cam if L.cam != Vector2.ZERO else Vector2(f.x, f.y - 12), "to": to, "t": 0, "n": maxi(1, int(st.get("frames", 45))), "zoom": maxf(0.5, float(st.get("zoom", 1.0)))}
				if bool(st.get("wait", true)):
					L.ev["until"] = "camera"
					return
			"camera_back":
				L.cut_cam = {}
			"shake":
				L.shake = maxf(L.shake, float(st.get("amount", 4)))
			"show_person":
				var np = {"name": str(st.get("name", "SOMEONE")), "set": int(st.get("set", 54)), "x": float(st.get("x", f.x + 30)), "y": float(st.get("y", f.y)),
					"lines": [], "cut_dir": _dir_of(st.get("dir", "down"))}
				_remove_person(L, np["name"])
				L.area["people"].append(np)
				f.flags["shown:%s:%s" % [_key(L), np["name"]]] = np.duplicate()
				f.flags.erase("hidden:%s:%s" % [_key(L), str(np["name"]).to_upper()])
			"hide_person":
				var hw = str(st.get("who", ""))
				var hp2 = _person(L, hw)
				if not hp2.is_empty():
					hp2["hidden"] = true
				f.flags["hidden:%s:%s" % [_key(L), hw.to_upper()]] = [float(hp2["x"]), float(hp2["y"])] if not hp2.is_empty() else true
				f.flags.erase("shown:%s:%s" % [_key(L), hw])
			"emote":
				var ew = str(st.get("who", "PLAYER"))
				var kind = str(st.get("kind", "!"))
				if ew.to_upper() == "PLAYER":
					world.emote_player(L, kind)
				else:
					var ep2 = _person(L, ew)
					if not ep2.is_empty():
						ep2["emote"] = [kind, Engine.get_physics_frames() + 100]
			"boss_fight":
				if _start_fight(L, st):
					L.ev["until"] = "fight"
					return
			"fight_on":
				if L.ev.has("fight"):
					L.ev["until"] = "fight"
					return
			# ---------------------------------------------------- logic
			"var":
				var vn = "var:" + str(st.get("name", "x"))
				var cur_v = float(f.flags.get(vn, 0))
				var val = float(st.get("value", 0))
				match str(st.get("op", "set")):
					"add": cur_v += val
					"sub": cur_v -= val
					"mul": cur_v *= val
					"random": cur_v = randi_range(int(val), int(st.get("max", val + 10)))
					_: cur_v = val
				f.flags[vn] = cur_v
			"if_var":
				var vv = float(f.flags.get("var:" + str(st.get("name", "x")), 0))
				var cv = float(st.get("value", 0))
				var ok = false
				match str(st.get("cmp", "=")):
					"=", "==": ok = is_equal_approx(vv, cv)
					"!=": ok = not is_equal_approx(vv, cv)
					"<": ok = vv < cv
					"<=": ok = vv <= cv
					">": ok = vv > cv
					">=": ok = vv >= cv
				if ok:
					_goto(L, str(st.get("goto", "")))
			"timer":
				f.flags["timer:" + str(st.get("name", "t"))] = {"end": int(Time.get_unix_time_from_system() * 1000.0) + int(float(st.get("seconds", 30)) * 1000), "show": bool(st.get("show", true))}
			"if_timer":
				var td = f.flags.get("timer:" + str(st.get("name", "t")), {})
				if td is Dictionary and not td.is_empty() and int(Time.get_unix_time_from_system() * 1000.0) >= int(td.get("end", 0)):
					f.flags.erase("timer:" + str(st.get("name", "t")))
					_goto(L, str(st.get("goto", "")))
			# ---------------------------------------------------- story
			"companion":
				if bool(st.get("leave", false)):
					world.companion_leave(L, str(st.get("name", "")))
				else:
					world.companion_join(L, str(st.get("who", "PICCOLO")), str(st.get("name", "")), int(st.get("level", 0)))
			"switch_hero":
				world.switch_hero(L, str(st.get("hero", "GOKU")))
				f = L.fighter
				var lk = int(st.get("look", -1))
				if lk == 3207 and Assets.sprite_set(lk).is_empty():
					lk = 135      # (TEEN TRUNKS without the port's look: the game's own teen Trunks)
				if lk > 0 and not Assets.sprite_set(lk).is_empty():
					f.set_id = lk      # how they look in this scene (the intro's younger Trunks); a form or BACK TO NORMAL ends it
			"open_area", "close_area":
				var r = [float(st.get("x0", 0)), float(st.get("y0", 0)), float(st.get("x1", 0)), float(st.get("y1", 0))]
				var oid = str(st.get("id", "area%d" % hash(str(r))))
				var opening = str(st.get("do", "")) == "open_area"
				f.flags["open:" + oid] = {"key": _key(L), "rect": r, "walk": opening}
				world.apply_open(_key(L), r, opening)
			"save":
				Game.save_fighter(f, L.k)
				world.save_all()
				world.toasts.append(["THE STORY IS SAVED", Color(0.7, 1, 0.8), 160])
				Sfx.play("levelup", 0.5)
			"the_end":
				L.ev = {}
				Game.save_fighter(f, L.k)
				world.show_credits()
				break
			"demo_end":      # the demo's own goodbye screen (not the real story's credits - it has none yet)
				L.ev = {}
				Game.save_fighter(f, L.k)
				world.show_credits({"title": str(st.get("title", "THE END")), "lines": st.get("lines", []), "music": str(st.get("music", "victory"))})
				break
	if guard >= 200:
		L.ev = {}
	if L.ev.is_empty():
		_cleanup(L)
		Game.save_fighter(L.fighter, L.k)      # the story so far is kept

static func _quest_name(id: String) -> String:
	for q in Content.quests:
		if str(q["id"]) == id:
			return str(q.get("name", id))
	return id

## the box at the bottom: who speaks, the line, the choices
func draw(c: Control, L, i: int) -> void:
	if not L.ev.is_empty() and L.ev.has("dim"):      # a story fade to black (stays black until the next fade in)
		var dm: Array = L.ev["dim"]
		var da = clampf(float(Engine.get_physics_frames() - int(dm[0])) / float(dm[1]), 0.0, 1.0)
		c.draw_rect(Rect2(-4000, -4000, 12000, 12000), Color(0, 0, 0, da))
	if L.ev.is_empty() or L.ev["say"].is_empty():
		return
	if bool(L.ev["say"].get("gba", false)):
		var sy = L.ev["say"]
		_draw_story_talk(c, str(sy.get("text", "")), _typed(sy), bool(sy.get("mine", false)), int(sy.get("gface", -1)), Story.box_style(int(sy.get("speaker", 0)), int(sy.get("hero_ch", -1))), str(sy.get("at", "")))
		return
	if bool(L.ev["say"].get("narrate", false)) and Assets.gba_font("font_talk") != null:
		if bool(L.ev["say"].get("black", false)):
			c.draw_rect(Rect2(-4000, -4000, 12000, 12000), Color.BLACK)      # (the HUD is drawn scaled: cover it all)
		_draw_narration(c, str(L.ev["say"].get("text", "")), _typed(L.ev["say"]))
		return
	var vs = c.get_viewport_rect().size
	var font = ThemeDB.fallback_font
	var w = minf(320.0, vs.x - 16) if world.locals.size() == 1 else minf(232.0, vs.x / 2 - 8)
	var x = (vs.x - w) / 2.0 if world.locals.size() == 1 else (4.0 if i == 0 else vs.x - w - 4)
	var ch: Array = L.ev["choice"]
	var txt = str(L.ev["say"].get("text", ""))
	var lh = font.get_height(8)
	var nl = clampi(int(ceil(font.get_multiline_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, w - 12, 8).y / maxf(1.0, lh))), 1, 3)
	var ty = 14.0 + lh * nl         # under the lines (the box grows with them: no line over its edge)
	var h = ty + 12.0 + 10.0 * ch.size()
	var y = vs.y - h - 8 - 11 * world.toasts.size()
	c.draw_rect(Rect2(x, y, w, h), Color(0.03, 0.04, 0.12, 0.92))
	c.draw_rect(Rect2(x, y, w, h), Color(0.95, 0.85, 0.5, 0.9), false, 1.0)
	var who = str(L.ev["say"].get("who", ""))
	var face = int(L.ev["say"].get("face", -1))
	var portrait = int(L.ev["say"].get("portrait", -1))
	var ptex = Story.face(portrait) if portrait >= 0 else null
	if ptex != null:
		# a portrait: the game's own dialogue face (the same art the CAPSULE CORP computer shows - "portrait": its number)
		var pbox = Rect2(x - 46, y + h - 46, 44, 44)
		if pbox.position.x < 2:
			pbox.position.x = x + w + 2
		c.draw_rect(pbox, Color(0.03, 0.04, 0.12, 0.92))
		c.draw_texture_rect(ptex, Rect2(pbox.position + Vector2(2, 2), pbox.size - Vector2(4, 4)), false)
		c.draw_rect(pbox, Color(0.95, 0.85, 0.5, 0.9), false, 1.0)
	elif face >= 0:
		# a face: the character's first frame (facing you), in a frame left of the box
		var fs = Assets.sprite_set(face)
		if not fs.is_empty() and fs.get("slots", []).size() > 0 and not fs["slots"][0].is_empty():
			var fr: Dictionary = fs["slots"][0][0]
			var fw = float(fr["w"]); var fh = float(fr["h"])
			var box = Rect2(x - 40, y + h - 44, 38, 44)
			if box.position.x < 2:
				box.position.x = x + w + 2
			c.draw_rect(box, Color(0.03, 0.04, 0.12, 0.92))
			c.draw_rect(box, Color(0.95, 0.85, 0.5, 0.9), false, 1.0)
			var sc = minf(minf(34.0 / maxf(1.0, fw), 40.0 / maxf(1.0, fh)), 2.0)
			var dst = Rect2(box.position + (box.size - Vector2(fw, fh) * sc) / 2.0, Vector2(fw, fh) * sc)
			c.draw_texture_rect_region(fs["tex"], dst, Rect2(0, 0, fw, fh))
	if who != "":
		c.draw_string(font, Vector2(x + 6, y + 10), who, HORIZONTAL_ALIGNMENT_LEFT, w - 12, 8, Color(1, 0.85, 0.35))
	c.draw_multiline_string(font, Vector2(x + 6, y + 20), txt, HORIZONTAL_ALIGNMENT_LEFT, w - 12, 8, 3, Color(1, 1, 1))
	for j in ch.size():
		var sel = j == int(L.ev["sel"])
		c.draw_string(font, Vector2(x + 14, y + ty + 4 + j * 10), ("> " if sel else "  ") + str(ch[j][0]), HORIZONTAL_ALIGNMENT_LEFT, w - 20, 8, Color(1, 1, 0.5) if sel else Color(0.85, 0.85, 0.9))
	if ch.is_empty():
		c.draw_string(font, Vector2(x + w - 40, y + h - 4), Game.keys("A: NEXT"), HORIZONTAL_ALIGNMENT_LEFT, -1, 7, Color(0.7, 0.8, 1))

## the story's narrator, drawn like LoG2 draws it: a 160 x 64 box in the middle of the screen with a raised grey
## frame and dark lines, the words in the game's own story font (font_talk), centred both ways, 14 pixels apart
## and at most 128 pixels wide
func _narration_lines(txt: String) -> Array:
	var font = Assets.gba_font("font_talk")
	var lines = []
	var cur = ""
	for word in txt.split(" ", false):
		var t = word if cur == "" else cur + " " + word
		if cur != "" and font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x - 1 > 128:
			lines.append(cur)
			cur = word
		else:
			cur = t
	if cur != "":
		lines.append(cur)
	return lines

## the game's raised grey frame (3 pixels: light on the top and left, darker on the bottom and right)
func _gba_frame(c: Control, r: Rect2) -> void:
	for k in 3:
		var lt = Color8([255, 198, 115][k], [255, 198, 115][k], [255, 198, 115][k])
		var dk = Color8([115, 198, 255][k], [115, 198, 255][k], [115, 198, 255][k])
		c.draw_rect(Rect2(r.position.x + k, r.position.y + k, r.size.x - 2 * k, 1), lt)
		c.draw_rect(Rect2(r.position.x + k, r.position.y + k, 1, r.size.y - 2 * k), lt)
		c.draw_rect(Rect2(r.end.x - 1 - k, r.position.y + k, 1, r.size.y - 2 * k), dk)
		c.draw_rect(Rect2(r.position.x + k, r.end.y - 1 - k, r.size.x - 2 * k, 1), dk)

## a story scene's line, as the game shows it: a face box (64 x 64, light blue) and the words box (160 x 64,
## green lines) side by side at the bottom, "NAME: words" from the top left in the story font
## (the hero's own lines: face on the left and green, as Trunks in the game's opening; everyone else: face on the
## right and blue, as Gohan)
func _draw_story_talk(c: Control, txt: String, shown: int, mine: bool, gface: int = -1, style: int = -1, at: String = "") -> void:
	var font = Assets.gba_font("font_talk")
	var vs = c.get_viewport_rect().size
	var x = floorf(vs.x / 2.0) - 112.0
	var y = floorf(vs.y) - 71.0
	if at == "top":      # (the game's '!' lines: near the top; '@' in the middle - on the GBA box centres 40 / 80 / 120)
		y = floorf(vs.y / 2.0) - 72.0
	elif at == "middle":
		y = floorf((vs.y - 64.0) / 2.0)
	var fx = x if mine else x + 160.0
	var bx = x + 64.0 if mine else x
	var ft = Story.face(gface) if gface >= 0 else null
	if ft != null:
		c.draw_texture(ft, Vector2(fx, y))      # (the game's own face picture: its frame and sky in it)
	else:
		c.draw_rect(Rect2(fx + 3, y + 3, 58, 58), Color8(120, 206, 248))
		_gba_frame(c, Rect2(fx, y, 64, 64))
	var bt = Story.box(style) if style >= 0 else null
	if bt != null:
		c.draw_texture(bt, Vector2(bx, y))      # (the game's own box: frame, lines and the dark Z)
	else:
		var lc = Color8(44, 130, 94) if mine else Color8(41, 74, 140)
		for k in 58:
			c.draw_rect(Rect2(bx + 3, y + 3 + k, 154, 1), lc if k % 2 == 0 else Color.BLACK)
		_gba_frame(c, Rect2(bx, y, 160, 64))
	var lines = _narration_lines(txt)
	for j in mini(4, lines.size()):
		var t = lines[j].left(maxi(0, shown))
		shown -= lines[j].length() + 1
		c.draw_string(font, Vector2(bx + 8, y + 3 + 14 * j + 13), t, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)

## how many letters of a line are out yet (the game writes them one by one: about one every 2 frames)
func _typed(say: Dictionary) -> int:
	if not say.has("t0"):
		return 100000
	return int((Engine.get_physics_frames() - int(say["t0"])) / 2)

func _draw_narration(c: Control, txt: String, shown: int = 100000) -> void:
	var font = Assets.gba_font("font_talk")
	var lines = _narration_lines(txt)
	var vs = c.get_viewport_rect().size
	var h = maxf(64.0, 8.0 + 14.0 * lines.size())
	var x = floorf(vs.x / 2.0) - 80.0
	var y = floorf((vs.y - h) / 2.0)
	var nb = Story.box(0)
	if nb != null and h <= 64.0:
		c.draw_texture(nb, Vector2(x, y))      # (the game's own narrator box: frame, lines and the dark Z)
	else:
		var g = func(v: int) -> Color: return Color8(v, v, v)
		for k in int(h) - 6:      # the dark lines: grey, black, grey...
			c.draw_rect(Rect2(x + 3, y + 3 + k, 154, 1), g.call(90) if k % 2 == 0 else Color.BLACK)
		_gba_frame(c, Rect2(x, y, 160, h))
	var top = 3.0 + floorf((h - 6.0 - (14.0 * lines.size() + 2.0)) / 2.0)      # the lines in the middle of the box, as the game has them
	for j in lines.size():
		var lw = font.get_string_size(lines[j], HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x - 1      # (centred on the whole line, as the game)
		c.draw_string(font, Vector2(x + 80 - floorf(lw / 2.0), y + top + 14 * j + 13), lines[j].left(maxi(0, shown)), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)
		shown -= lines[j].length() + 1

## a Free Play / BRAWL / HEROES VS VILLAINS NPC's own talk box - the same look as the story's: the game's own box
## picture (its frame, lines and dark "press on" Z baked right in - no extra "A: MORE" needed, the game never drew
## one either), font_talk, "WHO: words" centred line by line. No face (not every NPC has the story's own face
## picture - a sprite-set thumbnail instead is possible later, but keeping to one plain box for now, as asked)
## near the bottom, above any toasts, blue ("anyone else" - the game's own box-colour rule)
func draw_npc_talk(c: Control, who: String, txt: String, toast_n: int = 0) -> void:
	var font = Assets.gba_font("font_talk")
	if font == null:
		return
	var lines = _narration_lines("%s: %s" % [who, txt] if who != "" else txt)
	var vs = c.get_viewport_rect().size
	var h = maxf(64.0, 8.0 + 14.0 * lines.size())
	var x = floorf(vs.x / 2.0) - 80.0
	var y = floorf(vs.y) - h - 8.0 - 11.0 * toast_n
	var nb = Story.box(2)
	if nb != null and h <= 64.0:
		c.draw_texture(nb, Vector2(x, y))      # (the game's own box: frame, lines and the dark Z)
	else:
		var lc = Color8(41, 74, 140)
		for k in int(h) - 6:
			c.draw_rect(Rect2(x + 3, y + 3 + k, 154, 1), lc if k % 2 == 0 else Color.BLACK)
		_gba_frame(c, Rect2(x, y, 160, h))
	var top = 3.0 + floorf((h - 6.0 - (14.0 * lines.size() + 2.0)) / 2.0)
	for j in lines.size():
		var lw = font.get_string_size(lines[j], HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x - 1
		c.draw_string(font, Vector2(x + 80 - floorf(lw / 2.0), y + top + 14 * j + 13), lines[j], HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)

# ------------------------------------------------------------------ scenes, fights, words
func _key(L) -> String:
	return str(Game.planet.nodes[L.node_i]["key"])

## %s = the player's name, {var:coins} = a number
func _text(L, t: String) -> String:
	t = t.replace("%s", L.name)
	var guard = 0
	while t.find("{var:") >= 0 and guard < 20:
		guard += 1
		var a = t.find("{var:")
		var b = t.find("}", a)
		if b < 0:
			break
		var nm = t.substr(a + 5, b - a - 5)
		var v = float(L.fighter.flags.get("var:" + nm, 0))
		t = t.substr(0, a) + (str(int(v)) if is_equal_approx(v, roundf(v)) else str(v)) + t.substr(b + 1)
	return t

static func _dir_of(d) -> int:
	if d is int or d is float:
		return clampi(int(d), 0, 3)
	return maxi(0, ["down", "up", "left", "right"].find(str(d).to_lower()))

## the person of that name nearest to the player (a big map can have more than one KRILLIN)
func _person(L, name: String) -> Dictionary:
	var best = {}
	var bd = INF
	var me = Vector2(L.fighter.x, L.fighter.y)
	var by_set = int(name.substr(1)) if name.begins_with("#") else -1      # "#54": the person with sprite set 54 (story scenes)
	for p in L.area.get("people", []):
		if (by_set >= 0 and int(p.get("set", -1)) == by_set) or str(p.get("name", "")).to_upper() == name.to_upper():
			var d = me.distance_squared_to(Vector2(float(p["x"]), float(p["y"])))
			if d < bd:
				bd = d; best = p
	return best

func _remove_person(L, name: String) -> void:
	var ppl: Array = L.area.get("people", [])
	for i in range(ppl.size() - 1, -1, -1):
		if str(ppl[i].get("name", "")).to_upper() == name.to_upper() and ppl[i].get("hidden", false):
			ppl.remove_at(i)

func _face(L, who: String, d: int) -> void:
	if who.to_upper() == "PLAYER":
		L.fighter.dir = d
		L.fighter.scene_dir = d
	else:
		var p = _person(L, who)
		if not p.is_empty():
			p["cut_dir"] = d

## people (and the player) walking where a MOVE step sends them
func _step_moves(L) -> void:
	var mv: Array = L.get_meta("moves", [])
	if mv.is_empty():
		return
	var f = L.fighter
	for m in mv.duplicate():
		var who = str(m["who"])
		var at: Vector2
		var p = {}
		if who.to_upper() == "PLAYER":
			at = Vector2(f.x, f.y)
		else:
			p = _person(L, who)
			if p.is_empty():
				mv.erase(m)
				continue
			at = Vector2(float(p["x"]), float(p["y"]))
		var to = Vector2(float(m["x"]), float(m["y"]))
		var dv = to - at
		var sp = float(m["speed"]) * 1.1
		var d = 0
		if absf(dv.x) > absf(dv.y):
			d = 3 if dv.x > 0 else 2
		else:
			d = 0 if dv.y > 0 else 1
		var done = dv.length() <= sp
		var nxt = to if done else at + dv.normalized() * sp
		if who.to_upper() == "PLAYER":
			f.x = nxt.x; f.y = nxt.y
			f.dir = d
			f.scene_dir = -1 if done else d
			f.scene_pose = -1 if done else 1
			f.scene_loop = true
		else:
			p["x"] = nxt.x; p["y"] = nxt.y
			p["cut_dir"] = d
			if bool(m.get("fly", false)):
				p["cut_fly"] = not done; p["cut_walk"] = false
			else:
				p["cut_walk"] = not done; p["cut_fly"] = false
			var sk = "shown:%s:%s" % [_key(L), str(p.get("name", ""))] if done else ""
			if done and f.flags.get(sk) is Dictionary:
				f.flags[sk]["x"] = nxt.x; f.flags[sk]["y"] = nxt.y; f.flags[sk]["cut_dir"] = d    # (a save finds them where they walked to)
		if done:
			mv.erase(m)

## a story boss fight: the boss comes, the doors close; it ends in WIN (beaten) or LOSE (you are knocked out)
func _start_fight(L, st: Dictionary) -> bool:
	var f = L.fighter
	var key = _key(L)
	var sim = Game.sims.get(key)
	if sim == null:
		return false
	var t = int(st.get("kind", 8))
	var p = Vector2(float(st.get("x", -1)), float(st.get("y", -1)))
	if p.x < 0:
		p = Vector2(f.x + 80, f.y)
	# "take": a foe already standing there (one placed in the map - THE HERO OF EARTH's Cooler on the Moon) becomes
	# the boss instead of a new one: the nearest of that kind within "take" px of x, y
	var e = {}
	if float(st.get("take", 0)) > 0:
		e = _take(L, st)
		if not e.is_empty():
			if st.has("match"):
				# its strength matched to the player (a placed foe's own level can be far above a story hero's)
				var tmp = sim.make_enemy(e["id"], t, int(e["set"]), Vector2(e["x"], e["y"]), maxi(1, f.level + int(st["match"])), false, true)
				for k in ["hp", "maxhp", "atk", "lvl", "exp", "base_hp", "base_atk"]:
					e[k] = tmp[k]
			e["hp"] = e["maxhp"]      # (a fresh fight: full health, whatever an earlier try left)
			e["hold"] = 0
			e.erase("pose")
			if st.has("rival_hp"):
				e["rival_hp"] = float(st["rival_hp"])
				world.brawl.drop_rival(key, int(e["id"]))      # (one already up comes back in a moment, at the boss's strength)
			var ai: Dictionary = Content.enemy_cfg.get("styles", {}).get("boss", {}).duplicate()
			ai["style"] = "boss"
			ai["own"] = Content.own_attack(t)
			e["ai"] = ai
			e["boss"] = true
			e["big"] = true
			e["respawn_ms"] = 1 << 40      # (a one-time boss: gone for this visit once beaten)
			if not sim.awake.has(e):
				sim.awake.append(e)
	var made = e.is_empty()
	if made:
		e = sim.make_enemy(sim.enemies.size(), t, Assets.set_for_type(t), sim._open_near(p), maxi(1, int(st.get("level", f.level))), false, true)
		e["respawn_ms"] = 1 << 40
		e["minion"] = true
	if str(st.get("name", "")) != "":
		e["name"] = str(st["name"])
	if float(st.get("hp", 0)) > 0:
		e["hp"] = maxi(1, roundi(e["hp"] * float(st["hp"]))); e["maxhp"] = e["hp"]
	if made:
		sim.enemies.append(e)
		sim.awake.append(e)
	var phases = []
	var ph = st.get("phases", "")
	if ph is String:
		for part in ph.split(",", false):
			var kv = part.split(":")
			if kv.size() == 2:
				phases.append([float(kv[0]), kv[1].strip_edges()])
	elif ph is Array:
		phases = ph
	L.ev["fight"] = {"key": key, "id": int(e["id"]), "win": str(st.get("win", "")), "lose": str(st.get("lose", "")), "phases": phases, "lock": bool(st.get("lock", true)), "done": [],
		"keep_down": bool(st.get("keep_down", false)), "leash": float(st.get("leash", 0)), "home": [float(e["x"]), float(e["y"])]}
	world.toasts.append([(str(e["name"]) + " APPEARS!") if str(e.get("name", "")) != "" else "A BOSS APPEARS!", Color(1, 0.5, 0.4), 200])
	return true

func _fight_foe(L) -> Dictionary:
	var fi: Dictionary = L.ev["fight"]
	var sim = Game.sims.get(str(fi["key"]))
	if sim == null:
		return {}
	var id = int(fi["id"])
	if id < sim.enemies.size() and int(sim.enemies[id]["id"]) == id:
		return sim.enemies[id]
	for e in sim.enemies:
		if int(e["id"]) == id:
			return e
	return {}

## "go": the event goes on (won, lost, or a phase), "": still fighting
func _step_fight(L) -> String:
	var fi: Dictionary = L.ev["fight"]
	var e = _fight_foe(L)
	var f = L.fighter
	if e.is_empty() or not e["alive"] or e["state"] == "dying":
		L.ev.erase("fight")
		L.ev["until"] = ""
		if str(fi["win"]) != "":
			_goto(L, str(fi["win"]))
		return "go"
	if float(fi.get("leash", 0)) > 0 and Vector2(f.x, f.y).distance_to(Vector2(float(fi["home"][0]), float(fi["home"][1]))) > float(fi["leash"]):
		# walked away (back into the ship...): the fight is off, the boss as it was - full health, back at its post
		e["hp"] = e["maxhp"]; e["x"] = float(fi["home"][0]); e["y"] = float(fi["home"][1]); e["state"] = "idle"; e["hold"] = 0
		world.brawl.drop_rival(str(fi["key"]), int(fi["id"]))
		L.ev = {}
		return ""
	if f.state == "down" and bool(fi.get("keep_down", false)):
		# beaten for real: the player stays down, the boss stands over them (the story's lose part plays it out)
		L.ev.erase("fight")
		L.ev["until"] = ""
		L.ev["down_hold"] = true
		L.ev["held"] = [str(fi["key"]), int(fi["id"])]
		e["hold"] = 3
		if str(fi["lose"]) != "":
			_goto(L, str(fi["lose"]))
		return "go"
	if f.state == "down":
		L.ev.erase("fight")
		L.ev["until"] = ""
		f.revive(f.x, f.y)
		e["state"] = "dying"; e["t"] = 40       # (the boss leaves: the story decides what happens)
		if str(fi["lose"]) != "":
			_goto(L, str(fi["lose"]))
		return "go"
	if str(L.ev.get("until", "")) == "fight":
		var frac = float(e["hp"]) / maxf(1.0, float(e["maxhp"]))
		for ph in fi["phases"]:
			if ph.size() >= 2 and frac <= float(ph[0]) and not fi["done"].has(str(ph[1])):
				fi["done"].append(str(ph[1]))
				L.ev["until"] = ""
				_goto(L, str(ph[1]))
				return "go"
	return ""

func _hold_boss(L) -> void:
	var e = _fight_foe(L)
	if not e.is_empty():
		e["hold"] = 2

## the event is over: the scene lets go of everyone
func _cleanup(L) -> void:
	var f = L.fighter
	f.scene_pose = -1
	f.scene_dir = -1
	L.cut_cam = {}
	var mv: Array = L.get_meta("moves", [])
	for m in mv.duplicate():
		if str(m["who"]).to_upper() == "PLAYER":
			mv.erase(m)      # (only people walk on after a scene - you have the buttons back)
	for p in L.area.get("people", []):
		p.erase("cut_pose")
		if not mv.any(func(m): return _person(L, str(m["who"])) == p):
			p.erase("cut_walk")

static func _attack_in(f, r: Array) -> bool:
	var rr = Rect2(float(r[0]), float(r[1]), float(r[2]) - float(r[0]), float(r[3]) - float(r[1]))
	for sh in f.shots:
		if rr.grow(4).has_point(Vector2(float(sh.get("x", -9999)), float(sh.get("y", -9999)))):
			return true
	if f.state in ["attack", "rush", "skill"]:
		# the game tests a blow's box against the thing's box (0x0800F2B6): here the hero's body (round its feet box -
		# fighter_sim._under) reaching REACH px the way it faces (the game's own blow box not read yet)
		const REACH = 24.0
		var body = Rect2(f.x, f.y - 16.0, 16.0, 24.0)
		var fwd = [Vector2(0, 1), Vector2(0, -1), Vector2(-1, 0), Vector2(1, 0)][clampi(f.dir, 0, 3)]
		var blow = body.merge(Rect2(body.position + fwd * REACH, body.size))
		if blow.intersects(rr):
			return true
	return false

## a story boss fight: the boss's name and a big red health bar across the top of the screen
func draw_boss(c: Control, L, vs: Vector2) -> void:
	if not L.ev.has("fight"):
		return
	var e = _fight_foe(L)
	if e.is_empty() or not e["alive"]:
		return
	var font = ThemeDB.fallback_font
	var w = minf(vs.x * 0.6, 420.0)
	var x = (vs.x - w) / 2.0
	var y = 34.0
	var frac = clampf(float(e["hp"]) / maxf(1.0, float(e["maxhp"])), 0.0, 1.0)
	if e.get("fighter", false):      # (a hero foe fights for it: its health is the fighter's)
		var rv = world.brawl.rival_for(str(L.ev["fight"]["key"]), int(e["id"]))
		if not rv.is_empty():
			frac = clampf(float(rv["f"].hp) / maxf(1.0, float(rv["f"].maxhp)), 0.0, 1.0)
	var nm = str(e.get("name", "")) if str(e.get("name", "")) != "" else "BOSS"
	c.draw_string(font, Vector2(x, y - 4), nm, HORIZONTAL_ALIGNMENT_CENTER, w, 12, Color(1, 0.9, 0.85))
	c.draw_rect(Rect2(x - 2, y - 2, w + 4, 14), Color(0, 0, 0, 0.8))
	c.draw_rect(Rect2(x, y, w, 10), Color(0.25, 0.04, 0.04))
	c.draw_rect(Rect2(x, y, w * frac, 10), Color(0.9, 0.12, 0.1))
	c.draw_rect(Rect2(x, y, w * frac, 3), Color(1, 0.5, 0.45, 0.8))
	c.draw_rect(Rect2(x - 2, y - 2, w + 4, 14), Color(1, 0.85, 0.5, 0.9), false, 1.0)

## the nearest living foe of a kind ("kind") within "take" px of x, y on the player's map ({} if none)
func _take(L, st: Dictionary) -> Dictionary:
	var sim = Game.sims.get(_key(L))
	if sim == null:
		return {}
	var p = Vector2(float(st.get("x", L.fighter.x)), float(st.get("y", L.fighter.y)))
	var best = float(st.get("take", 400))
	var out = {}
	for c in sim.enemies:
		if c["alive"] and c["state"] != "dying" and int(c["type"]) == int(st.get("kind", -1)) and Vector2(float(c["x"]), float(c["y"])).distance_to(p) <= best:
			best = Vector2(float(c["x"]), float(c["y"])).distance_to(p)
			out = c
	if not out.is_empty() and not sim.awake.has(out):
		sim.awake.append(out)
	return out

## a foe by [map key, id] ({} if gone)
func _foe_at(ref) -> Dictionary:
	if not ref is Array or ref.size() < 2:
		return {}
	var sim = Game.sims.get(str(ref[0]))
	if sim == null:
		return {}
	for c in sim.enemies:
		if int(c["id"]) == int(ref[1]) and c["alive"]:
			return c
	return {}

## the scene's effects over the world: the Supernova thrown up, big words
func draw_scene_fx(c: Control, L, i: int, vs: Vector2) -> void:
	if L.ev.has("orb"):
		# the Supernova: the artist's own picture (builtin/sprites/fx_supernova.png - its charge frames growing over the
		# foe's head, then its flying frames thrown up off the screen)
		var o: Dictionary = L.ev["orb"]
		var t = int(o["t"])
		var rise = maxf(0.0, t - 80.0) * 9.0
		var p = world.hud_point(i, Vector2(float(o["x"]), float(o["y"]) - 30.0 - rise))
		var z = world.hud_zoom(i)
		var tex = Assets.texture(Assets.builtin_dir().path_join("sprites/fx_supernova.png"))
		if tex != null:
			var row = 0; var fr = 0; var grow = 1.0
			if t < 80:
				fr = mini(2, t * 3 / 80)
				grow = lerpf(0.25, 1.0, clampf(t / 80.0, 0.0, 1.0))
			else:
				row = 128; fr = (t / 4) % 4
			var d = Vector2(128, 128) * grow * z
			c.draw_texture_rect_region(tex, Rect2(p - d * 0.5, d), Rect2(fr * 128, row, 128, 128))
		if t == 80:
			Sfx.play("bomb")
	if L.ev.has("big"):
		var b: Dictionary = L.ev["big"]
		var a = clampf(int(b["t"]) / 20.0, 0.0, 1.0)
		var font = Assets.gba_font("font_head")
		if font == null:
			font = ThemeDB.fallback_font
		var col2 = Color.from_string(str(b["col"]), Color(1, 0.2, 0.2))
		var txt = str(b["text"])
		var y = vs.y * 0.45
		c.draw_rect(Rect2(0, y - 40, vs.x, 56), Color(0, 0, 0, 0.6 * a))
		for o2 in [Vector2(-2, 0), Vector2(2, 0), Vector2(0, -2), Vector2(0, 2)]:
			c.draw_string(font, Vector2(0, y) + o2, txt, HORIZONTAL_ALIGNMENT_CENTER, vs.x, 32, Color(0, 0, 0, a))
		c.draw_string(font, Vector2(0, y), txt, HORIZONTAL_ALIGNMENT_CENTER, vs.x, 32, Color(col2.r, col2.g, col2.b, a))

## where a foe really is: the hero foe standing in for it (it moves), or the foe itself
func _foe_pos(ref, e: Dictionary) -> Vector2:
	if ref is Array and ref.size() >= 2:
		var rv = world.brawl.rival_for(str(ref[0]), int(ref[1]))
		if not rv.is_empty():
			return Vector2(rv["f"].x, rv["f"].y)
	return Vector2(float(e["x"]), float(e["y"]))
