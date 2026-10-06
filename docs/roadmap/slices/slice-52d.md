## Slice 52D: SIMD Layer Codegen For The v2 Release Baseline

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 52A](slice-52a.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Depends on **52A**'s `-Dcpu-baseline` option
(`ship` = `x86_64_v2` / `apple_m1`, `compat` = `x86_64` SSE2, `native`
dev/bench only). Until 52A lands, every command below works with today's
`-Dcpu=x86_64_v2` / `-Dcpu=x86_64`. This slice changes no `SimulationPipeline`
stage, `DataSystem` store, threading contract, or allocation. Land it before
Slice 35 (35's restructured kernels are mask/select-heavy and inherit these
fixes) and before 52C records its first cross-baseline `frame-battle` digests
(the trig change moves last bits once). It closes the Slice 49 draft's
"Deterministic trig" Scaling Gap for sin/cos.

**Overlap check.** Archive **Slice 34** built this primitive layer and
deferred "a vector sin/cos approximation with a documented error bound"
(item 3, never picked up by Slice 29). 52D lands that approximation as a
deterministic polynomial, and it has a consumer: `math.sinCos` delegates to it.
Open **Slice 35** restructures AI and steering *loops* onto these primitives.
52D changes only how the primitives lower, plus the single `divInt4` call
site. It does not touch 35's loops, caps (`max_separation_neighbors` 32,
`max_separation_candidate_checks` 128), or arbitration. **52A** owns the
`@setFloatMode(.optimized)` and `@mulAdd` lint rules. 52D adds the
codegen-level check that proves them, plus two more lint rules.

Goal: every `src/core/simd.zig` primitive lowers to the shortest libcall-free
sequence the `ship` baseline offers, and stays libcall-free on `compat`. Every
result of the layer, sin/cos included, is bit-identical across `x86_64`,
`x86_64_v2`, `x86_64_v3`, native, Debug (Zig's self-hosted backend), and
`apple_m1`. A `zig build simd-asm-check` step inside `verify` holds that line,
and `simd-*` bench groups measure it.

Out of scope, with owners:
- AI and steering loop restructures: Slice 35.
- Scalar float `@min`/`@max` outside `core`, NaN payload canonicalization,
  and FP-environment assertions: **Slice 64A** (min/max, FP environment) and
  **Slice 64B** (NaN).
- AVX2/256-bit paths or a lane-width change: v3 is not a shipping baseline.
- Vector `atan2`: **Slice 64D** (consumer-gated).

### Current foundation (do not rebuild)

- `src/core/simd.zig` (647 lines, 19 importers):
  - `:8-12` declares `lane_count = 4` and `Float4`/`Int4`/`Uint4`/`Mask4`.
    Every helper is a plain `pub fn`.
  - `divInt4` `:111-121` does a per-lane `@divTrunc`.
  - `worldPosToCell4` is at `:123-131`.
  - `floorToI4` `:133-155` calls `@floor`, then applies four
    `selectFloat4`/`selectInt4` saturation patches.
  - `minFloat4`/`maxFloat4` `:157-167` use `@min`/`@max`. The compares are at
    `:173-199`, `selectFloat4`/`selectInt4` at `:201-207`, `clampFloat4` at
    `:209-211`, and `countTrue` at `:217-220`.
  - `gatherFloat4` `:282-289`, `scatterFloat4` `:303-312`,
    `reciprocalSqrtFloat4` `:314-318` (`1 / @sqrt`), and
    `normalizeOrZero2Float4` `:325-342`.
  - `sinFloat4`/`cosFloat4`/`sinCosFloat4` `:355-370` use `@sin`/`@cos` and
    have **zero callers**.
  - Tests are at `:378-647`: `floorToI4` saturation `:581`, `worldPosToCell4`
    `:607`, and sin/cos against `@sin` `:635`.
- `src/core/math.zig`:
  - `floorToI32` `:36` is branchy and uses `@floor`.
  - `worldPosToCell` is at `:47`.
  - `clampMinMax` `:132` uses `@min(@max(..))`.
  - `sinCos` `:144` uses `@sin`/`@cos`.
  - `atan2` `:160` is pure-Zig `std.math.atan2`, with no libm and no FMA in
    its scalar f32 path. Fine as-is.
- Callers:
  - **`divInt4`**: only `systems/simulation_scope.zig:673-674`, in
    `deriveChunkJob` (`:653`).
    - The dividend is `worldPosToCell4` output, in `[0, width-1]`.
    - The divisor is the splat of runtime `@max(grid.chunk_size_tiles, 1)`
      (`:660-661`): a `u16` world-config value that is not guaranteed to be a
      power of two.
    - The scalar tail (`:679-684`) divides with u32 `/`.
  - **`floorToI4`**: `spatial_index.zig:654-655` (`assignCellsDense` `:642`)
    and `steering.zig:542-543`.
  - **`worldPosToCell4`**: `simulation_scope.zig:671-672`.
  - **`clampFloat4`**: always called with constant bounds, at
    `affect.zig:486,538`, `particle.zig:507`, and `ai_memory.zig:261,300`.
  - **Mask/select users**: `affect.zig`, `collision.zig:869-871`,
    `perception.zig:1015-1017,1635-1636`, `steering.zig:1394`, and
    `pathfinding/nav_grid.zig:255` (`countTrue`).
  - **`math.sinCos`**: `core/rng.zig:57` (`unitVec2`, which drives AI wander
    at `systems/ai.zig:997`), `data_system/perception.zig:35`
    (`cos_half_fov`), `render/sprite_batch.zig:662,1525`, and
    `ai_debug_overlay.zig:362`.
  - Raw `@sin` appears at `ai_debug_overlay.zig:358`.
  - **`math.clampMinMax`**: `steering.zig:1186-1187`, with runtime AABB
    bounds.
- Existing parity tests:
  - `simulation_scope.zig:1127,1169`: deriveChunks, serial and threaded.
  - `simulation_scope.zig:1558`: warmed scope stays allocation-free under
    `FailingAllocator`.
  - `spatial_index.zig:1291`: `assignCellsDense` against scalar.
- `src/` contains no `@mulAdd` and no `@setFloatMode`, so strict float mode
  applies everywhere.
- Build:
  - `build.zig:76` `b.standardTargetOptions(.{})` resolves one `target`.
    Through `createSdlModule`'s `.target = target` (`:332-336`) it reaches the
    translate-c module (`:134`), exe (`:137`), gpu-smoke (`:148`), bench
    (`:154`), and tests (`:160`). No artifact overrides it, so a 52A baseline
    change reaches every artifact.
  - The `fmt` paths are at `:199-206`, and `idiom-lint` + `verify` at
    `:240-249`.
  - Debug x86_64-linux uses Zig's self-hosted backend (`99e6959`).
    ReleaseFast uses LLVM.
- `tools/lint_idioms.py` (322 lines) has `FORBIDDEN_PATTERNS` and
  `SRC_ONLY_PATTERNS`, top-level `in_test` tracking, and a NaN self-compare
  exemption for `simd.zig`.
- **Where the trig symbols come from today.** Slice 49's determinism contract
  records the same provenance.
  - Linux binaries statically contain Zig compiler-rt's musl-port
    `sinf`/`cosf`/`sincosf` as hidden weak symbols:
    `nm zig-out/bin/my-sdl3-game` shows local `t sinf`, `t cosf`, `t sincosf`.
    `ldd` still lists `libm.so.6` (pulled in by SDL), but the game's own trig
    calls bind to the static local copies, not the system libm.
  - x86_64-windows-gnu imports no trig from UCRT; it is statically linked.
  - aarch64-macos calls `___sincosf_stret` (and `_sinf`/`_cosf`). Only Apple
    libSystem provides `__sincosf_stret`, so results there depend on the
    installed OS, at runtime.

### Codegen audit data

**Method.** A scratch harness exports one `export fn` per primitive.
- Vector args pass by value in C-ABI registers, so each count is the
  primitive's body.
- A probe's mask result goes through an `inline` `@select` sink.
- Build flags: `zig build-obj -O ReleaseFast -fomit-frame-pointer -femit-asm
  -fno-emit-bin` with Zig 0.17.0, for `-target x86_64-linux
  -mcpu={x86_64,x86_64_v2,x86_64_v3}` and `-target aarch64-macos
  -mcpu=apple_m1`.
- Counts exclude `ret`. **RT** marks the mask round-trip (below), **N×call**
  marks libcalls, and **N×div** marks scalar `idiv`/`sdiv`.
- "after" is the same harness against the 52D design, prototyped in a scratch
  copy of the tree.

| Primitive | x86_64 now → after | x86_64_v2 now → after | x86_64_v3 now → after | apple_m1 now → after | Lowering class / note |
| --- | --- | --- | --- | --- | --- |
| `loadFloat4`, `storeFloat4Slice` | 1 → 1 | 1 → 1 | 1 → 1 | 1 → 1 | single `movups`/`ldr q`; optimal |
| `add/sub/mul/divFloat4`, `add/subInt4` | 1 | 1 | 1 | 1 | native |
| `lerpFloat4`, `dotFloat4` | 3 | 3 | 3 | 3 | sub/mul/add, **no FMA** on v3 or M1 |
| `mulInt4` | 8 | 1 | 1 | 1 | SSE2 `pmuludq` emulation; `pmulld` on v2 |
| `min/maxInt4` / `clampInt4` | 5 / 10 | 1 / 2 | 1 / 2 | 1 / 2 | SSE2 emulation; `pminsd`/`pmaxsd` on v2 |
| `lessThanFloat4` (any compare) | 7 RT → 1 | 7 RT → 1 | 7 RT → 1 | 1 → 1 | mask returned from a non-`inline` fn |
| compare → `selectFloat4` | 11 RT → 4 | 10 RT → 3 | 9 RT → 2 | 2 → 2 | RT on both the return and the param |
| compare → `countTrue` | 7 → 6 | 4 → 3 | 4 → 3 | 4 → 4 | `movmskps`+`popcnt` on v2; a dead byte store before |
| `minFloat4` / `maxFloat4` | 6 → 1 | 5 → 1 | 3 → 1 | 1 → 2 | `@min/@max` = maxnum: `maxps` + `cmpunordps` + blend |
| `clampFloat4` (runtime bounds) | 12 → 2 | 10 → 2 | 6 → 2 | 2 → 4 | constant bounds already lower to 2 ops on x86 (`particle.zig` loop) |
| `floorToI4` | 65 **4×`floorf`** RT → 16 | 39 RT → 12 | 41 RT → 13 | 15 → 13 | SSE2 has no vector floor, so 4 compiler-rt calls |
| `worldPosToCell4` | 78 **4×`floorf`** RT → 32 | 46 RT → 23 | 46 RT → 22 | 21 → 20 | |
| `divInt4` (`chunk_div` splat) → `UniformDivisor` | 25 **4×div** → 11 | 20 **4×div** → 11 | 19 **4×div** → 12 | 12 **4×div** → 16 | M1 count up, but four `sdiv` become two `umull` |
| `reciprocalSqrtFloat4` | 3 | 3 | 3 | 3 | `sqrtps`+`divps` / `fsqrt`+`fdiv`; no `rsqrtps` |
| `normalizeOrZero2Float4` | 25 RT → 17 | 25 RT → 17 | 24 RT → 16 | 16 → 16 | |
| `gatherFloat4` | 11 | 8 | 8 | 9 | scalar loads + `insertps`/`ld1`; no `vgatherdps` |
| `scatterFloat4` | 13 | 8 | 8 | 9 | `extractps`/`st1` |
| `sinFloat4` | 21 **4×`sinf`** | 22 **4×`sinf`** | 19 **4×`sinf`** | 25 **4×`_sinf`** | libcall per lane |
| `sinCosFloat4` → polynomial | 48 **8×call** → 59 | 51 **8×call** → 55 | 49 **8×call** → 59 | 37 **4×`__sincosf_stret`** → 79 | after: zero calls, IEEE ops only |
| `math.sinCos` → lane 0 of polynomial | 16 **`sinf`+`cosf`** → 61 | 16 **2×call** → 57 | 16 **2×call** → 61 | 9 **`__sincosf_stret`** → 80 | M1 count is constant materialization; hoisted in loops |
| `math.floorToI32` | 14 **`floorf`** → 17 | 12 → 13 | 12 → 15 | 13 → 15 | after: branch-free lane 0 of `floorToI4` |
| `math.clampMinMax` | 15 → 2 | 10 → 2 | 6 → 2 | 2 → 4 | |

**Mask round-trip (RT), root cause.** This is verified in the emitted LLVM IR.
- Zig 0.17's LLVM backend handles a `@Vector(4, bool)` that crosses a
  non-`inline` function boundary (parameter or return value) by storing it as
  `<4 x i1>` to an `i8` alloca, then reloading it as `load i8` → `trunc i4` →
  `bitcast <4 x i1>`.
- The alloca is created before LLVM inlines anything, so ReleaseFast inlining
  does not remove it.
- On x86 the store/load pair does not fold, which leaves `movmskps`, then a
  GPR, then `movd`, `pshufd`/`vpbroadcastd`, a constant `pand`, and
  `pcmpeqd`. That is about 6 ops per hand-off, plus a dead byte store. It
  occurs on every Mask4 hand-off at every x86 level, so it erases v2's
  single-op `blendvps`.
- On aarch64 the pair folds away.
- Zig `inline fn` (semantic inlining) removes it. This holds for both return
  and parameter positions, and was checked separately.

**Other findings.**
- No FMA anywhere. Strict mode leaves `a*b+c` unfused on v3 and M1. By
  contrast, `@mulAdd` on v2 lowers to four `fmaf` compiler-rt calls (35 ops),
  versus `vfmadd213ps` on v3.
- There is no rcp/rsqrt estimate anywhere, and no hardware gather.
- Unaligned `movups` is already optimal. It costs the same as `movaps` on
  aligned data on every v2+ CPU, and MAL column bases are not guaranteed
  64-byte aligned (`docs/coding-standards.md`). No aligned-load variant.
- `equalUint4` is a sign-agnostic `pcmpeqd`. No unsigned *ordered* compare
  exists or is needed. If one is ever added, it costs a sign-flip plus
  `pcmpgtd` on SSE2 (5 ops), `pmaxud`+`pcmpeqd`+not on v2 (4 ops), and one
  `cmhi` on M1. Add it only alongside a caller.
- **Signed-zero hazard in today's `@min`/`@max`.**
  - `clamp(-0.0, +0.0, 1.0)` evaluates to −0 with runtime bounds on x86,
    including scalar `clampMinMax`.
  - The same call evaluates to +0 with constant bounds on x86 (the `maxps x, 0`
    operand order), +0 on M1 (`fmaxnm`), and +0 at comptime. All four cases
    were measured.
  - So identical code can disagree in the sign bit depending on context and
    architecture.

**Exactness evidence** (scratch, run natively on Zen 4 at `-mcpu=x86_64`,
`x86_64_v2`, `x86_64_v3`, and `native`; identical output on all four):
- **Proposed `floorToI4`, both floor paths:** 0 mismatches against
  `math.floorToI32` over all 2^32 f32 bit patterns.
- **`UniformDivisor`:** 19,394,460,672 checks against `@divTrunc` with 0
  mismatches.
  - It covers every divisor in 1..65535, each with 1024 edge and random
    dividends.
  - It also runs the full dividend range [0, 2^31) for d ∈ {1, 3, 7, 8, 13,
    16, 60000, 65535, 2^31}.
- **Polynomial sin/cos accuracy:**
  - Over all 2,157,060,024 f32 in [−π, π]: max absolute error 9.25e-8, and at
    most 2 ulp from the correctly rounded f32 result.
  - Over a 4M-point sweep of [−8192, 8192]: max absolute error 9.30e-8.
  - sin is odd and cos is even, bit-exact.
  - The results differ from compiler-rt `sinf`/`cosf` on 1.87% of the inputs
    in [−π, π].
  - A Wyhash digest of every result is identical across the four CPU levels.
  - The golden bits below also match under Debug (`stage2_x86_64`) and LLVM
    ReleaseFast/ReleaseSafe.
- **Full suite** on the scratch tree with all of 52D applied:
  - 1131/1131 pass in Debug (self-hosted backend).
  - 1129/1131 pass (2 skipped) in ReleaseFast with `-Dcpu=x86_64`.
  - Intermediate states also passed in ReleaseSafe with `-Dcpu=x86_64` and in
    ReleaseFast with `-Dcpu=x86_64_v2`.
  - No existing test needed re-baselining.

**Bench evidence.** ReleaseFast `serial-direct`, pinned with `taskset -c 4`,
medians of 5–7 interleaved repetitions on a Zen 4 host. "now" is HEAD
`99e6959`; "after" is the scratch tree.

| Group (items) | ship `x86_64_v2` now → after | compat `x86_64` now → after |
| --- | --- | --- |
| `simd-floor-cell` (65,536) | 40.7 → 10.9 µs (−73%) | 121.1 → 15.4 µs (−87%) |
| `simd-world-to-chunk` (65,536) | 39.6 → 23.9 µs (−40%) | 126.3 → 37.9 µs (−70%) |
| `simd-clamp-select` (65,536) | 19.4 → 10.6 µs (−46%) | 22.4 → 11.7 µs (−48%) |
| `simd-normalize` (65,536) | 30.2 → 29.1 µs (−3%) | 30.2 → 29.3 µs (−3%) |
| `simd-sincos` (65,536) | 522.8 → 61.6 µs (−88%) | 596.6 → 67.7 µs (−89%) |
| `simd-sincos-scalar` (65,536) | 476.7 → 257.6 µs (−46%) | 481.0 → 283.0 µs (−41%) |
| `simd-gather-scatter` (65,536) | 56.8 → 57.1 µs (0%) | 57.2 → 57.2 µs (0%) |
| `simd-count-true` (65,536) | 5.7 → 6.7 µs (+17%, see note) | 7.1 → 6.8 µs (−4%) |
| `spatial_index` (50k) | 1060 → 1020 µs (−3.8%) | 1190 → 1020 µs (−14.3%) |
| `scope` (50k) | 4320 → 4240 µs (−1.9%) | 4440 → 4260 µs (−4.1%) |
| `perception` (50k) | 4370 → 4270 µs (−2.3%) | 4530 → 4390 µs (−3.1%) |
| `render-prep` (50k) | 1510 → 1380 µs (−8.6%) | 1440 → 1430 µs (−0.7%) |
| `ai` (10k) | 3010 → 2890 µs (−4.0%) | 3140 → 3110 µs (−1.0%) |
| `movement` (50k, control) | 14.2 → 14.3 µs | 13.9 → 13.9 µs |
| `particles` (50k, control) | 97.6 → 101.1 µs | 91.5 → 100.0 µs |

Notes on the table:
- **Real binaries confirm the change.** `assignCellsDense` drops from 172 to
  115 instructions on v2 and from 8 `movmskps` to 0. On compat it drops from
  240 to 142 instructions and from 10 `floorf` calls to 2 (the scalar tail).
  `deriveChunkJob` drops from 12 `idiv` to 6 (tail only).
- **`particles` and `simd-count-true` are layout noise.**
  - `particles`: `processRange` is the same instruction stream in both
    binaries. Only the loop head's 64-byte alignment moved (+32 → +48).
  - `simd-count-true`: the hot loop is a strict subset of the old one (the
    dead stores are removed).
  - This is why the bench gate below requires a disassembly check before it
    calls any change a regression.
- **Without 52D, `ship` gains little over `compat`:** `spatial_index` 1.06 vs
  1.10 ms, `steering` 17.2 vs 18.1 ms, `perception` 3.93 vs 3.93 ms.

### Architecture notes

**Ownership.**
- `src/core/simd.zig` and `src/core/math.zig` own every primitive change.
- `src/game/systems/simulation_scope.zig` owns the one caller migration, and
  `src/game/ai_debug_overlay.zig:358` gets a one-line trig swap.
- Tooling: `tools/lint_idioms.py`, `tools/check_simd_asm.py`,
  `src/core/simd_asm_probe.zig`, and `build.zig` (the `simd-asm-check` step
  plus `verify`).
- Bench: `src/benchmarks/simd.zig` and its registration in
  `src/benchmarks/runner.zig`.
- Docs. No other module changes.

**D1. Mask4 helpers are `inline fn`.**
- Change: `lessThanFloat4`, `lessThanInt4`, `greaterThanFloat4`,
  `greaterThanInt4`, `equalFloat4`, `equalInt4`, `equalUint4`,
  `selectFloat4`, `selectInt4`, and `countTrue` become `pub inline fn`.
- Rule: every function whose signature mentions `Mask4` or
  `@Vector(_, bool)` must be `inline fn`, across all of `src/`.
- Determinism: no numeric change.
- Affected callers: every compare/select/countTrue user listed above, plus
  `floorToI4`, `worldPosToCell4`, and `normalizeOrZero2Float4` internally.
- Also report the Zig behavior upstream (Checklist item below). Keep the rule
  regardless.

**D2. `floorToI4` without libcalls or round-trips; `floorToI32` delegates.**

```zig
const has_hardware_floor: bool = switch (builtin.cpu.arch) {
    .x86_64, .x86 => std.Target.x86.featureSetHas(builtin.cpu.features, .sse4_1),
    .aarch64, .aarch64_be => true,
    else => false,
};

pub fn floorToI4(values: Float4) Int4 {
    return floorToI4Impl(values, has_hardware_floor);
}

fn floorToI4Impl(values: Float4, comptime hardware_floor: bool) Int4 {
    // No f32 lies in (-2^31, -2^31 + 128) or (2^31 - 128, 2^31), so the
    // saturation masks can read the input instead of the floored value.
    const is_nan = values != values;
    const at_or_above_max = values >= splatFloat4(0x1p31);
    const no_nan = selectFloat4(is_nan, splatFloat4(0), values);
    const clamped = minFloat4(maxFloat4(no_nan, splatFloat4(-0x1p31)), splatFloat4(0x1p31 - 128.0));
    const floored: Int4 = if (hardware_floor) @intFromFloat(@floor(clamped)) else blk: {
        const truncated: Int4 = @intFromFloat(clamped);
        const back: Float4 = @floatFromInt(truncated);
        break :blk truncated - @select(i32, clamped < back, splatInt4(1), splatInt4(0));
    };
    return selectInt4(at_or_above_max, splatInt4(std.math.maxInt(i32)), floored);
}
```

- `math.floorToI32(v)` becomes `simd.floorToI4(simd.splatFloat4(v))[0]`. That
  gives single-source parity and removes the compat `floorf` call.
- The old branchy body moves into the tests as a private
  `referenceFloorToI32`, so the parity tests are not tautological.
- Determinism: integer results are identical for all 2^32 inputs on both
  paths. No numeric change.
- Affected callers: `spatial_index.zig:654-655,249-252,761-762`,
  `steering.zig:542-543`, `simulation_scope.zig:671-672`,
  `nav_grid.zig:191-192`, and `pathfinding/types.zig:395`.

**D3. Float min/max/clamp pin x86 `MINPS`/`MAXPS` semantics.**
- `minFloat4(a, b) = @select(f32, a < b, a, b)`.
- `maxFloat4(a, b) = @select(f32, a > b, a, b)`.
- `clampFloat4` keeps its composition, `minFloat4(maxFloat4(v, lo), hi)`.
- `math.clampMinMax` becomes:
  `const raised = if (value > min) value else min; return if (raised < max) raised else max;`.
- Documented contract:
  - NaN in `lhs` yields `rhs`.
  - NaN in `rhs` propagates.
  - Equal lanes, including −0 vs +0, yield `rhs`.
  - So clamp maps NaN to `lo` (unchanged) and clamp(−0, +0, hi) = +0
    everywhere.
- x86 is 1 op per min/max. M1 is 2 ops (`fcmgt`+`bif`). LLVM still emits
  `fmaxnm` on M1 when it can prove equivalence, as it does for
  `normalizeOrZero2Float4`'s positive constant.
- Determinism impact (flagged):
  - It changes only the sign of zero on ±0 ties and NaN-in-bound results.
  - All five SIMD clamp sites use constant 0/1/max bounds. On x86, LLVM
    already folds `maxnum(x, C)` to `maxps x, C`, which has these semantics
    (verified in `particle.zig:507`'s binary). They are therefore
    bit-identical on x86 and M1.
  - `math.clampMinMax` at `steering.zig:1186-1187` (runtime AABB bounds)
    changes only when the value and the bound are opposite-signed zeros.
  - The results now agree between comptime and runtime, and between x86 and
    M1.

**D4. `UniformDivisor` replaces `divInt4`.**

```zig
pub const UniformDivisor = struct {
    magic: u32,
    shift: u6,

    /// Granlund-Montgomery (N = 31): exact for every dividend in [0, 2^31).
    pub fn init(divisor: u32) UniformDivisor {
        std.debug.assert(divisor >= 1 and divisor <= 1 << 31);
        const log2_ceil: u6 = if (divisor == 1) 0 else @intCast(32 - @clz(divisor - 1));
        const numerator: u64 = @as(u64, 1) << (31 + log2_ceil);
        return .{ .magic = @intCast((numerator + divisor - 1) / divisor), .shift = 31 + log2_ceil };
    }

    pub fn divNonNegativeInt4(self: UniformDivisor, values: Int4) Int4 {
        std.debug.assert(@reduce(.And, values >= splatInt4(0)));
        const wide: @Vector(lane_count, u64) = @as(Uint4, @bitCast(values));
        const product = wide * @as(@Vector(lane_count, u64), @splat(self.magic));
        return @bitCast(@as(Uint4, @truncate(product >> @splat(self.shift))));
    }
};
```

- `deriveChunkJob` changes in two places:
  - `const chunk_div = simd.UniformDivisor.init(@intCast(chunk_size));` is set
    once per job range (one u64 divide per range).
  - Both `divInt4` calls become `chunk_div.divNonNegativeInt4(tx/ty)`.
- `ChunkGrid` is unchanged.
- **Delete `divInt4`** and its test row. After the migration it has no
  callers, and every target lowers it to four scalar divides.
- Determinism: exact (see the evidence above). No numeric change.

**D5. Deterministic polynomial sin/cos.**
- `simd.sinCosFloat4` becomes the kernel below.
- `sinFloat4`/`cosFloat4` return the matching member.
- `math.sinCos(angle)` returns lane 0 of `simd.sinCosFloat4(@splat(angle))`.
  This adds a top-level `math → simd` import; the cycle is fine in Zig.
- The op order is normative. Strict float mode keeps LLVM from reordering it.

```zig
// Cody-Waite pi/2 split: k*pio2_1 exact for |k| < 2^16, k*pio2_2 for |k| < 2^13.
const two_over_pi: f32 = 0.636619772367581343;
const pio2_1: f32 = 1.5703125;
const pio2_2: f32 = 4.837512969970703125e-4;
const pio2_3: f32 = 7.54978995489188216e-8;
const round_magic: f32 = 0x1.8p23; // (x + magic) - magic == round-half-even(x) for |x| < 2^22
const sin_c1: f32 = -1.6666654611e-1; // Cephes sinf/cosf minimax, |r| <= pi/4
const sin_c2: f32 = 8.3321608736e-3;
const sin_c3: f32 = -1.9515295891e-4;
const cos_c1: f32 = 4.166664568298827e-2;
const cos_c2: f32 = -1.388731625493765e-3;
const cos_c3: f32 = 2.443315711809948e-5;

pub fn sinCosFloat4(angles: Float4) SinCos4 {
    const sign_mask: Uint4 = @splat(0x8000_0000);
    const angle_bits: Uint4 = @bitCast(angles);
    const sign_in = angle_bits & sign_mask;
    const x: Float4 = @bitCast(angle_bits & ~sign_mask); // |angle|: sin odd, cos even by construction
    const shifted = x * splatFloat4(two_over_pi) + splatFloat4(round_magic);
    const k = shifted - splatFloat4(round_magic);
    const quadrant: Uint4 = @as(Uint4, @bitCast(shifted)) & @as(Uint4, @splat(3));
    const r = ((x - k * splatFloat4(pio2_1)) - k * splatFloat4(pio2_2)) - k * splatFloat4(pio2_3);
    const r2 = r * r;
    const s = r + r * r2 * (splatFloat4(sin_c1) + r2 * (splatFloat4(sin_c2) + r2 * splatFloat4(sin_c3)));
    const c = (splatFloat4(1) - splatFloat4(0.5) * r2) + r2 * r2 * (splatFloat4(cos_c1) + r2 * (splatFloat4(cos_c2) + r2 * splatFloat4(cos_c3)));
    const swap = (quadrant & @as(Uint4, @splat(1))) != @as(Uint4, @splat(0));
    const sin_base: Uint4 = @bitCast(selectFloat4(swap, c, s));
    const cos_base: Uint4 = @bitCast(selectFloat4(swap, s, c));
    const sin_sign = ((quadrant << @splat(30)) & sign_mask) ^ sign_in;
    const cos_sign = ((quadrant +% @as(Uint4, @splat(1))) << @splat(30)) & sign_mask;
    return .{ .sin = @bitCast(sin_base ^ sin_sign), .cos = @bitCast(cos_base ^ cos_sign) };
}
```

Documented contract:
- For |angle| ≤ 8192, absolute error is at most 1.0e-7 (measured 9.3e-8) and
  error is at most 2 ulp on [−π, π].
- Larger finite angles are deterministic but less accurate. Callers wrap
  their angles first.
- sin(±0) = ±0 and cos(±0) = 1.
- NaN or ±inf input yields NaN. The NaN sign and payload are unspecified: x86
  produces `0xffc00000`.

Golden bits, normative (inputs → sin, cos):

| input | sin | cos |
| --- | --- | --- |
| `0x00000000` | `0x00000000` | `0x3f800000` |
| `0x3f060a92` (π/6) | `0x3f000000` | `0x3f5db3d7` |
| `0x3f490fdb` (π/4) | `0x3f3504f3` | `0x3f3504f2` |
| `0x3fc90fdb` (π/2) | `0x3f800000` | `0xb33bbd2e` |
| `0x40490fdb` (π) | `0xb3bbbd2e` | `0xbf800000` |
| `0xbf860a92` (−π/3) | `0xbf5db3d8` | `0x3effffff` |
| `0x3f800000` (1) | `0x3f576aa5` | `0x3f0a5140` |
| `0x42c80000` (100) | `0xbf01a12e` | `0x3f5cc0ee` |
| `0x45fffc00` (8191.5) | `0xbf7ac05a` | `0xbe4e4a7f` |
| `0xc0200000` (−2.5) | `0xbf193579` | `0xbf4d17c0` |
| `0x3f333333` (0.7) | `0x3f24eb73` | `0x3f43ccb2` |
| `0x40800000` (4) | `0xbf41bdcf` | `0xbf275530` |

If an implementation does not reproduce these bits, its op order differs from
the spec. Fix the code, do not regenerate the table.

Determinism impact (flagged): last-bit changes against today's libm/compiler-rt
values, on 1.87% of inputs, by at most 2 ulp. Affected callers:
- AI wander directions (`rng.unitVec2` → `ai.zig:997`).
- FOV `cos_half_fov` (`data_system/perception.zig:35`).
- Sprite rotation (`sprite_batch.zig:662,1525`, render only).
- The debug overlay (`ai_debug_overlay.zig:358,362`). `:358` switches from
  `@sin(step * 0.5)` to `math.sinCos(step * 0.5).sin`.

Golden data: no test pins these bits today (scratch suite 1131/1131), and no
simulation checksum golden exists yet. If Slice 49 lands first, its
`simulationChecksum` golden values re-baseline in 52D's sin/cos commit, and
the commit message names that change.

**D6. Kept by decision. Each is recorded in a doc comment.**
- `divFloat4` stays a true division. `spatial_index.zig:640` already relies
  on scalar-`/` bit parity, and a reciprocal multiply would break it.
- `reciprocalSqrtFloat4` stays `sqrt` + `div`. `rsqrtps`/`rcpps` are
  approximations whose results differ between Intel and AMD.
- `gatherFloat4` stays scalar loads. `vgatherdps` is slower on Zen 2/3 and on
  Intel parts with the GDS microcode mitigation.
- Loads stay unaligned `movups`.
- The SSE2 integer emulations (`mulInt4` 8 ops, `clampInt4` 10 ops) are
  acceptable on `compat`.
- No unsigned ordered compare is added.
- `lerpFloat4`/`dotFloat4` stay sub/mul/add, never FMA.

**D7. Enforcement.**
1. **Determinism contract.** A `//!` header on `simd.zig` states the contract:
   - Only IEEE basic ops and `@sqrt`, exact conversions
     (`@intFromFloat`/`@floatFromInt`), `@floor`, compares, selects, and
     integer/bit ops.
   - No `@mulAdd`, no `@setFloatMode`, no estimates, no libm calls.
   - Every Mask4 helper is `inline`.
   - Results are bit-identical across `x86_64`/v2/v3/`apple_m1`/Debug for
     finite inputs.
   - NaN payload is unspecified.
2. **`tools/lint_idioms.py` gains two rules.** Both were prototyped and tested
   against the live tree.
   - **`LIBM_BUILTIN`** (src/, outside `test` blocks):
     `@(?:sin|cos|tan|exp|exp2|log|log2|log10)\s*\(`. Message: "libm-backed
     builtin: results come from compiler-rt on Linux/Windows but from Apple
     libSystem at runtime on macOS; use math.sinCos / simd.sinCosFloat4 (the
     deterministic polynomial)". On today's tree it flags exactly `math.zig:145`,
     `simd.zig:359,364,369`, and `ai_debug_overlay.zig:358`.
   - **`MASK_FN_NOT_INLINE`** (src/): join a declaration from its `fn` line up
     to its first `{` (at most 8 lines). If the signature matches
     `\bMask4\b|@Vector\([^()]*,\s*bool\s*\)` and the declaration lacks
     `inline fn`, flag it. Message: "Mask4 crossing a non-inline call
     boundary costs a movmskps→GPR→pshufd/pcmpeqd round trip (~6 ops) on x86;
     declare it `inline fn`". On today's tree it flags exactly the 10 helpers
     in D1.
   - 52A's `@setFloatMode(.optimized)` and `@mulAdd` rules: whichever slice
     lands first adds them, with 52A's regex and message, and the other slice
     checks them off as present.
3. **`zig build simd-asm-check`**, a dependency of `verify`:
   - **Probe.** `src/core/simd_asm_probe.zig` holds the export-only probe
     functions. It lives in `src/core` so it can import `simd.zig` and
     `math.zig` relatively as the root of one module. It is never imported by
     a runtime module.
   - **Build step.** `build.zig` resolves four explicit targets with
     `b.resolveTargetQuery`, independent of `-Dtarget` and
     `-Dcpu-baseline`:
     - `x86_64-linux` with each of `x86_64`, `x86_64_v2`, and `x86_64_v3`;
     - `aarch64-macos` with `apple_m1`.
   - **Per target.** It builds an object via `b.addObject` (`.use_llvm =
     true`, root module `.optimize = .fast`, `.omit_frame_pointer = true`, no
     SDL, no libc). It passes `obj.getEmittedAsm()` with the target label to
     `python3 tools/check_simd_asm.py`.
   - This mechanism was prototyped on Zig 0.17. Cross objects need no SDK.
   - `build.zig`'s `fmt` paths already cover `src/`.
   - **Checker.** `tools/check_simd_asm.py` (stdlib only):
     - parses each `simd_asm_probe.<fn>:` body, accepting the `_`, `.L`, and
       `l_` prefixes;
     - resolves LLVM identical-code-folding aliases (`<export> = <impl>`
       lines) and requires every probe to be present on every target;
     - drops directives and labels, then counts instructions excluding `ret`;
     - prints the measured table on every run;
     - fails on any rule below.

| Rule | Pattern / requirement |
| --- | --- |
| No calls | any `call`/`bl`/tail `jmp`/`b` to a symbol inside a probe |
| No FMA | `vfn?m(add\|sub)`, `\bfml[as]\b`, `\bfn?m(add\|sub)\b` |
| No estimates | `v?rsqrt(ps\|ss\|14)`, `v?rcp(ps\|ss\|14)`, `frsqrte`, `frecpe`, `frsqrts`, `frecps` |
| No HW gather | `v(p)?gather` |
| No mask round-trip | x86: no `v?movmskps` except in `probe_countTrue` |
| True sqrt/div | `probe_reciprocalSqrtFloat4` and `probe_normalizeOrZero2Float4` contain `v?sqrtps`/`fsqrt` and `v?divps`/`fdiv` |
| No scalar divide | `probe_divNonNegativeInt4` contains no `idiv`/`div`/`sdiv`/`udiv` |
| Budgets | body count ≤ the budget below |

Budgets: the measured "after" value (from the scratch prototype) plus
max(2, 25%). Probes whose lowering is one fixed sequence keep exact budgets:
load/store, lerp/dot, compare, x86 max/clamp, reciprocal sqrt, and x86
`clampMinMax`.

| Probe | x86_64 | x86_64_v2 | x86_64_v3 | apple_m1 |
| --- | --- | --- | --- | --- |
| `probe_loadFloat4` / `probe_storeFloat4Slice` | 1 | 1 | 1 | 1 |
| `probe_lerpFloat4` / `probe_dotFloat4` | 3 | 3 | 3 | 3 |
| `probe_lessThanFloat4` (inline `@select` sink) | 1 | 1 | 1 | 1 |
| `probe_selectFloat4` (compare → select) | 6 | 5 | 4 | 4 |
| `probe_countTrue` (compare → count) | 8 | 5 | 5 | 6 |
| `probe_maxFloat4` | 1 | 1 | 1 | 3 |
| `probe_clampFloat4` (runtime bounds) | 2 | 2 | 2 | 6 |
| `probe_floorToI4` | 20 | 15 | 17 | 17 |
| `probe_worldPosToCell4` | 40 | 29 | 28 | 25 |
| `probe_divNonNegativeInt4` (divisor by pointer) | 14 | 14 | 15 | 20 |
| `probe_reciprocalSqrtFloat4` | 3 | 3 | 3 | 3 |
| `probe_normalizeOrZero2Float4` | 21 | 21 | 20 | 20 |
| `probe_gatherFloat4` | 14 | 10 | 10 | 12 |
| `probe_sinCosFloat4` | 74 | 69 | 74 | 99 |
| `probe_mathSinCos` | 77 | 72 | 77 | 100 |
| `probe_mathFloorToI32` | 21 | 17 | 19 | 19 |
| `probe_mathClampMinMax` | 2 | 2 | 2 | 6 |

After a Zig/LLVM upgrade, a budget failure is a review item. Raise a budget
only with the new measured table in the commit message.

**D8. `simd-*` bench groups** (`src/benchmarks/simd.zig`, registered in
`src/benchmarks/runner.zig`).
- **Groups.** Eight groups, one kernel each, named `simd-floor-cell`,
  `simd-world-to-chunk`, `simd-clamp-select`, `simd-normalize`, `simd-sincos`,
  `simd-sincos-scalar`, `simd-gather-scatter`, and `simd-count-true`.
- **Item counts.** quick `{65_536}`; standard `{4_096, 65_536, 1_048_576}`
  (L1, L2, and DRAM); stress `{1_048_576}`.
- **Serial only.** Threaded cases return
  `suite.RunStats.skipped("serial SIMD primitive kernel")`.
- **Setup.** Columns are allocated and filled before timing from
  `std.Random.DefaultPrng.init(0x51d1_ea5e)`:
  - angles are drawn in [−π, π], positions in [−100, 19900], and runtime
    clamp bounds `lo`/`hi`;
  - the gather indices are a shuffled permutation;
  - the `bool` column is random.
- **Measurement.** It uses the `suite.StatsAccumulator` path with
  `suite.serialBatch(n, simd.lane_count)`. The outputs fold into
  `std.mem.doNotOptimizeAway(Wyhash(out))`.
- **Kernel shapes.** Each kernel mirrors its production caller:
  - `simd-floor-cell` mirrors `assignCellsDense`;
  - `simd-world-to-chunk` mirrors `deriveChunkJob`, with chunk size 7 (not a
    power of two) and 512 cells;
  - `simd-clamp-select` mirrors the affect/particle clamp + select;
  - `simd-normalize` mirrors perception;
  - `simd-sincos-scalar` mirrors sprite rotation and `rng.unitVec2`;
  - `simd-gather-scatter` mirrors ai_memory/affect;
  - `simd-count-true` mirrors `nav_grid`.
- No test imports this file.
- **Bench-first.** The file lands against the current API, with
  `simd-world-to-chunk` on `divInt4`, so later commits compare against an
  adjacent parent. The `UniformDivisor` commit switches that kernel in the
  same commit as `simulation_scope.zig`. Archive Slice 34's lesson was to
  compare only adjacent commits.

### Checklist

- [ ] **Bench groups first.** Add `src/benchmarks/simd.zig` (D8) and register
      it. Record the baseline at `ship` and `compat` with `tools/bench_run.py`
      (output in `benchmark_outputs/`). There is no production change in this
      commit.
- [ ] **Mask4 `inline`** (D1). Add the `MASK_FN_NOT_INLINE` lint rule. The
      existing compare/select/countTrue tests (`simd.zig:441,465`) stay
      green.
- [ ] (added by Slice 64) **File the upstream Zig issue** on the Zig issue tracker
      (`codeberg.org/ziglang/zig/issues`; search first and comment on an
      existing report instead of duplicating it). Record the issue URL in
      this slice's Status.
  - Title: "LLVM backend: by-value `@Vector(N, bool)` parameter/return is
    lowered through an `i8` alloca that x86 does not fold".
  - Body:
    - the IR pattern: `store <4 x i1>` to an `i8` alloca, then `load i8` →
      `trunc i4` → `bitcast <4 x i1>`, created before inlining, so
      ReleaseFast inlining keeps it;
    - x86 consequence: `movmskps` → GPR → byte store → `movd` → `pshufd` →
      constant `pand` → `pcmpeqd` on every hand-off;
    - aarch64 folds it, and `inline fn` avoids it.
  - Minimal repro, the design-time `maskprobe.zig`, pasted in full:

    ```zig
    const F = @Vector(4, f32);
    const M = @Vector(4, bool);
    fn selF(m: M, a: F, b: F) F { return @select(f32, m, a, b); }
    inline fn selFInline(m: M, a: F, b: F) F { return @select(f32, m, a, b); }
    export fn viaFn(x: F, y: F, a: F, b: F) F { return selF(x < y, a, b); }
    export fn viaInline(x: F, y: F, a: F, b: F) F { return selFInline(x < y, a, b); }
    export fn direct(x: F, y: F, a: F, b: F) F { return @select(f32, x < y, a, b); }
    ```

  - Command: `zig build-obj -O ReleaseFast -fomit-frame-pointer -target
    x86_64-linux -mcpu=x86_64 -femit-asm=mp.s -fno-emit-bin maskprobe.zig`
    (Zig 0.17.0).
  - Observed: `viaInline` is identical-code-folded to `direct` (4
    instructions: `cmpltps`, `andps`, `andnps`, `orps`). `viaFn` is 11
    (`cmpltps`, `movmskps`, `mov byte ptr [rsp-1]`, `movd`, `pshufd`,
    `movdqa` constant, `pand`, `pcmpeqd`, `pand`, `pandn`, `por`).
  - Attach the `-femit-llvm-ir` output for `viaFn` and both `.s` files.
  - Also add the repro to `tools/README.md`, so it survives outside chat and
    scratch storage.
- [ ] (added by Slice 64) **`MASK_FN_NOT_INLINE` stays after an upstream fix.** When a Zig
      release fixes the lowering, `simd-asm-check` budgets may drop (record
      the new table). The lint rule and the `inline fn` Mask4 helpers stay:
      they are free on every compiler, and the rule protects older pinned
      toolchains. A comment above the rule in `tools/lint_idioms.py` cites
      the issue URL.
- [ ] **`floorToI4` rewrite + `math.floorToI32` delegation** (D2). Tests in
      `simd.zig`:
  - `floorToI4Impl` hardware and truncate-adjust paths both match a private
    `referenceFloorToI32` on:
    - NaN, ±inf, ±0, ±denormal-min, and ±floatMax;
    - ±2^31, ±2^23, and ±2^24, each with 3 `nextAfter` steps either side;
    - ±0.5 and ±1 ± 1 ulp;
    - 65,536 bit patterns from fixed-seed `DefaultPrng`.
  - Existing `:581`/`:607` keep passing.
  - `math.zig` `:178` keeps passing, plus a new test,
    "floorToI32 equals floorToI4 lane 0 and the reference".
- [ ] **Select-form `min`/`max`/`clamp` + `math.clampMinMax`** (D3). Tests use
      runtime (`var`) inputs so LLVM cannot constant-fold. Expected bits:
  - `maxFloat4(-0, +0)` = `0x00000000` and `maxFloat4(+0, -0)` = `0x80000000`;
  - `maxFloat4(NaN, 1)` = 1, and `maxFloat4(1, NaN)` is NaN;
  - `clampFloat4(-0, +0, 1)` = `0x00000000` and `clampFloat4(NaN, 0, 1)` = 0;
  - `math.clampMinMax` matches `clampFloat4` lane 0 bit-for-bit on the same
    grid.
  - Update `math.zig:332` and the doc comments.
- [ ] **`UniformDivisor` + `deriveChunkJob` migration + delete `divInt4`**
      (D4). Tests:
  - Every divisor 1..1024 against `@divTrunc` with dividends
    {0, 1, d−1, d, d+1, 2d−1, 2^31−1, 2^31−d} plus 64 fixed-seed randoms.
  - The divisors {60000, 65535, 2^31−1, 2^31} with the same edge set.
  - In `simulation_scope.zig`: "deriveChunks with a non-power-of-two chunk
    size matches the scalar tail". Use `chunk_size_tiles = 7`, at least 9
    rows across several chunks, and both the vector block and the tail.
  - The existing `:1127`, `:1169`, and `:1558` (`FailingAllocator`) pass.
  - Switch the `simd-world-to-chunk` kernel in the same commit.
- [ ] **Polynomial sin/cos + `math.sinCos` delegation** (D5). Swap the trig at
      `ai_debug_overlay.zig:358` and add the `LIBM_BUILTIN` lint rule. Tests in
      `simd.zig`, all on runtime inputs:
  - "sinCosFloat4 golden bit patterns": the 12 rows above, exact `u32`.
  - "sinCosFloat4 within 1e-7 of the f64 reference": 8192-point sweeps of
    [−π, π] and [−8192, 8192] against `@sin`/`@cos` on `f64`. Builtins are
    allowed inside test blocks.
  - "sinCosFloat4 is odd/even, keeps signed zeros, and returns NaN for
    non-finite input".
  - "sinFloat4/cosFloat4 equal sinCosFloat4 lanes".
  - `math.zig`: "sinCos equals simd.sinCosFloat4 lane 0 bit-for-bit".
  - `simd.zig:635` is replaced by the tests above. `math.zig:297,323` keep
    their 1e-6 tolerances.
- [ ] **`simd-asm-check`** (D7.3). Add `src/core/simd_asm_probe.zig`,
      `tools/check_simd_asm.py`, and the `build.zig` step, then
      `verify_step.dependOn` it.
- [ ] **Contract header** (D7.1) on `simd.zig`. Correct the doc comments on
      `divFloat4`, `reciprocalSqrtFloat4`, `gatherFloat4`, and the
      `floorToI4`/`worldPosToCell4` lowering notes.
- [ ] **Docs:**
  - `docs/coding-standards.md` SIMD section (after `:330`): add "SIMD codegen
    and determinism rules". It covers inline Mask4 helpers, select-form float
    min/max, no libm builtins in `src/`, no `@mulAdd`/`@setFloatMode`/
    estimates, and enforcement by `simd-asm-check`.
  - `docs/simulation-tiers-and-pipeline.md`, Determinism Contract (Slice 49's
    section; if 49 has not landed, add a short "Float determinism" note that
    49 merges):
    - sin/cos are no longer a cross-machine caveat;
    - the Linux/Windows/macOS symbol-resolution facts (above) replace the old
      libm wording;
    - list the residual hazards owned by Slices 64A, 64B, and 64D.
  - `docs/development-workflow.md`: the `simd-asm-check` command and what it
    proves, plus the `simd-*` bench groups and the bench-gate procedure
    below.
  - `docs/architecture.md`: one line in the `src/core` section.
  - `CLAUDE.md`: add `simd-asm-check` to the command list.

### Acceptance checks

- [ ] `zig build verify` passes. It includes `simd-asm-check` and the new
      `idiom-lint` rules, and the checker prints a table within budget for all
      four targets.
- [ ] `zig build test` passes:
  - in Debug (self-hosted backend);
  - with `-Doptimize=ReleaseFast -Dcpu-baseline=ship`;
  - with `-Doptimize=ReleaseFast -Dcpu-baseline=compat`;
  - with `-Doptimize=ReleaseSafe -Dcpu=x86_64_v3` (informational).
  Together these prove the golden sin/cos bits and the floor, divisor, and
  clamp parity on every x86 level and on both backends.
- [ ] `zig build test` passes on an Apple Silicon Mac, either through 52C's
      macOS job or a manual run recorded in the slice Status. The same golden
      constants pass, which proves x86/arm64 bit-identity. Until then this
      check stays `[ ]`.
- [ ] `zig build check -Doptimize=ReleaseFast -Dcpu-baseline=compat`
      compiles, which exercises the truncate-adjust floor path.
- [ ] Each new lint rule fires on a temporary, uncommitted edit: an
      `@sin(` in `src/game/`, and a non-`inline` fn that takes `Mask4`.
- [ ] **Bench gate** (adjacent commits: the bench-first commit against the
      final commit).
  - Setup: ReleaseFast, `--case serial-direct`, pinned (`taskset -c N` on
    Linux), 5 interleaved repetitions, medians, at `ship` and `compat`.
  - `simd-floor-cell`, `simd-world-to-chunk`, `simd-clamp-select`,
    `simd-sincos`, and `simd-sincos-scalar` at 65,536 must each be at least
    25% faster at both baselines. The audit measured 40–89%.
  - `simd-normalize` and `simd-gather-scatter` must stay within ±5%.
    `simd-count-true` is informational (alignment-sensitive).
  - System groups: `spatial_index`, `scope`, `perception`, `steering`,
    `collision`, `ai-affect`, `particles`, and `movement` at 50k; `ai` at 10k;
    `render-prep` at 50k. Run 7 repetitions, `--iterations 200`.
    - No median may regress more than 3% at `ship`, unless the
      `objdump -d --disassemble=<hot fn>` instruction stream is identical or a
      strict subset (layout noise, as in the `particles` audit).
    - `spatial_index` at `compat` must improve by at least 8% (audit: −14%).
  - Record both tables in the slice Status.

