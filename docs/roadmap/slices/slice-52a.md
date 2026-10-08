## Slice 52A: Release CPU Baseline, Toolchain Pins, Pinned SDL, Committed Shaders

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: none · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: in progress.** The Windows LTO-off item landed 2026-10-05 (`01754ec`); everything else not started. First of 52A → 52B → 52C. No gameplay dependency.

Goal: a release build means the same ISA, the same Zig, the same SDL, and the
same shader bytes on every machine that produces it. The shipped ISA is
`x86_64_v2` (SSE4.2 + POPCNT) on x86_64 and `apple_m1` on macOS arm64, never
the build host's CPU. A fresh clone builds with only Zig, plus CMake/C
toolchain/platform headers on Linux and macOS. No shader compilers are needed
for a normal build.

Forward reference: Slice 52D (SIMD layer codegen for the v2 baseline) depends on
this slice's `-Dcpu-baseline` option.

### Current foundation

- `build.zig:76` calls `b.standardTargetOptions(.{})`. With no `-Dtarget` or
  `-Dcpu`, the query's `cpu_model` is `.determined_by_arch_os`, which resolves
  to the **host CPU**. On the reference dev host (Ryzen 9 7900X3D, `znver4`,
  AVX-512), `zig build package --release=fast` can emit AVX-512 instructions.
  Those crash with SIGILL on the Steam Deck (Zen 2), on Zen 2/3, and on Intel
  12th–14th gen consumer parts. Cross targets get Zig's generic `x86_64`
  baseline instead, which is SSE2 only (`lib/std/Target.zig`
  `Cpu.Model.baseline`). So today a Windows cross package and a native Linux
  package ship different ISAs.
- `src/core/simd.zig:8-12` fixes `lane_count = 4` (`@Vector(4, f32)`).
  `.claude/rules/memory-performance.md` mandates one lane width through `core`.
- `src/` contains no `@setFloatMode` and no `@mulAdd`, so Zig's default strict
  float mode applies. LLVM never contracts `a*b+c` into FMA, so float results
  are bit-identical across `x86_64`, `x86_64_v2`, and native.
- Scalar==SIMD and serial==threaded parity tests exist in about 18 modules,
  including `movement`, `collision`, `steering`, `perception`, `nav_graph`, and
  `data_system/system`.
- Windows SDL today:
  - `build.zig:11-36` and `build.zig.zon:15-31` pin SDL 3.4.10, SDL_ttf 3.2.2,
    and SDL_mixer 3.2.4 as lazy VC zips.
  - Per-file `CheckFile` validation lives at `:408-428`, `fetch-sdl` at
    `:122-130`, and the DLL install plus Windows-host PATH prepend at
    `:583-665`.
- Linux and macOS SDL today: `build.zig:85` makes `-Dsystem-sdl` default to true
  on every non-Windows target. Those targets link whatever pkg-config finds
  (`:308-317`, `:353-355`), with no version floor.
- Zig toolchain:
  - `build.zig.zon:13` sets `minimum_zig_version = "0.17.0"`.
  - The dev host installs Zig through mise
    (`~/.local/share/mise/installs/zig/0.17.0`).
  - There is no pin file and no guard against a newer Zig.
- Cost of the last Zig upgrade: `77a99f7..99e6959` was 80 files, +879/−479
  lines (56 files under `src/`), across 8 commits. The tree could not build
  between commits (`docs/changelogs/zig_0_17_upgrade.md:18-25`).
- Shaders today:
  - `build.zig:38-73` defines `shader_programs` (sprite and tilemap, each with
    vert/frag).
  - `:761-871` compiles them per target OS with host `glslc`, `spirv-cross`,
    and `dxc`.
  - The install step depends on those compiles (`:208-212`), and so does
    `verify` (`:247`). A fresh clone without `glslc` cannot run `zig build`.
  - `:188` excludes `.glsl .spv .msl .dxil .hlsl` from the bulk asset copy.
  - The MSL entry-signature `CheckFile` (`:823`) runs only for macOS targets.
- `tools/lint_idioms.py` and `tools/lint_assets_if_changed.py` are the existing
  pattern for Python lints wired into `verify` (`build.zig:236-249`).
- `src/benchmarks/suite.zig:607-616` prints a header with profile, warmup, and
  worker count only. It omits optimize mode, CPU model, and target, so archived
  outputs cannot be compared across baselines.

### Architecture notes

**CPU baseline: `-Dcpu-baseline` in `build.zig`**

- Add the option `-Dcpu-baseline=<native|ship|compat>` (enum
  `CpuBaseline { native, ship, compat }`). The default is `native` when
  `optimize == .debug` and `ship` otherwise. That covers ReleaseSafe soaks,
  ReleaseFast ship builds, ReleaseSmall, and release benches.
- Replace `b.standardTargetOptions(.{})` with three steps: call
  `b.standardTargetOptionsQueryOnly(.{})`, apply
  `applyCpuBaseline(query, baseline, host_arch)`, then call
  `b.resolveTargetQuery(query)`. The arch is `query.cpu_arch orelse host`.

  | Arch / OS | `ship` | `compat` | `native` |
  | --- | --- | --- | --- |
  | x86_64 (any OS) | `std.Target.x86.cpu.x86_64_v2` | `std.Target.x86.cpu.x86_64` (SSE2) | query untouched |
  | aarch64-macos | `aarch64.cpu.apple_m1` (every Apple Silicon Mac) | same | query untouched |
  | other aarch64 | `.baseline` | `.baseline` | query untouched |

  For `native`, an untouched query means the host CPU for the host arch and
  Zig's arch baseline for a cross arch.
- An explicit `-Dcpu=` always wins. Detect it as
  `cpu_model != .determined_by_arch_os` or a non-empty feature add/sub set.
  Passing both `-Dcpu` and `-Dcpu-baseline` is a configure-time
  `std.debug.panic` with a fix-it. This is the same pattern as invalid
  `-Dlog-level` (`build.zig:758`).
- The resolved target is shared, so the policy applies to the exe, tests,
  bench, and gpu-smoke alike.
- The SDL source build (below) never receives the baseline. SDL does its own
  runtime CPU dispatch, which mirrors VoidLight keeping its aggressive flags
  off dependencies.
- This option is CPU only. The glibc floor and macOS minimum come from the
  release `-Dtarget` (52C), and the SDL source build inherits the same floor.
  Pinning glibc 2.31 here would break local release builds: a glibc-2.31 exe
  linked against a host-built `libSDL3.so` that carries newer symbol versions
  fails under LLD's executable default `--no-allow-shlib-undefined`.
- **`package` refuses `native` and `-Dcpu` builds.** On the reference dev
  host (Zen 4, AVX-512) a `native` build crashes with SIGILL on Zen 2 and the
  Steam Deck. `zig build package` fails at configure (`addFail` on the
  `package` step only) when the resolved baseline is `native` or when an
  explicit `-Dcpu=` is passed: "package requires -Dcpu-baseline=ship or
  compat; native and -Dcpu builds are dev/bench only". 52A adds this refusal to
  today's `package` step, and 52B keeps it in its refusal list.
- **Why `ship` is v2 and not v3:**
  - Every SIMD kernel in `src/` is `@Vector(4, f32)` through `core/simd.zig`,
    which is 128-bit. AVX2's 256-bit lanes buy little here; they only appear
    when LLVM auto-vectorizes a scalar loop.
  - v2 gives the 4-lane kernels single-instruction forms that SSE2 emulates
    with multi-instruction sequences (list below).
  - v2 runs on every x86_64 gaming CPU still in use (Intel Nehalem 2008+, AMD
    Bulldozer/Jaguar 2011+), including Zen 2 and the Steam Deck. Record that
    month's Steam Hardware Survey SSE4.2 and AVX2 figures in the doc when this
    lands.
  - A native build is strictly worse than any named baseline, because it can
    leak AVX-512.
- **What v2 adds over the SSE2 `compat` floor,** since SIMD is
  `@Vector(4, f32)`:
  - SSE4.1 `roundps` (floor/ceil/round), `blendvps` (select), `pmulld` (i32
    multiply), `pminsd`/`pmaxsd` (i32 min/max), `ptest`, and
    `insertps`/`extractps` in the 4-lane kernels;
  - SSSE3 `pshufb` for byte shuffles;
  - `popcnt`, used by `@popCount` over component masks and bitsets;
  - `cmpxchg16b` and `lahf`/`sahf`.
  - FMA is not part of v2, and strict float mode would leave it unused anyway.

  Expect the largest gains in the floor/round, select, and integer-lane paths.
  The A/B check below records the real number, with an informational
  `-Dcpu=x86_64_v3` column that documents why AVX2 is not the default.
- **Per-game opt-down:** a game that wants maximum reach sets
  `-Dcpu-baseline=compat` (`x86_64`, SSE2; every x86_64 CPU). CI
  compile-checks `compat` so this path never rots.
- **One baseline per game release.** The CPU Baseline doc section states that
  every OS package of one game release uses the same `-Dcpu-baseline`, so
  replays, saves, and any future lockstep peers depend on cross-baseline
  equality no further than 52C proves; a baseline switch happens at a release
  boundary and is documented there.
- **No runtime CPU check.** It would need code compiled without v2 to run
  before any v2 instruction executes, but Zig's start code and compiler_rt are
  compiled for the target. The minimum spec is documented instead: SSE4.2 +
  POPCNT class CPUs (`x86_64_v2`; Intel Nehalem 2008+, AMD Bulldozer/Jaguar
  2011+) for `ship`, any x86_64 CPU for `compat`, and any Apple Silicon Mac for
  `apple_m1`.
- **Float-mode lint.**
  - `tools/lint_idioms.py` gains a `src/`-only rule rejecting
    `@setFloatMode(.optimized)`, which is the Zig spelling of `-ffast-math`,
    and a rule rejecting `@mulAdd` in `src/` (enforcing
    `.claude/rules/simulation.md`). Strict float mode with no `@mulAdd` is
    what keeps results identical across baselines.
  - Simulation float results are bit-identical across
    `native`/`ship`/`compat`, extending Slice 49's Determinism Contract; 52C
    proves it at battle scale.

**Zig toolchain pin**

- `build.zig.zon` `.minimum_zig_version` is the single, **exact** pin.
- `build.zig` reads it with `@import("build.zig.zon")` and adds a `comptime`
  guard. The guard rejects a compiler whose major.minor differs from the pin,
  or whose patch is lower, with:
  `@compileError("ZeroLight pins Zig 0.17.x via build.zig.zon minimum_zig_version; see docs/development-workflow.md Toolchain Pins And Upgrades")`.
- Add `mise.toml` with `[tools]` `zig = "0.17.0"`:
  - mise is the dev host's toolchain manager.
  - Its per-directory auto-switch lets each game repo pin its own Zig.
  - Use this instead of `.zigversion`, which nothing in this toolchain reads.
    `minimum_zig_version` is already read by `mlugg/setup-zig` (52C reads it
    explicitly) and by anyzig.
- New `tools/check_build_pins.py` (stdlib only, wired into `verify`) asserts
  that the `mise.toml` `zig` value equals `.minimum_zig_version`.
- `@import("build.zig.zon")` is verified: a bare import of this repo's zon
  (with the `.name = .zero_light_framework` enum literal) compiles under 0.17.0
  with no result type, and `minimum_zig_version` reads back `"0.17.0"`. No
  fallback is needed. "`@import("build.zig.zon")` still works" stays on the
  upgrade re-check list below.
- **Upgrade procedure** (described in the new `docs/development-workflow.md`
  section "Toolchain Pins And Upgrades"):
  1. An upgrade moves one Zig minor at a time, deliberately, never tracking
     master.
  2. The framework upgrades first, on a `zig-<ver>-upgrade` branch. Games
     follow after the framework branch merges, not mid-milestone. A shipped
     game may stay on its Zig version indefinitely.
  3. Bump `build.zig.zon` and `mise.toml` together. CI picks up the new version
     from zon.
  4. Commit order follows the 0.17 changelog:
     1. build plus compile fixes (the tree does not build in between);
     2. the `zig build fmt` migration as its own commit;
     3. `tools/lint_idioms.py` rules for removed spellings;
     4. docs and tooling bumps plus `docs/changelogs/zig_<ver>_upgrade.md`.
  5. Re-check list:
     - macOS LTO (`ltoSupportedForTarget`);
     - default backend/linker selection;
     - silent semantic changes, in the class of `@hasDecl`;
     - `ReleaseFast`/`ReleaseSmall` compile checks;
     - the Windows cross-check;
     - that CPU model names `x86_64`, `x86_64_v2`, and `apple_m1` still
       exist;
     - that `@import("build.zig.zon")` still works.
  6. Budget the work from the 0.17 evidence above: 80 files changed.

**SDL pin: one version triple, three delivery paths**

- `build.zig` declares
  `const sdl_pin = .{ .sdl3 = "3.4.18", .ttf = "3.2.2", .mixer = "3.2.4" }`.
  These are VoidLight's current pins. At landing, re-check that 3.4.18 is still
  the newest 3.4 patch, and pin the newest.
- The Windows `root_dir` values derive from the pin (`"SDL3-" ++ sdl_pin.sdl3`,
  and so on).
- A `comptime` check asserts that every SDL URL in zon contains
  `release-<pinned version>`.

  | Target | Default `SdlConfig` arm | Mechanism |
  | --- | --- | --- |
  | windows | `.packages` | Prebuilt VC zips. Mechanics unchanged; bumped to 3.4.18 with new hashes via `zig fetch --save=<name> <url>`. |
  | linux / macos, host os+arch == target | `.source` (new) | Lazy zon deps `sdl3_src`, `sdl3_ttf_src`, `sdl3_mixer_src`: the official release source tarballs (`…/release-3.4.18/SDL3-3.4.18.tar.gz`, `…/release-3.2.2/SDL3_ttf-3.2.2.tar.gz`, `…/release-3.2.4/SDL3_mixer-3.2.4.tar.gz`). Built by `tools/build_sdl.py` in one cached Run step. |
  | any, `-Dsystem-sdl=true` | `.system` | pkg-config, with a floor check. |
  | linux/macos cross from another os/arch | none | Configure error with a fix-it: build pinned Linux/macOS SDL on a matching host, which is what CI does. |

- **Why source on Linux/macOS:**
  - SDL publishes no Linux binaries.
  - SDL's macOS binaries ship as `.dmg`/xcframework, which `zig fetch` cannot
    unpack.
  - Hosted Ubuntu runners have no SDL3 3.4 package.
  - Upstream CMake is the build SDL itself tests, and what VoidLight already
    uses.
- **Rejected alternatives:**
  - Zig-native SDL ports: they cover core only, with no maintained
    SDL_ttf/FreeType/SDL_mixer port. Owning a port of SDL's CMake logic per
    release is a maintenance load the framework should not carry.
  - System SDL with only a floor check: not reproducible, and CI cannot build
    it.
- `WindowsSdlConfig` becomes `SdlConfig` with the arms `system`, `pending`,
  `local`, `packages`, and `source`. `.pending` keeps the lazy-fetch-then-rerun
  flow.
- `fetch-sdl` becomes "fetch and prepare pinned SDL for the selected target":
  Windows runs `CheckFile`; Linux/macOS fetch the sources and build SDL.
- **`tools/build_sdl.py` contract** (stdlib Python):
  - Arguments: the three source dirs, `--prefix <out>`, `--os linux|macos`,
    `--macos-deployment-target <ver>`, and `--revision <n>`.
  - It configures, builds, and installs, in order:
    1. SDL3;
    2. SDL3_ttf, with `SDL3_DIR` pointing at the prefix;
    3. SDL3_mixer.
  - All three use:
    - `CMAKE_BUILD_TYPE=Release`, shared libraries;
    - tests, examples, and samples off;
    - `CMAKE_INSTALL_LIBDIR=lib`;
    - `CMAKE_INSTALL_RPATH=$ORIGIN` on Linux and `@loader_path` on macOS;
    - `FETCHCONTENT_FULLY_DISCONNECTED=ON`, so a missing vendored source is a
      hard error and never a download.
  - SDL_ttf: `SDLTTF_VENDORED=ON` (vendored FreeType, linked static), with
    HarfBuzz and PlutoSVG off.
  - SDL_mixer: WAV plus the built-in header-only decoders only. Every codec
    option that needs an external or vendored library is off, because
    ZeroLight audio is WAV (`development-workflow.md:37-38`). Re-validate this
    off-list against the pinned version's `option()` names whenever the pin
    moves.
  - Compiler: the host default C compiler, not `zig cc`. With an explicit
    `-target`, `zig cc` drops host include paths, and SDL's backend detection
    would silently lose X11/Wayland.
  - macOS: `CMAKE_OSX_DEPLOYMENT_TARGET` is the resolved target's macOS min
    version, which `build.zig` passes in.
  - The script never receives `-Dcpu-baseline` flags.
- **Required-backend assertion.** After configuring SDL3, the script finds
  `SDL_build_config.h` in the build tree and checks for required defines:
  - Linux:
    - `SDL_VIDEO_DRIVER_X11`
    - `SDL_VIDEO_DRIVER_WAYLAND`
    - `SDL_GPU_VULKAN`
    - `SDL_AUDIO_DRIVER_ALSA`
    - at least one of `SDL_AUDIO_DRIVER_PIPEWIRE` / `SDL_AUDIO_DRIVER_PULSEAUDIO`
  - macOS:
    - `SDL_VIDEO_DRIVER_COCOA`
    - `SDL_GPU_METAL`
    - `SDL_AUDIO_DRIVER_COREAUDIO`

  If any are missing, the script exits non-zero and lists the missing defines
  plus the dev packages to install. This prevents ever shipping an SDL without
  Wayland.
- **Build graph:**
  - One `b.addSystemCommand(&.{ python, ... })` Run step.
  - Inputs: `addFileArg(b.path("tools/build_sdl.py"))` and three
    `addDirectoryArg(dep.path(""))` calls.
  - Output: `addOutputDirectoryArg("sdl-prefix")`.
  - Caching: the cache key includes the content-addressed package path. To
    force a rebuild after a host compiler or header change, bump the
    `--revision` constant in `build.zig`.
  - The TranslateC step adds `prefix.path(b, "include")`.
  - Each module adds `addLibraryPath(prefix/lib)` and calls
    `linkSystemLibrary(name, .{ .use_pkg_config = .no })`.
  - Test, bench, and gpu-smoke modules get `addRPath(prefix/lib)`. That path is
    absolute and never ships.
  - The game exe gets `addRPathSpecial("$ORIGIN/lib")` on Linux. On macOS it
    gets `"@executable_path/lib"` plus `"@executable_path/../Frameworks"`.
  - The default install copies the SONAME files into `bin/lib/`:
    `libSDL3.so.0`, `libSDL3_ttf.so.0`, `libSDL3_mixer.so.0` on Linux, and
    `lib*.0.dylib` on macOS. This mirrors the Windows DLL install
    (`build.zig:598-623`), so `run` and `dev` keep working.
- **`-Dsystem-sdl=true` fallback:**
  - The default flips to `false` on every OS.
  - The floor is the pinned minor at `.0`, since SDL patch releases are
    ABI-compatible: SDL3 ≥ 3.4.0, SDL_ttf ≥ 3.2.0, SDL_mixer ≥ 3.2.0.
  - On Linux/macOS, Run steps enforce it with
    `pkg-config --atleast-version=<floor> sdl3|sdl3-ttf|sdl3-mixer`.
  - Each step is named
    `check system SDL3 >= 3.4.0 (if failing: upgrade system SDL or drop -Dsystem-sdl)`,
    following the fix-it-in-step-name pattern at `build.zig:408-411`.
    TranslateC depends on them.
  - Windows system mode has no pkg-config, so it gets the runtime diagnostic
    only.
- **Runtime diagnostic** (`src/platform/sdl.zig`, `logging.platform`; cold
  path, main thread):
  - New build options: `sdl_pinned: bool`, plus `sdl_version_expected`,
    `sdl_ttf_version_expected`, and `sdl_mixer_version_expected`, each a `u32`
    in `SDL_VERSIONNUM` encoding. The expected value is the pin in pinned mode
    and the floor in system mode.
  - New `pub fn logLinkedVersions()`, called once from `Engine.init` right
    after `SdlContext.init` (`engine.zig:78`). At debug level it logs the header
    versions (`SDL_MAJOR_VERSION`…) and the linked versions (`SDL_GetVersion()`,
    `TTF_Version()`, `MIX_Version()`).
  - New pure function
    `classifyLinkedVersion(linked, expected, pinned) VersionCheck`, returning
    `{ match, newer_patch, mismatch, below_floor }`. The engine logs a warning on
    `mismatch` in pinned mode (a different `.so`/`.dylib` got loaded, for
    example through `LD_LIBRARY_PATH` or `DYLD_*`) and on `below_floor`.
  - This is never a hard failure: a missing symbol would already have failed
    at load time.
- **Bench header** (`suite.zig:607`): add
  `zig=<builtin.zig_version> optimize=<builtin.mode> target=<arch-os-abi> cpu_model=<builtin.cpu.model.name> sdl=<pinned|system>`.
  52C's CI greps this line.

**Shader artifacts: committed by default**

- **Decision:** commit every `shader_programs` artifact in all three formats
  beside the GLSL. Today that is 12 files,
  `assets/shaders/{sprite,tilemap}.{vert,frag}.{spv,msl,dxil}`. Also commit `assets/shaders/shader_sources.sha256`, in `sha256sum`
  format with one line per `.glsl`.
- Default builds install the committed artifact for the target format to
  today's path (`<asset_root>/shaders/<stem>.<ext>`). The installed format set
  per OS is unchanged (`shaderFormatsForTarget`, `build.zig:709-716`).
- New option `-Dshader-artifacts=committed|compile`, default `committed`.
  `compile` is today's per-OS pipeline (`build.zig:761-871`), kept for local
  shader iteration.
- New step `zig build shaders-update`:
  - It compiles **all three** formats from GLSL, whatever the target OS.
    Refactor the compile code into
    `compileShaderArtifact(b, stage_source, format) LazyPath`, shared with
    compile mode.
  - It writes the outputs into `assets/shaders/` via
    `b.addUpdateSourceFiles()`, then runs
    `tools/check_shader_artifacts.py --write-lock`.
  - It requires `glslc`, `spirv-cross`, and `dxc`. The pinned versions are
    documented, and 52C's CI job is the authority.
- **Checks in `verify`** (all hosts, no shader tools needed):
  - A `CheckFile` existence check for each artifact, generated from
    `shader_programs` × formats (never a hand-kept list).
  - The MSL entry-signature `CheckFile`, now run against the committed `.msl`.
    This means Linux and Windows `verify` also catch Metal slot drift.
  - New `tools/check_shader_artifacts.py` (stdlib only), which checks that:
    - every `*.glsl` has `.spv`, `.msl`, and `.dxil` files;
    - the lock hashes match the current GLSL. This is the stale-artifact gate
      for "GLSL edited, artifacts not regenerated";
    - SPIR-V starts with the magic `0x07230203`;
    - DXIL (a `DXBC` container) has non-zero digest bytes `4..20`, meaning the
      validator signed it. D3D12 rejects unsigned DXIL.
- Add `.sha256` to the `assets_install` exclude list (`build.zig:188`).
- **Why commit** instead of compiling at build time only:
  - A fresh clone or a new game needs no shader toolchain.
  - Linux→Windows cross packaging no longer needs a Linux `dxc`, whose DXIL
    may be unsigned.
  - VoidLight's intended "checked-in binaries" fallback never existed, because
    its `.gitignore` excluded them. ZeroLight commits them *and* gates them.

**Ownership:**

- `build.zig` and `build.zig.zon` own the build graph.
- `tools/build_sdl.py`, `tools/check_shader_artifacts.py`, and
  `tools/check_build_pins.py` are build tools only.
- `src/platform/sdl.zig` owns the version diagnostic, and `src/app/engine.zig`
  calls it once at init.
- `src/benchmarks/suite.zig` owns the header.
- No `SimulationPipeline` stage, `DataSystem` store, or hot-path change.
- **Coordination with Slice 50.** Slice 50 (`-Dsanitize-thread`) and 52A both
  edit `build.zig` `createSdlModule` and the option set. Slice 50 lands first
  in the suggested order, so 52A rebases onto it. `-Dcpu-baseline` and
  `-Dsanitize-thread` are independent and both apply through the shared
  resolved target and module options.

### Checklist

- [ ] **CPU baseline.** Add `-Dcpu-baseline` and `applyCpuBaseline` using
      `standardTargetOptionsQueryOnly`/`resolveTargetQuery`: `ship` =
      `x86_64_v2` / `apple_m1` / arch baseline, `compat` = `x86_64` (SSE2).
      An explicit `-Dcpu` wins, and passing both options fails at configure.
      Debug defaults to `native` and release modes to `ship`.
- [ ] **No native packages.** `package` fails at configure for a resolved
      `native` baseline or an explicit `-Dcpu`, with the fix-it.
- [ ] **Float-mode lint.** `tools/lint_idioms.py` gains `src/`-only rules
      rejecting `@setFloatMode(.optimized)` and `@mulAdd`.
- [ ] **Zig pin.** Add the `@import("build.zig.zon")` pin guard,
      `mise.toml`, and `tools/check_build_pins.py` wired into `verify`.
- [ ] **Windows SDL bump.** Add `sdl_pin`. Bump the Windows zon deps to 3.4.18
      with new hashes, derive `root_dir` from the pin, and add the `comptime`
      URL/version consistency check.
- [ ] **SDL source build.** Add the `sdl3_src`, `sdl3_ttf_src`, and
      `sdl3_mixer_src` lazy deps; `tools/build_sdl.py` with its
      required-backend assertion; the `SdlConfig.source` arm; include, library,
      and rpath wiring; the `bin/lib/` install; the generalized `fetch-sdl`;
      and the cross-target configure error.
- [ ] **System SDL fallback.** Default `-Dsystem-sdl` to `false` on every OS
      and add the pkg-config floor check steps with fix-it names.
- [ ] **Version diagnostic.** Add the build options, `logLinkedVersions`, and
      the pure `classifyLinkedVersion`. Add tests covering `match`,
      `newer_patch`, `mismatch`, `below_floor`, and the `SDL_VERSIONNUM`
      encode/decode round trip, all on synthetic integers with no SDL init.
- [ ] **Bench header.** Add the zig/optimize/target/cpu_model/sdl fields.
- [ ] **Shader artifacts.**
  - Commit every `shader_programs` artifact (12 today: sprite and tilemap,
    vert/frag, three formats) and the lock. A later slice that adds a program
    (Slice 60's composite pass) regenerates and commits its artifacts.
  - Add `-Dshader-artifacts`, the `compileShaderArtifact` refactor,
    `shaders-update`, and `tools/check_shader_artifacts.py` wired into
    `verify`.
  - Add the committed-file `CheckFile`s, the MSL signature check on all hosts,
    and the `.sha256` exclude.
- [ ] **Docs.**
  - `docs/development-workflow.md`: new sections CPU Baseline (the
    `compat`/`ship` A/B table with the informational v3 column, the
    minimum-spec CPUs, the `native` package refusal, one baseline per game
    release, and the per-game opt-down), SDL
    Versions And Sources
    (replacing Windows SDL Packages), Shader Artifacts, and Toolchain Pins And
    Upgrades.
  - `docs/setup.md`: Linux/macOS now need CMake, a C compiler, and SDL backend
    dev headers unless `-Dsystem-sdl`. Shader tools are only needed for
    `compile`/`shaders-update`.
  - `docs/rendering-assets-shaders.md`: the Shader Build section.
  - `README.md` Requirements.
  - `CLAUDE.md` command lines for `fetch-sdl` and
    `shaders-update`.
- [x] (added by Slice 66) **Windows LTO under Zig 0.17.** `ltoSupportedForTarget`
      (`build.zig:739-742`) returns false for `.coff` as well as `.macho`.
      Evidence: `zig build check -Dtarget=x86_64-windows
      -Doptimize=ReleaseFast` on `99e6959` fails at `lld-link` with
      54 undefined-symbol errors against the mingw libc/libm (`frexpf`,
      `frexpl`, `lrintl`, `lroundl`, `modfl`, `rintl`, `atanl`,
      `copysignl`, `fdiml`, `nanl`, `wmemchr`, `wmemcmp`, `wmemcpy`,
      `wmempcpy`, `wmemmove`, `wmemset`, `strndup`, `mempcpy`). Full and
      thin LTO both fail for x86_64/aarch64 windows-gnu with `link_libc`.
      Without LTO, Zig's default ReleaseFast selection links and emits the
      PDB (hello-world probe: `m.exe` + `m.pdb`). Update the `build.zig`
      comment above `release_lto` ("Linux/Windows ship with `-flto=full`")
      to "Linux ships with `-flto=full`; Darwin and Windows do not".
      Acceptance: `zig build check -Dtarget=x86_64-windows
      -Doptimize=ReleaseFast` and the `aarch64-windows` equivalent pass.
      Done 2026-10-05 (this commit): `ltoSupportedForTarget` excludes `.coff`; x86_64/aarch64 windows-gnu ReleaseFast `check` pass.
- [ ] (added by Slice 66) Add "windows-gnu LTO links (`-flto` hello-world with `-lc`)" to the
      Toolchain Pins And Upgrades re-check list beside "macOS LTO".
- [ ] Add the release CPU baseline rule to `.claude/rules/build-validation.md` when this lands.
- [ ] Add the cross-baseline float bit-identity rule to `.claude/rules/simulation.md` when this lands.
- [ ] Add the toolchain upgrade policy rule to `.claude/rules/build-validation.md` when this lands.

### Acceptance checks

- [ ] `zig build verify` passes on the Linux dev host in three configurations:
      the defaults (pinned source SDL, committed shaders), with
      `-Dsystem-sdl=true`, and with `glslc`, `spirv-cross`, and `dxc` removed
      from `PATH`.
- [ ] CPU baseline is visible in the bench header:
  - `zig build bench -Doptimize=ReleaseFast -- --group movement --profile quick`
    shows `cpu_model=x86_64_v2`.
  - A Debug run shows the host model.
  - `-Dcpu-baseline=compat` shows `cpu_model=x86_64 ` (the bare SSE2 model).
  - `-Dcpu=x86_64_v4 -Dcpu-baseline=ship` fails at configure with the fix-it.
- [ ] `zig build package --release=fast -Dcpu-baseline=native` and
      `zig build package --release=fast -Dcpu=znver4` fail at configure with
      the dev/bench-only fix-it.
- [ ] An A/B table is recorded in `docs/development-workflow.md`: ReleaseFast
      `--group movement|steering|collision|perception|render-game-prep` under
      `compat` (`x86_64`) and under `ship` (`x86_64_v2`), plus an
      informational `-Dcpu=x86_64_v3` column (not a shipping option), on the
      reference machine.
- [ ] `zig build test -Doptimize=ReleaseSafe` passes under both `ship` and
      `compat`.
- [ ] Windows cross-build passes from the Linux host with the 3.4.18 packages,
      including under `--cache-poison=disallowed`:
      `zig build fetch-sdl -Dtarget=x86_64-windows` and
      `zig build check -Dtarget=x86_64-windows -Doptimize=ReleaseFast`.
- [ ] The startup debug log reports linked SDL 3.4.18, SDL_ttf 3.2.2, and
      SDL_mixer 3.2.4, with no mismatch warning.
- [ ] Shader-artifact gates fail as designed:
  - Editing a `.glsl` without running `shaders-update` fails `verify` on the
    stale-lock line.
  - A zeroed DXIL digest fails `verify` on the unsigned-DXIL line.
- [ ] A Zig of a different minor fails at configure with the policy message.
- [ ] The docs listed in the Checklist are updated.

### VoidLight reference

- `CMakeLists.txt:182-229` pins SDL `release-3.4.18`, SDL_ttf `release-3.2.2`,
  and SDL_mixer `release-3.2.4`. It builds them from upstream source as shared
  libraries with vendored SDL_ttf dependencies (`SDLTTF_VENDORED`), and with
  `SDLMIXER_MP3_MPG123 OFF` (`:226`).
  - **Port:** the version triple, the upstream-CMake source build, and the
    vendored FreeType.
  - **Do not port:** FetchContent git clones at configure time (network during
    configure, tag not content-hashed). ZeroLight uses hash-pinned zon
    tarballs, offline after the fetch, with `FETCHCONTENT_FULLY_DISCONNECTED`.
  - **Do not port:** VoidLight's vendored mixer codecs (`SDLMIXER_VENDORED`,
    `:221`). ZeroLight is WAV-only.
- `CMakeLists.txt:58-66` and `:466-470` apply
  `-march=x86-64-v3 -mtune=generic -mavx2 -mfma` to project code only.
  `docs/performance/BuildSafetyControls.md:24-32` records AVX2 as a hard
  minimum spec (SIGILL, no runtime dispatch).
  - **Port:** the "deps keep their own flags" rule and the hard minimum spec
    with no runtime dispatch.
  - **Do not port** the v3/AVX2 level. ZeroLight's SIMD is 128-bit
    `@Vector(4, f32)`, so `ship` is `x86_64_v2` (reaches Zen 2 and the Steam
    Deck with margin) and FMA stays unused under strict float mode.
- `CMakeLists.txt:89-101` is the Profile build: `x86-64-v2`, no AVX, for
  Valgrind.
  - **Port as `ship`.** ZeroLight's release level is VoidLight's profiling
    level. It also matters here: a `native` build on the Zen 4 dev host can
    emit AVX-512, which Valgrind does not support. Use `ship`/`compat` for
    Valgrind/heaptrack sessions.
- `CMakeLists.txt:47-52` uses `-mcpu=native` for Apple arm64 Release.
  - **Do not port.** It ties the shipped binary to the build Mac's chip.
    ZeroLight uses `apple_m1`.
- `CMakeLists.txt:55-56` and `:63-65` use `-ffast-math`.
  - **Do not port.** ZeroLight's contracts are bit-exact:
    - scalar==SIMD and serial==threaded parity tests;
    - Slice 46's same-build save→load N-step trace parity;
    - 52C's cross-baseline digest check.

    Fast-math allows reassociation, FMA contraction, and reciprocal
    approximations that differ between the 4-lane body and the scalar tail,
    and between CPU baselines. VoidLight could tolerate it only because its
    saves are state snapshots that are never re-simulated
    (`BuildSafetyControls.md:38`).
  - The lint rule above enforces this.
- `CMakeLists.txt:267-298` and `:423-425` claim "using checked-in GPU shader
  binaries" when tools are missing. But `.gitignore:5-8` ignores
  `res/shaders/*.spv|*.metal|*.dxil`, so a fresh VoidLight clone has no
  shaders. VoidLight also writes compiled shaders into the source tree on every
  build (`SHADER_FINAL_OUTPUT` under `res/shaders`).
  - **Do not port either part.** ZeroLight writes source-tree artifacts only
    through the explicit `shaders-update` step, and gates them in `verify`.

