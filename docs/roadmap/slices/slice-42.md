## Slice 42: Affect Expansion — More Feelings, Coupling, And Mood

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 32](../archive/slice-32.md), [Slice 56](slice-56.md), [Slice 61](slice-61.md), [Slice 59](slice-59.md) (environment caution needs 59) · Track: [Emergent AI](../tracks/emergent-ai.md)

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

**Environment caution (VoidLight caution scale, ported as a per-entity fear
gain; added by Slice 69).** Night and storms raise fear through a per-entity appraisal gain, never
through a global fear multiplier.

- **Signal.** It is owned by Slice 59's `environment.zig`.
  `EnvironmentModifiers` gains `caution: f32 = 0`.
  - Time scale: `time_caution = lerp(1.3, 1.0, daylight)`. Night is 1.3 and
    day 1.0; VoidLight's evening 1.1 falls on this ramp.
  - Weather scale: a from→to blend of these per-kind values: clear 1.0,
    cloudy 1.0, rain 1.15, storm 1.4, fog 1.25, snow 1.2, wind 1.05.
  - `caution = (clamp(time_caution * weather_caution, 1.0, 1.5) - 1.0) / 0.5`,
    which lies in `[0, 1]`. Examples: night clear = 0.6, day storm = 0.8,
    night storm = 1.0.
  - It is not part of the `[0.25, 1]` clamp that applies to the three
    range/speed scales.
  - Identity (the default lookup, an unexposed level) gives `caution = 0`.
  - Only IEEE basic ops are used, so the signal is sim-safe.
- **Data.**
  - `AiAffect` gains the cold column `gain_fear_caution: f32 = 0`, validated
    finite in `[0, max_ai_affect_appraisal_gain]`. The new constant is
    `max_ai_affect_appraisal_gain: f32 = 1.0`. This slice's "promote
    appraisal gains" item shares that cap: a gain of 1 can saturate a drive in
    one step.
  - The column is threaded through `AffectRow`, `AiAffectSlice` /
    `ConstAiAffectSlice`, `validateAiAffect`, and the archetype `affect` key
    `gain_fear_caution` (`src/game/ai_archetypes.zig:125-138`).
- **Appraisal.**
  - `AffectConfig.environment: EnvironmentModifierLookup = .{}`.
  - `gatherScopedIndices` (`src/game/systems/affect.zig:323-371`) resolves
    `world_level` (missing → 0) and the movement body position (missing →
    caution 0). It packs `AffectGatherRow.environment_caution`, read through
    the lookup at the same position perception gathers. It calls
    `forPosition` if Slice 69B has landed, else `forLevel`; 69B's checklist
    migrates this call.
  - `processFearColumn` (`:545-587`) adds
    `gain_fear_caution[index] * environment_caution` to the fear delta in both
    the SIMD path (`simd.gatherFloat4(s.gain_fear_caution, lanes)` ×
    `loadFloat4`) and the scalar tail. The term applies regardless of
    visibility.
  - Steady state rises by `d·(1-r)/r` above baseline (from `combineDrive`,
    `:483-493`). Example: `d = 0.03 × 0.6` at the default decay `r = 0.05`
    gives +0.34.
- **Parity.** With a gain of 0, the added term is `+0.0`. The existing delta is
  never `-0.0`, because it is `select(…, +0)` or a non-negative product, so
  fear is bit-identical to today.
- **Pipeline.** `stageContract(.affect_update).reads += {environment}`.
  `environment_update` (index 0) writes it, so the comptime order check
  passes. The pipeline passes `environment.modifierLookup(world)`, the same
  value perception gets.
- **Content.** The `timid` archetype gets `"gain_fear_caution": 0.03`. Timid
  allies grow more skittish at night and in storms through the existing fear ×
  `gain_flee` table path. No other archetype changes.

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
- [ ] (added by Slice 69) `environment.zig` (Slice 59 module): `EnvironmentModifiers.caution`,
      the caution tables above, the time/weather blend, and identity → 0, with
      pure tests at night clear, day storm, night storm and underground.
- [ ] (added by Slice 69) `AiAffect.gain_fear_caution` cold column and `max_ai_affect_appraisal_gain`
      through the store, slices, validation (rejecting negative, non-finite and
      above-cap values) and the archetype key. `timid` gets 0.03 in
      `assets/ai/archetypes.json`.
- [ ] (added by Slice 69) `AffectConfig.environment`; gather of `environment_caution`; SIMD and
      scalar fear-delta term; pipeline wiring;
      `affect_update.reads += {environment}`.
- [ ] (added by Slice 69) Tests:
      - gain 0 (and the identity lookup) gives bit-identical fear columns
        against the pre-change fixture;
      - a surface night with gain 0.03 converges to `baseline +
        0.03·0.6·0.95/0.05` within 1e-4 after 600 steps;
      - an underground row stays at baseline;
      - SIMD lanes equal the scalar tail;
      - serial == threaded;
      - causal test "pipeline applies this step's environment caution before
        affect";
      - the `FailingAllocator` steady-state proof is unchanged.
- [ ] (added by Slice 69) Bench: `zig build bench -- --group ai-affect` shows no unexpected
      regression at equal agent counts.
- [ ] (Tables T3/T6) Every new hashed `AiAffect` column this slice adds
      (`gain_fear_caution`, promoted appraisal gains, coupling or mood
      columns) is classified in Slice 49's completeness lists and saved in its
      Slice 46 section; the landing change bumps `checksum_format_tag` (v+1)
      and the save `format_version` (live + 1) once each.

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

