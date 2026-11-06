## BEAM CLASH: two players in PVP facing each other in a line - side by side or one above the other, within 3 tiles of
## it - each with a beam out at the other: when the beams' heads meet, they lock. Both are held in the pose, sparks fly
## where the beams push on each other, and "TAP X!" comes up (C on a keyboard). Whoever taps the special button faster
## pushes the clash toward the other. No time limit: the beams eat ki as a held beam does, and the clash ends when one
## side is LEAD taps ahead or runs out of ki - the one pushed back (or out of ki) takes the winner's beam (a quarter of
## their health). The player with the lower id keeps the count and says who won (both see the same), the other sends
## its taps. The BRAWL fighters clash too (brawl.gd answers for them)
extends RefCounted

const ROWS = 24.0          # 3 tiles off the line, across it
const LEAD = 12            # taps ahead that win it at once
const HIT = 0.25           # the loser's health the winning beam takes
const QUIET = 180          # ticks without a word from the other side: it is over (they left, their game stopped)

## facing each other on one line: the other is in front of `d` (side by side for left / right, above or below for
## up / down), close enough across it, facing back the other way
static func lined_up(d: int, me: Vector2, od: int, them: Vector2) -> bool:
	if od != (d ^ 1):
		return false
	var fwd = Rules.dir_vec(d)
	var off = them - me
	return off.dot(fwd) > 0.0 and absf(off.x if fwd.x == 0.0 else off.y) <= ROWS

## our beam's head has reached theirs (or gone past it), along our way
static func heads_met(d: int, mine: Vector2, theirs: Vector2) -> bool:
	return (mine - theirs).dot(Rules.dir_vec(d)) >= 0.0

## the clash point: between the two along the line (k: how far toward them the taps have pushed it), across it where
## the beams are (an eye beam is higher than one from the hands)
static func clash_point(d: int, me: Vector2, them: Vector2, k: float, across: Vector2) -> Vector2:
	if Rules.dir_vec(d).x != 0.0:
		return Vector2(lerpf(me.x, them.x, k), across.y)
	return Vector2(across.x, lerpf(me.y, them.y, k))

## our beam's head kept on the clash point
static func pin_head(shots: Array, d: int, p: Vector2) -> void:
	for s in shots:
		if int(s.get("kind", 0)) == 1:
			if Rules.dir_vec(d).x != 0.0:
				s["x"] = p.x
			else:
				s["y"] = p.y

## pushed back by the winning beam: away from the other, along the line
static func knock(d: int, me: Vector2, them: Vector2) -> Vector2:
	var fwd = Rules.dir_vec(d)
	return -fwd * 8.0 if (them - me).dot(fwd) >= 0.0 else fwd * 8.0

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
	# the beam is still being fed: ki goes as a held beam's does (the fighter is held, so its own drain stands still)
	if int(c["t"]) % FighterSim.BEAM_DRAIN_TICKS == 0:
		f.ep = maxi(0, f.ep - 1)
	if f.ep <= 0:      # out of ki: the beam gives out, theirs comes through
		Game.send_social(int(c["with"]), world._my_pid(L), L.name, "clash_end", {"you_won": true})
		_finish(L, false)
		return false
	# the clash point: between the two, pushed by the taps
	var me = Vector2(f.x, f.y)
	var them = Vector2(float(other["x"]), float(other["y"]))
	var lead = clampi(int(c["mine"]) - int(c["theirs"]), -LEAD, LEAD)
	var k = 0.5 + 0.4 * float(lead) / float(LEAD)
	var p = clash_point(f.dir, me, them, k, meet(f, int(c["with"]), Vector2((me.x + them.x) * 0.5, (me.y + them.y) * 0.5 - 14.0), world))
	c["p"] = p
	pin_head(f.shots, f.dir, p)
	# sparks shooting straight out where they meet: each beam's colour on its own side (left / right, or above / below)
	var vert = Rules.dir_vec(f.dir).x == 0.0
	var mine_first = (f.y < them.y) if vert else (f.x < them.x)
	world.clash_burst(L.node_i, p, c["col"] if mine_first else c["col2"], c["col2"] if mine_first else c["col"], vert)
	if int(c["t"]) % 10 == 0:
		L.shake = maxf(L.shake, 1.5)
	# the referee: decides on the taps (running out of ki is each side's own to say)
	if bool(c["ref"]) and absi(int(c["mine"]) - int(c["theirs"])) >= LEAD:
		var won = int(c["mine"]) >= int(c["theirs"])
		Game.send_social(int(c["with"]), world._my_pid(L), L.name, "clash_end", {"you_won": not won})
		_finish(L, won)
	elif int(c["t"]) - int(c.get("heard", 0)) > QUIET:
		_end(L, false)      # (the other side went quiet: it just ends)
	return true

## a clash starting: our beam out sideways, theirs at us, close enough up and down, the heads met
func _look(L) -> void:
	var f = L.fighter
	var mine = _beam_of(f.shots, f.dir)
	if mine.is_empty():
		return
	for pid in Game.remote_states:
		var st: Dictionary = Game.remote_states[pid]
		var foe = bool(st.get("foe", false))      # (a HERO FOE: clashes with anyone, PVP or not)
		if int(st.get("node", -1)) != L.node_i or not (foe or (f.pvp and bool(st.get("pvp", false)))) or bool(st.get("down", false)):
			continue
		if not lined_up(f.dir, Vector2(f.x, f.y), int(st.get("dir", 0)), Vector2(float(st.get("x", 0)), float(st.get("y", 0)))):
			continue      # not facing us in a line, in front of us
		if not foe and world._hvv_on() and world._same_side(f.ch, int(st.get("ch", -1))):
			continue      # (HEROES VS VILLAINS: no clash with your own side)
		var theirs = _beam_snap(st.get("shots", []), f.dir ^ 1)
		if theirs.is_empty():
			continue
		if not heads_met(f.dir, mine["head"], theirs["head"]):
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

## where the clash is across its line: halfway between the two beams' heads (an eye beam is higher than one from the
## hands; one above the other, the beams' own left / right)
static func meet(f, with: int, fallback: Vector2, w) -> Vector2:
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
	return (mine["head"] + theirs["head"]) * 0.5

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
			L.clash["heard"] = int(L.clash["t"])
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
		var kb = knock(f.dir, Vector2(f.x, f.y), Vector2(float(other["x"]), float(other["y"])) if other != null else Vector2(f.x, f.y) + Rules.dir_vec(f.dir))
		f.invuln = 0
		f.take_hit(maxi(1, roundi(f.maxhp * HIT)), kb.x, kb.y)
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
