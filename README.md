# Zig SDL3 GPU 2D Game

A performance-focused Zig 0.16.0 + SDL3/SDL_GPU 2D game project.

The project keeps SDL_GPU at the center of rendering, uses SDL3 for windowing,
input, text, and core PNG loading, and builds target-native shaders as part of
the Zig build. It is structured as a lean framework for deterministic state
flow, fixed-step gameplay, high-refresh rendering, safe runtime assets, and
data-oriented update systems.

## What It Provides

### SDL_GPU Rendering Foundation

- A renderer built around SDL_GPU
- Sprite drawing through a small game-facing renderer API
- Batched draw submission with stable layer ordering and renderer-owned GPU resources
- Resizable high-DPI presentation that keeps gameplay in 1280x720 logical coordinates
- Build-time shader outputs for supported targets: SPIR-V on Linux and Metal shaders on macOS

### Predictable Game Flow

- Fixed-step 60Hz gameplay updates with interpolated rendering for high-refresh displays
- State-stack driven screens, overlays, pause behavior, and ordered transitions
- Named input actions that separate held gameplay movement from one-frame app/debug commands
- Visibility-aware frame pacing so hidden or minimized windows do not keep advancing gameplay

### Data-Oriented Gameplay Systems

- State-owned gameplay data in dense columns that processors can iterate directly
- A SIMD-aware movement system that proves the data path with serial and threaded execution
- A fixed-capacity particle system that reuses storage and avoids steady-state allocation
- Pre-spawned worker support for deterministic frame-bounded CPU work

### Assets, Text, And Debugging

- Runtime asset loading from the installed asset directory with traversal-safe relative paths
- Cached PNG texture ownership backed by SDL3 core PNG loading
- Asset-backed SDL3_ttf text rendering with cached renderer textures
- Optional F2 FPS overlay for local debugging

Technical details live in the docs:
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
cd Zig_SDL3_GPU_FrameWork
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
