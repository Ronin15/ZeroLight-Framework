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


