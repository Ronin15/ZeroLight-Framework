## Slice 66A: Shipped-Build Crash Triage — Split Symbols, Symbol Store, Crash Reports, Linux Window Icon

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 52B](slice-52b.md), [Slice 52C](slice-52c.md), [Slice 54](slice-54.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** After **52B** (staging layouts and the
`zig-out/package-symbols/<stage>/` dir), **52C** (`release.yml`, `-Dpython`),
and **54** (`UserStorage`, `sdl.prefPath`, `AppConfig.org_name`). No external
gate: land before the first build leaves the developer's machines (first
external playtest or storefront upload), because a crash in a build without
66A cannot be triaged after the fact.

Goal:
- Every package keeps its full debug info **outside** the shipped binary, keyed
  by a build identity the binary carries (GNU build-id, Mach-O UUID, PDB
  GUID+age), and every tag attaches those symbols to its GitHub Release.
- A shipped `ReleaseFast` binary that crashes (signal, SEH exception, or Zig
  panic) writes a small text report — plus a minidump on Windows — to
  `<pref>/crashes/`, carrying that identity and raw frame addresses.
- `tools/symbols.py` turns a report back into `file:line` from the stored
  symbols on the developer's Linux host.
- On Linux, the game window carries its icon at runtime (X11 `_NET_WM_ICON`,
  and Wayland `xdg-toplevel-icon` where the compositor supports it).

### Current foundation

- **No crash handling exists in either framework.** `src/main.zig:12` re-exports
  `logging.std_options` (`src/core/logging.zig:8-10`, `log_level` only); there
  is no root `panic` or `debug` declaration. VoidLight has no handler,
  minidump, or backtrace code (grep of `src/`, `include/`, `CMakeLists.txt`).
- **Zig 0.17 disables the segfault handler in shipped builds.**
  `std.debug.default_enable_segfault_handler = runtime_safety and
  have_segfault_handling_support` (`lib/std/debug.zig:1540`), so in
  `ReleaseFast` a SIGSEGV dies with no output. `std.Options.enable_segfault_handler`
  (`lib/std/std.zig:122`) re-enables it; `handleSegfault` defers to
  `root.debug.handleSegfault` when declared (`debug.zig` `handleSegfault`).
  `std.debug.FullPanic(fn)` (`debug.zig:103`) builds a root `panic` namespace;
  `defaultPanic` (`:511`) and `defaultHandleSegfault` are public. On Windows the
  std handler is a first-chance vectored handler
  (`RtlAddVectoredExceptionHandler`, `attachSegfaultHandler`).
- **Stack capture survives stripping; `-fstrip` does not.**
  `std.Options.allow_stack_tracing = !builtin.strip_debug_info`
  (`std.zig:185`), so the shipped exe must never use `.strip = true`; stripping
  happens after link. `captureCurrentStackTrace(options, addr_buf)` unwinds via
  DWARF CFI from `.eh_frame`, which `objcopy --strip-debug` keeps.
  **Probe (2026-10-05):** a ReleaseFast + full-LTO + `build_id = .sha1` exe
  split with binutils `objcopy`, whose `root.debug.handleSegfault` calls
  `captureCurrentStackTrace(.{ .context = ctx, .allow_unsafe_unwind = true })`,
  captured 4 frames from the **stripped** binary; `llvm-symbolizer
  --obj=<name>.debug` resolved them to `main.crashHere main.zig:28` and
  `main.main main.zig:39`. `__ehdr_start` gave the image base (`0x1000000`; the
  exe is `ET_EXEC`, like today's game binary).
- **`zig objcopy` cannot split ELF in 0.17.** `zig objcopy --strip-debug`,
  `--only-keep-debug`, and `--extract-to` all fail with `error: unimplemented`
  on a Zig-built ELF, and `b.addObjCopy` (`lib/std/Build/Step/ObjCopy.zig`) runs
  the same implementation. Binutils `objcopy` (and `llvm-objcopy`) work.
- **Std looks for split debug info.** `lib/std/debug/ElfFile.zig:50-215`
  searches `/usr/lib/debug/.build-id/xx/yyyy.debug`, the debuginfod cache, then
  `<exe_dir>/<debuglink>` and `<exe_dir>/.debug/<debuglink>`; the macOS reader
  (`debug/MachOFile.zig:388-405`) loads an adjacent `<exe>.dSYM` matched by
  UUID. Dropping the `.debug`/`.dSYM`/`.pdb` next to the exe restores in-process
  `file:line` traces on a developer machine.
- **macOS DWARF never enters the binary.** A Zig 0.17 Mach-O exe built through
  the build system carries `LC_UUID` and N_OSO stabs pointing at
  `.zig-cache/o/<hash>/<name>_zcu.o`; the DWARF lives only in that cache object.
  `dsymutil` on the build host produced a `.dSYM` whose UUID equals the exe's,
  and `strip -S` kept the UUID. 52B (umbrella addition) therefore runs
  `dsymutil` at package time into `package-symbols/<stage>/<app-name>.dSYM`
  and 52C uploads it; 66A builds on that step.
- **Windows:** 52B installs the game PDB to `zig-out/package-symbols/<stage>/`
  and 52C uploads it as `symbols-windows`. The pinned SDL VC zips also ship
  `SDL3.pdb`, `SDL3_ttf.pdb`, `SDL3_mixer.pdb` in `lib/{x64,arm64,x86}/`
  (verified in `zig-pkg/`).
- **Build identity:** today's dev binary has no `NT_GNU_BUILD_ID`
  (`readelf -n zig-out/bin/my-sdl3-game`). `Compile.build_id: ?std.zig.BuildId`
  (`Build/Step/Compile.zig:103`) sets it; LLD honors `.sha1` in both full-LTO
  ReleaseFast and default-linker ReleaseSafe (probe). Zig 0.17's self-hosted
  Debug ELF linker silently ignores it (`zig build-exe -O Debug
  --build-id=sha1`: `readelf -n` empty, no diagnostic).
- **Signal and exception plumbing in 0.17.** Std's POSIX handler is installed
  with `SA_SIGINFO | SA_RESTART | SA_RESETHAND | SA_ONSTACK`
  (`lib/std/debug.zig:1579-1581`), so a second fault inside any handler code
  (unwinder, `dladdr`) takes the default action and kills the process
  immediately. `std.Thread.maybeAttachSignalStack` gives `start.zig`'s main
  thread and every `std.Thread` a `signal_stack_size` (default `1 << 18`)
  alternate stack (`Thread.zig:1744-1764`); it returns early on Windows
  ("vectored exception handlers always run on the main stack"), and
  `std.zig:124-132` documents that Windows ignores `signal_stack_size`.
  Threads created by SDL (audio, HID) never call it. A root
  `pub const debug` is consulted from process start (`debug.zig:1667-1672`
  `handleSegfault`). `std.c` exposes `openat`, `write`, `alarm`, `getpid`,
  and `dl_iterate_phdr` (`c.zig:10577`, `:10830`, `:11070`, `:11079`,
  `:11449`); `std.debug.cpu_context.fromWindowsContext` is public
  (`debug/cpu_context.zig:193`), and `std.Thread.SpawnConfig.stack_size`
  sets a spawned thread's stack.
- **Window icon:** `src/platform/sdl.zig:32-55` `Window` has
  `create`/`deinit`/`setMinimumSize` only. `src/assets/image.zig:31-75`
  `loadPng` decodes through `SDL_LoadPNG` to RGBA32 owned pixels.
  `Engine.init` creates the window at `engine.zig:86`, then the `AssetStore` at
  `:97`; `ThreadSystem.init` is at `:130`. 52B adds `SDL_SetAppMetadata`, the
  Windows resource-icon hints, the macOS `.icns`, and the Linux `.desktop` +
  stage-root `<app-name>.png`; nothing sets a runtime icon.
- `AssetStore` (`src/assets/assets.zig:8-75`) only reads asset-root-relative,
  traversal-safe paths, with an exe-relative fallback (`:63-75`).
- Slice 54: `UserStorage.init(allocator, io, org_name, app_name)` runs right
  after SDL init (54 "Startup apply order" step 4); `sdl.prefPath` copies then
  `SDL_free`s.

### Architecture notes

**Owners.**
- `build.zig`: `exe.build_id`, the split-symbol Run steps, `-Dobjcopy`, the icon
  install and `window_icon_path` build option.
- `src/platform/crash_report.zig` (portable core, pure formatters/parsers, root
  hooks), `src/platform/crash_report_posix.zig` (Linux/macOS),
  `src/platform/crash_report_windows.zig` (Windows). Platform owns every OS
  binding; Zig 0.17's `std.os.windows.kernel32` exposes almost nothing
  (`CreateProcessW` only), so the Windows file declares its own
  `extern "kernel32"` / `dbghelp` function types locally.
- `src/main.zig` gains exactly three root declarations (wiring only).
- `src/app/engine.zig` calls `crash_report.install` and `applyWindowIcon` once
  each, main-thread cold path.
- `src/app/user_storage.zig` (54) gains one read-only accessor.
- `src/platform/sdl.zig` gains `Window.setIcon`.
- `tools/symbols.py` (stdlib only, plus `llvm-symbolizer` for `symbolize`).
- `.github/actions/package-*/action.yml`, `release.yml` edits.
- No pipeline, store, or hot-path change.

**1. Build identity in every packaged binary**
- `exe.build_id = .sha1` whenever the resolved target's `ofmt == .elf` (all
  modes). It takes effect wherever LLD links: every `package` mode, which is
  what ships. Debug builds use the self-hosted linker, which emits no
  `NT_GNU_BUILD_ID`; a Debug crash report therefore says `identity: none`, and
  nothing (tests, docs, `symbols.py`) relies on build-id in Debug. `.sha1` is a
  content hash, so identical inputs give identical IDs. Mach-O already has
  `LC_UUID`; PE already has the CodeView RSDS record (GUID + age) plus
  `TimeDateStamp`/`SizeOfImage`.

**2. Split symbols per OS (package graph only; dev `zig-out/bin` unchanged)**

| OS | Staged binary | `zig-out/package-symbols/<stage>/` |
| --- | --- | --- |
| Linux | `objcopy --strip-debug --add-gnu-debuglink=<app>.debug` output (keeps `.symtab`, `.eh_frame`, RUNPATH, build-id) | `<app-name>.debug` (`objcopy --only-keep-debug --compress-debug-sections=zlib`), copies of `lib/libSDL3*.so.0` |
| macOS | `strip -S` output (removes N_OSO stabs and their absolute cache paths; keeps symtab and `LC_UUID`), then 52B's codesign | `<app-name>.dSYM/` from 52B's package-time `dsymutil` (it runs **before** 66A's strip, while the cache `.o` exists), plus 66A's copies of `Frameworks/*.dylib` |
| Windows | unchanged exe (PDB already external) | `<app-name>.pdb` (52B), `SDL3.pdb`, `SDL3_ttf.pdb`, `SDL3_mixer.pdb` from the VC zip `lib/<arch>/`, copies of `<app-name>.exe` and the three DLLs (WinDbg needs the image for x64 unwind data in a minidump) |

- **Linux graph:** two `addSystemCommand` Run steps on the `-Dobjcopy=<exe>`
  tool (default `objcopy`, the 52C `-Dpython` pattern). Step 1:
  `objcopy --only-keep-debug --compress-debug-sections=zlib` with
  `addFileArg(exe.getEmittedBin())` and `addOutputFileArg("<app-name>.debug")`.
  Step 2: `objcopy --strip-debug` with
  `addPrefixedFileArg("--add-gnu-debuglink=", debug_out)`, the exe, and
  `addOutputFileArg("<app-name>")`. The staging install takes step 2's output
  instead of the raw exe. The debuglink stores the basename and a CRC, so the
  pair must be produced together; never rename the `.debug`.
- **Why keep `.symtab`:** function names appear in in-process traces and in the
  report's module+offset lines without the symbols archive, at a few hundred
  KB. A game that wants to hide names changes `--strip-debug` to
  `--strip-all` in its fork (std then prints `???` names; offline
  symbolization is unaffected).
- **macOS graph (macOS hosts only, 52A rule):** 52B's `dsymutil <exe> -o
  <out-dir>/<app-name>.dSYM` Run step (`addOutputDirectoryArg`) already exists;
  66A adds `strip -S -o <out> <exe>`, ordered after it (`step.dependOn`), and
  the bundle's `MacOS/<app-name>` installs the stripped output instead of the
  raw exe; 52B's ad-hoc `codesign` Run step depends on it. In 66B both steps
  run on the lipo'd fat exe, producing one fat dSYM.
- **SDL symbols:** SDL keeps 52A's `CMAKE_BUILD_TYPE=Release` (no `-g`). SDL
  frames symbolize to exported names from the shipped `.so`/`.dylib` copies
  (`.dynsym`/exports) and, on Windows, from SDL's own PDBs.
- **Self-validation:** `CheckFile`s for every `package-symbols` file above.
  Linux acceptance uses `readelf` (below); nothing in the graph parses ELF.
- **Supersedes 52B's "No symbol stripping" note**: staged Linux/macOS binaries
  are stripped of DWARF; shipped traces show function names, and `file:line`
  comes from the stored symbols.

**3. Crash reports (`src/platform/crash_report*.zig`)**

- **Decision: yes, a minimal in-process reporter.** Without it a shipped
  ReleaseFast crash leaves nothing: the std segfault handler is off, a Windows
  GUI-subsystem exe (52B) has no stderr, a Finder launch has no terminal, and
  Steam keeps no Linux/Windows crash data for indie titles. macOS CrashReporter
  `.ips` files still appear; the reporter complements them.
- **Decision: no network upload.** Reports stay in `<pref>/crashes/`; players
  attach them to bug reports (documented path per OS). No backend, no
  telemetry, no consent UI to build.
- **Decision: minidump on Windows only.** `MiniDumpWriteDump` (dbghelp, present
  on every Windows) adds every thread's stack, which matters for
  `ThreadSystem` worker crashes. Linux relies on the report plus
  systemd-coredump where enabled; macOS on the report plus CrashReporter.
  Breakpad/Crashpad are rejected (large C++ dependencies, out-of-process
  handler, upload server).
- **Root wiring (`src/main.zig`, the only change there):**

  ```zig
  pub const std_options = crash_report.app_std_options;
  pub const panic = crash_report.panic;
  pub const debug = crash_report.root_debug;
  ```

  - `app_std_options` copies `logging.std_options` and sets
    `enable_segfault_handler = builtin.os.tag != .windows`. It keeps std's
    default `signal_stack_size` (`1 << 18`), with a comptime assert that it is
    non-null and ≥ 64 KiB, so every std-created thread handles signals on a
    256 KiB alternate stack. POSIX keeps std's SIGSEGV/SIGILL/SIGBUS/SIGFPE
    handler, which calls our `root_debug.handleSegfault`. Windows disables
    std's first-chance vectored handler; `install` registers a last-chance
    `SetUnhandledExceptionFilter` instead, which sees only truly unhandled
    exceptions (drivers that probe memory under `__try` never trigger it) and
    receives the `EXCEPTION_POINTERS` the minidump needs.
  - `panic = std.debug.FullPanic(panicHandler)`.
  - `root_debug = struct { pub const handleSegfault = segfaultHandler; }`.
  - `src/tests.zig`, `src/gpu_smoke.zig`, and `src/benchmark_runner.zig` keep
    their current `std_options` and get no hooks: tests and benches are dev
    tools. The new dev executable `src/crash_probe.zig` (below) uses the same
    three declarations as `main.zig`.
- **Process-global state (the slice's only globals: signal handlers and
  exception filters get no context argument).** All are module-level in
  `crash_report.zig`, fixed-size, and documented at the site
  (`.claude/rules/budgets-capacities.md`):

  ```zig
  var installed: ReportTarget = .{};                      // every field defaulted (dir_fd = -1, lengths 0)
  var installed_ready: std.atomic.Value(bool) = .init(false);
  var crashing: std.atomic.Value(u8) = .init(0);          // 0 → 1 by the first crashing thread only
  var crash_buffers: CrashBuffers = undefined;              // frames: [crash_report_max_frames]usize,
                                                           // header: [crash_report_header_bytes]u8,
                                                           // line: [crash_report_line_bytes]u8
  ```

  - `install` fills `installed` on the main thread, then
    `installed_ready.store(true, .release)`. Every handler first does
    `installed_ready.load(.acquire)`; when false it falls straight through to
    the std default (POSIX: std's stderr trace; Windows: no filter is
    registered yet, so WER only). A crash during SDL init therefore never
    reads a half-written target.
  - `crash_buffers` is touched only by the thread that won `crashing`
    (`cmpxchgStrong(0, 1, .acq_rel, .acquire)`), so no crash-path buffer
    lives on the faulting stack. A second crashing thread (or the `abort()`
    that ends a panic) skips writing and falls through to the default action.
    If that default action ends the process while the first thread is still
    writing, the first report is already partially on disk (ordering below).
  - The writer functions take `*const ReportTarget` and `*CrashBuffers`
    (`frames`, `header`, `line`); handlers pass `installed` and the statics,
    so tests pass local targets and buffers and never touch the globals.

  ```zig
  pub const crash_report_format_version: u16 = 1;
  pub const crash_report_max_frames: usize = 64;          // main loop → state → pipeline → stage → worker is < 40 deep; bounds the report
  pub const crash_report_header_bytes: usize = 2 * 1024;  // app/build/module/identity/kind/reason/fault/thread lines; reason ≤ 512
  pub const crash_report_line_bytes: usize = 1024;        // one frame line: "#NN 0x<abs> <module ≤ 255 B>+0x<offset>"
  pub const crash_report_message_max_bytes: usize = 512;  // panic messages are truncated, never allocated
  pub const crash_report_keep: usize = 8;                 // newest report stems kept; older .txt/.dmp pruned at install
  pub const crash_report_path_capacity: usize = 1024;     // bytes (UTF-8); Windows keeps [crash_report_path_capacity]u16 copies
  pub const crash_report_watchdog_s: c_uint = 10;         // POSIX: alarm() bound on the whole crash path
  pub const crash_writer_stack_bytes: usize = 256 * 1024; // Windows crash-writer thread stack
  pub const crash_writer_wait_ms: u32 = 10_000;           // Windows: filter's bounded wait for the writer
  pub const minidump_type: u32 = 0x0000_1040;             // MiniDumpWithIndirectlyReferencedMemory | MiniDumpWithThreadInfo

  pub const CrashKind = enum { signal, panic, exception };
  pub const IdentityKind = enum { none, gnu_build_id, macho_uuid, pe_codeview };
  pub const BuildIdentity = struct {
      kind: IdentityKind = .none,
      id_bytes: [20]u8 = @splat(0), // build-id (≤ 20), UUID (16), or GUID (16)
      id_len: u8 = 0,
      pe_age: u32 = 0,
      pe_time_date_stamp: u32 = 0,
      pe_size_of_image: u32 = 0,
      image_base: usize = 0,
  };
  pub const ReportTarget = struct {
      dir: [crash_report_path_capacity]u8 = @splat(0), dir_len: u16 = 0, // 0 → stderr only
      stem: [64]u8 = @splat(0), stem_len: u8 = 0,                         // "crash-<startup_unix_s>-<pid>"
      app_name: []const u8 = "", app_version: []const u8 = "", app_identifier: []const u8 = "", // build_options statics
      exe_name: [64]u8 = @splat(0), exe_name_len: u8 = 0,
      identity: BuildIdentity = .{},
      main_thread_id: std.Thread.Id = 0,
      platform: PlatformState = .{},
      // POSIX PlatformState: dir_fd: c_int = -1 (crashes dir, opened at install, never closed),
      //   report_name_z: [80]u8 ("<stem>.txt\x00").
      // Windows PlatformState: report_path_w / dump_path_w: [crash_report_path_capacity]u16 (NUL-terminated),
      //   mini_dump_write_dump: ?*const MiniDumpWriteDumpFn = null, request_event / done_event: ?HANDLE = null.
  };
  pub const CrashInput = struct {
      kind: CrashKind,
      reason: []const u8,         // signal name, exception code text, or truncated panic message
      fault_address: ?usize,
      context: ?std.debug.CpuContextPtr,
      first_address: ?usize,      // panic: first_trace_addr
  };
  ```
- **Handlers:**
  - `panicHandler(msg, first_trace_addr)`: report `kind = .panic`, then
    `std.debug.defaultPanic(msg, first_trace_addr)` (stderr trace + abort).
    On Windows the report is written by the crash-writer thread (below).
  - `segfaultHandler(addr, name, opt_ctx)` (POSIX): report `kind = .signal`,
    then `std.debug.defaultHandleSegfault(addr, name, opt_ctx)`.
  - POSIX `SIGABRT` (C-side `abort()`, e.g. glibc heap-corruption checks):
    `install` adds a `sigaction` (`SA_SIGINFO | SA_ONSTACK | SA_RESETHAND`)
    whose handler writes a `kind = .signal`, reason `Abort` report and returns,
    so `abort()` re-raises with the default disposition.
  - Windows filter: hands the exception to the crash-writer thread, waits,
    then returns `EXCEPTION_CONTINUE_SEARCH` so WER still records the crash.
    It prints no stderr trace: a GUI-subsystem exe has no stderr, and loading
    PDBs inside the filter is exactly the work the writer thread exists to
    move off the faulting stack.
- **`install(allocator, io, options: InstallOptions) void`** — never fails;
  each problem logs once on `logging.platform` and degrades:
  - `InstallOptions { pref_dir: ?[]const u8, app_name, app_version,
    app_identifier }`, the last three from 52B's build options.
  - Joins `<pref_dir>/crashes`, creates it (`std.Io` dir create-path), and
    copies it into `installed.dir`. A null pref dir, a path longer than
    `crash_report_path_capacity`, or a create failure → `dir_len = 0` plus
    one `warn` ("crash reports disabled: …; stderr only").
  - Stem from wall-clock seconds at install (app layer, never gameplay) and the
    pid, so the crash path never reads a clock.
  - **Everything the crash path needs is resolved here, never in it:**
    - POSIX: `dir_fd = open(dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC)` and
      `report_name_z`. An `open` failure → `dir_fd = -1` (stderr only) plus
      one `warn`.
    - Windows: `report_path_w` / `dump_path_w` (`<dir>\<stem>.txt` / `.dmp`,
      UTF-16), `LoadLibraryW(L"dbghelp.dll")` + `GetProcAddress
      ("MiniDumpWriteDump")`, two auto-reset events (`CreateEventW`), and the
      crash-writer thread: `std.Thread.spawn(.{ .stack_size =
      crash_writer_stack_bytes }, crashWriterMain, .{})`, detached, parked in
      `WaitForSingleObject(request_event, INFINITE)` for the process lifetime.
      A spawn or event failure → one `warn`; the filter is still registered
      and returns `EXCEPTION_CONTINUE_SEARCH` without writing (WER records
      the crash). Then `SetUnhandledExceptionFilter`.
  - Identity, computed once here:
    - Linux: `std.c.dl_iterate_phdr`, first callback (the main executable):
      `PT_NOTE` scan through the pure `parseGnuBuildIdNotes(notes) ?[]const
      u8`; `image_base = dlpi_addr + lowest PT_LOAD p_vaddr` (equals
      `&__ehdr_start`).
    - macOS: `extern const _mh_execute_header`; pure `findMachOUuid(header
      bytes) ?[16]u8`; `image_base = &_mh_execute_header`.
    - Windows: `GetModuleHandleW(null)`; pure `parsePeIdentity(image bytes)
      ?PeIdentity` reads the debug directory's CodeView `RSDS` (GUID, age,
      PDB name), `TimeDateStamp`, and `SizeOfImage`.
  - Prunes `crash-*.txt`/`crash-*.dmp` to the newest `crash_report_keep` stems
    (names sort by stem); unrelated files are untouched.
  - POSIX: the SIGABRT `sigaction`.
  - Publishes `installed_ready` last, then logs `info`: `crash reports:
    dir=<dir> keep=8 identity=<kind>:<hex>`.
- **Crash path** (allocation-free by construction: no function on it takes an
  allocator; std's unwinder may use its debug-info allocator internally, the
  same best-effort contract as std's own handler). The order guarantees that
  every completed `write` survives a later fault:
  1. **Watchdog (POSIX).** `std.c.alarm(crash_report_watchdog_s)`. SIGALRM's
     default disposition terminates the process, so a deadlocked unwinder or
     `dladdr` (for example a fault inside `malloc` that holds its lock) ends
     after 10 s with whatever lines are already on disk. The alarm stays armed
     through std's default handler that follows, bounding the whole path.
     Windows bounds the same path with the filter's `crash_writer_wait_ms`.
  2. **Open.** POSIX: `std.c.openat(dir_fd, &report_name_z, .{ .ACCMODE =
     .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o600)`;
     `openat`, `write`, `close`, and `alarm` are on POSIX's
     async-signal-safe list, and no path is joined at crash time. Windows
     (writer thread): `CreateFileW(report_path_w, GENERIC_WRITE, 0, null,
     CREATE_NEW, FILE_ATTRIBUTE_NORMAL, null)`. A failed open → stderr only.
  3. **Header.** Pure `formatHeader(target, input, &bufs.header)` through
     `std.Io.Writer.fixed`, one `write` of everything through the `frames:`
     line, then the same bytes to stderr (fd 2; skipped on Windows).
  4. **Frame `#00` before unwinding.** `signal`/`exception`: the context's
     `getPc()`; `panic`: `first_address`. Written as its own line, so even a
     fault on the first unwind step leaves the faulting PC on disk.
  5. **Unwind.** `std.debug.captureCurrentStackTrace(.{ .context =
     input.context, .first_address = input.first_address,
     .allow_unsafe_unwind = true }, &bufs.frames)`. With a context, std reports
     the context PC first (`StackIterator.ctx_first`), so index 0 is skipped
     (already written).
  6. **Frames, one `write` per line.** Per frame: module + offset via POSIX
     `dladdr` (declared locally; `std.c` lacks it) or Windows
     `GetModuleHandleExW(FROM_ADDRESS | UNCHANGED_REFCOUNT)` +
     `GetModuleFileNameW`; frames in the exe use
     `target.identity.image_base`. Pure `formatFrameLine` into `bufs.line`.
  7. **Trailer.** `frames_end: <n> skipped=…` then `end`, then `close`.
  8. **Windows only:** `<stem>.dmp` (below).

  | Interruption | What is on disk |
  | --- | --- |
  | Second fault in steps 2–7 (POSIX: `SA_RESETHAND` default action; Windows: the writer's own filter call sees `crashing` set and returns `CONTINUE_SEARCH`) | header + `#00` + every frame line written so far; no `end` |
  | Hang in steps 5–6 | the same, after the 10 s watchdog / wait |
  | Crash before `installed_ready` | no report; std default (POSIX stderr trace) / WER |

  `symbols.py` treats a report without `end` as partial: it symbolizes the
  frames present and prints `partial report: crash path interrupted after
  #NN`.
- **Stack overflow.**
  - POSIX: the main thread and every `std.Thread` (ThreadSystem workers and
    the Slice 51 lane) run the handler on
    their 256 KiB alternate stack, and the crash path's buffers are statics,
    so an overflow produces a complete report. Threads that SDL creates
    (audio device, HID) never get an alternate stack, so an overflow on them
    ends with the kernel default (systemd-coredump / CrashReporter). This is a
    decided limit: SDL owns their creation, and ZeroLight runs only its audio
    callback and SDL-internal code there, with no recursion.
  - Windows: the filter runs on the faulting thread, which after
    `EXCEPTION_STACK_OVERFLOW` has only the guard-page remnant. The filter
    therefore does no formatting and holds no buffers. It touches only
    statics and three kernel32 calls: win `crashing`; store `info` and
    `GetCurrentThreadId()` in the static hand-off; `SetEvent(request_event)`;
    `WaitForSingleObject(done_event, crash_writer_wait_ms)`; return
    `EXCEPTION_CONTINUE_SEARCH`.
  - **Crash-writer thread (Windows).** On `request_event` it converts
    `info.ContextRecord` through `std.debug.cpu_context.fromWindowsContext`
    into a static, runs steps 2–7 with that context (the faulting thread is
    blocked in the filter, so its stack is stable to unwind from another
    thread), then calls `MiniDumpWriteDump(GetCurrentProcess(),
    GetCurrentProcessId(), dump_file, minidump_type, &mei, null, null)` with
    `mei = .{ .ThreadId = <faulting thread id>, .ExceptionPointers = info,
    .ClientPointers = FALSE }`, then `SetEvent(done_event)`. A Zig panic on
    Windows goes through the same hand-off with `info = null` (the dump shows
    the panicking thread's live state), so the panicking thread's remaining
    stack never matters either.
- **Report format v1** (UTF-8 text, one field per line; `tools/symbols.py`
  parses it):

  ```text
  ZeroLight crash report v1
  app: <app_name> <app_version> (<app_identifier>)
  build: zig=<zig_version> optimize=<mode> target=<arch>-<os>-<abi> cpu_model=<model>
  module: <exe_name> image_base=0x<hex>
  identity: gnu-build-id=<40 hex> | macho-uuid=<UUID> | pe-pdb=<pdb name>/<GUID32><age hex> pe-image=<TS %08X><SIZE %x> | none
  kind: signal | panic | exception
  reason: <text>
  fault_address: 0x<hex> | none
  thread: <id> main|worker
  frames:
  #00 0x<abs> <module>+0x<offset>
  ...
  frames_end: <n> skipped=none|unknown|<n>
  end
  ```

  Frame `#00` is the faulting PC for `signal`/`exception` and a return address
  for `panic`; `symbols.py` subtracts 1 from return addresses before lookup,
  as std does (`ra_call_offset`).
- **Engine wiring:** immediately after 54's `UserStorage.init` (54 step 4):
  `crash_report.install(allocator, io, .{ .pref_dir = user_storage.dirPath(),
  … })`. 66A adds `pub fn dirPath(self: *const UserStorage) ?[]const u8`
  (null when `PersistenceUnavailable`) to `src/app/user_storage.zig`. A crash
  before `installed_ready` is published gets the std default described
  above. There is no uninstall: the target stays valid through
  `Engine.deinit`.
- **Crash probe (dev executable, never packaged).** `src/crash_probe.zig`
  wires the same root declarations, calls `crash_report.install` with
  `--dir <path>` as the pref dir, then crashes on command: `crash-probe
  --mode segv|abort|panic|stack-overflow|worker-segv|worker-stack-overflow`
  (worker modes crash on a `std.Thread`). Stack overflow is unbounded
  recursion through a `noinline` function that writes a 4 KiB local array.
  `build.zig` adds it to `check_step` and `zig build crash-probe --
  <args>`. It is the acceptance and CI driver for every crash shape; nothing
  in the game exe gains a crash trigger.

**4. How a crash maps back (`tools/symbols.py`, stdlib Python 3)**

| OS | Report identity | Store path (under `<store>/`) | Lookup |
| --- | --- | --- | --- |
| Linux | GNU build-id | `linux/.build-id/<2 hex>/<38 hex>.debug` (debug file) and `linux/.build-id/<2>/<38>` (shipped `.so` copies) | `llvm-symbolizer --build-id=<id> --debug-file-directory=<store>/linux <addr>`; address = `offset + lowest PT_LOAD vaddr` of the debug file (`ET_EXEC`: equals the absolute address) |
| Windows | RSDS GUID+age, PE `TimeDateStamp`+`SizeOfImage` | SymStore layout: `windows/<pdb>/<GUID uppercase><age %x>/<pdb>`, `windows/<exe>/<TS %08X><SIZE %x>/<exe>` | report: exe + PDB linked into a temp dir, `llvm-symbolizer --obj=<exe> --relative-address <offset>`; minidump: WinDbg/Visual Studio with `_NT_SYMBOL_PATH=srv*<cache>*<store>/windows` |
| macOS | `LC_UUID` (per arch slice) | `macos/<UUID>/<app>.dSYM` | `llvm-symbolizer --obj=<dSYM>/Contents/Resources/DWARF/<app> --default-arch=<arch> <offset + __TEXT vmaddr>`; CrashReporter `.ips`: `atos -o <dSYM DWARF> -l <load addr> <addrs>` (documented, manual) |

- Subcommands:
  - `ingest --store <dir> <symbols archive or dir>…`: detects the OS from the
    content, parses identities (ELF notes, PE debug dir, Mach-O load commands
    including fat headers), copies into the layout, appends
    `<store>/index.tsv` (`os arch identity app version tag file`).
  - `fetch --store <dir> --tag <vX.Y.Z>`: `gh release download <tag> --pattern
    'symbols-*'`, then `ingest`.
  - `symbolize --store <dir> <report.txt>`: prints each frame as
    `#NN module+offset  function  file:line`, with `?` for unresolved frames
    and a header naming any identity not found in the store.
  - `--self-test`: parsers on hand-built ELF note / PE / Mach-O byte strings,
    report parsing on an embedded golden report and on the same report cut
    after `#01` (parsed as partial, frames kept), SymStore key formatting.
- `zig build tools-selftest` (new step, in `verify`, through `-Dpython`) runs
  `symbols.py --self-test`; 66D and 66E append their tools' self-tests to it.

**5. Runtime Linux window icon**

- **Source file:** the PNG is installed **into the asset root** at
  `icons/app-256.png` (from 52B's `platforms/linux/app-256.png`) for Linux
  targets, in both the dev install (`zig-out/bin/<asset_root>/icons/`) and the
  Linux staging dir (`assets/icons/app-256.png`, with a `CheckFile`). The
  stage-root `<app-name>.png` stays for the `.desktop` and AppImage. Reading
  the stage-root file would need a non-asset-root path rule; the copy keeps
  `AssetStore` the single traversal-safe resolver and works identically in dev,
  tarball, AppImage, and Steam.
- `build.zig` owns the sub-path once: `const window_icon_asset_subpath =
  "icons/app-256.png";`, exported as build option `window_icon_path:
  ?[]const u8` (the sub-path for Linux targets, `null` otherwise) on both
  `buildOptions` and `benchBuildOptions`.
- `src/platform/sdl.zig`: `pub fn setIcon(self: *Window, pixels: []const u8,
  width: u32, height: u32, pitch: usize) !void` →
  `SDL_CreateSurfaceFrom(w, h, SDL_PIXELFORMAT_RGBA32, ptr, pitch)` →
  `SDL_SetWindowIcon` → `SDL_DestroySurface` (SDL copies the pixels). A false
  return is `error.SdlError` with `SDL_GetError()` at `debug` (Wayland without
  `xdg-toplevel-icon-v1` reports unsupported; not a warning).
- `src/app/engine.zig`: `applyWindowIcon(&window, assets)` right after
  `AssetStore.init` (`:97`), compiled only when
  `build_options.window_icon_path != null`: `image.loadPng` → pure
  `validateWindowIcon(width, height) error{InvalidWindowIcon}!void` (square,
  power of two, 16 ≤ side ≤ 512) → `setIcon` → `image.deinit()`. Any failure
  logs one `warn` on `logging.app` and continues: a missing icon never blocks
  startup. It is not applied on Windows (resource icon, 52B) or macOS
  (`SDL_SetWindowIcon` would replace the bundle `.icns` dock icon with a PNG).
- Cold path, main thread, one ≈ 256 KiB RGBA decode at startup; no
  allocation-free claim.

**Threading/determinism:** none of this touches simulation state. Crash
reporting runs only after the process is already lost. The icon runs once
before states exist.

**Error sets:** `validateWindowIcon` → `error{InvalidWindowIcon}`;
`Window.setIcon` → `error{SdlError}`; `install` returns `void` and handles its
own `std.Io` errors by logging. Report writing has no error return (best
effort; failures are silent because no logger is safe there).

### Checklist

- [ ] **Build identity.** `exe.build_id = .sha1` for ELF targets.
- [ ] **Linux split.** Add `-Dobjcopy=<exe>` (default `objcopy`), the
      `--only-keep-debug --compress-debug-sections=zlib` and
      `--strip-debug --add-gnu-debuglink` Run steps, the stripped staged exe,
      `<app-name>.debug` and `lib/libSDL3*.so.0` copies in
      `package-symbols/<stage>/`, with `CheckFile`s.
- [ ] **macOS split.** The `strip -S` Run step after 52B's `dsymutil` and
      ahead of 52B's `codesign` step; the bundle installs the stripped exe;
      `Frameworks/*.dylib` copies in `package-symbols/<stage>/` beside 52B's
      `<app-name>.dSYM`, with `CheckFile`s.
- [ ] **Windows symbols.** Install `SDL3.pdb`, `SDL3_ttf.pdb`, `SDL3_mixer.pdb`
      from `lib/<arch>/` of each VC package plus copies of the exe and DLLs
      into `package-symbols/<stage>/`, with `CheckFile`s.
- [ ] **Crash reporter core.** `src/platform/crash_report.zig`: constants,
      types (every `ReportTarget` field defaulted), the process globals
      (`installed`, `installed_ready`, `crashing`, the static buffers),
      `CrashBuffers` (the writer takes its buffers explicitly; handlers pass
      the statics, tests pass locals), `formatHeader`, `formatFrameLine`,
      `formatTrailer`, `parseGnuBuildIdNotes`, `findMachOUuid`,
      `parsePeIdentity`, `crashStem`, `pruneReports`, `app_std_options` (with
      the `signal_stack_size` comptime assert), `panic`, `root_debug`. Tests
      (no display, no real crash):
  - golden text for each `CrashKind` with 0 and 3 frames, each identity kind,
    and a 600-byte panic message truncated to 512; the full report equals
    `formatHeader ++ formatFrameLine… ++ formatTrailer`, and the header ends
    with the `frames:` line;
  - handlers fall through to the std default while `installed_ready` is
    false (exercised through the pure `shouldWrite(ready, crashing)` gate,
    including "second crashing thread does not write");
  - `parseGnuBuildIdNotes` on a hand-built note (name `"GNU\0"`, type 3,
    20-byte desc), plus wrong type, wrong name, and truncated input → null;
  - `findMachOUuid` on a synthetic `mach_header_64` + `LC_SEGMENT_64` +
    `LC_UUID`, and without `LC_UUID` → null;
  - `parsePeIdentity` on a synthetic PE32+ (MZ, `PE\0\0`, optional header,
    debug directory → `RSDS` GUID/age/name) plus a missing-debug-dir case;
  - `pruneReports` in `std.testing.tmpDir` with 10 stems (`.txt` + `.dmp`) and
    one unrelated file → 8 newest stems remain, the unrelated file survives;
  - `crashStem` formatting and `crash_report_path_capacity` overflow →
    disabled target.
- [ ] **POSIX backend.** `crash_report_posix.zig`: `dl_iterate_phdr` /
      `_mh_execute_header` identity, `dir_fd` + `report_name_z` at install,
      local `dladdr`/`Dl_info`, the `alarm` watchdog, `openat`/`write`/`close`
      writes, SIGABRT `sigaction`. Test (Linux/macOS): `writeReport` with a
      local `ReportTarget` whose `dir_fd` is a `tmpDir` and local
      `CrashBuffers`, with a `CrashInput` from `captureCurrentStackTrace` in
      the test → the file parses as v1, has `#00`, `frames_end` ≥ 1, `end`,
      and an `identity:` line; the test cancels the watchdog with `alarm(0)`.
- [ ] **Windows backend.** `crash_report_windows.zig`: local
      kernel32/dbghelp externs (`callconv(.winapi)`: `SetUnhandledExceptionFilter`,
      `CreateEventW`, `SetEvent`, `WaitForSingleObject`, `GetCurrentThreadId`,
      `CreateFileW`, `WriteFile`, `CloseHandle`, `GetModuleHandleExW`,
      `GetModuleFileNameW`, `LoadLibraryW`, `GetProcAddress`), the
      `CrashWriter` (events + 256 KiB `std.Thread`), the minimal filter, the
      minidump call, wide-path handling. Test (runs on 52C's `windows` CI
      job; `error.SkipZigTest` elsewhere): a local `CrashWriter` and target
      in a `tmpDir` serve one `panic`-kind request with null exception
      pointers → the `.dmp` starts with `"MDMP"`, the `.txt` parses as v1
      with `end`.
- [ ] **Crash probe.** `src/crash_probe.zig`, `zig build crash-probe`, in
      `check_step`; all six modes; on Windows it calls `SetErrorMode
      (SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX)` so CI never waits on
      a WER dialog (probe only, never the game).
- [ ] **CI crash matrix** (52C `ci.yml`, ReleaseFast probe): Linux runs every
      mode; Windows runs `segv`, `panic`, `stack-overflow`, and
      `worker-stack-overflow`; macOS runs `segv` and `stack-overflow`. Each
      step asserts a `crash-*.txt` with `end` (Windows also a `.dmp` starting
      `MDMP`) and runs `symbols.py symbolize --store <tmp store>` on it
      after `ingest` of the probe's own symbols.
- [ ] **Root wiring.** The three `src/main.zig` declarations;
      `UserStorage.dirPath()`; `crash_report.install` in `Engine.init` right
      after `UserStorage.init`, before `ThreadSystem.init`.
- [ ] **Window icon.** `window_icon_path` build option, the Linux-target
      install of `platforms/linux/app-256.png` to
      `<asset_root>/icons/app-256.png` (dev install and staging + `CheckFile`),
      `Window.setIcon`, `Engine.applyWindowIcon`, `validateWindowIcon`. Tests:
      `validateWindowIcon` accepts 16/128/256/512 and rejects 255, 1024,
      256×128, 8; a test loads `app-256.png` through
      `AssetStore.init(testing.allocator, testing.io, "platforms/linux")` and
      asserts 256×256 and a passing validation.
- [ ] **`tools/symbols.py`** with `ingest`, `fetch`, `symbolize` (partial
      reports included), `--self-test`; new `zig build tools-selftest` step in
      `verify`.
- [ ] **CI.** Add the three `.github/actions/package-*/action.yml` composite
      actions (package, archive, symbols archive); switch 52C's
      `release.yml` jobs to them and to the `package-<os>-<arch>` /
      `symbols-<os>-<arch>` names; `publish` attaches `symbols-*`. Update 52C's
      acceptance wording ("three archives plus `symbols-windows` and
      `symbols-macos`", per the 52C addition below) to "three package
      archives plus three `symbols-*` archives".
- [ ] **Docs.**
  - `docs/development-workflow.md`: new "Symbols And Crash Reports" section
    (identity per OS, `package-symbols` layout, the store layout and
    `symbols.py` usage, report paths per OS — `~/.local/share/<org>/<app>/crashes`,
    `%APPDATA%\<org>\<app>\crashes`, `~/Library/Application Support/<org>/<app>/crashes`
    — dropping the `.debug`/`.dSYM`/`.pdb` beside the exe for in-process
    traces, the Windows minidump + WinDbg symbol path); the "Release
    Checklist" section; the Packaging section's symbol note replacing 52B's
    "no symbol stripping"; add "`zig objcopy` ELF strip still unimplemented"
    to 52A's Toolchain Pins And Upgrades re-check list.
  - `docs/architecture.md`: `src/platform/crash_report*.zig` ownership, root
    hooks in `main.zig` and `crash_probe.zig`, the process-global crash
    state as the documented exception, the window-icon asset path.
  - `tools/README.md`: `symbols.py`.

### Acceptance checks

- [ ] Linux `zig build package --release=fast`: `readelf -S` on the staged exe
      shows `.gnu_debuglink`, `.symtab`, `.eh_frame`, and no `.debug_info`;
      `readelf -n` shows the same `NT_GNU_BUILD_ID` in the exe and
      `<app-name>.debug`; `readelf -d` still shows RUNPATH `$ORIGIN/lib`; the
      staged exe size drop is recorded in `development-workflow.md`.
- [ ] Linux crash round trip (manual, on a display): run the staged exe, `kill
      -SEGV <pid>` → a v1 report in `~/.local/share/<org>/<app>/crashes/` with
      `kind: signal`, `frames` ≥ 1, the build-id; `symbols.py ingest` on the
      symbols archive, then `symbols.py symbolize` resolves the exe frames to
      `src/…zig:<line>`. `kill -ABRT <pid>` also writes a report. A
      truncated copy of a report (last 3 lines removed) symbolizes with the
      `partial report` notice.
- [ ] The CI crash matrix is green on all three OSes, including Windows
      `stack-overflow` and `worker-stack-overflow` (full `.txt` with `end`
      and a `.dmp`).
- [ ] Windows: the CI `windows` job runs the `CrashWriter`/minidump test
      green. Manual on a Windows host: attach `cdb -p <pid> -c "~0s; r rip=0;
      .detach; q"` to the packaged game (the forced fault runs after detach,
      so the unhandled-exception filter fires) → `.txt` + `.dmp` in
      `%APPDATA%\<org>\<app>\crashes\`; WinDbg with
      `srv*<cache>*<store>/windows` resolves `<app-name>!` frames from the
      dump; `symbols.py symbolize` resolves the report's exe frames.
- [ ] macOS (on a Mac): `dwarfdump --uuid` is identical for the staged exe and
      the dSYM; `codesign --verify --deep --strict` still passes after the
      strip; `kill -SEGV` yields a report that `symbols.py symbolize`
      resolves.
- [ ] Linux X11 (manual): `xprop -id <window id> _NET_WM_ICON` on the running
      game starts with `256, 256`; with the icon file removed the game starts
      and logs one `warn`.
- [ ] A test tag publishes three package archives and three `symbols-*`
      archives on the GitHub Release.
- [ ] `zig build verify` passes (including `tools-selftest`).
- [ ] The docs listed in the Checklist are updated.

### VoidLight reference

- `src/core/GameEngine.cpp:279-424` loads `res/img/icon.png` (128×128) with
  `SDL_LoadPNG` on a `ThreadSystem` task and calls `SDL_SetWindowIcon` on every
  OS. **Port** the `SDL_LoadPNG` + `SDL_SetWindowIcon` call. **Do not port**
  the worker-thread load (one cold 256² decode is cheaper than a future join,
  and ZeroLight creates the pool after the window) or the every-OS call
  (macOS would trade the `.icns` dock icon for a PNG; Windows already has the
  resource icon).
- `CMakeLists.txt:553-579` runs `dsymutil` for **Debug** macOS builds only and
  disables stripping. **Port** `dsymutil` (52B addition, at package time);
  **do not port** the Debug-only scope or the disabled stripping — ZeroLight
  extracts the dSYM in the release package, where the symbols matter, and
  66A then strips.
- `include/core/Logger.hpp:23-70` flushes stdout on `CRITICAL`. There is no
  handler, minidump, or symbol store; 66A is net-new.

