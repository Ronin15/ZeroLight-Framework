# ZeroLight Framework

A lean 2D game framework built with **Zig 0.16**, **SDL3**, and **SDL_GPU**.
It targets predictable runtime flow, data-oriented gameplay, and a clear split
between app coordination, rendering, assets, and simulation — without hiding
the hard parts of a real-time game behind convenience APIs.

The project is actively growing toward large procedural worlds, scoped
simulation, emergent AI, and production-friendly asset workflows. See
[framework implementation slices](docs/framework-implementation-slices.md) for
the live roadmap.

## Features

- **Runnable app shell** — main menu, settings, pause overlay, loading
  transitions, audio controls, and a debug overlay wired through one state stack
  and input-routing policy.
- **SDL_GPU rendering** — sprites, tilemaps, camera transforms, text, and
  ordered world drawing behind a small game-facing render API.
- **Worlds and tilemaps** — procedural multi-level worlds, chunk visibility,
  and tile editing that feeds navigation and gameplay.
- **Fixed-step simulation** — 60Hz gameplay with a pipeline of movement,
  collision, AI, pathfinding, particles, and related processors.
- **Emergent AI** — perception, memory, emotion, and behavior selection that
  feed steering and navigation instead of hard-coded chase loops.
- **Atlas-backed assets** — packed runtime atlases with stable IDs so art and
  audio can be swapped without rewriting game code.
- **Performance discipline** — threaded processors, benchmarks, and tests that
  keep hot paths allocation-free and behavior deterministic as the framework
  grows.

For design detail and ownership boundaries, start with
[architecture](docs/architecture.md). Topic guides cover
[state and input](docs/state-stack-and-input.md),
[rendering and shaders](docs/rendering-assets-shaders.md),
[atlas workflow](docs/atlas-asset-workflow.md), and
[simulation](docs/simulation-tiers-and-pipeline.md).

## Requirements

- Zig 0.16.0 or a compatible 0.16.x build
- SDL3, SDL3_ttf, and SDL3_mixer
- Shader toolchain: `glslc`; `spirv-cross` on macOS; `spirv-cross` and `dxc`
  on Windows

Linux and macOS use system development packages. Windows can fetch pinned SDL
packages through the build. See [setup](docs/setup.md) for platform notes.

## Quick Start

```sh
git clone git@github.com:Ronin15/ZeroLight-Framework.git
cd ZeroLight-Framework
zig build
zig build run
```

For the normal edit-and-run loop:

```sh
zig build dev
```

`zig build dev` compiles shaders, installs assets, builds the executable, and
runs the app.

## Commands

```sh
zig build           # build and install the app, runtime assets, and shaders
zig build run       # build, install assets/shaders, and run the app
zig build dev       # build shaders, install assets, and run the app
zig build check     # compile game, benchmark, and GPU smoke executables
zig build test      # run unit tests
zig build bench     # run CPU gameplay and render-prep benchmarks
zig build verify    # check + test + shaders + atlas lint (local dev gate)
zig build package   # install binaries and runtime assets for the selected mode
zig build gpu-smoke # display-gated renderer pipeline smoke test
```

Supporting commands:

```sh
zig build fmt         # format build.zig, build.zig.zon, and src/
zig build shaders     # compile GLSL sources to platform GPU shaders
zig build fetch-sdl   # fetch pinned Windows SDL packages (Windows only)
zig build assets-lint # lint runtime atlases and optional source sprite consistency
```

See [development workflow](docs/development-workflow.md) for release modes, build
options, and packaging notes.

## Project Layout

```text
build.zig / build.zig.zon   # build graph and project metadata
src/                        # framework source (app, render, game, assets, …)
assets/                     # runtime atlases, audio, fonts, shader sources
tools/                      # atlas packing, lint, and content helpers
docs/                       # architecture, workflow, and roadmap docs
```

Generated output lives under `zig-out/` and should not be committed.

## Documentation

- [Setup](docs/setup.md)
- [Development Workflow](docs/development-workflow.md)
- [Architecture](docs/architecture.md)
- [State Stack And Input](docs/state-stack-and-input.md)
- [Rendering, Assets, And Shaders](docs/rendering-assets-shaders.md)
- [Atlas Asset Workflow](docs/atlas-asset-workflow.md)
- [Simulation Tiers And Pipeline](docs/simulation-tiers-and-pipeline.md)
- [Framework Implementation Slices](docs/framework-implementation-slices.md)
- [Changelogs](docs/changelogs/)
- [Module Reviews](docs/reviews/)

## License

MIT — see [LICENSE](LICENSE).
