# Zig SDL3 Game Engine Framework Guide

## Project Intent

Use this guidance for lean Zig SDL3/SDL_GPU 2D game projects. Treat the codebase as a normal game project. Keep the base Linux-friendly, SDL_GPU-first, and dependency-conscious. Prefer SDL3 plus Zig standard library facilities unless the user explicitly chooses a dependency.

## Ownership Boundaries

- `src/main.zig` owns the executable entry point and high-level fixed-step timing loop.
- `src/app/` owns SDL3 app coordination, input, timing, frame pacing, pause policy, state stack flow, audio service, and thread system.
- `src/render/` owns SDL_GPU rendering, camera transforms, renderer resources, text, FPS counter, and debug overlay rendering.
- `src/game/` owns game/application states, `DataSystem`, gameplay-specific behavior, and ECS-style gameplay systems/processors.
- `src/platform/` owns SDL/platform integration helpers and GPU smoke-test implementation.
- `src/assets/` owns runtime asset path resolution, installed asset lookup, the typed startup manifest, and `RuntimeAssets` catalog.
- `src/core/` owns small shared helpers such as math primitives.
- `src/root.zig` should stay limited to math aliases and compile coverage; feature code should live under the matching `src/` area.

Keep `src/main.zig` timing-centric. Let app/state code own state lifetimes and transition application. Game states should emit transient draw records through `RenderQueue` by default. Use `Renderer.submitOrdered*` only for renderer-owned or tightly controlled paths that already submit in nondecreasing `RenderOrder`; game states should never call SDL_GPU directly.

## Slice Completion

Roadmap slices are full features. Runtime behavior, diagnostics, docs, tests, and acceptance checks must all be integrated before a slice is complete. If a needed dependency does not exist yet, label the result as foundation or preparation and leave the feature checklist incomplete.

Use scoped `std.log` diagnostics as part of feature work. Debug logs may include detailed low-frequency lifecycle, configuration, fallback, and failure context. Avoid routine per-frame, per-event, or per-draw formatting unless the diagnostic value is clear and the impact is minimal. Keep `warn` for recovered degraded behavior, `err` for real failure context, and pure helper/validation functions log-free unless they are runtime wrappers.

## Build And Validation Commands

- `zig build`: build and install a runnable app, runtime assets, and platform shaders to `zig-out/bin`.
- `zig build run`: build, install runtime assets/shaders, and run the app.
- `zig build dev`: shader build, asset install, and run loop for normal development.
- `zig build test`: run Zig unit tests.
- `zig build check`: compile the game, benchmark, and GPU smoke executables.
- `zig build verify`: run check, tests, shader compilation, and atlas lint.
- `zig build shaders`: compile platform GPU shaders.
- `zig build gpu-smoke`: open a small display-gated renderer pipeline smoke window, load installed shaders/assets, draw, and submit one frame.
- `zig build package`: install selected-mode binaries and runtime assets.
- `zig build fmt`: format `build.zig`, `build.zig.zon`, and `src/`.

Default optimize mode is `Debug`. Use explicit release modes only for release candidates or shipping builds.

## Rendering And Timing Rules

The app uses SDL_GPU directly and does not call Vulkan APIs itself. Game code should draw through `RenderQueue` unless it is a tightly controlled already ordered path. `RenderQueue` is the intentional ordering phase for world/effect/UI/debug records; `SpriteBatch` is a strict ordered-stream consumer, not a compatibility sorter. Shader sources live in `assets/shaders/*.glsl` and build into installed runtime shader files.

Keep CPU render prep outside the acquired swapchain window where practical. Snapshot, draw-record ordering, and worker vertex expansion should happen before `SDL_WaitAndAcquireGPUSwapchainTexture`; the acquired section should stay focused on upload, render-pass encoding, and submit.

Preserve fixed 60Hz simulation through the time loop. Visible rendering is paced by SDL_GPU swapchain acquisition and may follow higher refresh displays. Hidden, minimized, or no-swapchain frames may skip rendering and use fallback delay pacing so gameplay does not advance while the player cannot see it.

Do not convert visible rendering into a blanket 60 FPS cap. If a pacing change is needed, base it on window/swapchain state and the existing frame-pacer policy.

## Input And State Flow

Map raw input to named actions. Keep held gameplay input separate from one-frame commands. Keep debug state in debug UI. Let stack policies decide whether lower states receive update, input, or render passes.

Apply state transitions after dispatch. State stack code should own state lifetimes. Modal overlays should be able to block gameplay input underneath; pass-through overlays should keep lower gameplay active where policy allows.

## Asset And Shader Rules

Runtime assets live under `assets/` and are installed to `zig-out/bin/assets` unless `-Dasset-root` changes the root. Keep asset paths relative and traversal-safe. PNG texture loading uses core SDL3 support; do not add SDL3_image unless the user explicitly asks. Runtime gameplay and render prep should use stable manifest IDs through `RuntimeAssets`, not per-frame path lookup or live renderer/audio handles in `DataSystem`. Convert stable asset IDs to renderer texture IDs at the render-prep/queue boundary, not inside `DataSystem`.

Shader tools are required for runnable builds. Linux uses SPIR-V output; macOS uses SPIR-V converted to MSL. If shader compilation fails, separate shader tool availability from Zig compile errors.

## Testing Guidance

Use Zig `test` blocks and `std.testing`. Put reusable module tests beside the code they cover. Name tests by behavior, such as `test "player movement clamps to window bounds"`.

Prefer tests that validate contracts directly: input routing behavior, state policy flow, resource ID validation, viewport math, descriptor validation, or timing decisions. Do not require a window for ordinary unit tests.

Use an aggregate test root when nested imports would otherwise cross module paths. Keep GPU smoke checks separate from non-interactive unit behavior because they require a usable display and GPU backend.

## ECS And Data Processing

Treat `DataSystem` as the persistent gameplay data owner and ECS storage
foundation. It owns entity IDs, component masks, and dense typed SoA component
stores. Do not make app, render, SDL/GPU, input-frame, thread-system, or
transient event services persistent fields of `DataSystem`.

Gameplay systems are processors over `DataSystem`, not owners of persistent
gameplay data. Movement, AI, collision, pathfinding, and render preparation
should borrow `DataSystem` slices and any required runtime services, run in a
deterministic order, and complete before later systems consume their output.
When threaded processors produce events, intents, contacts, or deferred
structural commands, use typed range-owned output buffers. Prefer count per
range, prefix offsets, contiguous writes, deterministic range-index merge, and
batch commit boundaries over global per-command atomics, broad event buses, or
callback chains.

AI/perception processors should keep scalable setup work bounded and explicit:
use an appropriate spatial/perception structure for the workload, then emit
deterministic movement intents or rule outputs as separate staged work. Stages
that can dominate timing, such as separation/perception and intent emission,
should have independent tuning/stats so each can stay inline or thread
independently. Future pathfinding or rule processors need the same explicit
staged ownership, stage-specific tuning, and deterministic merge points.

Hot processors should iterate dense SoA columns directly. Component masks are
for membership/query decisions; they should not turn hot loops into dynamic
component joins, string lookup, or hash-map dispatch. Threaded/SIMD processors
must keep structural entity changes, state transitions, SDL/GPU calls, asset
loading, save/load streaming, and renderer resource ownership behind an explicit
deferred or main-thread boundary. Use serial fallbacks for tests, unsupported
thread targets, explicit fallback behavior, and deterministic comparisons; do
not gate production worker participation with static item-count floors.

Do not let those main-thread boundaries become a dumping ground for scalable
work in any subsystem. If app flow, event reaction, intent application, tier
policy, pathfinding, AI, collision, render prep, asset handling, platform glue,
or tooling can grow with workload size, give it an explicit owner and write
deterministic owned outputs over immutable inputs. Inline main-thread work
should be deliberately light or tied to a concrete ownership boundary.

Production contracts should not carry test-only scaffolding. Do not add testing
stages, marker payloads, fake enum variants, fixture fields, service hooks, or
test-only paths to app, game, render, asset, platform, tooling, events, intents,
structural commands, IDs, components, or service APIs just to make tests
convenient. Use private test helper types, local fixtures, test-only mocks, or
real runtime payloads.

For threaded/SIMD ECS work, treat cache-line behavior as part of the contract.
Document hot SoA column alignment before relying on wider or target-specific
loads, choose worker ranges so workers do not write the same cache line, and use
64-byte padding only for concurrently written thread-shared records where false
sharing is a real risk. Do not pad cold entity slot metadata by default.
