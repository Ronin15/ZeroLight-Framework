# Architecture

The project is organized for 2D game work. Keep executable timing thin, app
coordination under `src/app/`, GPU work under `src/render/`, and game-specific
behavior under `src/game/`.

## Source Layout

- `src/main.zig` creates `AppConfig`, initializes `Engine`, and runs the fixed-step loop.
- `src/app/engine.zig` coordinates SDL app flow, the window, assets, renderer, state stack, pause controller, input, debug overlay, and thread system.
- `src/app/time_loop.zig` keeps simulation fixed at 60Hz.
- `src/app/frame_pacer.zig` classifies window visibility and applies fallback frame pacing.
- `src/app/state.zig` manages state allocation, destruction, policies, and queued transitions.
- `src/app/thread_system.zig` provides pre-spawned workers for synchronous parallel CPU batches.
- `src/app/resolution.zig` owns pure logical-resolution, viewport, and coordinate conversion policy.
- `src/render/renderer.zig` manages the SDL_GPU device, window claim, swapchain setup, logical presentation, sprite pipeline, textures, and frame submission.
- `src/render/debug_overlay.zig` and `src/render/fps_counter.zig` draw the F2 FPS overlay.
- `src/game/demo_state.zig` and `src/game/pause_state.zig` are the current game states.
- `src/platform/` contains shared SDL C imports and GPU smoke-test code.
- `src/assets/assets.zig` resolves safe runtime asset paths.
- `src/core/` contains small shared helpers such as math primitives.

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
texture size and current SDL window size. World and logical UI draws use the
configured logical size and SDL_GPU viewport/scissor state; drawable overlays use
raw swapchain pixels. The project does not use `SDL_Renderer` logical
presentation.

## Coordination Boundaries

Game states draw through `Renderer`; they should not call SDL_GPU directly.
Window, GPU device, swapchain, shader, texture, and frame submission code stays
under `src/render/` and `src/app/`.

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
