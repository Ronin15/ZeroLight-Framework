## Slice 66A: Shipped-Build Crash Triage — Split Symbols, Symbol Store, Crash Reports, Linux Window Icon

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 52B](slice-52b.md), [Slice 52C](slice-52c.md), [Slice 54](slice-54.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** No external gate: land before the first build
leaves the developer's machines, because a crash in a build without it
cannot be triaged afterwards.

Goal:
- Every package keeps full debug info outside the shipped binary, keyed by
  an identity the binary carries (GNU build-id, Mach-O UUID, PDB GUID+age),
  and every tag attaches those symbols to its GitHub Release.
- A shipped `ReleaseFast` binary that crashes (signal, Windows exception,
  or Zig panic) writes a small versioned text report, plus a minidump on
  Windows, to `<pref>/crashes/`, carrying that identity and raw frame
  addresses.
- A stdlib-Python tool turns a report back into `file:line` from the stored
  symbols.
- On Linux the game window carries its icon at runtime.

### Current foundation

- No crash handling exists: `src/main.zig` re-exports
  `logging.std_options` and declares no root `panic` or `debug`.
- Zig 0.17 disables the segfault handler when runtime safety is off, so a
  `ReleaseFast` SIGSEGV dies silently; `std.Options.enable_segfault_handler`
  re-enables it and `handleSegfault` defers to a root `debug` declaration.
  `std.debug.FullPanic` builds a root panic.
- Stack tracing is disabled under `-fstrip`, so the shipped exe must strip
  after link. Probe (2026-10-05): a ReleaseFast full-LTO exe with
  `build_id = .sha1`, split with binutils `objcopy`, captured frames from
  the stripped binary that `llvm-symbolizer` resolved to `file:line`.
- `zig objcopy` cannot split ELF in 0.17 (`--strip-debug`,
  `--only-keep-debug`, `--extract-to` are unimplemented); binutils and
  `llvm-objcopy` work.
- A Zig 0.17 Mach-O exe built through the build system holds only stabs to
  `.zig-cache` objects; its DWARF exists only there until `dsymutil` runs
  (52B runs it at package time). `strip -S` keeps `LC_UUID`.
- The dev binary has no `NT_GNU_BUILD_ID`. LLD honors `build_id = .sha1` in
  release modes; the self-hosted Debug ELF linker silently ignores it.
- Std's POSIX handler uses `SA_RESETHAND | SA_ONSTACK`; std-created threads
  get an alternate signal stack, SDL-created threads do not, and Windows
  ignores signal stacks.
- Windows: 52B installs the game PDB to `zig-out/package-symbols/`; the
  pinned SDL VC zips ship `SDL3*.pdb` for x64 and arm64.
- `src/platform/sdl.zig` `Window` has no icon call; `src/assets/image.zig`
  `loadPng` decodes RGBA. Nothing sets a runtime window icon.
- Slice 54 provides the pref dir (`UserStorage`, app identity).

### Architecture notes

- Recorded decisions: a minimal in-process reporter (shipped builds
  otherwise leave nothing); no network upload, telemetry, or consent UI;
  minidumps on Windows only; Breakpad/Crashpad rejected; Linux symbols keep
  function names in the shipped binary.
- Platform owns every OS binding; `main.zig` gains only root declarations;
  `Engine` installs the reporter and window icon once on the main thread
  (`.claude/rules/engine-design.md`).
- The reporter's state is the documented process-global exception:
  module-level, fixed-size, documented at the site
  (`.claude/rules/budgets-capacities.md`). Everything the crash path needs
  is resolved at install; the crash path allocates nothing, joins no paths,
  reads no clock, and is bounded in time, so any interruption leaves a
  partial but parseable report.
- Crash reporting never touches simulation state and runs only after the
  process is lost; tests, benches, and gpu-smoke keep their current std
  options.
- A crash-probe dev executable (never packaged) drives every crash shape;
  the game exe gains no crash trigger
  (`.claude/rules/tests-benchmarks.md` § Tests).
- The window icon resolves through `AssetStore` as an asset-root path, is
  Linux-only (Windows uses the resource icon, macOS the bundle icon), and a
  missing icon logs once and never blocks startup
  (`.claude/rules/assets-audio.md`).
- VoidLight reference: port `SDL_LoadPNG` + `SDL_SetWindowIcon`
  (`GameEngine.cpp:279-424`) and `dsymutil`; not its worker-thread icon
  load, every-OS icon call, Debug-only dSYM, or disabled stripping.

### Checklist

- [ ] Build identity in every packaged ELF binary.
- [ ] Linux split symbols (`.debug` + debuglink, stripped staged exe, SDL
      `.so` copies) through a configurable `objcopy`, with `CheckFile`s.
- [ ] macOS strip after 52B's `dsymutil` and before codesign; dylib copies
      beside the dSYM.
- [ ] Windows symbols: SDL PDBs plus copies of the exe and DLLs.
- [ ] Crash reporter core: report format v1, identity parsers (ELF note,
      Mach-O UUID, PE CodeView), retention pruning, root panic/segfault
      hooks; pure tests including truncation, partial reports, and the
      second-crashing-thread gate.
- [ ] POSIX backend (identity, async-signal-safe writes, watchdog, abort
      handling) with a `tmpDir` report test.
- [ ] Windows backend (last-chance exception filter, writer thread off the
      faulting stack, minidump) with a CI-only test.
- [ ] Crash-probe executable with segv, abort, panic, stack overflow, and
      worker variants; in `check`.
- [ ] CI crash matrix on all three OSes, each report symbolized from its own
      ingested symbols.
- [ ] Root wiring in `main.zig`; reporter installed right after user
      storage and before `ThreadSystem`.
- [ ] Linux runtime window icon with validation tests.
- [ ] `tools/symbols.py` (ingest, fetch, symbolize, self-test) and a
      `zig build tools-selftest` step in `verify`.
- [ ] CI: package composite actions, `package-<os>-<arch>` /
      `symbols-<os>-<arch>` artifacts, symbols attached to releases; 52C's
      acceptance wording updated.
- [ ] Docs: `docs/development-workflow.md` Symbols And Crash Reports and the
      Release Checklist; `docs/architecture.md` crash-report ownership and
      the process-global exception; `tools/README.md`.

### Acceptance checks

- [ ] Linux package: staged exe has `.gnu_debuglink`, `.symtab`,
      `.eh_frame`, no `.debug_info`, the same build-id as its `.debug`, and
      its RUNPATH.
- [ ] Linux round trip (manual): `kill -SEGV` and `kill -ABRT` each write a
      report that `symbols.py symbolize` resolves to `src/…zig:<line>`; a
      truncated report symbolizes as partial.
- [ ] CI crash matrix green on all three OSes, including Windows stack
      overflow with a full report and minidump.
- [ ] Windows (manual): a forced fault in the packaged game writes a report
      and minidump that WinDbg and `symbols.py` resolve.
- [ ] macOS (on a Mac): exe and dSYM UUIDs match, codesign still verifies,
      and a SIGSEGV report symbolizes.
- [ ] Linux X11: the running window's `_NET_WM_ICON` is 256×256; with the
      icon removed the game starts and warns once.
- [ ] A test tag publishes package and symbols archives for each OS.
- [ ] `zig build verify` passes, including `tools-selftest`.
