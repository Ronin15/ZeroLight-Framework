## Slice 32: AI Behavior Arbitration

Goal: close the emergent-AI locomotion loop by selecting among composed
behaviors (flee, pursue, investigate, cohere, wander) via **utility scores**
over perception, memory, and **emotion drives** (`AiAffect`), resolving a
**per-agent goal**, and emitting the existing `NavigationIntent` so steering /
pathfinding / movement stay unchanged. Land a **reusable weight-resolution +
sticky-selection contract** that future non-AI producers can share, without
locking the project to "everyone seeks the player," an exclusive FSM, or a
frozen four-feeling if-tree.

Problem (code before this slice):

- `AiBehavior` was only `{ wander, seek }` (`data_system/types.zig`).
- `decideDir` blended seek-toward-`(tx,ty)` + wander noise; separation was a
  fixed post-blend (`systems/ai.zig`). `priorityForBehavior` was seek=10 /
  wander=0.
- `SimulationPipeline` always passed the player's previous position as
  `AiConfig.seek_target` / `seek_entity` with `nav_request_kind = .group`.
  Cold-memory retarget only substituted that same entity's last-known XY.
- `AffectSystem` ran and wrote drives every cognition step, but `ai_decide`'s
  stage contract did not list `affect_drives` as a read, and `AiConfig` had no
  affect slice — drives were dead output.
- Demo movers never attached `ai_perception` / `ai_memory` / `ai_affect`, so
  the live app could not exercise the stack even after unit tests passed.
- Goal level stayed pinned to surface for NPC seeks (pipeline comment) —
  explicitly out of scope for this slice, not made worse by new resolvers.

Current foundation (pre-existing, not rebuilt):

- Pipeline stage order and barriers: perception → memory → affect → AI →
  steering → pathfinding (`simulation_pipeline.zig`).
- `NavigationIntent` (`simulation.zig`): entity, kind, goal_level, goal XY,
  direct_direction, priority. Steering's highest-priority-wins selection stays
  the multi-emitter arbitration for *streams*, separate from *behavior utility*.
- Perception hot columns: `target_visible`, `last_seen_*`, `nearest_threat`,
  `nearest_threat_dist`, `heard_stimulus` + XY, facing.
- Memory: `last_known_*`, `staleness`, `familiarity`, fixed ring
  (`ai_memory_ring_capacity = 4`).
- Affect / emotion: four drives in `[0,1]` + baselines/decay/thresholds +
  Schmitt mask (`AiAffect` / `AffectSystem` — Slice 31).
- Spatial index + AI separation query path (Slice 28).
- Deterministic RNG (`core/rng.zig`) with salt channels.
- Cognition-scoped `ai_indices` gather (Slice 24).

Architecture notes — expandability first:

**What "arbitration" means here (and what it is not):**

| Do | Do not |
| --- | --- |
| Score a **fixed enum** of behavior candidates from columnar signals | Build a behavior tree, GOAP planner, or dynamic graph |
| Select one **primary** locomotion mode with sticky hysteresis | Flap every step on noisy score ties |
| Resolve **goal XY (+ optional goal entity)** per agent from signals | Keep broadcast player seek as the only production goal path |
| Emit one `NavigationIntent` per AI row through the existing stream | Add a new pipeline stage between AI and steering |
| Put active mode + scores in **hot columns** for debug/tests | Emit per-step "chose X" events for every agent |
| Expose pure `score` / `select` / `resolveGoal` helpers as a reusable contract | Hardcode another one-off priority ladder only AI understands |
| Treat missing perception/memory/affect as **zero signal** | Require all three components or skip the agent |
| Keep local separation as a **force modifier** after mode selection | Force cohere/separation to fight exclusive winner-take-all alone |
| Map **emotion → behavior via a drive×behavior weight table** | `if (fear > x) return .flee` as the only permanent pattern |
| Read live drive columns (`fear`…`fatigue`) every AI step | Ignore `AiAffect` or invent a second mood channel beside it |

Behavior set (fixed for this slice — extend by adding an enum tag + score
term + goal resolver, not by rewriting the stage):

| `AiBehavior` | Primary goal | Utility drivers (illustrative, constants tunable) |
| --- | --- | --- |
| `wander` | none (direction noise only) | baseline when nothing else scores; residual wander gain |
| `pursue` | visible `nearest_threat` else fresh memory of that threat / configured focus | aggression + threat proximity + (optional) memory freshness |
| `flee` | point **away from** threat / last-known threat | fear + threat proximity |
| `investigate` | heard stimulus XY, else freshest interesting ring contact | curiosity + stimulus present + low familiarity |
| `cohere` | local neighbor center-of-mass from spatial index (bounded samples) | personality cohere gain + local density; not affect-primary |

Explicitly out of scope (deferred to other slices, not half-wired here):

- Attack / interact / use intents (Slice 40).
- New stimulus producers beyond dig (Slice 39).
- World interest markers / cover points (Slice 41).
- JSON archetypes and debug overlay (Slice 33).
- SIMD restructure of separation/`decideDir` loops (Slice 35) — this slice's
  arbitration math is scalar-correct by design; data is shaped
  (`[behavior_count]f32` scores, `[drive_count][behavior_count]f32` weight
  table) so 35 can pack it later.
- Cross-level goal_level autonomy beyond existing start_level from entity
  level column.
- The optional `behavior_changed{entity, from, to}` event this slice's own
  design notes flagged as **optional** ("add if Slice 33 debug or a domain
  reaction needs it") — deliberately not built since neither consumer exists
  yet; `active_behavior` stays columnar-only. Add it when Slice 33's debug
  overlay or a domain reaction actually needs the edge.

Checklist:

- [x] Land pure sticky weight-resolution helpers with unit tests (argmax, ties
      by stable index, sticky hold within bonus, commitment countdown, zero
      allocation).
- [x] Expand `AiBehavior` to `{ wander, pursue, flee, investigate, cohere }`;
      migrate all `.seek` call sites; update affect fatigue "active pursuit"
      detection if it keys on behavior.
- [x] Expand `AiAgent` cold gains + commitment tunables and hot
      `active_behavior` / `commitment_remaining`; store, template, structural
      commands, validation, tests.
- [x] Gather affect (+ existing perception/memory) into AI gather rows; score
      via a **drive×behavior weight table** (plus perception/memory terms);
      sticky-select; write hot active-behavior columns.
- [x] Implement per-behavior goal resolvers and direction emitters; replace
      exclusive broadcast-seek as the only pursue path while keeping an
      optional `focus_target` fallback for demos.
- [x] Update `stageContract(.ai_decide)` to read `affect_drives`; thread affect
      slice through `SimulationPipeline` → `AiConfig`.
- [x] Adjust path `kind` policy so agent-specific goals do not falsely share a
      group flow field; document when `.group` remains valid.
- [x] Wire a demo subset with perception/memory/affect + distinct **emotion
      baselines/gains** (timid high fear baseline / flee weight, aggressive high
      aggression, curious high curiosity); reserve perception/affect event
      budgets accordingly.
- [x] Headless tests: each behavior's intent direction/goal shape; sticky
      non-flapping under threshold noise; serial == threaded; missing optional
      components degrade to wander/fallback; **identical perception/memory with
      only affect differing changes winner**; `FailingAllocator` steady-state
      proof on the AI update path; no steering/pathfinding API changes.
- [x] Benchmark: extend `src/benchmarks/ai.zig` reporting agent count,
      selections per behavior histogram counters, and intent count — measured
      at cognition-scoped scales (1,024–50,000 agents), not only demo counts.
- [x] Update `docs/architecture.md` AI / pipeline paragraphs: **emotion drives
      are consumed**; arbitration utility vs stream priority; per-agent goals;
      table-driven drive mapping.

Acceptance checks:

- [x] Same inputs → same `active_behavior`, goals, and `NavigationIntent` order
      for serial and threaded runs.
- [x] Agents with high fear + visible threat emit flee-away intents; high
      aggression pursue threat; curiosity + stimulus investigate toward stimulus;
      cohere agents bias toward local COM; wanderers without signals keep
      noise-driven motion.
- [x] **Feelings are load-bearing:** drive columns from Slice 31 measurably
      change selection (fixture where only `AiAffect` hot values differ →
      different winning behavior). Agents without `AiAffect` still function.
- [x] Emotion mapping is table/data extensible: scoring goes through a
      drive-indexed path, not a closed `switch` that only names today's four
      drives in a way that forbids appending a fifth without control-flow
      rewrites (documented extension point for Slice 42).
- [x] Downstream steering / pathfinding / movement module APIs and merge
      contracts unchanged (no new stages after AI).
- [x] Steady-state AI path allocation-free after reserve/warmup.
- [x] Demo subset with full cognition components runs without event-capacity
      throws; `zig build test`, `zig build check`, `zig build verify` pass.
- [x] Targeted `zig build bench -- --group ai` shows selection cost and does
      not regress separation intent counts for the baseline seek-equivalent
      case beyond noise.

**Status: landed.** `AiBehavior` is `{wander, pursue, flee, investigate,
cohere}` (`data_system/types.zig`); `.seek` has no remaining production call
sites. `AiAgent` carries cold `gain_wander`/`gain_pursue`/`gain_flee`/
`gain_investigate`/`gain_cohere`/`wander_amplitude`/`commitment_max_steps`/
`sticky_bonus` (validated non-negative, capped by `max_ai_gain`) and hot
`active_behavior`/`commitment_remaining`/`last_score`. The new pure module
`src/game/systems/arbitration.zig` (zero-alloc, no vtables, no dependency on
`AiSystem`/pipeline/spatial index) implements `scoreBehaviors` (a
`[drive_count][behavior_count]f32` weight table dimensioned off
`@typeInfo(AiAffectDrive)`, scaled by personality gains, plus small
perception/memory bonus terms), `selectSticky` (holds the previous behavior
while `commitment_remaining > 0` unless a challenger clears
`sticky_bonus + min_delta`, else argmax with ties broken by lowest enum
index), and `resolveGoal` (per-behavior goal resolution). `AiSystem`
(`src/game/systems/ai.zig`) gathers `arbitration.Signals` per row and runs
this chain **inside** the already-threaded `writeAiIntentsJob`/
`writeAiSeparationJob` range jobs (no new pipeline stage; `updateSerial`
dispatches the same job functions through a single full-range call, so
serial and threaded share one code path by construction). Cohere's
neighbor-mean gather rides the existing separation-stage `queryNeighbors`
call against the shared spatial index (Slice 28), filtered to friendly
stance — no second grid.

The player-broadcast is gone: `simulation_pipeline.zig`'s production
`self.ai.update(...)` call no longer forces `nav_request_kind = .group` or a
single shared `seek_target` — perception's `nearest_threat` (already
faction-generic via `stance()`, not player-special-cased at the perception
layer) is pursue/flee's primary signal, with fresh `AiMemory` as the second
tier and the renamed `AiConfig.focus_target`/`focus_entity` (fed from the
player) as an explicit, opt-in, `gain_pursue > 0`-gated last-resort fallback
only. `stageContract(.ai_decide)` reads `affect_drives` (written one stage
earlier by `affect_update`); `AiConfig.affect_slice` threads
`data.aiAffectSliceConst()` in. Path-request `kind` is a ceiling, not a
broadcast: `kind_hint` from `resolveGoal` (currently always `.individual` —
cohere's future shared-quantized-cell `.group` upgrade is an explicit,
documented extension point, not built here) wins over
`AiConfig.nav_request_kind`, which now defaults to `.individual` in
production.

`game_demo_state.zig` attaches `ai_perception`/`ai_memory`/`ai_affect` to a
subset of demo movers via an 8-slot `demoArchetypeForIndex` cycle: `timid`
(high `baseline_fear`/`gain_flee`, `.ally` faction), `aggressive` (high
`baseline_aggression`/`gain_pursue`), `curious` (high
`baseline_curiosity`/`gain_investigate`), and `cohesive` (`gain_cohere` only,
no cognition components — cohere reads the spatial index directly), alongside
preserved wander/fallback-pursue/no-`AiAgent` contrast groups. `timid`'s
`.ally` faction is deliberate: it gives `aggressive` a real non-player
hostile target to perceive and pursue, and `timid` a real non-player threat
to flee, so the demo itself exercises "agents react to each other, not just
the player." Perception/affect event budgets
(`perception_max_events_per_step`/`affect_max_events_per_step`) are derived
from the cognition-agent subset size, not left at the prior `0`.

Bench group `ai` (`src/benchmarks/ai.zig`) now cycles a 5-archetype fixture
(one per `AiBehavior`) and reports a per-behavior selection histogram plus
intent count alongside timing, at 1,024–50,000-agent scale; all five buckets
populate at every scale and `intents == item_count` throughout, with no
throughput regression from the pre-arbitration baseline.

**Residual expandability (tracked, not incomplete 32 work):**

- Cohere's `.group` path-kind upgrade for agents sharing an identical
  quantized goal cell is a documented extension point in `resolveGoal`, not
  implemented — `nav_request_kind` is currently inert (every behavior
  resolves `.individual`).
- The optional `behavior_changed` event stays unbuilt until Slice 33's debug
  overlay or a domain reaction needs it (this slice's own design notes marked
  it optional).
- Cross-level `goal_level` autonomy beyond the entity's current `world_level`
  is unchanged, per this slice's explicit scope boundary.
- Growth path for new feelings/drives is **Slice 42** (append a drive row to
  the weight table, no control-flow rewrite); growth path for authored
  personalities is **Slice 33** (JSON archetypes replace the hardcoded
  `demoArchetypeForIndex` bundles).

