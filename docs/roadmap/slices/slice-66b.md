## Slice 66B: Additional Package Targets — macOS universal2, aarch64-linux, aarch64-windows

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 66A](slice-66a.md), [Slice 52A](slice-52a.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started — gated per target.** Each target lands when its
trigger fires; the slice completes when all three have landed:
- universal2: the first game whose store page lists macOS and must run
  natively on Intel Macs;
- aarch64-linux: the first storefront or device that requires native ARM64
  Linux;
- aarch64-windows: the first game listing native Windows on ARM (x86_64
  under emulation covers players until then).

Goal: releases produce a macOS universal2 `.app` (replacing the arm64-only
one), an aarch64 Linux tarball, and an aarch64 Windows zip, each with its
symbols archive, and CI builds and tests each architecture on a native or
emulating runner.

### Current foundation

- 52A's SDL contract: Linux/macOS build pinned SDL from source only when
  host os+arch equals the target; Windows uses the VC zips, which already
  contain `lib/arm64/` DLLs, import libs, and PDBs, and `build.zig` already
  maps `aarch64` to `lib/arm64`.
- 52A CPU baselines: `x86_64_v2` (x86_64), `apple_m1` (aarch64-macos),
  `.baseline` elsewhere; one shipped baseline per game. Windows LTO is off
  under Zig 0.17.
- 52C release runners: Linux in the Steam Runtime sniper SDK container,
  Windows cross-built on Ubuntu, macOS on arm64.
- Probes: Zig 0.17 cross-links `aarch64-windows-gnu` (non-LTO), builds both
  macOS arches, and `llvm-lipo -create` merges them; `-frosetta` runs x86_64
  macOS tests on arm64.
- One SDL CMake build for two arches is unsound: SDL's configure-time
  feature checks run for one arch.
- Determinism: Slice 49's contract holds within one executable; no
  cross-target identity is required (owner decision 2026-10-14).

### Architecture notes

- Build, tooling, and CI only; no `src/` game-code change. The universal
  build affects the package graph only; dev build, run, test, and benches
  keep the primary arch.
- Both macOS slices follow the game's one shipped baseline (52A); each
  per-arch SDL build runs 52A's backend assertion. Cross-arch SDL source
  builds are allowed darwin-on-darwin only; Linux stays host-arch.
- 66A's symbol split and 66C's signing/AppImage steps apply to every new
  target through the shared package actions.
- VoidLight builds arm64 macOS and x86_64 elsewhere only; nothing to port.

### Checklist

- [ ] Per-arch macOS SDL builds and the darwin-on-darwin relaxation of 52A's
      cross-target configure error.
- [ ] Universal macOS packaging: second-arch graph, lipo for the exe and
      dylibs with arch verification, universal2 stage name, 66A's dSYM and
      strip on the fat exe.
- [ ] aarch64-linux release and CI jobs (runner/container and glibc floor
      recorded at landing).
- [ ] aarch64-windows release and CI jobs with arm64 symbols.
- [ ] macOS CI: Rosetta, x86_64 release check, x86_64 tests under Rosetta.
- [ ] Docs: `docs/development-workflow.md` Release Targets table, the
      universal2 determinism note, per-target gates;
      `docs/setup.md` Rosetta.

### Acceptance checks

- [ ] `lipo -info` lists `x86_64 arm64` for the staged exe and every dylib;
      exe and dSYM UUID pairs match.
- [ ] Manual (Mac): the universal2 app runs natively on Apple Silicon and
      as x86_64.
- [ ] `linux-arm64`, `windows-arm64`, and extended `macos` CI jobs are
      green.
- [ ] A test tag publishes the three new packages with symbols archives,
      each in the 52B layout.
- [ ] Manual: the aarch64 Linux and Windows builds render on native
      hardware.
- [ ] `zig build verify` passes; docs updated.
