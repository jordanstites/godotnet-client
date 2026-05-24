# Compatibility

The wire protocol is defined by
[`controlpb/control.proto`](https://github.com/jordanstites/godotnet/blob/main/controlpb/control.proto)
in the godotnet server repo. This client vendors a copy at
[`addons/godotnet_client/control.proto`](addons/godotnet_client/control.proto)
for reference, and the actual codec lives in
[`addons/godotnet_client/control_codec.gd`](addons/godotnet_client/control_codec.gd).

Any wire-incompatible change to the server's `control.proto` requires a
matching change in `control_codec.gd` and a new release of this plugin.

## Version pairs

| godotnet-client | godotnet server | control.proto pinned at |
|---|---|---|
| 0.1.0 | 0.1.x | [`c03b7a4`](https://github.com/jordanstites/godotnet/blob/c03b7a4767d1bc94b4e351727162dbd638c69f87/controlpb/control.proto) |
| 0.2.0 | 0.2.x | unreleased — adds `RpcRequest` / `RpcResponse` messages and `rpc_request` (field 17) / `rpc_response` (field 17) oneof variants on `ClientFrame` / `ServerFrame` |

### 0.2.0 — RPC plane

Wire-additive change. The new fields use oneof tag 17 in both
directions and do not collide with existing tags (game_payload is 16,
control plane is 1–3). A 0.1.0 client talking to a 0.2.x server still
works for non-RPC traffic — unknown oneof variants are tolerated by
both sides per protobuf rules — but `rpc_call` on the client and
`HandleRPC` on the server require the matching pair to actually do
anything useful.

## How drift gets caught

Adding or renaming a control-plane field in the server repo is rare but
possible. To avoid silent breakage:

1. The vendored `control.proto` in this repo should always match the
   pinned upstream commit byte-for-byte.
2. When bumping the server version we pin against, diff the upstream
   `control.proto` against the vendored copy and update `control_codec.gd`
   for any field, type, or numbering change.
3. Game-plane messages (`game_payload` bytes) are user-defined and not
   affected by this compatibility table — they pass through opaquely.

The plain `game_payload` wrapper means most server-side feature work
(new ClientMessage variants, new handlers) does **not** require a client
plugin update. Only changes to `Login`, `LoginResponse`, `UdpHandshake`,
`UdpHandshakeAck`, `Ping`, `Pong`, or the frame wrappers themselves do.
