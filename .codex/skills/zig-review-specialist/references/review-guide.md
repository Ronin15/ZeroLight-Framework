# Zig Game Engine Review Guide

## Severity Priorities

Start with issues that can cause wrong runtime behavior, crashes, leaks, undefined behavior, missed cleanup, broken build/test workflows, or performance regressions in hot paths. Style-only concerns belong last or should be omitted.

Use concrete severity judgment:

- High: crash, memory/resource leak, use-after-free, broken build, state corruption, broken input/update/render contract, GPU resource misuse, or visible gameplay regression.
- Medium: missing validation, stale handles, hidden allocation in per-frame paths, poor failure handling, incomplete tests for changed contracts, or ownership drift that will likely cause bugs.
- Low: local maintainability issue, unclear naming, small duplication, or documentation drift with limited behavioral risk.

## Zig-Specific Checks

- Allocator ownership is explicit; every allocation has a clear owner and cleanup path.
- `errdefer` protects partially initialized SDL/GPU resources.
- Pointers, `@ptrCast`, `@alignCast`, and `@intCast` have local justification through type or range checks.
- C strings passed to SDL are sentinel-terminated where required and live long enough.
- Error sets remain useful; errors are not swallowed in code paths where diagnosis matters.
- `defer` cleanup is close to the resource creation site where practical.

## Game Engine Checks

- Fixed update policy remains separate from render cadence.
- Pause, hidden/minimized/no-swapchain behavior does not advance gameplay invisibly.
- Input routing keeps held gameplay input separate from one-frame commands.
- State stack mutation happens through queued transitions or explicit stack APIs, not ad hoc ownership transfer.
- Lower states receive update/input/render only according to policy.
- Game code draws through renderer-facing APIs rather than owning raw SDL_GPU resources.
- When multiple game/effect/UI producers can interleave render depths, game code
  should emit transient records into `RenderQueue` or another explicit render-prep
  ordering phase. Flag ad hoc demo-local ordering lists and renderer-side
  fallback sorting that hides producer-order bugs.
- Shared gameplay orchestration stays state-owned: `StateStack` dispatches,
  gameplay states own `DataSystem`/`SimulationFrame`/pipeline instances, and
  pipelines own controller order.
- Domain controllers coordinate feature policy and handoff, but persistent
  gameplay/domain facts stay in `DataSystem` or state-owned domain storage.

## Simulation Event Checks

- Typed simulation/domain events are transient signals for important system
  changes, not persistent state and not a global app service.
- Event reaction order is explicit in the pipeline; consuming events must not
  cause unbounded immediate redispatch or recursive event storms.
- Event payloads use stable IDs, enums, compact coordinates, and small value
  payloads. Flag pointers, app/render/audio handles, asset paths, allocators,
  loaded resources, or service references in payloads.
- High-volume outputs remain specialized when appropriate: contacts, movement
  intents, navigation intents, path requests, render prep, and structural
  commands should not be collapsed into one generic event stream for uniformity.
- Threaded event producers use deterministic count/prefix/write/range-index
  merge, not worker-completion order or global per-command atomics.
- Event consumers own their reaction work instead of using the main thread as a
  generic dumping ground. This is the same project-wide rule used for app,
  gameplay, render-prep, asset, platform, and tooling work: inline main-thread
  work should be deliberately light or tied to an explicit ownership boundary;
  scalable work should have an owner and deterministic owned outputs.
- Production contracts should not include test-only stages, marker payloads,
  fixture variants, fake diagnostics, service shortcuts, or test-only paths.
  Tests should use private helper records, test-only mocks, or real production
  payloads.

## Rendering And Resource Checks

- Texture, shader, buffer, sampler, pipeline, transfer buffer, and device lifetimes are paired and ordered safely.
- Swapchain acquisition failure paths cancel or skip frame work deterministically.
- CPU render prep, draw-record ordering, and worker vertex expansion should not
  hold an acquired swapchain image unless the code has a narrow resize/revalidate
  reason. Flag `SDL_WaitAndAcquireGPUSwapchainTexture` before substantial CPU
  prep as latency and swapchain-pressure risk.
- Per-frame draw submission does not add avoidable allocation, string lookup, or hash-map lookup.
- Sprite ordering remains stable when render queue ordering or batching changes.
  `SpriteBatch` should consume ordered streams; it should not be the compatibility
  fallback sorter for unordered producers.
- Upload validation rejects bad dimensions, pitch, and buffer lengths before GPU work.
- Shader build changes preserve platform formats and installed runtime asset paths.

## Test Review Checks

Prefer tests that directly verify behavior: input routing, state policy, viewport math, resource ID validation, descriptor validation, player/gameplay movement, and pure timing decisions.

Do not require a display for unit tests. Treat GPU smoke and runnable window checks as separate validation with environmental prerequisites.

Do not let test convenience shape production contracts in any subsystem. Flag
test-only enum tags, union payloads, marker fields, fake stages, fixture-only
service hooks, service shortcuts, or test-only paths in production code; prefer
private test helper types, local fixtures, test-only mocks, or real runtime
payloads.

When tests are weak, say exactly what contract remains untested and give a narrow scenario that would expose the bug.

## Diagnostics Checks

New features and roadmap slices should add scoped `std.log` diagnostics where they help operate or debug the feature. Debug logs may cover low-frequency lifecycle, configuration, fallback, and failure context. Avoid routine per-frame, per-event, or per-draw formatting unless the diagnostic value is clear and the impact is minimal. Keep `warn` for recovered degraded behavior, `err` for real failure context, and pure helper/validation functions log-free unless they are runtime wrappers.
