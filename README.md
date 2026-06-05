# 2D SDL_GPU Game Framework in Zig

This is a lean 2D game framework built with Zig 0.16.0, SDL3, and SDL_GPU. It
is organized around predictable frame flow, SDL_GPU rendering, explicit
state/input policy, runtime assets and text, data-oriented architecture,
multi-threaded processing, and tests that keep those systems reliable as the
framework grows.

The goal is a framework that stays easy to reason about while still covering the
hard parts of a real-time 2D game: state flow, input routing, rendering,
resource ownership, fixed-step simulation, and processor-friendly gameplay data.

## Features

- **Fixed-step runtime flow:** a thin main loop with app coordination, state
  dispatch, pause policy, input routing, and interpolated rendering.
- **SDL_GPU rendering:** a game-facing `Renderer` with shader loading, texture
  ownership, sprite batching, and frame submission kept behind render/platform
  boundaries.
- **Data-oriented architecture:** dense component stores for direct,
  cache-friendly processor iteration over gameplay data.
- **Threaded and SIMD processors:** movement and particle updates with serial,
  SIMD, and worker-thread execution paths.
- **Comprehensive tests:** coverage for state transitions, input routing,
  resource lifetime, renderer math, threaded batches, and SIMD/scalar parity so
  framework behavior stays stable as it grows.
- **Runtime asset and text services:** traversal-safe asset paths, core SDL3 PNG
  loading, asset-backed SDL3_ttf text rendering, and an F2 FPS overlay.

For deeper details, see [architecture](docs/architecture.md),
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

For the normal edit and run loop:

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

- `build.zig` defines executables, tests, formatting, shaders, and install steps.
- `build.zig.zon` contains project metadata.
- `src/main.zig` contains the entry point and high-level fixed-step loop.
- `src/app/` contains SDL coordination, input, timing, pause policy, frame pacing, threads, and state stack flow.
- `src/render/` contains SDL_GPU rendering, camera transforms, GPU resources, text, and the debug overlay.
- `src/game/` contains game states, gameplay data, and ECS-style processors.
- `src/platform/` contains SDL/platform helpers and GPU smoke-test code.
- `src/assets/` contains runtime path resolution, installed-file loading, and cache-backed texture ownership.
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
