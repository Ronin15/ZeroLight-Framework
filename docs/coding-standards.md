# Coding Standards

This document is the canonical source for code style, performance, comments,
tests, and generated-output rules. `AGENTS.md` points here so future agents
treat these as repo standards, not optional style notes.

## Zig Style

Follow `zig fmt`; use 4-space indentation and avoid manual alignment that the
formatter will rewrite. Use lowerCamelCase for variables and functions,
PascalCase for types, and short descriptive names. Keep error sets explicit
when practical, as in `error{SdlError}`.

Prefer direct declaration imports for project types and constants when that
keeps call sites clear, such as `const Engine = @import("app/engine.zig").Engine;`
or `const ThreadSystem = @import("app/thread_system.zig").ThreadSystem;`. Use a
concise lowerCamelCase file namespace only when the call site is clearer as a
function or namespace lookup, such as `inputFile.actionForKey(...)` or
`assets.validateRelativePath(...)`.

Avoid `_mod` suffixes, `const Type = file.Type` bridge aliases, and double names
such as `thread.ThreadSystem`. Do not rewrite SDL/C symbols, generated
build-option names, or `std.Build` field names.

Keep `Renderer` as the render facade for app/game code. Do not import
`src/render/gpu/*` outside the render/platform boundary.

## Performance

Treat performance as part of correctness for fixed-step update, input dispatch,
render submission, asset lookup, text/debug overlay, and other hot or
frame-adjacent paths.

Hot paths must be allocation-free after initialization, reserve, or warmup.
Exceptions require an explicit owner, a measured and bounded cost, and a clear
reason the allocation cannot move to initialization, loading, state transition,
reserve/warmup, or another cold boundary.

Avoid per-frame, per-event, per-draw, or per-processor-loop string lookup,
hash-map dispatch, broad dynamic dispatch, callback chains, repeated descriptor
validation, formatted logging, and resource churn unless the cost is measured,
bounded, and intentionally isolated.

Prefer enums, bitsets, arrays, slices, direct indices, ring buffers, prepared
resources, stable asset IDs, and generational handles for runtime dispatch and
lookup.

Runtime gameplay and render-prep data should store stable IDs such as
`SpriteAssetId` and `AudioAssetId`, not string paths, `TextureId`,
`TextureLease`, prepared sprite records, SDL_mixer handles, loaded audio
handles, or renderer-owned resources in persistent `DataSystem` storage.

Keep fixed-step simulation separate from visible render cadence. Do not add
broad frame-rate caps that hide timing problems or harm high-refresh rendering
unless the cap preserves a named boundary and is measured.

Threaded/SIMD processors should iterate dense SoA columns directly. Component
masks are for membership/query decisions, not a replacement for direct slice
iteration in hot processors. Worker ranges should write disjoint rows and avoid
sharing writable cache lines in hot SoA columns.

### Dense SoA storage (`std.MultiArrayList`)

Prefer `std.MultiArrayList` when several columns grow, shrink, append, or
swap-remove **together** as one logical row. This is the default for persistent
`DataSystem` component stores, state-owned dense pools (for example
`ParticleSystem`), and per-step gather/scratch buffers built by parallel
`appendAssumeCapacity` across matching lengths (collision proxies, AI gather
rows, steering selected-work columns, collision-response intent rows).

Pattern:

- Define a row struct with one field per column (`MovementBodyRow`,
  `ProxyRow`, `AiGatherRow`, and similar).
- Store `rows: std.MultiArrayList(Row)`; expose hot paths through `slice()` /
  `sliceConst()` helpers that return the existing column-slice structs
  (`ConstMovementBodySlice`, `ParticleSlice`, and similar).
- Reserve with `rows.ensureTotalCapacity(allocator, hotStoreCapacity(n))` where
  hot threading/SIMD ranges need item alignment (`alignItemCount` from
  `thread_system.zig`).
- Emit or gather with one `rows.appendAssumeCapacity(row)` (or `set`) per row,
  not N separate column appends.
- Compact with `rows.swapRemove(index)` when unordered removal is acceptable.

Do **not** migrate to MAL when the layout is intentionally different:

- Hot/cold column splits for cache behavior (for example pathfinding result-cache
  probe slots vs cold payloads).
- Striped or arena buffers (`capacity × stride`) that are not one row per index.
- Thread range slots with cache-line padding to avoid false sharing.
- Spatial hash grids (`cell_entries` + `cell_ranges`), pair/contact output
  streams, or single `ArrayList(Struct)` pools where rows are already AoS.
- Sparse slot maps (`EntitySlot` lookup tables) that are not dense SoA.

Hot-path rules for MAL (mandatory):

- Call `rows.slice()` **once** per stage or function, then reuse column slices
  (`const ages = s.items(.age)`). Never call `rows.items(.field)` inside a loop;
  each call rebuilds slice pointers and has caused large regressions in Debug
  and Release.
- Publish hot float column types as plain `[]f32` / `[]const f32`. Do not
  require `[]align(64) f32` on MAL column slices; MAL does not guarantee
  64-byte column bases. Range alignment (16 items) is for threading chunk
  boundaries; explicit wide memory loads may need separate alignment planning.
- Keep `deinit`, `clearRetainingCapacity`, and capacity helpers on the owning
  store — one MAL replaces many parallel `deinit` / `ensureTotalCapacity` calls.

All vector operations and named math operations go through `core`:
`src/core/simd.zig` for vector types/ops and `src/core/math.zig` for reusable
scalar/vector math. This is unconditional and independent of how domain-specific
the calling system is — it keeps the math tested once and SIMD use consistent
(one lane width, no divergent copies). Do not declare raw `@Vector` in a system
or hand-roll a named primitive inline (gather/scatter, reciprocal/inverse sqrt,
length/normalize, trig, interpolation, clamp/saturating conversions, and the
like); if one is missing, add it to `core` with scalar-vs-SIMD parity tests and
keep the scalar and SIMD forms paired. A one-system composite kernel may stay in
its system, but assemble it from `core` primitives. Plain operator arithmetic
(`+ - * /`, including on the `simd` vector types) is fine inline — the rule
targets raw `@Vector` and named primitives, not basic arithmetic.

Apply SIMD with scale in mind. Use the `src/core/simd.zig` helpers for dense,
uniform, branch-light float math over contiguous SoA columns, always with a
scalar tail — this is the pattern in movement, collision broadphase/narrowphase,
collision response, particle integration, and the pathfinding flow field. MAL
column slices are contiguous SoA; prefer codegen-friendly scalar-to-`@Vector`
loads in `simd.zig` unless a target-specific aligned load is measured and owned.

This framework is built to scale to heavy scenes,
large battles, and late-game worlds, where per-agent and per-neighbor work
(AI decision, separation, steering avoidance) becomes the dominant cost. Do not
dismiss those loops as "low count" — assess them at their target scale, not their
current demo scale.

Vectorizability is a property of data layout, not an inherent property of a
system. A loop that is hard to vectorize today because it gathers from sparse
indices or branches per element is usually a candidate to *restructure* so it
becomes vectorizable: gather neighbor/contact data once into a packed local SoA
scratch buffer, then run the distance / inverse-sqrt / normalize / accumulate
math vectorized across lanes, and convert per-element branches into masked
`select`. At high element counts the one-time gather is amortized and the lane
gain dominates. Treat such restructuring as the default plan for hot per-agent
math before accepting a scalar loop. Genuinely irreducible scalar cases remain
(data-dependent frontier traversal such as BFS/A* expansion, swap-remove
compaction, rare branch-heavy setup); leave those scalar and say why. When a hot
float loop is added or restructured, vectorize it through the shared helpers and
prove scalar/SIMD and serial/threaded parity in tests.

Use 64-byte padding only for concurrently written thread-shared records where
false sharing is a real risk. Do not pad cold entity slot metadata by default.

Keep state transitions, entity structural changes, SDL/GPU/audio calls, asset
loading, save/load streaming, renderer resource ownership, and mixer resource
ownership out of threaded SIMD processors unless an explicit deferred or
main-thread boundary is designed.

Production worker participation should be driven by measured batch timing and
structural constraints. Do not add static item-count floors for worker
participation as a substitute for stage-owned tuning.

## Logging

Route all runtime diagnostics through the central logger `src/core/logging.zig`
scoped loggers (`app`, `assets`, `audio`, `core`, `game`, `render`, `platform`,
`debug_overlay`, `perf`): `const log = @import("../core/logging.zig").render;`.
Never call `std.log`/`std.log.scoped(...)` directly or use `std.debug.print` for
engine/gameplay diagnostics (`std.debug.print` is for `src/benchmarks/` CLI
stdout only). `info`/`debug` for lifecycle/config/fallback, `warn` for recovered
degradation, `err` for real failures; keep pure helpers/validation log-free.

Hot and frame-adjacent paths carry no logging in release — a release binary has
zero per-frame/update/event/draw/entity/iteration log calls. Such instrumentation
must be comptime-gated so it compiles out to a zero-sized no-op, not skipped at
runtime; `src/app/runtime_perf_log.zig` is the reference (`enabled` folds
`builtin.mode == .Debug and logging.enabled(.debug)`, the type and its `Context`
go zero-sized when disabled, per-frame work is counter increments, and the
formatted emit runs once per interval in Debug only). `logging.enabled(level)` is
comptime, so gate any non-trivially-formatted diagnostic behind it — call and
formatting both drop when the level is off.

## Comments

Use comments to preserve contracts and non-obvious intent, not to narrate
straight-line code. Public exported declarations that form a cross-module API
should use Zig doc comments (`///`) immediately above the declaration when the
caller needs to understand ownership, lifetime, invariants, ordering,
threading, allocation behavior, failure behavior, or performance assumptions.

Use ordinary `//` comments for private helpers, implementation phase markers,
local invariants, hot-path rationale, and test fixture context. Put
declaration-level comments above the declaration they describe and local
implementation comments near the block they explain.

Avoid comments that merely repeat the identifier, describe obvious assignment,
carry stale roadmap intent, or make broad claims not enforced by code or tests.

## Tests

Use Zig `test` blocks and `std.testing`. Put reusable module tests beside the
code they cover, and name tests by behavior, such as
`test "player movement clamps to window bounds"`.

Prefer focused tests for contracts that do not require opening a window: input
routing, state policy flow, transition ordering, resource ID validation,
viewport math, descriptor validation, asset path validation, timing decisions,
and pure gameplay/data contracts. Keep display/GPU checks in `gpu-smoke`.

Production contracts must expose runtime concepts only. Do not add test-only
enum tags, union payloads, marker fields, fake stages, fixture hooks, service
shortcuts, or test-only paths to production APIs. Tests should use private
helper types, local fixtures, test-only mocks, or real runtime payloads without
changing the shape of app, game, render, asset, platform, or tool contracts.

## Generated Output And Configuration

`zig-out/` and `.zig-cache/` are generated output and should not be edited by
hand. Do not commit generated binaries or local machine paths.

If adding dependencies to `build.zig.zon`, keep hashes accurate and review the
fingerprint carefully because it affects project identity.
