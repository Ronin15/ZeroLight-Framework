# Zig SDL3 GPU 2D Game

A Zig 0.16.0 + SDL3 project for SDL_GPU-first 2D games.

The project uses SDL3 for windowing, input, core PNG loading, and GPU rendering.
It builds target-native shaders at build time and renders through SDL_GPU.

## Features

- 2D game structure with app, game, render, asset, and platform layers
- SDL_GPU-first rendering with sprites, primitive rectangles, batching, and shader build steps
- 1280x720 logical game coordinates with resizable, high-DPI, aspect-preserving fit presentation
- Fixed-step 60Hz simulation with interpolated rendering for high-refresh displays
- State-stack flow for gameplay screens, modal overlays, and pause behavior
- Policy-based input routing for gameplay, app commands, UI, and debug actions
- Runtime asset loading from the installed asset directory with safe relative paths
- Linux and macOS shader pipeline: SPIR-V on Linux, Metal shaders on macOS
- Development workflow with `run`, `dev`, `test`, `check`, `verify`, `gpu-smoke`, and `package`
- Optional F2 FPS overlay for local debugging

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

## Logical Resolution

The app starts as a resizable, high-pixel-density SDL window with a 1280x720
logical game size. The default presentation mode is aspect-preserving fit:
gameplay and logical UI keep their proportions, and letterbox or pillarbox bars
use the configured clear color.

SDL_GPU swapchain textures can be larger than the window on high-DPI displays.
The renderer recomputes presentation from the acquired drawable size every
submitted frame. World and logical draws use logical coordinates; drawable
overlays use raw swapchain pixels.

Integer-fit presentation is intended for strict pixel scaling. When enabled, the
app requests a minimum SDL window size equal to the logical size so user resizing
does not normally crop the game below 1x scale.

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
- `src/render/` contains SDL_GPU rendering, camera transforms, GPU resources, and debug overlay rendering.
- `src/game/` contains game/application states such as the temporary demo and pause overlay.
- `src/platform/` contains SDL/platform integration helpers and GPU smoke-test code.
- `src/assets/` contains runtime asset path resolution, installed-file loading, and cache-backed texture ownership.
- `src/core/` contains small shared helpers.
- `assets/` contains runtime assets and shader sources.

Generated build output goes under `zig-out/` and should not be committed.

## Documentation

- [Setup](docs/setup.md)
- [Development Workflow](docs/development-workflow.md)
- [Architecture](docs/architecture.md)
- [State Stack And Input](docs/state-stack-and-input.md)
- [Rendering, Assets, And Shaders](docs/rendering-assets-shaders.md)

## License

This project is licensed under the MIT License. See `LICENSE` for details.
