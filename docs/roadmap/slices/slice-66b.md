## Slice 66B: Additional Package Targets — macOS universal2, aarch64-linux, aarch64-windows

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 66A](slice-66a.md), [Slice 64C](slice-64c.md), [Slice 52A](slice-52a.md) (gated per target) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started — gated per target.** After **66A** (composite actions,
symbols pipeline), 52A's Windows LTO amendment (see the umbrella), and
**64C** (`zl-replay`, the cross-arch CI check below). Each
target lands when its trigger fires; the slice is complete when all three
have landed:
- **universal2:** the first game whose store page lists macOS and must run
  natively on Intel Macs.
- **aarch64-linux:** the first storefront or device listing that requires a
  native ARM64 Linux build.
- **aarch64-windows:** the first game that lists native Windows on ARM
  (x86_64 under Prism emulation covers players until then).

Goal: `release.yml` produces a macOS universal2 `.app` (x86_64 + arm64 in one
bundle, replacing 52C's arm64-only `.app`), an aarch64 Linux tarball, and an
aarch64 Windows zip, each with its symbols archive. CI builds and tests each
architecture on a native or emulating runner.

### Current foundation

- 52A's SDL contract: Linux/macOS build pinned SDL from source with
  `tools/build_sdl.py` only when host os+arch equals the target; Windows uses
  the VC zips. `build.zig:481-488` already maps `aarch64` → `lib/arm64`, and
  the pinned zips contain `lib/arm64/{SDL3,SDL3_ttf,SDL3_mixer}.{dll,lib,pdb}`
  (verified in `zig-pkg/`).
- 52A CPU baselines: `ship` = `x86_64_v2` (x86_64), `apple_m1`
  (aarch64-macos), `.baseline` (other aarch64). One shipped baseline per game.
- 52C release: Linux in the sniper SDK container
  (`x86_64-linux-gnu.2.31`), Windows cross on `ubuntu-24.04`, macOS on
  `macos-15` (`aarch64-macos.11.0`).
- Zig 0.17 cross-links `aarch64-windows-gnu` (non-LTO; probe), builds
  `x86_64-macos.11.0` and `aarch64-macos.11.0` Mach-O, and `llvm-lipo
  -create` merges them into a valid fat binary (probe). `zig build -frosetta`
  runs x86_64 macOS binaries on arm64 hosts.
- Determinism scope: Slice 64 extends Slice 49's contract to every supported
  target built from one source and toolchain (64A pins float
  min/max/clamp and the FP environment, 64B canonicalizes NaN, 64C's
  `zl-replay` runner verifies). 64B's `buildFingerprint()` (zon version + Zig
  version + `checksum_format_tag`) does not include the arch, so a replay or
  save from one arch slice is checkpoint-comparable on the other. 64C's
  `zl-replay` CLI (`<file> [--threads N] [--fixed-range N] [--stop-step S]
  [--trace]`) verifies captures; it has no way to produce one headlessly.

### Architecture notes

**Owners:** `build.zig` (`-Dmacos-universal`, second target graph, lipo
steps), `tools/build_sdl.py` (`--macos-arch`), `.github/workflows/{ci,release}.yml`.
No `src/` change.

**macOS universal2**
- New option `-Dmacos-universal=<bool>`, default `false`. Valid only with a
  macOS target on a macOS host and a release optimize mode; otherwise a
  configure-time `std.debug.panic` with a fix-it. It affects the `package`
  graph only; `zig build`, `run`, `test`, and benches keep the primary arch.
- The primary target is `-Dtarget` (release: `aarch64-macos.11.0`). The second
  query copies its OS version range, switches the arch, and goes through
  52A's `applyCpuBaseline` (x86_64 → `x86_64_v2` under `ship`, `x86_64` under
  `compat`), so both slices follow the game's one shipped baseline.
- Second graph: `createSdlTranslateC` and `createGameModule` for the second
  target (SDL headers carry arch ifdefs, so translate-c is per target), a
  second SDL source prefix, a second exe with the same options.
- **Two pinned SDL builds.** `tools/build_sdl.py` gains `--macos-arch
  arm64|x86_64` → `CMAKE_OSX_ARCHITECTURES=<arch>` (Apple clang
  cross-compiles either Darwin arch with the universal SDK). 52A's
  configure rule is relaxed for **darwin-on-darwin only**: a macOS host may
  build SDL for either Darwin arch; Linux stays host-arch-only, because a
  cross-arch Linux SDL needs a target sysroot with every backend's dev
  headers. Each build runs 52A's required-backend assertion. One universal
  CMake build (`arm64;x86_64`) is rejected: SDL's configure-time feature
  checks run once, for one arch.
- `lipo -create -output` Run steps for the exe and each of the three dylibs,
  then `lipo -verify_arch <file> arm64 x86_64` Run steps as package
  self-validation. 66A's `dsymutil` + `strip -S` run on the fat exe (one fat
  dSYM, two UUIDs), then 52B's bundle and codesign.
- Stage name `<app-name>-<version>-macos-universal2`.
- **Determinism note** (docs): replays and checksums match across arch
  slices of a universal binary built from one source and toolchain. That is
  Slice 64's contract: 64A pins float min/max/clamp and the FP environment,
  64B canonicalizes NaN, and 64C runs the replay. Saves load across slices
  (state is restored verbatim).
- **Cross-arch replay check.** 66B adds one flag to 64C's runner
  (`src/replay_runner.zig`): `zl-replay --record-script <out.zlrp>
  [--repeat N]` builds a `HeadlessSession` from
  `GameSessionDescriptor.newGame(.init(0x5A17_0000_0000_0001))`, drives Slice
  49's pinned determinism input script (the 120-step table; moved from the
  `game_demo_state.zig` test into `src/app/replay_script.zig` so the tests
  and the CLI read one table) `N` times (default 30 → 3,600 steps, one
  minute), records with `ReplayRecorder` (checkpoints at its normal cadence),
  encodes, and writes the file. It is a developer tool feature of the
  non-packaged `zl-replay` exe, not a game-exe hook. The `macos` CI job
  builds `zl-replay` for `x86_64-macos.11.0` and `aarch64-macos.11.0` with the
  package options (ReleaseFast, `-Dcpu-baseline=ship`), records with the
  x86_64 build under Rosetta (`arch -x86_64`), verifies with the arm64 build,
  then records with arm64 and verifies with x86_64. Both runs must exit 0
  (`matched`). The job runs on 52C's pinned macOS runner (`macos-15`, arm64,
  Rosetta installed by the step below).

**aarch64-linux**
- Package: `-Dtarget=aarch64-linux-gnu.2.35` on `ubuntu-22.04-arm` (host arch
  = target, so 52A's source SDL path applies; glibc floor 2.35 = Ubuntu 22.04).
  Landing rule, applied once: if `registry.gitlab.steamos.cloud/steamrt/sniper/sdk`
  publishes an arm64 manifest at landing, use it pinned by digest with
  `aarch64-linux-gnu.2.31` instead and record the 2.31 floor.
- CPU baseline `.baseline` (armv8-a), per 52A.
- Stage `<app-name>-<version>-linux-aarch64`; 66A's objcopy split applies
  unchanged; 66C's AppImage step applies through the shared composite action.

**aarch64-windows**
- Package: cross on `ubuntu-24.04`, `-Dtarget=aarch64-windows`, arm64 VC
  libs, committed DXIL (D3D12 on Windows-on-Arm GPUs accepts SM 6.0). LTO
  follows 52A's `ltoSupportedForTarget` (off for COFF under 0.17).
- Stage `<app-name>-<version>-windows-aarch64`; 66A copies the arm64 SDL PDBs
  and PE images into its symbols.

**CI additions**
- `ci.yml`:
  - `linux-arm64` on `ubuntu-24.04-arm`: SDL dev packages (same list as
    `linux`), `zig build verify`, `zig build test -Doptimize=ReleaseSafe`.
  - `windows-arm64` on `windows-11-arm`: `zig build fetch-sdl`,
    `zig build verify`, `zig build test -Doptimize=ReleaseSafe`.
  - `macos` gains `softwareupdate --install-rosetta --agree-to-license`
    (idempotent), `zig build check -Dtarget=x86_64-macos.11.0
    -Doptimize=ReleaseFast`, `zig build test -Dtarget=x86_64-macos.11.0
    -frosetta`, and the two-direction cross-arch replay check above.
- `release.yml`: `package-linux-aarch64`, `package-windows-aarch64`, and the
  macOS job switched to `-Dmacos-universal=true`; all through 66A's composite
  actions; artifacts `package-{linux,windows}-aarch64`,
  `package-macos-universal2`, and matching `symbols-*`.

### Checklist

- [ ] **`build_sdl.py --macos-arch`** and the darwin-on-darwin relaxation of
      52A's cross-target configure error (Linux keeps the error).
- [ ] **`-Dmacos-universal`**: validation + fix-it, second target/TranslateC/
      module/exe/SDL prefix, `lipo -create` for the exe and three dylibs,
      `lipo -verify_arch` checks, the universal2 stage name, 66A's
      dSYM/strip on the fat exe.
- [ ] **aarch64-linux**: `release.yml` `package-linux-aarch64` (runner and
      container per the landing rule), `ci.yml` `linux-arm64`.
- [ ] **aarch64-windows**: `release.yml` `package-windows-aarch64`, `ci.yml`
      `windows-arm64`, arm64 PDBs in symbols.
- [ ] **macOS CI**: Rosetta install, x86_64 ReleaseFast check, x86_64 tests
      under `-frosetta`.
- [ ] **Cross-arch replay**: `src/app/replay_script.zig` (the Slice 49 table,
      consumed by its determinism tests and the runner), `zl-replay
      --record-script` with `--repeat`, usage text, and the two-direction
      `macos` CI step. Test (`replay_runner.zig`): `--record-script` with
      `--repeat 1` into a `tmpDir`, then the runner's verify path on the
      file returns `matched`; an unknown `--repeat` value (0 or non-numeric)
      prints usage and exits 64.
- [ ] **Docs**: `docs/development-workflow.md` "Release Targets" table (target,
      runner, container, baseline, glibc/macOS floor, artifact), the
      universal2 determinism note and the cross-arch replay check, the
      per-target gates, `zl-replay --record-script` in "## Replay runner";
      `docs/setup.md`
      (Rosetta for x86_64 tests on Apple Silicon).

### Acceptance checks

- [ ] `lipo -info` on the staged exe and each dylib lists `x86_64 arm64`;
      `dwarfdump --uuid` lists two UUIDs for both the exe and the dSYM, equal
      pairwise.
- [ ] The universal2 app launches natively on Apple Silicon and with `arch
      -x86_64 <app>.app/Contents/MacOS/<app-name>` (manual, on a Mac).
- [ ] `ci.yml` `linux-arm64`, `windows-arm64`, and the extended `macos` jobs
      are green, including both directions of the cross-arch replay check
      (`matched`).
- [ ] A test tag publishes the aarch64 Linux tarball, the aarch64 Windows zip,
      and the universal2 macOS zip with their `symbols-*` archives; each
      extracts to the 52B layout.
- [ ] Manual: the aarch64 Linux build renders on an ARM64 Linux host with a
      display; the aarch64 Windows build renders on a Windows-on-Arm device.
- [ ] `zig build verify` passes; the docs are updated.

### VoidLight reference

VoidLight builds macOS arm64 only (`CMakeLists.txt:47-52`, `-mcpu=native`),
x86_64 Linux/Windows only, and has no CI. Nothing to port; 66B is net-new.

