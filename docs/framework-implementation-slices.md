# Framework Implementation Slices

This roadmap is the agent implementation contract for the project frontier. Work
is organized as **numbered slices**: each slice is one complete, verifiable
feature chunk with a **Goal**, **Checklist**, and **Acceptance checks**. Agents
implement by opening a slice section, checking items off only when integrated,
and running `zig build verify` before marking the slice complete.

Slices 0–7 and 9–17 are settled in
[framework-implementation-slices-archive.md](framework-implementation-slices-archive.md).
This file owns slices 8 and 18 onward.

## Ground Rules

- Preserve runnable defaults: `zig build`, `zig build run`, and installed assets
  should keep working after every slice.
- **A slice is not complete until every Checklist and Acceptance check in that
  slice section is `[x]`** and runtime behavior, owning-module docs, and tests
  are integrated. Partial wiring stays `[ ]` with explicit remaining notes in the
  slice section — never implied complete elsewhere.
- Keep hot paths simple: prefer enums, bitsets, arrays, and generational slot IDs
  over dynamic dispatch, string lookup, or hash maps during input/update/draw.
- If a dependent system does not exist yet, label the work as foundation or
  preparation and leave the slice checklist incomplete.
- Avoid half-wired states; either finish the slice end to end or keep every open
  item visible in that slice's Checklist or Acceptance checks.
- Keep `src/root.zig` minimal; feature modules should live in their matching
  `src/` area and import each other directly when needed.
- Read [architecture.md](architecture.md) and the owning live modules before
  editing; code wins over stale slice prose when they disagree.
- Run `zig build verify` before considering a slice complete.

## Agent Workflow: Implementing A Slice

1. **Pick a slice** from **Open Frontier Slice Index** (below) or **Suggested
   Order** when dependencies matter. Confirm prerequisites are `[x]` in their slice
   sections.
2. **Open the slice section** (`## Slice N: …`). Read **Goal**, **Current
   foundation**, and **Architecture notes**; cross-read [architecture.md](architecture.md)
   and any doc linked in the slice.
3. **Implement only that slice's scope** in the owning `src/` modules. Do not
   expand into unrelated refactors.
4. **Check off items** in the slice **Checklist** as each integration lands (runtime
   behavior + tests for that item).
5. **Satisfy Acceptance checks** — each must pass before the slice is done.
6. **Update durable docs** the slice touches (`architecture.md`, rendering/sim
   docs) when contracts change.
7. **Set slice Status** (if present) and run `zig build verify`.
8. **Scaling Gaps** items are backlog until promoted into a numbered slice's
   Checklist. Do not treat Scaling Gaps checkboxes as a substitute slice.

### Standard slice section shape

Every frontier slice section should contain (some fields optional for early
foundation slices):

| Block | Agent use |
| --- | --- |
| **Goal** | What "done" means for this chunk |
| **Current foundation** | What already exists — do not rebuild |
| **Architecture notes** / **Problem** | Constraints and ownership boundaries |
| **Checklist** | `[ ]` / `[x]` implementation steps — check off as you land each |
| **Acceptance checks** | `[ ]` / `[x]` verification gates — all required before complete |
| **Status** | Landed slices: one-line completion record |

Landed slices keep their sections as historical acceptance records; do not delete
checklists after completion.

## Open Frontier Slice Index

Use this index to choose the next slice; **implement from that slice's section**
(checklists live there, not here).

| Slice | Status | Open work (see slice section for full Checklist) |
| --- | --- | --- |
| **24 / 24B** | Landed | Render collect hardening — acceptance history; follow-up in Scaling Gaps |
| **23A** | Partial | Landed on `expand2`; merge to `world` remains backlog |
| **25E** | Landed | Per-entity depth alignment + demo 32L/32E validation |
| **26–28** | Landed | Entity faction/classification, deterministic per-entity RNG, shared spatial index — see **Emergent AI Track Overview** |
| **29** | Landed | AI Perception Substrate — vision and hearing (component/system/events), LOS-cost risk closed, LOS diagonal-tunneling correctness fix, caller-sized event budget (see slice section) |
| **30–33** | Not started | AI memory, affect, behavior arbitration, data-driven archetypes/debug — see **Emergent AI Track Overview** then each slice |
| **34** | Landed | Core SIMD primitive layer + dense-path wins; sin/cos polynomial deferred to Slice 29 |
| **35** | Not started | AI/steering hot-loop SIMD restructure — Checklist open |

**Landed slice sections (18–25, 24B):** checklists complete; sections are
acceptance history. Follow-up hardening without a new slice number lives in
**Scaling Gaps And Hardening Frontier** until promoted to a slice Checklist.

**Bench policy:** 50k bench scales are throughput ceilings, not per-frame targets.

## Next Priority Tracks

Sequencing hints only — **does not replace slice Checklists**. When in doubt,
follow **Suggested Order** and the open items in the target slice section.

- Close open **Slice 23A** and **25E** Checklists before raising world
  depth count or starting **Slices 26–33**.
- Widen `ComponentMask` before the emergent-AI track — schedule as its own slice
  or checklist block when picked up (see Scaling Gaps).
- Guard CPU paths with existing benches; keep SDL_GPU submit on the render thread.
- Hardening without a slice number: collision-response merge, `SpriteBatch`
  capacity, text-cache lifetime (track when scheduled as slices).
- Reuse state-owned `SimulationPipeline`; persistent data in `DataSystem`;
  structural changes through `SimulationFrame`.

## Scaling Gaps And Hardening Frontier

**Backlog, not a slice.** Items here are architectural pressure points waiting
to be **promoted into a numbered slice** (new section or added Checklist items).
Agents implement only from slice **Checklist** / **Acceptance checks**; use this
section for planning and to avoid duplicating gap lists inside landed slice
sections. When work starts, copy items into a slice Checklist and check off there.

Measure with `zig build bench` and scope stats before raising entity counts,
world depth, or cognition-track scope.

**Policy boundaries (settled — do not regress)**

- Simulation LOD (tier, halos, stagger, scope gathers) controls fixed-step
  processor participation only.
- Render visibility (camera chunk window, pixel AABB, render overscan margin)
  controls draw-record construction only.
- Scope pin metadata may keep an entity in a higher sim band off-camera; it must
  not bypass render visibility.

**Simulation scale**

- [ ] **Movement contiguous-path vs scoped LOD.** Any dormant movement row
      disables the contiguous SIMD movement fast path for the whole step. At
      steady-state LOD with routine off-camera sleepers, revisit compacted-dense
      movement iteration or a dormant-fraction threshold (Slice 24 follow-up).
- [ ] **Per-entity depth axis.** Multi-floor entities need one level column
      aligned across scope cube LOD, navigation queries, and render cull —
      separate from the dense-floor vertical render window (Slice 25E).
- [ ] **Component storage headroom.** Widen `ComponentMask` before the
      cognition/AI track adds more component slots (see Next Priority Tracks).
- [ ] **Multi-world scope policy.** Inactive world instances stay out of
      pipeline scope; the active world uses chunk + halo rules (Slice 22
      deferred).

**Render scale**

- [ ] **Dynamic collect scan cost.** Collect walks every movement-body row;
      camera gates skip draw prep but not the scan. Hardening: warmed visible
      movement dense-index list parallel to scoped simulation gathers (Slice 22
      handoff; partial inline gating landed in 24B).
- [ ] **Dense floor submit vs camera.** The vertical render window bounds layer
      count; each in-window layer still submits one full-world tilemap quad (GPU
      clips). Hardening: chunked dense submit if layer-quad cost dominates
      (Slice 23B follow-up).
- [ ] **On-screen record ordering.** `finalizeDepthBuckets` sorts collected
      dynamic records; replace with fixed-band or counting buckets when on-screen
      density rises (Slice 24B follow-up).
- [ ] **Bench phase isolation.** Split `render-game-prep` collect vs sparse/dynamic
      emit timers so regressions name the hot phase (Slice 24B follow-up).

**Sequencing guardrails**

- Raise entity stress counts and world depth only after `validateDenseRenderBudget`
  passes and scope stats show typical participation stays below bench ceilings.
- Land per-entity depth alignment (25E) before multi-floor gameplay scenarios that
  depend on cross-level entity presence.
- Land scoped cognition gating (24) and component widening before scaling the
  emergent-AI track (26–33).

## Long-Term Gameplay Direction

Future features land as slices: state-owned pipeline or feature controllers for
orchestration, SoA processors for hot data, typed `SimulationFrame` outputs,
deferred structural commits. Controllers own phase order, budgets, and handoff;
processors stay dumb; persistent facts stay in `DataSystem` / `WorldSystem`.
Simulation scope filters which rows enter each stage without changing processor
math. New gameplay domains should add a slice section (Goal, Checklist,
Acceptance) before implementation. Durable boundaries:
[architecture.md](architecture.md); emergent-AI shared contracts: **Emergent AI
Track Overview** below.

## Completed Foundation Slices (0–7, 9–17)

Slices 0–7 and 9–17 are complete and settled. Their full checklists and
acceptance records moved to
[framework-implementation-slices-archive.md](framework-implementation-slices-archive.md)
to keep this roadmap focused on the frontier. Slice 8 stays below because it has
residual shader/material hardening items (also tracked under "Next Priority
Tracks" above). The full dependency-ordered slice list (0–35) remains in
"Suggested Order" below.

## Frontier Slice Records (8, 18+)

**Agent source of truth for implementation.** Each `## Slice N` block is a
complete work chunk: read **Goal** → check off **Checklist** items → pass
**Acceptance checks** → update **Status**. Use **Open Frontier Slice Index** to
choose N. Landed slices keep their sections as verified records.

## Slice 8: Shader And Platform Expansion

**Status: landed.** All Checklist and Acceptance checks below are `[x]`.

Goal: keep platform support reliable as shader count and target platforms grow.

Current foundation:

- SDL chooses the GPU backend from supplied shader formats.
- Linux builds SPIR-V, macOS builds MSL, and Windows builds DXIL.
- Runtime selects shader files from SDL-reported supported formats.
- Build metadata and runtime pipeline metadata are still updated in separate
  places until a shared shader/material manifest exists.

Architecture notes:

- Shader expansion should add render-owned material/pipeline metadata; it should
  not push shader, pipeline, or SDL_GPU handles into `DataSystem` or gameplay
  state.
- Lighting, fire, post-effect, and tile shaders should keep draw intent as
  stable asset/material IDs plus typed render order until render prep resolves
  them into queue records or a render-owned batcher stream.
- New batchers may be added for tile spans, light volumes, or effect particles,
  but they should consume an explicitly ordered stream or a documented
  render-owned phase with the same ordering guarantees. Do not add renderer
  fallback sorting to hide unordered producers.
- Build-time shader manifests and runtime pipeline registries should converge so
  adding a material does not require unrelated parallel edits.

Checklist:

- [x] Keep generated runtime shader files under `assets/shaders` in the install
      tree.
- [x] Add explicit Windows target output through DXIL.
- [x] Keep runtime backend selection SDL-driven; do not hard-code GPU driver names.
- [x] Consolidate shader-program, material, and runtime pipeline metadata so
      new pipelines do not need parallel registry edits.
- [x] Define the material/batcher routing contract for sprites, tile spans,
      lighting/fire effects, and post-effect passes without exposing SDL_GPU
      handles to game code.
- [x] Validate the right shader format list for each target OS.
- [x] Add direct runtime asset/shader lookup guidance or tests for direct binary
      execution outside the installed binary directory.
- [x] Add shader output checks for each supported target path.

Acceptance checks:

- [x] `zig build shaders` emits the same sprite shader outputs as before.
- [x] `zig build verify` exercises shader compilation.
- [x] `zig build gpu-smoke` confirms runtime submission on display-capable hosts.

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

## Slice 19: Steering And Local Avoidance

Goal: turn pathfinding results into smoother NPC movement by adding local
steering, avoidance, and stuck/replan policy above the pathfinder without moving
that transient behavior into `DataSystem`.

Current foundation:

- Slice 14 AI processing provides deterministic AI decision output; Slice 19
  routes that output through navigation intents before final steering movement.
- Slice 18 pathfinding can provide frame-delayed path waypoints and unavailable
  results.
- Slice 13 collision contacts and spatial-query foundations provide the data
  shape needed for local crowd and obstacle decisions.
- `SteeringSystem` consumes high-level navigation intents, pathfinding status,
  dense steering components, movement slices, and static obstacle data, then
  emits final NPC movement intents through deterministic threaded range writes
  after main-thread path/status preparation.

Architecture notes:

- Steering should be a system or state-owned feature controller that consumes
  path results and typed SoA views, then emits movement intents or rule outputs.
- Persistent tuning data such as agent radius, desired speed, or avoidance class
  may live in dense `DataSystem` components. Per-step neighbor lists, waypoint
  cursors, avoidance scratch, and replan queues should stay transient or
  state-owned.
- Avoidance and steering benchmarks should measure the processor cost directly
  rather than masking it behind the pathfinding benchmark.

Checklist:

- [x] Add path-following state needed to turn completed paths into movement
      intents.
- [x] Add local obstacle and agent avoidance using bounded fixed scratch.
- [x] Add stuck detection, replan cooldowns, and unavailable-path backoff.
- [x] Define arbitration between player input, AI steering, collision response,
      and future rule outputs.
- [x] Add deterministic tests for waypoint following, avoidance ordering, replan
      backoff, and no steady-state hot-loop allocation.
- [x] Add steering/local-avoidance benchmarks that report agent count, bounded
      avoidance checks, accepted samples, intents emitted, and threaded/adaptive
      detail where used.

Acceptance checks:

- [x] NPCs can follow path waypoints without sharp frame-to-frame oscillation.
- [x] Nearby NPCs and static obstacles are avoided through bounded local work.
- [x] Unavailable or stale paths do not cause per-frame re-request loops.
- [x] Steering outputs compose through typed movement intents or rule outputs
      with deterministic order.
- [x] `zig build fmt`, `zig build test`, `zig build check`, `zig build verify`,
      and `zig build bench -- --profile quick --group steering --details` pass.

Slice 19 lands steering as a separate gameplay processor. AI now emits
`NavigationIntent` goals, `SteeringSystem` owns runtime steering rows,
path-request cooldown/backoff, local avoidance scratch, deterministic priority
arbitration, and threaded final movement-intent emission. Only the steering
stage writes final NPC `MovementIntent`s. Player movement remains direct input,
and collision response still resolves after movement.

**Hardening follow-up (post-Slice 27, no new slice number):** chasing a moving
goal (the player) produced a visible NPC direction wiggle — a discrete flip in
the chosen base direction (path-following vs. direct-fallback toggling while a
goal-cell requantization is in flight, a fresh corridor replacing a stale
waypoint, or a wander-epoch change) snapped the heading in one step instead of
turning smoothly. `RuntimeRow` gained `prev_dir_x/y`/`has_prev_dir`, and
`smoothBaseDirection` (steering.zig) blends the previous emitted direction
toward the new target by `steering_turn_smoothing = 0.15` per fixed step
(~10 steps to mostly converge at 60Hz) before it reaches
`SelectedWorkRow.base_dir`. The first direction observed for a runtime row is
used as-is (no startup lag). Benchmarked before/after on `zig build bench --
group steering` at 128/512/1024 agents: no measurable regression (differences
within normal run-to-run noise).

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

## Slice 21: Typed Simulation Event System And Domain Signals

Goal: add a deterministic, typed simulation event layer that lets future
gameplay/domain systems communicate important system changes and interactions,
including tile, pathfinding, AI, obstacle, weather, combat, spawning, rules, and
resource changes, without introducing a global pub/sub bus, hidden persistent
state, or hot-path dynamic dispatch.

Current foundation:

- Slice 12 already provides `SimulationFrame`, typed transient streams,
  `RangeOutputStream(T)`, deterministic range-index merge, and deferred
  structural command boundaries.
- Collision, AI, steering, and pathfinding already use specialized typed
  streams for high-volume or latency-sensitive outputs: contacts, navigation
  intents, movement intents, path requests, and structural commands.
- `SimulationEvents` now owns lower-volume typed domain-signal records inside
  `SimulationFrame`, with deterministic range-owned writes, immutable merged
  reads, explicit per-step event capacity, event stats, and dropped diagnostic
  counts.
- `GameDemoState` consumes structural events after the deferred commit point and
  emits navigation invalidation when static obstacle-affecting structural
  changes require a pathfinding grid rebuild.
- `DataSystem` is the persistent gameplay-fact owner; transient event, request,
  scratch, queue, and service state stay outside persistent component storage.
  `DataSystem` remains the single source for applying structural commands and
  reports plain structural change records that `SimulationFrame` maps into
  events after the commit succeeds.

Architecture notes:

- Map this feature to the intended simulation structure explicitly:
  `StateStack` dispatches states; a gameplay state owns `DataSystem`,
  `SimulationFrame`, and, when shared orchestration is needed, a
  `SimulationPipeline`; the pipeline owns event phases and domain-controller
  order; controllers consume typed event slices and decide reactions;
  processors do hot SoA work and emit typed outputs; `DataSystem` stores
  persistent facts; `SimulationFrame` stores this-step communication.
- Use events to communicate that something important changed or that a later
  stage should consider a request. Use `DataSystem` to store what remains true
  after the step. Use controllers to decide how domains react. Use processors
  for scalable data work. Use deferred commands for structural mutation.
- The event layer is state-owned through `SimulationFrame` for one gameplay
  state instance. A future `SimulationPipeline` can own event reaction order
  without changing event storage or producer APIs. The event layer is not an app
  service, global singleton, reflection system, string-topic dispatcher,
  callback chain, or dynamic dependency graph.
- Events communicate domain or system changes that happened this step, or
  requests that a later fixed stage should consider. Persistent facts such as
  tile state, obstacle occupancy, weather fields, faction state, resources,
  actor components, or long-lived rule state still live in `DataSystem` or
  state-owned domain storage.
- The first concrete payloads are structural lifecycle/component change signals
  and `NavRegionInvalidated`. Add later domain payloads as explicit union
  variants with focused emit/read tests; do not add placeholder systems for
  domains that do not exist yet.
- Keep existing high-volume streams specialized. Collision contacts, movement
  intents, navigation intents, path requests, and render-prep command streams
  should not be collapsed into one generic simulation-event stream just for
  uniformity. Events may invalidate or wake a render producer, but render prep
  still emits explicit ordered commands with typed `RenderOrder`.
- Threaded producers must use the same count/prefix/write/range-index merge
  model as other `SimulationFrame` streams. Output order must come from stable
  phase, input, range, and per-range sequence order, not worker timing.
- Event consumers run at explicit reaction points after a producer stage has
  finished and the stream has merged. Consumers own their reaction work instead
  of dumping it into a generic main-thread bucket: light orchestration may stay
  inline, while expensive reactions should split over immutable event slices and
  write their own range-owned outputs.
- Main-thread reaction work must name the ownership boundary it preserves, such
  as structural commit, SDL/GPU/audio ownership, state transition, asset
  loading, save/load streaming, renderer resource ownership, or measured light
  orchestration. This is a project-wide rule: do not move scalable work in any
  subsystem to the main thread simply to make ordering or testing easier.
- Avoid recursive event storms. If consuming one event emits more events, the
  design must name the next event phase or defer to the next fixed step instead
  of allowing unbounded immediate redispatch.
- Events must carry stable IDs, scalar data, enum tags, compact coordinates,
  and small value payloads only. Do not store pointers, renderer/audio/SDL
  handles, asset paths, loaded resources, allocators, or service references in
  event payloads.
- Production contracts in any subsystem must not gain test-only tags, marker
  fields, fake stages, fixture hooks, or testing-only service paths. Event,
  intent, structural-command, ID, component, render, asset, app, platform, and
  tool APIs should expose runtime concepts only. Tests should use private helper
  record types, local fixtures, test-only mocks, or real production payloads.
- Simulation-event diagnostics should expose counts by type and
  producer/controller stage. Logging individual events in hot paths is not
  acceptable outside targeted debug tooling.

Checklist:

- [x] Define `SimulationEvent` payloads for the first concrete cross-system
      signals: structural entity/component changes and navigation invalidation.
- [x] Add a state-owned event collection API under the simulation/pipeline
      boundary, reusing `RangeOutputStream` or an equivalent typed
      count/prefix/write collector.
- [x] Define event phases, producer-stage merge points, explicit reaction
      points, derived-event policy, and no-recursive-dispatch behavior.
- [x] Add domain-reaction integration for current gameplay state orchestration:
      structural events can trigger one nav-grid rebuild and a typed
      `NavRegionInvalidated` event without moving persistent facts out of
      `DataSystem`.
- [x] Add capacity and reserve policy for event channels, including behavior
      when a low-priority event channel exceeds its per-step budget. Required
      events preflight the configured event budget before structural mutation or
      domain-reaction side effects; diagnostic events drop and increment stats.
- [x] Add event stats with per-type counts, dropped/deferred counts where
      applicable, and stage/controller attribution for benchmarks or debug UI.
- [x] Document which cross-system communication should use simulation/domain
      events and which should remain a specialized stream such as contacts,
      movement intents, navigation intents, path requests, render-prep commands,
      or structural commands.
- [x] Document the architecture mapping for event producers and consumers:
      pipeline phase, controller owner, persistent data owner, transient event
      stream, processor outputs, and deferred mutation point.

Acceptance checks:

- [x] Replaying the same initial `DataSystem`, controller state, fixed-step
      inputs, and worker split decisions produces the same event order and same
      downstream outputs.
- [x] Threaded producers merge events deterministically by stable range order,
      never by worker completion order.
- [x] Event consumption cannot mutate `DataSystem` structurally except through
      deferred structural commands applied at the pipeline commit point.
- [x] Event payload tests reject or avoid pointers, app/render/audio handles,
      asset paths, allocator references, and other non-stable runtime state.
- [x] Capacity tests cover reserve, appended and range-owned overflow,
      diagnostic drop policy, structural preflight before mutation, and
      no-allocation warmed event production.
- [x] Event stats expose counts by type/stage and dropped diagnostic counts so
      current structural and navigation interactions do not become invisible
      fixed-step cost.
- [x] Production contracts contain only runtime payloads; tests use private
      fixtures, test-only mocks, or real payloads instead of leaking testing
      markers into production enums/unions or service APIs.

Slice 21 lands the typed event infrastructure as a current runtime contract:
events are deterministic phase outputs inside `SimulationFrame`, threaded
producers use the same range-owned merge model as other streams, stats are
range-owned during production and merged deterministically, consumers run at
explicit reaction points, and high-volume streams remain specialized. The first
concrete domain reaction is navigation
invalidation from static obstacle-affecting structural changes.

## Slice 22: Simulation Pipeline And Tier/Scope Scaffolding

Goal: make `SimulationPipeline` the state-owned fixed-step simulation owner,
add the tier/scope scaffolding in its final ownership locations, and preserve
today's full active-set processor behavior. This is the architectural landing
zone for later scoped simulation, not the slice that turns on world/chunk tier
filtering.

Design source of truth:

- [architecture.md](architecture.md) for durable pipeline, controller,
  tier/scope, and ownership guidance.
- [simulation-tiers-and-pipeline.md](simulation-tiers-and-pipeline.md) for the
  current `SimulationFrame` streams, events, and structural-command contracts
  that the pipeline extraction must preserve.

Current foundation:

- Slice 12 provides `SimulationFrame`, `SimulationPhase`, typed streams, and
  deferred structural commits.
- `SimulationPipeline` owns reusable fixed-step simulation systems and today's
  ordered processor dispatch for one gameplay state instance.
- `GameDemoState.update` applies main-thread input/audio, delegates processor
  dispatch to `SimulationPipeline`, applies structural commits, and keeps
  dynamic render-prep scratch reserved for current primitive-visual rows.
- `GameDemoState.render` collects dynamic render records once, sorts them by
  world z, then merges them with visible world z layers. The player marker and
  particles are explicit render producers outside fixed-step simulation.
- Processors gather dense `DataSystem` slices and support threaded serial
  parity paths with benchmarks into the 50k stress scale.
- Architecture docs describe `SimulationPipeline` as the long-term owner of
  phase order, budgets, system ownership, and concrete domain-controller
  composition.

Architecture notes:

- Tiers are persistent membership; scope is per-step active filtering; the
  pipeline is one ordered stage list with gated inputs. Slice 22 defines those
  contracts, stores cold tier/chunk metadata, reports default full-active
  stats, and keeps runtime filtering deferred until world rendering and
  chunk/visibility data exist.
- Tier and chunk metadata stay on cold `EntitySlot` data, not hot movement SoA
  columns, unless profiling proves otherwise.
- Processors stay dumb: scoped gather entry points filter inputs without
  learning world/chunk/camera policy.
- Tier promotion/demotion commits at the deferred structural boundary or an
  explicit main-thread commit, not inside worker ranges.
- Slice 21 events/controllers are the long-term tier transition source; spatial
  chunk policy is the first concrete source after world rendering lands.
- Benchmark 50k counts prove spike absorption; typical gameplay should scope
  active cognition/collision far lower every frame.
- Render preparation remains a separate render-facing phase after fixed-step
  simulation data is ready. The pipeline can determine which entities are in
  active scope, visible scope, or dirty regions, but it should hand immutable
  slices and scope lists to render prep rather than calling `Renderer` or
  owning render-prep ordering.

Implementation context to preserve:

- This slice is still the planned pipeline + tier/scope architecture, not a
  reduced pipeline-only cleanup. It should scaffold `SimulationScope`,
  `SimulationTier`, `ActiveRegion`, cold tier/chunk metadata, full-active scope
  construction, and scope stats in the places where later scoped runtime
  behavior will hook in.
- The extraction makes the next implementation easier by moving system
  ownership, phase driving, and ordered processor dispatch behind a state-owned
  simulation owner. It should not erase the already-decided tier, scope,
  controller, render-handoff, or event-driven transition plan.
- Keep the current order visible while extracting it: main-thread inputs,
  AI navigation intent production, steering/path status consumption,
  pathfinding, sparse movement-intent application, movement integration,
  player bounds clamp, collision detection, collision response, particle/domain
  reactions, structural commit, and post-commit render-prep reservation.
- Scoped runtime behavior remains required after world rendering provides real
  tile/chunk/visibility data. The initial full-active-set pipeline and tier
  scaffolding are architectural stepping stones; they must not be documented as
  completed scoped tier behavior.

Checklist:

- [x] Add `src/game/simulation_pipeline.zig` with a state-owned
      `SimulationPipeline` that owns today's reusable systems and drives the
      ordered fixed-step sequence over `DataSystem` and `SimulationFrame`.
- [x] Change `GameDemoState` to own one `SimulationPipeline` and delegate the
      processor dispatch from `update` without changing behavior for the full
      active set.
- [x] Add `src/game/simulation_scope.zig` with `SimulationTier`, `ActiveRegion`,
      `SimulationScope`, full-active default construction, scope stats, and
      validation helpers.
- [x] Add cold tier/chunk metadata on `EntitySlot` or equivalent compact storage
      with default values that preserve today's behavior for all existing
      entities.
- [x] Keep player input, audio command emission, structural commit/domain
      reactions, render enqueue, and private clamp/sync helpers in
      `GameDemoState`, while interpolation sync delegates pipeline-owned
      movement history to `SimulationPipeline`.
- [x] Add full-set delegation/parity tests that prove the pipeline extraction
      preserves phase order, stream outputs, structural commit behavior, render
      queue reservation, and simulation stats.
- [x] Add tests proving tier/chunk metadata defaults, validation, and full-active
      scope construction do not change current simulation output.
- [x] Leave scoped processor filtering, stagger/reduced cadence, and real
      chunk/visibility gates disabled until the post-world-rendering scoped tier
      slice.

Post-22 deferred items (Slice 24 landed unless noted): open work is tracked in
**Scaling Gaps And Hardening Frontier** (visible-index handoff, multi-world scope).

- [x] Scoped gathers, stagger, scope stats, and architecture cross-links (Slice 24).
- [x] Inline camera gating at collect time (Slice 24B); warmed visible-index list
      remains open (Scaling Gaps — render scale).
- [ ] Multi-world scope policy and render-prep visible-index handoff (Scaling Gaps).

Acceptance checks:

- [x] `GameDemoState` delegates fixed-step processor dispatch to
      `SimulationPipeline` with no behavior change for today's full active set.
- [x] Tier/scope scaffolding exists in the final owner modules and storage
      locations, with default full-active behavior and validation tests.
- [x] Scope stats report the full-active counts without changing processor
      participation, adding per-frame logging, or adding benchmark timers to
      runtime rendering.
- [x] The slice does not claim scoped-tier completion: scoped gathers, stagger
      policy, real chunk gates, and tier transitions remain unchecked in this
      slice until world rendering supplies concrete world/chunk inputs.
- [x] `zig build test` covers pipeline phase transitions, full-active scope
      construction, metadata defaults, and no behavior change without opening a
      window.

**Status: landed (scaffolding).** `SimulationPipeline` owns fixed-step processor
orchestration; scoped runtime behavior landed in Slice 24. Scope metadata now
lives on movement-body dense columns (Slice 24), not cold `EntitySlot` fields as
originally sketched below — code is authoritative.

## Slice 23: Atlas-Backed World Rendering Addition

Goal: add a minimal world/tile rendering foundation that uses the existing
world tileset atlas metadata and render-prep boundary. This gives scoped
simulation concrete world, chunk, and visibility data to consume later.

Current foundation:

- Runtime assets preload atlas textures and metadata for `.world_tileset`,
  `.grim_characters`, and `.grim_items`.
- `world_tileset_meta.zig` validates tile JSON and exposes tile lookup by name,
  id, category, animation, and source rect.
- Explicit render-prep phases own transient draw-record ordering and `Renderer`
  owns SDL_GPU submission.

Architecture notes:

- World/tile state lives in the state-owned `WorldSystem`, not in renderer
  resources and not inside `SimulationPipeline`.
- `GameDemoState` is constructed from Engine-owned `RuntimeAssets` through a
  loading state; world construction requires `.world_tileset` metadata and
  world rendering requires the `.world_tileset` texture.
- The runtime loading path now uses the Engine-owned `ThreadSystem` for
  deterministic procedural chunk generation; it does not create a separate
  worker pool.
- Persistent world storage is SoA: stable tile IDs, atlas source-rect columns,
  level z metadata, dense/sparse tile columns, and chunk/visibility columns.
- Gameplay viewport size is separate from world size. The first large runtime
  world is a finite 512x512 tile segment with camera-visible chunk rendering,
  intended as a foundation for later larger-map streaming.
- The first world renderer exposes enough chunk/visibility shape for the later
  scoped tier slice, but it does not enable simulation tier filtering by itself.
- Demo actors can use character atlas entries with primitive-visual rectangle
  fallback; world tiles do not have a rectangle fallback path.

Checklist:

- [x] Add a small world/tile data owner with tile IDs, world coordinates, and
      chunk/visibility metadata suitable for later `ActiveRegion` construction.
- [x] Render at least one world/tile layer from `.world_tileset` atlas metadata
      through ordered render prep.
- [x] Keep tile draw ordering explicit by `RenderOrder` and stable source rects.
- [x] Add tests for tile lookup, strict missing atlas texture behavior,
      actor primitive fallback, and deterministic queue record order.
- [x] Add tests for ThreadSystem-driven procedural chunk generation,
      camera-follow world bounds, visible chunk culling, and world-tile
      pathfinding blockers.
- [x] Update rendering/assets docs and roadmap cross-links after runtime wiring
      lands.

Acceptance checks:

- [x] Demo/world rendering uses atlas metadata instead of per-tile textures or
      runtime string lookup.
- [x] World/chunk/visibility data exists in a form the later scoped tier slice
      can consume without ownership rewrites.
- [x] Render-prep benchmarks still measure the queue-to-batch path outside the
      production render path.
- [x] `zig build test`, `zig build check`, and `zig build verify` pass.

Slice 23 adds `WorldSystem` as `GameDemoState`-owned SoA world storage and
render prep. `LoadingState` now bridges menu activation to runtime-asset-backed
gameplay construction, fixing the old direct demo-state constructor boundary.
The demo renders a dense atlas-backed floor layer plus sparse world decoration
through ordered render prep, carries level/chunk/visibility columns for future
scoped simulation, and keeps `SimulationPipeline` focused on fixed-step entity
processors. Demo actors now reference `.grim_characters` atlas entries while
retaining primitive visuals as missing-character placeholders.
The runtime loading path now builds a 512x512 procedural segment with
`ThreadSystem` chunk batches, follows the player with an interpolated sub-pixel
camera, and renders only camera-visible chunks. World blocking tiles are folded
into the pathfinding nav-grid rebuild alongside static entity obstacles.

Follow-up slices **23A** (render hardening landed on `expand2`) and **23B**
(multi-depth render scaling for ~120 levels) extend this foundation; see below.

## Slice 23A: GPU Tilemap Render Hardening

Goal: harden Slice 23's retained GPU tilemap path for production digging and
multi-level compositing — correct depth ordering, safe partial tile uploads,
batched copy-pass staging, and pre-acquire CPU prep — without changing
simulation or `dig_controller` contracts.

Problem (observed on `expand2` before hardening):

- A linear `mergeDrawList` assumed static groups were pre-sorted by depth, but
  `submitStaticDenseGeometry` appended dense layers in storage order (surface
  first). That inverted underground compositing (grass/dirt flip, wrong plane
  visible through holes).
- Batched copy-pass staging passed `cycle=true` on the final upload when tile
  edits were the last work in the pass. Retained per-layer `GRAPHICS_STORAGE_READ`
  tile buffers require `cycle=false`; otherwise each dig ping-ponged GPU tile
  storage and flipped dirt/grass visually while CPU state stayed correct.
- Tile edits staged before swapchain acquire could be dropped on skipped frames
  when using clear-replace upload queues.

Current foundation (landed on `expand2`, runtime-validated):

- `mergeDrawList` stable-sorts static+dynamic groups by `RenderOrder` before
  coalescing; regression test covers unsorted underground dense depths.
- `submitStaticDenseGeometry` collects visible layers, sorts back-to-front by
  render depth at submit, and respects `active_level` (skip floors above the
  player). Re-submits on `dense_quads_dirty` or plane change only.
- `recordFrameCopyPass` batches dynamic vertices, optional static vertices, and
  tile edits in one copy pass; `uploadsRemainingCycle` counts **vertex** uploads
  only. Tile storage uses `recordStorageRegionsInPass` with **always
  `cycle=false`** and `MapGPUTransferBuffer(..., false)` for edit staging.
- `uploadTileDataEdits` appends pending edits (survives skipped frames); digs
  flush at the render boundary via `WorldSystem.flushDenseTileEdits`.
- Pre-acquire path: `prepareFrameCommands` / vertex staging before swapchain
  acquire; tile edits recorded after acquire in the frame copy pass (matches
  retained-buffer lifetime).
- `render_prep.submitGameplayFrame` owns layered world submit (static dense →
  tile-edit flush → sparse/dynamic z-walk); grow-only renderer reservations.

GPU upload `cycle` contract (do not regress):

| Resource | `cycle` on upload |
| --- | --- |
| Dynamic/static **vertex** ring streams | `true` on last vertex upload in the copy pass |
| **Tile-data storage** buffers (per-layer, retained) | **always `false`** |
| Tile-edit transfer buffer map | **`false`** |

Checklist:

- [x] Restore stable-sort `mergeDrawList` and add unsorted dense-layer regression
      test.
- [x] Sort dense layers back-to-front in `submitStaticDenseGeometry` before append.
- [x] Enforce `cycle=false` for all tile-storage uploads and tile-edit staging.
- [x] Exclude tile edits from vertex `uploadsRemainingCycle`; batch tile edits in
      the post-acquire copy pass.
- [x] Append pending tile edits across skipped frames; flush once per gameplay
      frame at the render boundary.
- [x] Keep dig/simulation ownership in `dig_controller` / `WorldSystem` CPU tile
      fields; render path consumes queued edits only.
- [x] Extend `render-game-prep` bench static depths to realistic underground
      stack order (`-2`, `-18`, `-34`).
- [ ] Land as a coherent commit stack on `expand2` and merge to `world`.
- [x] Document `cycle` rules in `docs/rendering-assets-shaders.md`.
- [ ] Optional: restore O(n) linear `mergeDrawList` now that submit-side sort is
      guaranteed (micro-opt; measure first).

Acceptance checks:

- [x] Dig hole/fall/ramp simulation tests pass unchanged (`dig_controller`,
      `game_demo_state`).
- [x] Visual layer stack correct: grass above dirt, carved tunnels show the plane
      below, no per-dig dirt/grass flip.
- [x] `zig build verify` passes.
- [x] `zig build gpu-smoke` exercises tilemap storage-buffer binds (`gpu_smoke_impl.zig`
      submits `appendStaticTilemapSpan` with retained tile-data buffer).

Status: landed on `expand2`; optional linear `mergeDrawList` micro-opt and
`expand2` → `world` merge remain backlog.

## Slice 23B: Multi-Depth Dense-Layer Render Scaling

Goal: make the Slice 23A retained tilemap path scale to large vertical worlds
(~120 depth levels, more entities) without linear draw-count and memory blow-up
at the surface, while preserving the 23A GPU upload invariants.

Problem (current envelope):

- One draw + one full-world storage buffer per **submitted** dense layer. At
  `active_level = 0` every layer at or below the player is submitted — for 120
  floors that is 120 draws and ~120 MB GPU tile data at 512² (manageable on
  desktop, wrong policy for steady-state frame cost).
- `k_max_dense_submit_layers = 16` in `world_system.zig` hard-fails beyond 16
  visible dense layers — blocks the first content expansion.
- `mergeDrawList` is O(n log n) in group count; acceptable at a bounded window,
  not at 120+ static groups every frame at the surface.
- Entity render prep already scales via SoA collect + `spriteCommandCapacity`;
  dense floors are the primary new cost — not per-tile vertex streaming.

Architecture notes:

- Simulation and nav already support multi-level worlds (Slice 25 per-level grids,
  `LevelLink`, incremental rebuild). This slice is **render visibility policy**
  only — no dig logic or nav contract changes.
- Slice 24 cube LOD already demotes off-level / far entities on the **sim**
  axis; 23B is the matching **render** axis for dense floor layers.
- Slice 25E adds per-entity depth alignment and entity render cull; dense-floor
  window policy stays in `WorldSystem` / `render_prep`.
- Chunked or streaming tilemaps are out of scope here unless profiling forces
  them; prefer a vertical **render window** first.

Recommended policy (default unless gameplay disproves it):

- Submit dense layers only in `[active_level .. active_level + N]` (N tuned to
  visible stack depth, e.g. 4–8) plus any layers required for surface-hole
  see-through (at most one ceiling band above the player when standing on
  level 0).
- Size `k_max_dense_submit_layers`, `reserveStaticGeometry`, and
  `draw_list_high_water` from the chosen window — not from total world depth.
- Pre-size GPU tile-data buffers for all authored dense layers at load (memory
  is level-count × cell count); culling affects **draw/submit** only unless a
  later slice adds buffer residency policy.

Current foundation (landed):

- `DenseLayerRenderWindow` in `world_system.zig`: default `levels_below = 6`,
  `ceiling_when_underground = false` (render slice follows `player_level` /
  `active_level`; surface hole see-through uses the below window at level 0).
  Optional `ceiling_when_underground` redraws one level above when enabled.
  `levelInWindow` gates submit;
  `maxSubmitLayers` sizes the window from per-level dense-band cap.
- `maxDenseSubmitLayerCount`, `validateDenseRenderBudget`, and
  `collectDenseSubmitLayers` replace the demo-only 16-layer hard cap;
  `k_max_dense_submit_stack_cap = 32` is a defensive submit-time guard.
  `WorldBuildConfig.render_window` and optional `max_dense_tile_gpu_bytes`
  fail loud at world build (`initDemo` / `initProcedural`).
- `submitStaticDenseGeometry` collects only in-window layers, sorts
  back-to-front, and re-submits on `dense_quads_dirty`, `active_level`, or
  window change. `GameplayScene.player_level` drives the handoff.
- `render_prep.ensureStaticGeometryCapacity` reserves static geometry from
  `WorldSystem.maxDenseSubmitLayerCount()` at the start of `submitGameplayFrame`
  (grow-only; allocation-free after the first reserve).
- `render-game-prep` dense 8/16/32 surface (`player_level = 0`) and deep
  (`player_level = 40`) benchmark groups; unit tests cover window caps, player
  level transitions, per-band inclusion, and depth order.

Checklist:

- [x] Define `DenseLayerRenderWindow` policy (min/max level offset, hole/ceiling
      exception rules) and document it beside `submitStaticDenseGeometry`.
- [x] Replace demo-only `k_max_dense_submit_layers = 16` with window-derived cap
      (or explicit world-build budget) and fail loud at world build if exceeded.
- [x] Wire window into `submitStaticDenseGeometry` and
      `GameplayScene.player_level` / camera-level handoff.
- [x] Reserve renderer static-group high-water from window + sparse overhead.
- [x] Add `render-game-prep` bench cases at 8/16/32 static tilemap groups and
      `player_level` 0 vs mid-depth; record `mergeDrawList` and submit cost.
- [x] Add unit tests: surface window caps submit count; deep play submits only
      the near stack; depth order preserved within the window.
- [x] Profile GPU memory budget for target level count × world size; document
      ceiling in `WorldBuildConfig` or load-time gate.
- [ ] Optional: restore linear `mergeDrawList` after window sort guarantees
      static order.

Deferred (separate slice if window is insufficient):

- Chunk-aligned dense tilemap regions instead of one full-world quad per layer.
- Level-of-detail / clip planes for deep underground beyond the window.
- Tile-data buffer unload for layers far from play (residency policy).

Acceptance checks:

- [x] World build with ≥32 dense levels succeeds; surface play stays within the
      configured draw and submit budget.
- [x] Digging through a vertical stack at depth 0..N shows correct planes in the
      window; no 23A regressions (depth order, `cycle=false`).
- [x] `zig build bench -- --group render-game-prep` reports stable prep cost at
      configured window sizes.
- [x] `zig build verify` passes.

Status: implemented and runtime-validated; window policy documented in
`docs/rendering-assets-shaders.md`. Optional linear `mergeDrawList` micro-opt
remains open.

## Slice 24: Scoped Simulation Tiers And Chunk Policy

Goal: turn the Slice 22 scaffolding into real scoped simulation behavior after
Slice 23 provides world/chunk/visibility inputs.

Readiness: the foundation for this slice is fully present (Slices 22/23/21);
what remains is wiring. The six checklist items below are the concrete gaps
between the current full-active pipeline and real scoped behavior.

> Historical pre-implementation assessment (2026-06-28, superseded by the
> **Status** below): at the time, `allowsMovement`/`allowsCollision`/
> `allowsCognition` were confirmed never consulted in `SimulationPipeline.update`,
> so every entity paid full pipeline cost every step regardless of tier. That gap
> is closed — see **Status** and **Implementation decisions** below for the
> landed `SimulationScopeSystem` gating.

Current foundation (present — do not rebuild):

- `SimulationTier` enum with capability predicates `allowsMovement`,
  `allowsCollision`, `allowsCognition` (`simulation_scope.zig`).
- Per-entity cold metadata `EntitySimulationMetadata { tier, chunk }` on
  `EntitySlot.simulation`, with `simulationMetadata`/`setSimulationMetadata`
  accessors and a `simulationScopeStatsFullActive()` tally (`data_system.zig`).
- `ActiveRegion` half-open chunk rectangle with `containsChunk()`, and
  `SimulationScope { active_region: ?ActiveRegion, stats }` plus per-tier and
  per-stage `SimulationScopeStats` (`simulation_scope.zig`).
- `WorldSystem` maintains `chunk_visible[]`, chunk coordinate columns, and
  `setVisibleChunksForWorldRect` / `chunkCoordForCell` (`world_system.zig`).
- (Pre-implementation state, now superseded by **Status** below) the pipeline
  used to run full-active unconditionally: `SimulationPipeline.update` built
  `SimulationScope.fullActive(...)` and dispatched every stage over the full
  component slices.

Status: implemented (2026-06-28). The backbone owner is
`SimulationScopeSystem` (`src/game/systems/simulation_scope.zig`), a pipeline-owned
system alongside movement/collision/ai/steering. It owns step/stagger state, the
scoped gathers, and the tier policy. Each O(N)-per-step pass threads like the other
processors and owns its own `AdaptiveWorkTuner`: the three gathers (movement,
collision, AI) are stream-compactions (per-range index buffers merged in scan
order), and the tier policy is a variable-output producer (per-range command
buffers merged into the frame's structural-command stream via the append protocol).
Threaded and serial produce identical results, and each pass exposes a `*Serial`
variant for the serial bench/test path.

Implementation decisions that diverged from the original sketch (code is
authoritative):

- Scope metadata moved off `EntitySlot` into **dense columns on the movement-body
  store** (`tier`, `chunk_x/y`, `stagger_phase`, `always_active`), in lockstep with
  the movement rows. The O(N)-per-step passes (chunk recompute, movement gather,
  tier policy) are aligned SoA scans/writes with no per-entity slot resolve. Scope
  metadata therefore exists exactly for entities with a movement body.
- Movement and collision gate on **tier only, no chunk filter** — off-screen
  entities keep moving and colliding. Their gathers short-circuit to full-active in
  O(1) via incremental `tier_counts` when no `dormant`/`kinematic` entity exists
  (the common frame), so the per-step scope cost scales with active scope.
- The cognition halo is derived from the **camera's visible chunks**
  (`WorldSystem.cognitionActiveRegion`), not a gameplay anchor position. AI gates
  on `cognition tier AND chunk-in-halo AND stagger phase`; scope pin metadata
  bypasses halo and stagger. With no visibility window yet, the gather falls back
  to full-active (no halo/stagger).
- **Steering is transitively scoped**: it acts only on the navigation intents AI
  emits, so gating AI gates steering without a second index list. Its avoidance
  spatial grid stays full so in-scope agents still avoid out-of-scope neighbors.
- **Simulation-LOD tier policy** (`collectChunkTierChanges`) assigns every entity
  the tier for its **cube (L∞) distance** from the **visible region**
  (`ActiveRegion.lodDistance` → `tierForChunkDistance`): `cognition` (≤
  `cognition_halo_chunks`) → `locomotion` (≤ `locomotion_halo_chunks`) → `kinematic`
  (≤ `kinematic_halo_chunks`) → `dormant` (beyond). So near entities think, far
  entities sleep — all four tiers are produced by distance, not just the cognition
  band. Scope pin metadata skips automatic tier demotion. It emits deferred
  `set_simulation_tier` structural commands appended to the frame stream for the
  state's commit seam (no tier mutation inside worker ranges), and reserves its
  command buffer up front so the per-step path is allocation-free even on a frame
  where many entities cross a band.
- **3D cube LOD (depth/level axis)**. The LOD volume is an L∞ ball over
  `(chunk_x, chunk_y, level)`, not a flat 2D ring: `ActiveRegion.lodDistance` takes
  the chebyshev chunk distance but floors it by a per-level penalty
  (`level_distance_chunks`, one band per level) against the region's `level` (set by
  the pipeline from the camera/player level). So an entity on a far depth/level
  reads as far regardless of its x/y and demotes out of cognition. The per-entity
  `level` rides as a dense scope column beside `tier`/`chunk_x/y`. Single-floor
  content defaults level to 0; the machinery supports multi-level worlds. The AI
  halo gate stays 2D (`containsChunk`); off-level entities are excluded purely
  through the tier the cube policy assigns them.

Checklist (done):

- [x] Public `WorldSystem.visibleChunkRegion()` and `cognitionActiveRegion(halo)`
      expose the camera chunks (+halo) as an `ActiveRegion`.
- [x] Entity chunk columns are derived in-pass by the movement processor from each
      integrated body's settled position (`movement.ChunkGridParams`), so there is no
      separate recompute pass; the scope gathers read the chunk columns movement wrote.
- [x] Scoped gather entry points for movement, collision, and AI (steering
      transitive). Processors keep their hot loops and take a `scope_dense_indices`
      option; null = full-active.
- [x] Per-entity `stagger_phase` (cold dense column) drives a 1-in-N cognition
      cadence inside the halo; skips counted in scope stats.
- [x] Tier promotions/demotions routed through deferred structural commands at the
      commit seam; no worker-range tier mutation.
- [x] Scope stats expose per-tier, per-stage, `stagger_skips`, and
      `chunk_filtered_entities` counts via `runtime_perf_log` and the demo state.

Acceptance checks:

- [x] Scoped and full-active processor paths produce identical outputs for the same
      entity subset (gather index path mirrors the full path).
- [x] Tier/chunk filtering changes stage participation without changing stage order
      or `SimulationFrame` stream contracts.
- [x] Chunk metadata stays consistent with position after movement; scope counts
      match entities actually processed per stage.
- [x] Tier changes mutate `DataSystem` only through the deferred command commit.
- [x] `zig build test` covers gathers, tier gates, stagger, tier-command commit,
      and pipeline phase transitions without opening a window.
- [x] Debug stats report active scope counts so typical runs stay far below 50k
      stress scales by policy.

Known limitations / follow-up: see **Scaling Gaps And Hardening Frontier**
(simulation scale — movement contiguous-path vs scoped LOD).

## Slice 24B: Render Collect Hardening

**Status: landed.** All Checklist and Acceptance checks below are `[x]`.

Goal: harden dynamic entity render prep for scale — movement-index collect and
camera-only visibility gates — without conflating simulation LOD with render
policy or moving SDL_GPU submission into the pipeline.

Problem (observed at `render-game-prep` stress scales):

- `collectDynamicRecords` iterated `primitiveVisualSliceConst().entities` and
  called `renderEntityComponentIndices` per row — an `EntityId → slot` resolve on
  every visual even when chunk/AABB cull skipped append.
- An early draft gated render on `SimulationTier` (`allowsRender`), which blended
  sim LOD with draw policy. Render visibility must be camera-only; sim tier
  controls processor participation only.

Architecture notes:

- **Movement-body dense rows are the collect anchor.** Scope columns align on
  `movement_index`; a dense `has_primitive_visual` flag skips movement-only rows
  before slot resolve; `renderCollectIndicesForMovement` performs one slot read per
  chunk-pass row that carries a primitive visual. Scope columns are simulation
  inputs only — render collect does not read tier or pin metadata.
- **Render visibility is camera policy only.** `entityVisibleForRenderCollect`
  uses `WorldSystem.visibleChunkRegion()`; every drawable row then passes
  `VisibleWorldRect.overlapsAabb`. No render bypasses on scope metadata.
- **Dense floors are a separate axis.** In-window layers submit one full-world
  tilemap quad each (Slice 23B); GPU clips to the viewport. Per-entity depth
  cull (25E) is separate from the dense-floor window.

Checklist:

- [x] Add `RenderCollectIndices` and `renderCollectIndicesForMovement` on
      `DataSystem`.
- [x] Walk `movementBodySliceConst().entities` in `collectDynamicRecords`.
- [x] Camera-only `entityVisibleForRenderCollect` (chunk) + AABB for all entities.
- [x] Remove `SimulationTier.allowsRender`; sim tier does not gate draw.
- [x] Headless tests: sim tier does not affect collect; movement-index resolve.

Acceptance checks:

- [x] On-screen entities collect regardless of sim tier; off-screen entities
      (including player) skip before interpolation.
- [x] `zig build test` covers camera gates and movement-index collect helpers.
- [x] `zig build verify` passes.

**Status: landed.** Render-scale follow-up without a new slice number is backlog
in **Scaling Gaps And Hardening Frontier** until promoted to a slice Checklist.

## Slice 25: Z-Aware Scalable Navigation Redesign

Goal: make the pathfinder correct, scalable, and functional for multi-Z-level,
fixed-but-variable-size worlds with event-driven dynamic tile changes and
mostly per-agent distinct goals. This supersedes the single-flat-grid,
goal-field-centric core from Slices 18/20 while keeping the frame-delayed
request/result contract and steering integration from Slices 18/19 intact.

Current foundation:

- Slice 18 frame-delayed pathfinding, Slice 19 steering/local avoidance, and
  Slice 20 bounded hard-path budgets define the request/result contract,
  deterministic deferral, and fixed-capacity caches this redesign keeps.
- Slice 21 typed events (`world_tile_changed`, `world_obstacle_changed`,
  `nav_region_invalidated`) are the dynamic-update signal source.
- Slice 23 world rendering provides `WorldSystem` levels (`addLevel`/
  `level_base_z`), dense render bands (`addDenseLayer`/`denseLayerCount`), sparse
  obstacles, `cellRect`, and tile size (32).
- Slice 22 `SimulationPipeline` owns the per-tick `pathfinding.update` call site
  and the one-time nav build; the per-stage `pipeline_pathfinding` timer exists.

Problem (observed defects this slice fixes):

- A Z-level is a `WorldSystem` level (floor), not a render band. `NavGrid`
  collapses every dense band of every level into one flat blocked mask
  (`pathfinding.zig` `markWorldObstacles`), which is wrong across bands and
  across floors. There is no inter-level connectivity.
- Whole-grid scratch sizing is the real scalability wall: goal fields and
  per-worker scratch are sized to total cell count, costing ~293 MB at 512²/32px
  before the demo coarsened to 128px nav cells. The 65,536-cell `goalFieldsEnabled`
  / `fallbackSearchEnabled` gates then silently degrade navigation to direct seek
  with no error — a correctness landmine.
- `PathQueryKey` includes the agent start cell, so a drifting agent mints a new
  key every cell, pending entries never dedup, and agents replan-storm (observed
  `replans=17256` in a 60s sample).
- Goal fields only build for ≥2 same-goal requests in the same step, so with
  per-agent distinct goals they never cache-hit (`field_cache_hits=0`,
  `fields_built=51`, `evictions=277`) — pure thrash and the source of the
  `pipeline_pathfinding_max≈31ms` dropped-frame spike.
- `update()` writes `deferred_requests` twice (`pathfinding.zig` ~1008 then
  ~1041); budget exhaustion can read as `unavailable` instead of `pending`.
- Coarse 128px cells push waypoints away from walls, raising `stuck`/`unavailable`.

Architecture notes:

- Navigable unit is the level (Z-floor). A level's per-cell blocked mask is the
  OR of that level's dense bands plus its sparse obstacles, exposed by a new
  `WorldSystem.levelBlocksMovement(level, x, y)` accessor so pathfinding stops
  iterating render bands directly.
- Two-tier (HPA*-style) structure per level: a fine per-level blocked bitset
  (cell = one 32px tile) plus a coarse chunk-portal graph (default 16-tile
  chunks). Inter-level travel uses explicit `LevelLink` records (ramp/stair/
  teleport) owned by `WorldSystem` as persistent world facts carrying only stable
  cell coordinates and level indices — never live nav indices or handles.
- A path query maps start/goal to `(level, cell)`, projects a blocked goal to the
  nearest open cell within a bounded radius, rejects cross-component goals via
  per-level connected components, then runs abstract A* over the portal graph plus
  link edges (Z-crossing is a link edge between portal nodes in different levels).
  The chosen corridor is then STITCHED into one obstacle-aware (level,cell) path by
  running per-segment local A* between consecutive corridor portals (a discrete jump
  only across a link edge) and cached whole; the per-agent query walks the path on its
  current level cell by cell, so multi-hop and cross-level routes converge with every
  heading a traversable neighbor. The `PathView` contract
  (`status`/`next_waypoint`/`path_len`) is unchanged.
- Per-agent A* uses a binary-heap open set and generation-stamped closed/g-cost
  storage sized to a bounded `max_explored_nodes` budget (e.g. 4096) via a
  cell→slot hash, not whole-grid arrays. Budget exhaustion returns `pending`
  (loud `path_budget_exhausted` counter), never silent `unavailable`.
- Cache/pending key is `{ nav_version, agent_class, goal_level, goal_cell }` —
  start is dropped. A cached result stores the abstract corridor; the per-entity
  waypoint is re-refined from the agent's current cell each step it is consumed,
  so a moving agent reuses one corridor for its whole trip and many agents sharing
  a goal share one pending entry.
- The core provides TWO coordinated solver modes. (1) Per-agent A* for distinct
  goals (the default). (2) A MANAGED shared-goal flow field for declared common
  goals (crowds converging on the player/an objective): a small fixed registry of
  reverse-Dijkstra integration fields keyed by `{nav_version, goal_cell}`,
  persistent and reused across frames and all agents, rebuilt only when nav
  changes or the declared goal crosses into a new nav cell, throttled by a minimum
  rebuild interval, and built under a per-frame expansion budget (a field may be
  `building` across frames) so it never spikes. This is NOT the old per-step
  auto-grouped goal field (which thrashed at `field_cache_hits=0`); grouping is
  declared by the request, not detected. Agents sample the field in O(1) and the
  result surfaces through the unchanged `PathView` contract. The long-range
  individual mechanism is the Slice 25C chunk-portal abstract tier; the group
  field is the shared-goal mechanism — both coexist.
- Dynamic updates are event-driven: `world_tile_changed`/`world_obstacle_changed`
  map to affected cells, flip blocked bits, mark owning (and border-touching
  neighbor) chunks dirty, and `applyNavUpdates` recomputes only dirty chunks'
  cells/portals/adjacency plus dirty-driven component relabel (full relabel only
  past a threshold, loud counter). One `nav_version` bump per batch invalidates
  goal-keyed cache/pending entries. The whole-world build runs only at init.
- The cell gates are deleted. Oversized worlds fail loud at construction via a
  configured `max_nav_memory_bytes` (`error.NavWorldTooLarge` with a diagnostic),
  not at query time. Per-query work is bounded by the abstract graph plus the node
  budget, independent of total world cell count.
- Threading: per-request abstract+local A* runs on workers with worker-indexed
  scratch and deterministic per-`pending_index` output (existing fallback
  dispatch shape); small batches stay inline via the adaptive tuner.
  `applyNavUpdates` runs single-threaded at the event reaction point before the
  next step's solves; chunk recompute is parallelizable later if needed.

Capacity/memory model (per level: W·H nav cells = C, L levels, K-cell chunks):
nav ≈ `L·(C/8 bitset + 4·C components) + links·16`. The per-worker local A* scratch
is now generation-stamped DIRECT per-cell arrays (g-cost + parent + stamp + closed
≈ 13 B/cell), so A* scratch ≈ `slots · C · 13 B` — O(cells) instead of
O(`max_explored_nodes`). This is a deliberate speed-for-bounded-memory trade (O(1)
node access, no hash probes); slots = `worker_participant_count` (workers+1, sized at
the build), and the build-time `max_nav_memory_bytes` gate counts exactly that
resident scratch, so a large world that exceeds the budget fails loud at the gate. `max_explored_nodes` remains the per-solve node BUDGET (a spill cap), enforced
by an explicit expansion counter rather than a hash-table-full condition.
`components` width (u32→u16 or abstract-graph-only reachability) is a
future memory lever for very large worlds.

Sub-slices (each independently shippable and headless-testable):

- Slice 25A — `WorldSystem` per-level navigability accessor + `LevelLink` store;
  pathfinding consumes `levelBlocksMovement` for level 0 only (behavior-preserving
  for the single-level demo).
- Slice 25B — hybrid core: per-agent A* (goal-keyed corridor cache, budgeted
  scratch) PLUS a managed shared-goal flow-field registry. Remove the old
  auto-grouped goal fields, cell gates, and the start-cell key; add
  `max_explored_nodes`, `max_group_fields`, group rebuild throttle/budget, and
  `max_nav_memory_bytes`; fix the `deferred_requests` double-write; redefine
  `unavailable` vs `pending`; request contract carries individual-vs-group kind.
- Slice 25C — chunk-portal abstract tier and cross-level query; `PathRequest`/
  `NavigationIntent` gain `start_level`/`goal_level`; steering fills them.
- Slice 25D — event-driven incremental rebuild: dirty nav-cell set, `applyNavUpdates`,
  per-affected-level mask/component recompute, single `nav_version` bump, nav-update
  metrics; wire world-tile/obstacle events from the post-commit reaction point into the
  pipeline instead of full rebuilds. Granularity: per-AFFECTED-LEVEL recompute (the
  bounded fallback the brief permits) — only affected levels' masks/components are
  re-derived and the shared chunk-portal abstract graph is rebuilt once (bounded by
  chunk borders, not cells); true per-chunk portal/CSR surgery would require a
  per-chunk-addressable portal store (a larger redesign) and is deferred. A relabel of
  every level happens only past a configured affected-level threshold and increments a
  loud `nav_full_relabel` counter; unaffected levels are never touched and the
  whole-world build stays init-only.

Checklist:

- [x] 25A: add `WorldSystem.levelBlocksMovement`, `levelCount`, and `LevelLink`
      store/accessors; switch `markWorldObstacles` to per-level composition.
- [x] 25B: per-agent A* (budgeted scratch, goal-keyed corridor cache, no
      start-cell key); delete the old auto-grouped goal fields, cell gates, and
      their stats; add memory-gate validation; fix the `deferred_requests`
      single-write. Heap A* is now the sole individual solver; scratch is sized
      to `max_explored_nodes` via a cell->slot hash, not whole-grid arrays; the
      node-budget spill returns `pending` and increments `path_budget_exhausted`.
- [x] 25B: managed shared-goal flow-field registry (`max_group_fields`,
      cell-quantized + throttled + per-frame-budgeted rebuilds, declared by
      request kind, sampled O(1) through `PathView`); both modes tested. Group
      fields are built only on declared `group` requests (zero cost when unused),
      throttled by `group_field_rebuild_min_steps`, and built across frames under
      `group_field_build_budget`.
- [x] 25C: build per-level chunk-portal graph; abstract A* over portals + link
      edges; stitch the chosen corridor into one full obstacle-aware (level,cell) path
      via per-segment local A* (link edges are discrete jumps) and walk it per-agent on
      its current level cell by cell; add level fields to request/intent/steering.
      Abstract scratch saturation or a per-segment node-budget spill returns
      `budget_exhausted` (retry), reserving `unavailable` for a missing corridor.
      Abstract seeding scans only the start level's portals via a per-level portal
      index, so per-query work is bounded independent of total cells and of other
      levels' portals. (Performance, post-25: the per-level index is further grouped
      by connected component — a per-(level,component) CSR — so seeding scans only the
      START component's portals, not the level's full border; architecture unchanged.)
- [x] 25D: incremental nav rebuild driven by typed world events. `applyNavUpdates`
      flips the affected level's blocked bits, recomputes only affected levels'
      masks/components, rebuilds the chunk-portal abstract graph once, and bumps
      `nav_version` once per batch so goal-keyed cache/pending/group entries re-solve.
      `GameDemoState` collects blocking `world_tile_changed`/`world_obstacle_changed`
      (and entity-driven obstacle) changes into a pre-reserved dirty nav-cell set and
      feeds `pipeline.applyNavUpdates`; the whole-world build path is init-only. Added
      `nav_dirty_chunks`, `nav_incremental_rebuilds`, `nav_full_relabel`,
      `nav_version_bumps` metrics; the per-affected-level relabel degenerates to a
      counted full relabel only past `nav_full_relabel_level_threshold`. The build
      helpers were moved off per-call `allocator.alloc` onto persistent scratch, and
      the abstract-graph buffers grow to their real size at the init rebuild and
      retain that high-water capacity, so an incremental rebuild within the
      high-water mark allocates nothing (a failing-allocator test drives both the
      system and graph allocators across a block-then-reopen). A genuine topology
      expansion past the high-water mark does one bounded amortized growth — a cold,
      event-triggered path covered by a separate test. The `max_nav_memory_bytes`
      gate estimates nav memory from realistic structure (portals bounded by
      chunk-border cells, CSR edges by portal count times a small abstract degree),
      not a per-chunk pairwise worst case, so large sparse worlds build. `PathView`
      and request contracts are unchanged.
- [x] Reset the demo `nav_cell_size` stopgap (currently 128) to a tile-aligned
      principled value (32 = one nav cell per tile); coarseness lives in the chunk
      tier, not the cell size.
- [x] Keep pathfinding a gameplay system in `src/game/systems/`; no test-only
      enum tags, marker fields, or fixture hooks in production contracts.

Acceptance checks:

- [x] Intra-level paths are correct against a per-level composed mask; a blocked
      goal projects to the nearest open cell (`path_goal_projected`); disconnected
      goals return `unavailable` exactly once and cache.
- [x] Cross-level `LevelLink` traversal works (25C): a bidirectional link routes an
      off-level agent across floors (`cross_level_solves`); a directed link works one
      way only; a missing or blocked-endpoint link returns `unavailable` (not a
      permanent stall); per-level obstacles do not bleed across floors; a multi-hop
      same-level corridor (split component bridged by a same-level teleport) and a
      cross-level corridor both travel obstacle-free past a concave wall in single-cell
      steps (no straight-line cut) and reach the goal; abstract scratch saturation
      reads pending (not cached unavailable); a warmed abstract solve does not
      allocate; a cross-level group member falls back to an individual corridor once
      the goal-level field is ready. All asserted by headless tests.
- [x] A moving agent toward a fixed goal produces one accepted request then cache
      reuse (no per-cell churn): asserted by the goal-keyed dedup-under-drift test.
- [x] Per-query explored-node count is bounded (`max_explored_nodes`) and
      independent of total world cell count; spills return `pending`.
- [x] An oversized world returns `error.NavWorldTooLarge` at construction; no query
      path ever silently degrades to direct seek (the cell gates were removed).
- [x] A tile/obstacle event blocks/unblocks a corridor and the next path reflects
      it; `nav_incremental_rebuilds`/`nav_version_bumps` are non-zero and full
      rebuild runs only at init. (Slice 25D.) Headless tests cover: flipping a
      corridor gap to blocking reroutes the next solve through a different gap (and
      stale cached path invalidates because its `nav_version` key no longer matches);
      closing the last gap returns `unavailable`; unblocking a tile opens a shorter
      path; an edit on level 0 leaves a second level's mask/components byte-for-byte
      untouched (work scales with the dirty set, not world size); an empty batch is a
      no-op; and the steady-path update is allocation-free under a failing allocator.
- [x] `zig build fmt`, `zig build check`, `zig build test`, `zig build verify`, and
      targeted pathfinding benchmarks pass.

Open decisions (recommendation in parentheses): inter-level link representation
(explicit `LevelLink` records, not inferred tile flags); chunk size (16 tiles);
shared-goal flow field is folded into the 25B core (declared by request kind,
persistent, cell-quantized + throttled + budgeted), not opportunistically grouped;
parallel-solve threshold (keep existing adaptive/inline behavior; `applyNavUpdates`
serial initially); `components` width (u32 initially); goal-level source
(`NavigationIntent`, default 0 until multi-level gameplay exists).

Status: 25A, 25B, 25C, and 25D implemented. The hybrid core ships goal-keyed individual
A* with budget-bounded scratch, the managed shared-goal flow-field registry, and the
chunk-portal abstract tier with cross-level `LevelLink` routing. Long-range and
cross-level queries route through abstract A* over portal/link nodes, then stitch the
chosen corridor into one full obstacle-aware (level,cell) path via per-segment local
A* (link edges are discrete jumps) and cache it whole; the per-agent query walks it on
its current level cell by cell, so every heading is a traversable neighbor. Abstract
seeding scans only the start level's portals (per-level portal index); abstract scratch
saturation or a per-segment node-budget spill returns `budget_exhausted` (retry) rather
than a hard negative. The old auto-grouped goal fields, cell gates, start-cell key, and
their stats remain removed; `deferred_requests` is a single post-compaction write in
both update paths; the memory gate fails loud at rebuild. 25D (event-driven incremental
rebuild) is implemented: `applyNavUpdates` folds a dirty nav-cell set from
world-tile/obstacle (and entity-driven obstacle) events into the existing graph by
recomputing only affected levels' masks/components, rebuilding the chunk-portal abstract
graph once, and bumping `nav_version` once per batch so goal-keyed work re-solves; the
whole-world build runs only at init. Granularity is per-affected-level (the bounded
fallback) with a counted `nav_full_relabel` past a level threshold; true per-chunk
portal/CSR surgery is deferred pending a per-chunk-addressable portal store. Route the
slice diff to review with attention to the goal-keyed cache reuse and
corridor-advancement contracts, the per-affected-level update scope, and the
allocation-free steady-path claim.

Post-25 performance pass (architecture unchanged — same A* results, deterministic,
allocation-free on the warmed path; all layers retained): (1) the per-worker local A*
scratch is generation-stamped DIRECT per-cell arrays indexed by cell index, giving
O(1) node access with no hash probes/collisions in place of the prior open-addressed
cell→slot hash. Per-worker scratch is now O(cells); the build-time memory gate
(`NavMemoryBudget.requiredBytes`) counts `slots · cells · 13 B`, and `max_explored_nodes`
remains the per-solve node budget enforced by an explicit expansion counter.
(2) Abstract seeding is component-scoped: the per-level portal index is grouped by
connected component (a per-(level,component) CSR), so seeding scans only the start
component's portals rather than the level's full border. (3) `localAStar` derives each
neighbor's (x,y) incrementally from the current cell plus the direction offset and feeds
those coordinates straight to the octile heuristic, removing per-neighbor `index%width`/
`index/width` div/mod. A node-access design that would make a same-component
budget-spill escalate to the abstract corridor (the considered "WIN C") was NOT adopted:
with component-scoped seeding the abstract corridor for a same-component goal collapses
to a single portal, so escalation cannot subdivide the long segment and would only add
per-frame work — making it effective would require start-chunk-scoped seeding (a global
corridor-shape change), a design decision left for a future slice.

Deferred follow-up: per-entity depth alignment across sim, navigation, and
render is tracked as Slice 25E below and under **Scaling Gaps And Hardening
Frontier** (simulation scale). The nav substrate is in place; the gap is entity
level column wiring in `DataSystem`, steering, path views, and render cull.

## Slice 25E: Per-Entity NPC Level And Autonomous Z-Traversal

**Status: landed**, with one superseded item. All Checklist and Acceptance
checks below are `[x]` for the record, but `PathView.next_cell_level`
(checklist items below referencing it) was later found to have zero
production consumers — `steering.zig`'s `directionFromPathStatus`, the only
real caller of `statusForWorld`/`statusForKeyAndStart`, never read it — and was
removed as dead code. The actual NPC level-transition mechanism is, and always
was, `DigController.applyEntityPlaneTraversal` (invoked from
`SimulationPipeline.applyNpcPlaneTraversal`), which drives transitions from the
entity's real physical-cell world geometry with no lag/latency gap. See
`docs/coding-standards.md`/project convention: code is authoritative for doc
drift, so this note replaces the earlier "landed" claim for the
`next_cell_level` field specifically; the rest of the slice (per-entity level
column, steering `start_level` sourcing, render cull by entity level) is
unaffected and still landed as described.

Goal: give each NPC entity its own Z-level so it can request cross-level paths,
traverse ramps and stairs autonomously, and be culled to its own floor instead
of always rendering on the player's level.

Prerequisite context: Slice 23B scales **dense floor** submission (~120 layers);
this slice scales **entity** level columns and NPC draw cull. Player floor
policy (`GameplayScene.player_level` → `submitStaticDenseGeometry`) stays in
23B; NPCs need their own level column and render-prep filter here.

Current foundation:

- Slice 25 provides a fully correct two-tier nav substrate with `LevelLink`
  records and cross-level A* corridor stitching.
- `PathRequest`/`NavigationIntent` already carry `start_level`/`goal_level`
  fields (added in 25C); steering hardcodes `start_level = 0`.
- The per-level portal graph, `PathView`, and link-edge traversal are complete.

Problem (confirmed silent-behavior gap):

- `steering.zig` `writePathRequests` hardcodes `start_level = 0` and
  `statusForEntityWorld(..., 0, ...)` ignores the entity's actual floor.
- `PathView` exposes `next_waypoint` XY but no level; an agent crossing a link
  cannot detect the level transition and update its own Z.
- Ramp/fall plane-traversal logic is player-only (`game_demo_state.zig`).
- NPCs are drawn at their XY on whatever level the player occupies, so an NPC
  pursuing the player underground appears to teleport along its level-0 path.
  This produces wrong-but-non-crashing behavior that attributes to AI logic,
  not a routing defect.

Checklist:

- [x] Add a per-entity level (Z) column to `DataSystem` (cold metadata, default
      surface level `0`), following the component-store pattern; initialize in
      `createEntity`.
- [x] Steering sources `start_level` from the entity's level column rather than
      the hardcoded `0`.
- [x] Extend `PathView` to expose `next_cell_level` alongside `next_waypoint`
      so an agent can detect a link crossing and commit a level update. (Later
      removed: no production consumer ever read this field — see status note
      above.)
- [x] Update the per-step movement/traversal pass to apply NPC level transitions
      at link cells (mirroring the player ramp/fall logic); update the entity
      level column through an explicit main-thread commit, not inside worker
      ranges. (Landed via `DigController.applyEntityPlaneTraversal` driven by
      physical-cell world geometry, not via the removed `next_cell_level`.)
- [x] Render and cull each NPC on its own level, not the player's.
- [x] Add tests covering same-level NPC pathing (no regression), cross-level
      pathfinding, and NPC render cull matching entity level. (The
      `next_cell_level`-specific assertions were removed alongside the field;
      the remaining status/waypoint/render-cull assertions still cover this.)
- [x] Demo stress: procedural world `addUndergroundLevelStack(31)` (32 levels),
      32 movers, GPU budget gate, scaled pipeline reserves.

Acceptance checks:

- [x] Cross-level path queries route through link cells correctly (pathfinding
      + caches tests); NPC traversal commits `world_level` on ramp/fall cell
      entry via `DigController.applyEntityPlaneTraversal`, not via
      `next_cell_level` (removed — see status note above).
- [x] Intra-level NPC behavior is unchanged (steering parity tests).
- [x] NPCs are culled to their own level, not the player's (`render_prep` test).
- [x] No steady-state allocation on hot paths.
- [x] `zig build test`, `zig build check`, and `zig build verify` pass.

## Emergent AI Track Overview (Slices 26–33)

Goal: layer emergent NPC behavior — perception, memory, emotion, and richer
behavior arbitration — on top of the navigation substrate, while staying
allocation-free on hot paths, deterministic (serial == threaded, scalar ==
SIMD), and affordable at scale by running only under the cognition tier gated by
Slice 24.

Sequencing rationale:

- Slices 26–28 are framework foundations the AI work requires and the framework
  does not have yet (entity classification, deterministic RNG, a shared spatial
  index). They are blockers or strong enablers for perception.
- Slices 29–32 are the composing AI stack: perception → memory → affect →
  behavior arbitration. Each reads the prior layer's columnar state.
- Slice 33 is authoring/tuning infrastructure (data-driven archetypes + debug
  introspection) that makes the stack usable and verifiable.

Shared design contracts for the whole track:

- Each new per-entity concept follows the existing component-store pattern in
  the `data_system/` subpackage (fronted by `data_system.zig`; `Component`,
  `EntityTemplate`, and related types now live in `data_system/types.zig`):
  `Component` enum tag, component mask, `EntityTemplate` field,
  `StructuralCommand` variant, `StructuralCapacityNeeds` capacity, an SoA
  `*Store` (modeled on `AiAgentStore`), a `Const*Slice`, an `EntitySlot` index,
  and public set/get/slice + validation helpers.
- Each new per-step computation is a parallel processor stage modeled on
  `ai.zig` (main-thread gather → grid/precompute → parallel range jobs → emit),
  preserving serial/threaded parity and writing range-disjoint output.
- Stages are designed SIMD-first because they run per cognition-agent and must
  hold up in heavy scenes and large battles. Gather neighbor/perception data once
  into packed local SoA scratch, then vectorize the float math (distance, FOV,
  normalize, drive appraisal, weight blend) through `src/core/simd.zig` with
  masked branches and a scalar tail, per the SIMD policy in
  `docs/coding-standards.md` and Slice 34. Scale assessment uses target battle
  counts, not demo counts.
- Events follow the Slice 21 contract: scalar-only payloads (`EntityId`, enums,
  scalars — no pointers/slices/handles), added as a `SimulationEventPayload`
  union variant with a matching `SimulationEventStats` counter, `record()` switch
  arm, and `addProduced()` line; emitted at the `domain_reaction` stage through
  the per-range `SimulationEvents.RangeWriter`; capacity pre-reserved.
- High-volume per-frame data (e.g. "who each agent sees this frame") lives in
  component columns / transient frame buffers, never in the event stream. Only
  state *transitions* (acquired/lost target, drive threshold crossed) become
  events. This keeps the event stream low-volume and the design scalable.

## Slice 26: Entity Faction And Classification Model

**Status: landed.** All Checklist and Acceptance checks below are `[x]`.

Goal: give entities a classification so perception and behavior can distinguish
threat / ally / neutral. No team or faction concept exists anywhere today; it is
a hard prerequisite for perception (Slice 29) and behavior arbitration
(Slice 32).

Current foundation:

- Entities are dense SoA with stable `EntityId` handles and component masks
  (`data_system.zig`); the component-store pattern is established (e.g.
  `AiAgentStore`).
- No faction, team, allegiance, or relationship data exists.

Checklist:

- [x] Add an `AiFaction` (or lightweight `entity_tag`) component: a small enum
      faction id per entity, following the full component-store pattern.
- [x] Add a fixed faction-relationship matrix (enum × enum → stance:
      hostile / neutral / friendly), const-evaluated, scalar/enum only, no
      per-frame allocation and no hash lookup on hot paths.
- [x] Expose a stance query usable from processor hot paths (`stance(a, b)`)
      that compiles to a table index, not a map lookup.
- [x] Add to `EntityTemplate` and demo spawns so actors can be tagged.

Acceptance checks:

- [x] Stance lookups are allocation-free and branch-light on hot paths.
- [x] Faction assignment round-trips through structural commands and survives
      entity destruction/reuse with generational correctness.
- [x] `zig build test` covers stance symmetry/asymmetry and template wiring.

## Slice 27: Deterministic Per-Entity RNG Facility

**Status: landed.** All Checklist and Acceptance checks below are `[x]`.

Goal: provide reproducible randomness for AI (wander jitter, appraisal noise,
investigate targets) that does not break the determinism contract
(serial == threaded, replayable, range-order-independent).

Current foundation:

- `src/core` owns shared math/SIMD/logging helpers but has no deterministic RNG
  facility; existing wander randomness is ad hoc.
- The fixed-step loop provides a stable per-step index usable as an RNG input.

Architecture notes:

- A counter-based / hash-based stream (e.g. `hash(entity_index, step, salt)`) is
  required rather than a stateful PRNG, so a worker can derive an entity's noise
  independent of range partitioning or execution order.

Checklist:

- [x] Add a stateless, seeded, splittable RNG in `src/core` keyed by
      `(entity_index, step, salt)` returning uniform f32 / bounded ints.
- [x] Document the determinism guarantee: same inputs → same outputs regardless
      of thread count or range order.
- [x] Migrate existing AI wander randomness onto it as the first consumer.

Acceptance checks:

- [x] Identical RNG outputs across serial and threaded runs for the same step.
- [x] No per-call allocation; no shared mutable RNG state across workers.
- [x] `zig build test` covers reproducibility and distribution bounds.

`src/core/rng.zig` adds `mix64`/`uniformF32`/`boundedU32`/`unitVec2`, generalizing
the splitmix64-style mixer that was previously a private, non-reusable helper
inside `ai.zig`. The migration also fixed a real bug, not just a refactor: the
old call was keyed only by a hardcoded seed and the entity's dense index, both
constant over time, so wander direction never resampled. `SimulationScopeSystem`
now exposes `currentStep()`, `SimulationPipeline` threads it into `AiConfig.step`
each fixed step, and `ai.zig`'s `decideDir` keys its wander draw off
`(seed, entity_index, step, wander_rng_salt)` so direction actually varies over
time while staying deterministic for a fixed step and identical across serial
and threaded runs. A first landing resampled on every AI-active step, which
review caught as trading the "never varies" bug for a "zero continuity" one
(uncorrelated direction every tick reads as jitter, not wandering). Fixed by
quantizing `step` into coarser epochs (`AiConfig.wander_resample_period_steps`,
default 300 steps / 5s at 60Hz) before hashing, so direction holds steady for a
stretch and then jumps to a new per-entity-distinct heading.

## Slice 28: Shared Spatial Index Service

**Status: landed.** All Checklist and Acceptance checks below are `[x]`.

Goal: build one frame-level spatial index consumed by AI separation and
perception instead of each system building its own grid.

Current foundation:

- AI separation built a deterministic 32-unit grid each step
  (`systems/ai.zig`); Perception (Slice 29) would have added a second.

**Deviation from the original checklist wording:** the original draft asked to
port "AI separation *and collision broadphase*" onto one shared grid. Collision
broadphase does not actually build a grid — it runs sweep-and-prune (SAP) on a
`min_x`-sorted `order` array (`src/game/systems/collision.zig`), with a warm
incremental insertion-sort (`sortWarm`/`full_sort_disorder_percent`) that
exploits frame-to-frame temporal coherence, plus SIMD Y-overlap filtering.
That is a different, already-tuned algorithm, not a duplicate grid build.
Forcing collision onto a per-step-rebuilt uniform grid would risk regressing
that incremental-sort win and would require reproducing SAP's exact
candidate-pair order to satisfy this slice's own parity gate. **Decision: build
the shared index for AI separation (this slice) and Perception (Slice 29, the
actual driver). Collision stays on SAP, untouched.**

Architecture notes:

- Built once per fixed step by the pipeline-owned `SpatialIndexSystem`
  (`src/game/systems/spatial_index.zig`), from the same cognition-scoped
  population `AiSystem` already gathers (`scope_dense_indices`); workers read
  the resulting `SpatialIndexView` immutably. AI separation's ported output
  matches the pre-refactor per-step grid exactly (parity-tested, including an
  O(n²) brute-force bit-for-bit proof plus a second cross-cell oracle that
  independently reconstructs the cell_y-outer/cell_x-inner/ascending-index
  traversal spec, since float-summation order only becomes observable once a
  population spans multiple cells), not just approximately.

Checklist:

- [x] Add a frame-built spatial hash/grid owned at the pipeline boundary, sized
      from reserved capacity, rebuilt per step, read-only to workers.
- [x] Port AI separation to consume it; remove the duplicate grid build.
      Collision keeps its own tuned SAP broadphase by design (see the
      Deviation note above) — porting it is a future benchmarked-optional item,
      not this slice's requirement.
- [x] Expose a bounded neighbor-query API (max samples / radius) reusable by
      perception.

Acceptance checks:

- [x] Separation outputs are identical to the pre-refactor results (parity
      tests, including a single-cell brute-force bit-for-bit proof and a
      multi-cell cross-cell-order oracle proof).
- [x] Index build and queries are allocation-free after warmup and deterministic
      (serial == threaded).
- [x] `zig build bench` shows no regression from removing the redundant grid
      build — the `ai` group's timed window now excludes the build (its own
      `spatial_index` bench group times that separately), so per-step
      `separation_checks` are unchanged and measured throughput improved.

## Slice 29: AI Perception Substrate

**Status: landed** — vision (including the LOS cost-risk fix) and hearing are
both in place. `AiPerception` (`data_system/perception.zig`), `PerceptionSystem`
(`systems/perception.zig`), the `entity_perceived`/`entity_lost` event
contract, and the `perception`/`perception-los-dense` benchmark groups are all
in place with full test coverage: range/FOV/LOS gating, faction-stance
gating, same-level gating, player-as-candidate, all four transition shapes
(acquire/lose/hold/identity-swap), the per-step event cap with drop
diagnostics, serial/threaded parity, and a `FailingAllocator` steady-state
allocation-free proof. The squared-form FOV test
(`dot(facing, to) > 0 AND dot^2 > cos_half_fov^2 * dist2`) turned out not to
need the vector sin/cos polynomial Slice 34 deferred here — no production
caller for `simd.sinFloat4`/`cosFloat4`/`sinCosFloat4` was added, since a
unit-length facing vector makes the squared dot-product compare exact without
any per-frame trig.

**Hearing (closes this slice):** `AiPerception` gained a cold `hearing_range`
tunable and hot `heard_stimulus`/`heard_stimulus_x/y` columns
(`data_system/types.zig`, `data_system/perception.zig`), following the same
cold/hot split and `PerceptionStore.set`-preserves-hot-columns contract as
vision. `SimulationFrame` gained `stimuli: RangeOutputStream(WorldStimulus)`
(`simulation.zig`) — a transient per-step positional buffer
(`position`/`intensity`/`kind`/`level`, scalar-only), cleared every
`beginStep` and never promoted to a `SimulationEvent`, since it carries no
stable entity identity to transition against (only state *transitions*
become events, per the track-wide contract above). `intensity` is stored but
unused until a second producer exists to calibrate a falloff curve.
`DigController.process` is the sole producer today (`dig_controller.zig`),
appending one stimulus alongside its existing `world_tile_changed` event; its
sibling `carveLandingCell` (the fall/landing path) deliberately does not,
since it runs after `PerceptionSystem.update` in the same fixed step and
would be cleared before any hearing pass could read it — documented in place
rather than silently wired up wrong. Hearing is folded into
`PerceptionSystem.computeOneAgent` as a squared-distance range check gated by
same-level only (no FOV, no faction-stance gate — a stimulus is positional
and factionless), reading `frame.stimuli.mergedItems()` through a
`PerceptionConfig.stimuli` field. The stream itself needs no reserve call
from any owning module: its per-step count is a fixed producer invariant (at
most one, from `dig.process`), not scene-scale-dependent, so it grows lazily
on first use exactly like `PerceptionSystem`'s own gather buffers already do.
Tests cover range/level gating, nearest-of-multiple selection, hot-column
round-trip and preservation-on-retune, serial/threaded parity, and
`FailingAllocator` allocation-free proofs alongside vision's existing
coverage.

**LOS cost-risk fix (`hasLineOfSight`'s per-sample lookup is now O(1)):** this
slice originally shipped with `hasLineOfSight` calling
`WorldSystem.levelBlocksMovement` once per raycast sample, which linearly
rescans every sparse tile in the world on every call. `src/benchmarks/perception.zig`'s
`perception`/`perception-los-dense` groups proved this was a real hazard, not
theoretical: identical `sensed_count`/`los_checks`/`los_blocked`/
`nearest_threat_found_count` between the two fixtures, but the `-dense`
fixture (20,000 extra sparse tiles placed far outside any agent's path) paid
a 6.5x–10x wall-clock penalty purely from world-wide tile-count bulk.

The fix adds `PerceptionSystem.level_blocked`: a per-level, raw-world-tile-
granularity blocked bitmap (`LevelBlockedSlot`), built at most once per
distinct observer level per step by `ensureLevelBlockedCachesForObservers`/
`ensureLevelBlockedCache` (mirrors `pathfinding/nav_grid.zig`'s
`markWorldObstacles` shape — dense-band scan + sparse-tiles-filtered-to-level
pass — but with no nav-cell rect rasterization, since this bitmap is
tile-indexed 1:1). The build runs on the main thread before any range job is
dispatched; every worker range only ever reads the completed, per-step-stable
snapshot. `hasLineOfSight` now calls `lookupLevelBlocked` (an O(1) bitmap
read) per sample instead of `levelBlocksMovement`.

This slice deliberately did **not** reuse `pathfinding/nav_grid.zig`'s
already-resident, incrementally-maintained `NavGrid` (via
`NavGraph.grid(level)`), even though that would avoid a second structure.
Two independent findings ruled it out: (1) `NavGrid.blocked` is a strict
*superset* of `levelBlocksMovement`'s contract — it composes world obstacles
**OR** (on level 0 only) `DataSystem` static collision bodies
(`NavGrid.markStaticBodies`), so reusing it would silently occlude LOS behind
entities that `levelBlocksMovement` never blocks on, failing the parity test
by construction on any fixture with a level-0 static body not coincident with
a world tile; and (2) `NavGrid.cell_size` (32, set explicitly at
`rebuildStaticNavGrid`/`rebuildStaticNavGridWithWorld` call sites, e.g.
`game_demo_state.zig`'s `nav_cell_size = 32`) equals `WorldSystem.tile_size`
(also enforced to 32 at asset load, `world_tileset_meta.zig`'s
`required_tile_size`) only *incidentally* — two independently-set literals,
not an invariant enforced by an assert or a shared constant — so reuse would
also risk a silent LOS-granularity change if that ever drifted.
`NavGraph.grid(level)` is additionally nullable and only covers levels
pathfinding has actually built, which observers are not guaranteed to be
confined to. `PerceptionSystem` therefore owns its own cache, matching
`levelBlocksMovement`'s exact contract with zero cross-grid coordinate or
occlusion-set risk, proven by a dedicated parity test
(dense-blocked/sparse-blocked/open/out-of-range-level/out-of-range-cell, all
compared directly against `levelBlocksMovement`). The cache originally
rebuilt fully every step for every level touched that step (no
nav-invalidation-event-driven cross-step reuse) — a deliberate scope decision
at the time, not an oversight; see the residual note below, and the
incremental dirty-tracking fix that later replaced this (superseding the
residual note) further down this section.

Before/after (`--profile quick`, same methodology as this slice's original
risk-confirmation run), 10,000 agents, serial-direct: `perception` 33.60ms →
21.98ms; `perception-los-dense` 217.58ms → 25.74ms (was a 6.5x regression,
now 1.17x). Best-threaded case, 10,000 agents: `perception` ~6.24ms → 6.39ms
(unchanged, within run-to-run noise); `perception-los-dense` 25.81ms (over the
16.67ms/60Hz budget) → 9.64ms (`thread-small-range`, well under budget). Full
8-case tables at 1,024/4,096/10,000 agents for both groups are in this
change's PR/session record.

**Honest residual, not rounded away:** the two groups do not fully converge.
A fixed, non-scaling gap remains — measured best-case-threaded: ~2.99ms
(1,024 agents), ~2.89ms (4,096), ~3.25ms (10,000); serial-direct: ~2.63ms,
~3.27ms, ~3.76ms respectively. This gap is flat across a ~10x population
range (not proportional to agent count or `los_checks`, which are identical
between the two fixtures at every scale), which is itself the evidence the
per-sample lookup is genuinely O(1): the residual is entirely the once-per-step
cache-rebuild cost (a single O(world sparse-tile count) pass over the
`-dense` fixture's 20,000 extra tiles, paid once per step regardless of how
many agents or LOS samples run that step), not a per-sample or per-agent cost.
The realistic `perception` fixture shows no regression at all. Cross-step
caching (invalidating the bitmap only on an actual world-tile change, the same
way `PathfindingSystem` already reacts to nav-invalidation events) would
close this residual entirely but was deliberately deferred at the time — it
would touch the nav-invalidation event contract for a gap that only appears
in a fixture engineered specifically to be an unrealistic sparse-tile-density
torture test, not in any representative world density this project's other
benchmarks use. **This deferral is now superseded** — see "Incremental
dirty-tracked LOS-blocked cache" below, which implements exactly this and
closes the residual.

**Shared per-level sparse-tile index (root-cause fix behind the residual):**
after the LOS cost-risk fix above, a review pass found the *same*
scan-every-sparse-tile-then-filter-by-level pattern independently duplicated
in three places: `WorldSystem.levelBlocksMovement`, `NavGrid.markWorldObstacles`,
and `PerceptionSystem.ensureLevelBlockedCache` (added by this slice). Each
walked every `SparseTileRow` in the world checking `level_index` per tile,
even though a `SparseTileRow`'s level is fixed at insertion and never changes.
`WorldSystem` now carries a reverse per-level index —
`sparse_level_tiles: std.ArrayList(std.ArrayList(u32))`, one growable bucket of
`sparse_tiles` indices per level, plus the accessor
`sparseTileIndicesForLevel(level_index) []const u32` — maintained *eagerly*
inside `addSparseTile` (the sole inserter; tiles are never removed and never
reassigned to another level, confirmed by inspection) rather than lazily
rebuilt off a dirty flag. Eager maintenance was a deliberate deviation from
the `sparse_render_order`/`sparse_depth_ranges` render-index pattern this was
modeled after: that pattern's flat sorted-array-plus-ranges shape only stays
correct if rebuilt in full on every structural change, and `render_index_dirty`
is safely deferred only because its sole reader (`ensureRenderDepthIndex`) runs
once per render frame. `levelBlocksMovement`, `NavGrid.markWorldObstacles`, and
`PerceptionSystem.ensureLevelBlockedCache` do not have that luxury — they run
inside the fixed-step gameplay tick (nav reacting to a dig, perception
rebuilding its bitmap) and can be reached in the same step a sparse tile is
placed, before any render pass would run; a lazily-rebuilt index keyed off a
render-only dirty flag would have been stale for them. `sparse_level_tiles`
also cannot itself be shaped like `sparse_render_order` for the same reason:
keeping one level's run contiguous in a single flat array only works with a
full resort after every insert, which is exactly the O(n) rescan this index
exists to remove. All three consumers now iterate
`sparseTileIndicesForLevel(level)` instead of the whole `sparse_tiles` set.
Proof: a new `sparseTileIndicesForLevel` exact-set test (multiple levels,
interleaved insertion order, a level with zero sparse tiles, and an
out-of-range level) and a new `levelBlocksMovement` multi-level parity test
placing an obstacle on one level at a cell shared with two other levels
(`world_system.zig`); the existing `nav_graph.zig` incremental-update tests
(which compare `NavGrid`'s composed mask directly against
`levelBlocksMovement` cell-by-cell across every level of a multi-level demo
world) continued to pass unchanged, since the contract did not move, only the
scan did.

Measured effect on the `perception`/`perception-los-dense` gap (`--profile
quick`, same methodology as the numbers above): the `-dense` fixture's extra
20,000 sparse tiles all land on the *same single level* as the populated
region (`WorldSystem.initDemoFromMeta` never adds a second level), so this
fixture cannot exercise the index's intended cross-level win — the
scan-avoidance the three consumers now get on a genuinely multi-level world
(e.g. the underground stack `nav_graph.zig`'s tests build) does not apply
here. What the per-level index *did* remove from this single-level scan was
the redundant per-tile `sparseTileLevel(idx)` accessor call and its
`MultiArrayList.items(.level_index)` re-derivation on every one of the 20,000
tiles, replaced by one hoisted slice read up front. An isolated, same-session
A/B on identical 20,002-tile single-level data (30 back-to-back reps,
`world_system.zig`, removed after measurement) showed this specific loop drop
from ~784us/rebuild (old scan-and-filter) to ~45us/rebuild (new indexed
scan) — a ~17x reduction in the loop itself, with zero behavior change (both
loops agree on the blocked-tile count every rep).

At the full pipeline level, serial-direct, 10,000 agents: `perception` 22.74ms,
`perception-los-dense` 24.41ms — gap 1.67ms, versus the 3.76ms gap recorded
above before this fix. Note this "before" comes from this same slice's own
prior recorded numbers (above), not a controlled same-session revert of just
this change — the sandbox's revert-safety policy ruled out stashing the
working tree mid-task to get a stricter A/B, so the isolated loop measurement
below is the controlled proof for this specific change; the table comparison
against the prior recorded numbers is corroborating, not conclusive on its
own. Full table:

| agents | perception serial | los-dense serial | gap (was) | perception best-threaded | los-dense best-threaded | gap (was) |
|---|---|---|---|---|---|---|
| 1,024 | 3.42 ms | 5.43 ms | 2.01 ms (2.63 ms) | 2.24 ms | 4.13 ms | 1.89 ms (2.99 ms) |
| 4,096 | 9.89 ms | 11.76 ms | 1.87 ms (3.27 ms) | 3.77 ms | 5.61 ms | 1.84 ms (2.89 ms) |
| 10,000 | 22.74 ms | 24.41 ms | 1.67 ms (3.76 ms) | 6.49 ms | 8.34 ms | 1.85 ms (3.25 ms) |

**Honest, not rounded away:** the gap shrank meaningfully (24–56% serial,
36–43% threaded) but did **not** converge to indistinguishable, contrary to
this fix's original hypothesis (which assumed the `-dense` fixture's extra
tiles lived on a different level than the populated region — they do not).
The isolated loop measurement (~45us/rebuild) is far smaller than the
~1.7–2.0ms full-pipeline gap that remains; the difference is warm-vs-cold
cache, not an unaccounted cost: the isolated microbenchmark runs 30 reps
back-to-back, so the first rep warms the ~240KB working set (the u32 index
plus the gathered `cell_index`/`flags` columns) into L2, and every later rep
reads hot — but the real pipeline runs the rebuild exactly once per step,
sandwiched between thousands of agents' spatial queries and bitmap reads that
evict that working set, so every real rebuild pays a cold scan. A cold Debug
scan landing at ~1–1.6ms for ~240KB is plausible and consistent with the
observed residual. Closing it further (e.g. keeping the per-level working set
resident, or a spatial index within a level) is out of this task's scope,
which targeted the shared scan-and-filter duplication itself, not
cache-residency within a level. `pathfinding-hard-fallback` (which exercises
`levelBlocksMovement` directly via `simulation_pipeline.zig`'s local fallback
graph) was spot-checked at 64/128 item counts post-fix: all cases completed
with `fallback_requests == results` and no dropped/evicted requests, i.e. no
functional regression; no controlled before/after number exists for this
group specifically.

**Multi-level proof for `NavGrid.markWorldObstacles`, transitively:** no
dedicated multi-level-sparse `markWorldObstacles` test was added, but the
requirement is still covered by chaining existing tests rather than by a new
fixture: `sparseTileIndicesForLevel`'s exact-set test (above) proves the new
per-level index itself is correct across levels with interleaved insertion
order; both `markWorldObstacles` and `levelBlocksMovement` now read that same
index; and `nav_graph.zig`'s existing incremental-update tests compare
`NavGrid`'s composed blocked mask against `levelBlocksMovement` cell-by-cell
across every level of a multi-level demo world. That chain — not the
`nav_graph.zig` test alone, since both sides of that comparison changed
together and a consistent-but-wrong shared index would still pass it — is
what anchors correctness; the exact-set test and `levelBlocksMovement`'s own
hardcoded-value assertions are the load-bearing proof underneath it.

**Allocation and concurrency:** `sparseTileIndicesForLevel` and
`levelBlocksMovement` take no allocator, so they cannot allocate by
construction — reading the per-level index adds no new allocation risk on top
of `PerceptionSystem`'s existing `FailingAllocator` steady-state proof, which
already drives `ensureLevelBlockedCache`'s rebuild end to end. `sparse_level_tiles`
and its chunk-bucketed sibling `sparse_level_chunk_tiles` (see
`sparseTileIndicesForChunk`) are mutated only inside `addSparseTile`, a
main-thread structural edit; the threaded nav-remask and perception phases
only ever read them, so this adds no new concurrent-access hazard.
`addSparseTile` now reserves capacity in `sparse_tiles`, `sparse_level_tiles`,
and `sparse_level_chunk_tiles` up front (`reserveSparseLevelIndexEntry`,
`reserveSparseChunkIndexEntry`) before appending to any of them
(`commitSparseLevelIndexEntry`, `commitSparseChunkIndexEntry`), closing the
gap that used to exist here: an allocation failure partway through can no
longer leave a tile present in one structure but absent from the other two.
A `FailingAllocator` test drives a failure at each of the three reservation
steps and asserts all three structures are unchanged afterward.

**Incremental dirty-tracked LOS-blocked cache (closes the residual above):**
`ensureLevelBlockedCache` originally keyed staleness only on
`PerceptionSystem.step_counter` — since that counter is unique per step, every
distinct level touched by an observer paid a full rebuild every single step,
regardless of whether the world actually changed since the last build. This
is now replaced with NavGraph-style incremental patching, mirroring
`PathfindingSystem`'s post-commit nav reaction but deliberately narrower:

- `LevelBlockedSlot` gains `pending_dirty: std.ArrayList(DirtyRect)`, a plain
  min-inclusive/max-exclusive rect list (not `NavGrid`'s chunk-grid
  `NavCellEdit` — reusing that would couple this file to nav's chunk-grid
  shape for no benefit; the chunk grid is only consulted transiently, at
  patch time, to scope the sparse-tile rescan). It grows rather than drops on
  append (same must-not-lose-an-edit contract as
  `PathfindingSystem.nav_dirty_edits`) and, unlike that per-step-drained
  buffer, can persist across MULTIPLE untouched steps: a level with no
  observer this step is never asked to rebuild, so edits on it simply
  accumulate until an observer next looks at it.
- `PerceptionSystem.reactToPostCommitPerceptionEvents(frame, world)` — a new
  pipeline-level reaction (`SimulationPipeline.reactToPostCommitPerceptionEvents`,
  called alongside `reactToPostCommitNavEvents` at every one of its call
  sites; the two are fully independent side effects on disjoint state, so
  call order does not matter) — filters `frame.events.mergedItems()` to
  exactly `.world_tile_changed` (single-cell rect, only when the
  movement-blocking flag actually flipped) and `.world_obstacle_changed` (the
  event's own already-multi-cell rect), pushing a `DirtyRect` into the
  relevant level's `pending_dirty`. This is deliberately narrower than
  `PathfindingSystem.eventInvalidatesNavigation`: no other event variant is
  read, and there is no non-localizable whole-level fallback case (unlike
  nav's fallback for entity-obstacle toggles, which this cache never needs to
  react to, since it only ever reads world tiles). No event is emitted in
  return — nothing currently reacts to "perception's cache changed."
- `ensureLevelBlockedCache`'s decision tree, after the existing "already built
  this exact step" short-circuit: first-ever build for a level runs the full
  rebuild unchanged (discarding any `pending_dirty` recorded before that first
  build, rather than replaying it as a patch — the fresh rebuild already
  reflects current world state directly); an already-built slot with an empty
  `pending_dirty` SKIPS the rescan entirely (the headline fix — this case
  never used to happen, since staleness was keyed only on the step counter,
  not on whether anything changed); an already-built slot with a bounded
  amount of pending dirty area PATCHES only the affected cells (`@memset`
  false first per rect, since a bit can go blocked→unblocked and not just the
  reverse, then rescans only that rect per relevant dense layer and only the
  sparse tiles in the rect's overlapping level-local chunks via
  `WorldSystem.sparseTileIndicesForChunk`, bounding the sparse-side candidate
  set by chunk population instead of level population); an already-built slot
  whose accumulated dirty area exceeds a quarter of the level's total cells
  falls back to a full rebuild instead (patch overhead — a memset, rescan,
  and chunk walk per pending rect — starts to rival one dense full pass well
  before "half the level changed"; the 25% constant mirrors the spirit of
  `nav_graph.zig`'s `full_relabel_level_threshold`, which caps affected
  *levels* rather than a fraction of one level's *cells*, the finer unit this
  cache actually works in). `WorldSystem.chunksX`/`chunksY` (the level-local
  chunk grid shape, previously private) are now `pub` so this patch-time
  chunk-range computation can live in `perception.zig` without duplicating
  `localChunkIndexForCell`'s per-cell arithmetic.
- Proof: parity tests compare a patched/skipped/fallback-rebuilt result
  bit-for-bit against a fresh full rebuild of the same post-edit world state,
  covering a single dense-tile flip (both directions), a single sparse-tile
  add, a simulated sparse-tile blocking removal (two independently built
  `WorldSystem`s, since sparse tiles are append-only with no removal API — see
  `sparse_level_tiles`'s doc comment), a multi-cell `world_obstacle_changed`
  rect, dirty rects accumulated across several untouched steps before the
  level is next touched, an edit recorded before a level's first-ever build
  (discarded, not replayed), and the full-rebuild-threshold fallback path. A
  dedicated `FailingAllocator` test proves the steady-state patch path (and
  the dirty-rect bookkeeping that feeds it) allocates nothing once
  `pending_dirty`'s capacity has plateaued. The existing serial/threaded
  parity test continues to pass unchanged (the skip/patch/rebuild decision
  still happens entirely on the main thread, before any worker dispatch, same
  as the old unconditional rebuild).
- Measured effect (`--profile quick`): two new benchmark groups,
  `perception-cache-full-rebuild` and `perception-cache-patch`, isolate the
  cache-maintenance cost itself by reporting one synthetic structural-commit
  event per iteration (a whole-level rect vs. a single-cell rect) against
  `perception`'s own representative-density fixture, so `sensed_count`/
  `los_checks`/`nearest_threat_found_count` stay identical between the two and
  only wall-clock cost differs — serial-direct: 1,024 agents 3.58ms
  (full-rebuild-forced) vs 2.25ms (patch), 4,096 agents 11.74ms vs 10.75ms,
  10,000 agents 29.10ms vs 26.61ms; best-threaded: 1,024 agents 1.97ms vs
  0.65ms, 4,096 agents 3.85ms vs 2.41ms, 10,000 agents 7.58ms vs 6.10ms — a
  roughly flat ~1.3–1.5ms gap across a ~10x population range, confirming the
  gap really is the once-per-step cache-maintenance cost and not a per-agent
  cost. More directly, this fix also re-closes the `perception`/
  `perception-los-dense` residual documented above, since neither of those
  fixtures' positions ever change across iterations and neither calls
  `reactToPostCommitPerceptionEvents`, so every measured step after the first
  now skips instead of rebuilding: re-measured at 10,000 agents,
  `perception` 26.92ms serial / 6.09ms best-threaded, `perception-los-dense`
  27.31ms serial / 6.11ms best-threaded — a ~0.4ms/~0.02ms gap, down from the
  1.67ms/1.85ms gap recorded right after the shared-index fix and the
  original 3.76ms/3.25ms gap before any of this slice's LOS-cost work. See
  `src/benchmarks/perception.zig`'s module doc for the full write-up.

**LOS correctness fix (diagonal tunneling):** a review pass found that
`hasLineOfSight`'s original sampling — fixed `step_count = ceil(distance /
tile_size)` linear-interpolation samples along the ray, each checked against
`lookupLevelBlocked` — was not a true grid traversal. Consecutive samples on a
non-45-degree diagonal ray can straddle a gridline such that the continuous
segment passes through a blocking cell's interior without either sample ever
landing inside it, so a single-tile diagonal occluder could be silently
skipped and `target_visible`/`nearest_threat` set as if the wall weren't
there. The existing corner-grazing 45-degree test did not exercise this (a
perfectly corner-aligned line only ever touches cell corners, a measure-zero
case, and never crosses a cell's interior off-axis).

The fix replaces the fixed-step sampler with a proper Amanatides-Woo grid/DDA
walk that visits every cell the segment's interior actually crosses between
observer and target, still checking each visited cell with the same O(1)
`lookupLevelBlocked` lookup, with an early exit on the first blocked cell. The
defensive step ceiling (`los_max_steps`, 32) is now `los_max_cells` (64,
doubled headroom since Manhattan cell counts on a diagonal run higher than
the old Euclidean-based step count); hitting it now fails closed (returns
blocked) rather than coarsening resolution while still resolving the
endpoint — unreachable under any valid `AiPerception` config, a fallback for
pathological input only. A dedicated regression test reproduces a mid-segment
diagonal occluder a corner-grazing case would miss (observer/target placed so
the ray's true path crosses one cell's interior that no fixed-step sample
would land in) and confirms it is now correctly reported as blocked.
Benchmarked at 1,024 and 10,000 agents (`--group perception`): best-threaded
612.66us and 6.07ms respectively, in the same range as the cache-fix numbers
above — the cell-walk correctness fix adds no measurable per-agent cost.

**Perception event budget is caller-sized, not a floating default:**
`PerceptionConfig.max_events_per_step` (library default 512) was never
derived from the real per-step `frame.events` capacity a caller reserves via
`SimulationFrame.reserveStreams`. Once enough observers change visibility in
the same step to push the merged perception-event total past that real
budget, `mergePerceptionEvents`'s `prefixAppendedRanges` call throws
`error.EventCapacityExceeded` — unhandled all the way out of the fixed-step
loop, not the graceful truncate-and-drop the module intends. `SimulationPipelineConfig`
now carries `perception_max_events_per_step` (default `0`, following the same
caller-sized-capacity convention as `contact_capacity`/`static_obstacle_capacity`),
threaded into `PerceptionConfig` at the pipeline's perception call site. A
static caller-declared share was chosen over reading remaining capacity at
perception's call time, since perception runs before later
event-emitting stages (structural commits, nav invalidation) that would
otherwise inherit the same unhandled-throw risk on headroom perception
consumed first. `game_demo_state.zig`'s `demo_event_reserve` (83) needs no
added term today: no demo entity attaches `AiPerception`, so
`perception_max_events_per_step` stays `0` and perception's real contribution
to the shared budget is `0` by construction; a state that wires up
`AiPerception` must size this field against its own reserve. A compact test
(tight capacity, two observer/hostile pairs, `perception_max_events_per_step
= 1`) proves the graceful-drop path: no throw, `dropped_events == 1`.

Goal: let agents sense other entities (and later sounds) within vision/hearing
limits, writing per-frame sensed state to columns and emitting only acquisition/
loss transitions as events.

Current foundation:

- AI today perceives only an aggregate seek target and separation neighbors
  (`systems/ai.zig`); there is no range/FOV/line-of-sight sensing and no notion
  of distinct sensed entities.
- Slice 26 supplies faction stance; Slice 28 supplies a shared spatial index;
  Slice 21 supplies the event contract.
- Slice 34 deferred the vector sin/cos polynomial approximation to here:
  `simd.sinFloat4`/`cosFloat4`/`sinCosFloat4` exist today only as thin
  `@sin`/`@cos` vector-builtin wrappers with no production caller. If this
  slice's FOV math needs batched-angle trig across many agents, implement and
  benchmark the real polynomial (with a documented error bound and scalar
  fallback) here, against this slice's actual workload.

Architecture notes:

- Runs as a parallel processor stage before AI decision. High-volume per-frame
  sense results are columnar; only transitions are events.
- Hearing depends on a world stimulus/sound-emission buffer; ship vision-first
  and gate hearing behind that buffer (tracked in this slice's checklist).

Checklist:

- [x] Add an `AiPerception` component: cold tunables (vision range, FOV
      half-angle, hearing range) plus hot output columns (`target_visible`,
      `last_seen_x/y`, `nearest_threat: EntityId`, `nearest_threat_dist`).
      `vision_range`/`fov_half_angle_radians`/`hearing_range` (cold), the
      derived `cos_half_fov`, the four listed hot output columns, plus
      `facing_x/y` and `heard_stimulus`/`heard_stimulus_x/y` hot columns the
      original wording didn't anticipate, are all landed in
      `data_system/perception.zig`.
- [x] Add a `PerceptionSystem` parallel stage that queries the shared spatial
      index for candidates, then applies bounded range/FOV/line-of-sight checks
      (LOS against world blocking tiles via `world_system` walkability), writing
      results to perception columns.
- [x] Add scalar-only `entity_perceived` / `entity_lost` event payloads for
      target acquisition/loss transitions, emitted at `domain_reaction` via the
      per-range writer with pre-reserved capacity.
- [x] Add a transient per-step world stimulus/sound buffer (position +
      intensity + type, scalar-only) and consume it for hearing; keep it separate
      from the audio playback service. `SimulationFrame.stimuli`
      (`RangeOutputStream(WorldStimulus)`, `simulation.zig`) is the buffer;
      `DigController.process` is the sole producer; hearing is folded into
      `PerceptionSystem.computeOneAgent` as a same-level squared-distance
      check. See "Hearing (closes this slice)" above for the full account,
      including why `carveLandingCell` does not also produce one.

Acceptance checks:

- [x] Per-frame sense results live in columns, not events; only transitions emit
      events, bounded by a per-step cap with drops surfaced via event stats.
- [x] Serial and threaded perception produce identical columns and event order.
- [x] Sensing is allocation-free after warmup and runs only for cognition-tier
      entities in scope.
- [x] `zig build test` covers range/FOV/LOS gating, transition events, and
      serial/threaded parity.
- [x] `hasLineOfSight`'s per-cell blocked test is O(1) (`level_blocked`'s
      per-level bitmap cache, kept current for a distinct observer level at
      most once per step via a skip/patch/rebuild decision — see "Incremental
      dirty-tracked LOS-blocked cache" above), proven behavior-identical to
      `WorldSystem.levelBlocksMovement` by dedicated parity tests (including
      patch-vs-fresh-rebuild parity across every dirty-tracking case), and
      proven allocation-free after warmup by dedicated `FailingAllocator`
      assertions (serial, threaded, and the dirty-tracked patch path). The
      `perception-los-dense` benchmark confirms the original fix in practice:
      10,000 agents best-threaded went from 25.81ms (over the 16.67ms/60Hz
      budget) to 9.64ms; the incremental dirty-tracking fix further closed
      the once-per-step cache-rebuild residual that fix left behind (see
      above for the full before/after and the honestly-reported numbers at
      each stage).
- [x] `computeOneAgent`'s scatter writes into `job.perception_slice` at
      `perception_dense_index[i]` were checked for cross-worker false-sharing
      risk: the `perception-scattered-dense-index` benchmark
      (`benchmarks/perception.zig`) shuffles `perception_dense_index` so
      worker ranges write genuinely interleaved (same-cache-line) slots, unlike
      `perception`/`perception-los-dense`'s near-monotonic assignment. At
      50,000 agents this decorrelated case was not slower than the correlated
      one (4.42x/4.54x vs 4.34x/4.49x threaded speedup, within noise), with
      identical `sensed_count`/`los_checks`/`los_blocked`/
      `nearest_threat_found_count` confirming only store-write locality
      changed. Conclusion: measured, no regression — the per-agent
      spatial-query/FOV/LOS cost dwarfs the 5 scattered writes, so the direct
      scatter is left as-is rather than rewritten to a dense-pass-then-
      serial-scatter pattern.
- [x] `hasLineOfSight` walks every grid cell the segment's interior crosses
      (Amanatides-Woo DDA), not fixed-distance samples, closing a diagonal-
      tunneling gap where a mid-segment occluder could be skipped; proven by a
      dedicated regression test and re-benchmarked with no measurable
      per-agent cost regression. See "LOS correctness fix (diagonal
      tunneling)" above.
- [x] Perception's per-step event cap is caller-sized against the real
      `frame.events` capacity (`SimulationPipelineConfig.perception_max_events_per_step`,
      default `0`), not left at the library's permissive 512 default; proven
      by a tight-capacity test asserting graceful drop-and-report instead of
      an unhandled `error.EventCapacityExceeded`. See "Perception event budget
      is caller-sized, not a floating default" above.

## Slice 30: AI Memory And Scope-Aware AI State Policy

Goal: give agents short-term memory of recent contacts and last-known positions
with decay, and define what happens to AI state when an entity leaves the
cognition tier.

Current foundation:

- No per-entity memory exists; AI reacts only to current-frame inputs.
- Slice 24 introduces tier promotion/demotion; this slice defines the state
  policy across those transitions.

Checklist:

- [ ] Add an `AiMemory` component with fixed-size scalar columns: last-known
      target position + staleness timer, a small fixed-capacity recent-contact
      ring (entity id + last-seen pos + age), and a spatial familiarity scalar —
      no per-entity `ArrayList` on the hot path.
- [ ] Refresh memory from perception transitions and decay it each step
      (staleness++, familiarity toward baseline); vectorizable column math.
- [ ] Feed memory to AI when perception is cold (e.g. pursue last-known
      position).
- [ ] Implement the scope ↔ AI-state policy: freeze memory/affect decay on
      demotion out of cognition, resync on promotion, routed through the Slice 24
      deferred-commit path; no background per-frame work for out-of-scope agents.
- [ ] Optional `memory_expired` event (scalar-only, `domain_reaction`) if a
      reaction needs it; otherwise memory stays purely columnar.

Acceptance checks:

- [ ] Memory updates and decay are deterministic and allocation-free; fixed-size
      storage never grows per frame.
- [ ] Demoted entities preserve state with decay paused and resume correctly on
      promotion.
- [ ] `zig build test` covers refresh-from-perception, decay, ring eviction, and
      demotion/promotion state continuity.

## Slice 31: AI Affect And Emotion Drives

Goal: add an appraisal-driven scalar emotion model whose drives modulate behavior
weights, decaying toward per-entity baselines.

Current foundation:

- No affective/emotional state exists. `data_system.zig` already provides
  SIMD-aligned hot f32 column support reusable for drive columns.
- Perception (29) and memory (30) provide the appraisal inputs.

Architecture notes:

- Drives are a small fixed set (`fear`, `curiosity`, `aggression`, `fatigue`) as
  hot SIMD-aligned f32 columns; the update is pure column math that vectorizes
  like movement integration (`systems/movement.zig`).

Checklist:

- [ ] Add an `AiAffect` component with fixed scalar drive columns plus per-entity
      baselines, SIMD-aligned.
- [ ] Add an `AffectSystem` parallel/SIMD stage that appraises perception +
      memory into drive deltas, applies them, and decays each drive toward its
      baseline; bounded, allocation-free, deterministic.
- [ ] Expose drives to behavior arbitration (Slice 32) as weight modulators
      (fear → flee weight + speed, curiosity → investigate weight, fatigue → max
      speed).
- [ ] Add scalar-only `affect_threshold_crossed { entity, drive, rising }` events
      for threshold crossings (panic onset/calm) at `domain_reaction`.

Acceptance checks:

- [ ] Scalar and SIMD affect updates produce identical results (parity test).
- [ ] Drives stay bounded and decay to baseline with no inputs; updates are
      allocation-free.
- [ ] Threshold events are low-volume by construction and capacity-bounded.
- [ ] `zig build test` covers appraisal, decay-to-baseline, and threshold events.

## Slice 32: AI Behavior Arbitration

Goal: select among composed behaviors (flee, pursue, investigate, group/cohere)
by weighted arbitration over drives, memory, and perception, producing the
existing `NavigationIntent` so downstream steering/pathfinding/movement are
unchanged.

Current foundation:

- `AiBehavior` is `wander`/`seek` and `decideDir()` blends wander + seek +
  separation (`systems/ai.zig`); AI emits `NavigationIntent` consumed by steering
  (`simulation.zig`).
- Slices 29–31 supply perception, memory, and affect inputs.

Architecture notes:

- Arbitration is a weighted blend (data-oriented), not an FSM, so it stays
  vectorizable and emergent. Emergence comes from richer intent inputs, not new
  pipeline plumbing — the intent → steering → pathfinding → movement contract is
  untouched.

Checklist:

- [ ] Extend `AiBehavior` and `decideDir()` with `flee`, `pursue`, `investigate`,
      and `group/cohere`.
- [ ] Compute behavior selection as a weighted arbitration over affect drives
      (31), memory (30), and perception (29), emitting `NavigationIntent` +
      priority through the existing path.
- [ ] Keep steering/pathfinding/movement and their merge contracts unchanged.

Acceptance checks:

- [ ] Behavior selection is deterministic and allocation-free; serial == threaded.
- [ ] Downstream steering/pathfinding/movement contracts are unchanged (no new
      pipeline stages downstream of AI).
- [ ] `zig build test` covers each behavior's intent output and arbitration
      blending.

## Slice 33: Data-Driven AI Archetypes And Debug Introspection

Goal: make the emergent-AI stack authorable without recompiling and observable
for tuning.

Current foundation:

- Demo spawn specs are hardcoded in `game_demo_state.zig`; tuning drives or
  behaviors means editing source.
- A debug overlay exists in the render layer but has no AI introspection.
- The atlas-metadata workflow is an established JSON-sidecar pattern to mirror.

Checklist:

- [ ] Add JSON-sidecar AI archetype definitions (faction, perception, memory,
      affect, behavior tunables) resolved to component bundles at load, mirroring
      the atlas-metadata workflow; validate strictly.
- [ ] Migrate demo spawns to named archetypes (e.g. timid / curious /
      aggressive) exercising emergent flee / pursue / investigate / cohere.
- [ ] Extend the debug overlay to draw vision cones, drive bars, last-known
      memory markers, current behavior, and Slice 24 scope/tier counts.

Acceptance checks:

- [ ] Archetypes load from data with strict validation and persist via stable
      asset IDs / enum tunables, not paths or live handles.
- [ ] Debug overlay visualizes perception, affect, memory, behavior, and scope
      without affecting simulation determinism.
- [ ] `zig build verify` passes; demo shows emergent interplay (timid agents
      flee, curious investigate, threats pursue, crowds cohere).

## Slice 34: Core SIMD Primitive Layer Expansion And Dense-Path Wins

**Status: landed, with two items deferred/reverted by evidence.** The gather/
scatter, rsqrt/normalize, sprite-transform, and AI-memset items were already
shipped pre-existing. The packed-SoA-scratch idiom doc landed. The batched
`lerpVec2Float4` primitive landed (correct, tested) but its `render_prep.zig`
consumer was **built, benchmarked, and reverted** — see item 6 below. The
sin/cos polynomial stays deferred to Slice 29.

> Doc-drift note: this section previously listed every item below as `[ ]`
> "Not started." Direct code reading found most of this slice had already
> shipped in earlier commits without the roadmap being updated — the gather/
> scatter helper, rsqrt/normalize, the sprite vertex-transform vectorization,
> and the AI separation-grid `@memset` all predate this correction pass (see
> commit `a723821`, "updated collisions hand rolled gather 4 into SIMD.zig",
> and the `world` branch changelog's "Expanded `src/core/simd.zig` and
> `src/core/math.zig` with reusable gather, normalize, sin/cos, and tail
> helpers"). This pass corrects the stale checkboxes and lands the packed-
> SoA-scratch idiom documentation. It also attempted the batched-lerp item
> (item 6) with a `render_prep.zig` consumer, measured it rigorously, found no
> real win, and reverted the consumer — see item 6 for the full account,
> including a caution about benchmark methodology worth reading before trying
> this again. Two items are **reinterpreted, not implemented as originally
> worded** — see the notes on items 3 and 5 below.

Goal: extend `src/core/simd.zig` with the vector primitives the SIMD-first
gameplay/AI stages will need, and land the layout-independent dense-path
vectorization wins that are measurable today. This is foundational and should
land before the SIMD-first emergent-AI stages (Slices 29–32) so they build on
shared primitives instead of each hand-rolling gather/rsqrt/normalize. The
applicability policy itself already lives in `docs/coding-standards.md`.

Why now: the primitive layer is foundation — its absence forces every new stage
to reinvent gather and normalize and risks drift. The dense-path wins
(sprite_batch, batched lerp) are low-risk and benchmarkable now via the existing
render-prep profile. Restructuring the existing AI/steering hot loops is NOT in
this slice — that is optimization that must be validated at battle scale and is
deferred to Slice 35.

Current foundation (already vectorized through `src/core/simd.zig`, with scalar
tails, no raw `@Vector` in systems):

- `systems/movement.zig` — position/velocity integration over SoA columns.
- `systems/collision.zig` — broadphase AABB sweep and narrowphase contact math,
  both ported onto the shared `simd.gatherFloat4`/`scatterFloat4` helpers
  (`a723821`) — no local hand-rolled `gather4` remains.
- `systems/collision_response.zig` — normal/penetration/velocity correction math.
- `systems/particle.zig` — particle integration and color/size lerp.
- `systems/pathfinding.zig` — flow-field octile heuristic and nav-grid marking;
  `pathfinding_range_alignment_items = simd.lane_count`.
- `game/render_prep.zig`'s `collectDynamicRecords` interpolation loops remain
  scalar `math.lerp` per entity/particle — a batched version was built and
  reverted; see item 6 below for why.
- The helper exposes `Float4/Int4/Mask4`, arithmetic, compare, select, clamp,
  gather/scatter, reciprocal-sqrt/normalize, sin/cos, lerp (including the
  `Vec2x4` batched `lerpVec2Float4`), and tail helpers, with a single
  `lane_count` source of width and a documented packed-SoA-scratch idiom on
  `gatherFloat4`.

Checklist:

- [x] Add gather/scatter helpers to `core/simd.zig`, generalizing collision's
      local `gather4`; port collision to the shared helper. Landed pre-existing
      (`a723821`); `gatherFloat4`/`gatherInt4`/`scatterFloat4` are in
      `core/simd.zig`, collision's broadphase/narrowphase call them directly.
- [x] Add reciprocal-sqrt / inverse-length and a vectorized 2D normalize with a
      masked zero-guard (matching the scalar `normalizeOrZero` semantics).
      Landed pre-existing: `reciprocalSqrtFloat4`/`normalizeOrZero2Float4`.
- [ ] Add a vector sin/cos (or sincos) approximation with a documented error
      bound and a scalar fallback path. **Deferred, not implemented.**
      `sinFloat4`/`cosFloat4`/`sinCosFloat4` exist as thin `@sin`/`@cos`
      vector-builtin wrappers (correct, but not a polynomial approximation),
      and have **zero production callers** today. Building a bespoke
      polynomial with no consumer would be unmeasurable, premature
      optimization. Deferred to Slice 29 (AI Perception), the first stage
      needing batched-angle FOV trig across many agents — implement and
      benchmark it there, against a real workload, not here.
- [x] Document the packed-SoA-scratch idiom in `core/simd.zig` (or a sibling
      helper) so later stages reuse one gather-into-lanes pattern. Landed this
      pass: a worked-example doc block on `gatherFloat4` citing
      `CollisionSystem.buildBroadphaseCandidatesSimd`/
      `writeNarrowphaseContactsSimd` as the canonical existing example.
- [x] Vectorize the sprite vertex transform in `render/sprite_batch.zig`
      (`writePreparedSpriteVertices` / `fillPreparedRange`). **Reinterpreted:**
      `writeSpriteQuad` already vectorizes the 4-corner rotation+translation via
      `Float4` math (landed pre-existing). The "camera transform" and
      "coordinate_space branch" clauses in the original wording no longer map
      onto the code as it evolved — the camera transform is baked into the GPU
      vertex uniform (no CPU-side camera math exists to vectorize), and
      `coordinate_space` is read only in `buildDrawGroups` for draw-group
      boundaries, not in the per-vertex emit path, so there is no branch there
      to mask.
- [x] Replace the AI separation-grid zero-fill (`systems/ai.zig`) with `@memset`
      or a vector fill. Landed pre-existing: `resetSeparationScratch` already
      zero-fills via `@memset` (the separation grid itself was replaced by
      `SpatialIndexSystem` in Slice 28).
- [x] Add a batched `lerpVec2` path in `core/math.zig` for render interpolation
      when the interpolation pass iterates many entities over contiguous
      columns. **Primitive landed, consumer reverted.** `lerpVec2Float4`
      landed in `core/simd.zig` (co-located with the other `Vec2x4` SIMD
      primitives it mirrors, not `core/math.zig` as originally worded) — it is
      correct and bit-exact parity-tested, and stays, currently without a
      production caller (same situation as `sinCosFloat4`, item 3).
      `game/render_prep.zig`'s `collectDynamicRecords` was restructured to
      consume it (buffer `simd.lane_count` already-scalar-filtered candidates
      → `gatherFloat4` → `lerpVec2Float4` → per-lane finish, scalar tail for
      the remainder) and initially reported as a ~6–9% `entity_collect` win.
      That result did not reproduce and the consumer was reverted:
      - The original comparison was against a stale `benchmark_outputs/`
        file from a non-adjacent ancestor commit, 9 commits and 226 unrelated
        `render_prep.zig` lines removed from the true parent — the true
        unmodified parent commit, measured in isolation, was itself ~2–6%
        faster than that stale baseline at every scale, which alone accounts
        for most of the falsely-reported win. Lesson: a benchmark file's age
        isn't the issue (that's what `benchmark_outputs/` history is for);
        comparing against a **non-adjacent commit with unrelated changes in
        the exact function under test** is.
      - The first "real" comparison also ran under the default `Debug`
        optimize mode, where per-element safety checks can dominate and mask
        (or invert) whatever a vectorized change would show under the
        `ReleaseFast` mode this project actually ships.
      - A corrected, controlled comparison (`git worktree` at the true parent
        commit, 8 repeated runs per side, both `Debug` and `--release=fast`)
        found **no reliable win at any scale, and a real ~5–15% regression at
        two of three scales under `--release=fast`** — confirmed
        independently by a `zig-review-specialist` review that reproduced the
        regression before the corrected comparison above was even run.
      - Root cause: `collectDynamicRecords`'s interpolation loop is
        memory-bound and dominated by non-vectorizable branchy work (asset-
        reference resolution, AABB cull, draw-record construction) — the two
        float lerps being batched were never the bottleneck. The batching
        overhead (scattered-index gather lowers to scalar loads + vector
        inserts, not a hardware gather; per-lane extract to feed the still-
        scalar finish work; stack-buffer bookkeeping; a by-value 4-candidate
        struct array passed to a non-trivially-sized function that may not
        fully inline) cost more than the ~24 scalar flops it replaced could
        ever save. This is a poor fit for the packed-SoA-scratch idiom
        compared to collision.zig's canonical use (compare/select-bound over
        many candidates, not memory/branch-bound over a few).
      Before retrying this consumer, either (a) profile first to confirm
      `collectDynamicRecords` is actually a hot path at real gameplay scale
      (not bench-fixture scale), or (b) extend the batch to vectorize the
      AABB cull alongside the lerp (gather `visual_index`-indexed
      `size_x`/`size_y`, compute the overlap mask in-lane) so the vectorized
      portion amortizes its own gather/extract cost over more work — both
      unverified, next-step ideas, not requirements.

Acceptance checks:

- [x] New primitives have unit tests and scalar-vs-SIMD parity tests; numeric
      approximations (rsqrt, sin/cos) document error bounds and keep a scalar
      fallback. `lerpVec2Float4` has a bit-exact parity test against
      `math.lerpVec2` (no fast-math in this codebase, so `expectEqual`, not an
      approximate tolerance, is the correct — and stronger — check). Sin/cos
      approximation remains deferred per above.
- [x] Collision narrowphase produces identical contacts after porting to the
      shared gather helper (parity test) — landed pre-existing.
- [x] `zig build bench` shows a render-prep win at 10k–50k sprites with no
      regression at low counts. **Not satisfied by `render_prep.zig`'s
      interpolation loop** — see item 6's full account: a controlled
      before/after comparison found no reliable win and a real regression at
      two of three scales, so that consumer was reverted rather than kept
      against this acceptance bar. The primitive-layer items (gather/scatter,
      rsqrt/normalize, sprite-transform vectorization) that this check was
      originally written against were already landed pre-existing and are
      unaffected by the revert.
- [x] Systems use `src/core/simd.zig` helpers, not raw `@Vector`.
- [x] `zig build verify` passes.

## Slice 35: AI And Steering Hot-Loop SIMD Restructure

Goal: restructure the existing scalar per-agent / per-neighbor loops in AI and
steering into packed-SoA-scratch vectorized kernels, so they hold up in heavy
scenes, large battles, and late-game worlds where they become the dominant cost.

Why deferred (not part of Slice 34): this is optimization, not foundation, and
its acceptance is defined at target scale. It needs the Slice 34 primitive layer,
Slice 24 scoping (which determines how many entities actually reach these loops
per step), and a way to spawn representative agent counts (Slice 33 archetypes or
a stress spawner) so wins and regressions can be measured at battle scale rather
than demo scale. Doing it before that is optimizing against guessed load, and the
emergent-AI slices (29–32) will reshape these systems anyway — new stages are
built SIMD-first per the track contract, so this slice targets the pre-existing
loops.

Current foundation:

- AI separation accumulation and decision math (`systems/ai.zig`) and steering
  neighbor/obstacle avoidance (`systems/steering.zig`) are scalar today because of
  sparse-index gather and per-element early exits — a data-layout limitation, not
  an inherent one.
- Slice 34 supplies gather/rsqrt/normalize/sincos and the packed-SoA-scratch idiom.

Checklist:

- [ ] Restructure AI separation accumulation: gather each agent's in-range
      neighbors once into packed SoA scratch, vectorize the
      `dx, dy, dist2, inv_sqrt, accumulate` math, and replace the per-neighbor
      early exit with a bounded mask.
- [ ] Vectorize AI decision math (`decideDir`, wander/seek blend, normalize)
      across agents using `select`-masked branches instead of per-agent control
      flow.
- [ ] Restructure steering neighbor/obstacle avoidance: pack sampled neighbors and
      obstacle boxes into local SoA scratch, vectorize the
      distance/push/normalize/blend force math, and keep the dynamic sampling
      bound as a batched mask.

Acceptance checks:

- [ ] Each restructured path has scalar-vs-SIMD and serial-vs-threaded parity
      tests (bit-stable across layouts).
- [ ] `zig build bench` shows wins at high neighbor/agent counts measured at
      target battle scale, with no regression at low counts.
- [ ] Gather-into-SoA-scratch buffers are allocation-free after warmup and
      reserved up front.
- [ ] Only irreducibly scalar loops (pathfinding frontier traversal/portal
      linking, particle swap-remove) remain scalar, each documented with the
      reason per the coding-standards policy.
- [ ] `zig build verify` passes.

## Suggested Order

0. Runtime diagnostics policy.
1. Input routing.
2. Logical resolution and viewport policy.
3. Render resource layer.
4. Asset cache.
5. Text and font service.
6. Renderer composition.
7. Preallocated thread system and parallel render prep.
8. Shader and platform expansion.
9. Platform-neutral SIMD helper layer.
10. DataSystem and SoA composition foundation.
11. SIMD-aware data processor systems.
12. Simulation contracts and deferred structural changes.
13. Spatial queries and collision contacts.
14. First AI intent processor and future rule contracts.
15. SDL3_mixer audio service.
16. Main menu and settings menu.
17. Startup runtime asset catalog.
18. Frame-delayed pathfinding system.
19. Steering and local avoidance.
20. Navigation hardening and hard-path budgets.
21. Typed simulation event system and domain signals.
22. Simulation pipeline and tier/scope scaffolding.
23. Atlas-backed world rendering addition.
23A. GPU tilemap render hardening (`expand2`; merge before depth expansion).
23B. Multi-depth dense-layer render scaling (~120 levels).
24. Scoped simulation tiers and chunk policy.
24B. Render collect hardening (movement dense-index collect + camera-only gates).
25. Z-aware scalable navigation redesign.
25E. Per-entity NPC level and autonomous Z-traversal.
26. Entity faction and classification model.
27. Deterministic per-entity RNG facility.
28. Shared spatial index service.
34. Core SIMD primitive layer expansion and dense-path wins.
29. AI perception substrate.
30. AI memory and scope-aware AI state policy.
31. AI affect and emotion drives.
32. AI behavior arbitration.
33. Data-driven AI archetypes and debug introspection.
35. AI and steering hot-loop SIMD restructure.

Dependency index for slice ordering. **Open Frontier Slice Index** is the entry
point; each slice's **Checklist** and **Acceptance checks** are what agents
complete. **Scaling Gaps** is backlog until copied into a slice section.
