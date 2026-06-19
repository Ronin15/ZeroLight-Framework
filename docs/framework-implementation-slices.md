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

- Finish Slice 7 parallel CPU render prep on top of the Slice 17
  `RuntimeAssets` catalog. Keep it incomplete until serial and parallel prep
  produce identical draw order, grouping, and invalid-resource handling.
- Finish Slice 20 navigation hardening before scaling to large maps or many NPC
  path users. Rare true-A* work, pending budgets, cache aging/capacity, and
  hard-path benchmark visibility should remain explicit.
- Track collision-response merge/apply, renderer batch capacity, text-cache
  lifetime policy, and manual registry guardrails as hardening follow-ups.
- Add a typed simulation event system slice before broad domain features such as
  tiles, weather, obstacle state, AI perception, navigation invalidation, combat,
  and spawning start depending on cross-system change signals.
- When multiple gameplay states need the same ordered processor flow, extract a
  state-owned simulation pipeline helper instead of duplicating `GameDemoState`
  orchestration or adding a global ECS scheduler. The pipeline may own
  lightweight domain controllers, but persistent facts stay in `DataSystem` and
  hot loops stay in SoA processors.
- Keep future gameplay systems built on Slice 12's typed processor outputs,
  deterministic merge, and deferred structural-change contracts.

## Long-Term Gameplay Direction

Future gameplay features should use state-owned feature controllers or a
state-owned simulation pipeline helper for orchestration, and SoA processors for
hot data work. Controllers choose phase order, budgets, queues, cooldowns,
conflict policy, and which typed `DataSystem` views processors receive. A
reusable pipeline is appropriate once multiple gameplay states or instances
need the same ordered stages; it should remain owned by the state instance and
should not be promoted into a global scheduler. The pipeline can own domain
controllers for one state instance, and those controllers can coordinate small
feature-local state and processor handoff. Persistent gameplay/domain facts
live in `DataSystem` or state-owned domain storage, per-step outputs live in
`SimulationFrame`, and large or reusable loops stay in systems that process
typed slices and emit deterministic outputs.
Pathfinding provides a navigation substrate; immersive NPC behavior still needs
steering, local avoidance, perception, and rule arbitration layered above it.

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
- [x] `zig build check` compiles the app, GPU smoke, and benchmark executables.
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
- [x] Hidden/minimized windows still skip rendering and use fallback pacing;
      visible no-swapchain frames enter render-blocked gameplay pause before
      the next update.
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
- [x] Keep renderer texture creation centered on decoded pixel uploads through
      `createTextureFromPixels` and `replaceTextureFromPixels`.
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
- `AssetStore` resolves and decodes PNGs into transient CPU `LoadedImage` data.
- `AssetCache` maps validated relative PNG paths to retained renderer
  `TextureId` values by decoding through assets and asking render to upload
  already-decoded pixels.
- `Engine` owns the cache. Slice 17 later moved gameplay-facing render lookup
  to stable `RuntimeAssets` IDs exposed through `RenderContext`.
- `assets/test/cache_probe.png` provides a tiny installed PNG fixture for cache
  and asset-root checks.

Future render-data slice:

- Entity creation and world loading should bind stable sprite or atlas-region
  IDs before render-time. `DataSystem` render data should store stable asset
  references plus source intent such as tint, layer, and coordinate-space
  intent, not live renderer handles.
- A state-owned render-prep system should read immutable `DataSystem` slices and
  submit prepared `Sprite` commands to `Renderer`. The renderer should not look
  up gameplay entities, world data, asset paths, or texture assignments.
- Atlas work should build on the same boundary: assets decode source images,
  atlas code packs CPU pixels, render uploads the final atlas texture, and
  entities reference atlas regions.

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
      thread count, stack size, and items per claimed range
      (`items_per_range`).
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
      Static item-count floors do not gate production worker participation;
      timing and structural range feasibility decide whether work stays inline.
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
- [x] Existing visible rendering remains swapchain/vsync paced, hidden/minimized
      fallback pacing remains unchanged, and visible no-swapchain results block
      gameplay before the next update.
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
- Linux builds SPIR-V, macOS builds MSL, and Windows builds DXIL.
- Runtime selects shader files from SDL-reported supported formats.
- Build metadata and runtime pipeline metadata are still updated in separate
  places until a shared shader/material manifest exists.

Checklist:

- [x] Keep generated runtime shader files under `assets/shaders` in the install
      tree.
- [x] Add explicit Windows target output through DXIL.
- [x] Keep runtime backend selection SDL-driven; do not hard-code GPU driver names.
- [ ] Consolidate shader-program, material, and runtime pipeline metadata so
      new pipelines do not need parallel registry edits.
- [ ] Validate the right shader format list for each target OS.
- [ ] Add direct runtime asset/shader lookup guidance or tests for direct binary
      execution outside the installed binary directory.
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
- `MovementSystem` integrates explicit movement-body SoA slices through a serial
  path or `ThreadSystem.parallelForWithOptions`.
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
  tests, explicit fallback behavior, and deterministic comparisons, but the
  processor API and tests must prove that systems can split `DataSystem` slices through
  `ThreadSystem.parallelFor`.
- Treat adaptive work tuning as a measured batch-profile policy, not a separate
  worker-count heuristic. The tuner starts inline, probes threaded profiles only
  when measured batch time justifies it, then searches aligned range sizes
  around the best measured threaded profile before settling. Benchmark output
  should keep reporting worker count, range size, main-thread wait time, and
  worker utilization so regressions are visible.
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

- `MovementSystem` reads and writes explicit movement-body SoA slices, keeps a
  simple serial path for tests and deterministic comparisons, and uses
  timing-adaptive threaded SIMD ranges for eligible batches.
- `MovementSystem` must not create, destroy, add, or remove entities/components
  inside worker ranges. Structural changes from future processors should flow
  through the state-owned simulation frame and `DataSystem` batch commit path.
- `ParticleSystem` is a state-owned transient effect system rather than a
  `DataSystem` entity processor. It keeps emission and expired row swap-removal
  on the main thread, while worker ranges only mutate assigned particle rows.
- These implementations prove the threaded/SIMD system contract before
  broadening into AI, collision, pathfinding, or render-prep processors.

Checklist:

- [x] Define ECS systems as data processors that accept typed `DataSystem`
      slices/views, `ThreadSystem`, and fixed-step delta time; document
      `ParticleSystem` as the state-owned transient effect exception.
- [x] Add a movement processor that splits dense SoA slices through
      `parallelFor`.
- [x] Add particle processors that split dense SoA slices through `parallelFor`.
- [x] Wire `MovementSystem` through `ThreadSystem.parallelFor` with a serial path
      for deterministic tests and explicit comparisons.
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
velocity, exposes a movement-body slice to `MovementSystem`, applies player-only
bounds clamping, emits a small particle trail, updates particles, and renders
transient particle rectangles. A few colored moving squares remain as non-player
movement processor coverage. Parallel render prep remains open under Slice 7,
while simulation contracts, collision, and the first AI intent processor are
covered by Slices 12-14. Pathfinding and broader rule processing remain future
systems that should build on the same typed-output contracts.

## Slice 12: Simulation Contracts And Deferred Structural Changes

Goal: define deterministic, efficient simulation phase contracts before broad
gameplay systems start creating entities, emitting events, or requesting
structural changes from worker jobs.

Implemented foundation:

- `main.zig` -> `Engine` -> `StateStack` is the existing runtime dispatch path
  for events, fixed updates, and rendering.
- `StateTransitions` already queues state-stack changes until dispatch is safe.
- `DataSystem` owns persistent state-local gameplay data and excludes transient
  services.
- `ThreadSystem` runs synchronous range batches that complete before the next
  system consumes their output.
- `ParallelRange.index` gives inline and threaded jobs stable range-order
  identity independent of worker scheduling.
- `SimulationFrame` is state-owned transient per-step data with typed event,
  intent, and deferred structural command streams.
- `RangeOutputStream(T)` implements count/prefix/write output collection and
  deterministic range-index merge.
- `DataSystem.applyStructuralCommands` applies deferred entity/component changes
  at explicit main-thread commit points.
- `GameDemoState` owns a `SimulationFrame`, clears it each fixed step, runs
  processor phases, and applies deferred structural commands before the step
  finishes.
- `MovementSystem` now consumes explicit movement-body slices rather than broad
  structural `DataSystem` access.

Architecture notes:

- Structural entity/component changes, state transitions, SDL/GPU calls, asset
  loading, save/load streaming, and renderer ownership must remain behind an
  explicit main-thread or deferred boundary.
- Determinism, performance, and efficiency are one contract: output order must
  come from stable input/range order, not worker timing or worker IDs; high-volume
  outputs must use typed range-owned buffers instead of global per-command append,
  callback chains, or hot-path hash maps; warmed paths must avoid allocation.
- Threaded output collection should use a count/prefix/write pipeline:
  count outputs per range, prefix offsets on the main thread, write contiguous
  output by range, merge by range index, then consume the typed batch.
- Structural mutation remains behind `DataSystem` batch commit boundaries.
  Event and intent streams use the same typed range-output model, but remain
  transient simulation data rather than persistent `DataSystem` state.
- Designs should make fixed-step processor order, input order, output owner,
  merge order, allocation policy, conflict resolution, and structural apply
  points explicit before adding systems that can interact emergently.

Checklist:

- [x] Define the fixed-step simulation phase order for gameplay processors,
      transient events, deferred structural commands, and save/load hooks.
- [x] Add stable `ParallelRange.index` support so output order can be tied to
      deterministic range order rather than worker scheduling.
- [x] Add a state-owned simulation frame with typed event, intent, and deferred
      structural command streams.
- [x] Add range-owned output collection for high-volume streams using
      count/prefix/write and deterministic range-index merge.
- [x] Add `DataSystem` batch commit boundaries for deferred structural changes;
      do not expose per-command structural mutation as the simulation output API.
- [x] Refactor `MovementSystem` so the processor path receives typed slices
      rather than broad structural `DataSystem` access.
- [x] Add tests that worker-produced outputs merge in stable order.
- [x] Refactor typed processor APIs so hot processor paths avoid broad
      structural `DataSystem` access.
- [x] Document what belongs in persistent `DataSystem` state versus transient
      per-frame simulation data.

Acceptance checks:

- [x] Deferred entity/component changes apply only after the producing processor
      completes.
- [x] Replaying the same initial data and inputs produces the same event,
      command, and processor output order, independent of worker timing.
- [x] High-volume output paths use preallocated typed arrays, slices, range-owned
      buffers, and deterministic batch commit instead of global per-command
      atomics, broad event buses, or hot-path hash-map dispatch.
- [x] Save/load boundaries exclude transient frame events, scratch buffers,
      renderer resources, app services, and thread-system state.

## Slice 13: Spatial Queries And Collision Contacts

Goal: add data-oriented spatial query and collision contact foundations that can
feed gameplay response systems without turning hot loops into per-entity object
dispatch.

Current foundation:

- `DataSystem` has entity IDs, component masks, movement bodies, primitive
  visual intent, dedicated collision bounds, and aligned movement SoA columns.
- `MovementSystem` updates positions deterministically before later processors
  read them.
- Slice 12 provides the event/deferred-command boundary needed for collision
  outcomes that create, remove, or change entities.

Architecture notes:

- `CollisionSystem` owns warmed transient AABB proxy scratch, not persistent
  gameplay data.
- The first broadphase is sweep-and-prune over entities with both movement bodies
  and collision bounds. It threads sorted anchor ranges, uses SIMD overlap
  filtering, and emits range-owned candidate pairs once before deterministic
  merge.
- Narrowphase is a separate threaded batch: worker ranges SIMD-compute contact
  math over candidate pairs, then merge range-owned contact buffers
  deterministically for the same-step response stream.
- Thread-written broadphase and narrowphase range scratch is 64-byte padded;
  persistent collision component storage remains dense and unpadded by default.
- Broadphase and narrowphase keep separate adaptive tuners and batch stats; no
  combined timing trains either stage. Inline stage measurements still train the
  owning stage tuner, so a later expensive window can switch that stage to
  worker threads without borrowing another stage's profile.
- Collision response stays separate from detection; `CollisionResponseSystem`
  consumes the completed same-step contact stream through explicit
  response-policy components before structural commands commit.

Checklist:

- [x] Add persistent collision-shape or bounds data in `DataSystem` only for
      world objects that need collision or spatial queries.
- [x] Add a deterministic broadphase/spatial-query structure appropriate for the
      current 2D scale.
- [x] Add a contact output buffer and response processor boundary.
- [x] Add tests for stable contact ordering, stale entity rejection, and serial
      versus threaded query behavior where threading is used.
- [x] Add non-interactive collision benchmarks with quick-profile dense/sparse
      regression coverage, heavier 10k-50k standard-profile sweeps, and
      candidate/contact counters.

Acceptance checks:

- [x] Collision queries operate from typed SoA data and stable IDs, not object
      callbacks.
- [x] Contact generation is deterministic for the same initial data and fixed
      update step.
- [x] Collision response cannot perform unsafe structural mutation inside worker
      ranges.

Slice 13 landed as a high-throughput collision-contact foundation. The collision
processor builds 64-byte-aligned AABB proxies from movement and collision bounds,
maintains warm sorted order, partitions sweep-and-prune work into deterministic
range windows, and emits transient contacts through `SimulationFrame`. The
response processor consumes the completed same-step contact stream through
`collision_response` components, keeps trigger output in a typed transient
stream, computes correction columns with `src/core/simd.zig`, and applies sparse
movement writes in deterministic contact order before structural commands
commit. The demo uses the same generic response path for player-obstacle,
moving-square-obstacle, and player-moving-square contacts. Detector benchmarks
report candidate pairs and contacts for dense/sparse body workloads, while
response benchmarks report triggers and intents across 1k-50k contact workloads.

## Slice 14: First AI Intent Processor And Future Rule Contracts

Goal: add the first data-driven non-player decision processor that emits
deterministic movement intents through `SimulationFrame`, proving the AI/rule
processor boundary before broader rule systems are added.

Current foundation:

- `DataSystem` and component masks can identify entity membership for processors.
- Movement and particle processors demonstrate the system API shape.
- Slice 12 provides deterministic event/intent/deferred-command contracts.
- Slice 13 provides spatial query and contact data for perception and
  collision-aware decisions.
- `DataSystem` owns aligned `AiAgent` SoA data, membership masks,
  structural-command validation, and dense movement lookup for AI rows.
- `AiSystem` reads `AiAgent` and movement slices, builds a transient 32-unit
  spatial grid, computes bounded local-separation samples, emits deterministic
  `MovementIntent` ranges into `SimulationFrame`, and uses serial or adaptive
  threaded execution for the separation and intent-emission stages.
- `GameDemoState` runs AI after main-thread player input and before movement
  integration, then applies AI movement intents on the main thread before
  `MovementSystem`.
- AI benchmarks cover serial, fixed-thread, and adaptive profiles for quick,
  standard, and stress workloads.
- `zig build fmt`, `zig build test`, `zig build check`, and `zig build verify`
  passed for this slice.

Architecture notes:

- State-owned feature controllers should orchestrate feature phases and budgets,
  not become hidden per-entity stores. They may take typed `DataSystem` views
  and run small policy passes, but hot or reusable loops should remain
  systems/processors over SoA slices.
- Future AI and rules should emit movement intents, steering outputs, target
  choices, typed requests/results, or deferred commands rather than mutating
  unrelated stores directly.
- AI separation and intent emission are independently staged and tuned. Future
  perception or rule passes need the same explicit work ownership,
  stage-specific tuning, and deterministic merge points.
- Deterministic randomness must be explicit state or an explicit service passed
  through the processor boundary.

Checklist:

- [x] Reuse `MovementIntent` and `RangeOutputStream` for the first AI steering
      output.
- [x] Define processor order for the first AI decision output, movement intent
      application, movement integration, collision response, and cleanup.
- [x] Keep current conflict policy narrow: single-writer AI movement intents are
      applied on the main thread in merged range order. Multi-system
      incompatible-intent arbitration remains future work.
- [x] Add tests for repeatable decisions, stable merge order, and no steady-state
      allocation in hot processors.

Acceptance checks:

- [x] Non-player entities can be driven by data and processors rather than
      player-behavior copies.
- [x] The AI movement-intent processor produces deterministic outputs for fixed
      initial data, target, and random seed.
- [x] Processor outputs compose through typed data, intents, or deferred commands
      with explicit ownership and lifetime.

## Slice 15: SDL3_mixer Audio Service

Goal: add app-owned SFX and music support so gameplay states can request
immersive audio without owning SDL_mixer resources or moving audio calls into
threaded processors.

Current foundation:

- SDL3_mixer is a required system dependency beside SDL3 and SDL3_ttf.
- `AudioService` owns SDL_mixer initialization, the mixer device, reusable SFX
  tracks, one music track, loaded audio assets, failed-load memoization, bus
  gains, and pause ducking.
- `AudioCommandBuffer` carries state-owned audio intent through `UpdateContext`.
  States queue copied, traversal-safe relative paths during fixed-step updates;
  `Engine` drains commands on the main thread after state updates and transition
  application.
- The demo starts looping music once, updates the listener from the player, and
  emits debounced positional collision SFX from completed contact streams.

Checklist:

- [x] Link SDL3_mixer and include its C API through the platform SDL import.
- [x] Add audio config validation for track count, command cap, gains, and
      spatial scale.
- [x] Add an app-owned audio service and fixed-step command buffer.
- [x] Pass audio intent through `UpdateContext` without putting SDL_mixer handles
      in gameplay state or `DataSystem`.
- [x] Add demo music and collision SFX assets under `assets/audio/`.
- [x] Add tests for command validation, command caps, load caching, failed-load
      memoization, music idempotence, pause ducking, and spatial positioning.
- [x] Update architecture, setup, workflow, and repository guidance docs.

Acceptance checks:

- [x] Gameplay states can request SFX and music without owning mixer handles.
- [x] Audio commands are bounded per fixed step and drained on the main thread.
- [x] Pause stops active SFX and ducks/resumes music gain.
- [x] Missing audio assets warn once per path instead of retrying every frame.
- [x] The demo proves music plus collision SFX through installed runtime assets.

## Slice 16: Main Menu and Settings Menu

Goal: provide a root main menu as the default startup state and a reachable settings menu for basic configurable options (initially live audio bus/master gains) so the app no longer boots directly into gameplay. Menus use the existing state stack (opaque + modal policies), input routing (new menu actions routed under the `.ui` context), text service for labels, renderer logical-space drawing, and audio command buffer for fixed-step gain changes.

Current foundation:

- `StateStack` + `StateTransitions` (replaceGameplay, replaceOwnedGameplay, pushModal, pop support added in this slice) and the four policies (gameplay / modal_overlay / pass_through_overlay / opaque_screen).
- `InputState` / `FrameCommands` + `input_router` with explicit `.ui` context and `modalUi`/`opaqueScreen` policies that already block gameplay movement while allowing app/debug/ui commands. Consumed state events suppress fallback routing into global frame commands.
- `TextService` cached text drawing/preparation (Slice 5) and `Renderer.drawSprite` / `drawRectInSpace(..., .logical)` for UI.
- `PauseState` provides the concrete drawing, layering (~9000+), color, text-measurement, and centered-panel precedent.
- `AudioCommandBuffer.setMasterGain` / `setBusGain` + `AudioBus` (Slice 15) for live settings feedback without owning mixer resources. MainMenuState owns the runtime audio-setting values so they persist across settings reopen and into gameplay launch.
- `GameDemoState.init(allocator, w, h)` as the target launched from the menu.
- `bootstrapStartupState` in Engine with the explicit comment that a real MainMenuState was expected.
- Menus use `handleEvent` (raw SDL events, which reach top state for modal/opaque policies) and translate keys through `input.actionForKey(...)` before acting on named ui/app actions. `UpdateContext` carries audio for gain commands, transitions, input, and thread_system; `RenderContext` carries renderer + optional text_service. This matches the actual `UpdateContext` definition (no one-frame commands field).
- All states follow the vtable shape with `init`/`deinit`/`update`/`render`/`handleEvent` and required `onPause`; `onResume` is optional.

Architecture notes:

- `StatePolicy.gameplay` is the source of truth for active gameplay; pause entry
  is gated by `StateStack.isGameplayActive()`.
- `pauseActive` / `resumeActive` target the gameplay-policy state, so overlays
  can sit on top without stealing gameplay pause notifications.
- Menu and settings states are non-gameplay UI states; pause attempts over them
  are inert.
- Settings are currently runtime menu state. Persistent settings file work
  should move pending adjustment persistence out of modal-local state so closing
  the settings menu cannot drop a not-yet-applied adjustment.

Checklist:

- [x] Add four menu navigation actions (`menuUp`/`menuDown`/`menuLeft`/`menuRight`) bound to arrow keys, classified as command actions, and routed to the `.ui` context. Update binding, routing, and action tests.
- [x] Extend `StateTransitions` and `StateStack` with `pop()` (request + apply + destroy) plus minimal tests so child menus can dismiss themselves cleanly.
- [x] Implement `MainMenuState` (src/game/main_menu_state.zig) as an opaque-screen root menu: 3 items, allocator storage for spawning GameDemo, selection + wrap, text-service-backed title+items with accent for selected, logical rect + text rendering, confirm via resumeGame action, quit action exits, transitions to gameplay or settings or app quit. Internal focused tests.
- [x] Implement `SettingsMenuState` (src/game/settings_menu_state.zig): 3 volume rows + Back, u8 0-10 state, menuLeft/menuRight records a pending adjustment for the selected volume, the next update queues set*Gain, labels render from current state, quit action or Back confirm does pop(), same visual style. Tests for clamping, emitted commands, pop, and command-failure consistency.
- [x] Update Engine bootstrap to create MainMenuState (opaque) at startup with logical size + allocator; keep GameDemo import for launch path. Update the old placeholder comment.
- [x] Register the two new game modules in src/tests.zig comptime block for `zig build test` coverage.
- [x] Add the full Slice 16 section (this text) to framework-implementation-slices.md following prior slice format, plus update Next Priority Tracks and the Suggested Order list.
- [x] Minor doc updates in state-stack-and-input.md (new actions in input model) and architecture.md (new states under game/, bootstrap note).
- [x] `zig build fmt`, `zig build test`, `zig build check`, `zig build verify` all pass.
- [x] Manual `zig build dev` smoke confirmed: arrow navigation + wrap, Enter starts demo, Esc quits from main, Settings reachable, Left/Right adjust volumes with audible result and label update, Back/Esc returns to main, gains persist into launched gameplay, F2 overlay works, no leaks on repeated transitions.

Acceptance checks:

- [x] App starts at a usable main menu (title + 3 keyboard-selectable items) instead of the demo.
- [x] Arrow keys change selection (wraps); Enter/Space activates; Esc quits from main menu.
- [x] "Start Game" replace-launches a fully functional GameDemoState (player input, systems, audio, pause overlay still work).
- [x] "Settings" pushes a modal settings view; Left/Right on volume rows records a pending gain change, the next update queues the gain command, labels update, and Esc or Back returns cleanly via pop.
- [x] Volume changes made in settings are respected when starting gameplay afterward.
- [x] Menu states store dirty non-owning `PreparedText` views, not generated
      text texture ownership; stable render frames draw prepared views directly
      and `TextService` owns the app-lifetime text cache.
- [x] Focused (no-window) tests cover action-mapped selection, wrap, transition requests (including pop), volume clamp + command emission, and command-failure consistency.
- [x] Updated routing tests prove menu actions are allowed exactly under ui/modal/opaque policies and blocked from pure gameplay routing.
- [x] `zig build verify` passes; docs updated in the canonical slices format.

Slice 16 lands the first real menu layer. The implementation stays deliberately small (no widget system, keyboard only, volumes as the single live setting) while covering the tested contract: state-driven navigation through named actions, consumed-event ui input routing, service-cached text + logical renderer drawing, fixed-step audio command effects from menus, clean pop + replace transitions, allocator hand-off for spawned gameplay, pause restricted to active gameplay, and complete tests + docs. Future menu work (controls, graphics stubs, in-game pause integration, persistence) can build directly on these states and the pop primitive.

## Slice 17: Startup Runtime Asset Catalog

Goal: preload the declared runtime asset set during `Engine.init` and make an
Engine-owned `RuntimeAssets` app service the source of stable sprite/audio
handles for gameplay, render prep, and audio commands. Missing declared content
should log once and mark that asset unavailable, but should not fail app
initialization.

Current foundation:

- `AssetStore` resolves traversal-safe runtime asset paths under the configured
  asset root.
- `AssetCache` decodes PNGs, uploads renderer textures, and returns retained
  `TextureLease` values.
- `AudioService` owns SDL3_mixer lifecycle, track pools, loaded audio handles,
  bus gains, and pause ducking.
- `Renderer` owns live GPU textures and draw submission.
- `DataSystem` stores persistent asset-reference component rows as stable
  `SpriteAssetId` values, but it does not own live renderer or audio resources.
- `RenderContext` exposes `RuntimeAssets`; `AudioCommandBuffer` carries stable
  `AudioAssetId` values plus playback parameters.

Architecture notes:

- `RuntimeAssets` lives under `src/assets/` and is an app service/catalog, not a
  gameplay processor under `src/game/systems/`.
- Add a typed code manifest for startup assets. It assigns stable IDs such as
  `SpriteAssetId` and `AudioAssetId` to relative asset paths.
- `Engine` owns `RuntimeAssets`. It preloads declared sprites/images through
  `AssetCache` after `Renderer` exists and preloads declared audio through
  `AudioService` after the mixer service exists.
- `RuntimeAssets` owns startup texture lease tokens, releases them explicitly
  through the live `AssetCache`/`Renderer` owner, and exposes prepared sprite
  metadata such as `{ texture, source_rect }`. Today each sprite can use a full
  texture; future atlas work can map the same `SpriteAssetId` to an atlas texture
  and source rectangle.
- `DataSystem` stores only stable sprite asset IDs as persistent entity component
  data. It may keep those component rows dense, but it must not store
  `TextureId`, `TextureLease`, prepared sprite records, SDL_mixer handles, or
  loaded audio handles.
- Runtime gameplay and render prep should use stable asset IDs, not string
  paths. Path validation, PNG decode, GPU upload, audio load/predecode, and
  string/hash lookup stay out of fixed update and hot render paths.
- Missing declared assets are logged and exposed as unavailable handles;
  allocation failures, invalid config, and SDL/GPU/audio service initialization
  failures still return errors.
- A dedicated loading state is future work for larger asset sets, streamed
  content, or visible progress. This slice keeps startup preload in `Engine.init`
  but should keep enough catalog status to let a later loading state report
  loaded, missing, and unavailable assets without changing ownership.

Checklist:

- [x] Add a typed startup asset manifest with stable sprite and audio IDs.
- [x] Add Engine-owned `RuntimeAssets` that preloads declared sprite/image
      assets during `Engine.init`, owns their texture leases, and releases them
      before renderer teardown.
- [x] Add audio preload support so declared music and SFX IDs resolve to loaded
      `AudioService` handles without path lookup during command drain.
- [x] Change render-facing code to resolve `SpriteAssetId` through
      `RuntimeAssets` instead of acquiring textures by relative path.
- [x] Change audio commands to carry `AudioAssetId` instead of copied relative
      paths.
- [x] Change `DataSystem` asset-reference component data from relative paths to
      stable `SpriteAssetId` values.
- [x] Add the first demo sprite asset under `assets/sprites/` and assign sprite
      IDs to player, AI squares, and obstacles.
- [x] Update render-facing demo code so deterministic entity drawing resolves
      sprite IDs through `RuntimeAssets` with primitive fallback for unavailable
      sprite IDs.
- [x] Update architecture and rendering/assets docs to describe startup preload,
      stable IDs, missing-asset behavior, and atlas-ready source rectangles.

Acceptance checks:

- [x] Engine startup attempts to preload every declared sprite and audio asset
      once.
- [x] Missing declared content logs once, marks the asset unavailable, and does
      not abort app initialization.
- [x] Gameplay state, render-facing drawing, and audio commands use stable asset
      IDs rather than runtime string paths.
- [x] `DataSystem` contains no live renderer texture IDs, texture leases,
      prepared sprite records, SDL_mixer handles, or loaded audio handles.
- [x] Render-facing drawing resolves `SpriteAssetId` to
      `{ texture, source_rect }` and preserves deterministic draw ordering.
- [x] Future atlas mapping can change the catalog resolution without changing
      entity component storage.
- [x] `zig build fmt`, `zig build test`, `zig build check`, and
      `zig build verify` pass.
- [x] Manual `zig build dev` smoke confirms menu, gameplay, sprite rendering,
      audio, pause, debug overlay, and repeated transitions still work.

Slice 17 lands the startup runtime asset catalog. `Engine` now preloads the
manifest-declared demo sprite and audio set, gameplay stores stable sprite IDs,
rendering resolves IDs through `RuntimeAssets` with primitive fallback, and
audio commands drain by preloaded `AudioAssetId` instead of copied paths. The
catalog release path uses the live cache/renderer owner rather than
self-releasing lease pointers. Manual `zig build dev` validation confirmed menu,
gameplay, sprite rendering, audio, pause, debug overlay, and repeated
transitions.

## Slice 18: Frame-Delayed Pathfinding System

Goal: add a state-owned, frame-delayed grid pathfinding system so AI and rule
processors can request navigation without blocking current-step movement or
storing solver queues, caches, or scratch data in `DataSystem`.

Current foundation:

- Slice 12 provides typed transient streams and deterministic merge points
  through `SimulationFrame`.
- Slice 14 provides AI processors that can emit movement intent and consume
  later-step navigation results without owning solver state.
- `PathfindingSystem` lives under `src/game/systems/` as a system, not a
  controller. It owns a static versioned nav grid, pending request queue,
  request dedupe, completed result cache, unavailable-path cache, connected
  components, portal data, warmed fixed scratch buffers, shared goal fields, and
  per-stage adaptive tuners.
- `SimulationFrame.path_requests` carries transient path requests from AI to the
  pathfinder. Results are frame-delayed so AI consumes completed paths on later
  fixed steps instead of blocking current-step movement on fresh solves.
- Common requests avoid heap A* through request/result caches, unavailable-key
  caches, shared goal fields, open-grid direct paths, disconnected-component
  rejection, line-of-sight paths, and portal detours.
- Regular batch work uses `src/core/simd.zig` for request key preparation and
  static-grid blocked rectangle marking. Branch-heavy A* frontier expansion
  remains scalar inside worker ranges.
- Benchmarks split common-goal field reuse, hot cache-hit profiles, and hard
  fallback profiles. Cache profiles report `cache_hits`; hard fallback profiles
  report `fallback_requests` so regressions do not hide behind aggregate timing.

Architecture notes:

- Persistent gameplay facts stay in `DataSystem`; solver queues, caches,
  scratch buffers, nav-grid topology, and tuner state stay in the state-owned
  pathfinding system.
- Pathfinding uses read-only navigation snapshots during worker jobs and merges
  results deterministically before AI, movement, or response systems consume
  them.
- Adaptive tuning belongs to the actual work stage being measured. Shared goal
  field construction, fallback solves, and result emission should each either
  stay inline by design or use the tuner that measures that exact batch shape.
- Heap A* is a bounded fallback path, not the expected per-frame path for common
  requests. Hard true-A* fixtures and solve budgets remain a future hardening
  track.

Checklist:

- [x] Add typed path requests and completed path results through
      `SimulationFrame`.
- [x] Add a state-owned `PathfindingSystem` under `src/game/systems/` and wire
      it into fixed-step gameplay order after AI request emission.
- [x] Keep solver state, warmed scratch buffers, caches, and adaptive tuners out
      of `DataSystem`.
- [x] Add request/result cache hits, unavailable-path caching, request dedupe,
      and pending-request dedupe so repeat work stays cheap.
- [x] Add shared goal fields and regular-batch SIMD where the data shape is
      suitable.
- [x] Add fast paths for direct open-grid paths, unreachable component rejects,
      line-of-sight paths, and portal detours before heap A* fallback.
- [x] Add deterministic serial, fixed-thread, and adaptive benchmarks for common
      field reuse, hot cache-shaped workloads, and hard fallback workloads with
      visible cache/fallback counters.
- [x] Add tests covering deterministic results, cache behavior, no hot-loop heap
      allocation in steady-state paths, unavailable requests, and serial versus
      threaded consistency.

Acceptance checks:

- [x] AI can request paths without blocking the current fixed-step movement
      integration on a fresh solve.
- [x] Pathfinding is modeled as a gameplay system over typed data and transient
      requests, not as a persistent gameplay-state owner.
- [x] Repeated, unavailable, open-grid, detour, and shared-goal requests use
      cheaper paths before heap A*.
- [x] Adaptive and threaded runs are benchmarked against serial runs with
      fallback counters visible.
- [x] Debug and ReleaseFast 1024-request benchmarks cover open unique, detour,
      and unreachable fixtures; all report zero fallback requests for the fast
      fixtures after the fixture correction.
- [x] `zig build test --summary all`, `zig build check`, `zig build verify`, and
      `git diff --check` pass for the pathfinding implementation.

Slice 18 lands the navigation substrate. It gives AI and future rule systems a
deterministic, frame-delayed path request/result boundary with caches, fixed
scratch, SIMD-friendly batch work, and adaptive thread-system scheduling. It
does not by itself make NPC behavior immersive; steering, avoidance, perception,
and behavior arbitration remain the next gameplay layers.

## Slice 19: Steering And Local Avoidance

Goal: turn pathfinding results into smoother NPC movement by adding local
steering, avoidance, and stuck/replan policy above the pathfinder without moving
that transient behavior into `DataSystem`.

Current foundation:

- Slice 14 AI processing provides deterministic AI decision output; Slice 19
  routes that output through navigation intents before final steering movement.
- Slice 18 pathfinding can provide frame-delayed path waypoints and unavailable
  results.
- Slice 13 collision contacts and spatial-query foundations provide the data
  shape needed for local crowd and obstacle decisions.
- `SteeringSystem` consumes high-level navigation intents, pathfinding status,
  dense steering components, movement slices, and static obstacle data, then
  emits final NPC movement intents through deterministic threaded range writes
  after main-thread path/status preparation.

Architecture notes:

- Steering should be a system or state-owned feature controller that consumes
  path results and typed SoA views, then emits movement intents or rule outputs.
- Persistent tuning data such as agent radius, desired speed, or avoidance class
  may live in dense `DataSystem` components. Per-step neighbor lists, waypoint
  cursors, avoidance scratch, and replan queues should stay transient or
  state-owned.
- Avoidance and steering benchmarks should measure the processor cost directly
  rather than masking it behind the pathfinding benchmark.

Checklist:

- [x] Add path-following state needed to turn completed paths into movement
      intents.
- [x] Add local obstacle and agent avoidance using bounded fixed scratch.
- [x] Add stuck detection, replan cooldowns, and unavailable-path backoff.
- [x] Define arbitration between player input, AI steering, collision response,
      and future rule outputs.
- [x] Add deterministic tests for waypoint following, avoidance ordering, replan
      backoff, and no steady-state hot-loop allocation.
- [x] Add steering/local-avoidance benchmarks that report agent count, bounded
      avoidance checks, accepted samples, intents emitted, and threaded/adaptive
      detail where used.

Acceptance checks:

- [x] NPCs can follow path waypoints without sharp frame-to-frame oscillation.
- [x] Nearby NPCs and static obstacles are avoided through bounded local work.
- [x] Unavailable or stale paths do not cause per-frame re-request loops.
- [x] Steering outputs compose through typed movement intents or rule outputs
      with deterministic order.
- [x] `zig build fmt`, `zig build test`, `zig build check`, `zig build verify`,
      and `zig build bench -- --profile quick --group steering --details` pass.

Slice 19 lands steering as a separate gameplay processor. AI now emits
`NavigationIntent` goals, `SteeringSystem` owns runtime steering rows,
path-request cooldown/backoff, local avoidance scratch, deterministic priority
arbitration, and threaded final movement-intent emission. Only the steering
stage writes final NPC `MovementIntent`s. Player movement remains direct input,
and collision response still resolves after movement.

## Slice 20: Navigation Hardening And Hard-Path Budgets

Goal: keep rare true-A* and complex-map navigation costs bounded, tested, and
visible so pathfinding remains a stable gameplay foundation as map and NPC
counts grow.

Current foundation:

- Slice 18 benchmark profiles expose common fast paths and fallback counters.
- Pathfinding stats already distinguish field requests, cache hits,
  unavailable-path cache hits, and fallback requests.

Architecture notes:

- Benchmarks should distinguish common-path throughput from true hard-path
  fallback costs. A slow fallback should be treated as a visible budget decision,
  not hidden by aggregate adaptive numbers.
- Solve budgets should prefer deterministic deferral over unbounded same-frame
  work. If the pathfinder cannot finish all fallback work inside the budget, it
  should report pending work explicitly.
- Module splitting is justified only if it improves maintainability without
  weakening the system boundary. The pathfinder should remain a system, not a
  controller that owns gameplay state.

Checklist:

- [ ] Add true-A*-required fixtures that cannot be solved by direct, field,
      component, or portal fast paths.
- [ ] Add per-frame fallback solve budgets and deterministic pending/deferred
      behavior for overflow work.
- [ ] Add cache, goal-field, and unavailable-entry aging or capacity tests if
      long-running sessions need eviction.
- [ ] Add regression thresholds or benchmark callouts for Debug and ReleaseFast
      hard-path workloads.
- [ ] Audit heap use and scratch sizing for worst-case fallback fixtures.
- [ ] Consider splitting solver internals into smaller files once hard-path
      contracts are stable.

Acceptance checks:

- [ ] Benchmarks report true fallback count and timing separately from fast-path
      work.
- [ ] Unreachable or impossible destinations are rejected once and cached rather
      than re-solved every frame.
- [ ] Fallback overflow defers deterministically instead of stalling the fixed
      update.
- [ ] Hard-path changes cannot silently regress common request throughput.

## Slice 21: Typed Simulation Event System And Domain Signals

Goal: add a deterministic, typed simulation event layer that lets future
gameplay/domain systems communicate important system changes and interactions,
including tile, pathfinding, AI, obstacle, weather, combat, spawning, rules, and
resource changes, without introducing a global pub/sub bus, hidden persistent
state, or hot-path dynamic dispatch.

Current foundation:

- Slice 12 already provides `SimulationFrame`, typed transient streams,
  `RangeOutputStream(T)`, deterministic range-index merge, and deferred
  structural command boundaries.
- Collision, AI, steering, and pathfinding already use specialized typed
  streams for high-volume or latency-sensitive outputs: contacts, navigation
  intents, movement intents, path requests, and structural commands.
- The roadmap now points toward a state-owned `SimulationPipeline` as the owner
  of ordered gameplay phases and lightweight domain controller composition.
- `DataSystem` is the persistent gameplay-fact owner; transient event, request,
  scratch, queue, and service state stay outside persistent component storage.

Architecture notes:

- Map this feature to the intended simulation structure explicitly:
  `StateStack` dispatches states; a gameplay state owns `DataSystem`,
  `SimulationFrame`, and, when shared orchestration is needed, a
  `SimulationPipeline`; the pipeline owns event phases and domain-controller
  order; controllers consume typed event slices and decide reactions;
  processors do hot SoA work and emit typed outputs; `DataSystem` stores
  persistent facts; `SimulationFrame` stores this-step communication.
- Use events to communicate that something important changed or that a later
  stage should consider a request. Use `DataSystem` to store what remains true
  after the step. Use controllers to decide how domains react. Use processors
  for scalable data work. Use deferred commands for structural mutation.
- The event layer should be state-owned and tied to the `SimulationPipeline` for
  one gameplay state instance. It is not an app service, global singleton,
  reflection system, string-topic dispatcher, callback chain, or dynamic
  dependency graph.
- Events communicate domain or system changes that happened this step, or
  requests that a later fixed stage should consider. Persistent facts such as
  tile state, obstacle occupancy, weather fields, faction state, resources,
  actor components, or long-lived rule state still live in `DataSystem` or
  state-owned domain storage.
- Prefer explicit typed event unions or typed event channels with stable IDs:
  examples include `TileChanged`, `ObstacleChanged`, `WeatherChanged`,
  `NavRegionInvalidated`, `PerceptionStimulus`, `NoiseEmitted`,
  `InteractionRequested`, `DamageRequested`, and `SpawnRequested`.
- Keep existing high-volume streams specialized. Collision contacts, movement
  intents, navigation intents, path requests, and render-prep outputs should not
  be collapsed into one generic simulation-event stream just for uniformity.
- Threaded producers must use the same count/prefix/write/range-index merge
  model as other `SimulationFrame` streams. Output order must come from stable
  phase, input, range, and per-range sequence order, not worker timing.
- The pipeline owns event reaction order. Controllers consume immutable event
  slices in explicit stages, may emit typed requests or deferred structural
  commands, and may schedule next-step work in controller-owned queues when a
  response cannot safely happen in the same fixed step.
- Avoid recursive event storms. If consuming one event emits more events, the
  design must name the next event phase or defer to the next fixed step instead
  of allowing unbounded immediate redispatch.
- Events must carry stable IDs, scalar data, enum tags, compact coordinates,
  and small value payloads only. Do not store pointers, renderer/audio/SDL
  handles, asset paths, loaded resources, allocators, or service references in
  event payloads.
- Simulation-event diagnostics should expose counts by type and
  producer/controller stage. Logging individual events in hot paths is not
  acceptable outside targeted debug tooling.

Checklist:

- [ ] Define `SimulationEvent` extensions and/or typed event channels with
      concrete payloads for the first cross-system domains needed by tiles,
      obstacles, pathfinding invalidation, AI perception, weather interaction,
      combat, spawning, resource changes, or other system-change signals.
- [ ] Add a state-owned event collection API under the simulation/pipeline
      boundary, reusing `RangeOutputStream` or an equivalent typed
      count/prefix/write collector.
- [ ] Define pipeline event phases: producer stages, merge points, controller
      reaction order, derived-event policy, and next-step deferral policy.
- [ ] Add domain-controller integration points so controllers can consume
      immutable event slices and emit typed outputs, requests, or deferred
      structural commands without owning persistent entity/component facts.
- [ ] Add capacity and reserve policy for event channels, including behavior
      when a low-priority event channel exceeds its per-step budget.
- [ ] Add event stats with per-type counts, dropped/deferred counts where
      applicable, and stage/controller attribution for benchmarks or debug UI.
- [ ] Document which cross-system communication should use simulation/domain
      events and which should remain a specialized stream such as contacts,
      movement intents, navigation intents, path requests, render prep, or
      structural commands.
- [ ] Document the architecture mapping for event producers and consumers:
      pipeline phase, controller owner, persistent data owner, transient event
      stream, processor outputs, and deferred mutation point.

Acceptance checks:

- [ ] Replaying the same initial `DataSystem`, controller state, fixed-step
      inputs, and worker split decisions produces the same event order and same
      downstream outputs.
- [ ] Threaded producers merge events deterministically by stable range order,
      never by worker completion order.
- [ ] Event consumption cannot mutate `DataSystem` structurally except through
      deferred structural commands applied at the pipeline commit point.
- [ ] Event payload tests reject or avoid pointers, app/render/audio handles,
      asset paths, allocator references, and other non-stable runtime state.
- [ ] Capacity tests cover reserve, overflow, drop/defer policy, and
      no-allocation warmed event production.
- [ ] Benchmarks or debug stats can show event counts by type/stage so weather,
      tile, obstacle, AI, and navigation interactions do not become invisible
      fixed-step cost.

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
14. First AI intent processor and future rule contracts.
15. SDL3_mixer audio service.
16. Main menu and settings menu.
17. Startup runtime asset catalog.
18. Frame-delayed pathfinding system.
19. Steering and local avoidance.
20. Navigation hardening and hard-path budgets.
21. Typed simulation event system and domain signals.

This order records the dependency path used to build the current project
foundation. Current work should be chosen from Next Priority Tracks above.
Resource ownership, text/UI, renderer composition, threading, SIMD,
`DataSystem`, simulation outputs, collision, AI intent processing, audio, menus,
startup runtime assets, and frame-delayed pathfinding now form the
source-of-truth foundation for future slices. Steering/local avoidance and
navigation hardening are the next navigation-focused gameplay candidates. Typed
simulation/domain events should land before broad tile, weather, obstacle,
perception, combat, spawning, resource, and rule-system interactions depend on
cross-system communication.
