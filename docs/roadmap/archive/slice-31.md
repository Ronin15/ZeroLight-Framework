## Slice 31: AI Affect And Emotion Drives

Goal: add an appraisal-driven scalar emotion model whose drives modulate behavior
weights, decaying toward per-entity baselines.

Current foundation:

- No affective/emotional state exists. `data_system.zig` already provides
  SIMD-aligned hot f32 column support reusable for drive columns.
- Perception (29) and memory (30) provide the appraisal inputs.

Architecture notes:

- Drives are a small fixed set (`fear`, `curiosity`, `aggression`, `fatigue`) as
  hot SIMD-aligned f32 columns; the update is pure column math that vectorizes
  like movement integration (`systems/movement.zig`).

Checklist:

- [x] Add an `AiAffect` component with fixed scalar drive columns plus per-entity
      baselines, SIMD-aligned.
- [x] Add an `AffectSystem` parallel/SIMD stage that appraises perception +
      memory into drive deltas, applies them, and decays each drive toward its
      baseline; bounded, allocation-free, deterministic.
- [ ] Expose drives to behavior arbitration (Slice 32) as weight modulators
      (fear → flee weight, curiosity → investigate weight, aggression → pursue
      weight, fatigue → slow/wander bias). Deferred to Slice 32 itself —
      `AiConfig`/`decideDir()` do not yet read any affect drive.
- [x] Add scalar-only `affect_threshold_crossed { entity, drive, rising }` events
      for threshold crossings (panic onset/calm) at `domain_reaction`.

Acceptance checks:

- [x] Scalar and SIMD affect updates produce identical results (parity test).
- [x] Drives stay bounded and decay to baseline with no inputs; updates are
      allocation-free.
- [x] Threshold events are low-volume by construction and capacity-bounded.
- [x] `zig build test` covers appraisal, decay-to-baseline, and threshold events.

**Status: landed** (substrate complete; **consumption = Slice 32**, **growth =
Slice 42**). `AiAffect` (`data_system/types.zig`) carries four independent
emotion drives (`fear`, `curiosity`, `aggression`, `fatigue`), each with its
own per-entity cold `baseline_*`/`decay_rate_*`/`threshold_*` tunables plus a
hot per-step value clamped to `[0, 1]`; `decay_rate_*`/`threshold_*` are
deliberately per-entity, not a single global constant, since a future
data-driven archetype (Slice 33) needs per-personality decay speed and
sensitivity, not just a per-personality resting level — the only global
tunable is `ai_affect_threshold_hysteresis`. `AiAffectStore`
(`data_system/affect.zig`) mirrors `PerceptionStore`'s cold-preserves-hot
`set()` contract exactly. `AffectSystem` (`systems/affect.zig`) runs in
`SimulationPipeline` between `AiMemorySystem` and `AiSystem`: it appraises the
cognition-scoped `AiAffect` subset from this step's just-written
`AiPerception`/`AiMemory` state (both independently optional per row — a
missing component contributes "no signal," never excludes the row) plus each
row's own `AiAgent.behavior` (fatigue's input, since active pursuit vs.
wandering is not a perception/memory signal). Fear and aggression share the
same visible-hostile/distance signal but use independent gain constants and
are deliberately never cross-coupled; curiosity rises from an unseen heard
stimulus and separately from low memory familiarity; **cross-drive modulation
and additional feelings are Slice 42**, not half-wired here. Appraisal *gain*
constants (`gain_fear`, etc. in `affect.zig`) are still module-level — moving
them to per-entity/archetype fields is Slice 42 (33 can already author
baselines/thresholds). The compute pass vectorizes across four scattered rows
per lane group, one drive-column pass at a time, gathering each row's own
baseline/decay rate/threshold via `simd.gatherFloat4`. Threshold edges use a
true Schmitt trigger on `above_threshold_mask` (u8 → room for 8 drives before
a widen). Event emission mirrors `PerceptionSystem.mergePerceptionEvents`,
with up to one edge event per drive per row per step. Bench group `ai-affect`
(`src/benchmarks/affect.zig`): `--profile quick`, 10,000 agents serial-direct
2.09ms / best-threaded 1.44ms (1.45x).

**Residual expandability (tracked, not incomplete 31 work):**

- Drives are **unread by AI** until Slice 32.
- Four-drive named fields + global appraisal gains + no cross-drive coupling +
  no longer-horizon mood — growth path is **Slice 42** and the track-overview
  "How to add a new feeling" checklist, not ad-hoc forks of `AffectSystem`.


