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

## Next Priority Tracks

- Finish Slice 7 parallel CPU render prep and Slice 8 shader/platform
  validation as engine-support tracks.
- Use Slice 12 as the gameplay-systems foundation before broad collision, AI,
  pathfinding, or emergent-rule work.
- Treat Slice 13 and Slice 14 as dependent on Slice 12's deterministic
  processor, event, and deferred-structural-change contracts.

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

- [x] Audit app, assets, game, core, render, and platform code for actionable diagnostics.
- [x] Add scoped logs only where they report startup facts, recovered degraded behavior, or real failure context.
- [x] Keep normal frame/update/render hot paths free of per-frame string formatting.
- [x] Keep pure helpers and validation helpers log-free unless they are runtime wrappers.
- [x] Keep release builds quiet by default while preserving warnings and errors.

Acceptance checks:

- [x] `zig build test` compiles the test root with the shared log policy.
- [x] `zig build check` compiles the app and GPU smoke executable.
- [x] `zig build check --release=safe` verifies the release log-level default.
- [x] Project-wide diagnostic audit confirms no meaningful subsystem still uses default-scope logging or noisy warning/error severity.

## Slice 1: Input Routing

Goal: let modal UI, gameplay, and debug commands control which actions receive
input without broad special cases in `Engine`.

Current foundation:

- [x] `InputState` tracks held gameplay actions.
- [x] `FrameCommands` tracks one-frame commands.
- [x] `input_router.zig` defines context-oriented routing contracts.
- [x] `StatePolicy` carries the active named-action routing policy.
- [x] `StatePolicy` explicitly marks modal and opaque states that block held
      gameplay input in the active event path.
- [x] Pause and modal routing intentionally release held gameplay movement; keys
      pressed while gameplay is blocked are not synthesized on resume.
- [x] Engine logs the low-frequency gameplay-routing block transition at app
      debug scope when held movement is released.

Checklist:

- [x] Add a routing policy field to the active state policy or derive it from the
      active state stack entry.
- [x] Route SDL key events through `InputRoutingPolicy` before mutating
      `InputState` or `FrameCommands`.
- [x] Keep debug commands available unless explicitly disabled.
- [x] Ensure modal overlays can block gameplay held input.
- [x] Ensure pass-through overlays do not tunnel gameplay input through modal or
      opaque blockers in the active event path.
- [x] Release held gameplay movement when a modal policy starts blocking gameplay.
- [x] Add tests for gameplay-only, modal UI, pass-through overlay, and debug
      command behavior.
- [x] Update README input guidance after behavior is wired.

Acceptance checks:

- [x] A gameplay state still receives WASD movement by default.
- [x] A modal state can prevent gameplay movement from being latched underneath.
- [x] A pass-through overlay above a modal state still leaves gameplay movement
      blocked.
- [x] F2 debug overlay toggle still works while gameplay is active.
- [x] `zig build test` covers routing behavior without opening a window.

## Slice 2: Logical Resolution And Viewport Policy

Goal: make logical game coordinates deliberate before real UI, resizing, or
high-DPI behavior depends on them.

Current foundation:

- `AppConfig` owns a `ResolutionPolicy` plus resizable and high-pixel-density
  window defaults.
- `resolution.zig` defines logical size, scale mode, viewport math,
  presentation state, and pure coordinate conversion helpers.
- Renderer computes presentation from SDL_GPU swapchain drawable size and SDL
  window size on each submitted frame.
- World and logical drawing is transformed through the logical presentation into
  drawable pixels, then clipped to the logical viewport; drawable overlays use
  raw swapchain pixels.
- Integer-fit windows request a logical-size minimum client area so user
  resizing should not normally crop below 1x scale.

Checklist:

- [x] Add a `ResolutionPolicy` to `AppConfig`.
- [x] Compute the current `Viewport` when swapchain/window size changes.
- [x] Apply the viewport through SDL_GPU render pass or draw transform as
      appropriate for SDL_GPU.
- [x] Keep world/game drawing in logical coordinates.
- [x] Decide whether debug overlay is logical-space or screen-space and document it.
- [x] Add tests for fit, integer-fit, stretch, small windows, and invalid sizes.
- [x] Update README with resize/logical-resolution behavior.
- [x] Prevent normal sub-logical integer-fit resizing with SDL window minimum size.

Acceptance checks:

- [x] Existing demo renders correctly at the default 1280x720 logical size.
- [x] Resizable windows preserve the configured scale policy.
- [x] Letterbox offsets are centered and stable.
- [x] Hidden/minimized/no-swapchain frame policy still behaves as before.
- [x] `zig build test`, `zig build check`, `zig build verify`, and
      `zig build gpu-smoke` cover unit, compile, shader, and one-frame GPU smoke
      validation. Manual `zig build dev` resize/pause smoke confirmed Retina
      1280x720 -> 2560x1440 and resized 1800x1130 -> 3600x2260 fit presentation.

## Slice 3: Render Resource Layer

Goal: replace long-lived raw texture indices with a resource layer that can grow
into caching, reload, and ownership tracking.

Current foundation:

- Renderer owns GPU textures in a generational slot table.
- Public renderer APIs use `TextureId` instead of long-lived raw texture indices.
- `resources.zig` defines generational `TextureId` and resource descriptors.

Architecture notes:

- Future atlas and tile rendering should reuse one atlas `TextureId` with
  per-sprite or per-tile source rectangles. Slice 3 intentionally stops at
  stable texture identity, descriptor lookup, and stale-ID rejection; it does not
  add atlas metadata, tilemap storage, or tile renderer batching.

Checklist:

- [x] Add a slot table for textures with generation, alive state, and descriptor.
- [x] Add `TextureId` creation, validation, lookup, and destruction helpers.
- [x] Keep draw submission lookup array-backed and allocation-free.
- [x] Preserve the white texture as an internal renderer resource.
- [x] Keep `createTextureFromPng`, `createTextureFromPixels`, and
      `replaceTextureFromPixels` behavior compatible during migration.
- [x] Add tests for stale IDs, destroyed IDs, invalid generation, and descriptor
      validation.
- [x] Add a focused compatibility note for the `TextureHandle` to `TextureId`
      rename.

Acceptance checks:

- [x] Destroyed or stale texture IDs are skipped or rejected deterministically.
- [x] Existing demo and debug text still render.
- [x] Texture upload validation still rejects bad dimensions, pitch, and buffer
      lengths before GPU work.
- [x] No hash map lookup is introduced into per-sprite draw submission.

## Slice 4: Asset Cache

Goal: make runtime asset ownership explicit enough for real projects without
building a broad content pipeline too early.

Current foundation:

- `AssetStore` resolves safe relative paths from repo root or executable-relative
  install location.
- Renderer can load PNGs directly through `createTextureFromPng`.
- `AssetCache` maps validated relative PNG paths to retained renderer
  `TextureId` values.
- `Engine` owns the cache and exposes it to states through `RenderContext`.
- `assets/test/cache_probe.png` provides a tiny installed PNG fixture for cache
  and asset-root checks.

Checklist:

- [x] Add an asset/resource cache module that maps stable asset paths to
      renderer resource IDs.
- [x] Keep path validation in `AssetStore`; do not duplicate traversal checks.
- [x] Decide cache ownership: app-level service owned by `Engine` is the default.
- [x] Add explicit load/unload or retain/release policy before adding hot reload.
- [x] Keep synchronous load first; defer async/staged loading until needed.
- [x] Add tests for duplicate path reuse, unload behavior, and invalid paths.

Acceptance checks:

- [x] Loading the same PNG twice can reuse the existing texture.
- [x] Asset paths remain relative and traversal-safe.
- [x] Installed-binary asset lookup still works with `-Dasset-root`.

## Slice 5: Text And Font Service

Goal: move from FPS-only SDL_ttf usage to asset-backed text rendering suitable
for menus, buttons, and UI.

Current foundation:

- SDL3_ttf is a core dependency.
- `TextService` owns SDL3_ttf lifecycle, asset-backed font loading, and cached
  renderer text textures.
- `FpsCounter` consumes the text service instead of probing system fonts or
  owning raw SDL_ttf resources.
- `assets/fonts/NotoSansMono-Regular.ttf` is the bundled default text font.

Checklist:

- [x] Add a centralized text/font service that owns `TTF_Init` and `TTF_Quit`.
- [x] Load fonts from `assets/fonts/...` through `AssetStore`.
- [x] Add `FontId` allocation and validation using generational IDs.
- [x] Render text into cached renderer textures.
- [x] Define cache invalidation for text string, font, color, wrap width, and
      layout options.
- [x] Move `FpsCounter` to consume the text service.
- [x] Add at least one bundled font or document the asset requirement clearly.
- [x] Add tests for descriptor validation and cache keys where possible.

Acceptance checks:

- [x] F2 overlay still renders yellow FPS text.
- [x] No system font path probing remains in normal text flow.
- [x] Text texture lifetime is centralized and cleaned up by the owning service.

## Slice 6: Renderer Composition

Goal: split renderer responsibilities so sprites, UI, shapes, tilemaps, and
future effects do not all require editing one monolithic renderer path.

Implemented foundation:

- `Renderer` owns frame coordination, public draw APIs, texture IDs, swapchain
  acquisition, render-pass encoding, and command submission.
- `SpriteBatch` owns sprite command sorting, vertex expansion, and draw-group
  construction.
- `src/render/gpu/` owns SDL_GPU device/window setup helpers, pipeline creation,
  upload buffers, and texture upload helpers.
- Build now has a shader-program table for the existing sprite shader pair.

Architecture notes:

- Prefer landing Slice 3 resource IDs before physically splitting
  `renderer.zig`, so texture ownership does not migrate across several files at
  the same time as the handle model changes.
- The first split uses `src/render/gpu/` for SDL_GPU device/window setup,
  shader/pipeline creation, buffers, and texture upload, with sprite command
  sorting and vertex expansion moved to `sprite_batch.zig`.
- Keep `Renderer` as the game-facing facade and frame coordinator; the split
  should hide GPU details behind narrower render-owned modules, not expose more
  SDL_GPU surface area to game states.

Checklist:

- [x] Keep `Renderer` as the device/frame coordinator.
- [x] Move sprite batching internals behind a `SpriteBatch` or equivalent module.
- [x] If `renderer.zig` remains too broad after resource IDs land, split GPU
      setup, pipeline, buffer, and texture helpers under `src/render/gpu/`.
- [x] Introduce static material/pipeline records for the current sprite pipeline.
- [x] Keep draw command sorting stable by layer and submission order.
- [x] Preserve `drawSprite` and `drawRect` as the game-facing API during the
      first split.
- [x] Add tests for batch grouping, invalid texture skipping, and ordering.
- [x] Re-run `gpu-smoke` when display access is available.

Acceptance checks:

- [x] Existing demo output is unchanged.
- [x] New batcher owns sprite-specific vertex construction.
- [x] Renderer frame lifecycle still handles `.submitted` and
      `.skipped_no_swapchain` correctly.
- [x] Adding a second batcher later would not require rewriting device setup.

## Slice 7: Preallocated Thread System And Parallel Render Prep

Goal: add a deterministic, pre-spawned worker system that lets each engine
system use all active workers for CPU work, then finish before the next system
or render phase starts.

Current foundation:

- `Engine` owns app coordination and state-stack update/render flow.
- `main.zig` owns the outer loop and calls `Engine` phase methods; `Engine`
  delegates state callbacks through `StateStack` policy dispatch.
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
- Worker threads park when idle. Do not add spin-wait configuration unless
  measurement proves condition-variable wake latency is the bottleneck.
- `max_worker_threads` counts only pre-spawned worker threads. The
  main/render thread may also process ranges, so the default `cpu_count - 1`
  worker threads uses all normal CPU participants without oversubscription.
- Long-lived async work such as asset streaming or file IO should use a
  separate service later instead of sharing this frame-bounded barrier path.

Thread-system design:

- [x] Add `src/app/thread_system.zig` with `ThreadSystem`,
      `ThreadSystemConfig`, `WorkerId`, `ParallelRange`, `BatchStats`, and a
      deterministic `parallelFor` API.
- [x] Own `ThreadSystem` from `Engine`; initialize it after SDL/app config is
      known and deinitialize it before allocator teardown.
- [x] Pre-spawn up to `max_worker_threads` worker threads at init with
      `std.Thread.spawn`.
      Never create or destroy OS threads during gameplay frames.
- [x] Default worker thread count to one fewer than
      `std.Thread.getCpuCount()` when possible, reserving the main/render thread
      as an additional batch participant; allow config override for worker
      thread count, stack size, minimum parallel item count, and grain size.
- [x] Use preallocated worker records, one synchronous batch descriptor, and an
      atomic range cursor. No frame-batch submission may allocate after
      initialization.
- [x] Use atomics for hot range claiming and range stats; use `std.Io.Mutex` and
      `std.Io.Condition` only for batch publication, worker parking, completion,
      and shutdown paths where blocking is expected.
- [x] Let the main thread participate in submitted batches while waiting so it
      does useful work instead of only acting as a coordinator.
- [x] Dynamically scale active workers only at batch boundaries based on prior
      batch cost, item count, main-thread wait time, and worker utilization.
      Small batches run inline on the main thread.
- [x] Stop accepting work during shutdown, wake parked workers, join every
      pre-spawned thread, and assert that no frame batch is still outstanding.

Engine/system integration:

- [x] Add an update/render-prep context that exposes `thread_system` to states
      or future systems without moving timing policy out of `main.zig`.
- [x] Preserve the runtime flow where `main.zig` calls `Engine` phase methods
      and `Engine` invokes eligible state callbacks through `StateStack`.
- [x] Keep systems ordered: each system may use the whole worker set, but all
      of its jobs must complete before the next system starts.
- [x] Allow worker jobs to read immutable snapshots and write only disjoint
      output ranges.
- [x] Add explicit per-worker scratch slot indexing keyed by `WorkerId` before
      systems need temporary output buffers.
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
explicit update/render contexts, synchronous `parallelFor`, adaptive per-batch
background-worker participation, per-worker scratch slot indexing, and a serial
renderer prep hook. Adaptive scheduling only changes how many already
pre-spawned parked workers participate in each batch; workers are spawned during
`ThreadSystem.init`, reused across frame batches, parked when idle, and joined
only during `ThreadSystem.deinit`. Remaining unchecked work is the actual
parallel CPU render-prep pipeline.

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
- The v1 helper uses Zig `@Vector` as the project abstraction; LLVM may lower the
  resulting vector operations to SSE-family or NEON instructions for suitable
  targets and optimize modes, but this slice does not hand-write target-specific
  intrinsics.

Checklist:

- [x] Add `src/core/simd.zig` with friendly vector aliases such as `Float4`,
      `Int4`, and `Mask4`.
- [x] Prefer portable Zig vector types first, hiding target-specific intrinsic
      details behind the helper API.
- [x] Add load, store, splat, add, subtract, multiply, divide, min, max,
      compare, select, and clamp helpers needed by movement and particle loops.
- [x] Add scalar-tail helpers for item counts that are not a multiple of the
      vector lane count.
- [x] Keep the helper free of game-specific entity, particle, SDL, renderer, or
      thread-system dependencies.
- [x] Document when scalar code should be preferred for tiny batches or clarity.

Acceptance checks:

- [x] SIMD helper tests prove lane order is stable.
- [x] SIMD and scalar implementations produce identical results for representative
      float and integer operations.
- [x] Tail handling covers empty, partial, exact-lane, and multi-lane inputs.
- [x] `zig build test` passes on targets where the helper is expected to compile.

## Slice 10: DataSystem And SoA Composition Foundation

Goal: introduce `DataSystem` as the state-owned persistent gameplay data
container and save/load streaming boundary, with dense SoA storage designed for
fast systems, threading, and SIMD.

Current foundation:

- `StateStack` owns active state lifetimes.
- `UpdateContext` exposes `ThreadSystem` to states.
- `GameDemoState` owns a `DataSystem` for state-local persistent game-world data.
- `Player` remains a player-specific behavior facade, backed by entity data in
  `DataSystem`.

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
- Per-entity component masks are the membership/query layer. Hot system data is
  still exposed through aligned scalar SoA slices, not joined dynamically in the
  update or render loop.

Checklist:

- [x] Add a game data module with `DataSystem` and an entity ID/generation
      registry.
- [x] Add dense scalar-column SoA stores for initial persistent gameplay data
      such as movement bodies and renderable primitive visual intent.
- [x] Use stable handles or dense indices so stores can remain compact while
      rejecting stale IDs.
- [x] Keep SDL handles, GPU handles, input frame state, renderer state,
      `ThreadSystem`, transient events, and scratch buffers outside `DataSystem`.
- [x] Store persistent asset references as stable IDs or relative paths, not
      live renderer texture handles.
- [x] Add explicit init/deinit and clear/reset behavior for state lifecycle and
      save/load preparation.

Acceptance checks:

- [x] Entity IDs reject stale generations after removal and reuse.
- [x] Dense SoA stores keep arrays length-aligned and compact after add/remove.
- [x] Movement-body columns can be loaded directly with `src/core/simd.zig`
      helpers and handle vector ranges plus scalar tails.
- [x] Component masks track entity membership for future system queries without
      replacing the SIMD-ready SoA storage.
- [x] `DataSystem` can be initialized and deinitialized without leaks.
- [x] Tests cover which data belongs inside `DataSystem` versus transient runtime
      services that must stay outside it.

Slice 10 landed as a state-owned data foundation. Update systems mutate
`DataSystem` slices, render systems read immutable slices and submit through
`Renderer`, and live engine/runtime services stay outside persistent data. The
movement-body store is SIMD-ready scalar SoA storage; threaded/SIMD processors
remain Slice 11 work.

## Slice 11: SIMD-Aware Data Processor Systems

Goal: add high-performance systems that process `DataSystem` slices with the
thread system and SIMD helpers while preserving deterministic fixed-step update
behavior.

Current foundation:

- `ThreadSystem.parallelFor` runs synchronous range batches and returns only
  after all selected workers finish.
- `ThreadSystem.parallelForWithOptions` can align ranges to hot-column cache
  boundaries and cap selected worker threads for a specific processor.
- `UpdateContext` passes `thread_system` into states.
- `DataSystem` provides persistent 64-byte-aligned movement SoA slices for
  systems to process.
- `src/core/simd.zig` provides portable vector helpers.
- `MovementSystem` integrates movement-body SoA columns through a serial path or
  `ThreadSystem.parallelForWithOptions`.
- `ParticleSystem` owns a state-local fixed-capacity transient SoA pool and
  updates particle rows through a serial path or
  `ThreadSystem.parallelForWithOptions`.
- `GameDemoState` spawns a few colored moving square entities so the processor has
  visible non-player runtime coverage.
- `GameDemoState` emits and renders transient particle rectangles through its state
  update/render functions.

Performance notes:

- Hot processors should iterate SoA columns directly, not per-entity AoS structs
  or dynamically joined component records.
- `ThreadSystem` integration is required for this slice. Keep a serial path for
  small counts, tests, and fallback behavior, but the processor API and tests
  must prove that systems can split `DataSystem` slices through
  `ThreadSystem.parallelFor`.
- Treat the current adaptive thread-system thresholds as a starting heuristic,
  not a tuned policy. The first real processor should record whether selected
  worker counts, range sizes, main-thread wait time, and worker utilization are
  sensible under representative movement workloads before broadening the policy.
- Treat cache-line behavior as part of the processor contract. SoA columns used
  by SIMD processors should have an explicit alignment policy before relying on
  wider loads or target-specific vector behavior.
- Padding to 64-byte cache lines should be applied deliberately to thread-shared
  records, worker scratch, counters, queues, and other concurrently written
  coordination data where false sharing is a real risk.
- Do not pad the cold entity slot metadata by default. Entity slots hold
  generation, component masks, free-list state, and dense store indices; they
  should stay out of hot movement/render processor loops unless profiling proves
  otherwise.
- Worker ranges should be chosen so two workers do not write the same cache line
  of a hot SoA column during normal fixed-step processing.

System shape:

- `MovementSystem` reads and writes the movement-body SoA slices in
  `DataSystem`, keeps a simple serial path for small counts and tests, and uses
  threaded SIMD ranges for larger batches.
- `MovementSystem` must not create, destroy, add, or remove entities/components
  inside worker ranges. Any structural change needed by future systems should be
  deferred to a later command-buffer design.
- `ParticleSystem` is a state-owned transient effect system rather than a
  `DataSystem` entity processor. It keeps emission and expired row swap-removal
  on the main thread, while worker ranges only mutate assigned particle rows.
- These implementations prove the threaded/SIMD system contract before
  broadening into AI, collision, pathfinding, or render-prep processors.

Checklist:

- [x] Define ECS systems as data processors that accept `DataSystem`,
      `ThreadSystem`, and fixed-step delta time; document `ParticleSystem` as
      the state-owned transient effect exception.
- [x] Add a movement processor that splits dense SoA slices through
      `parallelFor`.
- [x] Add particle processors that split dense SoA slices through `parallelFor`.
- [x] Wire `MovementSystem` through `ThreadSystem.parallelFor` with a serial path
      for small counts and deterministic tests.
- [x] Use SIMD inside each worker range and scalar-tail code for remainder
      elements.
- [x] Add an explicit alignment strategy for hot SoA columns before introducing
      wider or target-specific vector loads.
- [x] Audit thread-shared processor data for false sharing and add 64-byte
      padding only where concurrent writes justify it.
- [x] Ensure worker jobs write only to assigned disjoint ranges.
- [x] Ensure worker ranges avoid sharing writable cache lines in hot SoA columns.
- [x] Keep state transitions, entity creation/removal, SDL calls, GPU calls,
      asset loading, and save/load streaming on the main thread.
- [x] Keep particle expired-row removal on the main thread after the worker
      batch completes. Future systems that produce per-worker output buffers
      will need an explicit deterministic merge step.
- [x] Keep normal 60Hz update paths allocation-free after initialization.

Acceptance checks:

- [x] Scalar and SIMD movement results match for representative data sets.
- [x] Serial and threaded processor results match for the same initial
      `DataSystem`.
- [x] The movement processor has test coverage for the serial path and the
      `ThreadSystem.parallelFor` path.
- [x] Worker jobs do not write outside their assigned `ParallelRange`.
- [x] Hot SoA columns used by SIMD processors have documented alignment behavior.
- [x] Thread-shared processor records that are concurrently written are either
      disjoint by design or padded/aligned to avoid false sharing.
- [x] Update processors perform no allocations during steady-state simulation.
- [x] Fixed-step update order remains deterministic: later systems always see
      completed output from earlier systems.

Movement and particle passes landed: the demo maps player input to movement
velocity, runs `MovementSystem` once over all movement bodies, applies
player-only bounds clamping, emits a small particle trail, updates particles,
and renders transient particle rectangles. A few colored moving squares remain
as non-player movement processor coverage. Parallel render prep remains open
under Slice 7, while simulation contracts, collision, AI, pathfinding, and rule
processing are covered by Slices 12-14.

## Slice 12: Simulation Contracts And Deferred Structural Changes

Goal: define deterministic simulation phase contracts before broad gameplay
systems start creating entities, emitting events, or requesting structural
changes from worker jobs.

Current foundation:

- `main.zig` -> `Engine` -> `StateStack` is the existing runtime dispatch path
  for events, fixed updates, and rendering.
- `StateTransitions` already queues state-stack changes until dispatch is safe.
- `DataSystem` owns persistent state-local gameplay data and excludes transient
  services.
- `ThreadSystem` runs synchronous range batches that complete before the next
  system consumes their output.
- Movement and particle processors prove serial and threaded fixed-step updates
  over dense SoA slices.

Architecture notes:

- Structural entity/component changes, state transitions, SDL/GPU calls, asset
  loading, save/load streaming, and renderer ownership must remain behind an
  explicit main-thread or deferred boundary.
- Transient simulation events and intents should be typed, bounded, ordered
  data, not callback chains or hot-path hash-map dispatch.
- Designs should make fixed-step processor order, conflict resolution, and
  merge points explicit before adding systems that can interact emergently.

Checklist:

- [ ] Define the fixed-step simulation phase order for gameplay processors,
      transient events, deferred structural commands, and save/load hooks.
- [ ] Add a state-owned event/intent/deferred-command path with deterministic
      append and merge behavior.
- [ ] Add tests that worker-produced outputs merge in stable order and cannot
      mutate `DataSystem` structure from worker ranges.
- [ ] Document what belongs in persistent `DataSystem` state versus transient
      per-frame simulation data.

Acceptance checks:

- [ ] Deferred entity/component changes apply only after the producing processor
      completes.
- [ ] Replaying the same initial data and inputs produces the same event,
      command, and processor output order.
- [ ] Save/load boundaries exclude transient frame events, scratch buffers,
      renderer resources, app services, and thread-system state.

## Slice 13: Spatial Queries And Collision Contacts

Goal: add data-oriented spatial query and collision contact foundations that can
feed gameplay response systems without turning hot loops into per-entity object
dispatch.

Current foundation:

- `DataSystem` has entity IDs, component masks, movement bodies, primitive
  visual intent, and aligned movement SoA columns.
- `MovementSystem` updates positions deterministically before later processors
  read them.
- Slice 12 will provide the event/deferred-command boundary needed for collision
  outcomes that create, remove, or change entities.

Architecture notes:

- Spatial query data should be built from dense slices and stable entity IDs.
- Collision detection should produce deterministic contact/query output before
  response processors consume it.
- Collision response should be separate from broadphase/narrowphase detection so
  gameplay rules can choose how to react to contacts.

Checklist:

- [ ] Add persistent collision-shape or bounds data in `DataSystem` only for
      world objects that need collision or spatial queries.
- [ ] Add a deterministic broadphase/spatial-query structure appropriate for the
      current 2D scale.
- [ ] Add a contact output buffer and response processor boundary.
- [ ] Add tests for stable contact ordering, stale entity rejection, and serial
      versus threaded query behavior where threading is used.

Acceptance checks:

- [ ] Collision queries operate from typed SoA data and stable IDs, not object
      callbacks.
- [ ] Contact generation is deterministic for the same initial data and fixed
      update step.
- [ ] Collision response cannot perform unsafe structural mutation inside worker
      ranges.

## Slice 14: AI, Pathfinding, And Emergent Rule Processing

Goal: add AI, pathfinding, and gameplay-rule processors that compose through
data, intents, and deterministic order rather than copying player-specific
behavior into many entity types.

Current foundation:

- `DataSystem` and component masks can identify entity membership for processors.
- Movement and particle processors demonstrate the system API shape.
- Slice 12 should provide deterministic event/intent/deferred-command contracts.
- Slice 13 should provide spatial query and contact data for perception and
  collision-aware decisions.

Architecture notes:

- AI and rules should usually emit movement intents, steering outputs, target
  choices, path requests/results, or deferred commands rather than mutating
  unrelated stores directly.
- Deterministic randomness must be explicit state or an explicit service passed
  through the processor boundary.
- Pathfinding should use read-only navigation or world snapshots during worker
  jobs and merge results deterministically before movement or response systems
  consume them.

Checklist:

- [ ] Add typed intent/request/result stores for AI, rules, and pathfinding.
- [ ] Define processor order for perception, decision, path/steering output,
      movement intent, movement integration, collision response, and cleanup.
- [ ] Add deterministic conflict-resolution policy when multiple systems request
      incompatible outcomes.
- [ ] Add tests for repeatable decisions, stable merge order, and no steady-state
      allocation in hot processors.

Acceptance checks:

- [ ] Non-player entities can be driven by data and processors rather than
      player-behavior copies.
- [ ] AI/path/rule processors produce deterministic outputs for fixed initial
      data, inputs, and random seeds.
- [ ] Processor outputs compose through typed data, intents, or deferred commands
      with explicit ownership and lifetime.

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
12. Simulation contracts and deferred structural changes.
13. Spatial queries and collision contacts.
14. AI, pathfinding, and emergent rule processing.

This order keeps gameplay/menu correctness ahead of larger renderer work, then
builds resource ownership before text/UI, renderer composition, and parallel
render preparation depend on it. SIMD helpers land before the DataSystem and
processor slices so the storage and system APIs can be designed around the hot
loop shape from the start. The new gameplay-system slices keep structural
changes, spatial contacts, and AI/rule outputs ordered and testable before
emergent behavior becomes broad.
