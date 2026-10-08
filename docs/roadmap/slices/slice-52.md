## Slice 52: Release Build Baseline, Pinned Dependencies, And CI

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 49](slice-49.md) (52C only) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started (umbrella).** Sub-slices 52A → 52B → 52C, and 52D after
52A. Closes when all four are archived. Land 52A before the first game forks
from the framework, because every game inherits these build contracts.

Goal: every shipped ZeroLight game binary is built from pinned inputs (Zig,
SDL3 / SDL3_ttf / SDL3_mixer, shader artifacts, a CPU baseline) through one
`zig build package` contract per OS, verified continuously by CI, so "it only
builds on my machine" and "the dev box's native AVX-512 leaked into the
package" stop being possible.

Each sub-slice has its own owner files and evidence and is verifiable without
the next: 52A locally with `zig build verify`; 52B by inspecting each OS's
staging directory; 52C only on GitHub, so a red CI job never blocks 52A's
local fixes.

| Concern | Decision | Owner |
| --- | --- | --- |
| CPU baseline | `-Dcpu-baseline=native\|ship\|compat`: `ship` = `x86_64_v2` / `apple_m1` / arch baseline, `compat` = `x86_64` (SSE2), `native` dev/bench only and never packaged; Debug defaults to `native`, release modes to `ship`. | 52A |
| SDL | SDL 3.4.18, SDL_ttf 3.2.2, SDL_mixer 3.2.4 on every OS (re-check the newest 3.4 patch at landing): Windows prebuilt, Linux/macOS upstream-CMake source build, `-Dsystem-sdl` floor-checked fallback. | 52A |
| Zig | `build.zig.zon` `.minimum_zig_version` is the exact pin, guarded in `build.zig`; `mise.toml` pins the dev toolchain; documented upgrade policy. | 52A |
| Shaders | Committed SPIR-V/MSL/DXIL with a source-hash lock gated by `verify`; compile mode kept; CI regenerates with pinned tools. | 52A (+ 52C job) |
| Packaging | One staging dir per OS: Linux tarball dir, Windows icon/VERSIONINFO/GUI subsystem, macOS `.app` with ad-hoc signature (non-LTO). | 52B |
| CI | GitHub Actions: verify matrix, shader regeneration, tag packaging, soak and bench. | 52C |
| Release perf baseline | `frame-battle`: the full fixed step plus CPU render prep (no GPU) as a scaling bench over population and world size, with serial/threaded and cross-baseline digest parity. | 52C |
| SIMD codegen | `core/simd.zig` primitives lower libcall-free and bit-identical across baselines and targets, held by `simd-asm-check` in `verify`. | 52D |
