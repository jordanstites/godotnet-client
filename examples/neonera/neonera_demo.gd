extends Node

# Richer demo for godotnet-client.
#
# Requires:
#   - The godotnet-client plugin enabled (provides GodotNet autoload).
#   - godobuf installed and used to generate game_pb.gd from game.proto.
#     The generated file should expose Credentials, Move, ClientMessage,
#     and ServerMessage classes. Adjust the GamePb references below if
#     godobuf chose different identifiers for your install.
#
# Behavior:
#   - Connects to a neonera Go server on 127.0.0.1:7777/7778.
#   - Once READY, sends Move() every MOVE_INTERVAL drawing a circle.
#   - Logs every PlayerMoved broadcast received from the server.
#   - Auto-reconnects with backoff on disconnect.

const HOST := "127.0.0.1"
const TCP_PORT := 7777
const UDP_PORT := 7778

const USERNAME := "alice"
const TOKEN := "dev"

# Movement: circle of radius RADIUS centered at origin, one revolution
# per ORBIT_PERIOD seconds, sample every MOVE_INTERVAL seconds.
const RADIUS := 10.0
const ORBIT_PERIOD := 4.0
const MOVE_INTERVAL := 0.2

var _elapsed := 0.0
var _next_send_at := 0.0

func _ready() -> void:
	GodotNet.state_changed.connect(_on_state_changed)
	GodotNet.connected.connect(_on_connected)
	GodotNet.disconnected.connect(_on_disconnected)
	GodotNet.login_failed.connect(_on_login_failed)
	GodotNet.server_message.connect(_on_server_message)

	GodotNet.set_auto_reconnect(true, 1.0, 10.0)

	var creds := GamePb.Credentials.new()
	creds.set_username(USERNAME)
	creds.set_token(TOKEN)
	GodotNet.connect_to_server(HOST, TCP_PORT, creds.to_bytes(), UDP_PORT)

func _process(delta: float) -> void:
	if not GodotNet.is_ready():
		return
	_elapsed += delta
	if _elapsed < _next_send_at:
		return
	_next_send_at = _elapsed + MOVE_INTERVAL
	var theta := (_elapsed / ORBIT_PERIOD) * TAU
	_send_move(RADIUS * cos(theta), RADIUS * sin(theta))

func _send_move(x: float, y: float) -> void:
	var move := GamePb.Move.new()
	move.set_x(x)
	move.set_y(y)
	var cm := GamePb.ClientMessage.new()
	cm.set_move(move)
	GodotNet.send_unreliable(cm.to_bytes())

# ---- Signal handlers ------------------------------------------------

func _on_state_changed(new_state: int) -> void:
	var names := ["DISCONNECTED", "CONNECTING_TCP", "LOGGING_IN",
		"HANDSHAKING_UDP", "READY"]
	var state_name := names[new_state] if new_state >= 0 and new_state < names.size() else "?"
	print("[neonera] state -> %s" % state_name)

func _on_connected(player_id: int) -> void:
	print("[neonera] connected as player ", player_id)
	print("[neonera] sending Move every %dms" % int(MOVE_INTERVAL * 1000))

func _on_disconnected(code: int, reason: String) -> void:
	print("[neonera] disconnected (code=%d): %s" % [code, reason])

func _on_login_failed(error_message: String) -> void:
	print("[neonera] login failed: ", error_message)

func _on_server_message(payload: PackedByteArray, reliable: bool) -> void:
	var sm := GamePb.ServerMessage.new()
	if sm.from_bytes(payload) != GamePb.PB_ERR.NO_ERRORS:
		push_warning("[neonera] failed to parse ServerMessage")
		return
	if sm.has_moved():
		var m := sm.get_moved()
		print("[neonera] PlayerMoved id=%d x=%.2f y=%.2f (via %s)" % [
			m.get_player_id(), m.get_x(), m.get_y(),
			"TCP" if reliable else "UDP",
		])
