# AI Update Changelog

Branch: `ai_update`

Range: `main..ai_update`

Base: `e6ed17b` (`Merge pull request #8 from Ronin15/expand2`)

Tip: `107dd03` (`test seperation from demo state`)

## Summary

`ai_update` lands the emergent-AI cognition track's first three sensing/memory/
mood slices on top of the `world` branch's simulation and rendering
foundation. Slices 26–28 add the prerequisites — a deterministic faction/
stance model, a per-entity deterministic RNG facility, and a shared spatial
index — that Slice 29's AI Perception Substrate (vision and hearing, with a
resolved LOS performance risk and a follow-on incremental-cache fix), Slice 30
(AI memory), and Slice 31 (AI affect/emotion drives) then build on. Slice 34
closes out the core SIMD primitive layer with an honest record of one
deferred item and one built-and-reverted item (a batched lerp that measured as
a regression once benchmarked correctly). Slice 36 replaces one-draw-per-
dense-layer tilemap rendering with a bounded number of depth-composited draws,
removing the render cost's dependency on world depth. Alongside the new
cognition systems, the branch runs a substantial pathfinding hardening pass —
most notably a compile-time-enforced `SimulationPipeline` stage-ordering
contract and localized (rather than whole-level) nav invalidation for
entity-driven obstacle changes — plus a benchmark-suite expansion and a fix
to keep `zig build test` fast as gameplay fixtures grew.

The branch keeps the durable direction from `world`: persistent gameplay facts
stay in `DataSystem`, per-step communication stays in typed `SimulationFrame`
streams and events, hot processors work over dense SoA slices with
deterministic serial/threaded parity, and every allocation-free claim on a hot
path carries a `FailingAllocator` proof rather than a comment.

## Highlights

- Landed Slices 26–28: a const-evaluated faction × faction stance matrix
  (`AiFaction`/`entity_tag`), a reusable deterministic per-entity RNG
  (`src/core/rng.zig`, `mix64`/`uniformF32`/`boundedU32`/`unitVec2`) that also
  fixed a pre-existing bug where AI wander direction never actually resampled,
  and a shared `SpatialIndexSystem` for AI separation and perception (proven
  bit-for-bit identical to the grid it replaced; collision broadphase stays on
  its own tuned sweep-and-prune, a deliberate documented deviation from the
  original slice wording).
- Landed Slice 29, AI Perception Substrate: `AiPerception`
  (`data_system/perception.zig`) and `PerceptionSystem`
  (`systems/perception.zig`, 2,915 lines) add vision (range/FOV/LOS/faction-
  stance gating) and hearing (`SimulationFrame.stimuli`, fed today only by
  `DigController`), emitting capped `entity_perceived`/`entity_lost` events on
  acquire/lose transitions.
- Found and fixed a real O(n) LOS performance hazard: `hasLineOfSight` was
  rescanning every sparse tile in the world per raycast sample. A per-level
  O(1) blocked-bitmap cache, a shared per-level sparse-tile index (also
  benefiting `WorldSystem.levelBlocksMovement` and
  `NavGrid.markWorldObstacles`), and finally an incremental dirty-tracked
  cache closed a 6.5x–10x worst-case regression down to a ~0.4ms residual at
  10,000 agents. A follow-on correctness fix replaced fixed-step-count LOS
  sampling with a proper DDA grid walk to close a diagonal-tunneling gap.
- Landed Slice 30, AI memory: `AiMemory`/`AiMemoryStore`
  (`data_system/memory.zig`) and `AiMemorySystem` (`systems/ai_memory.zig`)
  give agents a last-known-target position, a fixed-capacity recent-contact
  ring, and spatial familiarity, letting `AiSystem.seek` retarget toward a
  cold target's last known position instead of losing it outright.
- Landed Slice 31, AI affect/emotion: `AiAffect`
  (`data_system/affect.zig`)/`AffectSystem` (`systems/affect.zig`, 1,262
  lines) track four independent per-entity drives (fear, curiosity,
  aggression, fatigue) with per-entity decay tunables and Schmitt-trigger
  threshold-crossing events; arbitration on these drives is deferred to
  Slice 32.
- Closed out Slice 34's core SIMD primitive layer, correcting stale roadmap
  checkboxes for work that had already landed earlier, and recording (rather
  than silently dropping) two honest non-wins: a deferred vector sin/cos
  polynomial with no production caller, and a batched `lerpVec2Float4` render-
  prep integration that a corrected, controlled benchmark A/B showed as a
  regression, not the win an earlier uncontrolled comparison had reported.
- Landed Slice 36: dense-layer tilemap rendering now uploads one combined GPU
  buffer, loops a bounded topmost-first window in the fragment shader, and
  buckets the CPU-side draw list at true depth-interleave points instead of
  once per layer — collapsing the shipped default to 1 composite draw
  regardless of world depth and letting the procedural render window return to
  its full authored underground stack.
- Added a compile-time-enforced `SimulationPipeline` stage-ordering contract
  (`PipelineResource`/`StageId`/`stageContract`/`stage_order`) so a stage
  reading a resource no earlier stage writes fails the build, plus a
  test-only `stage_trace` proving the declared order matches what `update()`
  actually runs; documented in `docs/coding-standards.md` as mandatory.
- Localized entity-driven static-obstacle nav invalidation: destroyed or
  changed collision entities now carry a resolved world-space rect that
  patches only the affected nav chunks, replacing the previous whole-level-0
  rebuild fallback (now purely defensive) — 5x–62x faster and proportional to
  obstacle count rather than world size.
- Ran a broad pathfinding hardening pass across the whole `pathfinding/`
  subpackage (`nav_graph.zig`, `system.zig`, `caches.zig`, `types.zig`,
  `group_field.zig`) fixing unreachable-goal handling, AI navigation-intent
  correctness, and capacity/perf tuning, and formalized the "fixed work
  budgets must never scale with world size" rule into `CLAUDE.md`.
- Decoupled test-fixture population size from the game's battle-scale demo
  population: a `default_demo_mover_count`/`battle_scale_demo_mover_count`
  split plus a `deriveDemoPopulationCapacity` helper stopped every test in
  `game_demo_state.zig` from spawning 2,048 movers, cutting `zig build test`
  from ~43s back toward its prior ~6s.
- Added `affect.zig`, `ai_memory.zig`, and `perception.zig` (5 groups)
  benchmarks, expanded `nav_update.zig`/`pathfinding.zig` with localized-
  invalidation and group-field-detour cases, collapsed
  `render_game_prep.zig`'s now-redundant 8/16/32-group axis, and pinned
  benchmark logging to `.warn` regardless of build mode so per-case debug
  logging doesn't skew timings.
- Added the `zig build bench` vs `zig build test` separation-of-concerns rule
  to `CLAUDE.md` after removing heavyweight fixture-building `test` blocks
  from benchmark files that were slowing the unit-test suite without adding
  fast-feedback value.

## AI Perception, Memory, And Affect (Slices 26–31)

- `AiFaction`/`entity_tag` (Slice 26) is a full component-store addition —
  enum tag, mask, `EntityTemplate` field, structural command, capacity, SoA
  store, and validation — backing a fixed, const-evaluated faction × faction
  → stance (hostile/neutral/friendly) table lookup instead of a hash map, a
  hard prerequisite for perception's faction-stance gating.
- `src/core/rng.zig` (Slice 27) generalizes a splitmix64-style mixer that
  previously lived as a private, non-reusable helper inside `ai.zig`. The
  migration fixed a real bug along the way: wander jitter used to be keyed
  only by a constant seed and entity index, so direction never actually
  resampled over time. `decideDir` now keys off `(seed, entity_index, step,
  wander_rng_salt)`, quantized into ~5-second epochs so direction holds
  steady then jumps rather than jittering every tick.
- `SpatialIndexSystem` (Slice 28, `src/game/systems/spatial_index.zig`) is
  built once per fixed step from the same cognition-scoped population
  `AiSystem` already gathers, and is read-only for worker ranges. AI
  separation's output through the shared index is proven bit-for-bit
  identical to the grid it replaced (brute-force O(n²) proof plus a
  cross-cell traversal-order oracle, since float-summation order is
  observable across cells). Collision broadphase deliberately stays on its
  own sweep-and-prune — investigation found it isn't grid-based to begin
  with, so porting it onto the shared index would have replaced an
  already-tuned algorithm for no benefit.
- `AiPerception`/`PerceptionSystem` (Slice 29) run as a parallel stage
  immediately after the shared spatial index is built: gather → grid/
  precompute → parallel range jobs → per-range emit → merge, mirroring
  `ai.zig`'s shape. The FOV test stays in squared form
  (`dot(facing,to) > 0 AND dot² > cos_half_fov² * dist²`), needing no sqrt,
  normalize, or trig — which retroactively made Slice 34's deferred vector
  sin/cos polynomial unnecessary. Hearing rides `SimulationFrame.stimuli`, a
  transient per-step buffer (position/intensity/kind/level) cleared every
  `beginStep` and never promoted to an event, since a stimulus carries no
  stable identity to transition against; `DigController.process` is its sole
  producer today.
- The LOS cost-risk fix added `PerceptionSystem.level_blocked`, a per-level
  raw-tile-granularity bitmap built at most once per distinct observer level
  per step and read in O(1) per raycast sample. It deliberately does not
  reuse pathfinding's `NavGrid`: `NavGrid.blocked` is a strict superset (also
  blocks on level-0 static collision bodies, which would silently occlude LOS
  incorrectly) and `NavGrid.cell_size`/`WorldSystem.tile_size` only
  coincidentally match today. Before/after at 10,000 agents (`--profile
  quick`, serial): `perception` 33.6→22.0ms, the adversarial
  `perception-los-dense` fixture 217.6→25.7ms (a 6.5x–10x regression down to
  1.17x).
- A follow-on fix found the same "scan every sparse tile then filter by
  level" pattern duplicated three ways (`WorldSystem.levelBlocksMovement`,
  `NavGrid.markWorldObstacles`, and the new perception cache) and added
  `WorldSystem.sparse_level_tiles`, an eagerly-maintained reverse per-level
  index (eager rather than the lazy dirty-flag pattern used elsewhere,
  because these three consumers run mid-fixed-step and cannot tolerate a
  render-frame-only refresh). Isolated loop measurement: ~784us/rebuild →
  ~45us/rebuild.
- A final incremental dirty-tracked cache (`LevelBlockedSlot.pending_dirty`,
  fed by a new `PerceptionSystem.reactToPostCommitPerceptionEvents` reaction)
  replaced full-rebuild-every-touched-step with skip-if-untouched / patch-if-
  bounded / full-rebuild-if-large-area, closing the residual gap to ~0.4ms at
  10,000 agents. A separate correctness fix replaced fixed-step-count LOS
  sampling with a proper DDA grid walk, closing a diagonal-tunneling gap
  where a straddled gridline could skip a diagonal single-tile occluder.
- `AiMemory`/`AiMemoryStore` (Slice 30, `data_system/memory.zig`) use fixed-
  size scalar columns — no per-entity `ArrayList` — for last-known-target
  position/staleness, a small fixed-capacity recent-contact ring, and spatial
  familiarity. `AiMemorySystem` runs between perception and AI, decaying
  state for the cognition-scoped subset and refreshing from perception's
  acquisition events; `AiSystem.seek` retargets to `AiMemory.last_known_x/y`
  when perception is cold but memory is fresh. Scope freeze/resync on tier
  demotion falls out of reusing the same cognition-scope dense-index list
  perception/AI already gate on. `memory_expired` is defined but not yet
  reacted to.
- `AiAffect`/`AiAffectStore` (Slice 31, `data_system/affect.zig`) carry four
  independent `[0,1]`-clamped drives — fear, curiosity, aggression, fatigue —
  each with per-entity baseline/decay-rate/threshold tunables (deliberate,
  ahead of a future data-driven-archetype slice needing per-personality decay
  speed). `AffectSystem` runs between memory and AI, appraising perception and
  memory (both independently optional per row); fear and aggression share a
  visible-hostile/distance signal through independent, uncoupled gains.
  Threshold-crossing uses a true Schmitt trigger (a persisted
  `above_threshold_mask` per drive) so a value hovering at threshold cannot
  refire the same edge twice. Arbitration that consumes these drives is
  deferred to Slice 32.

## Pathfinding Hardening

- The `SimulationPipeline` stage-ordering contract
  (`PipelineResource`/`StageId`/`stageContract()`/`stage_order`) makes stage
  dependency order a compile-time-checked property instead of a
  comment-and-convention one: a `comptime` block walks `stage_order` and
  fails the build if any stage reads a resource no earlier stage writes. A
  test-only `stage_trace` records what `update()` actually marks and asserts
  it matches the declared order. `docs/coding-standards.md` documents the
  4-step checklist (resource tags, `stage_order` slot, `stageContract()` arm,
  the real call plus its `stage_trace.mark()`) as mandatory for any new or
  reordered stage.
- Entity-driven static-obstacle nav invalidation is now localized the same
  way tile edits already were: `component_changed` events on
  `movement_body`/`collision_bounds`/`collision_response` and
  `entity_destroyed` now carry an optional world-space collision rect,
  resolved via `markNavObstacleRectDirty` to patch only the nav chunks that
  rect touches. The previous behavior — a whole-level-0 remask on every
  entity-driven obstacle change — is now a defensive fallback (logs a warn)
  for the case a change carries no resolvable rect, not the common path. Two
  bugs surfaced and were fixed along the way: the static-body coverage cache
  was never refreshed on the incremental path, and the whole-level refresh
  scanned O(cells × bodies) instead of O(bodies). A new
  `nav-update-entity-obstacles` bench shows the localized path 5x–62x faster
  and proportional to obstacle count rather than world size.
- A follow-on multi-commit pass (`92568e1`, `5aeefa6`, `7c69d5b`, `b5ca3fb`,
  `9201f9f`) reworked most of `src/game/systems/pathfinding/`: unreachable-
  goal handling in `solve.zig`/`nav_memory.zig`/`scratch.zig`, an `ai.zig`
  fix so requests carry the intent pathfinding actually needs, and broad
  internal hardening across `caches.zig`, `nav_graph.zig`, `nav_grid.zig`,
  `group_field.zig`, and `types.zig`. This is also where the tier0/tier1
  attempt-ladder's fixed abstract-node-cap design was generalized into the
  `CLAUDE.md` rule that per-query work budgets must be fixed constants, never
  derived from world/map/cell/portal size.
- `e56831e` ("more capacity and perf tuning") separately tuned
  `game_demo_state.zig` capacity estimation and touched
  `collision.zig`/`collision_response.zig`.

## Rendering (Slice 36)

- Dense-layer tilemap rendering moved from one draw per layer to a bounded
  number of depth-composited draws. `WorldSystem` now uploads a single
  combined `dense_tile_data_buffer` for the flat tile-id array instead of one
  buffer per layer (also sidestepping an SDL_GPU per-stage binding limit and
  a Metal storage-slot-shift quirk).
- `tilemap.frag.glsl` loops a per-draw, topmost-first window of level offsets
  and stops at the first non-empty cell, so most pixels resolve in 1–2
  iterations instead of discarding through every layer's full pass — the old
  per-layer `discard` had disabled early-fragment-test culling, making cost
  scale as `layers × viewport_pixels` regardless of visual payoff.
- CPU-side bucketing (`submitStaticDenseGeometry`/`partitionDenseComposite
  Buckets`) cuts the depth-ascending dense layer list only at true
  "interleave depths" — a depth something else (dynamic entity, particle, or
  any sparse tile anywhere in the world) needs to render sandwiched between
  two dense layers this frame. The shipped default config resolves to
  exactly 1 composite draw; `Renderer.k_max_dense_composite_draws = 8` is a
  defensive cap, not the expected case.
- Because draw count no longer scales with render-window depth, the
  procedural render window returned from Slice 23B's `levels_below = 6`
  mitigation back to the full 31-level authored underground stack.
  `render_prep.staticGeometryCapacity` reservation switched to the flat
  `WorldSystem.maxDenseSubmitDrawCount()` bound. Proven via bucket/window
  unit tests, an end-to-end `render_prep.zig` interleave test, and `zig
  build gpu-smoke`; `render-game-prep` benches assert
  `merged_tilemap_group_count == 1` as the CPU-measurable proxy for the fix
  (this repo has no GPU timestamp-query infra to measure fill-rate directly).

## SIMD Primitives (Slice 34)

- Closed out the core SIMD layer with a doc-drift correction: most items
  (gather/scatter, rsqrt/normalize, sprite-transform vectorization, AI
  separation-grid `@memset`) had already shipped on earlier commits without
  the roadmap checkboxes being updated, so this pass corrected the stale
  state rather than re-doing the work.
- Vector sin/cos (`sinFloat4`/`cosFloat4`/`sinCosFloat4`) exist as thin
  builtin wrappers with no production caller; deferred to Slice 29, which
  then found the squared-form FOV test avoids trig entirely, so the
  deferral stands with no follow-up needed.
- A batched `lerpVec2Float4` was built, bit-exact parity-tested, and wired
  into `render_prep.zig`'s `collectDynamicRecords`, initially reported as a
  6–9% win. That result did not reproduce: the original comparison was
  against a stale, non-adjacent baseline and ran under Debug instead of
  ReleaseFast. A corrected, controlled A/B (isolated worktree, 8 repeated
  runs, Debug and `--release=fast`) found no reliable win and a real 5–15%
  regression at two of three scales — the interpolation loop is memory/
  branch-bound (asset resolution, AABB cull, draw-record construction), not
  lerp-bound, so batching overhead exceeded the scalar flops saved. The
  render-prep consumer was reverted; the primitive itself stays in
  `src/core/simd.zig` with no caller. This episode is the origin of the
  benchmark-methodology caution ("back claims with evidence") now expected
  of every perf claim in this repo.

## Test Suite And Benchmarks

- `game_demo_state.zig`'s test fixtures no longer inherit the game's
  battle-scale mover count. `test_square_count` (a single comptime constant
  every test paid for) was replaced with `default_demo_mover_count = 32` for
  test paths and `battle_scale_demo_mover_count = 2048` reserved for the real
  procedural game entry point, with dependent capacities (contact, intent,
  collision-trigger, structural, event reserve) now derived at runtime via
  `deriveDemoPopulationCapacity`, mirroring pathfinding's existing
  `deriveCapacity` pattern. This is the concrete instance of the new
  `CLAUDE.md` rule to keep test fixtures at the smallest size that still
  exercises the behavior under test, and cut `zig build test` from ~43s back
  toward ~6s.
- Added `src/benchmarks/affect.zig`, `ai_memory.zig`, and `perception.zig`
  (contributing 5 groups: `perception`, `perception-los-dense`,
  `perception-scattered-dense-index`, `perception-cache-full-rebuild`,
  `perception-cache-patch`), all wired into `runner.zig`'s benchmark-group
  table.
- Expanded `nav_update.zig` with an `entity_obstacle_group` proving the
  localized-invalidation fix, and `pathfinding.zig` with
  `escalated_detour_group`/`group_field_detour_group` and their moving/
  hysteresis variants.
- Collapsed `render_game_prep.zig`'s `dense_8/16/32_surface/deep` six-group
  axis down to `dense_surface_group`/`dense_deep_group` once Slice 36 made
  that axis stop varying the built fixture, and added
  `render_game_prep_merged_tilemap_groups` to `RunStats`.
- `build.zig` now pins benchmark logging to a separate `bench_log_level =
  .warn` regardless of the game's optimize-mode-driven log level, so
  per-case debug logging (e.g. `ThreadSystem` re-init chatter) doesn't skew
  bench tables; `-Dlog-level=debug` still overrides explicitly for
  troubleshooting.
- Removed a heavyweight `test` block from `benchmarks/pathfinding.zig` (a
  hard-fallback-ceiling check that built real fixtures) and ~66 lines of
  test code from `render_game_prep.zig`, dropping both files from
  `src/tests.zig`'s import list. This is the origin of the new `CLAUDE.md`
  rule that `zig build test` must never call into `src/benchmarks/*.zig`
  fixture builders or case runners — `suite.zig`'s own tests are the sole
  exception, since they cover only pure utility logic against hand-built
  stubs.

## Documentation

- `docs/coding-standards.md` gained the "Simulation pipeline stage ordering
  (mandatory, not advisory)" section.
- `CLAUDE.md` gained three new working rules from this branch: fixed
  per-query/per-frame work budgets must never scale with world/map/cell/
  portal size; the `zig build bench` vs `zig build test` separation of
  concerns (and the ban on test code reaching into `src/benchmarks/*.zig`);
  and keeping `WorldSystem`/`DataSystem` test fixtures at the smallest size
  that still exercises the behavior under test.
- `docs/rendering-assets-shaders.md`'s GPU-driven tilemap section was
  substantially rewritten for Slice 36 (combined buffer, composite-draw
  bucketing, interleave-depth partitioning).
- `docs/simulation-tiers-and-pipeline.md` gained a stage-ordering-contract
  section and perception/memory/affect stage descriptions in the fixed-step
  pipeline order.
- `docs/framework-implementation-slices.md` marked Slices 26–31, 34, and 36
  landed with full acceptance-history detail, and split remaining frontier
  work into Slices 32–33 (behavior arbitration, data-driven archetypes),
  35 (AI/steering hot-loop SIMD restructure), 37 (dense render-window ceiling
  raise), and 38 (elevation above the surface).

## Follow-Up Work Left Explicit

- Slice 32 (behavior arbitration) and Slice 33 (data-driven archetypes/
  debug) are the next emergent-AI track slices; affect's threshold-crossing
  events have no consumer until 32 lands.
- `memory_expired` (Slice 30) is defined but not yet reacted to; no current
  system needs it.
- Slice 35 (AI/steering hot-loop SIMD restructure) remains open; Slice 34's
  reverted batched lerp is a cautionary data point for any future dynamic-
  record vectorization attempt in that area.
- Slice 37 (dense render-window ceiling raise, 32→128, with shader/host
  layer-count sync hardening) and Slice 38 (elevation above the surface,
  depends on 37) remain not started.
- The perception LOS-blocked cache's residual ~0.4ms gap at 10,000 agents is
  attributed to a once-per-step cold-cache scan cost and considered closed
  for realistic world densities; further closing it (e.g. keeping the
  per-level working set resident) was explicitly out of scope for this pass.

## Commit List

- `515a0ca` render iterpolation simd lerp implemented
- `a0c4076` corrected docs and reverted render prep lerp changes, but left simd helpers
- `3c4820e` slice 29 added, LOS and perception
- `bf5e7fa` Fix Slice 29 perception review findings
- `f0774b6` slice 29 hearing reviewed and implemented
- `8cca4a4` full branch review, and cleaned up a few issues
- `2cb3a49` doc update
- `867a36e` slice 30 reviewed and implemented
- `b9ead01` memory bench added
- `be62525` slice 31 done - needs review
- `5c60aad` GPU usage hotfix needs slice 36 to be fixed correctly.
- `ce71826` slice 31 review and fixes complete
- `232599f` render tilemap fixes to not touch every world tile every frame amd making a shader to to the heavy work.
- `2f5d73c` Add pipeline stage-ordering contract and localize entity-driven nav invalidation
- `9e23f90` Merge branch 'ai_update' into worktree-sim-pipeline-hardening
- `363c156` added some digging/hole contrast
- `28c7650` bigger review of all changes made today
- `947aaae` updated roadmap
- `92568e1` pathfinding fix for unreachable goals
- `98e4c08` removed test blcoks from bench code that were too heavy
- `75c077f` updated build zig to remove logging from bench to help it be faster.
- `5aeefa6` more pathfinder tweaks
- `7c69d5b` more pathfinder review and tweaks
- `b5ca3fb` pathifinding fix, AI to request correct intent
- `9201f9f` pathfinder fixes and mre tweaks
- `e56831e` more capcity and perf tunning
- `107dd03` test seperation from demo state
