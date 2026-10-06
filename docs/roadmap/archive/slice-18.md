## Slice 18: Frame-Delayed Pathfinding System

**Status: landed (historical).** Superseded nav core in Slice 25; contract retained.

> Note (superseded core): Slice 25 replaced the goal-field-centric core described
> below. The opportunistic per-step auto-grouped goal fields, the open-grid direct
> path / portal-detour fast paths, and the start-cell-in-key model are gone. The
> frame-delayed request/result contract, fixed-capacity caches, deterministic
> deferral, and adaptive thread scheduling remain. Read the Slice 25 section and
> `docs/architecture.md` for the as-built solver (per-agent budgeted A* + managed
> shared-goal flow field + chunk-portal abstract/cross-level tier). This slice is
> retained as historical record.

Goal: add a state-owned, frame-delayed grid pathfinding system so AI and rule
processors can request navigation without blocking current-step movement or
storing solver queues, caches, or scratch data in `DataSystem`.

Current foundation:

- Slice 12 provides typed transient streams and deterministic merge points
  through `SimulationFrame`.
- Slice 14 provides AI processors that can emit movement intent and consume
  later-step navigation results without owning solver state.
- `PathfindingSystem` lives under `src/game/systems/` as a system, not a
  controller. It owns a static versioned nav grid, pending request queue,
  request dedupe, completed result cache, unavailable-path cache, connected
  components, portal data, warmed fixed scratch buffers, shared goal fields, and
  per-stage adaptive tuners.
- `SimulationFrame.path_requests` carries transient path requests from AI to the
  pathfinder. Results are frame-delayed so AI consumes completed paths on later
  fixed steps instead of blocking current-step movement on fresh solves.
- Common requests avoid heap A* through request/result caches, unavailable-key
  caches, shared goal fields, open-grid direct paths, disconnected-component
  rejection, line-of-sight paths, and portal detours.
- Regular batch work uses `src/core/simd.zig` for request key preparation and
  static-grid blocked rectangle marking. Branch-heavy A* frontier expansion
  remains scalar inside worker ranges.
- Benchmarks split common-goal field reuse, hot cache-hit profiles, and hard
  fallback profiles. Cache profiles report `cache_hits`; hard fallback profiles
  report `fallback_requests` so regressions do not hide behind aggregate timing.

Architecture notes:

- Persistent gameplay facts stay in `DataSystem`; solver queues, caches,
  scratch buffers, nav-grid topology, and tuner state stay in the state-owned
  pathfinding system.
- Pathfinding uses read-only navigation snapshots during worker jobs and merges
  results deterministically before AI, movement, or response systems consume
  them.
- Adaptive tuning belongs to the actual work stage being measured. Shared goal
  field construction, fallback solves, and result emission should each either
  stay inline by design or use the tuner that measures that exact batch shape.
- Heap A* is a bounded fallback path, not the expected per-frame path for common
  requests. Hard true-A* fixtures and solve budgets remain a future hardening
  track.

Checklist:

- [x] Add typed path requests and completed path results through
      `SimulationFrame`.
- [x] Add a state-owned `PathfindingSystem` under `src/game/systems/` and wire
      it into fixed-step gameplay order after AI request emission.
- [x] Keep solver state, warmed scratch buffers, caches, and adaptive tuners out
      of `DataSystem`.
- [x] Add request/result cache hits, unavailable-path caching, request dedupe,
      and pending-request dedupe so repeat work stays cheap.
- [x] Add shared goal fields and regular-batch SIMD where the data shape is
      suitable.
- [x] Add fast paths for direct open-grid paths, unreachable component rejects,
      line-of-sight paths, and portal detours before heap A* fallback.
- [x] Add deterministic serial, fixed-thread, and adaptive benchmarks for common
      field reuse, hot cache-shaped workloads, and hard fallback workloads with
      visible cache/fallback counters.
- [x] Add tests covering deterministic results, cache behavior, no hot-loop heap
      allocation in steady-state paths, unavailable requests, and serial versus
      threaded consistency.

Acceptance checks:

- [x] AI can request paths without blocking the current fixed-step movement
      integration on a fresh solve.
- [x] Pathfinding is modeled as a gameplay system over typed data and transient
      requests, not as a persistent gameplay-state owner.
- [x] Repeated, unavailable, open-grid, detour, and shared-goal requests use
      cheaper paths before heap A*.
- [x] Adaptive and threaded runs are benchmarked against serial runs with
      fallback counters visible.
- [x] Debug and ReleaseFast 1024-request benchmarks cover open unique, detour,
      and unreachable fixtures; all report zero fallback requests for the fast
      fixtures after the fixture correction.
- [x] `zig build test --summary all`, `zig build check`, `zig build verify`, and
      `git diff --check` pass for the pathfinding implementation.

Slice 18 lands the navigation substrate. It gives AI and future rule systems a
deterministic, frame-delayed path request/result boundary with caches, fixed
scratch, SIMD-friendly batch work, and adaptive thread-system scheduling. It
does not by itself make NPC behavior immersive; steering, avoidance, perception,
and behavior arbitration remain the next gameplay layers.


