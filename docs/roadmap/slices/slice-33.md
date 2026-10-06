## Slice 33: Data-Driven AI Archetypes And Debug Introspection

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 32](../archive/slice-32.md) · Track: [Emergent AI](../tracks/emergent-ai.md)

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
      passes. (Spawn resolves `@backingInt` → prevalidated bundle; strict
      load-time parse only.)
