class_name EnemyAI
extends RefCounted
## LoG2's own enemy AI, run from the game's behaviour scripts (read from your game at import: data/ai.json).
##
## Every foe kind starts in one behaviour of the game's table (the enemy table's "w8"). A behaviour is a
## little tree: sequences, "do these together", distance checks, chances per frame, waits, and actions
## (chase, line up, back off, strike, dash, shoot a missile, a ki blast, a laser...). Behaviours replace
## each other ("go to"), or stack ("push": a flinch, then back to what it was doing). Every behaviour also
## has a reaction for being hit (take the damage, flinch, get dizzy, turn on the attacker).
## Under the behaviours each foe has a small state of its own (idle, walk, hurt, strike 6/7/8, missile...)
## that picks its animation and times its attacks - the same numbers as the game (16 ticks a strike,
## the missile leaves on tick 8 of 32, ...).
##
## Positions are the game's: a foe's x/y is the top-left of its foot box (w x h from its sprite set,
## usually 16 x 8); its body box per direction comes from the sprite set too.

const TABLE = 0x086D5194
const DV = [Vector2(0, 1), Vector2(0, -1), Vector2(-1, 0), Vector2(1, 0)]

# node factories (the first word of a node) and check functions (the second)
const F_SEQ = 0x0801b63f
const F_PAR1 = 0x0801b887
const F_PARALL = 0x0801b861
const F_GOTO = 0x0801ab65
const F_PUSH = 0x0801a71d
const F_CALL = 0x0801b511
const F_HOME = 0x0801c451
const F_NULL = 0x0801a825
const F_POP = 0x0801a9a5
const F_IDLE = 0x0801a98d
const F_DIST = 0x0801aef3
const F_DISTAWAY = 0x0801d749
const F_CHANCE = 0x0801ba47
const F_IFCONTACT = 0x0801c05b
const F_IFTOUCH = 0x0801ea59
const F_WAIT = 0x0801bbad
const F_CHASE = 0x0801b333
const F_ALIGN = 0x0801b15f
const F_RETREAT = 0x0801c431
const F_BACKOFF = 0x0801c2ad
const F_FLEE = 0x0801b4f3
const F_KNOCKBACK = 0x0801a947
const F_STAGGER = 0x0801acb7
const F_STRIKE = 0x0801be8b
const F_DASH = 0x0801d255
const F_SWOOP = 0x0801c7f3
const F_SHAKE = 0x0801c95f
const F_FACE = 0x0801c0d7
const F_SETIDLE = 0x0801c085
const F_TRUE = 0x0801bb89
const F_WALKANIM = 0x0801c85b
const F_FLY = 0x0801c82d
const F_MISSILE = 0x0801bb6d
const F_KIBLAST = 0x0801bc6f
const F_LASER = 0x0801dcdb
const F_LASERBEAM = 0x0801e145
const F_DIZZY = 0x0801dbb3
const F_GUARD = 0x0801c5a3
const F_THROW = 0x0801cf73      # the ninjas: a throwing star
const F_THROWAT = 0x0801cca9    # the bandits: a bomb lobbed at you
const F_FREEZE = 0x0801bcf1     # struck still by a special (then a shiver, then back)
const F_SHIVER = 0x0801bca9
const F_UNFREEZE = 0x0801bd17

const C_OR = 0x0801b689
const C_GOTO = 0x0801ab7b
const C_PUSH = 0x0801a733
const C_CALL = 0x0801b525
const C_HOME = 0x0801c46b
const C_DIST = 0x0801af2b
const C_CHANCE = 0x0801ba69
const C_IFATK = 0x0801a805
const C_IFROOM = 0x0801acd5
const C_TAKEDMG = 0x0801a6e1
const C_TRUE = 0x0801bb8d
const C_SETIDLE = 0x0801c089
const C_FACE = 0x0801c0db
const C_POP = 0x0801a9a9
const C_GUARD = 0x0801c5a9
const C_FREEZE = 0x0801bcf7
const C_SHIVER = 0x0801bcad
const C_UNFREEZE = 0x0801bd1b

const KB_ROOM = [Vector2(0, 4), Vector2(0, -4), Vector2(-4, 0), Vector2(4, 0)]   # 0x086FF40C
const KB_DIR = [-8.0, 8.0, 8.0, -8.0]                                             # 0x086FF3D0
const MISSILE_MUZZLE = [Vector2(4, 4), Vector2(13, -24), Vector2(-8, -8), Vector2(24, -8)]   # 0x086FF440
const LASER_MUZZLE = [Vector2(40, 16), Vector2(8, -48), Vector2(-16, -12), Vector2(64, -12)]  # 0x08701E2C

static var words = {}     # address >> 2 -> word
static var loaded = false

static func load_data() -> void:
	if loaded:
		return
	loaded = true
	var d = Assets.data.get("ai", null)
	if not (d is Dictionary) or not d.has("ranges"):
		return
	for r in d["ranges"]:
		var a0 = ("0x" + str(r[0])).hex_to_int()
		var arr: Array = r[1]
		for i in arr.size():
			words[(a0 >> 2) + i] = int(arr[i])

static func ready_for(t: int) -> bool:
	load_data()
	if words.is_empty():
		return false
	var root = behaviour_of(t)
	return root >= 0 and root < 152

static func behaviour_of(t: int) -> int:
	var tab: Array = Assets.data.get("enemies", [])
	if t < 0 or t >= tab.size():
		return -1
	return int(tab[t].get("w8", -1))

static func w(a: int) -> int:
	return int(words.get(a >> 2, 0))

static func sw(a: int) -> int:
	var v = w(a)
	return v - 0x100000000 if v >= 0x80000000 else v

static func entry_def(idx: int) -> int:
	return w(TABLE + 8 * idx)

static func entry_hit(idx: int) -> int:
	return w(TABLE + 8 * idx + 4)

# ------------------------------------------------------------------ the world the foes live in
## sim: the AreaSim (walkable, fighters, rng, shots); set per tick
var sim = null
var fighters: Array = []

func _init(s) -> void:
	sim = s

# ------------------------------------------------------------------ a foe's boxes (the game's)
static func foot_size(e: Dictionary) -> Vector2:
	if e.has("_fw"):
		return Vector2(e["_fw"], e["_fh"])
	var hd: Array = Assets.sprite_set(int(e["set"])).get("header", [])
	var fw = 16; var fh = 8
	if hd.size() >= 2:
		var w0 = ("0x" + str(hd[0])).hex_to_int()
		fw = maxi(4, (w0 >> 24) & 0xFF)
		fh = maxi(4, ("0x" + str(hd[1])).hex_to_int() & 0xFF)
	e["_fw"] = fw; e["_fh"] = fh
	return Vector2(fw, fh)

static func center(e: Dictionary) -> Vector2:
	var s = foot_size(e)
	return Vector2(floorf(e["x"]) + floorf(s.x / 2.0), floorf(e["y"]) + floorf(s.y / 2.0))

## the body box for the foe's direction, in the world (x0, y0, x1, y1)
static func body(set_id: int, dir: int, x: float, y: float) -> Rect2:
	var hd: Array = Assets.sprite_set(set_id).get("header", [])
	var b = [-2, -23, 18, 10]
	var k = 3 + 4 * clampi(dir, 0, 3)
	if hd.size() >= k + 4:
		for i in 4:
			var v = ("0x" + str(hd[k + i])).hex_to_int()
			b[i] = v - 0x100000000 if v >= 0x80000000 else v
	var fx = floorf(x); var fy = floorf(y)
	return Rect2(fx + b[0], fy + b[1], b[2] - b[0], b[3] - b[1])

## where a thing leaves the foe's hands (the game's 0x07A26): the body box's middle edge toward its facing
static func hand(e: Dictionary) -> Vector2:
	var b = body(int(e["set"]), int(e["dir"]), e["x"], e["y"])
	var c = Vector2(floorf((b.position.x + b.end.x) / 2.0), floorf((b.position.y + b.end.y) / 2.0))
	match int(e["dir"]):
		0: return Vector2(c.x, floorf(e["y"]))
		2: return Vector2(b.position.x, c.y)
		3: return Vector2(b.end.x, c.y)
	return c

static func dir_to(d: Vector2) -> int:
	if absf(d.x) > absf(d.y):
		return 3 if d.x > 0 else 2
	return 0 if d.y > 0 else 1

## the nearest standing fighter (the game's target is player 1; two players: whoever is nearer)
func target(e: Dictionary) -> Variant:
	if e.has("_tgt"):
		return e["_tgt"]
	var c = center(e)
	var best = 1e9
	var t = null
	for f in fighters:
		if f["down"]:
			continue
		var d = f_center(f).distance_squared_to(c)
		if d < best:
			best = d; t = f
	e["_tgt"] = t
	return t

static func f_center(f: Dictionary) -> Vector2:
	return Vector2(floorf(f["x"]) + 8.0, floorf(f["y"]) + 4.0)

static func f_body(f: Dictionary) -> Rect2:
	return body(int(f.get("set", 54)), int(f.get("dir", 0)), f["x"], f["y"])

func can_stand(e: Dictionary, x: float, y: float) -> bool:
	if e.get("fly", false):
		return x >= -8 and y >= -8 and x < float(sim.area["w"]) and y < float(sim.area["h"])
	var s = foot_size(e)
	var a = sim.area
	for p in [Vector2(x + 1, y + 1), Vector2(x + s.x - 1, y + 1), Vector2(x + 1, y + s.y - 1), Vector2(x + s.x - 1, y + s.y - 1)]:
		if not Assets.walkable(a, p.x, p.y):
			return false
	return true

## move with the game's sliding: both ways, else across, else down/up; false when it could not move at all
func slide(e: Dictionary, v: Vector2) -> bool:
	var nx = e["x"] + v.x; var ny = e["y"] + v.y
	if can_stand(e, nx, ny):
		e["x"] = nx; e["y"] = ny
		return true
	if v.x != 0.0 and can_stand(e, nx, e["y"]):
		e["x"] = nx
		return true
	if v.y != 0.0 and can_stand(e, e["x"], ny):
		e["y"] = ny
		return true
	return false

func move_exact(e: Dictionary, v: Vector2) -> bool:
	var nx = e["x"] + v.x; var ny = e["y"] + v.y
	if can_stand(e, nx, ny):
		e["x"] = nx; e["y"] = ny
		return true
	return false

func rand16() -> int:
	return sim.rng.randi() & 0xFFFF

func rand_n(n: int) -> int:
	return (rand16() * n) >> 16

func chance(p: int) -> bool:
	return rand16() < p

# ------------------------------------------------------------------ the foe's own state (animation + timing)
## st: {id, t, ...}; anim/frame for the picture
func set_state(e: Dictionary, id: String, extra: Dictionary = {}) -> void:
	var old: Dictionary = e.get("st", {})
	if str(old.get("id", "")) == "shake":
		e["x"] = old["sx"]; e["y"] = old["sy"]
	var st = {"id": id, "t": 0}
	st.merge(extra, true)
	match id:
		"idle":
			st["t"] = rand_n(255)
			e["anim"] = 0; e["frame"] = 0
		"walk", "run":
			e["anim"] = 1; e["frame"] = 0
		"backwalk":
			e["anim"] = 1; e["frame"] = 0
		"hurt":
			e["anim"] = 2; e["frame"] = 0
		"melee":
			e["anim"] = int(st["n"]); e["frame"] = 0
			sim.ai_sound(e, "foe_swing")
		"missile":
			e["anim"] = 6; e["frame"] = 0
		"kiblast":
			e["anim"] = 5; e["frame"] = 0
		"laser":
			e["anim"] = 7; e["frame"] = 0
			sim.ai_sound(e, "foe_laser")
		"laserbeam":
			e["anim"] = 6; e["frame"] = 0
		"swoop":
			e["anim"] = 6; e["frame"] = 0
		"shake":
			st["sx"] = e["x"]; st["sy"] = e["y"]
			e["anim"] = 0; e["frame"] = 0
			sim.ai_sound(e, "foe_rumble")
		"dizzy":
			st["t"] = 0xF0
			e["anim"] = 2; e["frame"] = 2
		"throw", "throwat":
			e["anim"] = 8; e["frame"] = 0
		"frozen":
			pass
		"shiver":
			e["anim"] = 2; e["frame"] = 0
	e["st"] = st
	if id == "laserbeam":
		_laserbeam_start(e)

func state_is(e: Dictionary, id: String) -> bool:
	return str(e.get("st", {}).get("id", "")) == id

func ensure_state(e: Dictionary, id: String) -> void:
	# (walking, but showing another picture - put there by dying, coming back, a freeze...: the foe slid along
	# without moving its legs until a blow reset it - the TIGER MEN. The walk's own picture again)
	if not state_is(e, id) or (id in ["walk", "run", "backwalk"] and int(e["anim"]) != 1):
		set_state(e, id)

func step_state(e: Dictionary) -> void:
	var st: Dictionary = e.get("st", {})
	if st.is_empty():
		set_state(e, "idle")
		st = e["st"]
	match str(st["id"]):
		"idle":
			st["t"] += 1
			e["frame"] = 1 if (st["t"] & 0xFF) > 0xF0 else 0
		"walk":
			st["t"] += 1
			e["frame"] = (st["t"] >> 3) & 3
		"run":
			st["t"] += 1
			e["frame"] = (st["t"] >> 2) & 3
		"backwalk":
			st["t"] -= 1
			e["frame"] = (st["t"] >> 3) & 3
		"hurt":
			st["t"] += 1
			if st["t"] >= 32:
				set_state(e, "idle")
			else:
				e["frame"] = st["t"] >> 3
		"melee":
			st["t"] += 1
			if st["t"] >= 16:
				set_state(e, "idle")
			else:
				e["frame"] = st["t"] >> 2
		"missile":
			st["t"] += 1
			if st["t"] >= 32:
				set_state(e, "idle")
			else:
				e["frame"] = st["t"] >> 3
				if st["t"] == 8:
					var p = Vector2(floorf(e["x"]), floorf(e["y"])) + MISSILE_MUZZLE[int(e["dir"])]
					sim.ai_shot(e, "missile", p, int(e["dir"]))
		"kiblast":
			st["t"] += 1
			if st["t"] >= 32:
				set_state(e, "idle")
			else:
				e["frame"] = st["t"] >> 4
				if st["t"] == 16:
					sim.ai_shot(e, "kiblast", hand(e), int(e["dir"]))
		"laser":
			st["t"] += 1
			if st["t"] >= 0x80:
				sim.ai_sound_stop(e, "foe_laser")
				set_state(e, "idle")
			elif st["t"] < 4:
				e["frame"] = 0
			else:
				var f = (st["t"] >> 2) & 3
				e["frame"] = 2 if f == 0 else f
				var p3 = Vector2(floorf(e["x"]), floorf(e["y"])) + LASER_MUZZLE[int(e["dir"])]
				sim.ai_shot(e, "laserseg", p3, int(e["dir"]))
		"laserbeam":
			st["t"] += 1
			if st["t"] >= 0x3C:
				if st.has("inst"):
					st["inst"]["done"] = true
				set_state(e, "idle")
			else:
				e["frame"] = (st["t"] >> 3) & 3
		"swoop":
			pass
		"shake":
			if st.has("n"):
				st["n"] -= 1
				if st["n"] >= 16:
					if st["n"] & 1:
						e["x"] = st["sx"] + (rand_n(1024) - 512) / 256.0
						e["y"] = st["sy"] + (rand_n(1024) - 512) / 256.0
				else:
					e["x"] = st["sx"]; e["y"] = st["sy"]
		"throw", "throwat":
			st["t"] += 1
			if st["t"] >= 32:
				set_state(e, "idle")
			else:
				e["frame"] = st["t"] >> 3
				if st["id"] == "throw" and st["t"] == 8:
					sim.ai_shot(e, "star", hand(e), int(e["dir"]))
				elif st["id"] == "throwat" and st["t"] == 16:
					var muz = [Vector2(12, -8), Vector2(12, -8), Vector2(16, -16), Vector2(0, -16)][int(e["dir"])]     # 0x086FF8A8
					sim.ai_shot(e, "bomb2", Vector2(floorf(e["x"]), floorf(e["y"])) + muz, int(e["dir"]), {"v": st["v"]})
		"frozen":
			pass
		"shiver":
			st["t"] += 1
			e["frame"] = (st["t"] >> 2) & 1
		"dizzy":
			st["t"] -= 1
			if st["t"] <= 0:
				set_state(e, "idle")
			else:
				e["frame"] = 2 + ((st["t"] >> 4) & 1)

func _laserbeam_start(e: Dictionary) -> void:
	var b = body(int(e["set"]), int(e["dir"]), e["x"], e["y"])
	var p = b.get_center() + DV[int(e["dir"])] * (b.size * 0.5)
	sim.ai_shot(e, "laserbeam", p, int(e["dir"]), {"len": float(e["st"].get("n", 64))})

# ------------------------------------------------------------------ behaviour instances
## an instance: {"k": factory, "d": def, ...}
func make(d: int, e: Dictionary) -> Dictionary:
	var f = w(d)
	match f:
		F_SEQ, F_PAR1, F_PARALL:
			var n = w(d + 12)
			var ch = []
			for i in n:
				ch.append(make(w(d + 16 + 4 * i), e))
			return {"k": f, "d": d, "i": 0, "n": n, "ch": ch}
		F_CALL:
			return make(entry_def(w(d + 12)), e)
		F_HOME:
			return make(entry_def(behaviour_of(int(e["type"]))), e)
		F_DIST, F_DISTAWAY:
			return {"k": f, "d": d, "r2": w(d + 12), "a": make(w(d + 16), e), "b": make(w(d + 20), e), "far": 1}
		F_CHANCE:
			return {"k": f, "d": d, "p": w(d + 12), "c": make(w(d + 16), e)}
		F_IFCONTACT, F_IFTOUCH:
			return {"k": f, "d": d, "on": false, "c": make(w(d + 12), e)}
		F_WAIT, F_SHAKE:
			return {"k": f, "d": d, "n": w(d + 12)}
		F_DASH, F_SWOOP:
			return {"k": f, "d": d, "speed": w(d + 12), "range": w(d + 16)}
		0:
			return {"k": F_NULL, "d": d}
		_:
			return {"k": f, "d": d, "p": w(d + 12)}

func enter(n: Dictionary, e: Dictionary) -> void:
	match int(n["k"]):
		F_SEQ:
			if n["i"] < n["n"]:
				enter(n["ch"][n["i"]], e)
		F_PAR1, F_PARALL:
			for c in n["ch"]:
				enter(c, e)
		F_DIST:
			n["far"] = 0           # (the game enters the near branch first, whatever the distance)
			enter(n["a"], e)
		F_DISTAWAY:
			n["far"] = _away_cond(n, e)
			enter(n["b"] if n["far"] else n["a"], e)
		F_CHANCE:
			enter(n["c"], e)
		F_IFCONTACT, F_IFTOUCH:
			n["on"] = _contact(e, int(n["k"]) == F_IFTOUCH)
			if n["on"]:
				enter(n["c"], e)
		F_KNOCKBACK:
			var d = int(e.get("hitdir", 0)) ^ 1
			var s7 = ((rand_n(64) + 0x60) * int(n["p"])) >> 7
			var v = Vector2.ZERO
			var along = KB_DIR[d] * s7 / 256.0
			var side = ((rand_n(32768) - 16384) * s7 >> 12) / 256.0
			if d < 2:
				v = Vector2(side, along)
			else:
				v = Vector2(along, side)
			n["v"] = v
			e["dir"] = d
			set_state(e, "hurt")
		F_STAGGER:
			e["dir"] = int(e.get("hitdir", 0)) ^ 1
			set_state(e, "hurt")
		F_STRIKE:
			_strike(n, e)
		F_DASH:
			_dash_enter(n, e)
		F_SWOOP:
			_dash_enter(n, e)
			set_state(e, "swoop")
		F_SHAKE:
			if int(n["n"]) > 0:
				set_state(e, "shake", {"n": int(n["n"])})
		F_MISSILE:
			sim.ai_sound(e, "foe_missile")
			set_state(e, "missile")
		F_KIBLAST:
			set_state(e, "kiblast")
		F_LASER:
			_face(e)
			set_state(e, "laser")
		F_LASERBEAM:
			_face(e)
			n["done"] = false
			set_state(e, "laserbeam", {"n": int(n["p"]), "inst": n})
		F_DIZZY:
			set_state(e, "dizzy")
		F_WALKANIM:
			ensure_state(e, "walk")
		F_FLY:
			e["fly"] = true
		F_GUARD:
			set_state(e, "hurt")
		F_THROW:
			_face(e)
			set_state(e, "throw")
		F_THROWAT:
			_face(e)
			var t = target(e)
			var dv = Vector2.ZERO
			if t != null:
				dv = Vector2(floorf(t["x"]) - floorf(e["x"]), floorf(t["y"]) - floorf(e["y"]))
				if int(e["dir"]) >= 2:
					dv.y = 0
				else:
					dv.x = 0
			set_state(e, "throwat", {"v": dv * (0x71d / 65536.0)})
		F_FREEZE:
			set_state(e, "frozen")
		F_SHIVER:
			set_state(e, "shiver")
		F_UNFREEZE:
			set_state(e, "idle")

## one frame; true = done
func update(n: Dictionary, e: Dictionary) -> bool:
	match int(n["k"]):
		F_SEQ:
			if n["i"] >= n["n"]:
				return true
			if update(n["ch"][n["i"]], e):
				exit(n["ch"][n["i"]], e)
				n["i"] += 1
				if n["i"] >= n["n"]:
					return true
				enter(n["ch"][n["i"]], e)
			return false
		F_PAR1:
			for c in n["ch"]:
				if update(c, e):
					return true
			return false
		F_PARALL:
			var r = false
			for c in n["ch"]:
				r = update(c, e) or r
			return r
		F_GOTO:
			replace_top(e, int(n["p"]))
			return true
		F_PUSH:
			push(e, int(n["p"]))
			return false
		F_NULL:
			return false
		F_POP:
			pop(e)
			return false
		F_IDLE:
			return _idle(e)
		F_DIST:
			var far = 1 if _far(n, e) else 0
			if far != n["far"]:
				n["far"] = far
				var old = n["a"] if far else n["b"]
				var nw = n["b"] if far else n["a"]
				exit(old, e); enter(nw, e)
				return update(nw, e)
			return update(n["b"] if far else n["a"], e)
		F_DISTAWAY:
			var far2 = _away_cond(n, e)
			if far2 != n["far"]:
				n["far"] = far2
				var old2 = n["a"] if far2 else n["b"]
				var nw2 = n["b"] if far2 else n["a"]
				exit(old2, e); enter(nw2, e)
				return update(nw2, e)
			return update(n["b"] if far2 else n["a"], e)
		F_CHANCE:
			if chance(int(n["p"])):
				return update(n["c"], e)
			return false
		F_IFCONTACT, F_IFTOUCH:
			var c2 = _contact(e, int(n["k"]) == F_IFTOUCH)
			if c2 != n["on"]:
				n["on"] = c2
				if c2:
					enter(n["c"], e)
					return update(n["c"], e)
				exit(n["c"], e)
				return false
			return update(n["c"], e) if c2 else false
		F_WAIT, F_SHAKE:
			if n["n"] == 0:
				return true
			n["n"] -= 1
			return n["n"] == 0
		F_CHASE:
			return _chase(n, e)
		F_ALIGN:
			return _align(n, e)
		F_RETREAT:
			return _retreat(n, e)
		F_BACKOFF:
			return _backoff(n, e)
		F_FLEE:
			return _flee(n, e)
		F_KNOCKBACK, F_STAGGER, F_GUARD:
			if not state_is(e, "hurt"):
				return true
			if n.has("v"):
				if not move_exact(e, n["v"]):
					n["v"] = Vector2.ZERO
			return false
		F_STRIKE:
			return state_is(e, "idle")
		F_DASH:
			return _dash(n, e)
		F_SWOOP:
			return _swoop(n, e)
		F_FACE:
			_face(e)
			return true
		F_SETIDLE:
			return true
		F_TRUE, F_WALKANIM, F_FLY:
			return true
		F_MISSILE:
			return not state_is(e, "missile")
		F_KIBLAST:
			return not state_is(e, "kiblast")
		F_LASER:
			return not state_is(e, "laser")
		F_LASERBEAM:
			return bool(n.get("done", false))
		F_DIZZY:
			return not state_is(e, "dizzy")
		F_THROW:
			return not state_is(e, "throw")
		F_THROWAT:
			return state_is(e, "idle")
		F_FREEZE, F_SHIVER, F_UNFREEZE:
			return true
	return true      # a node not known yet: it is done at once

func exit(n: Dictionary, e: Dictionary) -> void:
	match int(n["k"]):
		F_SEQ:
			if n["i"] < n["n"]:
				exit(n["ch"][n["i"]], e)
		F_PAR1, F_PARALL:
			for c in n["ch"]:
				exit(c, e)
		F_DIST, F_DISTAWAY:
			exit(n["b"] if n["far"] else n["a"], e)
		F_CHANCE:
			exit(n["c"], e)
		F_IFCONTACT, F_IFTOUCH:
			if n["on"]:
				exit(n["c"], e)
		F_LASER:
			sim.ai_sound_stop(e, "foe_laser")
		F_SHAKE:
			pass

# ------------------------------------------------------------------ the behaviour stack (the game's controller)
func start(e: Dictionary) -> void:
	e["ai_stack"] = []
	e["fly"] = false
	set_state(e, "idle")
	push(e, behaviour_of(int(e["type"])))

func push(e: Dictionary, idx: int) -> void:
	var stk: Array = e["ai_stack"]
	if stk.size() >= 5 or idx < 0 or idx >= 152:
		return
	var inst = make(entry_def(idx), e)
	stk.append([inst, idx])
	enter(inst, e)

func replace_top(e: Dictionary, idx: int) -> void:
	var stk: Array = e["ai_stack"]
	if idx < 0 or idx >= 152:
		return
	var inst = make(entry_def(idx), e)
	if not stk.is_empty():
		exit(stk[-1][0], e)
		stk[-1] = [inst, idx]
	else:
		stk.append([inst, idx])
	enter(inst, e)

func pop(e: Dictionary) -> void:
	var stk: Array = e["ai_stack"]
	if stk.size() <= 1:
		return
	var top = stk.pop_back()
	exit(top[0], e)

## one frame of a foe: its state, then its top behaviour
func tick(e: Dictionary) -> void:
	e.erase("_tgt")
	if not e.has("ai_stack"):
		start(e)
	step_state(e)
	var stk: Array = e["ai_stack"]
	if stk.is_empty():
		push(e, behaviour_of(int(e["type"])))
		return
	update(stk[-1][0], e)

## hit by a fighter: info {dir: the way the blow went, kind: attack kind (1 punch... 9/15 specials), died}
func on_hit(e: Dictionary, info: Dictionary) -> void:
	if not e.has("ai_stack"):
		start(e)
	e["hitdir"] = int(info.get("dir", 0))
	var stk: Array = e["ai_stack"]
	if stk.is_empty():
		return
	check(entry_hit(int(stk[-1][1])), e, info)

## a node's reaction ("check"): true stops an "or" list
func check(d: int, e: Dictionary, info: Dictionary) -> bool:
	if d == 0:
		return false
	var c = w(d + 4)
	match c:
		C_OR:
			var n = w(d + 12)
			for i in n:
				if check(w(d + 16 + 4 * i), e, info):
					return true
			return false
		C_GOTO:
			replace_top(e, w(d + 12))
			return false
		C_PUSH:
			push(e, w(d + 12))
			return false
		C_CALL:
			return check(entry_hit(w(d + 12)), e, info)
		C_HOME:
			return check(entry_hit(behaviour_of(int(e["type"]))), e, info)
		C_DIST:
			var t = target(e)
			var far = t == null or center(e).distance_squared_to(f_center(t)) > w(d + 12)
			return check(w(d + 20) if far else w(d + 16), e, info)
		C_CHANCE:
			return chance(w(d + 12)) and check(w(d + 16), e, info)
		C_IFATK:
			var kind = w(d + 12)
			var k: Array = info.get("kinds", [0, int(info.get("kind", 1))])
			return (kind == int(k[1]) or kind == int(k[0])) and check(w(d + 16), e, info)
		C_IFROOM:
			var p = Vector2(e["x"], e["y"]) + KB_ROOM[clampi(int(info.get("dir", 0)), 0, 3)]
			var room = can_stand(e, p.x, p.y)
			return check(w(d + 16) if room else w(d + 12), e, info)
		C_TAKEDMG:
			return bool(info.get("died", false))
		C_TRUE:
			return true
		C_SETIDLE:
			set_state(e, "idle")
			return false
		C_FACE:
			_face(e)
			return false
		C_POP:
			pop(e)
			return true
		C_GUARD:
			set_state(e, "hurt")
			return false
		C_FREEZE:
			set_state(e, "frozen")
			return false
		C_SHIVER:
			set_state(e, "shiver")
			return false
		C_UNFREEZE:
			set_state(e, "idle")
			return false
	return false

# ------------------------------------------------------------------ the conditions
func _far(n: Dictionary, e: Dictionary) -> bool:
	var t = target(e)
	if t == null:
		return true
	return center(e).distance_squared_to(f_center(t)) > int(n["r2"])

## 1 when there is no one near, or the foe looks straight away from them (it has not noticed)
func _away_cond(n: Dictionary, e: Dictionary) -> int:
	var t = target(e)
	if t == null:
		return 1
	var d = f_center(t) - center(e)
	if d.length_squared() > int(n["r2"]):
		return 1
	var away = 0
	if absf(d.x) >= absf(d.y):
		away = 3 if d.x < 0 else 2
	else:
		away = 0 if d.y < 0 else 1
	return 1 if int(e["dir"]) == away else 0

## in reach for a blow: the target's body against the foe's body box (and it turns to face them)
func _contact(e: Dictionary, touch: bool) -> bool:
	var t = target(e)
	if t == null:
		return false
	var tb = f_body(t)
	var b = body(int(e["set"]), int(e["dir"]), e["x"], e["y"])
	var x0 = b.position.x; var y0 = b.position.y; var x1 = b.end.x; var y1 = b.end.y
	if touch:
		if not (x0 + 2 < tb.end.x and tb.position.x < x1 - 3 and y0 + 2 < tb.end.y and tb.position.y < y1 - 6):
			return false
	else:
		if not (x0 - 4 < tb.end.x and tb.position.x < x1 + 3 and y0 < tb.end.y and tb.position.y < y1 - 6):
			return false
	var d = tb.get_center() - b.get_center()
	e["dir"] = dir_to(d) if absf(d.x) != absf(d.y) else int(e["dir"])
	var b2 = body(int(e["set"]), int(e["dir"]), e["x"], e["y"])
	var c = b2.get_center()
	var r = Rect2()
	match int(e["dir"]):
		3: r = Rect2(c.x, b2.position.y, b2.end.x + 3 - c.x, b2.size.y)
		2: r = Rect2(b2.position.x - 4, b2.position.y, c.x - b2.position.x + 4, b2.size.y)
		0: r = Rect2(b2.position.x, c.y, b2.size.x, b2.end.y - 6 - c.y)
		1: r = Rect2(b2.position.x, b2.position.y, b2.size.x, c.y - b2.position.y)
	return r.intersects(tb)

# ------------------------------------------------------------------ the actions
func _face(e: Dictionary) -> void:
	var t = target(e)
	if t == null:
		return
	var d = Vector2(floorf(t["x"]) - floorf(e["x"]), floorf(t["y"]) - floorf(e["y"]))
	if absf(d.x) >= absf(d.y):
		e["dir"] = 3 if d.x > 0 else 2
	else:
		e["dir"] = 0 if d.y > 0 else 1

func _chase(n: Dictionary, e: Dictionary) -> bool:
	var t = target(e)
	if t == null:
		return false
	var d = f_center(t) - center(e)
	e["dir"] = (3 if d.x > 0 else 2) if absf(d.x) > absf(d.y) else (0 if d.y > 0 else 1)
	var m = maxf(absf(d.x), absf(d.y))
	if m < 3:
		ensure_state(e, "idle")
		return false
	ensure_state(e, "walk")
	var sp = int(n["p"]) / 256.0
	slide(e, d * sp / m)
	return false

func _align(n: Dictionary, e: Dictionary) -> bool:
	var t = target(e)
	if t == null:
		return false
	var d = f_center(t) - center(e)
	var sp = int(n["p"]) / 256.0
	if absf(d.x) > absf(d.y):
		if absf(d.y) < 3:
			if state_is(e, "walk"):
				set_state(e, "idle")
			e["dir"] = 3 if d.x > 0 else 2
			return true
		e["dir"] = 0 if d.y > 0 else 1
		var v = Vector2(0, sp if d.y > 0 else -sp)
		if move_exact(e, v):
			ensure_state(e, "walk")
			return false
	else:
		if absf(d.x) < 3:
			if state_is(e, "walk"):
				set_state(e, "idle")
			e["dir"] = 0 if d.y > 0 else 1
			return true
		e["dir"] = 3 if d.x > 0 else 2
		var v2 = Vector2(sp if d.x > 0 else -sp, 0)
		if move_exact(e, v2):
			ensure_state(e, "walk")
			return false
	if state_is(e, "walk"):
		set_state(e, "idle")
	return true

func _retreat(n: Dictionary, e: Dictionary) -> bool:
	var t = target(e)
	if t == null:
		return false
	var d = f_center(t) - center(e)
	var m = 0.0
	if absf(d.x) > absf(d.y):
		e["dir"] = 2 if d.x > 0 else 3
		d.y = 0; m = absf(d.x)
	else:
		e["dir"] = 1 if d.y > 0 else 0
		d.x = 0; m = absf(d.y)
	if m == 0:
		return false
	ensure_state(e, "walk")
	var sp = int(n["p"]) / 256.0
	return not move_exact(e, -d * sp / m)

func _backoff(n: Dictionary, e: Dictionary) -> bool:
	var t = target(e)
	if t == null:
		return true
	var d = f_center(t) - center(e)
	var m = maxf(absf(d.x), absf(d.y))
	if absf(d.x) > absf(d.y):
		e["dir"] = 2 if d.x < 0 else 3
	else:
		e["dir"] = 1 if d.y < 0 else 0
	if m == 0:
		return false
	ensure_state(e, "backwalk")
	var sp = int(n["p"]) / 256.0
	slide(e, -d * sp / m)
	return false

func _flee(n: Dictionary, e: Dictionary) -> bool:
	var t = target(e)
	if t == null:
		return true
	var d = f_center(t) - center(e)
	var m = maxf(absf(d.x), absf(d.y))
	if absf(d.x) > absf(d.y):
		e["dir"] = 2 if d.x > 0 else 3
	else:
		e["dir"] = 1 if d.y > 0 else 0
	if m == 0:
		return false
	ensure_state(e, "walk")
	var sp = int(n["p"]) / 256.0
	return not slide(e, -d * sp / m)

func _strike(n: Dictionary, e: Dictionary) -> void:
	var t = target(e)
	if t != null:
		var tb = f_body(t)
		var b = body(int(e["set"]), int(e["dir"]), e["x"], e["y"])
		var dd = tb.get_center() - b.get_center()
		e["dir"] = dir_to(dd) if absf(dd.x) != absf(dd.y) else int(e["dir"])
		var b2 = body(int(e["set"]), int(e["dir"]), e["x"], e["y"])
		var c = b2.get_center()
		var r = Rect2()
		match int(e["dir"]):
			3: r = Rect2(c.x, c.y, b2.end.x + 3 - c.x, 1).grow_individual(0, c.y - b2.position.y, 0, b2.end.y - c.y)
			2: r = Rect2(b2.position.x - 4, b2.position.y, c.x - b2.position.x + 4, b2.size.y)
			0: r = Rect2(b2.position.x, c.y, b2.size.x, maxf(1, b2.end.y - 6 - c.y))
			1: r = Rect2(b2.position.x, b2.position.y, b2.size.x, c.y - b2.position.y)
		if sim.ai_attack(e, r, 1.0, int(e["dir"])):
			sim.ai_sound(e, "foe_hit")
	set_state(e, "melee", {"n": 6 + rand_n(maxi(1, int(n["p"])))})

func _dash_enter(n: Dictionary, e: Dictionary) -> void:
	n["hit"] = false; n["fin"] = false
	n["unit"] = Vector2.ZERO; n["vel"] = Vector2.ZERO
	var t = target(e)
	if t == null:
		return
	var d = f_center(t) - center(e)
	e["dir"] = (3 if d.x > 0 else 2) if absf(d.x) > absf(d.y) else (0 if d.y > 0 else 1)
	var m = maxf(absf(d.x), absf(d.y))
	var u = d / m if m > 0 else Vector2.ZERO
	n["unit"] = u
	n["vel"] = u * (int(n["speed"]) / 256.0)
	if int(n["k"]) == F_DASH:
		set_state(e, "run")
		sim.ai_sound(e, "foe_dash")

func _dash(n: Dictionary, e: Dictionary) -> bool:
	if n["fin"]:
		return true
	var t = target(e)
	if t == null:
		return true
	if not move_exact(e, n["vel"]):
		return true
	var d = f_center(t) - center(e)
	if n["unit"].dot(d) < 0 and d.length_squared() > float(int(n["range"]) * int(n["range"])):
		n["fin"] = true
		return true
	if not n["hit"]:
		var b = body(int(e["set"]), int(e["dir"]), e["x"], e["y"])
		var r = Rect2(b.position.x, b.get_center().y, b.size.x, b.end.y - b.get_center().y)
		if sim.ai_attack(e, r, 1.0, int(e["dir"])):
			n["hit"] = true
			sim.ai_sound(e, "foe_hit")
	return false

func _swoop(n: Dictionary, e: Dictionary) -> bool:
	if n["fin"]:
		return true
	var t = target(e)
	if t == null:
		return true
	e["x"] += n["vel"].x; e["y"] += n["vel"].y
	var d = f_center(t) - center(e)
	var along = n["unit"].dot(d)
	if along < -8:
		e["frame"] = 3
		if d.length_squared() > float(int(n["range"]) * int(n["range"])):
			n["fin"] = true
			return true
	elif along < 8:
		if int(e["frame"]) != 2:
			var b = body(int(e["set"]), int(e["dir"]), e["x"], e["y"])
			if sim.ai_attack(e, b, 1.0, int(e["dir"])):
				sim.ai_sound(e, "foe_hit")
			e["frame"] = 2
	elif along < 16:
		e["frame"] = 1
	else:
		e["frame"] = 0
	return false

## wandering about its post when nobody is around (the game walks a little patrol of its own)
func _idle(e: Dictionary) -> bool:
	var wd = int(e.get("wt", 0)) - 1
	e["wt"] = wd
	if wd <= 0:
		e["wt"] = sim.rng.randi_range(60, 180)
		var home = Vector2(e["hx"], e["hy"])
		var here = Vector2(e["x"], e["y"])
		if here.distance_to(home) > 48:
			e["wander"] = (home - here).normalized() * 0.5
		elif sim.rng.randf() < 0.5:
			e["wander"] = Vector2.ZERO
		else:
			e["wander"] = [Vector2(0.5, 0), Vector2(-0.5, 0), Vector2(0, 0.5), Vector2(0, -0.5)][sim.rng.randi_range(0, 3)]
	var v: Vector2 = e.get("wander", Vector2.ZERO)
	if v != Vector2.ZERO and slide(e, v):
		e["dir"] = dir_to(v)
		ensure_state(e, "walk")
	else:
		ensure_state(e, "idle")
	return false
