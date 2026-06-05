# Zig SDL3 GPU 2D Game

Zig SDL3 GPU 2D Game is a lean real-time 2D project built on Zig 0.16.0,
SDL3, and SDL_GPU. The architecture keeps the main loop small and separates app
coordination, state/input policy, SDL_GPU rendering, asset ownership, and
gameplay data processing into clear runtime boundaries.

The project is strongest where engine work usually becomes fragile: fixed-step
updates, queued state transitions, modal input routing, logical-to-drawable
presentation, renderer resource identity, sprite batch construction,
multi-threaded SoA processors, and SIMD/scalar parity. Those behaviors are
covered by focused Zig tests so refactors can be checked against runtime rules
before playtesting.

## Design Focus

- **Executable contracts:** `zig build test` covers the rules that make the
  runtime dependable: state lifetime and dispatch policy, named input routing,
  transition ordering, frame timing, resource generations, asset cache lifetime,
  text cache identity, renderer batch construction, viewport math, thread batch
  scheduling, SIMD/scalar equivalence, SoA alignment, and gameplay processors.
- **SDL_GPU rendering boundary:** game code draws through `Renderer`; GPU device
  setup, swapchain handling, shader loading, texture ownership, batching, and
  command submission stay in the rendering layers. Shader builds emit SPIR-V on
  Linux and Metal shader output on macOS.
- **Deterministic app flow:** `src/main.zig` keeps the high-level fixed-step
  loop thin. `Engine` coordinates SDL services, pause/frame visibility policy,
  input, state dispatch, and rendering. Gameplay updates run at a fixed 60Hz,
  with interpolation used for rendering.
- **Policy-driven states and input:** `StateStack` owns state lifetimes,
  queued transitions, overlays, modal behavior, opaque screens, and pass-through
  rules. Raw input maps to named actions so held gameplay input and one-frame
  app/debug commands can be routed by active state policy.
- **Data-oriented gameplay systems:** `DataSystem` uses generational entity IDs,
  component masks, and dense typed SoA stores. Hot movement columns are aligned
  for SIMD loads, and worker ranges are split so processors own the rows they
  mutate.
- **Practical runtime services:** runtime asset paths are relative and
  traversal-safe, PNG textures load through core SDL3, retained texture leases
  keep renderer resources explicit, SDL3_ttf text is asset-backed and cached,
  diagnostics use scoped Zig logging, and F2 toggles the local FPS overlay.

For deeper implementation details, see
[architecture](docs/architecture.md),
[state stack and input](docs/state-stack-and-input.md), and
[rendering, assets, and shaders](docs/rendering-assets-shaders.md).

## Requirements

- Zig 0.16.0 or a compatible 0.16.x build
- SDL3 development headers and library
- SDL3_ttf development headers and library
- `glslc` for shader compilation
- `spirv-cross` for macOS Metal shader generation

See [setup](docs/setup.md) for platform package notes.

## Quick Start

```sh
git clone git@github.com:Ronin15/Zig_SDL3_GPU_Framework.git
cd Zig_SDL3_GPU_Framework
zig build
zig build run
```

For the normal edit/run loop:

```sh
zig build dev
```

`zig build dev` compiles shaders, installs assets, builds the executable, and
runs the app.

## Commands

```sh
zig build           # build and install a runnable app into zig-out/bin
zig build run       # build, install assets/shaders, and run the app
zig build dev       # build shaders, install assets, and run the app
zig build check     # compile the game and GPU smoke executable
zig build test      # run Zig unit tests
zig build verify    # run check, test, and shader compilation
zig build package   # install selected-mode binaries and runtime assets
zig build gpu-smoke # create an SDL_GPU device and submit one frame
```

See [development workflow](docs/development-workflow.md) for release modes,
build options, formatting, shader commands, and GPU smoke details.

## Project Layout

- `build.zig` defines executables, tests, formatting, shader compilation, and install steps.
- `build.zig.zon` contains project metadata.
- `src/main.zig` contains the executable entry point and high-level fixed-step timing loop.
- `src/app/` contains SDL app coordination, input routing, timing, pause policy, frame pacing, thread system, and state stack flow.
- `src/render/` contains SDL_GPU rendering, camera transforms, GPU resources, text, and debug overlay rendering.
- `src/game/` contains game/application states, gameplay data, and ECS-style processors.
- `src/platform/` contains SDL/platform integration helpers and GPU smoke-test code.
- `src/assets/` contains runtime asset path resolution, installed-file loading, and cache-backed texture ownership.
- `src/core/` contains small shared helpers.
- `assets/` contains runtime assets, bundled fonts, and shader sources.

Generated build output goes under `zig-out/` and should not be committed.

## Documentation

- [Setup](docs/setup.md)
- [Development Workflow](docs/development-workflow.md)
- [Architecture](docs/architecture.md)
- [State Stack And Input](docs/state-stack-and-input.md)
- [Rendering, Assets, And Shaders](docs/rendering-assets-shaders.md)

## License

This project is licensed under the MIT License. See `LICENSE` for details.
