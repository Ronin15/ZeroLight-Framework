# Repository Guidelines

## Project Intent

This is a Zig 0.16 + SDL3/SDL_GPU 2D game project. Keep the base lean,
dependency-light, and SDL_GPU-first. The build entry point is `build.zig`, with
project metadata in `build.zig.zon`.

Use the existing docs as source of truth for deeper details:

- `docs/architecture.md` for frame flow, source layout, and engine boundaries.
- `docs/state-stack-and-input.md` for state contracts, transition policies, and input mapping.
- `docs/rendering-assets-shaders.md` for SDL_GPU rendering, assets, PNG loading, shaders, and debug overlay.
- `docs/development-workflow.md` for build options, release modes, testing, and GPU smoke usage.

## Ownership Boundaries

- `src/main.zig` owns the executable entry point and high-level fixed-step timing loop.
- `src/app/` owns SDL app coordination, input, time loop, frame pacing, pause policy, state stack flow, and the thread system.
- `src/render/` owns SDL_GPU rendering, camera transforms, renderer resources, text, FPS/debug overlay, and frame submission.
- `src/game/` owns game/application states and gameplay behavior such as the demo state, pause state, and player.
- `src/platform/` owns SDL C imports, small platform wrappers, and GPU smoke-test implementation.
- `src/assets/` owns runtime asset path resolution and safe installed asset loading.
- `src/core/` owns small shared helpers such as math primitives.
- `src/root.zig` is the minimal test/root file for math aliases and compile coverage.
- `assets/` contains runtime assets and shader sources. Runtime assets install under `zig-out/bin/assets` by default.

Add new code under the matching owner directory. Keep executable-only code near
`main.zig`, app flow under `src/app/`, rendering and GPU resource code under
`src/render/`, and game-specific behavior under `src/game/`.

## Durable Architecture Rules

- Keep `src/main.zig` timing-centric; move coordination details into `src/app/`.
- `StateStack` owns state lifetimes, state destruction, policies, and transition application.
- Queue state transitions through `StateTransitions` from state dispatch, then apply them after dispatch completes.
- Game states draw through `Renderer`; keep SDL_GPU device, swapchain, shader, texture, and command submission details in render/platform layers.
- Map raw input to named actions. Keep held gameplay input in `InputState` separate from one-frame app commands in `FrameCommands`.
- Let stack policies decide whether lower states receive update, input, or render passes.
- Keep debug UI state in the debug overlay path, not in gameplay state.
- Keep runtime asset paths relative and traversal-safe.
- Use core SDL3 PNG loading for textures. Do not add `SDL3_image` unless that dependency is explicitly chosen.
- SDL3 and SDL3_ttf are system dependencies; avoid vendoring or half-adopting external dependencies.
- Pair SDL resource creation with cleanup close to the creation site.

## Slice Implementation Rules

- Treat implementation slices as full features, not partial scaffolds.
- Do not mark a slice complete until its runtime behavior, docs, tests, and acceptance checks are integrated.
- If a dependent system does not exist yet, label the work as foundation or preparation, and leave the actual feature checklist incomplete.
- Avoid half-wired states: either finish the feature end to end or keep the roadmap honest about what remains.

## Build, Test, And Development Commands

- `zig build` builds and installs the game executable to `zig-out/bin/my-sdl3-game`.
- `zig build run` builds, installs runtime assets/shaders, and runs the app.
- `zig build dev` builds shaders, installs assets, and runs the app for normal development.
- `zig build test` runs reusable module tests plus SDL-linked compile coverage.
- `zig build check` compiles the game and GPU smoke executable without installing.
- `zig build verify` runs check, tests, and shader compilation.
- `zig build shaders` compiles platform GPU shaders.
- `zig build gpu-smoke` runs a display-gated SDL_GPU frame submission check.
- `zig build fmt` formats `build.zig`, `build.zig.zon`, and `src/`.
- `zig build package` installs selected-mode game binaries and runtime assets.

Default optimize mode is `Debug`. Use explicit release modes such as
`zig build --release=safe`, `zig build --release=fast`, or
`zig build -Doptimize=ReleaseFast` only for release candidates or shipping
builds.

Shader tools are required for runnable builds. Linux emits SPIR-V shader files;
macOS emits Metal shader files through `spirv-cross`. `zig build gpu-smoke`
requires a usable display, video backend, and GPU.

## Coding And Testing Standards

Follow `zig fmt`; use 4-space indentation and avoid manual alignment that the
formatter will rewrite. Use Zig-style lowerCamelCase for variables and
functions, `PascalCase` for types, and short descriptive names. Keep error sets
explicit when practical, as in `error{SdlError}`.

Use Zig `test` blocks and `std.testing`. Put reusable module tests beside the
code they cover, and name tests by behavior, such as
`test "player movement clamps to window bounds"`.

Prefer focused tests for contracts that do not require opening a window: input
routing, state policy flow, transition ordering, resource ID validation,
viewport math, descriptor validation, asset path validation, and timing
decisions. Keep display/GPU checks in `gpu-smoke`.

## Generated Output And Configuration

`zig-out/` and `.zig-cache/` are generated output and should not be edited by
hand. Do not commit generated binaries or local machine paths.

If adding dependencies to `build.zig.zon`, keep hashes accurate and review the
fingerprint carefully because it affects project identity.
