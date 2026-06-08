# Architecture

The project is organized for SDL_GPU-first 2D game work. Keep executable timing
thin, app coordination under `src/app/`, GPU work under `src/render/`, and
game-specific behavior under `src/game/`.

## Source Layout

- `src/main.zig` creates `AppConfig`, initializes `Engine`, and runs the fixed-step loop.
- `src/config.zig` defines app configuration, presentation options, clear color,
  and thread-system defaults shared by build options and runtime startup.
- `src/app/engine.zig` coordinates SDL app flow, the window, asset cache, audio service, text service, renderer, state stack, pause controller, input, debug overlay, and thread system.
- `src/app/audio.zig` owns SDL3_mixer lifecycle, app-level audio tracks,
  loaded audio assets, bus gains, and the fixed-step audio command buffer.
- `src/app/input.zig` owns named actions, held gameplay input, and one-frame app/debug commands.
- `src/app/input_router.zig` applies state-policy action contexts before input mutates `InputState` or `FrameCommands`.
- `src/app/time_loop.zig` keeps simulation fixed at 60Hz.
- `src/app/frame_pacer.zig` classifies window visibility and applies fallback frame pacing.
- `src/app/state.zig` manages state allocation, destruction, policies, and queued transitions.
- `src/app/thread_system.zig` provides pre-spawned workers for synchronous parallel CPU batches.
- `src/app/resolution.zig` owns pure logical-resolution, viewport, and coordinate conversion policy.
- `src/assets/assets.zig` resolves safe runtime asset paths, `src/assets/image.zig`
  decodes PNGs into transient CPU image data, and `src/assets/cache.zig` caches
  renderer-backed runtime assets.
- `src/render/renderer.zig` is the game-facing render facade and frame coordinator.
- `src/render/camera.zig` owns simple world-to-screen camera transforms.
- `src/render/resources.zig` defines generational renderer resource IDs and descriptors.
- `src/render/sprite_batch.zig` owns sprite draw command sorting, vertex construction, draw grouping, and allocation-free warmed batch prep.
- `src/render/gpu/` owns SDL_GPU device/window setup helpers, upload buffers, texture uploads, and sprite material/pipeline creation.
- `src/render/text.zig` owns SDL3_ttf lifecycle, asset-backed fonts, and cached text textures.
- `src/render/debug_overlay.zig`, `src/render/debug_overlay_stub.zig`, and `src/render/fps_counter.zig` draw or compile out the F2 FPS overlay.
- `src/game/game_demo_state.zig` and `src/game/pause_state.zig` are the current game states.
- `src/game/data_system.zig` owns state-local persistent entity data in dense
  SoA stores for gameplay, collision, and render systems.
- `src/game/player.zig` keeps player-specific input and facing behavior while
  storing persistent player data in `DataSystem`.
- `src/game/systems/movement.zig` integrates movement-body SoA columns through
  serial or threaded SIMD-aware ranges.
- `src/game/systems/particle.zig` owns state-local transient particle effects
  in a fixed-capacity SoA pool with serial or threaded SIMD-aware updates.
- `src/gpu_smoke.zig` is the GPU smoke executable entry point, while
  `src/platform/gpu_smoke_impl.zig` owns the display-gated SDL_GPU probe.
- `src/platform/sdl.zig` contains shared SDL, SDL_ttf, and SDL_mixer C imports
  plus small SDL wrappers.
- Audio assets live under `assets/audio/` and are resolved through the same
  traversal-safe asset root.
- `src/core/math.zig` and `src/core/simd.zig` contain small shared math and portable SIMD helpers.
- `src/core/logging.zig` owns scoped logging categories and build-option-driven log filtering.
- `src/root.zig` stays minimal for math aliases and compile coverage.
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

Each submitted frame computes presentation from the acquired SDL_GPU swapchain
texture size and current SDL window size. World and logical UI draws are
transformed through that presentation into drawable pixels, then clipped to the
logical viewport; drawable overlays use raw swapchain pixels. All presentation
state stays in the SDL_GPU renderer path.

## Coordination Boundaries

Game states draw through `Renderer`; they should not call SDL_GPU directly.
Window, GPU device, swapchain, shader, texture, text, and frame submission code
stays under `src/render/` and `src/app/`.

`Renderer` preserves the public `drawSprite` and `drawRect` API while delegating
sprite-specific CPU prep to `SpriteBatch`. SDL_GPU command-buffer acquisition,
swapchain acquisition, vertex upload, render-pass encoding, and submit remain
coordinated by `Renderer` on the main/render thread.

Game code submits sprites and rectangles through `Renderer` using prepared
resource handles. Asset paths and PNG decode stay in `src/assets`; renderer
texture creation starts from decoded pixels and owns only the GPU texture
resource. Retained `TextureId` leases and text texture leases belong to setup,
state transitions, world/entity creation, or owner shutdown paths; hot render
paths should keep drawing with retained IDs rather than performing asset,
entity, or text lookup.

Game states request SFX and music through `AudioCommandBuffer` in
`UpdateContext`. `AudioService` is app-owned because SDL_mixer device, mixer,
track pool, loaded-audio cache, bus gains, and pause ducking are process-level
runtime services. States choose what sound to request; they do not own
`MIX_Mixer`, `MIX_Track`, or loaded `MIX_Audio` handles. `Engine` drains audio
commands on the main thread after fixed-step state updates and state transition
application. Gameplay pause stops active SFX and ducks music; resume restores
music gain.

Raw keyboard input maps to named actions in `src/app/input.zig`.
`input_router.zig` applies the active state stack's action contexts before
mutating held gameplay actions in `InputState` or one-frame app/debug commands
in `FrameCommands`. State `handleEvent` methods still receive raw SDL events
according to stack policy, so named-action routing and raw event handling stay
separate.

State policies decide whether lower states receive updates, events, or render
passes. Transitions are queued through `StateTransitions` and applied after the
current dispatch completes.

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
while it waits. Small batches run inline on the main thread, and batch
submission does not allocate after initialization.

Adaptive work tuning chooses a complete batch profile: inline or threaded,
worker threads, and items per claimed range. Worker count and range size remain
distinct knobs, but `AdaptiveWorkTuner` measures them together so one controller
owns the decision. The tuner starts inline, probes a threaded profile when the
measured inline window is expensive enough, then searches smaller and larger
aligned range sizes around the best measured threaded profile before settling.
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

## Gameplay Data

Gameplay states own their own `DataSystem`; it is not an app singleton. The
system stores persistent world entities, per-entity component masks for system
membership queries, and typed SoA data such as movement bodies, facing,
primitive visual intent, and relative asset references.
Collision bounds are stored as dedicated persistent gameplay data rather than
being inferred from render visuals.

Hot gameplay data is stored as scalar columns. The movement-body store exposes
64-byte-aligned `position_x`, `position_y`, `previous_x`, `previous_y`,
`velocity_x`, `velocity_y`, and `speed` slices so update processors can load
lanes directly with `src/core/simd.zig`. Movement processor ranges should align
to `data_system.movement_range_alignment_items`, which maps one cache line to
sixteen `f32` elements. Component masks decide whether an entity belongs to a
system; hot processors iterate already aligned SoA slices.

Gameplay states own a transient `SimulationFrame` for each fixed step. The
state clears the frame, runs main-thread input writes, dispatches processors,
merges transient outputs, and applies deferred structural commands at explicit
main-thread commit points. `DataSystem` remains persistent storage, not the
simulation scheduler.

Processors run behind explicit barriers. Each ordered system finishes its serial
or threaded work, merges any range-owned output in stable order, and only then
allows the next system to consume the result. Deferred structural commands are
prevalidated before the main-thread commit mutates `DataSystem`, so validation
failures do not partially apply a command batch.

Update processors receive typed slices or views from `DataSystem` during
fixed-step updates instead of broad structural access. Render systems read
immutable `DataSystem` slices during state render and submit draw calls through
`Renderer`. `DataSystem` does not own SDL handles, GPU handles, SDL_mixer
handles, live renderer texture IDs, asset leases, audio command buffers, input
frame state, thread-system state, transient events, or scratch buffers.

`MovementSystem` updates movement-body slices as an ordered gameplay data
processor, using SIMD lanes inside each assigned range and
`ThreadSystem.parallelForWithOptions` when completion-time feedback shows the
batch is large enough. Worker ranges are aligned to movement cache-line
boundaries and only write their assigned movement rows.

`CollisionSystem` is a high-throughput contact generator over entities that have
both movement bodies and collision bounds. It owns warmed, 64-byte-aligned AABB
proxy scratch, preserves a sorted sweep-and-prune order across fixed steps, and
uses range-window broadphase passes with count/prefix/write contact output.
Contacts are transient `SimulationFrame` data; `CollisionResponseSystem`
consumes the completed same-step contact stream through explicit response-policy
components, computes aligned correction columns with `src/core/simd.zig`, and
applies sparse movement writes deterministically on the main thread before
structural commands commit.

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
mutation remains behind `DataSystem` batch commit boundaries; event and intent
streams are transient simulation data, not persistent `DataSystem` state.

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
