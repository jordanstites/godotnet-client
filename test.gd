extends Node

# Self-contained smoke test for the godotnet_client plugin.
#
# Builds the protobuf messages by hand so we don't need godobuf set up
# yet — verifies the plugin end-to-end against the `neonera` server
# from godotnet/docs/GETTING_STARTED.md.
#
# Expected output (server running on 127.0.0.1):
#   [test] state -> 1 (CONNECTING_TCP)
#   [test] state -> 2 (LOGGING_IN)
#   [test] state -> 3 (HANDSHAKING_UDP)
#   [test] state -> 4 (READY)
#   [test] connected as player 1
#   [test] sent Move(42.5, 17.0)
#   [test] PlayerMoved id=1 x=42.50 y=17.00 (via UDP)

const HOST := "127.0.0.1"
const TCP_PORT := 7777
const UDP_PORT := 7778

func _ready() -> void:
	GodotNet.connected.connect(_on_connected)
	GodotNet.disconnected.connect(_on_disconnected)
	GodotNet.login_failed.connect(_on_login_failed)
	GodotNet.server_message.connect(_on_server_message)
	GodotNet.state_changed.connect(_on_state_changed)

	var creds := _encode_credentials("alice", "dev")
	GodotNet.connect_to_server(HOST, TCP_PORT, creds, UDP_PORT)

func _on_state_changed(new_state: int) -> void:
	print("[test] state -> %d" % new_state)

func _on_connected(player_id: int) -> void:
	print("[test] connected as player ", player_id)
	GodotNet.send_unreliable(_encode_client_message_move(42.5, 17.0))
	print("[test] sent Move(42.5, 17.0)")

func _on_disconnected(code: int, reason: String) -> void:
	print("[test] disconnected (code=%d): %s" % [code, reason])

func _on_login_failed(error_message: String) -> void:
	print("[test] login failed: ", error_message)

func _on_server_message(payload: PackedByteArray, reliable: bool) -> void:
	var moved := _decode_server_message_moved(payload)
	if moved.is_empty():
		print("[test] server_message len=%d (no PlayerMoved body)" % payload.size())
		return
	print("[test] PlayerMoved id=%d x=%.2f y=%.2f (via %s)" % [
		moved["player_id"], moved["x"], moved["y"],
		"TCP" if reliable else "UDP",
	])

# ---- Inline proto3 encoders/decoders --------------------------------
# These mirror the neonera game.proto from godotnet/docs/GETTING_STARTED.md.
# Keep here so the smoke test has zero runtime dependencies beyond the
# plugin itself.

# Credentials { string username = 1; string token = 2; }
static func _encode_credentials(username: String, token: String) -> PackedByteArray:
	var out := PackedByteArray()
	_append_string_field(out, 1, username)
	_append_string_field(out, 2, token)
	return out

# ClientMessage { oneof body { Move move = 1; } }
# Move { float x = 1; float y = 2; }
static func _encode_client_message_move(x: float, y: float) -> PackedByteArray:
	var move_bytes := PackedByteArray()
	_append_float_field(move_bytes, 1, x)
	_append_float_field(move_bytes, 2, y)
	var out := PackedByteArray()
	_append_message_field(out, 1, move_bytes)
	return out

# ServerMessage { oneof body { PlayerMoved moved = 1; } }
# PlayerMoved { uint32 player_id = 1; float x = 2; float y = 3; }
# Returns {} if the message has no PlayerMoved set.
static func _decode_server_message_moved(data: PackedByteArray) -> Dictionary:
	var i := 0
	while i < data.size():
		var tag_res := _read_varint(data, i)
		if tag_res[1] < 0: return {}
		var tag: int = tag_res[0]
		i = tag_res[1]
		var field := tag >> 3
		var wire := tag & 0x07
		if field == 1 and wire == 2:
			var ld := _read_len_delim(data, i)
			if ld[1] < 0: return {}
			return _decode_player_moved(ld[0])
		i = _skip_field(data, i, wire)
		if i < 0: return {}
	return {}

static func _decode_player_moved(data: PackedByteArray) -> Dictionary:
	var out := {"player_id": 0, "x": 0.0, "y": 0.0}
	var i := 0
	while i < data.size():
		var tag_res := _read_varint(data, i)
		if tag_res[1] < 0: return out
		var tag: int = tag_res[0]
		i = tag_res[1]
		var field := tag >> 3
		var wire := tag & 0x07
		if field == 1 and wire == 0:
			var v := _read_varint(data, i)
			if v[1] < 0: return out
			out["player_id"] = v[0]
			i = v[1]
		elif field == 2 and wire == 5:
			if i + 4 > data.size(): return out
			out["x"] = data.decode_float(i)
			i += 4
		elif field == 3 and wire == 5:
			if i + 4 > data.size(): return out
			out["y"] = data.decode_float(i)
			i += 4
		else:
			i = _skip_field(data, i, wire)
			if i < 0: return out
	return out

# ---- Wire helpers ---------------------------------------------------

static func _append_tag(buf: PackedByteArray, field: int, wire: int) -> void:
	_append_varint(buf, (field << 3) | wire)

static func _append_varint(buf: PackedByteArray, value: int) -> void:
	const MASK57 := 0x01FFFFFFFFFFFFFF
	for _i in range(10):
		var b := value & 0x7F
		var rest := (value >> 7) & MASK57
		if rest == 0:
			buf.append(b)
			return
		buf.append(b | 0x80)
		value = rest

static func _append_string_field(buf: PackedByteArray, field: int, s: String) -> void:
	var enc := s.to_utf8_buffer()
	_append_tag(buf, field, 2)
	_append_varint(buf, enc.size())
	buf.append_array(enc)

static func _append_message_field(buf: PackedByteArray, field: int, inner: PackedByteArray) -> void:
	_append_tag(buf, field, 2)
	_append_varint(buf, inner.size())
	buf.append_array(inner)

static func _append_float_field(buf: PackedByteArray, field: int, value: float) -> void:
	_append_tag(buf, field, 5)
	var fb := PackedByteArray()
	fb.resize(4)
	fb.encode_float(0, value)
	buf.append_array(fb)

static func _read_varint(data: PackedByteArray, offset: int) -> Array:
	var result := 0
	var shift := 0
	var i := offset
	while i < data.size():
		var b := data[i]
		i += 1
		result |= (b & 0x7F) << shift
		if (b & 0x80) == 0:
			return [result, i]
		shift += 7
		if shift >= 64:
			return [0, -1]
	return [0, -1]

static func _read_len_delim(data: PackedByteArray, offset: int) -> Array:
	var lr := _read_varint(data, offset)
	if lr[1] < 0: return [PackedByteArray(), -1]
	var n: int = lr[0]
	var start: int = lr[1]
	if n < 0 or start + n > data.size():
		return [PackedByteArray(), -1]
	return [data.slice(start, start + n), start + n]

static func _skip_field(data: PackedByteArray, offset: int, wire: int) -> int:
	match wire:
		0:
			var v := _read_varint(data, offset)
			return v[1]
		1:
			if offset + 8 > data.size(): return -1
			return offset + 8
		2:
			var ld := _read_len_delim(data, offset)
			return ld[1]
		5:
			if offset + 4 > data.size(): return -1
			return offset + 4
		_:
			return -1
