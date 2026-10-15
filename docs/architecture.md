# Architecture

The project is organized for SDL_GPU-first 2D game work: thin executable
timing, app coordination under `src/app/`, GPU work under `src/render/`, and
game-specific behavior under `src/game/`. This doc describes how the engine is
built; the rules it follows live in `.claude/rules/`.

## Target Model

The engine core serves a fully simulated game of many worlds that keeps
growing; the demo state is a harness that exercises this model, not the model.
Designs start here, then read the live structure below (rules:
`.claude/rules/engine-design.md` § Target scale and § Cost model).

- **Fully simulated:** everything that exists keeps advancing, in every
  world; distance from the observer (the camera focus, or a player when a
  game has one) lowers fidelity (far-off AI thinks on slower ticks, movement
  stays near full rate). `dormant` is for inert things only.
- **World instance:** independent, created and destroyed in play (persistent
  worlds, temporary dungeons); owns all its storage, released on destroy.
- **Level:** a world's stack grows in play; a level holds a directory of its
  chunks, never data sized to its area.
- **Chunk** `(level, cx, cy)`: the unit of terrain and nav storage, change,
  work, threading, and save. A dig, ramp, or cave-in costs work in the chunks
  it touches. Nav covers the whole world; residency is a chunk's storage form,
  never its presence in the simulation. Terrain, nav, and scope share one
  chunk edge, `WorldSystem.chunk_size_tiles` (a power of two up to 16, default
  16), and a nav cell is a tile.
- **Nav:** processed per chunk, so threading scales with any number of
  requests under a fixed per-step budget.
- **Populations, items, links:** grow in play at the structural-commit seam.
- **Scale:** 2048² levels, deep stacks, and several worlds are a floor; work
  and memory follow what changed and what exists, never extent × world count.

## Source Layout

- `src/main.zig` creates `AppConfig`, initializes `Engine`, and runs the fixed-step loop.
- `src/config.zig` defines app configuration, presentation options, clear color,
  and thread-system defaults shared by build options and runtime startup.
- `src/app/engine.zig` coordinates SDL app flow, the window, asset cache,
  runtime asset catalog, audio service, text service, renderer, state stack,
  pause controller, input, debug overlay, and thread system.
- `src/app/audio.zig` owns SDL3_mixer lifecycle, app-level audio tracks,
  loaded audio assets, bus gains, and the fixed-step audio command buffer.
- `src/app/input.zig` owns named actions, keyboard and default gamepad button bindings, held gameplay input (including analog left-stick movement), and one-frame app/debug commands.
- `src/app/input_router.zig` applies state-policy action contexts before input mutates `InputState` or `FrameCommands`.
- `src/app/gamepad.zig` owns single active-gamepad device lifecycle: first-connected-wins adoption, hot-plug add/remove reaction, and fallback-to-next-device (or keyboard) on disconnect.
- `src/app/time_loop.zig` keeps simulation fixed at 60Hz.
- `src/app/frame_pacer.zig` classifies window visibility and applies fallback frame pacing.
- `src/app/state.zig` manages state allocation, destruction, policies, and queued transitions.
- `src/app/pause_controller.zig` owns the pause policy: pushes the modal `PauseState` over gameplay and resets timing on resume.
- `src/app/thread_system.zig` provides pre-spawned workers for synchronous parallel CPU
  batches, the adaptive tuner, and the one copy of the stage pattern every threaded
  system uses (§ Thread System).
- `src/app/resolution.zig` owns pure logical-resolution, viewport, and coordinate conversion policy.
- `src/app/runtime_perf_log.zig` records fixed-step runtime perf metrics (Debug and
  ReleaseSafe; fully compiled out of ReleaseFast/Small) consumed by the engine
  interval dump and related diagnostics.
- `src/assets/assets.zig` resolves safe runtime asset paths,
  `src/assets/image.zig` decodes PNGs into transient CPU image data,
  `src/assets/cache.zig` caches renderer-backed runtime assets,
  `src/assets/manifest.zig` defines stable startup sprite/audio IDs, and
  `src/assets/runtime_assets.zig` owns the startup runtime asset catalog.
- `src/render/renderer.zig` is the game-facing render facade and frame coordinator.
- `src/render/camera.zig` owns simple world-to-screen camera transforms.
- `src/render/resources.zig` defines generational renderer resource IDs and descriptors.
- `src/render/sprite_batch.zig` owns ordered sprite command storage, vertex construction, draw grouping, and allocation-free warmed batch prep.
- `src/render/gpu/` owns SDL_GPU device/window setup helpers, upload buffers, texture uploads, and sprite material/pipeline creation.
- `src/render/text.zig` owns SDL3_ttf lifecycle, asset-backed fonts, and cached text textures.
- `src/render/debug_overlay.zig`, `src/render/debug_overlay_stub.zig`, and `src/render/fps_counter.zig` draw or compile out the F2 FPS overlay.
- `src/game/game_demo_state.zig`, `src/game/loading_state.zig`, `src/game/pause_state.zig`, `src/game/main_menu_state.zig`, `src/game/settings_menu_state.zig`, and `src/game/menu_view.zig` are the game/application state and menu modules. Main menu is the default startup state; gameplay is launched from it via a runtime-asset-backed loading transition.
- **Split-file types.** A type too large for one file keeps its definition,
  fields, and remaining methods in its package's `system.zig`; each public
  method defined in a sibling file is a declaration alias on the type
  (`pub const setDenseTile = world_edit.setDenseTile;`) with its `///` doc on the
  definition, so method syntax resolves straight to it with no forwarder frame
  in any mode (`.claude/rules/zig-style.md`). `world/` and `data_system/` use it.
- `src/game/world/` holds `WorldSystem`'s state-local world/tile data, with no
  facade: importers name the file they use. Public methods in `render.zig`,
  `edit.zig`, and `worldgen.zig` are aliases on the type (split-file types,
  above).
  - `system.zig`: the type and its storage (levels, dense layers, sparse tiles,
    level links, render-window state), queries, the tile catalog (source rects,
    flags), and view geometry (view window, chunk and cognition regions).
  - `render.zig`: `WorldSystem`'s render path: the render window's sparse tile
    list, the dense composite submit, the GPU tile store sync, and the sparse
    submit.
  - `edit.zig`: every terrain content write: single-cell dense writes and their
    reserve seams, batched dense writes as threaded plan and write jobs, sparse
    add/remove, and blocking clears.
  - `worldgen.zig`: the procedural and demo world builds (procedural ground
    painted per chunk on the thread system) and the underground level stack.
  - `terrain.zig`: chunk-owned terrain storage: per dense layer a chunk
    directory over a pool of tile blocks, and per level a `LevelTerrain`
    (growable band list and cached floor layer, a composed movement-blocked
    directory over a pool of bit blocks, per-chunk link-endpoint heads and
    counts, and per-chunk sparse-tile chain heads), directories sized at level
    create. Its `ChunkGeometry` (u32 sides, u16 chunk edge, shift-based
    `chunkOf`/`localOf`) is the one chunk tiling terrain, nav, and static
    colliders share.
  - `gpu_tiles.zig`: the mirror of the renderer-owned GPU tile store: the
    store's non-owning id, the resident window, each resident layer's toroidal
    directory and chain link, and the directory and block allocator it plans
    and commits each frame, uploading changed chunks found through layer flags
    and block change marks; reset when the renderer retires the store.
  - `interest.zig`: durable **interest/affordance markers** (Slice 41).
    Markers are world-authored POIs with fixed inline slot capacity
    (allocation-free by construction) — not `DataSystem` components and not
    ephemeral `WorldStimulus` dig/footstep/impact events. Kind `investigate` is
    the AI consumer today; `cover` / `resource` / `patrol` are reserved schema
    tags until a later consumer lands. Cognition discovery uses a fixed query
    radius (`dist ≤ query_r`); authored `marker.radius` is influence footprint,
    not the discovery gate. Queries return nearest-k (dist², then slot index).
  - `test_support.zig`: test-only `WorldSystem` fixtures shared across modules
    and world files (a demo surface at any chunk edge, terrain pool warmup, GPU
    sync and sparse-index checks).
- `src/game/stamped_table.zig` holds the generation-stamped open-addressed table
  the per-step key tables share (nav's abstract and local search tables, the plane
  stage's landing claims): an O(1) reset outside the rare wraparound.
- `src/game/data_system.zig` fronts the `data_system/` subpackage (types,
  movement, visual, collision, agents, faction_level, perception, memory,
  affect, destructible, structural, system) and owns state-local persistent
  entity data in dense SoA stores for gameplay, collision, and render systems.
  `DataSystem`'s structural-commit entries in `structural.zig` are aliases on
  the type (split-file types, above).
- `src/game/simulation.zig` owns transient fixed-step streams, deterministic
  range-output collection, and deferred structural command buffers.
- `src/game/simulation_pipeline.zig` owns state-local fixed-step processor
  orchestration, reusable gameplay systems, and full-active scope stats.
- `src/game/simulation_scope.zig` defines simulation tiers, active-region
  scaffolding, per-entity scope metadata types, stagger/halo constants, and scope
  counters.
- `src/game/systems/simulation_scope.zig` owns `SimulationScopeSystem`, the
  backbone scope processor: tier/halo/stagger gathers and the auto tier wake/sleep
  policy (entity chunk columns are derived by the dedicated late `chunk_derive`
  stage after positions settle, not in the scope pass).
- `src/game/player.zig` keeps player-specific input and facing behavior while
  storing persistent player data in `DataSystem`.
- `src/game/systems/movement.zig` integrates movement-body SoA columns through
  serial or threaded SIMD-aware ranges (world x/y only; discrete vertical plane
  is `position_z` / `world_level`, not continuous z motion) and applies the
  step's AI movement intents as a threaded stage.
- `src/game/systems/world_gate.zig` clamps settled bodies to world bounds and
  gates them off solid tiles (serial, main thread).
- `src/game/systems/plane_entry.zig` owns `PlaneEntrySystem`, plane traversal's
  threaded per-agent cell-entry gather and classification.
- `src/game/systems/static_colliders.zig` owns `StaticColliderSystem`, the shared
  static-collider rows nav and steering read through `ColliderView`.
- `src/game/systems/chunk_list_map.zig` holds `ChunkListMap` (per-key owner lists
  backing the static-collider chunk lists and the path registry) and
  `OrderedIndexSet` (the ordered chunk/level set nav's plan merge and the world's
  write grouping drain).
- `src/game/systems/spatial_index.zig` owns `SpatialIndexSystem`, the
  pipeline-shared per-step uniform grid built once from the cognition-scoped
  population and read by AI separation and perception.
- `src/game/systems/perception.zig` owns `PerceptionSystem`: vision
  (range/FOV/LOS/faction-stance gating) and hearing (transient world
  stimuli), emitting `entity_perceived`/`entity_lost` events on acquire/lose
  transitions. LOS reads the world's chunk terrain directly; it keeps no LOS
  state.
- `src/game/systems/ai_memory.zig` owns `AiMemorySystem`: decays last-known-
  target position, a fixed-capacity recent-contact ring, and spatial
  familiarity; refreshes last-known from continuous same-identity visibility
  and perception acquire/lose events; raises familiarity under sustained track.
- `src/game/systems/affect.zig` owns `AffectSystem`: appraises perception and
  memory into four independent per-entity mood drives (fear, curiosity,
  aggression, fatigue) and emits threshold-crossing events.
- `src/game/systems/ai.zig` emits navigation intents for ai_agent rows
  (arbitration over perception, memory, affect, and world interest markers).
- `src/game/ai_archetypes.zig` loads data-driven personality bundles from
  `assets/ai/archetypes.json` at load time into a fixed enum → component table
  (no hot-path JSON).
- `src/game/ai_debug_overlay.zig` draws read-only AI introspection (vision,
  drives, memory, active behavior) under the existing debug toggle; never
  mutates simulation.
- `src/game/systems/steering.zig` consumes navigation intents and path status,
  then emits final NPC movement intents with local avoidance (same-level agent
  neighbor gating mirrors collision).
- `src/game/systems/collision.zig` generates deterministic contact streams.
- `src/game/systems/collision_response.zig` consumes contacts and applies
  response-policy movement corrections;
  `src/game/systems/collision_response_test_support.zig` holds its test-only
  fixtures shared across modules.
- `src/game/systems/particle.zig` owns state-local transient particle effects
  in a fixed-capacity SoA pool with serial or threaded SIMD-aware updates.
- `src/game/systems/pathfinding.zig` fronts the `pathfinding/` subpackage
  (types, nav_grid, nav_graph, connectivity, caches, goal_table, group_field,
  scratch, solve, system, test_support) for frame-delayed multi-level grid
  navigation.
- `src/game/dig_controller.zig` is the pipeline-owned controller for player
  digging, authoring world-tile edits and navigation-invalidation signals.
- `src/game/destructible_controller.zig` is the pipeline-owned controller that
  consumes `action_intents` (interact/attack) into deferred destructible
  damage/destroy commands and domain events.
- `src/game/audio_controller.zig` is the pipeline-owned controller that turns
  per-step input and collision contacts into audio command-buffer intents
  (ambient music, a movement-gated jet loop, and collision SFX with per-pair
  cooldowns). It owns only audio-policy runtime state, never mixer handles.
- `src/game/render_depth.zig` defines world depth bands and z-order intent;
  `src/game/render_prep.zig` resolves entities to ordered render-draw records.
- `src/gpu_smoke.zig` is the GPU smoke executable entry point, while
  `src/platform/gpu_smoke_impl.zig` owns the display-gated SDL_GPU probe.
- `src/platform/sdl.zig` contains shared SDL, SDL_ttf, and SDL_mixer C imports
  plus small SDL wrappers.
- Sprite and audio startup assets are declared in `src/assets/manifest.zig` and
  live under the same traversal-safe asset root.
- `src/core/math.zig` and `src/core/simd.zig` contain small shared math and portable SIMD helpers.
- `src/core/rng.zig` provides a deterministic, stateless, seeded per-entity RNG
  facility (`mix64`/`uniformF32`/`boundedU32`/`unitVec2`) for reproducible
  gameplay randomness (AI wander, etc.).
- `src/core/logging.zig` owns scoped logging categories and build-option-driven log filtering.
- `src/root.zig` stays minimal for math aliases and compile coverage; feature
  modules live in their matching `src/` area and import each other directly.
- `src/tests.zig` imports reusable modules so `zig build test` covers their tests and compile-time contracts.
- `src/benchmarks/` holds the `zig build bench` groups, one file per area:
  `suite.zig` is the shared harness (options, cases, item codes, stage shapes,
  reporting, the nav memory estimate) and `fixtures.zig` the shared fixtures
  (thread systems, bodies, request streams, tilesets, banded worlds, nav tuner
  setup).

## Frame Flow

`src/main.zig` keeps the high-level loop:

1. Begin a frame and clear one-frame commands.
2. Poll SDL events, route named actions, and dispatch raw events through the
   engine and state stack.
3. Apply pause and frame visibility policy.
4. Run fixed 60Hz updates while the time accumulator needs them.
5. Drain queued audio commands on the main thread after each fixed update.
6. Render with interpolation between fixed updates.

The runtime call path is `main.zig` -> `Engine` phase method -> `StateStack`
policy dispatch -> eligible state or states. `main.zig` does not call gameplay
state methods directly; `Engine` builds the update/render contexts and
`StateStack` decides which states receive events, updates, and render calls.

Visible rendering is paced by SDL_GPU swapchain acquisition with the configured
present mode. Hidden and minimized frames skip GPU rendering, enter pause, and
use `SDL_DelayNS` fallback pacing. A visible no-swapchain result enters a
render-blocked gameplay pause before the next update, keeps using fallback
pacing, and clears that policy after a later frame is submitted. Occluded or
unfocused visible windows keep rendering but apply a 60Hz cap to avoid
background render runaway.
Frame pacing policy is explicit and situational
(`.claude/rules/memory-performance.md`).

Each submitted frame computes presentation from the acquired SDL_GPU swapchain
texture size and current SDL window size. World and logical UI draws are
transformed through that presentation into drawable pixels, then clipped to the
logical viewport; drawable overlays use raw swapchain pixels. Swapchain
presentation state lives in the SDL_GPU renderer path, world render state in
`WorldSystem`'s render path, and debug UI state in the debug overlay and
render-service path (`.claude/rules/render.md`).

## Coordination Boundaries

Game states submit through `Renderer.submitOrdered*` only from explicit
render-prep phases that already walk nondecreasing `RenderOrder`. World render
submission is layer-owned: z/depth discovery happens in `WorldSystem` and
state-owned dynamic render prep, then both streams are merged by world z before
commands reach `SpriteBatch`. Window, GPU device, swapchain, shader, texture,
text, and frame submission code lives under `src/render/` and `src/app/`;
ownership wrappers may centralize cleanup at the owning site
(`.claude/rules/engine-design.md`, `.claude/rules/zig-style.md`).

`Renderer` preserves strict ordered submission while delegating sprite-specific
CPU prep to `SpriteBatch`. SDL_GPU command-buffer acquisition, swapchain
acquisition, vertex upload, render-pass encoding, and submit remain coordinated
by `Renderer` on the main/render thread.
`SpriteBatch` owns a render-specific adaptive tuner and can use the app
`ThreadSystem` to expand prepared sprite commands into disjoint vertex spans.
Texture metadata is snapshotted before worker dispatch, workers read no
live renderer resource slots, and draw groups are built on the main thread from
the already ordered command stream. Small or cheap frames may stay inline
through the same adaptive policy.

CPU sprite command preparation stays before SDL_GPU swapchain acquisition where
practical, including transfer-buffer staging for the normal steady-state path.
Sprite prep emits presentation-independent world/logical or drawable positions;
the acquired swapchain interval stays focused on acquired-size presentation
uniforms, copy-pass upload, render-pass encoding, and submit.

Dense world floors use one renderer-owned GPU tile store per rendered world
(`Renderer.createTileStore`), stored by chunk like the CPU terrain but only for
the render window: per resident layer a toroidal directory of `side²` chunk
words (a uniform tile or a block offset) plus a link word chaining it to the
next deeper resident layer, and a block per mixed chunk inside the camera's
chunk window. The resident layers are those of the levels in the vertical
render window (`DenseLayerRenderWindow`, `levels_below` default 6, widened to
the full authored underground stack in the procedural demo world), so GPU
memory follows the window's layers times its chunks, never level area, world
depth, or world count. `WorldSystem.syncDenseTileStore` (`world/render.zig`;
mirror: `world/gpu_tiles.zig`) runs once per frame in render prep before
swapchain acquisition: a level entering the window uploads its window directory and
mixed blocks, a pan across a chunk boundary uploads the entering chunks, a dig
uploads one element, and everything goes in the frame's one batched copy pass.
Store uploads always use `cycle=false`; vertex ring buffers alone use
`cycle=true` on the final upload. The world holds only a generational
`TileDataId` and claims the store each sync (`Renderer.claimTileStore`);
`Renderer.endFrame` first retires every store no world claimed since the last
frame, so a destroyed, replaced, or unviewed world's store goes at the next
frame with no teardown call and no device drain (sweep O(store-slot high
water), derived). A world whose claim fails re-uploads its window into a new
store, O(resident layers × window chunks), derived.
Multi-level compositing requires back-to-front dense-layer depth order at
submit and in `mergeDrawList`. Sparse tiles draw from a per-window list the
window update builds from the window's levels and chunks, ordered by (depth,
cell, tile id): memory O(V), rebuild O(window levels × window chunks + V log V)
for the V tiles in the window, independent of the world's sparse count.
Dynamic entities collect from movement-body dense rows (Slice 24B): scope
columns and `renderCollectIndicesForMovement` align on `movement_index`; render
visibility is camera chunk + AABB only (simulation tier does not gate draw).
Dense floor submit buckets the resident layer set into a small number of
composite draws (`partitionDenseCompositeBuckets`, cut only at true
depth-interleave points where a dynamic entity, particle, or sparse tile
needs to render between two dense layers this frame; at most one per resident
layer), not one draw per layer; the fragment shader walks a bucket's chain of
layer directories topmost-first per pixel and stops at the first opaque cell
(GPU clips full-world quads; pixels outside the resident chunk window
discard). NPC per-level cull (Slice 25E) uses the `world_level` component in `DataSystem`
as the gameplay/nav/render authority; `setWorldLevel` syncs `scope.level` for
cube LOD. Player floor policy stays on `Player.current_level` for digging.
See `docs/rendering-assets-shaders.md`'s GPU-Driven Tilemap section (source
of truth for the composite-draw/shader-loop detail) and archive
[Slice 36](roadmap/archive/slice-36.md).

Simulation LOD and render visibility are separate policies: tier, halos, and scope
gathers control fixed-step processor participation; camera chunk window, pixel
AABB, and render overscan control draw-record construction. Simulation scope
comes only from the fixed-step camera (`GameDemoState.simViewRect()` passed as
`SimulationPipelineUpdateContext.sim_view`, read through the pipeline's
`simViewRegion` / `WorldSystem.cognitionRegionForWorldRect`), never from the
render visibility window, which follows the interpolated render camera and so
depends on frame pacing. Scope pin metadata
may keep an entity in a higher sim band off-camera without bypassing render
visibility (`.claude/rules/simulation.md`). Open scaling gaps (collect scan cost, dense-floor layer quads,
movement contiguous-path vs dormant rows, per-entity depth alignment, component
mask headroom) are consolidated under **Scaling Gaps And Hardening Frontier** in
[`docs/roadmap/scaling-gaps.md`](roadmap/scaling-gaps.md).

Game code submits sprites and rectangles through `Renderer` using prepared
resource handles. Asset paths and PNG decode stay in `src/assets`; renderer
texture creation starts from decoded pixels and owns only the GPU texture
resource. `Engine` owns `RuntimeAssets`, which preloads declared sprites through
`AssetCache`, keeps retained texture lease tokens, releases them through the
live cache/renderer owner, and exposes `SpriteAssetId` lookup as atlas-ready
`{ texture, source_rect }` records. Hot entity render paths resolve stable IDs
through this catalog and fall back to primitive rectangles when a declared actor
sprite is unavailable. World tile rendering is strict: `WorldSystem` requires
world atlas metadata during construction and the world tileset texture during
render. Engine-owned services keep no pointers to sibling service fields;
release paths take the live owner explicitly. Cache lease tokens include
cache-owner identity, slot generation, and texture identity so release paths can
reject stale, forged, or wrong-owner tokens. Missing declared startup content is
logged and exposed as unavailable; fatal preload errors roll back partial sprite
work instead of leaving retained renderer resources behind.

Generated text follows the render-service ownership rule. `TextService` owns
SDL_ttf, loaded fonts, and generated renderer text textures for the app
lifetime. UI states describe text intent during render and receive only
non-owning prepared text views when the intent changes. Stable render frames
draw those prepared views directly, without re-checking the text cache. State
teardown is service-free.

Game states request SFX and music through `AudioCommandBuffer` in
`UpdateContext` using stable `AudioAssetId` values. `AudioService` is app-owned
because SDL_mixer device, mixer, track pool, loaded-audio cache, bus gains, and
pause ducking are process-level runtime services. Startup preload resolves
declared audio paths before command drain; fixed-step audio commands carry IDs,
gain, priority, frequency, and position only. States own no `MIX_Mixer`,
`MIX_Track`, or loaded `MIX_Audio` handles. `Engine` drains audio commands on
the main thread after fixed-step state updates and state transition application.
Gameplay pause stops active SFX and ducks music; resume restores music gain.
Game-side audio policy — which intents to emit, jet-loop edge detection, and SFX
cooldowns — is the pipeline-owned `AudioController`; the gameplay state passes the
borrowed command buffer through the pipeline at its input/contact seams and holds
no audio-policy state.

Raw keyboard and gamepad input map to named actions in `src/app/input.zig`;
`src/app/gamepad.zig` owns the single-active-device lifecycle that decides
which `*SDL_Gamepad` (if any) supplies gamepad-sourced events. `input_router.zig`
applies the active state stack's action contexts before mutating held gameplay
actions in `InputState` or one-frame UI/app/debug commands in `FrameCommands`,
treating keyboard key events and gamepad button events through the same
policy/latch path, and gating analog left-stick axis motion on the `.gameplay`
context. State `handleEvent` methods still receive raw SDL events according to
stack policy, so named-action routing and raw event handling stay separate.

State policies decide whether lower states receive updates, events, or render
passes. Transitions are queued through `StateTransitions` and applied after the
current dispatch completes.

Pause notifications via `pauseActive`/`resumeActive` target the active `replaceGameplay`
state (via the `StatePolicy.gameplay` flag on `StateStack`) so `GameDemoState` (and its
`syncInterpolatedState` for movement/particles) receive the call even if overlays or the
`PauseState` modal are present on top. `PauseController` + `Engine` gate entry (user + policy)
so the pause overlay + associated side effects are never shown or applied over menus or
non-gameplay states.

## Configuration And Diagnostics

`AppConfig` is the runtime contract for app metadata, asset root, resolution
policy, window flags, GPU validation, frames in flight, present mode, clear
color, audio settings, and thread-system settings. `src/main.zig` builds it from
generated build options, then `Engine` validates it before creating SDL,
renderer, asset, audio, text, state, pause, input, and thread-system services.

Logging uses the scoped categories in `src/core/logging.zig`, with the default
log level chosen from build options; diagnostics cover startup, configuration,
fallback, lifecycle, and failure context, and hot paths stay quiet
(`.claude/rules/zig-style.md`).

## Thread System

`Engine` creates a `ThreadSystem` and passes it through `UpdateContext` and
`RenderContext`. Game states and processors use `parallelFor` for parallel CPU
work that must finish before the next system or render phase.

Worker threads are pre-spawned at startup. The default worker thread count is based
on CPU count, with the main/render thread participating as an additional worker
while it waits. Batch submission does not allocate after initialization.
Production worker participation is timing-adaptive: batches start inline and
move to worker participation only when measured completion time shows the
threaded profile is worthwhile. Structural limits still force inline execution
when there is no work, no available worker, only one splittable range, an
explicit serial override, or a processor range-alignment constraint leaves no
safe split.

Adaptive work tuning chooses a complete batch profile: inline or threaded,
worker threads, and items per claimed range. Worker count and range size remain
distinct knobs, but `AdaptiveWorkTuner` measures them together so one controller
owns the decision. The tuner starts inline, records that inline baseline for the
owning batch, probes a threaded profile when the measured work is expensive
enough, and only reports a best threaded profile after a threaded candidate wins.
Each decision reads the median of a short sample window, so one spike or one
near-free batch never decides alone. A batch outside the learned item-count band
runs with the current profile without being sampled; a full window of them in a
row on the same side is a sustained shift, which re-tunes a threaded stage at the
new count and relearns an inline one; that retune re-bases on the incumbent profile
at the new count and commits a climb only at the threaded commit margin (5%), while
the periodic retune keeps the measured best and the 1% margin. A settled
threaded-to-inline demotion remembers its threaded profile, and the first inline
window judges it: at or above the gate, with the profile still dispatching threaded
at that count, the profile is restored at once and the bound rule is suppressed
until the next retune probe or sustained shift; otherwise the demotion stands. Main
waiting on workers never demotes a stage. There are no static item-count floors
(`.claude/rules/threading.md`);
slower hardware or expensive small-N processors train their own threaded
profile. The tuner counts closed probe windows and demotions for `--details`
(`probes=`, `demotes=`); the counters compile to nothing in ReleaseFast and
ReleaseSmall and no policy reads them.
Reported `worker_threads` counts are background worker threads only; the main
thread is not included in that count and may also process ranges while waiting
for the batch barrier.
Production processors own their own tuner state so movement, particles,
collision, and future systems never train each other with unrelated batch
timings; `ThreadSystem` keeps shared fallback state for generic callers. Batches
can still force explicit fixed profiles through `items_per_range`,
`max_worker_threads`, and `adaptive = false`. Worker threads are reused across
frame batches, parked when idle, and joined during `ThreadSystem` shutdown.
Processor-specific batches can align range starts to hot-column boundaries
through `parallelForWithOptions`.

Systems with multiple independently timed threaded stages own one tuner per
stage (broadphase and narrowphase, AI gather and decision emission). A stage
that preselects a profile passes it with its own tuner, so inline samples still
train that stage, and diagnostics report inline stages as `inline`
(`.claude/rules/threading.md`).

`thread_system.zig` holds the one copy of the stage pattern: `StageControls`
(`items_per_range`, `max_worker_threads`, `adaptive`; every stage takes a per-stage
worker cap, which production leaves unset), `Dispatch` (select a profile under the
stage's tuner, then run it), `StageThreads(Config)` (a system's thread system plus
config), `stageShape`/`runShaped`/`runStage` (pre-size range windows for the shape
the dispatch will use, then run), and `RoundDispatch` (a multi-round stage selects
once and records one tuner sample per step). Beside them: the 64-byte
`thread_shared_record_alignment`, `paddingForCacheLine`, `PaddedSlot`/`SlotList`,
`BandPartition`, `inlineBatch`, `accumulateBatch`, and `offMainNs`.

## Gameplay Data

Gameplay states own their own `DataSystem`; it is not an app singleton. The
system stores persistent world entities, per-entity component masks for system
membership queries, and typed SoA data such as movement bodies, facing,
primitive visual intent, and stable sprite asset references.
Collision bounds are stored as dedicated persistent gameplay data rather than
being inferred from render visuals.

Hot gameplay data is stored as scalar columns. The movement-body store exposes
64-byte-aligned `position_x`, `position_y`, `previous_x`, `previous_y`,
`velocity_x`, `velocity_y`, and `speed` slices so update processors can load
lanes directly with `src/core/simd.zig`. Movement processor ranges align
to `data_system.movement_range_alignment_items`, which maps one cache line to
sixteen `f32` elements. The same store carries the dense simulation-scope columns
(`tier`, `chunk_x/y`, `stagger_phase`, `always_active`) as separate aligned arrays
in lockstep with the movement rows; the movement processor's slice omits them, so
movement integration never touches their cache lines. Component masks decide
whether an entity belongs to a system; hot processors iterate already aligned SoA
slices.

Gameplay states own their `DataSystem`, a transient `SimulationFrame`, and a
state-owned `SimulationPipeline` for each fixed step. The state clears the
frame, runs main-thread input writes, delegates fixed-step processor dispatch to
the pipeline, and applies deferred structural commands at explicit main-thread
commit points. `DataSystem` remains persistent storage, not the simulation
scheduler.

Large world surfaces belong to state-owned world storage rather than
`DataSystem` entities or the simulation pipeline. `GameDemoState` owns its
`WorldSystem`, whose persistent storage holds stable tile IDs, atlas
source-rect columns, level base-z columns, dense layers, and sparse tile
columns. Dense tiles live per chunk: each layer's chunk directory holds a
uniform tile or a block index into a pool of chunk-sized tile blocks, and a
block returns to uniform when a write leaves its in-level cells holding one
tile, whichever tile (an O(1) count of unequal neighbors along a row-major cell
chain). Pool growth is counted (`terrain_pool_grows`) and logged once.
Each level's `LevelTerrain` keeps its band list (growable: a band add is never
refused, and a batched edit carries per-group band bits sized to the widest
touched level), its floor layer (so `denseFloorLayerForLevel` is O(1)), and
composed movement-blocked bits per chunk
(OPEN, BLOCKED, or a bit block), so `levelBlocksMovement` is O(1) and a write
recomposes only its own cell. Level links are append-only and indexed per
endpoint chunk (per-chunk heads and counts), so `levelChunkLinkEndpoints` (and
`rampLinkOtherLevel` on it) walks one chunk's endpoints. Sparse tiles chain per
chunk both ways, so an add or remove is O(1) and a chunk's sparse tiles are one
walk. A dig or fall carve reserves its growth with
`reserveDenseCellWrite` (and `reserveLevelLink`) before any mutation, so an OOM
leaves the step's state intact; a ramp dig also clears its exit cell on the
level above (`reserveClearCellBlocking`/`clearCellBlocking`: blocking bands to
the floor tile or empty, blocking sparse tiles unlinked from their chunk's chain,
O(bands + sparse tiles in the chunk)) and emits its `world_obstacle_changed` with the ramp's
`world_tile_changed`; a local change costs only the chunks it touches, and
adding a level costs only its own directories. A dense one-step change (cave-in,
explosion, the step's fall carves) goes through `applyDenseCellWrites`: writes
arrive grouped by chunk (`groupDenseCellWrites` groups a batch given in any order
in O(1) per write through each level's ordered chunk set, with no sort), storage
is reserved on the main thread first (`reserveDenseCellWrites`), chunks are written in parallel on the
`ThreadSystem`, and results merge in a fixed order, so threaded equals serial
(`.claude/rules/threading.md`). A write marks its block changed and, on a layer
resident in the GPU tile store, flags the layer for the next
`syncDenseTileStore`, which uploads each changed window chunk once; edits hold
no render memory. Dense layers can be added in play. Visibility is the
cached render chunk window, not per-chunk rows. `WorldSystem` prepares world draw records during
render, using explicit world-depth bands from `src/game/render_depth.zig`.
Runtime gameplay construction uses the Engine-owned `ThreadSystem` to build the
procedural 512x512 tile world in deterministic chunk ranges. The gameplay state
keeps viewport size separate from world bounds, follows the player with an
interpolated sub-pixel camera, and asks `WorldSystem` to expose only
camera-visible chunks to render prep. Simulation scope uses the fixed-step
`sim_view` region, never the render window; `SimulationPipeline` owns no tile
storage, runtime atlas metadata, or camera policy.

The current gameplay fixed-step pipeline is:

1. Clear `SimulationFrame` and mark the step active.
2. Apply main-thread player input and queue fixed-step audio commands.
3. `SimulationPipeline` runs its comptime-checked `stage_order` (see
   `.claude/rules/simulation.md` and
   `docs/simulation-tiers-and-pipeline.md` for the full contract):
   at step open: promote prior-step deferred impacts onto the live bus, then
   `dig_world_edit` (author world-tile edits from player digging), then at most
   one player footstep when velocity is non-trivial — all before
   `perception_update` reads `frame.stimuli` → `scope_advance_and_ai_gather` →
   `spatial_index_build` (shared `SpatialIndexSystem`, Slice 28) →
   `perception_update` (vision/hearing,
   Slice 29) → `ai_memory_update` (Slice 30) → `affect_update` (Slice 31) →
   `ai_decide` → `path_goal_resolve` (the step's goal table) →
   `steering_update` → `pathfinding_update` (frame-delayed) →
   `apply_ai_movement_intents` → `movement_integrate` →
   `collision_scope_gather` → `collision_detect` → `collision_respond` →
   `bounds_and_tile_gate` (world bounds clamp + solid-tile gate; after
   collision so a contact push into dirt is re-gated) →
   `plane_traversal` (ramp/fall/carve/snap) → `chunk_derive` →
   `action_react` (destructible / action-intent consumers) →
   `tier_policy` (deferred `set_simulation_tier` commands).
4. Queue contact audio, emit/update transient particles, and merge outputs.
5. Update the state-owned follow camera and visible world chunks.
6. The structural-commit seam, in order: reserve the static-collider rows and
   static nav marks, commit deferred structural commands to `DataSystem` under the
   budgeted all-or-fail commit, capture the step's static changes into the
   collider's dirty list, run `SimulationPipeline.syncPopulationCapacity` (the
   population growth seam), sync the static colliders (recording their nav marks;
   it runs even when the growth seam failed), then the post-commit reactions:
   `reactToPostCommitNavEvents` (only after a successful growth seam and collider
   sync, else every mark stays for the next step) and
   `reactToPostCommitSteeringEvents` (always). The first growth, collider, or nav
   error is returned only after the steering reaction has run. The demo state holds
   this order (`commitStructuralAndReact`).
7. Render current `WorldSystem`, `DataSystem`, and particle state with
   interpolation.

`SimulationPipeline` owns the reusable fixed-step simulation systems, concrete
stage order, scope stats, budgets, and processor handoff for one gameplay state
instance, while `StateStack` remains the dispatch/lifetime owner. Domain
features are concrete pipeline-owned controllers; the pipeline is a thin
composer and each controller and system owns its own internals
(`.claude/rules/simulation.md`).

Simulation tiers and active scope belong in the same pipeline boundary. Tier and
chunk metadata are dense SoA columns on the movement-body store
(`tier`, `chunk_x/y`, `stagger_phase`, `always_active`), in lockstep with the
movement rows so they exist exactly for simulated entities and the O(N) scope
passes read/write aligned columns rather than scattered slots. The pipeline-owned
`SimulationScopeSystem` (`src/game/systems/simulation_scope.zig`) is the backbone
that derives the camera cognition halo from `WorldSystem` and selects which entities
enter each stage; entity chunk columns are derived by the dedicated late `chunk_derive`
stage, ordered after every `movement_positions` writer so tier policy and render prep
read chunks matching each body's final settled position.
Processors keep their hot loops and receive a `scope_dense_indices` option
(null = full-active) instead of learning world/chunk policy. Movement and
collision gate on tier only (no chunk filter, so off-screen entities keep moving
and colliding) and short-circuit to full-active in O(1) via incremental
`tier_counts` when nothing is dormant/kinematic; **cognition thinking** (perception
observers, memory, affect, AI decide) gates on tier + camera halo + a per-entity
stagger cadence, while the shared spatial index and perception **candidates** are
built from the unstaggered cognition halo so off-phase agents remain visible;
steering inherits think-set scope transitively through the navigation-intent
stream. Tier wake/sleep changes flow through deferred
`set_simulation_tier` structural commands at the commit seam, never inside worker
ranges. Scope bounds active work per step; benches at large counts show how
each stage scales (`.claude/rules/tests-benchmarks.md`).

The durable tier model is capability-based, not visibility-based:
`dormant` entities exist but do not enter normal active scope (today every
row not `always_active` past `kinematic_halo_chunks` of the sim-view region;
the Target Model keeps `dormant` for inert things), `kinematic`
entities run movement integration, `locomotion` entities add collision
detection/response, and `cognition` entities add AI, steering, and path
requests. Scope then decides which worlds, chunks, chunk halos, or
staggered/reduced-cadence groups enter those tiered stages for the current
fixed step.

Emergent NPC behavior layers on the cognition tier. Perception, memory, and
**affect (feelings / emotion drives)** are durable per-entity concepts that live
as SoA components in `DataSystem` and are advanced by cognition-gated processor
stages in `src/game/systems/`, alongside AI, steering, and pathfinding, with
allocation-free hot paths, serial/threaded and scalar/SIMD parity,
range-disjoint output, and explicit barriers like every other processor. Dense per-step sensing/affect data stays in component columns
or transient range streams; only notable transitions become low-volume domain
events (`entity_perceived` / `entity_lost`, `affect_threshold_crossed`, and
similar). Cross-entity classification (faction/stance), a deterministic
per-entity RNG facility in `src/core`, and a shared per-frame spatial index are
shared substrate these stages consume. Because they *think* only for in-halo, on-phase cognition entities, their
think cost scales with the stagger-filtered set (~N/4), not total entity
count; the shared index and candidate table scale with the unstaggered halo.

**Emotion model (Slice 31 substrate):** `AiAffect` stores independent scalar
drives (`fear`, `curiosity`, `aggression`, `fatigue`) in `[0, 1]`, each with
per-entity baseline, decay rate, and threshold. `AffectSystem` appraises them
from perception/memory (optional per row) and emits rising/falling threshold
edges only. Behavior arbitration (`src/game/systems/arbitration.zig`, Slice
32) consumes these drive columns directly: `scoreBehaviors` sums each drive
against a fixed `[drive_count][behavior_count]f32` weight table (fear→flee,
aggression→pursue, curiosity→investigate, fatigue→wander), scaled by the
agent's own `AiAgent.gain_*` personality gains. `AiConfig.affect_slice`
threads `DataSystem.aiAffectSliceConst()` into `AiSystem`, and
`stageContract(.ai_decide)` reads `affect_drives` (written one stage earlier
by `affect_update`, per `stage_order`). Adding a feeling:
`.claude/rules/simulation.md` § AI and affect (roadmap
[Slice 42](roadmap/slices/slice-42.md)). See the
[Emergent AI Track Overview](roadmap/tracks/emergent-ai.md).

The pipeline is also the right place to compose light domain controllers for
features such as combat, spawning, rules, encounters, or other gameplay
domains. Controllers own feature orchestration: small queues, budgets,
cooldowns, priority/conflict policy, and handoff between processors. They
emit `SimulationFrame` outputs or deferred structural commands and call
processors with typed `DataSystem` views (`.claude/rules/simulation.md`).

Landed pipeline-owned domain controllers (beside processors):

- `DigController` — dig intents → world-tile edits + stimuli/events, and plane
  traversal: `PlaneEntrySystem` gathers, on workers, each AI agent that entered a
  new cell where it could change plane (a ramp-link cell, or a hole with a level
  below) or lacks `world_level`, and classifies that cell there (`PlaneTarget`:
  the action, target level, landing floor layer, whether a carve is needed;
  through the one `planeTarget` the player's own path also uses). The reserve
  then decides every traversal in commit order in O(1) per entry through
  stamp-cleared plane claims (`StampedTable`: shut holes, deduped landings, an
  exact carve count), and the step's carves go out as one (level, chunk)-ordered
  `applyDenseCellWrites` batch on `carve_controls`, all-or-nothing, its scratch
  reserved and counted at the plane reserve; carve events are in (level, chunk,
  cell) order. Main is O(1) per entry and flat in agents on steps with no entry.
- `SensoryBus` — deferred impacts, sticky dig/impact linger, and the hearing scratch. Promote and footstep run in `dig_world_edit`; perception reads `hearingSlice` then `advanceSticky`; collision response enqueues the next step's impacts
- `AudioController` — ambient + collision SFX queues (no SDL in the controller). Impact gain uses the same penetration scale as `SensoryBus`
- `DestructibleController` (Slice 45) — first `action_intents` consumer:
  interact/attack → deferred `destroy_entity`/`set_destructible` +
  `destructible_destroyed` domain event; optional soft-drop particle burst

Non-locomotion player/AI requests flow through `SimulationFrame.action_intents`
(Slice 40), consumed at explicit `action_react` by `DestructibleController`
(and future combat/rules controllers) — not through `NavigationIntent` or the
pathfinder. Locomotion stays on `navigation_intents` → steering → `intents`
(movement).

Processors run behind explicit barriers. Each ordered system finishes its serial
or threaded work, merges any range-owned output in stable order, and only then
allows the next system to consume the result. Deferred structural commands are
prevalidated before the main-thread commit mutates `DataSystem`, so validation
failures do not partially apply a command batch.

Update processors receive typed slices or views from `DataSystem` during
fixed-step updates instead of broad structural access. Render systems read
immutable world and entity slices during state render, resolve stable tile IDs,
sprite IDs, and atlas-entry IDs through `RuntimeAssets`, and submit draw calls
through `Renderer`. `DataSystem` does not own SDL handles, GPU handles,
SDL_mixer handles, live renderer texture IDs, prepared sprite records, asset
leases, audio command buffers, input frame state, thread-system state,
transient events, tile maps, or scratch buffers.

`MovementSystem` updates movement-body slices as an ordered gameplay data
processor, using SIMD lanes inside each assigned range and
`ThreadSystem.parallelForWithOptions` when completion-time feedback shows the
batch is large enough. Worker ranges are aligned to movement cache-line
boundaries and only write their assigned movement rows.
`MovementSystem.applyIntents` (`apply_ai_movement_intents`) runs over the step's
merged movement intents as a threaded stage with its own tuner and an inline path:
one dense-index resolve per intent (`DataSystem.aiMovementDenseIndex`), a 4-lane
SIMD velocity block (default speed where speed is not positive) with a
bit-identical scalar finish, and velocity written in place at each intent's
movement row. Rows are disjoint because `SimulationFrame.intents` carries at most
one movement intent per entity per step (steering's first claim), asserted at the
stage; main keeps O(ranges) dispatch. The rows are scattered across the velocity
columns, which `threading.md` allows: `movement-apply-intents-sorted` is its
row-order control.

`CollisionSystem` is a high-throughput contact generator over entities that have
both movement bodies and collision bounds. It owns warmed, 64-byte-aligned AABB
proxy scratch, preserves a sorted sweep-and-prune order across fixed steps, and
threads broadphase anchor ranges through `ThreadSystem` to emit candidate pairs
once with SIMD Y-overlap filtering. Narrowphase then uses its own threaded batch
over candidate pairs, computes AABB contact math with SIMD lanes inside each
worker range, and merges range-owned contact buffers deterministically for
same-step response. Thread-written range scratch is cache-line padded;
persistent collision component data is not padded by default. Broadphase and
narrowphase keep separate adaptive tuners and batch stats so each stage is
measured against its own workload; benchmark detail rows report narrowphase
separately so an inline narrowphase cannot be mistaken for a broadphase tuning
result.
Contacts are transient `SimulationFrame` data; `CollisionResponseSystem`
consumes the completed same-step contact stream through explicit response-policy
components in two threaded stages, each with its own tuner and an inline path.
`gather` (over contacts) classifies each contact, resolves each response intent's
movement row, writes its range's windows of intents, triggers, and observer
contacts, and runs the intent math with `src/core/simd.zig`; with workers it also
places its intents by 16-row movement band, and `apply` (over bands) applies, for
the rows each band owns, every gather range's segment in range order (a 4-lane
SIMD block, flushed when a row repeats). An inline gather applies its own window
inside its timed range, so its tuner measures everything the inline choice keeps
on main. Either way each movement row takes its intents in contact order, so the
result is bit-identical for any worker count, range size, or tuner decision. Main
does O(ranges) tallies, merges the trigger stream and observer contacts in range
order (O(1) per record), and reserves everything before dispatch.
`observerContacts` (the contacts naming the observer) serves player impacts and
collision audio, replacing two scans of every contact.

`PerceptionSystem` (`src/game/systems/perception.zig`, Slice 29) runs over the
cognition-scoped `AiPerception` subset right after the shared spatial index is
built, reusing the same `SpatialIndexView` `AiSystem` consumes rather than
building its own grid. Vision applies range/FOV/line-of-sight gating (faction
stance and same-level checks included). `hasLineOfSight` walks every grid
cell the segment touches past the observer's own cell, bounded by the ray's
own cell count (|dcx| + |dcy|). Through an exact grid corner either side cell
blocks (pathfinding's no-corner-cutting rule), and a ray along a grid line also
tests the cells across it, so LOS is symmetric between two open cells. The
level's composed blocked bits are resolved once per ray
(`WorldSystem.levelBlockedView`), then each cell is O(1) on its chunk's bits;
an invalid level or a point off the world is blocked. Perception keeps no LOS
state and has no post-commit reaction; `perception_update` reads `world_tiles`
after `dig_world_edit`, so a same-step edit occludes, and serial and threaded
ranges read the same const world. Hearing folds
into the same per-agent pass as a same-level squared-distance check against
`SimulationFrame.stimuli`, a transient per-step positional buffer that
`SensoryBus` feeds (Slice 39, placed by Slice 48): deferred-promoted
`.impact`, a required same-step `.dig` from `DigController`, and an optional
same-step `.footstep` from player velocity — all before `PerceptionSystem` hearing.
Cognition does not read `AudioCommandBuffer`; audio may play in parallel for presentation
only. Dense per-step results (visibility,
last-seen position, nearest threat, heard stimulus) write to `PerceptionStore`
hot columns; only acquisition/loss transitions emit low-volume
`entity_perceived`/`entity_lost` domain events, capped per step by
`SimulationPipelineConfig.perception_max_events_per_step` (caller-sized
against the pipeline's real per-step event capacity, not a floating library
default) with drops surfaced through event stats rather than an unhandled
capacity error.

`AiSystem` (first AI processor) is a decision emitter over ai_agent entities.
It receives const AiAgent + movement prior-position slices and a read-only
`SpatialIndexView` from the pipeline-owned `SpatialIndexSystem`
(`src/game/systems/spatial_index.zig`, Slice 28) — the shared per-step spatial
index, built once from the unstaggered cognition halo, that AI
separation queries for bounded local-separation samples instead of building
its own grid. Think rows map into halo rows via `spatial_self_index`. Per row, `AiSystem` gathers perception/memory/affect signals
(each independently optional; an absent component contributes zero signal)
into `arbitration.Signals` and runs them through
`src/game/systems/arbitration.zig`'s pure utility-arbitration chain:
`scoreBehaviors` (the table-driven drive×behavior scoring above) picks a raw
winner among `wander`/`pursue`/`flee`/`investigate`/`cohere`; `selectSticky`
applies sticky hysteresis, holding the previous behavior while
`commitment_remaining > 0` unless a challenger clears
`sticky_bonus + min_delta`, otherwise argmaxing with ties broken by lowest
enum index; `resolveGoal` then resolves a concrete per-agent goal for the
selected behavior — pursue and flee prefer a visible or freshly-remembered
hostile-faction entity (perception's faction-generic `nearest_threat`, not a
player special case) over the opt-in `AiConfig.focus_target`/`focus_entity`
fallback, which only applies as a last resort when the agent's pursue gain is
nonzero and no better signal exists; investigate resolves goals in priority
order **heard stimulus → nearest in-range world interest marker → freshest
`AiMemory` ring contact** (stimulus still wins short-term over markers;
`investigate_interest_marker_bonus` sits between ring and stimulus scoring).
The separation job queries `WorldSystem.interest_markers` read-only (fixed
radius, not world-sized) only for rows with `gain_investigate > 0`. Gather
stores the row's level and does not scan. Cohere reads a friendly-neighbor mean
gathered from the same shared spatial index. This utility arbitration decides
*what* an agent wants (a behavior and a goal); it is a distinct mechanism from
`SteeringSystem`'s stream-priority arbitration below, which decides *which*
emitter wins when multiple systems submit a `NavigationIntent` for the same
entity. `AiSystem` then emits threaded navigation intents through
`SimulationFrame.navigation_intents` (count/prefix/write). Separation and
intent emission have independent AdaptiveWorkTuner state and benchmark stats
so each stage can remain inline or thread independently; the index build has
its own separate tuner on `SpatialIndexSystem`. `CollisionSystem`'s
sweep-and-prune broadphase (see above) is intentionally not ported onto this
index — it is a different, already-tuned algorithm, not a duplicate grid
build.

`SteeringSystem` consumes `NavigationIntent` rows, dense `SteeringAgent`
component data, movement slices, the shared static-collider rows, and
frame-delayed `PathfindingSystem` status. It owns runtime path-following rows
(indexed by steering row; an O(k) main-thread rekey follows the rows a commit
swap-removed), replan cooldowns, unavailable-path backoff, stuck counters, and its
agent grid outside `DataSystem`. Its prepare phase runs as threaded stages, each
with its own tuner and an inline path: `agents` (runtime tick, agent snapshot,
movement-index refresh), `select_resolve` and `select_claim` (one intent per
steering row, banded first-appearance and best-intent claims with per-step
stamps), `directions` (path status and base direction, SIMD tail, per-item path
request prefixes), and `grid_bucket`/`grid_sort` (the agent grid in 64
count-balanced cell-key bands whose splitters are quantiles of up to 256 rows
sampled on main in a golden-ratio sequence, so clustered and corridor crowds split
like uniform ones; a cell never straddles bands). With threads, a stage its tuner
keeps inline runs the same job as threaded; the serial and zero-worker paths keep
the single pass and single sort. Main keeps per-range and per-band bookkeeping,
the splitters, and the rekey. The avoidance pass emits final NPC
`MovementIntent`s through deterministic threaded range writes to
`SimulationFrame.intents`, and the movement job writes path requests per range
from the prefixes. Static avoidance queries `ColliderView.queryBox` (largest size
class first, at most 64 box hits and 512 probes per agent) and pushes with SIMD
over the packed hits, so a static change costs steering nothing; agent-agent
avoidance reads the agent grid. Steering follows a `.partial` path like
`.available`, requests the next hop on its replan cooldown once inside the end's
refresh window, and holds at the end with no direction.
Priority arbitration chooses the highest-priority navigation intent per entity
with stable stream order as the tie-breaker.
Player movement remains direct input with no steering component, while collision
response still resolves after movement.

`PathfindingSystem` (`src/game/systems/pathfinding/`) is a frame-delayed, Z-aware
grid pathfinding processor (rules: `.claude/rules/pathfinding.md`). It runs two
solver modes per request kind: budget-bounded goal-keyed A* for individual goals,
and a demand-driven shared-goal reverse-Dijkstra flow field for declared `group`
requests. It owns the nav graph (§ Nav Graph And Reaction), the pending queue (a
`std.Deque`), the goal table, the goal-keyed result cache and its path registry,
the group fields, per-participant search scratch, the tier-1 corridor pool, and a
tuner per stage. `SimulationFrame.path_requests` carries transient requests from
steering; queues, scratch, thread state, and caches stay out of `DataSystem`.
Results are consumed on later steps, so a missing path never stalls same-step
movement. `PathfindingCapacity` is configuration only (agent ceiling, search and
field budgets, policy knobs). Pools are sized by a private `Limits` derived from it
and the elastic capacity; each step's gates (`StepGates`: frame and pending at
`max(agents, 8)`, group tallies at `min(512, that)`) derive only from the live
steering-agent count, so admission never depends on capacity history (the result
cache still does; Slice 64G checklist). The fixed-step work:

- `path_goal_resolve` (its own pipeline stage, before steering) builds the step's
  goal table: one projection per distinct blocked goal key (nearest open cell
  within `default_goal_projection_radius`, 16), shared by every status query,
  intake request, group-field decision, and solve that step. Two threaded stages,
  `goal_scan` over intents and `goal_project` over distinct blocked goals, with an
  ordered main merge between them; any grid change invalidates the table.
- `path_intake` converts start and goal cells four requests per
  `src/core/simd.zig` vector; ranges classify against step-start state into their
  windows, and the main thread merges the windows in range order (group tallies,
  expired results, in-step duplicates, pending pushes past the pending gate
  dropped deterministically and re-requested on `.missing`), one classifier for
  every partition; a step carries at most one request per steering agent
  (asserted). Each request is answered
  `unavailable` (no open goal cell within the radius, or reach says the open start
  cannot reach the live goal), a cache hit (a fresh result whose stored goal cell
  is the live goal, unless it is partial and the start lies in its end's refresh
  window), or a candidate. Agents that share a goal key share one pending entry.
- `group_field_expand` advances building fields (one item per field, an advance
  pass before the main-thread slot decisions and a begin pass after; stall rounds
  have their own tuner).
- The solve batch admits up to the per-step ceiling (`default_max_solves_per_frame`
  512, a fixed count; at most `max_escalated_solves_per_step` of them tier-1) and
  writes each output at its solve ordinal; branch-heavy A* frontier work stays
  scalar inside threaded ranges.
- Publish: the main thread claims slots, payloads, and long blocks in order, O(1)
  per result (a claim is never another claim's victim in the same publish);
  `publish_copy` copies path bytes and buckets each path's registry runs per shard
  on workers. `registry_flush` then applies the owner log (retire, rename) and adds
  per shard, appending each shard's sorted segment with one probe per run of
  same-key records (`ChunkListMap.addAll`); its items are work units over the 16 shard pairs (a pair weighs its
  ops plus its adds plus one), a range runs the pairs whose first unit lies in it,
  and at most 15 workers dispatch. Pending compaction costs the solve window, not the queue.

Reachability answers before any search (`pathfinding.md`). Status, intake, and solve
read, in order, the live goal (the key's cell when open, else its projection from
the goal table), reach (`connectivity.reach`, O(1): `start_blocked`, `reaches`, or
`unreachable_goal`), the cache (served only when its stored goal cell is the live
goal), and pending. Reach is keyed by `TraversalClass` (one per way agents move;
`walk` today), so a new class adds a connectivity instance. An accepted request
whose goal became unreachable answers at solve with no search.

A solve on one level within one chunk-local component runs local A* in the
participant's `SearchScratch`: an AoS table of 16 B slots (cell, stamp with closed
bit, g, parent slot) at `ceilPow2(2 × budget)` rows (`stamped_table.zig`), a
per-solve explored budget of min(capacity, reserved limit), and an open heap at
`openHeapLimit` (4 entries per budgeted node, lazy pop-skip of superseded entries)
whose sifts move a hole and store the moving node once. Anything else routes
through the abstract chunk graph: abstract A* over the per-chunk records' portals
and links picks a corridor (abstract slots cache cell coordinates and portal
label), then `stitchCorridor` runs local A* per corridor segment (a link is one
discrete jump) into one obstacle-aware (level, cell) path, at most
`max_stitch_segments` (512) segment searches per solve. The query walks it cell by
cell on the agent's level. A two-tier ladder bounds each attempt: tier 0 runs in
the participant's corridor scratch at 4096 abstract nodes and 512 stitched cells;
exhausting it promotes the request once to tier 1, which runs in the tier-1 pool
entry of its escalated admission index at fixed caps of 16384 nodes and 2048 cells,
never derived from world size (`.claude/rules/budgets-capacities.md`). At tier 1:

- a stitch stopped by its cell or segment cap publishes its prefix as `.partial`
  when the prefix leaves its start cell, else drops;
- a segment's node-budget spill drops (the next hop would spill again);
- an abstract saturation publishes `.partial` toward the least-estimate expanded
  node (`LeastExpanded`, O(1) per expansion), its stitch cut to the last cell whose
  estimate lies below the start's (`cutBelowStart`), else drops. On an unchanged
  graph each such hop ends strictly below its start's estimate, so a hop chain
  requested from exact ends advances;
- a drop leaves no negative: the next query reads `.missing` and the requester
  retries on its replan cooldown. An exhausted budget is never `unavailable`.

`PathView.refresh` marks a start inside a partial's end window (the end's level,
Chebyshev distance at most one nav chunk side, `inPartialRefreshWindow`, which
status and intake share), where a request re-solves instead of hitting the cache;
a re-solve from inside the window costs at most one request per cooldown.

The abstract heuristic (`CrossLevelHeuristic`) is admissible and consistent on
every edge kind, so corridors are optimal. On the goal level it is octile. Off it,
h = min(max(h_short, crossing distance), long term):

- h_short prices K = ceil(level gap / widest crossing span) crossings by the
  cheapest level-crossing short link (a link whose cost covers its planar octile).
- The crossing distance is a lazy Dijkstra from the goal (`CrossingSearch`) over
  each level's departing short crossing links clustered into at most 16 boxes plus
  an arrival window (`NavGraph.level_crossings`, about 840 B per level), exact in a
  relaxed graph (free octile per level, boxes at least cost). Its budget is the
  search's node budget / 4 settles (`crossingBoxBudget`); past it the search
  freezes at the distance of the settle in progress, so h stays a pure function of
  (graph, goal, budget). A 16-entry level-indexed cache keeps gathered boxes
  (on the 127-level descent probe, 49,944 gathers became 266, `41afa5f`).
  Work starts only when a search evaluates a level other than the goal's.
- The long term is the least, over at most 16 directed long-link pairs (entrance
  box, exit box, least cost; merged on combined entrance+exit volume at the cap),
  of the node's entrance-box term plus the pair's cost and its chain bound to the
  goal (`LinkBounds.chains`: a min-plus closure of pair chains under the crossing
  rates). Per query the exit lanes and a lazy 16×16 min-plus run once; per push,
  two gates and one SIMD offset scan over the pairs' lane groups.
- `LinkBounds` and `level_crossings` fold once per link where links enter the graph
  (world build, marks commit): O(1) per link, the pair chain closure once per batch
  that changes the pairs or crossing rates. A refold is a no-op; a dig costs the
  heuristic nothing. Links are append-only; a future removal seam refolds both
  from the remaining links.

The result cache (`caches.zig`) is goal-keyed (`.claude/rules/pathfinding.md`): a
`CacheCore` slot table and entry records (4 results per agent; round-robin victims,
never a refusal; TTL 300 steps) whose record index is the owner id in the path
registry. Each entry stores its path exactly in a paged inline stripe of
`max_stored_path_cells` words (a plain path, or a stitched one as SoA words) or one
long block (`resultBlockWords`) from a paged pool the publish reserve grows, at most
one per entry, plus its end and goal cell. A grow appends pages and copies nothing; a
shrink selects survivors by an O(n) radix pass (oldest first, equal to the age
order), `resize_copy` moves path bytes on workers, tail pages free, and the owner log
renames registry owners. A shrink's registry flush runs at a fixed one-range-per-pair
shape outside the flush tuner. The path registry is 16 `ChunkListMap` shards keyed
by (level, chunk) (shard = top bits of `std.hash.int` of the key): every published
path registers each run of consecutive cells on one level in one chunk, so eviction
reaches exactly the results whose cells a change touches.

Group fields (`group_field.zig`) build only for declared group requests whose
decaying per-step tally reaches `min_group_field_agents` (1024 sharers, a fixed
policy constant) and rekey at most once per `group_field_rebuild_min_steps` (8). A
field floods with Dial's monotone bucket queue at `group_field_build_budget` (8192)
pops per step, capped per build at `group_field_max_cells` = budget × 16 steps, so
it is ready within 16 steps on any level; cells past the cap are uncovered and their
agents take individual solves, never `unavailable`. Storage is a per-field pool of
nav-chunk cell blocks under a chunk directory, reserved at the field's first build
and grown on the main thread between expand rounds: a field that runs out stalls
before its pop and resumes the same step, so coverage never depends on pool
capacity, and memory follows covered chunks (measured 13 B per covered cell in an
open crowd, 113–130 B in tunnels, `10bbbc7`). An active goal's field is never
taken: a new goal takes an empty slot, else the least-demanded inactive goal's
(lowest slot on a tie), else waits on individual solves.

Capacity is elastic: `SimulationPipeline.init` sizes the pools for the committed
steering agents through the same helper the population seam uses
(`growPathfindingForAgents`), so the first update after load has nothing to grow;
after that the seam grows them at least 2× for the live agent count
(`growForAgentCount`), never refused (`raiseAgentBudget`), and the update's own
resize remains for shrinks and as the fallback after a failed seam (raising the
ceiling 1.5× past a crowd beyond it). A count below half capacity for
`capacity_shrink_window` (120) steps shrinks them to the larger of the crowd, the
live pending queue, and the live group tallies, never dropping live work, and
keeps the cached results that fit. Every reserve is failure-atomic, and on OOM each table-sizing
budget falls back to min(committed, requested). A budget whose indices cannot hold a
field cap or result block fails with `PathfindingBudgetTooWide`.

The demo player is intentionally a special-case facade for player input and
facing rules, backed by `DataSystem` data. Enemies and other world objects are
plain entities processed by enemy, movement, collision, AI, or render systems.

`ParticleSystem` is the transient visual-effect exception. It is owned by the
game state instead of `DataSystem`, because particles are short-lived effect
rows rather than persistent world entities. Particle emission and expired row
swap-removal run on the state/main thread; threaded jobs only update assigned
SoA ranges and render submits rectangles through `Renderer`.

Simulation outputs coordinate determinism, performance, and efficiency as one
contract. Threaded processors that produce events, intents, contacts, or
deferred structural commands use typed range-owned output buffers: count outputs
per stable range, prefix offsets on the main thread, write contiguous output
slices, merge by range index, and consume the result as a batch. Passes with at
most one output per item (scope gathers and tier policy, the spatial gather, the
collision narrowphase) write fixed per-range windows of one item-count buffer
plus a padded tally and compact in range order, so their capacity-seam reserve
covers every partition (Slice 72 C5). Events derived from per-row state after
the join (perception transitions, affect crossings) use no output buffer at all
(Slice 72 I1/I2).
Output order
comes from stable input/range order, not worker timing or worker IDs. Structural
mutation remains behind `DataSystem` batch commit boundaries. `DataSystem` is
the single source for applying structural commands and may report plain
structural change records to `SimulationFrame`, which maps them into transient
events after the commit succeeds; event and intent streams are transient
simulation data, not persistent `DataSystem` state.

`SimulationFrame` owns `SimulationEvents` as the typed domain-signal hub for
lower-volume system changes. Events are phase outputs, not immediate callbacks:
a producer stage finishes, the event stream merges deterministically, and later
explicit reaction points consume immutable event slices. Consumers may emit
specialized outputs, later-phase events, or deferred structural commands, without
recursive redispatch or structural `DataSystem` mutation outside the commit
boundary. The current event payloads cover structural
entity/component changes, world tile/obstacle changes, and navigation-region
invalidation. Event records carry only stable entity IDs, component enums,
reason enums, compact coordinates, and small scalar payloads
(`.claude/rules/simulation.md`).

High-volume streams stay specialized. Collision contacts, collision triggers,
navigation intents, movement intents, path requests, render-prep commands, and
structural commands are not collapsed into the generic event stream. The event
hub exists for cross-system change signals and diagnostics. Event producers own
their range writes and range-local stats; the stream merges per-type and
per-stage counters deterministically after producer completion. A configured
per-step event capacity is enforced for both appended and range-owned event
producers: required events fail before structural mutation or domain reaction
side effects, while diagnostic events are dropped and counted. Reaction work has
explicit ownership: light orchestration runs inline, and expensive consumers
split over immutable event slices and write range-owned outputs. After the commit point, the
post-commit nav reaction applies the step's terrain and static changes to the
nav graph (§ Nav Graph And Reaction).

### Nav Graph And Reaction

The nav graph (`nav_graph.zig`, `nav_grid.zig`, `connectivity.zig`) is stored per
chunk (`.claude/rules/budgets-capacities.md`). With a world, a nav cell is a tile
and a nav chunk the world's chunk (`NavExtent.world`, one `ChunkGeometry`);
bounds, `nav_cell_size`, and `nav_chunk_tiles` shape only a world-less build.

- **Cells.** Per level, `NavGrid` holds a chunk directory whose entry is OPEN,
  BLOCKED, or a slot in a pool of cell blocks (blocked bits plus chunk-local
  component labels; a uniform chunk holds no cells). A chunk's cells are the
  world's composed blocked bits OR the static colliders listed at that chunk.
  Reads go through a 3×3 neighborhood and a comptime move table.
- **Records.** Per level, `NavLevelGraph` holds one record per chunk that has a
  portal: its border-run portals in a fixed `border_stride` window (at most
  4 × ceil(E / 2)), its open link-endpoint portals, the links leaving them, and one
  connectivity node per portal-bearing label. Records, link slots, and nodes are
  pools with exact free lists (`growPool`), so a release never allocates. Graph
  node ids never leave a batch (`.claude/rules/pathfinding.md`).
- **Connectivity.** Each node's row holds a comp, and every comp hangs off one
  root, so two nodes connect over border mirrors and two-way links exactly when
  their comps share a root. Over the roots sits the exact one-way closure: a
  terminal is a root holding an endpoint of a live one-way link, an H-component a
  weak component of terminals over those links, and each H-component owns its
  reachability matrix (one bit row per terminal) in a block of its own, freed with
  it. Memory follows nodes and terminals; a one-way system of k terminals holds
  about k²/32 words, inherent to an exact table.
- **Statics.** `StaticColliderSystem` rows (one per static navigation obstacle:
  committed AABB, level, cell span) are listed per (level, chunk) in a
  `ChunkListMap` in entity-index order, plus a query tier (a size-class map with
  per-chunk anchor bitmaps) for `ColliderView.queryBox`. The commit seam captures
  the step's entity changes into a persistent dirty list; `sync` applies them with
  O(1) main work per change and a threaded `static_collider_splice` stage that
  places list entries in entity order, so a static add, move, or destroy costs its
  own footprint chunks, never the static count.

`PathfindingSystem` owns the post-commit nav reaction end to end
(`.claude/rules/pathfinding.md`). Writers record what changed, never the reaction:
a terrain writer (the dig stage, plane traversal's carve batch) reserves its record
before its world write (`reserveTerrainNavRecord`) and records its appended events
right after it, even when it failed after writing (`recordTerrainNavEvents`, the
`nav_mark` stage interpreting events into per-range windows that merge tile boxes
of one chunk); the collider sync records each change's old and new cell spans
(`recordStaticColliderChanges`, room reserved before the commit by
`reserveStaticColliderMarks`). At the seam `reactToPostCommitNavEvents` runs
`applyBufferedNavUpdates`, each step its own transaction:

1. **Level builds.** Levels the world added build into fresh storage (the same
   batch over a new level, with an open/blocked/mixed chunk fast path): a level
   added in play costs its own chunks and nodes, threaded, never refused.
2. **Revision rebuilds.** The world-wide content revision is compared once (O(1));
   only when it moved are levels walked, and a level whose revision moved (a change
   with no per-cell events: a blocking band add, a procedural fill) is rebuilt.
   `evictLevel` then evicts the results with a path run on that level and its group
   fields, O(level chunks + registrations), one flush after the loop; pending
   requests survive, since a solve re-checks its live goal and reach.
3. **Marks batch.** The recorded marks and every link added since the last batch
   apply as one transaction. `prepareMarks`, the fallible half, plans the changed,
   dirty, and patch keys (the `plan` stage sorts and dedupes per range; the merge
   pops each level's ordered chunk set, `LevelPlanSets`, about 3 bits per chunk,
   sized at level build and freed with the level, through a world-level set over
   the levels holding keys, so main is linear in keys) and reserves cell blocks,
   records, link slots, connectivity and closure staging, and the eviction windows
   (`nav_evict_count`). `commitMarks`, the infallible half, folds the new links into
   `link_bounds` and `level_crossings`, remasks the changed chunks from the world and
   the colliders (recording each chunk's flipped cells), re-derives only the patch
   keys on the changed span's edge plus link keys, and updates connectivity and the
   closure. `abortMarks` drops a prepare with the graph and its marks unchanged. On
   any error the graph is intact and every mark, level, revision, and link gap stays
   pending for the next step; there is no relabel, degraded state, or level- or
   world-wide fallback, and an incremental batch never bumps `nav_version`.
4. **Eviction.** `nav_evict` walks each changed key's owned halo keys (its 3×3
   block, each halo key owned by exactly one changed key) and evicts exactly the
   cached paths with a cell within one cell of a changed cell and the group fields
   with a costed cell within one cell of one; the main thread removes the hits in
   item order, O(1) each, and `evict_flush` unlinks their registrations. Pending
   requests, tallies, and every other result and field survive. A new ramp or
   teleport evicts nothing: it only adds connectivity.
5. **Landing.** `landClosure` lands the one-way closure blocks the step relocated
   (below), once, on the error path too.

Connectivity maintenance per batch: a seed stage reads the changed chunks'
pre-change adjacency, a gather stage reads the re-derived records, and the main
thread merges both in key order (node rows, unions, fresh ids, union by size).
Changes no removal can split settle at once. Removals flood both sides read-only on
workers in balanced rounds: per round each lagging set of a family runs one search
of up to its budget (targets m + clamp(m / 2, 1, 512), round window 16384), budgets
equalize the family's claimed counts, and main merges claims, joins, and queue
splices in item order at O(1) per item; every round runs under one profile selected
once and recorded once (`RoundDispatch`). A removal therefore costs about its smaller
side when it splits a component, or the reach until both floods meet when it does
not, the reachability exception in `.claude/rules/budgets-capacities.md` (measured:
at most ~2.2× the smaller side, a thin tunnel ~2× its length, flat in level side
256–2048, `e793590`). A change touching no one-way system does no closure work. A
touched system re-resolves its links (threaded per link), masks the rows whose reach
can change, plans SCC levels (Tarjan per piece), and recomputes only those rows per
SCC span in level rounds, threaded under `RoundDispatch`; main merges terminals and
pieces and commits, O(1) per item. Blocks grow by powers of two and narrow when under
a quarter full; a relocated or new block is written at commit into the batch's tail,
reserved at prepare from the batch's exact per-key bound, so commit stays
allocation-free, and lands (`conn_closure_land`, threaded per line) into its own
allocation at the end of the update. No batch reads or moves an untouched
component's block. A landing that runs out of memory is deferred: the blocks stay
valid in the tail, `land_deferrals` counts it (logged once), and the next prepare
retries it, failing as ordinary OOM with the graph intact. An index-map entry is
live when the terminal it names points back to it at its own index, so terminal and
H-component ids use the full u32.

Every stage has its own tuner and an inline path: `nav_mark` and the eviction trio
(`nav_evict_count`, `nav_evict`, `evict_flush`) on `PathfindingSystem`, and the
graph's `NavStage` tuners (`plan`, `remask`, `patch`, `conn_seed`, `conn_gather`,
`conn_flood`, `conn_closure_candidates`, `_resolve`, `_mask`, `_plan`, `_rows`,
`_land`) under one `nav_controls`. The main thread keeps O(1) work per item
(`.claude/rules/threading.md`); a single dominant one-way system's Tarjan is one
item, so it runs where the thread system places one item, and its rows thread. The
runtime perf log records `nav_remask`, `nav_connect` (the flood rounds), `nav_closure`
(the closure rows), and `nav_evict`. `NavUpdateStats` folds the plan, remask, and
patch stats over level builds and marks, and `--details` splits the reaction's main
time by section (`main_split`).

Batch staging (key lists, windows, tallies, masks, remask and patch lists, plan and
connectivity staging) grows through counted helpers and is released by a
sustained-window rule (`types.StagingWindow`: `capacity_shrink_window` fixed steps,
quiet steps included, below half), only at `finishStagingStep` at the end of a step,
never inside a stage; floors keep a single dig allocation-free. A step's level builds
share one level-sized staging, freed at that step's end. Connectivity's merge map
runs at load 3/4; the goal table, read on workers, at 1/2.

Index widths fail loudly (`budgets-capacities.md`): `validateChunkGrid` runs at world
create, level add in play, nav rebuild, and collider geometry (the chunk edge; each
side below the u32 sentinel; width × height below 2^32 - 1; chunk count below 2^31;
`chunks_x × chunk_tiles` within u32), and `NavExtent.validatedCellGrid` is the one
validate-and-cast site, clamping each side's float quotient so an oversize or
infinite bound fails as `LevelCellIndexOverflow`. The u16 level index fails with
`WorldLevelOverflow`. Node rows are proven below `no_node` through the label space
(live plus one batch's claims at most 2 × chunks × labels); closure offsets are
`usize`. Ids that grow in play (connectivity comp, root, terminal, and H-component
ids, the one-way registry, merge staging, level-link endpoints, sparse rows, dense
layers, chunk-list entries, anchor blocks) stay u32 and fail as `OutOfMemory` at
their growth seam, state intact for retry.

## SIMD Helpers

`src/core/simd.zig` provides project-named vector aliases and helper functions for
SoA movement, particle, terrain, nav, steering, and data processor loops. Every lane
count derives from one 16-byte register constant (the SSE2/NEON width): four lanes
for 32-bit elements (`Float4`, `Int4`), and a private 8 × u16 vector behind
`countUnequalU16`; nothing is wider than 128 bits. Each kernel has a scalar twin
and a parity test (for example `math.lastCellOfSpan` and `lastCellOfSpan4`, the one
mapping of a half-open max edge to its cell). The helpers use
Zig `@Vector` operations as the portable abstraction so LLVM can lower vector
math to the target CPU features, such as SSE-family instructions on x86 targets
or NEON on ARM targets, when the target and optimization mode make that
profitable. Platform intrinsics such as x86 or ARM-specific calls stay hidden
from gameplay.

When to use them: `.claude/rules/memory-performance.md`.
