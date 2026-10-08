---
paths:
  - "src/**/*.zig"
  - "build.zig"
---

# Memory And Performance

## Hot paths

- Performance is correctness on hot and frame-adjacent paths: fixed-step
  update, input dispatch, render submission, asset lookup, text/debug overlay.
- Hot paths are allocation-free after init, reserve, or warmup.
- Growth happens only at a named seam outside per-item loops (the
  structural-commit seam, or a main-thread pre-reserve before a submission
  pass), geometrically ahead of need and counted. Growth anywhere else on a hot
  path or in a threaded stage is a defect.
- Fix per-frame cost by moving work to init, load, transitions, or caches,
  never by a per-frame workaround.
- No per-frame, per-event, per-draw, or per-processor-loop string lookup,
  hash-map dispatch, broad dynamic dispatch, callback chains, repeated
  descriptor validation, formatted logging, or resource churn unless measured,
  bounded, and isolated. Use enums, bitsets, arrays, slices, direct indices,
  ring buffers, prepared resources, stable asset IDs, and generational handles.
- Keep fixed-step simulation separate from render cadence; no broad frame-rate
  cap unless it preserves a named boundary and is measured.

## Allocator discipline

- Every `reserve`/`ensureTotalCapacity` + `assumeCapacity` (or
  `addOneAssumeCapacity`) pairing ships in the same change with a
  `std.testing.FailingAllocator` test proving the warmed path allocates
  nothing; ReleaseFast strips the assert, so a comment is not proof.
- With reserve and commit in separate functions, the proof covers the success
  branch: reserve, arm the allocator to fail, assert the push completes.
- Behavior gates compare a stored logical limit, never physical `.capacity`
  (std rounds capacity up, so the two drift); assign the limit only after its
  reserve succeeds and `std.debug.assert(list.capacity >= limit)`.
- A `.capacity` read that only picks `appendAssumeCapacity` vs `append` with
  identical results is not a gate.
- A pool backed by a separately reserved dedup/probe table gates appends on the
  shared logical cap and honors the probe's insert-bool.
- A reserve/overflow contract's assert and overflow check bound the same
  quantity.
- `unreachable`, `catch`/`orelse unreachable`, and `.?` only where the state is
  impossible by construction; it is UB in ReleaseFast. Recoverable or
  data-influenced failures return an error or assert. `idiom-lint` accepts
  non-test `catch`/`orelse unreachable` only on the capacity-bounded handle
  constructors (`TextureId`, `FontId`, `TextTextureId`, `EntityId`,
  `LeaseHandle` `.init`) or with `// lint:allow catch-unreachable: <reason>`;
  never annotate a recoverable failure.
- In hot or worker loops, capture an optional as a non-optional local at
  dispatch or assert it non-null at entry; never rely on cross-thread ordering.
- Widen signed spans to `i64`/`usize` before subtracting, clamp while wide,
  then `@intCast`.
- Allocating structs take a `std.mem.Allocator` at `init` and store it
  immediately, never `undefined`.
- Never use `page_allocator`, `c_allocator`, or a fresh
  `GeneralPurposeAllocator` inside a function, even cold; thread the caller's (a
  local `ArenaAllocator` over it is fine).
- Register each `errdefer` right after its field is constructed, never a blanket
  `errdefer self.deinit()` before all fields exist (leak or double free).
- A caller's `defer` cleanup of an allocated container follows the fallible
  `init`, with a narrower `errdefer` before it.
- A function taking ownership of a by-value resource opens with
  `errdefer <res>.deinit()`.
- After ownership transfers (`put`, `append`, lease commit), disarm the earlier
  `errdefer` with a per-iteration bool (else double free).
- A handle-owning setter asserts its slot empty or closes the prior handle.

## Dense SoA storage

- Use `std.MultiArrayList` (MAL) when columns grow, shrink, and swap-remove
  together as one row: `DataSystem` stores, dense pools, same-length per-step
  gather/scratch buffers.
- Keep intentionally different layouts off MAL: hot/cold splits, striped or
  arena buffers, padded range slots, spatial hash grids, pair streams, existing
  AoS pools, sparse slot maps.
- Store `rows: std.MultiArrayList(Row)` with one field per column; expose hot
  paths through `slice()`/`sliceConst()` column-slice helpers.
- Reserve with `hotStoreCapacity(n)` where threading/SIMD ranges need item
  alignment.
- Call `rows.slice()` once per stage, function, or accessor; never
  `rows.items(.field)` in a loop. Per-row helpers take const column slices from
  the caller and never call `.slice()`.
- Hot gather loops capture `var row_slice = rows.slice()` once and append with
  `appendMalRow` (below), never `appendAssumeCapacity`. A per-row store append
  uses a private `ensureCapacityForOne` + `appendAssumeCapacity`, never
  `ensureCapacity(n)` + `append`.
- Compact with `swapRemove` when order does not matter; keep `deinit`,
  `clearRetainingCapacity`, and capacity helpers on the owning store.
- Publish hot float columns as `[]f32`, never `[]align(64) f32`; MAL does not
  guarantee aligned column bases.

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

## SIMD and core math

- All vector and named math goes through `src/core/simd.zig` and
  `src/core/math.zig`; plain operators are fine inline.
- Never declare raw `@Vector` in a system or hand-roll a named primitive
  (gather/scatter, inverse sqrt, normalize, trig, interpolation, clamp,
  saturating conversion).
- Add a missing primitive to `core` as a paired scalar and SIMD form with
  parity tests. A one-system kernel built from `core` primitives may stay
  local; promote it once reused.
- Use `simd.zig` helpers with a scalar tail for dense uniform float math over
  SoA columns; prefer scalar for tiny batches or simple logic.
- Prefer scalar-to-`@Vector` loads unless an aligned load is measured and
  owned.
- Judge per-agent and per-neighbor loops at target scale, never as "low count".
- Vectorize a gather-bound or branchy hot per-agent loop by gathering into
  packed local SoA scratch and masking branches with `select`.
- Leave scalar only irreducible loops (A*/BFS frontier, compaction, rare
  setup), stating why.
- A new or restructured hot float loop ships scalar/SIMD and serial/threaded
  parity tests.
- Never add a helper that only wraps plain arithmetic.
