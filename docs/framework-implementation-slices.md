# Framework Implementation Slices

This roadmap is the agent implementation contract for the project frontier. Work
is organized as **numbered slices**: each slice is one complete, verifiable
feature chunk with a **Goal**, **Checklist**, and **Acceptance checks**. Agents
implement by opening a slice section, checking items off only when integrated,
and running `zig build verify` before marking the slice complete.

Settled slices (0–8, 9–17, 18–25E, 26–32, 34, 36, 39–41, 45) live in
[framework-implementation-slices-archive.md](framework-implementation-slices-archive.md).
This file is the **open frontier**: agent workflow, priorities, Scaling Gaps,
track overviews, and open slice sections only. Landed slices that still need
manual/`gpu-smoke` confirmation (33, 43) stay here until that residual is closed.

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
| **33** | Landed (visual/GPU-smoke verification pending) | Data-driven AI archetypes (JSON→enum bundle table) + debug introspection overlay — implemented and unit-tested; on-screen viz (F2) confirmed only via `gpu-smoke`/manual run |
| **35** | Not started | AI/steering hot-loop SIMD restructure — unblocked (Slice 32 landed); measure at battle scale |
| **37** | Partial | Dense render-window ceiling raise (32→128) + shader/host layer-count sync hardening — stale-doc checklist item landed; rest open |
| **38** | Not started | Elevation above the surface (depends on Slice 37) |
| **42** | Not started | Affect expansion — more emotion drives, coupling, appraisal gains, optional mood (needs real appraisal signals) |
| **43** | Landed (manual HW verification pending) | SDL3 gamepad/controller support — single active device, analog movement, default button bindings (app/input layer; independent of AI/render tracks) |
| **44** | Not started | Input rebinding UI + extended gamepad controls (right stick / triggers) — completes controls deferred by Slice 43 |
| **46** | Not started | Save/load persistence — serialize `DataSystem`/`WorldSystem` by stable IDs; completes archive Slice 10's designed boundary |
| **47** | Not started | **Live perception defect:** un-stagger the shared spatial index / perception candidate set so cognition NPCs can perceive each other (stagger gates thinking only). **Highest-priority correctness item on the AI track** |
| **48** | Not started | SimulationPipeline thin-composer restoration — bind `stage_order` to execution, extract `SensoryBus`, evict movement/world domain logic, own event/allocation budgets. Land as independent steps |

**Recently settled (archive only):** 45, 40, 39, 41, 32, 8, 18–25E, 26–31, 34, 36 (plus 0–7, 9–17).
**Residual non-slice backlog:** optional render micro-opts (e.g. an O(n) linear
`mergeDrawList`) — see **Scaling Gaps**, not a live slice body. (The 23A
`expand2`→`world` merge is settled: `expand2`/`world` are merged into `main`.)

**Bench policy:** 50k bench scales are throughput ceilings, not per-frame targets.

## Next Priority Tracks

Sequencing hints only — **does not replace slice Checklists**. When in doubt,
follow **Suggested Order** and the open items in the target slice section.

**Locomotion emergence is closed** (archive 26–32, 39, 41; frontier residual 33
visual only). Multi-source investigate (stimuli + world markers + memory) and
table-driven affect→behavior are in place. Open work grows *beside* that loop.

| Track | Slices | Notes |
| --- | --- | --- |
| **Primary — action/interaction** | archive **40** + **45** | Action-intent substrate + first domain controller (destructibles) landed; future combat/rules consumers reuse the same bus. |
| **Feelings growth** | **42** | More drives / coupling / gains only when a real appraisal signal exists (often from 40/45 combat or other producers) — no dead enum tags. |
| **World / render verticality** | **37 → 38** | Cap raise + shader sync, then elevation-above-surface semantics. Independent of AI. |
| **Input polish** | **44** (after 43 residual) | Rebind UI + right stick/triggers; binding persistence optional in **46**. |
| **Perf** | **35** + Scaling Gaps | SIMD restructure of existing AI/steering loops when battle soak says math dominates — do not reshape arbitration contracts. |
| **Persistence** | **46** | Save/load by stable IDs; largely independent. |

- **Slice 32 contract (standing rule):** `scoreBehaviors` / `selectSticky` /
  `resolveGoal` stay the expandable path. Emotion → behavior is **table-driven
  over `AiAffectDrive`**, not a permanent `if (fear) flee` tree. Goals stay
  per-agent and multi-source (not broadcast player-only). Utility + sticky
  select over exclusive FSMs. No test-only production API tags.
- **Component headroom:** 14 of 32 `Component` tags used (`enum(u5)` +
  `ComponentMask = u32`). Slice 45 added `destructible`. Slice 41 used
  `WorldSystem` interest markers, not a new tag — see Scaling Gaps.
- Guard CPU paths with existing benches; keep SDL_GPU submit on the render
  thread. Reuse state-owned `SimulationPipeline`; persistent data in
  `DataSystem`; structural changes through `SimulationFrame`.

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

- [ ] **Interest marker consumers beyond investigate.** Slice 41 stores
      `cover` / `resource` / `patrol` kinds and nearest-k query, but only
      `investigate` is wired into AI. Promote when ready: cover-aware flee/pursue
      (locomotion AI follow-up), resource/patrol action targets via Slice 40/45
      action intents — do not half-wire into `NavigationIntent`.
- [ ] **Movement contiguous-path vs scoped LOD.** Any dormant movement row
      disables the contiguous SIMD movement fast path for the whole step. At
      steady-state LOD with routine off-camera sleepers, revisit compacted-dense
      movement iteration or a dormant-fraction threshold (Slice 24 follow-up).
- [x] **Per-entity depth axis.** Landed in archive Slice 25E (`world_level` /
      scope level / render cull alignment). Residual multi-floor chase policy
      is product work on open slices, not a missing column.
- [ ] **Component storage headroom.** `Component` is `enum(u5)` (32 tags) and
      `ComponentMask` is `u32` — **14 tags used** (`movement_body`…`destructible`).
      Slice 45 added `destructible`; Slice 41 stored interest markers on
      `WorldSystem`, not a new tag. Promote a widening slice only when the
      first new tag would exceed 32.
- [ ] **Multi-world scope policy.** Inactive world instances stay out of
      pipeline scope; the active world uses chunk + halo rules (Slice 22
      deferred).

**Battle-scale perf watch (2048 movers)**

**How to use:** fix cycles in **Debug**; intentional soaks in **ReleaseSafe**
(`zig build run -Doptimize=ReleaseSafe`), **one** 60s dump after load (not
multi-minute dual cycles unless comparing load vs settle). Same pop
(`battle_scale_demo_mover_count = 2048`), similar play. Diff new dumps against
the control table below: if stage lines move while selected/observer counts
stay similar → suspect **net-new code**; if selected/observers jump → **scope
density of the feature**. Sub-stage lines `steering_setup` / `collision_setup`
separate setup from batch. Do not min-max sub-ms when gameplay stays in band.

**ReleaseSafe control baseline (post-load, ~60s, 2048 movers)**

| Metric | Control band |
|--------|----------------|
| gameplay avg | **1.6–1.9 ms** |
| frame (present-bound) | **~8.3 ms** (~120 FPS); cap_hits **0–1** |
| steering stage | **~0.65–0.70 ms** |
| steering select / snapshot / directions | **~0.03 / ~0.33–0.34 / ~0.17–0.20 ms** |
| steering batch | **~0.40 ms** |
| collision stage | **~0.21 ms** |
| collision gather / sort | **~0.09 / ~0.02 ms** |
| AI stage | **~0.15–0.20 ms** |
| perception stage | **~0.16–0.20 ms** |
| pathfinding avg (steady; ignore load max) | **~0.05–0.06 ms** |
| cognition selected / observers (per step) | **~330 / ~140** |
| movers (per step) | **~2000–2050** |

Known costs inside that band (document, don’t thrash unless denser cognition
forces a move): full agent snapshot every cognition step (~0.33 ms Safe);
avoidance batch (~0.40 ms → Slice 35); collision gather (~0.09 ms Safe).

- [x] **Steering main-thread setup + event-driven caches.** Instrumented
      select / snapshot / directions; select one-slot resolve; path start from
      `scope.level[mi]`; **steering→movement dense index cache** (rebuild only
      on structural create/destroy/steering|movement component change); agent
      cell bins via dense SIMD assign + pdqsort; static obstacle spatial
      retained until post-commit invalidation or cell-size change. Remaining:
      Slice 35 avoidance SIMD when batch math dominates (`steering.zig`).
- [ ] **Collision full-sort under melee density.** Mid-pack soaks saw
      `full_sorts` jump (e.g. 1→24) while stage avg stayed ~0.21ms; broadphase
      batch ~0.09ms. Use `collision_setup` gather/sort timings +
      `full_sort_disorder_percent` (default 12%) to decide if full sort is
      expected melee disorder or a retune. Do not change SAP order without
      measured parity. (`collision.zig`)
- [ ] **AI separation density.** Sep samples ~2–3× when running through the
      pack; scales with denser cognition. Confirm gather vs sep batch owner via
      existing ai_separation batch line; vectorize with Slice 35 when math
      dominates. Keep candidate/sample caps fixed (world-size independent).
      (`ai.zig`, Slice 35)
- [ ] **Path group fields + cache pressure.** `group_built=0` at 2048 is
      intentional: demo pins `min_group_field_agents = 2000` after measuring
      that pending-dedup/cache already serves shared-goal bursts (see
      `proceduralPathfindingCapacity`). Re-measure eviction rate (~20k/min)
      and group payoff only when simultaneous same-goal demand from
      relationships/ships exists — do not lower the pin without a fresh 60s
      capture. (`game_demo_state.zig`, pathfinding capacity)
- [ ] **Perception tail.** Stage avg ~0.16ms, max ~2.4ms. Only if denser
      observers fill the tail; gather multi-lookup polish optional; FOV path
      already partially SIMD. (`perception.zig`)

**Branch / packaging residuals**

- [x] **Slice 23A merge — settled.** GPU tilemap hardening (archive Slice 23A)
      is merged into `main` (`expand2`/`world` are ancestors of HEAD). The only
      remaining item is the optional O(n) linear `mergeDrawList` micro-opt below,
      to do after measuring — not a merge task.

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
- Slice 32 (arbitration + per-agent goals) and multi-source investigate inputs
  (39, 41) are landed; Slice 33 authoring is landed (close the visual residual
  before shipping heavily data-tuned demo personalities as a product claim).
- Do not scale cognition population (archetype swarm stress) until arbitration
  is gated by the existing cognition-scope dense indices and benches report
  intent-selection cost separately from pathfinding.
- Keep locomotion emergence (32–33 + 39 + 41) independent of action/combat
  emergence (40+): `NavigationIntent` stays stable while action intents grow
  beside it, not inside it. Reserved interest kinds (`cover` / `resource` /
  `patrol`) must not be half-wired into investigate scoring.

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
  reads perception threats, memory last-known/ring contacts, multi-producer
  stimuli (Slice 39), and world interest markers (Slice 41; investigate wired;
  cover/resource/patrol reserved).
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

## Emergent AI Track Overview (Slices 26–33, +39–42, +45)

Goal: layer emergent NPC behavior — perception, memory, **feelings/emotions**,
and richer behavior arbitration — on top of the navigation substrate, while
staying allocation-free on hot paths, deterministic (serial == threaded, scalar
== SIMD), and affordable at scale by running only under the cognition tier gated
by Slice 24.

**Track status (code-authoritative):**

| Layer | Slice | Status | What it produces |
| --- | --- | --- | --- |
| Faction / RNG / spatial index | 26–28 | Landed (archive) | Stance table, deterministic draws, shared neighbor index |
| Perception | 29 | Landed (archive) | Vision/hearing columns + acquire/lose events |
| Memory | 30 | Landed (archive) | Last-known + ring + familiarity; cold-seek retarget in AI |
| **Emotion / affect** | **31** | **Landed (archive)** | **fear / curiosity / aggression / fatigue** SoA drives; **consumed by arbitration (32)** |
| **Arbitration** | **32** | **Landed (archive)** | Utility over 29–31 → per-agent `NavigationIntent`, table-driven drive consumption, sticky selection |
| Archetypes / debug | 33 | Landed (visual residual on frontier) | JSON personalities + overlay (drive bars / affect blocks) |
| Stimulus ecosystem | 39 | Landed (archive) | Multi-producer bus (dig, footstep, deferred impact) |
| World interest | 41 | Landed (archive) | Durable investigate/cover/resource/patrol markers; investigate wired |
| Action intents | 40 | Landed (archive) | Non-locomotion intent stream (attack/interact/use); player R capture |
| First action consumer | 45 | Landed (archive) | `DestructibleController` at `action_react`; deferred destroy + domain event |
| Sensing substrate fix | 47 | **Open (live defect)** | Un-stagger the shared spatial index / perception candidates so cognition NPCs perceive each other; stagger gates thinking only |
| **Affect expansion** | **42** | **Open** | More drives, cross-drive coupling, data-driven appraisal gains, optional mood |

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

**Closed-loop status: locomotion emergence landed.** Pipeline order
`perception → ai_memory → affect → ai_decide → steering → pathfinding`
(`simulation_pipeline.zig` `stage_order`) is unchanged — no new `StageId` was
added for arbitration. `AiSystem`'s `ai_decide` scores `AiBehavior`'s five
variants (`wander`/`pursue`/`flee`/`investigate`/`cohere`) via
`arbitration.scoreBehaviors`'s table-driven drive×behavior weight matrix,
sticky-selects one via `arbitration.selectSticky`, and resolves a per-agent
goal via `arbitration.resolveGoal` — pursue/flee prefer perception's
faction-generic `nearest_threat` or fresh `AiMemory` over the opt-in,
gain-gated `AiConfig.focus_target`/`focus_entity` player fallback; investigate
prefers heard stimuli, then world interest markers (41), then memory-ring
contacts; cohere reads the shared spatial index for a friendly-neighbor mean.
Demo spawns resolve named archetypes from `assets/ai/archetypes.json` (33).
See the archive for full Slice 32 / 39 / 41 records.

**Landed loop inputs (do not rebuild):** multi-producer stimuli (39: dig /
footstep / deferred impact) and world interest markers (41: investigate wired;
`cover` / `resource` / `patrol` reserved for later consumers).

**Sequencing rationale (what remains open on this track):**

- Slices 26–28 — framework foundations (landed).
- Slices 29–31 — composing signal stack (landed).
- **Slice 32** — behavior arbitration (landed).
- **Slice 33** — authoring/tuning infrastructure (landed; visual/`gpu-smoke`
  residual only).
- **Slices 39, 41** — richer senses + world-authored investigate POIs (landed).
- **Open post-loop expandability:** **45** (first action consumer; **next**),
  **42** (more/coupled feelings). Action intents (**40**) are landed. Each is
  a full slice — do not half-wire into 32 or overload `NavigationIntent`.

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

**Status: landed (on-screen visual/`gpu-smoke` verification pending).** Archetype
catalog (`src/game/ai_archetypes.zig` + `assets/ai/archetypes.json`) loads at
init through `UpdateContext.asset_store`, spawns replace the deleted
`demoArchetypeForIndex` literals with byte-identical parity, and the AI
introspection overlay (`src/game/ai_debug_overlay.zig`) draws under the existing
F2 / gamepad-BACK toggle. All checklist/acceptance items are integrated and
unit-tested; only the on-screen appearance (F2 in a live/`gpu-smoke` run) is
unconfirmed in a headless environment. Kept in the frontier (not archived) until
that visual pass, mirroring Slice 43.

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

- [x] Define archetype JSON schema (documented in `docs/` or beside the loader):
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
- [x] Implement loader + strict validation tests (good file, missing field,
      out-of-range gain, unknown behavior key, unknown faction, **unknown
      affect drive key**).
- [x] Register archetypes in runtime asset / content path used by
      `LoadingState` (same install-tree rules as other assets).
- [x] Migrate demo spawns to named archetypes (minimum set: `timid`,
      `curious`, `aggressive`, `cohesive`, optional `wanderer`) whose
      **emotion baselines** differ enough to show flee / investigate / pursue /
      cohere under the same world.
- [x] Extend debug overlay (gated by existing debug flag):
      - vision cone / range ring from perception cold+facing
      - **emotion drive bars** (fear/curiosity/aggression/fatigue; above-
        threshold highlight)
      - last-known memory marker + ring ticks
      - active behavior label
      - scope/tier counts from existing scope stats (no new sim policy)
- [x] Document authoring workflow in `docs/development-workflow.md` or a short
      `docs` note linked from the atlas/AI sections — include "how to tune a
      personality's feelings" via affect blocks.
- [ ] Optional: promote deferred `memory_expired` event only if debug or a
      reaction needs it; otherwise keep columnar (Slice 30 decision stands).

### Acceptance checks

- [x] Archetypes load from data with strict validation; spawns apply component
      bundles identical to hand-built fixtures for the same numbers. (Loader
      parity test asserts each catalog bundle equals the deleted literals
      field-for-field.)
- [ ] Demo shows differentiated behavior under the same world stimuli without
      code edits to gains (**timid fear → flee**, **curious → investigate dig
      noise**, aggressive pursues, cohesive clumps). (Mechanism verified: the
      `ai` bench shows all five behaviors emerging from the varied archetype
      baselines; the on-screen scene is the one item pending a live/`gpu-smoke`
      run.)
- [x] Debug overlay visualizes perception / **emotion drives** / memory /
      active behavior / scope without changing serial simulation checksums /
      intent streams. (Read-only const-slice gather; determinism test proves the
      AI columns are byte-identical before/after gather.)
- [x] No hot-path JSON or string behavior/emotion lookup; `zig build verify`
      passes. (Spawn resolves `@intFromEnum` → prevalidated bundle; strict
      load-time parse only.)
## Slice 35: AI And Steering Hot-Loop SIMD Restructure

Goal: restructure the existing scalar per-agent / per-neighbor loops in AI and
steering into packed-SoA-scratch vectorized kernels, so they hold up in heavy
scenes, large battles, and late-game worlds where they become the dominant cost.

Why deferred (not part of Slice 34): this is optimization, not foundation, and
its acceptance is defined at target scale. Prerequisites are landed: Slice 34
primitives, Slice 24 scoping (who reaches these loops per step), Slice 32's
arbitration reshape of AI decide, and Slice 33 archetypes / battle-scale demo
counts for representative load. New cognition stages stay SIMD-first per the
track contract; this slice targets the **pre-existing** AI separation /
decide-blend and steering avoidance scalar loops. Do not use 35 as a reason to
rewrite the utility/sticky arbitration contract.

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
- [ ] Migrate demo interest-marker placement
      (`game_demo_state.placeDemoInterestMarkers`) off hardcoded `level = 0` to
      the surface elevation (`levelElevation(...) == 0` / surface level index)
      so elevated stacks above the surface do not leave POIs on the wrong tier.
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
- [ ] Land at least one **new drive** end-to-end only when a real appraisal
      signal exists (e.g. damage/combat from 40/45, or another documented
      producer). **Do not ship a dead drive tag.** If deferred, leave this
      checklist item open with the blocking signal named.
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
- [ ] **No production `AiAffectDrive` tag without a wired appraisal path and
      at least one real producer signal** that can move the drive under test
      (no placeholder enums).
- [ ] New drive (when landed) appraises, decays, emits threshold edges, appears
      in archetype/debug, and modulates arbitration through the **same table
      path** as fear/curiosity/aggression/fatigue.
- [ ] No second emotion subsystem; no hot-path strings; `zig build verify`
      passes; `zig build bench -- --group ai-affect` shows no unexpected
      multi-x regression at equal agent counts.

## Slice 43: SDL3 Gamepad/Controller Support

**Status: landed (runtime behavior + tests + docs), manual hardware
verification pending.** This is app/input-layer work, independent of the
AI/render tracks (33, 35, 37–38, 40, 42, 45) — no ordering dependency either
way.

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

## Slice 44: Input Rebinding And Extended Gamepad Controls

**Status: not started.** App/input-layer work, depends on Slice 43 (landed);
independent of the AI/render tracks — no ordering dependency either way.

Goal: fill the controls Slice 43 deliberately deferred — a rebind capture UI
(defaults are no longer the only option) and the right-stick / trigger axes it
left as no-ops — without recompiling to change a binding and without breaking
the device-agnostic `Action` contract keyboard and gamepad already share.

### Current foundation (do not rebuild)

- `src/app/input.zig`'s `default_key_bindings` / `default_gamepad_bindings` are
  compile-time `pub const` tables; `actionForKey` / `actionForGamepadButton` /
  `actionForPressEvent` iterate them. A rebind UI needs a **runtime-mutable**
  table these resolvers read instead of the const arrays directly.
- `src/app/input_router.zig`'s `routeAction` + `SDL_EVENT_GAMEPAD_AXIS_MOTION`
  case forward only `SDL_GAMEPAD_AXIS_LEFTX`/`_LEFTY`; right stick and triggers
  arrive but are dropped.
- `src/game/settings_menu_state.zig` already owns a runtime settings struct
  (`RuntimeAudioSettings`) and menu-driven adjustment flow — the pattern a
  `RuntimeInputBindings` and its capture UI mirror.

### Architecture notes

- Introduce a runtime binding table (`RuntimeInputBindings`, initialized by
  copying the `default_*` consts) owned where the menu can mutate it; rewrite
  `actionForKey`/`actionForGamepadButton` to resolve against it. Keep the const
  tables as the reset-to-defaults source.
- Rebind capture (press-a-key-to-bind) lives in `settings_menu_state.zig`; reject
  conflicting/duplicate bindings loudly rather than silently shadowing an action.
- Add right-stick and trigger `Action` bindings with new axis cases in
  `input_router.zig`, gated by the same `InputRoutingPolicy` as the left stick.
  Right-stick semantics (e.g. camera/aim) stay a thin mapping — no new gameplay
  contract.
- **Persistence of custom bindings is deferred to Slice 46** (save/load). Until
  then bindings reset to defaults each launch — document this explicitly, do not
  leave it an implicit surprise.

### Checklist

- [ ] `RuntimeInputBindings` runtime table + reset-to-defaults; `actionFor*`
      resolve against it; tests that a rebound action resolves to the new
      key/button and that reset restores defaults.
- [ ] Settings-menu rebind capture flow with conflict/duplicate rejection; tests
      for the rejection path.
- [ ] Right-stick / trigger `Action` bindings + `input_router.zig` axis cases,
      policy-gated; tests mirroring the left-stick gating/no-op tests.
- [ ] Docs: update `docs/state-stack-and-input.md` `## Gamepad` / rebinding
      contract; note the reset-each-launch behavior pending Slice 46.

### Acceptance checks

- [ ] A rebound action resolves at runtime with no recompile; right stick /
      triggers drive their bound actions.
- [ ] Keyboard-only and default-binding paths are byte-for-byte unchanged.
- [ ] `zig build verify` passes.

## Slice 46: Save/Load Persistence

**Status: not started.** Completes the design intent from archive **Slice 10**,
which introduced `DataSystem` as "the state-owned persistent gameplay data
container **and save/load streaming boundary**" — the boundary exists, the
serialization was never implemented. Largely independent; benefits from Slice 44
(to persist custom bindings) but does not require it.

Goal: serialize and restore a running simulation to/from disk so gameplay state
survives a restart, reconstructing a **byte-identical** simulation — persisting
only stable IDs and enum/scalar columns, never paths or live handles.

### Current foundation (do not rebuild)

- `DataSystem` holds default-initialized SoA stores (`movement_bodies`,
  `facings`, `asset_refs`, `collision_*`, `ai_agents`, `steering_agents`,
  `world_levels`, `factions`, `ai_perceptions`, `ai_memories`, `ai_affects`,
  `destructibles`, …) plus entity slots + generations.
- `WorldSystem` owns tile / level storage; `player.zig` owns player state;
  `core/rng.zig` owns deterministic per-entity RNG; `RuntimeAssets` /
  `manifest.zig` own stable `SpriteAssetId` / `AudioAssetId`.
- The atlas / tileset metadata loaders (`world_tileset_meta.zig`,
  `sprite_atlas_meta.zig`) are the pattern for strict, versioned, load-time
  validation.

### Architecture notes

- Serialize by **stable asset IDs, entity slot + generation, and enum/scalar
  columns** — never file paths, live SDL/GPU/mixer handles, or prepared draw
  records (CLAUDE.md hard rule). This is what makes `DataSystem` the correct
  boundary rather than the renderer or asset layer.
- Versioned container: header (magic + format version) and per-store
  length-prefixed sections; strict validation on load (reject unknown version,
  out-of-range IDs, length mismatch) with **no partial apply** on failure —
  mirror the atlas-metadata loader discipline.
- Round-trip must reproduce an identical simulation checksum: persist enough sim
  state (step counter, RNG state, deferred-command-free quiescent snapshot point)
  that `save → load` yields byte-for-byte parity.
- Serialization is a **cold-path** operation (explicit save/load, not per-frame),
  so normal allocator use is fine — this is not a hot-path allocation-free
  constraint — but it must round-trip every persistent store and the world tile
  grid, not a subset.

### Checklist

- [ ] Versioned save writer over `DataSystem` stores + `WorldSystem` tiles/levels
      + player + sim step / RNG state; stable-ID mapping (no paths/handles).
- [ ] Strict-validation reader; corrupt / unknown-version / out-of-range
      rejection tests with no partial apply.
- [ ] Round-trip determinism test: `save → load → checksum-equal` against a
      hand-built fixture world.
- [ ] Optional: persist Slice 44 custom input bindings if that slice has landed.
- [ ] Docs: `docs/architecture.md` records the save/load boundary contract
      (what is persisted, by which stable identifiers, and what is deliberately
      excluded).

### Acceptance checks

- [ ] Save then load reproduces an identical simulation checksum on a fixture
      world.
- [ ] Malformed / version-mismatched saves reject loudly without partially
      mutating live state.
- [ ] Serialized form contains no handles or filesystem paths (payload-purity
      inspection/test); `zig build verify` passes.

## Slice 47: Un-Stagger The Shared Sensing Substrate

**Status: not started. Live perception defect** surfaced by the architecture
review — perception-carrying NPCs cannot perceive one another in the shipped
demo. Highest-priority correctness item on the AI track; land it before Slice 48.

Goal: build the shared spatial index and perception candidate set over the full
cognition-halo population, using cognition stagger only to choose which agents
*think* this step — so two observers on different stagger phases can sense each
other, and a timid `.ally` can see the hostile it is meant to flee.

### Problem (verified against live code)

- `simulation_pipeline.zig`'s `update()` hands the stagger-filtered
  `ai_indices` to `spatial_index.build`, and perception re-walks the same list.
  The shared neighbor grid and the perception candidate set therefore contain
  only one stagger cohort per step.
- `ai_archetypes.archetype_count = 8` and `simulation_scope.cognition_stagger_n
  = 4`, and demo spawns cycle archetypes by index, so archetype slot permanently
  pins stagger phase. The perception-carrying demo archetypes land on distinct
  phases → no observer can ever appear in another observer's candidate set.
- `perception.zig` gates the unconditional player fold-in on hostile stance, so
  the `.ally` timid archetype (designed to flee hostiles) has no candidates at
  all once its own cohort is filtered out.
- This is broken today, not a latent risk. The sticky-stimulus linger and the
  unconditional player candidate are the two demo-visible patches over the same
  hazard class; this slice fixes the general case.

### Architecture notes

- Split the two roles the single `ai_indices` list conflates: build the spatial
  index and perception's candidate table over the full cognition-halo population
  (tier + halo, **no** stagger filter); pass the stagger-filtered list only as
  the observer/decider (thinking) set. Think budget stays ~N/4; the candidate
  set becomes complete. The index build is the SIMD/threaded pass, so it is the
  cheapest stage to un-stagger.
- Coupling cost (verified): `ai.zig`'s `cohereNeighborVisit` indexes
  `ctx.candidate_faction[candidate_index]` with a **spatial** row index, so it
  hard-requires index-row == AI-row identity. Un-staggering requires giving
  `ai.zig` a candidates side table + `spatial_self_index` mapping — the pattern
  `perception.zig` already implements; copy it. Preserve serial==threaded and
  scalar==SIMD parity.
- Optional diagnostic dividend (coordinate with Slice 48): rename
  `.ai_scope_indices` into `ai_halo_indices` (index/candidate population) vs
  `ai_cognition_indices` (thinking population) so the two populations are
  distinct names in the comptime graph.
- All per-step caps stay fixed and world-size-independent; determinism preserved.

### Checklist

- [ ] `spatial_index.build` and perception's candidate gather run over the
      unstaggered cognition-halo population.
- [ ] Cognition stagger applies only to the observer/decider (thinking) set.
- [ ] `ai.zig` gains a candidates side table + `spatial_self_index` mapping so
      cohere neighbor queries no longer assume index-row == AI-row.
- [ ] Test with a non-null `cognition_region` and two observers on different
      stagger phases asserting mutual perception (whole class untested today —
      fixtures pass null).
- [ ] Verify a timid `.ally` perceives a hostile once its cohort is not filtered.

### Acceptance checks

- [ ] Two cognition observers on distinct stagger phases perceive each other in
      the same step.
- [ ] Serial==threaded and scalar==SIMD parity hold; think budget stays ~N/4.
- [ ] No AI/perception bench regression at battle scale; `zig build verify` passes.

## Slice 48: SimulationPipeline Thin-Composer Restoration

**Status: not started.** Structural refactor surfaced by the architecture
review. Land as independently-shippable steps in the listed order, never as one
change; each step is separately bisectable.

Goal: restore [architecture.md](architecture.md)'s thin-composer contract by
binding `stage_order` to execution, extracting the sensory bus into a controller,
evicting movement/world domain logic to its owning systems, and moving event and
allocation budgets to their producers — so the comptime stage graph governs what
actually runs and the composer stops owning cross-step state and policy.

### Problem (verified against live code)

- `update()` is ~270 straight-line lines mixing four altitudes. The pipeline
  owns cross-step sensory state (`deferred_stimuli`, `sticky_*`,
  `interact_held_last`, hearing scratch) plus policy (lifetime rules, the impact
  penetration curve, an eligibility gate, the interact latch).
- Four sensory mutations run as untagged wall-clock statements the comptime
  reads-before-writes check cannot see; `.action_intent_capture` is a declared
  stage whose real work happens before `update()`. `stage_order` binds to no
  executor (`runStage`/dispatch), so it governs nothing: the review panel
  reordered load-bearing stage pairs and the whole suite still passed.
- ~230 lines of movement/world domain logic and four serial, scalar,
  random-access full-AI-population scans sit in the composer — precisely because
  they live here instead of a system that would inherit the threading/SIMD/scope
  conventions (`simulation_pipeline.zig` has zero `@Vector` uses).

### Checklist (each step independently landable)

- [ ] **Contract vocabulary** (declaration-only): add a `carried` field to
      `StageContract` (checked disjoint from `reads`, required to be written by
      some stage) so `.reads = .empty` regains its meaning; split `.events` into
      `perception_events`/`affect_events`/`world_events`/`structural_events` (a
      stage-0-written tag must not vacuously satisfy every downstream read); add
      `.stimuli`/`.interest_markers`/`.ai_behavior` tags and `ai_decide`'s
      missing write; add a `stage_order` permutation comptime check.
- [ ] **Bind the graph**: add `StepState`, one private `stage<Name>` method per
      stage (carrying its own `StageTimer`), `runStage(comptime id)` with an
      exhaustive switch, and `inline for (stage_order) |id| try runStage(...)`;
      `update()` drops to ~6 lines. Delete `.action_intent_capture` (no body) →
      `carried = {action_intents}` on `.action_react`. Watch `zig build check`
      eval-branch quota; if it bites, split the switch by stage-half — never a
      runtime dispatch table on the frame path.
- [ ] **Extract `SensoryBus`** (`src/game/sensory_bus.zig`, in the
      DigController/AudioController mold): move the sensory state fields + the
      free functions (already written with `pipeline: *SimulationPipeline`
      first) + thresholds; add `StimulusConfig` mirroring `DigConfig`; split
      `footstep_velocity_sq_threshold` into `footstep_min_speed_sq` +
      `impact_min_approach_speed_sq`. Extract `contact_query.zig` as a shared
      leaf both `sensory_bus` and `audio_controller` import (including the
      duplicated `clamp(penetration/18, 0.25, 1)` curve). Decide sticky sizing:
      either fixed `(stimulus_max_impacts_per_step + 1) * (cognition_stagger_n -
      1)` with a comptime assert, or priority-aware capture (dig before impact).
      *(Bounded-drop + a counted `stimuli_sticky_dropped` metric already landed;
      this step chooses the permanent capacity, never a bigger number for one
      map.)*
- [ ] **Evict domain logic**: plane traversal (`applyPlaneTraversalStage` +
      helpers) → `DigController`, replacing the live-population
      `ensureTotalCapacity` carve scratch with a fixed init-sized buffer
      (`config.movement_body_capacity + 1`); the gate/clamp/`rectOverlap` family
      → a new `src/game/systems/world_gate.zig` (thread/SIMD it in a **separate
      benched** follow-up, so a perf change never rides inside a structural one);
      `applyAiMovementIntents` → `MovementSystem.applyIntents`.
- [ ] **Own the budgets**: add `SimulationPipeline.reserve(frame, pop)`; add
      `reserve` to `ai`/`perception`/`affect`/`ai_memory` called from `init`
      (they have no reserve seam today — allocation-freedom is "after warmup at a
      fixed population," not "after init"), and convert their `FailingAllocator`
      tests from warm-then-run to reserve-then-run; add an exhaustive
      `EventProducerId` + `maxEventsPerStep` so an unbudgeted producer will not
      compile; add the first composite `FailingAllocator` test over
      `pipeline.update()` on a minimal 1x1 fixture with dig + falls + contacts live.
- [ ] **Ordering-backstop tests** (belt-and-braces once the graph is bound):
      the affect-before-ai test must assert an AI-visible consequence of drives,
      not `fear > 0`; add a `chunk_derive` causal test (a body pushed across a
      chunk boundary by collision response, asserting the chunk column matches
      the settled position after `update()`); add a perception→ai_memory causal
      test where perception actually acquires so `ai_memory` refreshes
      `last_known` from this step's `last_seen`; fold the `RowInterest` column
      into the `ai` serial/threaded parity test.
- [ ] **Follow-ups** (independently landable, none blocking): route every
      producer through `SensoryBus.emit` and delete
      `SimulationFrame.appendStimulus`/`tryAppendStimulus`, making `live <= 32` a
      type invariant (ships with its own dig-behavior-change test); extend the AI
      bench to the full production config (memory/affect/populated
      `interest_markers`) and correct the roadmap AI-stage band; move
      `findBestInvestigateMarker`'s scan out of the serial gather into
      `writeAiSeparationJob`.
- [ ] Update [architecture.md](architecture.md) and
      [simulation-tiers-and-pipeline.md](simulation-tiers-and-pipeline.md): the
      contributor checklist gains the `carried` rule and the "a tag written by
      stage 0 cannot constrain anything downstream" rule; record the SensoryBus
      controller's stage placement.

### Acceptance checks

- [ ] `update()` is a short `runStage` loop; no untagged sensory mutation
      remains; reordering `stage_order` either fails to compile or fails a causal
      test.
- [ ] The sensory bus, `world_gate`, and movement-intent apply live in their
      owning modules; the pipeline composes them like `DigController`.
- [ ] Every per-step budget stays fixed/world-size-independent; the composite
      `update()` path is proven allocation-free-after-reserve by `FailingAllocator`.
- [ ] No bench regression from the moves (the `world_gate` SIMD pass is a
      separate benched follow-up); `zig build verify` passes.

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
23A. GPU tilemap render hardening (landed; merged to `main`).
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
32. AI behavior arbitration (**consume emotion drives**) — landed (archive).
33. Data-driven AI archetypes and debug introspection (incl. affect blocks). —
    landed (visual/GPU-smoke residual on frontier).
39. Sensory stimulus ecosystem (richer hearing/investigate inputs). — landed
    (archive).
41. World interest / affordance markers (multi-source goals). — landed
    (archive).
40. Action and interaction intent substrate (non-locomotion emergence). —
    landed (archive).
45. First action-intent consumer domain controller / destructibles (after 40).
    — landed (archive).
42. Affect expansion (more feelings, coupling, appraisal gains, optional mood)
    — only when a real appraisal signal exists.
35. AI and steering hot-loop SIMD restructure (unblocked; measure at battle
    scale — do not reshape arbitration contracts).
36. Single-pass dense-layer depth compositing. — landed (archive).
37. Dense render-window ceiling raise + shader/host sync hardening.
38. Elevation above the surface (after 37).
43. SDL3 gamepad/controller support (landed; HW residual on frontier).
44. Input rebinding UI + extended gamepad controls (after 43).
46. Save/load persistence (independent; benefits from 44 for binding
    persistence).
47. Un-stagger the shared sensing substrate (live perception defect; before 48).
48. SimulationPipeline thin-composer restoration (after 47; independent landable
    steps — contract vocab → bind graph → extract SensoryBus → evict domain
    logic → own budgets).

Dependency index for slice ordering. **Open Frontier Slice Index** is the entry
point; each slice's **Checklist** and **Acceptance checks** are what agents
complete. **Scaling Gaps** is backlog until copied into a slice section.
