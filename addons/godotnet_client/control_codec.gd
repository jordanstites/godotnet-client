extends RefCounted

# Hand-rolled protobuf codec for the godotnet control plane (Login,
# LoginResponse, UdpHandshake, UdpHandshakeAck, Ping, Pong, and the
# ClientFrame/ServerFrame wrappers). Self-contained — no godobuf
# runtime dependency. Mirrors controlpb/control.proto.

const WIRE_VARINT := 0
const WIRE_LEN_DELIM := 2

# ---- Outbound (ClientFrame) -----------------------------------------

# encode_login wraps the user's marshaled Credentials bytes in a Login
# message and then in a ClientFrame{login=...}.
static func encode_login(credentials_bytes: PackedByteArray) -> PackedByteArray:
	var login_body := PackedByteArray()
	_append_tag(login_body, 1, WIRE_LEN_DELIM)
	_append_len_delim(login_body, credentials_bytes)
	return _wrap_client_frame(1, login_body)

static func encode_udp_handshake(player_id: int, session_token: String) -> PackedByteArray:
	var body := PackedByteArray()
	_append_tag(body, 1, WIRE_VARINT)
	_append_varint(body, player_id)
	_append_tag(body, 2, WIRE_LEN_DELIM)
	_append_len_delim(body, session_token.to_utf8_buffer())
	return _wrap_client_frame(2, body)

static func encode_pong(nonce: int) -> PackedByteArray:
	var body := PackedByteArray()
	_append_tag(body, 1, WIRE_VARINT)
	_append_varint(body, nonce)
	return _wrap_client_frame(3, body)

# encode_game_payload wraps user-marshaled ClientMessage bytes in a
# ClientFrame{game_payload=...}. Field 16, wire type 2.
static func encode_game_payload(payload: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	_append_tag(out, 16, WIRE_LEN_DELIM)
	_append_len_delim(out, payload)
	return out

static func _wrap_client_frame(field: int, inner: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	_append_tag(out, field, WIRE_LEN_DELIM)
	_append_len_delim(out, inner)
	return out

# ---- Inbound (ServerFrame) ------------------------------------------

# decode_server_frame returns a Dictionary describing the populated
# oneof:
#   {"kind": "login_response", "ok": bool, "error_message": String,
#    "player_id": int, "session_token": String, "udp_endpoint": String}
#   {"kind": "udp_handshake_ack", "ok": bool, "player_id": int}
#   {"kind": "ping", "nonce": int}
#   {"kind": "game_payload", "payload": PackedByteArray}
#   {"kind": "unknown"}             # oneof unset or unknown field
#   {"kind": "error", "reason": String}
static func decode_server_frame(data: PackedByteArray) -> Dictionary:
	var i := 0
	var result := {"kind": "unknown"}
	while i < data.size():
		var tag_res := _read_varint(data, i)
		if tag_res[1] < 0:
			return {"kind": "error", "reason": "truncated tag"}
		var tag: int = tag_res[0]
		i = tag_res[1]
		var field := tag >> 3
		var wire := tag & 0x07
		match field:
			1: # LoginResponse, wire 2
				if wire != WIRE_LEN_DELIM:
					return {"kind": "error", "reason": "bad wire on field 1"}
				var ld := _read_len_delim(data, i)
				if ld[1] < 0:
					return {"kind": "error", "reason": "truncated login_response"}
				result = _decode_login_response(ld[0])
				i = ld[1]
			2: # UdpHandshakeAck, wire 2
				if wire != WIRE_LEN_DELIM:
					return {"kind": "error", "reason": "bad wire on field 2"}
				var ld2 := _read_len_delim(data, i)
				if ld2[1] < 0:
					return {"kind": "error", "reason": "truncated udp_handshake_ack"}
				result = _decode_udp_handshake_ack(ld2[0])
				i = ld2[1]
			3: # Ping, wire 2
				if wire != WIRE_LEN_DELIM:
					return {"kind": "error", "reason": "bad wire on field 3"}
				var ld3 := _read_len_delim(data, i)
				if ld3[1] < 0:
					return {"kind": "error", "reason": "truncated ping"}
				result = _decode_ping(ld3[0])
				i = ld3[1]
			16: # game_payload bytes, wire 2
				if wire != WIRE_LEN_DELIM:
					return {"kind": "error", "reason": "bad wire on field 16"}
				var ld4 := _read_len_delim(data, i)
				if ld4[1] < 0:
					return {"kind": "error", "reason": "truncated game_payload"}
				result = {"kind": "game_payload", "payload": ld4[0]}
				i = ld4[1]
			_:
				# Unknown field — skip per protobuf rules.
				var ni := _skip_field(data, i, wire)
				if ni < 0:
					return {"kind": "error", "reason": "truncated unknown field"}
				i = ni
	return result

static func _decode_login_response(data: PackedByteArray) -> Dictionary:
	var out := {
		"kind": "login_response",
		"ok": false,
		"error_message": "",
		"player_id": 0,
		"session_token": "",
		"udp_endpoint": "",
	}
	var i := 0
	while i < data.size():
		var tag_res := _read_varint(data, i)
		if tag_res[1] < 0:
			return {"kind": "error", "reason": "truncated LoginResponse tag"}
		var tag: int = tag_res[0]
		i = tag_res[1]
		var field := tag >> 3
		var wire := tag & 0x07
		match field:
			1:
				var v := _read_varint(data, i)
				if v[1] < 0: return {"kind": "error", "reason": "trunc lr.ok"}
				out["ok"] = v[0] != 0
				i = v[1]
			2:
				var s := _read_len_delim(data, i)
				if s[1] < 0: return {"kind": "error", "reason": "trunc lr.error"}
				out["error_message"] = (s[0] as PackedByteArray).get_string_from_utf8()
				i = s[1]
			3:
				var v3 := _read_varint(data, i)
				if v3[1] < 0: return {"kind": "error", "reason": "trunc lr.id"}
				out["player_id"] = v3[0]
				i = v3[1]
			4:
				var s4 := _read_len_delim(data, i)
				if s4[1] < 0: return {"kind": "error", "reason": "trunc lr.token"}
				out["session_token"] = (s4[0] as PackedByteArray).get_string_from_utf8()
				i = s4[1]
			5:
				var s5 := _read_len_delim(data, i)
				if s5[1] < 0: return {"kind": "error", "reason": "trunc lr.udp"}
				out["udp_endpoint"] = (s5[0] as PackedByteArray).get_string_from_utf8()
				i = s5[1]
			_:
				var ni := _skip_field(data, i, wire)
				if ni < 0: return {"kind": "error", "reason": "trunc lr.unknown"}
				i = ni
	return out

static func _decode_udp_handshake_ack(data: PackedByteArray) -> Dictionary:
	var out := {"kind": "udp_handshake_ack", "ok": false, "player_id": 0}
	var i := 0
	while i < data.size():
		var tag_res := _read_varint(data, i)
		if tag_res[1] < 0:
			return {"kind": "error", "reason": "truncated ack tag"}
		var tag: int = tag_res[0]
		i = tag_res[1]
		var field := tag >> 3
		var wire := tag & 0x07
		match field:
			1:
				var v := _read_varint(data, i)
				if v[1] < 0: return {"kind": "error", "reason": "trunc ack.ok"}
				out["ok"] = v[0] != 0
				i = v[1]
			2:
				var v2 := _read_varint(data, i)
				if v2[1] < 0: return {"kind": "error", "reason": "trunc ack.id"}
				out["player_id"] = v2[0]
				i = v2[1]
			_:
				var ni := _skip_field(data, i, wire)
				if ni < 0: return {"kind": "error", "reason": "trunc ack.unknown"}
				i = ni
	return out

static func _decode_ping(data: PackedByteArray) -> Dictionary:
	var out := {"kind": "ping", "nonce": 0}
	var i := 0
	while i < data.size():
		var tag_res := _read_varint(data, i)
		if tag_res[1] < 0:
			return {"kind": "error", "reason": "truncated ping tag"}
		var tag: int = tag_res[0]
		i = tag_res[1]
		var field := tag >> 3
		var wire := tag & 0x07
		match field:
			1:
				var v := _read_varint(data, i)
				if v[1] < 0: return {"kind": "error", "reason": "trunc ping.nonce"}
				out["nonce"] = v[0]
				i = v[1]
			_:
				var ni := _skip_field(data, i, wire)
				if ni < 0: return {"kind": "error", "reason": "trunc ping.unknown"}
				i = ni
	return out

# ---- Low-level wire helpers -----------------------------------------

static func _append_tag(buf: PackedByteArray, field: int, wire: int) -> void:
	_append_varint(buf, (field << 3) | wire)

# _append_varint writes value as a protobuf varint. Treats value as
# unsigned 64-bit; negative GDScript ints are encoded with their full
# 64-bit pattern (matches the round-trip we need for Ping/Pong nonces).
static func _append_varint(buf: PackedByteArray, value: int) -> void:
	# Mask used to clear sign-extension after each arithmetic right shift.
	# 0x01FF...FFFF = (1 << 57) - 1, the max remaining bits after a >> 7.
	const MASK57 := 0x01FFFFFFFFFFFFFF
	for _i in range(10):
		var b := value & 0x7F
		var rest := (value >> 7) & MASK57
		if rest == 0:
			buf.append(b)
			return
		buf.append(b | 0x80)
		value = rest
	# Should never reach here for valid uint64s.

static func _append_len_delim(buf: PackedByteArray, payload: PackedByteArray) -> void:
	_append_varint(buf, payload.size())
	buf.append_array(payload)

# _read_varint returns [value, new_offset], or [_, -1] on truncation /
# overflow.
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

# _read_len_delim returns [bytes, new_offset], or [_, -1] on truncation.
static func _read_len_delim(data: PackedByteArray, offset: int) -> Array:
	var lr := _read_varint(data, offset)
	if lr[1] < 0:
		return [PackedByteArray(), -1]
	var n: int = lr[0]
	var start: int = lr[1]
	if n < 0 or start + n > data.size():
		return [PackedByteArray(), -1]
	return [data.slice(start, start + n), start + n]

static func _skip_field(data: PackedByteArray, offset: int, wire: int) -> int:
	match wire:
		0: # varint
			var v := _read_varint(data, offset)
			return v[1]
		1: # fixed64
			if offset + 8 > data.size(): return -1
			return offset + 8
		2: # length-delimited
			var ld := _read_len_delim(data, offset)
			return ld[1]
		5: # fixed32
			if offset + 4 > data.size(): return -1
			return offset + 4
		_:
			return -1
