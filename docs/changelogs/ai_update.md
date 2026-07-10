# AI Update Changelog

Branch: `ai_update`

Range: `main..ai_update`

Base: `e6ed17b` (`Merge pull request #8 from Ronin15/expand2`)

Tip: `94e1443` (`review fixes`)

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

On top of that foundation, Slice 32 (AI Behavior Arbitration) closes the
emergent-AI locomotion loop: a new pure `arbitration.zig` module scores
`wander`/`pursue`/`flee`/`investigate`/`cohere` from a table-driven
drive×behavior weight matrix over perception, memory, and the Slice 31 affect
drives, sticky-selects one, and resolves a per-agent goal — the broadcast
"everyone seeks the player" path is gone. Profiling the resulting perception
cost at 2,048 cognition-enabled entities found `SpatialIndexSystem`'s
hashmap-backed cell lookup was the bottleneck; it was replaced with a
direct-indexed, camera-relative dense grid queried via 4-wide SIMD occupancy
checks. A follow-on review pass fixed a fatigue-drive gap (only `pursue`
raised fatigue; `flee` now does too, matching arbitration's exertion model)
and hardened the dense-window bound to survive `ReleaseFast`'s stripped
asserts with a clamp instead of relying on a debug-only invariant.

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
- A full-branch code review pass (`a26487d`) found and fixed two more Slice
  36 rendering correctness bugs (a dense composite-draw interleave-depth
  collector that could silently drop a needed cut, and a rim-shadow flicker
  driven by unrelated scene content), an AI memory retarget bug where a cold
  agent could snap toward a remembered position belonging to the wrong
  entity, a pathfinding tier-0 budget clamp gap, and a perception cache
  false-sharing/self-healing hardening pass — see "Branch Review Pass" below.
- Landed Slice 32, AI Behavior Arbitration: `src/game/systems/arbitration.zig`
  scores `wander`/`pursue`/`flee`/`investigate`/`cohere` via a table-driven
  drive×behavior weight matrix (fear→flee, aggression→pursue,
  curiosity→investigate), sticky-selects one with hysteresis, and resolves a
  per-agent goal — closing the loop from Slice 31's previously-dead affect
  drives into actual locomotion choices. The old broadcast "every agent seeks
  the player" path is gone: perception's faction-generic `nearest_threat` is
  now the primary pursue/flee signal, with the player reachable only through
  an explicit, opt-in, gain-gated `focus_target` fallback.
- Replaced `SpatialIndexSystem`'s hashmap-backed populated-cell lookup
  (`CellLookup`) with a direct-indexed, camera-relative `DenseCellLookup`
  grid queried 4 cells at a time via new `simd.loadUint4`/`equalUint4`
  helpers — found while profiling perception cost at 2,048 cognition-enabled
  entities. See "Spatial Index Dense-Window SIMD Rewrite" below.
- Fixed a demo audio regression at higher NPC counts: `AudioController
  .queueCollision` now only plays a sound for contacts involving the player
  entity, since NPC-vs-NPC pileups at scale were spamming the mixer with
  simultaneous collision triggers every step that no longer serve a purpose
  once Slice 32 gives agents real reasons to cluster.
- A review pass on Slice 32 fixed a fatigue-drive gap (`AffectSystem` only
  raised fatigue on `pursue`; `flee` is equally exertive per arbitration's
  weight table and now raises it too) and replaced a `std.debug.assert`-only
  guard on the dense spatial-index window's bounding box with an
  unconditional clamp-and-skip, since this project ships `ReleaseFast` and an
  assert-only guard would silently corrupt `dense_lookup` in the shipped
  build if the window-sizing assumption were ever violated.

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

## AI Behavior Arbitration (Slice 32)

- New pure module `src/game/systems/arbitration.zig` (zero-alloc, no
  vtables, no dependency on `AiSystem`/pipeline/spatial index) implements
  three helpers: `scoreBehaviors` sums a `[drive_count][behavior_count]f32`
  weight table (dimensioned off `@typeInfo(AiAffectDrive)`) scaled by the
  agent's own personality gains, plus small perception/memory bonus terms;
  `selectSticky` holds the previous behavior while `commitment_remaining >
  0` unless a challenger clears `sticky_bonus + min_delta`, otherwise
  argmaxes with ties broken by lowest enum index; `resolveGoal` resolves a
  concrete goal per behavior (pursue/flee toward or away from a visible or
  remembered threat, investigate toward a heard stimulus or the freshest
  memory-ring contact, cohere toward a local friendly-neighbor mean read
  from the shared spatial index).
- `AiBehavior` expanded from `{wander, seek}` to `{wander, pursue, flee,
  investigate, cohere}`; `.seek` has no remaining production call sites.
  `AiAgent` gained cold `gain_wander`/`gain_pursue`/`gain_flee`/
  `gain_investigate`/`gain_cohere`/`wander_amplitude`/
  `commitment_max_steps`/`sticky_bonus` tunables (validated non-negative,
  capped by `max_ai_gain`) and hot `active_behavior`/`commitment_remaining`/
  `last_score` columns for debug/test observability.
- `AiSystem` gathers `arbitration.Signals` per row and runs the scoring
  chain **inside** the already-threaded `writeAiIntentsJob`/
  `writeAiSeparationJob` range jobs rather than as a new pipeline stage;
  `updateSerial` dispatches the same job functions through a single
  full-range call, so serial and threaded selection share one code path by
  construction. Cohere's neighbor-mean gather rides the existing
  separation-stage `queryNeighbors` call against the shared spatial index
  (Slice 28), filtered to friendly stance — no second grid.
- The player-broadcast path is gone: `simulation_pipeline.zig`'s production
  `self.ai.update(...)` call no longer forces `nav_request_kind = .group` or
  a single shared `seek_target`. Perception's `nearest_threat` (already
  faction-generic via `stance()`) is pursue/flee's primary signal, fresh
  `AiMemory` is the second tier, and the renamed `AiConfig.focus_target`/
  `focus_entity` (fed from the player) is an explicit, opt-in,
  `gain_pursue > 0`-gated last-resort fallback only. Path-request `kind` is
  now a ceiling, not a broadcast: `resolveGoal`'s `kind_hint` (currently
  always `.individual`) wins over `AiConfig.nav_request_kind`, which
  defaults to `.individual` in production.
- `stageContract(.ai_decide)` now reads `affect_drives` (written one stage
  earlier by `affect_update`); `AiConfig.affect_slice` threads
  `data.aiAffectSliceConst()` into the AI stage, making Slice 31's emotion
  drives load-bearing for the first time.
- `game_demo_state.zig` attaches `ai_perception`/`ai_memory`/`ai_affect` to
  a subset of demo movers via an 8-slot `demoArchetypeForIndex` cycle:
  `timid` (high `baseline_fear`/`gain_flee`, `.ally` faction), `aggressive`
  (high `baseline_aggression`/`gain_pursue`), `curious` (high
  `baseline_curiosity`/`gain_investigate`), and `cohesive` (`gain_cohere`
  only, no cognition components), alongside preserved wander/fallback-pursue
  contrast groups. `timid`'s `.ally` faction is deliberate — it gives
  `aggressive` a real non-player hostile target to pursue and `timid` a real
  non-player threat to flee, so the demo exercises agents reacting to each
  other, not just the player.
- Bench group `ai` (`src/benchmarks/ai.zig`) now cycles a 5-archetype
  fixture (one per `AiBehavior`) and reports a per-behavior selection
  histogram plus intent count alongside timing at 1,024–50,000-agent scale;
  all five buckets populate at every scale with no throughput regression
  from the pre-arbitration baseline.
- Review-pass fix: `AffectSystem`'s fatigue column keyed its exertion delta
  off `active_behavior == .pursue` only (`behavior_pursue_f`). Arbitration's
  own fatigue weight-table row treats `pursue` and `flee` as equally
  exertive, so a fleeing agent's fatigue was decaying instead of rising.
  Renamed to `behavior_exertion_f` and widened the gate to `pursue or
  flee`; new test `"fatigue rises under flee just like pursue..."` pins the
  parity.
- Deferred by design, not half-wired: attack/interact intents (Slice 40),
  new stimulus producers beyond dig (Slice 39), world interest markers
  (Slice 41), JSON archetypes and a debug overlay (Slice 33), and the SIMD
  restructure of the separation/`decideDir` loops themselves (Slice 35) —
  this slice's arbitration math is scalar-correct by design, with data
  already shaped (`[behavior_count]f32` scores, per-drive weight rows) for
  35 to pack later. The optional `behavior_changed{entity, from, to}` event
  also stays unbuilt until Slice 33's debug overlay or a domain reaction
  actually needs it.

## Spatial Index Dense-Window SIMD Rewrite

- Diagnosing perception cost at 2,048 cognition-enabled entities pointed at
  `SpatialIndexSystem.queryNeighbors`' populated-cell lookup. The prior
  `CellLookup` (`std.HashMapUnmanaged(SpatialCell, SpatialCellRange, ...)`
  with a custom splitmix64-style hash) was replaced with `DenseCellLookup`:
  a row-major dense grid over a bounded, camera-relative window, re-anchored
  every build to that step's own populated-cell bounding box (not absolute
  world coordinates) so a fixed-size buffer represents any camera position
  without growing.
- Row-major layout makes consecutive `cell.x` values at a fixed `cell.y`
  land on consecutive flat indices, so `queryNeighbors` scans 4 cells per
  row at a time with a plain contiguous load (new `simd.loadUint4`) and
  tests all 4 for "unpopulated" (`start == end`) with one compare (new
  `simd.equalUint4`/`Uint4`), instead of one hashmap probe per cell. Each
  populated lane still finishes scalarly in the same ascending order as
  before, so entry-visit order and existing determinism guarantees are
  unchanged; a row's x-span is clipped to the window bounds up front so the
  batch loop never reads outside `starts`/`ends`, and a clipped span not a
  multiple of 4 finishes with a scalar tail.
- The window is sized in `SpatialIndexSystem.reserve` (now taking a
  `DenseWindowGeometry` alongside the existing capacity) from the
  cognition-halo margin plus a fixed assumed visible-region span
  (`max_expected_visible_window_cells = 256`), clamped to a hard ceiling
  (`max_dense_window_side_cells = 4096`) sized for a documented future
  camera-zoom range this genre is expected to need, not just today's
  hardcoded zoom=1.0. `simulation_pipeline.zig` now threads
  `chunk_size_tiles`/`tile_size` from the loaded `WorldSystem` into that
  geometry at construction time.
- `runtime_perf_log.zig` gained a `perception` batch stage and six new
  metrics (`perception_observers`/`_sensed`/`_los_checks`/`_los_blocked`/
  `_nearest_threat_found`/`_candidate_checks`) plus a per-batch-stage
  `wait_ns_on_max_duration` field, distinguishing "one worker got an unlucky
  range while siblings idled" from "every worker was equally busy on a
  globally harder population" — the instrumentation that identified the
  hashmap bottleneck in the first place.
- Review-pass hardening: the dense window's bounding box fitting inside its
  reserved capacity had been enforced with `std.debug.assert`, which
  `ReleaseFast` strips — a violation in a shipped build would have silently
  corrupted `dense_lookup.starts`/`ends`. The write loop now unconditionally
  clamps the window and skips any cell that falls outside it in every build
  mode, so a violation degrades to a per-step correctness gap (a cell
  temporarily missing from spatial queries) rather than memory corruption;
  `entries`/`ranges` themselves are unaffected since they don't share the
  fixed-capacity buffer. New test:
  `"buildEntriesAndRanges clamps the dense window and skips out-of-window
  cells instead of writing past reserved capacity"`.

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
  exactly 1 composite draw; `Renderer.k_max_dense_composite_draws = 32` is a
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
- Review pass fix: `render_prep.collectDenseInterleaveDepths` deduplicated
  candidate cut depths by raw value, so enough unrelated dynamic/sparse
  depths could fill the fixed 32-slot scratch buffer before a real,
  needed sparse-tile cut (appended last) was ever seen — silently merging a
  composite draw that should have stayed split. Candidates are now
  deduplicated by which *gap* between two adjacent submitted dense layers
  they'd cut (`interleaveGapIndex`), bounded at
  `k_max_dense_submit_stack_cap - 1` regardless of how many raw candidate
  depths the scene produces; `WorldSystem.denseWindowLayerDepths()` exposes
  the cached submitted-layer depths this relies on. Proven by a
  `render_prep.zig` test feeding 93 candidates (3x the real gap count) and
  asserting all 32 composite draws still land.
- Review pass fix: the fragment shader's rim-shadow effect gated on
  `resolved_depth == 0`, which means "topmost within this draw's own
  composited window", not "topmost in the world at this cell" — an unrelated
  interleave point elsewhere on the map could split a hole-revealing pair of
  dense layers into two composite draws, making the deeper (merely
  hole-revealed) tile flicker rim-shadow on and off as unrelated entities
  moved. Fixed with a new per-draw `TilemapWindowLayers.is_shallowest_bucket`
  flag (`Renderer.applyWindowLayers` forwards it into the previously-unused
  `layer_meta.y`), set by `WorldSystem.submitStaticDenseGeometry` only for
  the bucket holding the frame's actual shallowest submitted layer; the
  shader now gates on `resolved_depth == 0 && layer_meta.y != 0`. Proven by a
  `world_system.zig` test that splits the same two layers via an unrelated
  interleave point and asserts only the shallower bucket is ever marked.

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
  raise), and 38 (elevation above the surface). A later pass moved Slice 32
  itself to the archive as landed and re-pointed the frontier doc's
  Suggested Order at Slice 33.
- `docs/architecture.md`'s AI/pipeline paragraphs were rewritten for Slice
  32: emotion drives are now described as consumed (not merely tracked),
  with the `scoreBehaviors`/`selectSticky`/`resolveGoal` chain and the
  distinction between AI's *utility* arbitration (what an agent wants) and
  `SteeringSystem`'s *stream-priority* arbitration (which emitter wins)
  spelled out explicitly.
- Added `AGENTS.md` as a tool-agnostic mirror of `CLAUDE.md`'s source-of-truth
  index for non-Claude agent tooling, added `.cursor/` agent/rule/skill
  definitions mirroring the existing `.claude/agents/*.md` set, refreshed
  the `.claude/agents/*.md` subagent definitions, and consolidated
  `README.md`.

## Branch Review Pass (`a26487d`)

A full-branch code review pass across rendering, AI, and pathfinding found
and fixed several real correctness bugs beyond the two Slice 36 rendering
fixes already covered above:

- `AiSystem.resolveRowTarget` let a cold agent's `AiMemory.last_known_target`
  substitute for the live seek goal even when that memory belonged to a
  different entity than the one actually being sought (e.g. some other
  hostile-stance target glimpsed earlier), snapping the agent toward a stale,
  unrelated position. `AiConfig` gained an optional `seek_entity` identity
  gate; `resolveRowTarget` now only trusts remembered position when the
  memory's target matches it. Null `seek_entity` preserves prior behavior for
  callers with no single entity backing `seek_target` (e.g. the
  center-of-mass fallback).
- `pathfinding/solve.zig`'s tier-0 search used
  `capacity.tier0_abstract_node_cap` unclamped, but `AbstractScratch.reserve`
  always physically sizes its slot table from `max_abstract_nodes` (the
  tier-1 ceiling) alone. A caller tuning `tier0_abstract_node_cap` above that
  ceiling would silently saturate the physical slot table via `slotFor`'s
  linear-probe loop well short of the configured budget, instead of hitting
  the intended budget check. `solveOne` now clamps the tier-0 cap to
  `@min(tier0_abstract_node_cap, max_abstract_nodes)`; a new
  `pathfinding/system.zig` test pins a deliberately-inverted config (tier-0
  far above tier-1) still solving cleanly.
- `PerceptionSystem.range_stats` was a bare `ArrayList(PerceptionRangeStats)`
  (32 bytes/slot) with concurrently-running worker ranges each writing their
  final stats into adjacent slots — two slots could share one 64-byte cache
  line, a false-sharing risk the analogous `PerceptionEventRangeSlot` buffer
  already guarded against. Wrapped in a padded
  `PerceptionRangeStatsSlot`, matching the existing pattern.
- `PerceptionSystem.ensureLevelBlockedCache`'s self-healing gap: a level
  queried (fail-closed) before `WorldSystem.addLevel` created it left
  `built_step` stamped as if a real build had happened, so a later step could
  see a step-counter match and skip revisiting it even after the level
  actually existed, staying permanently fail-closed. A rebuild that still
  finds the level out of range now leaves `built_step` unstamped, so the
  cache keeps retrying every touch until the level is real. New test:
  `"ensureLevelBlockedCache self-heals once a level queried before it
  existed is actually added"`.
- `GameDemoState.deinit` freed `test_squares` through `self.data.allocator`
  — `DataSystem`'s own allocator field, which need not match the allocator
  `test_squares` was actually spawned with. `GameDemoState` now stores its
  own `allocator` field, set once at `init` from the same parameter
  `spawnTestSquares` used, and frees through that instead.
- `benchmarks/perception.zig`'s decorrelated-fixture shuffle asserted a
  fixed stride (97) was coprime with the pair count, which only held for the
  bench's own default `--items` tiers; a `--items` override could trip the
  assert. `shuffleStrideFor` now searches upward from the preferred stride
  for one that's actually coprime with the supplied pair count (bounded,
  fixture-build-time only, not on a measured path).
- `benchmarks/render_game_prep.zig`'s `initFixture` used one narrow
  `errdefer` per heap-owning field, added as each field was built; a new
  `InitStage` enum plus a single consolidated `errdefer` unwinds everything
  built so far in reverse order instead, so a future added field only needs
  one enum variant and one `stage = .field;` line rather than a fresh
  standalone `errdefer` placed exactly right.
- Corrected two documentation/comment inaccuracies: the stale
  `Renderer.k_max_dense_composite_draws = 8` references in
  `docs/rendering-assets-shaders.md` and this file's own Slice 36 section
  (the real shipped value is `32`), and `docs/framework-implementation-slices.md`'s
  Slice 26 checklist item, which described the landed component as
  `AiFaction`/`entity_tag` when it actually shipped as `Faction`
  (`src/game/faction.zig`).

## Follow-Up Work Left Explicit

- Slice 32 (behavior arbitration) is landed; Slice 33 (data-driven
  archetypes + debug introspection) is the next emergent-AI track slice.
  Cohere's `.group` path-kind upgrade for agents sharing a quantized goal
  cell and the optional `behavior_changed{entity, from, to}` event are
  documented extension points in `arbitration.zig`, deliberately not built
  until Slice 33's debug overlay or a domain reaction needs them. Growing
  the feeling set (new drives/coupling) is Slice 42 — append a weight-table
  row, no control-flow rewrite.
- `memory_expired` (Slice 30) is defined but not yet reacted to; no current
  system needs it.
- Slice 35 (AI/steering hot-loop SIMD restructure) remains open, now that
  Slice 32 has shaped `arbitration.zig`'s data
  (`[behavior_count]f32` scores, per-drive weight rows) for it to pack;
  Slice 34's reverted batched lerp is a cautionary data point for any future
  dynamic-record vectorization attempt in that area.
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
- `f8b6e6b` changelog and documentation update
- `a26487d` branch review and fixes
- `26cea7e` docs: changelog for branch review pass (a26487d)
- `51cbc49` updated claude skills and updated guidance documentation
- `b31a2a5` cursor project tooling added.
- `8937161` readme consolidated
- `1e8dd07` slice 32 comitted peception time needs SIMD cell checks or further optimization
- `89bae91` audio fix for constant colliding npcs not needed anymore
- `df0f9c8` Slice 32 optimizations at 2048 entities
- `94e1443` review fixes
