# Module Layout Changelog

Branch: `module_layout`

Range: `main..module_layout`

Base: `93b5276` (`Merge pull request #11 from Ronin15/engine_scale`)

Tip: Slice 82 complete; Slice 81 (split the pathfinding module) follows on
this branch.

## Summary

A short branch of file moves and splits, merged before the core branch opens,
so later branches plan against the final file layout. No behavior, order,
layout, or allocation change: the full suite is 1741/1741 at each Slice 82
commit and at the tip.

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

## Conventions

- **Declaration aliases (`7f2cfa9`).** A public method defined in a split file
  is a declaration alias on its type (`pub const setDenseTile =
  world_edit.setDenseTile;`), documented at the definition, so method syntax
  reaches the definition with no forwarder frame in any mode. `WorldSystem`
  and `DataSystem` (`structural.zig`) use it (`docs/architecture.md`
  § Source Layout).
- **Alias wording (`c8a27ae`).** `zig-style.md` now allows file-local aliases
  of imported declarations and bans only bridge re-exports kept so an old
  path still resolves.

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
