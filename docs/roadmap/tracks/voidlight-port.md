## VoidLight Port Track Overview (Slices 49–63, extended by 64–71)

> [Roadmap index](../../framework-implementation-slices.md) · Slice files:
> [`../slices/`](../slices/) · Backlog: [Scaling Gaps](../scaling-gaps.md)

Origin: a feature comparison between ZeroLight and the older C++ VoidLight
framework chose ZeroLight as the go-forward base for every game. Slices 49–63
bring VoidLight's best shipping features (combat, items, harvesting, worldgen,
time/weather, camera, UI, settings, saves, packaging, CI) onto ZeroLight's
contracts: determinism (serial == threaded, scalar == SIMD, same seed → same
checksum), fixed budgets, world-sized capacities, and allocation-free hot
paths. Each slice ends with a
**VoidLight reference** block listing what to port and what not to. Slices
64–71 finish the track: cross-machine determinism and replay tooling (64),
lane-heavy consumers (65), distribution (66), UI/input/text completion (67),
battle-scale hardening (68), worldgen breadth and regional environment (69),
presentation polish (70), and AI behavior parity (71). Every former
"VoidLight port residuals" Scaling Gap is owned by one of these slices.

**Port rule.** Port features, never VoidLight's nondeterminism: no
`thread_local` `random_device`-seeded RNG, no `steady_clock` (or any wall time)
in gameplay, no completion-order application of path/job results, no
atomic-sequence conflict resolution, no `-ffast-math`
(`@setFloatMode(.optimized)`). Never port a world-scaled work budget (for
example VoidLight's `worldW / 200` pathfinding sectors): per-step and per-query
budgets stay fixed counts, with deterministic deferral when they bind.
Data-structure capacities (anchor and node stores, the projectile live store,
persistent populations, plan buffers) are sized from the loaded world and
content at init/load and reserved up front (`FailingAllocator`-proven).
Stores that grow at runtime (the inventory slot arena, level links, and any
later runtime node producer) take a content-derived initial size and grow
geometrically at the main-thread structural-commit seam, refusing only at a
format/index ceiling. Fixed caps remain for format/index limits, loud
load-time safety ceilings, and standard fixed pools (the 512-slot text-label
pool with idle reclaim), and heuristic thresholds derive from the cost of the
operation they gate (coding-standards § Budgets, Capacities, And Thresholds).

**Shared contracts later slices rely on (one owner each; never fork them):**

| Contract | Owner | Consumers |
| --- | --- | --- |
| `SimulationSeed` (`root`), `seed.derive(SeedDomain)` once at `SimulationPipeline.init`; append-only `SeedDomain` registry (reserved: `combat = 3` 56, `loot = 4` 57, `dig_yield = 5` 58, `environment = 6` 59, `harvest = 7` 61, `population = 8` 62) | 49 | 56–62 |
| Sim scope from the fixed-step `sim_view` (`GameDemoState.simViewRect()`), read only through `SimulationPipeline.simViewRegion(context)`; never the render window | 49 (60 supplies the rect body) | 55, 59, 62 |
| `GameDemoState.simulationChecksum()` same-binary oracle, `checksum_format_tag`, `DataSystem`/`WorldSystem` completeness lists; replay frame with pinned gameplay bits (8 `attack`, 9 `use_item`, 10/11 zoom, 12 `rest`; Table T1) | 49 | 46, 51, 52C, every persistent-state slice |
| Background lane `submit`/`complete` with step-keyed handoff at `submit + k` (`background_handoff`); `isDone` for app-layer consumers only | 51 | 46 |
| Absolute-step schedules through `stepAfter` / `stepReached` | 56 | 57, 59, 61, 62 |
| Shared action bus: one AI action emitter (`ai_action_select`, per-kind arms) and one `ActionClaimSet` / `action_claims`, claim order trade → harvest → destructible (`combat_resolve` takes unclaimed `.attack`); fairness policy (deferral-age priority) from Slice 68A | 56 | 57 (`.use`), 61, 63, 71D (`.sell`) |
| Inventory transfers: `TransferBatch` / `InventoryTransferQueue.tryAppend` / `canAccept` / `canRemove` / `canRemoveCoins` / `applyTransferBatch` (phase 0 of `inventory_update`); `consume` (68C) | 57 (pipeline wiring lands with 61) | 61, 63, 68C |
| `PendingPlayerActions` UI→gameplay queue, `live_modal_overlay` preset, toast primitive, replay format v3 action records (Table T1) | 57B | 63 |
| `AffectImpulse` queue, drained at the commit seam (no impulse pending at a step boundary) | 61 | 63 (`.social`), 71A (`guard_alarm`) |
| Engine-owned `SettingsStore` (versioned ZON, `upgradeVNToVN+1` chain, Table T2); settings never enter a save | 54 | 44 (bindings), 60 (zoom), 67A (scancodes), 70B (scene resolution); a locale setting is deferred ([Deferred By Owner → Full localization](../../framework-implementation-slices.md#deferred-by-owner)) |
| `StepIndex = u64` / `stepKey` | 49 | all |
| `normalizeDerivedState` + `buildFingerprint` | 64B | 46, 64C, 69F |
| `HeadlessSession` / `GameSessionDescriptor` | 64C | — |
| Frozen-borrow job input | 51, amended by 65B | 65C |
| `StaticColliderIndex` | 71B | steering, collision |
| `TransferBatch.consume` | 57, added by 68C | — |
| `StringId` registry | 67E | every later UI slice |
| `encodedSaveBytes` / `saveSizeBound` (save and region-image buffer sized from content; `k_max_save_file_bytes` is only a loud ceiling on encode and untrusted reads) | 46 | 67C (header + thumbnail + payload bound), 69F (`RegionImage`) |

**Pipeline additions (merged `stage_order`):** `environment_update` (59) at
index 0; `ai_decide_gather` (55) between `affect_update` and `ai_decide`;
`knockback_apply` (68B) after `movement_integrate`; then `… chunk_derive →
ai_action_select (56) → action_react → projectile_update (56B) →
combat_resolve (56) → inventory_update (57) → social_react (63) → guard_alarm
(71A) → tier_policy → population_update (62)`. The full numbered order is
Table T4.

**Component tag projection:** 14 of 32 `Component` tags are used today. Planned
appends: 56 `health`, `combat_stats`; 56B `projectile`; 57 `inventory`,
`equipment`, `world_item`; 61 `resource_node`; 62 `spawn_origin`; 63
`social_ledger`, `merchant`; then 71A `ai_post`. That is 11 new, **25 of 32
(7 spare)** when all land (Table T5). Slices 49–55, 58, 59, 60, and 64–71
except 71A add none (worldgen, clock, and anchor state live on `WorldSystem`;
`FactionRelations` is a `DataSystem` field). Tags are appended in landing order
and never pinned in slice text.

## Authoritative Cross-Slice Tables (T1–T6)

These tables are the single source of truth for cross-slice numbering. They
were produced by the cross-slice consistency review of drafts 64–71 against
33–63 and reconciled with the final slice files when the roadmap was split
into per-slice files. Every bump is **relative** (live value + 1 in the
landing change); the "merged order" numbers below are the planned values when
slices land in the [Suggested Order](../../framework-implementation-slices.md#suggested-order).
If a slice lands out of that order, it still takes live + 1 and updates this
table in the same change. A slice file that disagrees with a table is a
defect: fix the slice text and the table together.

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

70B moves only pad *bindings* (R3/L3 zoom; RT/LT `attack`/`use_item`). No bit
changes. Appending a bit needs no version bump (49's rule).

| `flags` bit | Meaning | Owner |
| --- | --- | --- |
| 0 | `pause_boundary_before_step` (was `resync_before_step`) | 49, renamed by 64A |
| 1 | `normalized_before_step` (+ stepper `replayNormalize()`) | 69F (gated) |
| 2–7 | must be 0 | — |

**Flag bit1 owner (resolved).** An earlier draft of this table assigned bit1
to Slice 46 (via 64B). The final design moved it: Slice 64B's B5 decision
makes the *saved image* normalized and never normalizes the live session, so
a save is not a simulation event and sets no flag (Slice 46 Checklist: "a
replay recorded across a save verifies `matched` with no flag bits set";
Slice 51: the capture never sets bits 1–7 for a save). The first and only
live normalization point is Slice 69F's region swap, so 69F pins bit1 and
adds `replayNormalize()` in its own change (Slice 64 addition (m)). 64B owns
`normalizeDerivedState` itself; no 64 code path sets bit1.

| `replay_format_version` | Change | Owner |
| --- | --- | --- |
| 1 | 48-byte header, chunked frames (u32 steps) | 49 |
| 2 | 80-byte header: `build_fingerprint` at 44, 32-byte session block 48–79 | 64C |
| 3 | per-frame `player_action_count` + `ReplayActionRecord`s | 57B (after 64C) |
| 4 | `ReplayActionRecord` gains `quantity`, `price_limit` | 63 |
| 5 | 88-byte header: `region_x` i16 @80, `region_y` i16 @82, `reserved3` u32 @84 | 69F (gated) |

Normative rule: live value + 1, cumulative (Slice 64 addition (d)); a bump
keeps every earlier header and frame extension. The edge 64C → 57B keeps the
numbering correct.

### T2. Settings `k_settings_format_version` chain (relative, `upgradeVNToVN+1`)

| Version | Slice | Change |
| --- | --- | --- |
| 1 | 54 | audio / video / accessibility |
| 2 | 44 | `.input.bindings` list form (keys as `SDL_Keycode`) |
| 3 | 60 | `video.zoom_index` |
| 4 | 67A | keyboard entries become `.scancode` (keymap-dependent migration step; freeze rule: any upgrade sets `save_requested`) |
| 5 | 70B | `video.scene_resolution`, plus the pad-default migration (attack→RT, use_item→LT when old default; zoom→R3/L3 when absent or `.none`) and the explicit-beats-default loader rule |

69C `rest`, 56 `attack`, and 57 `use_item` add Controls rows without a bump
(list form). Slice 67E (Localization Roots) adds no settings field or
version; a locale setting belongs to the deferred full localization
([Deferred By Owner](../../framework-implementation-slices.md#deferred-by-owner))
and takes the live value + 1 when it lands.

### T3. Save file

`format_version` is relative; loader policy: the immediately previous version
still loads only for header-only bumps (67C); payload bumps reject older files
with `SaveVersionUnsupported`.

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
| 68 | player_level | u16 | 46 |
| 70/72/74 | world_width / world_height / world_levels | u16 ×3 | 46 |
| 76 | thumbnail_bytes | u32 (0 or 57,600) | 67C |
| 80 | thumbnail_crc32 | u32 | 67C |
| 84/86 | thumbnail_width / thumbnail_height | u16 (0/160, 0/90) | 67C |
| 88 | thumbnail_format | u8 | 67C |
| 89 | slot_name_len | u8 ≤ 32 | 67C |
| 90 | slot_name | [32]u8 | 67C |
| 122 | region_x | i16 (0 when not paged) | 69F |
| 124 | region_y | i16 | 69F |
| 126 | reserved | [2]u8 = 0 | — |

**File:** `header | thumbnail (thumbnail_bytes) | payload`.

**Payload sections**, in canonical order: the checksum section order of 64B
B2, so the save and the checksum walk the same field set.

1. `entity_slots`.
2. One section per `DataSystem` store in declaration order. Later stores
   append here: 56 health/combat_stats, 56B projectile,
   57 inventory/equipment/world_item plus the slot arena (run layout is not
   persisted; load rebuilds runs from the initial bound and grows the arena at
   the structural-commit seam, refusing only at the `u32` ceiling with
   `InventorySlotArenaTooLarge`), 61 resource_node,
   62 spawn_origin, 63 social_ledger/merchant/`FactionRelations`,
   68C `pending_drops` (FIFO order, `head` = 0 on load), 71A ai_post. New
   columns in existing stores (42 `AiAffect.gain_fear_caution`, 68A
   `AiAgent.action_deferrals`, 68B knockback/retaliation fields, 71D
   `AiAgent.gain_trade`) ride in their store's section.
3. `world_meta`: levels (plus 38 `level_elevation`), 58 `chunk_biomes`, 62
   `spawn_anchors` (+71A `patrol_route`), and 69D `weather_overrides`. 62
   `spawn_anchors` is variable-length: it records the slot high-water mark
   (`<= maxInt(u16)`) so load reserves the store to it and restores live slots
   at their original `SpawnAnchorId` indices. `SpawnAnchorChunkIndex` is never
   saved; `finalizeChunkIndex` rebuilds it after load. No `format_version`
   renumbering: 62's v11 already carries the section.
4. `world_dense`, then `world_sparse`, then `world_markers`.
5. `world_environment` (64 addition (b): `game_ms`, `level_sky_exposed`).
6. `pipeline_history` (64B / 64 addition (c): interact, sensory, dig, ai,
   steering, plus 56 `attack_held_last`, the 57 use-item latch, and the 69C
   `rest_held_last`).
7. `player`.

There are no `nav_history`/`nav_deferred` sections (65B's deferred job is
`normalized`, never saved). 69F region images are separate files under
`saves/slot_<n>.regions/`.

**Planned `format_version` sequence (merged order; the relative rule governs):**

| Version | Slice | Change |
| --- | --- | --- |
| v1 | 46 | base, including `pipeline_history` from 64B |
| v2 | 67C | header-only (thumbnail + slot name); v1 still accepted |
| v3 | 56 | health / combat_stats stores |
| v4 | 56B | projectile store |
| v5 | 57 | inventory / equipment / world_item + slot arena |
| v6 | 59 | `world_environment` (clock, sky exposure) |
| v7 | 69C | `rest_held_last` latch |
| v8 | 61 | resource_node store |
| v9 | 58 | `chunk_biomes`, `uniform_blocking` |
| v10 | 63 | social_ledger / merchant / `FactionRelations` |
| v11 | 62 | `spawn_anchors`, spawn_origin |
| v12 | 71A | ai_post store, `patrol_route` |
| v13 | 71D | `AiAgent.gain_trade` |
| v14 | 42 | `AiAffect.gain_fear_caution` (Slice 69 addition) and any further hashed affect columns |
| v15 | 68A | `AiAgent.action_deferrals` |
| v16 | 68B | knockback / retaliation fields |
| v17 | 68C | `pending_drops` FIFO, `WorldItem.coins` |
| — | 69D, 69F | gated (each live + 1 when its gate trips) |
| — | 38 | `level_elevation`: a bump only if 38 lands after 46 (live + 1); before 46 it is part of v1 |

Reconciled against the final slice files: 69C is v7 and 61 is v8 (the merged
order lands 69C first; the earlier table had them swapped); Slice 71D's
`gain_trade` is hashed, saved state, so it takes one relative step (v13),
which moves 42/68A/68B/68C to v14–v17. 65B, 65C, 67C (beyond its header
bump), 69A, 69B, 69E, 70A, 70B, 71B, and 71C add no saved state.

### T4. Merged `stage_order` (live 19, plus 55/56/56B/57/59/62/63, plus 64–71)

| # | Stage | Origin |
| --- | --- | --- |
| 0 | environment_update | 59; 69C `carried time_skip_request`; 69D `carried weather_overrides` |
| 1 | dig_world_edit | live |
| 2 | scope_advance_and_ai_gather | live |
| 3 | spatial_index_build | live; 68A halo table columns |
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
- **Comptime checks:** no conflicts.
  - `knockback_apply` sits between `movement_integrate` and `chunk_derive`,
    so the `chunk_columns` freshness derivation holds.
  - `combat_resolve`'s new write (`movement_knockback`) is not a derivation
    input.
  - `guard_alarm` writes no position.
  - Every new `carried` entry is external or has a later writer:
    `combat_state`→`combat_resolve`, `spawn_anchors`→`population_update`,
    `inventory_state`→`inventory_update`.
  - 64, 65, 66, 67, 69A/B/E/F, 70, 71C, and 71D add no stage (65B mutates the
    graph only at `main_thread_inputs`, outside the order).
  - Raise `@setEvalBranchQuota` once for 29 stages.

### T5. Component tag tally

- Live: 14 (`types.zig:61-76`).
- VoidLight port: +10 (56: 2, 56B: 1, 57: 3, 61: 1, 62: 1, 63: 2) = 24.
- Slices 64–71: **+1** (`ai_post`, 71A). 64, 65, 66, 67, 68 (fields only:
  `MovementBody.knockback_v*`, `Health.last_attacker_*`, `AiMemory`
  retaliation, `AiAgent.action_deferrals`, `WorldItem.coins`, and the
  `DataSystem.pending_drops` field), 69, 70, 71B, 71C, and 71D add none.
- **Total 25 of 32 (7 spare). No widening slice is needed.**

### T6. `checksum_format_tag` (relative "v+1" string)

| Tag | Slice |
| --- | --- |
| v1 | 49 (with `StepIndex` u64 from day one) |
| v2 | 64B |
| v+1 each | every later slice that adds or reclassifies hashed state, in merged order: 56, 56B, 57, 59, 69C, 61, 58, 63, 62, 71A, 71D, 42, 68A, 68B, 68C; gated 69D/69F; 38 only if it lands after 49 |

Slices that change no hashed state take no bump: 67C (header-only save
change), 70A/70B, 71B (index is cache; prewarm is `normalized`), 71C, 69A,
69B (`chunk_biomes` already hashed), 65B/65C. Slice 38's
`level_sky_exposed` derivation changes no classification.
