## Slice 56: Health, Damage, And Combat Domain Controller

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 49](slice-49.md), [Slice 73](slice-73.md), [Slice 40](../archive/slice-40.md), [Slice 45](../archive/slice-45.md) · Track: [VoidLight port](../tracks/voidlight-port.md) · [Emergent AI](../tracks/emergent-ai.md)

**Status: not started.**

Goal: entities can be damaged and die, in every world and at every distance
from the observer. NPCs, and a player when present, attack through the existing
`action_intents` bus. This slice owns the single AI action emitter and the
single per-step claim set every later action consumer shares (one consumer
per intent). Damage and crit rolls are deterministic functions of the
session seed's combat domain, stable entity IDs, and the step. Deaths commit
as deferred destroys. Damage feeds affect through a real appraisal signal,
and scalar domain events drive audio and particles. Serial == threaded,
allocation-free after reserve, every per-step budget a fixed count.

In scope: melee (explicit-target AI attacks and the player's faced-arc
swing), simultaneous same-step resolution, death, the affect signal, events
with audio and particle reactions, archetype authoring. Out of scope:
projectiles (56B), equipment modifiers (57), knockback and retaliation
(68B), loot (57).

### Current foundation

- Action bus: `ActionKind` (`interact`, `attack`, `use`, `signal`),
  `ActionIntent`, `action_intent_live_capacity = 64`, and the append helpers
  in `src/game/simulation.zig`; player `.interact` capture with a rising-edge
  latch in `SimulationPipeline.captureActionIntent`.
- First consumer: `DestructibleController.process`
  (`src/game/destructible_controller.zig`) at `action_react` preflights
  structural and event capacity, emits `destructible_destroyed` while the
  target is alive, and soft-drops particles.
- Stage graph: `PipelineResource`, `StageId`, `stageContract`, and
  `stage_order` with comptime checks in `src/game/simulation_pipeline.zig`;
  event bounds from the exhaustive `EventProducerId` summed by
  `SimulationPipeline.eventCapacitySum()`.
- Components: `Component = enum(u5)` with 14 tags
  (`src/game/data_system/types.zig`); MAL store pattern in
  `data_system/destructible.zig`.
- RNG: stateless `mix64` / `uniformF32` / `boundedU32`
  (`src/core/rng.zig`); AI keys draws off `AiConfig.intent_seed`. Slice 49
  supplies `SimulationSeed` / `SeedDomain` and `StepIndex = u64`; today
  `step_count` is `u32` (`src/game/systems/simulation_scope.zig`).
- Affect gathers optional inputs with "no signal" defaults
  (`src/game/systems/affect.zig`).
- The spatial index holds step-start positions
  (`src/game/systems/spatial_index.zig`); perception's `nearest_threat` is
  faction-generic and includes the player; `faction.stance`
  (`src/game/faction.zig`).
- `AudioController` (`src/game/audio_controller.zig`) has only
  `collision_sfx`; `ParticleSystem.emitBurst`
  (`src/game/systems/particle.zig`).

### Architecture notes

- Health is integer so saves and goldens stay exact; `health` and
  `combat_stats` follow the component-store pattern, tags appended in
  landing order (`.claude/rules/simulation.md` § Persistent data).
- Absolute steps are stored as due steps with saturating "step after" and
  "step reached" helpers owned here; 56B, 57, 61, 62 reuse them.
- One AI action emitter (`ai_action_select`): attack is Slice 73 behavior
  data that emits an action, not a behavior switch arm; 61, 71D add their
  actions the same way, never a second emitter or an `ai_decide` write of
  `action_intents` (`.claude/rules/simulation.md` § Controllers and
  processors).
- One claim set, fixed claim order trade (63) → harvest (61) → destructible
  (45) inside `action_react`, then combat consumes unclaimed attacks.
- AI actions share a fixed per-step budget per world with deterministic
  rotating deferral (fairness priority from 68A); a deferred actor keeps its
  cooldown and retries (`.claude/rules/budgets-capacities.md`).
- Resolution is simultaneous: outcomes never depend on intent order; mutual
  kills in one step work; killer is the top contributor with a stable
  tie-break.
- Damage rolls draw only through `src/core/rng.zig` from
  `seed.derive(.combat)` computed once at init (Slice 49); no literal seeds.
- Combat work scaling with population runs through the thread system with
  serial and threaded paths; the main thread holds only ordered merge and
  commit (`.claude/rules/threading.md`).
- Damage reaches affect once per hit through a watermark on the victim
  (`.claude/rules/simulation.md` § AI and affect); rows without health
  contribute zero.
- Kills preflight events and structural commands; commits are all-or-fail
  (`.claude/rules/simulation.md` § Events and streams).
- Per-step hit and kill caps are fixed counts; excess hits defer
  deterministically to later steps, never dropped or refused; a kill
  resolves when its hit applies (`.claude/rules/budgets-capacities.md`).
- Player: `Action.attack` is a gameplay action under modal routing
  (`.claude/rules/input-state.md`); a replay bit is pinned with it (Slice
  49); death is downed-then-revived.
- New hashed stores are classified in Slice 49's lists and saved by Slice
  46 in the same change (Ground Rules; Tables T3/T6).
- Knockback stays out of `combat_resolve`, which runs after `chunk_derive`;
  Slice 68B adds it as a next-step movement column.
- VoidLight reference: port the base × variance × crit damage shape, the
  cooldown, the faced-arc melee, and critical-health-flees as emergent
  damage → fear; not its thread-local RNG, immediate event dispatch, or UI
  strings in combat code.

### Checklist

- [ ] `health` / `combat_stats` components, stores, validation, and full
      wiring; store `FailingAllocator` and round-trip tests.
- [ ] Slice 49 classification and Slice 46 save sections for both stores.
- [ ] Saturating absolute-step helpers on `StepIndex`, with boundary tests.
- [ ] `core/math` round-and-clamp-to-integer primitive with bound, NaN, and
      ±inf tests.
- [ ] Archetype health and combat content with strict validation; player
      combat stats.
- [ ] Pipeline: `ai_action_select` and `combat_resolve` stages with their
      resource tags and contracts; `action_react` reads `action_intents` and
      writes claims.
- [ ] `ai_action_select`: one threaded two-pass emitter over attack data,
      shared budget with rotating deferral, deferral counter.
- [ ] Claim set and claim order; destructible tests pass a claim set.
- [ ] `CombatController`: revive, explicit and arc resolve, simultaneous
      apply, seeded rolls, preflight, death, particles, fixed per-step hit
      and kill caps with deterministic deferral of excess hits.
- [ ] Combat events, stats, metrics, and event budget; pipeline-owned
      structural share for kills.
- [ ] Affect damage signal through the watermark; undamaged rows
      bit-identical.
- [ ] `Action.attack` bindings, routing tests, replay bit, and capture
      latch (classified in 64B and saved in 46's `pipeline_history`).
- [ ] `AudioController.queueCombat` with a fixed per-step SFX cap.
- [ ] (added by Slice 67) Event-log lines for both events; `StringId` text
      if 67E has landed.
- [ ] (If 55 landed) A coasting timid row hit by a visible attacker decides
      on its next sense tick.
- [ ] Docs: `docs/simulation-tiers-and-pipeline.md`, `docs/architecture.md`,
      `docs/state-stack-and-input.md`, archetype schema.

### Acceptance checks

- [ ] Same `(seed, attacker, target, step)` gives the same roll; a
      different seed changes the sequence; crit rate matches `crit_chance`
      over many rolls.
- [ ] `ai_action_select` serial == threaded, including a budget-capped
      rotation case; deferred attackers keep their cooldown.
- [ ] Permuted intent order gives identical health, deaths, killers, and
      cooldowns; a mutual kill works.
- [ ] A 60-step composite run gives identical health, cooldown, and kill
      checksums at 0 and N workers.
- [ ] Resolution rules: claims (crate before enemy), friendly rejection,
      cooldown, arc and reach on current poses, the documented one-step
      catch-up lag, saturating cooldown near `maxInt(StepIndex)`.
- [ ] Kill path: `entity_killed` before `entity_destroyed`; downed entities
      revive next step.
- [ ] A burst of hits past the per-step cap lands on later steps in order;
      no hit is dropped and no kill is refused.
- [ ] Damaged timid fear rises once per hit across stagger phases;
      undamaged rows unchanged.
- [ ] Payload-purity tests for both events; `FailingAllocator` proofs for
      stores, emitter, controller, and the composite pipeline.
- [ ] Benches `ai-action-select` (three population sizes, linear in
      candidates) and `combat-resolve` (flat per hit); `ai-affect` shows no
      regression.
- [ ] Slice 68A soak procedure recorded; `zig build verify` passes.
