## Slice 64B: Simulation Checksum v2 — NaN-Canonical, Sectioned, Threaded, Pipeline-History Coverage

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 49](slice-49.md), [Slice 50](slice-50.md), [Slice 64A](slice-64a.md), [Slice 64G](slice-64g.md), [Slice 74](slice-74.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Lands before 46, which saves exactly this slice's
hashed set, uses `normalizeDerivedState` as its load-parity reference, and
writes `buildFingerprint()`.

Goal: the checksum (1) is a pure function of IEEE-observable state, so NaN
sign and payload never cause a false cross-machine mismatch while NaN
presence is still reported; (2) covers every piece of carried pipeline
history that changes future persistent state, in every world instance, with a
comptime-enforced classification of every pipeline field; (3) hashes terrain
per chunk on the `ThreadSystem` with an ordered combine, identical serial or
threaded, with cost following content; (4) stays an allocation-free,
same-build oracle. This slice also owns `normalizeDerivedState` (derived
state rebuilt to equal a fresh init) and the single `buildFingerprint()`.

### Current foundation

- 49 (spec, not live) provides `StateHasher` with raw-bytes floats, checksum
  v1 over `DataSystem`, `WorldSystem`, player, seed, and step, comptime
  completeness lists, and the `simulation-checksum` bench. 50 makes owner-thread
  `parallelFor` safe; 64A makes pause simulation-invisible, so no field needs a
  pause exemption.
- Live carried history outside `DataSystem`/`WorldSystem`
  (`simulation_pipeline.zig` and its subsystems): `interact_held_last`;
  `SensoryBus` deferred and sticky stimuli (storage `undefined` past their
  counts); `DigController` latches and `player_last_cell`; `AiSystem`'s
  snapped goal; `SteeringSystem.runtime_rows` (per-entity history);
  `PathfindingSystem` request queues, result cache with TTL eviction, group
  fields, and the nav graph; perception's LOS cache; steering obstacle and
  movement-index caches; tuners, scratch, and the audio controller.
- Terrain is one flat dense-tile list per world today; 64G moves it to
  chunk-owned storage, so the chunk is the hashing unit.
- `PerceptionSystem.markLevelDirty` appends to a per-level `pending_dirty`
  list on every edit and clears it only when an observer next builds that
  level, so a level no observer visits grows it without bound.

### Architecture notes

- Owner direction: the checksum covers every world instance and all
  simulated state, including far-simulation state. Slices 73, 74, and 75
  land first and take their own tag bumps (Table T6); this slice's sections
  and completeness checks cover their fields.
- NaN: the simulation never observes NaN sign or payload (64A select forms and
  key bits), while those bits differ across platforms and folding, so the
  hasher canonicalizes NaN, keeps ±0 and ±inf distinct, and counts replaced
  values; the hasher stays total (no panic), and callers fail on a nonzero
  count (harness, 64C runner, 52C soak). NaN-free columns hash as raw bytes.
  Vector NaN primitives live in `core/simd.zig`.
- Terrain hashes per chunk on the thread system; serial equals threaded
  (`.claude/rules/threading.md`); nothing is sized to level area or world
  extent (`.claude/rules/budgets-capacities.md`); no allocation; owner thread
  only. Tag is live + 1 (Table T6).
- `buildFingerprint()` (app version, Zig version, checksum tag) is the only
  build fingerprint; consumers are 46's save header and 64C's replay header.
  Adds the `app_version` build option if 52B has not.
- Every field of `SimulationPipeline` and each subsystem holding hashed
  state is classified hashed (saved verbatim by 46), normalized (rebuilt by
  `normalizeDerivedState`), cache (output-transparent), or excluded; an
  unclassified or doubly classified field fails the build.
- Classification decisions: input and dig latches, sensory stimuli, the AI
  snapped goal, steering runtime rows, and any seam-raised ceiling that changes
  request intake are hashed. All derived nav state (graph, path requests and
  results, caches, group fields, dirty sets, any deferred rebuild) is
  normalized, not cache, because cache warmth changes outcomes. Derived
  perception state is normalized.
- `normalizeDerivedState`: afterwards every normalized field equals a freshly
  initialized pipeline's over the same `DataSystem`, `WorldSystem`, and config,
  with derived nav rebuilt from 64G's chunk storage. It is the load-parity
  reference; saves never call it on the live session, so a save is invisible
  to the continuing session. Callers: load-parity tests, the harness, and
  deferred-nav abandonment (65B).
- Derived perception state is rebuilt by `normalizeDerivedState` from 64G's
  chunk-owned LOS state; no per-level dirty list or level-wide rebuild
  remains.

### Checklist

- [ ] NaN-mask and any-true primitives in `core/simd.zig` with scalar parity
      across lane positions.
- [ ] `StateHasher` NaN canonicalization and count, struct recursion over
      float leaves; tests for NaN payload equality, distinct ±0 and ±inf,
      raw-byte equality of NaN-free columns, staging-boundary positions.
- [ ] Checksum v2: tag, sectioned digests, ordered combine, per-chunk terrain
      rounds on the thread system with serial fallback, value-plus-NaN-count
      report, `simulationChecksumReport`, `buildFingerprint()`; tests:
      serial == threaded, a change in the first or last chunk changes the
      value, round size does not, `FailingAllocator` with a real multi-worker
      `ThreadSystem` allocates nothing, the fingerprint tracks the tag.
- [ ] Class lists and comptime completeness on `SimulationPipeline` and every
      subsystem with hashed state, and the `"pipeline_history"` section; tests
      that each hashed field changes the value and storage past live counts,
      cache, and tuner fields do not.
- [ ] Derived perception state normalized; test that it equals fresh init
      after a multi-chunk change.
- [ ] `normalizeDerivedState` over derived nav and the pipeline; tests:
      normalized equals fresh init after requests, cached paths, a building
      group field, a runtime ramp, and a multi-chunk change; normalized
      pipelines step identically; path-cache state changes outcomes;
      solve-budget consumption depends on cache state.
- [ ] Harness traces assert a zero NaN count every step; checksum tests use
      this slice's tag.
- [ ] `simulation-checksum` gains a threaded case; the fixture asserts serial
      == threaded.
- [ ] Docs: Determinism Contract (v2 sections, chunk hashing, combine, NaN,
      classes, normalization); `docs/architecture.md` Gameplay Data; DW bench
      case.
- [ ] Rule additions when this lands: checksum field classification and
      normalized saves (`.claude/rules/simulation.md`); normalize completeness
      (`.claude/rules/pathfinding.md`).

### Acceptance checks

- [ ] `zig build verify` passes; Checklist tests pass in Debug and
      ReleaseFast.
- [ ] 49's repeat, partition, and seed traces hold under v2 with zero NaN.
- [ ] An unclassified new pipeline or subsystem field fails compilation
      (temporary, uncommitted edit).
- [ ] `zig build -Doptimize=ReleaseFast bench -- --group simulation-checksum
      --details`: cost grows linearly with hashed state across at least three
      sizes (level size, depth, population), the threaded case is at or below
      serial, and serial shows no regression beyond spread against 49's v1
      (`.claude/rules/tests-benchmarks.md`).
