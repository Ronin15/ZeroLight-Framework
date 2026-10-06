## Slice 24B: Render Collect Hardening

**Status: landed.** All Checklist and Acceptance checks below are `[x]`.

Goal: harden dynamic entity render prep for scale — movement-index collect and
camera-only visibility gates — without conflating simulation LOD with render
policy or moving SDL_GPU submission into the pipeline.

Problem (observed at `render-game-prep` stress scales):

- `collectDynamicRecords` iterated `primitiveVisualSliceConst().entities` and
  called `renderEntityComponentIndices` per row — an `EntityId → slot` resolve on
  every visual even when chunk/AABB cull skipped append.
- An early draft gated render on `SimulationTier` (`allowsRender`), which blended
  sim LOD with draw policy. Render visibility must be camera-only; sim tier
  controls processor participation only.

Architecture notes:

- **Movement-body dense rows are the collect anchor.** Scope columns align on
  `movement_index`; a dense `has_primitive_visual` flag skips movement-only rows
  before slot resolve; `renderCollectIndicesForMovement` performs one slot read per
  chunk-pass row that carries a primitive visual. Scope columns are simulation
  inputs only — render collect does not read tier or pin metadata.
- **Render visibility is camera policy only.** `entityVisibleForRenderCollect`
  uses `WorldSystem.visibleChunkRegion()`; every drawable row then passes
  `VisibleWorldRect.overlapsAabb`. No render bypasses on scope metadata.
- **Dense floors are a separate axis.** In-window layers submit one full-world
  tilemap quad each (Slice 23B); GPU clips to the viewport. Per-entity depth
  cull (25E) is separate from the dense-floor window.

Checklist:

- [x] Add `RenderCollectIndices` and `renderCollectIndicesForMovement` on
      `DataSystem`.
- [x] Walk `movementBodySliceConst().entities` in `collectDynamicRecords`.
- [x] Camera-only `entityVisibleForRenderCollect` (chunk) + AABB for all entities.
- [x] Remove `SimulationTier.allowsRender`; sim tier does not gate draw.
- [x] Headless tests: sim tier does not affect collect; movement-index resolve.

Acceptance checks:

- [x] On-screen entities collect regardless of sim tier; off-screen entities
      (including player) skip before interpolation.
- [x] `zig build test` covers camera gates and movement-index collect helpers.
- [x] `zig build verify` passes.

**Status: landed.** Render-scale follow-up without a new slice number is backlog
in **Scaling Gaps And Hardening Frontier** until promoted to a slice Checklist.


