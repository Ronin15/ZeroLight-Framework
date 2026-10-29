# ZeroLight Framework

A 2D engine for a colony sim, built with **Zig 0.17**, **SDL3**, and **SDL_GPU**.

One world is playable today: many floors, ground you can dig, and people living in it. The aim is a colony that keeps going everywhere else too, on deeper stacks and in more worlds, whether you are looking or not.

The engine is held to a few principles:

- **Data-oriented** — gameplay data sits in dense columns and is processed in batches.
- **Allocation-free hot paths** — a running frame and a simulation step do not allocate. Memory grows ahead of the work, and a test fails if a warmed path still asks for it.
- **SIMD for dense math** — wide number work uses SIMD. A loop stays scalar only when SIMD cannot fit that shape, the reason is recorded, and a new hot loop proves the scalar and SIMD results match.
- **Fully simulated** — what exists keeps advancing, in every world. Distance makes far-off work cheaper. It does not stop it.
- **Fixed step** — the simulation runs at 60Hz, apart from the frame rate.
- **Deterministic** — the same starting world and the same input give the same result on one core or many.
- **Local cost** — a chunk of a floor owns its terrain, navigation, and save data. A dig costs the chunks it touches, and memory follows what exists.
- **Separate layers** — app coordination, rendering, assets, and simulation stay apart. The game describes what to draw and never talks to the GPU.

The full model is in [architecture](docs/architecture.md).

## Features

- **Ground you can change** — procedural floors you can dig, ramp, and cross. A new tunnel is part of the map immediately.
- **People who find a way** — they cross floors and long distances, and they take a tunnel or ramp as soon as it exists.
- **Senses, memory, and mood** — they see, hear, remember, and react, with simple emotions and personalities you can edit as data. Combat and longer-term goals are still ahead.
- **Breaking things, with building still ahead** — digging, ramps, and objects you can destroy. Cave-ins, explosions, and construction are still ahead.
- **A steady pace** — the world advances sixty times a second, so the frame rate does not decide what happens.
- **The same result on one core or many** — the same actions produce the same world however the work is split.
- **Work stays local** — digging costs the ground you touched, not the whole map.
- **Art and audio you can swap** — pictures and sounds live in packed atlases, so new content does not take new code.
- **Keyboard and gamepad** — menus, pause, dig, move, and interact. Unplugging the pad, or leaving play, lets go of whatever you were holding.
- **A small shell you can run** — main menu, settings, pause, and loading, plus audio controls.
- **2D drawing** — sprites, layered maps, a camera, and text.

## Where it is headed

- Far away, people think less often instead of stopping, and the world around them keeps moving.
- Several worlds at once, opened and closed in play, each with its own people and ground.
- Menus, buttons, and a HUD that share one theme.

Setup, input, rendering, assets, and simulation are listed under Documentation.

## Requirements

- Zig 0.17.0 or a compatible 0.17.x build
- SDL3, SDL3_ttf, and SDL3_mixer
- Shader toolchain: `glslc`; `spirv-cross` on macOS; `spirv-cross` and `dxc`
  on Windows
- Python 3 for the lint steps in `zig build verify` (Pillow only for atlas
  packing and art tools)

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
zig build package   # install selected-mode binaries and runtime assets
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
- [Rules](.grok/rules/) (coding standards, one file per topic)
- [Roadmap](docs/framework-implementation-slices.md) (implementation slices)
- [Changelogs](docs/changelogs/) and [module reviews](docs/reviews/)

## License

MIT — see [LICENSE](LICENSE).
