# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`godotnet-client` is the Godot 4 client plugin for the [godotnet](../godotnet/) Go multiplayer server (sibling repo on disk). It owns the TCP+UDP handshake, length-prefixed framing, ping/pong reply, and auto-reconnect, exposing a signal-driven `GodotNet` autoload singleton to game scripts.

Status is v0.1. Pairs with godotnet server v0.1.x.

## Repo layout

| Path | Purpose |
|---|---|
| [addons/godotnet_client/plugin.gd](addons/godotnet_client/plugin.gd) | Plugin entry — registers `GodotNet` as an autoload |
| [addons/godotnet_client/network.gd](addons/godotnet_client/network.gd) | The singleton — state machine, sockets, signals, public API |
| [addons/godotnet_client/control_codec.gd](addons/godotnet_client/control_codec.gd) | Hand-written codec for the control-plane protobuf messages |
| [addons/godotnet_client/control.proto](addons/godotnet_client/control.proto) | Vendored copy of the server's wire schema — reference only, not parsed at runtime |
| [examples/neonera/](examples/neonera/) | Sample game integration |
| [project.godot](project.godot), [test.gd](test.gd), [node.tscn](node.tscn) | Minimal Godot project at the repo root for testing the plugin in-place |

## Commands

There is no build step. To exercise the plugin:

- Open the repo in Godot 4 (the repo root IS a Godot project).
- Project → Project Settings → Plugins → enable **godotnet_client**.
- Run [test.gd](test.gd) / [node.tscn](node.tscn) against a running godotnet server.

For consuming projects, installation is "copy `addons/godotnet_client/` into your Godot project's `addons/`, then enable the plugin."

## Architecture

### Thread model

Everything runs on the main thread inside `_process`. `StreamPeerTCP.poll()` and `PacketPeerUDP.get_packet()` are non-blocking; a slow frame just leaves packets in the OS buffer until the next frame. The public signal contract (which guarantees signals fire on the main thread) is intentionally decoupled from this — a future version could move I/O to a worker thread without breaking user code.

### Client state machine

```
DISCONNECTED → CONNECTING_TCP → LOGGING_IN → HANDSHAKING_UDP → READY
```

Transitions are emitted via `state_changed(new_state)`. `READY` is the only state in which `send_reliable` / `send_unreliable` / `rpc_call` succeed.

`DisconnectCode` distinguishes USER_REQUESTED, TCP_CLOSED, TCP_ERROR, LOGIN_REJECTED, UDP_HANDSHAKE_REJECTED, UDP_HANDSHAKE_TIMEOUT, PROTOCOL_ERROR — auto-reconnect logic and UI both branch on it.

### Wire format (the contract with the server)

Every TCP frame is `[4-byte BE length][ClientFrame protobuf bytes]`. Every UDP datagram is a bare `ClientFrame` protobuf. The `oneof body` discriminates control plane (`Login`, `UdpHandshake`, `Pong`) from game plane (`game_payload` — opaque bytes containing the game's marshaled top-level `ClientMessage`) from RPC plane (`RpcRequest` carries `correlation_id` + opaque user request bytes; the server's `RpcResponse` mirrors the id back).

The plugin **does not depend on [godobuf](https://github.com/oniksan/godobuf) for its own messages.** Control-plane encode/decode is implemented by hand in [control_codec.gd](addons/godotnet_client/control_codec.gd) precisely so that consumers only need godobuf for their own `game.proto`. Game-plane payloads pass through opaquely as `PackedByteArray` — `send_reliable` / `send_unreliable` take raw bytes; `server_message(bytes, reliable)` delivers raw bytes.

### Public API surface

`GodotNet` autoload singleton:

- Methods: `connect_to_server(host, tcp_port, credentials_bytes, udp_port=0)`, `disconnect_from_server()`, `send_reliable(bytes)`, `send_unreliable(bytes)`, `rpc_call(request_bytes, timeout_sec=10.0)` (await it), `set_auto_reconnect(enabled, initial_delay=1.0, max_delay=30.0, max_attempts=-1)`, `get_state()`, `is_ready()`, `get_player_id()`.
- Signals: `connected(player_id)`, `disconnected(code, reason)`, `login_failed(error_message)`, `server_message(payload_bytes, reliable)`, `state_changed(new_state)`.
- Auto-reconnect uses exponential backoff with ±20% jitter. `max_attempts = -1` is unlimited. Calling `disconnect_from_server()` cancels any pending reconnect.
- `rpc_call` returns a Dictionary `{ok, payload, error_message, error_code, timed_out}`. `error_code` is one of `GodotNet.RpcErrorCode.{NONE, NOT_CONNECTED, SERVER_ERROR, TIMEOUT, DISCONNECTED}` for branchable failure modes. Awaiting calls in flight during a disconnect are resolved with `DISCONNECTED` rather than hanging. Correlation IDs are managed internally — multiple concurrent `rpc_call` awaiters work and complete in arbitrary order.

## Compatibility with the server

The wire protocol is owned by the server repo. This plugin **vendors** `control.proto` at [addons/godotnet_client/control.proto](addons/godotnet_client/control.proto) for reference; the runtime codec is hand-written in `control_codec.gd`. [COMPATIBILITY.md](COMPATIBILITY.md) pins a specific upstream commit hash and version pair.

When updating against a new server release:

1. Diff `../godotnet/internal/proto/control.proto` against the vendored copy here.
2. If any field, type, or numbering changed in `Login` / `LoginResponse` / `UdpHandshake` / `UdpHandshakeAck` / `Ping` / `Pong` / `ClientFrame` / `ServerFrame`, update `control_codec.gd` accordingly.
3. Refresh the vendored `.proto` to match byte-for-byte.
4. Bump the table in `COMPATIBILITY.md` (and the plugin `version` in [addons/godotnet_client/plugin.cfg](addons/godotnet_client/plugin.cfg)).

Most server-side feature work — new user `ClientMessage` / `ServerMessage` variants, new server handlers — passes through `game_payload` opaquely and does NOT require a plugin update.

## Known v0.1 limitations (don't paper over)

- **No TLS in the plugin.** Run the server behind a TLS-terminating reverse proxy for encryption.
- **No client-initiated ping.** The protocol only has server→client `Ping`; the plugin auto-replies `Pong`. RTT is not exposed.
- **No UDP send pacing / congestion control.** Faster-than-network `put_packet` calls drop packets. Callers must rate-limit themselves.

If a request would address these by adding partial fixes, push back — these are intentional v0.1 scope cuts, not oversights.
