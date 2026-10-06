## Emergent AI Track Overview (Slices 26–33, +39–42, +45, +55, +56, +61, +68, +71)

> [Roadmap index](../../framework-implementation-slices.md) · Slice files:
> [`../slices/`](../slices/) · Settled slices: [`../archive/`](../archive/)

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
| Sensing substrate fix | 47 | **Landed (archive)** | Unstaggered halo spatial index + perception candidates; stagger gates observers/deciders only |
| **Affect expansion** | **42** | **Open** | More drives, cross-drive coupling, data-driven appraisal gains, optional mood, environment caution as a per-entity fear gain (first new drive `need` lands in 61) |
| Decision LOD | 55 | Open | Idle-agent decide coasting on fixed 8/32-step cadences; same-step wake from sensing; stagger unchanged |
| Combat signal | 56 | Open | Damage → fear/aggression appraisal; AI actions emitted by `ai_action_select` |
| Forage / `need` | 61 | Open | `need` drive + `forage` behavior; `resource` markers wired; `AffectImpulse` substrate |
| Battle-scale hardening | 68A | Open | Shared halo table (no main-thread O(halo) AI/perception walks), deferral-age action-bus fairness, re-baseline procedure |
| Knockback / retaliation | 68B | Open | Knockback column + `knockback_apply`; retaliation memory slot from `Health.last_attacker` |
| Posts / guard | 71A | Open | Patrol / follow / guard, `guard_alarm` help call, own-level post goals; `patrol` markers wired |
| Cover-aware movement | 71C | Open | Cover-aware flee and ranged pursue; `cover` markers wired |
| AI selling | 71D | Open | `trade` behavior + `.sell` arm; closes forage → sell |

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

1. Append a tag to `AiAffectDrive` (preserve existing `@backingInt` order —
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
- **Open post-loop expandability:** **42** (more/coupled feelings, only with a
  real appraisal signal). Action intents (**40**) and first consumer (**45**)
  are landed. Sensing substrate (**47**) and thin-composer restoration (**48**)
  are landed. Each remaining item is a full slice — do not half-wire into 32
  or overload `NavigationIntent`. Next open on this track is **42**, and only
  once a real appraisal signal exists. **35** is the unblocked perf follow-up.

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
