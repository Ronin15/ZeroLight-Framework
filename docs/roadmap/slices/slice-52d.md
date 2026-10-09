## Slice 52D: SIMD Layer Codegen For The v2 Release Baseline

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 52A](slice-52a.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Needs 52A's `-Dcpu-baseline` (until then the same
commands work with `-Dcpu=x86_64_v2` / `-Dcpu=x86_64`). Land before Slice 35
(its kernels are mask/select-heavy) and before 52C records cross-baseline
digests (the trig change moves last bits once). If 49 lands first, re-baseline
49's checksum goldens in the sin/cos commit.

Goal: every `src/core/simd.zig` primitive lowers to the shortest libcall-free
sequence the `ship` baseline offers and stays libcall-free on `compat`; every
result of the layer, sin/cos included, is bit-identical across `x86_64`,
`x86_64_v2`, `x86_64_v3`, native, Debug (self-hosted backend), and
`apple_m1`. A `zig build simd-asm-check` step in `verify` holds that line, and
`simd-*` bench groups measure it. This closes the sin/cos part of 49's
cross-machine caveat.

### Current foundation

- `core/simd.zig` (19 importers): `lane_count = 4`; every helper is a plain
  `pub fn`. `floorToI4` calls `@floor` plus four saturation patches; `divInt4`
  divides per lane; `minFloat4`/`maxFloat4` use `@min`/`@max`;
  `sinFloat4`/`cosFloat4`/`sinCosFloat4` use `@sin`/`@cos` and have no callers.
  `core/math.zig`: branchy `floorToI32`, `clampMinMax` as `@min(@max(..))`,
  `sinCos` via `@sin`/`@cos`, `atan2` as pure-Zig `std.math.atan2` (no libm,
  no FMA on its scalar path).
- Callers: `divInt4` only in `deriveChunkJob` (`systems/simulation_scope.zig`)
  with a runtime power-of-two `chunk_size_tiles` divisor (at most 16);
  `floorToI4` in the spatial index and steering; `math.sinCos` in `rng.unitVec2`
  (AI wander), perception `cos_half_fov`, sprite rotation, and the debug
  overlay; raw `@sin` in `ai_debug_overlay.zig`; runtime-bound
  `math.clampMinMax` in steering.
- Trig provenance: Linux and Windows binaries carry static compiler-rt
  `sinf`/`cosf`/`sincosf`; aarch64-macOS calls Apple libSystem
  (`__sincosf_stret`) at runtime, so results depend on the installed OS.
- Design-time codegen audit (Zig 0.17.0 ReleaseFast, scratch harness;
  re-measure at landing):
  - Zig's LLVM backend passes a `@Vector(4, bool)` across a non-`inline`
    function boundary through an `i8` alloca created before inlining; on x86
    every Mask4 hand-off costs about 6 extra ops (aarch64 folds it), erasing
    v2's single-op blend. `inline fn` removes it.
  - SSE2 has no vector floor, so `floorToI4` makes four `floorf` calls on
    `compat`; `divInt4` is four scalar divides on every target; sin/cos are one
    libcall per lane.
  - Float `@min`/`@max` lower to `minnum`/`maxnum`; `clamp(-0, +0, 1)` gives −0
    with runtime bounds on x86 and +0 with constant bounds, on M1, and at
    comptime.
  - No FMA, rsqrt/rcp estimate, or hardware gather anywhere; unaligned loads
    are already optimal.
  - A prototype of the changes below was exact against references (exhaustive
    over all f32 for floor; every divisor 1..65535 with edge dividends for
    division), kept sin/cos within 1e-7 absolute and 2 ulp, passed the full
    suite with no re-baselining, and cut the floor, chunk-division, clamp, and
    sin/cos kernels by roughly 40–89%.

### Architecture notes

- Owners: `core/simd.zig` and `core/math.zig` own every primitive change;
  `simulation_scope.zig` owns the one divisor caller migration and the debug
  overlay gets a one-line trig swap; tooling in `tools/` and `build.zig`; bench
  in `src/benchmarks/simd.zig`. No stage, store, threading, or allocation
  change.
- Decisions:
  - Every function whose signature carries `Mask4` or `@Vector(_, bool)` is
    `inline fn`, kept even after an upstream fix (free on every compiler,
    protects older pins).
  - `floorToI4` is libcall- and round-trip-free on both baselines with
    identical integer results for every input; `floorToI32` delegates to it
    (single-source parity).
  - Float `min`/`max`/`clamp` use select forms pinning x86 `MINPS`/`MAXPS`
    semantics (NaN in the first operand yields the second; ties including ±0
    yield the second), so comptime, runtime, x86, and arm64 agree.
  - A uniform-divisor reciprocal multiply replaces `divInt4`, exact for every
    non-negative dividend below 2^31; `divInt4` is deleted.
  - sin/cos become a deterministic polynomial with a fixed op order pinned by
    golden-bit tests; `math.sinCos` delegates to lane 0.
  - Kept: true division and sqrt (no estimates, which differ between vendors),
    scalar-load gather, unaligned loads, SSE2 integer emulations on `compat`,
    unfused lerp/dot.
- Determinism impact: sin/cos last bits change once (up to 2 ulp on a small
  fraction of inputs); float min/max/clamp change only on ±0 ties and NaN
  bounds; floor and division are exact.
- Enforcement: a determinism contract header on `simd.zig`; lint rules
  `LIBM_BUILTIN` (libm-backed builtins in `src/` outside tests) and
  `MASK_FN_NOT_INLINE`; 52A's float-mode rules land with whichever slice is
  first. `simd-asm-check` builds a probe object for `x86_64`, `x86_64_v2`,
  `x86_64_v3`, and `apple_m1` independent of `-Dtarget`, and fails on calls,
  FMA, estimates, hardware gather, mask round trips, missing true sqrt/div, a
  scalar divide in the divisor probe, or an instruction count over budget
  (measured + max(2, 25%); a raised budget carries the new table in its
  commit).
- Bench groups land first against the current API, so every later commit
  compares adjacent commits (archive Slice 34). Serial only; kernels mirror
  their production callers; item ladder spans L1, L2, and DRAM.
- Out of scope: loop restructures (35); scalar float min/max outside `core`,
  FP environment (64A); NaN canonicalization (64B); vector `atan2` (64D);
  wider lanes.

### Checklist

- [ ] `simd-*` bench groups (floor-cell, world-to-chunk, clamp-select,
      normalize, sincos, sincos-scalar, gather-scatter, count-true) registered,
      with a `ship` and `compat` baseline recorded; no production change.
- [ ] Mask4 helpers `inline` and the `MASK_FN_NOT_INLINE` rule.
- [ ] (added by Slice 64) Upstream Zig issue filed (or an existing one joined)
      with the minimal repro, its URL in Status, and the repro in
      `tools/README.md`; the lint rule cites it and stays after a fix.
- [ ] `floorToI4` rewrite and `floorToI32` delegation, both floor paths tested
      against a private reference on special values, boundaries, and a seeded
      sweep.
- [ ] Select-form `min`/`max`/`clamp` and `clampMinMax`, tested on runtime
      inputs for ±0 and NaN bits, scalar equal to lane 0.
- [ ] Uniform divisor, `deriveChunkJob` migration, `divInt4` removed; divisor
      tests and a non-power-of-two chunk-size scope test; existing scope parity
      and `FailingAllocator` tests pass.
- [ ] Polynomial sin/cos and `math.sinCos` delegation, the debug-overlay swap,
      and `LIBM_BUILTIN`; golden-bit, f64-reference, symmetry, signed-zero,
      non-finite, and lane-equality tests.
- [ ] `simd-asm-check` probe, checker, and `verify` wiring.
- [ ] Determinism contract header on `simd.zig` and corrected doc comments.
- [ ] Docs: Determinism Contract (sin/cos no longer a caveat; symbol facts;
      residual hazards owned by 64A, 64B, 64D); DW `simd-asm-check` and bench
      procedure; `docs/architecture.md` core line; `CLAUDE.md` command.
- [ ] Add the SIMD codegen and determinism rule (inline Mask4, select-form
      min/max, no libm builtins or estimates, `simd-asm-check`, cross-target
      bit identity) to `.claude/rules/memory-performance.md` when this lands.

### Acceptance checks

- [ ] `zig build verify` passes with `simd-asm-check` within budget on all four
      targets and the new lint rules.
- [ ] `zig build test` passes in Debug, ReleaseFast `ship`, ReleaseFast
      `compat`, and ReleaseSafe `x86_64_v3` (informational).
- [ ] `zig build test` passes on Apple Silicon with the same golden constants
      (52C macOS job or a manual run recorded in Status).
- [ ] `zig build check -Doptimize=ReleaseFast -Dcpu-baseline=compat` compiles.
- [ ] Each new lint rule fires on a temporary, uncommitted edit.
- [ ] Bench gate on adjacent commits (ReleaseFast, `serial-direct`, pinned
      core, interleaved repetitions, medians, at `ship` and `compat`): the
      floor, chunk-division, clamp, and sin/cos kernels improve beyond
      run-to-run spread across the ladder; normalize and gather-scatter stay
      within spread; system groups (spatial index, scope, perception,
      steering, collision, affect, particles, movement, AI, render prep) show
      no regression beyond spread unless the hot function's disassembly is
      identical or a strict subset (layout noise). Tables in Status.
