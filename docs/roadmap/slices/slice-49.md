## Slice 49: Session Seed And Determinism Checksum Harness

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 64G](slice-64g.md) (the checksum walks chunk-owned terrain) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: in progress.** Render→sim scope decoupling landed; seed, `StepIndex`,
checksum, harness, bench, and docs are open.

Goal: every session runs from one explicit seed root, and every simulation
random stream derives from it through a registered domain. A same-build
checksum covers all simulated state of every world instance the session
holds. `zig build test` proves headlessly that repeat runs, any worker count,
range size, or inline/threaded execution give bit-identical per-step state
for a pinned input script, and a seed change changes it. Simulation scope
never depends on render timing. Slices 46, 51, 52C, 64B, 64C, and every seeded gameplay slice build on
these outcomes.

### Current foundation

- `core/rng.zig` `mix64(seed, entity_index, step, salt)` is a stateless keyed
  mixer; `uniformF32`, `boundedU32`, and `unitVec2` build on it and are already
  partition-independent (archive Slice 27). Its only consumer is AI wander,
  with the seed hard-coded as `.intent_seed = 0xfeedf00d` in
  `simulation_pipeline.zig` and the step from
  `SimulationScopeSystem.currentStep()` (`systems/simulation_scope.zig`,
  `step_count: u32`).
- Worldgen seeds from the literal default `WorldBuildConfig.seed`
  (`world_system.zig`).
- Session entry: `MainMenuState` → `LoadingState.init` → `loadGameDemo` →
  `GameDemoState.initProceduralWithRuntimeAssets` → `initWithWorld` →
  `SimulationPipeline.init`. One world per session today.
- No production checksum exists; `aiStateHash` in
  `ai_debug_overlay.zig` is a test-local precedent.
- The simulation reads gameplay input only through `InputState` (held actions
  plus the raw left stick); the 8 gameplay actions are those
  `isGameplayAction` accepts. `FrameCommands` never reach the simulation.
- `RangeOutputStream` merges in range order. Design-time audit: no
  `@setFloatMode`, `@mulAdd`, wall-clock read, or atomic in simulation paths.
- Processor configs carry `items_per_range`, `max_worker_threads`, and
  `adaptive`; `ThreadSystemConfig` has no system-wide adaptive switch, and the
  tuner keeps small batches inline, so a small fixture never threads unless
  pinned.
- `GameDemoState.onPause`/`onResume` call `syncInterpolatedState`, which
  overwrites `previous_x/previous_y` and the camera the simulation reads, so a
  paused run diverges from an unpaused one (Slice 64A makes pause
  simulation-invisible).
- `math.sinCos` lowers to `sinf`/`cosf`: static compiler-rt copies on
  Linux/Windows, Apple libSystem at runtime on macOS (Slice 52D replaces it).
- Landed: `SimulationPipelineUpdateContext.sim_view`,
  `GameDemoState.simViewRect()`, `simViewRegion`,
  `WorldSystem.chunkRegionForWorldRect` / `cognitionRegionForWorldRect`; no
  simulation path reads `visibleChunkRegion`.

### Architecture notes

- Owner direction: worlds are fully simulated and several exist in play. The
  checksum covers every world instance and all simulated state,
  including far-simulation state; [Slice 74](slice-74.md) (world instances)
  and [Slice 75](slice-75.md) (far simulation) classify their state under this
  slice's completeness checks when they land
  (`.claude/rules/engine-design.md` § Target scale).
- Determinism guarantee and inputs: `.claude/rules/simulation.md` §
  Determinism. Scope pinned here: same executable (target, CPU features,
  toolchain, runtime libm), same seed root and initial state, same per-step
  input. No multiplayer is planned (owner decision 2026-10-14), so the
  guarantee stays within one executable; 52D, 64A, 64B, and 64D close the
  hazards that would let a thread split change a result.
- Seeds: one root per session, received at state init; each domain derives
  once at init, never per step and never from fresh entropy (per-world seeds
  in 74 derive from the root). The `SeedDomain` registry is append-only with
  pinned values (track shared contracts). Named exemptions: presentation-only
  streams and fixed load-spread schedule hashes. The default session keeps a
  fixed default root; a random New Game root is 64C.
- Checksum: a same-build equality oracle, never a persisted identifier;
  compared across files only when build fingerprints match (64B owns the
  fingerprint). Cold paths only (tests, save round trip),
  never the frame loop; no allocator. Every `DataSystem` and `WorldSystem`
  field is classified hashed or excluded at comptime, so a new field fails to
  build until classified (index Ground Rules pair it with a 46 save section).
  Undefined or dead storage is never hashed; allocation history that changes
  future outcomes (marker generation reuse) is. Terrain hashes through 64G's
  chunk storage, so cost follows content, not level area.
- No replay (owner decision 2026-10-14): the harness drives the input script
  directly; nothing records, encodes, or replays session input.
- `StepIndex = u64` lands here (decision: no `u32` session end); rng step keys
  truncate to `u32` (repeats every 2^32 steps, harmless).
- No new `StageId` or `PipelineResource`; `sim_view` is a borrowed
  update-context input. `ThreadSystemConfig.adaptive` defaults on, so
  production is unchanged; Slice 50 edits the same file.
- Out of scope: the random New Game root (64C), deterministic trig (52D, 64D), pipeline history in the checksum (64B).
- VoidLight: nothing structural to port; do not port its `thread_local
  std::mt19937` wander RNG seeded from hardware entropy.

### Checklist

- [x] Render→sim decoupling: `chunkRegionForWorldRect` /
      `cognitionRegionForWorldRect`, required `sim_view`, `simViewRegion`,
      migrated window tests, render-window independence test.
- [ ] `StepIndex = u64` step counter and `stepKey` truncation for rng keys;
      internal wrapping cache clocks stay as they are, commented.
- [ ] `rng.deriveSubSeed`, `SimulationSeed`, and `SeedDomain` (`ai_wander`,
      `worldgen_procedural`), with determinism, domain/root separation,
      pinned-value, and golden tests.
- [ ] Seed plumbing from the menu through `LoadingState` and `GameDemoState`
      to the pipeline; the hard-coded wander seed and worldgen literal become
      derived seeds.
- [ ] `core/state_hash.zig` `StateHasher`: comptime fold rules (an unfoldable
      column type fails to build), section separation, split-invariant
      streaming, no allocator; tests.
- [ ] Checksum over seed, step, `DataSystem`, `WorldSystem` (chunk-owned
      terrain), and player for every world instance, with comptime
      completeness on both systems; tests that each store, a dig, and marker
      churn change it and render visibility does not.
- [ ] `GameDemoState.simulationChecksum()`.
- [ ] `ThreadSystemConfig.adaptive` with a test that non-adaptive batches pin
      range size and workers and leave the tuner untouched.
- [ ] Determinism harness in `game_demo_state.zig` with a pinned input script:
      repeat, worker-count/range-split (serial, inline, multi-worker, pinned and
      adaptive) and seed-change tests.
- [ ] `simulation-checksum` bench over hashed-state size (level size, depth,
      population).
- [ ] Docs: "Determinism Contract" in `docs/simulation-tiers-and-pipeline.md`;
      `docs/architecture.md` ownership lines; DW test and bench names.
- [ ] Rule additions when this lands: determinism contract scope, seed-domain
      registry, checksum classification and persistence, `StepIndex` (`.claude/rules/simulation.md`); SIMD/scalar bit
      identity (`.claude/rules/memory-performance.md`).

### Acceptance checks

- [ ] Every Checklist test passes under `zig build test`.
- [ ] Serial repeats and every thread configuration give identical per-step
      traces; a different seed changes the final checksum; any
      partition-dependent processor found is fixed in its owning module with
      its own parity test, never by weakening the harness.
- [x] The render-window independence test passes; no simulation path reads
      `visibleChunkRegion`.
- [ ] The checksum takes no allocator.
- [ ] `zig build -Doptimize=ReleaseFast bench -- --group simulation-checksum
      --details` shows cost linear in hashed state across at least three sizes
      (`.claude/rules/tests-benchmarks.md`); 64B's gate supersedes it.
- [ ] Docs updated; `zig build verify` passes.
