## Slice 77: Explosions

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 64G](slice-64g.md), [Slice 76](slice-76.md) · Track: [Gameplay direction](../tracks/gameplay-direction.md)

**Status: not started.** Owner direction 2026-10-09: explosions belong to
the destructible controller.

Goal: an explosion destroys terrain in a region, across chunks and levels,
in one step, and hits the entities in it. It is never refused; the support
it removes feeds Slice 76's collapses; nav, perception, and render pick it
up the same step.

### Current foundation

- `DestructibleController` (`src/game/destructible_controller.zig`) consumes
  `action_intents` (interact/attack) into deferred destructible damage and
  destroy commands; it touches no terrain.
- Dense one-step terrain edits exist (64G S3b):
  `WorldSystem.applyDenseCellWrites`, chunk-major, threaded, serial equals
  threaded, OOM changes nothing. `chunk-scale-explosion-fill` times a disk
  region at 4, 64, and 256 chunks; no gameplay calls it.
- The demo's crates (`game_demo_state.zig`, `setDestructible` with one hit
  point) break on interact/attack with a small particle puff
  (`destroy_burst_*`, `destructible_controller.zig`): no area, no terrain
  damage, no effect on neighbours. Nothing produces an explosion today.

### Architecture notes

- Owner: `DestructibleController` (`.claude/rules/simulation.md` §
  Controllers and processors); entity hits go through deferred structural
  commands, never direct store mutation.
- Region cost follows the region, never level size, depth, or world count;
  terrain writes go through the dense path on the thread system
  (`.claude/rules/engine-design.md`, `.claude/rules/threading.md`).
- Never refused for capacity (`.claude/rules/budgets-capacities.md`);
  deterministic (`.claude/rules/simulation.md` § Determinism).

### Checklist

- [ ] What sets an explosion off and its shape (radius, falloff, which
      tiles and entities it affects) as content, confirmed by the owner
      before code.
      First source: explosive crates in the demo.
- [ ] Explosion terrain written through the dense path, multi-level when the
      content says so; its removed support handed to Slice 76's collapse
      stage.
- [ ] Entities in the region hit through deferred commands; required events
      reserved before the step.
- [ ] Downstream reactions take an explosion without a per-cell event cap.
- [ ] Tests: serial equals threaded; OOM leaves terrain and entities intact
      and the retry gives the same result; an explosion spanning chunks and
      levels; an explosion that triggers a collapse.
- [ ] `chunk-scale-explosion-*` benches through the controller: flat across
      level size and depth, linear in the region.

### Acceptance checks

- [ ] Manual (display, Debug): an explosion in the demo breaks terrain and
      nearby destructibles; NPCs route over the result.
- [ ] `zig build verify` passes.
