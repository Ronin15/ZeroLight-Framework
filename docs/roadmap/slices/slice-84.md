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
  requester (`.claude/rules/engine-design.md` § Cost model): per cell and
  level, built once per step, so an observer never pays for allies or
  other-level rows to reach a hostile.
- Neighbor queries use the shared index (`.claude/rules/simulation.md`). The
  build sorts, which is per-item work that grows, so it threads with a serial
  path and bitwise parity (`.claude/rules/threading.md`). Steering's banded
  grid build (`steering.zig:716`) is the proven threaded pattern.
- Per-query budgets stay fixed counts (`.claude/rules/budgets-capacities.md`).
- 75 owns indexing the whole population in every band; this index takes any
  population 75 hands it at the same per-row cost.

### Checklist

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
      `:846`) before the level check (`:1114`). Measured: `perception-crowd`
      0/1024 found at allies 256 and at levels 32. Pass: every observer finds
      its hostile in both variants; checks per observer flat in allies and
      in levels.
- [ ] Build on workers. Failure scenario: the halo sort runs on main
      (`spatial_index.zig:740`), so main time grows as H log H in the halo.
      Measured: 8.15 ms main at crowd P 16,384; `spatial_index` 95% main.
      Pass: main holds only the ordered merge; `spatial_index` and
      `production-step --details` show the build off main; serial == threaded
      across range sizes and worker counts; `FailingAllocator` proof on a
      multi-worker step; a pipeline test proves the build ran on workers.
- [ ] One index per step: `DenseCellLookup` (`:141`) goes, and 85 retires
      steering's second sort onto this index. Slice 72's dense-window open
      site closes with it (72 cross-edit).
- [ ] Tests: per-level queries at shared xy; ally-crowded and level-stacked
      hostiles found; serial == threaded; allocation-free warmed step.
- [ ] Docs: `docs/architecture.md` spatial index;
      `docs/simulation-tiers-and-pipeline.md` stage list.

### Acceptance checks

- [ ] `perception-crowd` meets its group-doc pass shape, and its shape
      asserts land with the fix (`.claude/rules/tests-benchmarks.md`).
- [ ] `spatial_index` at three sizes is linear with the build off main;
      `perception` and `ai` show no regression beyond run-to-run spread.
- [ ] `zig build verify` passes.
