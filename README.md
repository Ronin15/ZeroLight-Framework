# Zig SDL3 GPU 2D Game Starter

A Zig 0.16.0 + SDL3 clone-and-edit starter for SDL_GPU-first 2D games.

The project uses SDL3 for windowing, input, core PNG loading, and GPU rendering.
It builds target-native shaders at build time and renders through SDL_GPU.

## Features

- SDL3 window, event loop, and keyboard input
- SDL_GPU sprite and rectangle rendering
- Metal shaders on macOS and SPIR-V shaders on Linux
- Fixed 60Hz simulation with interpolation for varying-refresh rendering
- Vsync-paced visible rendering with 60Hz background throttling
- Player-controlled pause and forced pause for hidden, minimized, or no-swapchain frames
- State stack for gameplay, screens, and overlays
- Held gameplay input plus one-frame commands
- Pre-spawned thread system for parallel CPU batches that finish before the next engine step
- Runtime asset loading from the installed `assets/` directory
- F2 debug FPS overlay using SDL3_ttf
- GPU smoke executable for SDL_GPU device and frame-submission checks

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
- `build.zig.zon` contains package metadata.
- `src/main.zig` contains the executable entry point and high-level fixed-step timing loop.
- `src/app/` contains SDL app coordination, input, timing, pause policy, frame pacing, thread system, and state stack flow.
- `src/render/` contains SDL_GPU rendering, camera transforms, GPU resources, and debug overlay rendering.
- `src/game/` contains game/application states such as the temporary demo and pause overlay.
- `src/platform/` contains SDL/platform integration helpers and GPU smoke-test code.
- `src/assets/` contains runtime asset path resolution and installed-file loading.
- `src/core/` contains small shared starter helpers.
- `assets/` contains runtime assets and shader sources.

Generated build output goes under `zig-out/` and should not be committed.

## Documentation

- [Setup](docs/setup.md)
- [Development Workflow](docs/development-workflow.md)
- [Architecture](docs/architecture.md)
- [State Stack And Input](docs/state-stack-and-input.md)
- [Rendering, Assets, And Shaders](docs/rendering-assets-shaders.md)
- [Clone And Edit](docs/clone-and-edit.md)

## License

This project is licensed under the MIT License. See `LICENSE` for details.
