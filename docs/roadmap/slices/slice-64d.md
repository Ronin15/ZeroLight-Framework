## Slice 64D: Deterministic Vector `atan2`

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 52D](slice-52d.md) (gated on the first simulation `atan2` consumer) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started — gated on the first simulation consumer of `atan2`.**
The gate opens when a slice adds a call to `math.atan2`, `simd.atan2Float4`,
or any arc-tangent from a `src/game/` module that writes `DataSystem`,
`WorldSystem`, `SimulationFrame` streams, or pipeline-history state. That
excludes `ai_debug_overlay.zig`, `render_prep.zig`, and other render-only
readers. The consuming slice lists 64D as a prerequisite and lands it first
or in the same change. Technical prerequisite: **52D** (`simd-asm-check`,
the inline Mask4 rule, `src/benchmarks/simd.zig`).

Goal: when the simulation first needs an angle from a vector, it gets an
`atan2` that is bit-identical across every supported target and between its
SIMD lanes and scalar tail. It must never go through `std.math.atan`'s vector
path, which uses `@mulAdd` (`lib/std/math/atan.zig:621-628`) and lowers to
per-lane `fmaf` compiler-rt calls on `x86_64_v2`.

### Current foundation (do not rebuild)

- Audit (grep of `src/` at design time): `math.atan2` (`core/math.zig:
  160-162`, `std.math.atan2`, scalar musl port with IEEE basic ops only) has
  one caller, `ai_debug_overlay.zig:112` (render-only facing angle). No
  simulation module calls `atan2`/`atan`. 64A's `STD_MATH_TRANSCENDENTAL` lint
  keeps every arc-tangent behind `core/math.zig`.
- 52D's conventions apply: `simd.zig` determinism header, select-form
  helpers, golden-bit tables that fix the op order, and `simd-asm-check`
  budgets of measured + max(2, 25%).

### Architecture notes

**Kernel (`src/core/simd.zig`; op order is normative).** Constants are the
ARM optimized-routines `atanf` minimax set already used by
`std.math.atan`'s vector path, evaluated unfused in strict mode:

```zig
const atan_c0: f32 = -0x1.5554dcp-2;
const atan_c1: f32 = 0x1.9978ecp-3;
const atan_c2: f32 = -0x1.230a94p-3;
const atan_c3: f32 = 0x1.b4debp-4;
const atan_c4: f32 = -0x1.3550dap-4;
const atan_c5: f32 = 0x1.61eebp-5;
const atan_c6: f32 = -0x1.0c17d4p-6;
const atan_c7: f32 = 0x1.7ea694p-9;
const half_pi_f32: f32 = 0x1.921fb6p0; // 0x3fc90fdb
const pi_f32: f32 = 0x1.921fb6p1;      // 0x40490fdb, exactly 2 * half_pi_f32

pub fn atan2Float4(y: Float4, x: Float4) Float4 {
    const sign_mask: Uint4 = @splat(0x8000_0000);
    const y_bits: Uint4 = @bitCast(y);
    const x_bits: Uint4 = @bitCast(x);
    const ay: Float4 = @bitCast(y_bits & ~sign_mask);
    const ax: Float4 = @bitCast(x_bits & ~sign_mask);
    const swap = greaterThanFloat4(ay, ax);
    const num = selectFloat4(swap, ax, ay);
    const den = selectFloat4(swap, ay, ax);
    const den_safe = selectFloat4(equalFloat4(den, splatFloat4(0)), splatFloat4(1), den); // both zero → 0/1
    const t = num / den_safe;                                  // [0, 1]
    const t2 = t * t;
    var p = splatFloat4(atan_c7);
    p = splatFloat4(atan_c6) + t2 * p;
    p = splatFloat4(atan_c5) + t2 * p;
    p = splatFloat4(atan_c4) + t2 * p;
    p = splatFloat4(atan_c3) + t2 * p;
    p = splatFloat4(atan_c2) + t2 * p;
    p = splatFloat4(atan_c1) + t2 * p;
    p = splatFloat4(atan_c0) + t2 * p;
    const r0 = t + (t * t2) * p;                               // atan(t), [0, pi/4]
    const r1 = selectFloat4(swap, splatFloat4(half_pi_f32) - r0, r0);
    const x_negative = (x_bits & sign_mask) != @as(Uint4, @splat(0)); // -0 counts as negative
    const r2 = selectFloat4(x_negative, splatFloat4(pi_f32) - r1, r1);
    return @bitCast(@as(Uint4, @bitCast(r2)) | (y_bits & sign_mask));
}
```

- `math.atan2(y, x)` becomes lane 0 of `simd.atan2Float4(@splat(y),
  @splat(x))`, for single-source scalar/SIMD parity (52D D5's rule for
  `sinCos`). The render-only `ai_debug_overlay.zig:112` result moves by at
  most 2 ulp.
- **Contract** (measured on the design-time probe, Zig 0.17.0 ReleaseFast):
  - `atan(t)` stage: exhaustive over every `f32` in `[0, 1]`, ≤ 1 ulp, max
    absolute error 7.44e-8 (the `t + t*(t2*p)` association measured the
    same; the form above is normative);
  - `atan2`: 64M random pairs in `[-4096, 4096]²`, ≤ 2 ulp, max absolute
    error 2.88e-7;
  - special values are bit-exact with `std.math.atan2`: `atan2(±0, +0) = ±0`,
    `atan2(±0, -0) = ±π`, `atan2(±0, x<0) = ±π`, `atan2(y>0, ±0) = +π/2`,
    `atan2(±inf, finite) = ±π/2` (`0x3fc90fdb`; std returns `0x3fc90fda`),
    `atan2(finite, +inf) = ±0`;
  - `atan2(±inf, ±inf)` and any NaN input give NaN with unspecified sign and
    payload (64B canonicalizes NaN in the checksum);
  - a Wyhash digest of 2 × 4M-lane sweeps (random bit patterns, and finite
    values in ±1000) was identical (`0x98491af42b960ab2`) at `-mcpu=x86_64`,
    `x86_64_v2`, `x86_64_v3`, native Zen 4, and Debug (self-hosted backend).
- Golden bits (normative; `y`, `x` → result). If an implementation differs,
  its op order is wrong. Fix the code, never the table:

  | y | x | atan2 |
  | --- | --- | --- |
  | `0x00000000` | `0x3f800000` | `0x00000000` |
  | `0x80000000` | `0x3f800000` | `0x80000000` |
  | `0x00000000` | `0xbf800000` | `0x40490fdb` |
  | `0x80000000` | `0xbf800000` | `0xc0490fdb` |
  | `0x3f800000` | `0x00000000` | `0x3fc90fdb` |
  | `0x3f800000` | `0x3f800000` | `0x3f490fdb` |
  | `0xbf800000` | `0xbf800000` | `0xc016cbe4` |
  | `0x3f800000` | `0x80000000` | `0x3fc90fdb` |
  | `0x00000000` | `0x80000000` | `0x40490fdb` |
  | `0x40400000` (3) | `0x40800000` (4) | `0x3f24bc7d` |
  | `0xc0200000` (−2.5) | `0xc0e00000` (−7) | `0xc0331bc0` |
  | `0x3a83126f` (1e-3) | `0x3f800000` | `0x3a83126c` |
  | `0x42c80000` (100) | `0xbf000000` (−0.5) | `0x3fc9b3b2` |
  | `0x3f333333` (0.7) | `0x3f333333` | `0x3f490fdb` |
  | `0xc5800000` (−4096) | `0x457ff800` (4095.5) | `0xbf4913db` |
  | `0x7f800000` (+inf) | `0x3f800000` | `0x3fc90fdb` |
  | `0x3f800000` | `0x7f800000` (+inf) | `0x00000000` |

- **Codegen** (`simd-asm-check` probe `probe_atan2Float4`; measured on
  Zig 0.17.0 with no calls and no FMA on every target): x86_64 50, v2 46,
  v3 46, apple_m1 66 instructions. Budgets (measured + max(2, 25%)):
  **63 / 58 / 58 / 83**.
- No allocation, no state, no RNG.

### Checklist

- [ ] `simd.atan2Float4` + constants, `math.atan2` delegation, doc comments
      with the contract. Tests in `simd.zig` on runtime inputs:
  - [ ] `"atan2Float4 golden bit patterns"` (17 rows, exact `u32`);
  - [ ] `"atan2Float4 within 2 ulp of the f64 reference"`: a 65,536-pair
        fixed-seed sweep plus the 8 axis/diagonal directions at magnitudes
        1e-30, 1, and 1e30;
  - [ ] `"atan2Float4 special values"` (the contract list, plus NaN → NaN);
  - [ ] `"atan2Float4 lanes are independent"`: four different pairs in one
        vector equal four splat calls.
  - [ ] In `math.zig`: `"atan2 equals simd.atan2Float4 lane 0 bit-for-bit"`.
        The existing `math.zig:323` test keeps its 1e-6 tolerance.
- [ ] `simd-asm-check`: add `probe_atan2Float4` to
      `src/core/simd_asm_probe.zig` and the budget row to
      `tools/check_simd_asm.py`.
- [ ] Bench group `simd-atan2` in `src/benchmarks/simd.zig` (52D D8
      conventions: serial only; 65,536 items quick; `{4_096, 65_536,
      1_048_576}` standard). It runs the SIMD kernel against a
      `std.math.atan2` scalar loop as an informational row.
- [ ] The consuming slice's SIMD kernel uses `atan2Float4` and its scalar
      tail uses `math.atan2` (parity by construction). The consumer adds its
      own serial-vs-threaded parity test.
- [ ] Docs: Determinism Contract (atan2 is deterministic polynomial);
      `docs/coding-standards.md` SIMD determinism rules list `atan2Float4`.

### Acceptance checks

- [ ] `zig build verify` passes with `probe_atan2Float4` inside budget on
      all four `simd-asm-check` targets.
- [ ] `zig build test` passes in Debug, ReleaseFast `ship`, ReleaseFast
      `compat`, and on Apple Silicon (52C macOS job or a manual run recorded
      in Status), proving the golden bits on x86 and arm64.
- [ ] `zig build -Doptimize=ReleaseFast bench -- --group simd-atan2` is
      recorded in Status. The SIMD kernel is at least 2× faster than the
      scalar `std.math.atan2` row at 65,536 items.

---

