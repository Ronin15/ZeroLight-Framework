# Memory And Performance

## Data-oriented design

- Design data-first: name the data each hot loop reads and writes and its read
  order, store it as dense SoA columns in that order (§ Dense SoA storage), and
  stream it in batches (§ SIMD and core math). Data is grouped by its storage
  unit where it has one (the chunk `(level, cx, cy)` for terrain, nav, and
  spatial data); within it, keys a loop filters on (level, faction, kind)
  order the data ahead of position, so a filtered loop streams contiguous runs
  whole in SIMD lanes.
- A hot loop pays no per-item indirection: no pointer or linked-list walk, no
  read through an index permutation, no per-row lookup into another store; a
  stage needing another store's columns gathers them once into packed scratch.
  Inherently indirect access is exempt: search frontiers, pair streams, hash
  point lookups.
- A layout that fails either bullet fails the design and is fixed in the
  layout.

## Hot paths

- Performance is correctness on hot and frame-adjacent paths: fixed-step
  update, input dispatch, render submission, asset lookup, text/debug overlay.
- Hot paths are allocation-free after init, reserve, or warmup. Growth happens
  only at a named seam outside per-item loops (the structural-commit seam, or
  a main-thread pre-reserve before a submission pass), geometrically ahead of
  need and counted; growth anywhere else on a hot path or in a threaded stage
  is a defect.
- Fix per-frame cost by moving work to init, load, transitions, or caches,
  never by a per-frame workaround.
- No per-frame, per-event, per-draw, or per-processor-loop string lookup,
  hash-map dispatch, broad dynamic dispatch, callback chains, repeated
  descriptor validation, or resource churn unless measured, bounded, and
  isolated; formatted logging there only in Debug and ReleaseSafe, behind its
  level gate (`zig-style.md` § Logging). Use enums, bitsets, arrays, slices, direct indices,
  ring buffers, prepared resources, stable asset IDs, and generational handles.
- Authoring data (names, catalogs, AI archetypes) resolves at load or setup
  into enums, tables, and numeric IDs; hot paths never parse or hash names.
- Fixed-step simulation stays separate from render cadence: fixed update never
  runs at render cadence, and no broad frame-rate cap unless it preserves a
  named boundary and is measured.

## Allocator discipline

- Every `reserve`/`ensureTotalCapacity` + `assumeCapacity` (or
  `addOneAssumeCapacity`) pairing ships in the same change with a
  `std.testing.FailingAllocator` test proving the warmed path allocates
  nothing (ReleaseFast strips the assert; a comment is not proof). With
  reserve and commit in separate functions, the proof covers the success
  branch: reserve, arm the allocator to fail, assert the push completes.
- Behavior gates compare a stored logical limit, never physical `.capacity`
  (std rounds it up, so the two drift); assign the limit only after its reserve
  succeeds, and `std.debug.assert(list.capacity >= limit)`. A `.capacity` read
  that only picks `appendAssumeCapacity` vs `append` with identical results is
  not a gate.
- A pool backed by a separately reserved dedup/probe table gates appends on the
  shared logical cap and honors the probe's insert-bool. A reserve/overflow
  contract's assert and overflow check bound the same quantity.
- `unreachable`, `catch`/`orelse unreachable`, and `.?` only where the state is
  impossible by construction (it is UB in ReleaseFast); recoverable or
  data-influenced failures return an error or assert. `idiom-lint` accepts
  non-test `catch`/`orelse unreachable` only on the capacity-bounded handle
  constructors it lists or with `// lint:allow catch-unreachable: <reason>`;
  never annotate a recoverable failure.
- In hot or worker loops, capture an optional as a non-optional local at
  dispatch or assert it non-null at entry; never rely on cross-thread ordering.
- Widen signed spans to `i64`/`usize` before subtracting, clamp while wide,
  then `@intCast`.
- Allocating structs take a `std.mem.Allocator` at `init` and store it
  immediately, never `undefined`. Never use `page_allocator`, `c_allocator`,
  or a fresh `GeneralPurposeAllocator` inside a function, even cold; thread the
  caller's (a local `ArenaAllocator` over it is fine).
- Register each `errdefer` right after its field is constructed, never a
  blanket `errdefer self.deinit()` before all fields exist (leak or double
  free). A caller's `defer` cleanup of an allocated container follows the
  fallible `init`, with a narrower `errdefer` before it. A function taking
  ownership of a by-value resource opens with `errdefer <res>.deinit()`. After
  ownership transfers (`put`, `append`, lease commit), disarm the earlier
  `errdefer` with a per-iteration bool (else double free).
- A handle-owning setter asserts its slot empty or closes the prior handle.

## Dense SoA storage

- Use `std.MultiArrayList` (MAL) when columns grow, shrink, and swap-remove
  together as one row: `DataSystem` stores, dense pools, same-length per-step
  gather/scratch buffers. Keep intentionally different layouts off MAL:
  hot/cold splits, striped or arena buffers, padded range slots, spatial hash
  grids, pair streams, existing AoS pools, sparse slot maps.
- Store `rows: std.MultiArrayList(Row)` with one field per column; expose hot
  paths through `slice()`/`sliceConst()` column-slice helpers. A store whose
  ranges thread or run SIMD reserves an item-aligned capacity.
- Call `rows.slice()` once per stage, function, or accessor, never
  `rows.items(.field)` in a loop; per-row helpers take const column slices from
  the caller and never call `.slice()`.
- Hot gather loops capture the row slice once and add rows on it, never
  `appendAssumeCapacity`; a per-row store append reserves one row, then
  appends assuming capacity, never reserves `n` and then appends (both
  patterns: `docs/architecture.md` § Gameplay Data).
- Compact with `swapRemove` when order does not matter; keep `deinit`,
  `clearRetainingCapacity`, and capacity helpers on the owning store.
- Publish hot float columns as `[]f32`, never `[]align(64) f32`; MAL does not
  guarantee aligned column bases.

## SIMD and core math

- All vector and named math goes through `src/core/simd.zig` and
  `src/core/math.zig`; plain operators are fine inline. Never declare raw
  `@Vector` in a system or hand-roll a named primitive (gather/scatter, inverse
  sqrt, normalize, trig, interpolation, clamp, saturating conversion), and
  never add a helper that only wraps plain arithmetic.
- Add a missing primitive to `core` as a paired scalar and SIMD form with
  parity tests. A one-system kernel built from `core` primitives may stay
  local until reused.
- Dense uniform float math over SoA columns uses `simd.zig` helpers with a
  scalar tail; a loop whose results feed a lane consumer ends in one masked
  lane batch instead, so the consumer has one lane path. Prefer scalar for
  tiny fixed-size batches; short runs inside a population loop are a layout
  problem, fixed in the layout.
- Prefer scalar-to-`@Vector` loads unless an aligned load is measured and
  owned.
- Judge per-agent and per-neighbor loops at target scale, never as "low count".
  Vectorize a gather-bound or branchy hot per-agent loop by gathering into
  packed local SoA scratch and masking branches with `select`.
- A SIMD loop's results stay in lanes (vectors plus a pass mask) through their
  consumer; draining them into per-item scalar calls or branches fails the
  loop's shape.
- Leave scalar only irreducible loops (A*/BFS frontier, compaction, rare
  setup), stating why.
- SIMD or scalar is decided by the loop's shape, never by Debug timings (SIMD
  gains come with scale and release builds; benches run in Debug), so a Debug
  slowdown never reverts a SIMD-shaped loop. A choice that needs a number
  gets the targeted ReleaseFast run (`build-validation.md`), with the reason
  at the site.
- A new or restructured hot float loop ships scalar/SIMD and serial/threaded
  parity tests.
