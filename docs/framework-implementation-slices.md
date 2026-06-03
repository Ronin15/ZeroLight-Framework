# Framework Implementation Slices

This roadmap keeps the repo focused as a 2D game project. Each slice should
land as a small, verified step that improves a real extension point without
adding broad abstraction.

## Ground Rules

- Preserve runnable defaults: `zig build`, `zig build run`, and installed assets
  should keep working after every slice.
- A slice means a full feature: runtime behavior, docs, tests, and acceptance
  checks must be integrated before it is complete.
- Keep hot paths simple: prefer enums, bitsets, arrays, and generational slot IDs
  over dynamic dispatch, string lookup, or hash maps during input/update/draw.
- If a dependent system does not exist yet, label the work as foundation or
  preparation and leave the feature checklist incomplete.
- Avoid half-wired states; either finish the feature end to end or keep the
  roadmap explicit about what remains.
- Keep `src/root.zig` minimal; feature modules should live in their matching
  `src/` area and import each other directly when needed.
- Run `zig build verify` before considering a slice complete.

## Slice 0: Runtime Diagnostics Policy

Goal: use Zig's compile-time `std.log` filtering so debug builds can show useful
diagnostics while release builds stay quiet except for warnings and errors.

Current foundation:

- [x] Add `-Dlog-level=auto|err|warn|info|debug`.
- [x] Default `auto` to `debug` for Debug and `warn` for release modes.
- [x] Apply the policy through root `std_options` for the app, tests, and GPU smoke executable.
- [x] Add project log scopes for app, assets, core, game, render, platform, and debug overlay.
- [x] Use scoped logs for current render, platform, and debug-overlay diagnostics.
- [x] Keep routine startup facts such as the SDL_GPU driver at debug level.
- [x] Keep warnings for recovered degraded behavior and errors for real failure context.
- [x] Keep shader/config helper functions log-free where tests use pure logic.

Checklist:

- [ ] Audit app, assets, game, core, render, and platform code for actionable diagnostics.
- [ ] Add scoped logs only where they report startup facts, recovered degraded behavior, or real failure context.
- [ ] Keep normal frame/update/render hot paths free of per-frame string formatting.
- [ ] Keep pure helpers and validation helpers log-free unless they are runtime wrappers.
- [ ] Keep release builds quiet by default while preserving warnings and errors.

Acceptance checks:

- [x] `zig build test` compiles the test root with the shared log policy.
- [x] `zig build check` compiles the app and GPU smoke executable.
- [x] `zig build check --release=safe` verifies the release log-level default.
- [ ] Project-wide diagnostic audit confirms no meaningful subsystem still uses default-scope logging or noisy warning/error severity.

## Slice 1: Input Routing

Goal: let modal UI, gameplay, and debug commands control which actions receive
input without broad special cases in `Engine`.

Current foundation:

- `InputState` tracks held gameplay actions.
- `FrameCommands` tracks one-frame commands.
- `input_router.zig` defines context-oriented routing contracts.
- Current pause behavior intentionally resets gameplay movement; this slice should
  decide how key-down/key-up events received while gameplay input is blocked
  reconcile with held movement on resume.

Checklist:

- [ ] Add a routing policy field to the active state policy or derive it from the
      active state stack entry.
- [ ] Route SDL key events through `InputRoutingPolicy` before mutating
      `InputState` or `FrameCommands`.
- [ ] Keep debug commands available unless explicitly disabled.
- [ ] Ensure modal overlays can block gameplay held input.
- [ ] Release held gameplay movement when a modal policy starts blocking gameplay.
- [ ] Add tests for gameplay-only, modal UI, pass-through overlay, and debug
      command behavior.
- [ ] Update README input guidance after behavior is wired.

Acceptance checks:

- [ ] A gameplay state still receives WASD movement by default.
- [ ] A modal state can prevent gameplay movement from being latched underneath.
- [ ] F2 debug overlay toggle still works while gameplay is active.
- [ ] `zig build test` covers routing behavior without opening a window.

## Slice 2: Logical Resolution And Viewport Policy

Goal: make logical game coordinates deliberate before real UI, resizing, or
high-DPI behavior depends on them.

Current foundation:

- `AppConfig` has `logical_width`, `logical_height`, and `resizable`.
- `resolution.zig` defines logical size, scale mode, and viewport math.
- Renderer currently uses swapchain size directly.
- Current drawing uses logical 1280x720-style coordinates but normalizes them
  against the acquired swapchain size, so high-DPI or future resize behavior
  needs an explicit viewport policy before real UI depends on it.

Checklist:

- [ ] Add a `ResolutionPolicy` to `AppConfig`.
- [ ] Compute the current `Viewport` when swapchain/window size changes.
- [ ] Apply the viewport through SDL_GPU render pass or draw transform as
      appropriate for SDL_GPU.
- [ ] Keep world/game drawing in logical coordinates.
- [ ] Decide whether debug overlay is logical-space or screen-space and document it.
- [ ] Add tests for fit, integer-fit, stretch, small windows, and invalid sizes.
- [ ] Update README with resize/logical-resolution behavior.

Acceptance checks:

- [ ] Existing demo renders correctly at the default 1280x720 logical size.
- [ ] Resizable windows preserve the configured scale policy.
- [ ] Letterbox offsets are centered and stable.
- [ ] Hidden/minimized/no-swapchain frame policy still behaves as before.

## Slice 3: Render Resource Layer

Goal: replace long-lived raw texture indices with a resource layer that can grow
into caching, reload, and ownership tracking.

Current foundation:

- Renderer owns GPU textures in an array.
- `TextureHandle` is currently a raw index.
- `resources.zig` defines generational `TextureId` and resource descriptors.

Checklist:

- [ ] Add a slot table for textures with generation, alive state, and descriptor.
- [ ] Add `TextureId` creation, validation, lookup, and destruction helpers.
- [ ] Keep draw submission lookup array-backed and allocation-free.
- [ ] Preserve the white texture as an internal renderer resource.
- [ ] Keep `createTextureFromPng`, `createTextureFromPixels`, and
      `replaceTextureFromPixels` behavior compatible during migration.
- [ ] Add tests for stale IDs, destroyed IDs, invalid generation, and descriptor
      validation.
- [ ] Add a focused compatibility note if `TextureHandle` is renamed or aliased.

Acceptance checks:

- [ ] Destroyed or stale texture IDs are skipped or rejected deterministically.
- [ ] Existing demo and debug text still render.
- [ ] Texture upload validation still rejects bad dimensions, pitch, and buffer
      lengths before GPU work.
- [ ] No hash map lookup is introduced into per-sprite draw submission.

## Slice 4: Asset Cache

Goal: make runtime asset ownership explicit enough for real projects without
building a broad content pipeline too early.

Current foundation:

- `AssetStore` resolves safe relative paths from repo root or executable-relative
  install location.
- Renderer can load PNGs directly through `createTextureFromPng`.

Checklist:

- [ ] Add an asset/resource cache module that maps stable asset paths to
      renderer resource IDs.
- [ ] Keep path validation in `AssetStore`; do not duplicate traversal checks.
- [ ] Decide cache ownership: app-level service owned by `Engine` is the default.
- [ ] Add explicit load/unload or retain/release policy before adding hot reload.
- [ ] Keep synchronous load first; defer async/staged loading until needed.
- [ ] Add tests for duplicate path reuse, unload behavior, and invalid paths.

Acceptance checks:

- [ ] Loading the same PNG twice can reuse the existing texture.
- [ ] Asset paths remain relative and traversal-safe.
- [ ] Installed-binary asset lookup still works with `-Dasset-root`.

## Slice 5: Text And Font Service

Goal: move from FPS-only SDL_ttf usage to asset-backed text rendering suitable
for menus, buttons, and UI.

Current foundation:

- SDL3_ttf is a core dependency.
- `FpsCounter` proves rendered text can become a texture.
- `text.zig` defines asset-backed font and text layout contracts.

Checklist:

- [ ] Add a centralized text/font service that owns `TTF_Init` and `TTF_Quit`.
- [ ] Load fonts from `assets/fonts/...` through `AssetStore`.
- [ ] Add `FontId` allocation and validation using generational IDs.
- [ ] Render text into cached renderer textures.
- [ ] Define cache invalidation for text string, font, color, wrap width, and
      layout options.
- [ ] Move `FpsCounter` to consume the text service.
- [ ] Add at least one bundled font or document the asset requirement clearly.
- [ ] Add tests for descriptor validation and cache keys where possible.

Acceptance checks:

- [ ] F2 overlay still renders yellow FPS text.
- [ ] No system font path probing remains in normal text flow.
- [ ] Text texture lifetime is centralized and cleaned up by the owning service.

## Slice 6: Renderer Composition

Goal: split renderer responsibilities so sprites, UI, shapes, tilemaps, and
future effects do not all require editing one monolithic renderer path.

Current foundation:

- Renderer owns SDL_GPU device, window claim, swapchain, pipeline, buffers, and
  sprite batching.
- Build now has a shader-program table for the existing sprite shader pair.

Checklist:

- [ ] Keep `Renderer` as the device/frame coordinator.
- [ ] Move sprite batching internals behind a `SpriteBatch` or equivalent module.
- [ ] Introduce static material/pipeline records for the current sprite pipeline.
- [ ] Keep draw command sorting stable by layer and submission order.
- [ ] Preserve `drawSprite` and `drawRect` as the game-facing API during the
      first split.
- [ ] Add tests for batch grouping, invalid texture skipping, and ordering.
- [ ] Re-run `gpu-smoke` when display access is available.

Acceptance checks:

- [ ] Existing demo output is unchanged.
- [ ] New batcher owns sprite-specific vertex construction.
- [ ] Renderer frame lifecycle still handles `.submitted` and
      `.skipped_no_swapchain` correctly.
- [ ] Adding a second batcher later would not require rewriting device setup.

## Slice 7: Preallocated Thread System And Parallel Render Prep

Goal: add a deterministic, pre-spawned worker system that lets each engine
system use all active workers for CPU work, then finish before the next system
or render phase starts.

Current foundation:

- `Engine` owns app coordination and state-stack update/render flow.
- `TimeLoop` already enforces fixed-step gameplay updates.
- Renderer command submission is currently serial and owns SDL_GPU command
  buffers, swapchain acquisition, vertex upload, and submit.
- Zig 0.16 provides `std.Thread.spawn`, atomics, and `std.Io` blocking
  primitives; this checkout does not rely on a std thread-pool abstraction.

Architecture notes:

- This is a synchronous frame-batch system, not a general async job scheduler.
  It is for systems that need CPU work completed before the frame can continue.
- There is one active batch at a time. A batch exposes an atomic range queue:
  participants claim the next `ParallelRange` with an atomic cursor.
- Background workers park when idle. Do not add spin-wait configuration unless
  measurement proves condition-variable wake latency is the bottleneck.
- `max_background_workers` counts only pre-spawned background threads. The
  main/render thread may also process ranges, so the default `cpu_count - 1`
  background workers uses all normal CPU participants without oversubscription.
- Long-lived async work such as asset streaming or file IO should use a
  separate service later instead of sharing this frame-bounded barrier path.

Thread-system design:

- [x] Add `src/app/thread_system.zig` with `ThreadSystem`,
      `ThreadSystemConfig`, `WorkerId`, `ParallelRange`, `BatchStats`, and a
      deterministic `parallelFor` API.
- [x] Own `ThreadSystem` from `Engine`; initialize it after SDL/app config is
      known and deinitialize it before allocator teardown.
- [x] Pre-spawn up to `max_background_workers` background threads at init with
      `std.Thread.spawn`.
      Never create or destroy OS threads during gameplay frames.
- [x] Default background worker count to one fewer than
      `std.Thread.getCpuCount()` when possible, reserving the main/render thread
      as an additional batch participant; allow config override for background
      worker count, stack size, minimum parallel item count, and grain size.
- [x] Use preallocated worker records, one synchronous batch descriptor, and an
      atomic range cursor. No frame-batch submission may allocate after
      initialization.
- [x] Use atomics for hot range claiming and range stats; use `std.Io.Mutex` and
      `std.Io.Condition` only for batch publication, worker parking, completion,
      and shutdown paths where blocking is expected.
- [x] Let the main thread participate in submitted batches while waiting so it
      does useful work instead of only acting as a coordinator.
- [ ] Dynamically scale active workers only at batch boundaries based on prior
      batch cost, item count, main-thread wait time, and worker utilization.
      Small batches run inline on the main thread.
- [x] Stop accepting work during shutdown, wake parked workers, join every
      pre-spawned thread, and assert that no frame batch is still outstanding.

Engine/system integration:

- [x] Add an update/render-prep context that exposes `thread_system` to states
      or future systems without moving timing policy out of `main.zig`.
- [x] Keep systems ordered: each system may use the whole worker set, but all
      of its jobs must complete before the next system starts.
- [x] Allow worker jobs to read immutable snapshots and write only disjoint
      output ranges.
- [ ] Add explicit per-worker scratch storage keyed by `WorkerId` before systems
      need temporary output buffers.
- [x] Keep `StateTransitions`, state-stack mutation, SDL events, SDL window
      calls, and renderer ownership on the main thread.
- [x] Record batch stats in a lightweight struct that debug overlay or logs can
      consume later without adding hot-path string formatting.

Parallel render-prep design:

- [x] Keep SDL_GPU command-buffer acquisition, swapchain acquisition, GPU
      upload, render-pass encoding, and submit on the main/render thread for
      the first implementation.
- [ ] Parallelize CPU render prep only: visibility/culling, layer bucketing,
      stable sort by layer and submission sequence, sprite-to-vertex expansion,
      draw-group construction, and per-worker temporary vertex/group buffers.
- [ ] Snapshot texture/resource metadata needed by workers before dispatch so
      worker jobs never observe renderer arrays while they are being mutated.
- [ ] Merge worker outputs on the main thread in deterministic layer and
      sequence order, then upload the final vertex buffer and submit one GPU
      command buffer.
- [x] Preserve the current serial path and choose it for low command counts,
      low layer counts, unsupported thread targets, or debug comparisons.
- [ ] Defer threaded SDL_GPU command buffers until profiling proves main-thread
      command encoding is the bottleneck. If added later, command buffers must
      be acquired, used, and submitted on the same worker thread; swapchain
      acquisition must remain on the window thread.

Acceptance checks:

- [x] `parallelFor` covers every item exactly once and never writes outside the
      requested range.
- [x] Batch execution performs no allocations after init/reserve; enforce this
      with a failing allocator in tests.
- [x] System barriers are deterministic: later systems always see completed
      output from earlier systems.
- [x] Shutdown wakes and joins parked workers without leaking or deadlocking.
- [x] Worker idle policy parks on a condition variable; no spin loop or unused
      spin configuration remains in the config.
- [ ] Serial and parallel render prep produce identical vertex order, draw
      group order, layer ordering, and invalid-texture skipping for the same
      command input.
- [x] Existing visible rendering remains swapchain/vsync paced, and
      hidden/minimized/no-swapchain fallback pacing remains unchanged.
- [x] `zig build test`, `zig build check`, and `zig build verify` pass before
      the slice is considered complete.

Core pass landed: this slice now has a pre-spawned app-owned `ThreadSystem`,
explicit update/render contexts, synchronous `parallelFor`, and a serial renderer
prep hook. Remaining unchecked work is the deeper adaptive scheduling policy and
actual parallel CPU render-prep pipeline.

## Slice 8: Shader And Platform Expansion

Goal: keep platform support reliable as shader count and target platforms grow.

Current foundation:

- SDL chooses the GPU backend from supplied shader formats.
- macOS builds MSL, Linux builds SPIR-V.
- Runtime selects shader files from SDL-reported supported formats.

Checklist:

- [ ] Extend the shader-program table as new render pipelines are added.
- [ ] Keep generated runtime shader files under `assets/shaders` in the install
      tree.
- [ ] Add explicit Windows target support only when Windows is an active target.
- [ ] Validate the right shader format list for each target OS.
- [ ] Keep runtime backend selection SDL-driven; do not hard-code GPU driver names.
- [ ] Add shader output checks for each supported target path.

Acceptance checks:

- [ ] `zig build shaders` emits the same sprite shader outputs as before.
- [ ] `zig build verify` exercises shader compilation.
- [ ] `zig build gpu-smoke` confirms runtime submission on display-capable hosts.

## Slice 9: Platform-Neutral SIMD Helper Layer

Goal: provide a small SIMD helper layer with clear project names so movement,
particles, and other hot data processors can use vectors without exposing
platform-specific intrinsic names throughout gameplay code.

Current foundation:

- `src/core/math.zig` contains small math primitives.
- `ThreadSystem.parallelFor` already divides work into contiguous ranges.
- Future movement and particle processors are expected to operate on SoA slices.

Checklist:

- [ ] Add `src/core/simd.zig` with friendly vector aliases such as `Float4`,
      `Int4`, and `Mask4`.
- [ ] Prefer portable Zig vector types first, hiding target-specific intrinsic
      details behind the helper API.
- [ ] Add load, store, splat, add, subtract, multiply, divide, min, max,
      compare, select, and clamp helpers needed by movement and particle loops.
- [ ] Add scalar-tail helpers for item counts that are not a multiple of the
      vector lane count.
- [ ] Keep the helper free of game-specific entity, particle, SDL, renderer, or
      thread-system dependencies.
- [ ] Document when scalar code should be preferred for tiny batches or clarity.

Acceptance checks:

- [ ] SIMD helper tests prove lane order is stable.
- [ ] SIMD and scalar implementations produce identical results for representative
      float and integer operations.
- [ ] Tail handling covers empty, partial, exact-lane, and multi-lane inputs.
- [ ] `zig build test` passes on targets where the helper is expected to compile.

## Slice 10: DataSystem And SoA Composition Foundation

Goal: introduce `DataSystem` as the state-owned persistent gameplay data
container and save/load streaming boundary, with dense SoA storage designed for
fast systems, threading, and SIMD.

Current foundation:

- `StateStack` owns active state lifetimes.
- `UpdateContext` exposes `ThreadSystem` to states.
- Game-specific runtime data currently lives inside demo state/player structs.

Architecture notes:

- `DataSystem` is intentionally the unique name for the persistent data
  container.
- `DataSystem` persists for the lifetime of the owning gameplay state, not as a
  global app singleton.
- Systems are processors that borrow or view `DataSystem`; they do not own
  persistent gameplay data.
- Save/load should stream `DataSystem`, not `Engine`, `StateStack`, renderer,
  thread system, input, or transient frame state.
- Composition comes from meaningful data membership in typed stores, not from a
  free-form component soup where arbitrary behavior combinations are implied.

Checklist:

- [ ] Add a game data module with `DataSystem` and an entity ID/generation
      registry.
- [ ] Add dense SoA stores for initial persistent gameplay data such as transform
      and movement.
- [ ] Use stable handles or dense indices so stores can remain compact while
      rejecting stale IDs.
- [ ] Keep SDL handles, GPU handles, input frame state, renderer state,
      `ThreadSystem`, transient events, and scratch buffers outside `DataSystem`.
- [ ] Store persistent asset references as stable IDs or relative paths, not
      live renderer texture handles.
- [ ] Add explicit init/deinit and clear/reset behavior for state lifecycle and
      save/load preparation.

Acceptance checks:

- [ ] Entity IDs reject stale generations after removal and reuse.
- [ ] Dense SoA stores keep arrays length-aligned and compact after add/remove.
- [ ] `DataSystem` can be initialized and deinitialized without leaks.
- [ ] Tests cover which data belongs inside `DataSystem` versus transient runtime
      services that must stay outside it.

## Slice 11: SIMD-Aware Data Processor Systems

Goal: add high-performance systems that process `DataSystem` slices with the
thread system and SIMD helpers while preserving deterministic fixed-step update
behavior.

Current foundation:

- `ThreadSystem.parallelFor` runs synchronous range batches and returns only
  after all workers finish.
- `UpdateContext` passes `thread_system` into states.
- `DataSystem` will provide persistent SoA slices for systems to process.
- `src/core/simd.zig` will provide portable vector helpers.

Checklist:

- [ ] Define systems as data processors that accept `DataSystem`, `ThreadSystem`,
      and fixed-step delta time rather than owning persistent data.
- [ ] Add movement and particle processors that split dense SoA slices through
      `parallelFor`.
- [ ] Use SIMD inside each worker range and scalar-tail code for remainder
      elements.
- [ ] Ensure worker jobs write only to assigned disjoint ranges.
- [ ] Keep state transitions, entity creation/removal, SDL calls, GPU calls,
      asset loading, and save/load streaming on the main thread.
- [ ] Merge any per-worker output, event counts, or deferred structural changes
      on the main thread after the batch completes.
- [ ] Keep normal 60Hz update paths allocation-free after initialization.

Acceptance checks:

- [ ] Scalar and SIMD movement results match for representative data sets.
- [ ] Serial and threaded processor results match for the same initial
      `DataSystem`.
- [ ] Worker jobs do not write outside their assigned `ParallelRange`.
- [ ] Update processors perform no allocations during steady-state simulation.
- [ ] Fixed-step update order remains deterministic: later systems always see
      completed output from earlier systems.

## Suggested Order

0. Runtime diagnostics policy.
1. Input routing.
2. Logical resolution and viewport policy.
3. Render resource layer.
4. Asset cache.
5. Text and font service.
6. Renderer composition.
7. Preallocated thread system and parallel render prep.
8. Shader and platform expansion.
9. Platform-neutral SIMD helper layer.
10. DataSystem and SoA composition foundation.
11. SIMD-aware data processor systems.

This order keeps gameplay/menu correctness ahead of larger renderer work, then
builds resource ownership before text/UI, renderer composition, and parallel
render preparation depend on it. SIMD helpers land before the DataSystem and
processor slices so the storage and system APIs can be designed around the hot
loop shape from the start.
