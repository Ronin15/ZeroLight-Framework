## Emergent AI Track Overview (Slices 26–33, 39–42, 45, 47, 55, 56, 61, 68, 71, 73, 75)

> [Roadmap index](../../framework-implementation-slices.md) · Slice files:
> [`../slices/`](../slices/) · Settled slices: [`../archive/`](../archive/)

Goal: emergent NPC behavior (perception, memory, feelings, and utility
arbitration) on top of the navigation substrate, with many emotions and
decisions defined as content. Cognition runs for every agent in every world;
distance from the observer lowers its tick rate, never stops it (Slice 75,
`.claude/rules/engine-design.md` § Target scale). Hot paths stay
allocation-free and deterministic (serial == threaded, scalar == SIMD).

**Track status (code-authoritative):**

| Layer | Slice | Status | What it produces |
| --- | --- | --- | --- |
| Faction / RNG / spatial index | 26–28 | Landed (archive) | Stance table, deterministic draws, shared neighbor index |
| Perception | 29 | Landed (archive) | Vision/hearing columns + acquire/lose events |
| Memory | 30 | Landed (archive) | Last-known + ring + familiarity |
| Emotion / affect | 31 | Landed (archive) | fear / curiosity / aggression / fatigue drives with Schmitt thresholds |
| Arbitration | 32 | Landed (archive) | Utility scores + sticky selection → per-agent `NavigationIntent` |
| Archetypes / debug | 33 | Landed (visual residual) | JSON personalities + introspection overlay |
| Stimulus ecosystem | 39 | Landed (archive) | Multi-producer stimuli (dig, footstep, impact) |
| Action intents | 40 | Landed (archive) | Non-locomotion intent stream |
| World interest | 41 | Landed (archive) | investigate / cover / resource / patrol markers; investigate wired |
| First action consumer | 45 | Landed (archive) | `DestructibleController` at `action_react` |
| Sensing substrate | 47 | Landed (archive) | Unstaggered halo sensing; stagger gates observers/deciders only |
| **Data-driven cognition** | **73** | **Open** | Drives, behaviors, couplings, tasks, and factions as content; the per-agent think interval; gates every slice below that adds a drive or behavior |
| Affect expansion | 42 | Open (after 73) | New drives with real signals, authored coupling, mood, environment caution |
| Decision coasting | 55 | Open (after 73) | Idle agents decide less often; same-step wake from sensing |
| Combat | 56 | Open (after 73) | Damage → affect; AI actions through the one `ai_action_select` emitter |
| Forage / `need` | 61 | Open (after 73) | `need` drive, `forage` behavior, `resource` markers, affect impulses |
| Social / trade | 63 | Open (after 73) | Runtime stance, opinion ledger, social affect impulses |
| Battle-scale hardening | 68A | Open | Shared per-step entity table, action-bus fairness, soak procedure |
| Knockback / retaliation | 68B | Open (after 73) | Knockback column; retaliation memory |
| Posts / guard | 71A | Open (after 73) | Patrol / follow / guard, help call; `patrol` markers wired |
| Cover-aware movement | 71C | Open (after 73) | Cover goals for flee and ranged pursue; `cover` markers wired |
| AI selling | 71D | Open (after 73) | `trade` behavior; closes forage → sell |
| Far simulation | 75 | Open | Cognition at slower ticks far from the observer, in every world |

### Cognition redesign

The owner's cognition redesign (2026-10-08) is
[Slice 73](../slices/slice-73.md): drives and behaviors defined by data
with counts from content, no per-drive or per-behavior code, sparse
couplings and per-archetype behavior sets, a data-driven task layer under
utility selection, and the `.claude/rules/simulation.md` § AI and affect
edit, keeping utility scoring, sticky selection, and hysteresis drives.
Slices 42, 55, 56, 61, 63, 68B, 71A, 71C, and 71D add their drives and
behaviors on it.

### What exists today

| Piece | Location | Role |
| --- | --- | --- |
| `AiAffectDrive` | `data_system/types.zig` | Closed enum of four drives |
| `AiAffect` | `data_system/types.zig`, `data_system/affect.zig` | Named per-drive baseline / decay / threshold (cold) + value (hot) + `above_threshold_mask: u8` |
| `AffectSystem` | `systems/affect.zig` | Appraisal from perception, memory, and active behavior; decay; threshold events |
| `affect_threshold_crossed` | `simulation.zig` | Scalar `{ entity, drive, rising }` event |
| Arbitration | `systems/arbitration.zig` | `scoreBehaviors` / `selectSticky` / `resolveGoal` over `AiBehavior`'s five tags |
| `AiSystem` | `systems/ai.zig` | Gathers `Signals`, runs arbitration, emits `NavigationIntent` at `ai_decide` |
| Archetypes | `ai_archetypes.zig`, `assets/ai/archetypes.json` | Strict load-time personalities |

Stage order `perception → ai_memory → affect → ai_decide → steering →
pathfinding` (`simulation_pipeline.zig` `stage_order`). Pursue/flee prefer
perception's faction-generic `nearest_threat`, then fresh memory, then the
opt-in focus fallback; investigate prefers heard stimuli, then interest
markers, then memory-ring contacts; cohere reads the shared spatial index.

Track-wide contracts (component stores, SIMD-first processors, scalar
events, utility + sticky selection, optional signal components) are rules
in `.claude/rules/simulation.md`, `.claude/rules/threading.md`, and
`.claude/rules/memory-performance.md`.
