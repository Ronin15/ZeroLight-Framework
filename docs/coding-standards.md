# Coding Standards

This document is the canonical source for every technical engineering rule:
style, performance, budgets and capacities, threading, stage ordering,
resources, logging, comments, tests, benchmarks, and generated output.
`CLAUDE.md`, the agent files, the workflows, and the roadmap point here by
section name and do not restate these rules.

## Zig Style

Follow `zig fmt`; use 4-space indentation and avoid manual alignment that the
formatter will rewrite. Follow Zig's standard naming: camelCase for functions
and other callables, snake_case for variables, struct fields, enum members, and
non-type constants, PascalCase for types (and functions that return a type), and
short descriptive names.

Write the plain, obvious form first, in production and test code alike: names
that say what a value is (`corridor`, not `i`/`xy`), arithmetic over bit tricks
(`x % 2 == 1`, not `x | 1`), and small named helpers over inline tuple arrays.
Use a clever form only where a bench shows it matters on a hot path, and name
what it does in a one-line comment. Keep error sets explicit when practical, as in
`error{SdlError}`. The `*anyopaque` + `anyerror!T` function-pointer vtables at
type-erased service boundaries (state adapters, asset upload, audio/text
backends) are the accepted "not practical" exception: the concrete error set
cannot be named across the erased boundary, and these sit on cold
setup/service paths, not hot per-frame dispatch, so they do not violate the
"avoid broad dynamic dispatch" performance rule below.

Prefer direct declaration imports for project types and constants when that
keeps call sites clear, such as `const Engine = @import("app/engine.zig").Engine;`
or `const ThreadSystem = @import("app/thread_system.zig").ThreadSystem;`. Use a
concise snake_case file namespace only when the call site is clearer as a
function or namespace lookup, such as `input_file.actionForKey(...)` or
`assets.validateRelativePath(...)`.

Avoid `_mod` suffixes, `const Type = file.Type` bridge aliases, and double names
such as `thread.ThreadSystem`. Do not rewrite SDL/C symbols, generated
build-option names, or `std.Build` field names.

Use current standard-library spellings. `std.ArrayList` is the unmanaged list in
Zig 0.17 (it takes an explicit allocator per operation and initializes as
`.empty`); do not use the deprecated `std.ArrayListUnmanaged` alias for new or
edited code. Prefer the modern initializer forms (`= .empty`, `.{}`) over
removed managed-container constructors.

Use the Zig 0.17 builtin spellings: `@backingInt` / `@fromBackingInt` (not the
deprecated `@intFromEnum` / `@enumFromInt`), `@splat` instead of the removed `**`
array-repeat operator (prefer `var a: [N]T = @splat(x);` when the declaration
can carry the type), `@typeInfo(T).<kind>.field_names` / `field_types` or
`std.meta.tags(E)` instead of the removed `std.meta.fields`,
`allocator.dupeSentinel(u8, bytes, 0)` instead of the removed `dupeZ`, and
`std.builtin.Optimize` (`.debug`/`.safe`/`.fast`/`.small`) instead of the
`OptimizeMode` alias. C headers go through `build.zig`'s shared TranslateC step,
never `@cImport`.

Small idioms: `std.math.isNan(x)`, not scalar `x != x`; `EntityId.eql`, not a
free-function `EntityId` equality helper; `try`, not a no-op
`catch |e| return e`. `idiom-lint` exempts function-pointer-typed fields from the
camelCase check, so a camelCase fn-pointer field that should match the
snake_case production vtables (`state.zig`, `audio.zig`, `cache.zig`) is a
review-only catch.

Do not gate behavior hooks on `@hasDecl`. Since Zig 0.17, `@hasDecl` only sees
`pub` declarations, so a private hook is silently skipped instead of failing to
compile. Make a hook part of the required contract and call it unconditionally
(the state stack does this for `onPause` and `onResume`).

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

### Allocator discipline (mandatory, not advisory)

Every `reserve`/`ensureTotalCapacity` + `assumeCapacity` (or
`addOneAssumeCapacity`) pairing must ship with a `std.testing.FailingAllocator`
(or `std.testing.failing_allocator`) regression test proving the warmed hot
path allocates zero times. A doc comment or review claim of "allocation-free"
is not sufficient proof by itself. This project ships **ReleaseFast**, which
strips the debug assert backing `assumeCapacity`'s capacity check and disables
bounds/overflow safety checks; an unproven reserve is a silent
memory-corruption risk in the shipped binary, not a missed optimization. Add
the proof test in the same change that adds the `assumeCapacity` call — do not
defer it. When the reserve and its `assumeCapacity` commit live in separate
functions or public entry points (not one guarded helper), the proof must
exercise the reserved-then-push **success** branch — reserve, then arm the
allocator to fail on the next allocation, and assert the push completes — not
just the reserve-fails cleanup branch, since split sizing can silently desync
from the push count across a future edit. Threaded paths have an extra proof
requirement (see [Threading](#threading)).

Behavior gates compare stored **logical** limits, never a container's physical
`.capacity`. `ArrayList.ensureTotalCapacity` rounds up (`growCapacity(n) = n +
n/2 + cache_line/@sizeOf(T)` in std 0.17), `MultiArrayList.resize` rounds too,
and shrink hysteresis keeps slack. A gate on `.capacity` therefore makes
refusal, drops, truncation, spills or query reach depend on allocation history.
Store the limit beside the reserve, assign it only after the reserve succeeds,
gate on it, and `std.debug.assert(list.capacity >= limit)`. A `.capacity` read
that only chooses between `appendAssumeCapacity` and a growing `append`, with
the same result either way, is not a behavior gate. An appendable pool that
tracks a separately reserved fixed-capacity dedup/probe table gates its append
on the shared logical cap and honors the probe's insert-bool. A
reserve/overflow contract's assert and its overflow check bound the same
quantity (not a pre-rounding request against a rounded `.capacity`).

The same ReleaseFast safety-strip applies to `unreachable`, `catch unreachable`,
and `orelse unreachable` (including `.?`, which is `orelse unreachable`): in the
shipped binary a reached `unreachable` is undefined behavior, not a panic. All
are permitted only where the state is provably impossible by construction — the
established use is generational-handle constructors bounded by capacity
(`TextureId.init(...) catch unreachable`, `EntityId.init(...) catch unreachable`),
whose failure case cannot occur within the reserved index/generation range. Hold
`unreachable` to the same "provable, not merely expected" bar as `assumeCapacity`;
if a failure is recoverable or attacker/data-influenced, return an error or
assert instead. A `.?` on an optional field inside a hot or worker loop is
invisible to `idiom-lint`: capture it as a non-optional local at dispatch or
`assert(field != null)` at entry, and never rely on cross-thread ordering alone
to keep it non-null. The same strip makes narrowing casts unsafe: widen signed
coordinate/cell spans to `i64`/`usize` before subtracting and `@intCast`-ing to
an unsigned width/capacity, clamp while wide, then narrow — a saturated
float→`i32` conversion makes `@intCast(max - min + 1)` overflow/out-of-range UB,
not a panic.

This is enforced by `zig build idiom-lint` (part of `zig build verify`): a
`catch unreachable` / `orelse unreachable` outside a `test` block is rejected
unless it is on a sanctioned handle constructor or carries an explicit
`// lint:allow catch-unreachable: <reason>` justification at the site. Do not add
the annotation to silence the lint on a genuinely recoverable failure — propagate
the error instead (the reference case is `SpriteBatch.buildSerial`, which returns
`!void` rather than folding `ensureFrameStorage`'s allocation error into UB). The
same lint gate enforces snake_case struct fields/parameters, `k_snake_case`
constants, and current stdlib/builtin spellings (no `std.ArrayListUnmanaged`,
`usingnamespace`, `std.mem.copy`/`set`, `std.BoundedArray`, `@intFromEnum`,
`@enumFromInt`, `std.meta.fields`, `dupeZ`, `OptimizeMode`, `@cImport`, `**`
array repeat, or `@hasDecl` in `src/`); its rules live in
`tools/lint_idioms.py`.

Allocators are owned explicitly: every allocating struct takes an
`std.mem.Allocator` at `init` and stores it as a field, set immediately —
never left `undefined` until a later call sets it. Do not reach for
`std.heap.page_allocator`, `std.heap.c_allocator`, or a freshly constructed
`GeneralPurposeAllocator` inside a function body, including on a cold path;
thread the caller's allocator through instead. A local `ArenaAllocator`
wrapping the passed-in allocator is fine for a function that needs several
short-lived allocations it can free as one unit.

Register `errdefer` narrowly, immediately after each field that owns memory
is validly constructed. Never register a blanket `self.deinit()`-style
`errdefer` before every owned field exists — it runs over `undefined` memory
if an earlier step fails, and double-frees a field whose own narrow
`errdefer` already fired if a later step fails. A caller that unconditionally
`defer`s cleanup after allocating a container (e.g. `allocator.create(T)`)
must register that full cleanup `defer` only after the fallible `init` call
succeeds, with a narrower `errdefer` covering just the failure window before
that. A function that takes ownership of an already-constructed by-value
resource registers its `errdefer <res>.deinit()` as the **first** statement,
before any other fallible step — the caller built it inline and holds no cleanup
handle, so an earlier failure leaks it. Once a step transfers ownership of an
allocation onward (a map `put`, list `append`, or lease-slot commit), disarm the
earlier free-`errdefer` with a per-iteration bool set right after the transfer,
so exactly one path frees it. A handle-owning setter that overwrites an owned
slot asserts the slot empty (or closes the prior handle first) rather than
relying on call-site ordering to avoid a leak.

### Dispatch and lookup

Avoid per-frame, per-event, per-draw, or per-processor-loop string lookup,
hash-map dispatch, broad dynamic dispatch, callback chains, repeated descriptor
validation, formatted logging, and resource churn unless the cost is measured,
bounded, and intentionally isolated.

Prefer enums, bitsets, arrays, slices, direct indices, ring buffers, prepared
resources, stable asset IDs, and generational handles for runtime dispatch and
lookup.

Keep fixed-step simulation separate from visible render cadence. Do not add
broad frame-rate caps that hide timing problems or harm high-refresh rendering
unless the cap preserves a named boundary and is measured.

### Dense SoA storage (`std.MultiArrayList`)

Prefer `std.MultiArrayList` when several columns grow, shrink, append, or
swap-remove **together** as one logical row. This is the default for persistent
`DataSystem` component stores, state-owned dense pools (for example
`ParticleSystem`), and per-step gather/scratch buffers built across matching
lengths (collision proxies, AI gather rows, steering selected-work columns,
collision-response intent rows).

Pattern:

- Define a row struct with one field per column (`MovementBodyRow`,
  `ProxyRow`, `AiGatherRow`, and similar).
- Store `rows: std.MultiArrayList(Row)`; expose hot paths through `slice()` /
  `sliceConst()` helpers that return the existing column-slice structs
  (`ConstMovementBodySlice`, `ParticleSlice`, and similar).
- Reserve with `rows.ensureTotalCapacity(allocator, hotStoreCapacity(n))` where
  hot threading/SIMD ranges need item alignment (`alignItemCount` from
  `thread_system.zig`).
- Cold emit/setup (particles, world build, one-off row inserts) may use
  `rows.appendAssumeCapacity(row)` after `ensureTotalCapacity`.
- Hot gather loops must **not** call `rows.appendAssumeCapacity(row)` per row;
  use the fast-append helper instead (see below).
- A per-row store append uses a private `ensureCapacityForOne` +
  `appendAssumeCapacity`, never `ensureCapacity(n)` + plain `append` (which
  re-reserves internally and diverges from the sibling stores).
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
  and Release. Single-index cold accessors should still call `rows.slice()` once
  in the helper rather than `rows.items(.field)` directly.
- A per-row render/collect helper takes already-built const column slices from
  its caller and never calls `.slice()`/`.sliceConst()` itself: the rebuild hides
  behind the `pub` boundary (invisible to `idiom-lint`) and is dead work in
  ReleaseFast when it only feeds a stripped bounds assert.
- Hot gather append pattern (mandatory in per-step gather loops):

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

  Capture `var row_slice = rows.slice()` once before the gather loop and pass
  `&row_slice` into the helper. `MAL.appendAssumeCapacity` internally calls
  `set()`/`slice()` per row and has measured ~45% Debug regressions on gather
  paths; `addOneAssumeCapacity` + `set` avoids that overhead.
- Publish hot float column types as plain `[]f32` / `[]const f32`. Do not
  require `[]align(64) f32` on MAL column slices; MAL does not guarantee
  64-byte column bases. Range alignment (16 items) is for threading chunk
  boundaries; explicit wide memory loads may need separate alignment planning.
- Keep `deinit`, `clearRetainingCapacity`, and capacity helpers on the owning
  store — one MAL replaces many parallel `deinit` / `ensureTotalCapacity` calls.

### SIMD and core math

All vector operations and named math operations go through `core`:
`src/core/simd.zig` for vector types/ops and `src/core/math.zig` for reusable
scalar/vector math. This is unconditional and independent of how domain-specific
the calling system is — it keeps the math tested once and SIMD use consistent
(one lane width, no divergent copies). Do not declare raw `@Vector` in a system
or hand-roll a named primitive inline (gather/scatter, reciprocal/inverse sqrt,
length/normalize, trig, interpolation, clamp/saturating conversions, and the
like); if one is missing, add it to `core` with scalar-vs-SIMD parity tests and
keep the scalar and SIMD forms paired. A one-system composite kernel may stay in
its system, but assemble it from `core` primitives; promote a kernel reused
across systems. Plain operator arithmetic (`+ - * /`, including on the `simd`
vector types) is fine inline — the rule targets raw `@Vector` and named
primitives, not basic arithmetic.

Apply SIMD with scale in mind. Use the `src/core/simd.zig` helpers for dense,
uniform, branch-light float math over contiguous SoA columns, always with a
scalar tail — this is the pattern in movement, collision broadphase/narrowphase,
collision response, particle integration, and the pathfinding flow field. MAL
column slices are contiguous SoA; prefer codegen-friendly scalar-to-`@Vector`
loads in `simd.zig` unless a target-specific aligned load is measured and owned.
Prefer scalar code for tiny batches or simple logic where vectorization would
make the code harder to read.

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

## Budgets, Capacities, And Thresholds

These are three different things. The game is dig/build with cave-ins and
explosions, so dense multi-chunk terrain change in one step is normal
gameplay; size and bound for that.

**Per-step / per-query work budgets** (search node caps, solves per step,
links/spawns folded per step, and similar) **are fixed counts — never derived
from or scaled to world size, map size, level count, cell count, portal count,
band count, or any other measured "current scale."** Frame time is constant
whatever map is loaded; a budget that scales with the world makes big maps
slower per frame and makes behavior map-dependent. Use counts, not milliseconds
(time budgets are nondeterministic). This is a load-bearing, explicitly tested
invariant (grep `independent of` / `regardless of world size` — e.g. the
pathfinder's abstract A* node budget and `nav_graph.zig`'s incremental-dig
chunk-patch tests). Work that does not fit is deferred deterministically. When
a fixed budget is chronically insufficient, fix it with graceful degradation
(deterministic deferral / a bounded retry ladder) or an algorithmic change —
never a bigger number picked for one map.

**Data-structure capacities are right-sized per world instance**, never one
fixed size for every world. Two kinds:

- *World-extent data* (tiles, per-chunk nav, chunk tables, per-level data):
  sized exactly from the loaded world at init/load and never grown — dig/build
  changes contents, not extent.
- *Runtime-growing data* (population, items, particles, nodes, spawned
  structures, runtime links): start at the world/content-derived size plus
  headroom, then **grow only at a designated cold point** — the main-thread
  structural-commit seam, outside threaded stages — geometrically and ahead of
  need (e.g. at a fill threshold), or use paged/chunked storage that adds pages
  without moving data where a large realloc would spike a frame. Growth on a
  hot path or inside a threaded stage is a defect.

Between growth points hot paths stay allocation-free (the `FailingAllocator`
rule in [Allocator discipline](#allocator-discipline-mandatory-not-advisory)
still applies and proves exactly that). Capacity must never change behavior: no
iteration order, deferral, refusal, or result may depend on how much is
reserved. Fixed caps only for index/format widths (e.g. `u16`/`u32` indices,
save/replay layouts) proven unreachable for the loaded world extent, or a
platform memory ceiling; they fail loudly at load, never at a
gameplay-reachable point. No dig, build, cave-in, or explosion may be refused
for capacity. Exception: cosmetic effect pools that no simulation reads (e.g.
particles) may be fixed-capacity with deterministic overflow drop.

**Heuristic thresholds** (e.g. "build a group flow field above N agents")
derive from the cost of the operation they gate (its own bounded region or
input), never from the whole world's size.

**Decide per data structure, as an experienced engine programmer would.** Size
by lifetime and growth (world-extent exact; growing stores amortized-geometric
at a safe point, or paged); use pools, free lists, and generational handles for
churn; keep SoA contiguity over minimal footprint; use a fixed cap only when it
buys something (index width, stable format, per-frame work bound, platform
budget); back changes with a bench or memory number.

**Never change a constant just to satisfy this rule.** Default is keep.
Changing an existing budget/capacity/threshold needs a stated, concrete
performance or efficiency benefit (memory saved, an artificial limit removed,
fewer allocations or cache misses, simpler code) weighed against its cost and
risk (hot-path cost, layout/format churn, proof/test churn, determinism).

## Threading

When a collection is written from more than one thread, both of these must
hold and be verifiable by reading the call site, not just asserted in a
comment:

1. Writes are partitioned into disjoint per-worker or per-range slots — never
   a shared appendable collection written concurrently by more than one
   worker.
2. The matching `reserve`/`ensureTotalCapacity` call happens on the main
   thread strictly before the threaded dispatch, sized from the same
   selection/profile value the dispatch itself uses, so buffer size and
   worker/range count cannot drift apart across a future edit. Never reserve
   during or after dispatch.

New threaded hot-path code should open each worker job with a `std.debug.assert`
covering **both** its write range against the buffer length and `range.index`
against the dispatched range count, captured at dispatch time — a stage cloned
from a sibling routinely keeps one and drops the other, and the missing guard is
a silent OOB write in ReleaseFast rather than a Debug/ReleaseSafe panic. The
`FailingAllocator` proof must likewise exercise the real multi-worker
`ThreadSystem`, not only the serial/inline branch: an undersized reserve on the
threaded path fails as a concurrent shared-allocator call (a data race), not a
clean single-threaded OOM.

Merged output is deterministic from stable input and range order (count per
range → prefix offsets → contiguous write → range-index merge → batch commit),
never from worker timing, worker IDs, or per-command global atomics. Drive a
batched `RangeOutputStream`/`SimulationEvents` producer once per commit:
reserve and write every range, then call `finishWrite` a single time. A
record-per-item publish loop is O(N²), because `SimulationEvents.finishWrite`
rebuilds stats over all ranges (and, unlike `RangeOutputStream.finishWrite`,
survives ReleaseFast).

A threaded pass that emits **at most one output per input item** (a gather, a
stream compaction, a per-item command or contact) does not use per-range output
buffers at all: each range writes into its own `[range.start, range.end)` window
of one cache-line-aligned output buffer sized to the item count, stores its
count (and any diagnostics) in a cache-line-padded per-range tally, and the main
thread compacts the windows in range order (a forward copy, since the
destination never passes the source; no copy at all when nothing was excluded)
or streams them into the consuming `RangeOutputStream`. The buffer is sized by
the item capacity and the tallies by `thread_system.maxRangeCount(capacity,
alignment)` (every batch shape aligns its range size up to the alignment), so
one capacity-seam reserve covers every partition the tuner can pick and a
retune never allocates in-stage — there are no per-range buffers to warm. Only
a pass whose output count per item is data-dependent (the collision
broadphase's pairs) keeps per-range slots, reserved at the seam to the
per-item bound times the most items each range index can cover under any
partition (never clamped to the total), with overflow handled by a counted
grow-and-replay. Reference: `simulation_scope.zig`'s gathers and tier policy,
`spatial_index.zig`'s gather, `collision.zig`'s narrowphase (Slice 72 C5).

A pass whose events are a pure function of per-row state its workers already
write (perception's prev/final nearest-threat columns, affect's per-row crossing
bits) keeps no event scratch at all: the main thread derives and emits them in
row order after the join as one range, so nothing partition-sized exists to
reserve (Slice 72 I1/I2).

A partitioned processor that **emits an event stream** (not just scatters values
into disjoint slots) under a per-step cap has a second requirement beyond
disjoint writes: the merged emit order — and therefore which events survive the
cap — is canonical and partition-independent. Such processors emit in a stable
key order (per row, with a row's sub-kinds grouped, as
`PerceptionSystem.emitTransitionEvents` and `AffectSystem.emitCrossingEvents`
do) before applying the cap. Emitting one sub-kind or column at a time across a
whole range makes both the merged order and the capped membership depend on how
many ranges the tuner picked, so serial/threaded output diverges even though the
scatter is race-free. Parity
tests for these processors cross two or more event kinds for entities in
different ranges and include a capped case — a single-kind fixture is row-ordered
identically in both paths and hides the divergence.

Threaded/SIMD processors should iterate dense SoA columns directly. Component
masks are for membership/query decisions, not a replacement for direct slice
iteration in hot processors. Worker ranges should write disjoint rows and avoid
sharing writable cache lines in hot SoA columns. Use 64-byte padding only for
concurrently written thread-shared records where false sharing is a real risk.
Do not pad cold entity slot metadata by default.

Keep state transitions, entity structural changes, SDL/GPU/audio calls, asset
loading, save/load streaming, renderer resource ownership, and mixer resource
ownership out of threaded SIMD processors unless an explicit deferred or
main-thread boundary is designed. Workers never mutate `DataSystem`
structurally; structural commits are batched at the commit seam.

The main thread is not a fallback owner for work that lacks a better home.
Main-thread code must preserve a concrete boundary such as SDL/GPU/audio
ownership, state transitions, structural commits, asset loading, save/load
streaming, renderer resource ownership, or deliberately light orchestration.
Work that can scale with entity count, event count, asset count, draw count,
map size, file size, or tool complexity needs a named owner in app, game,
render, assets, platform, or tooling code. When it can become expensive, use
immutable inputs plus deterministic owned outputs instead of hiding the cost in
the frame coordinator or another convenient caller.

Work that scales with population, terrain change, or world size ships serial and
threaded paths in its first implementation, with serial/threaded parity tests.
The serial path also covers small batches, tests, and unsupported thread
targets. Small fixed-size or cold one-off work may stay serial; ask the owner if
unsure whether it scales.

Production worker participation should be driven by measured batch timing and
structural constraints. Do not add static item-count floors for worker
participation as a substitute for stage-owned tuning.

## Simulation Pipeline Stage Ordering

Mandatory, not advisory. `SimulationPipeline`'s `update()` runs a fixed stage
order over per-step
resources (navigation intents, movement intents, path requests, contacts, and
similar), where a later stage's correctness depends on an earlier stage having
already produced what it reads. This dependency is enforced at comptime, not
by convention: `simulation_pipeline.zig`'s `stageContract()` declares each
stage's resource reads, writes, and carried inputs, `stage_order` is a
permutation of `StageId`, and a `comptime` block walks `stage_order` failing
the build if any stage reads a resource no earlier stage writes. The pipeline is
the only fixed-step scheduler: do not add a scheduler beside it, and do not
promote it into a global ECS scheduler or app service.

`carried` is for a value this stage consumes that no earlier stage writes:
input captured before `update` (`action_intents`), world authoring
(`interest_markers`), or a column a later stage writes for the next step
(`ai_behavior` carried by `affect_update`). It is disjoint from that stage's
reads and writes. A resource an earlier stage already writes is a read.

Event payloads are four tags, not one `events` tag. A write of `world_events`
does not satisfy a read of `perception_events`, `affect_events`, or
`structural_events`. `structural_events` are the commit-seam payloads
(`entity_created`, `entity_destroyed`, `component_changed`) and are external
to the stage graph.

Every new or reordered `SimulationPipeline` stage must add, in the same
change:

1. The `PipelineResource` tag(s) it reads, writes, or carries (reuse an existing tag
   when it is the same coarse resource; do not add a redundant one-off tag).
2. Its `StageId` slotted into `stage_order` at the position its real
   dependencies require.
3. Its `stageContract()` arm declaring those reads/writes/carried inputs.
4. The stage method invoked from `runStage` (the `inline for` over
   `stage_order` inside `update()`).

`zig build check` catches a stage reading a resource before any earlier stage
produces it. Not every real ordering dependency is expressible as a
`PipelineResource` read/write (e.g. two stages that share no tracked resource
but still depend on call order). For those, add a targeted causal-effect
test: construct a scenario where the wrong order would produce an observably
different result, and assert the correct one. See `simulation_pipeline.zig`'s
"pipeline commits the dig stage's world edit before plane traversal reads it
in the same step", "pipeline runs ai_memory after perception and before ai",
and "pipeline runs affect after perception and ai_memory, before ai" tests
for the pattern.

## Resources And Error Handling

Pair every SDL/GPU/audio resource creation with its cleanup close to the owning
site, protect partially initialized resources with `errdefer`, and keep `defer`
cleanup next to the creation site. `@ptrCast`/`@alignCast`/`@intCast` carry a
local type or range justification. C strings passed to SDL are
sentinel-terminated and outlive the call.

Keep error sets meaningful and do not swallow errors where diagnosis matters.
Advance edge/latch state only on the fallible operation's success path
(`enqueue(...) catch return; latch = true;`), never after a swallowed error — a
latch that reads "active" while nothing was queued never re-triggers.

A config field whose zero default is also a valid domain value (e.g. `TileId` 0
is a real, blocking tile; the invalid sentinel is `maxInt`) defaults to the
domain's invalid sentinel and is assert-resolved at the use boundary, so an
unconfigured controller fails loudly instead of acting on 0. A boundary/config
validator bounds each scalar on both ends where its siblings do; a
present-but-wrong-typed optional field is an error, not a treated-as-absent
silent drop.

Remove callerless `pub` helpers, and do not keep a `pub` export whose doc
asserts a live contract that nothing references.

## Assets And Persistent Data

Runtime asset paths stay relative and traversal-safe.

Runtime gameplay and render-prep data store stable IDs such as `SpriteAssetId`
and `AudioAssetId`, not string paths, `TextureId`, `TextureLease`, prepared
sprite records, SDL_mixer handles, loaded audio handles, or renderer-owned
resources in persistent `DataSystem` storage. Convert stable IDs to renderer
texture IDs at the render-prep boundary, not in `DataSystem`.

`DataSystem` is the persistent gameplay-data owner (entity IDs, generations,
masks, dense typed SoA stores). App, render, SDL/GPU, input-frame, thread, and
event services, asset-loading state, and per-step scratch are never persistent
`DataSystem` fields; processors borrow `DataSystem` slices plus runtime
services.

## Logging

Route all runtime diagnostics through the central logger `src/core/logging.zig`
scoped loggers (`app`, `assets`, `audio`, `core`, `game`, `render`, `platform`,
`debug_overlay`, `perf`): `const log = @import("../core/logging.zig").render;`.
Never call `std.log`/`std.log.scoped(...)` directly or use `std.debug.print` for
engine/gameplay diagnostics (`std.debug.print` is for `src/benchmarks/` CLI
stdout only). `info`/`debug` for lifecycle/config/fallback, `warn` for recovered
degradation, `err` for real failures; keep pure helpers/validation log-free.

Hot and frame-adjacent paths carry no logging in **shipping** release
(`ReleaseFast` / `ReleaseSmall`) — those binaries have zero
per-frame/update/event/draw/entity/iteration log or perf-counter work. Such
instrumentation must be comptime-gated so it compiles out to a zero-sized no-op,
not skipped at runtime; `src/app/runtime_perf_log.zig` is the reference
(`enabled` is true for `Debug` and `ReleaseSafe`, false for
`ReleaseFast`/`ReleaseSmall`; the type and its `Context` go zero-sized when
disabled; per-frame work is counter increments; the formatted emit runs once per
interval). Which mode to use when (fix cycles, soaks, ship) is in
`docs/development-workflow.md` § Diagnostics And Log Levels.
`logging.enabled(level)` is comptime, so gate any non-trivially-formatted
diagnostic behind it — call and formatting both drop when the level is off.

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

Keep each comment as short as its contract allows. State the rule or invariant
and, when non-obvious, the one reason it holds; put proofs, worked arithmetic,
rejected alternatives, and design history in the owning slice doc or the
commit message, not in code. Slice docs record decisions and checklists, not
the full reasoning trail that produced them.

## Tests

Use Zig `test` blocks and `std.testing`. Put reusable module tests beside the
code they cover, and name tests by behavior, such as
`test "player movement clamps to window bounds"`.

Prefer focused tests for contracts that do not require opening a window: input
routing, state policy flow, transition ordering, resource ID validation,
viewport math, descriptor validation, asset path validation, timing decisions,
and pure gameplay/data contracts. Keep display/GPU checks in `gpu-smoke`.

Keep `WorldSystem`/`DataSystem` test fixtures at the smallest size that still
exercises the behavior under test — do not build out a full or large game world
per test. `chunksX`/`chunksY` is `ceilDiv(width, chunk_size_tiles)`, so a `1x1`
(or otherwise minimal) `WorldSystem` still yields exactly one real chunk, enough
for chunk-gate/visibility tests without a bigger tile grid. Reserve a larger
populated world for the one test that specifically needs structural
growth/capacity behavior at scale (e.g. a `FailingAllocator` reserve-proof
test). Fast, small fixtures keep `zig build test` fast as the suite grows.

Unit tests must never build production-scale worlds. Do not call
`initProcedural`, `initProceduralFromMeta`, `initProceduralWithRuntimeAssets`,
or loading/gameplay paths that construct the full procedural world with a
production-scale `WorldBuildConfig` (or equivalent) in `zig build test`. These
entry points take an explicit world-size/level-count config, so a test may
call them with a minimal config — at most 16x16 tiles and 1 underground level,
matching the compact-fixture threshold `worldUsesCompactDemoSpawn` already
uses elsewhere in this codebase — when it genuinely needs to exercise the real
code path (e.g. state-transition wiring), rather than a hand-built
`WorldSystem` fixture that would bypass that path — but never with the real
production config or anything approaching it. Prefer minimal hand-built
`WorldSystem` fixtures, small demo patches, or pure contract checks when the
real procedural/loading path isn't itself under test; full world build and
throughput validation belong in `zig build bench`.

Production contracts must expose runtime concepts only. Do not add test-only
enum tags, union payloads, marker fields, fake stages, fixture hooks, service
shortcuts, or test-only paths to production APIs. Tests should use private
helper types, local fixtures, test-only mocks, or real runtime payloads without
changing the shape of app, game, render, asset, platform, or tool contracts.

Test code never measures timing and never calls into `src/benchmarks/` (see
[Benchmarks](#benchmarks)).

## Benchmarks

`zig build bench` is for performance and OOM/leak-sweep checks; `zig build test`
is for fast contract/correctness checks only. Never measure or report
performance by hand-rolling a timer inside a `zig build test` test — not even
temporarily, not even with `-Doptimize=ReleaseFast`. All performance numbers
come from `zig build bench`, which provides warmup, repeated iterations, and
adaptive-settle statistics (`src/benchmarks/suite.zig`) that a one-off timed
test block does not.

Test code never calls into `src/benchmarks/*.zig` functions at all — not just
to avoid hand-timing: a benchmark file's fixture builders (`createFixture`,
`initFixture`, etc.) and case runners build large synthetic fixtures meant for
throughput measurement, and calling them from `zig build test` makes the whole
suite slow even without timing code. The one exception is `suite.zig`'s own
tests, which cover only its pure utility logic (arg parsing, formatting,
alignment math) against hand-built stubs, never a real fixture. If a
correctness property belongs to production code, test it in the owning
production module with a small hand-built fixture; if it is
benchmark-fixture-specific (e.g. does this fixture shape still assert
correctly), rely on the module's own internal `std.debug.assert` firing during
an actual `zig build bench` run instead of wrapping it in a test. If a perf
question needs answering and no benchmark case covers it yet, add or extend one
under `src/benchmarks/` and run it via `zig build bench`.

Run targeted benchmarks: `zig build bench -- --group <name>` (optionally
`--case`/`--items`). Do not run the whole suite and filter its output unless
explicitly asked or doing a deliberate OOM/capacity sweep. Bench only changes
that can move a hot path, with targeted groups and 3 interleaved reps.

Benches at target scale ship with a feature's first implementation, not as a
follow-up. Cover destruction-shaped workloads (an explosion region in one step,
repeated dig/fill) where terrain change is involved. Large-scale benches (e.g.
the 50k item scales) are stress tests and throughput ceilings, not per-frame
targets: weight a result by how often that workload really occurs at that
count. Population-driven systems (AI, perception, collision) are where large
counts are real; rare growth steps such as nav repacks are not.

## Generated Output And Configuration

`zig-out/` and `.zig-cache/` are generated output and should not be edited by
hand. Do not commit generated binaries or local machine paths.

If adding dependencies to `build.zig.zon`, keep hashes accurate and review the
fingerprint carefully because it affects project identity.
