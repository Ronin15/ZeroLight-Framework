# Coding Standards

The canonical source for every technical rule. `CLAUDE.md`, the agent files,
the workflows, and the roadmap point here by section name and do not restate
these rules.

## Zig Style

Follow `zig fmt`. Naming: camelCase for functions and other callables; snake_case for
variables, struct fields, enum members, and non-type constants; PascalCase for
types and type-returning functions; short descriptive names.

Write the plain, obvious form first, in production and test code alike: names
that say what a value is (`corridor`, not `i`/`xy`), arithmetic over bit tricks
(`x % 2 == 1`, not `x | 1`), small named helpers over inline tuple arrays. Use a
clever form only where a bench shows it matters on a hot path, and name what it
does in a one-line comment.

Keep error sets explicit when practical (`error{SdlError}`). The accepted
exception is the `*anyopaque` + `anyerror!T` function-pointer vtables at
type-erased service boundaries (state adapters, asset upload, audio/text
backends): the error set cannot be named across the erased boundary, and they
sit on cold setup/service paths, so they are not the "broad dynamic dispatch"
banned in [Dispatch And Lookup](#dispatch-and-lookup).

Prefer direct declaration imports for project types and constants
(`const Engine = @import("app/engine.zig").Engine;`). Use a concise snake_case
file namespace only when the call site reads better as a namespace lookup
(`input_file.actionForKey(...)`, `assets.validateRelativePath(...)`). No `_mod`
suffixes, no `const Type = file.Type` bridge aliases, no double names such as
`thread.ThreadSystem`. Do not rewrite SDL/C symbols, generated build-option
names, or `std.Build` field names.

Use current standard-library and builtin spellings:

- `std.ArrayList` is the unmanaged list in Zig 0.17 (explicit allocator per
  call, initialized as `.empty`); never the deprecated `std.ArrayListUnmanaged`.
  Prefer `= .empty` / `.{}` over removed managed constructors.
- `@backingInt` / `@fromBackingInt`, not `@intFromEnum` / `@enumFromInt`.
- `@splat`, not the removed `**` array repeat (prefer
  `var a: [N]T = @splat(x);`).
- `@typeInfo(T).<kind>.field_names` / `field_types` or `std.meta.tags(E)`, not
  the removed `std.meta.fields`.
- `allocator.dupeSentinel(u8, bytes, 0)`, not `dupeZ`.
- `std.builtin.Optimize` (`.debug`/`.safe`/`.fast`/`.small`), not `OptimizeMode`.
- C headers go through `build.zig`'s shared TranslateC step, never `@cImport`.

Small idioms: `std.math.isNan(x)`, not `x != x`; `EntityId.eql`, not a free
equality helper; `try`, not a no-op `catch |e| return e`. `idiom-lint` exempts
function-pointer-typed fields from the camelCase check, so a camelCase
fn-pointer field that should match the snake_case production vtables
(`state.zig`, `audio.zig`, `cache.zig`) is a review-only catch.

Never gate behavior hooks on `@hasDecl`: since Zig 0.17 it sees only `pub`
declarations, so a private hook is silently skipped. Make the hook part of the
required contract and call it unconditionally (as the state stack does for
`onPause`/`onResume`).

`Renderer` is the render facade for app/game code. Never import
`src/render/gpu/*` outside the render/platform boundary.

## Performance

Performance is correctness on hot and frame-adjacent paths (fixed-step
update, input dispatch, render submission, asset lookup, text/debug overlay).

Hot paths are allocation-free after init, reserve, or warmup. An exception needs
an explicit owner, a measured and bounded cost, and a reason the allocation
cannot move to init, load, a state transition, reserve/warmup, or another cold
boundary.

### Allocator Discipline

Mandatory, not advisory. Every `reserve`/`ensureTotalCapacity` +
`assumeCapacity` (or `addOneAssumeCapacity`) pairing ships, in the same change,
with a `std.testing.FailingAllocator` (or `std.testing.failing_allocator`) test
proving the warmed hot path allocates zero times; a comment or review claim is
not proof. **ReleaseFast** ships, and it strips the assert behind
`assumeCapacity` and bounds/overflow checks, so an unproven reserve is silent
memory corruption. When reserve and commit live in separate functions or entry
points, the proof exercises the reserved-then-push **success** branch (reserve,
arm the allocator to fail on the next allocation, assert the push completes),
not only the reserve-fails cleanup branch. Threaded paths add a proof
requirement ([Threading](#threading)).

Behavior gates compare stored **logical** limits, never a container's physical
`.capacity` (`ensureTotalCapacity` and `MultiArrayList.resize` round up, and
shrink hysteresis keeps slack, so a `.capacity` gate makes refusal, drops,
truncation, spills, or query reach depend on allocation history). Store the
limit beside the reserve, assign it only after the reserve succeeds, gate on
it, and `std.debug.assert(list.capacity >= limit)`. A `.capacity` read that only
picks `appendAssumeCapacity` vs a growing `append`, with the same result, is not
a gate. An appendable pool tracking a separately reserved fixed-capacity
dedup/probe table gates its append on the shared logical cap and honors the
probe's insert-bool. A reserve/overflow contract's assert and its overflow check
bound the same quantity.

The same strip applies to `unreachable`, `catch unreachable`, and
`orelse unreachable` (including `.?`): in ReleaseFast a reached `unreachable` is
undefined behavior. Use them only where the state is impossible by construction
(the established case: generational-handle constructors bounded by capacity,
`TextureId.init(...) catch unreachable`, `EntityId.init(...) catch unreachable`).
A recoverable or data-influenced failure returns an error or asserts instead. A
`.?` on an optional field in a hot or worker loop is invisible to `idiom-lint`:
capture it as a non-optional local at dispatch or assert non-null at entry; never
rely on cross-thread ordering to keep it non-null. Narrowing casts are unsafe the
same way: widen signed coordinate/cell spans to `i64`/`usize` before subtracting
and `@intCast`-ing to an unsigned width, clamp while wide, then narrow (a
saturated float→`i32` makes `@intCast(max - min + 1)` UB).

`zig build idiom-lint` (part of `verify`; rules in `tools/lint_idioms.py`)
rejects `catch unreachable` / `orelse unreachable` outside `test` blocks unless
on a sanctioned handle constructor or annotated
`// lint:allow catch-unreachable: <reason>`. Never annotate a recoverable
failure; propagate it (reference: `SpriteBatch.buildSerial` returns `!void`
rather than folding `ensureFrameStorage`'s error into UB). The lint also
enforces snake_case fields/parameters, `k_snake_case` constants, and current
spellings (no `std.ArrayListUnmanaged`, `usingnamespace`, `std.mem.copy`/`set`,
`std.BoundedArray`, `@intFromEnum`, `@enumFromInt`, `std.meta.fields`, `dupeZ`,
`OptimizeMode`, `@cImport`, `**` array repeat, or `@hasDecl` in `src/`).

Allocators are explicit: every allocating struct takes an `std.mem.Allocator`
at `init` and stores it as a field immediately, never left `undefined`. Never
reach for `std.heap.page_allocator`, `std.heap.c_allocator`, or a fresh
`GeneralPurposeAllocator` inside a function body, even on a cold path; thread
the caller's allocator through. A local `ArenaAllocator` over the passed-in
allocator is fine for short-lived allocations freed as one unit.

`errdefer` rules:

- Register narrowly, right after each owning field is validly constructed. Never
  a blanket `self.deinit()` `errdefer` before every owned field exists (it runs
  over `undefined` memory, or double-frees a field whose own `errdefer` fired).
- A caller that `defer`s cleanup of an allocated container (e.g.
  `allocator.create(T)`) registers that `defer` only after the fallible `init`
  succeeds, with a narrower `errdefer` for the window before it.
- A function taking ownership of an already-constructed by-value resource
  registers `errdefer <res>.deinit()` as its **first** statement.
- After a step transfers ownership onward (map `put`, list `append`, lease-slot
  commit), disarm the earlier free-`errdefer` with a per-iteration bool set
  right after the transfer, so exactly one path frees it.
- A handle-owning setter that overwrites an owned slot asserts the slot empty
  (or closes the prior handle first).

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

Use `std.MultiArrayList` (MAL) when several columns grow, shrink, append, or
swap-remove **together** as one logical row: the default for persistent
`DataSystem` component stores, state-owned dense pools (e.g. `ParticleSystem`),
and per-step gather/scratch buffers of matching lengths (collision proxies, AI
gather rows, steering selected-work columns, collision-response intent rows).

Pattern:

- A row struct with one field per column (`MovementBodyRow`, `ProxyRow`,
  `AiGatherRow`); store `rows: std.MultiArrayList(Row)`; expose hot paths via
  `slice()`/`sliceConst()` helpers returning the column-slice structs
  (`ConstMovementBodySlice`, `ParticleSlice`).
- Reserve with `rows.ensureTotalCapacity(allocator, hotStoreCapacity(n))` where
  threading/SIMD ranges need item alignment (`alignItemCount`,
  `thread_system.zig`).
- Cold emit/setup may use `rows.appendAssumeCapacity(row)` after reserving; hot
  gather loops must not (use `appendMalRow` below).
- A per-row store append uses a private `ensureCapacityForOne` +
  `appendAssumeCapacity`, never `ensureCapacity(n)` + plain `append`.
- Compact with `rows.swapRemove(index)` when unordered removal is fine.
- Keep `deinit`, `clearRetainingCapacity`, and capacity helpers on the owning
  store.

Do not migrate to MAL when the layout is intentionally different: hot/cold
column splits (e.g. pathfinding result-cache probe slots vs cold payloads),
striped or arena buffers (`capacity × stride`), cache-line-padded thread range
slots, spatial hash grids (`cell_entries` + `cell_ranges`), pair/contact output
streams, existing AoS `ArrayList(Struct)` pools, and sparse slot maps
(`EntitySlot` tables).

MAL hot-path rules (mandatory):

- Call `rows.slice()` **once** per stage or function and reuse its column slices
  (`const ages = s.items(.age)`). Never `rows.items(.field)` in a loop (it
  rebuilds slice pointers; large Debug and Release regressions). Single-index
  cold accessors also call `rows.slice()` once.
- A per-row render/collect helper takes const column slices from its caller and
  never calls `.slice()`/`.sliceConst()` itself.
- Per-step gather loops append with this helper, capturing
  `var row_slice = rows.slice()` once before the loop (`appendAssumeCapacity`
  calls `set()`/`slice()` per row: ~45% Debug regressions measured):

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

- Publish hot float columns as plain `[]f32` / `[]const f32`, never
  `[]align(64) f32` (MAL does not guarantee 64-byte column bases). 16-item range
  alignment is for threading chunk boundaries; wide aligned loads need their own
  planning.

### SIMD And Core Math

All vector and named math operations go through `core`: `src/core/simd.zig`
(vector types/ops) and `src/core/math.zig` (reusable scalar/vector math),
unconditionally, however domain-specific the caller. Never declare raw
`@Vector` in a system or hand-roll a named primitive inline (gather/scatter,
reciprocal/inverse sqrt, length/normalize, trig, interpolation,
clamp/saturating conversions). A missing primitive is added to `core` with
scalar-vs-SIMD parity tests, scalar and SIMD forms kept paired. A one-system
composite kernel may stay in its system, built from `core` primitives; promote
a kernel reused across systems. Plain operator arithmetic (`+ - * /`, including
on `simd` types) is fine inline.

Use the `simd.zig` helpers for dense, uniform, branch-light float math over
contiguous SoA columns, always with a scalar tail (movement, collision
broad/narrowphase, collision response, particles, the flow field). Prefer
codegen-friendly scalar-to-`@Vector` loads unless a target-specific aligned load
is measured and owned. Prefer scalar code for tiny batches or simple logic.

Judge per-agent and per-neighbor loops (AI decision, separation, steering
avoidance) at target scale (large battles, late-game worlds), never as "low
count". Vectorizability is a layout property: restructure a
gather-bound or branchy hot loop by gathering into packed local SoA scratch,
then running the math across lanes with masked `select` for branches. That is
the default plan for hot per-agent math. Leave genuinely irreducible loops
scalar (BFS/A* frontier traversal, swap-remove compaction, rare branch-heavy
setup) and say why. A new or restructured hot float loop goes through the shared
helpers with scalar/SIMD and serial/threaded parity tests.

## Budgets, Capacities, And Thresholds

Three different things. Size and bound for dense, multi-chunk terrain change in
one step.

**Per-step / per-query work budgets** (search node caps, solves per step,
links/spawns folded per step) **are fixed counts, never derived from world, map,
level, cell, portal, or band count or any measured current scale**, so frame
time and behavior do not depend on the map. Counts, not milliseconds (time
budgets are nondeterministic). Work that does not fit is deferred
deterministically. This is a tested invariant (grep `independent of` /
`regardless of world size`, e.g. the pathfinder's abstract A* node budget,
`nav_graph.zig`'s incremental-dig chunk-patch tests). A chronically
insufficient budget is fixed by graceful degradation (deterministic deferral, a
bounded retry ladder) or an algorithmic change, never a bigger number picked
for one map.

**Data-structure capacities are right-sized per world instance**, never one
size for every world:

- *World-extent data* (tiles, per-chunk nav, chunk tables, per-level data):
  sized exactly from the loaded world at init/load, never grown. Dig/build
  changes contents, not extent.
- *Runtime-growing data* (population, items, particles, nodes, spawned
  structures, runtime links): start at the world/content-derived size plus
  headroom, then **grow only at the main-thread structural-commit seam**,
  outside threaded stages, geometrically and ahead of need (e.g. at a fill
  threshold), or use paged/chunked storage where a large realloc would spike a
  frame. Growth on a hot path or inside a threaded stage is a defect.

Between growth points hot paths stay allocation-free, proven per
[Allocator Discipline](#allocator-discipline). Capacity never changes behavior:
no iteration order, deferral, refusal, or result depends on how much is
reserved. No dig, build, cave-in, or explosion is ever refused for capacity.
The only fixed caps:

- index/format widths (`u16`/`u32` indices, save/replay layouts) proven
  unreachable for the loaded world extent, failing loudly at load;
- presentation-only pools that no simulation reads (particles, text labels),
  with deterministic overflow drop.

**Load-time platform validation** (e.g. the dense GPU byte budget, the nav
memory estimate `max_nav_memory_bytes`) is allowed: it checks the loaded world
and configuration once and fails loudly at load. It never runs during play:
runtime-growing data that later outgrows the estimate (population, level links,
the pathfinding agent budget) grows at its seam, and only an allocator OOM can
fail that growth, as an ordinary error that leaves state intact for a retry.

**Heuristic thresholds** (e.g. "build a group flow field above N agents") derive
from the cost of the operation they gate (its own bounded region or input),
never from the whole world's size.

**Decide per data structure, as an experienced engine programmer would:** size
by lifetime and growth (world-extent exact; growing stores amortized-geometric
at a safe point, or paged); pools, free lists, and generational handles for
churn; SoA contiguity over minimal footprint; a fixed cap only where it buys
something (index width, stable format, per-frame work bound); back changes with
a bench or memory number.

**Never change a constant just to satisfy this rule.** Default is keep. A change
to an existing budget, capacity, or threshold states a concrete benefit (memory
saved, an artificial limit removed, fewer allocations or cache misses, simpler
code) weighed against cost and risk (hot-path cost, layout/format churn,
proof/test churn, determinism).

## Threading

A collection written from more than one thread satisfies both, verifiably at the
call site:

1. Writes are partitioned into disjoint per-worker or per-range slots, never a
   shared appendable collection written concurrently.
2. The matching reserve happens on the main thread strictly before dispatch,
   sized from the same selection/profile value the dispatch uses. Never reserve
   during or after dispatch.

Each threaded hot-path worker job opens with a `std.debug.assert` on **both** its
write range against the buffer length and `range.index` against the dispatched
range count captured at dispatch (a cloned stage often drops one, and the
missing guard is a silent OOB write in ReleaseFast). The `FailingAllocator`
proof exercises the real multi-worker `ThreadSystem`, not only the
serial/inline branch.

Merged output is deterministic from stable input and range order (count per
range → prefix offsets → contiguous write → range-index merge → batch commit),
never from worker timing, worker IDs, or per-command global atomics. Drive a
batched `RangeOutputStream`/`SimulationEvents` producer once per commit: write
every range, then call `finishWrite` once (`SimulationEvents.finishWrite`
rebuilds stats over all ranges and survives ReleaseFast, so a per-record publish
loop is O(N²)).

A pass emitting **at most one output per input item** (gather, compaction,
per-item command or contact) uses no per-range buffers: each range writes its
`[range.start, range.end)` window of one cache-line-aligned buffer sized by item
capacity, with its count (and diagnostics) in a cache-line-padded tally sized by
`thread_system.maxRangeCount(capacity, alignment)`; the main thread compacts
the windows in range order or streams them to the consuming
`RangeOutputStream`. One seam reserve then covers every partition. Only a pass with
data-dependent output per item (collision broadphase pairs) keeps per-range
slots, reserved at the seam to the per-item bound times the most items any range
index can cover under any partition (never clamped to the total), with overflow
handled by a counted grow-and-replay. References: `simulation_scope.zig`
gathers and tier policy, `spatial_index.zig` gather, `collision.zig`
narrowphase.

A pass whose events are a pure function of per-row state its workers already
write (perception's nearest-threat columns, affect's crossing bits) keeps no
event scratch: the main thread derives and emits them in row order after the
join.

A partitioned processor that **emits an event stream** under a per-step cap
emits in a canonical, partition-independent key order (per row, a row's
sub-kinds grouped, as `PerceptionSystem.emitTransitionEvents` and
`AffectSystem.emitCrossingEvents` do) before applying the cap. Its parity tests
cross two or more event kinds for entities in different ranges and include a
capped case.

Threaded/SIMD processors iterate dense SoA columns directly; component masks are
for membership/query, never dynamic joins, string lookup, or hash-map dispatch
in hot loops. Worker ranges write disjoint rows without sharing writable cache
lines in hot SoA columns. Use 64-byte padding only for concurrently written
thread-shared records with real false-sharing risk, never on cold entity slot
metadata.

Keep state transitions, entity structural changes, SDL/GPU/audio calls, asset
loading, save/load streaming, and renderer/mixer resource ownership out of
threaded processors unless an explicit deferred or main-thread boundary is
designed. Workers never mutate `DataSystem` structurally; structural commits
batch at the commit seam.

The main thread is not a fallback owner: main-thread code preserves a concrete
boundary (those above, or light orchestration). Work that scales with entity, event, asset, or draw count, map
or file size, or tool complexity gets a named owner; when it can get expensive,
use immutable inputs plus deterministic owned outputs.

Work that scales with population, terrain change, or world size ships serial and
threaded paths in its first implementation, with serial/threaded parity tests.
The serial path also covers small batches, tests, and unsupported thread
targets. Small fixed-size or cold one-off work may stay serial; ask the owner if
unsure. Multi-stage processors have per-stage tuners and visible timing/tuning
stats. Worker participation is driven by measured batch timing and structural
constraints, never static item-count floors.

## Simulation Pipeline Stage Ordering

Mandatory, not advisory. `SimulationPipeline.update()` runs a fixed stage order
over per-step resources, and the ordering is enforced at comptime:
`simulation_pipeline.zig`'s `stageContract()` declares each stage's reads,
writes, and carried inputs; `stage_order` is a permutation of `StageId`; a
`comptime` walk fails the build if a stage reads a resource no earlier stage
writes. The pipeline is the only fixed-step scheduler: no scheduler beside it,
and never promote it into a global ECS scheduler or app service.

`carried` is a value the stage consumes that no earlier stage writes: input
captured before `update` (`action_intents`), world authoring
(`interest_markers`), or a column a later stage writes for the next step
(`ai_behavior` carried by `affect_update`). It is disjoint from the stage's
reads and writes; a resource an earlier stage writes is a read.

Event payloads are four tags: a write of `world_events` does not satisfy a read
of `perception_events`, `affect_events`, or `structural_events`.
`structural_events` (`entity_created`, `entity_destroyed`, `component_changed`)
are commit-seam payloads, external to the stage graph.

Every new or reordered stage adds, in the same change:

1. Its `PipelineResource` tag(s) (reuse an existing coarse tag; no redundant
   one-off tags).
2. Its `StageId` in `stage_order` at the position its real dependencies require.
3. Its `stageContract()` arm.
4. Its `runStage` arm (the `inline for` over `stage_order` in `update()`).

An ordering dependency not expressible as a `PipelineResource` read/write gets a
causal-effect test: a scenario where the wrong order gives an observably
different result (see `simulation_pipeline.zig`'s "pipeline commits the dig
stage's world edit before plane traversal reads it in the same step" and the
ai_memory/affect ordering tests).

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

Tests are `test` blocks beside the code they cover, named by behavior
(`test "player movement clamps to window bounds"`).

Prefer focused contract tests that need no window: input routing, state policy,
transition ordering, resource ID and descriptor validation, viewport math, asset
path validation, timing decisions, pure gameplay/data contracts. Display/GPU
checks belong in `gpu-smoke`.

Where terrain is involved, contract tests cover a multi-chunk, one-step terrain
change and repeated dig/fill.

Keep `WorldSystem`/`DataSystem` fixtures at the smallest size that exercises the
behavior. A `1x1` `WorldSystem` still yields one real chunk
(`chunksX = ceilDiv(width, chunk_size_tiles)`), enough for chunk-gate and
visibility tests. Reserve a larger populated world for the one test that needs
growth/capacity behavior at scale (e.g. a `FailingAllocator` reserve proof).

Never build production-scale worlds in `zig build test`. `initProcedural`,
`initProceduralFromMeta`, `initProceduralWithRuntimeAssets`, and other full
world-building load/gameplay paths may run only with a minimal config (at most
16x16 tiles and 1 underground level, the `worldUsesCompactDemoSpawn` threshold)
and only when that real path is under test (e.g. state-transition wiring).
Otherwise use hand-built fixtures, small demo patches, or pure contract checks;
full-world throughput belongs in `zig build bench`.

Production contracts expose runtime concepts only: no test-only enum tags, union
payloads, marker fields, fake stages, fixture hooks, service shortcuts, or
test-only paths in production APIs. Tests use private helper types, local
fixtures, test-only mocks, or real payloads.

Test code never measures timing and never calls into `src/benchmarks/`
([Benchmarks](#benchmarks)).

## Benchmarks

`zig build bench` is for performance and OOM/leak sweeps; `zig build test` is
for fast contract checks only and never times anything, not even temporarily or
under ReleaseFast. All performance numbers come from `zig build bench`
(warmup, repetition, adaptive settle: `src/benchmarks/suite.zig`).

Test code never calls `src/benchmarks/*.zig` functions (their fixture builders
and case runners build large throughput fixtures). The one exception is
`suite.zig`'s own tests of its pure utilities (arg parsing, formatting,
alignment math) against hand-built stubs. A production correctness property is
tested in the owning module with a small fixture; a bench-fixture property
relies on the module's internal `std.debug.assert` firing during a real
`zig build bench` run. A perf question with no covering case gets a new or
extended case under `src/benchmarks/`.

Run targeted groups: `zig build bench -- --group <name>` (optionally
`--case`/`--items`). Never run the whole suite and filter its output; a
full-suite sweep runs only when the owner asks or a slice names it. Bench only
changes that can move a hot path, with targeted groups and 3 interleaved reps.

Target-scale benches ship with a feature's first implementation. Where terrain
change is involved, cover destruction-shaped workloads (an explosion region in
one step, repeated dig/fill). Large-scale cases (e.g. the 50k item scales) are
stress tests and throughput ceilings, not per-frame targets: weight a result by
how often that workload occurs at that count. Population-driven systems (AI,
perception, collision) are where large counts are real; rare growth steps such
as nav repacks are not.

## Generated Output And Configuration

Never hand-edit `zig-out/` or `.zig-cache/`. Do not commit generated binaries or
local machine paths. When adding `build.zig.zon` dependencies, keep hashes
accurate and review the fingerprint (it is project identity).
