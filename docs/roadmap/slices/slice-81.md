## Slice 81: Split The Pathfinding Module

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 64G](slice-64g.md) · Track: standalone (engine core)

**Status: not started.** Owner todo 2026-10-11: after 64G seals.

Goal: the pathfinding package's production parts that can stand on their own are
separated into their own files, each with its tests beside it, so every file has
one job a reader can hold; behavior, orders, allocation, and determinism do not
change. The design pass decides the seams from the code as landed.

### Current foundation

Sizes at `e2b9b2c` (lines; "test" counts top-level `test` blocks, the rest is
production code, doc comments, and helpers):

| File | Lines | Test | Rest |
| --- | --- | --- | --- |
| `pathfinding/system.zig` | 11,459 | 6,742 | 4,717 |
| `pathfinding/connectivity.zig` | 8,569 | 2,448 | 6,121 |
| `pathfinding/nav_graph.zig` | 5,418 | 2,247 | 3,171 |
| `pathfinding/solve.zig` | 3,332 | 1,408 | 1,924 |
| `pathfinding/caches.zig` | 2,241 | 740 | 1,501 |
| `pathfinding/types.zig` | 1,537 | 211 | 1,326 |
| `pathfinding/group_field.zig` | 1,201 | 381 | 820 |
| `pathfinding/nav_grid.zig` | 1,125 | 337 | 788 |
| `pathfinding/scratch.zig` | 790 | 230 | 560 |
| `pathfinding/test_support.zig` | 703 | 0 | 703 (test-only) |
| `pathfinding/goal_table.zig` | 578 | 186 | 392 |
| `systems/pathfinding.zig` (facade) | 44 | 13 | 31 |
| Package total | 36,997 | 14,943 | 22,054 |
| `benchmarks/pathfinding.zig` | 5,756 | 0 | 5,756 |
| `benchmarks/suite.zig` | 2,082 | 382 | 1,700 |

- `systems/pathfinding.zig` is a thin facade re-exporting the package's public
  surface; external importers resolve through it.
- `src/benchmarks/pathfinding.zig` holds every pathfinding bench group with its
  fixtures and drivers; `suite.zig` holds the generic harness and also the nav
  memory estimate (`navStorageParts`, `checkNavSize`, `checkNavBytes`).
- The 64G combined review named candidate seams in nav_graph, connectivity,
  and system; the bench review named the bench file's (shared nav fixtures,
  request load, routes, cache/eviction/elastic, negative, connectivity). The
  world module's move and split is [Slice 82](slice-82.md).

### Architecture notes

- File moves and splits only: no behavior, order, layout, or allocation change;
  identical results, serial and threaded (`.claude/rules/simulation.md`
  § Determinism). Ownership stays in `src/game/systems/pathfinding/`
  (`docs/architecture.md` § Source Layout).
- Tests stay beside the code they cover (`.claude/rules/tests-benchmarks.md`);
  shared fixtures stay in `test_support.zig`.
- Imports are direct, with no bridge aliases (`.claude/rules/zig-style.md`).
- A seam is one a design pass finds in the code as landed, never a target line
  count.

### Checklist

- [ ] Design pass on the landed package: which production parts separate
      (with their tests) and where each goes.
- [ ] The pathfinding package split along those seams, the facade's public
      surface unchanged.
- [ ] `src/benchmarks/pathfinding.zig` split along its seams (shared nav
      fixtures, request load, routes, cache/eviction/elastic, negative,
      connectivity); the nav memory estimate moves out of the generic `suite.zig`
      harness.
- [ ] `docs/architecture.md` § Source Layout lists the new files.

### Acceptance checks

- [ ] `zig build verify` passes before and after each move, and the full test
      count is unchanged.
- [ ] Bench `--details` outputs of the moved groups are identical apart from
      timings.
