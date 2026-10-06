## Long-Term Gameplay Direction

> [Roadmap index](../../framework-implementation-slices.md)

Future features land as slices: state-owned pipeline or feature controllers for
orchestration, SoA processors for hot data, typed `SimulationFrame` outputs,
deferred structural commits. Controllers own phase order, budgets, and handoff;
processors stay dumb; persistent facts stay in `DataSystem` / `WorldSystem`.
Simulation scope filters which rows enter each stage without changing processor
math. New gameplay domains should add a slice section (Goal, Checklist,
Acceptance) before implementation. Durable boundaries:
[architecture.md](../../architecture.md); emergent-AI shared contracts:
[Emergent AI Track Overview](emergent-ai.md); VoidLight port shared contracts
(seed, sim view, action claims, inventory transfers, settings) and the
authoritative cross-slice tables: [VoidLight Port Track Overview](voidlight-port.md).

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

