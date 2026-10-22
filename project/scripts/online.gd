extends Node
## GLOBAL MULTIPLAYER (Android port): play with anyone over the internet, nobody types an address.
## An embedded ZeroTier node (libzt, through the Java bridge LoG2ZeroTier - no app, no account) joins an ad-hoc
## network made from PORT, which carries only that port. The game itself talks WebSocket to 127.0.0.1 and the
## bridge carries those bytes across ZeroTier:
##   host:  ZeroTier listener on PORT -> the game's WebSocket server on 127.0.0.1:PORT
##   guest: 127.0.0.1:<a port the bridge picks> -> ZeroTier connection to the host's address, PORT
## Ad-hoc networks cannot broadcast, so hosts announce themselves to the lobby list (a Cloudflare worker, its
## address and password in the private res://lobby_server.txt) and players pick a game from it.
## Adapted from the PokeWilds Android port's coop_lobby.gd / coop_network.gd.

const PORT = 7790                 # the game server for GLOBAL play - and the ZeroTier network it picks
const PROTOCOL = "log2-1"         # games of another version are not listed
const ANNOUNCE_MS = 30000
const LIST_MS = 5000

var bridge = null
var _checked = false

# ---- hosting
var hosting = false
var world_name = ""             # the name the host gave their world (shown in JOIN GAME)
var is_private = false
var salt = ""
var _proof = ""                   # sha256(salt|password): what a joining player must send
var _key = ""                     # only this host knows it; the list shows a hash of it
var _next_announce = 0
var _announced_players = -1
var _announce_id = 0
var _announce_since = 0

# ---- finding games
var browsing = false
var lobbies = []                  # [{id, address, planet, character, private, players, max, salt}]
var list_error = ""
var _list_id = 0
var _next_list = 0

# ---- joining
var join_port = 0                 # the bridge's local port to the host (kept for reconnecting)
var join_proof = ""

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

## the Java bridge (Android builds made with the Gradle build); null elsewhere
func available() -> bool:
	if _checked:
		return bridge != null
	_checked = true
	if OS.get_name() == "Android" and Engine.has_singleton("JavaClassWrapper"):
		var w = Engine.get_singleton("JavaClassWrapper").wrap("com.godot.game.LoG2ZeroTier")
		if w != null and w.available():
			bridge = w
	elif not OS.has_feature("android"):
		var d = DesktopBridge.new(self)      # the PC and Mac builds: the same bridge as a small program next to the game
		if d.available():
			bridge = d
	return bridge != null

## The PC / Mac bridge: log2_ztbridge(.exe) next to the game runs the ZeroTier node (the same network as the
## Android app: everyone plays with everyone) and is driven over a local control port. Same calls as the Java one.
class DesktopBridge extends RefCounted:
	var owner: Node
	var tcp: StreamPeerTCP
	var pid = -1
	var last = "starting\t\t"
	var buf = ""
	var lobby_key = ""
	var http = {}       # id -> HTTPRequest (still running) or the "status\nbody" result
	var next_id = 0
	var args = []          # how it was started (to start it again if it closes)
	var ctrl = 0
	var restarts = 0
	func _init(o: Node) -> void:
		owner = o
	func exe() -> String:
		return Assets.exe_dir().path_join("log2_ztbridge.exe" if OS.get_name() == "Windows" else "log2_ztbridge")
	func available() -> bool:
		return FileAccess.file_exists(exe())
	func start(storage: String, port: int) -> String:
		if pid > 0:
			return ""
		DirAccess.make_dir_recursive_absolute(storage)
		ctrl = 47000 + randi() % 2000
		args = [storage, str(port), str(ctrl)]
		pid = OS.create_process(exe(), args)
		if pid <= 0:
			last = "error\t\tThe multiplayer helper could not start."
			return last
		tcp = StreamPeerTCP.new()
		var t0 = Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < 3000:
			if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
				tcp = StreamPeerTCP.new()
				tcp.connect_to_host("127.0.0.1", ctrl)
				OS.delay_msec(100)
				tcp.poll()
			if tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED:
				break
		return ""
	func _say(line: String) -> void:
		if tcp != null and tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			tcp.put_data((line + "\n").to_utf8_buffer())
	func status() -> String:
		if tcp == null:
			return "stopped\t\t"
		tcp.poll()
		var n = tcp.get_available_bytes()
		if n > 0:
			buf += tcp.get_utf8_string(n)
			var lines = buf.split("\n")
			buf = lines[lines.size() - 1]
			for i in lines.size() - 1:
				if lines[i].begins_with("S "):
					last = lines[i].substr(2)
		elif tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED and pid > 0:
			if OS.is_process_running(pid):
				# still starting (a slow PC, or Windows checking the new file): keep knocking, no giving up
				if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTING:
					tcp = StreamPeerTCP.new()
					tcp.connect_to_host("127.0.0.1", ctrl)
				last = "starting\t\t"
			elif restarts < 5:
				# it closed: start it again (on a new control port)
				restarts += 1
				pid = -1
				var a = args.duplicate()
				if a.size() == 3 and start(str(a[0]), int(a[1])) == "":
					last = "starting\t\t"
				else:
					last = "error\t\tThe multiplayer helper stopped."
			else:
				last = "error\t\tThe multiplayer helper stopped."
		return last
	func hostOpen(zt_port: int, local_port: int) -> bool:
		_say("HOST %d %d" % [zt_port, local_port])
		return true
	func hostClose() -> void:
		_say("HOSTCLOSE")
	func connectOpen(address: String, port: int) -> int:
		var lp = 49000 + randi() % 4000
		_say("CONNECT %s %d %d" % [address, port, lp])
		# the helper opens that local port a moment after it reads this (1-2 ms in its log): the game connected first,
		# was refused, and every try failed (a PC joining said it could not connect, 6 of 6). A short wait first.
		OS.delay_msec(300)
		return lp
	func connectClose() -> void:
		_say("CONNECTCLOSE")
	func setLobbyKey(key: String) -> void:
		lobby_key = key
	func httpStart(url: String, body: String) -> int:
		next_id += 1
		var id = next_id
		var r = HTTPRequest.new()
		r.timeout = 8.0
		owner.add_child(r)
		http[id] = r
		r.request_completed.connect(func(_res, code, _h, b: PackedByteArray):
			http[id] = "%d\n%s" % [code, b.get_string_from_utf8()]
			r.queue_free())
		var hd = PackedStringArray(["Content-Type: application/json"])
		if lobby_key != "":
			hd.append("X-Lobby-Key: " + lobby_key)
		var err = r.request(url, hd, HTTPClient.METHOD_POST if body != "" else HTTPClient.METHOD_GET, body)
		if err != OK:
			http[id] = "0\n"
			r.queue_free()
		return id
	func httpTake(id: int) -> String:
		var v = http.get(id, "")
		if v is String and v != "":
			http.erase(id)
			return v
		return ""

## safe to call again and again: the node starts once and keeps running
func start() -> void:
	if available():
		bridge.start(OS.get_user_data_dir().path_join("zerotier"), PORT)

## {"state": "starting|joining|ready|error", "address": this device's ZeroTier address, "message": ...}
func status() -> Dictionary:
	if not available():
		return {"state": "error", "address": "", "message": "GLOBAL MULTIPLAYER needs log2_ztbridge next to the game."}
	var parts = str(bridge.status()).split("\t")
	while parts.size() < 3:
		parts.append("")
	return {"state": "starting" if parts[0] == "stopped" else parts[0], "address": parts[1], "message": parts[2]}

func status_text() -> String:
	var s = status()
	match str(s["state"]):
		"ready":
			return "ONLINE" if str(s["message"]) == "" else str(s["message"]).to_upper()
		"error":
			return str(s["message"]).to_upper()
		"joining":
			return "JOINING THE GAME NETWORK..."
	return "CONNECTING TO THE INTERNET..."

func is_online() -> bool:
	return str(status()["state"]) == "ready"

# ------------------------------------------------------------------ the lobby list
## [address, password] from the private res://lobby_server.txt (not in the public source)
func lobby_access() -> Array:
	var f = FileAccess.open("res://lobby_server.txt", FileAccess.READ)
	if f == null:
		return ["", ""]
	var url = f.get_line().strip_edges().trim_suffix("/")
	var key = f.get_line().strip_edges()
	return [url, key]

func _endpoint() -> String:
	var u = str(lobby_access()[0])
	return "" if u == "" else u + "/v1/lobbies"

func _http_start(body: String = "") -> int:
	if not available() or _endpoint() == "":
		return 0
	bridge.setLobbyKey(str(lobby_access()[1]))
	return int(bridge.httpStart(_endpoint(), body))

## {} while waiting, then {"code", "body"} once (code 0: it failed)
func _http_take(id: int) -> Dictionary:
	if not available() or id <= 0:
		return {}
	var t = str(bridge.httpTake(id))
	if t == "":
		return {}
	var nl = t.find("\n")
	return {"code": int(t.left(nl)), "body": t.substr(nl + 1)}

static func proof_of(s: String, password: String) -> String:
	return (s + "|" + password).sha256_text()

static func _hex(n: int) -> String:
	return Crypto.new().generate_random_bytes(n).hex_encode()

# ------------------------------------------------------------------ hosting
## the WebSocket server already listens on PORT (Game.host_game_online): open it to the ZeroTier network
## and put the game on the list. password "" = a public game.
func host(password: String) -> void:
	hosting = true
	is_private = password != ""
	salt = _hex(12) if is_private else ""
	_proof = proof_of(salt, password) if is_private else ""
	_key = _hex(16)
	_next_announce = 0
	_announced_players = -1
	_announce_id = 0
	if available():
		bridge.hostOpen(PORT, PORT)

## what the players need to put the same world back on the list if they take over as host
func succession_info() -> Dictionary:
	return {"name": world_name, "private": is_private, "salt": salt, "proof": _proof}

## a player taking over as host: the same world name and password check as before
func resume(info: Dictionary) -> void:
	if info.is_empty():
		return
	world_name = str(info.get("name", world_name))
	is_private = bool(info.get("private", false))
	salt = str(info.get("salt", ""))
	_proof = str(info.get("proof", ""))
	_next_announce = 0

func stop_hosting() -> void:
	if not hosting:
		return
	hosting = false
	if _key != "":
		_http_start(JSON.stringify({"key": _key, "remove": true}))     # (one that stops announcing drops off anyway)
	_key = ""
	if available():
		bridge.hostClose()

## a joining player's password check (public games let everyone in)
func accepts(proof: String) -> bool:
	return not is_private or proof == _proof

func _announce(now: int) -> void:
	if _announce_id > 0 and (not _http_take(_announce_id).is_empty() or now - _announce_since > 12000):
		_announce_id = 0
	if _announce_id != 0:
		return
	var players = Game.remote_players_count() + (0 if Game.cfg.get("mode") == "server" else 1)
	if now < _next_announce and players == _announced_players:
		return
	var s = status()
	if str(s["state"]) != "ready":
		return
	var server = str(Game.cfg.get("mode", "")) == "server"
	var record = {"key": _key, "address": str(s["address"]),
		"name": world_name if world_name != "" else (Game.planet.title if Game.planet != null else ""),
		"mods": Game.planet.title if Game.planet != null else "",
		"host": "SERVER (NO PLAYER)" if server else str(Assets.CHARACTERS[clampi(int(Game.cfg.get("character", 0)), 0, Assets.CHARACTERS.size() - 1)]),
		"private": is_private, "salt": salt, "players": maxi(1, players), "max": Game.MAX_CLIENTS + (0 if server else 1),
		"protocol": PROTOCOL}
	_next_announce = now + ANNOUNCE_MS
	_announced_players = players
	_announce_id = _http_start(JSON.stringify(record))
	_announce_since = now

# ------------------------------------------------------------------ finding and joining
func browse(on: bool) -> void:
	browsing = on
	_next_list = 0
	if on:
		list_error = ""
		lobbies = []

func _list(now: int) -> void:
	if _list_id > 0:
		var a = _http_take(_list_id)
		if not a.is_empty():
			_list_id = 0
			_listed(int(a["code"]), str(a["body"]))
	if _list_id == 0 and now >= _next_list:
		_next_list = now + LIST_MS
		if _endpoint() == "":
			list_error = "THIS BUILD HAS NO ONLINE LOBBY LIST."
			return
		_list_id = _http_start()

func _listed(code: int, body: String) -> void:
	if code == 401:
		list_error = "THIS BUILD IS NOT ALLOWED ON THE LOBBY LIST."
		return
	var d = JSON.parse_string(body) if code == 200 else null
	if not d is Dictionary or not d.get("lobbies") is Array:
		list_error = "CANNOT REACH THE LOBBY LIST - CHECK YOUR INTERNET."
		return
	list_error = ""
	var own = str(status()["address"])
	var out = []
	for e in d["lobbies"]:
		if not e is Dictionary or str(e.get("protocol", "")) != PROTOCOL:
			continue
		var addr = str(e.get("address", "")).left(45)
		if addr == "" or addr == own:
			continue
		out.append({"id": str(e.get("id", addr)), "address": addr, "world": str(e.get("name", "")).left(24), "planet": str(e.get("mods", e.get("name", ""))).left(32),
			"character": str(e.get("host", "")).left(24), "private": bool(e.get("private", false)),
			"players": int(e.get("players", 1)), "max": int(e.get("max", 16)), "salt": str(e.get("salt", "")).left(64)})
	out.sort_custom(func(x, y): return str(x["character"]) + str(x["planet"]) < str(y["character"]) + str(y["planet"]))
	lobbies = out

## a game from the list: the bridge opens a local port to it; Game connects there. Returns that port (0: no).
func join(entry: Dictionary, password: String) -> int:
	if not available():
		return 0
	join_proof = proof_of(str(entry.get("salt", "")), password) if bool(entry.get("private", false)) else ""
	join_port = int(bridge.connectOpen(str(entry["address"]), PORT))
	return join_port

func stop_joining() -> void:
	join_port = 0
	join_proof = ""
	if available():
		bridge.connectClose()

func _process(_dt: float) -> void:
	if not hosting and not browsing:
		return
	var now = Time.get_ticks_msec()
	if hosting:
		_announce(now)
	if browsing:
		_list(now)
