## Slice 84: Level-Aware Shared Neighbor Index

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 83](slice-83.md) (layout) · Before: [Slice 86](../slices/slice-86.md), [Slice 85](../slices/slice-85.md), [Slice 75](../slices/slice-75.md) · Track: standalone (engine core; [Engine-Core Overhaul](../../framework-implementation-slices.md#engine-core-overhaul))

**Status: landed on `core_systems` (`c52a5ff`, `08e4799`, `3efa1e4`,
`320023a`, `5c4babb`, `2bcd8b6`); `verify` passes. 85 moves steering
onto the index.

Goal: one neighbor index per world per step, built once on workers and
shared by every neighbor query (separation, cohesion, perception, and, after
85, steering). It answers per level, so nothing senses, separates, or
coheres across levels through rock. An observer finds a hostile in range
however many allies or other-level rows surround it, at a per-observer cost
that does not grow with them.

### Current foundation

- `SpatialIndexSystem` (`src/game/systems/spatial_index.zig`; design in
  `docs/architecture.md`): entries keyed level | chunk | faction | local cell
  | slot (`:791-794`), per-chunk records with faction row masks (`:770`),
  built by bucket, sort, and link stages on workers under its own tuners
  (`build`, `:1051`), with `buildSerial` (`:1067`). A query reads one level
  and a faction set (`NeighborQuery`, `:194`) in lane groups through a per-key
  `NeighborBlock` (`:679`).
- Consumers: AI separation and cohere (`src/game/systems/ai.zig:1024`,
  `:1060`) and perception (`perception.zig:925`); the think set comes from the
  index in cell-major order (`ai_cognition_order`,
  `simulation_scope.zig:396`). Steering still sorts its own grid (85).
- Measured (Debug): `production-step` crowd P 16,384 tuned, spatial index
  0.27 ms main, 30/30 steps on workers (`c52a5ff`); `spatial_index` tuned
  184 / 474 / 952 µs at 1,024 / 4,096 / 10,000 entities (`c52a5ff`), 898 µs at
  10,000 (`3efa1e4`).

### Architecture notes

- A neighbor result is stored at the unit it covers and shared by every
  requester (`.grok/rules/engine-design.md` § Cost model), built once per
  step. Its order follows its hot queries' filter keys
  (`.grok/rules/memory-performance.md` § Data-oriented design), so an observer
  never pays for allies or other-level rows to reach a hostile.
- Neighbor queries use the shared index (`.grok/rules/simulation.md`). The
  build sorts, which is per-item work that grows, so it threads with a serial
  path and bitwise parity (`.grok/rules/threading.md`).
- Per-query budgets stay fixed counts (`.grok/rules/budgets-capacities.md`).
- 75 owns indexing the whole population in every band; this index takes any
  population 75 hands it at the same per-row cost.

### Checklist

- [x] Entry order: level and chunk, then faction ahead of position
      (`spatial_index.zig:791-794`); a masked query reads one run per (piece,
      faction) (`BoxRuns`, `:582`); the masked cell walk and short-run visit
      are gone; `spatial_index-shape dense_chunk` asserts the sort on workers
      (`08e4799`).
- [x] Per-level queries: queries read one level (`spatial_index.zig:194`;
      test `:2563`). `production-step` `stacked` (256 rows per level, L 1/4/8,
      `2bcd8b6`) holds separation checks per thinking row flat (28.17, 28.07,
      28.11 serial) and asserts them within one level's scan-box rows; a
      forced cross-level leak (86.85 at L 4, 103.99 at L 8) fails it.
- [x] A hostile in range is found regardless of allies and levels:
      hostile-masked perception and friendly-masked cohere queries per level;
      `perception-crowd` asserts every observer finds its hostile within its
      check bound; tests `perception.zig:1608`, `:1632`, `ai.zig:3084`.
- [x] Build on workers: main holds splitters, band prefixes, and the
      directory fit; parity `spatial_index.zig:2164`, `FailingAllocator`
      `:3392`, pipeline workers test (`simulation_pipeline.zig:5445-5467`),
      TSan clean in `c52a5ff`, `08e4799`, and `3efa1e4`.
- [x] One index per step: `DenseCellLookup` is gone (`c52a5ff`); Slice 72's
      dense-window open site is removed from its foundation and D4 is checked
      off there. Steering's second sort is 85's first item.
- [x] The whole subsystem checked against the cost model and the rules.
      Landed: every finding is fixed (`c52a5ff`–`3efa1e4`) or filed in 85
      (`steering_update` carries, the per-step width error, `select_claim`'s
      item unit) and 88 (affect's gather, memory's visibility order, the
      `u32` row caps) and 86 (collision response's `apply` stage dispatches
      one item per fixed band, `collision_response.zig:296`, `:307`).
- [x] `perception_update` and `ai_decide` carry `movement_positions` and
      `world_level` (`simulation_pipeline.zig:212-232`).
- [x] The separation accumulate runs in lanes
      (`SeparationAccumulator.visitLanes`, `ai.zig:1008`); parity tests
      `ai.zig:2925`, `:3010`.
- [x] The `spatial_index-query` doc states its pass shape and its asserts
      check it (`src/benchmarks/spatial_index.zig:16-25`).
- [x] The off-main bench assert names only the sort (`error.SortRanInline`,
      `benchmarks/spatial_index.zig:193`); bucket and link report `inline`;
      the 10,000 case ran in `c52a5ff`, `08e4799`, and `3efa1e4`.
- [x] Only `sort_batch` records `.spatial_index_build`
      (`simulation_pipeline.zig:547`; code audit L1).
- [x] The `ai` and `perception` benches build the index with `buildSerial`
      (code audit L6).
- [x] Scalar reasons at the gathers (`ai.zig:612-614`,
      `perception.zig:524-526`).
- [x] The cohere-skip comment states the contract (`ai.zig:972-973`).
- [x] The module doc's partition claim holds: every view structure is
      identical for any partition (`spatial_index.zig:18-19`), tested whole
      (`:2045-2090`).
- [x] `cellScanRadius` saturates (`lossyCast(@ceil)`, `:1290`); test at
      radius 1e30 (`:3217`).
- [x] The query's piece loop states its scalar reason (`BoxRuns`, `:578-580`).
- [x] An empty build releases the level-directory tail (`finishEmptyBuild`,
      `:1075`); test `:3296`.
- [x] No comment names `cellForPosition`.
- [x] Tests: per-level queries at shared xy, ally-crowded and level-stacked
      hostiles found, serial == threaded, allocation-free warmed step.
- [x] Production per-step and per-change sorts use `core/sort.zig`'s
      whole-element swaps (`320023a`; 43 sites in 22 files at the sweep);
      tests, benches, cold sorts, and the tie-holding `std.mem.sort` sites
      keep std (`.grok/rules/zig-style.md` § Style).
- [x] Docs: `docs/architecture.md` spatial index;
      `docs/simulation-tiers-and-pipeline.md` stage list.
- [x] Docs commit: the foundation and checklist describe the landed code.
- [x] Docs commit: the changelog's numbers come from one run, labelled wall
      or main; "ten" tuner fields.
- [x] Docs commit: 68A's foundation matches the landed index; its carry and
      think-set items record 84.
- [x] Docs commit: one place per explanation (docs audit L3, L4; owner
      2026-10-16: "you just are sloping the docs up otherwise"). Failure:
      bench_ab's behavior is explained in DW § Benchmarks (its last
      paragraph), `tools/README.md` § `bench_ab.py`, the `tools/bench_ab.py`
      docstring, and `CLAUDE.md` § Claude Code Tooling; configure-cache
      poisoning in `docs/setup.md` (Windows), DW § Windows SDL Packages, and
      DW § Thread Sanitizer; the CPU floor in DW § Release Modes and the
      bench_ab docstring; and DW § Benchmarks' group lists restate each
      bench group doc (for example `src/benchmarks/production_step.zig:5-21`).
      Failure scenario: one copy changes and the others drift. Pass:
      `tools/README.md` holds bench_ab's behavior, DW the CPU floor and the
      configure cache, and each group doc its pass shape; the others cite
      them. `CLAUDE.md` is the owner's to edit. Landed: `docs/setup.md`, DW
      § Thread Sanitizer, the `tools/bench_ab.py` docstring, and DW § Benchmarks'
      last paragraph cite their owners; DW § Benchmarks' group lists are an
      index (name, file) over the group docs; `CLAUDE.md` only points at
      bench_ab. Group doc gaps found are filed below.
- [x] Bench group docs hold the per-group facts DW's group lists held
      (`baa4e62`).
- [x] Docs commit: DW's callgrind refusal list names a non-native-Linux
      build.
- [x] Docs commit: DW keeps only the fields shared by every group (`main=`,
      the threaded-stage lines); per-group fields live in the group docs.
- [x] Docs commit: DW § Benchmarks says how to read `serial-direct` against
      the tuned case, citing `tests-benchmarks.md`.
- [x] Docs commit: Scaling Gaps holds perception's block at sharing factor 1.

### Acceptance checks

- [x] `perception-crowd` meets its group-doc pass shape, and its shape
      asserts landed (`src/benchmarks/perception.zig:619-622`).
- [x] `spatial_index` at three sizes follows its pass shape with the sort off
      main (184 / 474 / 952 µs tuned at 1,024 / 4,096 / 10,000, `c52a5ff`);
      `perception` and `ai` tuned faster at 2,048 (`3efa1e4`), serial a
      control there (`.grok/rules/tests-benchmarks.md`).
- [x] `zig build verify` passes (exit 0, and the full test under
      `-Dsanitize-thread=true` exit 0 with no reports, on `908ac83`; docs-only
      changes since).
