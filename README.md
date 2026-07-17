# ZeroLight Framework

A lean 2D game framework built with **Zig 0.16**, **SDL3**, and **SDL_GPU**.
It targets predictable runtime flow, data-oriented gameplay, and a clear split
between app coordination, rendering, assets, and simulation.

The project is actively growing toward large procedural worlds, scoped
simulation, richer emergent AI, and production-friendly asset workflows.

## Features

- **Runnable app shell** — main menu, settings, pause overlay, loading
  transitions, audio controls, and debug overlays on one state stack with
  policy-driven input routing.
- **Keyboard and gamepad** — controller support for menus, pause, dig, move,
  and interact, with disconnect handling and held-input release when focus
  leaves gameplay.
- **SDL_GPU rendering** — sprites, multi-level tilemaps, camera transforms,
  text, and ordered world drawing behind a small game-facing render API.
- **Worlds and tilemaps** — procedural multi-level worlds, chunk visibility,
  dig and plane traversal between floors, and tile edits that feed navigation
  and gameplay.
- **Fixed-step simulation** — 60Hz gameplay with a pipeline of movement,
  collision, AI, pathfinding, particles, and small domain controllers (dig,
  audio, early interactables).
- **Emergent AI (in progress)** — early substrate, not a finished AI game
  layer. Agents can see and hear, keep short-term memory, carry simple emotion
  drives, and choose among a few locomotion behaviors; personalities and
  interest points are data-authored. Hearing digs/footsteps/impacts and
  investigate markers are wired; combat AI, deeper goals, coupled feelings, and
  broader world reactions are still on the roadmap.
- **Action intents and destructibles (early)** — a typed interact/attack bus
  with a first consumer (smashable crates that open navigation). Not a full
  combat or interaction system yet.
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
zig build verify    # check + test + shaders + atlas + idiom lint (local gate)
zig build package   # install binaries and runtime assets for the selected mode
zig build gpu-smoke # display-gated renderer pipeline smoke test
```

Supporting commands:

```sh
zig build fmt         # format build.zig, build.zig.zon, and src/
zig build shaders     # compile GLSL sources to platform GPU shaders
zig build fetch-sdl   # fetch pinned Windows SDL packages (Windows only)
zig build assets-lint # lint runtime atlases and optional source sprite consistency
zig build idiom-lint  # lint Zig naming, stdlib currency, and unsafe catch patterns
```

See [development workflow](docs/development-workflow.md) for release modes, build
options, and packaging notes.

## Project Layout

```text
build.zig / build.zig.zon   # build graph and project metadata
src/                        # framework source (app, render, game, assets, …)
assets/                     # runtime atlases, audio, fonts, AI data, shaders
tools/                      # atlas packing, lint, and content helpers
docs/                       # architecture, workflow, and design docs
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

## License


MIT — see [LICENSE](LICENSE).
