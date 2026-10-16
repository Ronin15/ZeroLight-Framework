## Slice 80: Observer And Optional Player Character

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: none · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Owner direction 2026-10-14: the game is a colony
simulator driven by where the player looks, and the framework lets a game add
a player character without special cases. Slices 60, 74, and 75 bind the
observer this slice creates.

Goal: one observer (position, level, world) is the only source of what the
simulation and presentation treat as "here": `sim_view`, scope bands, render
culling, the visible level, and the audio listener. A free camera or an
entity it follows drives the observer, and either can replace the other at
runtime without changing what runs. A player character is an ordinary
entity with an input controller: with none, nothing in the simulation looks
for one; with one, perception, AI, collision, the tile gate, plane
traversal, and audio treat it through the same paths as any entity.

### Current foundation

- The rule already states the target: a player entity is optional, and the
  observer is the camera focus or a player when a game has one
  (`.claude/rules/engine-design.md` § Target scale).
- `Player` (`src/game/player.zig:16`) holds `entity` and `current_level`;
  `GameDemoState` always spawns one.
- Camera: `cameraForPlayer` (`src/game/game_demo_state.zig:634`) always
  follows the player's body; `simViewRect()` (`:618`) derives `sim_view`
  from that camera, and scope is anchored at `player.current_level`.
- Render: `setVisibleChunksForWorldRect(..., player.current_level)`
  (`game_demo_state.zig:557`) and `render_prep.GameplayScene`
  (`player_entity`, `player_level`) pick the drawn level from the player.
- Dig: `DigController` (`src/game/dig_controller.zig:155`) captures dig
  presses and plans the cell the player faces on the player's level.
- Interact: `SimulationPipeline.captureActionIntent`
  (`src/game/simulation_pipeline.zig:1159`) builds intents for
  `player.entity`.
- Perception: a separate `PlayerPerceptionCandidate`
  (`simulation_pipeline.zig:1389`) beside the halo candidates.
- Tile gate: `gatePlayerToWalkableTiles` and `Player.clampToBounds`
  (`src/game/systems/world_gate.zig:25`) apart from the NPC gate.
- Plane traversal: NPC entries exclude the player
  (`src/game/systems/plane_entry.zig:154`); the player's ramp and fall run
  on their own path.
- Audio: `AudioController.queueAmbient` (`src/game/audio_controller.zig:49`)
  places the listener at the player's center and drives a player jet loop.
- AI: the tier-3 pursue fallback reads an optional player target
  (`src/game/systems/ai.zig:329`); decide steers to a demo constant when no
  player exists (index AI findings).
- `Faction.player` (`src/game/faction.zig:7`) is a faction value, not a
  singleton.

### Architecture notes

- Scope derives only from the fixed-step `sim_view`, never the render window
  (`.claude/rules/simulation.md` § Scope and tiers); the observer supplies
  that rect, and its source (free camera or followed entity) never changes
  how it is computed. Slice 60's rig drives the observer's camera; Slice 74
  binds it to the viewed world; Slice 75's bands read it.
- Swapping the observer's source happens at a between-step seam and changes
  only fidelity bands, never whether anything advances
  (`.claude/rules/engine-design.md` § Target scale).
- A player character is a controller that writes `navigation_intents` or
  `intents` and `action_intents` like any producer
  (`.claude/rules/simulation.md` § Controllers and processors); no stage
  reads a player handle, and no store or event holds one.
- Input stays `InputState` → controller; app commands stay in
  `FrameCommands` (`.claude/rules/input-state.md`).
- Gameplay logic stays in states, controllers, and processors, never in
  `Engine` (`.claude/rules/engine-design.md` § Ownership boundaries).
- Open owner question: in a game with no player character, how dig and build
  orders are issued (cursor designations, a job system, or both); this slice
  keeps today's dig behind the player controller until that is decided.

### Checklist

- [ ] Observer state owned by the gameplay state: position, level, world,
      and source (free camera or followed entity); `sim_view`, render
      culling, the visible level, and the audio listener read only it.
- [ ] Free-camera source with input and bounds, and a follow-entity source;
      a runtime swap at a between-step seam.
- [ ] Player character as an optional controller over an ordinary entity;
      the demo spawns one by default and runs with none.
- [ ] Remove the player special cases: perception candidate, tile gate and
      bounds, plane-traversal exclusion, AI player target, and audio jet
      loop go through the general paths or through the controller.
- [ ] Dig and interact capture move behind the player controller, pending
      the owner's answer on orders without a player.
- [ ] Checksum (Slice 49) covers the observer and any player controller
      state through the normal completeness lists.

### Acceptance checks

- [ ] A session with no player character runs, simulates, renders, and
      plays audio from a free camera; no code path asserts a player exists.
- [ ] A free-camera observer and a follow-entity observer that produce the
      same `sim_view` give the same per-step checksum trace, including
      across a mid-session swap between them.
- [ ] With a player character, perception, AI, collision, the tile gate,
      and plane traversal give the same results as for an NPC in the same
      situation.
- [ ] Serial and threaded runs match for all of the above; `zig build
      verify` passes.
- [ ] `docs/architecture.md` and `docs/state-stack-and-input.md` describe
      the observer and the player controller.
