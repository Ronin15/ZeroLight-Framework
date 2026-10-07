## Slice 64B: Simulation Checksum v2 — NaN-Canonical, Sectioned, Threaded, Pipeline-History Coverage

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 49](slice-49.md), [Slice 50](slice-50.md), [Slice 64A](slice-64a.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Depends on **49** (`StateHasher`,
`SimulationChecksum`, completeness lists, `simulation-checksum` bench),
**50** (owner-thread `parallelFor` rules), and **64A** (pause is
simulation-invisible, so no pipeline field needs a pause exemption). Land
**before 46**: Slice 46 saves exactly the fields this slice classifies as
hashed, never saves the `normalized` class (a load constructs it fresh, which
B5 proves equal to a normalized pipeline), uses `normalizeDerivedState` as
its load-parity reference, and writes this slice's `buildFingerprint()` into
its header (see Checklist additions). Slices 56 and 57 add their input
latches to this slice's lists (Checklist additions). Steps are Slice 49's
`StepIndex` (`u64`) throughout.

Goal: the checksum (1) is a pure function of IEEE-observable state, so
NaN payload and sign never cause a false cross-machine mismatch, and NaN
presence is still reported; (2) covers every piece of carried pipeline history
that changes future persistent state, with a comptime-enforced classification
of every `SimulationPipeline` field; (3) hashes the dense tile grid in fixed-size
blocks on the `ThreadSystem` with an ordered combine, so the value is identical
serial or threaded; and (4) stays an allocation-free, same-build oracle.

### Current foundation (do not rebuild)

- Slice 49 (spec; not yet live): `src/core/state_hash.zig` `StateHasher`
  (Wyhash seed 0, fold rules, raw-bytes floats); `src/game/simulation_checksum.zig`
  (`checksum_format_tag = "zl-sim-checksum-v1"`, `ChecksumInput` with
  `step: StepIndex` hashed as `u64`, `compute`);
  `DataSystem.hashSimulationState` (`data_system/checksum.zig`) and
  `WorldSystem.hashSimulationState` with comptime completeness lists;
  `GameDemoState.simulationChecksum()`; bench group `simulation-checksum`
  (256×256 tiles, 32 dense layers = 4 MiB of `TileId`, `serial-direct` only,
  1.5 ms gate at 10,000 items).
- Live pipeline history (`simulation_pipeline.zig:585-631`):
  - `interact_held_last` (`:627-629`);
  - `sensory: SensoryBus` (`sensory_bus.zig:43-52`): `deferred_stimuli[0..
    deferred_stimulus_count]` (capacity 16), `sticky_stimuli`/`sticky_remaining
    [0..sticky_count]` (capacity `(8+1)*(4-1) = 27`); arrays are `undefined`
    past the counts; `WorldStimulus = { position: Vec2, intensity: f32, kind:
    StimulusKind, level: u16 }` (`simulation.zig:587-592`);
  - `dig: DigController` (`dig_controller.zig:70-83`): `hole_held_last`,
    `down_held_last`, `ramp_held_last`, `player_last_cell: ?CellCoord`;
    `ramp_tile`/`tunnel_tile` are asset config; `plane_tile_changes` is
    per-step scratch;
  - `ai: AiSystem` (`systems/ai.zig:394-406`): `snapped_goal`,
    `snapped_goal_initialized` (broadcast goal requantization state);
  - `steering: SteeringSystem.runtime_rows: std.ArrayList(RuntimeRow)`
    (`systems/steering.zig:110-113`, `RuntimeRow` `:1009-1027`: entity,
    `previous_progress_distance`, `has_previous_distance`, `stuck_steps`,
    `replan_cooldown`, `unavailable_backoff`, `waypoint_hint`, `prev_dir_x/y`,
    `has_prev_dir`) — per-entity history outside `DataSystem`;
  - `pathfinding: PathfindingSystem` (`systems/pathfinding/system.zig:74-111`):
    `pending`, `completed: ResultCache` (clock-hand eviction over physical
    probe slots, `caches.zig:520-529`; TTL stamps from `step_counter`),
    `unavailable`/`pending_keys` (`KeySet`), `group_fields` (4 fields of
    O(cells) arrays, `group_field.zig:38-57`), `group_requests`,
    `group_key_map`, `next_group_evict`, `effective_agent_capacity`,
    `low_load_steps`, and `graph: NavGraph`. After **64E** the graph's portals
    and each portal's edge *sequence* equal a full rebuild. Only the per-chunk
    edge-window layout (`chunk_edge_cap`/`chunk_edge_base`/`edge_hole_slots`,
    measured at the last full build, then moved by window growths and arena
    compactions) depends on build history. A relocation or compaction changes
    where a window sits in the arena, never the order of a portal's edges, and
    abstract A* walks each portal's edges in that order, so search results do
    not depend on the layout (64E tests: `expectPortalEdgeSequencesEqual` and
    "abstract A* after an edge-window growth returns the paths of a fresh full
    rebuild");
  - `perception.level_blocked` + `step_counter` (`systems/perception.zig:500-518`):
    an LOS cache whose scoped patch is proven equal to a full rebuild
    (`perception.zig:2576-2793` tests);
  - steering static obstacle index (invalidated by post-commit events,
    `steering.zig:1911` test) and `steering_movement_index` (rebuilt after
    structural invalidate, `:1863` test);
  - every system's `AdaptiveWorkTuner`s; per-step gather scratch;
    `audio_controller` (presentation).
- Dense tiles: `WorldSystem.dense_tile_ids: std.ArrayList(TileId)`
  (`world_system.zig:306`), all layers concatenated (`denseLayerOffset`).
  There is no fixed dense-layer count cap (the GPU byte budget
  `k_max_dense_tile_gpu_bytes = 64 MiB`, `:66`, bounds it per world size), so
  a digest slot per layer cannot be a fixed array.
- `ThreadSystem.parallelForWithOptions` (`thread_system.zig:843`) with
  `items_per_range`, `adaptive = false`; Slice 50 forced-inline and owner rules.

### Architecture notes

**B1. NaN canonicalization in `StateHasher` (decision: canonicalize, and count).**

Chosen over a finite-state assertion because:
- the checksum must be a pure function of state the simulation can observe.
  IEEE comparisons, select-form min/max (64A), `floorToI4` (NaN → 0), and
  `floatKeyBits` (64A) never observe NaN sign or payload, while the bits differ
  across x86/arm64 and even within one binary between LLVM-folded and runtime
  NaNs (64A probe: `0x7fc00000` vs `0xffc00000`);
- the oracle runs inside saves (46), replay verification (49/64C), and CI
  digests (52C). It must stay total: a panic there destroys the diagnostic it
  exists to produce, and ReleaseFast would strip an assert anyway;
- NaN in persistent state is still a defect (`DataSystem` setters reject
  non-finite input, for example `data_system/movement.zig:26-29`), so its
  presence is counted and treated as a failure by the harness, the runner, and
  the soak.

Rules:
- `f32`/`f64` (scalar, column, or `[N]f32` array element) are hashed with
  every NaN replaced by the canonical quiet NaN (`0x7fc00000` /
  `0x7ff8000000000000`). `-0.0` and `+0.0` stay distinct, and ±inf is kept.
- **Struct-typed values recurse.** The per-field fold walks struct fields
  (and arrays of structs) recursively and applies the NaN rule to every float
  leaf, so an `f32` embedded in a struct-typed column or entry is
  canonicalized too (for example `WorldStimulus.position: Vec2` and
  `.intensity`, `simulation.zig:587-592`, inside `SensoryBus` entries, and
  `RuntimeRow`'s `f32` fields). A struct value is never hashed as one raw
  byte blob. Non-float leaves keep 49's fold rules.
- **Vector NaN primitives live in `core/simd.zig`** (64B adds them; the
  `NAN_SELF_COMPARE` lint, `tools/lint_idioms.py:60-63`, exempts only
  `src/core/simd.zig`, so a `v != v` in `state_hash.zig` would fail
  `zig build verify`):

  ```zig
  /// Lane mask of NaN lanes (`v != v`, the only NaN-exact IEEE compare).
  pub inline fn nanMaskFloat4(values: Float4) Mask4 { return values != values; }
  /// True when any lane of `mask` is set. Pairs with the existing `countTrue`.
  pub inline fn anyTrue(mask: Mask4) bool { return @reduce(.Or, mask); }
  ```

  Both are `inline fn` (52D's Mask4 rule, `MASK_FN_NOT_INLINE`). Scalar
  parity test in `simd.zig`: for `{1, NaN 0x7fc00000, NaN 0xffc00000,
  sNaN 0x7f800001, +inf, -0}` in every lane position, `nanMaskFloat4` lane i
  equals `std.math.isNan(lane i)`, and `anyTrue` equals the OR of the scalar
  results.
- Fast path: a column is scanned once with `simd.loadFloat4` +
  `simd.nanMaskFloat4`, OR-accumulating masks and testing once per column
  with `simd.anyTrue`; the scalar tail (and every `f64`) uses
  `std.math.isNan`. `state_hash.zig` contains no raw `@Vector` and no
  self-compare. With no NaN, the column is hashed with one raw `update`
  (byte-identical to v1). Otherwise it is staged through the existing
  256-byte stack buffer with NaN lanes replaced. Both paths give the same
  digest for a NaN-free column.
- `StateHasher.nan_count: u64` counts replaced values.

**B2. Section digests and ordered combine (format tag = live value + 1).**

The tag bump is relative: this slice sets `checksum_format_tag` to the live
tag's version + 1. In the merged order Slice 49 ships v1 and nothing between
49 and 64B bumps it, so the value is `"zl-sim-checksum-v2"` below; if a
hashed-state slice lands first, use the next free number instead.

```zig
pub const checksum_format_tag = "zl-sim-checksum-v2"; // live + 1 (v2 in the merged order)
pub const checksum_dense_block_tiles: usize = 32 * 1024;     // 64 KiB of TileId per block
pub const checksum_digest_slots: usize = 256;                // per dispatch round, 2 KiB stack
pub const checksum_parallel_min_items: usize = 8;            // fewer work items → serial
pub const ChecksumReport = struct { value: u64, nan_values: u64, fixed_sections: u32, dense_blocks: u32 };
pub fn computeReport(input: ChecksumInput, thread_system: ?*ThreadSystem) ChecksumReport;
pub fn compute(input: ChecksumInput) u64; // computeReport(input, null).value
```

- `ChecksumInput` gains `pipeline: *const SimulationPipeline`.
- **Fixed sections, canonical order** (comptime list; each is one `StateHasher`
  that starts with `beginSection(name, len)` and ends in `final()`):
  1. `"header"`: tag, `seed.root`, `step` (`StepIndex`, folded as `u64`;
     Slice 49);
  2. `"entity_slots"`: slots, `first_free_slot`, `free_slot_count`,
     `tier_counts` (v1 rules);
  3. one section per `DataSystem` store, in declaration order
     (`DataSystem.checksum_store_count` comptime; v1's `multiArrayList` per
     store; a store with its own `hashSimulationState` keeps it);
  4. `"world_meta"`: every hashed `WorldSystem` field except
     `dense_tile_ids`, `sparse_tiles`, and `interest_markers` (v1 list, plus
     the fields later slices append: 59 `clock`/`level_sky_exposed`, 58
     `chunk_biomes`, 62 `spawn_anchors`);
  5. `"world_sparse"`: `sparse_tiles` MAL rows;
  6. `"world_markers"`: v1's live-slot marker rule plus `retired_generations`
     and `live_count`;
  7. `"pipeline_history"`: B4;
  8. `"player"`: `entity`, `current_level`.

  A comptime assert keeps the fixed section count `≤ 64` (`≤
  checksum_digest_slots`).
- **Dense blocks**: `dense_tile_ids` is cut into `ceil(len /
  checksum_dense_block_tiles)` blocks. Block `i` is the raw bytes of tiles
  `[i*B, min((i+1)*B, len))`, hashed with `beginSection("dense_block", i)`.
- **Combine** (normative order): `Wyhash(0)` over the tag bytes, `u64`
  fixed-section count, each fixed digest (`u64` LE), `u64` dense-block count,
  then each block digest in block order. `value = final()`;
  `nan_values` = sum of the per-section `nan_count`s.
- Why fixed-size blocks instead of one digest per dense layer: uniform work
  items; one fixed 256-slot round buffer regardless of layer count (no
  allocation, and no array sized to the world); the same value at any layer
  count or thread count. The value is a pure function of state: block
  boundaries depend only on `dense_tile_ids.len`.
- **Execution**:
  - Round 0 runs the fixed sections.
  - Dense blocks run in rounds of ≤ 256 work items.
  - Each round writes `digests[k]` and `nan_counts[k]` (disjoint `u64` stack
    slots, fully reserved before dispatch).
  - The combine folds the round's slots in index order after the batch joins.
  - Dispatch: `thread_system.parallelForWithOptions(round_len, &ctx,
    checksumWorkJob, .{ .items_per_range = 1, .adaptive = false })` when
    `thread_system != null` and `round_len >= checksum_parallel_min_items`.
    Otherwise the items run inline in index order.
  - `checksumWorkJob` opens with
    `std.debug.assert(range.index < round_len)` and
    `std.debug.assert(range.end <= round_len and round_len <=
    checksum_digest_slots)` (`round_len` is captured in the job context from
    the dispatch's own value), so a worker can never write outside the
    round's reserved `digests`/`nan_counts` slots.
  - Jobs only read `*const DataSystem`, `*const WorldSystem`, and
    `*const SimulationPipeline`.
  - Digest slots are unpadded: one 8-byte write per ≥ 64 KiB of hashing makes
    false sharing irrelevant (the 64-byte rule covers concurrently written
    records, not one-shot result slots).
- **Callers**: owner thread only (Slice 50 rule).
  `GameDemoState.simulationChecksum()` stays serial and returns the same
  value. New `GameDemoState.simulationChecksumReport(thread_system:
  ?*ThreadSystem) ChecksumReport`. Slice 51 capture checkpoints, 64C's runner,
  46's save, and 52C's `frame-battle` digest pass their `ThreadSystem`.
- **Allocation**: none. `computeReport` takes no allocator; the round
  buffers are stack arrays.
- **Build fingerprint (single owner, here so 46 does not wait on 64C).**
  `pub fn buildFingerprint() u32` in `simulation_checksum.zig`, beside
  `checksum_format_tag`: `std.hash.Crc32` over `build_options.app_version`,
  `builtin.zig_version_string`, and `checksum_format_tag`, through the
  private pure `fingerprintFor(version, zig_version, tag) u32`. If 52B has
  not landed, this slice adds the `app_version` build option (default: the
  `build.zig.zon` `.version` string) to both `buildOptions` and
  `benchBuildOptions`, and 52B reuses it. Consumers: Slice 64C's replay
  header and Slice 46's `SaveSlotHeader.build_fingerprint`. No second Crc32
  exists anywhere.

**B3. Field classification (comptime completeness, extends Slice 49's rule).**

Every `SimulationPipeline` field, and every field of each pipeline-owned
subsystem whose state is hashed, is listed in exactly one of these class
lists. A comptime walk (the same `@typeInfo` field-name walk as
`simulation_pipeline.zig:288`) fails compilation for an unclassified or
doubly-classified field.

| Class (list name) | Meaning | Saved by 46? |
| --- | --- | --- |
| `checksum_hashed_fields` | carried history that changes future persistent state and is not derivable from `DataSystem`/`WorldSystem`/step | yes, verbatim |
| `checksum_normalized_fields` | history-dependent derived state, reset/rebuilt by `normalizeDerivedState` (B5) at a recorded normalization point; not hashed | no (rebuilt) |
| `checksum_cache_fields` | output-transparent cache: a cold rebuild gives identical outputs (each entry cites its proving test) | no |
| `checksum_excluded_fields` | config, per-step scratch, tuners, telemetry, allocators, presentation, or derived-from-hashed state | no |

Classification at landing (later slices classify their own fields in the
same change):

| Field | Class | Note |
| --- | --- | --- |
| `interact_held_last` | hashed | input edge latch |
| `sensory` | hashed | `SensoryBus.hashSimulationState`: `deferred_stimulus_count` + live entries; `sticky_count` + live entries + `sticky_remaining[0..sticky_count]`; `config` and `hearing_stimuli_scratch` excluded |
| `dig` | hashed | `DigController.hashSimulationState`: three latches + `player_last_cell` (optional fold); `ramp_tile`, `tunnel_tile`, `plane_tile_changes`, `scratch_allocator`, 72's `plane_scratch_reserved` reservation, 64E's `ramp_refused_link_slots` telemetry + `nav_link_geometry` config, and 72's `plane_scratch_grown` telemetry excluded |
| `ai` | hashed | `AiSystem.hashSimulationState`: `snapped_goal` (x, y), `snapped_goal_initialized`; `allocator`, `rows`, `candidates`, both tuners excluded |
| `steering` | hashed | `SteeringSystem.hashSimulationState`: `runtime_rows` in list order, every `RuntimeRow` field folded per field (`entity` raw, `f32` NaN-canonical, `bool` fold, `u16`/`u32` raw); all other fields: scratch, derived (`steering_movement_index*`), cache (obstacle snapshot + index, `steering.zig:1911`), tuner; 72's `static_snapshot_grown_total`/`static_snapshot_grow_warned` telemetry excluded |
| `pathfinding` | normalized | lifecycle, caches, group fields, dirty marks, 64E's `nav_links_processed` cursor, 65B's deferred state, 71B.3's prewarm fields, and the nav graph (B5). Not `cache`: cache warmth changes simulation results (B5 tests) |
| `perception` | cache | `level_blocked`/`step_counter` (`perception.zig:2576-2793`), including each level slot's `pending_dirty` list and `full_rebuild_pending` flag (load-reserved and bounded; Checklist "B3 perception cache bound"); rows/candidates/ranges scratch; tuner; 72's `dropped_events_warned` diagnostic excluded |
| `scope` | excluded | `step_count` is hashed in `"header"`; indices/ranges scratch; tuners; `stagger_skips`, `chunk_filtered_entities` telemetry |
| `movement`, `collision`, `collision_response`, `spatial_index`, `ai_memory`, `affect` | excluded | per-step scratch + tuners; 72's affect `dropped_events_warned` diagnostic excluded |
| `destructible` | excluded | no fields |
| `audio_controller` | excluded | presentation (never feeds simulation) |
| `nav_cell_size`, `structural_headroom` | excluded | config |
| `movement_body_capacity`, `responder_capacity`, `perception_max_events_per_step`, `affect_max_events_per_step` | excluded | derived capacity (grown only at the commit seam, Slice 72 C3; output-transparent) |
| `population_capacity_grows`, `population_growth_logged` | excluded | telemetry |
| `pathfinding.capacity.max_agent_budget` (seam-raised) and `agent_budget_raise_refused_at` (72 C3) | hashed | history-dependent ceiling that changes future request intake; not derivable from `DataSystem` |
| `action_intents_dropped_step` | excluded | telemetry, reset each update |
| `seed` (49) | excluded | `seed.root` is in `"header"` |
| `ai_intent_seed` (49) | excluded | derived from `seed` |

Rules:
- A later controller with carried state (56 `attack_held_last`, 57 use-item
  latch, 59 `EnvironmentController` = excluded-derived, 61/62/63 controllers)
  classifies it in the same change. A hashed addition is also a Slice 46 save
  field.
- A field type with no fold rule is changed to a foldable type, never given a
  new fold rule (49's rule).
- Moving a field between classes, or adding a hashed field, changes the
  checksum. Bump `checksum_format_tag` to the live value + 1 in that change
  (relative, never a hard-coded number).

**B4. `"pipeline_history"` section.** `SimulationPipeline.hashSimulationState
(hasher)` hashes the hashed fields in the table order above, each under its
own `beginSection` name (`"interact"`, `"sensory"`, `"dig"`, `"ai"`,
`"steering"`), so two fields cannot alias. Cost is bounded by fixed capacities
(43 stimuli, a few scalars) plus steering rows (≤ steering agent capacity, 40
bytes each, about 80 KiB at 2048).

**B5. `normalizeDerivedState` (backs the `normalized` class).**

- `PathfindingSystem.normalize(data, world, bounds_width, bounds_height,
  cell_size, thread_system)`:
  - clears `pending`, `prepared_requests`, `solve_results`,
    `fallback_indices`, `completed`, `unavailable`, `pending_keys`,
    `group_requests`, `group_key_map`, and the `resize_*` snapshots;
  - sets every `group_fields[i].state = .empty`;
  - zeroes `step_counter`, `next_group_evict`, and `low_load_steps`;
  - restores `effective_agent_capacity` to the value `reserve` set;
  - runs the same `rebuildStaticNavGridWithWorld` as init, at reserved
    capacity (cold path; it may grow nav buffers within the existing
    high-water rule).
  - **Completeness** (every `PathfindingSystem` field, including state later
    slices add):
    - (a) when Slice 65B has landed, calls `abandonDeferred()` first and
      asserts `swap_event_pending == false`;
    - (b) clears `nav_dirty_edits`, `nav_dirty_cell_spans`, and
      `nav_dirty_levels`: their edits are already in the world the rebuild
      reads, and a fresh system holds none;
    - (c) leaves `nav_links_processed == world.levelLinks().len` through the
      full build (64E);
    - (c′) the full build resets `nav_link_cursor_pending` and syncs the
      graph's `edge_windows_grown_reported` / `edge_compactions_reported`
      to their totals (64E M7/M10);
    - (d) when Slice 71B.3 has landed, resets every `group_fields[i]` to
      `.empty` with `origin = .demand` and `prewarm_source = .none`.

    A later slice that adds a `PathfindingSystem` field adds it to
    `normalize` and to `"normalized pathfinding equals a freshly initialized
    system"` in the same change.
- `SimulationPipeline.normalizeDerivedState(data, world, thread_system)`
  calls it with the pipeline's stored bounds and `nav_cell_size`. Main thread,
  cold, never in the frame loop.
- Contract: after `normalizeDerivedState`, the pipeline's `normalized` fields
  equal those of a pipeline freshly `init`ed over the same `DataSystem`,
  `WorldSystem`, and config.
- **Why `normalized`, not `cache`: cache state changes simulation results.**
  Live evidence:
  - steering calls `pathfinding.statusForWorld(...)` every selected step
    (`steering.zig:777`) and branches on it (`:778-827`): `.available`
    steers along the cached waypoint; `.missing` emits a request and sets
    `runtime.replan_cooldown` (`:801-807`); `.pending` holds direction;
    `.unavailable` sets `unavailable_backoff`. Those cooldowns are hashed
    `RuntimeRow` history, and the directions become `movement_intents`;
  - acceptance short-circuits on `completed.findFresh(..., step_counter,
    default_cache_ttl_steps)` (`system.zig:1055-1080`); a miss enters
    `pending`, capped by `max_pending_requests` (overflow counts
    `dropped_requests`, `:1081-1084`), and competes for the per-step solve
    ceiling `capacity.max_solved_requests_per_step` (`types.zig:121,495`)
    and the fallback budget. Cache warmth therefore changes which requests
    are solved, deferred, or dropped on a step;
  - the group-field sample short-circuit (`system.zig:1022-1053`) works the
    same way, and TTL uses the wrapping `step_counter` (`:860`).

  Eviction is layout-dependent, and the nav graph's edge-window layout
  depends on build history (64E makes its content history-free, not its
  layout). Hashing and persisting all of it would mean hashing 4 × O(cells)
  group-field arrays plus a megabyte-scale path stripe store at every
  checkpoint, and persisting nav graph internals.
- **Saves (decision: the saved image is normalized; the live session never
  is).** Slice 46 saves no `normalized` field, so a load constructs a fresh
  `PathfindingSystem`, which the contract above makes equal to a normalized
  one. `SaveCapture` does **not** call `normalizeDerivedState` on the live
  session: saving changes nothing the continuing session can observe (no
  cache clear, no abandoned 65B job, no nav rebuild on the main thread at
  save time). Stated effects:
  - the continuing session's per-step checksum trace after a save equals a
    never-saved run's (Slice 46 addition (c) test);
  - a session loaded at step S equals the continuing session **normalized
    at S** (reference run calls `normalizeDerivedState` at S), not the
    un-normalized continuing session. The loaded side starts with cold path
    caches and group fields, so its NPCs re-request paths and their first
    paths land one solve later than in the continuing session. That
    divergence is the accepted cost of not persisting pathfinding;
  - the only nav rebuild is the load's existing post-load
    `rebuildStaticNavGridWithWorld`; its time on the 256×256×32 production
    world is recorded by Slice 46 (addition (c) acceptance item).
  - `normalizeDerivedState`'s callers are therefore the load-parity
    reference in tests and the determinism harness, Slice 65B's
    abandon-on-normalize contract, and Slice 69F's region swap (a live
    normalization point, which pins replay `flags` bit1
    `normalized_before_step` and the `replayNormalize()` stepper method in
    its own change, Checklist additions (m)). No 64 code path sets flags
    bit1: a save is not a simulation event.

**B6. Diagnostics.** `computeReport` logs nothing. Its callers decide:
- the determinism harness and 64C's runner fail on `nan_values > 0`;
- 52C's soak prints `state_nan_values=` beside `state_digest=` and fails on
  a nonzero value;
- 51's capture logs one `logging.game.warn` the first time a checkpoint
  reports NaN, through a capture-owned latch.

### Checklist

- [ ] **B1 primitives.** `simd.nanMaskFloat4` and `simd.anyTrue` (inline)
      with the scalar-parity test in `simd.zig` described in B1.
- [ ] **B1.** `StateHasher` NaN canonicalization (scan fast path + staged
      path, struct-field recursion) and `nan_count`. `state_hash.zig` uses
      only the `simd` helpers and `std.math.isNan` (no raw `@Vector`, no
      self-compare; `idiom-lint` clean). Tests in `state_hash.zig`:
  - [ ] columns `{1, NaN(0x7fc00000)}`, `{1, NaN(0xffc00000)}`, and
        `{1, 0x7f800001 sNaN}` hash equal, and `nan_count == 1` each;
  - [ ] `{-0.0}` and `{+0.0}` hash differently; `{+inf}` and `{-inf}` hash
        differently;
  - [ ] a NaN-free 1000-element `f32` column hashes equal to a raw-bytes
        `update` of the same bytes (the fast path is v1-compatible);
  - [ ] a `[4]f32` array field and an `f64` scalar follow the same rules;
  - [ ] canonicalization is independent of the NaN's position relative to the
        256-byte staging boundary (NaN at index 63, 64, and 65);
  - [ ] struct recursion: two `WorldStimulus` values whose `position.x` is
        NaN `0x7fc00000` vs `0xffc00000` hash equal with `nan_count == 1`,
        and `position.x = -0.0` vs `+0.0` hash differently.
- [ ] **B2.** `checksum_format_tag` (live + 1), `ChecksumReport`,
      `computeReport`, fixed sections, dense blocks, rounds, combine, serial
      fallback, the `checksumWorkJob` entry asserts, `buildFingerprint` +
      `app_version` option (if 52B has not added it);
      `DataSystem.hashSection(index, hasher)` + `checksum_section_count`;
      `WorldSystem.hashSection(kind, hasher)`, `denseTileBlockCount()`,
      `hashDenseTileBlock(block, hasher)`;
      `GameDemoState.simulationChecksumReport`. Tests (small fixtures; a
      1×1-chunk world plus a 3-layer world whose `dense_tile_ids.len` is not a
      multiple of the block size — set through a test-local block size
      parameter of the private `computeReportWithBlockTiles`, which production
      calls with `checksum_dense_block_tiles`):
  - [ ] serial (`null`) and threaded (`ThreadSystem`, 3 workers,
        `adaptive = false`) reports are equal on the same state;
  - [ ] changing one tile in the last partial block changes the value, and
        changing one tile in block 0 changes it;
  - [ ] the value does not depend on the number of dispatch rounds (a private
        round-size parameter of 2 versus 256 gives equal values);
  - [ ] `computeReport` is allocation-free: after warmup, install a
        `std.testing.FailingAllocator` as the `DataSystem`, `WorldSystem`,
        and pipeline allocator, then run `computeReport` with `null` **and**
        with a real 3-worker `ThreadSystem` (`adaptive = false`) on the
        3-layer fixture with a private round size of 2, so several
        multi-worker rounds dispatch. Both runs allocate zero times and
        return equal reports (no allocation path exists; the test pins it on
        the threaded path that ships, not only the inline one);
  - [ ] `buildFingerprint` changes when `checksum_format_tag` changes, tested
        through the private `fingerprintFor(version, zig_version, tag)`
        helper, and is stable across two calls.
- [ ] **B3/B4.** Class lists on `SimulationPipeline`, `SensoryBus`,
      `DigController`, `AiSystem`, and `SteeringSystem` with comptime
      completeness blocks; the `hashSimulationState` methods; the
      `"pipeline_history"` section. Tests (tiny pipeline fixture, one per
      hashed field):
  - [ ] toggling `interact_held_last`, each dig latch, and
        `player_last_cell` changes the checksum;
  - [ ] adding one deferred stimulus, adding one sticky stimulus, and
        decrementing one `sticky_remaining` each change it;
  - [ ] writing garbage past `deferred_stimulus_count`/`sticky_count` does not;
  - [ ] changing `snapped_goal` changes it; changing one `RuntimeRow` field
        (`prev_dir_x`, `stuck_steps`) changes it;
  - [ ] perturbing `perception.step_counter` or a tuner does not.
- [ ] **B3 perception cache bound (capacity audit).** The `perception` row's
      `cache` class depends on the LOS cache being output-transparent, so
      the cache's maintenance capacity lands with that classification.
      Today `LevelBlockedSlot.pending_dirty` grows by
      `ensureTotalCapacity(len + 1)` in `markLevelDirty`
      (`perception.zig:885-889`, reached from
      `reactToPostCommitPerceptionEvents` every step) and grows without
      bound on levels no observer visits.
  - `prebuildLevelCaches` (load) reserves each level slot's `pending_dirty`
    to that level's chunk count (`world.chunksX() × world.chunksY()`) and
    stores it as the slot's logical `pending_dirty_limit`. The gate reads
    the stored limit, never `pending_dirty.capacity`
    (`ensureTotalCapacity` may round up). A slot created without a prebuild
    has limit 0, so its marks go straight to the flag below; its first
    build is a full rebuild anyway.
  - `LevelBlockedSlot` gains `full_rebuild_pending: bool`. Below the limit,
    `markLevelDirty` appends with `appendAssumeCapacity`. At the limit it
    sets the flag, clears the list, and ignores later marks until the next
    build. When the flag is set, `ensureLevelBlockedCache` takes the
    existing full-rebuild branch and then clears the flag.
  - The limit is a threshold on the gated operation's own region (one
    level), not a world-wide size or a measured time. Each pending rect's
    scoped patch can walk one chunk's sparse tiles, so once the pending
    rects reach the chunk count, one full pass over the level costs no more
    than the patch.
  - The class stays `cache`: a full rebuild equals the patched bitmap.

  Tests in `perception.zig`, on a 2-chunk, 2-level world (32×16 tiles,
  chunk 16):
  - [ ] with `FailingAllocator` installed right after `prebuildLevelCaches`,
        marking 3 rects on the unobserved level allocates nothing and sets
        `full_rebuild_pending`;
  - [ ] the next observer visit runs a full rebuild, and the bitmap equals
        `levelBlocksMovement` on every cell (the existing parity helper);
  - [ ] with 1 pending rect (below the limit of 2), the scoped patch runs
        and the flag stays clear, so the existing patch-parity tests are
        unchanged.
- [ ] **B5.** `PathfindingSystem.normalize` and
      `SimulationPipeline.normalizeDerivedState`. Tests in
      `systems/pathfinding/system.zig` and `simulation_pipeline.zig`:
  - [ ] `test "normalized pathfinding equals a freshly initialized system"`:
        run 30 steps with pending requests, cached paths, a building group
        field, and a runtime ramp link processed through 64E's link cursor;
        then `normalize`. Lifecycle fields equal a fresh system's, and the nav
        graph's portal and link-edge arrays are byte-identical to a fresh
        `rebuildStaticNavGridWithWorld` over the same world;
  - [ ] `test "normalized pipelines step identically"`: two pipelines over
        identical `DataSystem`/`WorldSystem`/hashed history, one normalized
        after 30 steps and one freshly initialized from that state, produce
        equal 60-step checksum traces.
  - [ ] **B5 completeness** in `normalize`, items (b) and (c) (64E lands
        before 64B): hold one unapplied `markNavDirty` edit and one
        unprocessed runtime link before `normalize`; afterwards the three
        dirty buffers are empty and `nav_links_processed ==
        levelLinks().len`. Item (a) and its test `"normalize discards an
        in-flight deferred rebuild"` are in **Slice 65B's** Checklist; item
        (d) is in **Slice 71B.3's** Checklist (each lands with the field it
        covers and extends `"normalized pathfinding equals a freshly
        initialized system"` in that change).
  - [ ] `test "path cache state changes simulation outcomes"` (pins
        `pathfinding` in `checksum_normalized_fields`, never
        `checksum_cache_fields`):
    - build two pipelines over identical state, each holding one cached
      `available` path for one agent;
    - at step 10, clear `completed` on one of them without normalizing;
    - at step 10, steering reports `.missing` on the cleared side (a path
      request is emitted and `replan_cooldown` is set) and `.available` on
      the other, so `movement_intents` differ;
    - `normalize` both; their next 60-step traces are equal.
  - [ ] `test "solve-budget consumption depends on cache state"`:
    - set `capacity.max_solved_requests_per_step = 1` and have agents A and
      B request distinct goals in the same step;
    - with A's key warm, B solves at step s;
    - with A's key cold, A consumes the solve and B is deferred to s+1;
      `deferred_requests` and B's first `available` step differ.
- [ ] **Harness updates** (Slice 49 tests): every determinism trace helper
      uses `simulationChecksumReport` and asserts `nan_values == 0` at every
      step. Slice 49's checksum unit tests are updated for the v2 tag.
- [ ] **Bench**: `src/benchmarks/simulation_checksum.zig` gains the
      `thread-fixed-auto` case (Slice 49 measured `serial-direct` only). The
      fixture asserts (`std.debug.assert`) that serial and threaded values are
      equal on the first iteration. Both are reported at the
      `suite.eventScaleCounts` ladder.
- [ ] **Docs**: Determinism Contract — checksum v2 (sections, blocks, combine,
      NaN rule, class table, normalization); `docs/architecture.md` Gameplay
      Data (the pipeline-history classification rule for new controllers);
      `docs/development-workflow.md` (`thread-fixed-auto` case of
      `simulation-checksum`).

### Acceptance checks

- [ ] `zig build verify` passes; all Checklist tests pass in Debug and
      ReleaseFast.
- [ ] Slice 49's repeat/partition/seed traces still hold under v2 with
      `nan_values == 0`.
- [ ] An unclassified new field in `SimulationPipeline`, `SensoryBus`,
      `DigController`, `AiSystem`, or `SteeringSystem` fails compilation
      (checked with a temporary, uncommitted edit).
- [ ] Bench gate: `zig build -Doptimize=ReleaseFast bench -- --group
      simulation-checksum --details`. At 10,000 items (256×256×32 fixture),
      `thread-fixed-auto` is ≤ 1.5 ms and ≤ the `serial-direct` mean, and
      `serial-direct` stays within 10% of Slice 49's recorded v1 number
      (fast-path proof). Record the table in Status.

---

