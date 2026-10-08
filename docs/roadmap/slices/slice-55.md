## Slice 55: Cognition Think-Interval Coasting (Decision LOD)

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 49](slice-49.md) · Track: [VoidLight port](../tracks/voidlight-port.md) · [Emergent AI](../tracks/emergent-ai.md)

**Status: not started.** Hard dependency on **Slice 49**: the LOD band comes
from 49's fixed-step `sim_view` through its `simViewRegion(context)` helper,
never from the render visibility window. Also depends on archive Slices 24
(scope tiers + 1-in-4 stagger), 32 (arbitration + hot `active_behavior`), and 47
(unstaggered sensing substrate), all landed. Slice 35 is independent and
composes with this one: 55 cuts how many rows reach AI decide and steering, and
35 cuts the per-row math. Slice 42 and Slice 56 inherit the alert-input contract
described under **Classification** below; Slice 61 classifies its `forage`
behavior in `coastableBehavior`.

Goal: idle cognition agents re-run the **decide path** only every 8 or 32 fixed
steps instead of every 4. The decide path is the AI gather row, separation,
cohere, the interest-marker scan, score/select/resolve, and intent emit, plus the
steering and path requests that follow from it. Between decisions an idle agent
coasts on its persisted velocity and hot behavior. Any sensing signal that could
select a goal-directed behavior puts the agent back on the base cadence **on the
same step**. Interval, phase, and wake are pure functions of deterministic state:
behavior, gains, sensing columns, affect mask, LOD distance band (measured from
Slice 49's fixed-step sim view), entity index, and step counter. They never use
wall clock, render cadence, interpolation alpha, or measured cost. Sensing
(spatial index, perception candidates and observers, memory, affect) never
coasts.

### Current foundation

- **Stagger:** `cognition_stagger_n = 4` (`src/game/simulation_scope.zig:11-13`).
  `stagger_phase` is assigned as `dense_index % 4` at movement-body append
  (`:143-147`). Also here: `ActiveRegion.chunkDistance` / `lodDistance`
  (`:116-130`) and `SimulationScopeStats` (`:160-185`).
- **`SimulationScopeSystem`** (`src/game/systems/simulation_scope.zig`):
  - Stage-participation doc: `:19-26`.
  - Two-population gather: `gatherAiPopulations` (`:318`), the serial twin
    (`:363`), and `compactCognitionFromHalo` (`:403`). `always_active` bypasses
    halo and stagger. A null region disables both.
  - Per-range compaction scratch: `IndexRangeBuffer` / `IndexRangeSlot`
    (`:562-590`, 64-byte padded), `prepareIndexRangeBuffers` (`:611`), the
    range-ordered `mergeIndexRanges` (`:529`), and `aiGatherJob` (`:787`).
  - Clock and sizing: `staggerStep` / `currentStep` (`:174-183`), `reserve`
    (`:159`).
  - Parity and allocation tests: `:1491` and `:1558`.
- **Pipeline** (`src/game/simulation_pipeline.zig`):
  - Contract machinery: `PipelineResource` (`:86`), `StageId` (`:128`),
    `stageContract` (`:167`, `ai_decide` arm at `:191`), and `stage_order`
    (`:262`) with its comptime checks.
  - Stage methods: `stageScopeAdvanceAndAiGather` (`:1054`) and `stageAiDecide`
    (`:1145`, which passes `ai_cognition_indices` at `:1179`).
  - `stageTierPolicy` (`:1296`) uses Slice 49's `simViewRegion(context)`. (Live
    code still reads the render window there, `visibleChunkRegion()` at
    `:1298`; Slice 49 removes that leak and lands first.)
  - Stats and contract test: `buildScopeStats` (`:1303`) and the contract test
    (`:1328`).
- **Coasting already happens implicitly.** On the 3 off-phase steps an agent gets
  no `NavigationIntent`. Steering's `selectIntents` (`steering.zig:370`) then never
  selects it, and `MovementSystem.applyIntents` (`movement.zig:59`) leaves its
  velocity alone. Movement, collision, the tile gate, and plane traversal still run
  by tier. Slice 55 lengthens this coast for idle agents. It adds no new motion
  model.
- **AI processor:** `AiSystem.gatherAiData` (`ai.zig:590`) walks the halo for the
  `candidates` side table and the think list (`scope_dense_indices`, `:373`) for
  rows. Any ordered subsequence of the halo is valid input.
  `resolveRowArbitration` (`:1252`) persists `active_behavior`,
  `commitment_remaining`, and `last_score`. The wander epoch is
  `default_wander_resample_period_steps = 300` (`:301`).
- **Arbitration** (`arbitration.zig`):
  - `scoreBehaviors` (`:214`) is `gain[b] × (...)`, so a zero gain means a zero
    score whatever the inputs.
  - `resolveGoal` (`:411`) gives pursue/flee a goal only from a visible threat,
    fresh memory, or the focus fallback. Investigate gets a goal only from a heard
    stimulus, an interest marker, or a ring contact.
  - `memoryFresh` is at `:146`.
- **Columns the classifier reads.** All are written this step before `ai_decide`:
  - `AiPerception.target_visible` and `heard_stimulus`.
  - `AiMemory.last_known_target` and `staleness`. The cap is
    `max_ai_memory_staleness = 3600` sensing ticks, about 4 minutes
    (`types.zig:529`).
  - `AiAffect.above_threshold_mask` (`types.zig:701`; default threshold 0.6 at
    `:655`). Demo `timid` / `aggressive` / `curious` baselines of 0.65 sit above
    that threshold permanently (`assets/ai/archetypes.json`).
- **RNG:** `core/rng.zig` `mix64` / `boundedU32` (`:21`, `:48`) are pure functions
  of (seed, entity_index, step, salt).
- **Slice 47 regression guards:**
  - `pipeline dual-list perception: think observer acquires off-phase halo
    hostile` (`simulation_pipeline.zig:2582`).
  - `sticky dig linger reaches every stagger phase within the linger window`
    (`:4387`). Its asserts are sensing-only. Slice 49 migrates its window
    (`:4395`) to `.sim_view`; 55 uses it in that migrated form.
- **Benches:**
  - `ai` group (`src/benchmarks/ai.zig`): `AiSystem.update` over every row, with
    no scope.
  - `scope` group (`src/benchmarks/scope.zig:285-356`): halo/think gathers, then
    AI on `ai_cognition_indices`.

The `ai` group's fixture has every agent thinking on a dense 11×9 px grid
(about 112 separation checks per agent); its current numbers come from a fresh
run, not this file.

### Architecture notes

**Decision summary**

| Question | Decision |
| --- | --- |
| How it relates to the 1-in-4 stagger (replace, compose, or subsume) | **Compose.** The stagger stays the sensing cadence and the base (alert) decide cadence. Coasting is a per-agent power-of-two multiplier on decisions, aligned to sense ticks. `stagger_phase`, `gatherAiPopulations`, and `cognition_stagger_n` are untouched. Replacing the stagger would re-couple sensing to thinking, which is the Slice 47 defect class. It would also change memory and affect decay, which advance per sensing tick, not per dt. Subsuming would need a persisted column and would break the ~N/4 think-budget tests. |
| What coasts | Only the decide path (AI decide, plus steering and path requests through the intent stream). Perception observers, memory, and affect keep the stagger cadence for every think-set agent. |
| Owner | Scope/LOD policy, beside stagger and tier policy. The pure contract lives in `src/game/simulation_scope.zig` and the threaded compaction in `SimulationScopeSystem`. One new pipeline stage, `ai_decide_gather`. Processors stay unchanged apart from doc text and one AI early-out. |
| Cached decision columns | **None new.** The cached decision is state that already persists: `AiAgentStore` hot `active_behavior` / `commitment_remaining` / `last_score`, `MovementBodyStore` velocity, and the steering `RuntimeRow` (`prev_dir_*`, waypoint hint, cooldowns). Class is recomputed each sense tick and phase is a hash. A stored countdown or decision signature would be a second source of truth: it would need swap-remove upkeep, Slice 46 save/load coverage, and a write from a worker. Rejected. |
| Phase | Stateless `rng` hash of `entity.index` under a fixed, pinned seed literal. This is a named exemption in Slice 49's Determinism Contract (a fixed load-spread schedule hash, not derived from the session seed). |
| LOD band source | Slice 49's `simViewRegion(context)`: the fixed-step `sim_view` rect, level-anchored to the player. Never `visibleChunkRegion()`, whose window is written by render from the interpolated camera. |
| Wake | Column predicates evaluated after `affect_update` in the same step. Never event scans. |
| Budgets | Fixed power-of-two intervals and a fixed chunk band. No per-step decide cap and no deferral: coasting only removes work, and alert rows are never deferred. Because no budget can be exceeded, no degradation ladder is needed. |

**Per-step work for an agent in this step's think set** (off-phase steps are unchanged from today)

| Work | Decides this step | Coasts this step |
| --- | --- | --- |
| Perception observer (FOV/LOS/hearing), memory decay/refresh, affect appraisal/decay/threshold events | runs | **runs (sensing never coasts)** |
| Spatial-index row; perception/AI candidate row (so others see, avoid, and cohere with it) | present | **present** |
| AI gather row, separation query, cohere query, interest-marker scan, `scoreBehaviors` / `selectSticky` / `resolveGoal`, `decideDir`, `NavigationIntent` | runs | skipped |
| Steering select, path status, avoidance batch, path request | runs (transitive) | skipped (no intent) |
| Movement integrate, collision detect/respond, bounds/tile gate, plane traversal, chunk derive, tier policy | runs (by tier) | runs (by tier) |
| Velocity | rewritten by steering's movement intent | persists from the last decision |

**Classification** is pure. It runs once per think row per sense tick, on this
step's fresh columns.

1. **Pinned** (`always_active`): the agent decides on every think step, which for
   pinned agents is every step. Exempt from coasting.
2. **`alert`** (1 tick = 4 steps, today's cadence) when any of these holds:
   - `coastableBehavior(active_behavior) == false`. Pursue, flee, and investigate
     follow paths, which needs base-cadence steering. `coastableBehavior` is an
     exhaustive switch, so a new `AiBehavior` tag fails to compile until it is
     classified.
   - **Threat signal:** `(target_visible or memoryFresh) and (gain_pursue > 0 or gain_flee > 0)`.
   - **Stimulus signal:** `heard_stimulus and gain_investigate > 0`.
3. **`idle_near`** (2 ticks = 8 steps): not alert, and either
   `lodDistance(chunk, level) ≤ decision_coast_near_band_chunks` (measured
   against `simViewRegion(context)`) or `above_threshold_mask != 0` (an
   agitated agent).
4. **`idle_far`** (8 ticks = 32 steps): everything else.

The gain gating is sound because a score is `gain[b] × (...)`. An input that only
zero-gain behaviors consume cannot change the selected behavior. Without gating,
fresh memory (up to about 4 minutes) or a visible hostile would pin a gain-0
wanderer to alert for no effect. This is the same gating idiom as the gather's
`has_focus` check and the cohere/interest query skips.

A drive edge alone cannot give pursue, flee, or investigate a goal: `resolveGoal`
needs a threat, memory, focus, stimulus, marker, or ring contact. So agitation
tightens the cadence without forcing an immediate decision.

**Contract for Slices 42, 56, 61, and later producers:** any new signal that can
resolve a goal by itself must be added to the alert predicate by its producer,
and any new `AiBehavior` tag must be classified in `coastableBehavior` (Slice 61:
`coastableBehavior(.forage) = false`, because forage follows a path; a `need`
threshold crossing raises the row to `idle_near` through the drive mask).

Things coasting may delay, accepted and bounded by the agent's interval:

- Continuous score drift between idle behaviors (wander↔cohere driven by drive
  values).
- The wander-epoch heading change.
- Finding an interest marker or ring contact for investigate. The marker scan runs
  only at decisions.
- Resuming focus-fallback pursuit after fatigue decays.

Everything else that can give pursue/flee/investigate a goal from sensing promotes
to alert on the same step.

`commitment_remaining` still counts decisions, which was already the contract
under the stagger. Coasting stretches commitment in wall time for idle agents
only. Document this; there is no code change.

**Wake rules.** A wake means the row classifies alert (or tighter) on its sense
tick. Because `ai_decide_gather` runs after perception, memory, and affect, the
promoted row decides **in that same step**, adding zero latency over today's
stagger.

| Event | Signal read | Effect |
| --- | --- | --- |
| New threat perceived, or threat swapped | `target_visible` (gain-gated) | alert, same step |
| Threat lost | `memoryFresh` (gain-gated) | alert while memory is fresh |
| Stimulus heard (dig, footstep, impact, including sticky linger) | `heard_stimulus` (gain-gated) | alert, same step |
| Drive rises over threshold (Slice 31 Schmitt mask) | `above_threshold_mask != 0` | at least `idle_near` (at most 1 extra tick) |
| Decision becomes goal-directed | `active_behavior` | alert from the next sense tick on |
| Goal reached / path failed | none | Not a wake in 55: no coastable behavior follows a long path. Cohere's goal is a local drift of at most `cohere_radius` (96 px); overshoot is at most interval × speed. A future coastable path-follower (for example a `patrol` marker consumer) must either stay non-coastable or add a carried steering→scope path-status resource. |
| Damage | `above_threshold_mask` (via the affect watermark); attacker via perception/memory | Slice 56 produces damage through `Health.damage_taken_total` → affect watermark → drive mask (`above_threshold_mask` → at least `idle_near`). The attacker becomes alert input only through perception/memory. A damage-only goal-resolving signal must be added to the alert predicate by its producer. Never through a callback or a cross-entity write from a worker. |

Wakes are **not** read from `entity_perceived` or `affect_threshold_crossed`
events. Those streams are capped per step (`max_events_per_step`), and a dropped
event must never strand an agent in coast.

**Phase and schedule**

- `decisionCoastPhase(entity.index) = rng.boundedU32(decision_coast_phase_seed, entity.index, 0, decision_coast_phase_salt, decision_coast_cycle_ticks)`.
  It is stateless and recomputed in the gather; recycled slot indices reuse their
  phase, which is harmless.
- `sense_tick = step_count / cognition_stagger_n`. An agent's successive think
  steps (`step_count ≡ stagger_phase mod 4`) see consecutive sense ticks.
- An agent decides iff `((sense_tick +% phase) & (interval_ticks - 1)) == 0`.
- The phase is a hash rather than `entity.index % 8` because
  `stagger_phase = dense_index % 4` correlates with sequentially spawned entity
  indices. A modulo would put each stagger cohort on 2 of the 8 coast phases and
  lump the load.
- Power-of-two intervals that divide the cycle make the schedules **nest**: a row
  that is due under the far cadence is due under every class. The job therefore
  short-circuits pinned rows, goal-behavior rows, and far-due rows to "emit" with
  no component lookups.

**Fixed constants** go in `src/game/simulation_scope.zig` beside
`cognition_stagger_n`. They are never scaled to population, world size, or
measured cost, and are comptime-asserted.

| Constant | Value | Reason |
| --- | --- | --- |
| `decision_coast_near_ticks` | `2` (8 steps, 133 ms) | On-screen, near-band, or agitated idle agents. Halves visible idle decide and steer cost while re-evaluating separation at 7.5 Hz. Steering's per-call turn smoothing (`steering_turn_smoothing = 0.15`, `steering.zig:77`) then converges an idle heading change in about 1.3 s instead of about 0.67 s. This is a gentle, documented visual change for idle agents only. |
| `decision_coast_far_ticks` | `8` (32 steps, 533 ms) | Off-screen calm idle agents. Under 1/9 of the 300-step wander epoch, so heading changes land within about 11% of an epoch. |
| `decision_coast_cycle_ticks` | `= decision_coast_far_ticks` | Phase domain. Assert that near and far are powers of two, `far % near == 0`, and `cycle % far == 0`. |
| `decision_coast_near_band_chunks` | `2` | A camera must pan more than 2 chunks per far interval (about 960 px/s at the default 256 px chunk) for an agent to reach the screen without first being reclassified onto the near cadence. Assert `< cognition_halo_chunks`. Uses the same level-anchored `lodDistance` over Slice 49's `simViewRegion` as the tier policy, so off-level agents read as far. |
| `decision_coast_phase_seed` | pinned `u64` literal | Load spread, decorrelated from `stagger_phase`. Not session-seeded: a named exemption in Slice 49's Determinism Contract. The literal is pinned; the load-spread unit test is its guard, and changing the literal requires that test to pass again. |
| `decision_coast_phase_salt` | `1` | Distinct from `wander_rng_salt = 0`. |

**Data layout and lifetime**

- Persistent data: no new columns. There are no `DataSystem`, `EntityTemplate`,
  `StructuralCommand`, or archetype JSON changes, and nothing new for Slice 46 to
  serialize.
- Transient scratch, owned by `SimulationScopeSystem` beside `ai_cognition_indices`:
  - `ai_decide_indices: std.ArrayList(u32)`, reserved in `reserve(capacity)`
    with `capacity = SimulationPipelineConfig.movement_body_capacity` (the
    content-derived movement-body count the state passes at init: movers +
    obstacles + player). Decide ⊆ think ⊆ halo ⊆ movement bodies, so the
    list never grows while the population stays inside that reserve.
  - `ai_decide_ranges: IndexRangeSlotList`, reusing the padded `IndexRangeSlot`.
    Each slot is reserved to its exact range length on the main thread before
    dispatch, sized from the same selection the dispatch uses.
  - `ai_decide_gather_tuner: AdaptiveWorkTuner`.
  - `decision_coast_skips: usize`.
  - `IndexRangeBuffer` and `IndexMergeResult` each gain `coast_skips: usize`.
- These are not `MultiArrayList` because they are single-column index lists and
  cache-line-padded per-range slots, both named exceptions in the coding standards.
- Lifetime runs from `ai_decide_gather` until the next `advanceStep`. The lists are
  aliased by `StepState.ai_decide_indices`.

**Ordered processor list.** Only the touched stages are shown; all others are
unchanged.

| # | Stage | Reads | Writes | Carried |
| --- | --- | --- | --- | --- |
| 1 | `scope_advance_and_ai_gather` (unchanged) | — | `ai_halo_indices`, `ai_cognition_indices` | — |
| 2–5 | `spatial_index_build` → `perception_update` → `ai_memory_update` → `affect_update` (unchanged) | halo / cognition as today | `spatial_index`, `perception_sensed` + events, `ai_memory`, `affect_drives` + events | as today |
| 6 | **`ai_decide_gather` (new)** | `ai_cognition_indices`, `perception_sensed`, `ai_memory`, `affect_drives` | **`ai_decide_indices` (new tag)** | `ai_behavior` (written later by `ai_decide`), `chunk_columns` (written later by `chunk_derive`), `world_level` (the scope `level` column, written later by `plane_traversal`) |
| 7 | `ai_decide` | **`ai_decide_indices`** (replaces `ai_cognition_indices`), `ai_halo_indices`, `spatial_index`, `perception_sensed`, `ai_memory`, `affect_drives` | `navigation_intents`, `ai_behavior` | `interest_markers` |
| 8 | `steering_update` → … | unchanged (transitively scoped by intents) | unchanged | — |

Every carried entry has a later writer and no earlier writer, which satisfies the
comptime carried rules at `simulation_pipeline.zig:319-347`.

**Pipeline wiring**

- `runStage` gains the arm `.ai_decide_gather => try self.stageAiDecideGather(step)`.
- The new stage reuses Slice 49's `simViewRegion(context)`, the same helper
  `stageTierPolicy` reads. It adds no region helper and no second region
  source, and it never calls `visibleChunkRegion()`.
- The new stage calls
  `self.scope.gatherAiDecidePopulation(data, step.ai_cognition_indices, simViewRegion(context), self.scope.senseTick(), thread_system, .{})`
  under `StageTimer` `.pipeline_ai_decide_gather`.
- `stageAiDecide` passes `step.ai_decide_indices` as `scope_dense_indices`.
- `buildScopeStats` sets `ai_stage_entities = ai_decide_indices.len` and records
  `decision_coast_skips`. The think-set size equals `ai_stage_entities + decision_coast_skips`.

**Scope-system API** (`src/game/systems/simulation_scope.zig`)

- `pub fn senseTick(self) u32` returns `step_count / cognition_stagger_n`.
- `pub fn gatherAiDecidePopulation(self, data: *const DataSystem, think: []const u32, sim_region: ?ActiveRegion, sense_tick: u32, thread_system: *ThreadSystem, config: ScopeConfig) !AiDecideGatherResult { indices: []const u32, batch: BatchStats }`,
  with a `gatherAiDecidePopulationSerial` twin. It follows the same shape as
  `gatherAiPopulations`, which also takes its tick explicitly. `sim_region` is
  whatever `simViewRegion(context)` returned; the scope system never reads a
  world window itself.
- When `sim_region` is null (a world with no chunks; `sim_view` itself is a
  required `Rect`), the decide list is a memcpy of `think` and
  `decision_coast_skips = 0`. This mirrors the stagger's null-region full-active
  fallback, so every existing chunkless-world test keeps today's behavior. An empty `think` returns
  immediately.
- `fn coastableBehavior(b: AiBehavior) bool`: wander and cohere return true;
  pursue, flee, and investigate return false.
- `aiDecideGatherJob` handles one think row as follows:
  1. Resolve the entity, then `movementBodyDenseIndex orelse continue` (dropped
     and uncounted, mirroring the AI gather).
  2. Pinned rows, non-coastable rows, and far-due rows emit.
  3. Otherwise resolve the perception, memory, and affect dense indices. Each is
     optional; a missing component means "no signal" (the Slice 31 rule).
  4. Build `DecisionCoastInputs`, classify, then emit or increment
     `coast_skips`.

  The job opens with dual asserts: `range.end <= think.len` and
  `range.index < range_count`.
- The pure contract lives in `src/game/simulation_scope.zig`. It imports only
  `std` and `core/rng.zig`, with no `data_system` import, so the module stays free
  of import cycles. It defines:
  - `DecisionCoastClass = enum(u2) { alert, idle_near, idle_far }` with
    `intervalTicks()`.
  - `DecisionCoastInputs { goal_behavior, threat_signal, stimulus_signal, drive_alert: bool = false, lod_distance: i32 = 0 }`.
  - `decisionCoastClass(inputs)`, `decisionCoastPhase(entity_index: u32) u8`, and
    `decidesOnSenseTick(class, phase, sense_tick) bool`.

**AI early-out.** `AiSystem.gatherAiData` returns right after `clearWork` when the
think list is non-null and empty. This skips the halo candidate walk on steps
where every think-set agent coasts. The path already returns `.{}` without
touching the stream when `rows.len == 0`.

**Threading and SIMD**

- The gather is a threaded stream-compaction that mirrors `aiGatherJob`. Each
  worker writes only its padded range slot, and the main thread merges in range
  order. Worker IDs and timing never enter the output.
- There is a serial twin. The adaptive tuner keeps demo-scale batches inline.
- It is scalar by design. Each row does optional-component slot resolves plus
  compaction, the same irreducible shape as `aiGatherJob`, and the classify math is
  a handful of compares. Document this at the job.
- It emits no events, so the canonical event-order rule does not apply.

**Determinism.** The decide set is a pure function of the think-list order, the
columns, `entity.index`, `sense_tick`, and the fixed-step sim region. Serial,
threaded, any worker count, and any range size all produce the same set. There
is no wall clock, no measured cost, and no hidden RNG state.

The sim region is load-bearing for this claim. `visibleChunkRegion()` returns
the window `GameDemoState.render` writes from the **interpolated** camera
(`game_demo_state.zig:566-575`); its alpha depends on wall-clock pacing, and up
to 5 fixed updates can run between renders (`time_loop.zig:11`). Reading it
would make `idle_near` versus `idle_far`, and therefore the decide set, depend
on render cadence. Unit tests that pass a region explicitly cannot catch that,
so a pipeline test (Checklist) pins it: the same `sim_view` with two different
render windows yields identical decide lists and skip counts.

**Slice 47 guard (must not regress).** Coasting filters only the decider set, and
only downstream of sensing.

- (a) `spatial_index_build` and the perception and AI candidate tables still walk
  the unstaggered halo. A coasting agent is still seen, cohered with, and avoided.
  Steering's avoidance snapshot is full-population.
- (b) A coasting agent is still a perception **observer** on its sense tick,
  because observers are the think set. It can therefore perceive the thing that
  wakes it.
- (c) The lists form ordered subsequences, decide ⊆ think ⊆ halo, which preserves
  `AiSystem`'s two-pointer `spatial_self_index` mapping. The existing
  `think_k == think.len` assert catches violations.
- Never feed `ai_decide_indices` to spatial index build, perception (either list),
  memory, or affect.

**Relation to Slice 35.** There is no shared code beyond `ai_decide`'s input
list. Separation caps 32/128, `decideDir`, the avoidance kernels, and the
`scoreBehaviors` / `selectSticky` / `resolveGoal` contracts are all untouched.

**Out of scope:**

- Coasting sensing.
- Intent replay: re-emitting a cached `NavigationIntent` without arbitration so
  goal-directed agents keep base-cadence steering.
- Decide caps or deferral.
- A debug-overlay display of the coast class.
- Sharing perception's candidate table with AI ("AI candidate side-table halo
  walk"): Slice 68A's shared halo table; after 55 it is the remaining O(halo)
  main-thread AI cost.

### Checklist

- [ ] **Pure contract** (`src/game/simulation_scope.zig`): constants and comptime
      asserts, `DecisionCoastClass`, `DecisionCoastInputs`, `decisionCoastClass`,
      `decisionCoastPhase`, and `decidesOnSenseTick`. Unit tests:
      - Each alert input alone yields `alert`.
      - The near/far boundary falls at `decision_coast_near_band_chunks` and
        `+1`, and the agitated rule overrides far.
      - The phase is stable for the same index, and 1,024 indices fill all 8
        phases at between 0.5× and 1.5× of the mean.
      - Over 2 cycles each class decides exactly `cycle / interval` times per
        cycle for every phase.
- [ ] **Scope system:** `senseTick`; the new fields with `deinit`/`reserve`;
      `gatherAiDecidePopulation` and its serial twin; `aiDecideGatherJob` and its
      context with dual asserts; `coast_skips` in `IndexRangeBuffer` /
      `IndexMergeResult` / merge; `coastableBehavior`. Update the module doc's
      stage-participation table with the decide row.
- [ ] **Pipeline:**
      - `PipelineResource.ai_decide_indices` and `StageId.ai_decide_gather` in
        `stage_order` between `affect_update` and `ai_decide`.
      - Both `stageContract` arms as tabled, the `runStage` arm,
        `stageAiDecideGather` (reading Slice 49's `simViewRegion(context)`),
        and `StepState.ai_decide_indices`.
      - Raise `@setEvalBranchQuota` at `simulation_pipeline.zig:287` (4000
        today) if the comptime contract walk needs it after the new stage and
        resource tag.
      - Switch `stageAiDecide` to the decide list; update `buildScopeStats`; add
        `SimulationScopeStats.decision_coast_skips`.
      - Contract test modeled on `:1328`: `ai_decide` reads `ai_decide_indices`
        and not `ai_cognition_indices`; `ai_decide_gather` reads `affect_drives`
        and `perception_sensed`; perception/memory/affect/spatial-index contracts
        do not read `ai_decide_indices`.
- [ ] **AI early-out** on an empty non-null think list. Test: with a non-empty halo
      and an empty think list, `update` returns zero stats and leaves the intent
      stream untouched.
- [ ] **Diagnostics:**
      - Add a `scope_decision_coast_skips` metric with `coast_skips={}` on the
        scope perf line (`runtime_perf_log.zig:142`, `:601`).
      - Add a `pipeline_ai_decide_gather` timer on the pipeline timing line. Both
        compile out in ReleaseFast like the existing ones.
      - Emit one `logging.game` debug line at `SimulationPipeline.init` with the
        coast constants. No per-step logging.
- [ ] **Scope-system tests:**
      - Alert, pinned, and due rows are kept and the rest coast.
      - A null sim region gives `decide == think` with 0 skips.
      - **Wake preempts the interval:** an `idle_far` row on a not-due tick is
        excluded until `target_visible` (with `gain_flee > 0`), `heard_stimulus`
        (with `gain_investigate > 0`), or fresh memory is set. Then it is included
        in the same call.
      - Gain-gating negative: `target_visible` with zero pursue/flee gain still
        coasts.
      - The decide list is an ordered subsequence of the think list.
      - Idle-far load spread: 256 agents over 32 steps; each decides exactly once,
        and the per-step count never exceeds 3× the mean. (The per-step count is
        roughly Binomial(256, 1/32), mean 8; a 2× bound would hold or fail by
        the luck of the pinned `decision_coast_phase_seed`. 3× still catches a
        lumped phase hash. The seed is pinned and this test is its guard.)
- [ ] **Determinism tests:** serial matches threaded with 0 workers, 1 worker, and
      2 real workers, at two `items_per_range` values (for example
      `scope_range_alignment_items` ×1 and ×4), over 64 consecutive steps.
      Decide lists and `coast_skips` must be identical. This shows the interval
      phase is independent of worker count. Model on `:1491`.
- [ ] **FailingAllocator proof:**
      - Warm `gatherAiDecidePopulation` on a real 2-worker `ThreadSystem` (fixed
        `items_per_range`, skip if no workers) and its serial twin after
        `reserve`.
      - Then swap the system and thread allocators to `FailingAllocator(fail_index = 0)`
        and rerun both. Each must succeed with identical outputs. This exercises
        the reserved-then-push success branch per the coding standards.
- [ ] **Pipeline tests** (minimal worlds; the 1×1-tile pattern at `:2582`):
      - **Causal wake test:** an idle ally with `gain_flee > 0` on a not-due think
        step, with the hostile out of range, coasts. It emits no
        `NavigationIntent`, its velocity is unchanged, and `decision_coast_skips == 1`.
        On its next not-due think step, with the hostile inside FOV, it decides in
        that step: the intent is present at flee priority 20 and
        `active_behavior == .flee`. This proves `ai_decide_gather` runs after
        perception.
      - **Slice 47 guard:** on the ally's coast step, a hostile thinker still
        perceives it (`nearest_threat == ally`).
      - **Render-window independence:** `test "decision coasting ignores the
        render visibility window"`. Two pipelines over the same small fixture
        (idle agents spread across at least 4 chunks so near and far bands both
        occur) run the same steps with the same `sim_view`. Before each
        `pipeline.update`, run A sets the render window
        (`setVisibleChunksForWorldRect`) to a far rect and run B to the
        `sim_view` rect. `ai_decide_indices` and `decision_coast_skips` must be
        identical on every step.
      - Update the existing dual-list test at `:2582` by giving the ally
        `gain_flee = 1.0`, which matches Slice 47's "timid ally" narrative. Its
        visible hostile then promotes it to alert, so `ai.entity_count == 1` holds
        by policy, not by hash luck. The perception asserts stay unchanged.
      - The sticky-dig linger test (`:4387`) must pass with **no Slice 55
        modification**, in the form Slice 49 migrated it to (`.sim_view`
        replacing its `:4395` window).
- [ ] **Test-migration audit.** After Slice 49, `GameDemoState.update` always
      passes a non-null `sim_view`, so coasting is active in **every** demo
      test that runs `update` (the init-time window at
      `game_demo_state.zig:414-419` no longer matters). Grep every test that
      runs `GameDemoState.update` or `pipeline.update` (every one passes a
      `sim_view` now that it is required; pipeline tests pass
      `fullWorldSimView`, so coasting applies to them on any chunked world) and
      asserts per-agent intents or motion within one stagger
      cycle, and list each in the PR. Known today:
      - `game_demo_state.zig:1831` ("demo ai processor drives non-player
        squares via intents"): loop `cognition_stagger_n *
        decision_coast_far_ticks` steps, one full decide cycle, instead of one
        stagger cycle. The assertions stay as strong as they are now.
      - `game_demo_state.zig:1676-1725` ("demo owns and completes a simulation
        frame during update"): asserts `any_square_moved` after a single
        `update`, which now depends on which agents the phase hash schedules
        on step 1. Loop one full decide cycle before the `any_square_moved`
        check, keeping the single-step player and audio asserts on the first
        step.
      - Audited as decide-independent (expected to pass unchanged; confirm in
        the PR): `:1889` (player contact response with a preset square
        velocity; a coasting square keeps it) and `:1951` (bounds clamp in
        movement, which runs by tier).
      - `simulation_pipeline.zig:2582` and `:4387` are covered above.
- [ ] **Bench groups** (`src/benchmarks/ai.zig`, registered in
      `runner.zig` after `ai.group`): `ai-idle-stagger` (control) and
      `ai-idle-coast`, sharing one fixture.
      - **Population mix:**
        - `index % 10 == 0`: alert, with `gain_flee = 1.5` plus `AiPerception`
          (`target_visible = true`), as in `ai`'s slot 2.
        - `== 1`: cohesive, with `gain_cohere = 1.5`.
        - Everything else: pure wanderers (default `AiAgent`, no
          perception/memory/affect).
        - All agents are `.ally` and cognition tier, with
          `stagger_phase = index % cognition_stagger_n`.
      - **Layout:** a 16 px lattice over 256 px chunks. The fixture's fixed
        sim-view block is chunks `[0,8)×[0,5)`. The first 25% of rows fill the
        sim-view block and the rest fill chunks at `lodDistance` 3–16. Chunk
        metadata must be consistent with positions. The cognition region is the
        sim-view block ± `cognition_halo_chunks`.
      - **Per step:** `advanceStep` and `gatherAiPopulations` run untimed. Then,
        timed: `gatherAiDecidePopulation` (coast group only) plus
        `AiSystem.update`, using production-shaped config (decide or think list as
        `scope_dense_indices`, halo as `spatial_population_indices`). The spatial
        index is built once outside timing, as in `ai`.
      - **Samples:** each sample is one full 32-step window, recorded as
        `elapsed / 32` per step. Warmup and settle also run in whole windows.
        `output_count` is mean decided rows per step, and `candidate_pairs` is mean
        separation checks per step.
- [ ] **`scope` bench mirrors production:** insert `gatherAiDecidePopulation`
      (using the fixture's fixed sim-view region) between the halo gather and
      AI. `output_count`
      becomes decided rows. Record before and after; the drop is expected.
- [ ] **Docs:**
      - `docs/architecture.md` scope paragraph (~`:470-503`): think set → decide
        set; sensing never coasts.
      - `docs/simulation-tiers-and-pipeline.md` Fixed-Step Ownership.
      - `docs/development-workflow.md` bench examples (`--group ai-idle-coast`,
        `--group ai-idle-stagger`).
      - `ai.zig` module doc and `AiConfig.scope_dense_indices` doc (decide set).
      - Roadmap: this slice's Open Frontier index row, the **Perf** track
        row, and its Scaling Gaps entries (AI separation density,
        battle-scale control rows, cognition sequencing guardrail); the AI
        candidate side-table halo walk is Slice 68A.
- [ ] **Battle soak:** ReleaseSafe, 60 s, 2048 movers. Record decide count,
      `coast_skips`, and `ai_decide_gather` per step, then update the Scaling Gaps
      control table.

### Acceptance checks

- [ ] Sensing is never coasted. The contract test passes; the Slice 47 dual-list
      test (updated as specified) and the sticky-dig linger test (no Slice 55
      modification, in its Slice 49-migrated form) pass;
      the new Slice 47 guard test passes.
- [ ] Wake preemption is proven at both the unit and pipeline (causal) levels: a
      not-due agent decides in the **same step** its sensing produces a
      gain-relevant threat or stimulus.
- [ ] Decide lists and `coast_skips` are identical for serial, 0, 1, and 2 real
      workers and two range sizes over 64 steps. The interval phase is independent
      of worker count.
- [ ] Every idle agent decides exactly once per cadence window, and idle-far
      per-step load stays at or below 3× the mean in the 256-agent fixture
      (pinned phase seed).
- [ ] The decide set is independent of the render window: the
      render-window independence pipeline test passes, and no Slice 55 code
      calls `visibleChunkRegion()` (grep in the PR).
- [ ] The FailingAllocator proof passes on the serial and real multi-worker paths.
- [ ] The null-sim-region path keeps `decide == think`; every pre-existing
      null-region test passes unchanged.
- [ ] **Bench gate**, ReleaseFast, both groups in the same build:
      - **Hard gate, decided rows:** `output_count` is ≤ 0.32 × think rows
        (analytic 0.297). This is machine-independent and pass/fail.
      - **Relative timing target:** at 10,000 and 25,000 items, `ai-idle-coast`
        mean ≤ 0.65× `ai-idle-stagger` for `serial-direct` and ≤ 0.80× for
        `thread-adaptive-tuned-range`. These ratios come from the analytic
        decide ratio, but AI cost is not linear in decided rows (the O(halo)
        candidate walk stays). **Fallback if missed:** Slice 68A closes it;
        record the halo-walk share.
      - The existing `ai` group (code path untouched) stays within the run's
        noise band versus a same-session pre-change capture.
      - Commands:
        `zig build -Doptimize=ReleaseFast bench -- --group ai-idle-stagger --items 25000 --case serial-direct`,
        then the same with `ai-idle-coast`, then both with
        `--case thread-adaptive-tuned-range`. The 10k figures come from the quick
        profile.
- [ ] **Battle soak**, recorded as diagnostic trend data
      (`.claude/rules/tests-benchmarks.md`): AI, steering, and
      `ai_decide_gather` stage lines and decide/`coast_skips` counts go in the
      control table.
- [ ] `zig build check` (comptime stage-contract checks) and `zig build verify`
      pass.

### VoidLight reference

- **What VoidLight does:**
  - `src/ai/behaviors/WanderBehavior.cpp:342-352`: a wanderer accumulates
    `movementUpdateTimer += deltaTime` and runs `handleMovement` only every
    `config.updateInterval`. The default is 5 s
    (`include/ai/BehaviorConfig.hpp:136`). In between it coasts on its current
    velocity.
  - Urgent checks run every frame, before the throttle (`:293-334`): pending
    PANIC/RAISE_ALERT messages, recent attack, fear, and hostile-in-range.
- **Ported:** the idea itself. Idle behavior coasts on persisted velocity between
  decisions, and urgent signals bypass the throttle.
- **Changed:**
  - Intervals are fixed steps aligned to the sensing stagger (8 or 32 steps),
    not `deltaTime` accumulators.
  - Per-entity timers are replaced by a stateless hash phase, so there is no
    per-entity state and nothing for Slice 46 to save.
  - Urgent checks are not extra per-frame queries. They are the base-cadence
    sensing outputs read as columns.
  - The cap is 0.53 s, not 5 s, bounded by the wander epoch and the near-band
    reasoning above.
- **Not ported:** `src/ai/internal/Crowd.cpp:39-99` `SpatialQueryCache`. It is a
  `thread_local` 64-entry cache keyed by an 8 px-quantized position+radius hash
  with frame stamps. Its results depend on which worker ran which query first and
  on hash collisions, so they depend on worker count and order. ZeroLight caches
  no crowd counts: a coasting agent simply does not query. Any future cached crowd
  quantity must be a per-agent SoA column written at that agent's own decision
  (range-disjoint), never a per-thread position-keyed cache.
- **Numbers:** VoidLight's release AI bench is 25k wanderers at 0.44 ms
  single-threaded, with a 5 s coast. ZeroLight's `ai` group today is 6.48–6.60 ms
  serial and 3.09 ms adaptive at 25k ReleaseFast, with every agent thinking, no
  stagger, no coast, and a dense fixture. This is **not** a parity target: the
  intervals, fixture density, and VoidLight's nondeterministic cache all differ.
  After 55, the expected serial floor for an idle-heavy 25k population is
  `AiSystem`'s O(halo) main-thread candidate walk ("AI candidate side-table halo walk", now Slice 68A).

