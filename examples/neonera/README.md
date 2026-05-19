# Example: neonera

A richer demo than the root-level `test.gd` smoke test. This one uses
godobuf-generated GDScript classes for the game protocol — which is
how you'll actually structure a real game on top of godotnet-client.

Pairs with the `neonera` Go server from
[godotnet/docs/GETTING_STARTED.md](https://github.com/jordanstites/godotnet/blob/main/docs/GETTING_STARTED.md).

## Setup

1. **Install godobuf** in your Godot project.
   - Clone or download [oniksan/godobuf](https://github.com/oniksan/godobuf).
   - Copy its `addons/protobuf/` into your project's `addons/` folder.
   - Project → Project Settings → Plugins → enable **protobuf**.

2. **Generate `game_pb.gd`** from `game.proto`.
   - Open `Project → Tools → Godobuf`.
   - Input: `res://examples/neonera/game.proto`
   - Output: `res://examples/neonera/game_pb.gd`
   - Click "Generate".

3. **Wire up the scene.**
   - Create a new Node in any scene in your project.
   - Attach `neonera_demo.gd` to it.
   - Make sure the neonera Go server is running on `127.0.0.1:7777/7778`.
   - Run the scene.

## Expected output

```
[neonera] state -> CONNECTING_TCP
[neonera] state -> LOGGING_IN
[neonera] state -> HANDSHAKING_UDP
[neonera] state -> READY
[neonera] connected as player 1
[neonera] sending Move every 200ms
[neonera] PlayerMoved id=1 x=10.00 y=0.00 (via UDP)
[neonera] PlayerMoved id=1 x=9.51 y=3.09 (via UDP)
[neonera] PlayerMoved id=1 x=8.09 y=5.88 (via UDP)
...
```

Run two copies of Godot side-by-side (`--path` two project folders, or
just two scene instances in one editor session) to watch each one
receive the other's positions.

## Files

- `game.proto` — the game protocol (matches Step 2 of the godotnet getting-started).
- `neonera_demo.gd` — demo script. Connects, drives a circular motion, prints incoming `PlayerMoved`.
- `game_pb.gd` — **not checked in**. You generate this with godobuf in step 2.
