# godotnet-client

Godot 4 client plugin for the [godotnet](https://github.com/jordanstites/godotnet)
Go multiplayer server. Owns the TCP+UDP handshake, length-prefixed framing,
ping/pong, and auto-reconnect — exposes a small signal-driven API so your
game scripts just send and receive marshaled bytes.

**Status:** v0.1. API may still change. Pairs with godotnet server v0.1.x.

## Install

1. Copy `addons/godotnet_client/` into your Godot project's `addons/` folder.
2. Project → Project Settings → Plugins → enable **godotnet_client**.
3. A `GodotNet` autoload singleton is now available globally.

For game-plane messages you'll want [godobuf](https://github.com/oniksan/godobuf)
to generate GDScript classes from your own `game.proto`. The plugin itself
does **not** require godobuf — its control-plane messages are encoded in
`control_codec.gd` directly.

For a complete working setup (Godot project + paired Go server +
demos of every communication style), see the
[godotnet-demos](../godotnet-demos) sibling repo.

## Quick start

```gdscript
extends Node

func _ready() -> void:
    GodotNet.connected.connect(_on_connected)
    GodotNet.disconnected.connect(_on_disconnected)
    GodotNet.login_failed.connect(_on_login_failed)
    GodotNet.server_message.connect(_on_server_message)

    # Optional: reconnect automatically on dropped connection.
    GodotNet.set_auto_reconnect(true)

	# Your game's Credentials message, marshaled to bytes via godobuf.
	var creds := MyPb.Credentials.new()
	creds.set_username("alice")
	creds.set_token("dev")
	GodotNet.connect_to_server("127.0.0.1", 7777, creds.to_bytes(), 7778)

func _on_connected(player_id: int) -> void:
	print("connected as player ", player_id)

func _on_disconnected(code: int, reason: String) -> void:
	print("disconnected (%d): %s" % [code, reason])

func _on_login_failed(error_message: String) -> void:
	print("login failed: ", error_message)

func _on_server_message(payload: PackedByteArray, reliable: bool) -> void:
	var sm := MyPb.ServerMessage.new()
	if sm.from_bytes(payload) != MyPb.PB_ERR.NO_ERRORS:
		return
	if sm.has_moved():
		var m := sm.get_moved()
		_spawn_or_move(m.get_player_id(), m.get_x(), m.get_y())

func send_my_move(x: float, y: float) -> void:
	var move := MyPb.Move.new()
	move.set_x(x); move.set_y(y)
	var cm := MyPb.ClientMessage.new()
	cm.set_move(move)
	GodotNet.send_unreliable(cm.to_bytes())   # UDP, fast, lossy
```

## API

### Methods

| Method | Notes |
|---|---|
| `connect_to_server(host, tcp_port, credentials_bytes, udp_port=0) -> bool` | Begins handshake. `credentials_bytes` is your marshaled `Credentials` message. `udp_port` 0 means "use whatever the server advertises, else `tcp_port`". |
| `disconnect_from_server()` | Tears down TCP+UDP. Cancels any pending auto-reconnect. |
| `send_reliable(payload_bytes) -> bool` | TCP, ordered, lossless. Returns false if not READY. |
| `send_unreliable(payload_bytes) -> bool` | UDP, unordered, lossy. Returns false if not READY. |
| `set_auto_reconnect(enabled, initial_delay=1.0, max_delay=30.0, max_attempts=-1)` | Exponential backoff with ±20% jitter. `max_attempts=-1` is unlimited. |
| `get_state() -> int` | One of `State.DISCONNECTED / CONNECTING_TCP / LOGGING_IN / HANDSHAKING_UDP / READY`. |
| `is_ready() -> bool` | Shorthand for `get_state() == State.READY`. |
| `get_player_id() -> int` | 0 until READY. |

### Signals

| Signal | Notes |
|---|---|
| `connected(player_id: int)` | UDP handshake complete; safe to send game messages. |
| `disconnected(code: int, reason: String)` | Connection ended. See `DisconnectCode` for branching. |
| `login_failed(error_message: String)` | LoginResponse.ok was false. Always followed by `disconnected`. |
| `server_message(payload_bytes: PackedByteArray, reliable: bool)` | Every game payload from the server. `reliable=true` arrived via TCP. |
| `state_changed(new_state: int)` | Fires on each state transition. Convenient for connection-status UI. |

### DisconnectCode

| Code | Meaning |
|---|---|
| `USER_REQUESTED` | You called `disconnect_from_server()`. No reconnect attempted. |
| `TCP_CLOSED` | Server closed the TCP socket cleanly. |
| `TCP_ERROR` | Socket-level failure (connect refused, reset, etc). |
| `LOGIN_REJECTED` | Server's `LoginResponse.ok` was false. |
| `UDP_HANDSHAKE_REJECTED` | Server explicitly rejected the UDP pairing. |
| `UDP_HANDSHAKE_TIMEOUT` | No `UdpHandshakeAck` after the resend budget. Usually indicates a NAT/firewall problem. |
| `PROTOCOL_ERROR` | Malformed frame, length-prefix sanity failure, etc. |

## Thread model

All work happens on the main thread inside `_process`. `StreamPeerTCP.poll()`
and `PacketPeerUDP.get_packet()` are non-blocking. A long frame stall pauses
network reads (packets queue in the OS buffer until next frame) but for
games at 60fps this is invisible. The public signal contract doesn't depend
on this choice — if a future version needs a dedicated I/O thread, signals
will still emit on the main thread and existing user code will keep working.

## Limitations (v0.1)

- **No TLS.** Run the server behind a TLS-terminating reverse proxy if you
  need encryption. The plugin only speaks plain TCP/UDP.
- **No client-initiated ping.** RTT measurement isn't exposed because the
  protocol only has server → client `Ping`. We auto-reply with `Pong`.
- **No congestion control or pacing on UDP sends.** If you blast `put_packet`
  faster than the network can handle, packets will drop. Don't send more
  often than your simulation actually requires.

## License

MIT. See [LICENSE](LICENSE).
