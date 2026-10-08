## Slice 49: Session Seed And Determinism Checksum Harness

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: none · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status:** In progress: render→sim scope decoupling landed; seed, checksum,
replay, harness, bench, and docs are open.

No open prerequisite. Lands first among the new gameplay slices: it delivers
the session seed, the `SeedDomain` registry, the checksum, and the
`simViewRegion` scope band that later gameplay slices consume.
- Prerequisite for **51**: its first lane consumer streams this slice's replay
  format.
- **46** (save/load) reuses the checksum as its same-build oracle and persists
  `seed.root` (see "Slice 46 coordination").
- **52C** uses `simulationChecksum()` as its `frame-battle` digest.
- **55** and **62** read scope bands through `simViewRegion(context)`. **60**
  supplies the `sim_view` rect by changing the body of
  `GameDemoState.simViewRect()`.
- **56, 57, 58, 59, 61, 62** hold reserved `SeedDomain` values (registry
  below).
- This slice adds one field to `src/app/thread_system.zig`. **50** edits the
  same file, so whichever slice lands second rebases.

Goal: every gameplay session runs from one explicit `SimulationSeed` that the
state receives at init. Every simulation random stream derives a salted sub-seed
from that seed, apart from the named exemptions in the Determinism Contract.
`zig build test` proves, headlessly, three things about N fixed steps.
Repeat runs produce bit-identical persistent state. Worker counts, range sizes,
and inline versus threaded execution do not change it. A seed change does change
it. A versioned per-step input recording replays to the same checkpoint
checksums. Which entities participate in the simulation no longer depends on
render timing.

In scope: the seed type and its plumbing, `SimulationChecksum`, the render→sim
scope decoupling (defect 1 below), the replay format
with an in-memory recorder and a verifier, `ThreadSystemConfig.adaptive`, the
determinism tests, a checksum bench, and docs.

Out of scope, with owners:
- Live session capture to disk: Slice 51's first lane consumer.
- Headless replay runner tool: **Slice 64C**.
- Deterministic trig: **Slice 52D** (sin/cos) and **Slice 64D** (atan2).
- Random per-session seed and a New Game flow: **Slice 64C**.
- Pipeline controller state in the checksum: excluded from checksum v1 …
  covered by **Slice 64B** (checksum v2 classification). Slice 65B's
  deferred nav state is part of `PathfindingSystem`, which Slice 64B
  classifies `normalized` (never hashed, never saved).

### Current foundation

- `src/core/rng.zig:21` `mix64(seed, entity_index, step, salt)` is a stateless
  splitmix64-style mixer. Built on it: `:39` `uniformF32`, `:48` `boundedU32`,
  `:55` `unitVec2` (through `math.sinCos`). These are pure functions of their
  inputs and already partition-independent (archive Slice 27).
- The only consumer of `rng.zig` is AI wander:
  - `systems/ai.zig:293` `wander_rng_salt = 0`, `:311` `AiConfig.intent_seed`.
  - `:909` `wander_step = step / wander_resample_period_steps`.
  - `:997` `rng.unitVec2(seed, key, wander_step, wander_rng_salt)`.
  - The seed is hard-coded at `simulation_pipeline.zig:1168`
    (`.intent_seed = 0xfeedf00d`). The step comes from `:1169`
    `self.scope.currentStep()` (`systems/simulation_scope.zig:167`
    `advanceStep`, `:181` `currentStep() u32`).
- The worldgen seed is `world_system.zig:141`
  `WorldBuildConfig.seed: u64 = 0x51d1_ea5e_2026_0624`. Private `hash2`
  (`:2258`) consumes it in `addProceduralSparseTiles` (`:2122`) and in tile
  classification (`:2178-2188`).
- Session entry chain: `main_menu_state.zig:157-162` → `LoadingState.init`
  (`loading_state.zig:66`) → `loadGameDemo` (`:186`) →
  `GameDemoState.initProceduralWithRuntimeAssets` (`game_demo_state.zig:323`) →
  private `initWithWorld` (`:361`) → `SimulationPipeline.init` (`:439`).
- The only checksum-like code is a test-local precedent:
  `ai_debug_overlay.zig:671` `aiStateHash` (Wyhash over AI columns, labelled
  "not a production checksum"). No production checksum, recording, or replay
  exists.
- Fixed step: `time_loop.zig:10` `fixed_delta_seconds = 1/60`, passed at
  `engine.zig:298-307`.
- Simulation input: the sim reads gameplay input only through `InputState`
  (`input.zig:80`: `held_actions` plus the raw left stick):
  - Readers: `player.applyInput` (`player.zig:60`), `captureDigIntent` and
    `captureActionIntent` (`game_demo_state.zig:517-519`).
  - The 8 gameplay actions are the ones `isGameplayAction` accepts
    (`input.zig:188-193`).
  - `FrameCommands` (`input.zig:151`) carries pause, quit, menu, and debug
    commands. The sim never reads it.
- Deterministic output streams: `RangeOutputStream` counts per range, prefixes,
  writes, then merges in range order (`docs/simulation-tiers-and-pipeline.md`
  Range Output Streams). Design-time audit results:
  - No `@setFloatMode(.optimized)` anywhere in `src/`.
  - No wall-clock reads or atomics in `src/game` simulation paths.
- Every processor config already has `items_per_range`, `max_worker_threads`,
  and `adaptive` (for example `systems/movement.zig:19-21`, `ai.zig:304-308`).
  `ThreadSystem.selectBatchProfile` gates the tuner at `thread_system.zig:816`.
- Headless demo fixture:
  - `initDemoForTest` (`game_demo_state.zig:1191`): 8×8-tile world, 32 movers
    (`default_demo_mover_count`, `:81`), 4 obstacles.
  - `test "demo owns and completes a simulation frame during update"` (`:1676`)
    already drives the real `GameDemoState.update` with a hand-built
    `UpdateContext`.

**Determinism defects:**

1. **Render→sim coupling (fixed).** Simulation scope used to derive from the
   render visibility window, which follows the wall-clock-interpolated camera;
   it now comes from the fixed-step `sim_view` (section 3).
2. **Pause/resume mutates sim-visible state (recorded, not changed).**
   `onPause`/`onResume` call `syncInterpolatedState`
   (`game_demo_state.zig:606-619`), which runs
   `MovementSystem.syncPreviousPositions` (`systems/movement.zig:129-132`) and
   overwrites `previous_x/previous_y`. The sim reads those columns as the
   pre-step pose:
   - perception's player candidate (`simulation_pipeline.zig:1089-1092`);
   - AI `player_target` (`:1153-1154`);
   - the walk gate (`systems/world_gate.zig:65`);
   - dig facing (`dig_controller.zig:405`).

   A paused-and-resumed run therefore diverges from an unpaused run with
   identical input. This slice records pauses faithfully with a replay flag
   instead of changing AI semantics. **Slice 64A** makes pause
   simulation-invisible.

### Architecture notes

**Owners and new files**

- `src/core/rng.zig` (modify): `pub fn deriveSubSeed(root: u64, domain: u32) u64`.
- `src/core/state_hash.zig` (new; a core primitive with no game knowledge):
  `StateHasher`.
- `src/game/simulation_seed.zig` (new): `SimulationSeed`, `SeedDomain`.
- `src/game/simulation_checksum.zig` (new): `ChecksumInput`, `compute`.
- `src/game/data_system/checksum.zig` (new): the `DataSystem`
  `hashSimulationState` method, re-exported through `data_system/system.zig`.
  `WorldSystem.hashSimulationState` lives in `world_system.zig`.
- `src/game/replay.zig` (new): `ReplayInputFrame`, `ReplayRecorder`, `decode`,
  `verify`.
- Modified: `simulation_pipeline.zig`, `game_demo_state.zig`,
  `loading_state.zig`, `main_menu_state.zig`, `world_system.zig`, `input.zig`
  (exports the gameplay-action table), `app/thread_system.zig` (one field),
  `src/tests.zig`, `src/benchmarks/runner.zig`.
- Modified: each `data_system/` store file gains `pub const Row = <XRow>;`. The
  row structs are file-private today (for example `const MovementBodyRow` at
  `data_system/movement.zig:32`, and likewise in affect, agents, collision,
  destructible, faction_level, memory, perception, and visual), and
  `std.MultiArrayList(T).Elem` is private, so `data_system/checksum.zig` names
  each row type through this alias.
- No new `StageId`, no `stage_order` change, and no new `PipelineResource`. The
  sim-view rect is a borrowed `SimulationPipelineUpdateContext` input, like
  `world` and `player`, not a stage-written resource. The comptime stage graph
  does not change.

**1. `SimulationSeed`**

```zig
pub const SeedDomain = enum(u32) {
    ai_wander = 1,
    worldgen_procedural = 2,
    // Reserved, appended by their slices on landing (never placeholder tags here):
    // combat = 3 (56), loot = 4 (57), dig_yield = 5 (58), environment = 6 (59),
    // harvest = 7 (61), population = 8 (62).
};

pub const SimulationSeed = struct {
    root: u64,
    pub const default_root: u64 = 0x51d1_ea5e_2026_0624;
    pub const default: SimulationSeed = .{ .root = default_root };
    pub fn init(root: u64) SimulationSeed;
    pub fn derive(self: SimulationSeed, domain: SeedDomain) u64; // rng.deriveSubSeed(root, @backingInt(domain))
};
```

- **`default_root`** reuses the existing `WorldBuildConfig.seed` literal, so
  default sessions keep a fixed, reproducible identity. This slice adds no
  time-based seeding. A random per-session root belongs to Slice 64C, which
  chooses the root once on the main thread at session creation and records it
  in the replay header and the save.
- **`SeedDomain` tag values** are explicit and append-only: renumbering a
  domain would silently change every recorded replay and save. This slice
  lands exactly `ai_wander = 1` and `worldgen_procedural = 2`. Reserved values,
  each appended by its slice:

  | Value | Tag | Slice |
  | --- | --- | --- |
  | 3 | `combat` | 56 (56B reuses it) |
  | 4 | `loot` | 57 |
  | 5 | `dig_yield` | 58 |
  | 6 | `environment` | 59 |
  | 7 | `harvest` | 61 |
  | 8 | `population` | 62 |

  - The enum carries no placeholder tags. Value gaps are allowed; a value is
    never reused.
  - The AI wander consumer derives its seed once, at `SimulationPipeline.init`,
    as `self.seed.derive(.ai_wander)`, never per step, and mixes no raw salt
    into the root (`rng.mix64(root, 0, 0, salt)` is not a derivation).
  - Worldgen field seeds (elevation, moisture, veins, and so on) are internal
    derivations of `WorldBuildConfig.seed` (the `.worldgen_procedural` value),
    not domains.
  - Exempt from session seeding (section 2): presentation-only streams (Slice
    60 camera shake, Slice 59 weather-particle placement) and fixed load-spread
    schedule hashes (Slice 55 `decision_coast_phase_seed`).
- **`deriveSubSeed(root, domain)`** is a splitmix64 finalizer over
  `root ^ (@as(u64, domain) *% 0x9e3779b97f4a7c15)`. It is pure and documented.
  Its result depends only on `(root, domain)`, never on call order.
- **Plumbing**:
  - Add `SimulationPipelineConfig.seed: SimulationSeed = .default`.
    `SimulationPipeline` stores `seed` and `ai_intent_seed: u64`, computed once
    in `init` as `seed.derive(.ai_wander)`. `stageAiDecide` passes
    `.intent_seed = self.ai_intent_seed` in place of `0xfeedf00d`, so nothing is
    derived per step. The default keeps the existing pipeline unit tests
    compiling. Production passes the seed explicitly.
  - `GameDemoState.initWithWorld(..., session_seed: SimulationSeed)` forwards it
    to the pipeline config and logs
    `logging.game.debug("session seed root=0x{x:0>16}", ...)` once (cold).
    `initWithRuntimeAssets` and `initDemoForTest` pass `.default`.
    `initProceduralWithRuntimeAssets(..., session_seed)` forwards its argument.
  - `LoadingState` gets a `session_seed` field. `LoadingState.init(...,
    session_seed)` sets `world_build_config.seed =
    session_seed.derive(.worldgen_procedural)`, so the config it holds is the
    one actually used. `loadGameDemo` forwards `session_seed`.
    `MainMenuState` passes `SimulationSeed.default`.
  - On the session path the incoming `world_build_config.seed` is ignored, so a
    caller-supplied value would be dead. `LoadingState.init` therefore asserts
    `world_build_config.seed == (WorldBuildConfig{}).seed` (the only caller
    passes `game_demo_state.default_world_build_config`, which keeps the
    default), and its doc comment states that the session seed is the only
    worldgen seed source on this path.
  - The procedural demo world layout changes once, because its seed is now
    derived. That is accepted: no test asserts procedural layout.
  - `WorldBuildConfig.seed` stays a plain `u64` worldgen input. Benches and
    tools that build worlds directly keep their own literals. `WorldSystem`
    does not learn about sessions.

**2. Determinism contract.** The guarantee this slice's harness proves,
documented in a new `docs/simulation-tiers-and-pipeline.md` section,
"## Determinism Contract". The base guarantee and simulation inputs are in
`.claude/rules/simulation.md` § Determinism; this slice pins its scope.

- **Guarantee.** Hold these fixed:
  - the same executable: same target triple, CPU feature set, Zig/compiler-rt
    version, and the libm it resolves at runtime;
  - the same `SimulationSeed.root` and the same initial state;
  - the same per-step `InputState` sequence, including resync markers.

  Then persistent state is bit-identical after every fixed step. That holds for
  any `ThreadSystem` worker count, any `items_per_range`, any adaptive-tuner
  decision, inline or threaded execution, any render cadence, and any wall-clock
  timing.
- **Across CPU baselines.** The guarantee also holds across `-Dcpu-baseline`
  values (`native` / `ship` / `compat`) of the same target and libm. Slice 52C
  proves this. Results across OSes, libcs, or toolchains remain not guaranteed.
- **Not guaranteed: results across OSes, libcs, or toolchains.**
  - `math.sinCos` (`math.zig:144`) lowers `@sin`/`@cos` to `sinf`/`cosf`.
    Last-bit results are implementation-defined across implementations. On
    Linux/Windows these bind to Zig compiler-rt's statically linked copies, so
    one binary is stable across distros; on macOS they come from Apple
    libSystem at runtime and can vary with the OS version. Slice 52D replaces
    them with a deterministic polynomial `sinCos` (bit-identical across
    x86_64/v2/v3/apple_m1), which closes this gap for trig.
  - `@sqrt` and `+ - * /` are correctly rounded IEEE operations everywhere.
    Zig's default strict float mode forbids FMA contraction and reassociation.
    `math.atan2` is implemented in Zig.
  - Cross-machine determinism (lockstep play, shared replays) needs
    deterministic trig: **Slice 52D** (sin/cos) and **Slice 64D** (atan2).
- **Simulation inputs.**
  - Wall-clock, worker-ID, tuner, and render inputs:
    `.claude/rules/simulation.md` § Determinism.
  - SIMD and scalar-tail paths produce bit-identical per-item results. Today
    they use IEEE operations only, so they do.
  - A partition-dependent processor the harness finds is fixed in its owning
    module with a parity test (`.claude/rules/simulation.md` § Determinism);
    the harness is not weakened.
  - Every sim-affecting random stream derives from `SimulationSeed` through a
    registered `SeedDomain`. **Named exemptions** (fixed literals, not varied by
    the session seed, still deterministic):
    - presentation-only streams that never feed simulation state: Slice 60
      camera shake, Slice 59 weather-particle placement;
    - fixed load-spread schedule hashes: Slice 55 `decision_coast_phase_seed`.
  - Simulation scope comes from the fixed-step `sim_view` through
    `simViewRegion` (section 3; `.claude/rules/simulation.md` § Scope and
    tiers).

**3. Render→sim decoupling (defect 1)**

- Add `SimulationPipelineUpdateContext.sim_view: Rect` (required). It is the
  fixed-step camera rect the simulation uses for scope. Tests pass a
  full-world-extent rect; only a chunkless world yields the null-region
  full-active fallback.
- Add `pub fn chunkRegionForWorldRect(self: *const WorldSystem, rect: Rect,
  overscan_chunks: u16) ?ActiveRegion`. It is pure and returns `null` when
  `chunks.len == 0`. Factor the tile/chunk math out of
  `setVisibleChunksForWorldRect` (`:733`) into one private helper that both
  call, so render and sim cannot drift apart.
- Remove `cognitionActiveRegion`. Add
  `cognitionRegionForWorldRect(rect, overscan_chunks, halo)` in its place, so no
  sim path can reach the render window again. `visibleChunkRegion` stays,
  render-only (`render_prep.zig:401`).
- Pipeline changes:
  - `stageScopeAdvanceAndAiGather` uses
    `world.cognitionRegionForWorldRect(view, sim_view_overscan_chunks,
    cognition_halo_chunks)`.
  - `stageTierPolicy` uses `simViewRegion(context)` (below).
- `sim_view_overscan_chunks: u16 = 1` equals the demo's
  `world_render_overscan_chunks` (`game_demo_state.zig:246`), so the region
  matches today's at interpolation alpha 1 (minimal behavior change). A comptime
  assert in `game_demo_state.zig` ties the two values together.
- `GameDemoState.update` passes `.sim_view = self.simViewRect()`. That rect is
  `camera_current` × (`viewport_width`, `viewport_height`) / zoom.
  `camera_current` is the fixed-step camera that `updateCamera` computes from the
  player body at the end of the previous step, so it is deterministic. Render
  keeps calling `setVisibleChunksForWorldRect`, for draw culling only.
- **Shared scope-band helper.** Add the private helper

  ```zig
  fn simViewRegion(context: SimulationPipelineUpdateContext) ?ActiveRegion {
      var region = context.world.chunkRegionForWorldRect(
          context.sim_view,
          sim_view_overscan_chunks,
      ) orelse return null;
      region.level = context.player.current_level;
      return region;
  }
  ```

  - `stageTierPolicy` uses it; Slice 55 `ai_decide_gather` and Slice 62
    `population_update` read scope bands through it
    (`.claude/rules/simulation.md` § Scope and tiers).
  - `GameDemoState.simViewRect()` is the single sim-view source; Slice 60
    changes only its body (to `camera_rig.anchorRect()`).
  - The sim view has no anchor store and no `PipelineResource`; `sim_view` is a
    borrowed update-context input.
  - A chunkless world returns `null`, which keeps every existing null-region
    fallback (full active, no stagger filter, no coasting).
- **Migrating existing window-setting pipeline tests.** The two tests that set a
  window before `pipeline.update` use different overscans today:
  `simulation_pipeline.zig:2632` uses overscan **0** on a 1×1-tile world, and
  `:4395` (the sticky-dig linger test, which Slice 55 requires to keep passing)
  uses overscan **`cognition_halo_chunks` (16)** on the 8×8-tile
  `testMinimalMultiLevelWorld`. Passing the same rect as `.sim_view` with the
  fixed `sim_view_overscan_chunks = 1` could silently change their regions.
  For each migrated test:
  - choose a `sim_view` rect whose overscan-1 chunk region equals the old
    region, and assert the resulting `ActiveRegion` once in the test (both
    cited fixtures are a single chunk, so clamping should make the regions
    equal; the assert proves it);
  - where no rect reproduces the old region, document the region change in the
    test comment.

**4. `StateHasher` (`src/core/state_hash.zig`)**

```zig
pub const StateHasher = struct {
    inner: std.hash.Wyhash = .init(0),
    pub fn beginSection(self: *StateHasher, comptime name: []const u8, len: usize) void;
    pub fn scalar(self: *StateHasher, comptime T: type, value: T) void;
    pub fn column(self: *StateHasher, comptime T: type, values: []const T) void;
    pub fn multiArrayList(self: *StateHasher, comptime Row: type, slice: std.MultiArrayList(Row).Slice) void;
    pub fn final(self: *StateHasher) u64;
};
```

- **Hash choice.** `std.hash.Wyhash` with seed 0:
  - Its streaming result does not depend on how the input is split into calls.
  - It runs at GB/s.
  - It is what the repo's test-local precedent uses.
- **Not a persisted identifier.** Wyhash's output may change across Zig
  releases, and the checksum layout changes with `checksum_format_tag`, so this
  checksum is a same-build equality oracle only, not an identifier that
  outlives the build:
  - no consumer rejects data, or treats it as corrupt, because a checksum
    stored by a different build differs;
  - a stored copy (Slice 46's `sim_checksum`) is compared only when the stored
    `build_fingerprint` matches the running build (see "Slice 46
    coordination");
  - persisted integrity uses `std.hash.Crc32` over the payload bytes,
    separately.
- **Byte order.** Native, with
  `comptime std.debug.assert(builtin.cpu.arch.endian() == .little)`. Every
  supported target is little-endian.
- **Fold rules.** Dispatch happens at comptime on each column's element type
  `T`, and padding bytes are never hashed.
  - **Raw bytes** (one `update(std.mem.sliceAsBytes(column))` per column):
    `f32`/`f64`; integers whose bit size equals `@sizeOf * 8`; arrays and
    structs for which `std.meta.hasUniqueRepresentation` holds (for example
    `EntityId`, `[N]EntityId`); arrays of `f32`. Floats are hashed bit-exact, so
    `-0.0 != +0.0` and NaN payloads differ, because determinism means bit
    identity.
  - **Folded** through a 256-byte stack staging buffer (no allocation):
    - `bool` → `u8` 0 or 1;
    - `enum` → `@backingInt` widened to `u32`;
    - `?T` with `T` an int or enum → a presence `u8` plus the value (or 0).
  - **Anything else** →
    `@compileError("StateHasher: no fold rule for " ++ @typeName(T))`, so a
    column type outside this table fails compilation.
- **Sections.** `beginSection(name, len)` hashes the name bytes and `len` as a
  `u64`, so rows cannot alias across sections.
- **`multiArrayList`.** Iterates the `std.meta.FieldEnum(Row)` tags in
  declaration order and hashes one column per tag, using `@FieldType`. Zig's
  auto-layout reorders memory, not declaration order, so this order is stable.
- **No allocator anywhere**, so no allocation path exists.

**5. `SimulationChecksum` (`src/game/simulation_checksum.zig`)**

```zig
pub const checksum_format_tag = "zl-sim-checksum-v1";
pub const ChecksumInput = struct {
    seed: SimulationSeed,
    step: StepIndex, // u64; hashed as u64 in "header"
    data: *const DataSystem,
    world: *const WorldSystem,
    player: Player,
};
pub fn compute(input: ChecksumInput) u64;
```

The section order below is part of the checksum format; changing it bumps
`checksum_format_tag`.

1. **Section `"header"`**: `checksum_format_tag`, `seed.root`, and `step`
   (`scope.currentStep()`).
2. **`data.hashSimulationState(&hasher)`**, defined in
   `data_system/checksum.zig`:
   - section `"entity_slots"` (`len` = slot count): every `EntitySlot` field per
     slot, in declaration order, via `scalar`: `generation`, `alive`,
     `next_free`, `component_mask`, and every `?u32` dense index
     (`system.zig:1068-1088` today);
   - scalars: `first_free_slot` (`?u32`), `free_slot_count`, and `tier_counts`
     (each widened to `u64`);
   - one section per store field, in `DataSystem` declaration order
     (`system.zig:120-133`; 14 stores today, and every component slice appends
     its store). Each is hashed with
     `multiArrayList(@TypeOf(store).Row, store.rows.slice())` through the new
     `pub const Row` alias, covering every column. A store whose columns
     include allocation layout (for example Slice 57's slot-run offsets)
     provides its own `hashSimulationState` that hashes logical contents and
     lists the layout fields as excluded.
   - Completeness: a comptime block walks `DataSystem`'s field names with
     `@typeInfo`, the same Zig 0.17 introspection `simulation_pipeline.zig:288`
     uses. Each name must be in `checksum_hashed_fields` or in
     `checksum_excluded_fields = .{"allocator"}`. A new field fails compilation
     until someone classifies it.
   - **Classification.** Each `DataSystem` or `WorldSystem` field is listed
     here as hashed or excluded with a reason, and has a matching Slice 46 save
     section. A column type with no fold rule (for example `?bool`) becomes a
     foldable type (an explicit enum) rather than gaining a new fold rule.
3. **`world.hashSimulationState(&hasher)`**:
   - **Hashed**: `width`, `height`, `tile_size`, `chunk_size_tiles`,
     `level_base_z`, `level_links` (field by field), `dense_layers` (MAL rows;
     `uniform_fill_tile: ?TileId` uses the optional fold), `dense_tile_ids`,
     `sparse_tiles` (MAL rows), `dense_bands_per_level`,
     `max_dense_bands_per_level`.
   - **`interest_markers`, live slots only** (`generations[i] != 0`). Each live
     slot hashes its index, generation, kind, level, x, y, radius,
     `faction_filter_present`, and `faction_filter`. Hashing only live slots is
     required: the store's arrays are `undefined` for dead slots
     (`world_interest.zig:69-75`), so hashing whole arrays would hash garbage.
   - **`interest_markers` allocation state**, hashed whole: the
     `retired_generations` array (fixed `[interest_marker_capacity]u16`,
     always initialized, raw bytes) and `live_count` (widened to `u64`).
     `retired_generations` decides the generation of the next marker id at each
     slot (`world_interest.zig:66-68`), so two states that agree on live slots
     but differ here diverge after the next `addMarker`. Slice 46's oracle needs
     this.
   - **Excluded, with reasons**:
     - `allocator`;
     - `tileset_meta`, `owned_tileset_meta`, and `catalog_*`: load-time asset
       metadata and caches derived from it;
     - `dense_tile_data_buffer`: a renderer handle;
     - `dense_tile_edits`: the render upload queue;
     - `sparse_level_tiles` and `sparse_level_chunk_tiles`: indices derived
       from `sparse_tiles`;
     - `render_depths`, `sparse_render_order`, `sparse_depth_ranges`,
       `render_index_dirty`: render indexing;
     - `chunks`: derived geometry plus the camera `visible` flag;
     - render policy and state: all `visible_*` fields,
       `visibility_window_valid`, `last_*_chunk_*`, `visible_sparse_count`,
       `atlas_texture`, `tilemap_params`, `dense_quads_dirty`, `submitted_*`,
       `dense_window_*`, `render_window`, `max_dense_tile_gpu_bytes`.
   - The same comptime completeness check runs over `WorldSystem`'s field names.
4. **Section `"player"`**: `entity` and `current_level`.

Further notes:

- **Deliberately excluded pipeline and controller runtime state.** Divergence in
  any of these reaches persistent state within a few steps:
  - `SensoryBus` deferred and sticky stimuli; `DigController` latches;
    `interact_held_last`; `AudioController`;
  - pathfinding caches, pending requests, and group fields; steering per-agent
    caches; perception LOS caches;
  - all adaptive tuners; `SimulationFrame` streams (transient);
  - particles (effect state).

  One that becomes persistent (in 46, or the controller's own slice) joins the
  checksum under a bumped `checksum_format_tag`.
- **Cost.** Serial, on the main thread, cold paths only: tests, replay
  checkpoints (record and verify), and Slice 46's round trip. It never runs in
  the normal frame loop. The bench gate below measures it. Slice 64B hashes
  the dense grid in fixed-size threaded blocks.
- **Production entry point**: `pub fn simulationChecksum(self: *const
  GameDemoState) u64` on `GameDemoState`. Slice 51's capture and the future
  runner call it.

**6. `ThreadSystemConfig.adaptive: bool = true`**

- Setting it to `false` pins every batch to `items_per_range` × all permitted
  workers, with no tuner selection or recording. It is the system-wide form of
  the per-call fixed profile `docs/architecture.md` already documents
  ("Batches can still force explicit fixed profiles through `items_per_range`,
  `max_worker_threads`, and `adaptive = false`").
- Runtime uses: reproducible scheduling for profiling, and replay verification
  under a forced partition.
- Where it applies: in `selectBatchProfile`, `active_tuner` also requires
  `self.config.adaptive` (`:816`). In the `selected_profile` branch of
  `parallelForWithOptions`, `tuner_active` also requires it (`:861`).
- The default is unchanged, so production behavior is unchanged.
- The determinism tests need this knob. The adaptive tuner keeps every batch
  under `threaded_batch_ns = 250_000` inline (`thread_system.zig:110`), so on a
  32-mover fixture a "threaded" test would never thread.

**7. Replay (`src/game/replay.zig`)**

- **What is recorded.** One `ReplayInputFrame` per *executed* fixed step of the
  gameplay state: the sim-relevant subset of `InputState`. SDL events are not
  recorded. `FrameCommands` are not recorded either: app commands never reach
  the sim, and pause only changes whether steps run, which the presence or
  absence of frames already captures.

```zig
pub const ReplayInputFrame = extern struct {
    held_gameplay_bits: u16,
    flags: u8,
    reserved: u8, // must be 0
    stick_x_raw: i16,
    stick_y_raw: i16,
    pub fn fromInputState(input: *const InputState, resync_before_step: bool) ReplayInputFrame;
    pub fn toInputState(self: ReplayInputFrame) InputState; // setHeld + handleGamepadAxis
};
comptime { std.debug.assert(@sizeOf(ReplayInputFrame) == 8); }
```

- **`held_gameplay_bits`** uses a pinned bit order, deliberately not derived
  from the `Action` enum order, so adding actions never reshuffles the format.
  Live code has exactly 8 gameplay actions (`input.zig:188-193`), pinned as
  bits 0–7: bit0 `move_left`, 1 `move_right`, 2 `move_up`, 3 `move_down`,
  4 `dig_hole`, 5 `dig_ramp`, 6 `dig_down`, 7 `interact`.
  - The field is `u16` now, so the gameplay actions planned by later slices fit
    without a format bump. Reserved bit values, each pinned by the slice that
    adds the action: **8 `attack` (56), 9 `use_item` (57),
    10 `camera_zoom_in` (60), 11 `camera_zoom_out` (60), 12 `rest` (69C).**
  - Bits not in the pinned table are 0 (in v1 files, bits 8–15). `decode`
    rejects a set unpinned bit with `InvalidReplayFrame`. Appending a bit needs
    no version bump: an older binary rejects the newly set bit as unpinned,
    which is correct for a same-binary format.
  - `input.zig` exports `pub const gameplay_actions`, the set
    `isGameplayAction` accepts.
  - A comptime check asserts the pinned table covers exactly that set, so a new
    gameplay action fails compilation until its slice pins its bit.
  - `movementVector` is a pure function of these fields, so replay reproduces it
    exactly.
  - UI-originated `ActionIntent`s (item, quantity, price limit) are not
    `InputState` and are not in this frame. Slice 57B, their first producer,
    appends per-frame action records under the next `replay_format_version`
    (v3 in the merged order; Slice 64C takes v2).
- **`flags`**: bit0 is `resync_before_step` (defect 2; renamed
  `pause_boundary_before_step` by Slice 64A). It means `onPause` or
  `onResume` ran since the previous recorded step, and the verifier replays the
  resync before that step. Bits 1-7 are 0. Appending a flag bit needs no
  version bump, as for held bits; Slice 69F pins bit1
  `normalized_before_step` (Table T1 in the
  [VoidLight port track](../tracks/voidlight-port.md)).
- **`reserved`** must be 0; `decode` rejects anything else with
  `InvalidReplayFrame`.
- **Constants, with values and reasons**:
  - `replay_format_version: u16 = 1`, with magics `"ZLRP"`, `"ZLRC"`, `"ZLRE"`.
  - `replay_checkpoint_interval_steps: u32 = 60`: one checksum per simulated
    second. That localizes a divergence to ≤ 1 s and bounds checkpoint cost to
    1/60 of steps. It is a fixed count (`.claude/rules/budgets-capacities.md`).
  - `replay_max_frames_per_chunk: u32 = 4096`: about 68 s, or 32 KiB of frames.
    It bounds per-chunk decode and Slice 51's chunk buffer.
  - `replay_max_checkpoints_per_chunk = replay_max_frames_per_chunk /
    replay_checkpoint_interval_steps + 1`: computed at comptime, equal to 69.
  - `replay_max_total_frames: u32 = 864_000`: 4 h at 60 Hz, 6.9 MB of frames.
    It is the decoder's refusal bound, so a corrupt length field cannot request
    unbounded memory. Producers stop recording at this bound (the recorder
    refuses; Slice 51's capture seals and closes), so every file they write
    decodes.
- **Wire format.** Every field is little-endian and written one field at a
  time, not with an `@memcpy` of a struct.
  - **Header, 48 bytes**:

    | Field | Type / value |
    | --- | --- |
    | magic | `"ZLRP"` |
    | `version` | `u16` |
    | `header_bytes` | `u16`, value 48 |
    | `seed_root` | `u64` |
    | `start_step` | `u32` |
    | `fixed_delta_bits` | `u32` |
    | `sim_view_width_bits` | `u32` |
    | `sim_view_height_bits` | `u32` |
    | `checkpoint_interval` | `u32` |
    | `initial_checksum` | `u64` |
    | `reserved` | `u32`, value 0 |
  - **Chunk record (repeated)**:

    | Field | Type / value |
    | --- | --- |
    | magic | `"ZLRC"` |
    | `first_step` | `u32` |
    | `frame_count` | `u32`, `1..=4096` |
    | frames | `frame_count` × 8 bytes: `held u16`, `flags u8`, `reserved u8`, `stick_x i16`, `stick_y i16` |
    | `checkpoint_count` | `u32`, `≤ 69` |
    | checkpoints | `checkpoint_count` × (`step u32`, `checksum u64`) |
  - **End record**:

    | Field | Type |
    | --- | --- |
    | magic | `"ZLRE"` |
    | `total_frames` | `u32` |
    | `chunk_count` | `u32` |
  - The chunked form is the only form. Slice 51 streams chunks to disk as they
    fill, and the in-memory recorder emits the same records.
- **API**:

```zig
pub const ReplaySession = struct { seed_root: u64, start_step: u32, fixed_delta_bits: u32, sim_view_width_bits: u32, sim_view_height_bits: u32 };
pub const ReplayCheckpoint = struct { step: u32, checksum: u64 };
pub const ReplayRecorder = struct {
    pub fn init(allocator: std.mem.Allocator, session: ReplaySession, initial_checksum: u64, max_frames: u32) !ReplayRecorder;
    pub fn deinit(self: *ReplayRecorder) void;
    pub fn recordStep(self: *ReplayRecorder, frame: ReplayInputFrame) bool;
    pub fn checkpointDue(self: *const ReplayRecorder, step: u32) bool;
    pub fn recordCheckpoint(self: *ReplayRecorder, step: u32, checksum: u64) bool;
    pub fn encode(self: *const ReplayRecorder, writer: *std.Io.Writer) std.Io.Writer.Error!void;
};
pub const ReplayLog = struct { session: ReplaySession, initial_checksum: u64, frames: []ReplayInputFrame, checkpoints: []ReplayCheckpoint, pub fn deinit(...) void };
pub const ReplayDecodeError = error{ InvalidReplayMagic, UnsupportedReplayVersion, TruncatedReplay, ReplayTooLarge, InvalidReplayFrame, InvalidReplayCheckpoint, InvalidReplayChunk, OutOfMemory };
pub fn decode(allocator: std.mem.Allocator, reader: *std.Io.Reader) ReplayDecodeError!ReplayLog;
pub const ReplayVerifyResult = union(enum) {
    matched: struct { steps: u32 },
    session_mismatch,
    initial_state_mismatch: struct { expected: u64, actual: u64 },
    diverged: struct { step: u32, expected: u64, actual: u64 },
};
pub fn verify(stepper: anytype, log: *const ReplayLog) !ReplayVerifyResult;
```

- **`ReplayRecorder`**:
  - `init` reserves `frames` to `max_frames` (which must be
    `≤ replay_max_total_frames`) and `checkpoints` to the logical
    `checkpoint_cap = max_frames / interval + 1`, stored on the recorder.
  - `recordStep` returns `false` and latches `overflowed` once full. That is a
    deterministic refusal; the recorder never grows.
  - `recordCheckpoint` returns `bool`. It refuses (writes nothing, returns
    `false`) when `overflowed` is set or when
    `checkpoints.items.len == checkpoint_cap`. The gate is the logical cap,
    never `checkpoints.capacity` (`ensureTotalCapacity` may round up). Without
    this, a caller that keeps checkpointing after the frames overflow
    (`checkpointDue` stays true every 60 steps) would overrun the reservation.
  - `recordStep` and `recordCheckpoint` are allocation-free after `init`, proven
    by a `FailingAllocator` test that covers both the success branch and the
    refusal branch (`appendAssumeCapacity` is unchecked in ReleaseFast).
  - `checkpointDue(step)` is `(step - start_step) % interval == 0`.
- **`decode`** is strict and never returns a partial result.
  - It validates: header bytes and the zero reserved field; chunk steps
    contiguous from `start_step + 1`; reserved flag bits, the frame `reserved`
    byte, and unpinned held bits all zero; checkpoint steps
    strictly increasing, inside their chunk, and on the interval grid; end
    totals equal to the sums seen; total frames `≤ replay_max_total_frames`.
  - It is a cold path, so normal allocator use is fine.
- **`verify`** is comptime duck-typed, with no vtable.
  - The stepper provides: `replaySession() ReplaySession`,
    `replayChecksum() u64`, `replayResync() void`, and
    `replayStep(input: *const InputState) !void`.
  - Algorithm:
    1. If the session differs, return `.session_mismatch`.
    2. If `replayChecksum()` before the first step differs from
       `initial_checksum`, return `.initial_state_mismatch`.
    3. For frame `i` (step `start_step + i + 1`): call `replayResync()` when the
       flag is set, then `replayStep(&frame.toInputState())`. At each checkpoint
       step, compare checksums. The first mismatch returns `.diverged`.
    4. Otherwise return `.matched`.
  - `GameDemoState` provides `replaySession()` and `simulationChecksum()` as
    production methods. `replayStep` and `replayResync` need `UpdateContext`
    services, so the test adapter (and the future runner) implements them by
    calling `update` and `onPause`/`onResume`.

**`StepIndex`.** Slice 56 is the first slice that *stores* absolute steps, but
49, 51, 64B, 64C, 65B, 46, and 67B all land earlier in the merged order and
already carry steps. So the type and the counter land in this slice, and the
absolute-step fields of 51, 46, 56, 56B, 57, 61, 62, 65B, 67B, 71A, and 71B.3
are typed `StepIndex`. Slice 56 keeps `stepAfter` / `stepReached`, its own
fields, and the boundary pipeline test.

**Decision: `step_count` is `u64` from Slice 49.** The alternative, a `u32` with
a refusal at `maxInt(u32)`, would end a session with an error after about 2.27
years of play, propagated out of `Engine.update`, and every later slice would
keep the cursor-overflow hazard class. Slice 46's header already stores
`playtime_steps: u64`. `ChecksumInput.step` is a `StepIndex` hashed as `u64`
in the `"header"` section (checksum v1's own layout, so no tag bump). Replay
format v1 is unchanged (`start_step` / `first_step` / checkpoint `step` stay
`u32`); `ReplayRecorder.init` refuses a range past `maxInt(u32)` (Checklist).

**Slice 46 coordination (contract 46 implements).**
- Save/load uses `SimulationChecksum.compute` (through
  `GameDemoState.simulationChecksum()`) as its oracle.
- It persists `seed.root` (header field `seed_root: u64`) and
  `SimulationScopeSystem.step_count`.
- **Checksum persistence.** A save carries `sim_checksum: u64` only together
  with `build_fingerprint: u32`, a `std.hash.Crc32` over the zon
  `.version` string, `builtin.zig_version_string`, and `checksum_format_tag`
  (Slice 64B makes this `simulation_checksum.buildFingerprint()`, its single
  owner).
  Parity is checked only when the fingerprint matches the running build; a
  mismatched fingerprint skips parity (one `debug` log) and never fails the
  load. Payload integrity is a separate `std.hash.Crc32`.
- **Round-trip acceptance is an N-step trace.** Save at step S, load, run
  N = 120 steps with this slice's determinism input script, and require the
  per-step `simulationChecksum()` trace to equal the uninterrupted run's steps
  S+1…S+120. A single post-load checksum cannot catch omitted controller state.
- Each `DataSystem`/`WorldSystem` field's 46 save section pairs with its
  checksum classification (section 5).

### Checklist

- [ ] `pub const StepIndex = u64` in `src/game/simulation_scope.zig`.
      - `SimulationScopeSystem.step_count: StepIndex`
        (`systems/simulation_scope.zig:99`) and `currentStep() StepIndex`
        (`:180-182`).
      - `advanceStep` keeps a plain `+= 1` (`:168`), with a comment that
        2^64 steps at 60 Hz is about 9.7 billion years.
      - `staggerStep()` math is unchanged.
- [ ] `pub fn stepKey(step: StepIndex) u32 { return @truncate(step); }`.
      - Every `core/rng.zig` call passes `stepKey(step)`. That includes the
        `AiConfig.step` (`ai.zig:312`) feed at `simulation_pipeline.zig:1169`,
        and later 56's combat rolls and rotation, 57's loot, and 61/62's rolls.
      - `rng` signatures stay `u32` (`core/rng.zig:21,38,46`).
      - Decided: rng step keys repeat every 2^32 steps (about 2.27 years).
        That is harmless, because the step is one hash input among seed,
        entity, and salt; no schedule compares step keys.
      - Test: `stepKey(@as(StepIndex, maxInt(u32)) + 1) == 0`.
- [ ] Slice 55's `senseTick()` stays `u32 = @truncate(step_count / cognition_stagger_n)`.
      - That is exact for `decidesOnSenseTick`, because every coast interval
        is a power of two dividing 2^32.
      - Add the comptime assert
        `std.math.isPowerOfTwo(decision_coast_cycle_ticks)` if 55 has not.
- [ ] `ChecksumInput.step: StepIndex`, hashed as `u64` in the `"header"`
      section. This is checksum v1's own layout, so it needs **no**
      `checksum_format_tag` bump.
- [ ] Replay format v1 is **unchanged** (`start_step` / `first_step` /
      checkpoint `step` stay `u32`; see this slice's replay section).
      - `ReplayRecorder.init` returns `error.ReplayStepRangeExceeded` when
        `start_step + max_frames > maxInt(u32)`.
      - `GameDemoState.replaySession()` passes
        `std.math.cast(u32, currentStep())`.
      - Test the refusal at `start_step = maxInt(u32) - 10`.
- [ ] Step-derived cursors (`(step * budget) % len`, used by 61/62/71B.3) are
      computed directly in `StepIndex`. The product overflows only after
      2^64 / budget steps.
- [ ] Leave the internal wrapping TTL clocks untouched and say so in a
      comment: `PathfindingSystem.step_counter +%=`
      (`pathfinding/system.zig:860`) and `PerceptionSystem.step_counter +%=`
      (`perception.zig:735`). They are cache clocks, not absolute-step
      schedules.
- [ ] `rng.deriveSubSeed` plus tests:
  - deterministic;
  - different domains give different seeds;
  - different roots give different seeds;
  - the result differs from `root`;
  - golden value pinned for `deriveSubSeed(default_root, 1)`, so a mixer change
    is caught.
- [ ] `simulation_seed.zig` plus tests:
  - `test "seed domains keep their pinned values"`: pinned values for every
    landed tag (`ai_wander == 1`, `worldgen_procedural == 2` here; extended as
    reserved tags land);
  - `derive` is stable for a fixed root.
- [ ] Seed plumbing:
  - `SimulationPipelineConfig.seed` and `SimulationPipeline.ai_intent_seed`
    replace `0xfeedf00d` at `simulation_pipeline.zig:1168`;
  - `GameDemoState.initWithWorld`, `initProceduralWithRuntimeAssets`,
    `LoadingState`, and `MainMenuState` updated;
  - `LoadingState.init` derives `world_build_config.seed` and asserts the
    incoming seed is the default;
  - existing loading and demo tests compile and pass.
- [x] Render→sim decoupling: `chunkRegionForWorldRect` /
  `cognitionRegionForWorldRect`, required `sim_view`, `simViewRegion`, migrated
  window tests, and the render-window independence test.
- [ ] `src/core/state_hash.zig` plus tests:
  - swapping two rows changes the hash;
  - moving a row between sections changes it;
  - bool, enum, and optional folds are deterministic;
  - a hash built in one `update` equals one built in chunked updates;
  - registered in `src/tests.zig`.
- [ ] `pub const Row` alias on every `data_system/` store.
- [ ] `DataSystem.hashSimulationState` and `WorldSystem.hashSimulationState`,
  with comptime completeness blocks, plus tests:
  - create/destroy changes the checksum;
  - mutating one column of each store changes it (one tiny fixture, looped over
    the stores);
  - a dig tile change changes it;
  - `setVisibleChunksForWorldRect` does not;
  - adding or removing an interest marker changes it;
  - writing different values into dead marker slots does not;
  - an add/remove marker cycle that leaves the live slots equal but advances
    `retired_generations` changes it.
- [ ] `simulation_checksum.zig` and `GameDemoState.simulationChecksum` /
  `replaySession`, plus `test "pause resync changes the simulation checksum"`
  (proves the replay flag is load-bearing).
- [ ] `ThreadSystemConfig.adaptive`, plus `test "non-adaptive thread system pins
  batches to the configured range size and workers"`. The test asserts the
  resolved `BatchStats` shape and that the tuner report is untouched.
- [ ] `replay.zig`: frame, recorder, `encode`, `decode`, `verify`. Tests:
  - the pinned bit-order table;
  - `fromInputState`/`toInputState` round trip, including stick values;
  - encode→decode round trip;
  - each decode error: bad magic; an unsupported version
    (`replay_format_version + 1`); truncation mid-chunk;
    `frame_count` of 0 or > 4096; a reserved flag bit; a non-zero frame
    `reserved` byte; a held bit outside the pinned table (bit 8 in v1); a
    checkpoint out of order; a chunk step gap; an end-total mismatch; total
    frames over the max. Each returns its specific error with no partial
    result;
  - `FailingAllocator` proof for `recordStep` and `recordCheckpoint` after
    `init`: record and checkpoint successfully (success branch), fill to
    `max_frames`, then call `recordStep` and `recordCheckpoint` again; both
    return `false`, write nothing, and allocate nothing.
- [ ] Determinism harness in `game_demo_state.zig`. Tests live there because
  they need private `initWithWorld`. Test-local pieces:
  - `initDemoForDeterminismTest(allocator, seed, participant_count)`. Pathfinding
    A* scratch slots must cover the threaded participants; `initDemoForTest`
    sizes only 1 (`:1205`).
  - A stepper adapter that owns `ThreadSystem`, `AudioCommandBuffer`,
    `StateTransitions`, and `RuntimeAssets`.
  - `determinism_test_steps = 120`.
  - A pinned input script:

    | Steps | Input |
    | --- | --- |
    | 0–29 | `move_right` |
    | 30 | `dig_hole` |
    | 31–59 | `move_down`, stick (20000, -8000) |
    | 60 | `interact` |
    | 61–89 | `move_left`, plus `dig_ramp` at step 75 |
    | 90–119 | idle |

  Tests:
  - [ ] `test "simulation checksum trace is identical across repeat runs"`: two
    serial runs.
  - [ ] `test "simulation checksum trace is identical across worker counts and
    range splits"`: four `ThreadSystemConfig`s must produce equal per-step
    traces, and the helper reports the first divergent step on failure. Skipped
    when `builtin.single_threaded`.

    | Config | `max_worker_threads` | `items_per_range` | `adaptive` |
    | --- | --- | --- | --- |
    | A | 0 | default | default |
    | B | 1 | 16 | false |
    | C | 3 | 1 | false |
    | D | 3 | 64 | true |
  - [ ] `test "simulation checksum trace changes with the session seed"`:
    `.default` versus `default_root ^ 1` give different final checksums.
  - [ ] `test "replay recorded from a run verifies against a fresh run"`: record
    120 steps with an `onPause`/`onResume` pair between steps 99 and 100
    (resync flag set). Encode via `std.Io.Writer.Allocating`, decode via
    `std.Io.Reader.fixed`, and verify on a fresh demo under config C. Expect
    `.matched{ .steps = 120 }`.
  - [ ] `test "replay verification reports the first divergent checkpoint"`:
    flip one frame's held bits at step 70. Expect `.diverged` at the step-120
    checkpoint.
  - [ ] `test "replay verification rejects a session mismatch"`.
- [ ] Bench `src/benchmarks/simulation_checksum.zig`, group
  `simulation-checksum`, registered in `runner.zig`:
  - Fixture: tileset metadata loaded the way `render_game_prep.zig:553` loads
    it. The world comes from `WorldSystem.initProceduralFromMeta` with
    256×256 tiles and chunk 16, then `addUndergroundLevelStack(&meta, 31)` for
    32 dense layers (4 MiB of tile IDs). The `DataSystem` has `items` movement
    bodies with collision and facing; every 4th body also gets the AI cognition
    bundle (agent, perception, memory, affect).
  - Measured case: only `serial-direct`. The other default cases report
    `skipped`, because the checksum is serial.
  - Item ladder: `suite.eventScaleCounts`.
- [ ] Docs:
  - `docs/simulation-tiers-and-pipeline.md`: "## Determinism Contract"
    (guarantee, cross-baseline extension, caveat, the `SeedDomain` registry
    and named exemptions, checksum scope, exclusions, field classification,
    same-build-only checksum comparison, replay frame semantics and pinned
    bits, the sim view and `simViewRegion`), citing the
    `.claude/rules/simulation.md` rules rather than restating them.
  - `docs/architecture.md`:
    - Gameplay Data: seed ownership, checksum and replay owners,
      `core/state_hash.zig`;
    - Thread System: `ThreadSystemConfig.adaptive`;
    - Coordination Boundaries: the sim scope comes from the fixed-step camera,
      never from the render window.
  - `docs/development-workflow.md` Testing: name the determinism harness tests
    and the `simulation-checksum` bench.
- [ ] Add the determinism contract rule to `.claude/rules/simulation.md` when this lands.
- [ ] Add the seed domain registry rule to `.claude/rules/simulation.md` when this lands.
- [ ] Add the SIMD/scalar bit-identity rule to `.claude/rules/memory-performance.md` when this lands.
- [ ] Add the checksum field classification rule to `.claude/rules/simulation.md` when this lands.
- [ ] Add the checksum persistence rule to `.claude/rules/simulation.md` when this lands.
- [ ] Add the replay pinned-bit rule to `.claude/rules/simulation.md` when this lands.
- [ ] Add the wire-format rule to `.claude/rules/simulation.md` when this lands.
- [ ] Add the `StepIndex` rule to `.claude/rules/simulation.md` when this lands.

### Acceptance checks

- [ ] Every Checklist test exists and passes under `zig build test`.
- [ ] Repeat, partition, and seed results hold:
  - configs A–D produce identical 120-step traces;
  - two serial runs produce identical traces;
  - a different seed produces a different final checksum;
  - if any partition-dependent processor was found, it is fixed in its owning
    module with its own parity test, and the harness is not weakened.
- [ ] The replay round trip verifies, and divergence/session errors are
  reported as specified. `decode` rejects every malformed case with no partial
  result.
- [ ] The render-window independence test passes. No simulation path references
  `visibleChunkRegion` (grep in the PR), and every scope-band read in the
  pipeline goes through `simViewRegion` or `cognitionRegionForWorldRect`.
- [ ] `FailingAllocator` proofs pass for `ReplayRecorder.recordStep` and
  `recordCheckpoint`, including the post-overflow refusal.
  `SimulationChecksum.compute` takes no allocator.
- [ ] Bench gate: `zig build -Doptimize=ReleaseFast bench -- --group
  simulation-checksum --details` runs and shows the checksum's scaling shape
  across the item ladder (`.claude/rules/tests-benchmarks.md`); report it in
  the landing commit. Slice 64B's gate supersedes this one.
- [ ] Docs updated as listed. `zig build verify` passes.

### VoidLight reference

- **Port.** Nothing structural: VoidLight has no session seed, state checksum,
  or replay. A grep of `include/managers/SaveGameManager.hpp` and
  `WorldManager.hpp` finds no seed or checksum. The harness is ZeroLight-native.
- **Do not port.** `src/ai/behaviors/WanderBehavior.cpp:15`
  `thread_local std::mt19937 s_rng{std::random_device{}()};` is a stateful
  per-thread generator seeded from hardware entropy. Its results depend on which
  worker runs an entity and change on every launch. ZeroLight's stateless keyed
  `rng.mix64`, plus session sub-seeds, replaces it
  (`.claude/rules/simulation.md` § Controllers and processors).

---

