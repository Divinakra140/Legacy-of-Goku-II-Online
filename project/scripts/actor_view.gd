class_name ActorView
extends Node2D
## Draws one frame of a sprite set (the game's own frames, from the import) at the object's point.

var set_data = {}
var anim = 0
var dir = 0
var frame = 0
var tint = Color(1, 1, 1, 1)
var flash = false          # hit: flashing red, as the game's foes do
var dying = false          # beaten: gone in the game's cloud of brown smoke (fx v_boom) - a robot's white ring (fx e_ring)
var robot = false
var _dying_ms = -1
var concealed = false
var size_scale = 1.0
var label = ""
var label_color = Color(1, 1, 1)
var hp_frac = 1.0          # under 1: a small health bar over the head
var bubble = ""            # a chat message over the head
var aura = Color(0, 0, 0, 0)   # a transformation's aura (alpha 0: none)
var halo = false:              # THE HERO OF EARTH: a golden halo over the head
	set(v):
		if v and not halo and not set_data.is_empty():
			for a2 in [0, 12]:      # (its spots found now, as it appears - not the first time it dives mid-flight)
				for d2 in 4:
					_halo_spot(a2, d2)
		halo = v
var set_id = -1
var hero = false           # a player's fighter: a villain hero shows the game's boss effects (red when hit, smoke when beaten)
var _dead_ms = -1

func set_sprite_set(d: Dictionary) -> void:
	set_data = d
	queue_redraw()

func frames_of(a: int, d: int) -> Array:
	if set_data.is_empty():
		return []
	var slots: Array = set_data["slots"]
	var s = a * 4 + d
	if s < 0 or s >= slots.size():
		return []
	return slots[s]

func show_frame(a: int, d: int, f: int) -> void:
	if a == 3 and anim != 3:
		_dead_ms = Time.get_ticks_msec()
	if a != anim or d != dir or f != frame or (hero and (a == 2 or a == 3) and set_data.get("villain_fx", false)):
		anim = a; dir = d; frame = f
		queue_redraw()

func _draw() -> void:
	if set_data.is_empty() or concealed:
		return
	var fr = frames_of(anim, dir)
	var a = anim
	if fr.is_empty():
		fr = frames_of(0, dir)
		a = 0
		if fr.is_empty():
			return
	var f: Dictionary = fr[frame % fr.size()]
	if aura.a > 0.0:
		# a flickering flame around the fighter
		var tt = Engine.get_physics_frames()
		# centred on the fighter's own pixels (not the sprite's box, which has empty room on one side)
		var bb = _opaque_box(f, frame % fr.size(), a * 4 + dir)
		var hgt = bb.size.y * size_scale
		var base = Vector2(f["x"] + bb.position.x + bb.size.x * 0.5, f["y"] + bb.position.y + bb.size.y * 0.55) * size_scale
		for i in 3:
			var k = (tt / 3 + i * 5) % 8
			var w = (bb.size.x * 0.5 + 5 + k) * size_scale
			var col = Color(aura.r, aura.g, aura.b, 0.18 + 0.06 * i)
			var pts = PackedVector2Array([base + Vector2(-w * 0.55, hgt * 0.5), base + Vector2(-w * 0.62, -hgt * 0.1),
				base + Vector2(-w * 0.25, -hgt * 0.62 - k), base + Vector2(0, -hgt * 0.8 - k * 1.5), base + Vector2(w * 0.25, -hgt * 0.62 - k),
				base + Vector2(w * 0.62, -hgt * 0.1), base + Vector2(w * 0.55, hgt * 0.5)])
			draw_colored_polygon(pts, col)
	var cell: int = set_data["cell"]
	var slot = a * 4 + dir
	var src = Rect2((frame % fr.size()) * cell, slot * cell, f["w"], f["h"])
	var dst = Rect2(Vector2(f["x"], f["y"]) * size_scale, Vector2(f["w"], f["h"]) * size_scale)
	var c = tint
	if flash:
		c = Color(c.r * 1.3, c.g * 0.35, c.b * 0.35, c.a)
	var dk = -1.0
	if dying:
		if _dying_ms < 0:
			_dying_ms = Time.get_ticks_msec()
		dk = clampf((Time.get_ticks_msec() - _dying_ms) / 660.0, 0.0, 1.0)      # (the game's 40 ticks)
		c.a *= clampf(1.0 - dk * 3.0, 0.0, 1.0)      # under the smoke at once
	else:
		_dying_ms = -1
	var smoke_k = -1.0
	if hero and set_data.get("villain_fx", false):
		if anim == 2 and (Time.get_ticks_msec() / 80) % 2 == 0:
			c = Color(c.r * 1.3, c.g * 0.35, c.b * 0.35, c.a)      # hit: flashing red, like the boss
		elif anim == 3 and _dead_ms >= 0 and set_data.get("smoke_down", false):
			smoke_k = clampf((Time.get_ticks_msec() - _dead_ms) / 1400.0, 0.0, 1.0)
			c.a *= clampf(1.6 - smoke_k * 2.0, 0.0, 1.0)              # beaten: gone in the smoke
	if c.a > 0.0:
		draw_texture_rect_region(set_data["tex"], dst, src, c)
	if halo and c.a > 0.0:
		# a golden-white ring floating over the head, bobbing a little, its glow pulsing
		var tt2 = Engine.get_physics_frames()
		# over the head - found once per pose and way (no hopping frame to frame): on the ground always the standing
		# pose's head (a tail, a cape or wings never pull it off), flying the head end of the flying pose (_halo_spot)
		var spot = _halo_spot(12 if a == 12 else 0, dir)
		var hc = (spot + Vector2(0, -4.0 - 1.0 * sin(tt2 * 0.08))) * size_scale
		var hr = 6.0 * size_scale      # (a head's width, whatever the pose: flying it grew to the whole body's)
		draw_set_transform(hc, 0.0, Vector2(1.0, 0.32))
		draw_arc(Vector2.ZERO, hr + 1.5, 0, TAU, 28, Color(1.0, 0.85, 0.3, 0.25 + 0.1 * sin(tt2 * 0.12) * c.a), 4.0)
		draw_arc(Vector2.ZERO, hr, 0, TAU, 28, Color(1.0, 0.82, 0.25, c.a), 2.2)
		draw_arc(Vector2.ZERO, hr - 0.6, PI * 1.1, PI * 1.9, 12, Color(1, 1, 0.9, 0.9 * c.a), 1.0)
		draw_set_transform(Vector2.ZERO)
		queue_redraw()
	if dk >= 0.0 and dk < 1.0:
		# the game's brown cloud (puff, cloud, ring, bits); a robot's white ring first, the cloud a quarter second later
		var bb2 = _opaque_box(f, frame % fr.size(), slot)
		var mid2 = Vector2(f["x"] + bb2.position.x + bb2.size.x * 0.5, f["y"] + bb2.position.y + bb2.size.y * 0.5) * size_scale
		if robot:
			_death_fx("e_ring", dk, mid2)
			if dk >= 0.38:
				_death_fx("v_boom", (dk - 0.38) / 0.62, mid2)
		else:
			_death_fx("v_boom", dk, mid2)
		queue_redraw()
	if smoke_k >= 0.0 and smoke_k < 1.0:
		var fx = Assets.efx("e_smoke")
		if not fx.is_empty():
			var bb = _opaque_box(f, frame % fr.size(), slot)
			var mid = Vector2(f["x"] + bb.position.x + bb.size.x * 0.5, f["y"] + bb.position.y + bb.size.y * 0.5) * size_scale
			var spots = [Vector2(0, 0), Vector2(-0.35, -0.3), Vector2(0.35, -0.25), Vector2(-0.3, 0.3), Vector2(0.3, 0.3), Vector2(0, -0.45)]
			for i in spots.size():
				var k = smoke_k * 1.6 - i * 0.12
				if k < 0.0 or k >= 1.0:
					continue
				var fi = clampi(int(k * fx["frames"].size()), 0, fx["frames"].size() - 1)
				var sf: Dictionary = fx["frames"][fi]
				if int(sf["w"]) <= 0:
					continue
				var p = mid + spots[i] * bb.size * size_scale
				draw_texture_rect_region(fx["tex"], Rect2(p - Vector2(float(sf["ox"]), float(sf["oy"])), Vector2(sf["w"], sf["h"])), Rect2(fi * int(fx["cell"]), 0, sf["w"], sf["h"]))
	# names and speech: in the game they are drawn by the world on the screen's own layer, at full sharpness
	# (labels_outside; here, in the small picture that is then enlarged, 8-pixel letters came out blurry or broken);
	# the map editor (and split screen) still draw them here
	var z = maxf(0.05, get_global_transform_with_canvas().get_scale().x)
	label_y = (f["y"] - 4) * size_scale
	if label != "" and not labels_outside:
		var font = _text_font(z)
		draw_set_transform(Vector2(-70, label_y), 0.0, Vector2.ONE / z)
		draw_string_outline(font, Vector2.ZERO, label, HORIZONTAL_ALIGNMENT_CENTER, 140 * z, int(round(8 * z)), maxi(1, int(round(2 * z))), Color(0, 0, 0, 0.7))
		draw_string(font, Vector2.ZERO, label, HORIZONTAL_ALIGNMENT_CENTER, 140 * z, int(round(8 * z)), label_color)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	var top = f["y"] * size_scale - (12 if label != "" else 2)
	if hp_frac < 0.999 and hp_frac > 0.0:
		draw_rect(Rect2(-11, top - 3, 22, 4), Color(0, 0, 0, 0.75))
		draw_rect(Rect2(-10, top - 2, 20 * hp_frac, 2), Color(0.95, 0.25, 0.2) if hp_frac < 0.35 else Color(0.95, 0.8, 0.2))
		top -= 5
	bubble_y = top
	if bubble != "" and not labels_outside:
		var font2 = _text_font(z)
		var w = minf(160.0, font2.get_string_size(bubble, HORIZONTAL_ALIGNMENT_LEFT, -1, 8).x + 8)
		draw_rect(Rect2(-w / 2, top - 14, w, 12), Color(1, 1, 1, 0.92))
		draw_rect(Rect2(-w / 2, top - 14, w, 12), Color(0, 0, 0, 0.9), false, 1.0)
		draw_set_transform(Vector2(-w / 2 + 4, top - 5), 0.0, Vector2.ONE / z)
		draw_string(font2, Vector2.ZERO, bubble, HORIZONTAL_ALIGNMENT_LEFT, (w - 6) * z, int(round(8 * z)), Color(0.05, 0.05, 0.1))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

## set by the world while it draws names and bubbles itself (one screen, not split); where they go (this view's own units)
static var labels_outside = false
var label_y = 0.0
var bubble_y = 0.0

## in the game the world is drawn at the GBA's size and then enlarged: soft-edged 8-pixel letters came out as blurry
## blocks, so there the letters are hard-edged pixels (sharp when enlarged); zoomed in (the map editor) they stay smooth
static var _hard_font: Font
func _text_font(z: float) -> Font:
	# (in the game's own picture - a SubViewport at the GBA's size - always the hard letters: a bigger hero is drawn
	# scaled up, and by the zoom alone its name (other players' names) got the soft letters and came out blurry)
	if z > 1.5 and not (get_viewport() is SubViewport):
		return ThemeDB.fallback_font
	if _hard_font == null:
		var f = ThemeDB.fallback_font
		if f is FontFile:
			var h: FontFile = f.duplicate()
			h.antialiasing = TextServer.FONT_ANTIALIASING_NONE
			h.hinting = TextServer.HINTING_NORMAL
			h.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
			_hard_font = h
		else:
			_hard_font = f
	return _hard_font

## the part of a frame that has pixels (cached per sprite set image)
static var _boxes = {}
static var _imgs = {}
## one of the game's 4-picture effects at k (0..1 through it), centred on p
func _death_fx(name: String, k: float, p: Vector2) -> void:
	var sfx = Assets.efx(name)
	if sfx.is_empty():
		return
	var i = clampi(int(k * 4.0), 0, mini(3, sfx["frames"].size() - 1))
	var sf: Dictionary = sfx["frames"][i]
	if int(sf["w"]) > 0:
		draw_texture_rect_region(sfx["tex"], Rect2((p - Vector2(sf["w"], sf["h"]) * 0.5).floor(), Vector2(sf["w"], sf["h"])), Rect2(i * int(sfx["cell"]), 0, sf["w"], sf["h"]))

func _opaque_box(f: Dictionary, fi: int, slot: int) -> Rect2:
	var tex: Texture2D = set_data["tex"]
	var key = "%d:%d:%d" % [tex.get_rid().get_id(), slot, fi]
	if _boxes.has(key):
		return _boxes[key]
	var cell: int = set_data["cell"]
	var ik = tex.get_rid().get_id()
	if not _imgs.has(ik):
		_imgs[ik] = tex.get_image()
	var img: Image = _imgs[ik]
	var r = Rect2(0, 0, f["w"], f["h"])
	if img != null:
		var x0 = 999; var y0 = 999; var x1 = -1; var y1 = -1
		for y in int(f["h"]):
			for x in int(f["w"]):
				if img.get_pixel(fi * cell + x, slot * cell + y).a > 0.1:
					x0 = mini(x0, x); y0 = mini(y0, y); x1 = maxi(x1, x); y1 = maxi(y1, y)
		if x1 >= 0:
			r = Rect2(x0, y0, x1 - x0 + 1, y1 - y0 + 1)
	_boxes[key] = r
	return r

## where a halo sits for a pose (12 FLYING, else the standing pose 0) facing a way: from the feet, in the picture's px.
## Standing facing you / away: over the middle of the feet (hair swept to one side, a tail or a cape never pull it);
## standing side on: the middle of the very top of the head. Flying left / right: the front end, at the head's height
## there. Flying up: the top. Diving (flying down): wherever the hero's own head is in the picture - found by matching the
## top of the standing front pose's head (hair, helmet, turban: its exact colours) - Cooler and Cell dive head first,
## Tao and Tien with their feet up behind, Goku's head stays on top. Found once per hero (shared by every view)
static var _halo_spots = {}
func _halo_spot(a: int, d: int) -> Vector2:
	var tex: Texture2D = set_data.get("tex")
	var key = "%d:%d:%d" % [tex.get_rid().get_id() if tex != null else set_id, a, d]
	if _halo_spots.has(key):
		return _halo_spots[key]
	var res = Vector2(8, -30)
	var fr = frames_of(a, d)
	if fr.is_empty() and a != 0:
		res = _halo_spot(0, d)
		_halo_spots[key] = res
		return res
	var pic = _halo_pixels(a, d)
	if pic.is_empty():
		_halo_spots[key] = res
		return res
	var f: Dictionary = fr[0]
	var rows: Array = pic["rows"]
	var top: int = pic["top"]; var bot: int = pic["bot"]
	var med = func(y0: int, y1: int, xa: int, xb: int) -> float:
		var xs = []
		for y in range(maxi(0, y0), mini(rows.size(), y1 + 1)):
			for x in rows[y]:
				if x >= xa and x <= xb:
					xs.append(x)
		if xs.is_empty():
			return float(pic["xmin"] + pic["xmax"]) / 2.0
		xs.sort()
		return float(xs[xs.size() / 2])
	if a == 12 and d >= 2:
		var xa = int(pic["xmin"]) if d == 2 else int(pic["xmax"]) - 12
		var xb = int(pic["xmin"]) + 12 if d == 2 else int(pic["xmax"])
		var ht = -1
		for y in rows.size():
			for x in rows[y]:
				if x >= xa and x <= xb:
					ht = y
					break
			if ht >= 0:
				break
		res = Vector2(f["x"] + med.call(ht, ht + 4, xa, xb), f["y"] + maxi(0, ht))
	elif a == 12 and d == 0:
		var hm = _head_match(pic)
		res = Vector2(f["x"] + hm.x, f["y"] + hm.y) if hm.x > -900 else Vector2(f["x"] + med.call(top, top + 5, 0, 999), f["y"] + top)
	elif a == 12:
		res = Vector2(f["x"] + med.call(top, top + 5, 0, 999), f["y"] + top)
	elif d < 2:
		res = Vector2(f["x"] + med.call(bot - 5, bot, 0, 999), f["y"] + top)      # (over the feet)
	else:
		res = Vector2(f["x"] + med.call(top, top + 3, 0, 999), f["y"] + top)
	_halo_spots[key] = res
	return res

## a pose's first frame: its opaque x's per row, their colours, the figure's top / bottom / sides
func _halo_pixels(a: int, d: int) -> Dictionary:
	var fr = frames_of(a, d)
	var tex: Texture2D = set_data.get("tex")
	if fr.is_empty() or tex == null:
		return {}
	var f: Dictionary = fr[0]
	var cell: int = set_data["cell"]
	var ik = tex.get_rid().get_id()
	if not _imgs.has(ik):
		_imgs[ik] = tex.get_image()
	var img: Image = _imgs[ik]
	if img == null:
		return {}
	var slot = a * 4 + d
	var w = int(f["w"]); var h = int(f["h"])
	var rows = []; var cols = {}
	var top = -1; var bot = -1; var xmin = 999; var xmax = -1
	for y in h:
		var xs = []
		for x in w:
			var c = img.get_pixel(x, slot * cell + y)
			if c.a > 0.1:
				xs.append(x)
				cols[Vector2i(x, y)] = c.to_rgba32()
				xmin = mini(xmin, x); xmax = maxi(xmax, x)
		rows.append(xs)
		if not xs.is_empty():
			if top < 0:
				top = y
			bot = y
	if top < 0:
		return {}
	return {"rows": rows, "cols": cols, "top": top, "bot": bot, "xmin": xmin, "xmax": xmax, "w": w, "h": h}

## where the standing front pose's head top (its first 9 rows, exact colours) best fits in this picture: the middle of
## that head's top, in the picture's px ((-999, -999): no good fit)
func _head_match(pic: Dictionary) -> Vector2:
	var st = _halo_pixels(0, 0)
	if st.is_empty():
		return Vector2(-999, -999)
	var tmpl = []
	var tx0 = 999; var tx1 = -1
	for y in range(st["top"], mini(st["top"] + 9, st["rows"].size())):
		for x in st["rows"][y]:
			tmpl.append([x, y - int(st["top"]), int(st["cols"][Vector2i(x, y)])])
			tx0 = mini(tx0, x); tx1 = maxi(tx1, x)
	if tmpl.size() < 6:
		return Vector2(-999, -999)
	var cols: Dictionary = pic["cols"]
	var best = 0; var bx = 0; var by = 0
	for oy in range(-2, int(pic["h"])):
		for ox in range(-tx1, int(pic["w"]) - tx0):
			var n = 0
			for t in tmpl:
				if int(cols.get(Vector2i(int(t[0]) + ox, int(t[1]) + oy), 0)) == int(t[2]):
					n += 1
			if n > best:
				best = n; bx = ox; by = oy
	if best < tmpl.size() * 0.3:
		return Vector2(-999, -999)
	return Vector2((tx0 + tx1) / 2.0 + bx, float(by))
