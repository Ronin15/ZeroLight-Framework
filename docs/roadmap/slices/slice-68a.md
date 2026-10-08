## Slice 68A: Battle-Scale Hardening — Shared Halo Table, Action-Bus Fairness, Control Re-Baseline

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 55](slice-55.md), [Slice 56](slice-56.md) · Track: [VoidLight port](../tracks/voidlight-port.md) · [Emergent AI](../tracks/emergent-ai.md)

**Status: not started.** Hard dependencies: **Slice 55** (the `ai_decide_gather`
decide set and the `ai-idle-coast` / `ai-idle-stagger` bench fixture) and
**Slice 56** (`ai_action_select`, `ActionCandidate`, `ai_action_budget_per_step`,
`ai_actions_deferred`). Runs its own re-baseline after 56, 56B, and 57 have
landed; Slices 58, 61, 62, 68B, and 68C run the same procedure when they land
(folded into those slice files as "(added by Slices 68A–68C)" items; ledger at the
end of this section). Independent of Slice 35 (35
cuts per-row math; this slice removes per-halo-row main-thread lookups).

Goal: three battle-scale hardening items land together, each with a fixed cost
bound and a determinism proof.
1. The two serial main-thread O(halo) candidate walks in `PerceptionSystem`
   and `AiSystem` disappear. The threaded `spatial_index_build` gather emits
   one halo-aligned entity/faction/level/movement table plus a
   self-validating `ai_index → spatial row` map. Perception and AI then walk
   only their own think or decide lists in O(rows).
2. The shared action bus keeps its fixed `action_intent_live_capacity = 64` and
   `ai_action_budget_per_step = 48`. Slice 56's rotating deferral gains a
   deterministic **deferral-age priority**, so a deferred AI actor waits
   at most `ceil(q / budget)` of its qualifying steps. No cap grows with
   population.
3. The 2048-mover ReleaseSafe control table gets a written, reproducible
   re-baseline procedure (hands-off, seeded, three soaks, a fixed row schema).
   This slice executes it after its own changes.

Out of scope: per-row SIMD math (Slice 35), steering avoidance (Slice 35),
collision full-sort retune (Scaling Gaps watch row), coasting sensing (Slice
55 rejects it).

### Current foundation

- **Spatial index build** (`src/game/systems/spatial_index.zig`):
  - The threaded gather `spatialGatherJob` (`:842-859`) already walks the
    unstaggered halo on workers. It resolves
    `data.movementBodyDenseIndex(entity)` per row into padded per-range
    `RowRangeSlot` buffers (`:785-831`).
  - `mergeRowRanges` (`:621-633`) appends them serially in range order.
  - `SpatialIndexRow` (`:431-436`) is `{entity, pos_x, pos_y, cell}`.
  - `view()` (`:515-533`) exposes only `pos_x` / `pos_y`, entries, ranges,
    and the dense lookup.
  - `buildSerial` (`:578-614`) is the serial twin, and `reserve` (`:489-511`)
    sizes rows to `movement_body_capacity`.
- **Duplicate halo walks** (the cost this slice removes):
  - `PerceptionSystem.gatherPerceptionData` (`systems/perception.zig:905-978`)
    walks the halo serially on the main thread. Per halo row it calls
    `movementBodyDenseIndex`, `factionConst`, and `worldLevelConst`, then
    appends a `CandidateRow {entity, faction, level}` (`:258-262`) to
    `candidates` (`:495`). A two-pointer locates think rows (`think_k`). The
    job context reads `ConstCandidateSlice` (`:311-315`, `:710-714`).
  - `AiSystem.gatherAiData` (`systems/ai.zig:590-`) walks the same halo
    serially. Per halo row it calls `movementBodyDenseIndex` and
    `factionConst`, then appends `AiCandidateRow {entity, faction}`
    (`:209-212`, `:636-640`) to `candidates` (`:400`). It asserts
    `candidates.len == spatial.pos_x.len` (`:456`, `:545`, `:802`).
  - Both module docs call this "a deliberate duplicate gather, not shared
    code" (`ai.zig:18-23`, `spatial_index.zig:21-27`).
- **Single-resolve precedent:** `DataSystem.movementVisualDenseIndices`
  (`data_system/system.zig:561`) resolves one slot and returns two dense
  indices. Other accessors: `resolveSlotConst` (`:981`), `factionConst`
  (`:776`), `worldLevelConst` (`:742`).
- **Stage graph** (`src/game/simulation_pipeline.zig`):
  - `spatial_index_build` reads `{ai_halo_indices}` and writes
    `{spatial_index}` (`:173`).
  - `world_level` is written only by `plane_traversal` (`:219`).
  - `stageSpatialIndexBuild` is at `:1068-1080`.
- **Slice 55:** the decide set ⊆ think ⊆ halo, and the `ai-idle-coast` /
  `ai-idle-stagger` groups build the spatial index **once, outside timing**.
  Slice 55's fallback is to promote this item if its relative timing target is
  missed. This slice replaces that conditional with a committed fix and its
  own honest bench (below).
- **Slice 56 action bus:**
  - `action_intent_live_capacity = 64` (`simulation.zig:478-501`).
  - `ai_action_budget_per_step = 48`, with
    `budget = min(48, 64 - live)`.
  - Rotation starts at
    `rng.boundedU32(combat_seed, 0, step, ai_action_rotation_salt, n)` and
    unselected candidates count into `ai_actions_deferred`.
  - Player capture appends before `update`, so player intents always win the
    bus. Slice 61's `.harvest` arm and Slice 63's trade arm share the same
    budget.
- **Perf log:**
  - `runtime_perf_log.interval_ns = 60 s` (`src/app/runtime_perf_log.zig:26`).
    Metrics sum over the interval; `recordMetricMax` keeps a per-interval
    peak (`Context.recordMetricMax` `:258`, `EnabledRuntimePerfLog.recordMetricMax`
    `:348`). Both are compiled out of ReleaseFast (`:22-25`).
  - The control table and its "How to use" paragraph live in Scaling Gaps
    (**Battle-scale perf watch**).

### Architecture notes

#### 1. Shared halo table (spatial index owns it)

**Decision: per-step dense table plus a self-validating dense index, not an
incremental side table.**

- Rejected: an incremental halo table maintained across steps. Halo membership
  changes whenever the sim view crosses a chunk. `world_level` changes in
  `plane_traversal`, faction changes at structural commit, and AI-store
  swap-remove renumbers rows. Each of those would need an invalidation hook,
  and a missed hook is a silent stale read.
- The per-step spatial gather already resolves every halo row on workers.
  Extending that row costs two dense column reads per row and needs no
  invalidation.

**Data layout** (`systems/spatial_index.zig`). Both structures below are
system-owned, per-step transient scratch, never persisted.

- `SpatialIndexRow` becomes
  `{ entity: EntityId, ai_index: u32, movement_index: u32, faction: Faction, level: u16, pos_x: f32, pos_y: f32, cell: SpatialCell }`.
  It stays in the existing `std.MultiArrayList` (default layout, row per halo
  entry).
- New `ai_row_of: std.ArrayList(u32)`, an `ai dense index → spatial row` map.
  - Never cleared. Every entry is initialized to
    `invalid_spatial_row = maxInt(u32)` when the list grows.
  - It is a **named dense-index exception** to the MAL default: a sparse
    lookup keyed by AI-store dense index, not a row-per-entry store.
- `pub const invalid_spatial_row: u32 = std.math.maxInt(u32)`.

**Gather.**
- `DataSystem.haloRowLookup(id: EntityId) ?HaloRowLookup` is new in
  `data_system/system.zig`, beside `movementVisualDenseIndices`.
  - It returns `HaloRowLookup { movement_index: u32, faction: Faction, level: u16 }`.
  - It resolves the slot **once** and returns `null` when there is no movement
    body. A missing faction gives `.neutral` and a missing world level gives
    `0`, the same defaults both walks use today.
- `spatialGatherJob` and `buildSerial` call `haloRowLookup` in place of
  `movementBodyDenseIndex` and write the four new fields. `ai_index` is the
  halo list element `idx[k]`, or `k` on the full-population path.
- `mergeRowRanges` (serial, range order) gains one store per merged row:
  `ai_row_of[row.ai_index] = merged_row_index`. `buildSerial` does the same in
  its loop.
- Before the gather, `ensureAiRowMap(ai_agents.entities.len)` grows the map
  (with `invalid_spatial_row` fill) only past its high-water mark. The map is
  keyed by **AI-store dense index**, so it is sized from AI-agent capacity, not
  from the movement-body capacity that `rows` uses:
  - `SpatialIndexSystem.reserveAiRowMap(ai_capacity)` is a new method, separate
    from `reserve(capacity, geometry)` (which keeps sizing `rows` to
    `movement_body_capacity`, `simulation_pipeline.zig:665`).
  - `SimulationPipeline.reserve(frame, pop)` (`:720-723`, which today reserves
    ai / perception / ai_memory / affect but not the spatial index) gains
    `try self.spatial_index.reserveAiRowMap(pop)`. `pop` is the same AI-agent
    capacity those four reserves use. C3's `syncPopulationCapacity` re-runs
    `reserve` on growth (as it already does for 64E's `reserveNavDirty`), so
    the map follows the grown capacity.
  - After both reserves, `ensureAiRowMap` never allocates while
    `ai_agents.entities.len <= pop`. That is the same "allocation-free after
    reserve/warm-up" contract `rows` already has, and the FailingAllocator
    proof below covers it.

**View.** `SpatialIndexView` gains const columns `entities`, `ai_indices`,
`movement_indices`, `factions`, `levels`, and `ai_row_of`.

- **Freshness (doc comment on the `levels` and `factions` view fields).** Both
  columns are snapshots taken at stage 3. `levels` goes stale once
  `plane_traversal` (stage 18) writes `world_level`. Readers at stages 4–17
  (perception, ai_memory, affect, ai_decide_gather, ai_decide, steering) may
  use them. A reader at or after `plane_traversal` (Slice 56's
  `ai_action_select` and its `CombatController` arc query, Slice 71A's
  `guard_alarm`) reads `world_level` through `DataSystem`, never
  `spatial.levels`. A comptime `Derivation` entry
  (`simulation_pipeline.zig:240-250`) is **not** used: it would make every
  `spatial_index` read after `plane_traversal` a compile error, and Slice 56's
  arc query deliberately reads the stage-3 positions under its fixed 16 px
  slack. The doc comment plus the `"view levels are stage-3 snapshots"` test
  below carry the rule. Faction has no writer between structural commits, so
  `factions` stays valid for the whole step.

```zig
/// Spatial row of an AI-store dense index in THIS step's index, or null when
/// that agent is not in this step's halo or has no movement body. Self-
/// validating: a stale map entry from an earlier step fails the
/// `ai_indices[r] == ai_index` check, because each ai_index appears at most
/// once per build and is rewritten whenever it appears.
pub fn rowForAiIndex(self: SpatialIndexView, ai_index: u32) ?u32 {
    if (ai_index >= self.ai_row_of.len) return null;
    const r = self.ai_row_of[ai_index];
    if (r >= self.ai_indices.len or self.ai_indices[r] != ai_index) return null;
    return r;
}
```

**Consumers.**
- `PerceptionSystem`:
  - Delete `CandidateRow`, `appendCandidateRow`, `candidates`, and
    `ConstCandidateSlice`.
  - `gatherPerceptionData` walks only `scope_dense_indices` (the think set),
    or every AI row on the null path. Per row:
    `r = spatial.rowForAiIndex(ai) orelse continue`, which is the same skip as
    today's missing movement body.
  - Each row then takes `spatial_self_index = r`,
    `mi = spatial.movement_indices[r]`, `faction = spatial.factions[r]`, and
    `level = spatial.levels[r]`. The rest of the row gather is unchanged.
  - The job context reads candidates from the view columns.
  - `candidate_population_count = spatial.entities.len`.
- `AiSystem`:
  - Delete `AiCandidateRow`, `appendAiCandidateRow`, and `candidates`.
  - `gatherAiData` walks only `scope_dense_indices`, which after Slice 55 is
    the decide set. It uses the same `rowForAiIndex` resolve, with
    `mi = movement_indices[r]` and the faction from the view.
  - Separation and cohere stance filters read `spatial.factions`.
  - `update` signature is unchanged; it already takes `SpatialIndexView`.
- Both systems drop their halo-walk two-pointer, so their main-thread cost is
  O(think) or O(decide) dense lookups. The `candidates.len == pos_x.len`
  asserts become `spatial.entities.len == spatial.pos_x.len` inside the view
  (`std.debug.assert` in `view()`).
- `spatial_population_indices` / `candidate_dense_indices` are **deleted** from
  `PerceptionConfig` / `AiConfig` and their pipeline call sites. With the halo
  table in the view they have no reader, and a config field kept "as
  documentation" is API drift. The pairing they described is now checked where
  it can fail:
  - each processor asserts (`std.debug.assert`) that every row it resolves
    through `rowForAiIndex` satisfies `spatial.entities[r] == AiAgent.entities[ai]`;
  - each think/decide row for which `rowForAiIndex` returns null is asserted to
    lack a movement body (`data.movementBodyDenseIndex(entity) == null`),
    in Debug and ReleaseSafe. That is the only legitimate reason for a
    missing spatial row, since the pipeline builds the index from the halo,
    which contains the think set.
- Slice 56's `CombatController` target-less arc query maps a candidate row
  through `spatial.entities[r]` directly. Slice 56's text names
  `ai_halo_indices` → `AiAgent.entities`, which is wrong whenever a halo row
  lacks a movement body, because spatial rows are compacted.
- Slice 63's rewire of the perception and AI stance sites
  (`perception.zig:1326,1524`, `ai.zig:1168`) applies to the view-column reads
  at the same call sites.

**Stage contract.**
- `spatial_index_build` gains `carried = {world_level}`. It now reads the level
  column, `plane_traversal` writes it later, and no earlier stage writes it,
  so the comptime carried rules at `simulation_pipeline.zig:319-347` hold.
- Faction has no `PipelineResource`, because it is written only at structural
  commit.
- Values are identical to today's: perception and AI read level and faction
  before any same-step writer, at stages 4 and 7, and nothing writes either
  between stage 3 and stage 7.
- No new `StageId` and no `stage_order` change.

**Cost bound (fixed, world-size independent).**
- Workers: per halo row, 1 slot resolve plus 3 dense column reads (previously
  1 slot resolve).
- Main thread: one extra u32 store per merged row, inside an existing serial
  merge.
- Perception and AI: O(rows) dense lookups, down from O(halo) with about 5
  slot resolves and 2 MAL appends per halo row.
- Memory: 4 B × the AI-store high-water mark for the map, plus 11 B per
  reserved spatial row (`ai_index` 4 + `movement_index` 4 + `faction` 1 +
  `level` 2).

**Determinism.** Rows and the map come from the same range-ordered merge as
today. Serial, threaded, any worker count, and any range size give identical
columns. `rowForAiIndex` is a pure function of this step's columns: stale map
content cannot change a result.

#### 2. Action-bus capacity policy (fixed constants + deferral-age priority)

**Constants are unchanged and remain the policy.**

| Constant | Value | Rule |
| --- | --- | --- |
| `action_intent_live_capacity` | 64 | Bus ceiling. Never derived from population, faction count, or world size. |
| `ai_action_budget_per_step` | 48 | Shared by every AI action kind (56 `.attack`, 61 `.harvest`, 63 trade). Keeps at least 16 slots for the player and UI producers, which append first. |
| `ai_action_deferral_saturation` | 255 (`u8` max) | Priority counter ceiling. By the starvation bound below a key reaches 255 only when more than `48 × 255 = 12,240` candidates qualify on every step, six times the 2048-mover battle target. Decision: saturated keys tie, and the tie is broken by rotation rank, which still serves every saturated candidate in turn. Widening to `u16` would double the column for a population the bus is not designed for. |

**Algorithm.** This replaces 56's pure rotation inside `AiActionSelectSystem`
selection, on the main thread and serial.

- New persistent hot column `AiAgent.action_deferrals: u8 = 0`
  (`data_system/agents.zig` `AiAgentStore` row; `AiAgentSlice` /
  `ConstAiAgentSlice` gain the column).
  - It counts consecutive qualifying steps on which the agent was deferred.
  - Its only writer is `ai_action_select`.
- `ActionCandidate` gains `ai_index: u32` (AI-store dense index, written in
  pass 2), so selection never re-resolves an entity.
- With `n` candidates and `budget = min(ai_action_budget_per_step, 64 - live)`:
  1. If `n <= budget`, emit all of them in merged order (unchanged) and set
     every candidate's `action_deferrals = 0`.
  2. Otherwise:
     - `start = rng.boundedU32(combat_seed, 0, stepKey(step), ai_action_rotation_salt, n)` (unchanged).
     - `rank(i) = (i + n - start) % n`.
     - Key is `action_deferrals[ai_index]`.
     - Build a fixed `[256]u32` histogram of keys. Find the threshold `T` with
       `count(key > T) < budget <= count(key >= T)`.
     - Select every candidate with `key > T`, then the first
       `budget - count(key > T)` candidates with `key == T` in **rank order**.
     - Emit the selected set in rank order (deterministic; it equals 56's
       emit order whenever no candidate has a nonzero key).
     - Selected candidates get `action_deferrals = 0`; unselected ones get
       `action_deferrals +|= 1`. `ai_actions_deferred` counts as before.
- Selection scratch is a system-owned `selected: std.DynamicBitSetUnmanaged`
  sized to the candidate stream capacity in `reserve`, and the histogram is a
  `[256]u32` on the stack. Total cost is O(n + 256) with no allocation.
- **Starvation bound (tested).** Suppose `q` candidates qualify on every step
  (pinned agents, cooldown 1). Then no candidate is deferred more than
  `ceil(q / budget)` consecutive times while `q / budget <= 255`. That is
  graceful degradation under chronic over-demand: everyone attacks less often,
  nobody starves, and no cap grows.
- Candidates that qualify only on their stagger phase accumulate priority only
  on the steps they qualify. A deferred agent keeps its cooldown
  (`next_attack_step` untouched, Slice 56 acceptance), so it retries on its
  next think with a higher key.

**Stage contract.**
- New `PipelineResource.ai_action_deferrals`, written by `ai_action_select`.
- Its only reader is the next step's `ai_action_select`, through owned
  read-modify-write. That is declared as a write only, the same way
  `ai_memory_update` declares its decay of prior-step `ai_memory`.

**Persistence.**
- `AiAgentStore` is a hashed MAL, so the new column enters Slice 49's
  completeness walk automatically. Bump `checksum_format_tag` (live value + 1,
  Slice 64B's relative rule).
- Slice 46's AI-agent save section adds the field and bumps the save
  `format_version` (live value + 1; v15 in the merged order, Table T3), because Slice 46
  rejects older payload versions.
- **Slice 64B classification** (same change, B3 table): the new spatial-index
  halo columns and `ai_row_of` are `excluded` (per-step derived, rebuilt every
  step before any reader). `AiAgent.action_deferrals` is hashed through the
  `AiAgentStore` MAL.

**Diagnostics.**
- New metric `ai_action_max_deferral_streak`, recorded with
  `recordMetricMax`: the per-interval maximum key value of an unselected
  candidate.
- No per-step logging. One `logging.game` debug line at
  `SimulationPipeline.init` prints the bus constants.

#### 3. Battle-scale control re-baseline procedure

This procedure updates the rows of the Scaling Gaps control table. It runs
when a slice that adds a pipeline stage or changes the soak population lands
(56, 56B, 57, 58, 61, 62, 68A, 68B, 68C), on the reference machine. The
numbers are machine-specific trend data for locating regressions, never perf
claims or CI gates (`.claude/rules/tests-benchmarks.md`).

1. **Build:** `zig build run -Doptimize=ReleaseSafe` at the slice's final
   commit. Perf logging is enabled in ReleaseSafe.
2. **Session:**
   - The production demo, default `SimulationSeed`, and default window and
     logical size.
   - The population is `battle_scale_demo_mover_count = 2048` today, and the
     generated mix after Slice 58.
3. **Hands-off:** no keyboard or gamepad input from load completion until the
   second `perf` dump prints.
   - The simulation is seeded and input-free, so per-step populations,
     kills, and deferrals are identical across runs; only timing varies.
   - This replaces "similar play", which cannot be reproduced.
4. **Window:** use the first full 60 s dump whose `loading_build_avg_ms` is
   0, which is the second dump after start. The soak is invalid if that dump
   shows `cap_hits > 1`; rerun it.
5. **Repeat 3 times.** Each band is `[min, max]` over the three runs, rounded
   to 0.01 ms.
   - Count rows (`movers`, `cognition selected / observers`,
     `ai decide / coast_skips`, `combat kills`, `ai_actions deferred`) must
     agree within ±2% across the runs.
   - A larger spread is a determinism suspect. Route it to
     **zig-debug-specialist**; do not record it.
6. **Record:**
   - Replace the control table under a heading that names the commit, the
     machine, the date, and the slice.
   - Move the previous table, unedited, under a `History` sub-heading beside
     it.
   - Keep the "How to use" diff guidance:
     - If stage lines move while counts stay put, suspect net-new code.
     - If counts move, suspect the feature's scope density.
7. **Row schema.** Every column of the old table, plus these rows. A row is
   left as "—" only until the slice that introduces its metric lands.

   | Row | Source metric | Introduced by |
   | --- | --- | --- |
   | `spatial_index stage` | `pipeline_spatial_index` | existing (now carries the halo table) |
   | `ai_memory / affect stage` | `pipeline_ai_memory` / `pipeline_ai_affect` | existing, newly tabled |
   | `ai_decide_gather stage`, `ai decide / coast_skips (per step)` | Slice 55 | 55 |
   | `ai_action_select stage`, `combat_resolve stage` | `pipeline_ai_action_select` / `pipeline_combat_resolve` | 56 |
   | `ai_actions emitted / deferred (per step)`, `max deferral streak` | `ai_actions_emitted` / `_deferred`, `ai_action_max_deferral_streak` | 56, 68A |
   | `combat hits / kills (per 60 s)`, `movers (start-of-window / avg)` | `combat_hits` / `combat_kills`, `movement_bodies` / `fixed_updates` | 56 |
   | `projectile_update stage`, `projectiles live (avg)` | `pipeline_projectiles`, projectile store len | 56B |
   | `inventory stage`, `world items live (avg)` | `pipeline_inventory`, world-item store len | 57 |
   | `knockback stage` | `pipeline_knockback` | 68B |
   | `pending drops (peak)` | `pending_drops_peak` | 68C |
   | `kills deferred (drop capacity)` | `combat_kills_deferred_drop_capacity` | 68C |

### Checklist

- [ ] **Bench first.** Add `zig build bench -- --group halo-consumers`
      (`src/benchmarks/halo_consumers.zig`, registered in `runner.zig` after
      `scope`; `defaultItemCounts` = `suite.eventScaleCounts`). Land it in its
      own commit **before** the refactor, so a same-session pre-change
      capture exists.
      - **Fixture:** Slice 55's `ai-idle-coast` population mix and layout. The
        10% alert rows also get a real `AiPerception`
        (`vision_range = 200`, 120° FOV).
      - **Per step:**
        - Untimed: `advanceStep` + `gatherAiPopulations`.
        - Timed: `spatial_index.build` (every step, not once),
          `perception.update`, `gatherAiDecidePopulation`, `ai.update`.
      - `output_count` is the halo rows, and `candidate_pairs` is the decided
        rows.
      - Internal `std.debug.assert`s cover the halo/think/decide subsequence
        and the stream capacities.
- [ ] `DataSystem.haloRowLookup` and `HaloRowLookup` with a unit test against
      `movementBodyDenseIndex` / `factionConst` / `worldLevelConst` for rows
      with and without faction and level components, and for a dead or stale
      id.
- [ ] `SpatialIndexRow` gains `ai_index` / `movement_index` / `faction` /
      `level`. Also add `ai_row_of`, `ensureAiRowMap`, `reserveAiRowMap` and
      its call in `SimulationPipeline.reserve(frame, pop)`, the merge-time map
      store, the `SpatialIndexView` columns (with the stage-3 freshness doc
      comment on `levels` / `factions`) and `rowForAiIndex`, and
      `invalid_spatial_row`. Update the module doc so the deliberate duplicate
      gather becomes "the shared halo table".
- [ ] Delete `spatial_population_indices` / `candidate_dense_indices` from
      the perception and AI configs and their pipeline call sites; add the two
      per-row pairing asserts (entity match; null row ⇒ no movement body).
- [ ] `PerceptionSystem`: delete the candidate table; think-only gather
      through `rowForAiIndex`; view-column job context; module doc and
      `reserve` updated.
- [ ] `AiSystem`: delete the candidate table; decide-only gather through
      `rowForAiIndex`; view-column stance reads; module doc
      (`ai.zig:18-23`) and `reserve` updated.
- [ ] `CombatController` arc mapping reads `spatial.entities[r]`.
- [ ] Contract: `spatial_index_build` gains `carried = {world_level}`. Update
      the contract test at `simulation_pipeline.zig:1328`.
- [ ] Tests (minimal fixtures; the 1×1-tile pattern):
      - **View columns:** each row equals direct DataSystem lookups. A halo
        entry without a movement body is absent.
      - **Stale-map safety:** build step 1 with halo `{0..7}` and step 2 with
        halo `{4..7}`. Then `rowForAiIndex(0..3) == null` even though
        `ai_row_of` still holds step-1 rows, and `rowForAiIndex(4..7)` gives
        rows `0..3`.
      - **Swap-remove safety:** destroy an AI agent between builds. The moved
        agent's dense index resolves only if it is in the new halo.
      - **View levels are stage-3 snapshots:** a two-level pipeline fixture
        where `plane_traversal` moves one agent from level 0 to 1 in step s.
        During step s, `spatial.levels[r]` still reads 0 and
        `data.worldLevelConst` reads 1 after stage 18; at step s+1 both read 1.
      - **Map reserve:** after `SimulationPipeline.reserve(frame, pop)`,
        `ensureAiRowMap(pop)` allocates nothing (FailingAllocator,
        `fail_index = 0`).
      - **Serial == threaded:** columns and map are identical across 0, 1,
        and 2 real workers and two `items_per_range` values.
      - **Behavior:** existing perception, AI, and pipeline suites pass
        unchanged, including the Slice 47 dual-list test
        (`simulation_pipeline.zig:2582`) and the Slice 55 causal-wake and
        render-window tests.
- [ ] **FailingAllocator proofs:**
      - Spatial build after warm-up on a real 2-worker `ThreadSystem` (skip if
        no workers), and `buildSerial` after `reserve`, with system and thread
        allocators swapped to `FailingAllocator(fail_index = 0)`. Outputs are
        identical, including a step where the AI store shrank and regrew to
        its high-water mark.
      - `perception.update` and `ai.update` after `reserve`, with zero
        allocations.
- [ ] Action fairness:
      - `AiAgent.action_deferrals` column (store, slices, default 0, template
        passthrough).
      - `ActionCandidate.ai_index`.
      - The histogram threshold selection, the `selected` scratch reserved in
        `reserve`, and the deferral update.
      - `PipelineResource.ai_action_deferrals` in the `ai_action_select`
        contract.
      - The `ai_action_max_deferral_streak` metric (`recordMetricMax`) in
        `runtime_perf_log.zig`.
      - The init debug line.
- [ ] Persistence: Slice 49 completeness list (via the hashed `AiAgentStore`
      MAL), a `checksum_format_tag` bump, Slice 46's AI-agent save field, and
      a save `format_version` bump (both relative, live value + 1). Slice 64B
      B3 table rows: spatial-index halo table and `ai_row_of` `excluded`
      (per-step derived). All in the same change.
- [ ] Tests for fairness:
      - **Bound:** 100 pinned candidates qualify every step with
        `budget = 48`. Over 64 steps no candidate is deferred more than
        `ceil(100/48) = 3` consecutive times, and every candidate emits at
        least 21 times.
      - **Parity:** with all keys 0, the emitted set and order equal Slice
        56's rotation output (pin with a golden list from the same seed).
      - **Determinism:** serial (`max_worker_threads = 0`) equals threaded
        (≥ 2 ranges) for emitted intents and the resulting `action_deferrals`
        over 32 steps.
      - **Cooldown:** a deferred attacker keeps `next_attack_step`.
      - **Saturation:** a key at 255 stays 255 on deferral.
      - **FailingAllocator:** `AiActionSelectSystem.update` with a capped
        budget path, after `reserve`.
- [ ] Re-baseline procedure:
      - Rewrite the Scaling Gaps **Battle-scale perf watch** "How to use"
        paragraph to point at §3 of this section.
      - Add the empty schema rows to the control table.
      - Confirm the Scaling Gaps lines this slice promotes read "promoted into
        Slice 68A" (already done in the roadmap split).
- [ ] Docs:
      - `docs/architecture.md` scope paragraph: the shared halo table is
        owned by the spatial index, and perception and AI are O(rows).
      - `docs/simulation-tiers-and-pipeline.md`: the `spatial_index_build`
        outputs and the action-bus fairness policy.
      - `docs/development-workflow.md`: the `halo-consumers` bench example and
        the re-baseline procedure (a short pointer).
- [ ] Add the battle-scale re-baseline procedure pointer to `.claude/rules/tests-benchmarks.md` when this lands.

### Acceptance checks

- [ ] No main-thread O(halo) walk remains in `perception.zig` or `ai.zig`.
      Grep in the PR: no `candidates` table and no halo two-pointer
      (`think_k`) in either file.
- [ ] Shared-table tests, the stale-map and swap-remove tests, and
      serial == threaded across 0/1/2 workers and two range sizes all pass.
- [ ] FailingAllocator proofs pass on the serial and real multi-worker paths.
- [ ] **Bench gate**, ReleaseFast, same session, pre-change capture from the
      bench-first commit:
      - `zig build -Doptimize=ReleaseFast bench -- --group halo-consumers --items 25000 --case serial-direct`,
        then `--items 10000`, then both with
        `--case thread-adaptive-tuned-range`.
      - **Hard gate (pass/fail):** at 10k and 25k, the post-change mean is
        ≤ 0.85× the pre-change mean for `serial-direct` and ≤ 0.95× for
        `thread-adaptive-tuned-range`.
        - Basis: 3 serial halo walks become 1 worker walk plus O(decide)
          lookups, on a population where the decide set is about 7.5% of
          the halo.
        - Record the actual ratios in Status.
      - `zig build -Doptimize=ReleaseFast bench -- --group spatial_index`
        stays ≤ 1.30× its pre-change mean (two extra column reads per row on
        workers).
      - `zig build -Doptimize=ReleaseFast bench -- --group perception` and
        `--group ai` stay within the run's noise band or improve.
      - Slice 55's `ai-idle-coast` / `ai-idle-stagger` ratios are recomputed
        and recorded. If Slice 55 recorded a missed relative target, it must
        now pass.
      - `zig build -Doptimize=ReleaseFast bench -- --group ai-action-select`
        stays ≤ 1.10× pre-change.
- [ ] The fairness bound, parity, determinism, cooldown, and saturation tests
      pass.
- [ ] The re-baseline procedure is executed on the reference machine:
      - Three hands-off ReleaseSafe soaks, counts agreeing within ±2%.
      - The new control table is recorded and the old one moved to History.
      - AI and perception stage bands are recorded beside the parent commit's
        bands as diagnostic trend data (not a gate).
- [ ] `zig build check` and `zig build verify` pass.

### VoidLight reference

- **What VoidLight does.**
  - `AIManager` builds per-frame entity snapshots that each behavior re-reads.
  - `src/ai/internal/Crowd.cpp:39-99` adds a `thread_local` 64-entry
    position-keyed `SpatialQueryCache`, whose results depend on which worker
    ran a query first.
  - VoidLight has no action budget: AI attacks dispatch immediately through
    `AICommandBus` (`AttackBehavior.cpp:323-330`) in completion order.
- **Ported.** Only the idea that one per-frame entity snapshot serves several
  consumers.
- **Not ported.**
  - Thread-local or position-keyed caches, which ZeroLight's halo table
    replaces with range-ordered columns.
  - Completion-order command application.
  - Unbudgeted action dispatch. ZeroLight's bus is fixed, and degradation is
    deterministic deferral with age priority.

### Cross-slice additions from Slices 68A–68C (folded into the owning slices)

| Owner | What landed there |
| --- | --- |
| [49](slice-49.md) | `StepIndex = u64`, `stepKey`, `ChecksumInput.step: StepIndex`, replay v1 step-range refusal, TTL-clock comment (Architecture + Checklist) |
| [56](slice-56.md) | `stepAfter`/`stepReached` on `StepIndex` + boundary pipeline test; 68A §3 re-baseline soak; knockback/retaliation → 68B; drop admission phase 1b (68C); rotation start + deferral-age priority (68A); halo-table arc mapping |
| [56B](slice-56b.md) | `expire_step: StepIndex`; ammo → 68C; re-baseline acceptance |
| [57](slice-57.md) | `despawn_step: StepIndex`; carried drop via 68C FIFO; re-baseline acceptance |
| [58](slice-58.md) | 68A §3 re-baseline on the generated world |
| [61](slice-61.md), [62](slice-62.md) | `StepIndex` retypes; re-baseline acceptance; knockback note (61) |
| [51](slice-51.md), [46](slice-46.md), [59](slice-59.md) | `StepIndex` retypes and wording |
| [55](slice-55.md) | Halo-walk follow-up points to 68A |

The overview shared-contracts rows ("Shared action bus" fairness, `TransferBatch`
`consume`) and the Scaling Gaps battle-scale prose point here.
