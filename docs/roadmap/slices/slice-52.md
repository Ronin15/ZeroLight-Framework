## Slice 52: Release Build Baseline, Pinned Dependencies, And CI

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 49](slice-49.md) (52C only) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Umbrella for **52A → 52B → 52C**. This is build/tooling
work. 52A and 52B have no ordering dependency on the AI, render, input, or
persistence tracks in either direction. 52C depends on Slice 49 for its digest
oracle (`simulationChecksum()`). Land 52A before the first game forks from the
framework, because every game inherits these build contracts. Slice 52D (SIMD
layer codegen for the v2 baseline) depends on 52A's `-Dcpu-baseline` option.

Goal: every shipped ZeroLight game binary is built from pinned inputs: Zig,
SDL3/SDL3_ttf/SDL3_mixer, shader artifacts, and a CPU baseline. One
`zig build package` contract builds it for each OS, and CI verifies it
continuously. Two failure modes stop being possible: "it only builds on my
machine" and "the dev box's native AVX-512 leaked into the package".

**Why three sub-slices.** Each chunk has its own owner files and its own
acceptance evidence. Each one is verifiable without the next.

- **52A** builds locally and is verifiable with `zig build verify` on one host.
  It owns `build.zig`, `build.zig.zon`, `tools/`, docs, and one small
  diagnostic in `src/platform/`.
- **52B** owns packaging (the `package` step graph, `platforms/` templates, and
  the AssetStore macOS fallback). It bundles 52A's pinned SDL libraries, and
  each OS layout can be checked by inspecting its staging directory.
- **52C** owns `.github/workflows/`, the `frame-battle` bench, and
  `tools/bench_run.py`. It needs 52A, because hosted Ubuntu runners have no
  SDL3 3.4 package, so the pinned source build is the only way CI builds Linux.
  Its tag-packaging job also needs 52B.

One combined slice would put a CI rollout (verifiable only on GitHub) in the
same landing as local build-policy fixes, and a red CI job would block the
fixes.

| Concern | Decision | Owner |
| --- | --- | --- |
| CPU baseline | `-Dcpu-baseline=native\|ship\|compat`. `ship` = `x86_64_v2` (SSE4.2 + POPCNT) / `apple_m1` / arch baseline. `compat` = `x86_64` (SSE2, maximum reach). `native` is dev/bench only and never packaged. Debug defaults to `native`, every release mode to `ship`. | 52A |
| SDL | SDL 3.4.18, SDL_ttf 3.2.2, SDL_mixer 3.2.4 on every OS. Windows: prebuilt VC zips. Linux/macOS: official source tarballs built with upstream CMake. `-Dsystem-sdl` is the floor-checked fallback. | 52A |
| Zig | `build.zig.zon` `.minimum_zig_version` is the exact pin. A `build.zig` guard rejects other minors. `mise.toml` pins the dev toolchain. Upgrade policy is documented. | 52A |
| Shaders | Commit SPIR-V/MSL/DXIL with a source-hash lock, gated by `verify`. Keep `-Dshader-artifacts=compile`. CI regenerates the artifacts with pinned tools. | 52A (+52C job) |
| Packaging | One staging dir per OS. Linux: tarball dir (AppImage deferred). Windows: icon, VERSIONINFO, GUI subsystem. macOS: `.app` with Info.plist, icns, Frameworks, ad-hoc signature. macOS stays non-LTO. | 52B |
| CI | GitHub Actions: `ci.yml`, `shader-artifacts.yml`, `release.yml`, `soak-bench.yml`. | 52C |
| Release perf baseline | `frame-battle` bench group, in this slice (not Scaling Gaps): production 2048-mover demo, full fixed step plus CPU render-prep, no GPU. | 52C |

