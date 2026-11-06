extends CanvasLayer
## On-screen controls for phones and tablets (shown on a touch screen; F3 shows them on a PC for testing).
## Left side: a stick appears where your thumb goes down. Right side: the buttons.
## A punch (hold: rushing strike), B ki (hold: your beam), SP special, TR transform, RUN; on top MENU, MAP,
## ITEM and NEXT (the next special). Multi-touch: move and press at the same time.

var keys = {}                 # like a keyboard set: up down left right a b sp tr it nx mn run
var map_pressed = false       # the MAP button was tapped (the world opens the map)
var stick_id = -1
var stick_base = Vector2.ZERO
var stick_pos = Vector2.ZERO
var held = {}                 # touch index -> button name
var shown = false
var pad: Control
const R_STICK = 30.0

func _ready() -> void:
	pad = Control.new()
	pad.set_anchors_preset(Control.PRESET_FULL_RECT)
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.draw.connect(_draw_controls)
	add_child(pad)
	apply_mode()
	for b in ["up", "down", "left", "right", "a", "b", "sp", "tr", "it", "nx", "mn", "run", "fly", "runt"]:
		keys[b] = false

## where the buttons are, in screen (viewport) coordinates - they follow the screen's shape
## OPTIONS - ON-SCREEN BUTTONS: "auto" (a touch screen without a pad or handheld buttons), "on", "off"
func apply_mode() -> void:
	match str(Game.cfg.get("touch_mode", "auto")):
		"on":
			shown = true
		"off":
			shown = false
		_:
			shown = (DisplayServer.is_touchscreen_available() or OS.has_feature("mobile") or OS.has_feature("web_android") or OS.has_feature("web_ios")) and Input.get_connected_joypads().is_empty()
	if pad:
		pad.queue_redraw()

func _buttons() -> Dictionary:
	var s = pad.get_viewport_rect().size
	var r = s.x - 46
	var bt = s.y - 44
	return {
		"a": [Vector2(r, bt), 20.0, "A"],
		"b": [Vector2(r - 44, bt + 12), 17.0, "B"],
		"sp": [Vector2(r - 8, bt - 44), 15.0, "SP"],
		"tr": [Vector2(r - 50, bt - 30), 13.0, "TR"],
		"run": [Vector2(r - 88, bt + 18), 13.0, "RUN"],
		"fly": [Vector2(r - 92, bt - 22), 13.0, "FLY"],      # L2 on a pad: fly / land
		"runt": [Vector2(s.x - 40, 148), 11.0, "PVP"],     # R2 on a pad: PVP at a save point (elsewhere: sprint on / off)
		# a small column under the minimap
		"mn": [Vector2(s.x - 15, 88), 11.0, "MENU"],
		"map": [Vector2(s.x - 15, 112), 11.0, "MAP"],
		"it": [Vector2(s.x - 15, 136), 11.0, "ITEM"],
		"nx": [Vector2(s.x - 40, 124), 11.0, "NEXT"],
	}

func _input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not ev.echo and ev.keycode == KEY_F3:
		shown = not shown
		pad.queue_redraw()
		return
	if not (ev is InputEventScreenTouch or ev is InputEventScreenDrag):
		return
	if not shown:
		if str(Game.cfg.get("touch_mode", "auto")) != "auto" or Input.get_connected_joypads().size() > 0:
			return        # switched off, or buttons of its own: a tap does not bring them back
		shown = true      # a finger on the screen: the controls appear
	var p: Vector2 = ev.position
	var idx: int = ev.index
	if ev is InputEventScreenTouch:
		if ev.pressed:
			var hit = ""
			for name in _buttons():
				var bb: Array = _buttons()[name]
				if p.distance_to(bb[0]) < float(bb[1]) + 6.0:
					hit = name
			if hit != "":
				held[idx] = hit
				if hit == "map":
					map_pressed = true
			elif p.x < pad.get_viewport_rect().size.x * 0.45 and stick_id < 0:
				stick_id = idx
				stick_base = p
				stick_pos = p
		else:
			held.erase(idx)
			if idx == stick_id:
				stick_id = -1
	elif ev is InputEventScreenDrag:
		if idx == stick_id:
			stick_pos = p
			# the base follows a thumb that slides far away
			var d = stick_pos - stick_base
			if d.length() > R_STICK * 1.6:
				stick_base = stick_pos - d.normalized() * R_STICK * 1.6
		elif held.has(idx):
			# slide a finger from A to B and it presses B
			for name in _buttons():
				var bb: Array = _buttons()[name]
				if p.distance_to(bb[0]) < float(bb[1]) + 4.0 and name != "map" and name != "mn":
					held[idx] = name
	_update_keys()
	get_viewport().set_input_as_handled()

func _update_keys() -> void:
	for b in keys:
		keys[b] = false
	if stick_id >= 0:
		var d = stick_pos - stick_base
		if d.length() > 7.0:
			var a = d.angle()
			# 8 ways: a diagonal presses two directions
			keys["right"] = cos(a) > 0.38
			keys["left"] = cos(a) < -0.38
			keys["down"] = sin(a) > 0.38
			keys["up"] = sin(a) < -0.38
			# pushed all the way: run
			if d.length() > R_STICK * 1.25:
				keys["run"] = true
	for i in held:
		var b: String = held[i]
		if keys.has(b):
			keys[b] = true
	pad.queue_redraw()

func take_map_tap() -> bool:
	var m = map_pressed
	map_pressed = false
	return m

func _draw_controls() -> void:
	if not shown:
		return
	var font = ThemeDB.fallback_font
	if stick_id >= 0:
		pad.draw_circle(stick_base, R_STICK, Color(1, 1, 1, 0.12))
		pad.draw_arc(stick_base, R_STICK, 0, TAU, 32, Color(1, 1, 1, 0.35), 1.5)
		var d = stick_pos - stick_base
		pad.draw_circle(stick_base + d.limit_length(R_STICK), 12, Color(1, 1, 1, 0.4))
	else:
		var s = pad.get_viewport_rect().size
		var hint = Vector2(52, s.y - 52)
		pad.draw_arc(hint, R_STICK, 0, TAU, 32, Color(1, 1, 1, 0.18), 1.0)
		pad.draw_string(font, hint + Vector2(-20, 3), "MOVE", HORIZONTAL_ALIGNMENT_CENTER, 40, 7, Color(1, 1, 1, 0.3))
	var down = {}
	for i in held:
		down[held[i]] = true
	for name in _buttons():
		var bb: Array = _buttons()[name]
		var c: Vector2 = bb[0]
		var r: float = bb[1]
		var on = down.has(name)
		var col = {"a": Color(1, 0.55, 0.35), "b": Color(0.45, 0.75, 1), "sp": Color(1, 0.85, 0.3), "tr": Color(1, 0.95, 0.5)}.get(name, Color(0.85, 0.85, 0.9))
		pad.draw_circle(c, r, Color(col.r, col.g, col.b, 0.45 if on else 0.18))
		pad.draw_arc(c, r, 0, TAU, 32, Color(col.r, col.g, col.b, 0.8), 1.5)
		var t: String = bb[2]
		var fs = 9 if t.length() <= 2 else 6
		pad.draw_string(font, c + Vector2(-r, fs * 0.35), t, HORIZONTAL_ALIGNMENT_CENTER, r * 2, fs, Color(1, 1, 1, 0.85))

func _process(_dt: float) -> void:
	if shown:
		pad.queue_redraw()

## the phone's BACK button opens / closes the menu (instead of closing the game)
var back_t = 0
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		back_t = 6

func _physics_process(_dt: float) -> void:
	if back_t > 0:
		back_t -= 1
		keys["mn"] = back_t > 2
		if back_t == 0:
			_update_keys()
