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

**What exists today:**

| Piece | Location | Role |
| --- | --- | --- |
| `AiAffectDrive` | `data_system/types.zig` | Closed enum: `fear`, `curiosity`, `aggression`, `fatigue` |
| `AiAffect` component | same + `data_system/affect.zig` | Per-drive baseline / decay_rate / threshold (cold) + live value in `[0,1]` (hot) + `above_threshold_mask` |
| `AffectSystem` | `systems/affect.zig` | Cognition-scoped appraisal from perception + memory + agent mode; decay; threshold events |
| `affect_threshold_crossed` | `simulation.zig` | Scalar event `{ entity, drive, rising }` — panic onset / calm, etc. |
| Pipeline slot | `affect_update` before `ai_decide` | Correct order for a consumer; wired to arbitration (32) via `AiConfig.affect_slice` |

Rules for drives, appraisal, arbitration, events, and component stores:
`.claude/rules/simulation.md` (AI and affect, Events and streams, Persistent
data). Headroom: `above_threshold_mask` is `u8`, so up to 8 drives fit the
current packing; widening it belongs to Slice 42.

**How a new feeling is added (procedure for Slice 42):**

1. Append a tag to `AiAffectDrive` (preserve existing `@backingInt` order —
   append only).
2. Add cold baseline/decay/threshold + hot value columns on `AiAffect` /
   store / slices / template / validation (same pattern as existing drives).
3. Add one appraisal path in `AffectSystem` (signal → delta → decay → clamp →
   threshold bit). Prefer a shared `combineDrive` helper already used by the
   four drives.
4. Extend archetype JSON (33) and debug bars (33) for the new drive.
5. Add **one row** to arbitration's drive→behavior weight table (32's
   contract) rather than a `decideDir` special case.
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

**Landed loop inputs:** multi-producer stimuli (39: dig /
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
  are landed. Each remaining item is a full slice. Next open on this track is **42**, and only
  once a real appraisal signal exists. **35** is the unblocked perf follow-up.

Track-wide design contracts (component-store pattern, SIMD-first processor
stages, scalar events, utility + sticky selection, optional signal components)
are rules in `.claude/rules/simulation.md`, `.claude/rules/threading.md`, and
`.claude/rules/memory-performance.md`.
