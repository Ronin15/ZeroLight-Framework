## Slice 28: Shared Spatial Index Service

**Status: landed.** All Checklist and Acceptance checks below are `[x]`.

Goal: build one frame-level spatial index consumed by AI separation and
perception instead of each system building its own grid.

Current foundation:

- AI separation built a deterministic 32-unit grid each step
  (`systems/ai.zig`); Perception (Slice 29) would have added a second.

**Deviation from the original checklist wording:** the original draft asked to
port "AI separation *and collision broadphase*" onto one shared grid. Collision
broadphase does not actually build a grid — it runs sweep-and-prune (SAP) on a
`min_x`-sorted `order` array (`src/game/systems/collision.zig`), with a warm
incremental insertion-sort (`sortWarm`/`full_sort_disorder_percent`) that
exploits frame-to-frame temporal coherence, plus SIMD Y-overlap filtering.
That is a different, already-tuned algorithm, not a duplicate grid build.
Forcing collision onto a per-step-rebuilt uniform grid would risk regressing
that incremental-sort win and would require reproducing SAP's exact
candidate-pair order to satisfy this slice's own parity gate. **Decision: build
the shared index for AI separation (this slice) and Perception (Slice 29, the
actual driver). Collision stays on SAP, untouched.**

Architecture notes:

- Built once per fixed step by the pipeline-owned `SpatialIndexSystem`
  (`src/game/systems/spatial_index.zig`), from the same cognition-scoped
  population `AiSystem` already gathers (`scope_dense_indices`); workers read
  the resulting `SpatialIndexView` immutably. AI separation's ported output
  matches the pre-refactor per-step grid exactly (parity-tested, including an
  O(n²) brute-force bit-for-bit proof plus a second cross-cell oracle that
  independently reconstructs the cell_y-outer/cell_x-inner/ascending-index
  traversal spec, since float-summation order only becomes observable once a
  population spans multiple cells), not just approximately.

Checklist:

- [x] Add a frame-built spatial hash/grid owned at the pipeline boundary, sized
      from reserved capacity, rebuilt per step, read-only to workers.
- [x] Port AI separation to consume it; remove the duplicate grid build.
      Collision keeps its own tuned SAP broadphase by design (see the
      Deviation note above) — porting it is a future benchmarked-optional item,
      not this slice's requirement.
- [x] Expose a bounded neighbor-query API (max samples / radius) reusable by
      perception.

Acceptance checks:

- [x] Separation outputs are identical to the pre-refactor results (parity
      tests, including a single-cell brute-force bit-for-bit proof and a
      multi-cell cross-cell-order oracle proof).
- [x] Index build and queries are allocation-free after warmup and deterministic
      (serial == threaded).
- [x] `zig build bench` shows no regression from removing the redundant grid
      build — the `ai` group's timed window now excludes the build (its own
      `spatial_index` bench group times that separately), so per-step
      `separation_checks` are unchanged and measured throughput improved.


