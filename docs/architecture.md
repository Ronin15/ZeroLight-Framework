# Architecture

The project is organized for SDL_GPU-first 2D game work. Keep executable timing
thin, app coordination under `src/app/`, GPU work under `src/render/`, and
game-specific behavior under `src/game/`.

## Source Layout

- `src/main.zig` creates `AppConfig`, initializes `Engine`, and runs the fixed-step loop.
- `src/config.zig` defines app configuration, presentation options, clear color,
  and thread-system defaults shared by build options and runtime startup.
- `src/app/engine.zig` coordinates SDL app flow, the window, asset cache,
  runtime asset catalog, audio service, text service, renderer, state stack,
  pause controller, input, debug overlay, and thread system.
- `src/app/audio.zig` owns SDL3_mixer lifecycle, app-level audio tracks,
  loaded audio assets, bus gains, and the fixed-step audio command buffer.
- `src/app/input.zig` owns named actions, held gameplay input, and one-frame app/debug commands.
- `src/app/input_router.zig` applies state-policy action contexts before input mutates `InputState` or `FrameCommands`.
- `src/app/time_loop.zig` keeps simulation fixed at 60Hz.
- `src/app/frame_pacer.zig` classifies window visibility and applies fallback frame pacing.
- `src/app/state.zig` manages state allocation, destruction, policies, and queued transitions.
- `src/app/pause_controller.zig` owns the pause policy: pushes the modal `PauseState` over gameplay and resets timing on resume.
- `src/app/thread_system.zig` provides pre-spawned workers for synchronous parallel CPU batches.
- `src/app/resolution.zig` owns pure logical-resolution, viewport, and coordinate conversion policy.
- `src/app/runtime_perf_log.zig` records fixed-step runtime perf metrics consumed by states and the debug overlay.
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
- `src/game/world_system.zig` owns state-local world/tile data in SoA stores
  for levels, dense layers, sparse tiles, catalog source rects, and chunk
  visibility.
- `src/game/data_system.zig` fronts the `data_system/` subpackage (types,
  movement, visual, collision, agents, faction_level, structural, system) and
  owns state-local persistent entity data in dense SoA stores for gameplay,
  collision, and render systems.
- `src/game/simulation.zig` owns transient fixed-step streams, deterministic
  range-output collection, and deferred structural command buffers.
- `src/game/simulation_pipeline.zig` owns state-local fixed-step processor
  orchestration, reusable gameplay systems, and full-active scope stats.
- `src/game/simulation_scope.zig` defines simulation tiers, active-region
  scaffolding, per-entity scope metadata types, stagger/halo constants, and scope
  counters.
- `src/game/systems/simulation_scope.zig` owns `SimulationScopeSystem`, the
  backbone scope processor: tier/halo/stagger gathers and the auto tier wake/sleep
  policy (entity chunk columns are derived in-pass by movement, not a separate
  recompute).
- `src/game/player.zig` keeps player-specific input and facing behavior while
  storing persistent player data in `DataSystem`.
- `src/game/systems/movement.zig` integrates movement-body SoA columns through
  serial or threaded SIMD-aware ranges.
- `src/game/systems/ai.zig` emits navigation intents for ai_agent rows.
- `src/game/systems/steering.zig` consumes navigation intents and path status,
  then emits final NPC movement intents with local avoidance.
- `src/game/systems/collision.zig` generates deterministic contact streams.
- `src/game/systems/collision_response.zig` consumes contacts and applies
  response-policy movement corrections.
- `src/game/systems/particle.zig` owns state-local transient particle effects
  in a fixed-capacity SoA pool with serial or threaded SIMD-aware updates.
- `src/game/systems/pathfinding.zig` fronts the `pathfinding/` subpackage
  (types, nav_grid, nav_graph, caches, group_field, scratch, solve, system,
  nav_memory, test_support) for frame-delayed Z-aware grid navigation.
- `src/game/dig_controller.zig` is the pipeline-owned controller for player
  digging, authoring world-tile edits and navigation-invalidation signals.
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
- `src/core/logging.zig` owns scoped logging categories and build-option-driven log filtering.
- `src/root.zig` stays minimal for math aliases and compile coverage.
- `src/tests.zig` imports reusable modules so `zig build test` covers their tests and compile-time contracts.

## Cross-Cutting Ownership Rules

The main thread is not a fallback owner for work that lacks a better home.
Main-thread code must preserve a concrete boundary such as SDL/GPU/audio
ownership, state transitions, structural commits, asset loading, save/load
streaming, renderer resource ownership, or deliberately light orchestration.
Work that can scale with entity count, event count, asset count, draw count,
map size, file size, or tool complexity needs a named owner in app, game,
render, assets, platform, or tooling code. When it can become expensive, use
immutable inputs plus deterministic owned outputs instead of hiding the cost in
the frame coordinator or another convenient caller.

Production contracts expose runtime concepts only. Do not add test-only enum
tags, union payloads, marker fields, fake stages, fixture hooks, or service
shortcuts to production APIs just to make tests easier. Tests should use private
helper types, local fixtures, test-only mocks, or real runtime payloads without
changing the shape of app, game, render, asset, platform, or tool contracts.

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
Frame pacing policy should stay explicit and situational. Do not add broad
frame-rate caps that hide timing problems or harm high-refresh rendering unless
the cap preserves a named boundary and is measured.

Each submitted frame computes presentation from the acquired SDL_GPU swapchain
texture size and current SDL window size. World and logical UI draws are
transformed through that presentation into drawable pixels, then clipped to the
logical viewport; drawable overlays use raw swapchain pixels. All presentation
state stays in the SDL_GPU renderer path.
Debug UI state belongs in the debug overlay and render-service path, not in
gameplay state or persistent gameplay data.

## Coordination Boundaries

Game states submit through `Renderer.submitOrdered*` only from explicit
render-prep phases that already walk nondecreasing `RenderOrder`. World render
submission is layer-owned: z/depth discovery happens in `WorldSystem` and
state-owned dynamic render prep, then both streams are merged by world z before
commands reach `SpriteBatch`. Game states should not call SDL_GPU directly.
Window, GPU device, swapchain, shader, texture, text, and frame submission code
stays under `src/render/` and `src/app/`.
SDL, SDL_ttf, SDL_mixer, and SDL_GPU resources should pair creation and cleanup
close to the owning site. Ownership wrappers may centralize cleanup, but generic
state or gameplay teardown should not receive renderer, text, audio, or GPU
services merely to recover escaped resource ownership.

`Renderer` preserves strict ordered submission while delegating sprite-specific
CPU prep to `SpriteBatch`. SDL_GPU command-buffer acquisition, swapchain
acquisition, vertex upload, render-pass encoding, and submit remain coordinated
by `Renderer` on the main/render thread.
`SpriteBatch` owns a render-specific adaptive tuner and can use the app
`ThreadSystem` to expand prepared sprite commands into disjoint vertex spans.
Texture metadata is snapshotted before worker dispatch, workers do not read
live renderer resource slots, and draw groups are built on the main thread from
the already ordered command stream. Small or cheap frames may stay inline
through the same adaptive policy.

CPU sprite command preparation stays before SDL_GPU swapchain acquisition where
practical, including transfer-buffer staging for the normal steady-state path.
Sprite prep emits presentation-independent world/logical or drawable positions;
the acquired swapchain interval stays focused on acquired-size presentation
uniforms, copy-pass upload, render-pass encoding, and submit.

Dense world floors use retained per-layer tile-data storage buffers (Slice 23A):
partial dig uploads always use `cycle=false`; vertex ring buffers alone use
`cycle=true` on the final upload in a batched copy pass. Multi-level compositing
requires back-to-front dense-layer depth order at submit and in `mergeDrawList`.
Dense floor submit uses a vertical render window (`DenseLayerRenderWindow`:
six levels below the player, skipping floors above `active_level` so the slice
follows player level transitions) so draw count
stays bounded at the surface; all authored layers still retain GPU tile-data
buffers (Slice 23B). Sparse tiles cull by camera chunk visibility separately.
Dynamic entities collect from movement-body dense rows (Slice 24B): scope
columns and `renderCollectIndicesForMovement` align on `movement_index`; render
visibility is camera chunk + AABB only (simulation tier does not gate draw).
Dense floor submit uses a per-layer full-world quad inside the 23B window (GPU
clips; not camera-chunk culled). NPC per-level cull (Slice 25E) uses the `world_level` component in `DataSystem`
as the gameplay/nav/render authority; `setWorldLevel` syncs `scope.level` for
cube LOD. Player floor policy stays on `Player.current_level` for digging.
See `docs/rendering-assets-shaders.md` and slices 23B/24B in
`docs/framework-implementation-slices.md`.

Simulation LOD and render visibility are separate policies: tier, halos, and scope
gathers control fixed-step processor participation; camera chunk window, pixel
AABB, and render overscan control draw-record construction. Scope pin metadata
may keep an entity in a higher sim band off-camera; it must not bypass render
visibility. Open scaling gaps (collect scan cost, dense-floor layer quads,
movement contiguous-path vs dormant rows, per-entity depth alignment, component
mask headroom) are consolidated under **Scaling Gaps And Hardening Frontier** in
`docs/framework-implementation-slices.md`.

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
render. Engine-owned services must not persist pointers to sibling service
fields; release paths take the live owner explicitly. Cache lease tokens include
cache-owner identity, slot generation, and texture identity so release paths can
reject stale, forged, or wrong-owner tokens. Missing declared startup content is
logged and exposed as unavailable; fatal preload errors roll back partial sprite
work instead of leaving retained renderer resources behind.

Generated text follows the render-service ownership rule. `TextService` owns
SDL_ttf, loaded fonts, and generated renderer text textures for the app
lifetime. UI states describe text intent during render and receive only
non-owning prepared text views when the intent changes. Stable render frames
draw those prepared views directly, without re-checking the text cache. State
teardown stays service-free: do not pass renderer/text/audio services into
generic state destruction to compensate for escaped resource ownership.

Game states request SFX and music through `AudioCommandBuffer` in
`UpdateContext` using stable `AudioAssetId` values. `AudioService` is app-owned
because SDL_mixer device, mixer, track pool, loaded-audio cache, bus gains, and
pause ducking are process-level runtime services. Startup preload resolves
declared audio paths before command drain; fixed-step audio commands carry IDs,
gain, priority, frequency, and position only. States do not own `MIX_Mixer`,
`MIX_Track`, or loaded `MIX_Audio` handles. `Engine` drains audio commands on
the main thread after fixed-step state updates and state transition application.
Gameplay pause stops active SFX and ducks music; resume restores music gain.
Game-side audio policy — which intents to emit, jet-loop edge detection, and SFX
cooldowns — is the pipeline-owned `AudioController`; the gameplay state passes the
borrowed command buffer through the pipeline at its input/contact seams and holds
no audio-policy state.

Raw keyboard input maps to named actions in `src/app/input.zig`.
`input_router.zig` applies the active state stack's action contexts before
mutating held gameplay actions in `InputState` or one-frame UI/app/debug
commands in `FrameCommands`. State `handleEvent` methods still receive raw SDL
events according to stack policy, so named-action routing and raw event handling
stay separate.

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

Logging uses scoped `std.log` categories from `src/core/logging.zig`, with the
default log level chosen from build options. Diagnostics should explain startup,
configuration, fallback, lifecycle, and failure context. Per-frame, per-event,
per-draw, and processor hot paths should stay quiet unless a log is measured,
bounded, and intentionally useful.

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
Static item-count floors should not gate production threading; slower hardware
or expensive small-N processors must be able to train their own threaded
profile.
Reported `worker_threads` counts are background worker threads only; the main
thread is not included in that count and may also process ranges while waiting
for the batch barrier.
Production processors own their own tuner state so movement, particles,
collision, and future systems do not train each other with unrelated batch
timings; `ThreadSystem` keeps shared fallback state for generic callers. Batches
can still force explicit fixed profiles through `items_per_range`,
`max_worker_threads`, and `adaptive = false`. Worker threads are reused across
frame batches, parked when idle, and joined during `ThreadSystem` shutdown.
Processor-specific batches can align range starts to hot-column boundaries
through `parallelForWithOptions`.

Systems with multiple independently timed threaded stages own one tuner per
stage. Do not train a shared stage profile across different work shapes, such as
broadphase candidate generation and narrowphase contact validation, AI gather
and decision emission, or future pathfinding frontier expansion and path
reconstruction. If a stage preselects a profile before dispatch, it must pass
the selected profile and the stage-owned tuner together so inline samples still
train that stage before it decides whether to thread. Benchmark and diagnostics
output should report inline stages as `inline`, not as a fake zero-worker range
size.

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
lanes directly with `src/core/simd.zig`. Movement processor ranges should align
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
`WorldSystem`, whose persistent storage is SoA: stable tile IDs, atlas
source-rect columns, level base-z columns, dense/sparse tile columns, and
chunk/visibility columns. `WorldSystem` prepares world draw records during
render, using explicit world-depth bands from `src/game/render_depth.zig`.
Runtime gameplay construction uses the Engine-owned `ThreadSystem` to build the
procedural 512x512 tile world in deterministic chunk ranges. The gameplay state
keeps viewport size separate from world bounds, follows the player with an
interpolated sub-pixel camera, and asks `WorldSystem` to expose only
camera-visible chunks to render prep. Future scoped simulation slices may
consume its chunk/visibility view, but `SimulationPipeline` should not own tile
storage, runtime atlas metadata, or camera policy.

The current gameplay fixed-step pipeline is:

1. Clear `SimulationFrame` and mark the step active.
2. Apply main-thread player input and queue fixed-step audio commands.
3. `SimulationPipeline` builds the shared `SpatialIndexSystem` from the
   cognition-scoped population, then runs AI decision output (querying that
   index for separation), steering, and frame-delayed pathfinding.
4. `SimulationPipeline` applies merged AI movement intents.
5. `SimulationPipeline` runs movement over dense `DataSystem` movement slices.
6. `SimulationPipeline` clamps bounds, generates collision contacts, and applies collision response.
7. Queue contact audio, emit/update transient particles, and merge outputs.
8. Commit deferred structural commands to `DataSystem`.
9. Update the state-owned follow camera and visible world chunks.
10. Render current `WorldSystem`, `DataSystem`, and particle state with
    interpolation.

`SimulationPipeline` owns the reusable fixed-step simulation systems, concrete
stage order, scope stats, budgets, and processor handoff for one gameplay state
instance, while `StateStack` remains the dispatch/lifetime owner. Future domain
features should add concrete pipeline-owned controllers rather than growing
`GameDemoState.update` — or, as controllers accumulate, the pipeline's own
`update` — or introducing a global engine scheduler, reflection system, dynamic
dependency graph, or callback registry. The pipeline stays a thin composer; each
controller and system owns its own internals.

Simulation tiers and active scope belong in the same pipeline boundary. Tier and
chunk metadata are dense SoA columns on the movement-body store
(`tier`, `chunk_x/y`, `stagger_phase`, `always_active`), in lockstep with the
movement rows so they exist exactly for simulated entities and the O(N) scope
passes read/write aligned columns rather than scattered slots. The pipeline-owned
`SimulationScopeSystem` (`src/game/systems/simulation_scope.zig`) is the backbone
that derives the camera cognition halo from `WorldSystem` and selects which entities
enter each stage; entity chunk columns are derived in-pass by the movement processor
(not a separate scope recompute).
Processors keep their hot loops and receive a `scope_dense_indices` option
(null = full-active) instead of learning world/chunk policy. Movement and
collision gate on tier only (no chunk filter, so off-screen entities keep moving
and colliding) and short-circuit to full-active in O(1) via incremental
`tier_counts` when nothing is dormant/kinematic; AI gates on tier + camera halo +
a per-entity stagger cadence; steering inherits that scope transitively through the
navigation-intent stream. Tier wake/sleep changes flow through deferred
`set_simulation_tier` structural commands at the commit seam, never inside worker
ranges. CPU benchmarks at 50k scale are throughput ceilings for rare spikes;
typical frames scope active work far lower.

The durable tier model is capability-based, not visibility-based:
`dormant` entities exist but do not enter normal active scope, `kinematic`
entities run movement integration, `locomotion` entities add collision
detection/response, and `cognition` entities add AI, steering, and path
requests. Scope then decides which loaded worlds, chunks, chunk halos, or
staggered/reduced-cadence groups enter those tiered stages for the current
fixed step.

Emergent NPC behavior layers on the cognition tier. Perception, memory, and
affect (emotion) are durable per-entity concepts that live as SoA components in
`DataSystem` and are advanced by cognition-gated processor stages in
`src/game/systems/`, alongside AI, steering, and pathfinding. They follow the
same rules as every other processor: allocation-free hot paths, deterministic
serial/threaded and scalar/SIMD parity, range-disjoint output, and explicit
barriers. Dense per-step sensing/affect data stays in component columns or
transient range streams; only notable transitions become low-volume domain
events. Cross-entity classification (faction/stance), a deterministic per-entity
RNG facility in `src/core`, and a shared per-frame spatial index are shared
substrate these stages consume. Because they run only for in-scope cognition
entities, their cost scales with active scope, not total entity count.

The pipeline is also the right place to compose light domain controllers for
features such as combat, spawning, rules, encounters, or other gameplay
domains. Controllers own feature orchestration: small queues, budgets,
cooldowns, priority/conflict policy, and handoff between processors. They should
emit `SimulationFrame` outputs or deferred structural commands and call
processors with typed `DataSystem` views. They should not become hidden
per-entity stores, own renderer/audio/SDL handles, or replace SoA processors for
hot/reusable loops.

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

`AiSystem` (first AI processor) is a decision emitter over ai_agent entities.
It receives const AiAgent + movement prior-position slices and a read-only
`SpatialIndexView` from the pipeline-owned `SpatialIndexSystem`
(`src/game/systems/spatial_index.zig`, Slice 28) — the shared per-step spatial
index, built once from the same cognition-scoped population, that AI
separation queries for bounded local-separation samples instead of building
its own grid. `AiSystem` then emits threaded navigation intents through
`SimulationFrame.navigation_intents` (count/prefix/write). Separation and
intent emission have independent AdaptiveWorkTuner state and benchmark stats
so each stage can remain inline or thread independently; the index build has
its own separate tuner on `SpatialIndexSystem`. Wander amplitude and seek
prove non-player entities emit high-level goals from persistent data rather
than hardcoded velocities. `CollisionSystem`'s sweep-and-prune broadphase (see
above) is intentionally not ported onto this index — it is a different,
already-tuned algorithm, not a duplicate grid build.

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
stay out of `DataSystem`. Request key preparation and static grid marking use
`src/core/simd.zig` lane batches where the work is regular; branch-heavy A*
frontier expansion remains scalar inside threaded request ranges. Path results
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
`pending` and increments `path_budget_exhausted`. A blocked
goal projects to the nearest open cell on the goal level
(`path_goal_projected`); `unavailable` is reserved for definitive negatives
(disconnected component, no open cell near the goal, or no corridor across levels). Oversized worlds fail
loud at `NavGrid.rebuild` with `error.NavWorldTooLarge` rather than degrading at
query time. The managed flow field is built only on declared group requests
(zero cost otherwise), rebuilt only when the goal crosses a nav cell and at most
once per `group_field_rebuild_min_steps`, and budgeted across frames by
`group_field_build_budget`. Completed-path, unavailable-key, and group-field
registries are fixed-capacity runtime structures with explicit eviction or
saturation behavior rather than unbounded growth.

The demo player is intentionally a special-case facade for player input and
facing rules, backed by `DataSystem` data. Enemies and other world objects
should normally be plain entities processed by enemy, movement, collision, AI,
or render systems rather than copies of player behavior.

`ParticleSystem` is the transient visual-effect exception. It is owned by the
game state instead of `DataSystem`, because particles are short-lived effect
rows rather than persistent world entities. Particle emission and expired row
swap-removal run on the state/main thread; threaded jobs only update assigned
SoA ranges and render submits rectangles through `Renderer`.

Simulation outputs coordinate determinism, performance, and efficiency as one
contract. Threaded processors that produce events, intents, contacts, or
deferred structural commands use typed range-owned output buffers: count outputs
per stable range, prefix offsets on the main thread, write contiguous output
slices, merge by range index, and consume the result as a batch. Output order
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
specialized outputs, later-phase events, or deferred structural commands, but
they do not recursively redispatch events or mutate `DataSystem` structurally
outside the commit boundary. The current event payloads cover structural
entity/component changes, world tile/obstacle changes, and navigation-region
invalidation. Event records carry only stable entity IDs, component enums,
reason enums, compact coordinates, and small scalar payloads;
they do not carry pointers, app/render/audio handles, asset paths, allocators,
or service references.

High-volume streams stay specialized. Collision contacts, collision triggers,
navigation intents, movement intents, path requests, render-prep commands, and
structural commands are not collapsed into the generic event stream. The event
hub exists for cross-system change signals and diagnostics. Event producers own
their range writes and range-local stats; the stream merges per-type and
per-stage counters deterministically after producer completion. A configured
per-step event capacity is enforced for both appended and range-owned event
producers: required events fail before structural mutation or domain reaction
side effects, while diagnostic events are dropped and counted. Reaction work has
explicit ownership rather than a generic main-thread fallback: light
orchestration may run inline, and expensive consumers should split over
immutable event slices and write range-owned outputs. After the commit point, the
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
do NOT carry a resolvable cell (a destroyed entity's footprint is gone), so they
forward `pipeline.markNavLevelDirty(0)` instead — a whole-level dirty request that
re-derives every chunk on level 0 (the only level sourcing collision bodies) from the
world. `pipeline.applyNavUpdates` coalesces the buffered work to the set of touched
chunks (or every chunk on a whole-level-dirty level), RE-DERIVES each touched chunk's
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
incremental patch never renumbers it. A `LevelLink` ADDED at runtime (e.g.
`dig_controller.digRamp` carving a ramp) is therefore handled by endpoint: a PERIMETER
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

The cross-cutting ownership rules apply here too: event reactions may have
main-thread commit points, but scalable reaction work still needs a named owner,
and event/intent contracts must not grow test-only variants or marker payloads.

## SIMD Helpers

`src/core/simd.zig` provides project-named four-lane vector aliases and helper
functions for SoA movement, particle, and data processor loops. The helpers use
Zig `@Vector` operations as the portable abstraction so LLVM can lower vector
math to the target CPU features, such as SSE-family instructions on x86 targets
or NEON on ARM targets, when the target and optimization mode make that
profitable. Platform intrinsics such as x86 or ARM-specific calls stay hidden
from gameplay.

Prefer scalar code for tiny batches or simple logic where vectorization would
make the code harder to read. Use the SIMD helpers when a processor already
operates over dense slices and can handle vector ranges plus a scalar tail.
