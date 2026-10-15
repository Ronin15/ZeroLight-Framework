## Slice 13: Spatial Queries And Collision Contacts

Goal: add data-oriented spatial query and collision contact foundations that can
feed gameplay response systems without turning hot loops into per-entity object
dispatch.

Current foundation:

- `DataSystem` has entity IDs, component masks, movement bodies, primitive
  visual intent, dedicated collision bounds, and aligned movement SoA columns.
- `MovementSystem` updates positions deterministically before later processors
  read them.
- Slice 12 provides the event/deferred-command boundary needed for collision
  outcomes that create, remove, or change entities.

Architecture notes:

- `CollisionSystem` owns warmed transient AABB proxy scratch, not persistent
  gameplay data.
- The first broadphase is sweep-and-prune over entities with both movement bodies
  and collision bounds. It threads sorted anchor ranges, uses SIMD overlap
  filtering, and emits range-owned candidate pairs once before deterministic
  merge.
- Narrowphase is a separate threaded batch: worker ranges SIMD-compute contact
  math over candidate pairs, then merge range-owned contact buffers
  deterministically for the same-step response stream.
- Thread-written broadphase and narrowphase range scratch is 64-byte padded;
  persistent collision component storage remains dense and unpadded by default.
- Broadphase and narrowphase keep separate adaptive tuners and batch stats; no
  combined timing trains either stage. Inline stage measurements still train the
  owning stage tuner, so a later expensive window can switch that stage to
  worker threads without borrowing another stage's profile.
- Collision response stays separate from detection; `CollisionResponseSystem`
  consumes the completed same-step contact stream through explicit
  response-policy components before structural commands commit.

Checklist:

- [x] Add persistent collision-shape or bounds data in `DataSystem` only for
      world objects that need collision or spatial queries.
- [x] Add a deterministic broadphase/spatial-query structure appropriate for the
      current 2D scale.
- [x] Add a contact output buffer and response processor boundary.
- [x] Add tests for stable contact ordering, stale entity rejection, and serial
      versus threaded query behavior where threading is used.
- [x] Add non-interactive collision benchmarks with quick-profile dense/sparse
      regression coverage, heavier 10k-50k standard-profile sweeps, and
      candidate/contact counters.

Acceptance checks:

- [x] Collision queries operate from typed SoA data and stable IDs, not object
      callbacks.
- [x] Contact generation is deterministic for the same initial data and fixed
      update step.
- [x] Collision response cannot perform unsafe structural mutation inside worker
      ranges.

Slice 13 landed as a high-throughput collision-contact foundation. The collision
processor builds 64-byte-aligned AABB proxies from movement and collision bounds,
maintains warm sorted order, partitions sweep-and-prune work into deterministic
range windows, and emits transient contacts through `SimulationFrame`. The
response processor consumes the completed same-step contact stream through
`collision_response` components, keeps trigger output in a typed transient
stream, computes correction columns with `src/core/simd.zig`, and applies sparse
movement writes in deterministic contact order before structural commands
commit. The demo uses the same generic response path for player-obstacle,
moving-square-obstacle, and player-moving-square contacts. Detector benchmarks
report candidate pairs and contacts for dense/sparse body workloads, while
response benchmarks report triggers and intents across 1k-50k contact workloads.

