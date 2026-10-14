## Slice 82: Split The World Module

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 64G](slice-64g.md) · Track: standalone (engine core)

**Status: not started.** Owner direction 2026-10-09 (after 64G seals); its own
slice per owner 2026-10-14.

Goal: the world files move into `src/game/world/` (as `data_system/` is laid out)
and `world_system.zig` splits into files that each have one job a reader can hold,
with tests beside their code; behavior, orders, allocation, and determinism do not
change. The design pass decides the seams from the code as landed.

### Current foundation

Sizes at `dcdbea5` (lines):

| File | Lines |
| --- | --- |
| `game/world_system.zig` | 8,450 |
| `game/world_gpu_tiles.zig` | 1,198 |
| `game/world_terrain.zig` | 1,071 |
| `game/world_interest.zig` | 402 |
| `game/world_test_support.zig` | 131 |

- `world_terrain.zig` holds the one `ChunkGeometry` that terrain, nav, and static
  colliders share (`19256c5`).
- The 64G combined review (area C) named `world_system.zig` seams and routed the
  split after 64G.

### Architecture notes

- File moves and splits only: no behavior, order, layout, or allocation change;
  identical results, serial and threaded (`.claude/rules/simulation.md`
  § Determinism). World render state stays in `WorldSystem`'s render path
  (`.claude/rules/render.md`; `docs/architecture.md` § Source Layout).
- Tests stay beside the code they cover (`.claude/rules/tests-benchmarks.md`);
  shared fixtures stay in the world test support file.
- Imports are direct, with no bridge aliases (`.claude/rules/zig-style.md`).
- A seam is one a design pass finds in the code as landed, never a target line
  count.

### Checklist

- [ ] Design pass on the landed world files: the `world_system.zig` seams and
      the `src/game/world/` layout.
- [ ] World files moved under `src/game/world/` and `world_system.zig` split
      along those seams; importers updated directly.
- [ ] `docs/architecture.md` § Source Layout lists the new files.

### Acceptance checks

- [ ] `zig build verify` passes before and after each move, and the full test
      count is unchanged.
- [ ] Bench `--details` outputs of the world and chunk-scale groups are
      identical apart from timings.
