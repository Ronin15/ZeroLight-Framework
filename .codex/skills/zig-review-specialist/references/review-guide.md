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

## Rendering And Resource Checks

- Texture, shader, buffer, sampler, pipeline, transfer buffer, and device lifetimes are paired and ordered safely.
- Swapchain acquisition failure paths cancel or skip frame work deterministically.
- Per-frame draw submission does not add avoidable allocation, string lookup, or hash-map lookup.
- Sprite ordering remains stable when sorting or batching changes.
- Upload validation rejects bad dimensions, pitch, and buffer lengths before GPU work.
- Shader build changes preserve platform formats and installed runtime asset paths.

## Test Review Checks

Prefer tests that directly verify behavior: input routing, state policy, viewport math, resource ID validation, descriptor validation, player/gameplay movement, and pure timing decisions.

Do not require a display for unit tests. Treat GPU smoke and runnable window checks as separate validation with environmental prerequisites.

When tests are weak, say exactly what contract remains untested and give a narrow scenario that would expose the bug.

## Diagnostics Checks

New features and roadmap slices should add scoped `std.log` diagnostics where they help operate or debug the feature. Debug logs may cover low-frequency lifecycle, configuration, fallback, and failure context. Avoid routine per-frame, per-event, or per-draw formatting unless the diagnostic value is clear and the impact is minimal. Keep `warn` for recovered degraded behavior, `err` for real failure context, and pure helper/validation functions log-free unless they are runtime wrappers.
