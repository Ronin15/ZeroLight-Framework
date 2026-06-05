# Architecture

The project is organized for 2D game work. Keep executable timing thin, app
coordination under `src/app/`, GPU work under `src/render/`, and game-specific
behavior under `src/game/`.

## Source Layout

- `src/main.zig` creates `AppConfig`, initializes `Engine`, and runs the fixed-step loop.
- `src/app/engine.zig` coordinates SDL app flow, the window, asset cache, text service, renderer, state stack, pause controller, input, debug overlay, and thread system.
- `src/app/time_loop.zig` keeps simulation fixed at 60Hz.
- `src/app/frame_pacer.zig` classifies window visibility and applies fallback frame pacing.
- `src/app/state.zig` manages state allocation, destruction, policies, and queued transitions.
- `src/app/thread_system.zig` provides pre-spawned workers for synchronous parallel CPU batches.
- `src/app/resolution.zig` owns pure logical-resolution, viewport, and coordinate conversion policy.
- `src/render/renderer.zig` is the game-facing render facade and frame coordinator.
- `src/render/sprite_batch.zig` owns sprite draw command sorting, vertex construction, draw grouping, and allocation-free warmed batch prep.
- `src/render/gpu/` owns SDL_GPU device/window setup helpers, upload buffers, texture uploads, and sprite material/pipeline creation.
- `src/render/text.zig` owns SDL3_ttf lifecycle, asset-backed fonts, and cached text textures.
- `src/render/debug_overlay.zig` and `src/render/fps_counter.zig` draw the F2 FPS overlay.
- `src/game/demo_state.zig` and `src/game/pause_state.zig` are the current game states.
- `src/game/data_system.zig` owns state-local persistent entity data in dense
  SoA stores for gameplay and render systems.
- `src/game/player.zig` keeps player-specific input and facing behavior while
  storing persistent player data in `DataSystem`.
- `src/platform/` contains shared SDL C imports and GPU smoke-test code.
- `src/assets/assets.zig` resolves safe runtime asset paths, and `src/assets/cache.zig` caches renderer-backed runtime assets.
- `src/core/` contains small shared helpers such as math primitives and portable SIMD aliases.

## Frame Flow

`src/main.zig` keeps the high-level loop:

1. Begin a frame and clear one-frame commands.
2. Poll SDL events and dispatch them through the engine and state stack.
3. Apply pause and frame visibility policy.
4. Run fixed 60Hz updates while the time accumulator needs them.
5. Render with interpolation between fixed updates.

Visible rendering is paced by SDL_GPU swapchain acquisition with the configured
present mode. Hidden, minimized, or no-swapchain frames skip GPU rendering,
enter pause, and use `SDL_DelayNS` fallback pacing. Occluded or unfocused visible
windows keep rendering but apply a 60Hz cap to avoid background render runaway.

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

Raw keyboard input maps to named actions in `src/app/input.zig`. Gameplay code
reads held actions from `InputState`; app-level actions such as pause, resume,
quit, and debug overlay toggle are latched through `FrameCommands`.

State policies decide whether lower states receive updates, events, or render
passes. Transitions are queued through `StateTransitions` and applied after the
current dispatch completes.

## Thread System

`Engine` creates a `ThreadSystem` and passes it through `UpdateContext` and
`RenderContext`. Game states and future systems can use `parallelFor` for
parallel CPU work that must finish before the next system or render phase.

Workers are pre-spawned at startup. The default background worker count is based
on CPU count, with the main/render thread participating as an additional worker
while it waits. Small batches run inline on the main thread, and batch
submission does not allocate after initialization.

## Gameplay Data

Gameplay states own their own `DataSystem`; it is not an app singleton. The
system stores persistent world entities, per-entity component masks for system
membership queries, and typed SoA data such as movement bodies, facing,
primitive visual intent, and relative asset references.

Hot gameplay data is stored as scalar columns. The movement-body store exposes
aligned `position_x`, `position_y`, `previous_x`, `previous_y`, `velocity_x`,
`velocity_y`, and `speed` slices so update processors can load lanes directly
with `src/core/simd.zig`. Component masks decide whether an entity belongs to a
system; hot processors iterate already aligned SoA slices.

Update systems mutate `DataSystem` slices during fixed-step updates. Render
systems read immutable `DataSystem` slices during state render and submit draw
calls through `Renderer`. `DataSystem` does not own SDL handles, GPU handles,
live renderer texture IDs, asset leases, input frame state, thread-system state,
transient events, or scratch buffers.

The demo player is intentionally a special-case facade for player input and
facing rules, backed by `DataSystem` data. Future enemies and other world
objects should normally be plain entities processed by enemy, movement,
collision, AI, or render systems rather than copies of player behavior.

## SIMD Helpers

`src/core/simd.zig` provides project-named four-lane vector aliases and helper
functions for future SoA movement, particle, and data processor loops. The
helpers use Zig `@Vector` operations as the portable abstraction so LLVM can
lower vector math to the target CPU features, such as SSE-family instructions on
x86 targets or NEON on ARM targets, when the target and optimization mode make
that profitable. Platform intrinsics such as x86 or ARM-specific calls stay
hidden from gameplay and are not part of the first implementation.

Prefer scalar code for tiny batches or simple logic where vectorization would
make the code harder to read. Use the SIMD helpers when a processor already
operates over dense slices and can handle vector ranges plus a scalar tail.
