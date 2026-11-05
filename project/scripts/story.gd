class_name Story
extends RefCounted
## LoG2's own story scenes, read from your game at import (data/story.json: the game's scene records).
##
## A scene is a list of numbered records with an index after them (the index lists each record's address by
## number). A record: u16 number, u8 kind, then
##   kind 0: a little script - a stack machine (push numbers, maths, jumps, loops) calling the game's commands
##   kind 1: a line of the text box - one byte says who speaks, then the words ('#' in front: a new box)
##   kind 2: a long line, packed (the game's own LZ packer, unpacked by _unlz) - same speaker byte as kind 1
## In a line: '#' in front = a new box, "@^" in front = the narrator, byte 11 = the next box of the same speaker.
## The scripts are turned into EVENTS steps (events.gd plays them): wait, face, pose, move, fade, warp, say.
## Commands not known yet become {"do": "cart"} steps, which play as nothing (DEV TOOLS shows them).
## An event step {"do": "story", "table": "083b725c", "from": 16} plays the scene from that index entry on.

const BASE = 0x083B0000

static var rom := PackedByteArray()
static var tried = false
static var speakers = {}     # speaker byte -> the name the lines with that byte give ("GOHAN: ...")
static var cache = {}        # "story:table:from[:to]" -> the event

## the game's opening, checked against the original in mGBA (2026-10-27): the narration, the fire picture, the
## narration on black, Outside Pepper Town, the talk with Gohan, then Gohan's melee-boulder training instruction -
## table 6ec8 ends there. The two training rocks are ordinary breakables (place 1_1, data/breakables.json), broken
## with the same mechanic Free Play's rocks use; breaking the second one (scene 083b76d0) chains on into table
## 725c from entry 8 - verified against the real game, by eye and by ear, 2026-11-04 (see ROCK_CONTINUES below)
## [index table, first entry, entry to stop before (-1: to the end), hero to play, their look (sprite set; -1: theirs)]
const INTRO = [["083b8340", 0, -1, "TRUNKS", 3207], ["083b6ec8", 0, -1, "", -1]]      # 3207: the TEEN TRUNKS look (set 135 + flying frames)

## a scene that doesn't end the story on its own - it leads straight into another group, same place, same flags
## (chained in scene() below, which follows this until a table has no entry here). Not reached from the second
## training rock any more (083b76d0 ends the demo on its own now - see DEMO_END below); kept for table 725c's own
## continuation into 7adc, which a devtools test or a future continuation of the demo could still reach directly.
## - that 725c group ends the same way (Gohan's unseen death, blasts raining on him, Trunks finds him and
##   transforms); table 7adc picks up right there (entry 0) - verified against the real game, by eye and by
##   ear, 2026-11-04
const SCENE_CONTINUES = {"083b725c:8": ["083b7adc", 0]}

## where the demo ends, right after Trunks' second failed Super Saiyan attempt (story.scene table 083b76d0, entry
## 0, step 26 on) - a goodbye from Future Gohan, in character, instead of the game's own continuation
const DEMO_END = [
	{"do": "say", "who": "", "text": "It's okay, Divinakra. Maybe someone else will come along in the future who has the time and energy to rebuild the whole story mode in Godot.", "narrate": false, "black": false, "speaker": 57, "at": ""},
	{"do": "say", "who": "", "text": "For now, just have fun playing the online multiplayer in the beautiful open world you spent so much time creating...", "narrate": false, "black": false, "speaker": 57, "at": ""},
	{"do": "say", "who": "", "text": "...using that wonderful map editor you gave to the community for free.", "narrate": false, "black": false, "speaker": 57, "at": ""},
	{"do": "say", "who": "", "text": "You're right, Gohan. I've spent a lot of time watching the story mode and taking notes from the GBA game, trying to rebuild it in Godot.", "narrate": false, "black": false, "speaker": 1, "at": ""},
	{"do": "say", "who": "", "text": "But it's too difficult and time consuming, and my passions are moving onto different projects... Maybe someone else who is passionate about the story mode will find this game and rebuild it themselves.", "narrate": false, "black": false, "speaker": 1, "at": ""},
	{"do": "say", "who": "", "text": "Yeah - you posted the source code to GitHub on your v45 release.", "narrate": false, "black": false, "speaker": 57, "at": ""},
	{"do": "say", "who": "", "text": "So if anyone wants to add the story mode and rebuild it in Godot, they can - and they can send you a pull request once they finish, for a v46 with the story mode.", "narrate": false, "black": false, "speaker": 57, "at": ""},
	{"do": "say", "who": "", "text": "Or they can just start a new GitHub repo, if they'd rather.", "narrate": false, "black": false, "speaker": 57, "at": ""},
	{"do": "say", "who": "", "text": "That's a great idea. I'm totally okay with other people forking this repo, sending pull requests, or making their own repo with this same game.", "narrate": false, "black": false, "speaker": 1, "at": ""},
	{"do": "say", "who": "", "text": "I don't claim ownership over this game, this engine, or these assets. I simply rebuilt the game in Godot using the original assets. This game belongs to the community.", "narrate": false, "black": false, "speaker": 1, "at": ""},
	{"do": "demo_end", "title": "THANK YOU FOR TRYING THE DEMO", "lines": ["", "DIVINAKRA WILL NO LONGER BE DEVELOPING", "THE STORY MODE ASPECT OF THIS GAME.", "", "HE WILL LEAVE IT UP TO THE COMMUNITY", "TO CONTINUE IF THEY WISH.", "", "", "P.S. THERE IS A STORY MODE CREATOR", "BUILT INTO THE MAP EDITOR.", "", "SEE THE STORY MODE EDITOR GUIDE", "FOR HOW TO USE IT."]}
]

static var faces_rom := PackedByteArray()     # the text boxes' faces, packed (cartridge 0x086AF000 on)
static var faces_at = 0
static var face_pal := PackedColorArray()     # their 256 colours (index 0: see-through)
static var _faces = {}                         # face number -> texture
const FACE_TABLE = 0x083EC9F4                  # 107 entries: where each face is (its packed picture 8 bytes on)
## which face a line shows - the game's own rule (0x0800BDCC): the speaker byte 0 none; 1 the hero being played (the
## face of their form now: the game's form list, byte 1 its sprite set, byte 2 its face code - 0x08026440); 2-7 the
## party's characters in turn (their first form); 8 and over: face number (code - 8). Checked in mGBA: Trunks' lines
## (1, teen Trunks' form 18: code 0x67) show face 0x5F, future Gohan's (0x39) face 0x31.
static func face_for(code: int, hero_set: int = -1) -> int:
	if code <= 0:
		return -1
	if code >= 8:
		return code - 8
	var forms: Array = Assets.data.get("forms", [])
	if code == 1:
		var want = Assets.set_base(hero_set) if hero_set >= 0 else -1
		for i in mini(22, forms.size()):
			if int(forms[i][1]) == want:
				return face_for(int(forms[i][2]))
		return -1
	var fighters: Array = Assets.data.get("fighters", [])
	if code - 2 < fighters.size():
		var fm = int(fighters[code - 2].get("form", -1))
		if fm >= 0 and fm < forms.size():
			return face_for(int(forms[fm][2]))
	return -1

static func ready() -> bool:
	if not tried:
		tried = true
		var d = Assets.json(Assets.base_dir.path_join("data/story.json"))
		if d is Dictionary and str(d.get("base", "")) == "083b0000":
			rom = str(d.get("hex", "")).hex_decode()
			faces_rom = str(d.get("faces", "")).hex_decode()
			faces_at = ("0x" + str(d.get("faces_base", "0"))).hex_to_int()
			var pb = str(d.get("face_pal", "")).hex_decode()
			for i in pb.size() / 2:
				var c = pb.decode_u16(i * 2)
				face_pal.append(Color8((c & 31) * 255 / 31, ((c >> 5) & 31) * 255 / 31, ((c >> 10) & 31) * 255 / 31, 0 if i == 0 else 255))
	return rom.size() > 0

## the text boxes' own backgrounds (160 x 64, frame, lines and the dark Z), one per style - the game's table at
## 0x083EC9BC (0x0800BAB4 unpacks style n into the box): 0 grey (the narrator), 1 green (the hero), 2 blue, 3 red
const BOX_TABLE = 0x083EC9BC
static var _boxes = {}
static func box(style: int) -> Texture2D:
	if _boxes.has(style):
		return _boxes[style]
	_boxes[style] = null
	if not ready() or face_pal.size() < 256 or style < 0 or style > 3:
		return null
	var px = _unlz(_u32(BOX_TABLE + 4 * style) + 8)
	if px.size() < 10240:
		return null
	var img = Image.create(160, 64, false, Image.FORMAT_RGBA8)
	for i in 10240:
		img.set_pixel(i % 160, i / 160, face_pal[px[i]])
	_boxes[style] = ImageTexture.create_from_image(img)
	return _boxes[style]

## which box a line gets - the game's rule (0x0800B1E2): speaker 0 grey; 1, or the party's character being played,
## green; these speakers red; anyone else blue
const RED_SPEAKERS = [0x1A, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x26, 0x27, 0x28, 0x31, 0x32, 0x35, 0x46, 0x54, 0x56, 0x60]
static func box_style(code: int, hero_ch: int = -1) -> int:
	if code in RED_SPEAKERS:
		return 3
	if code <= 0:
		return 0
	if code == 1 or (code >= 2 and code <= 7 and code - 2 == hero_ch):
		return 1
	return 2

## a text box's face (the game's own picture, 64 x 64 with its frame), or null
static func face(n: int) -> Texture2D:
	if _faces.has(n):
		return _faces[n]
	_faces[n] = null
	if not ready() or faces_rom.is_empty() or face_pal.size() < 256 or n < 0 or n >= 107:
		return null
	var at = _u32(FACE_TABLE + 4 * n) + 8
	if at < faces_at or at >= faces_at + faces_rom.size():
		return null
	var px = _unlz_in(faces_rom, faces_at, at)
	if px.size() < 4096:
		return null
	var img = Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for i in 4096:
		img.set_pixel(i % 64, i / 64, face_pal[px[i]])
	_faces[n] = ImageTexture.create_from_image(img)
	return _faces[n]

static func _ok(a: int, n: int = 1) -> bool:
	return a >= BASE and a + n <= BASE + rom.size()

static func _u8(a: int) -> int:
	return rom[a - BASE]

static func _u32(a: int) -> int:
	return rom.decode_u32(a - BASE)

static func _in_rom(v: int) -> bool:
	return v >= BASE and v < BASE + rom.size()

## a scene's index: one entry per record number - a record's address, or a small number
static func index(table: int) -> Array:
	var out = []
	var a = table
	while _ok(a, 4) and out.size() < 512:
		var v = _u32(a)
		if not (_in_rom(v) or v < 0x100):
			break
		out.append(v)
		a += 4
	return out

static func _text_at(a: int) -> String:
	var b = PackedByteArray()
	var p = a
	while _ok(p) and _u8(p) != 0 and b.size() < 400:
		b.append(_u8(p))
		p += 1
	return b.get_string_from_ascii()

## a line record's words (kind 1 plain, kind 2 packed)
static func _line(v: int) -> String:
	if _u8(v + 2) == 2:
		var b = _unlz(v + 4)
		var z = b.find(0)
		return (b.slice(0, z) if z >= 0 else b).get_string_from_ascii()
	return _text_at(v + 4)

## the game's own unpacker (ARM code the game runs from RAM; cartridge 0x087FD6BC), step for step: bits are read
## from 32-bit words, top bit first. 1: a letter (r3 bits + r4); 01: a copy (gamma length, r5-bit offset, or
## the last offset again); 001: one byte from up to 14 back, a 0, 256-letter runs, or a new letter size;
## 000: a short copy (7-bit offset, 2-bit length), a new offset size, or the end.
static var _w = 0
static var _n = 0
static var _p = 0
static var _src := PackedByteArray()      # the block being unpacked from, and where it starts in the cartridge
static var _src_at = 0

static func _rd(a: int) -> int:
	var o = a - _src_at
	return _src.decode_u32(o) if o >= 0 and o + 4 <= _src.size() else 0

static func _bit() -> int:
	_n -= 1
	if _n < 0:
		_w = _rd(_p); _p += 4; _n = 31
	var c = (_w >> 31) & 1
	_w = (_w << 1) & 0xFFFFFFFF
	return c

static func _bits(n: int) -> int:
	if _n == 0:
		_w = _rd(_p); _p += 4; _n = 32
	var k = mini(n, _n)
	var r = (_w >> (32 - k)) if k > 0 else 0
	_w = (_w << k) & 0xFFFFFFFF
	_n -= k
	n -= k
	if n == 0:
		return r
	_w = _rd(_p); _p += 4; _n = 32 - n
	r = (r << n) + (_w >> (32 - n))
	_w = (_w << n) & 0xFFFFFFFF
	return r

static func _gamma() -> int:
	var v = 1
	while true:
		v = v * 2 + _bit()
		if _bit() == 0:
			return v
	return v

static func _unlz(src: int) -> PackedByteArray:
	return _unlz_in(rom, BASE, src)

static func _unlz_in(block: PackedByteArray, block_at: int, src: int) -> PackedByteArray:
	_src = block; _src_at = block_at
	var out = PackedByteArray()
	_p = src; _w = 0; _n = 0
	var obits = 8
	var last = 1
	var lbits = 8
	var lbase = 0
	var k1 = 0x37FF     # where far copies get longer (the unpacker's own two constants, 0x087FD9A4 / 0x087FD9A8)
	var k2 = 0x27F
	while out.size() < 16384 and _p - _src_at + 4 <= _src.size():
		if _bit():
			out.append((_bits(lbits) + lbase) & 0xFF)
			continue
		var n = 0
		if _bit():
			var g = _gamma()
			if g == 2:
				n = _gamma()
			else:
				last = _bits(obits) + ((g - 3) << obits)
				n = _gamma()
				if last >= 0x10000: n += 3
				elif last >= k1: n += 2
				elif last >= k2: n += 1
				elif last <= 127: n += 4
		elif _bit():
			var r = _bits(4) - 1
			if r == 0:
				out.append(0)
			elif r > 0:
				out.append(out[out.size() - r] if r <= out.size() else 0)
			elif _bit():
				while true:
					for k in 256:
						out.append(_bits(8))
					if _bit() == 0:
						break
			else:
				lbits = 7 + _bit()
				lbase = _bits(8) if lbits != 8 else 0
			continue
		else:
			var r7 = _bits(7)
			if r7 == 0:
				var q = _bits(2)
				if q == 0:
					break
				obits = _bits(q + 3)
				continue
			last = r7
			n = _bits(2) + 2
		if last > out.size():
			break
		for k in n:
			out.append(out[out.size() - last])
	return out

## who speaks a line: its own "NAME: " or the name the other lines with the same byte give
static func _learn_speakers(ix: Array) -> void:
	for v in ix:
		if _in_rom(v) and _ok(v, 4) and _u8(v + 2) in [1, 2]:
			var t = _line(v).trim_prefix("#")
			var c = t.find(": ")
			if c > 0 and c <= 22 and t.substr(0, c) == t.substr(0, c).to_upper():
				speakers[_u8(v + 3)] = t.substr(0, c)

## the scene from index entry `from` on, as an event; it ends at the first entry that is not a record
static func event(id: String) -> Dictionary:
	if cache.has(id):
		return cache[id]
	if id == "story:intro":
		if not ready():
			return {}
		var all = [{"do": "music", "name": "rom:7"}]      # the opening's song, as the new game starts
		var hero = ""
		var place = {}      # (carried on: the talk's group moves Gohan in the place the group before went to)
		for g in INTRO:
			if g[3] != "":
				hero = g[3]
				all.append({"do": "switch_hero", "hero": g[3], "look": g[4]})
			for s in _group(("0x" + str(g[0])).hex_to_int(), int(g[1]), int(g[2]), place):
				if s["do"] == "say":
					s = s.duplicate()
					s["mine"] = str(s["who"]) == hero      # the hero's own lines: their box (face left, green)

				all.append(s)
		all.append({"do": "end"})
		cache[id] = {"id": id, "name": "STORY: THE OPENING", "once": false, "steps": all}
		return cache[id]
	var parts = id.split(":")
	if parts.size() < 3 or not ready():
		return {}
	var steps = _group(("0x" + parts[1]).hex_to_int(), int(parts[2]), int(parts[3]) if parts.size() > 3 else -1, {})
	steps.append({"do": "end"})
	var e = {"id": id, "name": "STORY " + id, "once": false, "steps": steps}
	cache[id] = e
	return e

## one scene group's steps, from index entry `from` to before `stop` (-1: its end); `place` = where the scene is
static var _flags = {}      # the player's story flags while a scene is turned into steps (f13 / f14 read them, f1b sets)

## a scene group played from entry `from` with these story flags ("story:N": the game's flag N) - its branches
## ("if flag N", "go on at record N") followed as the game would; `place` = the place it happens in ({"at": offset})
static func scene(table: int, from: int, flags: Dictionary, place: Dictionary) -> Dictionary:
	if not ready():
		return {}
	_flags = flags.duplicate()
	var p = place.duplicate()
	var steps = _group(table, from, -1, p)
	if table == ("0x083b76d0").hex_to_int() and from == 0:
		# where the demo ends: right after Trunks' second failed Super Saiyan attempt (steps 0-25 - both real,
		# verified attempts) - cut before the game's own continuation (the Androids, the fight, Gohan's death),
		# which needs more work (sprites, a second map, more ROM research) than one session can respectably finish
		steps = steps.slice(0, 26)
		steps.append_array(DEMO_END)
		steps.append({"do": "end"})
		var did = "story:%08x:%d:-1:demo" % [table, from]
		cache[did] = {"id": did, "name": "STORY DEMO END", "once": false, "steps": steps}
		return cache[did]
	var t0 = table; var f0 = from
	var guard = 0
	while guard < 8:
		guard += 1
		var on = SCENE_CONTINUES.get("%08x:%d" % [t0, f0], [])
		if on.is_empty():
			break
		t0 = ("0x" + str(on[0])).hex_to_int(); f0 = int(on[1])
		var more = _group(t0, f0, -1, p)
		if t0 == ("0x083b725c").hex_to_int():
			# Gohan commits to flying off to fight: the FUTURE GOHAN (CUTSCENE) look (3208) has his flying frames
			more.push_front({"do": "npc_set", "who": "#54", "set": 3208})
			for s in more:
				if s.get("do", "") == "move" and str(s.get("who", "")) == "#54":
					s["fly"] = true
		elif t0 == ("0x083b7adc").hex_to_int():
			# the fight and Gohan's death: this plays in "1_5", Outside Pepper Town's OTHER area (the rain, where
			# Trunks just woke up) - the game's own map data has no person there at all (he's only placed in "1_1"),
			# so without this he is simply missing: every move/pose/npc_set aimed at "#54" quietly does nothing
			more.push_front({"do": "show_person", "name": "GOHAN", "set": 54, "x": 10232.0, "y": 18560.0, "dir": "down"})      # near where Trunks wakes up (10232,18600)
			more.insert(1, {"do": "npc_set", "who": "#54", "set": 3208})
			var last_hit = -1      # the true last hit-reaction, not just the last "blast_hit" marker - one more
			for i in more.size():      # flinch (pose 2) follows the final blast_hit before the death choreography starts
				var s2: Dictionary = more[i]
				if (s2.get("do", "") == "blast_hit" or (s2.get("do", "") == "pose" and str(s2.get("who", "")) == "#54" and int(s2.get("pose", -1)) == 2)):
					last_hit = i
			if last_hit >= 0:
				more.insert(last_hit + 1, {"do": "pose", "who": "#54", "pose": 17, "loop": false})
		steps.append_array(more)
	steps.append({"do": "end"})
	var id = "story:%08x:%d:-1:%d" % [table, from, hash(flags.keys())]
	cache[id] = {"id": id, "name": "STORY %08x" % table, "once": false, "steps": steps}
	return cache[id]

static func _group(table: int, from: int, stop: int, place: Dictionary) -> Array:
	var ix = index(table)
	_learn_speakers(ix)
	var steps = []
	var i = from - 1
	var guard = 0
	while guard < 200:
		guard += 1
		i += 1
		if i >= (ix.size() if stop < 0 else mini(stop, ix.size())):
			break
		var v: int = ix[i]
		if not _in_rom(v):
			break
		var kind = _u8(v + 2)
		if kind == 0:
			var went = _script(v + 3, steps, place)
			if went == -2:
				break
			if went >= 0:      # the game's "go on at record N" (a branch): that entry next
				i = went - 1
		elif kind == 1 or kind == 2:
			var raw = _line(v)
			var at = "top" if raw.begins_with("!") else ("middle" if raw.begins_with("@") else "")
			var t = raw.trim_prefix("!").trim_prefix("#")
			var who = str(speakers.get(_u8(v + 3), ""))
			var narrate = t.begins_with("@")
			if narrate:
				t = t.trim_prefix("@").trim_prefix("^")
				who = ""
			elif t.begins_with(who + ": "):
				t = t.substr(who.length() + 2)
			for box in t.split(char(11)):
				box = box.strip_edges().trim_prefix("@").trim_prefix("^").strip_edges()
				if box != "":
					steps.append({"do": "say", "who": who, "text": box, "narrate": narrate, "black": narrate, "speaker": _u8(v + 3), "at": at})      # (the narrator: on black, as the game)
	return steps

## the varint of the scripts: 7 bits a byte, high bit = more; the low bit of the number is its sign
static func _num(p: Array) -> int:
	var v = 0
	while true:
		var b = _u8(p[0]); p[0] += 1
		v = (v << 7) + (b & 0x7F)
		if b & 0x80 == 0:
			break
	return -(v >> 1) if v & 1 else v >> 1

static func _who(c: int) -> String:
	return "PLAYER" if c == 0 else "#%d" % c      # 1-6: party, 7+: the map's people (not named yet)

## a place's own song number (the game's map list, kit/maps.json; -1: the land's usual song)
static var _songs = {}
static func _place_song(z: int, a: int) -> int:
	if _songs.is_empty():
		var j = Assets.json(Assets.base_dir.path_join("kit/maps.json"))
		var ms = j if j is Array else (j.get("maps", []) if j is Dictionary else [])
		for m in ms:
			_songs[str(m.get("key", ""))] = int(m.get("song", -1))
		_songs["-"] = -1
	return int(_songs.get("%d_%d" % [z, a], -1))

## a place of the game (zone, area) -> where it is in this game: [land key, offset]
static func _place(z: int, a: int) -> Array:
	var key = "%d_%d" % [z, a]
	for lz in 15:      # EARTH (0) first: every place is on it
		var L = Assets.land(lz)
		if L.is_empty():
			continue
		var regs: Array = L.get("regions", [])
		for r in regs.size():
			for m in regs[r].get("maps", []):
				if str(m[0]) == key:
					return ["land/%d/%d" % [lz, r], Vector2(float(m[1]), float(m[2]))]
	return []

## one script, run on a stack of known numbers: -1 done, N >= 0 go on at record N ("push N; END"), -2 stop here
static func _script(a: int, steps: Array, place: Dictionary) -> int:
	var st = []
	var p = [a]
	var guard = 0
	var last_push = false
	while _ok(p[0]) and guard < 400:
		guard += 1
		var op = _u8(p[0]); p[0] += 1
		var after_push = last_push
		last_push = op == 0x00 or op == 0x01
		match op:
			0x00:
				st.append(_u8(p[0])); p[0] += 1
			0x01:
				st.append(_num(p))
			0x1D:
				var n = _u8(p[0]); p[0] += 1
				for k in n:
					st.append(_num(p))
			0x02:
				var f = _u8(p[0]); p[0] += 1
				_command(f, st, steps, place)
			0x14:
				st.pop_back()
			0x04, 0x05, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10:
				var q = _pop(st, 2)
				st.append(_math(op, q[0], q[1]))
			0x06:
				st.append(-_pop(st, 1)[0])
			0x12:
				p[0] += 1 + _u8(p[0])
			0x13:
				var dist = _u8(p[0]); p[0] += 1
				if _pop(st, 1)[0] == 0:      # (game values count as 0 here)
					p[0] += dist
			0x15, 0x16, 0x17, 0x18, 0x19:
				p[0] += 1                    # the game's own counters: not kept here
			0x1A:
				p[0] += 1
				_pop(st, 1)
			0x11:
				return int(st.back()) if after_push and not st.is_empty() else -1
			_:
				steps.append({"do": "cart", "op": "%02x" % op, "at": "%08x" % (p[0] - 1)})
				return -2
	return -2

static func _math(op: int, a: int, b: int) -> int:
	match op:
		0x04: return int(a != 0 and b != 0)
		0x05: return int(a != 0 or b != 0)
		0x07: return a + b
		0x08: return a - b
		0x09: return a * b
		0x0A: return a / b if b != 0 else 0
		0x0B: return int(a == b)
		0x0C: return int(a != b)
		0x0D: return int(a > b)
		0x0E: return int(a >= b)
		0x0F: return int(a < b)
	return int(a <= b)

static func _pop(st: Array, n: int) -> Array:
	var out = []
	for k in n:
		out.push_front(int(st.pop_back()) if not st.is_empty() else 0)
	return out

## how many numbers each command takes off the stack, and which leave one (read from the commands' own code)
const POPS = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 3, 2, 1, 0, 5, 5, 0, 5, 5, 1, 1, 1, 1, 1, 0, 1, 1, 0, 1, 0, 3, 1, 3, 3, 2, 2, 2, 2, 0, 1, 0, 3, 0, 0, 2, 0, 0, 1, 1, 1, 4, 4, 2, 0, 0, 1, 2, 2, 1, 1, 1, 1, 2, 1, 1, 1, 1, 0, 4, 3, 1, 1, 1, 3, 1, 3, 0, 2, 4, 3, 2, 2, 4, 2, 0, 0, 0, 0, 2, 2, 2, 2, 0, 0, 1, 0, 4, 4, 0, 2, 2, 0, 0, 3, 0, 0, 1, 2, 0, 0, 0, 0, 0, 3, 5, 4, 2, 0, 1, 2, 1, 3, 1, 2]
const PUSHES = [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x4b, 0x7e, 0x81, 0x83, 0x84, 0x85, 0x8f]

static func _command(f: int, st: Array, steps: Array, place: Dictionary) -> void:
	match f:
		0x45:      # wait N frames
			steps.append({"do": "wait", "frames": _pop(st, 1)[0]})
		0x37:      # someone faces a way (down, up, left, right)
			var q = _pop(st, 2)
			steps.append({"do": "face", "who": _who(q[0]), "dir": clampi(q[1], 0, 3)})
		0x39:      # someone plays an animation of their sprite set (0: back to normal) - 23/24 (Trunks' SSJ attempts):
			# not a plain pose - the game's own "trying to transform" charge (anim 9, hair turning gold) the port
			# already has for the real hold-the-button transform. He fails every time in this scene (training AND
			# after Gohan's death) - his first real Super Saiyan is later, not shown here - so both play the charge
			# and hold there; the next pose/line always shows him back to normal, no separate "revert" step needed
			var q = _pop(st, 2)
			if q[0] == 0 and (q[1] == 23 or q[1] == 24):
				steps.append({"do": "pose", "who": "PLAYER", "pose": 9, "loop": false})
			else:
				steps.append({"do": "pose", "who": _who(q[0]), "pose": q[1] if q[1] > 0 else -1, "loop": false})
		0x35, 0x36:      # someone walks to x, y of the place: the game (0x08009D4A / 0x08009E30) adds the walk to that
			# person's own list of things to do and the scene goes straight on - no wait (Gohan walks off to the
			# boulders as you get the buttons back; verified in mGBA)
			var q = _pop(st, 3)
			if place.has("at"):
				var o: Vector2 = place["at"]
				steps.append({"do": "move", "who": _who(q[0]), "x": o.x + q[1], "y": o.y + q[2], "speed": 1.0, "wait": false})
			else:
				steps.append({"do": "cart", "op": "f%x" % f, "args": q})
		0x13, 0x14:      # is story flag N set (13) / not set (14) - the player's own flags
			var fl = _flags.has("story:%d" % _pop(st, 1)[0])
			st.append(int(fl if f == 0x13 else not fl))
		0x1B:      # story flag N set
			var fn = "story:%d" % _pop(st, 1)[0]
			_flags[fn] = true
			steps.append({"do": "flag", "name": fn, "on": true})
		0x2E:      # one of the game's sounds (imported: sounds/sfx_NN.wav)
			steps.append({"do": "sound", "id": _pop(st, 1)[0]})
		0x41:      # the screen shakes (a nearby blast) - seen at "What was that?!" and again as Trunks confronts Gohan,
			# matching the world.gd camera shake already used for crits; the 2nd number looks like frames but the
			# existing shake only has a magnitude (it decays on its own) - taken as the magnitude, frames unused
			var q = _pop(st, 2)
			steps.append({"do": "shake", "amount": q[0] / 5.0})
		0x60:      # a blast hits someone (Gohan's death at Outside Pepper Town, repeated ~7 times): source, who, ?
			var q = _pop(st, 3)
			steps.append({"do": "blast_hit", "who": _who(q[1])})
		0x28:      # the screen fades OUT over N frames (seen in mGBA: the fire picture dims away, 240 frames)
			steps.append({"do": "fade_out", "frames": _pop(st, 1)[0]})
		0x23, 0x26, 0x27:      # to a place of the game: zone, area, ?, x, y (23 and 26 fade first; 23: the fire picture is place 1_3)
			var q = _pop(st, 5)
			if f != 0x27:
				steps.append({"do": "fade"})
			steps.append({"do": "hide_player", "on": f == 0x23})      # (23: a picture place - the fire - without the hero)
			var pl = _place(q[0], q[1])
			if pl.is_empty():
				steps.append({"do": "cart", "op": "f27", "args": q})
			else:
				place["at"] = pl[1]
				steps.append({"do": "warp", "map": pl[0], "x": pl[1].x + q[3], "y": pl[1].y + q[4]})
				var song = _place_song(q[0], q[1])
				if song >= 0:      # the place's own song, as the game plays it on arriving (the fire picture: 7)
					steps.append({"do": "music", "name": "rom:%d" % song})
		_:
			steps.append({"do": "cart", "op": "f%02x" % f, "args": _pop(st, POPS[f] if f < POPS.size() else 0)})
			if f in PUSHES:
				st.append(0)       # a game value: not known here
