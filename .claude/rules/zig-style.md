---
paths:
  - "**/*.zig"
  - "**/*.zon"
---

# Zig Style, Errors, Comments, Logging

## Style

- Follow `zig fmt`: camelCase callables; snake_case variables, fields
  (function-pointer fields included), enum members, and non-type constants;
  PascalCase types and type-returning functions.
- Write the plain form first: names that say what a value is (`corridor`, not
  `i`), arithmetic over bit tricks, named helpers over inline tuple arrays. A
  clever form needs a bench-shown hot-path win and a one-line comment. SIMD
  through `simd.zig` is the default form for hot loops, not a clever one
  (`memory-performance.md` § SIMD).
- Import declarations directly
  (`const Engine = @import("app/engine.zig").Engine;`), or a snake_case file
  namespace where the call reads better.
- No `_mod` suffixes, bridge aliases (`const Type = file.Type`), or double names
  (`thread.ThreadSystem`); never rename SDL/C, build-option, or `std.Build`
  names.
- Current spellings (`idiom-lint` enforces most):
  - `std.ArrayList` (unmanaged, `.empty`), never `std.ArrayListUnmanaged` or
    managed constructors.
  - `@backingInt`/`@fromBackingInt`, not `@intFromEnum`/`@enumFromInt`.
  - `@splat(x)`, not `**`; `@memcpy`/`@memset`, not `std.mem.copy`/`set`.
  - `@typeInfo(T).<kind>.field_names`/`field_types` or `std.meta.tags(E)`, not
    `std.meta.fields`.
  - `dupeSentinel(u8, bytes, 0)`, not `dupeZ`; `std.builtin.Optimize`, not
    `OptimizeMode`.
  - `build.zig`'s TranslateC step, never `@cImport`; the shared `sdl_c` module
    is the only C namespace for SDL headers.
  - `std.math.isNan(x)`, `EntityId.eql`, and `try`, not `x != x`, a free
    equality helper, or `catch |e| return e`.
  - No `usingnamespace`, `std.BoundedArray`, or `kCamel` constants.
- Never gate a hook on `@hasDecl` (0.17 sees only `pub` decls); make it
  required and call it unconditionally.
- Remove callerless `pub` helpers and any `pub` export whose doc asserts a
  contract nothing references.

## Errors and resources

- Keep error sets explicit (`error{SdlError}`), except `*anyopaque` +
  `anyerror!T` vtables at cold type-erased service boundaries (`state.zig`,
  `audio.zig`, `cache.zig`).
- Never swallow an error where diagnosis matters. Advance edge/latch state only
  on the success path (`enqueue(...) catch return; latch = true;`); otherwise it
  desyncs from the engine.
- Pair every SDL/GPU/audio resource creation with its cleanup at the owning
  site, `errdefer` partial initialization, and keep `defer` next to creation.
- `@ptrCast`/`@alignCast`/`@intCast` carry a local type or range justification.
- C strings passed to SDL are sentinel-terminated and outlive the call.
- A config field whose zero is a valid domain value (`TileId` 0 is a real
  tile) defaults to the domain's invalid sentinel (`maxInt`) and is
  assert-resolved at the use boundary.
- A validator bounds each scalar on both ends where its siblings do; a
  present-but-wrong-typed optional field is an error, not absent.

## Comments

- Comments preserve contracts and non-obvious intent; never narrate
  straight-line code or repeat the identifier.
- Cross-module public declarations get `///` when the caller needs ownership,
  lifetime, invariants, ordering, threading, allocation, failure, or
  performance assumptions. Use `//` for private helpers, phase markers, local
  invariants, hot-path rationale, and fixture context.
- Keep each comment as short as its contract: the invariant and, when
  non-obvious, one reason. Proofs, worked arithmetic, rejected alternatives,
  and history go in the commit message.
- Comments describe the code they sit on and nothing else: no roadmap or slice
  references, review tags, history, process notes, or pointers to docs and rule
  files; no broad claims not enforced by code or tests; describe content by its
  role (walkable, blocking), never by a specific art asset.

## Logging

- Route runtime diagnostics through `src/core/logging.zig` scoped loggers
  (`app`, `assets`, `audio`, `core`, `game`, `render`, `platform`,
  `debug_overlay`, `perf`): `const log = @import("../core/logging.zig").render;`.
- Never call `std.log`/`std.log.scoped(...)` directly; `std.debug.print` is for
  `src/benchmarks/` CLI stdout only.
- `info`/`debug` for lifecycle, config, and fallback; `warn` for recovered
  degradation; `err` for real failures. Pure helpers and validation stay
  log-free.
- Shipping builds (`ReleaseFast`/`ReleaseSmall`) do zero per-frame, update,
  event, draw, entity, or iteration log or perf-counter work: instrumentation
  is comptime-gated to a zero-sized no-op (reference:
  `src/app/runtime_perf_log.zig`). Gate any non-trivially formatted diagnostic
  behind `logging.enabled(level)`.
- A new growth or drop counter logs once through a scoped logger; its once-only
  flag lives on the owning system, never global.
