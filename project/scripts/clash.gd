## BEAM CLASH: two players in PVP, within 3 tiles of each other up and down, facing each other, each with a beam out
## sideways - when the beams' heads meet, they lock: both are held in the pose, sparks fly where the beams push on each
## other, and "TAP X!" comes up (C on a keyboard). Whoever taps the special button faster pushes the clash toward the other; the one
## pushed back takes the winner's beam (a quarter of their health). The player with the lower id keeps the count and
## says who won (both see the same), the other sends its taps. The BRAWL fighters clash too (brawl.gd answers for them)
extends RefCounted

const ROWS = 24.0          # 3 tiles up and down
const TIME = 240           # ticks: 4 seconds at most
const LEAD = 12            # taps ahead that win it at once
const HIT = 0.25           # the loser's health the winning beam takes

var world

func _init(w) -> void:
	world = w

## each tick of a player here, before the fighter steps: true while in a clash (the fighter is held)
func step(L, raw: Dictionary) -> bool:
	var f = L.fighter
	if L.clash.is_empty():
		_look(L)
		return false
	var c: Dictionary = L.clash
	var other = world._pos_of_pid(int(c["with"]))
	if other == null or bool(other["down"]) or f.state == "down":
		_end(L, false)
		return false
	c["t"] = int(c["t"]) + 1
	if raw.get("sp", false) and not c.get("held", false):
		c["mine"] = int(c["mine"]) + 1
	c["held"] = bool(raw.get("sp", false))
	if int(c["t"]) % 6 == 0:
		Game.send_social(int(c["with"]), world._my_pid(L), L.name, "clash_taps", {"n": int(c["mine"])})
	# the clash point: halfway between the two, pushed by the taps
	var me = Vector2(f.x, f.y)
	var them = Vector2(float(other["x"]), float(other["y"]))
	var lead = clampi(int(c["mine"]) - int(c["theirs"]), -LEAD, LEAD)
	var k = 0.5 + 0.4 * float(lead) / float(LEAD)
	var p = Vector2(lerpf(me.x, them.x, k), meet_y(f, int(c["with"]), (me.y + them.y) * 0.5 - 14.0, world))
	c["p"] = p
	for s in f.shots:      # our beam's head stays on the clash point
		if int(s.get("kind", 0)) == 1:
			s["x"] = p.x
	# sparks shooting straight out where they meet: each beam's colour on its own side
	var mine_left = f.x < them.x
	world.clash_burst(L.node_i, p, c["col"] if mine_left else c["col2"], c["col2"] if mine_left else c["col"])
	if int(c["t"]) % 10 == 0:
		L.shake = maxf(L.shake, 1.5)
	# the referee: decides
	if bool(c["ref"]) and (int(c["t"]) >= TIME or absi(int(c["mine"]) - int(c["theirs"])) >= LEAD):
		var won = int(c["mine"]) >= int(c["theirs"])
		Game.send_social(int(c["with"]), world._my_pid(L), L.name, "clash_end", {"you_won": not won})
		_finish(L, won)
	elif not bool(c["ref"]) and int(c["t"]) > TIME + 90:
		_end(L, false)      # (the referee went quiet: it just ends)
	return true

## a clash starting: our beam out sideways, theirs at us, close enough up and down, the heads met
func _look(L) -> void:
	var f = L.fighter
	if f.dir < 2:
		return
	var mine = _beam_of(f.shots, f.dir)
	if mine.is_empty():
		return
	for pid in Game.remote_states:
		var st: Dictionary = Game.remote_states[pid]
		var foe = bool(st.get("foe", false))      # (a HERO FOE: clashes with anyone, PVP or not)
		if int(st.get("node", -1)) != L.node_i or not (foe or (f.pvp and bool(st.get("pvp", false)))) or bool(st.get("down", false)):
			continue
		if absf(float(st.get("y", 0)) - f.y) > ROWS or int(st.get("dir", 0)) != (f.dir ^ 1):
			continue
		if not foe and world._hvv_on() and world._same_side(f.ch, int(st.get("ch", -1))):
			continue      # (HEROES VS VILLAINS: no clash with your own side)
		var ox = float(st.get("x", 0))
		if (ox > f.x) != (f.dir == 3):
			continue      # not in front of us
		var theirs = _beam_snap(st.get("shots", []), f.dir ^ 1)
		if theirs.is_empty():
			continue
		# the heads have met: ours has reached theirs (or past it)
		var meet = (mine["head"].x >= theirs["head"].x) if f.dir == 3 else (mine["head"].x <= theirs["head"].x)
		if not meet:
			continue
		var me_pid = world._my_pid(L)
		L.clash = {"with": int(pid), "t": 0, "mine": 0, "theirs": 0, "ref": me_pid < int(pid), "held": true,
			"col": mine["col"], "col2": theirs["col"], "p": (mine["head"] + theirs["head"]) * 0.5}
		world.toasts.append(["BEAM CLASH!", Color(1, 0.9, 0.4), 120])
		Sfx.play("crit")
		return

static func _beam_of(shots: Array, d: int) -> Dictionary:
	var fwd = Rules.dir_vec(d)
	for s in shots:
		var k = int(s.get("kind", 0))
		if k == 1:
			return {"head": Vector2(float(s["x"]), float(s["y"])), "col": Color.hex(int(s.get("col", 0xFFFFFFFF)))}
		if k == 5:
			return {"head": Vector2(float(s["x"]), float(s["y"])) + fwd * float(s.get("L", 0)), "col": rom_col(str(s.get("rom", "")))}
	return {}

static func _beam_snap(shots: Array, d: int) -> Dictionary:
	var fwd = Rules.dir_vec(d)
	for e in shots:
		var k = int(e[3])
		if k == 1:
			return {"head": Vector2(float(e[0]), float(e[1])), "col": Color.hex(int(e[4]))}
		if k == 5:
			return {"head": Vector2(float(e[0]), float(e[1])) + fwd * float(e[5]), "col": rom_col(str(e[9]) if e.size() > 9 else "")}
	return {}

## the height the clash is at: halfway between the two beams (an eye beam is higher than one from the hands)
static func meet_y(f, with: int, fallback: float, w) -> float:
	var mine = _beam_of(f.shots, f.dir)
	var theirs = {}
	if w.brawl != null and w.brawl.bots.has(with):
		var of = w.brawl.bots[with]["f"]
		theirs = _beam_of(of.shots, of.dir)
	elif with / 8 == Game.my_id() and w._local_of(with % 8) != null:
		var lf = w._local_of(with % 8).fighter
		theirs = _beam_of(lf.shots, lf.dir)
	elif Game.remote_states.has(with):
		var st: Dictionary = Game.remote_states[with]
		theirs = _beam_snap(st.get("shots", []), int(st.get("dir", 0)))
	if mine.is_empty() or theirs.is_empty():
		return fallback
	return (mine["head"].y + theirs["head"].y) * 0.5

## the colour of one of the game's own beams (drawn from its pictures): its move's own (KAMEHAMEHA light blue...)
static func rom_col(rom: String) -> Color:
	for sk in Content.skills:
		if str(sk.get("rom", "")) == rom and rom != "":
			return Content.color(sk.get("color", ""), Color(0.6, 0.85, 1))
	return Color(0.6, 0.85, 1)

## messages from the other one in the clash
func on_social(L, from: int, kind: String, data: Dictionary) -> void:
	if kind == "clash_taps":
		if L.clash.is_empty():
			# they saw it first: it is on for us too (our beam is out at them)
			var f = L.fighter
			if _beam_of(f.shots, f.dir).is_empty():
				return
			var st2: Dictionary = Game.remote_states.get(from, {})
			var theirs = _beam_snap(st2.get("shots", []), int(st2.get("dir", 0)))
			L.clash = {"with": from, "t": 0, "mine": 0, "theirs": 0, "ref": world._my_pid(L) < from, "held": true,
				"col": _beam_of(f.shots, f.dir)["col"], "col2": theirs.get("col", Color(0.6, 0.85, 1)), "p": Vector2(f.x, f.y)}
			world.toasts.append(["BEAM CLASH!", Color(1, 0.9, 0.4), 120])
		if int(L.clash.get("with", -1)) == from:
			L.clash["theirs"] = maxi(int(L.clash["theirs"]), int(data.get("n", 0)))
	elif kind == "clash_end" and int(L.clash.get("with", -1)) == from:
		_finish(L, bool(data.get("you_won", false)))

func _finish(L, won: bool) -> void:
	var f = L.fighter
	var c: Dictionary = L.clash
	if won:
		world.toasts.append(["YOU WIN THE CLASH!", Color(0.6, 1, 0.6), 160])
	else:
		world.toasts.append(["OVERPOWERED!", Color(1, 0.5, 0.4), 160])
		var other = world._pos_of_pid(int(c["with"]))
		var kx = (1.0 if other != null and float(other["x"]) < f.x else -1.0) * 8.0
		f.invuln = 0
		f.take_hit(maxi(1, roundi(f.maxhp * HIT)), kx, 0.0)
		L.shake = 6.0
		Sfx.play("hurt")
	_end(L, true)

## the clash over: the beams go out
func _end(L, _decided: bool) -> void:
	var f = L.fighter
	L.clash = {}
	f.shots = f.shots.filter(func(s): return int(s.get("kind", 0)) != 1 and int(s.get("kind", 0)) != 5)
	if f.state == "skill":
		f._skill_done()

## the prompt on the screen: TAP X! (C on a keyboard), the button pressed over and over
func draw(c: Control, L, at: Vector2) -> void:
	if L.clash.is_empty():
		return
	var font = Assets.gba_font("font_head")
	if font == null:
		font = ThemeDB.fallback_font
	var t = int(L.clash["t"])
	var k = Game.keys("X:").trim_suffix(":")      # (the special button: C on a PC or Mac's keyboard)
	var key = k != "X"      # a keyboard key (a key cap), or the pad's round X
	# the button being pressed over and over: pushed down onto its base, let up again, lines flashing round it when down
	var down = (t / 5) % 2 == 0
	var lift = 0.0 if down else -3.0
	var face = Color(0.82, 0.84, 0.9) if key else Color(0.25, 0.45, 1.0)
	var rim = Color(0.38, 0.4, 0.48) if key else Color(0.1, 0.2, 0.55)
	if key:
		c.draw_rect(Rect2(at + Vector2(-12, -9), Vector2(24, 22)), Color(0, 0, 0, 0.7))      # the hole round the key
		c.draw_rect(Rect2(at + Vector2(-11, -8 + 3), Vector2(22, 17)), rim)                 # its side under it
		c.draw_rect(Rect2(at + Vector2(-11, -8 + lift + 3), Vector2(22, 17)), face)        # its top
		c.draw_rect(Rect2(at + Vector2(-11, -8 + lift + 3), Vector2(22, 2)), Color(1, 1, 1, 0.6))
	else:
		c.draw_circle(at + Vector2(0, 3), 13.0, Color(0, 0, 0, 0.6))
		c.draw_circle(at + Vector2(0, 2), 12.0, rim)
		c.draw_circle(at + Vector2(0, lift), 12.0, face)
		c.draw_circle(at + Vector2(-4, lift - 4), 3.0, Color(1, 1, 1, 0.35))
	var tw = font.get_string_size(k, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
	var lp = at + Vector2(-tw / 2.0, 6 + lift + (3.0 if key else 0.0))
	for o in [Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1)]:
		c.draw_string(font, lp + o, k, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0, 0, 0))
	c.draw_string(font, lp, k, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1, 1, 1))
	if down:
		for a2 in [-2.4, -1.57, -0.74, 0.74, 2.4]:      # the press: short lines bursting out round it
			var dv = Vector2.from_angle(a2)
			c.draw_line(at + dv * 16.0, at + dv * 21.0, Color(1, 0.95, 0.6), 1.5)
	c.draw_string(font, at + Vector2(-60, -18), "TAP %s!" % k, HORIZONTAL_ALIGNMENT_CENTER, 120, 16, Color(1, 0.9, 0.4))
	# who is winning: a bar, yours from the left
	var lead = clampi(int(L.clash["mine"]) - int(L.clash["theirs"]), -LEAD, LEAD)
	var w = 120.0
	c.draw_rect(Rect2(at.x - w / 2, at.y + 18, w, 5), Color(0, 0, 0, 0.7))
	c.draw_rect(Rect2(at.x - w / 2, at.y + 18, w * (0.5 + 0.5 * float(lead) / float(LEAD)), 5), Color(1, 0.85, 0.3))
