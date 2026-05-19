extends Node

# GodotNet — client-side network singleton for the godotnet Go server.
#
# Public API:
#   connect_to_server(host, tcp_port, credentials_bytes, udp_port=0)
#   disconnect_from_server()
#   send_reliable(payload_bytes) -> bool   # TCP
#   send_unreliable(payload_bytes) -> bool # UDP
#   set_auto_reconnect(enabled, initial_delay=1.0, max_delay=30.0, max_attempts=-1)
#   get_state() / is_ready() / get_player_id()
#
# Signals:
#   connected(player_id)
#   disconnected(code, reason)
#   login_failed(error_message)
#   server_message(payload_bytes, reliable)
#   state_changed(new_state)

const ControlCodec := preload("res://addons/godotnet_client/control_codec.gd")

enum State {
	DISCONNECTED,
	CONNECTING_TCP,
	LOGGING_IN,
	HANDSHAKING_UDP,
	READY,
}

enum DisconnectCode {
	USER_REQUESTED,
	TCP_CLOSED,
	TCP_ERROR,
	LOGIN_REJECTED,
	UDP_HANDSHAKE_REJECTED,
	UDP_HANDSHAKE_TIMEOUT,
	PROTOCOL_ERROR,
}

signal connected(player_id: int)
signal disconnected(code: int, reason: String)
signal login_failed(error_message: String)
signal server_message(payload_bytes: PackedByteArray, reliable: bool)
signal state_changed(new_state: int)

# ---- Tunables ------------------------------------------------------

# How often to resend UdpHandshake while waiting for the ack.
const UDP_HANDSHAKE_RESEND_INTERVAL_MSEC := 500
# Give up on UDP handshake after this many resends.
const UDP_HANDSHAKE_MAX_ATTEMPTS := 6

# ---- State ---------------------------------------------------------

var _state: int = State.DISCONNECTED
var _tcp: StreamPeerTCP = null
var _udp: PacketPeerUDP = null
var _tcp_rx_buf := PackedByteArray()

var _host: String = ""
var _tcp_port: int = 0
var _udp_port: int = 0
var _credentials_bytes := PackedByteArray()

var _player_id: int = 0
var _session_token: String = ""
var _resolved_udp_host: String = ""
var _resolved_udp_port: int = 0

# UDP handshake retry tracking.
var _udp_handshake_attempts: int = 0
var _udp_handshake_last_send_msec: int = 0

# Auto-reconnect.
var _auto_reconnect: bool = false
var _reconnect_initial_delay: float = 1.0
var _reconnect_max_delay: float = 30.0
var _reconnect_max_attempts: int = -1
var _reconnect_attempt: int = 0
var _reconnect_at_msec: int = -1

# ---- Public API ----------------------------------------------------

func connect_to_server(host: String, tcp_port: int,
		credentials_bytes: PackedByteArray, udp_port: int = 0) -> bool:
	if _state != State.DISCONNECTED:
		push_warning("[GodotNet] connect_to_server called while state=%s" % State.keys()[_state])
		return false
	if host.is_empty() or tcp_port <= 0:
		push_error("[GodotNet] connect_to_server: host/port required")
		return false

	_host = host
	_tcp_port = tcp_port
	_udp_port = udp_port
	_credentials_bytes = credentials_bytes
	_reconnect_at_msec = -1

	_tcp_rx_buf.clear()
	_tcp = StreamPeerTCP.new()
	var err := _tcp.connect_to_host(host, tcp_port)
	if err != OK:
		_transition_disconnected(DisconnectCode.TCP_ERROR,
				"connect_to_host failed: %d" % err)
		return false
	_set_state(State.CONNECTING_TCP)
	return true

func disconnect_from_server() -> void:
	# Cancel any pending reconnect.
	_reconnect_at_msec = -1
	_reconnect_attempt = 0
	if _state == State.DISCONNECTED:
		return
	_transition_disconnected(DisconnectCode.USER_REQUESTED, "disconnect requested")

func send_reliable(payload_bytes: PackedByteArray) -> bool:
	if _state != State.READY:
		push_warning("[GodotNet] send_reliable while state=%s" % State.keys()[_state])
		return false
	_send_tcp_frame(ControlCodec.encode_game_payload(payload_bytes))
	return true

func send_unreliable(payload_bytes: PackedByteArray) -> bool:
	if _state != State.READY:
		push_warning("[GodotNet] send_unreliable while state=%s" % State.keys()[_state])
		return false
	_udp.put_packet(ControlCodec.encode_game_payload(payload_bytes))
	return true

func set_auto_reconnect(enabled: bool, initial_delay: float = 1.0,
		max_delay: float = 30.0, max_attempts: int = -1) -> void:
	_auto_reconnect = enabled
	_reconnect_initial_delay = max(0.1, initial_delay)
	_reconnect_max_delay = max(_reconnect_initial_delay, max_delay)
	_reconnect_max_attempts = max_attempts
	if not enabled:
		_reconnect_at_msec = -1
		_reconnect_attempt = 0

func get_state() -> int:
	return _state

func is_ready() -> bool:
	return _state == State.READY

func get_player_id() -> int:
	return _player_id

# ---- Per-frame pump ------------------------------------------------

func _process(_delta: float) -> void:
	# Pending auto-reconnect.
	if _state == State.DISCONNECTED and _reconnect_at_msec >= 0 \
			and Time.get_ticks_msec() >= _reconnect_at_msec:
		_reconnect_at_msec = -1
		print("[GodotNet] auto-reconnect attempt %d" % _reconnect_attempt)
		connect_to_server(_host, _tcp_port, _credentials_bytes, _udp_port)

	if _tcp != null:
		_tcp.poll()
		_pump_tcp()

	if _udp != null:
		_pump_udp()

	# UDP handshake resend / timeout.
	if _state == State.HANDSHAKING_UDP:
		var now := Time.get_ticks_msec()
		if now - _udp_handshake_last_send_msec >= UDP_HANDSHAKE_RESEND_INTERVAL_MSEC:
			if _udp_handshake_attempts >= UDP_HANDSHAKE_MAX_ATTEMPTS:
				_transition_disconnected(DisconnectCode.UDP_HANDSHAKE_TIMEOUT,
						"no UdpHandshakeAck after %d attempts" % UDP_HANDSHAKE_MAX_ATTEMPTS)
			else:
				_send_udp_handshake()

# ---- TCP -----------------------------------------------------------

func _pump_tcp() -> void:
	var status := _tcp.get_status()
	match status:
		StreamPeerTCP.STATUS_NONE, StreamPeerTCP.STATUS_ERROR:
			_transition_disconnected(DisconnectCode.TCP_ERROR, "tcp status=%d" % status)
			return
		StreamPeerTCP.STATUS_CONNECTING:
			return
		StreamPeerTCP.STATUS_CONNECTED:
			pass # fall through

	# First-time entry into CONNECTED: send Login.
	if _state == State.CONNECTING_TCP:
		_set_state(State.LOGGING_IN)
		_send_tcp_frame(ControlCodec.encode_login(_credentials_bytes))
		if _tcp == null:
			return # send failed and tore us down

	# Read whatever bytes are available, frame, dispatch.
	var avail := _tcp.get_available_bytes()
	if avail > 0:
		var res := _tcp.get_partial_data(avail)
		if res[0] != OK:
			_transition_disconnected(DisconnectCode.TCP_ERROR,
					"tcp read err %d" % res[0])
			return
		_tcp_rx_buf.append_array(res[1])

	while _tcp_rx_buf.size() >= 4:
		var n := (_tcp_rx_buf[0] << 24) | (_tcp_rx_buf[1] << 16) \
				| (_tcp_rx_buf[2] << 8) | _tcp_rx_buf[3]
		if n < 0 or n > 16 * 1024 * 1024:
			_transition_disconnected(DisconnectCode.PROTOCOL_ERROR,
					"absurd frame length %d" % n)
			return
		if _tcp_rx_buf.size() < 4 + n:
			break
		var frame := _tcp_rx_buf.slice(4, 4 + n)
		_tcp_rx_buf = _tcp_rx_buf.slice(4 + n)
		_handle_server_frame(frame, true)
		if _state == State.DISCONNECTED:
			return

	# Did the server close on us?
	if _tcp != null and _tcp.get_status() == StreamPeerTCP.STATUS_NONE:
		_transition_disconnected(DisconnectCode.TCP_CLOSED, "tcp closed by server")

func _send_tcp_frame(frame: PackedByteArray) -> void:
	if _tcp == null:
		return
	var n := frame.size()
	var hdr := PackedByteArray()
	hdr.resize(4)
	hdr[0] = (n >> 24) & 0xFF
	hdr[1] = (n >> 16) & 0xFF
	hdr[2] = (n >> 8) & 0xFF
	hdr[3] = n & 0xFF
	var e1 := _tcp.put_data(hdr)
	if e1 != OK:
		_transition_disconnected(DisconnectCode.TCP_ERROR, "tcp write err %d" % e1)
		return
	var e2 := _tcp.put_data(frame)
	if e2 != OK:
		_transition_disconnected(DisconnectCode.TCP_ERROR, "tcp write err %d" % e2)

# ---- UDP -----------------------------------------------------------

func _pump_udp() -> void:
	while _udp.get_available_packet_count() > 0:
		var pkt := _udp.get_packet()
		_handle_server_frame(pkt, false)
		if _state == State.DISCONNECTED:
			return

func _bind_udp_and_handshake() -> bool:
	_udp = PacketPeerUDP.new()
	var err := _udp.connect_to_host(_resolved_udp_host, _resolved_udp_port)
	if err != OK:
		_transition_disconnected(DisconnectCode.PROTOCOL_ERROR,
				"udp connect_to_host failed: %d" % err)
		return false
	_udp_handshake_attempts = 0
	_send_udp_handshake()
	return true

func _send_udp_handshake() -> void:
	if _udp == null:
		return
	var frame := ControlCodec.encode_udp_handshake(_player_id, _session_token)
	_udp.put_packet(frame)
	_udp_handshake_attempts += 1
	_udp_handshake_last_send_msec = Time.get_ticks_msec()

# ---- Dispatch ------------------------------------------------------

func _handle_server_frame(frame: PackedByteArray, reliable: bool) -> void:
	var msg := ControlCodec.decode_server_frame(frame)
	match msg.get("kind", "unknown"):
		"login_response":
			_on_login_response(msg)
		"udp_handshake_ack":
			_on_udp_handshake_ack(msg)
		"ping":
			# Echo the nonce back. Server pings over UDP; reply over UDP.
			if _udp != null:
				_udp.put_packet(ControlCodec.encode_pong(int(msg.get("nonce", 0))))
		"game_payload":
			server_message.emit(msg.get("payload", PackedByteArray()), reliable)
		"error":
			push_warning("[GodotNet] frame decode error: %s" % msg.get("reason", "?"))
		_:
			# Unknown / empty oneof — ignore.
			pass

func _on_login_response(msg: Dictionary) -> void:
	if _state != State.LOGGING_IN:
		push_warning("[GodotNet] LoginResponse in state %s — ignoring" % State.keys()[_state])
		return
	if not bool(msg.get("ok", false)):
		var emsg := String(msg.get("error_message", ""))
		login_failed.emit(emsg)
		_transition_disconnected(DisconnectCode.LOGIN_REJECTED,
				"login rejected: %s" % emsg)
		return

	_player_id = int(msg.get("player_id", 0))
	_session_token = String(msg.get("session_token", ""))

	# Resolve UDP target: prefer server-advertised endpoint, else
	# fall back to (TCP host, udp_port arg or TCP port).
	_resolved_udp_host = _host
	_resolved_udp_port = _udp_port if _udp_port > 0 else _tcp_port
	var endpoint := String(msg.get("udp_endpoint", ""))
	if not endpoint.is_empty():
		var parsed := _parse_endpoint(endpoint)
		if parsed["port"] > 0:
			# Use parsed port; keep host if endpoint omitted host (":7778" style).
			if not parsed["host"].is_empty():
				_resolved_udp_host = parsed["host"]
			_resolved_udp_port = parsed["port"]

	_set_state(State.HANDSHAKING_UDP)
	_bind_udp_and_handshake()

func _on_udp_handshake_ack(msg: Dictionary) -> void:
	if _state != State.HANDSHAKING_UDP:
		return
	if not bool(msg.get("ok", false)):
		_transition_disconnected(DisconnectCode.UDP_HANDSHAKE_REJECTED,
				"udp handshake rejected")
		return
	_set_state(State.READY)
	_reconnect_attempt = 0  # success resets backoff
	connected.emit(_player_id)

# ---- State transitions --------------------------------------------

func _set_state(new_state: int) -> void:
	if _state == new_state:
		return
	_state = new_state
	state_changed.emit(new_state)

func _transition_disconnected(code: int, reason: String) -> void:
	# Tear down sockets. We may be called recursively from inside a
	# pump, so guard against re-entry by clearing before emitting.
	if _tcp != null:
		_tcp.disconnect_from_host()
		_tcp = null
	if _udp != null:
		_udp.close()
		_udp = null
	_tcp_rx_buf.clear()
	_udp_handshake_attempts = 0

	_set_state(State.DISCONNECTED)
	disconnected.emit(code, reason)

	# Schedule reconnect unless the user asked to stop.
	if code != DisconnectCode.USER_REQUESTED:
		_maybe_schedule_reconnect()

func _maybe_schedule_reconnect() -> void:
	if not _auto_reconnect:
		return
	if _credentials_bytes.is_empty():
		return
	if _reconnect_max_attempts >= 0 and _reconnect_attempt >= _reconnect_max_attempts:
		print("[GodotNet] auto-reconnect: gave up after %d attempts" % _reconnect_attempt)
		return
	var base_delay := _reconnect_initial_delay * pow(2.0, float(_reconnect_attempt))
	var delay: float = min(base_delay, _reconnect_max_delay)
	# ±20% jitter so a server blip doesn't thunder-herd reconnects.
	delay *= 1.0 + (randf() - 0.5) * 0.4
	_reconnect_attempt += 1
	_reconnect_at_msec = Time.get_ticks_msec() + int(delay * 1000.0)
	print("[GodotNet] auto-reconnect in %.1fs (attempt %d)" % [delay, _reconnect_attempt])

# ---- Misc ----------------------------------------------------------

# _parse_endpoint splits "host:port" or ":port" into a Dictionary.
# Returns {"host": String, "port": int}; port=-1 on parse failure.
func _parse_endpoint(s: String) -> Dictionary:
	var colon := s.rfind(":")
	if colon < 0:
		return {"host": "", "port": -1}
	var host := s.substr(0, colon)
	var port_str := s.substr(colon + 1)
	if not port_str.is_valid_int():
		return {"host": host, "port": -1}
	return {"host": host, "port": int(port_str)}
