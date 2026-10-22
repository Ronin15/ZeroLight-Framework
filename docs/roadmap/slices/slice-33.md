## Slice 33: Data-Driven AI Archetypes And Debug Introspection

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 32](../archive/slice-32.md) · Track: [Emergent AI](../tracks/emergent-ai.md)

**Status: landed; on-screen visual (F2 / `gpu-smoke`) verification
pending.** Kept open until that visual pass, like Slice 43.

Goal: AI personalities are authorable without recompiling and observable
while tuning: archetypes are load-time data, not `DemoSpawnSpec` literals,
and an introspection overlay shows what each agent senses, feels, and
chooses, with no JSON or string names on the hot path.

### Current foundation

- `src/game/ai_archetypes.zig` loads `assets/ai/archetypes.json` at init
  through `UpdateContext.asset_store` into a closed `AiArchetypeId` and an
  enum-indexed bundle table; spawns resolve the id to a prevalidated bundle.
  The deleted `demoArchetypeForIndex` literals are reproduced field for
  field.
- `src/game/ai_debug_overlay.zig` draws vision cones, per-drive bars with the
  above-threshold highlight, memory markers, the active behavior label, and
  scope counts under the existing F2 / gamepad-BACK toggle, from a read-only
  const-slice gather.
- Slice 73 replaces the closed drive and behavior sets this schema names
  with catalog data; this slice's loader and overlay are its starting point.

### Architecture notes

- Parsing and strict validation are load-time only: unknown keys and
  out-of-range values fail loudly; hot paths see only ids and tables
  (`.claude/rules/simulation.md` § AI and affect).
- Archetypes resolve to stable identifiers and component bundles, never
  paths or live handles (`.claude/rules/simulation.md` § Persistent data).
- The overlay is read-only over simulation: no RNG, events, or mutation, and
  no draw path in AI benches (`.claude/rules/engine-design.md`).

### Checklist

- [x] Archetype JSON schema: faction, optional perception / memory / affect
      blocks, behavior gains, wander amplitude, steering defaults, stable
      sprite reference.
- [x] Strict loader with tests (good file, missing field, out-of-range gain,
      unknown behavior, faction, or drive key).
- [x] Archetypes registered in the runtime asset path used by
      `LoadingState`.
- [x] Demo spawns migrated to named archetypes (`timid`, `curious`,
      `aggressive`, `cohesive`, `wanderer`) with differentiated baselines.
- [x] Overlay: vision cone, drive bars, memory marker, behavior label, scope
      counts.
- [x] Authoring workflow documented, including tuning a personality's
      feelings.

### Acceptance checks

- [x] Archetypes load with strict validation; spawned bundles equal
      hand-built fixtures (loader parity test).
- [ ] Demo shows differentiated behavior under the same stimuli (timid
      flees, curious investigates dig noise, aggressive pursues, cohesive
      clumps); the `ai` bench shows all five behaviors emerging, and the
      on-screen scene awaits a live / `gpu-smoke` run.
- [x] The overlay leaves serial checksums and intent streams unchanged
      (byte-identical AI columns before and after gather).
- [x] No hot-path JSON or string lookup; `zig build verify` passes.
