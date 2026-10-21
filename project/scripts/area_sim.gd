class_name AreaSim
extends RefCounted
## One area's enemies, run by the host only (so every player sees the same enemies: no desync).
## Like a good online game: a beaten enemy comes back at its own post after about a minute (a strong
## one after 2.5, the boss after 6), fading in (it can't hit or be hit for a moment); now and then one
## comes back as a rare strong one. An enemy pulled too far from its post
## gives up, runs home and heals; one left alone heals slowly. Beaten foes sometimes leave an orb.

var key = ""
var area = {}
var enemies = []         # Dictionaries (see make_enemy)
var made = false
var rng = RandomNumberGenerator.new()
var spec = {}            # what lives here: {kinds, count, level, elite, look, boss_kind, boss_name, seed}
var last_active_ms = 0
var boss_id = -1
var boss_beaten = false
var posts = []           # every post of the area (where enemies may come back)
var drops = []           # {id, kind (0 health orb, 1 ki orb, 2 senzu bean), x, y, born}
var drop_seq = 0
var events_out = []      # {"type": "boss_back"} etc. for the host to tell everyone
var eshots = []          # what foes throw (the game's own attacks): {k, x, y, vx, vy, t, life, atk, ...} - see _launch
var shot_seq = 0
const SHOT_KINDS = ["ki", "laser", "fire", "bomb", "ring", "beam", "charge", "boom", "burn", "missile", "kiblast", "laserseg", "laserbeam", "smoke", "sfx", "star", "bomb2"]
const AI_SOUNDS = ["foe_swing", "foe_hit", "foe_missile", "foe_laser", "foe_rumble", "foe_dash"]
var ai: EnemyAI = null      # the game's own enemy AI (its behaviour scripts), for every foe kind that has one
var _ev: Array = []
const RANGED = ["laser", "fireball", "bomber", "shooter"]
const DIRV = [Vector2(0, 1), Vector2(0, -1), Vector2(-1, 0), Vector2(1, 0)]
var add_later = []       # foes called in during a tick (the boss's help)
const RESPAWN_MS = [40000, 70000]
const RESPAWN_STRONG_MS = 150000
const RESPAWN_BOSS_MS = 360000
const LEASH = 280.0
const DROP_LIFE_MS = 30000

func setup(k: String, a: Dictionary, s: Dictionary) -> void:
	key = k
	area = a
	spec = s
	rng.seed = int(s.get("seed", 1)) ^ hash(k)
	ai = EnemyAI.new(self)

func make_enemies(arrival: Vector2) -> void:
	if made:
		return
	made = true
	enemies.clear()
	var kinds: Array = spec.get("kinds", [])
	var objs: Array = spec.get("objects", [])
	if spec.has("fixed"):
		# a land of the game's own maps: every foe exactly where the original puts it
		var fid = 0
		for f in spec["fixed"]:
			var p = Vector2(float(f["x"]), float(f["y"]))
			if not _open(p):
				p = _open_near(p)
			var lv = maxi(int(f.get("lv", 0)), int(spec.get("level", 1))) + rng.randi_range(-1, 1)
			var elite = rng.randi_range(0, 99) < int(spec.get("elite", 4))
			var fe = make_enemy(fid, int(f["type"]), int(f["set"]), p, maxi(1, lv + (3 if elite else 0)), elite, false)
			if f.has("respawn_s"):
				fe["zone_ms"] = int(f["respawn_s"]) * 1000      # a foe zone's own time to come back
			enemies.append(fe)
			posts.append(p)
			fid += 1
		# treasure your team put down (DEV TOOLS): it lies there until someone takes it
		for it in spec.get("items", []):
			drop_seq += 1
			drops.append({"id": drop_seq, "kind": str(it.get("id", "senzu")), "x": float(it["x"]), "y": float(it["y"]), "born": Time.get_ticks_msec() + 1000000000, "n": int(it.get("count", 1))})
		return
	var count: int = spec.get("count", 6)
	if spec.get("boss_kind", -1) < 0:
		# no GBA object limit: a bigger place holds more foes
		count = clampi(int(area["w"] * area["h"] / (175.0 * 175.0)), count, 13)
	posts = _posts(count, arrival)
	var id = 0
	if spec.get("boss_kind", -1) >= 0:
		var ts = Rules.kind_to_type_set(1000 + int(spec["boss_kind"]))
		var c = Vector2(area["w"] / 2.0, area["h"] / 2.0)
		var p = _open_near(c)
		var e = make_enemy(id, ts[0], ts[1], p, int(spec.get("level", 1)) + 4, false, true)
		e["name"] = spec.get("boss_name", "")
		enemies.append(e)
		boss_id = id
		id += 1
	for i in posts.size():
		var t = -1
		var s = -1
		if objs.size() > 0:
			var o = objs[i % objs.size()]
			t = int(o["type"]); s = int(o["set"])
			var ts2 = Rules.kind_to_type_set(t)
			if ts2[1] >= 0:
				s = ts2[1]
		elif kinds.size() > 0:
			var ts = Rules.kind_to_type_set(int(kinds[rng.randi_range(0, kinds.size() - 1)]))
			t = ts[0]; s = ts[1]
		if t < 0 or s < 0:
			continue
		var lv = int(spec.get("level", 1)) + rng.randi_range(-2, 1)
		var elite = rng.randi_range(0, 99) < int(spec.get("elite", 4))
		enemies.append(make_enemy(id, t, s, posts[i], maxi(1, lv + (3 if elite else 0)), elite, false))
		id += 1

func make_enemy(id: int, t: int, s: int, p: Vector2, lv: int, elite: bool, boss: bool) -> Dictionary:
	if Content.enemy_types.get(t, {}).has("set") and int(Content.enemy_types[t]["set"]) >= 0:
		s = int(Content.enemy_types[t]["set"])      # your team's look for this kind (DEV TOOLS)
	var tab: Dictionary = Assets.data["enemies"][clampi(t, 0, 127)]
	var lb = maxi(1, int(tab["lvl"]))
	var hp = float(tab["hp"]) * Rules.hpf(lv) / Rules.hpf(lb)
	if elite:
		hp *= 3.0
	if boss:
		hp *= 7.0
	hp *= float(Game.difficulty_hp())
	var atk = float(tab["atk"]) * Rules.atf(lv) / Rules.atf(lb) * Game.difficulty_atk()
	var exp = maxf(1.0, float(tab["exp"]) * (5.0 if elite else 1.0) * (3.0 if boss else 1.0) * Rules.atf(lv) / Rules.atf(lb))
	var ai = Content.enemy_style(t, rng) if not boss else Content.enemy_cfg.get("styles", {}).get("boss", {}).duplicate()
	if boss:
		ai["style"] = "boss"
		ai["own"] = Content.own_attack(t)
	return {"ai": ai, "bt": 0, "helped": false, "lock": Vector2.ZERO, "hitp": {}, "id": id, "type": t, "set": s, "x": p.x, "y": p.y, "hx": p.x, "hy": p.y, "hp": maxi(1, roundi(hp)), "maxhp": maxi(1, roundi(hp)),
		"atk": atk, "lvl": lv, "exp": roundi(exp), "elite": elite, "boss": boss, "big": boss or t in Rules.BIG_TYPES,
		"alive": true, "dead_ms": 0, "state": "idle", "anim": 0, "dir": 0, "frame": 0, "t": 0, "cool": rng.randi_range(30, 90),
		"stun": 0, "kx": 0.0, "ky": 0.0, "flash": 0, "wander": Vector2.ZERO, "wt": 0, "name": "",
		"base_hp": maxi(1, roundi(hp / (3.0 if elite else 1.0))), "base_atk": atk, "born_elite": elite, "calm": 0, "respawn_ms": RESPAWN_MS[0], "ox": p.x, "oy": p.y}

func _posts(n: int, arrival: Vector2) -> Array:
	# the same places every visit: from the seed only (never from where you came in)
	var out = []
	var r = RandomNumberGenerator.new()
	r.seed = int(spec.get("seed", 1)) * 977 + hash(key)
	var tries = 0
	while out.size() < n and tries < 4000:
		tries += 1
		var p = Vector2(r.randi_range(24, maxi(25, area["w"] - 24)), r.randi_range(32, maxi(33, area["h"] - 24)))
		if not _open(p):
			continue
		var near = false
		for q in out:
			if q.distance_to(p) < 40:
				near = true
		if near:
			continue
		out.append(p)
	# a post right where you come in: this visit, that one waits a little way off
	for i in out.size():
		if out[i].distance_to(arrival) < 120:
			for k in 200:
				var p2 = Vector2(r.randi_range(24, maxi(25, area["w"] - 24)), r.randi_range(32, maxi(33, area["h"] - 24)))
				if _open(p2) and p2.distance_to(arrival) >= 120:
					out[i] = p2
					break
	return out

func _open(p: Vector2) -> bool:
	for dy in [-8, 0, 8]:
		for dx in [-8, 0, 8]:
			if not Assets.walkable(area, p.x + dx, p.y + dy):
				return false
	return true

func _open_near(p: Vector2) -> Vector2:
	for r in range(0, 400, 8):
		for k in 16:
			var q = p + Vector2(cos(k * PI / 8.0), sin(k * PI / 8.0)) * r
			if _open(q):
				return q
	return p

func can_stand(px: float, py: float) -> bool:
	return Assets.walkable(area, px - 4, py) and Assets.walkable(area, px + 4, py)

## fighters: [{peer, x, y, down, inv}]; returns events: {"type":"hurt","peer":..,"dmg":..,"kx":..,"ky":..}
func step(fighters: Array) -> Array:
	var ev = []
	var now = Time.get_ticks_msec()
	last_active_ms = now
	_awake_t -= 1
	if _awake_t <= 0 or awake.is_empty():
		_refresh_awake(fighters)
	for e in awake:
		if not e["alive"]:
			if now - int(e["dead_ms"]) > int(e.get("respawn_ms", RESPAWN_MS[0])) * float(Game.cfg.get("respawn_scale", 1.0)):
				var p = _free_post(e, fighters)
				if p != null:
					_respawn(e, p)
			continue
		if e["state"] == "dying":
			e["t"] += 1
			e["frame"] = mini(3, e["t"] / 8)
			if e["t"] > 40:
				e["alive"] = false
				e["dead_ms"] = now
				if e.get("minion", false):
					e["respawn_ms"] = 1 << 40
				elif e.has("zone_ms"):
					e["respawn_ms"] = int(e["zone_ms"])
				elif e["boss"]:
					e["respawn_ms"] = RESPAWN_BOSS_MS
				elif e["elite"]:
					e["respawn_ms"] = RESPAWN_STRONG_MS
				else:
					e["respawn_ms"] = rng.randi_range(RESPAWN_MS[0], RESPAWN_MS[1])
			continue
		if e["state"] == "spawning":
			# coming back: fades in, can't hit or be hit for a moment
			e["t"] += 1
			e["anim"] = 0
			e["frame"] = 0
			if e["t"] >= 45:
				e["state"] = "idle"; e["t"] = 0
			continue
		_shooter_type = int(e["type"])
		if int(e.get("hold", 0)) > 0:          # held still by a story scene (a boss while you talk)
			e["hold"] = int(e["hold"]) - 1
			continue
		if e.has("sts") and not e["sts"].is_empty() and _foe_states(e):
			continue
		if e["state"] == "return" and not uses_ai(e):
			# pulled too far: back home, healed (no kiting an enemy across the map)
			var home = Vector2(e["hx"], e["hy"])
			var dv2 = home - Vector2(e["x"], e["y"])
			if dv2.length() < 6.0:
				e["state"] = "idle"; e["hp"] = e["maxhp"]; e["anim"] = 0
			else:
				var n2 = dv2.normalized() * 1.4
				var before = Vector2(e["x"], e["y"])
				_move(e, n2.x, n2.y)
				e["stuck"] = int(e.get("stuck", 0)) + 1 if before.distance_to(Vector2(e["x"], e["y"])) < 0.3 else 0
				if e["stuck"] > 60:      # a wall in the way: it finds its way home out of sight
					e["x"] = e["hx"]; e["y"] = e["hy"]; e["stuck"] = 0
				e["dir"] = _dir_of(n2); e["anim"] = 1
				e["t"] += 1
				e["frame"] = (e["t"] / 6) % 4
			continue
		# far from every fighter: it rests (a big land costs nothing where nobody is)
		var near_any = false
		for f in fighters:
			if absf(f["x"] - e["x"]) < 700.0 and absf(f["y"] - e["y"]) < 520.0:
				near_any = true
				break
		if not near_any and e["state"] != "return":
			continue
		if e["flash"] > 0:
			e["flash"] -= 1
		if uses_ai(e):
			ai.fighters = fighters
			_ev = ev
			ai.tick(e)
			continue
		if e["stun"] > 0:
			e["stun"] -= 1
			_move(e, e["kx"], e["ky"])
			e["kx"] *= 0.8; e["ky"] *= 0.8
			continue
		var tgt = null
		var best = 1e9
		for f in fighters:
			if f["down"]:
				continue
			var d = Vector2(f["x"] - e["x"], f["y"] - e["y"]).length()
			if d < best:
				best = d; tgt = f
		var aggro = 150.0 if not e["boss"] else 400.0
		if tgt != null and best < aggro:
			e["calm"] = 0
		else:
			e["calm"] = int(e.get("calm", 0)) + 1
			if e["calm"] > 300 and e["calm"] % 10 == 0 and e["hp"] < e["maxhp"]:
				e["hp"] = mini(e["maxhp"], e["hp"] + maxi(1, e["maxhp"] / 100))
		if not e["boss"] and Vector2(e["x"] - e["hx"], e["y"] - e["hy"]).length() > LEASH and e["state"] != "attack":
			e["state"] = "return"
			continue
		if e["cool"] > 0:
			e["cool"] -= 1
		var ai: Dictionary = e["ai"]
		var style = str(ai.get("style", "melee"))
		match str(e["state"]):
			"windup":
				# crouching / arms up: the warning before a leap or a slam
				e["t"] += 1
				e["anim"] = 2
				e["frame"] = 0
				if tgt != null and e["next"] == "lunge":
					e["lock"] = Vector2(tgt["x"] - e["x"], tgt["y"] - e["y"]).normalized()
					e["dir"] = _dir_of(e["lock"])
				if e["t"] >= int(e["wind"]):
					e["state"] = e["next"]; e["t"] = 0; e["hitp"] = {}
				continue
			"lunge":
				e["t"] += 1
				var sp = float(ai.get("speed", 2.6)) * (1.2 if e["boss"] else 1.0)
				_move(e, e["lock"].x * sp, e["lock"].y * sp)
				e["anim"] = 2; e["frame"] = mini(3, 1 + e["t"] / 6)
				for f in fighters:
					if f["down"] or f["inv"] or e["hitp"].has(f["peer"]):
						continue
					if Vector2(f["x"] - e["x"], f["y"] - e["y"]).length() < (20.0 if not e["big"] else 34.0):
						e["hitp"][f["peer"]] = true
						ev.append({"type": "hurt", "peer": f["peer"], "atk": e["atk"] * 1.2, "kx": e["lock"].x * 2.5, "ky": e["lock"].y * 2.5, "et": int(e["type"])})
				if e["t"] >= int(ai.get("time", 18)):
					e["state"] = "idle"; e["t"] = 0
					e["cool"] = _cool(ai)
				continue
			"slam":
				var rad = float(e["slam_r"])
				for f in fighters:
					if not f["down"] and not f["inv"] and Vector2(f["x"] - e["x"], f["y"] - e["y"]).length() < rad:
						var kv = Vector2(f["x"] - e["x"], f["y"] - e["y"]).normalized() * 3.0
						ev.append({"type": "hurt", "peer": f["peer"], "atk": e["atk"] * 1.5, "kx": kv.x, "ky": kv.y, "et": int(e["type"])})
				events_out.append({"type": "slam", "x": e["x"], "y": e["y"], "r": rad})
				e["state"] = "idle"; e["t"] = 0; e["anim"] = 0
				e["cool"] = _cool(ai)
				continue
			"fire":
				# the attack itself: the foe's own attack pose, and what it throws leaves on the second frame
				e["t"] += 1
				e["anim"] = 2
				e["frame"] = mini(3, 1 + e["t"] / 4)
				if e["t"] == 2:
					_launch(e, tgt, ai, str(e.get("fire_kind", "fire")))
				if e["t"] >= int(e.get("fire_len", 14)):
					e["state"] = "idle"; e["t"] = 0
					e["cool"] = _cool(ai) if not e["boss"] else rng.randi_range(40, 70)
				continue
			"beam_charge":
				# a boss gathers energy (the orb grows at its hands), then the beam
				e["t"] += 1
				e["anim"] = 2; e["frame"] = 0
				if e["t"] >= int(ai.get("beam_charge", 50)):
					e["state"] = "fire"; e["t"] = 0; e["fire_kind"] = "beam_go"; e["fire_len"] = int(ai.get("beam_time", 60)) + 10
				continue
		# the boss: now and then a big move, and help when hurt
		if style == "boss" and tgt != null and best < aggro:
			e["bt"] += 1
			if not e["helped"] and float(e["hp"]) < float(e["maxhp"]) * float(ai.get("help_at", 0.5)):
				e["helped"] = true
				_call_help(e, int(ai.get("help", 3)))
			var every = int(ai.get("every", 220)) / (2 if e["helped"] else 1)
			if e["bt"] >= every and e["state"] != "attack":
				e["bt"] = 0
				var own = str(ai.get("own", ""))      # the attack this kind of foe has in the game
				var moves = ["beam", "volley", "rings", "lunge"]
				if own != "":
					moves.append(own)
				moves.erase(str(e.get("last_mv", "")))       # never the same big move twice in a row
				var mv: String = moves[randi() % moves.size()]
				e["last_mv"] = mv
				if OS.get_environment("LOG2_BOSSDBG") != "": print("[boss] ", mv, " own ", own)
				e["dir"] = _dir_of(Vector2(tgt["x"] - e["x"], tgt["y"] - e["y"]))
				match mv:
					"beam":
						e["beam_dir"] = e["dir"]
						e["state"] = "beam_charge"; e["t"] = 0
						_add_shot({"k": "charge", "x": e["x"] + DIRV[e["dir"]].x * 12, "y": e["y"] - 14 + DIRV[e["dir"]].y * 8, "life": int(ai.get("beam_charge", 50)), "a": 0.0})
					"volley":
						_windup(e, "fire", 24); e["fire_kind"] = "volley"; e["fire_len"] = 14
					"rings":
						_windup(e, "fire", 30); e["fire_kind"] = "rings"; e["fire_len"] = 16
					"lunge":
						_windup(e, "lunge", 26)
					_:
						_windup(e, "fire", 18); e["fire_kind"] = mv; e["fire_len"] = 14
				continue
		if e["state"] == "attack":
			e["t"] += 1
			e["frame"] = mini(3, e["t"] / 4)
			if e["t"] == 6 and tgt != null:
				var reach = 26.0 if not e["big"] else 44.0
				var dv = Vector2(tgt["x"] - e["x"], tgt["y"] - e["y"])
				if dv.length() < reach and not tgt["inv"]:
					var n = dv.normalized()
					ev.append({"type": "hurt", "peer": tgt["peer"], "atk": e["atk"], "kx": n.x * 1.5, "ky": n.y * 1.5, "et": int(e["type"])})
			if e["t"] >= 16:
				e["state"] = "idle"
				e["cool"] = rng.randi_range(45, 75) if not e["boss"] else rng.randi_range(30, 50)
			continue
		var ranged = style in RANGED
		if tgt != null and best < aggro and (style in ["lunger", "slammer", "stomper"] or ranged) and e["cool"] <= 0 and best < float(ai.get("range", 100)):
			var dv0 = Vector2(tgt["x"] - e["x"], tgt["y"] - e["y"])
			# the laser only goes straight (as in the game): first get in line with the target
			if style == "laser" and absf(dv0.x) > 10.0 and absf(dv0.y) > 10.0:
				var stp = Vector2(signf(dv0.x), 0) if absf(dv0.x) < absf(dv0.y) else Vector2(0, signf(dv0.y))
				_move(e, stp.x * 1.1, stp.y * 1.1)
				e["dir"] = _dir_of(dv0)
				e["anim"] = 1; e["t"] += 1; e["frame"] = (e["t"] / 6) % 4
				continue
			e["dir"] = _dir_of(dv0)
			match style:
				"lunger":
					_windup(e, "lunge", int(ai.get("windup", 22)))
				"slammer":
					e["slam_r"] = float(ai.get("radius", 46))
					_windup(e, "slam", int(ai.get("windup", 36)))
				"stomper":
					_windup(e, "fire", int(ai.get("windup", 30))); e["fire_kind"] = "rings"; e["fire_len"] = 16
				"laser":
					_windup(e, "fire", int(ai.get("windup", 20))); e["fire_kind"] = "laser"; e["fire_len"] = 14
				"bomber":
					_windup(e, "fire", int(ai.get("windup", 16))); e["fire_kind"] = "bomb"; e["fire_len"] = 14
				_:
					_windup(e, "fire", int(ai.get("windup", 16))); e["fire_kind"] = "fire"; e["fire_len"] = 14
			continue
		if tgt != null and best < aggro and ranged and best < float(ai.get("keep", 80)) - 25:
			# a foe that throws keeps its distance
			var away = Vector2(e["x"] - tgt["x"], e["y"] - tgt["y"]).normalized() * 0.6
			_move(e, away.x, away.y)
			e["dir"] = _dir_of(-away)
			e["anim"] = 1; e["t"] += 1; e["frame"] = (e["t"] / 8) % 4
			continue
		if tgt != null and best < aggro and ranged and best < float(ai.get("keep", 80)) + 25:
			e["dir"] = _dir_of(Vector2(tgt["x"] - e["x"], tgt["y"] - e["y"]))
			e["anim"] = 0; e["frame"] = 0
			continue
		if tgt != null and best < aggro:
			var dv = Vector2(tgt["x"] - e["x"], tgt["y"] - e["y"])
			e["dir"] = _dir_of(dv)
			var reach = 22.0 if not e["big"] else 38.0
			if best < reach and e["cool"] <= 0:
				e["state"] = "attack"; e["t"] = 0; e["anim"] = 2; e["frame"] = 0
				continue
			if best > reach - 6:
				var sp = 0.75 if not e["boss"] else 0.85
				var n = dv.normalized() * sp
				_move(e, n.x, n.y)
				e["state"] = "walk"; e["anim"] = 1
				e["t"] += 1
				e["frame"] = (e["t"] / 8) % 4
			else:
				e["state"] = "idle"; e["anim"] = 0; e["frame"] = 0
		else:
			# wander near the post
			e["wt"] -= 1
			if e["wt"] <= 0:
				e["wt"] = rng.randi_range(60, 180)
				var home = Vector2(e["hx"], e["hy"])
				var here = Vector2(e["x"], e["y"])
				if here.distance_to(home) > 48:
					e["wander"] = (home - here).normalized() * 0.5
				elif rng.randf() < 0.5:
					e["wander"] = Vector2.ZERO
				else:
					e["wander"] = Vector2.from_angle(rng.randf() * TAU) * 0.5
			var w: Vector2 = e["wander"]
			if w != Vector2.ZERO:
				_move(e, w.x, w.y)
				e["dir"] = _dir_of(w)
				e["anim"] = 1
				e["t"] += 1
				e["frame"] = (e["t"] / 10) % 4
			else:
				e["anim"] = 0
				e["t"] += 1
				e["frame"] = (e["t"] / 30) % 2
	drops = drops.filter(func(d): return now - int(d["born"]) < DROP_LIFE_MS)
	_step_shots(fighters, ev)
	for ne in add_later:
		enemies.append(ne)
	add_later.clear()
	return ev

func _cool(ai: Dictionary) -> int:
	var c = ai.get("cooldown", [60, 100])
	if c is Array and c.size() >= 2:
		return rng.randi_range(int(c[0]), int(c[1]))
	return int(c)

func _windup(e: Dictionary, nxt: String, ticks: int) -> void:
	e["state"] = "windup"; e["t"] = 0; e["next"] = nxt; e["wind"] = ticks
	e["anim"] = 2; e["frame"] = 0

## what a foe throws, as in the game (sprites read from your game: imported/fx/e_*.png):
##   laser  - the flying robots' zig-zag laser, straight along a direction
##   fire   - a fireball (one way per direction) that bursts into flame
##   bomb   - a lit bomb thrown in an arc; it lands, the fuse burns, then it goes off
##   ring   - the big ones' stomp: a white shock ring running outward along the ground
##   beam   - a boss's beam, after it gathers an orb (charge)
##   boom / burn - a burst of fire / a patch of burning ground left behind
var _shooter_type = -1
func _add_shot(d: Dictionary) -> Dictionary:
	if not d.has("et"):
		d["et"] = _shooter_type
	shot_seq += 1
	d["id"] = shot_seq
	if not d.has("t"):
		d["t"] = 0
	if not d.has("hitp"):
		d["hitp"] = {}
	eshots.append(d)
	return d

func _launch(e: Dictionary, tgt, ai: Dictionary, kind: String) -> void:
	var atk = float(e["atk"])
	var d: int = e["dir"]
	var v: Vector2 = DIRV[d]
	var hx = e["x"] + v.x * (12 if not e["big"] else 20)
	var hy = e["y"] - (12 if not e["big"] else 20) + v.y * 6
	var elite = e["elite"] or e["boss"]
	match kind:
		"laser":
			var n = 2 if elite else 1
			for i in n:
				_add_shot({"k": "laser", "x": hx, "y": hy, "ox": hx, "oy": hy, "dir": d, "vx": v.x, "vy": v.y, "a": 0.0,
					"len": float(ai.get("len", 72)), "speed": float(ai.get("speed", 5.0)), "life": int(ai.get("life", 60)) + i * 10, "t": -i * 10,
					"atk": atk * float(ai.get("power", 0.9))})
		"fire":
			var spread = [0.0] if not elite else [-0.35, 0.0, 0.35]
			var aim = v
			if tgt != null and ai.get("aim", false):
				aim = Vector2(tgt["x"] - hx, tgt["y"] - hy).normalized()
			for sp in spread:
				var w = aim.rotated(sp) * float(ai.get("speed", 2.4))
				_add_shot({"k": "fire", "x": hx, "y": hy, "dir": d, "vx": w.x, "vy": w.y, "life": int(ai.get("life", 90)),
					"atk": atk * float(ai.get("power", 1.0)), "burn": e["big"] or e["boss"]})
		"bomb":
			var tx = e["x"] + v.x * 60.0
			var ty = e["y"] + v.y * 60.0
			if tgt != null:
				tx = tgt["x"]; ty = tgt["y"]
			var n = 3 if elite else 1
			for i in n:
				var off = Vector2.ZERO if i == 0 else Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(18, 34)
				var fl = int(ai.get("flight", 40)) + i * 6
				_add_shot({"k": "bomb", "x": hx, "y": e["y"], "sx": hx, "sy": e["y"], "tx": tx + off.x, "ty": ty + off.y, "flight": fl,
					"fuse": int(ai.get("fuse", 45)), "a": 0.0, "b": -1.0, "atk": atk * float(ai.get("power", 1.4)), "r": float(ai.get("radius", 30))})
		"rings":
			var n = 2 if elite else 1
			for i in n:
				_add_shot({"k": "ring", "x": e["x"], "y": e["y"], "a": 4.0, "t": -i * 22, "max": float(ai.get("radius", 72)) * (1.3 if e["boss"] else 1.0),
					"speed": float(ai.get("ring_speed", 1.8)), "atk": atk * float(ai.get("power", 1.3))})
		"volley":
			var n = int(ai.get("volley", 10))
			for k in n:
				var w = Vector2.from_angle(k * TAU / n + rng.randf() * 0.2) * 2.0
				_add_shot({"k": "fire", "x": e["x"], "y": e["y"] - 16, "dir": _dir_of(w), "vx": w.x, "vy": w.y, "life": 120, "atk": atk * 0.9, "burn": false})
		"beam_go":
			var bd = int(e.get("beam_dir", d))
			var bv: Vector2 = DIRV[bd]
			_add_shot({"k": "beam", "x": e["x"] + bv.x * 14, "y": e["y"] - 14 + bv.y * 8, "dir": bd, "vx": bv.x, "vy": bv.y, "a": 0.0,
				"len": float(ai.get("beam_len", 240)), "life": int(ai.get("beam_time", 60)), "w": float(ai.get("beam_width", 12)), "atk": atk * 0.6})

func _boom(x: float, y: float, r: float, atk: float, burn: bool) -> void:
	_add_shot({"k": "boom", "x": x, "y": y, "a": r, "life": 24, "atk": atk})
	if burn:
		_add_shot({"k": "burn", "x": x, "y": y, "a": 14.0, "life": 150, "atk": atk * 0.25})

func _hurt_once(sh: Dictionary, f: Dictionary, ev: Array, atk: float, kv: Vector2) -> void:
	if sh["hitp"].has(f["peer"]):
		return
	sh["hitp"][f["peer"]] = true
	ev.append({"type": "hurt", "peer": f["peer"], "atk": atk, "kx": kv.x, "ky": kv.y, "et": int(sh.get("et", -1))})

static func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab = b - a
	var t = clampf((p - a).dot(ab) / maxf(0.001, ab.length_squared()), 0.0, 1.0)
	return p.distance_to(a + ab * t)

func _step_shots(fighters: Array, ev: Array) -> void:
	var keep = []
	var later = []
	for sh in eshots:
		sh["t"] += 1
		var t: int = sh["t"]
		if t <= 0:
			keep.append(sh)
			continue
		var gone = false
		match str(sh["k"]):
			"laser":
				sh["x"] += sh["vx"] * sh["speed"]; sh["y"] += sh["vy"] * sh["speed"]
				sh["a"] = minf(float(sh["len"]), float(sh["a"]) + float(sh["speed"]))
				var head = Vector2(sh["x"], sh["y"])
				var tail = head - Vector2(sh["vx"], sh["vy"]) * float(sh["a"])
				for f in fighters:
					if not f["down"] and not f["inv"] and _seg_dist(Vector2(f["x"], f["y"] - 10), tail, head) < 7.0:
						_hurt_once(sh, f, ev, sh["atk"], Vector2(sh["vx"], sh["vy"]) * 2.0)
				gone = t > int(sh["life"])
			"fire":
				sh["x"] += sh["vx"]; sh["y"] += sh["vy"]
				var hit = t > int(sh["life"]) or not Assets.walkable(area, sh["x"], sh["y"] + 8)
				for f in fighters:
					if not hit and not f["down"] and not f["inv"] and absf(f["x"] - sh["x"]) < 9.0 and absf((f["y"] - 10.0) - sh["y"]) < 11.0:
						_hurt_once(sh, f, ev, sh["atk"], Vector2(sh["vx"], sh["vy"]).normalized() * 2.0)
						hit = true
				if hit:
					gone = true
					later.append([sh["x"], sh["y"], 14.0, float(sh["atk"]) * 0.5, bool(sh.get("burn", false))])
			"bomb":
				var fl: int = sh["flight"]
				if t <= fl:
					var u = float(t) / fl
					sh["x"] = lerpf(sh["sx"], sh["tx"], u); sh["y"] = lerpf(sh["sy"], sh["ty"], u)
					sh["a"] = sin(u * PI) * (14.0 + 0.05 * Vector2(sh["tx"] - sh["sx"], sh["ty"] - sh["sy"]).length())
				else:
					sh["a"] = 0.0
					sh["b"] = 100.0 * float(t - fl) / float(sh["fuse"])
				if t >= fl + int(sh["fuse"]):
					gone = true
					later.append([sh["x"], sh["y"], float(sh["r"]), float(sh["atk"]), false])
			"ring":
				sh["a"] = float(sh["a"]) + float(sh["speed"])
				for f in fighters:
					if f["down"] or f["inv"]:
						continue
					var dd = Vector2(f["x"] - sh["x"], f["y"] - sh["y"])
					if absf(dd.length() - float(sh["a"])) < 7.0:
						_hurt_once(sh, f, ev, sh["atk"], dd.normalized() * 3.0)
				gone = float(sh["a"]) >= float(sh["max"])
			"beam":
				sh["a"] = minf(float(sh["len"]), float(sh["a"]) + 14.0)
				var o = Vector2(sh["x"], sh["y"])
				var end = o + Vector2(sh["vx"], sh["vy"]) * float(sh["a"])
				if t % 8 == 1:
					sh["hitp"] = {}
				for f in fighters:
					if not f["down"] and not f["inv"] and _seg_dist(Vector2(f["x"], f["y"] - 10), o, end) < float(sh["w"]) * 0.5 + 4.0:
						_hurt_once(sh, f, ev, sh["atk"], Vector2(sh["vx"], sh["vy"]) * 2.5)
				gone = t > int(sh["life"])
			"charge":
				sh["a"] = 100.0 * t / maxf(1.0, float(sh["life"]))
				gone = t > int(sh["life"])
			"boom":
				if t == 1:
					for f in fighters:
						if not f["down"] and not f["inv"] and Vector2(f["x"] - sh["x"], f["y"] - 6 - sh["y"]).length() < float(sh["a"]):
							_hurt_once(sh, f, ev, sh["atk"], Vector2(f["x"] - sh["x"], f["y"] - sh["y"]).normalized() * 3.0)
				gone = t > int(sh["life"])
			"burn":
				if t % 30 == 0:
					sh["hitp"] = {}
				for f in fighters:
					if not f["down"] and not f["inv"] and Vector2(f["x"] - sh["x"], f["y"] - sh["y"]).length() < float(sh["a"]):
						_hurt_once(sh, f, ev, sh["atk"], Vector2.ZERO)
				gone = t > int(sh["life"])
			"missile", "kiblast", "laserseg", "laserbeam", "smoke", "sfx", "star", "bomb2":
				gone = _step_ai_shot(sh, fighters, ev)
			_:
				gone = true
		if not gone:
			keep.append(sh)
	eshots = keep
	for b in later:
		_boom(b[0], b[1], b[2], b[3], b[4])

## the boss calls for help: a few of the area's foes appear around it (they don't come back)
func _call_help(boss: Dictionary, n: int) -> void:
	var kinds: Array = spec.get("kinds", [])
	var objs: Array = spec.get("objects", [])
	for i in n:
		var t = -1
		var st = -1
		if kinds.size() > 0:
			var ts = Rules.kind_to_type_set(int(kinds[rng.randi_range(0, kinds.size() - 1)]))
			t = ts[0]; st = ts[1]
		elif objs.size() > 0:
			var o = objs[rng.randi_range(0, objs.size() - 1)]
			var ts2 = Rules.kind_to_type_set(int(o["type"]))
			t = ts2[0]; st = ts2[1] if ts2[1] >= 0 else int(o["set"])
		if t < 0 or st < 0:
			continue
		var p = _open_near(Vector2(boss["x"], boss["y"]) + Vector2.from_angle(i * TAU / n) * 40.0)
		var ne = make_enemy(1000 + enemies.size() + add_later.size(), t, st, p, maxi(1, int(boss["lvl"]) - 4), false, false)
		ne["minion"] = true
		ne["state"] = "spawning"
		add_later.append(ne)
	events_out.append({"type": "help", "name": boss["name"]})

func _move(e: Dictionary, dx: float, dy: float) -> void:
	if can_stand(e["x"] + dx, e["y"]):
		e["x"] += dx
	if can_stand(e["x"], e["y"] + dy):
		e["y"] += dy

func _dir_of(v: Vector2) -> int:
	if absf(v.x) > absf(v.y):
		return 3 if v.x > 0 else 2
	return 0 if v.y > 0 else 1

## a fighter's blow lands; returns {"killed":bool,"exp":n}
func hit(id: int, dmg: int, kx: float, ky: float, stun: int = 12, kind: int = 1, inflict: Dictionary = {}) -> Dictionary:
	var pool = enemies
	if id >= 0 and id < enemies.size() and int(enemies[id]["id"]) == id:
		pool = [enemies[id]]      # (ids are their places in the list: no search through thousands)
	for e in pool:
		if e["id"] != id or not e["alive"] or e["state"] == "dying" or e["state"] == "spawning":
			continue
		e["calm"] = 0
		e["hp"] = maxi(0, e["hp"] - dmg)
		if not inflict.is_empty() and e["hp"] > 0 and rng.randf() < float(inflict.get("chance", 1.0)):
			var st = Content.state(str(inflict.get("state", "")))
			if not st.is_empty():
				if not e.has("sts"):
					e["sts"] = {}
				var secs = float(inflict.get("seconds", st.get("seconds", 8)))
				e["sts"][str(st["id"])] = maxi(60, roundi(secs * 60))
				events_out.append({"type": "foe_state", "x": e["x"], "y": e["y"], "text": str(st.get("name", "")), "color": str(st.get("color", "ffffff"))})
		if dmg > 0:
			e["flash"] = 8
		if e["state"] == "return":
			e["state"] = "idle"
		if uses_ai(e):
			if e["hp"] > 0:
				# the game's own reaction: the foe's behaviour decides (flinch, get dizzy, turn on you...)
				var hd = EnemyAI.dir_to(Vector2(kx, ky)) if Vector2(kx, ky).length() > 0.01 else int(e["dir"]) ^ 1
				ai.on_hit(e, {"dir": hd, "kind": kind, "kinds": [1 if kind != 1 else 0, kind], "died": false})
		elif not e["boss"]:
			e["stun"] = maxi(int(e["stun"]), maxi(stun, 12) if dmg > 0 else stun)
			e["kx"] = kx * 0.5; e["ky"] = ky * 0.5
			e["state"] = "idle"
		elif stun > 30:
			e["stun"] = 30          # a boss shakes it off quickly
			e["kx"] = 0.0; e["ky"] = 0.0
		if e["hp"] <= 0:
			e["state"] = "dying"; e["t"] = 0; e["anim"] = 0
			if e["boss"]:
				boss_beaten = true
			var wb = e.get("wboss", false)
			var luck = 12.0 if wb else (6.0 if e["boss"] else (3.0 if e["elite"] else 1.0))
			_maybe_drop(Vector2(e["x"], e["y"]), luck, int(e["lvl"]), int(e["type"]))
			if wb:
				for i in 6:
					_maybe_drop(Vector2(e["x"], e["y"]) + Vector2.from_angle(i * TAU / 6) * 20.0, 4.0, int(e["lvl"]))
				events_out.append({"type": "wboss_down", "name": e["name"]})
			return {"killed": true, "lvl": e["lvl"], "mult": 25.0 if wb else (20.0 if e["boss"] else (5.0 if e["elite"] else 1.0)),
				"info": {"type": int(e["type"]), "elite": bool(e["elite"]), "boss": bool(e["boss"]), "wboss": wb, "group": Rules.group_of(int(e["type"]))}}
		return {"killed": false}
	return {"killed": false}

var player_lv = 1           # the players' level here (the host sets it): foes coming back keep up with it
func _respawn(e: Dictionary, p: Vector2) -> void:
	e["alive"] = true      # (back as it was: its own strength, as in the original game)
	e["x"] = p.x; e["y"] = p.y
	e["hx"] = p.x; e["hy"] = p.y
	e["state"] = "spawning"; e["t"] = 0
	e["stun"] = 0; e["flash"] = 0; e["calm"] = 0
	e["cool"] = rng.randi_range(40, 90)
	if e["boss"]:
		events_out.append({"type": "boss_back", "name": e["name"]})
	else:
		# now and then a rare strong one (gold, tougher, five times the EXP)
		var strong = rng.randi_range(0, 99) < 8
		if strong and not e["elite"]:
			e["elite"] = true
			e["maxhp"] = e["base_hp"] * 3; e["atk"] = e["base_atk"] * 1.3
		elif not strong and e["elite"] and not e["born_elite"]:
			e["elite"] = false
			e["maxhp"] = e["base_hp"]; e["atk"] = e["base_atk"]
	e["hp"] = e["maxhp"]

## where a beaten enemy may come back: its own post, or another free one - never close to a player
func _free_post(e: Dictionary, fighters: Array) -> Variant:
	# its own post, like an online game - it fades in and cannot hit for a moment, so that is fair;
	# only if a player stands right on the spot it waits until they step away
	var own = Vector2(e.get("ox", e["hx"]), e.get("oy", e["hy"]))
	if _clear_of(own, fighters, 48.0 if not e["boss"] else 90.0):
		return own
	return null

func _clear_of(c: Vector2, fighters: Array, r: float) -> bool:
	for f in fighters:
		if Vector2(f["x"], f["y"]).distance_to(c) < r:
			return false
	return true

## what a beaten foe leaves: orbs (taken at once), zeni, items from content/items.json ("drop" chance)
func _maybe_drop(p: Vector2, luck: float, lvl: int = 1, t: int = -1) -> void:
	# this kind's own loot (DEV TOOLS - LOOT)
	var own = {}
	for lt in Content.loot:
		if str(lt.get("id", "")) == str(t):
			own = lt
	if not own.is_empty():
		for dr in own.get("drops", []):
			if rng.randf() < float(dr.get("chance", 0.1)) * minf(luck, 3.0):
				_drop(p + Vector2(rng.randf_range(-10, 10), rng.randf_range(-6, 6)), str(dr.get("item", "senzu")), int(dr.get("count", 1)))
		if int(own.get("zeni", 0)) > 0:
			_drop(p + Vector2(rng.randf_range(-8, 8), rng.randf_range(-4, 6)), "zeni", int(own["zeni"]))
		if bool(own.get("replace", false)):
			return
	var r = rng.randf()
	if r < 0.13 * luck:
		_drop(p, "orb_hp", 1)
	elif r < 0.22 * luck:
		_drop(p, "orb_ep", 1)
	var z: Dictionary = Content.zeni
	if rng.randf() < float(z.get("drop", 0.5)) * minf(luck, 1.5):
		var n = rng.randi_range(int(z.get("min", 4)), int(z.get("max", 18))) + int(z.get("per_level", 2)) * lvl
		_drop(p + Vector2(rng.randf_range(-8, 8), rng.randf_range(-4, 6)), "zeni", roundi(n * luck))
	for it in Content.items:
		if rng.randf() < float(it.get("drop", 0.0)) * luck:
			_drop(p + Vector2(rng.randf_range(-10, 10), rng.randf_range(-6, 6)), str(it["id"]), 1)
			break
	# gear: better pieces from stronger foes (rarer ones only from foes of a level that fits)
	for g in Content.gear:
		if lvl + 4 < int(g.get("level", 1)):
			continue
		if rng.randf() < float(g.get("drop", 0.0)) * luck:
			_drop(p + Vector2(rng.randf_range(-10, 10), rng.randf_range(-6, 6)), str(g["id"]), 1)
			break

func _drop(p: Vector2, kind: String, n: int) -> void:
	drop_seq += 1
	drops.append({"id": drop_seq, "kind": kind, "x": p.x, "y": p.y, "born": Time.get_ticks_msec(), "n": n})

## a player walks over an orb: the first to reach it gets it
func take_drop(id: int) -> Array:
	for i in drops.size():
		if int(drops[i]["id"]) == id:
			var d = drops[i]
			drops.remove_at(i)
			return [str(d["kind"]), int(d["n"])]
	return []

func drops_snapshot() -> Array:
	var out = []
	for d in drops:
		out.append([d["id"], d["kind"], snappedf(d["x"], 0.1), snappedf(d["y"], 0.1), d["n"]])
	return out

func heal_while_away(ms: int) -> void:
	for e in enemies:
		if e["alive"] and e["hp"] < e["maxhp"]:
			e["hp"] = mini(e["maxhp"], e["hp"] + roundi(e["maxhp"] * 0.01 * ms / 1000.0))

func alive_count() -> int:
	var n = 0
	for e in enemies:
		if e["alive"] and e["state"] != "dying":
			n += 1
	return n

## a big land (EARTH: thousands of foes): only the foes near someone are run and drawn; the list is made
## again 3 times a second (foes far from everyone rest - no stutter however big the world)
var awake = []
var _awake_t = 0
func _refresh_awake(fighters: Array) -> void:
	_awake_t = 20
	if enemies.size() < 250:
		awake = enemies
		return
	var out = []
	for e in enemies:
		for f in fighters:
			if absf(f["x"] - e["x"]) < 1000.0 and absf(f["y"] - e["y"]) < 800.0:
				out.append(e)
				break
	awake = out

## the compact picture sent to the players
func snapshot() -> Array:
	var out = []
	for e in awake:
		if not e["alive"]:
			continue
		out.append([e["id"], snappedf(e["x"], 0.1), snappedf(e["y"], 0.1), e["anim"], e["dir"], e["frame"], e["set"], e["hp"], e["maxhp"],
			(1 if e["elite"] else 0) | (2 if e["boss"] or e.get("wboss", false) else 0) | (4 if e["state"] == "dying" else 0) | (8 if e["flash"] > 0 else 0) | (16 if e["big"] else 0) | (32 if e["state"] == "spawning" else 0) | (64 if e["state"] == "windup" else 0), e["name"],
			int(e.get("slam_r", 0)) if e["state"] == "windup" and e.get("next", "") == "slam" else 0,
			int(100.0 * e["t"] / maxf(1.0, float(e.get("wind", 1)))) if e["state"] == "windup" else 0])
	return out

func eshots_snapshot() -> Array:
	# [x, y, kind, dir, t, a, b, id] - kind: index in SHOT_KINDS; a/b: length, radius, height... per kind
	var out = []
	for sh in eshots:
		out.append([snappedf(sh["x"], 0.1), snappedf(sh["y"], 0.1), SHOT_KINDS.find(sh["k"]), int(sh.get("dir", 0)), int(sh["t"]),
			snappedf(float(sh.get("a", 0)), 0.1), snappedf(float(sh.get("b", -1)), 0.1), int(sh["id"])])
	return out

## a WORLD BOSS: a giant of this place, much stronger, with a boss's moves - it never comes back
func add_world_boss(lv: int) -> String:
	var t = -1
	var st = -1
	for e in enemies:
		if not e["boss"] and not e.get("minion", false):
			t = int(e["type"]); st = int(e["set"])
			break
	if t < 0:
		return ""
	var grp = Rules.group_of(t)
	var names = {"human": ["WARLORD", "TYRANT", "DARK MASTER"], "animal": ["ALPHA BEAST", "ANCIENT ONE", "KING OF THE WILD"],
		"robot": ["MEGA MACHINE", "WAR ENGINE", "OMEGA UNIT"], "big": ["COLOSSUS", "TITAN", "MOUNTAIN"]}.get(grp, ["GIANT"])
	var nm = "THE " + str(names[rng.randi_range(0, names.size() - 1)])
	var p = _open_near(Vector2(area["w"] / 2.0, area["h"] / 2.0))
	var e = make_enemy(5000 + enemies.size(), t, st, p, lv + 6, true, false)
	e["wboss"] = true
	e["minion"] = true
	e["big"] = true
	e["maxhp"] = int(e["base_hp"]) * 20
	e["hp"] = e["maxhp"]
	e["atk"] = float(e["base_atk"]) * 1.6
	e["name"] = nm
	var ai: Dictionary = Content.enemy_cfg.get("styles", {}).get("boss", {}).duplicate()
	ai["style"] = "boss"
	ai["own"] = Content.own_attack(t)
	e["ai"] = ai
	e["state"] = "spawning"
	add_later.append(e)
	return nm

func has_world_boss() -> bool:
	for e in enemies + add_later:
		if e.get("wboss", false) and e["alive"]:
			return true
	return false


# ------------------------------------------------------------------ the game's own enemy AI (enemy_ai.gd) and its attacks
func uses_ai(e: Dictionary) -> bool:
	if e.has("_ai"):
		return e["_ai"]
	var on = not e["boss"] and not e.get("wboss", false) and EnemyAI.ready_for(int(e["type"])) and Game.cfg.get("game_ai", true)
	e["_ai"] = on
	return on

## a blow (or a dash, a swoop) from a foe: every fighter whose body the box touches is hit
func ai_attack(e: Dictionary, r: Rect2, power: float, dir: int) -> bool:
	var any = false
	for f in ai.fighters:
		if f["down"] or f["inv"]:
			continue
		if r.intersects(EnemyAI.f_body(f)):
			var kv = DIRV[clampi(dir, 0, 3)] * 2.0
			_ev.append({"type": "hurt", "peer": f["peer"], "atk": float(e["atk"]) * power, "kx": kv.x, "ky": kv.y, "et": int(e["type"])})
			any = true
	return any

## what a foe throws (the game's own): a missile, a ki blast, a laser
func ai_shot(e: Dictionary, kind: String, p: Vector2, dir: int, extra: Dictionary = {}) -> void:
	var d = {"k": kind, "x": p.x, "y": p.y, "dir": dir, "atk": float(e["atk"]), "owner": e["id"]}
	var v: Vector2 = DIRV[clampi(dir, 0, 3)]
	match kind:
		"missile":
			d["vx"] = v.x * 1.75; d["vy"] = v.y * 1.75
		"kiblast":
			d["vx"] = v.x * 3.0; d["vy"] = v.y * 3.0
		"laserseg":
			d["vx"] = v.x * 4.0; d["vy"] = v.y * 4.0
		"laserbeam":
			d["a"] = float(extra.get("len", 64)); d["life"] = 60
		"star":
			d["vx"] = v.x * 1.75; d["vy"] = v.y * 1.75
		"bomb2":
			# lobbed: straight at the spot, the screen-y speed starting 2 px up and falling 1/8 px a frame; it lands when its height drops below 0
			var vv: Vector2 = extra.get("v", Vector2.ZERO)
			d["vx"] = vv.x; d["vy"] = vv.y - 2.0; d["z"] = 8.0; d["vz"] = 2.0
	_add_shot(d)

func ai_sound(_e: Dictionary, name: String) -> void:
	var i = AI_SOUNDS.find(name)
	if i >= 0:
		_add_shot({"k": "sfx", "x": _e["x"], "y": _e["y"], "a": float(i)})

func ai_sound_stop(_e: Dictionary, _name: String) -> void:
	pass

## one tick of the game's own throws; true = it is gone
func _step_ai_shot(sh: Dictionary, fighters: Array, ev: Array) -> bool:
	var t: int = sh["t"]
	match str(sh["k"]):
		"bomb2":
			sh["x"] += sh["vx"]; sh["y"] += sh["vy"]
			sh["vy"] += 0.125
			sh["vz"] -= 0.125
			sh["z"] += sh["vz"]
			if sh["z"] < 0:
				var hb2 = Rect2(sh["x"] - 8, sh["y"] - 8, 16, 16)
				for f in fighters:
					if not f["down"] and not f["inv"] and hb2.intersects(EnemyAI.f_body(f)):
						_hurt_once(sh, f, ev, sh["atk"], Vector2.ZERO)
				_add_shot({"k": "boom", "x": sh["x"], "y": sh["y"], "a": 12.0, "life": 24, "atk": 0.0})
				return true
			return t > 200
		"missile", "kiblast", "laserseg", "star":
			sh["x"] += sh["vx"]; sh["y"] += sh["vy"]
			if sh["x"] < -16 or sh["y"] < -16 or sh["x"] > float(area["w"]) + 16 or sh["y"] > float(area["h"]) + 16:
				return true
			var hb = Rect2(sh["x"] - 8, sh["y"] - 14, 16, 16) if sh["k"] == "missile" else Rect2(sh["x"] - 4, sh["y"] - 4, 8, 8)
			var hit = false
			for f in fighters:
				if not f["down"] and not f["inv"] and hb.intersects(EnemyAI.f_body(f)):
					_hurt_once(sh, f, ev, sh["atk"], Vector2(sh["vx"], sh["vy"]).normalized() * 2.0)
					hit = true
					break
			if not hit and sh["k"] != "laserseg" and not Assets.walkable(area, sh["x"], sh["y"]) and t > 4:
				hit = true
			if hit:
				if sh["k"] == "missile":
					_add_shot({"k": "smoke", "x": sh["x"], "y": sh["y"], "life": 32})
				return true
			return t > 240
		"laserbeam":
			var v: Vector2 = DIRV[int(sh["dir"])]
			var o = Vector2(sh["x"], sh["y"])
			var r = Rect2(o, Vector2.ZERO).expand(o + v * float(sh["a"])).grow(3)
			for f in fighters:
				if not f["down"] and not f["inv"] and r.intersects(EnemyAI.f_body(f)):
					_hurt_once(sh, f, ev, sh["atk"], v * 2.0)
			return t > int(sh.get("life", 60))
		"smoke":
			return t > int(sh.get("life", 32))
		"sfx":
			return t > 3
	return true


## what a foe's states do this tick: poison / regeneration, a stun (it does nothing), slow (it skips ticks).
## true: it does nothing more this tick
func _foe_states(e: Dictionary) -> bool:
	var skip = false
	e["st_t"] = int(e.get("st_t", 0)) + 1
	for id in e["sts"].keys():
		var st = Content.state(id)
		e["sts"][id] = int(e["sts"][id]) - 1
		if int(e["sts"][id]) <= 0 or st.is_empty():
			e["sts"].erase(id)
			continue
		if int(e["st_t"]) % 60 == 0:
			var dh = int(st.get("hp_per_sec", 0))
			if dh < 0:
				# (as a blow: the foe can be beaten by it, and everyone near gets the EXP)
				var mag = maxi(1, roundi(-dh * maxf(1.0, float(e["maxhp"]) / 120.0)))
				var r = hit(int(e["id"]), mag, 0.0, 0.0, 0)
				events_out.append({"type": "foe_dot", "x": e["x"], "y": e["y"], "dmg": mag, "color": str(st.get("color", "ffffff")), "r": r})
				if not e["alive"] or e["state"] == "dying":
					return true
			elif dh > 0:
				e["hp"] = mini(int(e["maxhp"]), int(e["hp"]) + dh)
		if bool(st.get("stun", false)):
			skip = true
		var sp = float(st.get("speed", 1.0))
		if sp < 1.0 and rng.randf() > sp:
			skip = true
	if skip:
		if e["flash"] > 0:
			e["flash"] -= 1
	return skip
