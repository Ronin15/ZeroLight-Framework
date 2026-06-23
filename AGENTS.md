# Repository Guidelines

## Project Intent

This is a Zig 0.16 + SDL3/SDL_GPU 2D game project. Keep the base lean,
dependency-light, and SDL_GPU-first. The build entry point is `build.zig`, with
project metadata in `build.zig.zon`.

Use the existing docs as source of truth for deeper details:

- `docs/architecture.md` for frame flow, source layout, and engine boundaries.
- `docs/state-stack-and-input.md` for state contracts, transition policies, and input mapping.
- `docs/rendering-assets-shaders.md` for SDL_GPU rendering, assets, PNG loading, shaders, and debug overlay.
- `docs/atlas-asset-workflow.md` for filename-driven atlas packing, JSON sidecars, order manifests, and art swaps.
- `docs/simulation-tiers-and-pipeline.md` for `SimulationPipeline`, scoped tiers, world/chunk simulation policy, and Slice 22 design.
- `docs/development-workflow.md` for build options, release modes, testing, and GPU smoke usage.

## Ownership Boundaries

- `src/main.zig` owns the executable entry point and high-level fixed-step timing loop.
- `src/app/` owns SDL app coordination, input, time loop, frame pacing, pause policy, state stack flow, audio service, and the thread system.
- `src/render/` owns SDL_GPU rendering, camera transforms, renderer resources, text, FPS/debug overlay, and frame submission.
- `src/game/` owns game/application states, gameplay behavior, `DataSystem`, and ECS-style gameplay systems/processors.
- `src/platform/` owns SDL C imports, small platform wrappers, and GPU smoke-test implementation.
- `src/assets/` owns runtime asset path resolution, safe installed asset
  loading, the typed startup manifest, and the `RuntimeAssets` catalog.
- `src/core/` owns small shared helpers such as math primitives.
- `src/root.zig` is the minimal test/root file for math aliases and compile coverage.
- `assets/` contains runtime assets, audio files, and shader sources. Runtime assets install under `zig-out/bin/assets` by default.

Add new code under the matching owner directory. Keep executable-only code near
`main.zig`, app flow under `src/app/`, rendering and GPU resource code under
`src/render/`, and game-specific behavior under `src/game/`.

## Durable Architecture Rules

- Keep `src/main.zig` timing-centric; move coordination details into `src/app/`.
- `StateStack` owns state lifetimes, state destruction, policies, and transition application.
- Queue state transitions through `StateTransitions` from state dispatch, then apply them after dispatch completes.
- Game states emit transient draw records through `RenderQueue` by default. Use
  `Renderer.submitOrdered*` only for renderer-owned or tightly controlled paths
  that already submit in nondecreasing `RenderOrder`; keep SDL_GPU device,
  swapchain, shader, texture, and command submission details in render/platform
  layers.
- Game states request sound through `AudioCommandBuffer`; keep SDL_mixer
  device, mixer, track, bus, and loaded-audio ownership in the app audio service.
- Map raw input to named actions. Keep held gameplay input in `InputState` separate from one-frame app commands in `FrameCommands`.
- Let stack policies decide whether lower states receive update, input, or render passes.
- When multiple gameplay states or simulation instances need the same fixed-step
  order, use a state-owned `SimulationPipeline` helper. `StateStack` remains the
  dispatch and lifetime owner; it should not know domain controller internals.
- Treat `DataSystem` as the persistent gameplay data owner and ECS storage foundation:
  entity IDs, component masks, and dense typed SoA component stores live there.
- Let a state-owned pipeline own light domain controllers when a feature needs
  orchestration for phase order, budgets, queues, cooldowns, conflict policy,
  or processor handoff. Keep persistent gameplay/domain facts in `DataSystem`
  or state-owned domain storage, per-step outputs in `SimulationFrame`, and
  hot/reusable loops in systems/processors over typed SoA slices.
- Treat future simulation/domain events as typed transient
  `SimulationFrame`/pipeline signals for cross-system communication about
  important system changes. Do not add a global pub/sub bus, string-topic
  dispatcher, callback chain, or event payloads carrying pointers,
  app/render/audio handles, asset paths, allocators, or service references.
- Do not use the main thread as a generic dumping ground for scalable work in
  any subsystem. Main-thread work must name the explicit boundary it is
  preserving, such as SDL/GPU/audio ownership, state transitions, structural
  commits, asset loading, save/load streaming, renderer resource ownership, or
  measured light orchestration. Expensive app, gameplay, render-prep, event,
  asset, or tool work should keep a clear owner, split over immutable inputs
  when appropriate, and write deterministic owned outputs.
- Treat ECS systems/processors such as movement, AI, collision, pathfinding, and
  render preparation as mostly stateless processors over `DataSystem` slices;
  they borrow data and services, but do not own persistent gameplay state.
- Keep hot ECS component data in dense SoA columns. Component masks are for
  membership/query decisions, not a replacement for direct slice iteration in
  hot processors.
- Keep state transitions, entity structural changes, SDL/GPU/audio calls, asset
  loading, save/load streaming, renderer resource ownership, and mixer resource
  ownership out of threaded SIMD processors unless an explicit
  deferred/main-thread boundary is designed.
- Keep debug UI state in the debug overlay path, not in gameplay state.
- Keep runtime asset paths relative and traversal-safe.
- Keep persistent gameplay/render data on stable asset IDs such as
  `SpriteAssetId` and `AudioAssetId`; do not store string paths, `TextureId`,
  `TextureLease`, prepared sprite records, SDL_mixer handles, or loaded audio
  handles in `DataSystem`.
- Use core SDL3 PNG loading for textures. Do not add `SDL3_image` unless that dependency is explicitly chosen.
- SDL3, SDL3_ttf, and SDL3_mixer are system dependencies on Linux and
  macOS. Windows defaults to the pinned lazy packages in `build.zig.zon`;
  use `-Dsystem-sdl=true` for global SDL installs or `-Dsdl-root=...` for
  custom extracted archives. Avoid vendoring or half-adopting external
  dependencies.
- Pair SDL resource creation with cleanup close to the creation site.
- Treat performance as a correctness constraint in hot paths: fixed-step update,
  input dispatch, render submission, asset lookup, and text/debug overlay.
- Prefer allocation-free hot paths with enums, bitsets, arrays, slices, direct
  indices, prepared resources, and stable handles.
- For threaded/SIMD ECS work, treat cache-line behavior as part of correctness:
  document hot SoA column alignment, split worker ranges so workers do not write
  the same cache line, and use 64-byte padding only for thread-shared records
  where false sharing is a real risk. Do not pad cold entity slot metadata by
  default.
- Let `ThreadSystem` production scheduling adapt from measured batch timing.
  Do not add static item-count floors for worker participation; only structural
  limits such as zero work, no available workers, one splittable range, explicit
  serial overrides, and cache-line/range-alignment constraints should force
  inline execution.
- Avoid per-frame string lookup, hash-map dispatch, dynamic dispatch, resource
  churn, formatted logging, and broad frame-rate caps unless measured and
  justified.

## Slice Implementation Rules

- Treat implementation slices as full features, not partial scaffolds.
- Do not mark a slice complete until its runtime behavior, docs, tests, and acceptance checks are integrated.
- If a dependent system does not exist yet, label the work as foundation or preparation, and leave the actual feature checklist incomplete.
- Avoid half-wired states: either finish the feature end to end or keep the roadmap honest about what remains.
- Do not add test-only enum tags, union payloads, marker fields, fake stages,
  fixture hooks, or test-only service paths to production contracts in any
  subsystem. Tests should use private test helper types, local fixtures, mocks
  kept behind test-only code, or real production payloads.

## Build, Test, And Development Commands

- `zig build` builds and installs the game executable, runtime assets, and
  platform shader files under `zig-out/bin`.
- `zig build run` builds, installs runtime assets/shaders, and runs the app.
- `zig build dev` builds shaders, installs assets, and runs the app for normal development.
- `zig build test` runs reusable module tests plus SDL-linked compile coverage.
- `zig build check` compiles the game, benchmark, and GPU smoke executables without installing.
- `zig build bench` runs non-interactive CPU gameplay and render-prep benchmarks.
- `zig build verify` runs check, tests, shader compilation, and atlas lint.
- `zig build shaders` compiles platform GPU shaders.
- `zig build gpu-smoke` runs a display-gated renderer pipeline smoke that
  installs assets/shaders, creates SDL_GPU resources, draws, and submits one
  frame.
- `zig build fmt` formats `build.zig`, `build.zig.zon`, and `src/`.
- `zig build package` installs selected-mode game binaries and runtime assets.

Default optimize mode is `Debug`. Use explicit release modes such as
`zig build --release=safe`, `zig build --release=fast`, or
`zig build -Doptimize=ReleaseFast` only for release candidates or shipping
builds.

Shader tools are required for runnable builds. Linux emits SPIR-V shader files;
macOS emits Metal shader files through `spirv-cross`. `zig build gpu-smoke`
requires a usable display, video backend, and GPU.

## Coding And Testing Standards

Follow `zig fmt`; use 4-space indentation and avoid manual alignment that the
formatter will rewrite. Use Zig-style lowerCamelCase for variables and
functions, `PascalCase` for types, and short descriptive names. Keep error sets
explicit when practical, as in `error{SdlError}`.

Prefer direct declaration imports for project types and constants when that
keeps call sites clear, such as `const Engine = @import("app/engine.zig").Engine;`
or `const ThreadSystem = @import("app/thread_system.zig").ThreadSystem;`. Use a
concise lowerCamelCase file namespace only when the call site is clearer as a
function/namespace lookup, such as `inputFile.actionForKey(...)` or
`assets.validateRelativePath(...)`. Avoid `_mod` suffixes, `const Type =
file.Type` bridge aliases, and double names such as `thread.ThreadSystem`. Do
not rewrite SDL/C symbols, generated build-option names, or `std.Build` field
names. Keep `Renderer` as the render facade for app/game code; do not import
`src/render/gpu/*` outside the render/platform boundary.

Use comments to preserve contracts and non-obvious intent, not to narrate
straight-line code. Public exported declarations that form a cross-module API
should use Zig doc comments (`///`) immediately above the declaration when the
caller needs to understand ownership, lifetime, invariants, ordering,
threading, allocation behavior, failure behavior, or performance assumptions.
Use ordinary `//` comments for private helpers, implementation phase markers,
local invariants, hot-path rationale, and test fixture context. Put
declaration-level comments above the declaration they describe; put local
implementation comments near the block they explain. Avoid comments that merely
repeat the identifier or obvious assignment, stale roadmap notes, and broad
claims that are not enforced by code or tests.

Use Zig `test` blocks and `std.testing`. Put reusable module tests beside the
code they cover, and name tests by behavior, such as
`test "player movement clamps to window bounds"`.

Prefer focused tests for contracts that do not require opening a window: input
routing, state policy flow, transition ordering, resource ID validation,
viewport math, descriptor validation, asset path validation, and timing
decisions. Keep display/GPU checks in `gpu-smoke`.

## Generated Output And Configuration

`zig-out/` and `.zig-cache/` are generated output and should not be edited by
hand. Do not commit generated binaries or local machine paths.

If adding dependencies to `build.zig.zon`, keep hashes accurate and review the
fingerprint carefully because it affects project identity.
