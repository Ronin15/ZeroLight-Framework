# 2D SDL_GPU Game Framework in Zig

This is a lean 2D game framework built with Zig 0.16.0, SDL3, and SDL_GPU. It
keeps the main loop small while app flow, state/input policy, rendering, assets,
text, and gameplay data each have clear places in the source tree.

The framework includes a fixed-step update loop, policy-driven game
states, named input actions, an SDL_GPU sprite renderer, safe runtime asset
loading, SDL3_ttf text, and data-oriented gameplay processors. Focused Zig tests
cover core runtime behavior, and `zig build gpu-smoke` is available when you
want to verify SDL_GPU frame submission.

## What Is Here

- **SDL_GPU rendering:** game states draw through `Renderer`; GPU setup,
  shader loading, texture ownership, batching, and frame submission stay in the
  render/platform layers.
- **Fixed-step game flow:** gameplay updates run at 60Hz, rendering interpolates
  between simulation ticks, and hidden or minimized windows do not keep
  advancing gameplay.
- **State and input policy:** `StateStack` handles gameplay screens, overlays,
  modal states, pause behavior, and queued transitions. Keyboard input maps to
  named actions for gameplay movement, app commands, and debug commands.
- **Runtime assets and text:** assets load from traversal-safe relative paths,
  PNG textures use core SDL3 loading, SDL3_ttf renders asset-backed text, and F2
  toggles the local FPS overlay.
- **Gameplay data systems:** `DataSystem` owns persistent entity data in dense
  stores for direct processor iteration, with movement and particle updates
  using serial, SIMD, and worker-thread paths where appropriate.
- **Project checks:** `zig build test` covers app, render, asset, and gameplay
  behavior. `zig build verify` adds compile coverage and shader compilation.

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
