## Slice 81: Split The Pathfinding Module

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 64G](slice-64g.md), [Slice 82](slice-82.md) · Track: standalone (engine core)

**Status: complete (2026-10-15, branch `module_layout`).** Code in `e37c648`,
`e232337`, `6778fff`, `377db2d`, `b529767`, `932b4c8`, `1997a7e`, `cbc3e66`,
`f209ce7` (C1–C9); docs in the slice's docs commit. Owner todo 2026-10-11:
after 64G seals; runs right after 82 on the same file-move branch, before the
core branch opens.

Goal: the pathfinding package's production parts that can stand on their own are
separated into their own files, each with its tests beside it, so every file has
one job a reader can hold; behavior, orders, allocation, and determinism do not
change. The design pass decides the seams from the code as landed.

### Current foundation

Sizes as landed, at `f209ce7` (lines; "test" counts top-level `test` blocks, the
rest is production code, doc comments, and helpers):

| File | Lines | Test | Rest |
| --- | --- | --- | --- |
| `pathfinding/system.zig` | 6,023 | 3,898 | 2,125 |
| `pathfinding/publish.zig` | 831 | 388 | 443 |
| `pathfinding/group_service.zig` | 1,109 | 715 | 394 |
| `pathfinding/intake.zig` | 747 | 253 | 494 |
| `pathfinding/eviction.zig` | 1,365 | 652 | 713 |
| `pathfinding/nav_reaction.zig` | 1,564 | 966 | 598 |
| `pathfinding/connectivity.zig` | 4,122 | 1,010 | 3,112 |
| `pathfinding/connectivity_closure.zig` | 4,282 | 1,438 | 2,844 |
| `pathfinding/nav_graph.zig` | 4,578 | 1,983 | 2,595 |
| `pathfinding/link_bounds.zig` | 877 | 279 | 598 |
| `pathfinding/solve.zig` | 3,331 | 1,408 | 1,923 |
| `pathfinding/caches.zig` | 2,241 | 740 | 1,501 |
| `pathfinding/types.zig` | 1,539 | 211 | 1,328 |
| `pathfinding/group_field.zig` | 1,199 | 381 | 818 |
| `pathfinding/nav_grid.zig` | 1,125 | 337 | 788 |
| `pathfinding/scratch.zig` | 790 | 230 | 560 |
| `pathfinding/test_support.zig` | 1,458 | 0 | 1,458 (test-only) |
| `pathfinding/goal_table.zig` | 577 | 186 | 391 |
| `systems/pathfinding.zig` (facade) | 51 | 20 | 31 |
| Package total | 37,809 | 15,095 | 22,714 |
| `benchmarks/pathfinding/nav_fixtures.zig` | 496 | 0 | 496 |
| `benchmarks/pathfinding/requests.zig` | 1,325 | 0 | 1,325 |
| `benchmarks/pathfinding/routes.zig` | 1,869 | 0 | 1,869 |
| `benchmarks/pathfinding/cache.zig` | 545 | 0 | 545 |
| `benchmarks/pathfinding/negative.zig` | 670 | 0 | 670 |
| `benchmarks/pathfinding/connectivity.zig` | 1,052 | 0 | 1,052 |
| `benchmarks/nav_size.zig` | 263 | 73 | 190 |
| `benchmarks/suite.zig` | 1,829 | 309 | 1,520 |

- At `e2b9b2c`, `system.zig` was 11,459 lines (11,697 at `22e3aee`, the
  slice's base), `connectivity.zig` 8,569, `nav_graph.zig` 5,418,
  `test_support.zig` 703, `benchmarks/pathfinding.zig` 5,756, and `suite.zig`
  2,082.
- `systems/pathfinding.zig` is still the thin facade with an unchanged public
  surface; its `test` block reaches every package file.
- `PathfindingSystem` and `Connectivity` are split-file types
  (`docs/architecture.md` § Source Layout): public methods defined in a sibling
  file are declaration aliases on the type (13 in `nav_reaction.zig`,
  `groupFieldThreshold` in `group_service.zig`, and four closure entries on
  `Connectivity`).
- `src/benchmarks/pathfinding/` holds the 28 pathfinding groups; group files
  import only `nav_fixtures.zig` and the harness, and `runner.zig` lists the
  groups in the same order and names. The nav memory estimate is
  `src/benchmarks/nav_size.zig`, shared with `chunk_scale.zig`.

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

### Landed against the plan

The plan is `.claude/reports/slice-81-plan.md`.

- Test placement: a test of base code stays beside it.
  - C4: `connectivity` 37, `connectivity_closure` 46 (plan 32/51). Five tests
    in the plan's range cover `growPool`, the `MergeMap`/`reserveMerge` limits,
    comp-pool exhaustion (two), and the node-row reserve.
  - C5: `publish` 10 (plan 14). Two tests cover elastic resize and `reserve()`.
    The two threaded registry-flush parity tests need an unflushed owner log
    that only the private `updateInline` and `resizePreservingLiveState`
    produce, and those stay private.
  - C6: `group_service` 21 (plan 27). Six cover `reserve`, the group tally, or
    `statusForKeyAndStart`. C7 then took the group-tally test with
    `recordGroupRequestCount`, so `intake` has 6 (plan 5).
  - C8: `eviction` landed the plan's 19.
  - `system.zig` ends at 98 tests (plan 89).
- No `PathfindingSystem` method was widened. Cross-file calls go to free
  functions made `pub` in their new files; `StepGates` (in `acceptRequests`'s
  signature) and `GrowthCounter.record` are the only declarations on the type
  made `pub`.
- `navDispatch`, which eviction and the nav reaction call, is a file-level
  `pub fn` in `system.zig` rather than a `pub` method (C8 review fix), so the
  type the facade re-exports gains no internal helper.
- The workflow review file lists named each new file in its landing, from C3,
  rather than in the docs commit.

### Checklist

- [x] Design pass on the landed package: which production parts separate
      (with their tests) and where each goes. Five `system.zig` seams
      (`publish`, `group_service`, `intake`, `eviction`, `nav_reaction`), one
      in `connectivity.zig` (the one-way closure; the flood stays, since it
      shares merge staging with it), one in `nav_graph.zig` (`link_bounds`; the
      key plan stays); no split of the other files.
- [x] The pathfinding package split along those seams, the facade's public
      surface unchanged: `link_bounds` `6778fff`, `connectivity_closure`
      `377db2d`, `publish` `b529767`, `group_service` `932b4c8`, `intake`
      `1997a7e`, `eviction` `cbc3e66`, `nav_reaction` `f209ce7`. The package's
      test count stays 425.
- [x] `src/benchmarks/pathfinding.zig` split along its seams into
      `src/benchmarks/pathfinding/` (`nav_fixtures`, `requests`, `routes`,
      `cache`, `negative`, `connectivity`; `e232337`); the nav memory estimate
      moves out of the generic `suite.zig` harness into
      `src/benchmarks/nav_size.zig` with its 3 tests (`e37c648`). Rule edit
      `9e308ff` (owner approved) covers the harness exemption and the
      pathfinding bench globs.
- [x] `docs/architecture.md` § Source Layout lists the new files (docs commit).

### Acceptance checks

- [x] `zig build verify` passes before and after each move, and the full test
      count is unchanged: 1741/1741 at the baseline and at every commit C1–C9
      (fresh cache). At C3–C9 the test names match the commit before; C1 moved
      the estimate's 3 tests (`suite` 21, `nav_size` 3) and C2 moved none.
- [x] Bench `--details` outputs of the moved groups are identical apart from
      timings (quick profile, `thread-fixed-2`, masked for timing and tuner
      fields, against the Slice 81 baseline):
      - every pathfinding group at C1, C2 (group order identical), C5, C7
        (0 of 2,582 lines differ), C8 (0 of 2,583), and C9 (0 of 2,582);
      - the connectivity groups at C4 (0 of 493) and the group-field groups at
        C6 (0 of 195); C3 ran the suite only, and its code is under the full
        runs from C5 on;
      - at C9, against the tree before it, all six `nav-update` groups,
        `chunk-scale-dig`, and `chunk-scale-nav-dig`: no workload diffs; only
        adaptive-tuner rows vary, by as much as one tree varies against itself.
