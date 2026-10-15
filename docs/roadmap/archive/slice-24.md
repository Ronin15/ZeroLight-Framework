## Slice 24: Scoped Simulation Tiers And Chunk Policy

Goal: turn the Slice 22 scaffolding into real scoped simulation behavior after
Slice 23 provides world/chunk/visibility inputs.

Readiness: the foundation for this slice is fully present (Slices 22/23/21);
what remains is wiring. The six checklist items below are the concrete gaps
between the current full-active pipeline and real scoped behavior.

> Historical pre-implementation assessment (2026-06-28, superseded by the
> **Status** below): at the time, `allowsMovement`/`allowsCollision`/
> `allowsCognition` were confirmed never consulted in `SimulationPipeline.update`,
> so every entity paid full pipeline cost every step regardless of tier. That gap
> is closed — see **Status** and **Implementation decisions** below for the
> landed `SimulationScopeSystem` gating.

Current foundation (present — do not rebuild):

- `SimulationTier` enum with capability predicates `allowsMovement`,
  `allowsCollision`, `allowsCognition` (`simulation_scope.zig`).
- Per-entity cold metadata `EntitySimulationMetadata { tier, chunk }` on
  `EntitySlot.simulation`, with `simulationMetadata`/`setSimulationMetadata`
  accessors and a `simulationScopeStatsFullActive()` tally (`data_system.zig`).
- `ActiveRegion` half-open chunk rectangle with `containsChunk()`, and
  `SimulationScope { active_region: ?ActiveRegion, stats }` plus per-tier and
  per-stage `SimulationScopeStats` (`simulation_scope.zig`).
- `WorldSystem` maintains `chunk_visible[]`, chunk coordinate columns, and
  `setVisibleChunksForWorldRect` / `chunkCoordForCell` (`world_system.zig`).
- (Pre-implementation state, now superseded by **Status** below) the pipeline
  used to run full-active unconditionally: `SimulationPipeline.update` built
  `SimulationScope.fullActive(...)` and dispatched every stage over the full
  component slices.

Status: implemented (2026-06-28). The backbone owner is
`SimulationScopeSystem` (`src/game/systems/simulation_scope.zig`), a pipeline-owned
system alongside movement/collision/ai/steering. It owns step/stagger state, the
scoped gathers, and the tier policy. Each O(N)-per-step pass threads like the other
processors and owns its own `AdaptiveWorkTuner`: the three gathers (movement,
collision, AI) are stream-compactions (per-range index buffers merged in scan
order), and the tier policy is a variable-output producer (per-range command
buffers merged into the frame's structural-command stream via the append protocol).
Threaded and serial produce identical results, and each pass exposes a `*Serial`
variant for the serial bench/test path.

Implementation decisions that diverged from the original sketch (code is
authoritative):

- Scope metadata moved off `EntitySlot` into **dense columns on the movement-body
  store** (`tier`, `chunk_x/y`, `stagger_phase`, `always_active`), in lockstep with
  the movement rows. The O(N)-per-step passes (chunk recompute, movement gather,
  tier policy) are aligned SoA scans/writes with no per-entity slot resolve. Scope
  metadata therefore exists exactly for entities with a movement body.
- Movement and collision gate on **tier only, no chunk filter** — off-screen
  entities keep moving and colliding. Their gathers short-circuit to full-active in
  O(1) via incremental `tier_counts` when no `dormant`/`kinematic` entity exists
  (the common frame), so the per-step scope cost scales with active scope.
- The cognition halo is derived from the **camera's visible chunks**
  (`WorldSystem.cognitionActiveRegion`), not a gameplay anchor position. AI gates
  on `cognition tier AND chunk-in-halo AND stagger phase`; scope pin metadata
  bypasses halo and stagger. With no visibility window yet, the gather falls back
  to full-active (no halo/stagger).
- **Steering is transitively scoped**: it acts only on the navigation intents AI
  emits, so gating AI gates steering without a second index list. Its avoidance
  spatial grid stays full so in-scope agents still avoid out-of-scope neighbors.
- **Simulation-LOD tier policy** (`collectChunkTierChanges`) assigns every entity
  the tier for its **cube (L∞) distance** from the **visible region**
  (`ActiveRegion.lodDistance` → `tierForChunkDistance`): `cognition` (≤
  `cognition_halo_chunks`) → `locomotion` (≤ `locomotion_halo_chunks`) → `kinematic`
  (≤ `kinematic_halo_chunks`) → `dormant` (beyond). So near entities think, far
  entities sleep — all four tiers are produced by distance, not just the cognition
  band. Scope pin metadata skips automatic tier demotion. It emits deferred
  `set_simulation_tier` structural commands appended to the frame stream for the
  state's commit seam (no tier mutation inside worker ranges), and reserves its
  command buffer up front so the per-step path is allocation-free even on a frame
  where many entities cross a band.
- **3D cube LOD (depth/level axis)**. The LOD volume is an L∞ ball over
  `(chunk_x, chunk_y, level)`, not a flat 2D ring: `ActiveRegion.lodDistance` takes
  the chebyshev chunk distance but floors it by a per-level penalty
  (`level_distance_chunks`, one band per level) against the region's `level` (set by
  the pipeline from the camera/player level). So an entity on a far depth/level
  reads as far regardless of its x/y and demotes out of cognition. The per-entity
  `level` rides as a dense scope column beside `tier`/`chunk_x/y`. Single-floor
  content defaults level to 0; the machinery supports multi-level worlds. The AI
  halo gate stays 2D (`containsChunk`); off-level entities are excluded purely
  through the tier the cube policy assigns them.

Checklist (done):

- [x] Public `WorldSystem.visibleChunkRegion()` and `cognitionActiveRegion(halo)`
      expose the camera chunks (+halo) as an `ActiveRegion`.
- [x] Entity chunk columns are derived in-pass by the movement processor from each
      integrated body's settled position (`movement.ChunkGridParams`), so there is no
      separate recompute pass; the scope gathers read the chunk columns movement wrote.
- [x] Scoped gather entry points for movement, collision, and AI (steering
      transitive). Processors keep their hot loops and take a `scope_dense_indices`
      option; null = full-active.
- [x] Per-entity `stagger_phase` (cold dense column) drives a 1-in-N cognition
      cadence inside the halo; skips counted in scope stats.
- [x] Tier promotions/demotions routed through deferred structural commands at the
      commit seam; no worker-range tier mutation.
- [x] Scope stats expose per-tier, per-stage, `stagger_skips`, and
      `chunk_filtered_entities` counts via `runtime_perf_log` and the demo state.

Acceptance checks:

- [x] Scoped and full-active processor paths produce identical outputs for the same
      entity subset (gather index path mirrors the full path).
- [x] Tier/chunk filtering changes stage participation without changing stage order
      or `SimulationFrame` stream contracts.
- [x] Chunk metadata stays consistent with position after movement; scope counts
      match entities actually processed per stage.
- [x] Tier changes mutate `DataSystem` only through the deferred command commit.
- [x] `zig build test` covers gathers, tier gates, stagger, tier-command commit,
      and pipeline phase transitions without opening a window.
- [x] Debug stats report active scope counts so typical runs stay far below 50k
      stress scales by policy.

Known limitations / follow-up: see **Scaling Gaps And Hardening Frontier**
(simulation scale — movement contiguous-path vs scoped LOD).


