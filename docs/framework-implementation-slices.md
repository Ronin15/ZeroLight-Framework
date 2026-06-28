# Framework Implementation Slices

This roadmap keeps the repo focused as a 2D game project. Each slice should
land as a small, verified step that improves a real extension point without
adding broad abstraction.

## Ground Rules

- Preserve runnable defaults: `zig build`, `zig build run`, and installed assets
  should keep working after every slice.
- A slice means a full feature: runtime behavior, docs, tests, and acceptance
  checks must be integrated before it is complete.
- Keep hot paths simple: prefer enums, bitsets, arrays, and generational slot IDs
  over dynamic dispatch, string lookup, or hash maps during input/update/draw.
- If a dependent system does not exist yet, label the work as foundation or
  preparation and leave the feature checklist incomplete.
- Avoid half-wired states; either finish the feature end to end or keep the
  roadmap explicit about what remains.
- Keep `src/root.zig` minimal; feature modules should live in their matching
  `src/` area and import each other directly when needed.
- Run `zig build verify` before considering a slice complete.

## Next Priority Tracks

- Use the completed Slice 7 render-prep benchmark to guard the current ordered
  command -> `SpriteBatch` CPU prep path. Future tile rendering, richer UI,
  particles, lighting sprites, and debug records should feed typed `RenderOrder`
  commands through an explicit ordered render-prep phase first, then add
  specialized batchers only after measurement shows the sprite/rect batcher is
  the wrong representation. Keep SDL_GPU command-buffer, swapchain, upload,
  render-pass, and submit ownership on the render thread.
- Track collision-response merge/apply, SpriteBatch high-water/capacity policy,
  text-cache lifetime policy, shader/material registry guardrails, and remaining
  manual registry guardrails as hardening follow-ups.
- Treat Slice 20 pathfinding budgets, deterministic pending retention, and
  fixed-capacity cache contracts as the navigation hardening base before
  scaling to large maps or many NPC path users.
- Use the completed Slice 21 typed simulation events as the cross-system signal
  foundation before broad domain features such as tiles, weather, obstacle
  state, AI perception, combat, spawning, resources, and rules depend on those
  changes.
- Start Slice 22 with a behavior-preserving `SimulationPipeline` extraction
  plus tier/scope scaffolding in the final owner locations. The first runtime
  behavior stays full active-set parity, but `SimulationTier`, `ActiveRegion`,
  cold tier/chunk metadata, and scope stats should be shaped so later world and
  chunk hooks do not require guesswork or contract rewrites.
- Add atlas-backed world rendering before enabling scoped tier behavior. World
  rendering should provide the concrete tile/chunk/visibility data that scoped
  simulation consumes instead of inventing abstract chunk policy in isolation.
  See [architecture.md](architecture.md) for durable tier and pipeline
  boundaries; this roadmap owns the implementation order and acceptance themes.
- When multiple gameplay states need the same ordered processor flow, share the
  state-owned pipeline helper instead of duplicating orchestration or adding a
  global ECS scheduler. The pipeline may own lightweight domain controllers,
  but persistent facts stay in `DataSystem` and hot loops stay in SoA processors.
- Keep future gameplay systems built on Slice 12's typed processor outputs,
  deterministic merge, and deferred structural-change contracts.
- Treat CPU benchmark 50k scales as throughput ceilings, not per-frame targets;
  tiers and active scope keep typical fixed steps far below those stress counts.
- Land Slice 24 scoped cognition gating before the emergent-AI track
  (Slices 26–33). Per-entity perception, memory, and affect are only affordable
  at scale when the cognition tier shrinks which entities run them each step;
  building emergent AI on the full-active pipeline would bake in a scale problem.
  The track first adds the framework pieces it requires — entity faction
  classification, a deterministic per-entity RNG facility, and a shared spatial
  index — then layers perception → memory → affect → behavior arbitration as
  cognition-gated processor stages, keeping per-frame sensing columnar and routing
  only notable transitions through scalar-only `domain_reaction` events.
- Land NPC Z-level traversal (Slice 25E) before multi-floor emergent scenarios.
  The four touch-points are identified; schedule them as acceptance-checked work
  so the defect is caught in isolation rather than discovered mid-AI-track as a
  silent teleport behavior.
- Plan a `ComponentMask` widening from `u32` to `u64` before bit 28 is consumed.
  Eight component slots are currently used; the emergent-AI track (Slices 26–33)
  adds at minimum 8 more (faction, RNG seed, spatial index, perception, memory,
  affect, behavior weights, archetype). Combat, status effects, environmental
  state, and further domain expansions add more still. The widening touches
  `Component` (`u5` → `u6`), `ComponentMask` (`u32` → `u64`), `componentMask()`,
  `EntitySlot.component_mask`, and every `switch` on `Component` — mechanical but
  broad, cheaper to schedule before AI-track feature pressure mounts.
  `EntityId.index` stays `u32` (theoretical ceiling ~4.3 B entity slots is already
  ample for a 2D game; widening to `u64` would grow every `EntitySlot` and dense
  store row for no practical gain at this scale).

## Long-Term Gameplay Direction

Future gameplay features should use state-owned feature controllers or a
state-owned simulation pipeline helper for orchestration, and SoA processors for
hot data work. Controllers choose phase order, budgets, queues, cooldowns,
conflict policy, and which typed `DataSystem` views processors receive. A
reusable pipeline is appropriate once multiple gameplay states or instances
need the same ordered stages; it should remain owned by the state instance and
should not be promoted into a global scheduler. The pipeline can own domain
controllers for one state instance, and those controllers can coordinate small
feature-local state and processor handoff. Persistent gameplay/domain facts
live in `DataSystem` or state-owned domain storage, per-step outputs live in
`SimulationFrame`, and large or reusable loops stay in systems that process
typed slices and emit deterministic outputs.
Simulation tiers and per-step active scope filter which entities enter each
pipeline stage without changing processor hot paths. See
[architecture.md](architecture.md) for the durable tier and pipeline boundary.
Pathfinding provides a navigation substrate; immersive NPC behavior still needs
steering, local avoidance, perception, and rule arbitration layered above it.

## Completed Foundation Slices (0–7, 9–17)

Slices 0–7 and 9–17 are complete and settled. Their full checklists and
acceptance records moved to
[framework-implementation-slices-archive.md](framework-implementation-slices-archive.md)
to keep this roadmap focused on the frontier. Slice 8 stays below because it has
residual shader/material hardening items (also tracked under "Next Priority
Tracks" above). The full dependency-ordered slice list (0–35) remains in
"Suggested Order" below.

## Slice 8: Shader And Platform Expansion

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
- [ ] Consolidate shader-program, material, and runtime pipeline metadata so
      new pipelines do not need parallel registry edits.
- [ ] Define the material/batcher routing contract for sprites, tile spans,
      lighting/fire effects, and post-effect passes without exposing SDL_GPU
      handles to game code.
- [ ] Validate the right shader format list for each target OS.
- [ ] Add direct runtime asset/shader lookup guidance or tests for direct binary
      execution outside the installed binary directory.
- [ ] Add shader output checks for each supported target path.

Acceptance checks:

- [x] `zig build shaders` emits the same sprite shader outputs as before.
- [x] `zig build verify` exercises shader compilation.
- [x] `zig build gpu-smoke` confirms runtime submission on display-capable hosts.

## Slice 18: Frame-Delayed Pathfinding System

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

Deferred until after world rendering:

- [ ] Add scoped gather entry points for movement, collision, AI, and steering
      without changing hot processor math or merge rules.
- [ ] Add a render-prep handoff that exposes active/visible entity lists and
      dirty world regions without moving SDL_GPU calls, renderer handles, or
      queue ownership into the simulation pipeline.
- [ ] Keep the existing processor stage order identical to the current
      `GameDemoState` pipeline while scope shrinks participation.
- [ ] Add stagger and reduced-cadence policy for cognition without adding a
      second pipeline.
- [ ] Expose scope/tier debug or benchmark stats: counts per tier, per stage,
      stagger skips, and wake promotions.
- [ ] Document multi-world behavior: inactive worlds stay out of scope; active
      world uses chunk + halo rules.
- [ ] Update architecture and roadmap cross-links after runtime wiring lands.

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

Slice 22 lands the long-term fixed-step simulation owner. `SimulationPipeline`
now owns the reusable gameplay systems and concrete stage order for the demo
state, while `GameDemoState` keeps app/state boundaries such as input, audio,
particles, structural commit reactions, and render enqueue. `SimulationScope`
and cold tier/chunk metadata exist with full-active stats, but scoped gathers,
staggered cadence, real chunk gates, and tier transitions remain deferred until
world rendering supplies concrete world/chunk/visibility inputs.

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

## Slice 24: Scoped Simulation Tiers And Chunk Policy

Goal: turn the Slice 22 scaffolding into real scoped simulation behavior after
Slice 23 provides world/chunk/visibility inputs.

Readiness: the foundation for this slice is fully present (Slices 22/23/21);
what remains is wiring. The six checklist items below are the concrete gaps
between the current full-active pipeline and real scoped behavior.

Architecture assessment note (2026-06-28): confirmed that `allowsMovement`,
`allowsCollision`, and `allowsCognition` predicates on `SimulationTier` are
never consulted in `SimulationPipeline.update` — every entity, including dormant
ones, pays full pipeline cost every step. This is the highest-leverage open item
in the codebase: until it lands, entity population growth translates directly to
frame cost with no graduated degradation, and every cognition-tier stage added by
the AI track bakes in O(all entities) cost. Implement with a parallel
`scanLiveTierCounts` parity check in debug builds to detect tier-count drift; gate
the AI stage first and validate under stress before gating collision and movement.

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
- The pipeline still runs full-active: `SimulationPipeline.update` builds
  `SimulationScope.fullActive(...)` and dispatches every stage over the full
  component slices — scoped filtering is intentionally deferred to this slice
  (`simulation_pipeline.zig`).

Checklist (the remaining wiring):

- [ ] Expose a public `WorldSystem` query that returns visible chunks as an
      `ActiveRegion` (e.g. `visibleChunkRegion()` / `isChunkVisible(ChunkCoord)`)
      over the existing `chunk_visible[]` — today the data is maintained but not
      readable by scope.
- [ ] Add a main-thread pass (post-movement, pre-commit) that recomputes each
      scoped entity's cold `chunk` metadata from its position via
      `chunkCoordForCell`, writing off the hot worker ranges. This is the missing
      bridge between entity positions and chunk scope.
- [ ] Add scoped gather entry points for movement, collision, AI, and steering
      that filter by `(tier predicate AND active_region)`. Processors keep their
      current hot loops and merge rules and receive scoped slices/index lists
      instead of full slices.
- [ ] Add stagger and reduced-cadence policy for cognition (per-entity phase
      counter in cold metadata, 1-in-N cadence) without adding a second pipeline;
      count skips in scope stats.
- [ ] Wire tier promotions/demotions (wake/sleep) through the existing deferred
      structural-command commit or an explicit main-thread commit point;
      processors must not mutate tier metadata inside worker ranges.
- [ ] Expose scope/tier debug or benchmark stats: counts per tier, per stage,
      stagger skips, and wake promotions, surfaced in the debug overlay and a
      bench profile.

Acceptance checks:

- [ ] Scoped and unscoped processor paths produce identical outputs for the same
      entity subset in tests.
- [ ] Tier/chunk filtering changes which entities enter each stage without
      changing stage order or `SimulationFrame` stream contracts.
- [ ] Entity chunk metadata stays consistent with position after movement, and
      scope counts match the entities actually processed per stage.
- [ ] Tier changes do not mutate `DataSystem` structurally except through the
      existing deferred command commit point.
- [ ] `zig build test` covers scope build, tier gates, stagger skips, and
      pipeline phase transitions without opening a window.
- [ ] Benchmarks or debug stats report active scope counts so typical runs stay
      far below 50k stress scales by policy rather than by accident.

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

Deferred follow-up: per-entity NPC level and autonomous Z-descent is tracked
as Slice 25E below. The nav substrate is correct; the gap is four NPC-side
touch-points in `DataSystem`, `steering.zig`, `PathView`, and render/cull.
This is a gameplay-side correctness gap, not a pathfinder defect.

## Slice 25E: Per-Entity NPC Level And Autonomous Z-Traversal

Goal: give each NPC entity its own Z-level so it can request cross-level paths,
traverse ramps and stairs autonomously, and be culled to its own floor instead
of always rendering on the player's level.

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

- [ ] Add a per-entity level (Z) column to `DataSystem` (cold metadata, default
      surface level `0`), following the component-store pattern; initialize in
      `createEntity`.
- [ ] Steering sources `start_level` from the entity's level column rather than
      the hardcoded `0`; add a debug assertion that `steering.start_level ==
      entity.level` before each path request.
- [ ] Extend `PathView` to expose `next_cell_level` alongside `next_waypoint`
      so an agent can detect a link crossing and commit a level update.
- [ ] Update the per-step movement/traversal pass to apply NPC level transitions
      at link cells (mirroring the player ramp/fall logic); update the entity
      level column through the deferred structural-commit path or an explicit
      main-thread commit, not inside worker ranges.
- [ ] Render and cull each NPC on its own level, not the player's.
- [ ] Add tests covering same-level NPC pathing (no regression), cross-level
      NPC pursuing an off-level goal (level column updates at the link cell),
      and NPC render cull matching entity level.

Acceptance checks:

- [ ] An NPC pursuing a player on a different floor routes cross-level via
      `LevelLink` and updates its level column at the link cell; no teleport.
- [ ] Intra-level NPC behavior is unchanged (parity test).
- [ ] NPCs are culled to their own level, not the player's.
- [ ] No steady-state allocation; debug assertion fires if `steering.start_level`
      diverges from the entity level column.
- [ ] `zig build test`, `zig build check`, and `zig build verify` pass.

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
  `data_system.zig`: `Component` enum tag, component mask, `EntityTemplate`
  field, `StructuralCommand` variant, `StructuralCapacityNeeds` capacity, an SoA
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

- [ ] Add an `AiFaction` (or lightweight `entity_tag`) component: a small enum
      faction id per entity, following the full component-store pattern.
- [ ] Add a fixed faction-relationship matrix (enum × enum → stance:
      hostile / neutral / friendly), const-evaluated, scalar/enum only, no
      per-frame allocation and no hash lookup on hot paths.
- [ ] Expose a stance query usable from processor hot paths (`stance(a, b)`)
      that compiles to a table index, not a map lookup.
- [ ] Add to `EntityTemplate` and demo spawns so actors can be tagged.

Acceptance checks:

- [ ] Stance lookups are allocation-free and branch-light on hot paths.
- [ ] Faction assignment round-trips through structural commands and survives
      entity destruction/reuse with generational correctness.
- [ ] `zig build test` covers stance symmetry/asymmetry and template wiring.

## Slice 27: Deterministic Per-Entity RNG Facility

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

- [ ] Add a stateless, seeded, splittable RNG in `src/core` keyed by
      `(entity_index, step, salt)` returning uniform f32 / bounded ints.
- [ ] Document the determinism guarantee: same inputs → same outputs regardless
      of thread count or range order.
- [ ] Migrate existing AI wander randomness onto it as the first consumer.

Acceptance checks:

- [ ] Identical RNG outputs across serial and threaded runs for the same step.
- [ ] No per-call allocation; no shared mutable RNG state across workers.
- [ ] `zig build test` covers reproducibility and distribution bounds.

## Slice 28: Shared Spatial Index Service

Goal: build one frame-level spatial index consumed by AI separation, perception,
and collision broadphase instead of each system building its own grid.

Current foundation:

- AI separation builds a deterministic 32-unit grid each step
  (`systems/ai.zig`), and collision broadphase maintains its own candidate
  structure (`systems/collision.zig`). Perception (Slice 29) would add a third.

Architecture notes:

- Build once on the main thread (or a dedicated pre-stage); workers read it
  immutably. Must preserve each current consumer's results exactly so it lands as
  a parity-tested refactor, not a behavior change.

Checklist:

- [ ] Add a frame-built spatial hash/grid owned at the pipeline boundary, sized
      from reserved capacity, rebuilt per step, read-only to workers.
- [ ] Port AI separation and collision broadphase to consume it; remove the
      duplicate grid builds.
- [ ] Expose a bounded neighbor-query API (max samples / radius) reusable by
      perception.

Acceptance checks:

- [ ] Separation and collision outputs are identical to the pre-refactor results
      (parity tests).
- [ ] Index build and queries are allocation-free after warmup and deterministic.
- [ ] `zig build bench` shows no regression (ideally a win) from removing
      redundant grid builds.

## Slice 29: AI Perception Substrate

Goal: let agents sense other entities (and later sounds) within vision/hearing
limits, writing per-frame sensed state to columns and emitting only acquisition/
loss transitions as events.

Current foundation:

- AI today perceives only an aggregate seek target and separation neighbors
  (`systems/ai.zig`); there is no range/FOV/line-of-sight sensing and no notion
  of distinct sensed entities.
- Slice 26 supplies faction stance; Slice 28 supplies a shared spatial index;
  Slice 21 supplies the event contract.

Architecture notes:

- Runs as a parallel processor stage before AI decision. High-volume per-frame
  sense results are columnar; only transitions are events.
- Hearing depends on a world stimulus/sound-emission buffer; ship vision-first
  and gate hearing behind that buffer (tracked in this slice's checklist).

Checklist:

- [ ] Add an `AiPerception` component: cold tunables (vision range, FOV
      half-angle, hearing range) plus hot output columns (`target_visible`,
      `last_seen_x/y`, `nearest_threat: EntityId`, `nearest_threat_dist`).
- [ ] Add a `PerceptionSystem` parallel stage that queries the shared spatial
      index for candidates, then applies bounded range/FOV/line-of-sight checks
      (LOS against world blocking tiles via `world_system` walkability), writing
      results to perception columns.
- [ ] Add scalar-only `entity_perceived` / `entity_lost` event payloads for
      target acquisition/loss transitions, emitted at `domain_reaction` via the
      per-range writer with pre-reserved capacity.
- [ ] Add a transient per-step world stimulus/sound buffer (position +
      intensity + type, scalar-only) and consume it for hearing; keep it separate
      from the audio playback service.

Acceptance checks:

- [ ] Per-frame sense results live in columns, not events; only transitions emit
      events, bounded by a per-step cap with drops surfaced via event stats.
- [ ] Serial and threaded perception produce identical columns and event order.
- [ ] Sensing is allocation-free after warmup and runs only for cognition-tier
      entities in scope.
- [ ] `zig build test` covers range/FOV/LOS gating, transition events, and
      serial/threaded parity.

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
- `systems/collision.zig` — broadphase AABB sweep and narrowphase contact math
  (a locally hand-rolled `gather4` + masked select).
- `systems/collision_response.zig` — normal/penetration/velocity correction math.
- `systems/particle.zig` — particle integration and color/size lerp.
- `systems/pathfinding.zig` — flow-field octile heuristic and nav-grid marking;
  `pathfinding_range_alignment_items = simd.lane_count`.
- The helper exposes `Float4/Int4/Mask4`, arithmetic, compare, select, clamp, and
  tail helpers, with a single `lane_count` source of width.

Gaps the SIMD-first stages need (the missing primitives):

- No shared gather/scatter helper — collision hand-rolls `gather4`; AI/steering
  and perception will all need the same.
- No reciprocal/inverse sqrt and no vectorized 2D normalize (with a masked
  zero-length guard) — required by every separation/avoidance/perception kernel.
- No vector sin/cos approximation — Zig `@cos`/`@sin` do not auto-vectorize, and
  rotation (sprites) and FOV (perception) math need it.
- No documented packed-SoA-scratch idiom (gather sparse indices into contiguous
  lanes) — the standard tool for making gather-bound loops vectorizable.

Checklist:

- [ ] Add gather/scatter helpers to `core/simd.zig`, generalizing collision's
      local `gather4`; port collision to the shared helper.
- [ ] Add reciprocal-sqrt / inverse-length and a vectorized 2D normalize with a
      masked zero-guard (matching the scalar `normalizeOrZero` semantics).
- [ ] Add a vector sin/cos (or sincos) approximation with a documented error
      bound and a scalar fallback path.
- [ ] Document the packed-SoA-scratch idiom in `core/simd.zig` (or a sibling
      helper) so later stages reuse one gather-into-lanes pattern.
- [ ] Vectorize the sprite vertex transform in `render/sprite_batch.zig`
      (`writePreparedSpriteVertices` / `fillPreparedRange`): pack the 4-corner
      rotation + translation + camera transform through the helpers over the
      contiguous prepared-command array, mask the `coordinate_space` branch, keep
      a scalar tail (~1.3–1.5x on large batches).
- [ ] Replace the AI separation-grid zero-fill (`systems/ai.zig`) with `@memset`
      or a vector fill.
- [ ] Add a batched `lerpVec2` path in `core/math.zig` for render interpolation
      when the interpolation pass iterates many entities over contiguous columns.

Acceptance checks:

- [ ] New primitives have unit tests and scalar-vs-SIMD parity tests; numeric
      approximations (rsqrt, sin/cos) document error bounds and keep a scalar
      fallback.
- [ ] Collision narrowphase produces identical contacts after porting to the
      shared gather helper (parity test).
- [ ] `zig build bench` shows a render-prep vertex-emit win at 10k–50k sprites
      with no regression at low counts.
- [ ] Systems use `src/core/simd.zig` helpers, not raw `@Vector`.
- [ ] `zig build verify` passes.

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
24. Scoped simulation tiers and chunk policy.
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

This order records the dependency path used to build the current project
foundation. Current work should be chosen from Next Priority Tracks above.
Resource ownership, text/UI, renderer composition, threading, SIMD,
`DataSystem`, simulation outputs, collision, AI intent processing, audio, menus,
startup runtime assets, frame-delayed pathfinding, steering/local avoidance, and
navigation hardening now form the source-of-truth foundation for future slices.
Render ordering is also part of that foundation: game/world/UI/effect producers
emit typed ordered commands through explicit render-prep phases, persistent data
stores stable IDs and enum depth intent, `SpriteBatch` consumes strict ordered streams, and
benchmark-owned render-prep timing stays out of the production path.
Slice 21 typed simulation/domain events, Slice 22 `SimulationPipeline`
extraction, and Slice 23 atlas-backed world rendering are in place for the
current structural, navigation, and world/chunk visibility foundation. Slice 24
scoped simulation tiers should consume those world/chunk views next. Scoped
tiers, chunk policy, and tier transitions should use those event signals through
pipeline-owned controllers instead of adding parallel orchestration paths.
Slice 25E lands per-entity NPC Z-level before multi-floor emergent scenarios;
it is a gameplay-side correctness gap (four NPC touch-points in `DataSystem`,
`steering`, `PathView`, and render cull) on top of the fully correct Slice 25
nav substrate.
The emergent-AI track (Slices 26–33) builds on that foundation: it lands the
framework additions the AI work requires (faction classification, deterministic
RNG, shared spatial index), then layers perception, memory, affect, and behavior
arbitration as cognition-tier-gated processor stages, with data-driven archetypes
and debug introspection for authoring and tuning. The whole track stays
allocation-free on hot paths, deterministic (serial == threaded, scalar == SIMD),
routes notable signals through scalar-only `domain_reaction` events while keeping
per-frame sensing columnar, and reuses the existing intent → steering →
pathfinding → movement contract instead of adding new downstream plumbing.
