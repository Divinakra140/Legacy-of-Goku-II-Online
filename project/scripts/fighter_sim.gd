class_name FighterSim
extends RefCounted
## One fighter (the local player's): moves, punches, fires ki - with the timings measured on the original.

var ch = 4                 # 0 Gohan 1 Piccolo 2 Vegeta 3 Trunks 4 Goku 5 Mr. Satan
var set_id = 60
var name = "GOKU"
var x = 0.0
var y = 0.0
var dir = 0
var anim = Rules.A_IDLE
var anim_t = 0
var frame = 0
var state = "idle"
var idle_t = 0
var combo = 0
var since_attack = 999
var a_hold = 0
var b_hold = 0
var hit_done = {}          # enemy ids already hit by this swing
var hp = 100
var maxhp = 100
var ep = 20
var maxep = 20
var str_v = 5.0
var pwr_v = 5.0
var end_v = 5.0
var exp = 0
var level = 1
var invuln = 0
var regen_t = 0
var down_t = 0
var knock = Vector2.ZERO
var knock_t = 0
var shots = []             # {x,y,dir,life,beam,dmg,crit,id}
var shot_seq = 0
var events = []            # out: {"type":"hit","enemy":id,"dmg":n,"crit":b,"kx":..,"ky":..}
var rng = RandomNumberGenerator.new()
var area = {}
# --- special moves, transformations, items (all from content/*.json)
var skills = []            # this character's moves (unlocked by level)
var skill_i = 0            # the move on the SPECIAL button
var cooldowns = {}         # move id -> ticks left
var cur = {}               # the move being done
var skill_t = 0
var dash_left = 0.0
var forms = []             # this character's transformations
var form_i = -1            # -1: normal
var pending_form = -1
var base_set = 60
var drain_t = 0
var pvp = false            # PVP mode (a save point, R2): other PVP players can hurt you, and you them
var shape_set = -1         # drawn as another sprite set for a moment (Yamcha's wolf during the Wolf Fang Fist)
var barrier_t = 0          # the Android Barrier: ticks left (ki drains while it is up)
var barrier_col = 0
var buffs = {}             # "str"/"pwr"/"end"/"speed"/"exp" -> [mult, ticks]
var inv = {}               # item id -> count
var zeni = 0
var quick = ""             # the item on the ITEM button
var fx = []                # [type, x, y, r, color(int), t, life] effects drawn for everyone
var prev = {}              # last tick's buttons (for presses)
var sp_held = false        # the SPECIAL button is held now (a beam stays out while it is)
var rom_release = -1       # the tick of the special the button was let go (-1: still held)
var buf_sp = 0
var buf_tr = 0
var running = false
var tap_dir = -1           # double-tap a direction to run
var tap_run = false        # running from a double tap: until you stop
var sprint_latch = false   # L3 clicked: sprinting (or a flying boost) until you stop moving
var fly_was_moving = false
var tap_t = 99
var was_moving = false
var flying = false         # FREE PLAY: L2 flies over everything (nothing blocks you, you are drawn above it all); L2 again lands
var can_fly = true
var _fly_prev = false
const A_FLY = 12           # the sets' row 12: the hero flat out, flying
var equip = {}             # slot -> gear id (worn)
var quests = {}            # mission id -> progress
var qdone = []             # missions finished (that don't repeat)
var scene_pose = -1        # a story scene's pose (-1: none) - EVENTS pose / move steps
var scene_t = 0
var scene_loop = false
var scene_speed = 6
var scene_dir = -1
var states = {}            # states.json id -> ticks left (-1: until something takes it away)
var state_t = 0

func setup(character: int, levels: Array) -> void:
	ch = character
	name = Assets.CHARACTERS[ch]
	set_id = Assets.character_set(ch)
	var f = Assets.hero_stats(ch)
	maxhp = int(f["maxhp"]); hp = maxhp
	maxep = int(f["maxep"]); ep = maxep
	str_v = float(f["str"]); pwr_v = float(f["pwr"]); end_v = float(f["end"])
	exp = 0
	level = Rules.level_of(exp, levels)
	rng.randomize()
	base_set = set_id
	skills = Content.skills_for(ch)
	forms = Content.forms_for(ch)

var where = {}
var flags = {}             # the story so far (DEV TOOLS - EVENTS): flag name -> true, "event:<id>" once played             # the world and the place this fighter was last in: {world, node, x, y}

func to_save() -> Dictionary:
	return {"ch": ch, "maxhp": maxhp, "maxep": maxep, "str": str_v, "pwr": pwr_v, "end": end_v, "exp": exp, "level": level,
		"inv": inv, "zeni": zeni, "skill": skill_i, "quick": quick, "equip": equip, "quests": quests, "qdone": qdone, "flags": flags,
		"states": states.duplicate(), "where": where}

func from_save(d: Dictionary) -> void:
	maxhp = int(d.get("maxhp", maxhp)); hp = maxhp
	maxep = int(d.get("maxep", maxep)); ep = maxep
	str_v = float(d.get("str", str_v)); pwr_v = float(d.get("pwr", pwr_v)); end_v = float(d.get("end", end_v))
	exp = int(d.get("exp", 0)); level = int(d.get("level", 1))
	# (v44: the levels end at 50 as in the original, each twice the EXP, 3 points a level - a saved hero keeps their
	# level (above 50: 50), with the EXP and the strength that level has now)
	var lt = Assets.data.get("levels")
	if lt is Array and not lt.is_empty():
		level = clampi(level, 1, lt.size())
		if Rules.level_of(exp, lt) < level:
			exp = int(lt[level - 1])
		var hs = Assets.hero_stats(ch)
		str_v = maxf(str_v, float(hs["str"]) + level - 1)
		pwr_v = maxf(pwr_v, float(hs["pwr"]) + level - 1)
		end_v = maxf(end_v, float(hs["end"]) + level - 1)
	flags = d.get("flags", {}) if d.get("flags") is Dictionary else {}
	where = d.get("where", {}) if d.get("where") is Dictionary else {}
	states = {}
	var dst = d.get("states", {})
	if dst is Dictionary:
		for k in dst:
			if not Content.state(str(k)).is_empty():
				states[str(k)] = int(dst[k])
	inv = {}
	var di = d.get("inv", {})
	if di is Dictionary:
		for k in di:
			inv[str(k)] = int(di[k])
	zeni = int(d.get("zeni", 0))
	skill_i = int(d.get("skill", 0))
	quick = str(d.get("quick", ""))
	equip = {}
	var de = d.get("equip", {})
	if de is Dictionary:
		for k in de:
			equip[str(k)] = str(de[k])
	quests = {}
	var dq = d.get("quests", {})
	if dq is Dictionary:
		for k in dq:
			quests[str(k)] = int(dq[k])
	qdone = []
	for q in d.get("qdone", []):
		qdone.append(str(q))
	for k in flags:
		if str(k).begins_with("form:") and _form_index(str(k).substr(5)) < 0 and not Content.form_by_id(str(k).substr(5)).is_empty():
			forms.append(Content.form_by_id(str(k).substr(5)).duplicate(true))

func add_exp(n: int, levels: Array) -> bool:
	exp += n
	var L = Rules.level_of(exp, levels)
	var up = false
	while level < L:
		level += 1
		up = true
		# a level: more health and energy, a little stronger in everything
		maxhp += maxi(4, roundi(maxhp * 0.08))
		maxep += 1 if level % 2 == 0 else 0
		str_v += 1.0; pwr_v += 1.0; end_v += 1.0      # the original's 3 points a level (spread evenly)
	if up:
		hp = maxhp
		ep = maxep
	return up

func busy() -> bool:
	return state in ["attack", "rush", "ki", "skill", "transform", "hurt", "down"]

# ------------------------------------------------------------------ strength with forms and power-ups
func form() -> Dictionary:
	return forms[form_i] if form_i >= 0 and form_i < forms.size() else {}

func _mult(k: String) -> float:
	var m = float(form().get(k, 1.0))
	if buffs.has(k):
		m *= float(buffs[k][0])
	for id in states:
		m *= float(Content.state(id).get(k, 1.0))
	return m

# ------------------------------------------------------------------ states (poison, slow, blind... content/states.json)
## put a state on (seconds: -1 = its own length; 0 = until taken away)
func add_state(id: String, seconds: float = -1.0) -> bool:
	var st = Content.state(id)
	if st.is_empty() or state == "down":
		return false
	var secs = float(st.get("seconds", 10)) if seconds < 0 else seconds
	var fresh = not states.has(id)
	states[id] = -1 if secs <= 0 else roundi(secs * 60)
	if fresh:
		events.append({"type": "pop", "text": str(st.get("msg", st.get("name", id))), "color": Content.color(st.get("color", "ffffff"))})
		if str(st.get("form", "")) != "":
			force_form(str(st["form"]))
	return true

func remove_state(id: String, quiet: bool = false) -> void:
	if not states.has(id):
		return
	states.erase(id)
	var st = Content.state(id)
	if not quiet:
		events.append({"type": "msg", "text": "%s WORE OFF" % str(st.get("name", id))})
	if str(st.get("form", "")) != "" and str(form().get("id", "")) == str(st["form"]):
		_revert()

func clear_states() -> void:
	for id in states.keys():
		remove_state(id, true)

func has_state_flag(k: String) -> bool:
	for id in states:
		if bool(Content.state(id).get(k, false)):
			return true
	return false

func _step_states() -> void:
	if states.is_empty():
		return
	state_t += 1
	var sec = state_t % 60 == 0
	for id in states.keys():
		var st = Content.state(id)
		if sec and state != "down":
			var dh = int(st.get("hp_per_sec", 0))
			if dh != 0:
				hp = clampi(hp + dh, 0 if bool(st.get("can_kill", false)) else 1, maxhp)
				events.append({"type": "pop", "text": ("+%d" % dh) if dh > 0 else str(dh), "color": Content.color(st.get("color", "ffffff"))})
				if hp <= 0:
					take_hit(0, 0.0, 0.0)
					hp = 0; state = "down"; down_t = Rules.DOWN_TICKS; set_anim(Rules.A_DOWN)
			var de = int(st.get("ep_per_sec", 0))
			if de != 0:
				ep = clampi(ep + de, 0, maxep)
		if int(states[id]) > 0:
			states[id] = int(states[id]) - 1
			if int(states[id]) <= 0:
				remove_state(id)

## what states do to the buttons: can't act, no ki, no transforming, left and right swapped
func _gate(inp: Dictionary) -> Dictionary:
	if states.is_empty():
		return inp
	var o = inp.duplicate()
	if has_state_flag("stun"):
		return {}
	if has_state_flag("no_ki"):
		o["b"] = false; o["sp"] = false
	if has_state_flag("no_transform"):
		o["tr"] = false
	if has_state_flag("confuse"):
		var l = o.get("left", false); o["left"] = o.get("right", false); o["right"] = l
		var u = o.get("up", false); o["up"] = o.get("down", false); o["down"] = u
	return o

func state_tint() -> Color:
	var c = Color(1, 1, 1)
	for id in states:
		var st = Content.state(id)
		if st.has("tint"):
			c *= Content.color(st["tint"])
	return c

func gear_bonus(k: String) -> float:
	var t = 0.0
	for sl in equip:
		t += float(Content.item(str(equip[sl])).get(k, 0.0))
	return t

func eff_str() -> float:
	return (str_v + gear_bonus("str")) * _mult("str")

func eff_pwr() -> float:
	return (pwr_v + gear_bonus("pwr")) * _mult("pwr")

func eff_end() -> float:
	return (end_v + gear_bonus("end")) * _mult("end")

func speed() -> float:
	return Rules.WALK_SPEED * (_mult("speed") + gear_bonus("speed"))

func exp_mult() -> float:
	return (float(buffs["exp"][0]) if buffs.has("exp") else 1.0) * (1.0 + gear_bonus("exp"))

## wear a piece of gear (the old one goes back in the bag)
func wear(id: String) -> String:
	var g = Content.item(id)
	if not g.has("slot"):
		return "THAT IS NOT GEAR"
	if level < int(g.get("level", 1)):
		return "NEEDS LEVEL %d" % int(g.get("level", 1))
	if int(inv.get(id, 0)) <= 0:
		return "YOU DON'T HAVE IT"
	var sl = str(g["slot"])
	if equip.has(sl):
		inv[equip[sl]] = int(inv.get(equip[sl], 0)) + 1
	inv[id] = int(inv[id]) - 1
	if inv[id] <= 0:
		inv.erase(id)
	equip[sl] = id
	_sfx("item")
	return "WEARING " + str(g["name"])

func take_off(sl: String) -> void:
	if equip.has(sl):
		inv[equip[sl]] = int(inv.get(equip[sl], 0)) + 1
		equip.erase(sl)

## a friend helps you up where you lie
func revive_here() -> void:
	clear_states()
	hp = maxi(1, maxhp / 2)
	ep = maxi(ep, maxep / 2)
	state = "idle"
	invuln = 120
	set_anim(Rules.A_IDLE)

func unlocked_skills() -> Array:
	var out = []
	for sk in skills:
		if level >= int(sk.get("level", 1)):
			out.append(sk)
	return out

## a move grows with its hero: every 10 levels after it was learned, one step more (7 steps: full at 70 levels on)
const GROW_STEPS = 4      # (full length 40 levels after a beam is learned: the levels end at 50)
func skill_growth(sk: Dictionary) -> float:
	return clampf(float((level - int(sk.get("level", 1))) / 10) / GROW_STEPS, 0.0, 1.0)

## how far a beam reaches: short when it is learned (the game's own 56 px), up to a quarter past its full range
const BEAM_SHORT = 64.0
const BEAM_DRAIN_TICKS = 20      # a held beam eats a point of ki this often
func beam_reach(sk: Dictionary, short: float = -1.0) -> float:
	if short < 0.0:      # a beam drawn by the port: most of its range when learned (the great beams come late), growing past it
		short = float(sk.get("range", 240)) * 0.8
	return lerpf(short, float(sk.get("range", 240)) * 1.25, skill_growth(sk))

## how big a ball is: its own size when it is learned, up to twice that (never past the Supernova's huge 30)
const BALL_MAX = 30.0
func ball_scale(sk: Dictionary, base: float) -> float:
	return 1.0      # (balls keep their size: the villains' are big already)
	@warning_ignore("unreachable_code")
	return minf(1.0 + skill_growth(sk), maxf(1.0, BALL_MAX / maxf(1.0, base)))

## ki comes back faster as you grow, as in the game: a full bar takes about 50 s at level 1, 15 s at level 25,
## 4 s at level 50 (it feels instant), never more than 2 s beyond that
func regen_ticks() -> int:
	var full_s = maxf(2.0, 50.0 * exp(-0.0515 * float(level - 1)))
	return maxi(1, roundi(full_s * 60.0 / maxf(1.0, float(maxep))))

func current_skill() -> Dictionary:
	var u = unlocked_skills()
	if u.is_empty():
		return {}
	return u[clampi(skill_i, 0, u.size() - 1)]

## the forms on the TRANSFORM button: "unlock" level (from its level), reward (a mission or event gives it -
## and its level), event (never on the button: only events, moves and states put you in it)
func form_open(f: Dictionary) -> bool:
	match str(f.get("unlock", "level")):
		"event":
			return false
		"reward":
			return flags.has("form:" + str(f.get("id", ""))) and level >= int(f.get("level", 1))
	return level >= int(f.get("level", 1))

func unlocked_forms() -> Array:
	var out = []
	for i in forms.size():
		if form_open(forms[i]):
			out.append(i)
	return out

## a form given by a mission or an event: on the TRANSFORM button from now on
func unlock_form(id: String) -> bool:
	if Content.form_by_id(id).is_empty():
		return false
	var fresh = not flags.has("form:" + id)
	flags["form:" + id] = true
	if fresh and _form_index(id) < 0:
		forms.append(Content.form_by_id(id).duplicate(true))     # (another hero's form: this one can use it too)
	return fresh

func lock_form(id: String) -> void:
	flags.erase("form:" + id)
	if str(form().get("id", "")) == id:
		_revert()

func _form_index(id: String) -> int:
	for i in forms.size():
		if str(forms[i].get("id", "")) == id:
			return i
	return -1

## straight into a form (an event, a move, a state) - with the transformation, whether it is unlocked or not
func force_form(id: String) -> bool:
	var i = _form_index(id)
	if i < 0:
		var f = Content.form_by_id(id)
		if f.is_empty():
			return false
		forms.append(f.duplicate(true))
		i = forms.size() - 1
	if i == form_i or state == "down":
		return i == form_i
	pending_form = i
	state = "transform"
	skill_t = 0
	var tf_frames = Assets.sprite_set(set_id).get("slots", [])
	game_tf = int(forms[i].get("set", -1)) > 0 and tf_frames.size() > Rules.A_TRANSFORM * 4 and tf_frames[Rules.A_TRANSFORM * 4].size() >= 3
	set_anim(_anim_or(Rules.A_TRANSFORM, _anim_or(Rules.A_CHARGE, Rules.A_IDLE)))
	if not game_tf:
		_sfx("transform")
	return true

func _stat_of(sk: Dictionary) -> float:
	return eff_pwr() if str(sk.get("stat", "pwr")) == "pwr" else eff_str()

func _col(sk: Dictionary) -> int:
	return Content.color(sk.get("color", "ffffff")).to_rgba32()

func _sfx(n: String) -> void:
	events.append({"type": "sfx", "name": n})

func _anim_or(a: int, alt: int) -> int:
	return a if _frame_count(a) > 0 else alt

## the pose a move uses, from the fighter's own sprite set (rows of the game's sets):
## 18 the beam (Kamehameha: hands at the hip, then the release), 19 the overhead throw (Spirit Bomb, Hellzone),
## 20 flying, 5 the ki throw (for fighters without a beam row); a move may name its own row ("anim")
## the hand of a pose, from the sprite (where blasts and beams leave from)
## the eyes (a beam shot from the eyes - Cooler's): near the top of the body, a little toward where it looks
func _eyes() -> Vector2:
	return Assets.eye_point(set_id, anim, dir) * size_scale()

func hand(a: int) -> Vector2:
	return Assets.hand_point(set_id, a, dir) * size_scale()

func _pose(sk: Dictionary, kind: String) -> int:
	if sk.has("anim") and _frame_count(int(sk["anim"])) > 0:
		return int(sk["anim"])
	var order = {"beam": [18, 5], "bomb": [19, 18, 5], "volley": [19, 5], "dash": [20, Rules.A_RUSH]}.get(kind, [Rules.A_KI])
	for a in order:
		if _frame_count(a) > 0:
			return a
	return Rules.A_KI

## charge on the pose's first frame, then its other frames once (the release), holding the last
func _pose_frame(a: int, charging: bool, since_fire: int) -> void:
	if anim != a:
		anim = a
		anim_t = 0
	var n = maxi(1, _frame_count(a))
	frame = 0 if charging or n == 1 else mini(1 + since_fire / 4, n - 1)

func set_anim(a: int) -> void:
	if a != anim:
		anim = a
		anim_t = 0
		frame = 0

## the game has two levels of ground (1 = low, 2 = raised: bridges, cliff tops; 3 = both, where you step
## from one to the other): you stay on your level until you pass over a tile that has both
var lay = 3
func _under(px: float, py: float) -> int:
	return Assets.walk_at(area, px - 5, py) & Assets.walk_at(area, px + 4, py) & Assets.walk_at(area, px - 5, py - 4) & Assets.walk_at(area, px + 4, py - 4)

func can_stand(px: float, py: float) -> bool:
	if area.is_empty():
		return true
	return (_under(px, py) & lay) != 0

var fly_boost = false      # Y held while flying: twice as fast
func _fly_step(mx: int, my: int) -> void:
	if mx != 0 or my != 0:
		if mx != 0:            # flying: any sideways push turns the hero side-on (the flying pose), even on a diagonal
			dir = 3 if mx > 0 else 2
		else:
			dir = 0 if my > 0 else 1
		var spd = speed() * 2.2 * (2.0 if fly_boost else 1.0)
		if mx != 0 and my != 0:
			spd *= 0.7071
		x += mx * spd
		y += my * spd
		if not area.is_empty():
			x = clampf(x, 8.0, float(area["w"]) - 8.0)
			y = clampf(y, 16.0, float(area["h"]) - 4.0)
	state = "fly"
	if _frame_count(A_FLY) > 0:
		set_anim(A_FLY)
		_animate([8], true)
	else:
		set_anim(Rules.A_IDLE)
		_animate([240, 15], true)
	regen_t += 1
	if regen_t >= regen_ticks():
		regen_t = 0
		ep = mini(maxep, ep + 1)

## come down on the nearest ground you can stand on
func _land() -> void:
	flying = false
	state = "idle"
	set_anim(Rules.A_IDLE)
	if area.is_empty() or can_stand(x, y):
		return
	for r in range(4, 400, 4):
		for k in 16:
			var a = TAU * k / 16.0
			var px = x + cos(a) * r; var py = y + sin(a) * r
			if px > 8 and py > 16 and px < float(area["w"]) - 8 and py < float(area["h"]) - 4 and can_stand(px, py):
				place_at(px, py)
				return

func move_by(dx: float, dy: float) -> void:
	if dx != 0.0 and can_stand(x + dx, y):
		x += dx
	if dy != 0.0 and can_stand(x, y + dy):
		y += dy
	if not area.is_empty():
		var u = _under(x, y)
		lay = 3 if u == 3 else (lay & u if (lay & u) != 0 else lay)

## put somewhere new (a way in, a revive, a warp): on whatever level is there
func place_at(px: float, py: float) -> void:
	x = px
	y = py
	var u = _under(px, py) if not area.is_empty() else 3
	lay = u if u != 0 else 3

## input: {up,down,left,right,a,b} held this tick; enemies: [{id,x,y,alive,big}]
func step(inp: Dictionary, enemies: Array) -> void:
	events.clear()
	_step_states()
	inp = _gate(inp)
	if scene_pose >= 0 and state != "down":
		# a story scene moves this fighter: a pose played (or held on its last frame), nothing else
		scene_t += 1
		var nfr = maxi(1, _frame_count(scene_pose))
		anim = scene_pose
		var k = scene_t / maxi(1, scene_speed)
		frame = k % nfr if scene_loop else mini(k, nfr - 1)
		if scene_dir >= 0:
			dir = scene_dir
		return
	since_attack += 1
	if invuln > 0:
		invuln -= 1
	for k in cooldowns.keys():
		cooldowns[k] -= 1
		if cooldowns[k] <= 0:
			cooldowns.erase(k)
	if barrier_t > 0:
		barrier_t -= 1
		if barrier_t % 30 == 0:
			ep = maxi(0, ep - 1)
		if ep <= 0 or barrier_t <= 0:
			barrier_t = 0
			buffs.erase("end")
	for k in buffs.keys():
		buffs[k][1] -= 1
		if buffs[k][1] <= 0:
			buffs.erase(k)
			events.append({"type": "msg", "text": "%s WORE OFF" % {"str": "POWER", "pwr": "SPIRIT", "end": "IRON SKIN", "speed": "SPEED", "exp": "TRAINING"}.get(k, k.to_upper())})
	for e in fx:
		e[5] += 1
	fx = fx.filter(func(e): return e[5] < e[6])
	if form_i >= 0:
		drain_t += 1
		if drain_t >= int(form().get("drain_ticks", 90)):
			drain_t = 0
			ep -= 1
			if ep <= 0:
				ep = 0
				_revert()
				events.append({"type": "msg", "text": "OUT OF ENERGY - BACK TO NORMAL"})
	_step_shots(enemies)
	if knock_t > 0:
		knock_t -= 1
		move_by(knock.x, knock.y)
	if state == "down":
		down_t -= 1
		_animate([30, 30, 30, 30], false)
		return
	if state == "hurt":
		_animate([4, 4, 4, 4], false)
		if anim_t >= Rules.HURT_TICKS:
			state = "idle"
			set_anim(Rules.A_IDLE)
		return
	var mx = int(inp.get("right", false)) - int(inp.get("left", false))
	var my = int(inp.get("down", false)) - int(inp.get("up", false))
	var fly_now = bool(inp.get("fly", false))
	var fly_press = fly_now and not _fly_prev
	_fly_prev = fly_now
	if fly_press and (flying or (can_fly and state in ["idle", "walk"])):
		if flying:
			_land()
		else:
			flying = true
			events.append({"type": "msg", "text": "FLYING - L2/B TO LAND, Y TO BOOST"})
	if flying:
		if not can_fly:
			_land()
		else:
			if inp.get("b", false) and not prev.get("b", false):      # B lands too
				prev = inp.duplicate()
				_land()
				return
			if inp.get("l3", false) and not prev.get("l3", false):
				sprint_latch = true
			var fly_moving = mx != 0 or my != 0
			if fly_was_moving and not fly_moving:
				sprint_latch = false      # stopped: back to normal speed
			fly_was_moving = fly_moving
			fly_boost = bool(inp.get("tr", false)) or sprint_latch      # Y held, or L3 clicked: a flying sprint
			if inp.get("nx", false) and not prev.get("nx", false):      # the next special can be chosen up there too
				var fu = unlocked_skills()
				if fu.size() > 0:
					skill_i = (clampi(skill_i, 0, fu.size() - 1) + 1) % fu.size()
					events.append({"type": "msg", "text": "SPECIAL: " + str(fu[skill_i]["name"])})
					_sfx("move")
			prev = inp.duplicate()
			_fly_step(mx, my)
			return
	var a_now: bool = inp.get("a", false)
	var b_now: bool = inp.get("b", false)
	var a_press = a_now and a_hold == 0
	var b_press = b_now and b_hold == 0
	var b_release = (not b_now) and b_hold > 0
	a_hold = a_hold + 1 if a_now else 0
	b_hold = b_hold + 1 if b_now else 0
	var sp_press = inp.get("sp", false) and not prev.get("sp", false)
	var tr_press = inp.get("tr", false) and not prev.get("tr", false)
	if inp.get("l3", false) and not prev.get("l3", false):
		sprint_latch = true      # L3 clicked: sprint until you stop moving
	# a SPECIAL / TRANSFORM pressed in the middle of a punch is remembered for a moment (no lost presses)
	if sp_press: buf_sp = 20
	if tr_press: buf_tr = 20
	if busy():
		buf_sp = maxi(0, buf_sp - 1); buf_tr = maxi(0, buf_tr - 1)
	else:
		sp_press = sp_press or buf_sp > 0
		tr_press = tr_press or buf_tr > 0
		buf_sp = 0; buf_tr = 0
	var it_press = inp.get("it", false) and not prev.get("it", false)
	var nx_press = inp.get("nx", false) and not prev.get("nx", false)
	prev = inp.duplicate()
	sp_held = bool(inp.get("sp", false))
	if nx_press:
		var u = unlocked_skills()
		if u.size() > 0:
			skill_i = (clampi(skill_i, 0, u.size() - 1) + 1) % u.size()
			events.append({"type": "msg", "text": "SPECIAL: " + str(u[skill_i]["name"])})
			_sfx("move")
	if it_press and state != "down":
		use_item(quick if inv.get(quick, 0) > 0 else _first_item())

	match state:
		"attack":
			_attack_hits(enemies, 1.0 if anim != Rules.A_KICK else 2.0, 34.0)
			_animate([Rules.PUNCH_FRAME_TICKS], false)
			if anim_t >= Rules.PUNCH_TICKS:
				state = "idle"; since_attack = 0
				set_anim(Rules.A_IDLE)
			return
		"rush":
			move_by(Rules.dir_vec(dir).x, Rules.dir_vec(dir).y)
			_attack_hits(enemies, 1.5, 26.0)
			_animate([4], false)
			if anim_t >= Rules.RUSH_TICKS:
				state = "idle"; since_attack = 0
				set_anim(Rules.A_IDLE)
			return
		"ki":
			if anim_t == Rules.KI_FIRE_AT:
				_fire(false)
			_animate([8, 16, 8], false)
			if anim_t >= Rules.KI_TICKS:
				state = "idle"; since_attack = 0
				set_anim(Rules.A_IDLE)
			return
		"skill":
			_step_skill(enemies)
			return
		"transform":
			skill_t += 1
			if game_tf:
				# the game's own transformation: facing you, hands to the head, then the power breaks out
				# (frames of the hero's own sprite set, timed as in the game)
				dir = 0
				invuln = maxi(invuln, 2)
				var acc = 0
				for st in TF_SEQ:
					acc += int(st[1])
					if skill_t <= acc:
						anim = Rules.A_TRANSFORM
						frame = mini(int(st[0]), _frame_count(Rules.A_TRANSFORM) - 1)
						break
				if skill_t == 2:
					_sfx("transform")
				var total = 0
				for st2 in TF_SEQ:
					total += int(st2[1])
				if skill_t >= total:
					_apply_form(pending_form)
					state = "idle"
					set_anim(Rules.A_IDLE)
				return
			_animate([6], true)
			invuln = maxi(invuln, 2)
			if skill_t == 30:
				_apply_form(pending_form)
			if skill_t >= 42:
				state = "idle"
				set_anim(Rules.A_IDLE)
			return

	# free: attacks first
	if a_press:
		combo = combo + 1 if since_attack <= Rules.CHAIN_WINDOW else 0
		combo %= Rules.CHAIN.size()
		_start_attack(Rules.CHAIN[combo])
		return
	if a_now and a_hold >= Rules.RUSH_HOLD and state != "rush":
		state = "rush"
		hit_done.clear()
		set_anim(Rules.A_RUSH)
		return
	if b_press:
		if ep >= Rules.KI_COST:
			ep -= Rules.KI_COST
			state = "ki"
			set_anim(Rules.A_KI)
			regen_t = 0
		return
	if sp_press:
		start_skill(current_skill())
		return
	if tr_press:
		_transform_next()
		return
	if mx != 0 or my != 0:
		if mx != 0 and my == 0:
			dir = 3 if mx > 0 else 2
		elif my != 0 and mx == 0:
			dir = 0 if my > 0 else 1
		elif not ((dir == 3 and mx > 0) or (dir == 2 and mx < 0) or (dir == 0 and my > 0) or (dir == 1 and my < 0)):
			dir = 3 if mx > 0 else 2
		# run: hold RUN, or tap a direction twice quickly (the run cycle is the sets' row 13)
		var cur_dir = dir
		if not was_moving:
			tap_run = tap_dir == cur_dir and tap_t < 14
			tap_dir = cur_dir
			tap_t = 0
		running = inp.get("run", false) or tap_run or sprint_latch      # RUN held, R2's sprint on, or L3 clicked (until you stop)
		var spd = speed() * (1.75 if running else 1.0)
		if running and (mx == 0 or my == 0):
			spd *= 1.4142      # running straight is as fast as running on a diagonal (both directions at once)
		move_by(mx * spd, my * spd)
		state = "walk"
		idle_t = 0
		if running and _frame_count(13) > 0:
			set_anim(13)
			_animate([5], true)
		else:
			set_anim(Rules.A_WALK)
			_animate([6 if running else 8], true)
		was_moving = true
	else:
		state = "idle"
		idle_t += 1
		if was_moving:
			was_moving = false
			running = false
			sprint_latch = false
		tap_t += 1
		if idle_t > 1000:
			set_anim(Rules.A_BORED)
			_animate([32], true)
		else:
			set_anim(Rules.A_IDLE)
			_animate([240, 15], true)
	regen_t += 1
	if regen_t >= regen_ticks():
		regen_t = 0
		ep = mini(maxep, ep + 1)

func _start_attack(a: int) -> void:
	_sfx("kick" if a == Rules.A_KICK else "punch")
	state = "attack"
	hit_done.clear()
	set_anim(a)
	idle_t = 0

## frame timings: per-frame tick counts (the last one repeats)
func _animate(ticks: Array, loop: bool) -> void:
	anim_t += 1
	var t = anim_t
	var f = 0
	var acc = 0
	var n = 64
	while true:
		var d: int = ticks[mini(f, ticks.size() - 1)]
		if t < acc + d:
			break
		acc += d
		f += 1
		if f >= n:
			break
	frame = f
	if loop:
		# wrap over the number of frames this animation has (the view knows it; 4 is the usual)
		var cnt = _frame_count(anim)
		if cnt > 0:
			var total = 0
			for i in cnt:
				total += int(ticks[mini(i, ticks.size() - 1)])
			if total > 0 and anim_t >= total:
				anim_t = 0
			frame = f % cnt

func _frame_count(a: int) -> int:
	var s = Assets.sprite_set(set_id)
	if s.is_empty():
		return 4
	var slots: Array = s["slots"]
	var k = a * 4 + dir
	return slots[k].size() if k < slots.size() else 0

func _attack_hits(enemies: Array, mult: float, reach: float) -> void:
	var fwd = Rules.dir_vec(dir)
	for e in enemies:
		if not e["alive"] or hit_done.has(e["id"]):
			continue
		var d = Vector2(e["x"] - x, e["y"] - y)
		var along = d.dot(fwd)
		var side = absf(d.dot(Vector2(fwd.y, -fwd.x)))
		var big: bool = e.get("big", false)
		if along > -6 and along < reach + (12.0 if big else 0.0) and side < (16.0 if not big else 26.0):
			hit_done[e["id"]] = true
			var r = Rules.melee_damage(eff_str(), mult, rng)
			events.append({"type": "hit", "enemy": e["id"], "dmg": r[0], "crit": r[1], "kx": fwd.x * 6.0, "ky": fwd.y * 6.0})

func _fire(beam: bool) -> void:
	var v = Rules.dir_vec(dir)
	shot_seq += 1
	var r = Rules.ki_damage(eff_pwr(), 3.0 if beam else 1.0, rng)
	var hp0 = hand(Rules.A_KI)
	shots.append({"id": shot_seq, "inf": {}, "x": x + hp0.x, "y": y + hp0.y, "dir": dir, "life": Rules.KI_LIFE, "beam": beam, "dmg": r[0], "crit": r[1], "hit": {},
		"kind": 0, "vx": v.x * Rules.KI_SPEED, "vy": v.y * Rules.KI_SPEED, "col": 0, "w": 0, "ox": 0.0, "oy": 0.0, "pierce": false})
	_sfx("ki")

var skill_inflict = {}     # the last move's "inflict" (its blasts carry it when they hit)
func _step_shots(enemies: Array) -> void:
	for s0 in shots:
		if not s0.has("inf"):
			s0["inf"] = skill_inflict
	var keep = []
	for s in shots:
		var kind0 = int(s.get("kind", 0))
		if kind0 >= 5:
			if _step_rom_shot(s, enemies):
				keep.append(s)
			continue
		if kind0 == 1 and s.has("hold"):
			# a beam: shoots out, then stays at full length for a moment (pulsing, hitting again), then fades
			s["tick"] = int(s["tick"]) + 1
			if s["life"] > 0:
				s["x"] += s["vx"]; s["y"] += s["vy"]
				s["life"] -= 1
				s["w"] = minf(float(s["w0"]), float(s["w"]) + float(s["w0"]) * 0.08)
			elif s["hold"] > 0:
				# held: the beam stays as long as the button is held and there is ki to feed it (a point every third of a second)
				if sp_held and ep > 0 and s.get("feeding", true):
					s["hold"] = maxi(int(s["hold"]), 9)
					s["fed"] = int(s.get("fed", 0)) + 1
					if int(s["fed"]) % BEAM_DRAIN_TICKS == 0:
						ep = maxi(0, ep - 1)
				elif s.get("feeding", true):
					s["feeding"] = false      # let go (or out of ki): it ends soon after
					s["hold"] = mini(int(s["hold"]), 8)
				s["hold"] -= 1
				s["w"] = float(s["w0"]) * (1.0 + 0.12 * sin(float(s["tick"]) * 0.9))
				if int(s["hold"]) % 8 == 0:
					s["hit"] = {}                      # it keeps hurting what stands in it
					s["dmg"] = maxi(1, roundi(float(s["dmg"]) * 0.3)) if not s.get("rehit", false) else s["dmg"]
					s["rehit"] = true
				if int(s["hold"]) % 4 == 0:
					events.append({"type": "shake", "amount": 1.5})
			else:
				s["fade"] -= 1
				s["w"] = float(s["w0"]) * maxf(0.0, s["fade"] / 12.0)
			s["life_end"] = s["life"] <= 0 and s["hold"] <= 0 and s["fade"] <= 0
		else:
			s["x"] += s["vx"]
			s["y"] += s["vy"]
			s["life"] -= 1
		var gone: bool = s["life"] <= 0 if not s.has("hold") else bool(s.get("life_end", false))
		var kind = int(s.get("kind", 0))
		if not area.is_empty() and (s["x"] < -20 or s["y"] < -20 or s["x"] > area["w"] + 20 or s["y"] > area["h"] + 20):
			if kind0 == 1 and s.has("hold"):
				# a beam's head stops at the map's edge: the beam stays (held, then fading) - it does not vanish
				s["x"] = clampf(s["x"], -20.0, float(area["w"]) + 20.0); s["y"] = clampf(s["y"], -20.0, float(area["h"]) + 20.0)
				s["life"] = 0
			else:
				gone = true      # flies over low things, stops at the map's edge
		var explode = kind == 2 and gone
		for e in enemies:
			if gone and not explode:
				break
			if not e["alive"] or s["hit"].has(e["id"]):
				continue
			var big: bool = e.get("big", false)
			var rx = 18.0 if big else 11.0
			var ry = 22.0 if big else 13.0
			var touch = false
			if kind == 1:
				# a beam: anything along it, from the hands to its head
				var p0 = Vector2(s["ox"], s["oy"])
				var p1 = Vector2(s["x"], s["y"])
				var q = Vector2(e["x"], e["y"] - 10)
				var seg = p1 - p0
				var t = clampf((q - p0).dot(seg) / maxf(1.0, seg.length_squared()), 0.0, 1.0)
				touch = q.distance_to(p0 + seg * t) < float(s["w"]) / 2.0 + rx
			else:
				touch = absf(e["x"] - s["x"]) < rx + float(s.get("size", 0)) * 0.5 and absf((e["y"] - 10) - s["y"]) < ry + float(s.get("size", 0)) * 0.5
			if touch:
				if kind == 2 and not s.get("pierce", false):
					explode = true
					break
				s["hit"][e["id"]] = true
				if kind == 2 and str(s.get("look", "")) != "":      # a ball that cuts on through (the Destructo Disk): its hit at each foe
					fx.append(["xboom", e["x"], e["y"] - 10, 14.0, s["col"], 0, 16, str(s["look"]), int(s["dir"])])
				var dv = Vector2(s["vx"], s["vy"]).normalized()
				events.append({"type": "hit", "enemy": e["id"], "dmg": s["dmg"], "crit": s["crit"], "kx": dv.x * 3.0, "ky": dv.y * 3.0, "stun": int(s.get("stun", 0)), "inflict": s.get("inf", {})})
				if not s.get("pierce", false):
					gone = true
		if explode:
			var r = float(s.get("radius", 40))
			for e in enemies:
				if e["alive"] and Vector2(e["x"] - s["x"], e["y"] - 10 - s["y"]).length() < r + (14.0 if e.get("big", false) else 0.0):
					var kv = Vector2(e["x"] - s["x"], e["y"] - s["y"]).normalized() * 7.0
					events.append({"type": "hit", "enemy": e["id"], "dmg": roundi(s["dmg"] * rng.randf_range(0.9, 1.1)), "crit": s["crit"], "kx": kv.x, "ky": kv.y, "stun": 20, "inflict": s.get("inf", {})})
			if str(s.get("look", "")) != "":
				fx.append(["xboom", s["x"], s["y"], r, s["col"], 0, 26, str(s["look"])])
			else:
				fx.append(["boom", s["x"], s["y"], r, s["col"], 0, 26])
			_sfx("boom")
			gone = true
		if not gone:
			keep.append(s)
	shots = keep

# ------------------------------------------------------------------ special moves
func start_skill(sk: Dictionary) -> bool:
	if sk.is_empty():
		events.append({"type": "msg", "text": "NO SPECIAL MOVE YET"})
		return false
	var id = str(sk["id"])
	if cooldowns.has(id):
		_sfx("error")
		return false
	var cost = int(sk.get("ep", 0))
	if ep < cost:
		events.append({"type": "msg", "text": "NOT ENOUGH ENERGY"})
		_sfx("error")
		return false
	ep -= cost
	regen_t = 0
	cooldowns[id] = int(sk.get("cooldown", 60))
	cur = sk
	skill_inflict = sk.get("inflict", {}) if sk.get("inflict") is Dictionary else {}
	if str(sk.get("self_state", "")) != "":
		add_state(str(sk["self_state"]))
	skill_t = 0
	hit_done.clear()
	state = "skill"
	idle_t = 0
	dash_left = float(sk.get("range", 100))
	rom_release = -1
	if sk.has("rom") and not Content.rom_specials.get(str(sk["rom"]), {}).is_empty():
		_sfx("beam_charge")
		return true
	match str(sk.get("type", "")):
		"beam":
			_pose_frame(_pose(sk, "beam"), true, 0)
			_sfx("beam_charge")
		"bomb":
			_pose_frame(_pose(sk, "bomb"), true, 0)
			_sfx("beam_charge")
		"volley":
			_pose_frame(_pose(sk, "volley"), true, 0)
		"dash":
			shape_set = int(sk.get("shape_set", -1))
			set_anim(int(sk.get("shape_anim", 1)) if shape_set >= 0 else _pose(sk, "dash"))
			invuln = maxi(invuln, int(dash_left / maxf(1.0, float(sk.get("speed", 4)))) + 6)
			_sfx(str(sk.get("sfx", "dash")))
		"slash":
			set_anim(_anim_or(Rules.A_PUNCH2, Rules.A_PUNCH1))
			_sfx(str(sk.get("sfx", "slash")))
		"stretch":
			set_anim(Rules.A_PUNCH1)
		_:
			set_anim(_anim_or(Rules.A_CHARGE, Rules.A_IDLE))
	return true

func _skill_done() -> void:
	shape_set = -1
	draw_dx = 0
	state = "idle"
	since_attack = 0
	var then = str(cur.get("then_form", ""))
	cur = {}
	set_anim(Rules.A_IDLE)
	if then != "":
		force_form(then)       # (a move that ends in a transformation)

func _step_skill(enemies: Array) -> void:
	skill_t += 1
	if cur.has("rom"):
		_step_rom(enemies)
		return
	var sk = cur
	var t = skill_t
	var fwd = Rules.dir_vec(dir)
	var col = _col(sk)
	var power = float(sk.get("power", 1.0))
	var kind = str(sk.get("type", ""))
	match kind:
		"beam":
			var ch_t = int(sk.get("charge", 30))
			var pa = _pose(sk, "beam")
			_pose_frame(pa, t < ch_t, t - ch_t)
			if t < ch_t:
				var hc = _eyes() if str(sk.get("from", "")) == "eyes" else Assets.charge_point(set_id, pa, dir) * size_scale()
				var look = str(sk.get("look", ""))
				if str(sk.get("from", "")) == "eyes":
					pass                # an eye beam: no glow on the face, the beam just leaves the eye
				elif look != "" and t % 2 == 0:
					# the game's own energy gathering at the hands
					fx.append(["xcharge", x + hc.x, y + hc.y, float(t) / ch_t, col, 0, 3, look])
				elif t % 3 == 0:
					fx.append(["glow", x + hc.x, y + hc.y, 1.5 + 4.5 * t / ch_t + rng.randf_range(-0.6, 0.6), col, 0, 4])
				if t % 5 == 0 and str(sk.get("from", "")) != "eyes":
					fx.append(["gather", x + hc.x, y + hc.y, 26.0, col, 0, 14, rng.randi_range(0, 7)])
				if t > ch_t - 12 and t % 4 == 0:
					events.append({"type": "shake", "amount": 1.0})
				return
			if t == ch_t:
				var sp = float(sk.get("speed", 6))
				var r = Rules.ki_damage(_stat_of(sk), power, rng)
				shot_seq += 1
				var hb = _eyes() if str(sk.get("from", "")) == "eyes" else hand(pa)
				var ox = x + hb.x
				var oy = y + hb.y
				shots.append({"id": shot_seq, "x": ox, "y": oy, "ox": ox, "oy": oy, "vx": fwd.x * sp, "vy": fwd.y * sp, "dir": dir,
					"life": int(beam_reach(sk) / sp), "beam": true, "kind": 1, "dmg": r[0], "crit": r[1], "hit": {},
					"pierce": true, "w": float(sk.get("width", 10)) * 0.6, "w0": float(sk.get("width", 10)), "col": col,
					"hold": int(sk.get("hold", 40)), "fade": 12, "tick": 0, "look": "eyes" if str(sk.get("from", "")) == "eyes" else str(sk.get("look", ""))})
				_sfx(str(sk.get("sfx", "beam")))
				# the release: a flash at the hands (not on the face for an eye beam) and a hard shake
				if str(sk.get("from", "")) != "eyes":
					fx.append(["flash", ox, oy, float(sk.get("width", 10)) * 2.5, col, 0, 14])
				events.append({"type": "shake", "amount": 5.0})
			var alive = false
			for s in shots:
				if int(s.get("kind", 0)) == 1:
					alive = true
			if not alive and t > ch_t + 6:
				_skill_done()
		"bomb":
			var ch_t = int(sk.get("charge", 24))
			var bk = ball_scale(sk, float(sk.get("size", 8)))
			var bsize = float(sk.get("size", 8)) * bk
			_pose_frame(_pose(sk, "bomb"), t < ch_t, t - ch_t)
			if t < ch_t:
				var blook = str(sk.get("look", ""))
				if blook != "" and t % 2 == 0:
					# the ball grows over the head (the Spirit Bomb, Big Bang...) - the game's own sprites
					fx.append(["xcharge", x, y - (Assets.body_size(set_id).y + 6.0) * size_scale(), float(t) / ch_t, col, 0, 3, blook, bsize, float(sk.get("size", 8))])
				elif t % 4 == 0:
					fx.append(["glow", x, y - (Assets.body_size(set_id).y + 6.0) * size_scale(), 3.0 + bsize * t / ch_t, col, 0, 5])
				return
			if t == ch_t:
				var sp = float(sk.get("speed", 3))
				var r = Rules.ki_damage(_stat_of(sk), power, rng) if str(sk.get("stat", "pwr")) == "pwr" else Rules.melee_damage(_stat_of(sk), power, rng)
				shot_seq += 1
				var hbm = hand(_pose(sk, "bomb"))
				shots.append({"id": shot_seq, "x": x + hbm.x, "y": y + hbm.y, "ox": 0.0, "oy": 0.0, "vx": fwd.x * sp, "vy": fwd.y * sp, "dir": dir,
					"life": int(float(sk.get("range", 160)) / sp), "beam": false, "kind": 2, "dmg": r[0], "crit": r[1], "hit": {},
					"pierce": bool(sk.get("pierce", false)), "w": 0, "col": col, "radius": float(sk.get("radius", 40)) * bk, "size": bsize, "base": float(sk.get("size", 8)), "look": str(sk.get("look", ""))})
				_sfx("bomb")
			if t >= ch_t + 20:
				_skill_done()
		"volley":
			var n = int(sk.get("count", 5))
			_pose_frame(_pose(sk, "volley"), t < 4, (t - 4) % 12)
			if t % 6 == 1 and t / 6 < n:
				var k = t / 6
				var v = fwd
				if int(sk.get("spread", 0)) == 1:
					v = Vector2.from_angle(fwd.angle() + (k - n / 2.0) * (PI * 1.6 / n))
				var side = Vector2(-fwd.y, fwd.x) * (5.0 if k % 2 == 0 else -5.0)
				var sp = float(sk.get("speed", 3.5))
				var r = Rules.ki_damage(_stat_of(sk), power, rng)
				shot_seq += 1
				var hv = hand(_pose(sk, "volley"))
				shots.append({"id": shot_seq, "x": x + hv.x + side.x * 0.4, "y": y + hv.y + side.y * 0.4, "ox": 0.0, "oy": 0.0,
					"vx": v.x * sp, "vy": v.y * sp, "dir": dir, "life": int(float(sk.get("range", 200)) / sp), "beam": false, "kind": 0,
					"dmg": r[0], "crit": r[1], "hit": {}, "pierce": false, "w": 0, "col": col})
				_sfx("ki")
			if t >= n * 6 + 8:
				_skill_done()
		"dash":
			var sp = float(sk.get("speed", 4))
			var bx = x
			var by = y
			move_by(fwd.x * sp, fwd.y * sp)
			var moved = Vector2(x - bx, y - by).length()
			dash_left -= sp
			var dp = int(sk.get("shape_anim", 1)) if shape_set >= 0 else _pose(sk, "dash")
			if anim != dp:
				set_anim(dp)
			_animate([3], true)
			if t % 2 == 0 and sk.get("trail", true):
				fx.append(["trail", x, y, 0, col, 0, 10])
			for e in enemies:
				if e["alive"] and not hit_done.has(e["id"]) and Vector2(e["x"] - x, e["y"] - y).length() < (26.0 if not e.get("big", false) else 40.0):
					hit_done[e["id"]] = true
					var r = Rules.melee_damage(_stat_of(sk), power, rng)
					events.append({"type": "hit", "enemy": e["id"], "dmg": r[0], "crit": r[1], "kx": fwd.x * 8.0, "ky": fwd.y * 8.0, "stun": 18, "inflict": cur.get("inflict", {})})
			if dash_left <= 0 or moved < 0.2:
				_skill_done()
		"slash", "stretch":
			var at = 4 if kind == "slash" else 6
			_animate([4], false)
			if t == at:
				var reach = float(sk.get("range", 40))
				var wide = reach * 0.8 if kind == "slash" else 12.0
				for e in enemies:
					if not e["alive"]:
						continue
					var d = Vector2(e["x"] - x, e["y"] - y)
					var along = d.dot(fwd)
					var side = absf(d.dot(Vector2(fwd.y, -fwd.x)))
					var big = e.get("big", false)
					if along > -8 and along < reach + (14.0 if big else 0.0) and side < wide + (12.0 if big else 0.0):
						var r = Rules.melee_damage(_stat_of(sk), power, rng)
						events.append({"type": "hit", "enemy": e["id"], "dmg": r[0], "crit": r[1], "kx": fwd.x * 9.0, "ky": fwd.y * 9.0, "stun": 16, "inflict": cur.get("inflict", {})})
				if kind == "slash":
					fx.append(["arc", x, y - 12, reach, col, 0, 10, dir])
				else:
					fx.append(["line", x + fwd.x * 8, y - 14, reach, col, 0, 12, dir])
					_sfx("punch")
			if t >= (18 if kind == "slash" else 22):
				_skill_done()
		"wave", "flash":
			_animate([6], true)
			if t == 1 and bool(sk.get("dome", false)):
				# a solid ball at the belly that grows over the whole body, then spreads out and thins (Super Explosive Wave)
				var bd = Assets.body_size(set_id) * size_scale()
				fx.append(["dome", x, y - bd.y * 0.45, float(sk.get("range", 70)), col, 0, 40, maxf(bd.x, bd.y) * 0.6])
			if t == 10:
				var r0 = float(sk.get("range", 70))
				for e in enemies:
					if not e["alive"]:
						continue
					var d = Vector2(e["x"] - x, e["y"] - y)
					if d.length() < r0 + (14.0 if e.get("big", false) else 0.0):
						var kv = d.normalized() * 9.0
						if kind == "wave":
							var r = Rules.ki_damage(_stat_of(sk), power, rng)
							events.append({"type": "hit", "enemy": e["id"], "dmg": r[0], "crit": r[1], "kx": kv.x, "ky": kv.y, "stun": 24, "inflict": cur.get("inflict", {})})
						else:
							events.append({"type": "hit", "enemy": e["id"], "dmg": 0, "crit": false, "kx": 0.0, "ky": 0.0, "stun": int(sk.get("stun", 120)), "inflict": cur.get("inflict", {})})
				if not bool(sk.get("dome", false)):
					fx.append(["ring" if kind == "wave" else "flash", x, y - 12, r0, col, 0, 22])
				_sfx(str(sk.get("sfx", kind)))
			if t >= (40 if bool(sk.get("dome", false)) else 26):
				_skill_done()
		"heal", "buff":
			_animate([6], true)
			if t % 5 == 0:
				fx.append(["sparkle", x + rng.randf_range(-10, 10), y - rng.randf_range(4, 30), 3, col, 0, 14])
			if t == 20:
				if kind == "heal":
					var h = roundi(maxhp * float(sk.get("heal", 0.3)))
					hp = mini(maxhp, hp + h)
					events.append({"type": "pop", "text": "+%d HP" % h, "color": Color(0.4, 1, 0.5)})
				else:
					var bs = sk.get("buffs", {})
					for k in bs:
						buffs[str(k)] = [float(bs[k]), int(sk.get("ticks", 600))]
					if sk.get("barrier", false):
						barrier_t = int(sk.get("ticks", 600))
						barrier_col = Content.color(sk.get("aura", "60e0c0")).to_rgba32()
					events.append({"type": "msg", "text": str(sk.get("name", "")) + "!"})
				_sfx(str(sk.get("sfx", "heal")))
			if t >= 30:
				_skill_done()
		_:
			_skill_done()

# ------------------------------------------------------------------ transformations
func _transform_next() -> void:
	var u = unlocked_forms()
	if u.is_empty():
		if forms.size() > 0:
			events.append({"type": "msg", "text": "%s AT LEVEL %d" % [forms[0]["name"], int(forms[0].get("level", 1))]})
		else:
			events.append({"type": "msg", "text": "NO TRANSFORMATION"})
		_sfx("error")
		return
	# the next stronger form; from the strongest back to normal
	var nxt = -1
	for i in u:
		if i > form_i:
			nxt = i
			break
	if nxt < 0:
		_revert()
		events.append({"type": "msg", "text": "BACK TO NORMAL"})
		return
	if ep < 4:
		events.append({"type": "msg", "text": "NOT ENOUGH ENERGY TO TRANSFORM"})
		_sfx("error")
		return
	pending_form = nxt
	state = "transform"
	skill_t = 0
	var tf_frames = Assets.sprite_set(set_id).get("slots", [])
	# the game's own animation for the game's own forms (Super Saiyan, Piccolo dropping his cape...); not for Kaioken
	game_tf = int(forms[nxt].get("set", -1)) > 0 and tf_frames.size() > Rules.A_TRANSFORM * 4 and tf_frames[Rules.A_TRANSFORM * 4].size() >= 3
	set_anim(_anim_or(Rules.A_TRANSFORM, _anim_or(Rules.A_CHARGE, Rules.A_IDLE)))
	if not game_tf:
		_sfx("transform")

## the game's transformation, frame by frame: [frame of animation 9 (facing down), ticks] - measured from the game
const TF_SEQ = [[0, 17], [1, 16], [2, 17], [3, 17], [2, 16], [3, 17]]
var game_tf = false

func _apply_form(i: int) -> void:
	form_i = i
	drain_t = 0
	var f = form()
	var st = int(f.get("set", -1))
	set_id = st if st > 0 and not Assets.sprite_set(st).is_empty() else base_set
	events.append({"type": "msg", "text": str(f.get("name", "")) + "!"})
	game_tf = false

func _revert() -> void:
	form_i = -1
	set_id = base_set

func aura() -> int:
	if barrier_t > 0:
		return barrier_col
	var f = form()
	if f.has("aura"):
		return Content.color(f.get("aura", "")).to_rgba32()
	for id in states:
		var st = Content.state(id)
		if st.has("aura"):
			return Content.color(st["aura"]).to_rgba32()
	return 0

func tint() -> Color:
	return Content.color(form().get("tint", "ffffff"))

func size_scale() -> float:
	return float(form().get("scale", 1.0))

# ------------------------------------------------------------------ items
func add_item(id: String, n: int) -> int:
	var it = Content.item(id)
	if it.is_empty():
		return 0
	var mx = int(it.get("max", 99))
	var have = int(inv.get(id, 0))
	var add = clampi(n, 0, mx - have)
	if add > 0:
		inv[id] = have + add
		if quick == "" or int(inv.get(quick, 0)) <= 0:
			quick = id
	return add

func _first_item() -> String:
	for it in Content.items:
		if it.has("slot"):
			continue
		if int(inv.get(str(it["id"]), 0)) > 0:
			return str(it["id"])
	return ""

func use_item(id: String) -> bool:
	if id == "" or int(inv.get(id, 0)) <= 0:
		events.append({"type": "msg", "text": "NO ITEMS - FOES DROP THEM, OR THE CAPSULE SHOP (MENU)"})
		return false
	var it = Content.item(id)
	if it.is_empty():
		return false
	if it.has("slot"):
		events.append({"type": "msg", "text": wear(id)})
		return true
	inv[id] = int(inv[id]) - 1
	if inv[id] <= 0:
		inv.erase(id)
	var txt = []
	if it.has("hp"):
		var h = roundi(maxhp * float(it["hp"]))
		hp = mini(maxhp, hp + h)
		txt.append("+%d HP" % h)
	if it.has("ep"):
		var e = roundi(maxep * float(it["ep"]))
		ep = mini(maxep, ep + e)
		txt.append("+%d EP" % e)
	if it.has("buff"):
		buffs[str(it["buff"])] = [float(it.get("mult", 1.2)), int(it.get("ticks", 1800))]
		txt.append(str(it["name"]))
	if it.has("cure"):          # "all" or a list of state ids
		var cu = it["cure"]
		for sid in states.keys():
			if str(cu) == "all" or (cu is Array and sid in cu) or str(cu) == sid:
				remove_state(sid, true)
		txt.append("CURED")
	if it.has("state"):
		add_state(str(it["state"]), float(it.get("state_seconds", -1)))
	events.append({"type": "pop", "text": " ".join(PackedStringArray(txt)), "color": Content.color(it.get("color", "ffffff"))})
	fx.append(["sparkle", x, y - 20, 4, Content.color(it.get("color", "ffffff")).to_rgba32(), 0, 16])
	_sfx("item")
	return true

## an enemy hits this fighter
func take_hit(dmg: int, kx: float, ky: float) -> void:
	if invuln > 0 or state == "down" or flying:       # (flying: nothing can hit you up there)
		return
	hp = maxi(0, hp - dmg)
	invuln = Rules.INVULN_TICKS
	knock = Vector2(kx, ky).limit_length(1.5)
	knock_t = 8
	if hp <= 0:
		if form_i >= 0:
			_revert()
		state = "down"
		down_t = Rules.DOWN_TICKS
		set_anim(Rules.A_DOWN)
	else:
		state = "hurt"
		set_anim(Rules.A_HURT)

func revive(px: float, py: float) -> void:
	clear_states()
	place_at(px, py)
	hp = maxhp; ep = maxep
	state = "idle"
	invuln = 90
	set_anim(Rules.A_IDLE)

func snapshot() -> Dictionary:
	var sh = []
	for s in shots:
		if int(s.get("kind", 0)) >= 5:
			sh.append(_rom_snap(s))
			continue
		sh.append([snappedf(s["x"], 0.1), snappedf(s["y"], 0.1), s["dir"], int(s.get("kind", 0)), int(s.get("col", 0)), float(s.get("w", 0)),
			snappedf(float(s.get("ox", 0)), 0.1), snappedf(float(s.get("oy", 0)), 0.1), float(s.get("size", 0)), str(s.get("look", "")), float(s.get("base", 0))])
	var fxs = []
	for e in fx:
		fxs.append(e.duplicate())
	return {"ch": ch, "x": x, "y": y, "dir": dir, "anim": anim, "frame": frame, "hp": hp, "maxhp": maxhp, "ep": ep, "maxep": maxep,
		"lvl": level, "shots": sh, "down": state == "down", "inv": invuln > 0 or flying, "set": shape_set if shape_set >= 0 else set_id, "aura": aura(),
		"tint": (tint() * state_tint()).to_rgba32(), "sts": states.keys(), "scale": size_scale(), "dx": draw_dx, "fx": fxs, "form": str(form().get("name", "")), "fly": flying, "pvp": pvp}

# ------------------------------------------------------------------ the heroes' own attacks, exactly as the game draws them
## content/rom_specials.json: measured from the game frame by frame (the glow at the hands, the beam or the ball,
## where each sprite sits from the hero's feet, how fast it grows or flies)
const RDIR = [Vector2(0, 1), Vector2(0, -1), Vector2(-1, 0), Vector2(1, 0)]

func _rom_spec() -> Dictionary:
	return Content.rom_specials.get(str(cur.get("rom", "")), {})

func _rom_shot():
	for s in shots:
		if int(s.get("kind", 0)) >= 5 and int(s.get("owner_t", -1)) == shot_seq_owner:
			return s
	return null

var shot_seq_owner = 0

var draw_dx = 0           # the game draws a few poses a pixel off: the hero is drawn this much to the right
func _rom_pose(R: Dictionary, key: String, d: int) -> void:
	var owner = str(R.get("who", ""))
	if owner != "" and not (ch >= 0 and ch < Assets.CHARACTERS.size() and Assets.CHARACTERS[ch] == owner):
		# a move borrowed from another hero (Cell's Kamehameha): his own beam pose, hand out - the other hero's pose numbers mean nothing in his sheet
		anim = _pose(cur, "beam")
		frame = 0 if key == "pose_charge" else maxi(0, _frame_count(anim) - 1)
		draw_dx = 0
		return
	var p: Array = R.get(key, [[18, 0, 0], [18, 0, 0], [18, 0, 0], [18, 0, 0]])[d]
	anim = int(p[0])
	frame = mini(int(p[1]), maxi(0, _frame_count(anim) - 1))
	draw_dx = int(p[2]) if p.size() > 2 else 0

## a game move made for another hero (Cell's Kamehameha is Goku's): where it starts moves with this fighter's
## hand (side on) or size (up / down), so it leaves from a bigger or smaller body's hands
func _rom_offset(R: Dictionary) -> Vector2:
	var owner = str(R.get("who", ""))
	if ch >= 0 and ch < Assets.CHARACTERS.size() and Assets.CHARACTERS[ch] == owner:
		return Vector2.ZERO
	var oi = Assets.CHARACTERS.find(owner)
	if oi < 0:
		return Vector2.ZERO
	var oset = Assets.character_set(oi)
	if dir >= 2:
		return Assets.hand_point(set_id, Rules.A_KI, dir) * size_scale() - Assets.hand_point(oset, Rules.A_KI, dir)
	var hs = Assets.body_size(set_id) * size_scale()
	var ho = Assets.body_size(oset)
	return Vector2(0, -(hs.y - ho.y) * 0.5)

var rom_off = Vector2.ZERO
func _step_rom(enemies: Array) -> void:
	var R = _rom_spec()
	if R.is_empty():
		_skill_done()
		return
	var t = skill_t - 1      # the game counts from the press
	if t <= 0:
		rom_off = _rom_offset(R)
	var d = clampi(dir, 0, 3)
	if (not sp_held or ep <= 0) and rom_release < 0:
		rom_release = t      # let go - or out of ki: the beam ends
	elif rom_release < 0 and t > int(R.get("launch", 27)) and str(R.get("kind", "beam")) == "beam" and t % BEAM_DRAIN_TICKS == 0:
		ep = maxi(0, ep - 1)      # a held beam of the game's own eats ki too
	var launch = int(R.get("launch", 27))
	if t < launch:
		_rom_pose(R, "pose_charge", d)
		if t >= 2:
			var ch: Dictionary = R["charge"]
			var su = int(ch.get("small_until", 6))
			var fr = int(ch.get("small_frame", 0))
			var small = true
			if t >= su:
				var seq: Array = ch["seq"]
				fr = int(seq[((t - su) / int(ch.get("seq_ticks", 4))) % seq.size()])
				small = ch.has("small_frame") and fr == int(ch["small_frame"])
			var tl: Array = (ch["small"] if small else ch["big"])[d]
			if t == launch - 1 and R.has("glitch"):
				# the game shows the beam's tail in the glow's place for one frame before it fires
				var gl: Array = R["glitch"]
				fx.append(["rfx", x + rom_off.x, y + rom_off.y, str(R["sheet"]), int(gl[d]), 0, 1, int(tl[0]), int(tl[1])])
			else:
				fx.append(["rfx", x + rom_off.x, y + rom_off.y, str(R["charge_sheet"]), fr, 0, 1, int(tl[0]), int(tl[1])])
		return
	var kind = str(R.get("kind", "beam"))
	if t == launch:
		shot_seq += 1
		shot_seq_owner = shot_seq
		var r = Rules.ki_damage(_stat_of(cur), float(R.get("power", cur.get("power", 3.0))), rng)
		var sh = {"id": shot_seq, "owner_t": shot_seq, "rom": str(cur["rom"]), "dir": d, "t": 0, "x": roundf(x + rom_off.x), "y": roundf(y + rom_off.y),
			"vx": 0.0, "vy": 0.0, "life": 9999, "dmg": r[0], "crit": r[1], "hit": {}, "beam": kind == "beam", "col": 0}
		if kind == "beam":
			sh["kind"] = 5; sh["L"] = float(R.get("len0", 8)); sh["r"] = -1.0; sh["grow"] = true
			# longer with the levels: from the game's own length to far past it, and quicker to stretch out
			var mx = beam_reach(cur, float(R.get("max", 56)))
			sh["max"] = mx; sh["sp"] = float(R.get("speed", 3)) * sqrt(mx / float(R.get("max", 56)))
		else:
			sh["kind"] = 6; sh["burst"] = -1; sh["bt"] = 0
			sh["tl"] = R["path"][d][0] if R.has("path") else R["start"][d]
			# bigger with the levels: the game's ball in a glow of its colour that grows around it
			sh["k"] = ball_scale(cur, float(R.get("size", 16)))
			sh["col"] = int(Color.html(str(cur.get("color", "ffffff"))).to_rgba32())
		shots.append(sh)
		_sfx(str(cur.get("sfx", "beam")))
	var s: Variant = _rom_shot()
	if kind == "beam":
		_rom_pose(R, "pose_fire", d)
		if s == null:
			_skill_done()
			return
		var sd: Dictionary = s
		sd["grow"] = rom_release < 0 or t <= rom_release + int(R.get("after_release", 2))
		if rom_release >= 0 and t >= maxi(rom_release + int(R.get("after_release", 2)) - 1, launch):
			sd["retract"] = true
			_skill_done()      # the hero is free again while the tail runs after the head
	else:
		_rom_pose(R, "pose_fire", d)
		if t >= launch + int(R.get("pose_fire_ticks", 30)):
			_skill_done()

## one tick of a beam / ball of the game's own; false when it is gone
func _step_rom_shot(s: Dictionary, enemies: Array) -> bool:
	var R: Dictionary = Content.rom_specials.get(str(s["rom"]), {})
	if R.is_empty():
		return false
	s["t"] = int(s["t"]) + 1
	var d = int(s["dir"])
	var v: Vector2 = RDIR[d]
	var P = Vector2(float(s["x"]), float(s["y"]))
	if int(s["kind"]) == 5:
		# the hero was hit (or knocked down, or did something else) while the beam was out: it is gone at once,
		# like in the game - a beam never stays hanging in the air without the hero holding it
		if not s.get("retract", false) and (state != "skill" or not cur.has("rom") or int(s.get("owner_t", -1)) != shot_seq_owner):
			return false
		var sp = float(s.get("sp", R.get("speed", 3)))
		if not (s.get("retract", false) and float(s["r"]) >= 0):
			s["L"] = minf(float(s.get("max", R.get("max", 56))), float(s["L"]) + sp)
		if s.get("retract", false):
			s["r"] = 0.0 if float(s["r"]) < 0 else float(s["r"]) + sp
			if float(s["r"]) >= float(s["L"]):
				return false
		# what it touches: from the tail (or where the tail has run to) to the head
		var b0: Array = R["body"][d]
		var h0: Array = R["head"][d]
		var a = P + Vector2(b0[0], b0[1]) + Vector2(4, 4) + v * maxf(0.0, float(s["r"]))
		var e2 = P + Vector2(h0[0], h0[1]) + Vector2(8, 8) + v * (float(s["L"]) - float(R.get("len0", 8)))
		if int(s["t"]) % 10 == 1:
			s["hit"] = {}
		for e in enemies:
			if not e["alive"] or s["hit"].has(e["id"]):
				continue
			var q = Vector2(e["x"], e["y"] - 10)
			var seg = e2 - a
			var k = clampf((q - a).dot(seg) / maxf(1.0, seg.length_squared()), 0.0, 1.0)
			if q.distance_to(a + seg * k) < (8.0 if not e.get("big", false) else 16.0) + 4.0:
				s["hit"][e["id"]] = true
				var dmg = int(s["dmg"]) if not s.get("rehit", false) else maxi(1, int(s["dmg"]) / 3)
				events.append({"type": "hit", "enemy": e["id"], "dmg": dmg, "crit": s["crit"], "kx": v.x * 3.0, "ky": v.y * 3.0, "stun": 10, "inflict": s.get("inf", {})})
		if int(s["t"]) % 10 == 0:
			s["rehit"] = true
		return true
	# a ball
	var size = float(R.get("size", 16)) * float(s.get("k", 1.0))
	if int(s["burst"]) >= 0:
		s["bt"] = int(s["bt"]) + 1
		var seq: Array = R.get("boom", R.get("hit", []))
		var total = 0
		for q in seq:
			total += int(q[1])
		return int(s["bt"]) < total
	var t = int(s["t"])
	var tl: Vector2
	var end = false
	if R.has("path"):
		var path: Array = R["path"][d]
		var i = mini(t - 1, path.size() - 1)
		tl = Vector2(path[i][0], path[i][1])
		end = t >= path.size()
	else:
		var st: Array = R["start"][d]
		var dist = floorf(float(R.get("speed", 2.0)) * maxf(0.0, t - 1))
		tl = Vector2(st[0], st[1]) + v * dist
		end = dist >= float(R.get("range", 150))
		if end:
			return false
	s["tl"] = [tl.x, tl.y]
	var c = P + tl + Vector2(1, 1) * float(R.get("size", 16)) * 0.5
	var hit = end
	if not R.has("path") and not Assets.walkable(area, c.x, c.y + 8) and not area.is_empty() and t > 6:
		hit = true
	for e in enemies:
		if hit:
			break
		if e["alive"] and absf(e["x"] - c.x) < size * 0.5 + 6 and absf((e["y"] - 10) - c.y) < size * 0.5 + 8:
			hit = true
			events.append({"type": "hit", "enemy": e["id"], "dmg": s["dmg"], "crit": s["crit"], "kx": v.x * 4.0, "ky": v.y * 4.0, "stun": 16, "inflict": s.get("inf", {})})
			s["hit"][e["id"]] = true
	if hit:
		s["burst"] = 0
		s["bt"] = 0
		if R.has("radius"):      # Gohan's blast bursts: everything around is caught
			_sfx("boom")
			for e in enemies:
				if e["alive"] and not s["hit"].has(e["id"]) and Vector2(e["x"] - c.x, e["y"] - 10 - c.y).length() < float(R["radius"]) * float(s.get("k", 1.0)):
					events.append({"type": "hit", "enemy": e["id"], "dmg": s["dmg"], "crit": s["crit"], "kx": 0.0, "ky": 0.0, "stun": 16, "inflict": s.get("inf", {})})
	return true

## the snapshot of a game's-own shot: what every screen needs to draw it
func _rom_snap(s: Dictionary) -> Array:
	var R: Dictionary = Content.rom_specials.get(str(s["rom"]), {})
	if int(s["kind"]) == 5:
		return [s["x"], s["y"], s["dir"], 5, int(s["t"]), float(s["L"]), 0, 0, float(s["r"]), str(s["rom"])]
	var d = int(s["dir"])
	var tl: Array = s.get("tl", [0, 0])
	var sheet = str(R.get("sheet", ""))
	var fr = 0
	var dx = 0.0
	var dy = 0.0
	var t = int(s["t"])
	if int(s["burst"]) >= 0:
		var seq: Array = R.get("boom", R.get("hit", []))
		var bt = int(s["bt"])
		var acc = 0
		for q in seq:
			if bt < acc + int(q[1]):
				fr = int(q[0])
				if q.size() > 3:
					dx = float(q[2]); dy = float(q[3])
				break
			acc += int(q[1])
		if R.has("burst"):
			sheet = str(R["burst"])
		elif int(R.get("group", 0)) == 4:
			fr += 4 * d
	else:
		var fly: Array = R.get("fly", [0])
		fr = int(R.get("fly0", fly[0])) if t < 3 else int(fly[((t - 3) / int(R.get("fly_ticks", 8))) % fly.size()])
		if int(R.get("group", 0)) == 4:
			fr += 4 * d
	var halo = 0.0 if int(s["burst"]) >= 0 or float(s.get("k", 1.0)) <= 1.0 else float(R.get("size", 16)) * 0.5 * float(s.get("k", 1.0))
	return [float(s["x"]) + float(tl[0]) + dx, float(s["y"]) + float(tl[1]) + dy, d, 6, int(s.get("col", 0)), halo, float(R.get("size", 16)) * 0.5, float(R.get("size", 16)) * 0.5, fr, sheet]
