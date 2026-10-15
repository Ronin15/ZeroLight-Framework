## Slice 20: Navigation Hardening And Hard-Path Budgets

> Note (superseded core): Slice 25 supersedes the goal-field core and the
> opportunistic fast paths this slice hardened. The node-budget concept it
> introduced lives on as the per-agent A* `max_explored_nodes` budget and the
> abstract `max_abstract_nodes` budget; the budget-spill-returns-`pending`
> contract is unchanged. The auto-grouped goal fields it tuned are replaced by the
> declared managed shared-goal flow field. Retained as historical record.

Goal: keep rare true-A* and complex-map navigation costs bounded, tested, and
visible so pathfinding remains a stable gameplay foundation as map and NPC
counts grow.

Current foundation:

- Slice 18 benchmark profiles expose common fast paths and fallback counters.
- Pathfinding stats already distinguish field requests, cache hits,
  unavailable-path cache hits, and fallback requests.
- `PathfindingSystem` keeps solver queues, result caches, unavailable-key state,
  goal fields, scratch, and tuners out of `DataSystem`.

Architecture notes:

- Benchmarks should distinguish common-path throughput from true hard-path
  fallback costs. A slow fallback should be treated as a visible budget decision,
  not hidden by aggregate adaptive numbers.
- Solve budgets should prefer deterministic deferral over unbounded same-frame
  work. If the pathfinder cannot finish all fallback work inside the budget, it
  should report pending work explicitly.
- The current per-step solve and hard-fallback budgets default to 128 requests.
  This is a ReleaseFast-tuned crowd baseline: a 2000 hard-request pressure run
  solves 128 and reports the remaining backlog instead of stalling the fixed
  update.
- Slice 20 intentionally keeps cache aging, incremental A* continuation, module
  splitting, and pipeline extraction out of scope. The completed feature is the
  bounded hard-path contract, fixed-capacity cache coverage, and benchmark
  visibility.

Checklist:

- [x] Add true-A*-required fixtures that cannot be solved by direct, field,
      component, or portal fast paths.
- [x] Add per-frame fallback solve budgets and deterministic pending/deferred
      behavior for overflow work.
- [x] Add completed-result, entity-result, unavailable-key, and goal-field
      fixed-capacity tests.
- [x] Add benchmark callouts for Debug and ReleaseFast hard-path throughput and
      budget-pressure workloads.
- [x] Audit heap use and scratch sizing for worst-case fallback fixtures through
      warmed no-allocation hard-path tests.
- [x] Keep pathfinding as a gameplay system; do not split modules or promote it
      into a controller as part of this slice.

Acceptance checks:

- [x] Benchmarks report true fallback count, deferred budget pressure, and
      timing separately from fast-path work.
- [x] Unreachable or impossible destinations are rejected once and cached rather
      than re-solved every frame.
- [x] Fallback overflow defers deterministically instead of stalling the fixed
      update.
- [x] Hard-path changes cannot silently regress common request throughput because
      benchmark detail rows expose fallback, deferred, result, and eviction
      counters.
- [x] `zig build fmt`, `zig build test --summary all`, `zig build check`,
      `zig build verify`, and targeted Debug/ReleaseFast pathfinding benchmarks
      pass.

Slice 20 lands navigation hardening as a complete foundation feature. True A*
fallback work now has a separate per-step request budget, budget overflow stays
pending in stable order, cache capacity behavior is tested, and hard-fallback
benchmarks expose executed fallback work, deferred fallback work, remaining
pending work, results, and cache evictions across raw-throughput and
budget-pressure groups. The runtime defaults allow 128 true fallback solves per
step, with `--fallback-budget` available for ReleaseFast tuning sweeps.


