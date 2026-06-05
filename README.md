# Zig SDL3 GPU 2D Game

A performance-focused Zig 0.16.0 + SDL3/SDL_GPU 2D game project built around
explicit systems, deterministic frame flow, and testable game-framework
contracts.

Zig is part of the architecture here: `build.zig` owns the development loop,
shader generation, asset installation, unit tests, compile checks, GPU smoke
checks, and packaging. Testable framework logic carries inline Zig tests beside
the code it verifies, then `src/tests.zig` collects those modules into one fast
suite. That gives the project a strong contract layer for input, state flow,
timing, resources, threading, renderer batching, SIMD helpers, and gameplay
processors before full-game playtesting takes over.

## Highlights

- **Zig-native development loop:** `zig build dev`, `zig build test`,
  `zig build check`, `zig build verify`, shader compilation, asset installation,
  and packaging all run through the project build. Debug builds stay direct and
  test-heavy; release modes are explicit.
- **SDL_GPU-first rendering:** game code draws through a small renderer API while
  GPU device setup, shader loading, batching, texture ownership, and frame
  submission stay in the render layer. The build emits platform shader outputs:
  SPIR-V on Linux and Metal shaders on macOS.
- **Stable frame and state flow:** gameplay updates run at a fixed 60Hz while
  rendering interpolates for high-refresh displays. A policy-driven state stack
  handles gameplay screens, overlays, pause behavior, input routing, and ordered
  transitions.
- **Multi-threaded data processing:** gameplay state owns dense data columns for
  processor-friendly iteration. The shared thread system scales to the host CPU,
  adapts worker use per batch, and is already used by SIMD-aware movement and
  particle updates with serial paths for small workloads.
- **Practical runtime services:** installed assets use traversal-safe relative
  paths, PNG textures are cached through SDL3 core loading, text rendering uses
  asset-backed SDL3_ttf textures, and F2 toggles a local FPS overlay.

For technical details, see
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

See [architecture](docs/architecture.md) and
[rendering, assets, and shaders](docs/rendering-assets-shaders.md) for the full
frame flow and rendering model.

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
