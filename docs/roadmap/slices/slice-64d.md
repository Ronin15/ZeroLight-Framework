## Slice 64D: Deterministic Vector `atan2`

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 52D](slice-52d.md) (gated on the first simulation `atan2` consumer) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started — gated on the first simulation consumer of `atan2`.**
The gate opens when a slice adds an arc-tangent call from a `src/game/` module
that writes `DataSystem`, `WorldSystem`, frame streams, or pipeline history
(render-only readers such as the debug overlay and render prep do not count).
That slice lists 64D as a prerequisite and lands it first or in the same
change.

Goal: when the simulation first needs an angle from a vector, it gets an
`atan2` that is bit-identical across every supported target and between its
SIMD lanes and scalar tail, and never goes through `std.math.atan`'s vector
path, which uses `@mulAdd` and lowers to per-lane `fmaf` calls on
`x86_64_v2`.

### Current foundation

- `math.atan2` (`core/math.zig`) wraps `std.math.atan2`, a scalar musl port on
  IEEE basic ops; its only caller is the render-only facing angle in
  `ai_debug_overlay.zig`. No simulation module calls an arc-tangent, and 64A's
  `STD_MATH_TRANSCENDENTAL` lint keeps every one behind `core/math.zig`.
- 52D supplies the pieces this builds on: the `simd.zig` determinism header,
  select-form helpers, golden-bit tests that pin op order, `simd-asm-check`
  budgets, and `src/benchmarks/simd.zig`.
- A design-time prototype (minimax polynomial in fixed op order, evaluated
  unfused) measured at most 2 ulp over a wide random sweep, special values
  bit-exact with `std.math.atan2` except `atan2(±inf, finite)`, identical
  digests across `x86_64`, `x86_64_v2`, `x86_64_v3`, native, and Debug, and
  no calls or FMA on any target. Re-measure at landing.

### Architecture notes

- `simd.atan2Float4` lives in `core/simd.zig` beside 52D's `sinCosFloat4`;
  `math.atan2` returns its lane 0, so scalar and SIMD share one source (52D's
  `sinCos` pattern). The render-only caller moves by at most the kernel's ulp
  bound.
- Contract documented on the kernel: accuracy bound, the special-value table,
  and NaN results with unspecified sign and payload (64B canonicalizes NaN in
  the checksum).
- No allocation, state, or RNG; IEEE ops and selects only
  (`.claude/rules/memory-performance.md` § SIMD and core math).
- The consuming slice's SIMD kernel uses `atan2Float4` and its scalar tail
  `math.atan2`, and it adds its own serial-vs-threaded parity test
  (`.claude/rules/threading.md`).

### Checklist

- [ ] `simd.atan2Float4` and `math.atan2` delegation with the contract in doc
      comments. Tests on runtime inputs: golden bit patterns (exact `u32`),
      within 2 ulp of an `f64` reference over a seeded sweep plus axis and
      diagonal directions at extreme magnitudes, the special-value table, lane
      independence, and `math.atan2` equal to lane 0 bit for bit.
- [ ] `probe_atan2Float4` in `simd-asm-check` with its budget row.
- [ ] `simd-atan2` bench group (52D conventions: serial, L1/L2/DRAM ladder)
      with a `std.math.atan2` scalar row for comparison.
- [ ] The consumer's kernel and scalar tail use the pair, with its parity test.
- [ ] Docs: Determinism Contract (`atan2` is a deterministic polynomial).

### Acceptance checks

- [ ] `zig build verify` passes with `probe_atan2Float4` within budget on all
      four `simd-asm-check` targets.
- [ ] `zig build test` passes in Debug, ReleaseFast `ship`, ReleaseFast
      `compat`, and on Apple Silicon (52C macOS job or a manual run recorded in
      Status).
- [ ] `zig build -Doptimize=ReleaseFast bench -- --group simd-atan2` is
      recorded in Status, showing the SIMD kernel's scaling across the ladder
      against the scalar row.
