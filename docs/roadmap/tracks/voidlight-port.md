## VoidLight Port Track Overview (Slices 49–63, extended by 64–75)

> [Roadmap index](../../framework-implementation-slices.md) · Slice files:
> [`../slices/`](../slices/) · Measured pressure points: [Scaling Gaps](../scaling-gaps.md)

Slices 49–63 add shipping features (combat, items, harvesting, worldgen,
time/weather, camera, UI, settings, saves, packaging, CI); Slices 64–71 finish
the track: cross-machine determinism and replay tooling (64), lane-heavy
consumers (65), distribution (66), UI/input/text completion (67), battle-scale
hardening (68), worldgen breadth and regional environment (69), presentation
polish (70), and AI behavior parity (71); 74 (world instances) and 75 (far
simulation) carry the multi-world direction. The older C++ VoidLight framework
is reference material only: each slice's **VoidLight reference** bullet is its
parity entry and never sets design or rules.

**Direction (owner).** Every world instance is fully simulated: everything in
it keeps advancing, with fidelity lowered by distance from the observer (the
camera focus, or a player when a game has one), never stopped; worlds the
observer is not in still step at lower fidelity. Worlds are created and
destroyed in play and own their storage. Terrain and nav are owned per chunk
`(level, cx, cy)` (64G). So every contract below holds per world instance,
and the checksum, saves, and replays cover every world instance and all
simulated state, including far-simulation state
(`.claude/rules/engine-design.md` § Target scale).

**Sizing** follows `.claude/rules/budgets-capacities.md`: runtime stores
(anchors, nodes, projectiles, populations, plan buffers, the inventory slot
arena) start content-sized and grow at the commit seam; terrain, nav, and
level links are chunk-owned; the 512-slot text-label pool is a presentation
pool.

**Shared contracts later slices rely on (one owner slice each):**

| Contract | Owner | Consumers |
| --- | --- | --- |
| Chunk-owned terrain and nav: the chunk is the unit of storage, change, work, threading, and save; nav covers the whole world | 64G | 38, 46, 49, 64B, 65B, 74, 75 |
| World instances created, stepped, and destroyed in play, each owning its storage; every world steps whether or not the observer is in it, at 75's lowest band when the observer is elsewhere | 74 | 46, 52C, 64B, 64C |
| Far simulation: fidelity by distance from the observer (slower AI ticks, never skipped progress; dormancy only for inert things; ambient recycling only for unimportant spawns), with a lowest band for worlds the observer is not in | 75 | 46, 49, 57, 62, 64B, 74 |
| `SimulationSeed` (`root`), `seed.derive(SeedDomain)` once at `SimulationPipeline.init`; append-only `SeedDomain` registry (`ai_wander = 1`, `worldgen_procedural = 2` land with 49; reserved: `combat = 3` 56, `loot = 4` 57, `dig_yield = 5` 58, `environment = 6` 59, `harvest = 7` 61, `population = 8` 62); per-world seeds derive from the root | 49 | 56–62, 74 |
| Simulation scope from fixed-step simulation inputs (the observer's `sim_view` through `simViewRegion`), never the render window; scope sets fidelity, never whether anything advances | 49 (60 supplies the rect; 75 adds the bands; 74 applies the lowest band to other worlds) | 55, 59, 62, 75 |
| `simulationChecksum()` same-binary oracle over every world instance, `checksum_format_tag`, `DataSystem`/`WorldSystem` completeness lists; replay frame with pinned gameplay bits (Table T1) | 49 | 46, 51, 52C, every persistent-state slice |
| Background lane `submit`/`complete` with step-keyed handoff at `submit + k`; `isDone` for app-layer consumers only | 51 | 46 |
| Absolute-step schedules through `stepAfter` / `stepReached` | 56 | 57, 59, 61, 62 |
| Shared action bus: one AI action emitter (`ai_action_select`, per-kind arms) and one `ActionClaimSet` / `action_claims`, claim order trade → harvest → destructible (`combat_resolve` takes unclaimed `.attack`); fairness from 68A | 56 | 57 (`.use`), 61, 63, 71D (`.sell`) |
| Inventory transfers: `TransferBatch` / `canAccept` / `canRemove` / `canRemoveCoins` / apply in `inventory_update`; `consume` (68C) | 57 (pipeline wiring lands with 61) | 61, 63, 68C |
| `PendingPlayerActions` UI→gameplay queue, `live_modal_overlay` preset, toast primitive, replay v3 action records (Table T1) | 57B | 63 |
| `AffectImpulse` queue, drained at the commit seam (none pending at a step boundary) | 61 | 63 (`.social`), 71A (`guard_alarm`) |
| Engine-owned `SettingsStore` (versioned ZON, upgrade chain, Table T2); settings never enter a save | 54 | 44, 60, 67A, 70B; a locale setting is deferred ([Deferred By Owner](../../framework-implementation-slices.md#deferred-by-owner)) |
| `StepIndex = u64` / `stepKey` | 49 | all |
| `normalizeDerivedState` (derived state, including all derived nav, rebuilt to equal a fresh init; never saved) + `buildFingerprint` | 64B | 46, 64C, 65B |
| `HeadlessSession` / session descriptor (creation inputs of the session's initial worlds and content) | 64C | — |
| Frozen-borrow job input | 51, amended by 65B | 65C |
| `StaticColliderIndex` | 71B | steering, collision |
| `StringId` registry | 67E | every later UI slice |
| Save buffer sized from content before encoding; no fixed save-size ceiling; untrusted reads bounded by file length and format widths; terrain saved per chunk, every chunk of every world | 46 | 67C, 69F (later saves only edited chunks, in any storage form) |

**Pipeline additions (merged `stage_order`):** `environment_update` (59) at
index 0; `ai_decide_gather` (55) between `affect_update` and `ai_decide`;
`knockback_apply` (68B) after `movement_integrate`; then `… chunk_derive →
ai_action_select (56) → action_react → projectile_update (56B) →
combat_resolve (56) → inventory_update (57) → social_react (63) → guard_alarm
(71A) → tier_policy → population_update (62)`. The full order is Table T4.

**Component tag projection:** 14 of 32 `Component` tags are used today.
Planned appends: 56 `health`, `combat_stats`; 56B `projectile`; 57
`inventory`, `equipment`, `world_item`; 61 `resource_node`; 62
`spawn_origin`; 63 `social_ledger`, `merchant`; then 71A `ai_post`: 11 new,
**25 of 32 (7 spare)** (Table T5). Tags append in landing order; slice text
does not pin their values.

## Authoritative Cross-Slice Tables (T1–T6)

These tables are the single source of truth for cross-slice numbering. Every
bump is **relative** (live value + 1 in the landing change); the "merged
order" numbers are the planned values when slices land in the
[Suggested Order](../../framework-implementation-slices.md#suggested-order).
A slice landing out of that order still takes live + 1 and updates the table
in the same change. A slice file that disagrees with a table is a defect: fix
both together.

### T1. Replay `held_gameplay_bits`, `flags`, and `replay_format_version`

| Bit | Action | Owner |
| --- | --- | --- |
| 0–7 | `move_left`, `move_right`, `move_up`, `move_down`, `dig_hole`, `dig_ramp`, `dig_down`, `interact` | live / 49 |
| 8 | `attack` | 56 |
| 9 | `use_item` | 57 |
| 10 | `camera_zoom_in` | 60 |
| 11 | `camera_zoom_out` | 60 |
| 12 | `rest` | 69C |
| 13–15 | must be 0 | — |

70B moves only pad bindings; no bit changes. Appending a bit needs no version
bump.

| `flags` bit | Meaning | Owner |
| --- | --- | --- |
| 0 | `pause_boundary_before_step` (was `resync_before_step`) | 49, renamed by 64A |
| 1–7 | must be 0 | — |

A save sets no flag: the saved image is normalized and the live session never
is (64B).

| `replay_format_version` | Change | Owner |
| --- | --- | --- |
| 1 | 48-byte header, chunked frames (`u32` steps) | 49 |
| 2 | header gains `build_fingerprint` and the session descriptor block | 64C |
| 3 | per-frame player action count + action records | 57B (after 64C) |
| 4 | action records gain `quantity`, `price_limit` | 63 |

Each bump is cumulative and keeps every earlier extension; the edge 64C → 57B
keeps the numbering correct. 64C sizes its descriptor block from the
creation inputs it must carry, so v2's byte layout is set when 64C lands.

### T2. Settings `k_settings_format_version` chain (relative, one upgrade step per version)

| Version | Slice | Change |
| --- | --- | --- |
| 1 | 54 | audio / video / accessibility |
| 2 | 44 | `.input.bindings` list form (keys as `SDL_Keycode`) |
| 3 | 60 | `video.zoom_index` |
| 4 | 67A | keyboard entries become `.scancode` (keymap-dependent migration; any upgrade requests a save) |
| 5 | 70B | `video.scene_resolution`, pad-default migration, explicit-beats-default loader rule |

69C `rest`, 56 `attack`, and 57 `use_item` add Controls rows without a bump
(list form). 67E adds no settings field; a locale setting belongs to the
deferred full localization and takes live + 1 when it lands.

### T3. Save file

`format_version` is relative. The immediately previous version still loads
only across header-only bumps (67C); payload bumps reject older files with
`SaveVersionUnsupported`.

**`SaveSlotHeader` (128 bytes, little-endian, offsets pinned by comptime asserts)**

| Off | Field | Type | Owner |
| --- | --- | --- | --- |
| 0 | magic "ZLSV" | [4]u8 | 46 |
| 4 | format_version | u16 | 46 |
| 6 | header_bytes = 128 | u16 | 46 |
| 8 | saved_unix_ms | i64 | 46 |
| 16 | playtime_steps | u64 (`StepIndex`, stored directly) | 46/49 |
| 24 | seed_root | u64 | 46 (64C New Game root) |
| 32 | build_fingerprint | u32 (`buildFingerprint()`, 64B) | 46 |
| 36 | reserved_pad0 | [4]u8 = 0 | 46 (explicit) |
| 40 | sim_checksum | u64 | 46 |
| 48 | content_fingerprint | u64 | 46 |
| 56 | payload_bytes | u64 | 46 |
| 64 | payload_crc32 | u32 | 46 |
| 68 | observer_level | u16 (slot display) | 46 |
| 70/72/74 | world_width / world_height / world_levels | u16 ×3 (the observer's current world; slot display only) | 46 |
| 76 | thumbnail_bytes | u32 (0 or 57,600) | 67C |
| 80 | thumbnail_crc32 | u32 | 67C |
| 84/86 | thumbnail_width / thumbnail_height | u16 (0/160, 0/90) | 67C |
| 88 | thumbnail_format | u8 | 67C |
| 89 | slot_name_len | u8 ≤ 32 | 67C |
| 90 | slot_name | [32]u8 | 67C |
| 122 | reserved | [6]u8 = 0 | — |

**File:** `header | thumbnail (thumbnail_bytes) | payload`.

**Payload sections** follow 64B's checksum section order, so the save and the
checksum walk the same field set. Sections 1–6 repeat per world instance
(74's instance records); 7 is session-level.

1. `entity_slots`.
2. One section per `DataSystem` store in declaration order. Later stores
   append: 56 health/combat_stats, 56B projectile, 57
   inventory/equipment/world_item plus the slot arena (logical contents only;
   layout is rebuilt on load), 61 resource_node, 62 spawn_origin, 63
   social_ledger/merchant/`FactionRelations`, 68C `pending_drops` (FIFO
   order), 71A ai_post. New columns in existing stores (68A
   `action_deferrals`, 68B knockback/retaliation), 73's cognition state
   (catalog data that 42 and 71D extend), and 75's far-simulation state ride
   in their owner's section.
3. `world_meta`: levels (plus 38 `level_elevation`), 58 `chunk_biomes`, 62
   `spawn_anchors` (live slots at their original IDs; +71A `patrol_route`), 69D
   `weather_overrides`. Derived indices rebuild after load.
4. `world_terrain`: per-chunk terrain content and the level links stored with
   their chunks (64G), then `world_markers`.
5. `world_environment` (64 addition (b): `game_ms`, `level_sky_exposed`).
6. `pipeline_history` (64B / 64 addition (c): interact, sensory, dig, ai,
   steering, plus 56 `attack_held_last`, the 57 use-item latch, 69C
   `rest_held_last`).
7. `player`.

No section holds derived nav state: the graph, path state, and any deferred
rebuild are `normalized` (64B) and rebuilt on load.

**Planned `format_version` sequence (merged order; the relative rule governs):**

| Version | Slice | Change |
| --- | --- | --- |
| v1 | 46 | base: cognition state (73), every world instance (74), far-simulation state (75), chunk terrain (64G), `pipeline_history` (64B) |
| v2 | 67C | header-only (thumbnail + slot name); v1 still accepted |
| v3 | 56 | health / combat_stats stores |
| v4 | 56B | projectile store |
| v5 | 59 | `world_environment` (clock, sky exposure) |
| v6 | 57 | inventory / equipment / world_item + slot arena |
| v7 | 69C | `rest_held_last` latch |
| v8 | 38 | `level_elevation` |
| v9 | 61 | resource_node store |
| v10 | 58 | `chunk_biomes`, `uniform_blocking` |
| v11 | 63 | social_ledger / merchant / `FactionRelations` |
| v12 | 62 | `spawn_anchors`, spawn_origin |
| v13 | 71A | ai_post store, `patrol_route` |
| v14 | 71D | trade behavior state (73 data) |
| v15 | 42 | caution and any further hashed affect state (73 data) |
| v16 | 68A | `AiAgent.action_deferrals` |
| v17 | 68B | knockback / retaliation fields |
| v18 | 68C | `pending_drops` FIFO, `WorldItem.coins` |
| — | 69D, 69F | gated (each live + 1 when its gate trips) |

65B, 65C, 67C (beyond its header bump), 69A, 69B, 69E, 70A, 70B, 71B, and 71C
add no saved state.

### T4. Merged `stage_order` (live 19, plus 55/56/56B/57/59/62/63, plus 64–71)

| # | Stage | Origin |
| --- | --- | --- |
| 0 | environment_update | 59; 69C `carried time_skip_request`; 69D `carried weather_overrides` |
| 1 | dig_world_edit | live |
| 2 | scope_advance_and_ai_gather | live |
| 3 | spatial_index_build | live; 68A entity table columns |
| 4 | perception_update | live |
| 5 | ai_memory_update | live; 68B `carried combat_state` |
| 6 | affect_update | live; 42 `+reads environment` (caution) |
| 7 | ai_decide_gather | 55 |
| 8 | ai_decide | live; 71A `carried spawn_anchors`; 71D `carried inventory_state`, `faction_relations` |
| 9 | steering_update | live; 71B.1 `carried static_colliders` |
| 10 | pathfinding_update | live; 71B.3 `carried interest_markers, spawn_anchors` |
| 11 | apply_ai_movement_intents | live |
| 12 | movement_integrate | live |
| 13 | **knockback_apply** | 68B; writes `movement_positions`, `movement_knockback` |
| 14 | collision_scope_gather | live |
| 15 | collision_detect | live; 71B `carried static_colliders` |
| 16 | collision_respond | live |
| 17 | bounds_and_tile_gate | live |
| 18 | plane_traversal | live |
| 19 | chunk_derive | live |
| 20 | ai_action_select | 56; 68A writes `ai_action_deferrals` |
| 21 | action_react | live |
| 22 | projectile_update | 56B |
| 23 | combat_resolve | 56; 68B `+writes movement_knockback`; 68C `+reads/writes inventory_transfers`, `+carried inventory_state` |
| 24 | inventory_update | 57 |
| 25 | social_react | 63 |
| 26 | **guard_alarm** | 71A; writes `affect_impulses` |
| 27 | tier_policy | live |
| 28 | population_update | 62 |

- **External resources:** `action_intents`, `interest_markers`,
  `structural_events`, plus `time_skip_request` (69C), `weather_overrides`
  (69D), and `static_colliders` (71B.1).
- **Comptime checks hold:** `knockback_apply` sits between
  `movement_integrate` and `chunk_derive`, so `chunk_columns` freshness holds;
  `combat_resolve`'s new write is not a derivation input; `guard_alarm` writes
  no position; every new `carried` entry is external or has a later writer
  (`combat_state` → `combat_resolve`, `spawn_anchors` → `population_update`,
  `inventory_state` → `inventory_update`).
- 64–67, 69A/B/E/F, 70, 71C, and 71D add no stage. 73, 74, and 75 state any
  stage they add here when they land.

### T5. Component tag tally

- Live: 14 (`data_system/types.zig`).
- VoidLight port: +10 (56: 2, 56B: 1, 57: 3, 61: 1, 62: 1, 63: 2) = 24.
- Slices 64–71: **+1** (`ai_post`, 71A); the rest add fields only or nothing.
- **Total 25 of 32 (7 spare). No widening slice is needed.** 73, 74, and 75
  state any tag they add here when they land.

### T6. `checksum_format_tag` (relative "v+1" string)

| Tag | Slice |
| --- | --- |
| v1 | 49 (with `StepIndex` u64 from day one; hashes 64G's chunk-owned terrain) |
| v2 | 73 (cognition state) |
| v3 | 74 (per-world state) |
| v4 | 75 (far-simulation scope state) |
| v5 | 64B (checksum v2; covers 73, 74, and 75) |
| v6 | 56 |
| v7 | 56B |
| v8 | 59 |
| v9 | 57 |
| v10 | 69C |
| v11 | 38 (`level_elevation`) |
| v12 | 61 |
| v13 | 58 |
| v14 | 63 |
| v15 | 62 |
| v16 | 71A |
| v17 | 71D |
| v18 | 42 |
| v19 | 68A |
| v20 | 68B |
| v21 | 68C |
| live + 1 | gated 69D when its gate trips |

Slices that change no hashed state take no bump: 67C, 70A/70B, 71B (index is
cache; prewarm is `normalized`), 71C, 69A, 69B (`chunk_biomes` already
hashed), 65B/65C, and 69F (chunk storage forms never change hashed state).
Slice 38's `level_sky_exposed` derivation changes no classification.
