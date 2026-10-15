extends Node
## The dedicated server: runs the world (every enemy, every area someone is in) with no player of its own.

var t = 0
var status: Label
var log_lines = []

func _ready() -> void:
	Game.toast.connect(func(text, _c): _log(text))
	get_tree().set_auto_accept_quit(false)

func _log(s: String) -> void:
	var line = "%s  %s" % [Time.get_time_string_from_system(), s]
	print("[server] ", line)
	log_lines.append(line)
	if log_lines.size() > 10:
		log_lines.pop_front()

func _physics_process(_dt: float) -> void:
	Game.host_step([])
	t += 1
	if t % 30 == 0 and status:
		var lines = ["WORLD: %s (%s)   PORT %d" % [Game.planet.title, Game.world_id(), Game.PORT],
			("Anyone can join it under GLOBAL MULTIPLAYER - JOIN GAME." if Game.cfg.get("online", false) else "People on your Wi-Fi can join it under LOCAL MULTIPLAYER - JOIN GAME.") + " (Each player keeps their own fighter.)",
			"B: STOP THE SERVER AND GO BACK TO THE MENU" if OS.has_feature("mobile") else "Close this window or press ESC to stop.", "", "PLAYING NOW: %d" % Game.remote_states.size()]
		for pid in Game.remote_states:
			var st: Dictionary = Game.remote_states[pid]
			lines.append("  %s  LV %d  - %s" % [st.get("name", "?"), int(st.get("lvl", 1)), Game.planet.nodes[clampi(int(st.get("node", 0)), 0, Game.planet.nodes.size() - 1)]["name"]])
		lines.append("")
		lines.append_array(log_lines)
		status.text = "\n".join(PackedStringArray(lines))
	if t % 3600 == 0:
		_log("%d min up, %d playing" % [t / 3600, Game.remote_states.size()])

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		get_tree().quit()
	elif what == NOTIFICATION_WM_GO_BACK_REQUEST:
		stop()       # Android's back

## B (or ESC): the server stops, everyone is let go, back to the menu (Android port: there was no way out)
func _input(ev: InputEvent) -> void:
	if (ev is InputEventJoypadButton and ev.pressed and ev.button_index == Game.pad_btn("b")) or (ev is InputEventKey and ev.pressed and not ev.echo and ev.keycode == KEY_ESCAPE):
		get_viewport().set_input_as_handled()
		stop()

var _stopping = false
func stop() -> void:
	if _stopping:
		return
	_stopping = true
	Game.leave()
	get_tree().set_auto_accept_quit(true)
	get_tree().reload_current_scene()

## this device's addresses on the network (what a friend types to JOIN)
func _addresses() -> String:
	var ips = []
	for a in IP.get_local_addresses():
		if a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254."):
			ips.append(a)
	return ", ".join(PackedStringArray(ips)) if not ips.is_empty() else "(no network)"
