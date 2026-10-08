# Coding Standards

The canonical source for every technical rule. `CLAUDE.md`, the agent files,
the workflows, and the roadmap point here by section name and do not restate
these rules.

## Zig Style

- Follow `zig fmt`: camelCase callables; snake_case variables, fields, enum
  members, and non-type constants; PascalCase types and type-returning
  functions.
- Write the plain form first in all code: names that say what a value is
  (`corridor`, not `i`), arithmetic over bit tricks, named helpers over inline
  tuple arrays; a clever form needs a bench-shown hot-path win and a one-line
  comment.
- Keep error sets explicit (`error{SdlError}`), except `*anyopaque` +
  `anyerror!T` vtables at cold type-erased service boundaries.
- Import declarations directly
  (`const Engine = @import("app/engine.zig").Engine;`), or a snake_case file
  namespace where the call reads better.
- No `_mod` suffixes, bridge aliases (`const Type = file.Type`), or double
  names (`thread.ThreadSystem`); never rename SDL/C, build-option, or
  `std.Build` names.
- Use current spellings:
  - `std.ArrayList` (unmanaged, `.empty`), not `std.ArrayListUnmanaged` or
    managed constructors.
  - `@backingInt`/`@fromBackingInt`, not `@intFromEnum`/`@enumFromInt`.
  - `@splat(x)`, not `**`.
  - `@typeInfo(T).<kind>.field_names`/`field_types` or `std.meta.tags(E)`, not
    `std.meta.fields`.
  - `dupeSentinel(u8, bytes, 0)`, not `dupeZ`; `std.builtin.Optimize`, not
    `OptimizeMode`.
  - `build.zig`'s TranslateC step, never `@cImport`.
  - `std.math.isNan(x)`, `EntityId.eql`, and `try`, not `x != x`, a free
    equality helper, or `catch |e| return e`.
- Fn-pointer fields are snake_case like the production vtables (lint-exempt, so
  review catches it).
- Never gate a hook on `@hasDecl` (0.17 sees only `pub` decls); make it
  required and call it unconditionally.
- App/game code uses `Renderer`; never import `src/render/gpu/*` outside
  render/platform.

## Performance

Performance is correctness on hot and frame-adjacent paths (fixed-step update,
input dispatch, render submission, asset lookup, text/debug overlay). Hot paths
are allocation-free after init, reserve, or warmup; an exception needs an owner,
a measured bounded cost, and a reason it cannot move to init, load, a state
transition, reserve/warmup, or another cold boundary.

### Allocator Discipline

- Every `reserve`/`ensureTotalCapacity` + `assumeCapacity` (or
  `addOneAssumeCapacity`) pairing ships in the same change with a
  `std.testing.FailingAllocator` test proving the warmed hot path allocates
  nothing; ReleaseFast strips the assert, so a comment is not proof.
- With reserve and commit in separate functions, the proof covers the success
  branch: reserve, arm the allocator to fail, assert the push completes.
- Threaded paths add a proof rule ([Threading](#threading)).
- Behavior gates compare a stored logical limit, never physical `.capacity`;
  assign the limit only after its reserve succeeds and
  `std.debug.assert(list.capacity >= limit)`.
- A `.capacity` read that only picks `appendAssumeCapacity` vs `append` with
  identical results is not a gate.
- A pool backed by a separately reserved dedup/probe table gates appends on the
  shared logical cap and honors the probe's insert-bool.
- A reserve/overflow contract's assert and overflow check bound the same
  quantity.
- Use `unreachable`, `catch`/`orelse unreachable`, and `.?` only where the state
  is impossible by construction (capacity-bounded handle constructors such as
  `TextureId.init(...) catch unreachable`); recoverable or data-influenced
  failures return an error or assert.
- In hot or worker loops, capture an optional as a non-optional local at
  dispatch or assert it non-null at entry; never rely on cross-thread ordering.
- Widen signed spans to `i64`/`usize` before subtracting, clamp while wide, then
  `@intCast`.
- `idiom-lint` (in `verify`; `tools/lint_idioms.py`) rejects non-test
  `catch`/`orelse unreachable` unless on a sanctioned handle constructor or
  annotated `// lint:allow catch-unreachable: <reason>`; never annotate a
  recoverable failure, propagate it.
- The lint also enforces snake_case fields/parameters, `k_snake_case`
  constants, the [Zig Style](#zig-style) spellings, and no `@hasDecl`, and bans
  `usingnamespace`, `std.mem.copy`/`set`, and `std.BoundedArray`.
- Allocating structs take a `std.mem.Allocator` at `init` and store it
  immediately, never `undefined`.
- Never use `page_allocator`, `c_allocator`, or a fresh
  `GeneralPurposeAllocator` inside a function, even cold; thread the caller's (a
  local `ArenaAllocator` over it is fine).
- Register each `errdefer` right after its field is constructed, never a
  blanket `errdefer self.deinit()` before all fields exist.
- A caller's `defer` cleanup of an allocated container follows the fallible
  `init`, with a narrower `errdefer` before it.
- A function taking ownership of a by-value resource opens with
  `errdefer <res>.deinit()`.
- After ownership transfers (`put`, `append`, lease commit), disarm the earlier
  `errdefer` with a per-iteration bool.
- A handle-owning setter asserts its slot empty or closes the prior handle.

### Dispatch And Lookup

No per-frame, per-event, per-draw, or per-processor-loop string lookup,
hash-map dispatch, broad dynamic dispatch, callback chains, repeated descriptor
validation, formatted logging, or resource churn unless the cost is measured,
bounded, and isolated. Use enums, bitsets, arrays, slices, direct indices, ring
buffers, prepared resources, stable asset IDs, and generational handles.

### Timing And Frame Pacing

Keep fixed-step simulation separate from visible render cadence. Do not add
broad frame-rate caps that hide timing problems or harm high-refresh rendering
unless the cap preserves a named boundary and is measured.

### Dense SoA Storage

- Use `std.MultiArrayList` (MAL) when columns grow, shrink, and swap-remove
  together as one row: `DataSystem` stores, dense pools, and same-length
  per-step gather/scratch buffers.
- Keep intentionally different layouts off MAL: hot/cold splits, striped or
  arena buffers, padded range slots, spatial hash grids, pair streams, existing
  AoS pools, sparse slot maps.
- Store `rows: std.MultiArrayList(Row)` with one field per column and expose
  hot paths through `slice()`/`sliceConst()` column-slice helpers.
- Reserve with `hotStoreCapacity(n)` where threading/SIMD ranges need item
  alignment.
- Hot gather loops never call `appendAssumeCapacity` (use `appendMalRow`); a
  per-row store append uses a private `ensureCapacityForOne` +
  `appendAssumeCapacity`, never `ensureCapacity(n)` + `append`.
- Compact with `swapRemove` when order does not matter; keep `deinit`,
  `clearRetainingCapacity`, and capacity helpers on the owning store.
- Call `rows.slice()` once per stage, function, or accessor; never
  `rows.items(.field)` in a loop.
- Per-row helpers take const column slices from the caller and never call
  `.slice()`.
- Per-step gather loops capture `var row_slice = rows.slice()` once and append
  with:

```zig
fn appendMalRow(
    rows: *std.MultiArrayList(Row),
    row_slice: *std.MultiArrayList(Row).Slice,
    row: Row,
) void {
    _ = rows.addOneAssumeCapacity();
    row_slice.len = rows.len;
    row_slice.set(rows.len - 1, row);
}
```

- Publish hot float columns as `[]f32`, never `[]align(64) f32`; MAL does not
  guarantee aligned column bases.

### SIMD And Core Math

- All vector and named math goes through `src/core/simd.zig` and
  `src/core/math.zig`; plain operators are fine inline.
- Never declare raw `@Vector` in a system or hand-roll a named primitive
  (gather/scatter, inverse sqrt, normalize, trig, interpolation, clamp or
  saturating conversion).
- Add a missing primitive to `core` as a paired scalar and SIMD form with parity
  tests.
- A one-system kernel built from `core` primitives may stay local; promote it
  once reused.
- Use `simd.zig` helpers, with a scalar tail, for dense uniform float math over
  SoA columns; prefer scalar for tiny batches or simple logic.
- Prefer scalar-to-`@Vector` loads unless an aligned load is measured and
  owned.
- Judge per-agent and per-neighbor loops at target scale, never as "low
  count".
- Vectorize a gather-bound or branchy hot per-agent loop by gathering into
  packed local SoA scratch and masking branches with `select`.
- Leave scalar only irreducible loops (A*/BFS frontier, compaction, rare
  setup), stating why.
- A new or restructured hot float loop ships scalar/SIMD and serial/threaded
  parity tests.

## Budgets, Capacities, And Thresholds

- Size and bound for dense, multi-chunk terrain change in one step.
- A local change (one dig, ramp, or chunk) costs work proportional to what it
  changed, never to world width, depth, or world count. If shared storage would
  force a world-wide shift or rebuild, use per-level or paged storage.
- Everything is sized and stored per world instance; no global or cross-world
  caps or tables. A world's memory is released when it unloads.
- Per-step and per-query work budgets are fixed counts, never milliseconds and
  never derived from world, map, cell, or portal count or any measured scale.
- Over-budget work defers deterministically, tested as such (grep
  `independent of` / `regardless of world size`).
- Fix a chronically short budget with deterministic deferral, a bounded retry
  ladder, or a better algorithm, never a bigger number for one map.
- Capacities are right-sized per world instance, never one size for all.
- World-extent data (tiles, per-chunk nav, chunk tables) is sized exactly at
  load and never grown; dig/build changes contents, not extent.
- Runtime-growing data (population, items, nodes, links) starts at
  content-derived size plus headroom and grows only at the main-thread
  structural-commit seam, geometrically ahead of need, or uses paged storage.
- Growth on a hot path or in a threaded stage is a defect; between seams
  [Allocator Discipline](#allocator-discipline) applies.
- No order, deferral, refusal, or result depends on reserved capacity.
- No dig, build, cave-in, or explosion is ever refused for capacity.
- The only fixed caps are index/format widths (`u16`/`u32`, save/replay
  layouts) proven unreachable for the loaded world (failing loudly at load) and
  presentation-only pools no simulation reads (particles, text labels), with
  deterministic overflow drop.
- Load-time platform validation (GPU byte budget, `max_nav_memory_bytes`) runs
  once at load, fails loudly there, and never runs during play.
- Data outgrowing a load-time estimate grows at its seam; only allocator OOM
  fails it, as an ordinary error leaving state intact for retry.
- Heuristic thresholds derive from the cost of the operation they gate, never
  world size.
- Pick per structure as an engine programmer would: pools, free lists, and
  generational handles for churn; SoA contiguity over footprint; fixed caps only
  where they buy index width, a stable format, or a work bound.
- Never change a constant just to satisfy this section; default is keep.
- Changing a budget, capacity, or threshold states a concrete, measured benefit
  weighed against hot-path cost, format churn, proof churn, and determinism.

## Threading

- Work that scales runs through the thread system: across chunks and levels,
  and across world instances where they are independent.
- Multi-threaded writes go, verifiably at the call site, to disjoint per-worker
  or per-range slots, never a shared appendable collection.
- Reserve on the main thread strictly before dispatch, sized from the value the
  dispatch uses.
- Each worker job opens by asserting its write range against buffer length and
  `range.index` against the dispatched range count.
- The `FailingAllocator` proof exercises the real multi-worker `ThreadSystem`.
- Merged output is deterministic from range order (count, prefix offsets,
  write, range-index merge, batch commit), never worker timing, IDs, or global
  atomics.
- Call a batched `RangeOutputStream`/`SimulationEvents` `finishWrite` once per
  commit, after every range writes.
- A pass with at most one output per item writes its `[range.start, range.end)`
  window of one aligned item-capacity buffer, counting into a padded tally
  sized by `thread_system.maxRangeCount`; the main thread compacts or streams
  the windows in range order.
- Only data-dependent output (broadphase pairs) keeps per-range slots, reserved
  at the seam to the per-item bound times the most items any range can cover
  (never clamped to the total), with counted grow-and-replay on overflow.
- Events that are a pure function of worker-written row state are emitted by
  the main thread in row order after the join, with no event scratch.
- A partitioned processor with a capped event stream emits in canonical row and
  sub-kind order before the cap, with parity tests crossing event kinds across
  ranges plus a capped case.
- Hot loops iterate dense SoA columns; component masks are membership only,
  never dynamic joins.
- Worker ranges never share writable cache lines; pad to 64 bytes only shared
  records with real false-sharing risk.
- Keep state transitions, structural changes, SDL/GPU/audio, asset and save
  I/O, and resource ownership off workers unless a deferred boundary is
  designed.
- Workers never mutate `DataSystem` structurally; structural commits batch at
  the commit seam.
- The main thread is not a fallback owner: it holds only those boundaries and
  light orchestration.
- Work scaling with count, size, or complexity gets a named owner, with
  immutable inputs and deterministic owned outputs once it can get expensive.
- Work scaling with population, terrain change, or world size ships serial and
  threaded paths with parity tests in its first implementation.
- Small fixed or cold one-off work may stay serial; ask the owner if unsure.
- Multi-stage processors have per-stage tuners and visible timing stats.
- Worker participation follows measured timing and structural constraints,
  never static item-count floors.

## Simulation Pipeline Stage Ordering

- `SimulationPipeline.update()` is the only fixed-step scheduler; never add a
  second or promote it to a global ECS scheduler or app service.
- Stage order is comptime-enforced in `simulation_pipeline.zig`:
  `stageContract()` declares reads, writes, and carried inputs, `stage_order`
  permutes `StageId`, and reading an unwritten resource fails the build.
- `carried` is a value no earlier stage writes (pre-`update` input, world
  authoring, or next-step state from a later stage), disjoint from reads and
  writes; anything an earlier stage writes is a read.
- Event tags are distinct: `world_events` does not satisfy `perception_events`,
  `affect_events`, or `structural_events`.
- `structural_events` are commit-seam payloads outside the stage graph.
- A new or reordered stage adds, in one change, its `PipelineResource` tags
  (coarse, not one-off), `stage_order` position where its real dependencies
  require, `stageContract()` arm, and `runStage` arm.
- An ordering dependency not expressible as a resource gets a causal-effect
  test where the wrong order observably changes the result.

## Resources And Error Handling

Pair every SDL/GPU/audio resource creation with its cleanup at the owning site,
`errdefer` partial initialization, and keep `defer` next to creation.
`@ptrCast`/`@alignCast`/`@intCast` carry a local type or range justification. C
strings passed to SDL are sentinel-terminated and outlive the call.

Keep error sets meaningful; never swallow errors where diagnosis matters.
Advance edge/latch state only on the success path
(`enqueue(...) catch return; latch = true;`).

A config field whose zero is a valid domain value (e.g. `TileId` 0 is a real
blocking tile) defaults to the domain's invalid sentinel (`maxInt`) and is
assert-resolved at the use boundary. A validator bounds each scalar on both ends
where its siblings do; a present-but-wrong-typed optional field is an error, not
treated as absent.

Remove callerless `pub` helpers and any `pub` export whose doc asserts a
contract nothing references.

## Assets And Persistent Data

Runtime asset paths stay relative and traversal-safe.

Persistent gameplay and render-prep data store stable IDs (`SpriteAssetId`,
`AudioAssetId`) and render depth as enum intent, never string paths,
`TextureId`, `TextureLease`, prepared sprite records, SDL_mixer or loaded audio
handles, or renderer-owned resources. Convert stable IDs to texture IDs at the
render-prep boundary.

`DataSystem` owns persistent gameplay data (entity IDs, generations, masks,
dense typed SoA stores). App, render, SDL/GPU, input-frame, thread, and event
services, asset-loading state, and per-step scratch are never persistent
`DataSystem` fields; processors borrow `DataSystem` slices plus runtime
services.

## Logging

Route all runtime diagnostics through `src/core/logging.zig` scoped loggers
(`app`, `assets`, `audio`, `core`, `game`, `render`, `platform`,
`debug_overlay`, `perf`): `const log = @import("../core/logging.zig").render;`.
Never call `std.log`/`std.log.scoped(...)` directly; `std.debug.print` is for
`src/benchmarks/` CLI stdout only. `info`/`debug` for lifecycle, config, and
fallback; `warn` for recovered degradation; `err` for real failures. Pure
helpers and validation stay log-free.

Shipping builds (`ReleaseFast`/`ReleaseSmall`) do zero per-frame, update, event,
draw, entity, or iteration log or perf-counter work: such instrumentation is
comptime-gated to a zero-sized no-op, not skipped at runtime. Reference:
`src/app/runtime_perf_log.zig` (`enabled` only in `Debug`/`ReleaseSafe`; per-frame
work is counter increments; the formatted emit runs once per interval). Gate any
non-trivially formatted diagnostic behind the comptime `logging.enabled(level)`.
Which mode to use when: `docs/development-workflow.md` § Diagnostics And Log
Levels.

## Comments

Comments preserve contracts and non-obvious intent; they do not narrate
straight-line code. Cross-module public declarations get `///` doc comments when
the caller needs ownership, lifetime, invariants, ordering, threading,
allocation, failure, or performance assumptions. Use `//` for private helpers,
phase markers, local invariants, hot-path rationale, and fixture context, placed
above the declaration or near the block they explain.

Keep each comment as short as its contract allows: the rule or invariant and,
when non-obvious, the one reason; proofs, worked arithmetic, rejected
alternatives, and history go in the slice doc or commit message. No
slice/roadmap references or review tags in code comments, no comments that
repeat the identifier or describe obvious assignment, and no broad claims not
enforced by code or tests. Slice docs record decisions and checklists, not the
reasoning trail.

## Tests

- Tests are `test` blocks beside their code, named by behavior.
- Prefer focused window-free contract tests; display/GPU checks belong in
  `gpu-smoke`.
- Terrain contract tests cover a multi-chunk one-step change and repeated
  dig/fill.
- An incremental path (nav patch, repack) gets an incremental == full-rebuild
  parity test.
- Use the smallest `WorldSystem`/`DataSystem` fixture that exercises the
  behavior (a `1x1` world still has one real chunk).
- Only a test of growth or capacity at scale gets a larger populated world.
- Full world-building paths (`initProcedural*`) run in tests only when under
  test, with at most 16x16 tiles and 1 underground level.
- Production APIs carry no test-only tags, payloads, fields, stages, hooks,
  shortcuts, or paths; tests use private helpers, fixtures, mocks, or real
  payloads.
- Tests never time anything or call `src/benchmarks/`
  ([Benchmarks](#benchmarks)).

## Benchmarks

- All performance numbers and OOM/leak sweeps come from `zig build bench`.
- `zig build test` never times anything, even temporarily or in ReleaseFast.
- Tests never call `src/benchmarks/*.zig`, except `suite.zig`'s tests of its
  pure utilities against stubs.
- Test production correctness in its owning module with a small fixture;
  bench-fixture correctness relies on internal asserts firing during a real
  bench run.
- A perf question with no covering case gets a new case under
  `src/benchmarks/`.
- Run targeted groups (`zig build bench -- --group <name>`), never the full
  suite filtered; full sweeps only when the owner or a slice asks.
- Bench only changes that can move a hot path, with 3 interleaved reps.
- Target-scale benches ship with the first implementation; terrain features
  bench destruction-shaped workloads (a one-step explosion region, repeated
  dig/fill).
- Scaling benches check that an algorithm's cost grows as designed across
  sizes (flat for a local change, linear where linear is right). A cost that
  grows with world size on a local change is a design defect regardless of the
  absolute number; never cite a scaling bench as a frame-time verdict.

## Generated Output And Configuration

Never hand-edit `zig-out/` or `.zig-cache/`. Do not commit generated binaries or
local machine paths. When adding `build.zig.zon` dependencies, keep hashes
accurate and review the fingerprint (it is project identity).
