# Zig SDL3 GPU 2D Game

A performance-focused Zig 0.16.0 + SDL3/SDL_GPU 2D game project.

The project keeps SDL_GPU at the center of rendering, uses SDL3 for windowing,
input, text, and core PNG loading, and builds target-native shaders as part of
the Zig build. It is structured as a lean framework for deterministic state
flow, fixed-step gameplay, high-refresh rendering, safe runtime assets, and
data-oriented update systems.

## Features

### SDL_GPU Rendering

- SDL_GPU-first sprite and rectangle rendering through a game-facing `Renderer`
- Batched sprite commands with stable layer/submission ordering and renderer-owned GPU resources
- Generational `TextureId` handles so stale or destroyed texture IDs are rejected deterministically
- 1280x720 logical coordinates with resizable, high-DPI, aspect-preserving presentation
- Build-time shader output for supported targets: SPIR-V on Linux and Metal shaders on macOS

### Runtime Flow

- Fixed-step 60Hz gameplay updates with interpolated rendering for high-refresh displays
- State-stack flow for gameplay screens, modal overlays, pause behavior, and transition ordering
- Named input routing that separates held gameplay actions from one-frame app and debug commands
- Visibility-aware frame pacing so hidden or minimized windows do not keep advancing gameplay

### Performance-Focused Systems

- Pre-spawned worker threads for synchronous `parallelFor` CPU batches
- Main-thread participation in worker batches without creating threads during gameplay frames
- State-owned `DataSystem` with dense SoA storage for persistent gameplay data
- SIMD-aware movement processor over aligned SoA columns with serial and threaded paths
- Fixed-capacity particle system with SoA storage, SIMD updates, threaded ranges, and no steady-state allocation

### Assets, Text, And Debugging

- Runtime asset loading from the installed asset directory with traversal-safe relative paths
- Cached PNG texture leases backed by SDL3 core PNG loading
- Asset-backed SDL3_ttf text service with cached renderer textures
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
git clone git@github.com:Ronin15/Zig_SDL3_GPU_FrameWork.git
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

## Runtime Shape

The app starts as a resizable, high-pixel-density SDL window with a 1280x720
logical game size. The renderer recomputes presentation from the acquired
SDL_GPU drawable size each submitted frame, so world and logical UI drawing stay
in game coordinates while debug overlays can use raw drawable pixels.

The main loop stays timing-centric. SDL events, input routing, pause policy,
state dispatch, fixed updates, interpolation, rendering, assets, text, and worker
batches are coordinated through `src/app/`, `src/render/`, and `src/game/`.

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
