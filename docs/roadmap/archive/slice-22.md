## Slice 22: Simulation Pipeline And Tier/Scope Scaffolding

Goal: make `SimulationPipeline` the state-owned fixed-step simulation owner,
add the tier/scope scaffolding in its final ownership locations, and preserve
today's full active-set processor behavior. This is the architectural landing
zone for later scoped simulation, not the slice that turns on world/chunk tier
filtering.

Design source of truth:

- [architecture.md](../../architecture.md) for durable pipeline, controller,
  tier/scope, and ownership guidance.
- [simulation-tiers-and-pipeline.md](../../simulation-tiers-and-pipeline.md) for the
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


