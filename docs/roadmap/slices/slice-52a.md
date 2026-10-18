## Slice 52A: Release CPU Baseline, Toolchain Pins, Pinned SDL, Committed Shaders

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: none · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: in progress.** The Windows LTO-off item landed 2026-10-05
(`01754ec`); 64G set the release-mode CPU default (`46d3b7f`, `83f36a6`); Debug
moved to the same floor on the core branch (owner 2026-10-16);
everything else is not started. First of 52A → 52B → 52C; 52D
needs its `-Dcpu-baseline`. Rebases on Slice 50's `build.zig` edits.

Goal: a release build means the same ISA, Zig, SDL, and shader bytes on every
machine that produces it. The shipped ISA is `x86_64_v2` (SSE4.2 + POPCNT) on
x86_64 and `apple_m1` on macOS arm64, never the build host's CPU. A fresh
clone builds with only Zig, plus CMake, a C toolchain, and platform headers on
Linux and macOS; no shader compilers are needed for a normal build.

### Current foundation

- `build.zig` defaults every optimize mode, Debug included (owner
  2026-10-16), to the shipped CPU: `x86_64_v2` on x86-64, `apple_m1` on macOS
  arm64, the arch baseline elsewhere (`shippedCpuFloor`); `-Dcpu`/`-Dtarget`
  override, and `-Dcpu=native` is the dev opt-in. There is no `-Dcpu-baseline`
  option yet. A `-Dtarget` cross build without `-Dcpu` takes that target's
  default CPU (derived, not run).
- `core/simd.zig` derives every lane count from one 16-byte register constant
  (`vector_bytes`, the SSE2/NEON width): `lane_count = 4` (`@Vector(4, f32)`) and
  a private 8 × u16 vector behind `countUnequalU16`; nothing is wider than 128
  bits. `src/` has no
  `@setFloatMode` or `@mulAdd`, so strict float mode keeps results
  bit-identical across `x86_64`, `x86_64_v2`, and native. Scalar==SIMD and
  serial==threaded parity tests exist in about 18 modules.
- Windows SDL: `build.zig` / `build.zig.zon` pin SDL 3.4.10, SDL_ttf 3.2.2, and
  SDL_mixer 3.2.4 as lazy VC zips with per-file `CheckFile` validation,
  `fetch-sdl`, and a DLL install plus host PATH prepend.
- Linux/macOS: `-Dsystem-sdl` defaults to true off Windows and links whatever
  pkg-config finds, with no version floor.
- Zig: `.minimum_zig_version = "0.17.0"`; the dev host uses mise; no pin file or
  newer-Zig guard. The last upgrade touched 80 files across 8 commits with an
  unbuildable tree between them (`docs/changelogs/zig_0_17_upgrade.md`).
- Shaders: `shader_programs` (sprite, tilemap; vert/frag) compile per target
  OS with host `glslc`, `spirv-cross`, and `dxc`; install and `verify` depend
  on them, so a clone without `glslc` cannot `zig build`. The MSL
  entry-signature check runs only for macOS targets.
- Python lints wired into `verify` (`tools/lint_idioms.py`,
  `tools/lint_assets_if_changed.py`) are the tooling pattern.
- The bench header (`src/benchmarks/suite.zig`) omits optimize mode, CPU
  model, and target, so archived outputs cannot be compared across baselines.

### Architecture notes

- CPU baseline (decision): `-Dcpu-baseline=native|ship|compat`. `ship` =
  `x86_64_v2` / `apple_m1` / arch baseline; `compat` = `x86_64` (SSE2,
  maximum reach); `native` untouched query, dev/bench only. Every mode,
  Debug included, defaults to `ship` (owner 2026-10-16). An explicit `-Dcpu` wins; passing
  both fails at configure. One resolved target reaches every artifact. The SDL
  source build never receives the baseline (SDL dispatches at runtime). glibc
  and macOS floors come from 52C's release `-Dtarget`, not this option.
- Why v2, not v3: all SIMD is 128-bit through `core`; v2 gives the 4-lane
  kernels single-instruction floor/round, select, i32 multiply and min/max,
  byte shuffles, and `popcnt`, and runs on every x86_64 gaming CPU still in use
  (Nehalem 2008+, Bulldozer/Jaguar 2011+, Zen 2, Steam Deck). FMA is unused
  under strict float mode.
- `package` refuses `native` and `-Dcpu` builds. One baseline per game
  release across every OS package; a game may opt down to `compat`, which CI
  compile-checks. No runtime CPU check (start code is compiled for the
  target); the minimum spec is documented.
- Float-mode lint rejects `@setFloatMode(.optimized)` and `@mulAdd` in `src/`
  (enforces `.grok/rules/simulation.md` § Determinism).
- Zig pin: `.minimum_zig_version` is the single exact pin; a `build.zig` guard
  rejects another minor or a lower patch; `mise.toml` mirrors it, checked in
  `verify`. Upgrades move one minor at a time, framework first on its own
  branch, with the 0.17 commit order (compile fixes, fmt migration, lint rules,
  docs and changelog) and a re-check list (macOS and windows-gnu LTO, backend
  and linker defaults, silent semantic changes, release compile checks, the
  Windows cross-check, CPU model names, the zon import).
- SDL pin: one version triple, three delivery paths — Windows prebuilt zips,
  Linux/macOS official source tarballs built with upstream CMake as shared
  libraries (vendored FreeType, WAV-only mixer, host C compiler, offline after
  fetch), and `-Dsystem-sdl` with a pkg-config floor at the pinned minor.
  Linux/macOS cross from another host is a configure error. The source build
  asserts the required video, GPU, and audio backends and fails listing the
  missing dev packages, so no SDL ships without Wayland. Rejected: Zig-native
  SDL ports (no maintained ttf/mixer); floor-only system SDL (not
  reproducible).
- A cold startup diagnostic logs linked SDL versions and warns on a mismatch or
  below-floor library; never a hard failure.
- Shader artifacts (decision): commit every `shader_programs` output in all
  three formats with a source-hash lock; default builds install the committed
  artifact; a compile mode and an explicit `shaders-update` step remain.
  `verify` checks existence, the lock, SPIR-V magic, signed DXIL, and the MSL
  signature on every host, with no shader tools needed.
- Owners: `build.zig` / `build.zig.zon`, build-only tools under `tools/`, the
  version diagnostic in `src/platform/sdl.zig` (called once from
  `Engine.init`), and the bench header in `suite.zig`. No pipeline, store, or
  hot-path change.
- VoidLight: port its SDL version triple, upstream-CMake source build, and
  vendored FreeType, plus "dependencies keep their own flags" and a hard
  minimum spec; do not port configure-time FetchContent clones, vendored mixer
  codecs, the v3/AVX2 level, `-mcpu=native` on Apple, `-ffast-math`, or
  shaders written into the source tree on every build.

### Checklist

- [ ] `-Dcpu-baseline` with `ship` / `compat` / `native` resolution, `-Dcpu`
      precedence, and the configure-time conflict error.
- [ ] `tools/bench_ab.py` `shipped_cpu_floor` (`:97`) mirrors `build.zig`
      `shippedCpuFloor`. Failure scenario: `-Dcpu-baseline` lands or the floor
      moves, and bench_ab keeps A/B-ing at the old CPU with no error. Pass:
      bench_ab takes the baseline from the build (or the same option), never a
      copy.
- [ ] `package` refuses a `native` baseline or explicit `-Dcpu`, with a fix-it.
- [ ] Float-mode lint rules in `tools/lint_idioms.py`.
- [ ] Zig pin guard, `mise.toml`, and a pin-consistency check in `verify`.
- [ ] Windows SDL bumped to the pinned triple with derived root dirs and a
      comptime URL/version check.
- [ ] Linux/macOS SDL source build with the required-backend assertion,
      include/library/rpath wiring, `bin/lib/` install, generalized
      `fetch-sdl`, and the cross-target configure error.
- [ ] `-Dsystem-sdl` defaults off everywhere, with pkg-config floor checks.
- [ ] Linked-version diagnostic with a pure classifier and synthetic-integer
      tests.
- [ ] Bench header records Zig version, optimize mode, target, CPU model, and
      SDL mode.
- [ ] Committed shader artifacts and lock, `-Dshader-artifacts`,
      `shaders-update`, and the artifact checks in `verify`; a later slice that
      adds a program commits its artifacts.
- [x] (added by Slice 66) Windows LTO off under Zig 0.17: `ltoSupportedForTarget`
      excludes `.coff`; windows-gnu ReleaseFast `check` passes.
- [ ] (added by Slice 66) "windows-gnu LTO links" on the upgrade re-check list.
- [ ] The `addCallgrindBenchRun` doc comment points to
      `docs/development-workflow.md § Profiling` (`build.zig:789`) (code
      audit L9, docs audit L14; `.grok/rules/zig-style.md` § Comments).
      Failure scenario: the section moves or is renamed, and the comment
      sends readers to nothing. Pass: the comment states the step's contract
      only.
- [ ] Docs: DW sections CPU Baseline (with the A/B table and minimum spec), SDL
      Versions And Sources, Shader Artifacts, Toolchain Pins And Upgrades;
      `docs/setup.md`; `docs/rendering-assets-shaders.md` Shader Build;
      `README.md` requirements; `AGENTS.md` commands.
- [ ] Rule additions when this lands: release CPU baseline and toolchain
      upgrade policy (`.grok/rules/build-validation.md`).

### Acceptance checks

- [ ] `zig build verify` passes on the Linux host with defaults, with
      `-Dsystem-sdl=true`, and with no shader tools on `PATH`.
- [ ] The bench header shows `cpu_model=x86_64_v2` for a ReleaseFast run and in
      Debug, and `x86_64` under `compat`; `-Dcpu` with
      `-Dcpu-baseline` fails at configure.
- [ ] `package` with a `native` baseline or explicit `-Dcpu` fails with the
      fix-it.
- [ ] A `compat` vs `ship` (plus informational `x86_64_v3`) ReleaseFast A/B over
      the movement, steering, collision, perception, and render-prep groups is
      recorded in DW.
- [ ] `zig build test -Doptimize=ReleaseSafe` passes under `ship` and `compat`.
- [ ] Windows cross `fetch-sdl` and ReleaseFast `check` pass from Linux,
      including under `--cache-poison=disallowed`.
- [ ] The startup log reports the pinned SDL triple with no mismatch warning.
- [ ] Editing a `.glsl` without `shaders-update`, or zeroing a DXIL digest,
      fails `verify` on its own line; a different Zig minor fails at configure.
- [ ] Docs updated.
