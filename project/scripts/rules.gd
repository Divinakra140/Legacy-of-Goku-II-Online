class_name Rules
## The battle feel, measured frame by frame on the original game (GBA, 60 frames a second):
##   walk 1.25 px/frame on each axis (diagonals too), 4 walk frames of 8 ticks
##   A: punch 16 ticks (4 frames x 4); a 4-hit chain punch/punch/punch/kick, the kick hits twice as hard;
##      hold A 16 ticks: the rushing strike (7 frames x 4, moves forward 1 px/tick)
##   B: ki blast - 24 ticks (frame 0 for 8, frame 1 for 16), the blast leaves at tick 8, flies 3 px/tick,
##      lives about 80 ticks; costs 2 EP
##   hurt: 16 ticks; enemies hit about once a second when next to you
##   damage: punches ~1.8 x STR, ki blasts ~2 x PWR (+-10%), 1 in 16 a double-damage critical;
##           what you take shrinks with END (x (1 - END/150))

const TICK = 1.0 / 60.0
const WALK_SPEED = 1.25
const DIRS = {"down": 0, "up": 1, "left": 2, "right": 3}

# animations of a fighter's sprite set (slot = anim * 4 + dir)
const A_IDLE = 0
const A_WALK = 1
const A_HURT = 2
const A_DOWN = 3
const A_CHARGE = 4
const A_KI = 5
const A_PUNCH1 = 6
const A_PUNCH2 = 7
const A_KICK = 8
const A_TRANSFORM = 9
const A_BORED = 14
const A_RUSH = 16
const A_DEAD = 17
const A_BEAM_CHARGE = 18
const A_BEAM = 19

const PUNCH_TICKS = 16
const PUNCH_FRAME_TICKS = 4
const CHAIN = [A_PUNCH1, A_PUNCH2, A_PUNCH1, A_KICK]
const CHAIN_WINDOW = 14        # ticks after an attack ends in which the next press continues the chain
const RUSH_HOLD = 16
const RUSH_TICKS = 28
const KI_TICKS = 24
const KI_FIRE_AT = 8
const KI_SPEED = 3.0
const KI_LIFE = 80
const KI_COST = 2
const BEAM_HOLD = 40           # hold B this long: the beam (Kamehameha / Masenko / Special Beam Cannon / Final Flash...)
const BEAM_COST = 8
const BEAM_SPEED = 5.0
const HURT_TICKS = 16
const INVULN_TICKS = 40
const DOWN_TICKS = 120
const EP_REGEN_TICKS = 150     # +1 EP every 2.5 s while not attacking

# enemy kinds the planets use (kSpawn of the PC mod: type, sprite set, group 1 human 2 animal 4 robot 8 big)
const SPAWN = [
	[8,17,1],[9,18,1],[10,19,1], [12,142,1],[51,143,1],[85,141,1], [69,90,1],[70,91,1],[71,92,1], [75,96,1],[86,98,1],
	[1,7,2], [58,63,2], [55,109,2],[92,108,2], [47,112,2],[90,113,2],[103,114,2], [14,116,2],[53,118,2],[83,115,2],[91,119,2],
	[54,125,2],[94,125,2], [102,144,2], [17,146,2],[74,146,2],[57,148,2],[104,149,2],
	[31,37,4],[32,38,4],[33,39,4], [37,44,4],[38,45,4],[39,46,4],[40,47,4], [65,77,4],[66,78,4],[67,79,4],
	[80,105,8],[88,106,8], [11,123,8],[16,124,8],[99,122,8], [101,127,8],
	# 45-49: the first game's enemies in the PC mod (their pictures come from the LoG1 game there) -
	# here the LoG2 enemy each one fought like
	[17,146,2],[8,17,1],[47,112,2],[54,125,2],[58,63,2]]
# enemy type -> sprite set (the game's own pairs)
const TYPE_SET = {1:7,3:9,7:14,8:17,9:18,10:19,12:142,14:116,16:124,17:146,26:31,31:37,32:38,33:39,37:44,38:45,39:46,40:47,
	47:112,51:143,53:118,54:125,55:109,57:148,58:63,65:77,66:78,67:79,69:90,70:91,71:92,74:146,75:96,80:105,83:115,85:141,
	86:98,88:106,90:113,91:119,92:108,94:125,99:122,101:127,102:144,103:114,104:149,11:123,
	# the bosses and the rest the game places only by hand (its own placements: kind -> the set it wears there)
	4:11,5:12,6:14,21:30,22:30,23:30,24:30,25:30,29:34,36:42,41:48,44:50,60:28,64:76,76:29,78:30,79:30,98:121,106:156}
const BIG_TYPES = [11, 16, 99, 80, 88, 31, 32, 33, 101]

static func group_of(t: int) -> String:
	if t in BIG_TYPES:
		return "big"
	for e in SPAWN:
		if int(e[0]) == t:
			return {1: "human", 2: "animal", 4: "robot", 8: "big"}.get(int(e[2]), "human")
	return "human"

## a blow from another player (PVP, BRAWL): content/social.json pvp - a share of its strength, at most a small part of
## the health (a long fight, like a boss's bar, not one beam and down)
static func pvp_damage(dmg: int, maxhp: int) -> int:
	var cfg: Dictionary = Content.social_cfg.get("pvp", {})
	return clampi(roundi(float(dmg) * float(cfg.get("damage", 0.25))), 1, maxi(1, roundi(maxhp * float(cfg.get("max_hit", 0.06)))))

## BRAWL / HEROES VS VILLAINS: the kill goes to whoever dealt the most damage since the fighter was last at full
## health, not whoever only landed the finishing blow - ledger: {attacker pid -> {"dmg", "ch", "name"}}. [] if nobody
static func top_attacker(ledger: Dictionary) -> Array:
	var best_pid = -1
	var best: Dictionary = {}
	for p in ledger:
		if best.is_empty() or int(ledger[p].get("dmg", 0)) > int(best.get("dmg", 0)):
			best = ledger[p]; best_pid = p
	return [] if best_pid == -1 else [best_pid, int(best.get("ch", -1)), str(best.get("name", "?"))]

## heroes you must earn: the level another hero needs first, or -1 for one not finished yet (never shown, never a brawler)
const LOCKED_HEROES = {"KING COLD": -1}
static func not_ready(ch: int) -> bool:
	return ch >= 0 and ch < Assets.CHARACTERS.size() and int(LOCKED_HEROES.get(str(Assets.CHARACTERS[ch]), 0)) < 0

## HEROES VS VILLAINS: the villains' side (everyone else is a hero)
const VILLAINS = ["ANDROID 17", "ANDROID 18", "CELL", "COOLER", "FRIEZA", "KING COLD"]
static func is_villain(ch: int) -> bool:
	return ch >= 0 and ch < Assets.CHARACTERS.size() and VILLAINS.has(str(Assets.CHARACTERS[ch]))

## the game's robots (spawn class 4): they go in a white ring when beaten, not the brown smoke
static func is_robot_set(set_id: int) -> bool:
	for e in SPAWN:
		if int(e[1]) == set_id and int(e[2]) == 4:
			return true
	return false

static func kind_to_type_set(k: int) -> Array:
	if k >= 1000:
		var s = SPAWN[clampi(k - 1000, 0, SPAWN.size() - 1)]
		return [s[0], s[1]]
	return [k, TYPE_SET.get(k, -1)]

# ------------------------------------------------------------------ numbers
static func hpf(L: int) -> float:
	return 10.0 + 12.0 * L + 0.9 * L * L

static func atf(L: int) -> float:
	return 4.0 + 1.0 * L

static func level_of(exp: int, levels: Array) -> int:
	var L = 1
	for i in range(1, min(levels.size(), 99)):
		if exp >= int(levels[i]):
			L = i + 1
		else:
			break
	return L

static func melee_damage(str_v: float, mult: float, rng: RandomNumberGenerator) -> Array:
	var d = 1.8 * str_v * mult * rng.randf_range(0.9, 1.1)
	var crit = rng.randi_range(0, 15) == 0
	if crit:
		d *= 2.0
	return [maxi(1, roundi(d)), crit]

static func ki_damage(pwr: float, mult: float, rng: RandomNumberGenerator) -> Array:
	var d = 2.0 * pwr * mult * rng.randf_range(0.9, 1.1)
	var crit = rng.randi_range(0, 15) == 0
	if crit:
		d *= 2.0
	return [maxi(1, roundi(d)), crit]

static func taken_damage(atk: float, end_v: float, rng: RandomNumberGenerator) -> int:
	return maxi(1, roundi(atk * maxf(0.25, 1.0 - end_v / 150.0) * rng.randf_range(0.92, 1.08)))

static func dir_vec(dir: int) -> Vector2:
	match dir:
		0: return Vector2(0, 1)
		1: return Vector2(0, -1)
		2: return Vector2(-1, 0)
		_: return Vector2(1, 0)
