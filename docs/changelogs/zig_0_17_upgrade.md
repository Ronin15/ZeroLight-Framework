# Zig 0.17 Upgrade Changelog

Branch: `zig-0.17-upgrade`

Base: `77a99f7` (`shader update`)

## Summary

Moves the framework from Zig 0.16 to Zig 0.17.0 (`build.zig.zon`
`minimum_zig_version = "0.17.0"`). Under 0.17 the old tree failed in `build.zig`
before any `src/` file compiled. The 0.17 build system splits configuration from
the make phase and removes custom steps. The language removes `@cImport` and the
`**` array-repeat operator, and reshapes `@typeInfo`. `@hasDecl` now changes
behavior without any compile error. Runtime behavior, hot paths, and pipeline
contracts are unchanged. The only contract change is that `onResume` is now a
required state hook.

Commits, in order:

1. Build and source compile fixes, plus the `onResume` contract change. The tree
   does not build at any point in between, so they share one commit.
2. Whole-tree `zig build fmt` migration, kept separate so the mechanical
   builtin renames stay out of the other diffs.
3. `tools/lint_idioms.py` rules for the removed and deprecated spellings.
4. Docs and agent tooling version bumps, plus this changelog.

## Build system (`build.zig`)

| 0.17 break | Fix |
| --- | --- |
| `std.builtin.OptimizeMode` is now a deprecated alias, and its tags are `.debug/.safe/.fast/.small` | `std.builtin.Optimize` and the new tags in `parseLogLevel`, `release_lto`, and `gpu_debug`. `-Doptimize=ReleaseFast` style flags are still accepted. |
| `addFmt` paths are `LazyPath` | `b.path("build.zig")`, `b.path("build.zig.zon")`, `b.path("src")` |
| `b.getInstallPath` removed | `setCwd(.{ .relative = .{ .base = .install_bin } })` for `run` and `gpu-smoke` |
| `b.args` removed | `addPassthruArgs()` on the `run` and `bench` Run steps, so `zig build bench -- --group X` still forwards |
| `@cImport` removed from the language | New `src/platform/sdl_c.h`, translated by one shared `b.addTranslateC` step created in `build()`. Every SDL-linked module gets it with `addImport("sdl_c", ...)`, and `src/platform/sdl.zig` uses `pub const c = @import("sdl_c");`. On Windows, `_FORTIFY_SOURCE=0` and the SDL include dirs moved onto the TranslateC step. Library paths and `linkSystemLibrary` stay on the modules. |
| Custom steps gone (`Step.init` takes a closed tag set, no `makeFn`) | `ValidateWindowsSdlStep` deleted. `createWindowsSdlFileChecks` builds one `b.addCheckFile` per required header, import library, and DLL. Each is named `check Windows <file> (<fix-it hint>)` and returned as `validate_steps: []const *Step`, with no aggregator step. Compile steps, the shared TranslateC, the DLL installs, and `fetch-sdl` depend on all of them. A bad `-Dsdl-root` now fails on a `check Windows ...` line, not on a translate-c error. |
| `Build.pathFromRoot` removed | `package.dependency.builder.root.joinString(...)` for package lib dirs |
| `Run.addPathDir` removed | `WindowsSdlRuntimeDependencies` carries `path_env: ?[]const u8`. On a Windows host only, `windowsSdlRunPath` poisons the configure cache, makes the SDL lib dirs absolute against the cwd, prepends them to the configure-time `PATH`, and Run steps call `setEnvironmentVariable("PATH", ...)`. The poisoning is needed because the configure cache key excludes the environment, so Windows hosts re-run `build.zig` on every invocation. Other hosts, including Windows cross-builds, keep the configure cache (`--cache-poison=disallowed` passes). |
| `.cwd_relative` construction for `-Dsdl-root` paths | `b.graph.cwdRelativePath(...)` |
| Packages now extract to project-local `zig-pkg/` | `fetch-sdl` description and docs updated (`zig-pkg/` was already gitignored) |

Checked against 0.17 and still accurate: Mach-O targets skip LTO. In 0.17,
`-flto` still requires LLD ("LTO requires using LLD"), and LLD still rejects
Mach-O ("using LLD to link macho files is unsupported").

## Language and stdlib (`src/`)

- **`**` array repeat removed (83 sites).** Converted to `@splat`. When the
  declaration has no type, it now carries one: `var a: [N]T = @splat(x);`.
  Typed fields, assignments, and returns use a bare `@splat(x)`, including
  `return @splat(null);` for the optional atlas-meta slots.
- **`@typeInfo` reshaped.** `std.meta.fields` is now a compile error.
  - Enum counts use `@typeInfo(E).@"enum".field_names.len`.
  - Enum iteration uses `inline for (comptime std.meta.tags(E))`, which keeps
    declaration order, instead of `@enumFromInt(field.value)`.
  - Struct-field purity tests and `nav_memory.multiArrayRowBytes` iterate
    `field_names` / `field_types`.
  - The allocator-free signature tests iterate `@"fn".param_types`.
- **`Allocator.dupeZ` removed.** Replaced with `dupeSentinel(u8, bytes, 0)` (4 sites).
- **`builtin.mode` tags renamed.** Updated in `runtime_perf_log.enabled` and the
  pathfinding Debug-only asserts.
- **`std.ArrayList` grew a runtime-safety lock.** It is 32 B in Debug and
  ReleaseSafe, and 24 B in ReleaseFast and ReleaseSmall. This broke
  `@sizeOf(ChunkPatchScratch) == 64`. `nav_graph.zig` now uses the repo's
  `thread_shared_record_alignment = 64` policy on `ChunkPatchScratch` and
  `ChunkRemaskScratch`. It asserts `@alignOf == 64` and `@sizeOf % 64 == 0`,
  which is the real invariant: worker slots never share a cache line. The patch
  slot is 128 B in safe modes and 64 B in fast/small. `ReleaseFast` and
  `ReleaseSmall` compile checks cover both layouts.

## Silent semantic change: `@hasDecl` and `onResume`

In Zig 0.17, `@hasDecl` no longer sees non-`pub` declarations. The `StateStack`
adapter gated `onResume` on `@hasDecl`. As a result, a state fixture with a
private `onResume` was silently skipped, and one test failed.

`onResume` is now required. The adapter calls it unconditionally.
`MainMenuState`, `LoadingState`, `SettingsMenuState`, and `PauseState` gained
no-op `pub fn onResume`. The 19 `state.zig` fixtures and 3
`pause_controller.zig` fixtures that lacked one also gained no-op hooks.
`docs/state-stack-and-input.md` and `docs/coding-standards.md` now say that both
hooks are required, and that behavior hooks must not be gated on `@hasDecl`.

## `zig fmt` migration

The 0.17 `zig fmt` rewrites `@intFromEnum(x)` to `@backingInt(x)` (104 sites)
and `@enumFromInt(x)` to `@fromBackingInt(@intCast(x))` (29 sites), across 27
files. Four doc comments that named `@intFromEnum` were updated by hand.

## Lint

`tools/lint_idioms.py` (part of `zig build verify`) now rejects these spellings:

- `@intFromEnum(` and `@enumFromInt(`
- `std.meta.fields(` and `.dupeZ(`
- `OptimizeMode` and `@cImport`
- the `**` array-repeat operator
- `@hasDecl(` in `src/`

The stale "removed in Zig 0.16" `usingnamespace` message is now version-neutral.

## Docs and tooling

- Version references are bumped to 0.17 in `CLAUDE.md`, `AGENTS.md`, `README.md`,
  `docs/setup.md`, `docs/development-workflow.md`, `docs/coding-standards.md`,
  `build.zig` comments, `.claude/agents/*`, `.claude/workflows/*`, and `.grok/**`.
- `docs/setup.md` and `docs/development-workflow.md` now cover the `zig-pkg/`
  package location, the per-file Windows SDL check steps, and the Windows-host
  `PATH` prepend with its configure re-run.
- The live roadmap's forward guidance uses the new builtin spellings.
- The settled archive and older changelogs are left as historical record.

## Validation

- `zig build verify` passes (1131/1131 tests).
- `zig fmt --check build.zig build.zig.zon src` is clean.
- `zig build check -Doptimize=ReleaseFast` and `-Doptimize=ReleaseSmall` pass.
- The bench passthru args reach the binary.
- On Linux, `zig build fetch-sdl -Dtarget=x86_64-windows` and
  `zig build check -Dtarget=x86_64-windows` pass, including with
  `--cache-poison=disallowed`. `-Dsdl-root=/nonexistent` fails on
  `check Windows ...` step lines.
- Still a manual follow-up: a real Windows host run of `run`, `test`, `bench`,
  and `gpu-smoke` to exercise the `PATH` prepend, plus `gpu-smoke` and the
  ReleaseSafe soak on a display.
