# Module Layout Changelog

Branch: `module_layout`

Range: `main..module_layout`

Base: `93b5276` (`Merge pull request #11 from Ronin15/engine_scale`)

Tip: Slices 82 and 81 complete; the branch seal follows.

## Summary

A short branch of file moves and splits, merged before the core branch opens,
so later branches plan against the final file layout. No behavior, order,
layout, or allocation change: the full suite is 1741/1741 at each Slice 82 and
Slice 81 commit and at the tip.

## Slice 82: Split The World Module

- `1caabf4`: the five world files move into `src/game/world/` (`system`,
  `gpu_tiles`, `terrain`, `interest`, `test_support`). Every importer uses a
  direct path, with no facade beside the folder; the two `WorldSystem` bridge
  aliases became direct imports. The `render.md` globs name the new files
  (owner approved).
- `e6c314b`: `world/render.zig` takes the render path (sparse window, dense
  composite submit, GPU sync, sparse submit), with 48 tests.
- `92df3dc`: `world/edit.zig` takes every terrain content write (single-cell,
  batched with its threaded plan and write jobs, sparse, clear-cell), with 37
  tests.
- `b45dd15`: `world/worldgen.zig` takes the procedural and demo builds and the
  underground level stack, with 6 tests. Bench `--details` workload fields
  match the pre-move baseline across the five world and chunk-scale groups.
- `system.zig` keeps the type, storage, levels, layers, links, queries, the
  catalog, and view geometry (2,203 lines, from 8,450).

## Slice 81: Split The Pathfinding Module

- `e37c648` (C1): the nav memory estimate moves out of the generic `suite.zig`
  into `src/benchmarks/nav_size.zig`, with its 3 tests; `chunk_scale.zig` and
  the pathfinding benches import it directly.
- `e232337` (C2): `src/benchmarks/pathfinding.zig` becomes the
  `src/benchmarks/pathfinding/` folder: `nav_fixtures.zig` holds what two or
  more files share, and `requests`, `routes`, `cache`, `negative`, and
  `connectivity` hold the groups. `runner.zig` keeps the 28 groups' order and
  names.
- `6778fff` (C3): `link_bounds.zig` takes the link cost bounds from
  `nav_graph.zig`, with 5 tests.
- `377db2d` (C4): `connectivity_closure.zig` takes the one-way closure from
  `connectivity.zig`, with 46 tests; the flood stays.
- `b529767` (C5): `publish.zig` takes the publish and path registry, with 10
  tests.
- `932b4c8` (C6): `group_service.zig` takes the group-field service, with 21
  tests.
- `1997a7e` (C7): `intake.zig` takes request intake, with 6 tests.
- `cbc3e66` (C8): `eviction.zig` takes scoped eviction, with 19 tests.
  `navDispatch` becomes a file-level function the package files share.
- `f209ce7` (C9): `nav_reaction.zig` takes the nav builds, nav-mark recording,
  and the post-commit reaction, with 21 tests.
- `system.zig` keeps the type, its lifecycle and elastic capacity, status,
  reach and goals, the update orchestration, the solve phase, and the pending
  ring (6,023 lines, from 11,697). Test names are unchanged, and bench
  `--details` workload lines match the Slice 81 baseline for every pathfinding
  group, and for `nav-update` and `chunk-scale` at C9.

## Conventions

- **Declaration aliases (`7f2cfa9`).** A public method defined in a split file
  is a declaration alias on its type (`pub const setDenseTile =
  world_edit.setDenseTile;`), documented at the definition, so method syntax
  reaches the definition with no forwarder frame in any mode. `WorldSystem`,
  `DataSystem` (`structural.zig`), and from Slice 81 `PathfindingSystem` and
  `Connectivity` use it (`docs/architecture.md` § Source Layout).
- **Alias wording (`c8a27ae`).** `zig-style.md` now allows file-local aliases
  of imported declarations and bans only bridge re-exports kept so an old
  path still resolves.
- **Unused declarations (`ce1515d`).** `zig-style.md` states the rule
  idiom-lint rule 8 enforces: no unused file-scope declarations (owner
  approved).
- **Nav bench harness (`9e308ff`).** `tests-benchmarks.md` names
  `nav_size.zig` as shared harness beside `suite.zig`, with the same exemption
  for its pure-utility tests, and the `pathfinding.md` globs cover
  `src/benchmarks/pathfinding/**` and `nav_size.zig` (owner approved).

## Tests And Tooling

- `048008c`: the two world render tests that deliberately trip the window clip
  and layer drop raise the test log level, so `zig build test` prints no
  stderr.
- `f71c6e6`: idiom-lint rule 8 rejects unused file-scope consts; it found and
  removed six dead imports (benchmarks `collision`, `collision_response`;
  pathfinding `goal_table`, `group_field` (two), `solve`). `5aec1ce`: the rule
  counts `@"name"` and `@field(x, "name")` spellings as uses.

## Commit List

- `1caabf4` Slice 82: move the world files into src/game/world/
- `c8a27ae` zig-style: file-local type aliases are idiomatic; only bridge re-exports are banned
- `e6c314b` Slice 82: extract world/render.zig from world/system.zig
- `92df3dc` Slice 82: extract world/edit.zig from world/system.zig
- `7f2cfa9` WorldSystem and DataSystem: declaration aliases instead of forwarder methods
- `048008c` world/render tests: keep the two expected clip warnings off stderr
- `f71c6e6` idiom-lint: reject unused file-scope consts; remove the six dead imports
- `b45dd15` Slice 82: extract world/worldgen.zig from world/system.zig
- `5aec1ce` idiom-lint rule 8: count @"name" and @field(x, "name") as uses
- `7c28c42` world/render.zig header: public render methods are aliases, not forwarders
- `22e3aee` Slice 82 docs: world/ layout, split-file alias pattern, old paths, changelog
- `ce1515d` zig-style: no unused file-scope declarations (idiom-lint rule 8)
- `9e308ff` Rules for Slice 81's bench split: nav_size.zig harness, pathfinding bench globs
- `6778fff` Slice 81: extract pathfinding/link_bounds.zig from nav_graph.zig
- `e37c648` Slice 81: move the nav memory estimate out of suite.zig into nav_size.zig
- `e232337` Slice 81: split benchmarks/pathfinding.zig into benchmarks/pathfinding/
- `377db2d` Slice 81: extract pathfinding/connectivity_closure.zig from connectivity.zig
- `b529767` Slice 81: extract pathfinding/publish.zig from system.zig
- `932b4c8` Slice 81: extract pathfinding/group_service.zig from system.zig
- `1997a7e` Slice 81: extract pathfinding/intake.zig from system.zig
- `cbc3e66` Slice 81: extract pathfinding/eviction.zig from system.zig
- `f209ce7` Slice 81: extract pathfinding/nav_reaction.zig from system.zig
