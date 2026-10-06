## Slice 62: NPC Population, Spawning, And Spawn Tables

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 49](slice-49.md), [Slice 58](slice-58.md), [Slice 59](slice-59.md), [Slice 63](slice-63.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Depends on **49** (`spawn_seed = seed.derive(.population)`;
this slice appends `SeedDomain.population = 8`; and the sim-view band through
`SimulationPipeline.simViewRegion(context)`), **33** (archetypes), archive **24**
(tiers and halos), **58** (this slice extends 58's worldgen spec with anchor
placement and reads 58's `chunkBiome` for biome filters), **59** (time filters
read `EnvironmentSnapshot.day_phase`), **63** (`Merchant` + `SocialLedger` for the
merchant entry), and **57** (initial merchant stock). It lands last in the merged
order (after 49, 58, 59, 63). The controller core is fixture-testable with demo
anchors and `"any"` filters.

Goal: data-driven, deterministic ambient population. World-anchored spawn
points pull from spawn tables:

- Weighted tables pick archetype × faction × biome × time.
- Roster tables keep fixed counts, such as VoidLight's 1 merchant + 2 guards
  + 4 villagers.

Spawns happen only outside the sim view, inside the simulated band. Population
and work are capped by fixed constants, and ambient NPCs despawn far beyond the
dormant band with hysteresis. Merchants are an ordinary table entry with a
`persistent` despawn policy. Everything goes through deferred `create_entity` /
`destroy_entity` commands from one serial pipeline controller stage. Spawn and
despawn decisions read only committed state and Slice 49's fixed-step sim view,
never the render window.

### Current foundation (do not rebuild)

- Tier bands: `cognition/locomotion/kinematic_halo_chunks = 16/32/48`,
  `SimulationTier`, `tierForChunkDistance`, `ActiveRegion.lodDistance`
  (`src/game/simulation_scope.zig:27-29,45-80,127`).
- `tier_policy` reads Slice 49's `simViewRegion(context)`; `chunk_columns`
  comes from `chunk_derive`. `visibleChunkRegion()` (`world_system.zig:1576-1588`)
  is render-only after Slice 49 and is never read by this slice.
- Step clock: `step_count: u32` with a plain non-wrapping `+= 1`
  (`systems/simulation_scope.zig:168`). Absolute-step fields use it and inherit
  its documented horizon (about 2.27 years; Slice 59 clock role split), writing
  through Slice 56's `stepAfter` and comparing through `stepReached`.
- Deferred structure: `StructuralCommand.create_entity(EntityTemplate)` /
  `destroy_entity` (`types.zig:740-808`), all-or-fail preflight
  (`structural.zig:45-100`). Destroy-then-create slot reuse is already
  allocation-free after preflight (`data_system/system.zig` test "structural
  command preflight follows destroy then create slot reuse").
  `data_system/system.zig` has **no** public per-component row reserve.
- Contact, trigger, and intent capacity: `estimateContactCapacity(mover_count +
  obstacle_count + 1)` and the trigger estimate (`game_demo_state.zig:127-135`).
- Archetype bundles: `AiArchetypeCatalog.bundleForId`, `DemoArchetype`
  (`ai_archetypes.zig:70-105`). Demo spawn builds templates by hand
  (`game_demo_state.zig:911-944`), and there is no body or visual block in the
  archetype JSON yet.
- Fixed inline world store precedent: `InterestMarkerStore` with generational
  ids (`world_interest.zig:38-169`).
- Placement predicates: `world_gate.rectOverlapsSolidTile`
  (`systems/world_gate.zig:101`) and `NavGrid.isBlockedCell`
  (`systems/pathfinding/nav_grid.zig:221`).
- RNG: `mix64` / `boundedU32` / `uniformF32` (`src/core/rng.zig`).

### Architecture notes

**Owners / new modules**

- `src/game/spawn_anchors.zig`: `SpawnAnchorStore`, embedded in `WorldSystem`
  as `spawn_anchors` beside `interest_markers`. It is world-authored persistent
  data.
- `src/game/spawn_tables.zig`: `SpawnTableId`, `SpawnTableCatalog` (strict
  JSON → dense table), and `assets/world/spawn_tables.json`.
- `src/game/population_controller.zig`: pipeline-owned `PopulationController`.
  It is stateless across steps; its scratch is rebuilt every step.
- `src/game/data_system/spawn_origin.zig`: the `SpawnOrigin` component store.

**`SpawnAnchorStore` (fixed inline arrays, allocation-free by construction)**

`spawn_anchor_capacity = 256`. Each slot has:

- `generations` / `retired_generations: u16`;
- `level: u16`, `x, y, radius: f32`;
- `table: SpawnTableId`;
- `max_alive: u8` (≤ `max_alive_per_anchor`);
- `respawn: enum { refill, once }`;
- `spawn_interval_steps: u32` (≥ `min_spawn_interval_steps`);
- `faction_override: ?Faction`;
- runtime state that persists: `next_eligible_step: StepIndex` and
  `spawned_total: u16`.

`SpawnAnchorId{index: u16, generation: u16}` follows the `InterestMarkerId`
rules. `addAnchor` / `removeAnchor` validate finite position, radius in
`(0, 1024]`, and capacity. Worlds needing more anchors than the cap are refused
(`SpawnAnchorCapacityExceeded`), never grown.

**Slice 49 checksum classification (and the matching Slice 46 save section):**
`WorldSystem.spawn_anchors` is hashed over **live slots only**, under the same
rule as `interest_markers`. `SpawnOriginStore` is hashed. The
`PopulationController` scratch is excluded (rebuilt every step).

**Worldgen anchor placement (Slice 58 spec extension).** This slice extends
Slice 58's worldgen spec with per-biome `anchors: [{ table, density, max_alive,
respawn, interval_seconds }]`. They are emitted through 58's candidate path into
`GeneratedWorld.anchors`, then `spawn_anchors.addAnchor` at load, truncated to
`spawn_anchor_capacity` by hash rank (fixed, never world-scaled). It ships demo
anchors for non-generated worlds. Slice 58's load-time initial population
carries no `SpawnOrigin` and is never despawned by `population_update`.

**`SpawnOrigin` component** (one tag, appended after the last tag present at
landing)

`SpawnOrigin = { anchor: SpawnAnchorId, entry: u8, despawn: enum { when_far,
persistent } }` uses the full component-store pattern plus
`set_spawn_origin`. Live counts are not stored. Each step the controller
recomputes `alive[anchor][entry]` into a fixed
`[spawn_anchor_capacity][max_spawn_table_entries]u8` scratch with one pass over
the `SpawnOrigin` store. That pass is ≤ `spawn_population_cap` rows, so no
stale-count or destroyed-event attribution is needed. Stale anchor ids (removed
anchor) count toward nothing and despawn as `when_far`.

**Spawn tables (`assets/world/spawn_tables.json` → `SpawnTableCatalog`)**

```json
{ "tables": [
  { "id": "wilderness", "mode": "weighted", "entries": [
    { "archetype": "aggressive", "faction": "hostile", "weight": 3, "group": [1, 3],
      "biome": "any", "time": "any", "despawn": "when_far" } ] },
  { "id": "settlement", "mode": "roster", "entries": [
    { "archetype": "merchant", "count": 1, "despawn": "persistent",
      "merchant": { "profile": "general_goods" } },
    { "archetype": "guard", "count": 2 }, { "archetype": "villager", "count": 4 } ] } ] }
```

`SpawnTableId = enum(u8) { wilderness, settlement }` is a closed enum (Slice 33
precedent). The loader is strict:

- unknown keys, unknown archetype or faction, or a missing or duplicate table
  fail;
- weight must be `> 0` (weighted mode);
- `1 <= group_min <= group_max <= max_spawn_group` (weighted mode);
- `count` must be in `[1, max_alive_per_anchor]` (roster mode);
- entry count must be ≤ `max_spawn_table_entries`;
- `biome` is `"any"` or a Slice 58 biome id (`UnknownBiome`);
- `time` is `"any" | "dawn" | "day" | "dusk" | "night"` (Slice 59 `DayPhase`);
- `merchant.profile` resolves through Slice 63 (`UnknownMerchantProfile`);
- a referenced archetype must be spawnable (below).

The table catalog fingerprint joins Slice 46's `content_fingerprint`.

The archetype JSON gains optional `body { width, height, speed }`, `visual {
sprite, entry } | { color }`, and `steering {}` blocks. An archetype used by a
spawn table without `body` and `visual` fails load with
`ArchetypeNotSpawnable`. New archetype ids `merchant`, `guard`, and `villager`
append after `forager` and are outside the 8-slot demo cycle. Spawn builds one
`EntityTemplate`:

- the archetype bundle, plus `body`, `visual`, and `steering`;
- `world_level = anchor.level`;
- faction = `entry.faction orelse anchor.faction_override orelse archetype.faction`;
- `spawn_origin`;
- for merchant entries: 63's `merchant` + `social_ledger` and 57's initial
  stock.

**`PopulationController.update`** (serial, main thread, new last stage). It
reads the sim-view band once as `region = simViewRegion(context)` (Slice 49,
`.level = player.current_level`). **When `region` is null, the step performs no
spawns and no despawns** and counts `population_no_sim_view`.

1. Recount `alive` from the `SpawnOrigin` store into the fixed scratch and set
   `alive_total`. `queued_this_step = 0`.
2. Despawn sweep. It visits `SpawnOrigin` rows starting at
   `@intCast((@as(u64, step) * despawn_checks_per_step) % len)` for
   `despawn_checks_per_step` rows (wrapping; derived cursor, product widened to
   `u64`). A `when_far` row whose chunk `lodDistance` from `region` is greater
   than `despawn_lod_distance` emits `destroy_entity`, up to
   `despawn_destroys_per_step`.
3. Anchor evaluation. It visits anchor slots starting at
   `@intCast((@as(u64, step) * spawn_anchor_evals_per_step) % spawn_anchor_capacity)`
   for `spawn_anchor_evals_per_step` slots (wrapping, widened). An anchor
   spawns only when all of these hold:
   - the slot is live;
   - `stepReached(step, next_eligible_step)` (Slice 56 helper);
   - the `once` policy has `spawned_total == 0`;
   - the anchor chunk's `lodDistance` from `region` is in
     `[spawn_min_lod_distance, spawn_max_lod_distance]`.
4. Entry choice and group size:
   - roster: the lowest-index entry with `alive < count`; group size 1;
   - weighted: `boundedU32(spawn_seed, anchor.index, step,
     spawn_entry_salt, Σweight)` over entries passing the biome filter (Slice 58
     `chunkBiome(anchor chunk)`) and the time filter (this step's Slice 59
     `EnvironmentSnapshot.day_phase`), and only when `Σalive < max_alive`;
     group size `group_min + boundedU32(spawn_seed, anchor.index, step,
     spawn_group_salt, group_max - group_min + 1)`, then clamped to
     `max_alive - Σalive`.
   - **Cap gate:** the group proceeds only when
     `alive_total + queued_this_step + group_size <= spawn_population_cap` and
     `queued_this_step + group_size <= spawn_creates_per_step`. Otherwise it
     defers (counted as `spawn_cap_skips` or `spawn_deferred_budget`).
     `comptime assert(max_spawn_group <= spawn_creates_per_step)` guarantees
     every legal group fits an empty per-step budget, so no anchor starves.
5. Placement per member `m`, attempt `k < spawn_placement_attempts`, by an
   integer square-plus-reject sample (no trig, no `sqrt`):
   - `R = ceil(anchor.radius)` as an integer pixel radius (≤ 1024);
   - `key = anchor.index * max_spawn_group + m`;
   - `dx = boundedU32(spawn_seed, key, step, spawn_place_x_salt + k, 2R+1) - R`,
     `dy = boundedU32(spawn_seed, key, step, spawn_place_y_salt + k, 2R+1) - R`
     (computed in `i32`);
   - reject the attempt when `dx² + dy² > R²` (integer);
   - `p = anchor.pos + (dx, dy)`.

   A candidate is also rejected when any of these holds:
   - its chunk `lodDistance` from `region` is `< spawn_min_lod_distance`, so
     nothing pops in on screen;
   - `rectOverlapsSolidTile` on the level;
   - `PathfindingSystem.isWorldPointBlocked(level, p)`, a new read-only wrapper
     over `NavGrid.isBlockedCell`;
   - it overlaps a candidate already accepted this step.

   Groups are atomic: if any member exhausts its attempts, the whole group
   defers (counted as `spawn_deferred_placement`) and the anchor retries on its
   next evaluation.
6. On spawn: append the group's `create_entity` commands. **Only after that
   append succeeds** does the controller set `next_eligible_step = stepAfter(step,
   spawn_interval_steps)` (Slice 56, saturating), `spawned_total +|= 1` (saturating; refill anchors
   would otherwise overflow `u16`), and `queued_this_step += group_size` in the
   `WorldSystem` store, the controller's own write. A failed append leaves the
   anchor eligible.

**Stage placement.** New `StageId.population_update` at the end of
`stage_order`, after `tier_policy`. Spawned entities get their tier from
`tier_policy` on the next step. The contract is `reads {chunk_columns,
world_tiles, environment}`, `writes {structural_commands, spawn_anchors}`. The
new `PipelineResource.spawn_anchors` is read-modify-written by this stage only,
following `dig_world_edit`'s write-only declaration of `world_tiles`.
`chunk_columns` freshness holds because nothing between `chunk_derive` and this
stage writes `movement_positions`. The region source is Slice 49's
`simViewRegion(context)`, the same one `tier_policy` reads. It is a borrowed
context input, not a `PipelineResource`, so no `simulation_anchor` tag exists.

**Fixed budgets**

| Constant | Value | Reasoning |
| --- | --- | --- |
| `spawn_anchor_capacity` | 256 | Fixed inline world store (≈10 KB); larger worlds refused, never grown |
| `spawn_population_cap` | 512 | Ambient population ceiling, separate from battle-scale demo movers; DataSystem/pipeline/collision reserves include it |
| `max_alive_per_anchor` / `max_spawn_table_entries` / `max_spawn_group` | 16 / 16 / 4 | Bounds recount scratch (256×16 u8) and per-eval work; `max_spawn_group <= spawn_creates_per_step` (comptime assert) |
| `spawn_anchor_evals_per_step` | 8 | Full anchor sweep every 32 steps (~0.53 s) |
| `spawn_creates_per_step` | 4 | ≤240 creates/s; bounds structural commit cost |
| `despawn_checks_per_step` / `despawn_destroys_per_step` | 32 / 8 | Full 512-row sweep every 16 steps |
| `spawn_placement_attempts` | 8 | Bounded VoidLight ring search replacement; all-fail defers |
| `spawn_min_lod_distance` / `spawn_max_lod_distance` | 1 / `locomotion_halo_chunks` (32) | Never in the sim view; spawned NPCs land simulated |
| `despawn_lod_distance` | `kinematic_halo_chunks + 8` (56) | 24-chunk hysteresis gap vs spawn band; no flapping |
| `min_spawn_interval_steps` | 60 | Validation floor for anchor intervals |

**Reserves.** At state init, `DataSystem` component stores are reserved for
`spawn_population_cap` extra rows of every component a spawnable bundle can
carry, through a new `DataSystem.reserveComponentRows(mask, rows)` (none exists
in `data_system/system.zig` today; this slice adds it, with a
`FailingAllocator` test). The pipeline's `movement_body_capacity`, spatial-index,
and cognition reserves add the term `spawn_population_cap`, and so does the
demo's body count feeding contact, trigger, and intent capacity
(`game_demo_state.zig:127-135`). Structural stream headroom is
`spawn_creates_per_step + despawn_destroys_per_step`.

**Events.** None. Spawns surface as the existing `entity_created` /
`entity_destroyed` commit events. `SimulationPipelineStats` gains `spawned`,
`despawned`, `spawn_deferred_placement`, `spawn_deferred_budget`,
`spawn_cap_skips`, and `population_no_sim_view` with perf metrics.

**Determinism contract.** The inputs are:

- step, `spawn_seed = seed.derive(.population)`, and anchor slot index (never
  entity or worker order);
- committed `DataSystem` and `WorldSystem` state, plus this step's Slice 59
  environment snapshot;
- Slice 49's fixed-step sim view (`simViewRegion(context)`).

The render window never feeds spawn or despawn. Cursors are derived from the
step (widened to `u64`). The recount is a full pass. RNG keys are
`(anchor.index × max_spawn_group + member, step, salt)`. Placement is integer
only (square-plus-reject), so no libm trig affects who exists. Rejection order
is fixed. The controller runs serially; the serial == threaded check is
whole-pipeline parity with spawning enabled.

**Deferred:** a home/leash signal for spawned NPCs is Slice 71A (`resolveHome`
anchor precedence, leash, `return_home`); witness-gated or proximity-triggered spawn events (VoidLight
`NPCSpawnEvent` proximity), and multi-world anchors (the multi-world scope gap).

### Checklist

- [ ] `SpawnAnchorStore` on `WorldSystem` + `SpawnAnchorId`; add, remove, capacity, generation, and level tests; allocation-free signature test (`world_interest.zig` precedent).
- [ ] `SpawnOrigin` component (one appended tag; full store pattern + `set_spawn_origin`) and `FailingAllocator` proof.
- [ ] Slice 49 checksum classification + Slice 46 save sections: `spawn_anchors` (live slots only), `SpawnOriginStore`.
- [ ] `src/game/simulation_seed.zig`: append `SeedDomain.population = 8` (Slice 49 reserved value); `spawn_seed` derived once at pipeline init.
- [ ] Archetype JSON `body`, `visual`, and `steering` blocks with validation; append `merchant`, `guard`, and `villager` archetypes.
- [ ] `SpawnTableId` + strict `SpawnTableCatalog` loader with tests for every rejection above.
- [ ] `PopulationController` steps 1–6 (null sim view → no-op; cap gate; integer placement; counters advanced only after a successful append); `PathfindingSystem.isWorldPointBlocked`; demo anchors (one `wilderness`, one `settlement`).
- [ ] Worldgen anchor placement (Slice 58 spec extension: per-biome `anchors`, hash-rank truncation to `spawn_anchor_capacity`).
- [ ] Optionally let Slice 58's biome `spawns` reference a `SpawnTableId`, so one table authors the archetype × faction mix.
- [ ] Biome filter via Slice 58's `chunkBiome`.
- [ ] Time filter via the pipeline's current Slice 59 `EnvironmentSnapshot.day_phase`; `population_update` reads `environment`.
- [ ] Merchant roster entry spawns `Merchant` + `SocialLedger` + Slice 57 stock.
- [ ] `StageId.population_update` + `PipelineResource.spawn_anchors` + contract + `runStage` arm; stats and perf metrics. Raise `@setEvalBranchQuota` at `simulation_pipeline.zig:287` if the comptime contract walk needs it.
- [ ] `DataSystem.reserveComponentRows(mask, rows)`; spawn-population reserves at state init, including the `spawn_population_cap` term in contact, trigger, intent, `movement_body_capacity`, and spatial-index reserves; `FailingAllocator` churn proof (spawn to cap → despawn all → respawn to cap allocates nothing after the first fill reserve).
- [ ] Bench groups (one `BenchmarkGroup` per workload in `src/benchmarks/population.zig`, sizes in `defaultItemCounts`, registered in `runner.zig`):
  - `population-anchor-sweep` (256 anchors × 512 population);
  - `population-spawn-burst` (creates at the per-step budget).
- [ ] Docs:
  - `architecture.md` (anchors, `SpawnOrigin`, controller, spawn/despawn bands, Slice 58's initial population carrying no `SpawnOrigin`);
  - `simulation-tiers-and-pipeline.md` (stage, contract, LOD interplay, sim-view source).
- [ ] (added by Slice 67; if this lands after Slice 67E) New UI and event-log
  text as `StringId`s with English `StringSpec` entries in
  `src/assets/strings.zig`, value-bearing text through `strings.format`;
  67E's comptime table validation passes. Otherwise 67E migrates it. Every
  `SimulationEventPayload` arm this slice adds gets an `event_log_feed.lineFor`
  line or `=> null` (Slice 67B) in the same change.

### Acceptance checks

- [ ] An anchor inside the spawn band fills to `max_alive` across evaluations,
  respecting per-step create and interval budgets.
- [ ] An anchor in the sim view (distance 0) or beyond the band never spawns,
  and `once` anchors spawn exactly once.
- [ ] Roster mode keeps exact per-entry counts: a killed guard is replaced after
  its interval, while the merchant entry is `persistent`.
- [ ] Moving the sim view across the spawn and despawn edges never despawns and
  respawns the same anchor in a loop (hysteresis test).
- [ ] **Render-window independence:** calling `setVisibleChunksForWorldRect`
  with arbitrary rects between steps leaves the spawn and despawn command
  streams identical over N steps on a minimal fixture.
- [ ] A null sim view performs no spawns and no despawns and counts it.
- [ ] Same seed and step sequence give identical spawn entries, positions, and
  entity templates. A different seed differs.
- [ ] All-blocked placement defers deterministically with stats.
- [ ] The population cap is never exceeded, including in roster mode and at
  `alive_total = spawn_population_cap - 1` with a multi-member group pending.
- [ ] Cursor math at `step = maxInt(u32)` matches the `u64` reference with no
  overflow; `spawned_total` saturates on a refill anchor.
- [ ] Steady-state spawn and despawn churn allocates nothing (`FailingAllocator`).
- [ ] Whole-pipeline serial == threaded parity holds with spawning enabled.
- [ ] (added by Slices 68A–68C) Run the Slice 68A §3 re-baseline procedure and record
  this slice's schema rows; the movers row includes ambient NPCs.
- [ ] `zig build bench -- --group population-anchor-sweep` and `--group
  population-spawn-burst` recorded; `zig build verify` passes.

### VoidLight reference

**Port:**

- `WorldPopulation::populate` settlement roster (merchant + 2 guards + 4
  villagers) and wilderness spawning as table modes.
- `MAX_POPULATED_NPCS_PER_WORLD` / `MAX_WILDERNESS_NPCS_PER_WORLD` as fixed
  caps.
- The `used`-tile no-stacking rule, as the same-step accepted-candidate overlap
  check.
- `findInRings` / `adjustSpawnToNavigable`, as bounded seeded attempts against
  tile and nav walkability.
- `NPCSpawnEvent` respawn-when-dead, max-spawn-count (`once`), and time-of-day
  window (via Slice 59's `DayPhase`).
- `MerchantSpawnEvent` as an ordinary entry with a persistent despawn policy.

**Do not port:**

- `thread_local std::mt19937{random_device}` placement and race/class picks.
- `m_respawnTimer += 0.016f` frame-assumed timers.
- `getPlayerPosition()` screen-centre placeholder.
- String race/class/behavior overrides and `AIManager::assignBehavior` string
  dispatch.
- Full-grid `std::vector<uint8_t> used` sized to world tiles.
- Wilderness blocks iterated over the whole world (`WILDERNESS_BLOCK_TILES`
  scan).
- Event-pool tracking of spawned handles. `SpawnOrigin` recount replaces it.

