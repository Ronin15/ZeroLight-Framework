# Zig SDL3 Game Engine Framework Guide

## Project Intent

Use this guidance for lean Zig SDL3/SDL_GPU 2D game projects. Treat the codebase as a normal game project. Keep the base Linux-friendly, SDL_GPU-first, and dependency-conscious. Prefer SDL3 plus Zig standard library facilities unless the user explicitly chooses a dependency.

## Ownership Boundaries

- `src/main.zig` owns the executable entry point and high-level fixed-step timing loop.
- `src/app/` owns SDL3 app coordination, input, timing, frame pacing, pause policy, and state stack flow.
- `src/render/` owns SDL_GPU rendering, camera transforms, renderer resources, text, FPS counter, and debug overlay rendering.
- `src/game/` owns game/application states such as the demo state, pause state, and gameplay-specific behavior.
- `src/platform/` owns SDL/platform integration helpers and GPU smoke-test implementation.
- `src/assets/` owns runtime asset path resolution and installed asset lookup.
- `src/core/` owns small shared helpers such as math primitives.
- `src/root.zig` should stay limited to math aliases and compile coverage; feature code should live under the matching `src/` area.

Keep `src/main.zig` timing-centric. Let app/state code own state lifetimes and transition application. Keep renderer APIs as the path game code uses for drawing instead of calling SDL_GPU directly from game states.

## Slice Completion

Roadmap slices are full features. Runtime behavior, docs, tests, and acceptance checks must all be integrated before a slice is complete. If a needed dependency does not exist yet, label the result as foundation or preparation and leave the feature checklist incomplete.

## Build And Validation Commands

- `zig build`: build and install a runnable app to `zig-out/bin`.
- `zig build run`: build, install runtime assets/shaders, and run the app.
- `zig build dev`: shader build, asset install, and run loop for normal development.
- `zig build test`: run Zig unit tests.
- `zig build check`: compile the game and GPU smoke executable.
- `zig build verify`: run check, tests, and shader compilation.
- `zig build shaders`: compile platform GPU shaders.
- `zig build gpu-smoke`: open a small display-gated SDL_GPU smoke window and submit one frame.
- `zig build package`: install selected-mode binaries and runtime assets.
- `zig build fmt`: format `build.zig`, `build.zig.zon`, and `src/`.

Default optimize mode is `Debug`. Use explicit release modes only for release candidates or shipping builds.

## Rendering And Timing Rules

The app uses SDL_GPU directly and does not call Vulkan APIs itself. Game code should draw through `Renderer`. Shader sources live in `assets/shaders/*.glsl` and build into installed runtime shader files.

Preserve fixed 60Hz simulation through the time loop. Visible rendering is paced by SDL_GPU swapchain acquisition and may follow higher refresh displays. Hidden, minimized, or no-swapchain frames may skip rendering and use fallback delay pacing so gameplay does not advance while the player cannot see it.

Do not convert visible rendering into a blanket 60 FPS cap. If a pacing change is needed, base it on window/swapchain state and the existing frame-pacer policy.

## Input And State Flow

Map raw input to named actions. Keep held gameplay input separate from one-frame commands. Keep debug state in debug UI. Let stack policies decide whether lower states receive update, input, or render passes.

Apply state transitions after dispatch. State stack code should own state lifetimes. Modal overlays should be able to block gameplay input underneath; pass-through overlays should keep lower gameplay active where policy allows.

## Asset And Shader Rules

Runtime assets live under `assets/` and are installed to `zig-out/bin/assets` unless `-Dasset-root` changes the root. Keep asset paths relative and traversal-safe. PNG texture loading uses core SDL3 support; do not add SDL3_image unless the user explicitly asks.

Shader tools are required for runnable builds. Linux uses SPIR-V output; macOS uses SPIR-V converted to MSL. If shader compilation fails, separate shader tool availability from Zig compile errors.

## Testing Guidance

Use Zig `test` blocks and `std.testing`. Put reusable module tests beside the code they cover. Name tests by behavior, such as `test "player movement clamps to window bounds"`.

Prefer tests that validate contracts directly: input routing behavior, state policy flow, resource ID validation, viewport math, descriptor validation, or timing decisions. Do not require a window for ordinary unit tests.

Use an aggregate test root when nested imports would otherwise cross module paths. Keep GPU smoke checks separate from non-interactive unit behavior because they require a usable display and GPU backend.
