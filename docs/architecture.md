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
- `src/app/thread_system.zig` provides pre-spawned workers for synchronous parallel CPU batches.
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
- `src/game/world_system.zig` owns state-local world/tile data for levels,
  dense layers, sparse tiles, level links, catalog source rects, the render
  chunk window, and durable **interest/affordance markers** (`world_interest.zig`,
  Slice 41). Markers are world-authored POIs with fixed inline slot capacity
  (allocation-free by construction) — not `DataSystem` components and not
  ephemeral `WorldStimulus` dig/footstep/impact events. Kind `investigate` is
  the AI consumer today; `cover` / `resource` / `patrol` are reserved schema
  tags until a later consumer lands. Cognition discovery uses a fixed query
  radius (`dist ≤ query_r`); authored `marker.radius` is influence footprint,
  not the discovery gate. Queries return nearest-k (dist², then slot index).
- `src/game/world_terrain.zig` holds `WorldSystem`'s chunk-owned terrain
  storage: per dense layer a chunk directory over a pool of tile blocks, per
  level a growable band list, a composed movement-blocked directory over a pool
  of bit blocks, and per-chunk link-endpoint list heads, directories sized at
  level create.
- `src/game/world_test_support.zig` holds test-only `WorldSystem` fixtures shared
  across modules (a demo surface at any chunk edge, terrain pool warmup).
- `src/game/world_gpu_tiles.zig` holds `WorldSystem`'s mirror of its
  renderer-owned GPU tile store: the store's non-owning id, the resident
  window, each resident layer's toroidal directory and chain link, and the
  directory and block allocator it plans and commits each frame, uploading
  changed chunks found through layer flags and block change marks; reset when
  the renderer retires the store.
- `src/game/data_system.zig` fronts the `data_system/` subpackage (types,
  movement, visual, collision, agents, faction_level, perception, memory,
  affect, destructible, structural, system) and owns state-local persistent
  entity data in dense SoA stores for gameplay, collision, and render systems.
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
  is `position_z` / `world_level`, not continuous z motion).
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
  response-policy movement corrections.
- `src/game/systems/particle.zig` owns state-local transient particle effects
  in a fixed-capacity SoA pool with serial or threaded SIMD-aware updates.
- `src/game/systems/pathfinding.zig` fronts the `pathfinding/` subpackage
  (types, nav_grid, nav_graph, caches, group_field, scratch, solve, system,
  nav_memory, test_support) for frame-delayed multi-level grid navigation.
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
depth, or world count. `WorldSystem.syncDenseTileStore` (mirror:
`world_gpu_tiles.zig`) runs once per frame in render prep before swapchain
acquisition: a level entering the window uploads its window directory and
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
There are no static item-count floors (`.claude/rules/threading.md`);
slower hardware or expensive small-N processors train their own threaded
profile.
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
Each level keeps its band list (growable: a band add is never refused, and a
batched edit carries per-group band bits sized to the widest touched level) and
composed movement-blocked bits per chunk
(OPEN, BLOCKED, or a bit block), so `levelBlocksMovement` is O(1) and a write
recomposes only its own cell. Level links are append-only and indexed per
endpoint chunk, so `rampLinkOtherLevel` walks one chunk's endpoints. A dig or
fall carve reserves its growth with `reserveDenseCellWrite` (and
`reserveLevelLink`) before any mutation, so an OOM leaves the step's state
intact; a local change costs only the chunks it touches, and adding a level
costs only its own directories. A dense one-step change (cave-in, explosion)
goes through `applyDenseCellWrites`: writes arrive grouped by chunk, storage is
reserved on the main thread first, chunks are written in parallel on the
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
   `ai_decide` → `steering_update` → `pathfinding_update` (frame-delayed) →
   `apply_ai_movement_intents` → `movement_integrate` →
   `collision_scope_gather` → `collision_detect` → `collision_respond` →
   `bounds_and_tile_gate` (world bounds clamp + solid-tile gate; after
   collision so a contact push into dirt is re-gated) →
   `plane_traversal` (ramp/fall/carve/snap) → `chunk_derive` →
   `action_react` (destructible / action-intent consumers) →
   `tier_policy` (deferred `set_simulation_tier` commands).
4. Queue contact audio, emit/update transient particles, and merge outputs.
5. Update the state-owned follow camera and visible world chunks.
6. Commit deferred structural commands to `DataSystem`, run
   `SimulationPipeline.syncPopulationCapacity` (the population growth seam),
   then run the pipeline's post-commit reactions (nav, then steering:
   `SimulationPipeline.reactToPostCommitNavEvents` and
   `.reactToPostCommitSteeringEvents`, independent side effects on disjoint
   state reacting to the same committed event stream) so nav patches from this
   step's world edits. A nav error is returned only after the steering reaction
   has run.
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

- `DigController` — dig intents → world-tile edits + stimuli/events
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
components, computes aligned correction columns with `src/core/simd.zig`, and
applies sparse movement writes deterministically on the main thread before
structural commands commit.

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
component data, movement slices, static obstacle data, and frame-delayed
`PathfindingSystem` status. It owns runtime path-following rows, replan
cooldowns, unavailable-path backoff, stuck counters, and bounded local-avoidance
bucket scratch outside `DataSystem`. Path-status, cooldown mutation, runtime-row
pruning, and intent arbitration stay on the main-thread boundary, then the
prepared steering work emits final NPC `MovementIntent`s through deterministic
threaded range writes to `SimulationFrame.intents`.
Priority arbitration chooses the highest-priority navigation intent per entity
with stable stream order as the tie-breaker.
Player movement remains direct input with no steering component, while collision
response still resolves after movement.

`PathfindingSystem` is a frame-delayed, Z-aware grid pathfinding processor under
`src/game/systems/` (Slice 25A-25C). It runs two coordinated solver modes selected
per request kind: budget-bounded goal-keyed heap A* for individual goals, and a
demand-driven managed shared-goal reverse-Dijkstra flow field for declared `group`
requests. Long-range and cross-level individual queries route through a per-level
chunk-portal abstract graph plus inter-level `LevelLink` edges: abstract A* picks a
corridor, then the system STITCHES a full obstacle-aware (level,cell) path by running
per-segment local A* between consecutive corridor portals (a discrete jump only
across a link edge) and caches it whole. The per-agent query walks that path on its
current level cell by cell, exactly like a single-level A* path, so every heading is a
traversable neighbor — never a straight-line cut across a wall — and multi-hop and
cross-floor routes converge. Abstract seeding scans only the start level's portals
that share the start cell's connected component, via a per-(level,component) portal
index, so seeding scales with the reachable subset rather than the level's full
border; abstract scratch saturation or a per-segment node-budget
spill returns `pending` (retry) rather than a hard negative. It owns the static versioned
nav grid (one per level), the chunk-portal/link graph,
pending request queue, duplicate suppression, the goal-keyed completed path
cache, unavailable-path cache, per-worker budgeted A* scratch, a fixed group-field
registry, per-stage adaptive tuner state, and benchmark stats.
`SimulationFrame.path_requests` carries transient requests from steering or
future rule systems; path queues, scratch, thread state, and live path caches
stay out of `DataSystem`. Each update runs four stages with their own adaptive
tuners (`group_field_expand` has one per pass) and inline paths
(`.claude/rules/threading.md`): `path_intake` runs one direct
classify-and-accept pass when it stays on the main thread; on workers, ranges
classify against step-start state and the main thread merges their windows in
range order (group tallies, expired results, in-step duplicates folded per range,
the pending cap); `group_field_expand` runs each building field's budgeted
expansion as one item, in an advance pass before the main-thread slot
decisions and a begin pass after them; the solve batch keeps branch-heavy A*
frontier expansion scalar inside threaded ranges and writes every output at the
request's fallback ordinal; publish is a serial, fixed-count ordered commit.
Pending is a ring, so compaction costs the solve window, not the queue. Path results
are consumed on later fixed steps so missing or unreachable paths do not stall
same-step movement. Cache and pending keys are goal-keyed
(`nav_version + agent_class + goal_level + goal_cell`) so a moving agent reuses one
shared result and derives its per-step waypoint from its current cell against the
stored path/corridor; agents that share a goal share one pending entry. The local A*
node state (g-cost/parent/closed) lives in generation-stamped DIRECT per-cell arrays
indexed by cell index — O(1) access with no hash probes or collisions, in exchange
for per-worker scratch that is O(cells) (the grid is world-bounded, so this is a fixed
cost the build-time memory gate counts). `max_explored_nodes` stays the node BUDGET:
an explicit per-solve expansion counter caps how many distinct cells one solve may
stamp. Hitting that local node budget or saturating the abstract scratch returns
`pending` and increments `path_budget_exhausted`. Abstract/stitched-corridor work
follows a two-tier attempt ladder (`PendingRequest.tier`) rather than retrying a
budget-exhausted query at unchanged cost: a cheap tier-0 attempt uses the small fixed
`tier0_abstract_node_cap`/`tier0_stitched_cell_cap`; exhausting it promotes the
request to tier 1 exactly once, which retries against `max_abstract_nodes`/
`max_stitched_path_cells`, a larger fixed per-query budget (`default_tier1_*` in
`types.zig`; `.claude/rules/budgets-capacities.md`). A tier-1 exhaustion
drops the request WITHOUT negative-caching — it does not fit either fixed budget,
which is not the same as a definitive "no path exists" — so the next query falls
through to `.missing` (retryable after the caller's own replan cooldown) rather than a
false `unavailable`. A request therefore costs at most two solve attempts per replan
cycle, never an unbounded retry storm and never a permanently wrong negative. Per-step
`max_escalated_solves_per_step` additionally bounds how many tier-1 (expensive)
attempts one fixed step admits, so several simultaneously-stuck agents cannot
stack their escalated cost into a single frame. A blocked
goal projects to the nearest open cell on the goal level
(`path_goal_projected`); `unavailable` is reserved for definitive negatives
(disconnected component, no open cell near the goal, or no corridor across levels). With a world,
nav takes the world's width, height, `tile_size`, and `chunk_size_tiles`
(`NavExtent.world`); bounds, `nav_cell_size`, and `nav_chunk_tiles` shape only a
world-less build. Index widths fail loud
(`validateChunkGrid`) at world create, level add, and nav build: the chunk edge,
u32 level cell indices, and u32 chunk labels (`chunks × (edge² + 1)` below
`no_cell`); the u16 level index fails with `WorldLevelOverflow`. Oversized worlds fail
loud at `NavGrid.rebuild` with `error.NavWorldTooLarge` rather than degrading at
query time. The managed flow field is built only on declared group requests
(zero cost otherwise), rebuilt only when the goal crosses a nav cell and at most
once per `group_field_rebuild_min_steps`, and budgeted across frames by
`group_field_build_budget`. Completed-path, unavailable-key, and group-field
registries are fixed-capacity runtime structures with explicit eviction or
saturation behavior rather than unbounded growth.

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
post-commit nav reaction folds static obstacle-affecting changes into the
pathfinding nav graph INCREMENTALLY rather than rebuilding the whole world.
`PathfindingSystem` owns that reaction end to end (`reactToPostCommitNavEvents`):
interpreting structural events into changed nav cells, the dirty buffer, and the
incremental update — it is the named owner for work that scales with
digging/obstacle edits. `SimulationPipeline` orchestrates by delegating to it,
and the gameplay state only invokes that delegation at its main-thread commit
seam, holding the resulting `NavUpdateStats`. The nav-invalidation classifiers
(`eventInvalidatesNavigation`, `structuralCommandsMayInvalidateNavigation`,
`pendingEventsMayInvalidateNavigation`) are reusable nav policy on
`PathfindingSystem` too, used for both the reaction and the pre-commit event
capacity preflight. Cell-localizable edits — blocking `world_tile_changed` /
`world_obstacle_changed` changes (only when `old_blocks_movement !=
new_blocks_movement`) — are forwarded to the system-owned dirty buffer via
`pipeline.markNavDirty` (one entry per changed cell). Entity-driven obstacle changes
(`component_changed` on `movement_body`/`collision_bounds`/`collision_response`, and
`entity_destroyed`) instead carry an optional `ObstacleWorldRect` — the changed
entity's world-space collision AABB, before and/or after the change, when it was/is a
static navigation obstacle. `PathfindingSystem` resolves that rect to a nav-cell span
via `markNavObstacleRectDirty` and patches only the affected chunks, the same
incremental mechanism tile edits already use, instead of invalidating the whole level.
`pipeline.markNavLevelDirty(0)` — a whole-level dirty request that re-derives every
chunk on level 0 (the only level sourcing collision bodies) from the world — is only a
defensive fallback for the (stated-unreachable) case where the carried rect is null:
`isStaticNavigationObstacle` requires the same components the rect is derived from, so
that fallback logs a warn rather than silently rebuilding the whole level.
`pipeline.applyNavUpdates` coalesces the buffered work to the set of touched chunks
(resolved obstacle-rect spans, plus every chunk on any whole-level-dirty level),
RE-DERIVES each touched chunk's
blocked mask from the world WHOLE-CHUNK (so a coalesced rect, a large multi-actor
batch, or a cell-less entity change can never leave a cell stale against the world),
recomputes those chunks' components, and patches the chunk-portal abstract graph once
(bounded by chunk borders, not cells). An incremental batch keeps `nav_version` STABLE
and evicts only the cached paths crossing the changed cells (a whole-level request,
whose change is not bounded by edit spans, drops the whole completed-path cache
instead); only a degenerate full relabel or an edge-cap fallback — a genuine topology
rebuild — bumps `nav_version` once so every goal-keyed cache/pending entry and group
field keyed on the old version re-solves. The dirty
buffer GROWS rather than dropping, so any number of simultaneous diggers or
obstacle edits in one step all reach the graph — a dropped cell would leave the
graph stale. Unaffected chunks are never touched, and the whole-world build runs
only at init. The abstract SLOT GEOMETRY — the per-chunk perimeter slots plus the
per-chunk interior link-endpoint runs that index portal nodes — is a pure function of the
dimensions and the INIT-TIME link set, computed once by `computePortalGeometry`; the
incremental patch never renumbers it. A `LevelLink` ADDED at runtime (e.g. a ramp
dig through `DigController.commitWorldEdit`) is therefore handled by endpoint: a PERIMETER
endpoint keeps its positional slot and is admitted as a portal incrementally, while an
INTERIOR endpoint has no reserved slot and is DEFERRED — `tryLinkPortal` skips it, leaving
it non-live in the abstract graph (no portal node), exactly as a blocked endpoint would,
rather than resolving against an absent run. The walkability-keyed `link_edges` entry still
forms but is inert: the abstract solver only relaxes a link whose partner endpoint resolves
to a live portal (`cell_to_portal != no_cell`), so a deferred endpoint is never traversed.
A deferred interior endpoint is reserved by the next full rebuild. This is correct while
cross-level NPC pathing is inactive — NPC `goal_level` is pinned to the surface, and the
PLAYER climbs ramps through the `WorldSystem` link tier (`rampLinkOtherLevel`), not the
abstract graph; making a runtime interior ramp NPC-pathable would require per-chunk
interior-link slot headroom reserved at init. The reaction is recorded
through the `nav_dirty_chunks` / `nav_incremental_rebuilds` / `nav_full_relabel` /
`nav_version_bumps` metrics (the per-affected-level relabel degenerates to a
counted full relabel only past a configured level threshold), and a
`nav_region_invalidated` event is still emitted whenever the graph actually
changed. The reaction runs at the main-thread post-commit point, but it has TWO independently
threaded stages, each fanned across the `ThreadSystem` by its OWN adaptive tuner (one
tuner per stage, never shared): the remask-from-world + component re-flood through
`nav_remask_tuner`, and the per-chunk abstract patch through `nav_patch_tuner`. So a
single-tile dig stays inline while a many-chunk dig-storm (NPCs plus the player digging
at once) parallelizes both stages — the tuners are the work-sizing policy, with no fixed
per-step budget. Each worker re-derives or patches only its chunk's own disjoint
mask/component cells and slot/edge windows using a per-participant scratch slot, so the
threaded result is byte-identical to the serial one (and to a full rebuild). Only the
`link_edges` rebuild stays serial on the main-thread reaction. It is allocation-free on
the steady path: the abstract chunk-portal
buffers grow to their real size at the init rebuild and retain that high-water
capacity, so an incremental rebuild whose topology stays within the high-water
mark grows no buffer. The per-participant patch scratch is likewise pre-reserved at
the build to the largest chunk's caps. The system-owned dirty buffer is likewise
reserved to a steady-path high-water and does one bounded amortized grow only for an
unusually large structural step. A genuine topology expansion past it (an unblock opening
more portals than any prior build) does one bounded amortized growth, which is
acceptable on this cold, event-triggered path. The `max_nav_memory_bytes` gate
estimates nav memory from realistic structure (portals bounded by chunk-border
cells, CSR edges by portal count times a small abstract degree), not a per-chunk
pairwise worst case, so large sparse worlds build instead of being falsely
rejected.

## SIMD Helpers

`src/core/simd.zig` provides project-named four-lane vector aliases and helper
functions for SoA movement, particle, and data processor loops. The helpers use
Zig `@Vector` operations as the portable abstraction so LLVM can lower vector
math to the target CPU features, such as SSE-family instructions on x86 targets
or NEON on ARM targets, when the target and optimization mode make that
profitable. Platform intrinsics such as x86 or ARM-specific calls stay hidden
from gameplay.

When to use them: `.claude/rules/memory-performance.md`.
