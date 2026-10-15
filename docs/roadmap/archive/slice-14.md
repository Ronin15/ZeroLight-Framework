## Slice 14: First AI Intent Processor And Future Rule Contracts

Goal: add the first data-driven non-player decision processor that emits
deterministic movement intents through `SimulationFrame`, proving the AI/rule
processor boundary before broader rule systems are added.

Current foundation:

- `DataSystem` and component masks can identify entity membership for processors.
- Movement and particle processors demonstrate the system API shape.
- Slice 12 provides deterministic event/intent/deferred-command contracts.
- Slice 13 provides spatial query and contact data for perception and
  collision-aware decisions.
- `DataSystem` owns aligned `AiAgent` SoA data, membership masks,
  structural-command validation, and dense movement lookup for AI rows.
- `AiSystem` reads `AiAgent` and movement slices, builds a transient 32-unit
  spatial grid, computes bounded local-separation samples, emits deterministic
  `MovementIntent` ranges into `SimulationFrame`, and uses serial or adaptive
  threaded execution for the separation and intent-emission stages.
- `GameDemoState` runs AI after main-thread player input and before movement
  integration, then applies AI movement intents on the main thread before
  `MovementSystem`.
- AI benchmarks cover serial, fixed-thread, and adaptive profiles for quick,
  standard, and stress workloads.
- `zig build fmt`, `zig build test`, `zig build check`, and `zig build verify`
  passed for this slice.

Architecture notes:

- State-owned feature controllers should orchestrate feature phases and budgets,
  not become hidden per-entity stores. They may take typed `DataSystem` views
  and run small policy passes, but hot or reusable loops should remain
  systems/processors over SoA slices.
- Future AI and rules should emit movement intents, steering outputs, target
  choices, typed requests/results, or deferred commands rather than mutating
  unrelated stores directly.
- AI separation and intent emission are independently staged and tuned. Future
  perception or rule passes need the same explicit work ownership,
  stage-specific tuning, and deterministic merge points.
- Deterministic randomness must be explicit state or an explicit service passed
  through the processor boundary.

Checklist:

- [x] Reuse `MovementIntent` and `RangeOutputStream` for the first AI steering
      output.
- [x] Define processor order for the first AI decision output, movement intent
      application, movement integration, collision response, and cleanup.
- [x] Keep current conflict policy narrow: single-writer AI movement intents are
      applied on the main thread in merged range order. Multi-system
      incompatible-intent arbitration remains future work.
- [x] Add tests for repeatable decisions, stable merge order, and no steady-state
      allocation in hot processors.

Acceptance checks:

- [x] Non-player entities can be driven by data and processors rather than
      player-behavior copies.
- [x] The AI movement-intent processor produces deterministic outputs for fixed
      initial data, target, and random seed.
- [x] Processor outputs compose through typed data, intents, or deferred commands
      with explicit ownership and lifetime.

