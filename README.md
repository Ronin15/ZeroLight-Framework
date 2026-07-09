# ZeroLight Framework

This is a lean 2D game framework built with Zig 0.16.0, SDL3, and SDL_GPU. It
is organized around predictable frame flow, SDL_GPU rendering, explicit
state/input policy, atlas-backed runtime assets, data-oriented architecture,
multi-threaded processing, and tests that keep those systems reliable as the
framework grows.

The current `world` branch adds a procedural 512×512 world foundation,
GPU-driven dense tilemaps, a state-owned `SimulationPipeline` with scoped
simulation tiers, a split Z-aware pathfinding package, and pipeline-owned dig
and audio controllers.

The goal is a framework that stays easy to reason about while still covering the
hard parts of a real-time 2D game: state flow, input routing, rendering,
resource ownership, fixed-step simulation, world-scale asset workflows, and
processor-friendly gameplay data.

## Features

- **Fixed-step runtime flow:** a thin main loop with app coordination, state
  dispatch, pause policy, input routing, and interpolated rendering.
- **Usable app shell:** a startup main menu, modal settings screen, live audio
  gain controls, a runtime-asset-backed loading transition into gameplay, pause
  overlay, and debug overlay all run through the same state stack and
  input-routing rules.
- **SDL_GPU rendering:** a game-facing `Renderer` with sprite and tilemap
  pipelines, texture ownership, ordered render prep, GPU-driven dense tilemaps,
  world depth ordering, and frame submission kept behind render/platform
  boundaries.
- **World and tilemaps:** `WorldSystem` owns dense/sparse tile SoA storage,
  chunk visibility, procedural chunk generation, and nav-blocker integration;
  dense layers draw as one retained quad per layer with tile ids in a GPU
  storage buffer.
- **Simulation pipeline:** `SimulationPipeline` owns fixed-step processor
  order; `SimulationScopeSystem` gates movement, collision, and AI by tier,
  camera halo, and stagger cadence.
- **Atlas-backed world assets:** filename-driven atlas packing for world tiles,
  characters, and items, with JSON sidecar metadata, stable sprite IDs, and
  name-based lookup at runtime.
- **Data-oriented architecture:** dense component stores for direct,
  cache-friendly processor iteration over gameplay data.
- **Threaded and SIMD processors:** movement, particles, AI, collision,
  pathfinding, navigation rebuilds, scoped gathers, and steering use dense data,
  typed simulation streams, deterministic outputs, serial baselines, and
  worker-thread/SIMD paths where appropriate.
- **Comprehensive tests:** coverage for state transitions, input routing,
  resource lifetime, renderer math, threaded CPU range batches, and SIMD/scalar
  parity so framework behavior stays stable as it grows.
- **Runtime asset, audio, and text services:** traversal-safe asset paths,
  stable sprite/audio IDs, core SDL3 PNG loading, SDL3_mixer audio ownership,
  asset-backed SDL3_ttf text rendering, and an F2 FPS overlay.

For deeper details, see [architecture](docs/architecture.md),
[state stack and input](docs/state-stack-and-input.md),
[rendering, assets, and shaders](docs/rendering-assets-shaders.md),
[atlas asset workflow](docs/atlas-asset-workflow.md), and
[simulation tiers and pipeline](docs/simulation-tiers-and-pipeline.md).

## Requirements

- Zig 0.16.0 or a compatible 0.16.x build
- SDL3, SDL3_ttf, and SDL3_mixer
  - Linux and macOS use system development packages.
  - Windows defaults to pinned packages fetched by Zig's package manager.
- `glslc` for shader compilation
- `spirv-cross` for macOS Metal shader generation
- `spirv-cross` and `dxc` for Windows DXIL shader generation

See [setup](docs/setup.md) for platform package notes.

## Quick Start

```sh
git clone git@github.com:Ronin15/ZeroLight-Framework.git
cd ZeroLight-Framework
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
zig build           # build and install the app, runtime assets, and shaders
zig build run       # build, install assets/shaders, and run the app
zig build dev       # build shaders, install assets, and run the app
zig build check     # compile the game, benchmark, and GPU smoke executables
zig build test      # run Zig unit tests
zig build bench     # run non-interactive CPU gameplay and render-prep benchmarks
zig build verify    # run check, test, shader compilation, and atlas lint
zig build package   # install selected-mode binaries and runtime assets
zig build gpu-smoke # run a display-gated renderer pipeline smoke
```

See [development workflow](docs/development-workflow.md) for release modes,
build options, formatting, shader commands, and GPU smoke details.

## Project Layout

- `build.zig` defines executables, tests, formatting, shaders, and install steps.
- `build.zig.zon` contains project metadata.
- `src/main.zig` contains the entry point and high-level fixed-step loop.
- `src/app/` contains SDL coordination, input, timing, pause policy, frame pacing, audio, threads, and state stack flow.
- `src/render/` contains SDL_GPU rendering, camera transforms, GPU resources, text, and the debug overlay.
- `src/game/` contains game states, `WorldSystem`, `DataSystem`,
  `SimulationPipeline`, pipeline-owned controllers, and SoA gameplay processors
  (including the `pathfinding/` subpackage).
- `src/platform/` contains SDL/platform helpers and GPU smoke-test code.
- `src/assets/` contains runtime path resolution, installed-file loading, the typed asset manifest, atlas metadata loaders, runtime asset catalog, and cache-backed texture ownership.
- `src/core/` contains small shared helpers.
- `assets/` contains runtime atlases, audio, bundled fonts, and shader sources.
- `tools/` contains atlas packing, export, lint, art-generation, and benchmark helpers (see [tools/README.md](tools/README.md)).

Generated build output goes under `zig-out/` and should not be committed.

## Documentation

- [Setup](docs/setup.md)
- [Development Workflow](docs/development-workflow.md)
- [Architecture](docs/architecture.md)
- [State Stack And Input](docs/state-stack-and-input.md)
- [Rendering, Assets, And Shaders](docs/rendering-assets-shaders.md)
- [Atlas Asset Workflow](docs/atlas-asset-workflow.md)
- [Simulation Tiers And Pipeline](docs/simulation-tiers-and-pipeline.md)
- [Framework Implementation Slices](docs/framework-implementation-slices.md) (frontier roadmap; settled slices are in [archive](docs/framework-implementation-slices-archive.md))
- [Changelogs](docs/changelogs/) (per-branch feature summaries; latest: [world](docs/changelogs/world.md))
- [Module Reviews](docs/reviews/) (pathfinder, GPU, and other deep dives)

## License

This project is licensed under the MIT License. See `LICENSE` for details.
