## Slice 76: Cave-Ins

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 64G](slice-64g.md) · Track: [Gameplay direction](../tracks/gameplay-direction.md)

**Status: not started.** Owner direction 2026-10-09: cave-ins are a dig
mechanic owned by the dig controller.

Goal: digging out too much support makes the ground above collapse. A
collapse is ordinary colony-sim gameplay: it can span many chunks and
several levels in one step, it is never refused, and nav, perception, and
render pick it up the same step as any other terrain change.

### Current foundation

- `DigController` (`src/game/dig_controller.zig`) owns dig intents → world
  tile edits: one dig reserves once (`reserveWorldEdit`) and commits
  (`commitWorldEdit`); falls carve their landing cell. No support or
  collapse rule exists.
- Dense one-step terrain edits exist on the engine side (64G S3b):
  `WorldSystem.applyDenseCellWrites` takes chunk-major writes, plans and
  writes per chunk on the thread system, serial equals threaded, and OOM
  changes nothing. Benches `chunk-scale-cave-in` and
  `chunk-scale-explosion-fill` time it at 4, 64, and 256 chunks; nothing in
  gameplay calls it yet.
- The dense path emits one `WorldTileChangedEvent` per changed cell, so a
  large collapse can exceed a fixed per-step event capacity.

### Architecture notes

- Owner: `DigController`, a pipeline-owned controller
  (`.claude/rules/simulation.md` § Controllers and processors); no new
  pipeline stage unless its resource contract needs one.
- A dig evaluates support only in the chunks it touched and their
  neighbours; cost follows what changed, never level size, depth, or world
  count (`.claude/rules/engine-design.md`,
  `.claude/rules/budgets-capacities.md`).
- A collapse writes through `applyDenseCellWrites`; scalable support
  evaluation runs on the thread system with serial and threaded paths
  (`.claude/rules/threading.md`). Results are deterministic
  (`.claude/rules/simulation.md` § Determinism).
- Never refused for capacity; over-budget evaluation defers
  deterministically (`.claude/rules/budgets-capacities.md`).
- Collapses keep advancing in every world and at any distance from the
  observer (`.claude/rules/engine-design.md` § Target scale).

### Checklist

- [ ] Support rule: what holds the ground up and when it gives way, stated
      as tunable content, confirmed by the owner before code.
- [ ] Support evaluated per dig over the touched chunks; a collapse written
      through the dense terrain path, multi-level when the rule says so.
- [ ] Downstream reactions take a collapse without a per-cell event cap:
      nav, perception, and render marks per chunk.
- [ ] Entities caught in a collapse are handled (the rule decides how).
- [ ] Tests: serial equals threaded; OOM leaves terrain intact and the
      retry gives the same result; a collapse spanning chunks and levels in
      one step; repeated dig/collapse/refill.
- [ ] `chunk-scale-*` collapse benches: support evaluation flat across level
      size and depth for a fixed dig, linear in the collapsed region.

### Acceptance checks

- [ ] Manual (display, Debug): a cave-in in the demo from digging; NPCs
      route around or through the result.
- [ ] `zig build verify` passes.
