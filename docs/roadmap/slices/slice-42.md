## Slice 42: Affect Expansion — More Feelings, Coupling, And Mood

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 73](slice-73.md), [Slice 56](slice-56.md), [Slice 61](slice-61.md), [Slice 59](slice-59.md) (environment caution only) · Track: [Emergent AI](../tracks/emergent-ai.md)

**Status: not started.**

Goal: grow the feelings model on Slice 73's drive catalog: new drives that
each have a real appraisal signal, authored cross-drive coupling, per-archetype
appraisal gains, an optional slow mood layer, and environment caution (night
and storms make cautious agents more fearful), all as content plus the
signal primitives they need, never a second emotion system.

### Current foundation

- Four drives (`AiAffectDrive`, `src/game/data_system/types.zig`) with
  module-level appraisal gains and no cross-drive terms in
  `src/game/systems/affect.zig`; Slice 73 turns drives, gains, and coupling
  into catalog data.
- Real signals arriving before this slice: Slice 56's damage watermark
  (`Health.damage_taken_total` appraised once per hit), Slice 61's `need`
  drive and affect-impulse queue, Slice 59's environment modifiers (game
  clock, day phase, weather).
- Benches: `ai-affect`, `ai`.

### Architecture notes

- Every drive lands with a real producer signal and at least one behavior
  term; no placeholder drives (`.claude/rules/simulation.md` § AI and
  affect). Candidates: `pain` on 56's damage signal, `morale` from ally
  density and faction, `contentment` from low threat and high familiarity.
- Appraisal gains are per-archetype content, so timid and bold agents feel
  the same threat differently.
- Coupling is sparse authored drive → drive terms applied once per
  appraisal, deterministic and allocation-free; no recursive passes.
- Mood is slow per-agent state biasing baselines or scores, never a
  replacement for drives; it advances for every agent at its own tick rate
  (Slice 75), never freezes.
- Environment caution (VoidLight caution scale) is a per-agent appraisal
  gain on a caution signal owned by Slice 59's environment module, never a
  global fear multiplier. Signal: time scale 1.3 at night to 1.0 by day
  times a weather scale blended between kinds (clear 1.0, cloudy 1.0, rain
  1.15, storm 1.4, fog 1.25, snow 1.2, wind 1.05), clamped to `[1, 1.5]`
  and mapped to `[0, 1]`; underground and default lookups give 0. A gain of
  0 leaves fear bit-identical. Slice 69B moves the lookup to per-region.
- New hashed state is classified in Slice 49's lists and saved by Slice 46
  with relative version bumps (Tables T3/T6).
- Serial == threaded; SIMD == scalar where vectorized
  (`.claude/rules/threading.md`, `.claude/rules/memory-performance.md`).
- Non-goals: full psychological simulation, emotion graphs as runtime
  structures, per-entity heap emotion stacks, string emotion names on the
  hot path, an FSM of named moods.

### Checklist

- [ ] Per-archetype appraisal gains authored for the existing drives;
      defaults equal today's constants.
- [ ] First new drive end to end on a real signal (e.g. `pain` on 56's
      damage watermark), with behavior terms and overlay display; if no
      signal is ready, this item stays open naming the blocker.
- [ ] Optional: sparse drive → drive coupling content with tests (fear
      dampens curiosity, aggression raises fatigue).
- [ ] Optional: mood layer that advances at every distance.
- [ ] (added by Slice 69) Caution signal in Slice 59's environment module
      with pure tests (night clear, day storm, night storm, underground).
- [ ] (added by Slice 69) Caution appraisal input and per-archetype gain;
      one archetype authored with a nonzero gain.
- [ ] (added by Slice 69) Causal pipeline test: this step's caution is
      applied before affect.
- [ ] Persistence: new hashed state classified (Slice 49) and saved (Slice
      46), relative version bumps.
- [ ] Docs: `docs/architecture.md` affect section and the archetype
      authoring doc.

### Acceptance checks

- [ ] Existing drives are unchanged at default content (Slice 32 parity
      fixtures pass with coupling off).
- [ ] No drive exists without a wired appraisal path and a producer signal
      that moves it under test.
- [ ] A new drive appraises, decays, emits threshold edges, appears in the
      overlay, and changes arbitration through the catalog path.
- [ ] Caution: gain 0 is bit-identical; a surface night converges to the
      analytic steady state; an underground row stays at baseline.
- [ ] Serial == threaded; `FailingAllocator` proofs hold on affect and the
      AI consume path.
- [ ] `zig build bench -- --group ai-affect` shows per-agent cost linear in
      the drives an agent uses; `zig build verify` passes.
