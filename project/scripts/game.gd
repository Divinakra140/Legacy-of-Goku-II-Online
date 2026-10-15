extends Node
## The shared game: settings, the planet, the host's enemy simulation and the network (LAN / Hamachi).
## The host runs every enemy; each player runs their own fighter (no lag on your own moves) and the
## host decides what enemies do - so both players always see the same world.

signal started
signal lobby_changed
signal toast(text: String, color: Color)
signal exp_gained(k: int, lvl: int, mult: float, info: Dictionary)
signal revived(k: int, from: String)
signal hurt(k: int, atk: float, kx: float, ky: float, st: String)
signal victory(name: String)
signal chat(from: String, text: String, pid: int)
signal item_got(k: int, kind: String, n: int)
signal gift(k: int, kind: String, n: int, from: String)
signal social(k: int, from_pid: int, from_name: String, kind: String, data: Dictionary)

const PORT = 7777
var cfg = {"mode": "solo", "ip": "127.0.0.1", "character": 4, "adventure": "gatorra", "seed": 12345, "difficulty": 1, "name": "PLAYER",
	"local_players": 1, "character2": 0, "name2": "PLAYER 2"}
const LOCAL_KEYS = ["character", "mode", "name", "local_players", "character2", "name2", "ip"]
## every fighter has a player id: (network peer id) * 8 + (which player on that PC, 0 or 1)
static func pid_of(peer: int, k: int) -> int:
	return peer * 8 + k
var planet: Planet
var sims = {}                     # host: area key -> AreaSim
var peers = {}                    # peer id -> {name, character, state:{}, node, ready}
var remote_states = {}            # peer id -> latest fighter snapshot (with "node")
var area_states = {}              # area key -> latest enemy snapshot (clients and host)
var in_game = false
var net_error = ""
var victory_done = false
var start_override = -1   # test aid
var local_nodes = {}      # local player k -> the area they are in
var session_where = {}    # local player k -> {world, node, x, y}: where you are (back there after a reconnect)
var area_drops = {}       # area key -> [[id, kind, x, y]] orbs lying there
var area_eshots = {}      # area key -> [[x, y, color]] foes' ki blasts
var area_fx = {}          # area key -> [[type, x, y, r, ticks]] big moments (a slam) to draw
var reconnect_tries = 0
var reconnect_t = 0.0
var save_world_t = 0
const MAX_CLIENTS = 15

func world_id() -> String:
	return "%s_%d" % [str(cfg["adventure"]), int(cfg["seed"])]

## each player's own character is saved on their own PC (save_fighter); the world itself starts
## fresh every time (enemies come back on their own, like an online game) - nothing to lose or reset
func save_world() -> void:
	pass

# ------------------------------------------------------------------ host migration (Android port)
## The host keeps the players in the order they joined and tells everyone (with how to reach each one, and the
## online world's name and password check). When the host leaves, the first in line becomes the host - their
## world goes on, foes and all - and everyone else connects to them. If they do not come up, the next one does.
var join_order = []        # host: peer ids in the order they joined
var peer_addr = {}         # host: peer id -> address (LAN: IP, online: ZeroTier address)
var succession = []        # everyone: [[peer id, address], ...] - who takes over, in order
var succ_info = {}         # everyone: the online world {name, private, salt, proof}
var my_peer_id = 0
var migrating = false

## where the others can reach this device (LAN: its IP on the Wi-Fi, online: its ZeroTier address)
func my_address() -> String:
	if cfg.get("online", false):
		return str(Online.status()["address"])
	for a in IP.get_local_addresses():
		if a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254."):
			return a
	return ""

func _send_succession() -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	var list = []
	for id in join_order:
		if peer_addr.get(id, "") != "":
			list.append([id, peer_addr[id]])
	var info = {}
	if cfg.get("online", false):
		info = Online.succession_info()
	rpc("succession_msg", list, info)

@rpc("authority", "reliable")
func succession_msg(list: Array, info: Dictionary) -> void:
	succession = list
	succ_info = info
	my_peer_id = multiplayer.get_unique_id()

func _migrate(me: int) -> void:
	if succession.is_empty():
		return
	var next = succession[0]
	if int(next[0]) == me:
		_become_host()
	else:
		migrating = true
		toast.emit("THE HOST LEFT - CONNECTING TO THE NEW HOST...", Color(1, 0.8, 0.4))
		if cfg.get("online", false):
			Online.join({"address": str(next[1]), "salt": str(succ_info.get("salt", "")), "private": bool(succ_info.get("private", false))}, "")
			Online.join_proof = str(succ_info.get("proof", ""))
		else:
			cfg["ip"] = str(next[1])
		reconnect_tries = 40
		reconnect_t = 2.5          # (the new host needs a moment to open their game)

func _become_host() -> void:
	succession.pop_front()
	var online = cfg.get("online", false)
	cfg["mode"] = "host"
	var ok = false
	if online:
		Online.stop_joining()
		ok = host_game_online("")
		Online.resume(succ_info)       # the same world on the list: its name, and its password if private
	else:
		ok = host_game()
	if not ok:
		toast.emit("COULD NOT TAKE OVER AS HOST - PLAYING ON ALONE", Color(1, 0.5, 0.5))
		return
	cfg["online"] = online
	net_error = ""
	join_order = []
	peer_addr = {}
	sims.clear()                   # (foes start again round the players, as on any host)
	print("[game] the host left - this device is the host now")
	toast.emit("THE HOST LEFT - YOU ARE THE HOST NOW", Color(0.6, 1, 0.7))
	lobby_changed.emit()

## the host turned this player away (a private game's wrong password)
@rpc("authority", "reliable")
func refused(why: String) -> void:
	print("[game] the host turned us away: ", why)
	net_error = why
	reconnect_tries = 0
	refused_why = why
	lobby_changed.emit()
var refused_why = ""

## the host went away: keep trying to get back in (the world is kept on their side)
func _on_server_lost() -> void:
	if refused_why != "":
		net_error = refused_why
		refused_why = ""
		lobby_changed.emit()
		if multiplayer.has_multiplayer_peer():
			multiplayer.multiplayer_peer = null
		return
	net_error = "THE HOST LEFT"
	lobby_changed.emit()
	var me = my_peer_id
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer = null
	if in_game and not succession.is_empty():
		_migrate(me)
		return
	if in_game:
		toast.emit("LOST THE HOST - RECONNECTING...", Color(1, 0.6, 0.4))
		reconnect_tries = 40
		reconnect_t = 2.0

func _process(dt: float) -> void:
	_lan_host_poll()
	if _lan_scan != null:
		_lan_scan_poll(dt)
	_world_boss_tick(dt)
	if reconnect_tries > 0:
		reconnect_t -= dt
		if reconnect_t <= 0.0:
			reconnect_t = 3.0
			reconnect_tries -= 1
			if not multiplayer.has_multiplayer_peer() or multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
				if cfg.get("online", false):
					join_game_online(Online.join_port)
				else:
					join_game(str(cfg["ip"]))
			# the next in line did not come up (gone too): try the one after them
			if migrating and reconnect_tries % 5 == 0 and succession.size() > 1:
				succession.pop_front()
				_migrate(my_peer_id)
				return
			if reconnect_tries == 0:
				migrating = false
				toast.emit("COULD NOT REACH THE HOST - PLAYING ON ALONE (Q IN THE PAUSE MENU: BACK)", Color(1, 0.5, 0.5))
	# a partner we have not heard from for 4 seconds has gone (left, or dropped out of split screen)
	var now = Time.get_ticks_msec()
	for pid in remote_states.keys():
		if now - int(remote_states[pid].get("_t", now)) > 4000:
			remote_states.erase(pid)

func _ready() -> void:
	load_options.call_deferred()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(func(): net_error = "COULD NOT CONNECT"; lobby_changed.emit())
	multiplayer.server_disconnected.connect(_on_server_lost)

func is_host() -> bool:
	return cfg["mode"] != "join"

func my_id() -> int:
	return multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else 1

func difficulty_hp() -> float:
	return [0.8, 1.0, 1.3][clampi(int(cfg["difficulty"]), 0, 2)]

func difficulty_atk() -> float:
	return [0.75, 1.0, 1.3][clampi(int(cfg["difficulty"]), 0, 2)]

# ------------------------------------------------------------------ games on this Wi-Fi (Android port)
## A host (HOST ONLINE or WORLD SERVER) answers "LOG2?" on LAN_PORT with its name, planet and players.
## FIND GAMES ON WI-FI asks every address of the network one by one (phones often drop broadcasts).
const LAN_PORT = 7778
var _lan_host: PacketPeerUDP = null
var _lan_scan: PacketPeerUDP = null
var _lan_scan_t = 0.0
var lan_found = {}       # ip -> {"name", "planet", "players", "server", "seen"}

func lan_host_start() -> void:
	lan_host_stop()
	_lan_host = PacketPeerUDP.new()
	if _lan_host.bind(LAN_PORT) != OK:
		_lan_host = null

func lan_host_stop() -> void:
	if _lan_host != null:
		_lan_host.close()
		_lan_host = null

func _lan_host_poll() -> void:
	while _lan_host != null and _lan_host.get_available_packet_count() > 0:
		var pkt = _lan_host.get_packet().get_string_from_utf8()
		var ip = _lan_host.get_packet_ip()
		var port = _lan_host.get_packet_port()
		if pkt != "LOG2?" or ip == "":
			continue
		var server = str(cfg.get("mode", "")) == "server"
		var info = {"name": "SERVER" if server else str(cfg.get("name", "HOST")), "planet": planet.title if planet != null else "",
			"character": "SERVER (NO PLAYER)" if server else str(Assets.CHARACTERS[clampi(int(cfg.get("character", 0)), 0, Assets.CHARACTERS.size() - 1)]),
			"players": remote_states.size() + (0 if server else 1), "server": server}
		_lan_host.set_dest_address(ip, port)
		_lan_host.put_packet(("LOG2!" + JSON.stringify(info)).to_utf8_buffer())

func lan_scan_start() -> void:
	lan_scan_stop()
	lan_found.clear()
	_lan_scan = PacketPeerUDP.new()
	for t in 20:      # any free port to hear the answers on
		if _lan_scan.bind(40000 + randi() % 20000) == OK:
			break
	_lan_scan_t = 0.0

func lan_scan_stop() -> void:
	if _lan_scan != null:
		_lan_scan.close()
		_lan_scan = null

func _lan_scan_poll(dt: float) -> void:
	_lan_scan_t -= dt
	if _lan_scan_t <= 0.0:
		_lan_scan_t = 2.0
		for a in IP.get_local_addresses():
			if a.count(".") != 3 or a.begins_with("127.") or a.begins_with("169.254."):
				continue
			var pre = a.substr(0, a.rfind(".") + 1)
			for h in range(1, 255):
				_lan_scan.set_dest_address(pre + str(h), LAN_PORT)
				_lan_scan.put_packet("LOG2?".to_utf8_buffer())
	var now = Time.get_ticks_msec()
	while _lan_scan.get_available_packet_count() > 0:
		var pkt = _lan_scan.get_packet().get_string_from_utf8()
		var ip = _lan_scan.get_packet_ip()
		if not pkt.begins_with("LOG2!"):
			continue
		var info = JSON.parse_string(pkt.substr(5))
		if info is Dictionary:
			info["seen"] = now
			lan_found[ip] = info
	for ip in lan_found.keys():
		if now - int(lan_found[ip]["seen"]) > 7000:
			lan_found.erase(ip)

# ------------------------------------------------------------------ connecting
func host_game() -> bool:
	var p = ENetMultiplayerPeer.new()
	var err = p.create_server(PORT, MAX_CLIENTS)
	if err != OK:
		net_error = "COULD NOT OPEN PORT %d" % PORT
		return false
	multiplayer.multiplayer_peer = p
	peers.clear()
	peers[1] = {"name": lobby_name(), "character": cfg["character"]}
	lobby_changed.emit()
	lan_host_start()
	return true

## GLOBAL MULTIPLAYER: the same game over WebSocket (it rides the ZeroTier bridge as TCP - see online.gd)
func host_game_online(password: String) -> bool:
	var p = WebSocketMultiplayerPeer.new()
	var err = p.create_server(Online.PORT, "127.0.0.1")
	if err != OK:
		net_error = "COULD NOT START THE GAME SERVER"
		return false
	multiplayer.multiplayer_peer = p
	cfg["online"] = true
	peers.clear()
	peers[1] = {"name": lobby_name(), "character": cfg["character"]}
	lobby_changed.emit()
	Online.host(password)
	return true

## port: the local end of the bridge to the host (Online.join)
func join_game_online(port: int) -> bool:
	if port <= 0:
		net_error = "COULD NOT REACH THAT GAME"
		return false
	var p = WebSocketMultiplayerPeer.new()
	var err = p.create_client("ws://127.0.0.1:%d" % port)
	if err != OK:
		net_error = "COULD NOT REACH THAT GAME"
		return false
	multiplayer.multiplayer_peer = p
	cfg["online"] = true
	return true

## the players connected to this host (for the lobby list)
func remote_players_count() -> int:
	return multiplayer.get_peers().size() if multiplayer.has_multiplayer_peer() else 0

func join_game(ip: String) -> bool:
	var p = ENetMultiplayerPeer.new()
	var err = p.create_client(ip, PORT)
	if err != OK:
		net_error = "COULD NOT CONNECT TO %s" % ip
		return false
	multiplayer.multiplayer_peer = p
	return true

func leave() -> void:
	succession = []
	succ_info = {}
	join_order = []
	peer_addr = {}
	migrating = false
	lan_host_stop()
	Online.stop_hosting()
	if not cfg.get("online", false) or reconnect_tries == 0:
		Online.stop_joining()
	cfg.erase("online")
	save_world()
	reconnect_tries = 0
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	peers.clear()
	remote_states.clear()
	in_game = false

func lobby_name() -> String:
	if int(cfg.get("local_players", 1)) >= 2:
		return "%s + %s" % [cfg["name"], cfg["name2"]]
	return str(cfg["name"])

func _on_connected() -> void:
	my_peer_id = multiplayer.get_unique_id()
	migrating = false
	if reconnect_tries > 0:
		reconnect_tries = 0
		net_error = ""
		toast.emit("BACK IN THE WORLD", Color(0.6, 1, 0.6))
	rpc_id(1, "hello", lobby_name(), int(cfg["character"]), Online.join_proof if cfg.get("online", false) else "", my_address())

func _on_peer_connected(_id: int) -> void:
	lobby_changed.emit()

func _on_peer_disconnected(id: int) -> void:
	save_world()
	peers.erase(id)
	if is_host():
		join_order.erase(id)
		peer_addr.erase(id)
		_send_succession()
	for pid in remote_states.keys():
		if pid / 8 == id:
			remote_states.erase(pid)
	lobby_changed.emit()
	if in_game:
		toast.emit("A PLAYER LEFT THE WORLD", Color(1, 0.7, 0.4))

@rpc("any_peer", "reliable")
func hello(n: String, ch: int, proof: String = "", addr: String = "") -> void:
	if not is_host():
		return
	var id = multiplayer.get_remote_sender_id()
	if cfg.get("online", false) and not Online.accepts(proof):      # a private game: the password was wrong
		print("[server] turned away %s: wrong password" % n)
		rpc_id(id, "refused", "WRONG PASSWORD")
		get_tree().create_timer(1.0).timeout.connect(func(): if multiplayer.has_multiplayer_peer(): multiplayer.multiplayer_peer.disconnect_peer(id))
		return
	peers[id] = {"name": n, "character": ch}
	if not join_order.has(id):
		join_order.append(id)
	peer_addr[id] = addr
	_send_succession()
	rpc("lobby", peers)
	lobby_changed.emit()
	if in_game:
		toast.emit("%s JOINED THE WORLD" % n, Color(0.6, 1, 0.9))
		print("[server] %s joined (peer %d)" % [n, id])
	if in_game:   # joining a world already running: come in next to a friend
		var c = cfg.duplicate()
		var sp = session_where.get(0)
		if cfg["mode"] == "server" or sp == null:
			for pid in remote_states:
				if pid / 8 != id:
					var st: Dictionary = remote_states[pid]
					sp = {"node": int(st.get("node", 0)), "x": float(st["x"]), "y": float(st["y"])}
					break
		if sp != null:
			c["spawn"] = {"node": int(sp["node"]), "x": float(sp["x"]), "y": float(sp["y"])}
		rpc_id(id, "start_game", c)

@rpc("authority", "reliable")
func lobby(p: Dictionary) -> void:
	peers = p
	lobby_changed.emit()

# ------------------------------------------------------------------ starting
func begin() -> void:
	cfg.erase("spawn")
	if cfg["mode"] == "host" or cfg["mode"] == "server":
		rpc("start_game", cfg)
	start_game(cfg)

@rpc("authority", "reliable")
func start_game(c: Dictionary) -> void:
	var mine = {}
	for k in LOCAL_KEYS:
		mine[k] = cfg.get(k)
	cfg = c.duplicate()
	for k in LOCAL_KEYS:
		cfg[k] = mine[k]
	Assets.load_data()
	planet = Planet.new()
	var adv: String = cfg["adventure"]
	if adv.begins_with("land:"):
		if not planet.build_land(int(adv.substr(5)), int(cfg["seed"])):
			planet = Planet.new()
			planet.build_random(int(cfg["seed"]))
	elif adv == "random" or not planet.build_adventure(adv, int(cfg["seed"])):
		planet = Planet.new()
		planet.build_random(int(cfg["seed"]))
	if start_override >= 0 and start_override < planet.nodes.size():
		planet.start = start_override
	sims.clear()
	area_states.clear()
	victory_done = false
	local_nodes.clear()
	area_drops.clear()
	area_eshots.clear()
	area_fx.clear()
	wboss_t = 300.0
	in_game = true
	started.emit()

# ------------------------------------------------------------------ the host's world
func sim_for(node: int, arrival: Vector2, levels_hint: int) -> AreaSim:
	var n: Dictionary = planet.nodes[node]
	var key: String = n["key"]
	if not sims.has(key):
		var s = AreaSim.new()
		var spec: Dictionary = n["spec"].duplicate()
		spec["level"] = maxi(int(spec["level"]), levels_hint)   # enemies keep up with the players (like the PC mod)
		s.setup(key, Assets.area(key), spec)
		s.make_enemies(arrival)
		sims[key] = s
	return sims[key]

## every tick on the host: run each area someone stands in.
## locs: this PC's players [{k, node, st}]; returns the blows they take [{k, atk, kx, ky}]
func host_step(locs: Array) -> Array:
	var my_events = []
	var by_node = {}
	var all = {}
	for l in locs:
		var d: Dictionary = l["st"].duplicate()
		d["node"] = l["node"]
		all[pid_of(1, int(l["k"]))] = d
	for id in remote_states:
		all[id] = remote_states[id]
	var lv_sum = 0
	var lv_n = 0
	for id in all:
		var st: Dictionary = all[id]
		if not st.has("node"):
			continue
		var nd = int(st["node"])
		if nd < 0 or nd >= planet.nodes.size():
			continue
		if not by_node.has(nd):
			by_node[nd] = []
		by_node[nd].append({"peer": id, "x": float(st["x"]), "y": float(st["y"]), "down": st.get("down", false), "inv": st.get("inv", false),
			"set": int(st.get("set", 54)), "dir": int(st.get("dir", 0))})
		lv_sum += int(st.get("lvl", 1)); lv_n += 1
	var lv = lv_sum / maxi(1, lv_n)
	for nd in by_node:
		var fs: Array = by_node[nd]
		var s = sim_for(nd, Vector2(fs[0]["x"], fs[0]["y"]), lv)
		s.player_lv = lv
		var ev = s.step(fs)
		for e in ev:
			if e["type"] == "hurt":
				var pid = int(e["peer"])
				var stt = _roll_inflict(int(e.get("et", -1)))
				if pid / 8 == 1:
					my_events.append({"k": pid % 8, "atk": e["atk"], "kx": e["kx"], "ky": e["ky"], "st": stt})
				else:
					rpc_id(pid / 8, "hurt_me", pid % 8, e["atk"], e["kx"], e["ky"], stt)
		var snap = s.snapshot()
		area_states[s.key] = snap
		var dsnap = s.drops_snapshot()
		area_drops[s.key] = dsnap
		var esnap = s.eshots_snapshot()
		area_eshots[s.key] = esnap
		for oe in s.events_out:
			match oe["type"]:
				"boss_back":
					announce("%s HAS RETURNED TO HIS LAIR!" % str(oe["name"]))
				"help":
					announce("%s CALLS FOR HELP!" % str(oe["name"]))
				"wboss_down":
					announce("%s HAS FALLEN! WELL FOUGHT!" % str(oe["name"]))
				"foe_state", "foe_dot":
					var txt = str(oe.get("text", "")) if oe["type"] == "foe_state" else str(int(oe.get("dmg", 0)))
					var pop = [float(oe["x"]), float(oe["y"]), txt, str(oe.get("color", "ffffff"))]
					add_area_pop(s.key, pop)
					for f in fs:
						var pr2 = int(f["peer"]) / 8
						if pr2 != 1:
							rpc_id(pr2, "area_pop_msg", s.key, pop)
					if oe["type"] == "foe_dot" and oe.get("r", {}).get("killed", false):
						_give_kill(s.key, oe["r"])
				"slam":
					var fx = ["slam", float(oe["x"]), float(oe["y"]), float(oe["r"])]
					add_area_fx(s.key, fx)
					for f in fs:
						var pr = int(f["peer"]) / 8
						if pr != 1:
							rpc_id(pr, "area_fx_msg", s.key, fx)
		s.events_out.clear()
		var sent = {}
		if Engine.get_physics_frames() % 2 == 1:
			fs = []          # the picture goes out 30 times a second (smooth on the other side, light on Hamachi)
		var big = s.area["w"] > 1200 or s.area["h"] > 900
		for f in fs:
			var peer = int(f["peer"]) / 8
			if peer != 1 and not sent.has(peer):
				sent[peer] = true
				if big:
					# a big land: each PC only hears about what is near its own players
					var mine = []
					for f2 in fs:
						if int(f2["peer"]) / 8 == peer:
							mine.append(Vector2(f2["x"], f2["y"]))
					rpc_id(peer, "area_state", s.key, _near(snap, mine, 1, 2), _near(dsnap, mine, 2, 3), _near(esnap, mine, 0, 1))
				else:
					rpc_id(peer, "area_state", s.key, snap, dsnap, esnap)
		# the boss is beaten
		if s.boss_beaten and not victory_done:
			victory_done = true
			rpc("victory_all", planet.title)
			victory_all(planet.title)
	return my_events

# ------------------------------------------------------------------ chat
func say(from: String, text: String, k: int) -> void:
	text = text.strip_edges().left(80)
	if text == "":
		return
	chat.emit(from, text, pid_of(my_id(), k))
	if multiplayer.has_multiplayer_peer() and not multiplayer.get_peers().is_empty():
		rpc("chat_msg", from, text, k)

@rpc("any_peer", "reliable")
func chat_msg(from: String, text: String, k: int) -> void:
	chat.emit(from, text.left(80), pid_of(multiplayer.get_remote_sender_id(), k))

static func _near(list: Array, pts: Array, ix: int, iy: int) -> Array:
	var out = []
	for e in list:
		var p = Vector2(float(e[ix]), float(e[iy]))
		for q in pts:
			if absf(p.x - q.x) < 560.0 and absf(p.y - q.y) < 400.0:
				out.append(e)
				break
	return out

@rpc("authority", "unreliable_ordered")
func area_state(key: String, snap: Array, dsnap: Array, esnap: Array) -> void:
	area_states[key] = snap
	area_drops[key] = dsnap
	area_eshots[key] = esnap

var area_pops = {}          # key -> [[x, y, text, colour]] numbers and words over foes (poison, states)
func add_area_pop(key: String, pop: Array) -> void:
	if not area_pops.has(key):
		area_pops[key] = []
	area_pops[key].append(pop)

@rpc("authority", "reliable")
func area_pop_msg(key: String, pop: Array) -> void:
	add_area_pop(key, pop)

func add_area_fx(key: String, fx: Array) -> void:
	if not area_fx.has(key):
		area_fx[key] = []
	area_fx[key].append(fx + [0])

@rpc("authority", "reliable")
func area_fx_msg(key: String, fx: Array) -> void:
	add_area_fx(key, fx)

## a message on every screen in the world
func announce(text: String) -> void:
	toast.emit(text, Color(1, 0.6, 0.3))
	if multiplayer.has_multiplayer_peer() and not multiplayer.get_peers().is_empty():
		rpc("announce_msg", text)

@rpc("authority", "reliable")
func announce_msg(text: String) -> void:
	toast.emit(text, Color(1, 0.6, 0.3))

# ------------------------------------------------------------------ orbs on the ground
func try_pickup(node: int, id: int, k: int) -> void:
	if is_host():
		_pickup(node, id, pid_of(1, k))
	else:
		rpc_id(1, "pickup_from_client", node, id, k)

@rpc("any_peer", "reliable")
func pickup_from_client(node: int, id: int, k: int) -> void:
	if is_host():
		_pickup(node, id, pid_of(multiplayer.get_remote_sender_id(), k))

func _pickup(node: int, id: int, pid: int) -> void:
	if node < 0 or node >= planet.nodes.size():
		return
	var key: String = planet.nodes[node]["key"]
	if not sims.has(key):
		return
	var got: Array = sims[key].take_drop(id)
	if got.is_empty():
		return
	area_drops[key] = sims[key].drops_snapshot()
	if pid / 8 == 1:
		item_got.emit(pid % 8, got[0], got[1])
	else:
		rpc_id(pid / 8, "got_item", pid % 8, got[0], got[1])

@rpc("authority", "reliable")
func got_item(k: int, kind: String, n: int) -> void:
	item_got.emit(k, kind, n)

# ------------------------------------------------------------------ giving to a friend (trading)
## give items or zeni to any player in the world: target = player id (peer*8 + k)
func give(target: int, kind: String, n: int, from: String) -> void:
	if target / 8 == my_id():
		gift.emit(target % 8, kind, n, from)
	elif multiplayer.has_multiplayer_peer():
		rpc_id(target / 8, "gift_msg", target % 8, kind, n, from)

## party, duel and trade messages between two players (target = player id, peer*8 + k)
func send_social(target: int, from_pid: int, from_name: String, kind: String, data: Dictionary) -> void:
	if target / 8 == my_id():
		social.emit(target % 8, from_pid, from_name, kind, data)
	elif multiplayer.has_multiplayer_peer():
		rpc_id(target / 8, "social_msg", target % 8, from_pid % 8, from_name, kind, data)

@rpc("any_peer", "reliable")
func social_msg(k: int, from_k: int, from_name: String, kind: String, data: Dictionary) -> void:
	social.emit(k, pid_of(multiplayer.get_remote_sender_id(), from_k), from_name, kind, data)

@rpc("any_peer", "reliable")
func gift_msg(k: int, kind: String, n: int, from: String) -> void:
	gift.emit(k, kind, clampi(n, 0, 99999), from)

@rpc("authority", "reliable")
func hurt_me(k: int, atk: float, kx: float, ky: float, st: String) -> void:
	hurt.emit(k, atk, kx, ky, st)

## a foe kind's "inflict" (ENEMIES): {state, chance} - the state its blow puts on you ("" none)
func _roll_inflict(et: int) -> String:
	if et < 0:
		return ""
	var inf = Content.enemy_types.get(et, {}).get("inflict", {})
	if inf is Dictionary and not inf.is_empty() and randf() < float(inf.get("chance", 0.3)):
		return str(inf.get("state", ""))
	return ""

@rpc("authority", "reliable")
func victory_all(t: String) -> void:
	victory_done = true
	victory.emit(t)

@rpc("any_peer", "unreliable_ordered")
func player_state(st: Dictionary) -> void:
	st["_t"] = Time.get_ticks_msec()
	remote_states[pid_of(multiplayer.get_remote_sender_id(), int(st.get("k", 0)))] = st

@rpc("any_peer", "reliable")
func player_gone(k: int) -> void:
	remote_states.erase(pid_of(multiplayer.get_remote_sender_id(), k))

func send_state(k: int, node: int, st: Dictionary, nm: String) -> void:
	if not multiplayer.has_multiplayer_peer() or multiplayer.get_peers().is_empty():
		return
	var d = st.duplicate()
	d["node"] = node
	d["name"] = nm
	d["k"] = k
	rpc("player_state", d)

## a player on this PC stopped playing (split screen back to one)
func local_gone(k: int) -> void:
	local_nodes.erase(k)
	if multiplayer.has_multiplayer_peer() and not multiplayer.get_peers().is_empty():
		rpc("player_gone", k)

## a fighter's blow on an enemy (applied by the host)
func hit_enemy(node: int, id: int, dmg: int, kx: float, ky: float, crit: bool, stun: int = 12, inflict: Dictionary = {}) -> void:
	if is_host():
		_apply_hit(node, id, dmg, kx, ky, 1, stun, inflict)
	else:
		rpc_id(1, "hit_from_client", node, id, dmg, kx, ky, stun, inflict)

@rpc("any_peer", "reliable")
func hit_from_client(node: int, id: int, dmg: int, kx: float, ky: float, stun: int, inflict: Dictionary) -> void:
	if is_host():
		_apply_hit(node, id, dmg, kx, ky, multiplayer.get_remote_sender_id(), stun, inflict)

func _apply_hit(node: int, id: int, dmg: int, kx: float, ky: float, _from: int, stun: int = 12, inflict: Dictionary = {}) -> void:
	var key: String = planet.nodes[node]["key"]
	if not sims.has(key):
		return
	var r = sims[key].hit(id, dmg, kx, ky, stun, 1, inflict)
	_give_kill(key, r)

## a foe beaten: everyone in that area gets the EXP
func _give_kill(key: String, r: Dictionary) -> void:
	var node = -1
	for i in planet.nodes.size():
		if str(planet.nodes[i]["key"]) == key:
			node = i
			break
	if node < 0:
		return
	if r.get("killed", false):
		# everyone in that area gets the EXP (playing together never slows anyone down)
		var lv = int(r["lvl"])
		var mult = float(r["mult"])
		var info: Dictionary = r.get("info", {})
		for k in local_nodes:
			if int(local_nodes[k]) == node:
				exp_gained.emit(int(k), lv, mult, info)
		for pid in remote_states:
			if int(remote_states[pid].get("node", -1)) == node:
				rpc_id(pid / 8, "give_exp", pid % 8, lv, mult, info)

@rpc("authority", "reliable")
func give_exp(k: int, lv: int, mult: float, info: Dictionary) -> void:
	exp_gained.emit(k, lv, mult, info)

# ------------------------------------------------------------------ helping a friend up
func revive(pid: int, from: String) -> void:
	if pid / 8 == my_id():
		revived.emit(pid % 8, from)
	elif multiplayer.has_multiplayer_peer():
		rpc_id(pid / 8, "revive_msg", pid % 8, from)

@rpc("any_peer", "reliable")
func revive_msg(k: int, from: String) -> void:
	revived.emit(k, from)

# ------------------------------------------------------------------ world boss events (the host)
var wboss_t = 300.0       # seconds to the next one (the first after 5 minutes)

func _world_boss_tick(dt: float) -> void:
	if not in_game or not is_host() or planet == null:
		return
	if local_nodes.is_empty() and remote_states.is_empty():
		return
	wboss_t -= dt / float(cfg.get("event_scale", 1.0))
	if wboss_t > 0.0:
		return
	wboss_t = randf_range(720.0, 1080.0)
	for key in sims:
		if sims[key].has_world_boss():
			return
	var cands = []
	for i in planet.nodes.size():
		if int(planet.nodes[i]["kind"]) == 0 and not planet.nodes[i].get("hidden", false):
			cands.append(i)
	if cands.is_empty():
		return
	var nd: int = cands[randi() % cands.size()]
	if int(cfg.get("wb_node", -1)) >= 0:
		nd = int(cfg["wb_node"])     # test aid
	var lv_sum = 0
	var lv_n = 0
	for id in remote_states:
		lv_sum += int(remote_states[id].get("lvl", 1)); lv_n += 1
	for k in local_nodes:
		lv_sum += int(local_levels.get(k, 1)); lv_n += 1
	var lv = lv_sum / maxi(1, lv_n)
	var s = sim_for(nd, planet.start_point(), lv)
	var nm = s.add_world_boss(lv)
	if nm != "":
		announce("WORLD BOSS! %s APPEARED IN %s - TAB: TRAVEL THERE" % [nm, planet.nodes[nd]["name"]])
		print("[world] world boss in node ", nd)

var local_levels = {}     # local player k -> level (for the world boss's strength)

# ------------------------------------------------------------------ the pad's A/B/X/Y
## "xbox": A is the bottom button (a PC pad). "nintendo": A on the right, B at the bottom, X on top, Y on the left
## (the labels on a Retroid and other handhelds) - the default on Android
func pad_layout() -> String:
	return str(cfg.get("pad_layout", "nintendo" if OS.has_feature("android") else "xbox"))

## the pad button for a face button's label ("a", "b", "x", "y")
func pad_btn(label: String) -> int:
	if pad_layout() == "nintendo":
		return {"a": JOY_BUTTON_B, "b": JOY_BUTTON_A, "x": JOY_BUTTON_Y, "y": JOY_BUTTON_X}[label]
	return {"a": JOY_BUTTON_A, "b": JOY_BUTTON_B, "x": JOY_BUTTON_X, "y": JOY_BUTTON_Y}[label]

## the menus' OK (buttons on the title screen) follows the layout too
func apply_pad_layout() -> void:
	InputMap.action_erase_events("ui_accept")
	var ev = InputEventJoypadButton.new()
	ev.button_index = pad_btn("a")
	InputMap.action_add_event("ui_accept", ev)

# ------------------------------------------------------------------ options (volume) kept on this PC
func save_options() -> void:
	var fa = FileAccess.open("user://options.json", FileAccess.WRITE)
	if fa:
		fa.store_string(JSON.stringify({"music": Music.volume, "sound": Sfx.volume, "view_zoom": int(cfg.get("view_zoom", 0)), "touch_mode": str(cfg.get("touch_mode", "auto")), "pad_layout": pad_layout(), "name": str(cfg.get("name", "PLAYER"))}))
		fa.close()

func load_options() -> void:
	apply_pad_layout.call_deferred()
	if FileAccess.file_exists("user://options.json"):
		var t = JSON.parse_string(FileAccess.get_file_as_string("user://options.json"))
		if t is Dictionary:
			Music.volume = float(t.get("music", Music.volume))
			Sfx.volume = float(t.get("sound", Sfx.volume))
			cfg["view_zoom"] = int(t.get("view_zoom", 0))
			cfg["touch_mode"] = str(t.get("touch_mode", "auto"))
			if str(t.get("name", "")) != "":
				cfg["name"] = str(t["name"])
			if t.has("pad_layout"):
				cfg["pad_layout"] = str(t["pad_layout"])
			var mn = get_tree().root.get_node_or_null("Main")
			if mn and mn.has_method("_fit_view"):
				mn._fit_view()

# ------------------------------------------------------------------ saving (each player keeps their own fighter)
static func _slot(f: FighterSim, k: int) -> String:
	return str(f.ch) if k == 0 else "%d_p%d" % [f.ch, k + 1]

## the save file of this world ("land:0" -> fighters_land_0.json; a colon is not allowed in a Windows file name)
func _save_path() -> String:
	if cfg.has("dev_return"):
		return "user://fighters_playtest.json"     # a play-test from the DEV TOOLS never touches your own heroes
	if cfg.has("story"):
		return "user://fighters_story_%s.json" % str(cfg["story"])       # a story's own save slot
	return "user://fighters_%s.json" % str(cfg["adventure"]).replace(":", "_")

## FREE PLAY: a hero's growth (level, numbers, items, zeni, moves) is shared by every map - level 16 Piccolo is level 16
## everywhere; what belongs to one world (where you stand, its quests and flags) stays in that world's own file.
const SHARED_SAVE = "user://fighters_free.json"
const WORLD_KEYS = ["where", "quests", "qdone", "flags"]
func _shared_saves() -> bool:
	return not cfg.has("dev_return") and not cfg.has("story")

static func _read_json_dict(path: String) -> Dictionary:
	if FileAccess.file_exists(path):
		var t = JSON.parse_string(FileAccess.get_file_as_string(path))
		if t is Dictionary:
			return t
	return {}

static func _write_json(path: String, d: Dictionary) -> void:
	var fa = FileAccess.open(path, FileAccess.WRITE)
	if fa:
		fa.store_string(JSON.stringify(d))
		fa.close()

func save_fighter(f: FighterSim, k: int = 0) -> void:
	var d = f.to_save()
	var path = _save_path()
	var all = _read_json_dict(path)
	if _shared_saves():
		var shared = _read_json_dict(SHARED_SAVE)
		var grow = d.duplicate(true)
		var here = {"ch": d.get("ch")}
		for key in WORLD_KEYS:
			here[key] = grow.get(key)
			grow.erase(key)
		shared[_slot(f, k)] = grow
		_write_json(SHARED_SAVE, shared)
		all[_slot(f, k)] = here
	else:
		all[_slot(f, k)] = d
	_write_json(path, all)

## a hero's shared growth; the first time, the strongest copy from the older one-file-per-map saves
func shared_entry(slot: String) -> Dictionary:
	var shared = _read_json_dict(SHARED_SAVE)
	if shared.get(slot) is Dictionary:
		return shared[slot]
	var best = {}
	var dir = DirAccess.open("user://")
	if dir:
		for fn in dir.get_files():
			if not fn.begins_with("fighters_") or fn.begins_with("fighters_story") or fn in ["fighters_playtest.json", "fighters_free.json"]:
				continue
			var e = _read_json_dict("user://" + fn).get(slot)
			if e is Dictionary and e.has("level") and (best.is_empty() or int(e.get("level", 1)) * 10000000 + int(e.get("exp", 0)) > int(best.get("level", 1)) * 10000000 + int(best.get("exp", 0))):
				best = e.duplicate(true)
	for key in WORLD_KEYS:
		best.erase(key)
	return best

func load_fighter(f: FighterSim, k: int = 0) -> void:
	var path = _save_path()
	if not FileAccess.file_exists(path) and FileAccess.file_exists("user://fighters_%s.json" % str(cfg["adventure"])):
		path = "user://fighters_%s.json" % str(cfg["adventure"])     # saved by an older version
	var t = _read_json_dict(path)
	var d = {}
	if t.get(_slot(f, k)) is Dictionary:
		d = t[_slot(f, k)].duplicate(true)
	if _shared_saves():
		var here = {}
		for key in WORLD_KEYS:
			if d.has(key):
				here[key] = d[key]
		d = shared_entry(_slot(f, k)).duplicate(true)
		d.merge(here, true)
	if not d.is_empty():
		f.from_save(d)
