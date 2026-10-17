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
| AI stage | ~0.15–0.20 ms |
| perception stage | ~0.16–0.20 ms |
| pathfinding avg (steady) | ~0.05–0.06 ms |
| cognition selected / observers (per step) | ~330 / ~140 |
| movers (per step) | ~2000–2050 |

Known costs inside the band: the full agent snapshot each cognition step
(~0.33 ms) and the avoidance batch (~0.40 ms; [Slice 85](slices/slice-85.md)).

