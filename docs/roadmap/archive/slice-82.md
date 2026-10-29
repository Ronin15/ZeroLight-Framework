## Slice 82: Split The World Module

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 64G](../slices/slice-64g.md) · Track: standalone (engine core)

**Status: complete (2026-10-15, branch `module_layout`).** Code in `1caabf4`,
`e6c314b`, `92df3dc`, `7f2cfa9`, `b45dd15`; docs in the slice's docs commit.
Owner direction 2026-10-09 (after 64G seals); its own slice per owner
2026-10-14.

Goal: the world files move into `src/game/world/` (as `data_system/` is laid out)
and `world_system.zig` splits into files that each have one job a reader can hold,
with tests beside their code; behavior, orders, allocation, and determinism do not
change. The design pass decides the seams from the code as landed.

### Current foundation

Sizes as landed, at `5aec1ce` (lines):

| File | Lines |
| --- | --- |
| `game/world/system.zig` | 2,203 |
| `game/world/render.zig` | 2,422 |
| `game/world/edit.zig` | 3,336 |
| `game/world/worldgen.zig` | 512 |
| `game/world/gpu_tiles.zig` | 1,198 |
| `game/world/terrain.zig` | 1,071 |
| `game/world/interest.zig` | 402 |
| `game/world/test_support.zig` | 294 |

- At `dcdbea5`, `world_system.zig` was 8,450 lines and `world_test_support.zig`
  131; the other three moved unchanged apart from imports.
- `world/terrain.zig` holds the one `ChunkGeometry` that terrain, nav, and static
  colliders share (`19256c5`).
- The 64G combined review (area C) named `world_system.zig` seams and routed the
  split after 64G.

### Architecture notes

- File moves and splits only: no behavior, order, layout, or allocation change;
  identical results, serial and threaded (`.grok/rules/simulation.md`
  § Determinism). World render state stays in `WorldSystem`'s render path
  (`.grok/rules/render.md`; `docs/architecture.md` § Source Layout).
- Tests stay beside the code they cover (`.grok/rules/tests-benchmarks.md`);
  shared fixtures stay in the world test support file.
- Imports are direct, with no bridge aliases (`.grok/rules/zig-style.md`).
- A seam is one a design pass finds in the code as landed, never a target line
  count.

### Checklist

- [x] Design pass on the landed world files: the `world_system.zig` seams and
      the `src/game/world/` layout. Four seams (`system`, `render`, `edit`,
      `worldgen`), no facade beside the folder.
- [x] World files moved under `src/game/world/` and `world_system.zig` split
      along those seams; importers updated directly. Move `1caabf4` (the two
      bridge aliases became direct imports), render `e6c314b`, edit `92df3dc`,
      worldgen `b45dd15`; `7f2cfa9` made the cross-file methods declaration
      aliases. World tests stay 150 (system 30, render 48, edit 37, worldgen 6,
      the moved files 29).
- [x] `docs/architecture.md` § Source Layout lists the new files and the
      split-file alias pattern (docs commit).

### Acceptance checks

- [x] `zig build verify` passes before and after each move, and the full test
      count is unchanged: 1741/1741 at the baseline and at `1caabf4`,
      `e6c314b`, `92df3dc`, `b45dd15` (fresh cache from `e6c314b` on);
      `7f2cfa9` ran check, idiom-lint, and the full suite (1741/1741); the
      full suite at `5aec1ce` is 1741/1741.
- [x] Bench `--details` outputs of the world and chunk-scale groups are
      identical apart from timings (`b45dd15`, against the pre-move baseline):
      every workload field matches for `chunk-scale-dig`,
      `chunk-scale-cave-in`, `chunk-scale-gpu-sync-dig`,
      `render-sparse-window-frame`, and `render-game-prep-dense-surface`; only
      scheduler/tuner fields differ, by as much as two runs of one tree.
