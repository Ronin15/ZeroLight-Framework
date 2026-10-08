## Slice 69F: Chunk Storage Forms For Large Worlds

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 64G](slice-64g.md), [Slice 58](slice-58.md), [Slice 46](slice-46.md), [Slice 74](slice-74.md), [Slice 75](slice-75.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started — gated** on a game whose worlds, at their design
extent, depth, and count, cannot hold every chunk in its expanded form within
the target platform's memory (measured with the 64G `chunk-scale` and
`footprint-*` benches at that game's world configuration).

Goal: a world's chunks can live in more than one storage form (for example
expanded, compact, or regenerable-from-seed for chunks no edit has touched),
chosen by activity and distance from the observer, so world memory follows what
is active and edited while every chunk in every form keeps simulating: agents
path across it, items on it decay, and population on it advances. Residency
is a storage form only; nothing leaves the simulation, and the simulation's
results never depend on a chunk's form.

### Current foundation

- Terrain and nav are per-level flat arrays and per-level graphs today
  (`WorldSystem` `dense_tile_ids`, `NavGrid`, `NavLevelGraph`); 64G replaces
  them with chunk-owned storage, a per-level chunk directory, and per-chunk
  render upload; storage forms are this slice's.
- Positions are absolute world `f32` coordinates in every position column,
  path cache, marker, anchor, and node index; level dimensions are `u16`.
- Slice 58 (not landed) makes terrain a pure function of seed, spec, and cell,
  so an unedited chunk can be regenerated exactly.

### Architecture notes

- Owner direction: residency is a chunk's storage form, never whether it
  simulates; nothing is evicted from the simulation; worlds are created and
  destroyed in play (`.claude/rules/engine-design.md` § Target scale).
- A level's size is fixed at creation; this slice does not make worlds grow
  or stream new territory (`.claude/rules/budgets-capacities.md`). World
  extent is bounded only by coordinate and index widths, checked loudly at
  world creation.
- Every form answers the terrain and nav queries simulation needs; a form
  change costs the chunk changed, never the level or world, and runs at a
  named seam (main-thread commit or a designed deferred boundary; I/O off
  the step path) (`.claude/rules/threading.md`).
- Form choice reads only fixed-step state (the observer's `sim_view`, chunk
  activity), never the render window or wall clock; same seed and inputs
  give bit-identical persistent state for any form history
  (`.claude/rules/simulation.md` § Determinism).
- Needs: 64G's chunk storage and per-chunk render upload; 58's pure
  generator for regenerable forms; 46's per-chunk terrain save (every
  chunk); 74's world lifetime; 75's distance-from-observer fidelity.
- Saving only edited chunks, with pristine chunks regenerated, is this
  slice's optimization over 46's all-chunk save.
- Rejected (owner direction): a single resident region with frozen,
  unsimulated regions behind loading seams.

### Checklist

- [ ] Chunk storage forms and the transitions between them, each costing the
      chunk changed.
- [ ] Form selection from fixed-step activity and observer distance, under a
      fixed per-step count with deterministic deferral.
- [ ] Simulation queries (terrain, nav, perception, items) answer the same in
      every form.
- [ ] Regenerable form for unedited chunks backed by the 58 generator; edited
      chunks always keep their edits.
- [ ] Saves store only edited chunks; pristine chunks regenerate on load;
      edits survive in any form (extends 46).
- [ ] Coordinate and index width checks at world creation.
- [ ] Docs: `docs/architecture.md` (chunk storage forms, residency as
      storage only).

### Acceptance checks

- [ ] A run with forced form changes every step gives the same
      `simulationChecksum()` trace as a run with every chunk expanded.
- [ ] An agent paths across, and an item decays on, a chunk in each form.
- [ ] Form-change cost is flat across world sizes and depths (`chunk-scale`
      style bench at three sizes); memory follows active and edited chunks.
- [ ] A regenerated unedited chunk is bit-identical to its generation.
- [ ] `FailingAllocator`: an OOM during a form change leaves the chunk in
      its prior form and simulation intact.
- [ ] `zig build verify` passes.
