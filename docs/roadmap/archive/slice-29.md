## Slice 29: AI Perception Substrate

**Status: landed** — vision (including the LOS cost-risk fix) and hearing are
both in place. `AiPerception` (`data_system/perception.zig`), `PerceptionSystem`
(`systems/perception.zig`), the `entity_perceived`/`entity_lost` event
contract, and the `perception`/`perception-los-dense` benchmark groups are all
in place with full test coverage: range/FOV/LOS gating, faction-stance
gating, same-level gating, player-as-candidate, all four transition shapes
(acquire/lose/hold/identity-swap), the per-step event cap with drop
diagnostics, serial/threaded parity, and a `FailingAllocator` steady-state
allocation-free proof. The squared-form FOV test
(`dot(facing, to) > 0 AND dot^2 > cos_half_fov^2 * dist2`) turned out not to
need the vector sin/cos polynomial Slice 34 deferred here — no production
caller for `simd.sinFloat4`/`cosFloat4`/`sinCosFloat4` was added, since a
unit-length facing vector makes the squared dot-product compare exact without
any per-frame trig.

**Hearing (closes this slice):** `AiPerception` gained a cold `hearing_range`
tunable and hot `heard_stimulus`/`heard_stimulus_x/y` columns
(`data_system/types.zig`, `data_system/perception.zig`), following the same
cold/hot split and `PerceptionStore.set`-preserves-hot-columns contract as
vision. `SimulationFrame` gained `stimuli: RangeOutputStream(WorldStimulus)`
(`simulation.zig`) — a transient per-step positional buffer
(`position`/`intensity`/`kind`/`level`, scalar-only), cleared every
`beginStep` and never promoted to a `SimulationEvent`, since it carries no
stable entity identity to transition against (only state *transitions*
become events, per the track-wide contract above). `intensity` is stored but
unused until a second producer exists to calibrate a falloff curve.
`DigController.process` is the sole producer today (`dig_controller.zig`),
appending one stimulus alongside its existing `world_tile_changed` event; its
sibling `carveLandingCell` (the fall/landing path) deliberately does not,
since it runs after `PerceptionSystem.update` in the same fixed step and
would be cleared before any hearing pass could read it — documented in place
rather than silently wired up wrong. Hearing is folded into
`PerceptionSystem.computeOneAgent` as a squared-distance range check gated by
same-level only (no FOV, no faction-stance gate — a stimulus is positional
and factionless), reading `frame.stimuli.mergedItems()` through a
`PerceptionConfig.stimuli` field. The stream itself needs no reserve call
from any owning module: its per-step count is a fixed producer invariant (at
most one, from `dig.process`), not scene-scale-dependent, so it grows lazily
on first use exactly like `PerceptionSystem`'s own gather buffers already do.
Tests cover range/level gating, nearest-of-multiple selection, hot-column
round-trip and preservation-on-retune, serial/threaded parity, and
`FailingAllocator` allocation-free proofs alongside vision's existing
coverage.

**LOS cost-risk fix (`hasLineOfSight`'s per-sample lookup is now O(1)):** this
slice originally shipped with `hasLineOfSight` calling
`WorldSystem.levelBlocksMovement` once per raycast sample, which linearly
rescans every sparse tile in the world on every call. `src/benchmarks/perception.zig`'s
`perception`/`perception-los-dense` groups proved this was a real hazard, not
theoretical: identical `sensed_count`/`los_checks`/`los_blocked`/
`nearest_threat_found_count` between the two fixtures, but the `-dense`
fixture (20,000 extra sparse tiles placed far outside any agent's path) paid
a 6.5x–10x wall-clock penalty purely from world-wide tile-count bulk.

The fix adds `PerceptionSystem.level_blocked`: a per-level, raw-world-tile-
granularity blocked bitmap (`LevelBlockedSlot`), built at most once per
distinct observer level per step by `ensureLevelBlockedCachesForObservers`/
`ensureLevelBlockedCache` (mirrors `pathfinding/nav_grid.zig`'s
`markWorldObstacles` shape — dense-band scan + sparse-tiles-filtered-to-level
pass — but with no nav-cell rect rasterization, since this bitmap is
tile-indexed 1:1). The build runs on the main thread before any range job is
dispatched; every worker range only ever reads the completed, per-step-stable
snapshot. `hasLineOfSight` now calls `lookupLevelBlocked` (an O(1) bitmap
read) per sample instead of `levelBlocksMovement`.

This slice deliberately did **not** reuse `pathfinding/nav_grid.zig`'s
already-resident, incrementally-maintained `NavGrid` (via
`NavGraph.grid(level)`), even though that would avoid a second structure.
Two independent findings ruled it out: (1) `NavGrid.blocked` is a strict
*superset* of `levelBlocksMovement`'s contract — it composes world obstacles
**OR** (on level 0 only) `DataSystem` static collision bodies
(`NavGrid.markStaticBodies`), so reusing it would silently occlude LOS behind
entities that `levelBlocksMovement` never blocks on, failing the parity test
by construction on any fixture with a level-0 static body not coincident with
a world tile; and (2) `NavGrid.cell_size` (32, set explicitly at
`rebuildStaticNavGrid`/`rebuildStaticNavGridWithWorld` call sites, e.g.
`game_demo_state.zig`'s `nav_cell_size = 32`) equals `WorldSystem.tile_size`
(also enforced to 32 at asset load, `world_tileset_meta.zig`'s
`required_tile_size`) only *incidentally* — two independently-set literals,
not an invariant enforced by an assert or a shared constant — so reuse would
also risk a silent LOS-granularity change if that ever drifted.
`NavGraph.grid(level)` is additionally nullable and only covers levels
pathfinding has actually built, which observers are not guaranteed to be
confined to. `PerceptionSystem` therefore owns its own cache, matching
`levelBlocksMovement`'s exact contract with zero cross-grid coordinate or
occlusion-set risk, proven by a dedicated parity test
(dense-blocked/sparse-blocked/open/out-of-range-level/out-of-range-cell, all
compared directly against `levelBlocksMovement`). The cache originally
rebuilt fully every step for every level touched that step (no
nav-invalidation-event-driven cross-step reuse) — a deliberate scope decision
at the time, not an oversight; see the residual note below, and the
incremental dirty-tracking fix that later replaced this (superseding the
residual note) further down this section.

Before/after (`--profile quick`, same methodology as this slice's original
risk-confirmation run), 10,000 agents, serial-direct: `perception` 33.60ms →
21.98ms; `perception-los-dense` 217.58ms → 25.74ms (was a 6.5x regression,
now 1.17x). Best-threaded case, 10,000 agents: `perception` ~6.24ms → 6.39ms
(unchanged, within run-to-run noise); `perception-los-dense` 25.81ms (over the
16.67ms/60Hz budget) → 9.64ms (`thread-small-range`, well under budget). Full
8-case tables at 1,024/4,096/10,000 agents for both groups are in this
change's PR/session record.

**Honest residual, not rounded away:** the two groups do not fully converge.
A fixed, non-scaling gap remains — measured best-case-threaded: ~2.99ms
(1,024 agents), ~2.89ms (4,096), ~3.25ms (10,000); serial-direct: ~2.63ms,
~3.27ms, ~3.76ms respectively. This gap is flat across a ~10x population
range (not proportional to agent count or `los_checks`, which are identical
between the two fixtures at every scale), which is itself the evidence the
per-sample lookup is genuinely O(1): the residual is entirely the once-per-step
cache-rebuild cost (a single O(world sparse-tile count) pass over the
`-dense` fixture's 20,000 extra tiles, paid once per step regardless of how
many agents or LOS samples run that step), not a per-sample or per-agent cost.
The realistic `perception` fixture shows no regression at all. Cross-step
caching (invalidating the bitmap only on an actual world-tile change, the same
way `PathfindingSystem` already reacts to nav-invalidation events) would
close this residual entirely but was deliberately deferred at the time — it
would touch the nav-invalidation event contract for a gap that only appears
in a fixture engineered specifically to be an unrealistic sparse-tile-density
torture test, not in any representative world density this project's other
benchmarks use. **This deferral is now superseded** — see "Incremental
dirty-tracked LOS-blocked cache" below, which implements exactly this and
closes the residual.

**Shared per-level sparse-tile index (root-cause fix behind the residual):**
after the LOS cost-risk fix above, a review pass found the *same*
scan-every-sparse-tile-then-filter-by-level pattern independently duplicated
in three places: `WorldSystem.levelBlocksMovement`, `NavGrid.markWorldObstacles`,
and `PerceptionSystem.ensureLevelBlockedCache` (added by this slice). Each
walked every `SparseTileRow` in the world checking `level_index` per tile,
even though a `SparseTileRow`'s level is fixed at insertion and never changes.
`WorldSystem` now carries a reverse per-level index —
`sparse_level_tiles: std.ArrayList(std.ArrayList(u32))`, one growable bucket of
`sparse_tiles` indices per level, plus the accessor
`sparseTileIndicesForLevel(level_index) []const u32` — maintained *eagerly*
inside `addSparseTile` (the sole inserter; tiles are never removed and never
reassigned to another level, confirmed by inspection) rather than lazily
rebuilt off a dirty flag. Eager maintenance was a deliberate deviation from
the `sparse_render_order`/`sparse_depth_ranges` render-index pattern this was
modeled after: that pattern's flat sorted-array-plus-ranges shape only stays
correct if rebuilt in full on every structural change, and `render_index_dirty`
is safely deferred only because its sole reader (`ensureRenderDepthIndex`) runs
once per render frame. `levelBlocksMovement`, `NavGrid.markWorldObstacles`, and
`PerceptionSystem.ensureLevelBlockedCache` do not have that luxury — they run
inside the fixed-step gameplay tick (nav reacting to a dig, perception
rebuilding its bitmap) and can be reached in the same step a sparse tile is
placed, before any render pass would run; a lazily-rebuilt index keyed off a
render-only dirty flag would have been stale for them. `sparse_level_tiles`
also cannot itself be shaped like `sparse_render_order` for the same reason:
keeping one level's run contiguous in a single flat array only works with a
full resort after every insert, which is exactly the O(n) rescan this index
exists to remove. All three consumers now iterate
`sparseTileIndicesForLevel(level)` instead of the whole `sparse_tiles` set.
Proof: a new `sparseTileIndicesForLevel` exact-set test (multiple levels,
interleaved insertion order, a level with zero sparse tiles, and an
out-of-range level) and a new `levelBlocksMovement` multi-level parity test
placing an obstacle on one level at a cell shared with two other levels
(`world_system.zig`); the existing `nav_graph.zig` incremental-update tests
(which compare `NavGrid`'s composed mask directly against
`levelBlocksMovement` cell-by-cell across every level of a multi-level demo
world) continued to pass unchanged, since the contract did not move, only the
scan did.

Measured effect on the `perception`/`perception-los-dense` gap (`--profile
quick`, same methodology as the numbers above): the `-dense` fixture's extra
20,000 sparse tiles all land on the *same single level* as the populated
region (`WorldSystem.initDemoFromMeta` never adds a second level), so this
fixture cannot exercise the index's intended cross-level win — the
scan-avoidance the three consumers now get on a genuinely multi-level world
(e.g. the underground stack `nav_graph.zig`'s tests build) does not apply
here. What the per-level index *did* remove from this single-level scan was
the redundant per-tile `sparseTileLevel(idx)` accessor call and its
`MultiArrayList.items(.level_index)` re-derivation on every one of the 20,000
tiles, replaced by one hoisted slice read up front. An isolated, same-session
A/B on identical 20,002-tile single-level data (30 back-to-back reps,
`world_system.zig`, removed after measurement) showed this specific loop drop
from ~784us/rebuild (old scan-and-filter) to ~45us/rebuild (new indexed
scan) — a ~17x reduction in the loop itself, with zero behavior change (both
loops agree on the blocked-tile count every rep).

At the full pipeline level, serial-direct, 10,000 agents: `perception` 22.74ms,
`perception-los-dense` 24.41ms — gap 1.67ms, versus the 3.76ms gap recorded
above before this fix. Note this "before" comes from this same slice's own
prior recorded numbers (above), not a controlled same-session revert of just
this change — the sandbox's revert-safety policy ruled out stashing the
working tree mid-task to get a stricter A/B, so the isolated loop measurement
below is the controlled proof for this specific change; the table comparison
against the prior recorded numbers is corroborating, not conclusive on its
own. Full table:

| agents | perception serial | los-dense serial | gap (was) | perception best-threaded | los-dense best-threaded | gap (was) |
|---|---|---|---|---|---|---|
| 1,024 | 3.42 ms | 5.43 ms | 2.01 ms (2.63 ms) | 2.24 ms | 4.13 ms | 1.89 ms (2.99 ms) |
| 4,096 | 9.89 ms | 11.76 ms | 1.87 ms (3.27 ms) | 3.77 ms | 5.61 ms | 1.84 ms (2.89 ms) |
| 10,000 | 22.74 ms | 24.41 ms | 1.67 ms (3.76 ms) | 6.49 ms | 8.34 ms | 1.85 ms (3.25 ms) |

**Honest, not rounded away:** the gap shrank meaningfully (24–56% serial,
36–43% threaded) but did **not** converge to indistinguishable, contrary to
this fix's original hypothesis (which assumed the `-dense` fixture's extra
tiles lived on a different level than the populated region — they do not).
The isolated loop measurement (~45us/rebuild) is far smaller than the
~1.7–2.0ms full-pipeline gap that remains; the difference is warm-vs-cold
cache, not an unaccounted cost: the isolated microbenchmark runs 30 reps
back-to-back, so the first rep warms the ~240KB working set (the u32 index
plus the gathered `cell_index`/`flags` columns) into L2, and every later rep
reads hot — but the real pipeline runs the rebuild exactly once per step,
sandwiched between thousands of agents' spatial queries and bitmap reads that
evict that working set, so every real rebuild pays a cold scan. A cold Debug
scan landing at ~1–1.6ms for ~240KB is plausible and consistent with the
observed residual. Closing it further (e.g. keeping the per-level working set
resident, or a spatial index within a level) is out of this task's scope,
which targeted the shared scan-and-filter duplication itself, not
cache-residency within a level. `pathfinding-hard-fallback` (which exercises
`levelBlocksMovement` directly via `simulation_pipeline.zig`'s local fallback
graph) was spot-checked at 64/128 item counts post-fix: all cases completed
with `fallback_requests == results` and no dropped/evicted requests, i.e. no
functional regression; no controlled before/after number exists for this
group specifically.

**Multi-level proof for `NavGrid.markWorldObstacles`, transitively:** no
dedicated multi-level-sparse `markWorldObstacles` test was added, but the
requirement is still covered by chaining existing tests rather than by a new
fixture: `sparseTileIndicesForLevel`'s exact-set test (above) proves the new
per-level index itself is correct across levels with interleaved insertion
order; both `markWorldObstacles` and `levelBlocksMovement` now read that same
index; and `nav_graph.zig`'s existing incremental-update tests compare
`NavGrid`'s composed blocked mask against `levelBlocksMovement` cell-by-cell
across every level of a multi-level demo world. That chain — not the
`nav_graph.zig` test alone, since both sides of that comparison changed
together and a consistent-but-wrong shared index would still pass it — is
what anchors correctness; the exact-set test and `levelBlocksMovement`'s own
hardcoded-value assertions are the load-bearing proof underneath it.

**Allocation and concurrency:** `sparseTileIndicesForLevel` and
`levelBlocksMovement` take no allocator, so they cannot allocate by
construction — reading the per-level index adds no new allocation risk on top
of `PerceptionSystem`'s existing `FailingAllocator` steady-state proof, which
already drives `ensureLevelBlockedCache`'s rebuild end to end. `sparse_level_tiles`
and its chunk-bucketed sibling `sparse_level_chunk_tiles` (see
`sparseTileIndicesForChunk`) are mutated only inside `addSparseTile`, a
main-thread structural edit; the threaded nav-remask and perception phases
only ever read them, so this adds no new concurrent-access hazard.
`addSparseTile` now reserves capacity in `sparse_tiles`, `sparse_level_tiles`,
and `sparse_level_chunk_tiles` up front (`reserveSparseLevelIndexEntry`,
`reserveSparseChunkIndexEntry`) before appending to any of them
(`commitSparseLevelIndexEntry`, `commitSparseChunkIndexEntry`), closing the
gap that used to exist here: an allocation failure partway through can no
longer leave a tile present in one structure but absent from the other two.
A `FailingAllocator` test drives a failure at each of the three reservation
steps and asserts all three structures are unchanged afterward.

**Incremental dirty-tracked LOS-blocked cache (closes the residual above):**
`ensureLevelBlockedCache` originally keyed staleness only on
`PerceptionSystem.step_counter` — since that counter is unique per step, every
distinct level touched by an observer paid a full rebuild every single step,
regardless of whether the world actually changed since the last build. This
is now replaced with NavGraph-style incremental patching, mirroring
`PathfindingSystem`'s post-commit nav reaction but deliberately narrower:

- `LevelBlockedSlot` gains `pending_dirty: std.ArrayList(DirtyRect)`, a plain
  min-inclusive/max-exclusive rect list (not `NavGrid`'s chunk-grid
  `NavCellEdit` — reusing that would couple this file to nav's chunk-grid
  shape for no benefit; the chunk grid is only consulted transiently, at
  patch time, to scope the sparse-tile rescan). It grows rather than drops on
  append (same must-not-lose-an-edit contract as
  `PathfindingSystem.nav_dirty_edits`) and, unlike that per-step-drained
  buffer, can persist across MULTIPLE untouched steps: a level with no
  observer this step is never asked to rebuild, so edits on it simply
  accumulate until an observer next looks at it.
- `PerceptionSystem.reactToPostCommitPerceptionEvents(frame, world)` — a new
  pipeline-level reaction (`SimulationPipeline.reactToPostCommitPerceptionEvents`,
  called alongside `reactToPostCommitNavEvents` at every one of its call
  sites; the two are fully independent side effects on disjoint state, so
  call order does not matter) — filters `frame.events.mergedItems()` to
  exactly `.world_tile_changed` (single-cell rect, only when the
  movement-blocking flag actually flipped) and `.world_obstacle_changed` (the
  event's own already-multi-cell rect), pushing a `DirtyRect` into the
  relevant level's `pending_dirty`. This is deliberately narrower than
  `PathfindingSystem.eventInvalidatesNavigation`: no other event variant is
  read, and there is no non-localizable whole-level fallback case (unlike
  nav's fallback for entity-obstacle toggles, which this cache never needs to
  react to, since it only ever reads world tiles). No event is emitted in
  return — nothing currently reacts to "perception's cache changed."
- `ensureLevelBlockedCache`'s decision tree, after the existing "already built
  this exact step" short-circuit: first-ever build for a level runs the full
  rebuild unchanged (discarding any `pending_dirty` recorded before that first
  build, rather than replaying it as a patch — the fresh rebuild already
  reflects current world state directly); an already-built slot with an empty
  `pending_dirty` SKIPS the rescan entirely (the headline fix — this case
  never used to happen, since staleness was keyed only on the step counter,
  not on whether anything changed); an already-built slot with a bounded
  amount of pending dirty area PATCHES only the affected cells (`@memset`
  false first per rect, since a bit can go blocked→unblocked and not just the
  reverse, then rescans only that rect per relevant dense layer and only the
  sparse tiles in the rect's overlapping level-local chunks via
  `WorldSystem.sparseTileIndicesForChunk`, bounding the sparse-side candidate
  set by chunk population instead of level population); an already-built slot
  whose accumulated dirty area exceeds a quarter of the level's total cells
  falls back to a full rebuild instead (patch overhead — a memset, rescan,
  and chunk walk per pending rect — starts to rival one dense full pass well
  before "half the level changed"; the 25% constant mirrors the spirit of
  `nav_graph.zig`'s `full_relabel_level_threshold`, which caps affected
  *levels* rather than a fraction of one level's *cells*, the finer unit this
  cache actually works in). `WorldSystem.chunksX`/`chunksY` (the level-local
  chunk grid shape, previously private) are now `pub` so this patch-time
  chunk-range computation can live in `perception.zig` without duplicating
  `localChunkIndexForCell`'s per-cell arithmetic.
- Proof: parity tests compare a patched/skipped/fallback-rebuilt result
  bit-for-bit against a fresh full rebuild of the same post-edit world state,
  covering a single dense-tile flip (both directions), a single sparse-tile
  add, a simulated sparse-tile blocking removal (two independently built
  `WorldSystem`s, since sparse tiles are append-only with no removal API — see
  `sparse_level_tiles`'s doc comment), a multi-cell `world_obstacle_changed`
  rect, dirty rects accumulated across several untouched steps before the
  level is next touched, an edit recorded before a level's first-ever build
  (discarded, not replayed), and the full-rebuild-threshold fallback path. A
  dedicated `FailingAllocator` test proves the steady-state patch path (and
  the dirty-rect bookkeeping that feeds it) allocates nothing once
  `pending_dirty`'s capacity has plateaued. The existing serial/threaded
  parity test continues to pass unchanged (the skip/patch/rebuild decision
  still happens entirely on the main thread, before any worker dispatch, same
  as the old unconditional rebuild).
- Measured effect (`--profile quick`): two new benchmark groups,
  `perception-cache-full-rebuild` and `perception-cache-patch`, isolate the
  cache-maintenance cost itself by reporting one synthetic structural-commit
  event per iteration (a whole-level rect vs. a single-cell rect) against
  `perception`'s own representative-density fixture, so `sensed_count`/
  `los_checks`/`nearest_threat_found_count` stay identical between the two and
  only wall-clock cost differs — serial-direct: 1,024 agents 3.58ms
  (full-rebuild-forced) vs 2.25ms (patch), 4,096 agents 11.74ms vs 10.75ms,
  10,000 agents 29.10ms vs 26.61ms; best-threaded: 1,024 agents 1.97ms vs
  0.65ms, 4,096 agents 3.85ms vs 2.41ms, 10,000 agents 7.58ms vs 6.10ms — a
  roughly flat ~1.3–1.5ms gap across a ~10x population range, confirming the
  gap really is the once-per-step cache-maintenance cost and not a per-agent
  cost. More directly, this fix also re-closes the `perception`/
  `perception-los-dense` residual documented above, since neither of those
  fixtures' positions ever change across iterations and neither calls
  `reactToPostCommitPerceptionEvents`, so every measured step after the first
  now skips instead of rebuilding: re-measured at 10,000 agents,
  `perception` 26.92ms serial / 6.09ms best-threaded, `perception-los-dense`
  27.31ms serial / 6.11ms best-threaded — a ~0.4ms/~0.02ms gap, down from the
  1.67ms/1.85ms gap recorded right after the shared-index fix and the
  original 3.76ms/3.25ms gap before any of this slice's LOS-cost work. See
  `src/benchmarks/perception.zig`'s module doc for the full write-up.

**LOS correctness fix (diagonal tunneling):** a review pass found that
`hasLineOfSight`'s original sampling — fixed `step_count = ceil(distance /
tile_size)` linear-interpolation samples along the ray, each checked against
`lookupLevelBlocked` — was not a true grid traversal. Consecutive samples on a
non-45-degree diagonal ray can straddle a gridline such that the continuous
segment passes through a blocking cell's interior without either sample ever
landing inside it, so a single-tile diagonal occluder could be silently
skipped and `target_visible`/`nearest_threat` set as if the wall weren't
there. The existing corner-grazing 45-degree test did not exercise this (a
perfectly corner-aligned line only ever touches cell corners, a measure-zero
case, and never crosses a cell's interior off-axis).

The fix replaces the fixed-step sampler with a proper Amanatides-Woo grid/DDA
walk that visits every cell the segment's interior actually crosses between
observer and target, still checking each visited cell with the same O(1)
`lookupLevelBlocked` lookup, with an early exit on the first blocked cell. The
defensive step ceiling (`los_max_steps`, 32) is now `los_max_cells` (64,
doubled headroom since Manhattan cell counts on a diagonal run higher than
the old Euclidean-based step count); hitting it now fails closed (returns
blocked) rather than coarsening resolution while still resolving the
endpoint — unreachable under any valid `AiPerception` config, a fallback for
pathological input only. A dedicated regression test reproduces a mid-segment
diagonal occluder a corner-grazing case would miss (observer/target placed so
the ray's true path crosses one cell's interior that no fixed-step sample
would land in) and confirms it is now correctly reported as blocked.
Benchmarked at 1,024 and 10,000 agents (`--group perception`): best-threaded
612.66us and 6.07ms respectively, in the same range as the cache-fix numbers
above — the cell-walk correctness fix adds no measurable per-agent cost.

**Perception event budget is caller-sized, not a floating default:**
`PerceptionConfig.max_events_per_step` (library default 512) was never
derived from the real per-step `frame.events` capacity a caller reserves via
`SimulationFrame.reserveStreams`. Once enough observers change visibility in
the same step to push the merged perception-event total past that real
budget, `mergePerceptionEvents`'s `prefixAppendedRanges` call throws
`error.EventCapacityExceeded` — unhandled all the way out of the fixed-step
loop, not the graceful truncate-and-drop the module intends. `SimulationPipelineConfig`
now carries `perception_max_events_per_step` (default `0`, following the same
caller-sized-capacity convention as `contact_capacity`/`static_obstacle_capacity`),
threaded into `PerceptionConfig` at the pipeline's perception call site. A
static caller-declared share was chosen over reading remaining capacity at
perception's call time, since perception runs before later
event-emitting stages (structural commits, nav invalidation) that would
otherwise inherit the same unhandled-throw risk on headroom perception
consumed first. `game_demo_state.zig`'s `demo_event_reserve` (83) needs no
added term today: no demo entity attaches `AiPerception`, so
`perception_max_events_per_step` stays `0` and perception's real contribution
to the shared budget is `0` by construction; a state that wires up
`AiPerception` must size this field against its own reserve. A compact test
(tight capacity, two observer/hostile pairs, `perception_max_events_per_step
= 1`) proves the graceful-drop path: no throw, `dropped_events == 1`.

Goal: let agents sense other entities (and later sounds) within vision/hearing
limits, writing per-frame sensed state to columns and emitting only acquisition/
loss transitions as events.

Current foundation:

- AI today perceives only an aggregate seek target and separation neighbors
  (`systems/ai.zig`); there is no range/FOV/line-of-sight sensing and no notion
  of distinct sensed entities.
- Slice 26 supplies faction stance; Slice 28 supplies a shared spatial index;
  Slice 21 supplies the event contract.
- Slice 34 deferred the vector sin/cos polynomial approximation to here:
  `simd.sinFloat4`/`cosFloat4`/`sinCosFloat4` exist today only as thin
  `@sin`/`@cos` vector-builtin wrappers with no production caller. If this
  slice's FOV math needs batched-angle trig across many agents, implement and
  benchmark the real polynomial (with a documented error bound and scalar
  fallback) here, against this slice's actual workload.

Architecture notes:

- Runs as a parallel processor stage before AI decision. High-volume per-frame
  sense results are columnar; only transitions are events.
- Hearing depends on a world stimulus/sound-emission buffer; ship vision-first
  and gate hearing behind that buffer (tracked in this slice's checklist).

Checklist:

- [x] Add an `AiPerception` component: cold tunables (vision range, FOV
      half-angle, hearing range) plus hot output columns (`target_visible`,
      `last_seen_x/y`, `nearest_threat: EntityId`, `nearest_threat_dist`).
      `vision_range`/`fov_half_angle_radians`/`hearing_range` (cold), the
      derived `cos_half_fov`, the four listed hot output columns, plus
      `facing_x/y` and `heard_stimulus`/`heard_stimulus_x/y` hot columns the
      original wording didn't anticipate, are all landed in
      `data_system/perception.zig`.
- [x] Add a `PerceptionSystem` parallel stage that queries the shared spatial
      index for candidates, then applies bounded range/FOV/line-of-sight checks
      (LOS against world blocking tiles via `world_system` walkability), writing
      results to perception columns.
- [x] Add scalar-only `entity_perceived` / `entity_lost` event payloads for
      target acquisition/loss transitions, emitted at `domain_reaction` via the
      per-range writer with pre-reserved capacity.
- [x] Add a transient per-step world stimulus/sound buffer (position +
      intensity + type, scalar-only) and consume it for hearing; keep it separate
      from the audio playback service. `SimulationFrame.stimuli`
      (`RangeOutputStream(WorldStimulus)`, `simulation.zig`) is the buffer;
      `DigController.process` is the sole producer; hearing is folded into
      `PerceptionSystem.computeOneAgent` as a same-level squared-distance
      check. See "Hearing (closes this slice)" above for the full account,
      including why `carveLandingCell` does not also produce one.

Acceptance checks:

- [x] Per-frame sense results live in columns, not events; only transitions emit
      events, bounded by a per-step cap with drops surfaced via event stats.
- [x] Serial and threaded perception produce identical columns and event order.
- [x] Sensing is allocation-free after warmup and runs only for cognition-tier
      entities in scope.
- [x] `zig build test` covers range/FOV/LOS gating, transition events, and
      serial/threaded parity.
- [x] `hasLineOfSight`'s per-cell blocked test is O(1) (`level_blocked`'s
      per-level bitmap cache, kept current for a distinct observer level at
      most once per step via a skip/patch/rebuild decision — see "Incremental
      dirty-tracked LOS-blocked cache" above), proven behavior-identical to
      `WorldSystem.levelBlocksMovement` by dedicated parity tests (including
      patch-vs-fresh-rebuild parity across every dirty-tracking case), and
      proven allocation-free after warmup by dedicated `FailingAllocator`
      assertions (serial, threaded, and the dirty-tracked patch path). The
      `perception-los-dense` benchmark confirms the original fix in practice:
      10,000 agents best-threaded went from 25.81ms (over the 16.67ms/60Hz
      budget) to 9.64ms; the incremental dirty-tracking fix further closed
      the once-per-step cache-rebuild residual that fix left behind (see
      above for the full before/after and the honestly-reported numbers at
      each stage).
- [x] `computeOneAgent`'s scatter writes into `job.perception_slice` at
      `perception_dense_index[i]` were checked for cross-worker false-sharing
      risk: the `perception-scattered-dense-index` benchmark
      (`benchmarks/perception.zig`) shuffles `perception_dense_index` so
      worker ranges write genuinely interleaved (same-cache-line) slots, unlike
      `perception`/`perception-los-dense`'s near-monotonic assignment. At
      50,000 agents this decorrelated case was not slower than the correlated
      one (4.42x/4.54x vs 4.34x/4.49x threaded speedup, within noise), with
      identical `sensed_count`/`los_checks`/`los_blocked`/
      `nearest_threat_found_count` confirming only store-write locality
      changed. Conclusion: measured, no regression — the per-agent
      spatial-query/FOV/LOS cost dwarfs the 5 scattered writes, so the direct
      scatter is left as-is rather than rewritten to a dense-pass-then-
      serial-scatter pattern.
- [x] `hasLineOfSight` walks every grid cell the segment's interior crosses
      (Amanatides-Woo DDA), not fixed-distance samples, closing a diagonal-
      tunneling gap where a mid-segment occluder could be skipped; proven by a
      dedicated regression test and re-benchmarked with no measurable
      per-agent cost regression. See "LOS correctness fix (diagonal
      tunneling)" above.
- [x] Perception's per-step event cap is caller-sized against the real
      `frame.events` capacity (`SimulationPipelineConfig.perception_max_events_per_step`,
      default `0`), not left at the library's permissive 512 default; proven
      by a tight-capacity test asserting graceful drop-and-report instead of
      an unhandled `error.EventCapacityExceeded`. See "Perception event budget
      is caller-sized, not a floating default" above.


