## Scaling Gaps

> [Roadmap index](../framework-implementation-slices.md)

> **Scaling Gaps holds only measured pressure points awaiting a benchmark.**
> Unplanned or deferred work goes into a numbered slice file under
> [`slices/`](slices/) (a new slice or added Checklist items), never here.
> When a point gets its benchmark and an owner, it moves to that slice and
> leaves this file.

Measure with `zig build bench` and scope stats before raising entity counts,
world depth, or cognition scope.

### Battle-scale perf watch (2048 movers)

ReleaseSafe dumps are diagnostic trend data, never a perf claim
(`.claude/rules/tests-benchmarks.md`); they are captured and re-baselined per
[Slice 68A](slices/slice-68a.md) §3. If stage lines move while selected and
observer counts hold, suspect new code; if those counts jump, suspect scope
density.

**ReleaseSafe control baseline (post-load, ~60 s, 2048 movers)**

| Metric | Control band |
| --- | --- |
| gameplay avg | 1.6–1.9 ms |
| frame (present-bound) | ~8.3 ms (~120 FPS); cap_hits 0–1 |
| steering stage | ~0.65–0.70 ms |
| steering select / snapshot / directions | ~0.03 / ~0.33–0.34 / ~0.17–0.20 ms |
| steering batch | ~0.40 ms |
| collision stage | ~0.21 ms |
| collision gather / sort | ~0.09 / ~0.02 ms |
| AI stage | ~0.15–0.20 ms |
| perception stage | ~0.16–0.20 ms |
| pathfinding avg (steady) | ~0.05–0.06 ms |
| cognition selected / observers (per step) | ~330 / ~140 |
| movers (per step) | ~2000–2050 |

Known costs inside the band: the full agent snapshot each cognition step
(~0.33 ms), the avoidance batch (~0.40 ms; [Slice 35](slices/slice-35.md)),
and the collision gather (~0.09 ms).

- [ ] **Collision full-sort under melee density.** Mid-pack soaks saw
      `full_sorts` jump (1 → 24) while the stage held ~0.21 ms and the
      broadphase batch ~0.09 ms. A melee-density `collision` case with
      `collision_setup` gather/sort timings and `full_sort_disorder_percent`
      decides whether that is expected disorder or a retune; SAP order never
      changes without measured parity. (`collision.zig`)
- [ ] **AI separation density.** Separation samples rise 2–3× running through
      the pack and scale with cognition density. The `ai_separation` batch
      line separates gather from math; Slice 55 removes queries for coasting
      rows and Slice 35 owns the per-row math. Candidate and sample caps stay
      fixed. (`ai.zig`)
- [ ] **Path group fields and cache pressure.** At 2048 movers
      `group_built = 0` because the demo pins `min_group_field_agents = 2000`
      after measuring that pending dedup and the cache serve shared-goal
      bursts; eviction runs ~20k/min. Re-measure eviction and group payoff
      when simultaneous same-goal demand exists; shared-goal prewarm is
      [Slice 71B](slices/slice-71b.md) (71B.3). (`game_demo_state.zig`,
      pathfinding capacity)
- [ ] **Perception tail.** Stage avg ~0.16 ms, max ~2.4 ms. Bench a denser
      observer case before touching the gather; the FOV path is partly SIMD.
      (`perception.zig`)
