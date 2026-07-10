# Framework Implementation Slices

This roadmap is the agent implementation contract for the project frontier. Work
is organized as **numbered slices**: each slice is one complete, verifiable
feature chunk with a **Goal**, **Checklist**, and **Acceptance checks**. Agents
implement by opening a slice section, checking items off only when integrated,
and running `zig build verify` before marking the slice complete.

Settled slices (0–8, 9–17, 18–25E, 26–32, 34, 36) live in
[framework-implementation-slices-archive.md](framework-implementation-slices-archive.md).
This file is the **open frontier**: agent workflow, priorities, Scaling Gaps,
track overviews, and open slice sections only.

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
   Order** when dependencies matter. Confirm prerequisites are settled (their
   archive sections and/or live Status) before starting.
2. **Open the open slice section** in this file (`## Slice N: …`), or the
   archive if you need a landed prerequisite's acceptance record. Read **Goal**,
   **Current foundation**, and **Architecture notes**; cross-read
   [architecture.md](architecture.md) and any doc linked in the slice.
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
| **Status** | Open/partial note, or one-line completion record before archive move |

When a frontier slice is fully complete, **move its entire section** to
[framework-implementation-slices-archive.md](framework-implementation-slices-archive.md),
update the Open Frontier index, and leave residual follow-ups only in
**Scaling Gaps** or the next consuming slice. Do not delete acceptance history —
archive it.

## Open Frontier Slice Index

Use this index to choose the next slice; **implement from that slice's section**
(checklists live there, not here). Settled acceptance history is in the
[archive](framework-implementation-slices-archive.md).

| Slice | Status | Open work (see slice section for full Checklist) |
| --- | --- | --- |
| **33** | **Next** | Data-driven AI archetypes + debug introspection — depends on Slice 32 (landed) |
| **35** | Not started | AI/steering hot-loop SIMD restructure — after 32 reshapes AI loops |
| **37** | Not started | Dense render-window ceiling raise (32→128) + shader/host layer-count sync hardening |
| **38** | Not started | Elevation above the surface (depends on Slice 37) |
| **39** | Not started | Sensory stimulus ecosystem — more `WorldStimulus` producers/kinds |
| **40** | Not started | Action/interaction intent substrate |
| **41** | Not started | World interest / affordance markers |
| **42** | Not started | Affect expansion — more emotion drives, coupling, appraisal gains, optional mood |
| **43** | Landed (manual HW verification pending) | SDL3 gamepad/controller support — single active device, analog movement, default button bindings (app/input layer, independent of AI slices 33/35/37-42) |

**Recently settled (archive only):** 32, 8, 18–25E, 26–31, 34, 36 (plus 0–7, 9–17).
**Residual non-slice backlog:** 23A `expand2`→`world` merge and optional render
micro-opts — see **Scaling Gaps** / Next Priority Tracks, not a live slice body.

**Bench policy:** 50k bench scales are throughput ceilings, not per-frame targets.

## Next Priority Tracks

Sequencing hints only — **does not replace slice Checklists**. When in doubt,
follow **Suggested Order** and the open items in the target slice section.

- **Slice 32 (behavior arbitration) is landed** — the closed loop that turns
  perception/memory/**emotion drives** into varied locomotion intents.
  `arbitration.zig` scores `wander`/`pursue`/`flee`/`investigate`/`cohere` via
  a table-driven drive×behavior weight matrix, sticky-selects one, and
  resolves a per-agent goal; the broadcast "everyone seeks the player" path is
  gone — perception's faction-generic `nearest_threat` is the primary pursue/
  flee signal, and the player is reachable only through an explicit, opt-in,
  gain-gated `AiConfig.focus_target`/`focus_entity` fallback. See the archive's
  Slice 32 entry for the full record.
- **Emotion substrate (Slice 31) is now consumed** — fear, curiosity,
  aggression, fatigue feed arbitration's weight table every cognition step via
  `AiConfig.affect_slice`; `stageContract(.ai_decide)` reads `affect_drives`.
  Slice 42 is how the **feeling set and coupling grow** without rewriting AI.
- **Next implementation slice: 33** (archetypes + debug) so personalities
  (including affect baselines and future appraisal gains) and tuning are
  data-driven and observable — required before claiming live "emergent" demo
  interplay.
- **Keep systems expandable (standing rule, not just a 32 requirement):** the
  weight-resolution and per-agent goal-resolution contract Slice 32 landed
  (`scoreBehaviors`/`selectSticky`/`resolveGoal` in `arbitration.zig`) is
  reusable by future producers, not a one-off. Emotion → behavior mapping stays
  **table-driven over `AiAffectDrive`**, not a permanent `if (fear) flee` tree
  that freezes the four-drive set. Do not lock agents to the player as the only
  goal, do not replace utility with an exclusive FSM, and do not grow
  production APIs with test-only tags.
- **After the locomotion AI closed loop (32–33):** Slice 39 (stimulus richness),
  41 (world interest), 40 (action intents), and **42 (affect expansion)** unlock
  richer senses, non-locomotion emergence, and more feelings. Render slices
  37–38 and SIMD restructure 35 are independent tracks — interleave by need.
- **Component headroom:** 13 of 32 `Component` tags used (`enum(u5)` +
  `ComponentMask = u32`). No widening required for Slices 32–33; promote a
  widening slice only when a new tag would exceed 32 (see Scaling Gaps).
- Guard CPU paths with existing benches; keep SDL_GPU submit on the render thread.
- Hardening without a slice number: collision-response merge, `SpriteBatch`
  capacity, text-cache lifetime, 23A `expand2`→`world` merge (track when
  scheduled as slices).
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
- [x] **Per-entity depth axis.** Landed in archive Slice 25E (`world_level` /
      scope level / render cull alignment). Residual multi-floor chase policy
      is product work on open slices, not a missing column.
- [ ] **Component storage headroom.** `Component` is `enum(u5)` (32 tags) and
      `ComponentMask` is `u32` — 13 tags used after Slices 26–31
      (`movement_body`…`ai_affect`). Free headroom covers Slice 32 hot columns
      on existing stores and Slice 33 authoring without a new component.
      Promote a widening slice only when the first new tag would exceed 32
      (likely when action/affordance components land in 40–41 or later).
- [ ] **Multi-world scope policy.** Inactive world instances stay out of
      pipeline scope; the active world uses chunk + halo rules (Slice 22
      deferred).

**Branch / packaging residuals**

- [ ] **Slice 23A merge residual.** GPU tilemap hardening is landed on
      `expand2` (archive Slice 23A). Remaining: land as a coherent commit stack
      and merge to `world`; optional O(n) linear `mergeDrawList` micro-opt only
      after measuring.

**Render scale**

- [ ] **Dynamic collect scan cost.** Collect walks every movement-body row;
      camera gates skip draw prep but not the scan. Hardening: warmed visible
      movement dense-index list parallel to scoped simulation gathers (Slice 22
      handoff; partial inline gating landed in 24B).
- [ ] **Dense floor submit vs camera.** Each dense composite draw (Slice 36) is
      still one full-world tilemap quad regardless of camera pan (GPU clips).
      Hardening: chunked dense submit if quad cost dominates at very large
      worlds.
- [ ] **On-screen record ordering.** `finalizeDepthBuckets` sorts collected
      dynamic records; replace with fixed-band or counting buckets when on-screen
      density rises (Slice 24B follow-up).
- [ ] **Bench phase isolation.** Split `render-game-prep` collect vs sparse/dynamic
      emit timers so regressions name the hot phase (Slice 24B follow-up).

**Sequencing guardrails**

- Raise entity stress counts and world depth only after `validateDenseRenderBudget`
  passes and scope stats show typical participation stays below bench ceilings.
- Per-entity depth alignment (archive 25E) is settled before multi-floor
  gameplay scenarios that depend on cross-level entity presence.
- Slice 32 (arbitration + per-agent goals) is landed; land Slice 33 before
  shipping data-tuned personalities in the demo.
- Do not scale cognition population (archetype swarm stress) until arbitration
  is gated by the existing cognition-scope dense indices and benches report
  intent-selection cost separately from pathfinding.
- Keep locomotion emergence (32–33) independent of action/combat emergence
  (40+): NavigationIntent contract stays stable while action intents grow
  beside it, not inside it.

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

**Emergent-gameplay expandability (do not regress):**

- **Compose signals, do not hardcode stories.** Perception, memory, and
  **emotion drives** are columnar inputs; arbitration (32) turns them into
  intents via utility weights. New domains add inputs or intent kinds — they do
  not rewrite AI into scripted cutscenes or exclusive FSMs.
- **Feelings are first-class, not flavor text.** `AiAffect` is persistent SoA
  state with appraisal, decay, thresholds, and transition events (Slice 31).
  Behavior must *read* drives (32); new feelings extend the drive set and
  appraisal (42) rather than bolting onside channels or string moods.
- **Locomotion vs action stay separate streams.** `NavigationIntent` remains the
  high-level movement goal. Attack/interact/use land as a parallel action-intent
  substrate (Slice 40), not as overloaded `NavigationIntent` fields or string
  topics.
- **Goals are per-agent and multi-source.** Broadcast "everyone seek the player"
  is a demo convenience, not the long-term production path. Goal resolution
  reads perception threats, memory last-known/ring contacts, stimuli, and later
  world interest markers (Slice 41).
- **Authoring is data, runtime is enums/scalars.** Archetypes (33) resolve at
  load into component bundles and fixed gain tables; hot paths never parse JSON
  or hash string behavior names.
- **Domain controllers orchestrate; processors scale.** Combat, spawning, rules,
  and encounters are pipeline-composed controllers with budgets and cooldowns —
  they emit typed frame outputs and structural commands, never own renderer/
  audio handles or per-entity heap maps on the hot path.

## Frontier Slice Records (open only)

**Agent source of truth for implementation.** Each open `## Slice N` block is a
complete work chunk: read **Goal** → check off **Checklist** items → pass
**Acceptance checks** → update **Status** → when fully done, **move the section
to the archive**. Use **Open Frontier Slice Index** to choose N. Settled slices
are not duplicated here.

## Emergent AI Track Overview (Slices 26–33, +39–42)

Goal: layer emergent NPC behavior — perception, memory, **feelings/emotions**,
and richer behavior arbitration — on top of the navigation substrate, while
staying allocation-free on hot paths, deterministic (serial == threaded, scalar
== SIMD), and affordable at scale by running only under the cognition tier gated
by Slice 24.

**Track status (code-authoritative):**

| Layer | Slice | Status | What it produces |
| --- | --- | --- | --- |
| Faction / RNG / spatial index | 26–28 | Landed | Stance table, deterministic draws, shared neighbor index |
| Perception | 29 | Landed | Vision/hearing columns + acquire/lose events; dig stimuli only |
| Memory | 30 | Landed | Last-known + ring + familiarity; cold-seek retarget in AI |
| **Emotion / affect** | **31** | **Landed** | **fear / curiosity / aggression / fatigue** SoA drives, per-entity baselines/decay/thresholds, Schmitt threshold events; **consumed by arbitration (32)** |
| **Arbitration** | **32** | **Landed** | Utility over 29–31 → per-agent `NavigationIntent`, table-driven drive consumption, sticky selection |
| Archetypes / debug | 33 | Open | JSON personalities + overlay (incl. drive bars / affect blocks) |
| Stimulus ecosystem | 39 | Open | More producers/kinds so hearing is not dig-only |
| Action intents | 40 | Open | Non-locomotion intent stream (attack/interact/use) |
| World interest | 41 | Open | Durable investigate/cover/resource markers |
| **Affect expansion** | **42** | Open | More drives, cross-drive coupling, data-driven appraisal gains, optional mood |

### Emotion / feelings model (landed + expandability)

**What exists today (do not rebuild):**

| Piece | Location | Role |
| --- | --- | --- |
| `AiAffectDrive` | `data_system/types.zig` | Closed enum: `fear`, `curiosity`, `aggression`, `fatigue` |
| `AiAffect` component | same + `data_system/affect.zig` | Per-drive baseline / decay_rate / threshold (cold) + live value in `[0,1]` (hot) + `above_threshold_mask` |
| `AffectSystem` | `systems/affect.zig` | Cognition-scoped appraisal from perception + memory + agent mode; decay; threshold events |
| `affect_threshold_crossed` | `simulation.zig` | Scalar event `{ entity, drive, rising }` — panic onset / calm, etc. |
| Pipeline slot | `affect_update` before `ai_decide` | Correct order for a consumer; wired to arbitration (32) via `AiConfig.affect_slice` |

**Design rules that keep feelings expandable (do not regress):**

1. **Drives are independent scalar columns**, not a single mood enum and not a
   heap of named emotions. Adding a feeling is "another drive," not a new AI
   subsystem.
2. **Appraisal is optional-input.** Missing perception/memory contributes zero
   signal; agents without `AiAffect` simply have no emotional modulation.
3. **Hot values are continuous `[0,1]`**; discrete "states" are derived via
   thresholds + hysteresis (`above_threshold_mask`), not exclusive FSM tags.
4. **Consumers index by `AiAffectDrive` / fixed drive-count tables**, never by
   string name and never by hardcoding only today's four tags in a way that
   forbids a fifth (Slice 32 requirement — see below).
5. **Events are edges only.** Continuous drive levels stay in columns; only
   rising/falling threshold crossings enter the event stream.
6. **Headroom before a layout change:** `above_threshold_mask` is `u8` → up to
   **8 drives** with the current bit packing. Named SoA fields scale by adding
   columns (mechanical store work). Past 8 drives, widen the mask (and likely
   move to drive-indexed arrays) in Slice 42 — not ad hoc mid-feature.
7. **Cross-drive coupling and extra feelings are Slice 42**, not silent
   half-wires inside 32. Slice 32 may *read* the four drives; it must not invent
   a second parallel emotion channel.

**How to add a new feeling later (contract for Slice 42 / implementers):**

1. Append a tag to `AiAffectDrive` (preserve existing `@intFromEnum` order —
   append only).
2. Add cold baseline/decay/threshold + hot value columns on `AiAffect` /
   store / slices / template / validation (same pattern as existing drives).
3. Add one appraisal path in `AffectSystem` (signal → delta → decay → clamp →
   threshold bit). Prefer a shared `combineDrive` helper already used by the
   four drives.
4. Extend archetype JSON (33) and debug bars (33) for the new drive.
5. Add **one row** to arbitration's drive→behavior weight table (32's contract)
   — do not rewrite `decideDir` as a special case.
6. If drive count exceeds 8: widen `above_threshold_mask` and consider packing
   drives as `[drive_count]f32` columns instead of named fields (Slice 42).

**Closed-loop status: Slice 32 landed.** The pipeline order
`perception → ai_memory → affect → ai_decide → steering → pathfinding`
(`simulation_pipeline.zig` `stage_order`) is unchanged — no new `StageId` was
added. `AiSystem`'s `ai_decide` stage now: scores `AiBehavior`'s five
variants (`wander`/`pursue`/`flee`/`investigate`/`cohere`) via
`arbitration.scoreBehaviors`'s table-driven drive×behavior weight matrix,
sticky-selects one via `arbitration.selectSticky`, and resolves a per-agent
goal via `arbitration.resolveGoal` — pursue/flee prefer perception's
faction-generic `nearest_threat` or fresh `AiMemory` over the opt-in,
gain-gated `AiConfig.focus_target`/`focus_entity` player fallback; investigate
prefers heard stimuli over memory-ring contacts; cohere reads the shared
spatial index for a friendly-neighbor mean. `game_demo_state.zig` now attaches
`ai_perception`/`ai_memory`/`ai_affect` to a subset of demo movers
(`demoArchetypeForIndex`: timid/aggressive/curious/cohesive archetypes) with
sized event budgets. See `docs/framework-implementation-slices-archive.md`'s
Slice 32 entry for the full implementation record.

Slices 39–41 expand the *inputs and outputs* of that loop so emergence is not
permanently limited to "chase or wander around the player after a dig."

Sequencing rationale:

- Slices 26–28 are framework foundations (landed).
- Slices 29–31 are the composing signal stack (landed).
- **Slice 32** is behavior arbitration — the first consumer of affect and the
  first per-agent multi-behavior / multi-goal selector (landed).
- **Slice 33** is authoring/tuning infrastructure so the loop is data-driven
  and observable (next).
- **Slices 39–42** are post-loop expandability: richer senses, non-locomotion
  actions, world-authored interest points, and **more/coupled feelings**. They
  must not be folded into 32 as half-wired stubs — each is a full slice with
  its own checklist.

Shared design contracts for the whole track:

- Each new per-entity concept follows the existing component-store pattern in
  the `data_system/` subpackage (fronted by `data_system.zig`; `Component`,
  `EntityTemplate`, and related types live in `data_system/types.zig`):
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
- High-volume per-frame data (e.g. "who each agent sees this frame", behavior
  scores, active mode) lives in component columns / transient frame buffers,
  never in the event stream. Only state *transitions* (acquired/lost target,
  drive threshold crossed, optional behavior-mode edge) become events.
- **Expandability contract (track-wide):**
  - Prefer **utility scores + sticky selection** over exclusive FSMs.
  - Prefer **per-agent resolved goals** over broadcast single-target config.
  - Prefer **optional signal components** (missing perception/memory/affect
    contributes zero signal, never excludes the agent — same pattern Slice 31
    already uses for appraisal inputs).
  - Prefer **new intent streams or new score terms** over overloading
    `NavigationIntent` or growing string/hash dispatch on the hot path.
  - Prefer **fixed enum behavior labels + columnar gains** over dynamic
    behavior graphs, BT trees, or per-entity `ArrayList` planners.
  - Downstream steering / pathfinding / movement contracts stay unchanged
    unless a later slice explicitly owns a contract change.
## Slice 33: Data-Driven AI Archetypes And Debug Introspection

**Status: not started.** Depends on Slice 32's behavior set, `AiAgent` gains,
and hot `active_behavior` columns.

Goal: make the closed emergent-AI loop **authorable without recompiling** and
**observable while tuning**, so personalities (timid / curious / aggressive /
cohesive) are data, not one-off `DemoSpawnSpec` literals — without putting JSON
or string behavior names on the hot path.

### Current foundation

- Slice 32 (required) lands utility arbitration, gains, active behavior, and a
  Zig-hardcoded demo subset.
- Atlas metadata workflow (`docs/atlas-asset-workflow.md`,
  `world_tileset_meta.zig` / sprite atlas JSON) is the pattern for strict
  load-time validation → runtime enums/IDs.
- Debug overlay exists under `src/render/` (`debug_overlay.zig` / stub) with no
  AI introspection.
- `RuntimeAssets` / manifest already own stable asset IDs; archetypes must
  resolve to the same class of stable identifiers (faction enum, component
  bundles), never file paths or live SDL handles in saved gameplay state.

### Architecture notes

- **Load-time only:** parse JSON at loading-state / asset-catalog time into a
  fixed `AiArchetypeId` (enum or dense u16) and a table of prevalidated
  component defaults + gains. Gameplay spawn references the id; `DataSystem`
  receives concrete components via existing structural commands / templates.
- **Strict validation:** unknown keys fail loud; ranges clamp or reject per
  existing `validateAi*` helpers; no silent defaults for required fields once
  an archetype opts into a component.
- **Hot path remains enum/scalar:** no hashmap from string behavior name during
  fixed-step update.
- **Debug draw is render-only:** read immutable slices after simulation; never
  mutate drives/memory from the overlay; never enable draw paths in
  `zig build bench` measurement of AI.
- **Determinism:** overlay presence must not change simulation outputs (no
  RNG consumption, no extra events).

### Checklist

- [ ] Define archetype JSON schema (documented in `docs/` or beside the loader):
      faction, optional perception/memory/**affect** blocks (per-drive baseline,
      decay_rate, threshold — and, once Slice 42 lands, appraisal gains),
      `AiAgent` behavior gains and wander amplitude, steering defaults,
      sprite/asset reference by stable id. The perception block should let
      archetypes differentiate `AiPerception`'s already-per-entity
      `vision_range`/`hearing_range`/`fov_half_angle_radians` (e.g. a
      keen-eyed sentry with long `vision_range`, or a blind tracker with
      `vision_range` near 0 and a large `hearing_range`) — mechanically
      already supported since these are cold per-entity fields, not global
      constants; today's demo archetypes (Slice 32) just don't vary them.
- [ ] Implement loader + strict validation tests (good file, missing field,
      out-of-range gain, unknown behavior key, unknown faction, **unknown
      affect drive key**).
- [ ] Register archetypes in runtime asset / content path used by
      `LoadingState` (same install-tree rules as other assets).
- [ ] Migrate demo spawns to named archetypes (minimum set: `timid`,
      `curious`, `aggressive`, `cohesive`, optional `wanderer`) whose
      **emotion baselines** differ enough to show flee / investigate / pursue /
      cohere under the same world.
- [ ] Extend debug overlay (gated by existing debug flag):
      - vision cone / range ring from perception cold+facing
      - **emotion drive bars** (fear/curiosity/aggression/fatigue; above-
        threshold highlight)
      - last-known memory marker + ring ticks
      - active behavior label
      - scope/tier counts from existing scope stats (no new sim policy)
- [ ] Document authoring workflow in `docs/development-workflow.md` or a short
      `docs` note linked from the atlas/AI sections — include "how to tune a
      personality's feelings" via affect blocks.
- [ ] Optional: promote deferred `memory_expired` event only if debug or a
      reaction needs it; otherwise keep columnar (Slice 30 decision stands).

### Acceptance checks

- [ ] Archetypes load from data with strict validation; spawns apply component
      bundles identical to hand-built fixtures for the same numbers.
- [ ] Demo shows differentiated behavior under the same world stimuli without
      code edits to gains (**timid fear → flee**, **curious → investigate dig
      noise**, aggressive pursues, cohesive clumps).
- [ ] Debug overlay visualizes perception / **emotion drives** / memory /
      active behavior / scope without changing serial simulation checksums /
      intent streams.
- [ ] No hot-path JSON or string behavior/emotion lookup; `zig build verify`
      passes.
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

## Slice 37: Dense Render-Window Ceiling Raise And Shader/Host Sync Hardening

Goal: raise the composited dense render-window ceiling from 32 to a materially
larger, reasoned bound (128) so worlds bigger than today's demo (more levels,
more dense bands per level) can use Slice 36's single-pass compositing path,
and permanently close the one gap Slice 36 left open: the GLSL shader's
fixed-size layer-offset array and its Zig-side mirror struct are not tied to
any shared constant, so a future ceiling bump could silently overrun a fixed
array in a ReleaseFast build instead of failing to compile.

Why now: Slice 23B's original goal targeted ~120 depth levels; the ceiling
that shipped (`k_max_dense_submit_stack_cap = 32`) never actually reached it.
Today's shipped procedural world already sits at that ceiling (its render
window intentionally spans the full 31-level authored stack, Slice 36's
payoff). Slice 38 (elevation above the surface) needs headroom in the same cap
to add levels above the player without shrinking how many can be below — this
slice is a prerequisite for that, not just a number bump.

Problem (current envelope):

- `world_system.k_max_dense_submit_stack_cap = 32` bounds
  `DenseLayerRenderWindow.maxSubmitLayers()`; `Renderer.k_max_tilemap_window_layers`
  and `Renderer.k_max_dense_composite_draws` are comptime-tied to it via
  cross-module asserts (`world_system.zig:60-70`). All three must move
  together.
- `assets/shaders/tilemap.frag.glsl`'s `uvec4 layer_offsets[8]` (32 `u32`
  slots) and `sprite_batch.zig`'s `TilemapParams.layer_offsets: [32]u32` both
  hardcode that literal independently of `Renderer.k_max_tilemap_window_layers`.
  Nothing currently fails to compile or asserts at runtime if these three
  values drift apart. `Renderer.applyWindowLayers`'s existing assert only
  checks the caller's `window.count` against the Zig constant, not the
  physical array size — so bumping the Zig constant alone would pass that
  assert and then write past the end of the fixed 32-slot array. In Debug/
  ReleaseSafe that's a bounds-check panic; in **ReleaseFast, what this project
  ships, bounds checks are stripped — silent memory corruption**, not a crash.
- `docs/rendering-assets-shaders.md` and the archive Slice 36 section said
  `Renderer.k_max_dense_composite_draws = 8` — stale even before this slice
  (today's crash-safety fix already raised it to 32 to match the submit-stack
  cap); corrected alongside the real ceiling raise.
- `game_demo_state.zig`'s `procedural_max_dense_tile_gpu_bytes` computes its
  budget ceiling from the exact same formula `estimateDenseTileGpuBytes`
  checks it against, so `validateDenseRenderBudget`'s GPU-byte gate can never
  actually fail for that world. The mechanism itself
  (`WorldBuildConfig.max_dense_tile_gpu_bytes` + `validateDenseRenderBudget`)
  is otherwise correct and already tested — only this one caller defeats it.

Current foundation (landed, do not rebuild):

- Slice 36's single-pass compositing (`partitionDenseCompositeBuckets`,
  `buildWindowLayers`, `TilemapWindowLayers`, the per-pixel shader walk)
  already makes draw-call count track interleave points rather than window
  depth — this slice only widens the fixed capacity those mechanisms operate
  within, it does not change how they work.
- `WorldBuildConfig.max_dense_tile_gpu_bytes` / `validateDenseRenderBudget`
  (`world_system.zig`) is a real, independently-settable, already-tested
  budget gate — do not redesign it, just stop one caller from defeating it.
  Choosing the actual byte ceiling is deferred to a future release-sizing
  pass with a runtime RAM/VRAM check gating world/chunk size — out of scope
  here.

Architecture notes:

- Raise `k_max_dense_submit_stack_cap` and the two renderer constants
  comptime-tied to it from 32 to 128 together. 128 gives headroom for roughly
  double today's demo level count, or a symmetric ~30-level-above/~30-level-below
  world at 2 dense bands/level (Slice 38's shape) — a concrete target, not an
  arbitrary doubling. If a future world's real need
  (`(levels_above + levels_below + 1) * max_dense_bands_per_level`) exceeds
  128, that is the signal to design a dynamic/runtime-sized compositing
  window instead of bumping this constant again — not a decision to make
  preemptively now.
- Move `k_max_tilemap_window_layers` ownership (and `TilemapParams.layer_offsets`'s
  array size) into `sprite_batch.zig`, defined directly off the shared
  constant instead of a hardcoded literal, so the Zig-side half of the gap is
  structurally closed rather than merely asserted against. `Renderer`
  re-exports the constant so `world_system.zig`'s existing cross-module
  comptime asserts keep compiling unchanged.
- GLSL cannot read a Zig constant, so the shader-side literal needs its own
  enforcement: add a headless `zig build test` test (co-located with
  `sprite_batch.zig`'s existing `TilemapParams` layout tests) that
  `@embedFile`s `tilemap.frag.glsl`, parses its `layer_offsets[N]`
  declaration, and asserts `N == k_max_tilemap_window_layers / 4`. This turns
  a doc-comment convention into a CI-enforced contract; document the exact
  literal pattern the test expects so an unrelated shader edit doesn't break
  it confusingly.
- Fix `game_demo_state.zig`'s self-referential GPU-byte budget by removing the
  computed-from-the-same-count ceiling, leaving `max_dense_tile_gpu_bytes` at
  the `WorldBuildConfig` default (`0`, gate disabled) with a comment noting
  this is intentionally unset pending a future release-time hardware-based
  ceiling — not replacing one guessed number with another.
- No gameplay, dig, or nav contract changes in this slice — capacity and
  correctness-of-synchronization only.

Checklist:

- [ ] Raise `k_max_dense_submit_stack_cap` (`world_system.zig`),
      `Renderer.k_max_tilemap_window_layers`, and
      `Renderer.k_max_dense_composite_draws` from 32 to 128 together; confirm
      the existing cross-module comptime asserts still tie them.
- [ ] Move `k_max_tilemap_window_layers` and `TilemapParams.layer_offsets`'s
      array-size ownership into `sprite_batch.zig`, defined off the shared
      constant; `Renderer` re-exports it.
- [ ] Update `assets/shaders/tilemap.frag.glsl`'s `uvec4 layer_offsets[8]` to
      `[32]` (128/4) and recompile shaders (`zig build shaders`).
- [ ] Add an `@embedFile`-based headless test asserting the GLSL
      `layer_offsets[N]` literal matches `k_max_tilemap_window_layers / 4`;
      cross-reference the test by name in both the Zig doc comment and the
      GLSL comment so neither side can drift silently again.
- [ ] Remove `game_demo_state.zig`'s self-referential
      `procedural_max_dense_tile_gpu_bytes` computation; leave the budget gate
      at its default disabled state with a comment pointing at the deferred
      release-sizing/RAM-check work.
- [x] Correct the stale `Renderer.k_max_dense_composite_draws = 8` references
      in `docs/rendering-assets-shaders.md` and the archive Slice 36 section
      to the current/raised value.

Acceptance checks:

- [ ] `zig build verify` passes (check + test + shader compile + atlas lint)
      with the raised constants and the new GLSL array size together.
- [ ] The new GLSL-sync test fails if either the Zig constant or the shader
      literal changes without the other (spot-checked by temporarily editing
      one in a scratch branch, not shipped).
- [ ] `partitionDenseCompositeBuckets`'s existing worst-case test (proving no
      fold/error at the cap) passes at the new 128 cap.
- [ ] `validateDenseRenderBudget`'s existing GPU-byte-budget test still
      passes, and the demo world no longer computes a self-defeating ceiling
      (confirm by inspection: `procedural_max_dense_tile_gpu_bytes` is gone or
      explicitly `0`).

## Slice 38: Elevation Above The Surface

Goal: let a world represent levels above the surface (not just underground
depth below it) as an explicit, stable per-level fact, and generalize the
dense render window to a symmetric above/below policy — so elevation, not
append order or storage index, determines what "surface" means.

Depends on: Slice 37 (raised render-window ceiling; a world with levels both
above and below the surface needs headroom in the same cap Slice 37 raises).

Problem (current envelope):

- `WorldSystem.level_base_z` / `world_level: u16` is a plain 0-based,
  append-order storage index everywhere (`NavGraph.levels`, `LevelLink`,
  `CellCoord`, `DataSystem.world_level`) — none of that needs to change, since
  it's always treated as an opaque stable index, never a signed or centered
  value.
- But "level 0 is the surface" is not just a storage convention — three
  gameplay call sites bake in "index 0 == surface" directly: `dig_controller.zig`'s
  hole-vs-tunnel dig branch, its `setEntityLevel` open-surface snap exemption,
  and `simulation_pipeline.zig`'s `gateBodyToWalkableTiles` surface
  pass-through. If a level could exist above index 0 without a corresponding
  semantic fix, it would silently inherit the surface's
  no-collision/no-snap/hole-not-tunnel treatment.
- `DenseLayerRenderWindow.ceiling_when_underground` is the only existing
  "look upward" mechanic, and it's a narrow, explicitly-documented special
  case (exactly one level above the active level, whole-layer-only —
  "cannot do per-cell shaft cull") — not a pattern to generalize from.

Current foundation (landed, do not rebuild):

- Slice 37's raised `k_max_dense_submit_stack_cap` /
  `k_max_tilemap_window_layers` / `k_max_dense_composite_draws` (128) and
  closed shader/host sync gap — this slice needs that headroom and that
  safety net, not a redesign of the compositing mechanism itself.
- `worldZForLevel` already saturates Z to the `i32` range via `i64` math — no
  overflow risk from added elevated levels.
- `addUndergroundLevelStack` / `addLevel` (`world_system.zig`) already
  correctly append levels with negative Z going deeper; this slice adds a
  parallel "above" path, it does not change the existing one.

Architecture notes:

- Add an explicit `level_elevation: std.ArrayList(i32)` column to
  `WorldSystem`, always the same length as `level_base_z` (enforced at the
  single `appendLevelBaseZ` choke point, not by caller convention) — not a
  signed storage index, and not derived from `base_z` or append order.
  `base_z` stays a free-form, caller-supplied render/Z-sort value (existing
  tests already pass arbitrary non-multiple values); coupling elevation to it
  or to build order would make elevation an implicit fact with no compiler or
  runtime signal if a future change reordered level construction — exactly
  the kind of derived-not-stored fact this project's stable-ID discipline
  avoids elsewhere (`LevelLink` / `CellCoord`).
- `addLevel`'s existing signature is unchanged (defaults `elevation = 0`
  internally) so none of its ~30 existing call sites need to change;
  `addUndergroundLevelStack` passes the real negative tier it already
  computes the sign for. New `addElevatedLevelStack` mirrors
  `addUndergroundLevelStack`'s shape for positive elevation — scoped as
  allocation/indexing only in this slice (no default fill tile the way
  underground gets solid dirt; there's no universal "what's above the world"
  content yet, so leave dense-floor authoring for elevated levels to the
  caller via the existing `addDenseLayer`).
- New `pub fn levelElevation(self, level_index: u16) i32` — O(1) lookup, `0`
  at the surface, positive above, negative below.
- `DenseLayerRenderWindow.ceiling_when_underground: bool` is replaced by
  `levels_above: u16 = 0` (default preserves today's behavior byte-for-byte —
  today's default never looks above the active level either way).
  `levelInWindow` is rewritten in elevation-relative terms
  (`world_elevation <= active_elevation` → within `levels_below`; else within
  `levels_above`) instead of raw-index arithmetic, removing the narrow
  "only when underground" conditional entirely.
- Migrate the three gameplay call sites off `level == 0`: `dig_controller.zig`'s
  hole-vs-tunnel branch and `setEntityLevel`'s surface exemption become
  `world.levelElevation(level) == 0`. `simulation_pipeline.zig`'s
  `gateBodyToWalkableTiles` surface pass-through becomes the same check.
  **`digRamp`'s "no-op on the surface, nothing above" check needs new logic,
  not a rename** — once index 0 has no privileged geometric meaning, "is
  there a level above this one" must become an elevation-adjacency lookup (a
  level whose elevation is this level's elevation + 1), not an index
  comparison. Do not treat this as mechanical find-replace.
- Explicitly out of scope for this slice (deferred, not silently dropped):
  actual elevated-world demo content/tile authoring (fill tiles, ramps up
  into an elevated stack, any new dig/build tool targeting elevation), and
  the release-time RAM/VRAM-based GPU memory ceiling (Slice 37 already leaves
  that hook in place, unset).

Checklist:

- [ ] Add `WorldSystem.level_elevation` column, populated at the single
      `appendLevelBaseZ` choke point so it can never drift out of
      length-sync with `level_base_z`.
- [ ] Add `levelElevation()` accessor; update `addUndergroundLevelStack` to
      pass real negative elevation.
- [ ] Add `addElevatedLevelStack` (allocation/indexing only, mirroring
      `addUndergroundLevelStack`'s shape) for positive-elevation levels.
- [ ] Replace `DenseLayerRenderWindow.ceiling_when_underground` with
      `levels_above: u16 = 0`; rewrite `levelInWindow` / `maxLevelSpan` in
      elevation-relative terms; confirm `levels_above = 0` reproduces today's
      behavior exactly.
- [ ] Migrate `dig_controller.zig`'s two `level == 0` / `current_level == 0`
      call sites and `simulation_pipeline.zig`'s `gateBodyToWalkableTiles` to
      `levelElevation(...) == 0`.
- [ ] Replace `digRamp`'s raw index-0 "nothing above" check with an
      elevation-adjacency lookup (a reachable level at
      `levelElevation(level) + 1`), verified against a real multi-tier
      (elevated + surface + underground) fixture, not just the current
      surface-and-below-only demo world.
- [ ] Update `docs/architecture.md` / `docs/simulation-tiers-and-pipeline.md`
      wherever they describe level 0 as structurally special, to describe
      elevation instead.

Acceptance checks:

- [ ] New tests: `levelElevation` correctness for surface/underground/elevated
      levels; `addElevatedLevelStack` index/elevation bookkeeping (parity with
      existing `addUndergroundLevelStack` tests); symmetric `levelInWindow`
      behavior (above only, below only, both at once).
- [ ] The three migrated gameplay call sites are re-proven against a world
      whose surface is *not* index 0 (i.e., has at least one elevated level
      above it) — this is the case that actually catches a regression back to
      "surface == index 0"; today's demo alone would not.
- [ ] `digRamp`'s elevation-adjacency replacement is verified against a real
      multi-tier fixture (zig-debug-specialist review recommended given this
      is the one non-mechanical change in this slice).
- [ ] `zig build verify` passes.

## Slice 39: Sensory Stimulus Ecosystem

**Status: not started.** Depends on Slice 29's `SimulationFrame.stimuli` /
hearing path; most valuable after Slice 32 so investigate/flee can react to
richer sounds than dig alone.

Goal: expand the world sensory bus so hearing and curiosity are not permanently
tied to a single dig producer — without turning stimuli into a second event
stream or audio-playback service.

### Problem (code today)

- `SimulationFrame.stimuli` is a `RangeOutputStream(WorldStimulus)` with
  scalar fields (position, intensity, kind, level).
- **Sole producer:** `DigController.process` (one stimulus per dig). Landing/
  fall carve deliberately does not emit (ordering vs perception in the same
  step — documented in Slice 29).
- `intensity` is stored but unused (no falloff curve yet).
- No footsteps, combat hits, alarms, or player-jet coupling into cognition —
  investigate utility in Slice 32 only fires when something digs nearby.

### Architecture notes

- Stimuli stay **transient per-step positional records**, not `SimulationEvent`s
  and not `AudioCommandBuffer` entries. Audio may *also* play a sound for the
  same gameplay moment, but cognition must not read the audio service.
- Add producers at explicit pipeline stages that run **before**
  `perception_update` (same rule as dig), or document a one-step delay if a
  producer can only run later — never silently emit after perception.
- Keep `WorldStimulus.kind` a small closed enum; extend with new tags + tests,
  not strings.
- Falloff: hearing already range-gates; optional intensity attenuation
  `effective = intensity / (1 + dist2 * k)` with fixed `k`, only if a second
  producer needs relative loudness. Do not scale constants from world size.
- Capacity: pre-reserve stimulus stream from a caller-sized budget (mirror
  perception event budget discipline) once producers can exceed one item/step.

### Checklist

- [ ] Document producer-phase rule in `docs/simulation-tiers-and-pipeline.md`
      and `architecture.md` (must precede perception or be next-step delayed).
- [ ] Extend `WorldStimulus.kind` with the first real multi-producer set
      (minimum: dig retained, plus at least two of: footstep burst, collision
      impact, tool/use pulse — pick from systems that already have main-thread
      or fixed-step hooks).
- [ ] Wire 2+ producers with tests for range/level gating and multi-stimulus
      nearest selection (perception already has nearest-of-multiple tests —
      extend fixtures).
- [ ] Implement or explicitly defer intensity falloff; if deferred, document
      why intensity remains unused.
- [ ] Reserve stimulus capacity from demo/pipeline config; capacity + drop
      policy tests if overflow is possible.
- [ ] Headless proof: dig-only worlds unchanged; multi-producer frames remain
      allocation-free after warmup; serial == threaded perception.

### Acceptance checks

- [ ] Hearing can acquire non-dig stimuli; Slice 32 investigate agents move
      toward them in fixtures (or 33 demo once archetypes exist).
- [ ] No cognition → audio service dependency; no stimulus pointers/handles.
- [ ] `zig build verify` passes; perception benches do not regress beyond noise
      at equal agent counts when stimulus count stays bounded.

## Slice 40: Action And Interaction Intent Substrate

**Status: not started.** Depends on Slice 32 for a stable locomotion intent
path; do not block 32 on this slice.

Goal: add a **parallel, typed action-intent stream** for non-locomotion
gameplay (attack, interact, use, signal) so emergent systems can express more
than movement without overloading `NavigationIntent` or inventing a string
pub/sub bus.

### Problem

- `SimulationIntent` today is effectively movement-only
  (`simulation.zig`: `union(enum) { movement: MovementIntent }`).
- `NavigationIntent` is the high-level AI → steering handoff for **where to
  go**. Cramming "attack target X" into goal XY or priority bits would lock
  combat into pathfinding and break expandability.
- Architecture already describes domain controllers for combat/rules/spawning
  (`architecture.md`) but no intent substrate exists for their outputs.

### Architecture notes

- New stream on `SimulationFrame`, e.g. `action_intents:
  RangeOutputStream(ActionIntent)`, same count/prefix/write / range merge
  model as navigation intents.
- `ActionIntent` payload: entity, kind enum, optional target `EntityId`,
  optional cell/level scalars, priority, cooldown key — **scalar/enum only**.
- Producers: AI arbitration (later extension), player input controller, future
  combat controller. Consumers: domain controllers at explicit reaction phases
  after merge — not the pathfinder.
- **Do not** require Slice 32 to emit actions. Slice 32 may leave a documented
  extension point (e.g. score term reserved) but shipping attack from 32 is
  out of scope.
- Structural mutations from successful actions still go through deferred
  structural commands / world edits — action intents request consideration,
  they do not mutate `DataSystem` inside worker ranges.

### Checklist

- [ ] Define `ActionIntent` + kind enum + stream on `SimulationFrame`; reserve
      API; stats counters; docs for when to use action vs navigation vs domain
      events.
- [ ] Pipeline phase: declare producer stage(s) and consumer reaction point(s)
      in `stage_order` / contracts without breaking existing stage resources.
- [ ] Player or test harness emits at least one action kind end-to-end
      (e.g. interact-noop or attack-request that a stub consumer counts).
- [ ] Capacity, deterministic merge, serial/threaded parity, payload purity
      tests (no pointers/handles).
- [ ] Document expansion path: AI arbitration may later emit actions when a
      pursue agent is in range — separate checklist item / future slice, not a
      silent partial in 40's "done" claim unless fully tested.

### Acceptance checks

- [ ] Movement-only demos unchanged when no action producers run.
- [ ] Action stream is deterministic and allocation-free after reserve.
- [ ] NavigationIntent contract untouched.
- [ ] `zig build verify` passes.

## Slice 41: World Interest And Affordance Markers

**Status: not started.** Best after Slices 32–33 (agents can investigate) and
usable with 39 (stimuli) without requiring 40.

Goal: give agents durable, world-authored **interest points** (investigate
hooks, cover, resource nodes, patrol anchors) as persistent facts in
`WorldSystem` or compact `DataSystem` markers — so goal selection is not limited
to living entities, dig noise, and the player.

### Problem

- Perception tracks entities + transient stimuli; memory rings remember
  entities. There is no first-class "point of interest" for curiosity,
  garrison, loot, or cover.
- Without this, investigate/pursue content stays combatant-centric and
  demo-shaped.

### Architecture notes

- Prefer **world-owned SoA markers** (stable id, kind enum, level, cell/xy,
  optional faction filter, optional radius) over per-agent heap lists.
- Agents query markers through a bounded spatial structure (reuse chunk
  hashing or a frame-built index — do not N² scan the world on the hot path).
- Slice 32's investigate resolver should be written so a future "best interest
  marker" signal slots in as another score input without rewriting arbitration.
- Rendering of markers is optional/debug; gameplay facts must not require GPU
  handles.

### Checklist

- [ ] Define marker storage + kind enum + add/remove at load or via structural/
      world APIs; tests for level isolation and capacity.
- [ ] Bounded query API for cognition agents (max K markers in radius).
- [ ] Wire investigate (and optionally pursue/flee cover) scoring to consume
      markers when present; fixtures without markers preserve prior behavior.
- [ ] Demo or content path places a few markers; archetypes (33) can bias
      curiosity toward marker kinds.
- [ ] Docs: ownership in WorldSystem vs DataSystem decision recorded in
      architecture.md.

### Acceptance checks

- [ ] Agents investigate markers without entity targets present.
- [ ] Queries bounded and allocation-free after warmup; determinism holds.
- [ ] `zig build verify` passes.

## Slice 42: Affect Expansion — More Feelings, Coupling, And Mood

**Status: not started.** Depends on Slice 32 (drives must already be consumed
via a table so new feelings are additive) and benefits from Slice 33
(archetype keys for new drives). Do **not** block 32–33 on this slice.

Goal: grow the emotion model beyond the four landed drives without forking AI
or inventing a second affective system — add feelings, optional cross-drive
coupling, data-driven appraisal gains, and an optional slow **mood** layer that
biases baselines.

### Why this is separate from 31/32

Slice 31 deliberately shipped a **minimal independent-drive core** that is
correct, SIMD-friendly, and event-capable. Slice 32 must **consume** that core
through a table. This slice is the planned expansion valve so designers can add
loyalty, morale, pain, joy, etc. later without a rewrite — and so 32 is not
pressured into half-shipping coupling.

### Current foundation

- Four drives, named SoA fields, `above_threshold_mask: u8` (8-drive bit
  headroom), module-level appraisal gains in `affect.zig`, no cross-drive terms.
- Track overview **"How to add a new feeling"** checklist.
- Slice 32 drive×behavior weight table (required prerequisite pattern).

### Architecture notes

**New drives (feelings):**

- Append-only `AiAffectDrive` tags. Prefer gameplay-proven candidates when
  first expanding (examples, not mandates): `pain` / `hurt` (from damage
  events — needs Slice 40 or combat signals), `morale` / `loyalty` (faction +
  ally density), `joy` / `contentment` (low threat + high familiarity). Only
  land drives with a real appraisal signal and a table row — no placeholder
  tags in production enums.
- Mechanical work: store columns, validation, AffectSystem pass, archetype
  schema, debug bar, arbitration table row (see track overview steps 1–6).
- At **>8 drives**: widen mask; strongly consider refactoring hot values to a
  dense `[drive_count]f32` (and parallel cold arrays) so gather/SIMD stays
  uniform — do this as an explicit sub-checklist item, not a silent reshape.

**Appraisal gains become data:**

- Move `gain_fear` / `gain_aggression` / … from module constants to per-entity
  cold fields (or archetype-only defaults stamped at spawn). Caps + validation
  like other affect cold fields.
- Lets timid vs bold agents *feel* the same threat differently, not only decay
  to different baselines.

**Cross-drive coupling (optional, bounded):**

- After independent deltas, apply a small fixed coupling matrix
  `delta'[d] += sum_e(delta[e] * c[e][d])` with sparse authored coefficients
  (most zeros). Example: high fear slightly suppresses curiosity that step.
- Keep coupling **post-appraisal, pre-clamp**, allocation-free, deterministic.
- Do not introduce recursive multi-pass coupling storms; one multiply-add pass
  only.

**Optional mood layer (longer horizon):**

- Slow-moving scalars (e.g. one `mood_valence` or per-drive mood bias) updated
  at a lower cadence or with much smaller rates, biasing baselines or score
  offsets — **not** a replacement for drives.
- Must freeze with cognition demotion the same way memory does (no background
  work out of scope).
- Skip entirely if product does not need multi-minute emotional weather yet;
  document as optional checklist block.

**Explicit non-goals:**

- Full psychological simulation, Plutchik graphs as runtime structures, string
  emotion names on the hot path, or per-entity heap emotion stacks.
- Replacing Slice 32's table with an FSM of named moods.

### Checklist

- [ ] Document the drive-addition runbook in `docs/architecture.md` (link the
      track overview steps); keep code and docs aligned.
- [ ] Promote appraisal gains to per-entity cold fields; migrate module
      constants to defaults; archetype JSON (33) gains keys; validation + tests.
- [ ] Land at least one **new drive** end-to-end only when a real signal exists
      (or defer the first new tag until combat/stimuli provide one — do not ship
      a dead drive). If deferred, leave checklist item open with reason.
- [ ] Optional: sparse cross-drive coupling matrix + tests (fear dampens
      curiosity; aggression slightly raises fatigue, etc.).
- [ ] Optional: mood / long-horizon bias layer with scope freeze semantics.
- [ ] If drive_count > 8: widen `above_threshold_mask` and evaluate dense
      drive-indexed column packing; bench affect at 10k agents before/after.
- [ ] Extend arbitration weight table + debug overlay for every new drive in
      the same PR as the drive itself (no orphan columns).
- [ ] `FailingAllocator` steady-state proof still holds on AffectSystem + AI
      consume path; serial == threaded; SIMD parity where vectorized.

### Acceptance checks

- [ ] Existing four drives unchanged in default configs (behavior parity
      fixtures from Slice 32 still pass with coupling disabled / zero matrix).
- [ ] New drive (when landed) appraises, decays, emits threshold edges, appears
      in archetype/debug, and modulates arbitration through the **same table
      path** as fear/curiosity/aggression/fatigue.
- [ ] No second emotion subsystem; no hot-path strings; `zig build verify`
      passes; `zig build bench -- --group ai-affect` shows no unexpected
      multi-x regression at equal agent counts.

## Slice 43: SDL3 Gamepad/Controller Support

**Status: landed (runtime behavior + tests + docs), manual hardware
verification pending.** This is app/input-layer work, independent of the
AI-track slices (33/35/37–42) — no ordering dependency either way.

Goal: single active-device gamepad support that mirrors the existing
keyboard `Action` model 1:1 with default button bindings, adds true analog
left-stick movement (deadzone + normalized magnitude, not digital d-pad
synthesis), and hot-plug add/remove handling with a clean fallback to
keyboard — no rebind UI (defaults only, a later slice).

### Current foundation

- `src/app/input.zig`'s device-agnostic `Action` enum, `KeyBinding`/
  `default_key_bindings`, `InputState` (held actions + `movementVector`),
  `FrameCommands` (one-frame latched commands), and the private
  `isGameplayAction`/`isCommandAction` classifiers already existed and needed
  no reshaping — only extension.
- `src/app/input_router.zig`'s `InputRoutingPolicy` (gameplay/modalUi/
  passThroughOverlay/opaqueScreen) and `routeEvent` already gated keyboard
  events through per-state action contexts.
- `src/platform/sdl.zig`'s `@cImport` already exposed the full SDL3 gamepad
  API; `init_flag_names` already listed gamepad/joystick flag names for
  debug logging.

### Architecture notes

- New `src/app/gamepad.zig`: `GamepadManager` owns at most one open
  `*SDL_Gamepad` + its `SDL_JoystickID`. Pure decision logic
  (`shouldAdopt`/`isActiveDevice`/`pickFallback`) is unit-tested against
  synthetic `SDL_JoystickID` values; `SDL_OpenGamepad`/`SDL_GetGamepads`/
  `SDL_CloseGamepad` glue is thin and untested (no real/virtual hardware in
  CI, same posture as the display-gated `gpu-smoke` probe).
  `handleDeviceEvent` reacts to `SDL_EVENT_GAMEPAD_ADDED`/`_REMOVED`,
  returning `enum { none, connected, disconnected }`.
- `src/app/input.zig` gained `GamepadButtonBinding`/`default_gamepad_bindings`,
  `actionForGamepadButton`, and `actionForPressEvent` (resolves a fresh
  key-down or gamepad-button-down event to an `Action` in one call — used by
  menu states). `InputState` gained `gamepad_stick_x_raw`/`gamepad_stick_y_raw`,
  `handleGamepadAxis`, and a scaled-radial-deadzone `movementVector` that adds
  the normalized stick vector to the keyboard digital direction and clamps
  each axis independently to `[-1, 1]` (deliberately not clamping combined
  length, to avoid changing keyboard-only sqrt(2) diagonal feel).
  `releaseMovement` now also zeroes the raw stick fields; a new
  `releaseGamepadInput` additionally clears held dig actions for the
  disconnect path. `FrameCommands` gained a public `press` setter mirroring
  `InputState.setHeld`.
- `src/app/input_router.zig` factored a shared `routeAction` helper (policy
  gate + held-vs-one-frame classification) reused by keyboard key events and
  new `SDL_EVENT_GAMEPAD_BUTTON_DOWN`/`_UP` cases (gamepad buttons never
  repeat). A new `SDL_EVENT_GAMEPAD_AXIS_MOTION` case, gated by
  `policy.allowsContext(.gameplay)`, forwards only
  `SDL_GAMEPAD_AXIS_LEFTX`/`_LEFTY` to `InputState.handleGamepadAxis`.
- `src/game/main_menu_state.zig` and `src/game/settings_menu_state.zig` swapped
  their raw `SDL_EVENT_KEY_DOWN` + `actionForKey` checks for the single
  `inputFile.actionForPressEvent(event) orelse return false` call, so D-pad
  nav / South confirm / East cancel work with no per-state gamepad branching.
- `src/app/engine.zig`: `sdl_flags` now includes `SDL_INIT_GAMEPAD`; `Engine`
  gained a `gamepad: GamepadManager` field, initialized via `openInitial()`
  right after `sdl_context` and torn down in `deinit()` before
  `sdl_context.deinit()`; `handleEvents` reacts to
  `SDL_EVENT_GAMEPAD_ADDED`/`_REMOVED` and calls
  `self.input.releaseGamepadInput()` on a `.disconnected` result.
- No changes were needed in `src/game/player.zig`, `src/game/audio_controller.zig`,
  or `src/app/pause_controller.zig` — all three already consumed
  `movementVector()`/`releaseMovement()` through the existing device-agnostic
  contract.
- SDL3 header ground truth used during implementation: `SDL_GamepadButtonEvent.button`
  and `SDL_GamepadAxisEvent.axis` are raw `Uint8` fields (translated to Zig
  `u8`); `SDL_GamepadButton`/`SDL_GamepadAxis` themselves translate to plain
  `c_int` (not a genuine Zig `enum`) because `SDL_GAMEPAD_BUTTON_INVALID`/
  `SDL_GAMEPAD_AXIS_INVALID` are `-1`, so translate-c falls back to an integer
  alias with comptime constants. The correct cast at every call/construction
  site is therefore a plain `@intCast` between the `u8` event field and the
  `c_int` binding/comparison type — never `@enumFromInt`.

### Checklist

- [x] `src/app/gamepad.zig` (new): `GamepadManager` device lifecycle + pure-function
      unit tests; registered in `src/tests.zig`.
- [x] `src/app/input.zig`: gamepad button binding table, `actionForGamepadButton`,
      `actionForPressEvent`, analog stick fields/deadzone/`handleGamepadAxis`,
      `movementVector` rewrite, `releaseMovement` extension, `releaseGamepadInput`,
      `FrameCommands.press`; tests for every binding, event shape, deadzone case,
      and combination case.
- [x] `src/app/input_router.zig`: shared `routeAction`, gamepad button/axis
      routing cases; tests mirroring keyboard across all four
      `InputRoutingPolicy` presets, plus axis gating/no-op tests.
- [x] `src/game/main_menu_state.zig` / `src/game/settings_menu_state.zig`:
      swapped to `actionForPressEvent`; extended existing named-action tests
      with an equivalent gamepad-driven pass.
- [x] `src/app/engine.zig`: `SDL_INIT_GAMEPAD` flag, `GamepadManager` field +
      init/deinit wiring, device-add/remove handling in `handleEvents`.
- [x] Docs updated: this section, `docs/state-stack-and-input.md` `## Gamepad`
      section (binding table, deadzone/analog contract, hot-plug behavior),
      `docs/architecture.md` ownership bullets and input-flow sentence.

### Acceptance checks

- [x] `zig build verify` (check + test + shader compile + atlas lint) passes.
- [x] All tests listed in the Checklist above are present and passing under
      `zig build test`.
- [x] Docs updated as listed above.
- [ ] Manual hardware verification (no headless virtual-gamepad harness exists
      in this repo, so this is a follow-up outside the automated gate):
      connect a real controller and confirm (a) an already-connected
      controller is picked up automatically at startup, (b) movement feels
      analog through the full deflection range, (c) every binding in the
      table above matches actual button presses, (d) mid-game unplug releases
      held movement/dig state cleanly and falls back to keyboard with no stuck
      input, (e) plugging in a second controller while one is active does not
      steal input from the first.

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
32. AI behavior arbitration (**consume emotion drives**). **← next**
33. Data-driven AI archetypes and debug introspection (incl. affect blocks).
39. Sensory stimulus ecosystem (richer hearing/investigate inputs).
41. World interest / affordance markers (multi-source goals).
40. Action and interaction intent substrate (non-locomotion emergence).
42. Affect expansion (more feelings, coupling, appraisal gains, optional mood).
35. AI and steering hot-loop SIMD restructure (after 32 reshapes AI loops).
36. Single-pass dense-layer depth compositing.
37. Dense render-window ceiling raise + shader/host sync hardening.
38. Elevation above the surface.

Dependency index for slice ordering. **Open Frontier Slice Index** is the entry
point; each slice's **Checklist** and **Acceptance checks** are what agents
complete. **Scaling Gaps** is backlog until copied into a slice section.
