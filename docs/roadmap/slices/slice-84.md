## Slice 84: Level-Aware Shared Neighbor Index

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 83](slice-83.md) (layout) · Before: [Slice 86](slice-86.md), [Slice 85](slice-85.md), [Slice 75](slice-75.md) · Track: standalone (engine core; [Engine-Core Overhaul](../../framework-implementation-slices.md#engine-core-overhaul))

**Status: not started.** First feature slice on the core branch; 85 moves
steering onto its index.

Goal: one neighbor index per world per step, built once on workers and
shared by every neighbor query (separation, cohesion, perception, and, after
85, steering). It answers per level, so nothing senses, separates, or
coheres across levels through rock. An observer finds a hostile in range
however many allies or other-level rows surround it, at a per-observer cost
that does not grow with them.

### Current foundation

- `SpatialIndexSystem` (`src/game/systems/spatial_index.zig`): a row holds
  entity, position, and cell, no level (`:434`). The halo's cell-major sort
  runs serially on main (`buildEntriesAndRanges`, `std.mem.sort` at `:740`).
  `DenseCellLookup` (`:141`) is a halo-derived dense window; Slice 72 lists its
  silent clamp of a wider populated box.
- AI separation and cohesion visits (`src/game/systems/ai.zig:1100`, `:1149`)
  take every row the query returns, with no level filter.
- Perception (`src/game/systems/perception.zig`): the 64-check budget per
  observer (`:134`) counts every row the walk visits, allies and other levels
  included. Hostiles fill a 16-entry scratch (`:124`), and the walk stops when
  it is full (`:846`), before the same-level check (`:1114`).
- Steering sorts the same positions again in its private grid (Slice 85).
- Measured (Debug, 23 workers, `5d5a089`):
  - `perception-crowd` `allies`: 0/1024 observers find the hostile behind 256
    allies (64 checks each); 1024/1024 at 16 and 64 allies.
  - `perception-crowd` `levels`: 0/1024 find the same-level hostile at L 32.
    Per observer, 1, 7, and 16 rows on other levels are sensed at L 2, 8, 32
    (pass: 0). Tuned time goes 1.22 → 7.40 ms as L goes 2 → 32.
  - `production-step` tuned: spatial index 8.15 ms on main of a 38.8 ms step
    (148 µs off main) at crowd P 16,384; 0.67 ms at spread P 16,384, never
    threaded (0/10 steps).
  - `spatial_index` tuned at 10,000 rows: 4.12 ms, 95% of it on main, 1.04×
    serial.

### Architecture notes

- A neighbor result is stored at the unit it covers and shared by every
  requester (`.claude/rules/engine-design.md` § Cost model), built once per
  step. Its order follows its hot queries' filter keys
  (`.claude/rules/memory-performance.md` § Dense SoA storage), so an observer
  never pays for allies or other-level rows to reach a hostile.
- Neighbor queries use the shared index (`.claude/rules/simulation.md`). The
  build sorts, which is per-item work that grows, so it threads with a serial
  path and bitwise parity (`.claude/rules/threading.md`). Steering's banded
  grid build (`steering/agent_grid.zig:62`) is the proven threaded pattern.
- Per-query budgets stay fixed counts (`.claude/rules/budgets-capacities.md`).
- 75 owns indexing the whole population in every band; this index takes any
  population 75 hands it at the same per-row cost.

### Checklist

- [ ] Entry order puts level and faction before position; the masked-walk
      and short-run paths are deleted (code audit H1; chunk-index review 1,
      with 8). Failure: the key is level, chunk, local cell, then faction and
      slot (`spatial_index.zig:528`), so a faction-masked query reads each
      cell's faction sub-range as its own fragment, often one entry, through
      `visitMaskedCells` (`:329`), `visitMaskedRun` (`:354`), and
      `visitShortRun` (`:363`) (`.claude/rules/memory-performance.md`
      § Dense SoA storage). The hot masked queries are perception's hostile
      query (`perception.zig:910-914`) and cohere's friendly query
      (`ai.zig:992-998`), once per thinking agent per step. Splitters snap to
      row-part starts (`:1310`), so a crowd in fewer row parts than bands
      sorts on that many workers, one in a single row part on one. Failure
      scenario (derived): an observer in an ally crowd walks one fragment per
      cell and fills no lane block, at population scale. Design:
      `.claude/reports/slice-84-faction-layout-plan.md` (level, chunk,
      faction, then in-chunk position); the all-faction queries (separation,
      steering) read one run per faction per row piece. Pass: a masked query
      reads one contiguous run per requested faction and row piece; the three paths are gone; the
      tests and the `spatial_index-query` masked variant that encode the old
      order change with it; the sort order in the cost model carries its
      row-part qualifier, and `spatial_index-shape dense_chunk` stays off
      main.
- [ ] Per-level queries. Failure scenario: rows at the same xy on other
      levels count toward separation, cohesion, and perception (`:434`;
      `ai.zig:1100`, `:1149`). Measured for perception only:
      `perception-crowd levels` senses 16 cross-level rows per observer at
      L 32. Derived for separation and cohesion. Pass: `perception-crowd
      levels` senses 0 across levels, and on the `production-step` L axis
      `ai_separation_neighbor_samples` per thinking agent stays flat.
- [ ] A hostile in range is found regardless of allies and other levels.
      Failure scenario: allies spend the check budget (`perception.zig:134`),
      and cross-level hostiles fill the 16-entry scratch (`:124`, stop at
      `:846`) before the level check (`:1114`). Cohere fails the same way:
      hostiles spend its 64-check budget (`ai.zig:247`) before it reaches an
      ally; no bench measures it (code audit H1). Measured:
      `perception-crowd` 0/1024 found at allies 256 and at levels 32. Pass:
      every observer finds its hostile in both variants; checks per observer
      flat in allies and in levels; a cohere test or `ai` case finds its
      allies at a fixed check count however many hostiles surround them.
- [ ] Build on workers. Failure scenario: the halo sort runs on main
      (`spatial_index.zig:740`), so main time grows as H log H in the halo.
      Measured: 8.15 ms main at crowd P 16,384; `spatial_index` 95% main.
      Pass: main holds only the ordered merge; `spatial_index` and
      `production-step --details` show the build off main; serial == threaded
      across range sizes and worker counts; `FailingAllocator` proof on a
      multi-worker step; a pipeline test proves the build ran on workers; a
      clean TSan run over the new threaded range writes (the link stage's
      rows and slots) before merge (`.claude/rules/threading.md`; open
      question in the chunk-index review).
- [ ] One index per step: `DenseCellLookup` (`:141`) goes, and 85 retires
      steering's second sort onto this index. Slice 72's dense-window open
      site closes with it (72 cross-edit; code audit L10).
- [ ] The whole subsystem checked against the cost model and the rules
      (owner 2026-10-16), not only the items above: `spatial_index.zig`,
      its build and query paths, and the stage contract and dispatch it
      touches in `simulation_pipeline.zig` (the first core slice to change
      the pipeline). Each finding becomes an item here.
- [ ] `perception_update` and `ai_decide` declare their carried inputs
      (code audit M1). Failure: both read previous positions, velocity, and
      world level straight from `DataSystem` (`perception.zig:437-445`,
      `ai.zig:546-549`), but only `spatial_index_build` declares `carried`
      (`simulation_pipeline.zig:197-201`); the `perception_update` (`:207`)
      and `ai_decide` (`:219-223`) arms do not
      (`.claude/rules/simulation.md` § Pipeline and stage ordering). Failure
      scenario: either stage reordered after `plane_traversal` still
      compiles; its rows then hold this step's levels while the index holds
      the previous step's, so it senses across levels or misses a hostile.
      Pass: both arms carry `movement_positions` and `world_level`, so the
      reorder fails the comptime contract check.
- [ ] The separation accumulate is vectorized (moved from 35; code audit
      M4). Failure: `SeparationAccumulator.visit` (`ai.zig:931-946`), which
      this slice restructures, normalizes up to 32 neighbors per agent one
      at a time with no verdict at the site; a per-neighbor float loop is
      SIMD-shaped, so the restructured loop ships SIMD
      (`.claude/rules/memory-performance.md` § SIMD and core math). Pass:
      in-range neighbors gathered once into packed scratch sized from the
      fixed per-query budgets, the accumulate through `simd.zig` helpers
      with a scalar tail and a bounded mask in place of the per-neighbor
      early exit; scalar/SIMD and serial/threaded parity tests; a
      `FailingAllocator` proof over a multi-worker step with agents at the
      full neighbor and candidate caps.
- [ ] The new `spatial_index-shape` and `spatial_index-query` groups get a
      base (chunk-index review 2). Failure: they land in the same diff as
      the fix (`src/benchmarks/runner.zig:115-116`), so the per-query cost
      claim has no before number from its covering group and rests on
      derived numbers; the query group doc says its asserts check fixture
      invariants (`benchmarks/spatial_index.zig:27`), which
      `.claude/rules/tests-benchmarks.md` § Benchmarks allows only in a
      measuring landing. Pass: the groups' raw numbers on the base are in the
      landing notes, or the commit states they have none; the group doc
      states the pass shape its asserts check.
- [ ] Off-main bench asserts that hold in every mode (code audit L2;
      chunk-index review 3). Failure: `timeBuilds` asserts with
      `std.debug.assert` that each tuned stage ran on workers
      (`benchmarks/spatial_index.zig:192-193`), which depends on host timing;
      the link stage at 10,000 rows (about 1,000 cells, derived) sits far
      below the tuner's gate, where inline is the measured efficiency choice
      (`.claude/rules/threading.md`). Failure scenario: a fast host keeps link
      inline and the bench fails; under `bench_ab --optimize ReleaseFast` the
      false assert is UB. Pass: the bench returns an error, never asserts;
      it requires off main only the stages a Debug run shows above the gate
      with margin (the sort, the cost driver) and reports the rest `inline`;
      the landing notes name the run that reached the 10,000 case.
- [ ] Done in the working tree, checked off in the docs commit: the bucket
      and sort batches no longer share one perf-log `BatchStage`; only
      `sort_batch` records `.spatial_index_build`
      (`simulation_pipeline.zig:548`) (code audit L1; its log-policy
      remainder is [88](slice-88.md)'s).
- [ ] Done in the working tree, checked off in the docs commit: the three
      index-build `ThreadSystem` fixtures in `src/benchmarks/ai.zig` and
      `perception.zig` are gone; those benches build the index serially
      (code audit L6).
- [ ] Scalar reasons at the restructured gathers `gatherAiData`
      (`ai.zig:509`) and `gatherPerceptionData` (`perception.zig:415`)
      (code audit L7; `.claude/rules/memory-performance.md` § SIMD). Failure
      scenario: a restructured loop with no verdict leaves its scalar choice
      unreviewed. Pass: each site states its reason.
- [ ] The cohere-skip comment at `ai.zig:899` justifies code by demo content
      ("most demo archetypes …") (code audit L9;
      `.claude/rules/zig-style.md` § Comments). Pass: it states the contract
      (a zero cohere gain never wins) only.
- [ ] The module doc says the index is identical for any splitters and
      partition (`spatial_index.zig:30-32`), but `cells` layout and
      `RowPart.first_cell` differ by partition (the parity helper says so,
      `:1593`) (chunk-index review 4). Failure scenario: a consumer relies
      on partition-independent cell indices. Pass: the doc says the entries,
      masks, slots, and every query's visits are identical for any
      partition.
- [ ] `cellScanRadius` overflows for radius ÷ cell ≥ 2^31
      (`spatial_index.zig:941-944`; chunk-index review 5): `floorToI32`
      saturates `-(r / c)` to `minInt(i32)` and the negation overflows, a
      Debug panic and ReleaseFast UB; the query asserts only a finite
      radius, and `vision_range` is authored data. Pass: computed in i64 or
      clamped before the floor; a test at `radius = 1e30`.
- [ ] A SIMD verdict on the query's row and chunk loop
      (`spatial_index.zig:270-301`; chunk-index review 6;
      `.claude/rules/memory-performance.md` § SIMD). Pass: the site states
      its scalar reason (dependent directory, row, and cell loads).
- [ ] An empty build releases the level-directory tail (chunk-index review
      7). Failure: `build` and `buildSerial` return early at zero slots
      (`spatial_index.zig:753`, `:762`), and `buildBanded` returns before
      `prepareLink` at zero entries (`:842`). Failure scenario: the
      population empties while a tail level grown for a body past the
      world's levels keeps `chunks × 24 B` until the next non-empty build.
      Pass: the zero-entry paths fit levels to the geometry's level count;
      the level-directory test (`:2448`) gains an empty build after the
      grown one.
- [ ] The oracle comment at `ai.zig:2791` names `cellForPosition`, which no
      longer exists (chunk-index review 9). Pass: the name is dropped or
      reads `math.worldPosToCell`.
- [ ] Tests: per-level queries at shared xy; ally-crowded and level-stacked
      hostiles found; serial == threaded; allocation-free warmed step.
- [ ] Docs: `docs/architecture.md` spatial index;
      `docs/simulation-tiers-and-pipeline.md` stage list.
- [ ] Docs commit: the foundation and checklist describe the code as
      landed (docs audit M3: `spatial_index.zig:141`, `:434`, `:740` name
      code that is gone).
- [ ] Docs commit: archive Slice 83 (docs audit M4): `git mv` its file to
      `roadmap/archive/`, move its row
      (`framework-implementation-slices.md`, Open Frontier index) to the
      archive index, and update its Suggested Order line (Ground Rules).
- [ ] Docs commit: the changelog matches the slices (docs audit M12).
      Failure: `docs/changelogs/core_systems.md:9-12` says Slice 83's
      `verify` is open (it passes at `13e88ad`); `:87-88` gives collision
      2.7 / 11.0 ms and spatial index 8.0 ms where the slices give 2.95 /
      11.6 ms and 8.15 ms main; `:98` gives `world-create` nav 122 ms where
      74 gives 117.5 ms; `:110` says nine caller-settable tuner fields where
      ten are listed. Pass: numbers from one run, labelled wall or main;
      "ten".
- [ ] Docs commit: 68A cross-edit (code audit L10). Failure: 68A's
      foundation and checklist still describe the halo candidate tables and
      a missing `world_level` carry on `spatial_index_build`; `c52a5ff`
      removed the tables and added the carry
      (`simulation_pipeline.zig:200`). Pass: 68A's foundation matches the
      landed index, and its carry item records that 84 landed it.
- [ ] Docs commit: DW indexes the bench groups instead of restating them
      (docs audit L3). Failure: DW:519-560 restates each group doc's pass
      shape and fields (for example `src/benchmarks/production_step.zig:5-23`),
      and DW defines `main=` twice with different wording (`:433`, `:532`).
      Pass: one index line per group pointing at its group doc; one `main=`
      definition.
- [ ] Docs commit: one canonical place per explanation (docs audit L4).
      Failure: bench_ab's CPU, cache, and verdict behavior appear in DW:733-745,
      `tools/README.md:53-70`, and the `tools/bench_ab.py` docstring (:18-37),
      plus `CLAUDE.md:98`; configure-cache poisoning in `docs/setup.md:66-71`
      and DW:165-172; the CPU floor mapping in DW:73-79 and the bench_ab
      docstring. Pass: `tools/README.md` holds bench_ab's behavior and DW the
      floor and configure cache; the others cite them. `CLAUDE.md` is the
      owner's to edit.
- [ ] Docs commit: DW's callgrind refusal list (docs audit L12). Failure:
      DW:366 says the build refuses "a non-Linux target", but `build.zig:799`
      also refuses a non-Linux host and a foreign-arch target. Pass: "a
      non-native-Linux build".
- [ ] Docs commit: DW's bench fields match what prints (docs audit L13).
      Failure: DW:427-431 lists `narrow=` as a summary field, but it prints
      only under `--details` (`src/benchmarks/collision.zig:313`); the
      spatial index `sort=` field is undocumented (DW:432). Pass: each field
      listed under the view that prints it.

### Acceptance checks

- [ ] `perception-crowd` meets its group-doc pass shape, and its shape
      asserts land with the fix (`.claude/rules/tests-benchmarks.md`).
- [ ] `spatial_index` at three sizes is linear with the build off main;
      `perception` and `ai` show no regression beyond run-to-run spread.
- [ ] `zig build verify` passes.
