## Slice 64B: Simulation Checksum v2 — NaN-Canonical, Sectioned, Threaded, Pipeline-History Coverage

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 49](slice-49.md), [Slice 50](slice-50.md), [Slice 64A](slice-64a.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status:** not started; lands after 49/50/64A and before 46.

Goal: the checksum (1) is a pure function of IEEE-observable state, so
NaN payload and sign never cause a false cross-machine mismatch, and NaN
presence is still reported; (2) covers every piece of carried pipeline history
that changes future persistent state, with a comptime-enforced classification
of every `SimulationPipeline` field; (3) hashes the dense tile grid in
fixed-size blocks on the `ThreadSystem` with an ordered combine, so the value
is identical serial or threaded; and (4) stays an allocation-free, same-build
oracle.

### Current foundation

- Dependencies: **49** (`StateHasher`, `SimulationChecksum`, completeness
  lists, `simulation-checksum` bench), **50** (owner-thread `parallelFor`),
  **64A** (pause is simulation-invisible, so no pipeline field needs a pause
  exemption). Slice 46 consumes this slice: it saves exactly the `hashed`
  fields, never the `normalized` class, uses `normalizeDerivedState` as its
  load-parity reference, and writes `buildFingerprint()` into its header.
  Steps are Slice 49's `StepIndex` (`u64`).
- Slice 49 (spec; not yet live): `src/core/state_hash.zig` `StateHasher`
  (Wyhash seed 0, fold rules, raw-bytes floats);
  `src/game/simulation_checksum.zig` (`checksum_format_tag =
  "zl-sim-checksum-v1"`, `ChecksumInput` with `step` hashed as `u64`,
  `compute`); `DataSystem.hashSimulationState` (`data_system/checksum.zig`)
  and `WorldSystem.hashSimulationState` with comptime completeness lists;
  `GameDemoState.simulationChecksum()`; bench group `simulation-checksum`
  (256×256×32 dense tiles, `serial-direct` only).
- Live pipeline history (`simulation_pipeline.zig`; B3 classifies each):
  `interact_held_last`; `SensoryBus` deferred (cap 16) and sticky (cap 27)
  stimuli, `undefined` past their counts; `DigController` latches and
  `player_last_cell`; `AiSystem.snapped_goal*`; `SteeringSystem.runtime_rows`
  (per-entity `RuntimeRow` history outside `DataSystem`); `PathfindingSystem`
  request queues, result cache (clock-hand eviction, TTL from
  `step_counter`), O(cells) `group_fields`, and `NavGraph` (after 64E content
  equals a full rebuild; only the 64F edge-window layout depends on build
  history, and search results do not); perception's LOS cache (scoped patch
  proven equal to a full rebuild); steering obstacle and movement index
  caches; tuners, scratch, and `audio_controller`.
- Dense tiles: `WorldSystem.dense_tile_ids: std.ArrayList(TileId)`, all
  layers concatenated. No fixed layer cap exists (the GPU byte budget bounds
  it per world), so a digest slot per layer cannot be a fixed array.
- `ThreadSystem.parallelForWithOptions` with `items_per_range`,
  `adaptive = false`.

### Architecture notes

**B1. NaN canonicalization in `StateHasher` (canonicalize and count).** The
simulation never observes NaN sign or payload (IEEE compares, select-form
min/max, `floorToI4`, `floatKeyBits`), while those bits differ across
platforms and between folded and runtime NaNs. The oracle runs inside saves,
replay verification, and CI digests, so it stays total (no panic); NaN
presence is counted and failed by callers (B6).

- `f32`/`f64` (scalar, column, or `[N]f32` element) hash with every NaN
  replaced by the canonical quiet NaN (`0x7fc00000` /
  `0x7ff8000000000000`); `-0.0` and `+0.0` stay distinct; ±inf is kept.
- Struct-typed values recurse per field (and arrays of structs), applying
  the NaN rule to every float leaf (`WorldStimulus.position`/`.intensity`,
  `RuntimeRow` floats). A struct value is never hashed as one byte blob.
  Non-float leaves keep 49's fold rules.
- Vector NaN primitives go in `core/simd.zig` (the `NAN_SELF_COMPARE` lint
  exempts only that file):

  ```zig
  /// Lane mask of NaN lanes (`v != v`, the only NaN-exact IEEE compare).
  pub inline fn nanMaskFloat4(values: Float4) Mask4 { return values != values; }
  /// True when any lane of `mask` is set. Pairs with the existing `countTrue`.
  pub inline fn anyTrue(mask: Mask4) bool { return @reduce(.Or, mask); }
  ```

- Fast path: scan a column once with `simd.loadFloat4` + `nanMaskFloat4`,
  OR-accumulate, test once with `anyTrue`; scalar tail and `f64` use
  `std.math.isNan`. NaN-free columns hash with one raw `update`
  (byte-identical to v1); otherwise stage through the existing 256-byte
  stack buffer with NaN lanes replaced. `state_hash.zig` has no raw
  `@Vector` and no self-compare.
- `StateHasher.nan_count: u64` counts replaced values.

**B2. Section digests and ordered combine.**

```zig
pub const checksum_format_tag = "zl-sim-checksum-v2"; // live + 1 (v2 in the merged order)
pub const checksum_dense_block_tiles: usize = 32 * 1024;     // 64 KiB of TileId per block
pub const checksum_digest_slots: usize = 256;                // per dispatch round, 2 KiB stack
pub const checksum_parallel_min_items: usize = 8;            // fewer work items → serial
pub const ChecksumReport = struct { value: u64, nan_values: u64, fixed_sections: u32, dense_blocks: u32 };
pub fn computeReport(input: ChecksumInput, thread_system: ?*ThreadSystem) ChecksumReport;
pub fn compute(input: ChecksumInput) u64; // computeReport(input, null).value
```

- The tag is the live tag + 1 (`.claude/rules/simulation.md`); v2 if no
  hashed-state slice lands between 49 and 64B.
- `ChecksumInput` gains `pipeline: *const SimulationPipeline`.
- Fixed sections, canonical order (comptime list; each one `StateHasher`
  opened with `beginSection(name, len)`, closed with `final()`; comptime
  assert count ≤ 64):
  1. `"header"`: tag, `seed.root`, `step` (as `u64`);
  2. `"entity_slots"`: slots, `first_free_slot`, `free_slot_count`,
     `tier_counts`;
  3. one section per `DataSystem` store in declaration order
     (`checksum_store_count`; a store with its own `hashSimulationState`
     keeps it);
  4. `"world_meta"`: hashed `WorldSystem` fields except `dense_tile_ids`,
     `sparse_tiles`, `interest_markers` (plus later fields: 59
     `clock`/`level_sky_exposed`, 58 `chunk_biomes`, 62 `spawn_anchors`);
  5. `"world_sparse"`: `sparse_tiles` rows;
  6. `"world_markers"`: v1 live-slot rule plus `retired_generations`,
     `live_count`;
  7. `"pipeline_history"`: B4;
  8. `"player"`: `entity`, `current_level`.
- Dense blocks: `ceil(len / checksum_dense_block_tiles)` blocks; block `i` is
  the raw bytes of tiles `[i*B, min((i+1)*B, len))` under
  `beginSection("dense_block", i)`. Boundaries depend only on
  `dense_tile_ids.len`, so the value is independent of layer and thread
  count, with no array sized to the world.
- Combine order: `Wyhash(0)` over the tag bytes, `u64` fixed-section count,
  each fixed digest (`u64` LE), `u64` dense-block count, each block digest in
  block order; `value = final()`; `nan_values` = sum of section `nan_count`s.
- Execution: round 0 runs the fixed sections; dense blocks run in rounds of
  ≤ 256 items writing `digests[k]`/`nan_counts[k]` (stack slots, reserved
  before dispatch); the combine folds slots in index order after the join.
  Dispatch `parallelForWithOptions(round_len, &ctx, checksumWorkJob,
  .{ .items_per_range = 1, .adaptive = false })` when a `ThreadSystem` is
  given and `round_len >= checksum_parallel_min_items`, else inline in index
  order. `checksumWorkJob` opens with `assert(range.index < round_len)` and
  `assert(range.end <= round_len and round_len <= checksum_digest_slots)`
  (`round_len` captured from the dispatch). Jobs read only `*const`
  `DataSystem`, `WorldSystem`, `SimulationPipeline`. Digest slots are
  unpadded one-shot writes (`.claude/rules/threading.md`).
- Callers: owner thread only. `GameDemoState.simulationChecksum()` stays
  serial with the same value; new `simulationChecksumReport(thread_system:
  ?*ThreadSystem) ChecksumReport`. Slice 51 checkpoints, 64C's runner, 46's
  save, and 52C's `frame-battle` digest pass their `ThreadSystem`.
- Allocation: none; `computeReport` takes no allocator.
- Build fingerprint: `pub fn buildFingerprint() u32` beside the tag,
  `std.hash.Crc32` over `build_options.app_version`,
  `builtin.zig_version_string`, and `checksum_format_tag`, via private pure
  `fingerprintFor(version, zig_version, tag) u32`. If 52B has not landed,
  add the `app_version` build option (default `build.zig.zon` `.version`) to
  `buildOptions` and `benchBuildOptions`. It is the only build fingerprint;
  consumers are 64C's replay header and 46's `SaveSlotHeader`.

**B3. Field classification.** This slice adds four class lists on
`SimulationPipeline` and on each pipeline-owned subsystem whose state is
hashed (`SensoryBus`, `DigController`, `AiSystem`, `SteeringSystem`). Each
field is in exactly one list; a comptime `@typeInfo` field-name walk (as at
`simulation_pipeline.zig:288`) fails compilation for an unclassified or
doubly-classified field, so any later field must be classified to build. A
field type with no fold rule changes to a foldable type rather than gaining a
new fold rule.

| Class (list name) | Meaning | Saved by 46? |
| --- | --- | --- |
| `checksum_hashed_fields` | carried history that changes future persistent state and is not derivable from `DataSystem`/`WorldSystem`/step | yes, verbatim |
| `checksum_normalized_fields` | history-dependent derived state, rebuilt by `normalizeDerivedState` (B5); not hashed | no (rebuilt) |
| `checksum_cache_fields` | output-transparent cache: a cold rebuild gives identical outputs (each entry cites its proving test) | no |
| `checksum_excluded_fields` | config, scratch, tuners, telemetry, allocators, presentation, or derived-from-hashed state | no |

Classification at landing:

| Field | Class | Note |
| --- | --- | --- |
| `interact_held_last` | hashed | input edge latch |
| `sensory` | hashed | `deferred_stimulus_count` + live entries; `sticky_count` + live entries + `sticky_remaining[0..sticky_count]`; `config`, `hearing_stimuli_scratch` excluded |
| `dig` | hashed | three latches + `player_last_cell` (optional fold); `ramp_tile`, `tunnel_tile`, `plane_tile_changes`, `scratch_allocator`, 72's `plane_scratch_reserved`/`plane_scratch_grown` excluded |
| `ai` | hashed | `snapped_goal` (x, y), `snapped_goal_initialized`; `allocator`, `rows`, `candidates`, tuners excluded |
| `steering` | hashed | `runtime_rows` in list order, each `RuntimeRow` field folded per field (`entity` raw, `f32` NaN-canonical, `bool` fold, ints raw); scratch, `steering_movement_index*` (derived), obstacle snapshot + index (cache), tuner, 72's `static_snapshot_grown_total`/`static_snapshot_grow_warned` excluded |
| `pathfinding` | normalized | lifecycle, caches, group fields, dirty marks, 64E's `nav_links_processed`, 65B's deferred state, 71B.3's prewarm fields, nav graph. Not `cache`: cache warmth changes results (B5 tests) |
| `perception` | cache | `level_blocked`/`step_counter`, incl. each slot's `pending_dirty` and `full_rebuild_pending` (Checklist "B3 perception cache bound"); scratch; tuner; 72's `dropped_events_warned` excluded |
| `scope` | excluded | `step_count` is in `"header"`; scratch; tuners; telemetry |
| `movement`, `collision`, `collision_response`, `spatial_index`, `ai_memory`, `affect`, `destructible` | excluded | scratch + tuners (72's affect `dropped_events_warned`); `destructible` has no fields |
| `audio_controller`; `nav_cell_size`, `structural_headroom` | excluded | presentation; config |
| `movement_body_capacity`, `responder_capacity`, `perception_max_events_per_step`, `affect_max_events_per_step` | excluded | derived capacity (seam-grown, Slice 72 C3) |
| `population_capacity_grows`, `population_growth_logged`, `action_intents_dropped_step` | excluded | telemetry |
| `pathfinding.capacity.max_agent_budget` (seam-raised, 72 C3) | hashed | history-dependent ceiling that changes request intake |
| `seed`, `ai_intent_seed` (49) | excluded | `seed.root` is in `"header"`; derived |

**B4. `"pipeline_history"` section.**
`SimulationPipeline.hashSimulationState(hasher)` hashes the hashed fields in
table order, each under its own `beginSection` name (`"interact"`,
`"sensory"`, `"dig"`, `"ai"`, `"steering"`) so fields cannot alias. Cost: 43
stimuli and a few scalars plus steering rows (40 bytes each).

**B5. `normalizeDerivedState` (backs the `normalized` class).**

- `PathfindingSystem.normalize(data, world, bounds_width, bounds_height,
  cell_size, thread_system)`: clears `pending`, `prepared_requests`,
  `solve_results`, `fallback_indices`, `completed`, `unavailable`,
  `pending_keys`, `group_requests`, `group_key_map`, and the `resize_*`
  snapshots; sets every `group_fields[i].state = .empty`; zeroes
  `step_counter`, `next_group_evict`, `low_load_steps`; restores
  `effective_agent_capacity` to its `reserve` value; runs init's
  `rebuildStaticNavGridWithWorld` (cold). It covers every
  `PathfindingSystem` field:
  - (a) with 65B landed, calls `abandonDeferred()` first and asserts
    `swap_event_pending == false`;
  - (b) clears `nav_dirty_edits`, `nav_dirty_cell_spans`, `nav_dirty_levels`
    (their edits are already in the world);
  - (c) leaves `nav_links_processed == world.levelLinks().len`; the full
    build resets `nav_link_cursor_pending`/`nav_apply_degraded` and syncs
    `edge_windows_grown_reported`/`edge_repacks_reported` (64E, 64F);
  - (d) with 71B.3 landed, resets each group field to `.empty`,
    `origin = .demand`, `prewarm_source = .none`.
- `SimulationPipeline.normalizeDerivedState(data, world, thread_system)`
  calls it with the stored bounds and `nav_cell_size`; main thread, cold.
- Contract: afterwards the `normalized` fields equal a freshly `init`ed
  pipeline's over the same `DataSystem`, `WorldSystem`, and config.
- `pathfinding` is `normalized`, not `cache`, because cache warmth changes
  results: steering branches on `statusForWorld` (`.missing` emits a request
  and sets the hashed `replan_cooldown`); a `completed` hit skips `pending`,
  whose cap and the per-step solve ceiling then decide which requests are
  solved, deferred, or dropped; group-field samples short-circuit the same
  way. Hashing it instead would mean O(cells) group fields and nav internals
  at every checkpoint.
- Saves: a save omits the `normalized` fields; a load constructs a fresh
  `PathfindingSystem`, equal to a normalized one by the contract. Save
  capture does not normalize the live session, so a save is invisible to the
  continuing session (no cache clear, abandoned 65B job, or save-time nav
  rebuild). Effects:
  - the continuing session's checksum trace after a save equals a
    never-saved run's (Slice 46 addition (c) test);
  - a session loaded at step S equals the continuing session normalized at
    S; its NPCs re-request paths, so first paths land one solve later;
  - the only nav rebuild is the load's post-load
    `rebuildStaticNavGridWithWorld`, timed by Slice 46.
- `normalizeDerivedState` callers: load-parity tests, the determinism
  harness, 65B's abandon-on-normalize, and 69F's region swap (which adds
  replay `flags` bit1 `normalized_before_step` and `replayNormalize()` in its
  own change). Nothing in 64B sets bit1.

**B6. Diagnostics.** `computeReport` logs nothing. The determinism harness
and 64C's runner fail on `nan_values > 0`; 52C's soak prints
`state_nan_values=` beside `state_digest=` and fails on nonzero; 51's
capture logs one `logging.game.warn` on the first NaN checkpoint through a
capture-owned latch.

### Checklist

- [ ] **B1 primitives.** `simd.nanMaskFloat4` and `simd.anyTrue` (inline).
      Scalar-parity test in `simd.zig`: for `{1, NaN 0x7fc00000, NaN
      0xffc00000, sNaN 0x7f800001, +inf, -0}` in every lane position, lane i
      equals `std.math.isNan`, and `anyTrue` equals the OR.
- [ ] **B1.** `StateHasher` NaN canonicalization (fast + staged path, struct
      recursion) and `nan_count`; `idiom-lint` clean. Tests in
      `state_hash.zig`:
  - [ ] `{1, NaN(0x7fc00000)}`, `{1, NaN(0xffc00000)}`, `{1, sNaN
        0x7f800001}` hash equal, `nan_count == 1` each;
  - [ ] `{-0.0}` vs `{+0.0}` and `{+inf}` vs `{-inf}` hash differently;
  - [ ] a NaN-free 1000-element `f32` column equals a raw `update` of the
        same bytes;
  - [ ] a `[4]f32` field and an `f64` scalar follow the same rules;
  - [ ] NaN at index 63, 64, and 65 (staging boundary) canonicalizes;
  - [ ] two `WorldStimulus` with `position.x` NaN `0x7fc00000` vs
        `0xffc00000` hash equal (`nan_count == 1`); `-0.0` vs `+0.0` differ.
- [ ] **B2.** Tag, `ChecksumReport`, `computeReport`, sections, dense blocks,
      rounds, combine, serial fallback, `checksumWorkJob` asserts,
      `buildFingerprint` + `app_version` option (if 52B has not added it);
      `DataSystem.hashSection(index, hasher)` + `checksum_section_count`;
      `WorldSystem.hashSection(kind, hasher)`, `denseTileBlockCount()`,
      `hashDenseTileBlock(block, hasher)`;
      `GameDemoState.simulationChecksumReport`. Fixtures: a 1×1-chunk world
      and a 3-layer world whose `dense_tile_ids.len` is not a block multiple
      (private `computeReportWithBlockTiles`; production passes
      `checksum_dense_block_tiles`). Tests:
  - [ ] serial and threaded (3 workers, `adaptive = false`) reports equal;
  - [ ] one tile changed in the last partial block, or in block 0, changes
        the value;
  - [ ] private round size 2 vs 256 gives equal values;
  - [ ] `FailingAllocator` as `DataSystem`, `WorldSystem`, and pipeline
        allocator after warmup: `computeReport` with `null` and with a real
        3-worker `ThreadSystem` (round size 2, several rounds) allocates
        nothing and both reports are equal;
  - [ ] `fingerprintFor` changes with the tag and is stable across calls.
- [ ] **B3/B4.** Class lists and comptime completeness on
      `SimulationPipeline`, `SensoryBus`, `DigController`, `AiSystem`,
      `SteeringSystem`; their `hashSimulationState`; `"pipeline_history"`.
      Tests (tiny pipeline fixture):
  - [ ] toggling `interact_held_last`, each dig latch, and
        `player_last_cell` changes the checksum;
  - [ ] adding a deferred or sticky stimulus, or decrementing a
        `sticky_remaining`, changes it;
  - [ ] garbage past `deferred_stimulus_count`/`sticky_count` does not;
  - [ ] changing `snapped_goal` or a `RuntimeRow` field (`prev_dir_x`,
        `stuck_steps`) changes it;
  - [ ] perturbing `perception.step_counter` or a tuner does not.
- [ ] **B3 perception cache bound.** `LevelBlockedSlot.pending_dirty`
      grows per mark today (`markLevelDirty`, every step) without bound on
      unobserved levels. `prebuildLevelCaches` reserves each slot's
      `pending_dirty` to the level's chunk count and stores it as logical
      `pending_dirty_limit` (gate reads the limit, never `.capacity`; a slot
      without prebuild has limit 0). New `full_rebuild_pending: bool`: below
      the limit `markLevelDirty` appends with `appendAssumeCapacity`; at the
      limit it sets the flag, clears the list, and ignores marks until the
      next build, which `ensureLevelBlockedCache` runs as a full rebuild
      before clearing the flag. The limit derives from the gated region's
      cost (one level's chunks). Tests in `perception.zig` (2-chunk, 2-level,
      32×16 tiles, chunk 16):
  - [ ] `FailingAllocator` after `prebuildLevelCaches`: 3 rects on the
        unobserved level allocate nothing and set `full_rebuild_pending`;
  - [ ] the next observer visit full-rebuilds; the bitmap equals
        `levelBlocksMovement` on every cell;
  - [ ] 1 pending rect (below limit 2) runs the scoped patch; flag clear.
- [ ] **B5.** `PathfindingSystem.normalize` and
      `SimulationPipeline.normalizeDerivedState`. Tests in
      `systems/pathfinding/system.zig` and `simulation_pipeline.zig`:
  - [ ] `"normalized pathfinding equals a freshly initialized system"`: 30
        steps with pending requests, cached paths, a building group field,
        and a runtime ramp link through 64E's cursor; after `normalize`,
        every field equals a fresh system's and portal/link-edge arrays are
        byte-identical to a fresh `rebuildStaticNavGridWithWorld`;
  - [ ] `"normalized pipelines step identically"`: one pipeline normalized
        after 30 steps and one freshly initialized from that state give
        equal 60-step traces;
  - [ ] completeness (b)/(c): one unapplied `markNavDirty` edit and one
        unprocessed runtime link before `normalize`; afterwards the dirty
        buffers are empty and `nav_links_processed == levelLinks().len`.
        Items (a) and (d) land in Slices 65B and 71B.3 with their fields;
  - [ ] `"path cache state changes simulation outcomes"`: two pipelines with
        one cached `available` path; at step 10 clear `completed` on one;
        steering reports `.missing` (request + `replan_cooldown`) vs
        `.available`, so `movement_intents` differ; after `normalize` both,
        60-step traces are equal;
  - [ ] `"solve-budget consumption depends on cache state"`:
        `max_solved_requests_per_step = 1`, agents A and B request distinct
        goals in one step; A warm → B solves at s; A cold → B defers to s+1
        (`deferred_requests` and B's first `available` step differ).
- [ ] **Harness updates** (Slice 49 tests): trace helpers use
      `simulationChecksumReport` and assert `nan_values == 0` every step;
      checksum unit tests updated for the v2 tag.
- [ ] **Bench**: `simulation_checksum.zig` gains `thread-fixed-auto`; the
      fixture asserts serial == threaded on the first iteration; both run at
      the `suite.eventScaleCounts` ladder.
- [ ] **Docs**: Determinism Contract (checksum v2: sections, blocks, combine,
      NaN handling, class table, normalization); `docs/architecture.md`
      Gameplay Data (pipeline-history classification, citing the rule);
      `docs/development-workflow.md` (`thread-fixed-auto` case).
- [ ] Add the checksum field-classification rule to `.claude/rules/simulation.md` when this lands.
- [ ] Add the normalized-save rule to `.claude/rules/simulation.md` when this lands.
- [ ] Add the pathfinding normalize-completeness rule to `.claude/rules/pathfinding.md` when this lands.

### Acceptance checks

- [ ] `zig build verify` passes; all Checklist tests pass in Debug and
      ReleaseFast.
- [ ] Slice 49's repeat/partition/seed traces hold under v2 with
      `nan_values == 0`.
- [ ] An unclassified new field in `SimulationPipeline`, `SensoryBus`,
      `DigController`, `AiSystem`, or `SteeringSystem` fails compilation
      (temporary, uncommitted edit).
- [ ] Bench gate: `zig build -Doptimize=ReleaseFast bench -- --group
      simulation-checksum --details`. Across at least three sizes the cost grows
      linearly with hashed state; `thread-fixed-auto` is at or below the
      `serial-direct` mean; `serial-direct` shows no regression beyond
      run-to-run spread against Slice 49's v1 case
      (`.claude/rules/tests-benchmarks.md`). Numbers go in the commit
      message.
