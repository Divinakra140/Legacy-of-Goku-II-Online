## BRAWL (MULTIPLAYER - BRAWL): the host fills every free place of the game (16 in all, the host's own included)
## with a fighter the computer plays - each hero and villain once - who fights the others nonstop near the host. They
## follow the players' rules: PVP always on, so they hurt players only when those have PVP on too, and they never
## touch the foes (the EXP stays the players'). A player joining takes a brawler's place (the one playing their hero
## first), a player leaving gives it back. To everyone they are players: sent out as player states from the host
## (ids 8 + k, k 2 and up - real players' ids are network ids x 8, never this small), so older versions see them too
extends RefCounted

const PLACES = 16          # Game.MAX_CLIENTS + the host
const FIRST_K = 2          # (k 0 and 1: the host's own players)
const NEAR = 320.0         # how far from the host they roam
const FOLLOW = 300.0       # further off than this they stop fighting and come after the host - sprinting, or flying
const FAR = 1600.0         # further than this (the host warped) they are put near the host
const PVP_ID = -2000       # (world.PVP_ID: another player, as something to hit)

var world
var bots = {}              # pid -> {f, k, name, tgt, think, down_t, a, b, send}
var rivals = {}            # HERO FOES fought as fighters: pid -> the same, and {rival, key, id, home}
var t = 0
var put_back = 0           # (how many were put by the host: the log)
var specials = 0           # (how many the brawlers let go: the log)
var clashes = 0            # (beam clashes decided: the log)
var foe_hits = 0           # (friendly CPUs' blows on foes: the log)

# ---- WIN CONDITION: BRAWL - the first to KILLS_TO_WIN_BRAWL PVP kills; HEROES VS VILLAINS - the first side to
# KILLS_TO_WIN_HVV, every brawler's and player's kills on that side together. Every PVP kill, on whatever machine it
# happens, reaches the host through Game.pvp_kill - this is the one place that decides and tells everyone (world.gd)
const KILLS_TO_WIN_BRAWL = 10
const KILLS_TO_WIN_HVV = 20
var pvp_kills = {}         # BRAWL: pid -> its kills this match
var pvp_kill_names = {}    # BRAWL: pid -> its name, last seen (the STAT screen's standings)
var kills_heroes = 0       # HEROES VS VILLAINS: every hero's kills together
var kills_villains = 0
var match_over = false     # a winner was decided: no more kills counted

func _init(w) -> void:
	world = w
	Game.bot_social.connect(_social_in)
	Game.bot_hurt.connect(_foe_hit)
	Game.pvp_kill.connect(_register_kill)

## a PVP kill, anywhere in the game: BRAWL / HEROES VS VILLAINS only, and only until a winner is decided
func _register_kill(pid: int, ch: int, nm: String) -> void:
	if match_over or not bool(Game.cfg.get("brawl", false)):
		return
	if hvv():
		if Rules.is_villain(ch):
			kills_villains += 1
		else:
			kills_heroes += 1
		Game.announce_match_score({"mode": "hvv", "heroes": kills_heroes, "villains": kills_villains})
		if kills_heroes >= KILLS_TO_WIN_HVV or kills_villains >= KILLS_TO_WIN_HVV:
			match_over = true
			Game.announce_match_won({"mode": "hvv", "heroes_won": kills_heroes >= KILLS_TO_WIN_HVV})
	else:
		pvp_kills[pid] = int(pvp_kills.get(pid, 0)) + 1
		pvp_kill_names[pid] = nm
		var rows = []
		for q in pvp_kills:
			rows.append({"pid": q, "name": str(pvp_kill_names.get(q, "?")), "n": int(pvp_kills[q]), "lvl": _level_of_pid(q)})
		rows.sort_custom(func(a, b): return int(a["n"]) > int(b["n"]))
		Game.announce_match_score({"mode": "brawl", "rows": rows})      # (16 at most: everyone sees everyone, not just the top few)
		if int(pvp_kills[pid]) >= KILLS_TO_WIN_BRAWL:
			match_over = true
			Game.announce_match_won({"mode": "brawl", "winner": nm, "lvl": _level_of_pid(pid)})

## a fighter's current level, by its pid (a brawler's, a local player's, or a remote one's) - for the STAT screen's
## BRAWL standings
func _level_of_pid(pid: int) -> int:
	if not _any(pid).is_empty():
		return int(_any(pid)["f"].level)
	if pid / 8 == Game.my_id():
		var L = world._local_of(pid % 8)
		return int(L.fighter.level) if L != null else 1
	return int(Game.remote_states.get(pid, {}).get("lvl", 1))

## a foe's blow on a friendly CPU (Game.host_step): as on a player
func _foe_hit(pid: int, atk: float, kx: float, ky: float) -> void:
	if not bots.has(pid):
		return
	var f = bots[pid]["f"]
	if f.invuln > 0 or f.state == "down" or f.flying:
		return
	f.take_hit(Rules.taken_damage(atk, f.eff_end(), f.rng), kx, ky)

static func on() -> bool:
	return Game.is_host() and (bool(Game.cfg.get("brawl", false)) or allies() > 0)

## FREE PLAY with FRIENDLY CPUS: how many (the host picked it); they fight the foes with the players, never them
static func allies() -> int:
	if bool(Game.cfg.get("brawl", false)):
		return 0
	return clampi(int(Game.cfg.get("allies", 0)), 0, PLACES - 1)

## HEROES VS VILLAINS (a BRAWL in two sides, 8 each): heroes hurt only villains, villains only heroes
static func hvv() -> bool:
	return bool(Game.cfg.get("hvv", false))

## how many fighters in all (the host picked it: BRAWL / HEROES VS VILLAINS screen)
static func places() -> int:
	return clampi(int(Game.cfg.get("brawl_places", default_places())), 2, PLACES)

## the count a game starts with: small enough for a handheld (16 slowed a Retroid Pocket Flip 2, 7 did not);
## HEROES VS VILLAINS keeps its two sides even
static func default_places() -> int:
	return 8 if hvv() else 7

func is_bot(pid: int) -> bool:
	return bots.has(pid)

## every tick (the host, after its own players)
func tick() -> void:
	if Game.is_host() and not world.locals.is_empty():
		_rivals_tick()
	if not on() or world.locals.is_empty():
		if not bots.is_empty():
			for pid in bots.keys():
				_remove(pid)
		return
	t += 1
	if t % 60 == 1:
		_fill()
	var host = world.locals[0]
	for pid in bots.keys():
		_step_bot(pid, bots[pid], host)
	if t % 300 == 0:
		var down = 0
		for pid in bots:
			down += 1 if bots[pid]["f"].state == "down" else 0
		var vil = 0
		for pid in bots:
			vil += 1 if Rules.is_villain(int(bots[pid]["f"].ch)) else 0
		var fl = 0
		var far = 0.0
		for pid in bots:
			var bf = bots[pid]["f"]
			fl += 1 if bf.flying else 0
			far = maxf(far, Vector2(bf.x - host.fighter.x, bf.y - host.fighter.y).length())
		print("[brawl] %d brawlers (%d villains), %d down, %d specials used, %d clashes, %d foe hits, %d flying, furthest %d px, %d put back" % [bots.size(), vil, down, specials, clashes, foe_hits, fl, int(far), put_back])

# ---- who plays: one brawler for every free place
func _real_players() -> Array:
	var out = []
	for L in world.locals:
		out.append(int(L.fighter.ch))
	for pid in Game.remote_states:
		var st: Dictionary = Game.remote_states[pid]
		if not st.get("bot", false):
			out.append(int(st.get("ch", -1)))
	return out

func _fill() -> void:
	var real = _real_players()
	if hvv():
		_fill_sides(real)
		return
	# (FRIENDLY CPUS: as many as asked - a player who joins takes one's place, and it is back when they go)
	var want = maxi(0, mini(allies() - (real.size() - world.locals.size()), PLACES - real.size())) if allies() > 0 else maxi(0, places() - real.size())
	# too many: the one playing a real player's hero goes first, then any
	while bots.size() > want:
		var drop = -1
		for pid in bots:
			if real.has(int(bots[pid]["f"].ch)):
				drop = pid
				break
		if drop < 0:
			drop = bots.keys()[randi() % bots.size()]
		_remove(drop)
	# too few: a hero or villain nobody plays yet (then any)
	while bots.size() < want:
		var used = real.duplicate()
		for pid in bots:
			used.append(int(bots[pid]["f"].ch))
		var free = []
		var all = range(Assets.CHARACTERS.size()).filter(func(c): return not Rules.not_ready(c))
		for c in all:
			if not used.has(c):
				free.append(c)
		var ch = free[randi() % free.size()] if not free.is_empty() else all[randi() % all.size()]
		if not _add(ch):
			break

## HEROES VS VILLAINS: each side made up to 8 (the players on it counted); villains may come twice (there are few)
func _fill_sides(real: Array) -> void:
	for side in [false, true]:
		var real_n = real.filter(func(c): return Rules.is_villain(c) == side).size()
		var want = maxi(0, places() / 2 - real_n)
		var mine = bots.keys().filter(func(q): return Rules.is_villain(int(bots[q]["f"].ch)) == side)
		while mine.size() > want:
			var drop = mine[0]
			for q in mine:
				if real.has(int(bots[q]["f"].ch)):
					drop = q
					break
			mine.erase(drop)
			_remove(drop)
		var pool = []
		for c in Assets.CHARACTERS.size():
			if Rules.is_villain(c) == side and not Rules.not_ready(c):
				pool.append(c)
		while mine.size() < want and not pool.is_empty():
			var used = real.duplicate()
			for q in bots:
				used.append(int(bots[q]["f"].ch))
			var free = pool.filter(func(c): return not used.has(c))
			var ch = free[randi() % free.size()] if not free.is_empty() else pool[randi() % pool.size()]
			if not _add(ch):
				break
			mine = bots.keys().filter(func(q): return Rules.is_villain(int(bots[q]["f"].ch)) == side)

func _free_k() -> int:
	var k = FIRST_K
	while bots.has(Game.pid_of(1, k)) or rivals.has(Game.pid_of(1, k)):
		k += 1
	return k

func _add(ch: int) -> bool:
	var k = _free_k()
	var host = world.locals[0]
	var f = FighterSim.new()
	_set_level(f, ch)
	f.area = host.area
	_place_near(f, host)
	var pid = Game.pid_of(1, k)
	pvp_kills.erase(pid); pvp_kill_names.erase(pid)      # (a different fighter takes this pid now: its own kill count starts fresh)
	bots[pid] = {"f": f, "k": k, "name": Assets.hero_shown_name(ch), "node": host.node_i, "tgt": -1, "think": 0, "down_t": 0, "a": false, "b": false, "send": 0}
	return true

## a brawler's level: the real players' average, give or take 3 (a level 5 who joins a level 50 host meets fighters
## near both, and they come back nearer each time they are beaten)
func _set_level(f, ch: int) -> void:
	var n = 0; var sum = 0
	for L in world.locals:
		sum += int(L.fighter.level); n += 1
	for pid in Game.remote_states:
		var st: Dictionary = Game.remote_states[pid]
		if not st.get("bot", false):
			sum += int(st.get("lvl", 1)); n += 1
	var lv = clampi(roundi(float(sum) / maxf(1.0, n)) + randi_range(-3, 3), 1, world.levels.size() - 1)
	f.setup(ch, world.levels)
	f.add_exp(int(world.levels[lv - 1]), world.levels)
	f.hp = f.maxhp; f.ep = f.maxep
	f.pvp = allies() == 0      # (a friendly CPU: no player can hurt it, it hurts no player)

func _remove(pid: int) -> void:
	var b = bots[pid]
	bots.erase(pid)
	Game.remote_states.erase(pid)
	Game.local_gone(int(b["k"]))

func _place_near(f, host) -> void:
	var hf = host.fighter
	for i in 24:
		var a = randf() * TAU
		var r = randf_range(90.0, 220.0)
		var px = hf.x + cos(a) * r; var py = hf.y + sin(a) * r
		if f.can_stand(px, py):
			f.revive(px, py)
			f.invuln = 0
			return
	f.revive(hf.x, hf.y)
	f.invuln = 0

# ---- one brawler's tick: think, press its buttons, step like a player
func _step_bot(pid: int, b: Dictionary, host) -> void:
	var f = b["f"]
	if int(b["node"]) != host.node_i or Vector2(f.x - host.fighter.x, f.y - host.fighter.y).length() > FAR:
		b["node"] = host.node_i      # the host went through a door (or warped far off): they come along
		f.area = host.area
		put_back += 1
		_place_near(f, host)
	if _clash_step(pid, b, host):
		_publish(pid, b)      # (held in the clash: the fighter does not step)
		return
	if allies() == 0:
		_clash_look(pid, b)
	var targets = _targets(pid, b, host)
	var inp = {}
	if f.state == "down":
		b["down_t"] = int(b["down_t"]) + 1
		if int(b["down_t"]) > 300:      # back in the fight after five seconds - at the players' level now
			b["down_t"] = 0
			var keep_area = f.area
			_set_level(f, int(f.ch))
			f.area = keep_area
			_place_near(f, host)
	else:
		inp = _think(b, f, targets, host)
	f.step(inp, targets)
	for ev in f.events:
		if str(ev.get("type", "")) == "hit" and int(ev["enemy"]) <= PVP_ID:
			var to = PVP_ID - int(ev["enemy"])
			if not _any(to).is_empty():
				_hurt(to, int(ev["dmg"]), float(ev["kx"]), float(ev["ky"]), pid, f.ch, str(b["name"]))
				var o = _any(to)["f"]
				if ev.get("ki", false) and int(_any(to)["node"]) == host.node_i:
					world.ki_spark(host.node_i, Vector2(o.x, o.y), float(ev["kx"]), float(ev["ky"]))
			else:
				Game.send_social(to, pid, str(b["name"]), "pvp_hit", {"dmg": int(ev["dmg"]), "kx": float(ev["kx"]), "ky": float(ev["ky"]), "crit": bool(ev["crit"]), "ki": bool(ev.get("ki", false)), "ch": f.ch})
		elif str(ev.get("type", "")) == "hit" and int(ev["enemy"]) >= 0 and allies() > 0:
			# a friendly CPU's blow on a foe: as a player's (its kill gives the players there their EXP)
			foe_hits += 1
			Game.hit_enemy(int(b["node"]), int(ev["enemy"]), int(ev["dmg"]), float(ev["kx"]), float(ev["ky"]), bool(ev["crit"]), int(ev.get("stun", 12)), ev.get("inflict", {}) if ev.get("inflict") is Dictionary else {})
			if ev.get("ki", false) and int(b["node"]) == host.node_i:
				for e in targets:
					if int(e["id"]) == int(ev["enemy"]):
						world.ki_spark(host.node_i, Vector2(float(e["x"]), float(e["y"])), float(ev["kx"]), float(ev["ky"]))
	_publish(pid, b)

## its state out to everyone, as a player's
func _publish(pid: int, b: Dictionary) -> void:
	var f = b["f"]
	var st: Dictionary = f.snapshot()
	st["bot"] = true
	if b.get("rival", false):
		st["foe"] = true      # a hero foe: everyone fights it, PVP or not (and it everyone)
	elif allies() > 0:
		st["ally"] = true      # (the foes go for it as for a player: Game.host_step)
	if hvv():
		st["hvv"] = true      # (the players' games learn the sides from it)
	st["node"] = int(b["node"])
	st["name"] = str(b["name"])
	st["k"] = int(b["k"])
	st["_t"] = Time.get_ticks_msec()
	Game.remote_states[pid] = st
	b["send"] = int(b["send"]) + 1
	if int(b["send"]) >= 2:
		b["send"] = 0
		Game.send_state(int(b["k"]), int(b["node"]), st, str(b["name"]))

## what it can hit: the other brawlers, and players here with PVP on (never the foes). A friendly CPU: only the foes
## near the host
func _targets(pid: int, b: Dictionary, host) -> Array:
	var out = []
	if allies() > 0:
		var key: String = Game.planet.nodes[int(b["node"])]["key"]
		for e in Game.area_states.get(key, []):
			if (int(e[9]) & 4) == 0 and Vector2(float(e[1]) - host.fighter.x, float(e[2]) - host.fighter.y).length() < NEAR:
				out.append({"id": int(e[0]), "x": float(e[1]), "y": float(e[2]), "alive": true, "big": (int(e[9]) & 16) != 0})
		for q in rivals:      # (the hero foes: fought as fighters)
			var rf = rivals[q]["f"]
			if int(rivals[q]["node"]) == int(b["node"]) and Vector2(rf.x - host.fighter.x, rf.y - host.fighter.y).length() < NEAR:
				out.append({"id": PVP_ID - q, "x": rf.x, "y": rf.y, "alive": rf.state != "down" and not rf.flying, "big": false})
		return out
	var side = Rules.is_villain(int(b["f"].ch))
	for q in bots:
		if q == pid or int(bots[q]["node"]) != int(b["node"]):
			continue
		if hvv() and Rules.is_villain(int(bots[q]["f"].ch)) == side:
			continue
		var o = bots[q]["f"]
		out.append({"id": PVP_ID - q, "x": o.x, "y": o.y, "alive": o.state != "down" and not o.flying, "big": false})      # (flying: nothing can reach it up there)
	for L in world.locals:
		if hvv() and Rules.is_villain(int(L.fighter.ch)) == side:
			continue
		if L.node_i == int(b["node"]) and L.fighter.pvp:
			out.append({"id": PVP_ID - Game.pid_of(1, L.k), "x": L.fighter.x, "y": L.fighter.y, "alive": L.fighter.state != "down" and not L.fighter.flying, "big": false})
	for q in Game.remote_states:
		var st: Dictionary = Game.remote_states[q]
		if st.get("bot", false) or int(st.get("node", -1)) != int(b["node"]) or not bool(st.get("pvp", false)) or bool(st.get("high", false)):
			continue
		if hvv() and Rules.is_villain(int(st.get("ch", -1))) == side:
			continue
		out.append({"id": PVP_ID - int(q), "x": float(st.get("x", 0)), "y": float(st.get("y", 0)), "alive": not bool(st.get("down", false)) and not bool(st.get("fly", false)), "big": false})
	return out

## a simple fighter's mind: pick the nearest one standing, go at them, punch close up, a ki blast from a little way
## off when lined up, now and then one of its own specials (beams held a while) - and never wander far from the host
func _think(b: Dictionary, f, targets: Array, host) -> Dictionary:
	if int(b.get("hold", 0)) > 0:      # a special going: the button held (a beam stays out while it is)
		b["hold"] = int(b["hold"]) - 1
		return {"sp": true}
	var come = _follow(b, f, host)
	if not come.is_empty():
		return come
	b["think"] = int(b["think"]) - 1
	if int(b["think"]) <= 0:
		b["think"] = 20 + randi() % 20
		b["tgt"] = -1
		var best = 999999.0
		for e in targets:
			if not e["alive"]:
				continue
			var d = Vector2(float(e["x"]) - f.x, float(e["y"]) - f.y).length()
			if d < best and d < NEAR:
				best = d
				b["tgt"] = int(e["id"])
	var goal = _spot(b, host)
	var tgt = null
	for e in targets:
		if int(e["id"]) == int(b["tgt"]) and e["alive"]:
			tgt = e
	var inp = {}
	if tgt == null:
		# no one to fight: it stays put, unless it is well away from its own place round the host (then it walks there,
		# not after every step the host takes)
		b["home"] = bool(b.get("home", false)) and Vector2(goal.x - f.x, goal.y - f.y).length() > 12.0 or Vector2(goal.x - f.x, goal.y - f.y).length() > 100.0
		if bool(b["home"]):
			_walk(inp, Vector2(goal.x - f.x, goal.y - f.y))
		return inp
	return _fight(b, f, tgt)

## fighting the one it picked (a brawler's, a CPU's, a hero foe's): with fists up close, or keeping off in line for
## ki blasts and its specials, a beam back at a beam
func _fight(b: Dictionary, f, tgt: Dictionary) -> Dictionary:
	var inp = {}
	var dv = Vector2(float(tgt["x"]) - f.x, float(tgt["y"]) - f.y)
	var ax = absf(dv.x); var ay = absf(dv.y)
	# its mood, now and then changed: up close with fists, or keeping off in line for blasts and specials
	b["mood_t"] = int(b.get("mood_t", 0)) - 1
	if int(b["mood_t"]) <= 0:
		b["mood_t"] = 120 + randi() % 180
		b["ranged"] = randf() < 0.4
	# a beam coming at it (being charged, or out): one of its own back at once, if it has one ready - the beams meet
	# in a clash (as near in line as a clash takes). Slow to answer, the first beam would hit it while it charges
	if ((ax > ay and ay < Clash.ROWS) or (ay > ax and ax < Clash.ROWS)) and maxf(ax, ay) > 30.0 and maxf(ax, ay) < 280.0 and not f.busy() and _beam_at(int(tgt["id"]), float(tgt["x"]), float(tgt["y"]), f) and _special(b, f, true):
		_face(inp, f, dv)
		inp["sp"] = true
		return inp
	# in line with them (a little slack once there, so a pixel or two of drift does not send it back and forth)
	var slack = 16.0 if bool(b.get("lined", false)) else 8.0
	var lined = ay < slack and ax > 40.0 and ax < 240.0 or ax < slack and ay > 40.0 and ay < 240.0
	b["lined"] = lined
	var ranged = bool(b.get("ranged", false))
	# once in line it stands its ground a second or so before moving again (as a player would - not a step for every
	# step they take)
	b["stand"] = maxi(0, int(b.get("stand", 0)) - 1)
	if ranged and lined and int(b["stand"]) == 0 and not bool(b.get("was_lined", false)):
		b["stand"] = 45 + randi() % 45
	b["was_lined"] = lined
	if ranged and not lined and int(b["stand"]) > 0 and ax < 260.0 and ay < 260.0:
		_face(inp, f, dv)
		return inp
	if ranged and not lined:
		# which side of them it lines up on: chosen, then kept a while (both of them moving would turn it each tick)
		b["side_t"] = int(b.get("side_t", 0)) - 1
		if int(b["side_t"]) <= 0 or int(b.get("side_of", -1)) != int(tgt["id"]):
			b["side_t"] = 60 + randi() % 60
			b["side_of"] = int(tgt["id"])
			b["side"] = Vector2(110.0 if f.x > float(tgt["x"]) else -110.0, 0.0) if ax >= ay else Vector2(0.0, 110.0 if f.y > float(tgt["y"]) else -110.0)
		var spot = Vector2(float(tgt["x"]), float(tgt["y"])) + b["side"]
		_walk(inp, spot - Vector2(f.x, f.y))
		return inp
	if ax < 22.0 and ay < 14.0:
		# close up: face them and punch (a press, let go, press)
		_face(inp, f, dv)
		b["a"] = not b["a"]
		inp["a"] = b["a"]
	elif lined and not f.busy() and randi() % 25 == 0 and _special(b, f):
		# lined up further off: turn to them and let a special go
		_face(inp, f, dv)
		inp["sp"] = true
	elif lined and ax < 150.0 and ay < 150.0 and f.ep > f.maxep / 4 and randi() % 30 == 0:
		# lined up a little way off: turn to them and send a ki blast
		_face(inp, f, dv)
		inp["b"] = true
	elif ranged:
		_face(inp, f, dv)      # in line and keeping off: it stands, turned to them, until its moment
	else:
		_walk(inp, dv)
	return inp

## its own place round the host (each a different one, changed now and then): where it heads with no one to fight
func _spot(b: Dictionary, host) -> Vector2:
	b["spot_t"] = int(b.get("spot_t", 0)) - 1
	if int(b["spot_t"]) <= 0 or not b.has("spot"):
		b["spot_t"] = 240 + randi() % 240
		b["spot"] = Vector2.from_angle(randf() * TAU) * randf_range(90.0, 220.0)
	return Vector2(host.fighter.x, host.fighter.y) + b["spot"]

## coming after the host as a player would: sprinting when a way off, flying when the host flies or is far (boosting
## when further still), landing once caught up on ground it can stand on. Empty: close enough, it fights
func _follow(b: Dictionary, f, host) -> Dictionary:
	var hf = host.fighter
	var goal = _spot(b, host)
	var dv = goal - Vector2(f.x, f.y)
	var d = dv.length()
	var inp = {}
	if f.flying:
		# caught up: down again (the host may still be up there - it lands all the same, as a player would)
		if d < 60.0 and f._under(f.x, f.y) & 4 == 0:      # (over a wall or water: landing puts it on the ground near)
			b["flyp"] = not bool(b.get("flyp", false))      # (a press, let go, press: the fly button lands)
			inp["fly"] = b["flyp"]
			return inp
		b["flyp"] = false
		if d > 12.0:
			_walk(inp, dv)
		inp["tr"] = d > 260.0 or hf.fly_boost      # the flying boost
		return inp
	# the host near (a screen or so): it stays and fights - only far off does it come after them, sprinting, or
	# flying when further still (or when the host went off flying)
	var dh = Vector2(hf.x - f.x, hf.y - f.y).length()
	if dh < FOLLOW:
		b["flyp"] = false
		return {}
	if f.busy():
		return {}
	if hf.flying or dh > FOLLOW * 1.6:
		b["flyp"] = not bool(b.get("flyp", false))      # up into the air
		inp["fly"] = b["flyp"]
		return inp
	_walk(inp, dv)
	inp["run"] = true      # a sprint to catch up
	return inp

## a special it can use now (unlocked, the ki for it, not cooling down): chosen as a player chooses one, and how long
## to hold the button (a beam: through its charge, then a second or two out)
func _special(b: Dictionary, f, beam_only: bool = false) -> bool:
	var u: Array = f.unlocked_skills()
	var ok = []
	for i in u.size():
		var sk: Dictionary = u[i]
		if beam_only and str(sk.get("type", "")) != "beam":
			continue
		if not f.cooldowns.has(str(sk["id"])) and f.ep >= int(sk.get("ep", 0)):
			ok.append(i)
	if ok.is_empty():
		return false
	var i = ok[randi() % ok.size()]
	f.skill_i = i
	specials += 1
	var sk2: Dictionary = u[i]
	b["hold"] = int(sk2.get("charge", 20)) + 60 + randi() % 60 if str(sk2.get("type", "")) == "beam" or sk2.has("rom") else 4
	return true

## the one it fights is letting a beam go sideways at it: charging one (in the beam pose) or with it out
const BEAM_POSE = 18
func _beam_at(tid: int, tx: float, ty: float, f) -> bool:
	var q = PVP_ID - tid
	var d = -1
	var beam = {}
	var pose = false
	if bots.has(q):
		var of = bots[q]["f"]
		d = of.dir
		beam = Clash._beam_of(of.shots, d)
		pose = of.beaming()
	else:
		var L = world._local_of(q % 8) if q / 8 == Game.my_id() else null
		if L != null:
			d = L.fighter.dir
			beam = Clash._beam_of(L.fighter.shots, d)
			pose = L.fighter.beaming()
		elif Game.remote_states.has(q):
			var st: Dictionary = Game.remote_states[q]
			d = int(st.get("dir", 0))
			beam = Clash._beam_snap(st.get("shots", []), d)
			pose = bool(st.get("beaming", false)) or int(st.get("anim", -1)) == BEAM_POSE      # (older games: the beam pose)
	return (pose or not beam.is_empty()) and ((d == 3 and f.x > tx) or (d == 2 and f.x < tx) or (d == 0 and f.y > ty) or (d == 1 and f.y < ty))

## turned to them: the way pressed only while not facing it (a tap turns a fighter without a step)
static func _face(inp: Dictionary, f, dv: Vector2) -> void:
	if absf(dv.x) > absf(dv.y):
		inp["right" if dv.x > 0 else "left"] = f.dir != (3 if dv.x > 0 else 2)
	else:
		inp["down" if dv.y > 0 else "up"] = f.dir != (0 if dv.y > 0 else 1)

static func _walk(inp: Dictionary, dv: Vector2) -> void:
	if absf(dv.x) > 4.0:
		inp["right" if dv.x > 0 else "left"] = true
	if absf(dv.y) > 4.0:
		inp["down" if dv.y > 0 else "up"] = true

## a player's blow (or another brawler's, or a hero foe's) on a brawler: as a player in PVP takes it. Who threw it
## (attacker_pid, its ch and name): only given for a genuine BRAWL / HEROES VS VILLAINS blow, so it can be scored -
## left out for a hero foe's (never scored; see _rival_think / _step_rival). The kill goes to whoever dealt the most
## damage since it was last at full health (Rules.top_attacker), not just whoever landed the finishing blow
func _hurt(pid: int, dmg: int, kx: float, ky: float, attacker_pid: int = -1, attacker_ch: int = -1, attacker_name: String = "") -> void:
	var b: Dictionary = _any(pid)
	var f = b["f"]
	if f.invuln > 0 or f.state == "down" or f.flying:
		return
	var real_dmg = Rules.pvp_damage(dmg, f.maxhp)
	f.take_hit(real_dmg, kx, ky)
	if b.get("rival", false) or attacker_pid == -1:
		return
	var dt: Dictionary = b.get("dmg_taken", {})
	var row: Dictionary = dt.get(attacker_pid, {"dmg": 0})
	row["dmg"] = int(row["dmg"]) + real_dmg; row["ch"] = attacker_ch; row["name"] = attacker_name
	dt[attacker_pid] = row
	b["dmg_taken"] = dt
	if f.state == "down":
		var top = Rules.top_attacker(dt)
		b["dmg_taken"] = {}      # (its next life starts a fresh ledger)
		if not top.is_empty():
			Game.report_pvp_kill(int(top[0]), int(top[1]), str(top[2]))

## a player's message to a brawler (Game.bot_social): only their PVP blows mean anything
func _social_in(pid: int, from_pid: int, from_name: String, kind: String, data: Dictionary) -> void:
	var b: Dictionary = _any(pid)
	if b.is_empty():
		return
	if kind == "pvp_hit":
		_hurt(pid, int(data.get("dmg", 1)), float(data.get("kx", 0)), float(data.get("ky", 0)), from_pid, int(data.get("ch", -1)), from_name)
	elif kind == "clash_taps":
		# a player's beam locked with ours (their game saw it first): the clash is on here too
		if b.get("clash", {}).is_empty():
			if Clash._beam_of(b["f"].shots, b["f"].dir).is_empty():
				return
			_clash_start(pid, b, from_pid)
		if int(b["clash"]["with"]) == from_pid:
			b["clash"]["theirs"] = maxi(int(b["clash"]["theirs"]), int(data.get("n", 0)))
			b["clash"]["heard"] = int(b["clash"]["t"])
	elif kind == "clash_end" and int(b.get("clash", {}).get("with", -1)) == from_pid:
		_clash_finish(pid, b, bool(data.get("you_won", false)))

# ---- BEAM CLASHES (clash.gd, the players' own): a brawler's beam locked with another's - a brawler's (the host plays
# both) or a player's (their game keeps its side, the lower id says who won). A brawler "taps" at its own pace
const Clash = preload("res://scripts/clash.gd")

func _clash_start(pid: int, b: Dictionary, with: int) -> void:
	b["clash"] = {"with": with, "t": 0, "mine": 0, "theirs": 0, "ref": pid < with, "rate": randf_range(0.095, 0.115)}      # a steady ~6 taps/second - a real fight, not a dice roll (was 0.08-0.17: anywhere from a crawl to faster than a human can mash)
	b["hold"] = 0

## two brawlers' beams meeting (the players' games find their own): the clash starts for both
func _clash_look(pid: int, b: Dictionary) -> void:
	var f = b["f"]
	if not b.get("clash", {}).is_empty():
		return
	var mine = Clash._beam_of(f.shots, f.dir)
	if mine.is_empty():
		return
	for q in bots:
		var o: Dictionary = bots[q]
		var of = o["f"]
		if q == pid or int(o["node"]) != int(b["node"]) or not o.get("clash", {}).is_empty() or of.state == "down":
			continue
		if not Clash.lined_up(f.dir, Vector2(f.x, f.y), of.dir, Vector2(of.x, of.y)):
			continue
		if hvv() and Rules.is_villain(int(f.ch)) == Rules.is_villain(int(of.ch)):
			continue
		var theirs = Clash._beam_of(of.shots, of.dir)
		if theirs.is_empty():
			continue
		if Clash.heads_met(f.dir, mine["head"], theirs["head"]):
			_clash_start(pid, b, q)
			_clash_start(q, o, pid)
			return

## a tick of a brawler's clash: true while it is held in it
func _clash_step(pid: int, b: Dictionary, host) -> bool:
	var c: Dictionary = b.get("clash", {})
	if c.is_empty():
		return false
	var f = b["f"]
	var with = int(c["with"])
	var other = world._pos_of_pid(with)
	if other == null or bool(other["down"]) or f.state == "down" or Clash._beam_of(f.shots, f.dir).is_empty():
		_clash_end(pid, b)
		return false
	c["t"] = int(c["t"]) + 1
	if randf() < float(c["rate"]):
		c["mine"] = int(c["mine"]) + 1
	if bots.has(with):
		c["theirs"] = int(bots[with].get("clash", {}).get("mine", c["theirs"]))
		c["heard"] = int(c["t"])      # (both here: never quiet)
	elif int(c["t"]) % 6 == 0:
		Game.send_social(with, pid, str(b["name"]), "clash_taps", {"n": int(c["mine"])})
	# no time limit: the beam eats ki as a held one does, and out of ki it gives out (clash.gd)
	if int(c["t"]) % FighterSim.BEAM_DRAIN_TICKS == 0:
		f.ep = maxi(0, f.ep - 1)
	if f.ep <= 0:
		if bots.has(with):
			_clash_finish(with, bots[with], true)
		else:
			Game.send_social(with, pid, str(b["name"]), "clash_end", {"you_won": true})
		_clash_finish(pid, b, false)
		return false
	# the clash point between them, pushed by the taps: our beam's head kept on it, sparks where they meet
	var lead = clampi(int(c["mine"]) - int(c["theirs"]), -Clash.LEAD, Clash.LEAD)
	var k = 0.5 + 0.4 * float(lead) / float(Clash.LEAD)
	var me = Vector2(f.x, f.y)
	var them = Vector2(float(other["x"]), float(other["y"]))
	var p = Clash.clash_point(f.dir, me, them, k, Clash.meet(f, with, Vector2((me.x + them.x) * 0.5, (me.y + them.y) * 0.5 - 14.0), world))
	Clash.pin_head(f.shots, f.dir, p)
	if int(b["node"]) == host.node_i and bool(c["ref"]) and bots.has(with):
		# two brawlers: the sparks here (with a player, their game shows them)
		var mc = Clash._beam_of(f.shots, f.dir).get("col", Color(1, 1, 1))
		var tc = Clash._beam_of(bots[with]["f"].shots, bots[with]["f"].dir).get("col", Color(1, 1, 1))
		var vert = Rules.dir_vec(f.dir).x == 0.0
		var first = (me.y < them.y) if vert else (me.x < them.x)
		world.clash_burst(host.node_i, p, mc if first else tc, tc if first else mc, vert)
	if bool(c["ref"]) and absi(int(c["mine"]) - int(c["theirs"])) >= Clash.LEAD:
		var won = int(c["mine"]) >= int(c["theirs"])
		if bots.has(with):
			_clash_finish(with, bots[with], not won)
		else:
			Game.send_social(with, pid, str(b["name"]), "clash_end", {"you_won": not won})
		_clash_finish(pid, b, won)
	elif int(c["t"]) - int(c.get("heard", 0)) > Clash.QUIET:
		_clash_end(pid, b)      # (the other went quiet: it just ends)
	return true

## the clash decided: the loser takes the winner's beam (a quarter of its health)
func _clash_finish(pid: int, b: Dictionary, won: bool) -> void:
	var f = b["f"]
	if won:
		clashes += 1
	if not won:
		var other = world._pos_of_pid(int(b.get("clash", {}).get("with", -1)))
		var kb = Clash.knock(f.dir, Vector2(f.x, f.y), Vector2(float(other["x"]), float(other["y"])) if other != null else Vector2(f.x, f.y) + Rules.dir_vec(f.dir))
		f.invuln = 0
		f.take_hit(maxi(1, roundi(f.maxhp * Clash.HIT)), kb.x, kb.y)
	_clash_end(pid, b)

func _clash_end(_pid: int, b: Dictionary) -> void:
	var f = b["f"]
	b["clash"] = {}
	b["hold"] = 0
	f.shots = f.shots.filter(func(s): return int(s.get("kind", 0)) != 1 and int(s.get("kind", 0)) != 5)
	if f.state == "skill":
		f._skill_done()

## a brawler or a hero foe by its id ({} for neither)
func _any(pid: int) -> Dictionary:
	return bots.get(pid, rivals.get(pid, {}))

# ---- HERO FOES: the game's own Frieza, Cell, Cooler and the Androids standing in the world fight as the heroes do -
# a fighter as the brawlers (their moves, specials, beams - a beam clash with a player's), guarding its post, against
# every player there, PVP or not, levelled to the players. It is still the foe: beaten, it is killed (EXP and loot to
# the players there) and comes back as foes do. Nobody near: it stands at its post again, a foe as before. Not in a
# story (its scenes keep their own)
const FOE_HEROES = {9: "ANDROID 17", 11: "ANDROID 18", 30: "CELL", 34: "COOLER", 48: "FRIEZA"}      # the game's own sets
## a foe's sprite set -> [hero, set, name] (or []): the game's own sets above (the hero in its usual looks), or a
## villain's own set or one of its outfits (SEMI CELL...: worn as it is)
var _foe_heroes = {}
func _foe_hero(set_id: int) -> Array:
	if _foe_heroes.has(set_id):
		return _foe_heroes[set_id]
	var out = []
	if FOE_HEROES.has(set_id):
		var ch0 = Assets.CHARACTERS.find(FOE_HEROES[set_id])
		if ch0 >= 0:
			out = [ch0, -1, ""]
	else:
		for ch in Assets.CHARACTERS.size():
			if not out.is_empty() or not Rules.is_villain(ch):
				continue
			var hh = Mods.hero_entry(Assets.CHARACTERS[ch])
			if int(hh.get("set", -1)) == set_id:
				out = [ch, set_id, str(hh.get("name", Assets.CHARACTERS[ch]))]
			for o in Assets.outfits(ch):
				if out.is_empty() and o is Dictionary and int(o.get("set", -1)) == set_id:
					out = [ch, set_id, str(o.get("name", Assets.CHARACTERS[ch]))]
	_foe_heroes[set_id] = out
	return out
const FOE_WAKE = 480.0       # a player this near its post: out it comes
const FOE_SLEEP = 900.0      # nobody this near any more: back at its post
const FOE_AGGRO = 260.0      # who it goes for
const FOE_LEASH = 450.0      # this far from its post it goes back
var _rival_t = 0

func _rivals_tick() -> void:
	if Game.cfg.has("story"):
		return
	_rival_t += 1
	if _rival_t % 30 == 0:
		_rivals_wake()
	for pid in rivals.keys():
		if rivals.has(pid):
			_step_rival(pid, rivals[pid])

## the players' places, by the place they are in: node -> [[pid, Vector2, down, high, flying]]
func _players_by_node() -> Dictionary:
	var out = {}
	for L in world.locals:
		if not out.has(L.node_i):
			out[L.node_i] = []
		out[L.node_i].append([Game.pid_of(Game.my_id(), L.k), Vector2(L.fighter.x, L.fighter.y), L.fighter.state == "down", L.fighter.on_high(), L.fighter.flying])
	for pid in Game.remote_states:
		var st: Dictionary = Game.remote_states[pid]
		if st.get("bot", false):
			continue
		var nd = int(st.get("node", -1))
		if not out.has(nd):
			out[nd] = []
		out[nd].append([int(pid), Vector2(float(st.get("x", 0)), float(st.get("y", 0))), bool(st.get("down", false)), bool(st.get("high", false)), bool(st.get("fly", false))])
	return out

func _rivals_wake() -> void:
	var by_node = _players_by_node()
	for nd in by_node:
		if nd < 0 or nd >= Game.planet.nodes.size():
			continue
		var key: String = Game.planet.nodes[nd]["key"]
		var sim = Game.sims.get(key)
		if sim == null:
			continue
		for e in sim.awake:
			if not e["alive"] or e["state"] == "dying" or e.get("fighter", false):
				continue
			var fh = _foe_hero(int(e["set"]))
			if fh.is_empty() or Rules.not_ready(int(fh[0])):
				continue
			var ep = Vector2(float(e["x"]), float(e["y"]))
			for pl in by_node[nd]:
				if (pl[1] as Vector2).distance_to(ep) < FOE_WAKE:
					_rival_add(nd, key, sim, e, fh)
					break

func _rival_add(nd: int, key: String, sim, e: Dictionary, fh: Array) -> void:
	var ch = int(fh[0])
	var k = _free_k()
	var pid = Game.pid_of(1, k)
	var f = FighterSim.new()
	_set_level(f, ch)
	if int(fh[1]) > 0 and not Assets.sprite_set(int(fh[1])).is_empty():
		f.set_id = int(fh[1]); f.base_set = int(fh[1])      # (in the outfit the foe wears: SEMI CELL...)
	f.pvp = true
	f.area = sim.area
	f.revive(float(e["x"]), float(e["y"]))
	f.invuln = 0
	e["fighter"] = true
	rivals[pid] = {"f": f, "k": k, "name": str(fh[2]) if str(fh[2]) != "" else str(Mods.hero_entry(Assets.CHARACTERS[ch]).get("name", Assets.CHARACTERS[ch])), "node": nd, "rival": true, "key": key, "id": int(e["id"]),
		"home": Vector2(float(e.get("ox", e["hx"])), float(e.get("oy", e["hy"]))), "tgt": -1, "think": 0, "down_t": 0, "a": false, "b": false, "send": 0}

## back to the foe it stands for (nobody near, or beaten and gone)
func _rival_remove(pid: int) -> void:
	var b: Dictionary = rivals[pid]
	var sim = Game.sims.get(str(b["key"]))
	if sim != null and int(b["id"]) < sim.enemies.size():
		sim.enemies[int(b["id"])]["fighter"] = false
	rivals.erase(pid)
	Game.remote_states.erase(pid)
	Game.local_gone(int(b["k"]))

func _step_rival(pid: int, b: Dictionary) -> void:
	var f = b["f"]
	var sim = Game.sims.get(str(b["key"]))
	var e = sim.enemies[int(b["id"])] if sim != null and int(b["id"]) < sim.enemies.size() else null
	if e == null or (not e["alive"] and not bool(b.get("killed", false))):
		_rival_remove(pid)      # (the foe went some other way: a story, the place emptied)
		return
	if f.state == "down":
		if not bool(b.get("killed", false)):
			b["killed"] = true      # beaten: the foe it stands for is killed - EXP and loot to the players there
			Game.hit_enemy(int(b["node"]), int(b["id"]), int(e["hp"]) + 1, 0.0, 0.0, false, 0)
		b["down_t"] = int(b["down_t"]) + 1
		f.step({}, [])
		_publish(pid, b)
		if int(b["down_t"]) > 90:
			_rival_remove(pid)
		return
	# the players (and the friendly CPUs) here
	var players: Array = _players_by_node().get(int(b["node"]), [])
	var near = false
	var targets = []
	for pl in players:
		var d = (pl[1] as Vector2).distance_to(Vector2(f.x, f.y))
		near = near or d < FOE_SLEEP
		if not pl[2] and not pl[3] and not pl[4]:      # not down, not out of reach on high ground, not flying
			targets.append({"id": PVP_ID - int(pl[0]), "x": pl[1].x, "y": pl[1].y, "alive": true, "big": false})
	for q in bots:
		if Game.remote_states.get(q, {}).get("ally", false) and int(bots[q]["node"]) == int(b["node"]):
			var af = bots[q]["f"]
			targets.append({"id": PVP_ID - q, "x": af.x, "y": af.y, "alive": af.state != "down" and not af.flying, "big": false})
	if not near:
		_rival_remove(pid)
		return
	if _clash_step(pid, b, world.locals[0]):
		_publish(pid, b)
		return
	var inp = _rival_think(b, f, targets)
	f.step(inp, targets)
	for ev in f.events:
		if str(ev.get("type", "")) == "hit" and int(ev["enemy"]) <= PVP_ID:
			var to = PVP_ID - int(ev["enemy"])
			if not _any(to).is_empty():
				_hurt(to, int(ev["dmg"]), float(ev["kx"]), float(ev["ky"]))
			else:
				Game.send_social(to, pid, str(b["name"]), "pvp_hit", {"dmg": int(ev["dmg"]), "kx": float(ev["kx"]), "ky": float(ev["ky"]), "crit": bool(ev["crit"]), "ki": bool(ev.get("ki", false)), "foe": true})
	e["x"] = f.x; e["y"] = f.y      # (the foe where its fighter is: the other foes and the map know it there)
	_publish(pid, b)

## a hero foe's mind: the nearest player near it (or near its post) - fought as a brawler fights; nobody, or too far
## from its post: back there
func _rival_think(b: Dictionary, f, targets: Array) -> Dictionary:
	if int(b.get("hold", 0)) > 0:
		b["hold"] = int(b["hold"]) - 1
		return {"sp": true}
	var home: Vector2 = b["home"]
	b["think"] = int(b["think"]) - 1
	if int(b["think"]) <= 0:
		b["think"] = 20 + randi() % 20
		b["tgt"] = -1
		var best = 999999.0
		for t2 in targets:
			var d = Vector2(float(t2["x"]) - f.x, float(t2["y"]) - f.y).length()
			if d < best and (d < FOE_AGGRO or Vector2(float(t2["x"]), float(t2["y"])).distance_to(home) < FOE_AGGRO):
				best = d
				b["tgt"] = int(t2["id"])
	var tgt = null
	for t2 in targets:
		if int(t2["id"]) == int(b["tgt"]) and t2["alive"]:
			tgt = t2
	var inp = {}
	if tgt == null or Vector2(f.x, f.y).distance_to(home) > FOE_LEASH:
		if Vector2(f.x, f.y).distance_to(home) > 16.0:
			_walk(inp, home - Vector2(f.x, f.y))
		return inp
	return _fight(b, f, tgt)
