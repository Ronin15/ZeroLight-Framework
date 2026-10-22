# Development Workflow

## Common Commands

```sh
zig build           # build and install the app, runtime assets, and shaders
zig build run       # build, install assets/shaders, and run the app
zig build dev       # build shaders, install assets, and run the app
zig build check     # compile the game, GPU smoke, and benchmark executables, and run idiom-lint
zig build test      # run Zig unit tests (-Dtest-filter=<text> runs only matching tests)
zig build bench     # run CPU gameplay and render-prep benchmarks
zig build verify    # run check, test, shader compilation, atlas + idiom lint, fmt check
zig build package   # install selected-mode binaries and runtime assets
```

Useful supporting commands:

```sh
zig build fmt        # format build.zig, build.zig.zon, and src/
zig build shaders    # compile GLSL shader sources to platform GPU shaders
zig build gpu-smoke  # run a display-gated renderer pipeline smoke
zig build assets-lint # lint runtime atlases and source sprite consistency
zig build idiom-lint # lint Zig naming, stdlib currency, and unsafe catch unreachable
```

`zig build idiom-lint` (`tools/lint_idioms.py`, also part of `verify`) checks
the mechanical subset of `.claude/rules/zig-style.md` and
`.claude/rules/memory-performance.md`; the script's docstring lists exactly what
it enforces. `catch unreachable` and `orelse unreachable` are allowed only on
the `.init` constructors of the generational handles `TextureId`, `FontId`,
`TextTextureId`, `EntityId`, and `LeaseHandle` (guarded at every call site),
inside `test` blocks, or with a `// lint:allow catch-unreachable: <reason>`
comment at the site.

`zig build package` installs the selected-mode game binary and runtime assets.
It does not install the `gpu-smoke` development executable.

On Windows, `package`, `run`, `dev`, and normal build steps install the required
`SDL3.dll`, `SDL3_ttf.dll`, and `SDL3_mixer.dll` beside the app binary when
using the pinned package SDL path. Optional SDL_mixer codec DLLs are not copied
because current runtime audio assets are WAV-based.

`run`, `dev`, and `gpu-smoke` launch from the installed binary directory, so the
default asset root resolves copied runtime assets and generated shader files
under `zig-out/bin`. If you run the binary directly, run it from `zig-out/bin`
or provide a deliberate asset-root layout; launching from the repo root can find
source assets while missing generated shader outputs.

**Running outside the install directory:** the asset store resolves files in
this order: (1) the configured asset root (default `assets/`) relative to the
current working directory; (2) the same relative root resolved from the
directory containing the executable (exe-relative fallback). The fallback fires
only when the configured root directory does not exist at all, not when
individual files are missing. To use it, place a full `assets/` tree beside
the binary. The asset root is a relative, traversal-safe path (default
`assets`); `AppConfig` rejects absolute roots at startup.

## Release Modes

The default optimize mode is `Debug`. Release modes (when to use them:
`.claude/rules/build-validation.md`):

```sh
zig build --release=safe
zig build --release=fast
zig build --release=small
zig build -Doptimize=ReleaseFast
```

Release builds use the same pinned packages in `zig-pkg/` as Debug builds. They do
not download SDL again unless a required package is missing and Zig fetching is
enabled by the current `--fetch` mode.

**Packaged builds ship `ReleaseFast`** (no safety checks; why reserves need
proofs: `.claude/rules/memory-performance.md`).

CPU floor: every optimize mode, Debug included, defaults to the shipped CPU
minimum, `x86_64_v2` (SSE4.2, POPCNT) on x86-64, `apple_m1` on macOS arm64,
and the baseline model (NEON) on other aarch64. Gates and soaks test what
ships, and Debug benches measure the shipped instruction set on every
machine. `-Dcpu` or `-Dtarget` overrides
(`-Dcpu=native` builds for the host); moving the floor (for example to v3) is a
deliberate decision.

LTO: on Linux (ELF), `build.zig` enables `-flto=full` for the shipped **app
executable only** in `ReleaseFast`, explicitly selecting LLVM + LLD (which LTO
requires). `gpu-smoke`, benchmarks, and tests get no LTO and use Zig's default
backend and linker. macOS skips LTO (LLD cannot link Mach-O in Zig 0.17);
Windows skips it (under Zig 0.17, LTO with libc fails at `lld-link` on mingw
libc/libm symbols, while non-LTO ReleaseFast links and emits its PDB). Debug,
ReleaseSafe, and ReleaseSmall leave LTO off.

**Release gate:** a multi-hour `--release=safe` soak precedes every ReleaseFast
release candidate (`.claude/rules/build-validation.md`).

## Build Options

Customize app metadata at build time:

```sh
zig build -Dapp-name=my-game -Dwindow-title="My Game"
```

Disable the debug overlay feature when you do not want debug UI in a build:

```sh
zig build -Ddebug-overlay=false
```

The default runtime asset directory is `assets`. If you pass
`-Dasset-root=content`, generated shaders and copied runtime assets are installed
under `zig-out/bin/content`, and the executable looks there at runtime.
Startup sprite IDs, font paths, and audio IDs all resolve through this runtime
root.

Use non-default shader compiler paths:

```sh
zig build shaders -Dshader-compiler=/path/to/glslc
zig build shaders -Dshader-cross-compiler=/path/to/spirv-cross
zig build shaders -Ddxil-compiler=/path/to/dxc
```

On Windows, the shader pipeline is GLSL to SPIR-V with `glslc`, SPIR-V to HLSL
with `spirv-cross --hlsl --shader-model 60`, and HLSL to DXIL with `dxc` using
`vs_6_0` or `ps_6_0` targets. Installed Windows shader files end in `.dxil`.

`build.zig` uses Zig's default backend and linker selection for every target.
On x86_64 Linux, Debug builds use Zig's self-hosted backend and linker, which
compile much faster; release builds use LLVM and LLD. Two explicit overrides: the
app executable in `ReleaseFast` with LTO sets LLVM and LLD (LTO requires them),
and `-Dsanitize-thread` sets LLVM on the test and bench artifacts
([Thread Sanitizer](#thread-sanitizer)).

## Windows SDL Packages

The pinned Windows SDL packages are declared in `build.zig.zon` and fetched by
Zig's package manager:

- SDL 3.4.10, `SDL3-devel-3.4.10-VC.zip`
- SDL_ttf 3.2.2, `SDL3_ttf-devel-3.2.2-VC.zip`
- SDL_mixer 3.2.4, `SDL3_mixer-devel-3.2.4-VC.zip`

Default Windows builds use Zig's native target and do not require an external
MinGW or Visual Studio toolchain. The `-VC.zip` suffix is SDL's published
archive naming, not a compiler requirement for this project.

Use this once on a Windows machine, or any time you want to validate the cache:

```sh
zig build fetch-sdl
```

The default `--fetch=needed` behavior fetches only missing lazy packages into the
project-local `zig-pkg/` directory (Zig 0.17's package location, gitignored),
then re-runs the build with package paths available. After that, normal builds
are offline and deterministic unless `zig-pkg/` is removed. Pass
`-Dsystem-sdl=true` to use globally installed SDL libraries instead, or
`-Dsdl-root=<path>` for custom extracted SDL archives.

Each required SDL header, import library, and DLL is validated by its own
`CheckFile` step named `check Windows <file> (<fix-it hint>)`; compile steps, the
shared SDL translate-c step, the DLL installs, and `fetch-sdl` all depend on
them, so a missing or wrong `-Dsdl-root` fails on that step line instead of on a
later translate-c or link error. SDL headers are translated once per build from
`src/platform/sdl_c.h` (Zig 0.17 removed `@cImport`) and imported as the
`sdl_c` module.

On a Windows host, the `run`, `test`, `bench`, and `gpu-smoke` steps prepend the
absolute SDL DLL directories to the launched process's `PATH` (Zig 0.17 removed
`Run.addPathDir`). That value is computed from the configure-time environment,
which Zig 0.17's configure cache does not key on, so `build.zig` poisons the
configure cache on Windows hosts and the configure phase re-runs on every
`zig build` there. A `-Dsanitize-thread` build ([Thread Sanitizer](#thread-sanitizer)) and a
`-Dcallgrind` build ([Profiling](#profiling)) poison it on every host; other builds on non-Windows hosts,
including Windows cross-builds, are unaffected.

## Diagnostics And Log Levels

SDL_GPU debug validation is enabled by default in Debug builds. Override it with:

```sh
zig build -Dgpu-debug=false
zig build -Dgpu-debug=true
```

Runtime diagnostics use Zig `std.log` filtering. The default `auto` level is:

- **Debug** and **ReleaseSafe** → `debug` (full diagnostics + 60s runtime perf
  dumps from `runtime_perf_log`)
- **ReleaseFast** / **ReleaseSmall** → `warn` (ship/package; runtime perf is
  fully compiled out)

**Fix cycles:** Debug — `zig build dev` / `zig build run`. Fast compile, full
safety, behavior and unit work. Not the authority for scale timing.

**Soaks and stage ranking:** ReleaseSafe — `zig build run -Doptimize=ReleaseSafe`,
one 60s dump after load when you want a stage ranking (diagnostic trend data,
not a perf claim; `.claude/rules/tests-benchmarks.md`). Longer compile; usage
limits are in `.claude/rules/build-validation.md`.

**Ship:** ReleaseFast packages (runtime perf fully compiled out).

The dump's batch stages (`runtime_perf_log.BatchStage`) are the per-step load
stages plus each change path's cost driver (`.claude/rules/threading.md`); every
other stage is bench-only (`--details`):

- per-step load: `spatial_index_build`, `perception`, `ai_separation`,
  `ai_intent`, `steering`, `path_solve`, `path_intake` (the request load),
  `path_registry_flush` (the pathfinding update's registry flush, shrinks
  included), `movement`, `chunk_derive`, `collision_broadphase`,
  `collision_narrowphase`, `particles`, `sprite_prep`;
- dig/build and dense terrain change: `nav_remask` (the reaction's chunk remask,
  level-build remasks included), `nav_connect` (the connectivity flood, its rounds
  summed), `nav_closure` (the one-way closure rows), `nav_evict` (the path-cache
  eviction halo walk), `static_collider_splice` (the commit seam's collider
  chunk-list splice);
- capacity resize: `path_resize_copy` (the pathfinding update's shrink copy).

Movement-intent apply, plane-entry gather, and collision-response gather/apply
are bench-only. Pathfinding metrics include `path_solved_requests` (searches that
ended in a result; an `.unavailable` answered at solve is not one),
`path_solve_admissions`, `path_admission_deferred_requests`, `path_partial_results`,
`path_goal_projected` (accepted requests whose goal cell was blocked),
`path_group_field_evictions`, and `path_max_distinct_group_keys`. Pipeline timings include `path_goals` (`pipeline_path_goals`, the
goal resolve), and the `steering_setup` line reports select, snapshot, directions,
and the agent grid (`steering_grid`) separately. The `pathfinding` line's
`resize_avg_ms`/`resize_max_ms` time the update's own elastic resize (a shrink, or a
grow after a failed population seam), recorded only on steps that resized; pipeline
init and the population seam do the grows, and a seam grow shows in
`gameplay_structural`.

Debug logs can include detailed startup and fallback context, but warning and
error logs should stay rare and actionable. Override the level when you need a
different signal:

```sh
zig build -Dlog-level=warn
zig build -Dlog-level=debug
zig build run -Doptimize=ReleaseSafe              # intentional soak
zig build run -Doptimize=ReleaseSafe -Dlog-level=err  # quiet Safe; no perf dumps
```

## Atlas Packing

Loose source sprites under `source_assets/` pack into runtime atlases under
`assets/sprites/`. `source_assets/` is optional and only needs to exist once you
add raw art to pack; until then the runtime ships the registered sidecars in
`assets/sprites/` and atlas lint runs in sidecar-only mode. See
`docs/atlas-asset-workflow.md` for the full filename-driven workflow, order
manifests, and art-swap steps.

Atlas packing, source-art export, and placeholder generation require Python 3
and Pillow (`pip install pillow`). Runtime atlas lint reads registered PNG/JSON
sidecars directly; it only needs Pillow when `source_assets/` is present and the
source-to-runtime comparison invokes the packer.

Common commands:

```sh
cd tools
python3 export_source_sprites.py
python3 pack_atlas.py --kind all
python3 pack_atlas.py --kind world --lint
python3 gen_atlas_orders.py
```

After packing, run `zig build test` or `zig build verify` to validate metadata
loaders against the refreshed JSON sidecars. `verify` always validates the
registered runtime atlas PNG/JSON sidecars. When `source_assets/` is present,
lint also compares the source-driven generated manifests against the runtime
sidecars so additions and art swaps are caught before commit.

## AI Archetypes

Demo AI personalities are data, not code. `assets/ai/archetypes.json` holds one
self-declaring entry per `AiArchetypeId` (`src/game/ai_archetypes.zig`); the
loader parses it at load time (strict — an unknown or misspelled key fails the
load) into a fixed enum → prevalidated component-bundle table, and
`GameDemoState` spawns from that table. Editing the JSON changes behavior with
no recompile.

Each entry sets a `faction` and optional `agent` / `perception` / `memory` /
`affect` blocks. Within a block, only non-default fields need to be written —
omitted numeric fields fall back to the component's own struct defaults, so an
entry stays terse. Out-of-range values are rejected at load by the same
`validateAi*` checks the runtime uses.

To tune a personality's **feelings**, edit its `affect` block: the four drive
baselines (`baseline_fear` / `baseline_curiosity` / `baseline_aggression` /
`baseline_fatigue`, each `0..1`) set resting emotion, and optional `decay_rate_*`
/ `threshold_*` control how fast a drive relaxes and when it crosses into
above-threshold behavior. Higher `baseline_fear` biases toward flee, higher
`baseline_curiosity` toward investigate, and so on — arbitration maps drives to
behavior through the weight table in `src/game/systems/arbitration.zig`. Under
`agent`, non-zero `commitment_max_steps` / `sticky_bonus` keep a chosen behavior
from flapping every fixed step (shipped timid / aggressive / curious set these).
Give an archetype a `perception` block with a longer `vision_range` (keen-eyed
sentry) or a near-zero `vision_range` with a large `hearing_range` (blind
tracker) to differentiate senses. After editing, run `zig build test` to
re-validate the catalog.

Press **F2** (or gamepad **BACK**) at runtime to toggle the debug overlay: it
draws each nearby agent's vision cone, emotion drive bars, memory markers, and
active behavior label, plus scope/tier counts — read-only, so it never changes
simulation.

In gameplay, **R** or gamepad **left shoulder** is interact (rising-edge action
intent); dig and move keep their existing keyboard / stick bindings — see
[state stack and input](state-stack-and-input.md).

## Testing

Unit tests live beside the code they cover as `test` blocks. Run them with
`zig build test`. `-Dtest-filter=<text>` (repeatable) compiles and runs only
tests whose names contain the text; names carry their module path, so
`-Dtest-filter=systems.pathfinding` selects the pathfinding modules. A filter
that matches nothing compiles an empty stub and does not type-check the suite.
`zig build test-compile` type-checks the test root and does not run it; pass
no filter when the whole root must compile. Test rules:
`.claude/rules/tests-benchmarks.md`.

## Validation Cadence

The cadence (which step when) is `.claude/rules/build-validation.md`.
`zig build verify` runs compile coverage, unit tests, shader compilation, atlas
lint, idiom lint, and a `zig fmt --check` over `build.zig`, `build.zig.zon`, and
`src/` (files edited outside the format hook fail here; `zig build fmt` fixes
them).

## Thread Sanitizer

```sh
zig build test -Dsanitize-thread=true
zig build test -Dsanitize-thread=true -Dtest-filter=thread_system
zig build bench -Dsanitize-thread=true -- --group thread-dispatch
```

`-Dsanitize-thread=true` builds the unit-test and bench artifacts with
ThreadSanitizer and forces the LLVM backend on them (the self-hosted backend
does not instrument). The app and `gpu-smoke` are never instrumented, and SDL
and GPU driver threads stay uninstrumented. The option is enabled for x86_64
and aarch64 on Linux (glibc), macOS, and FreeBSD; on any other target every
step that builds a sanitized artifact (`check`, `test`, `bench`, `verify`)
fails with one message. Only x86_64-linux-gnu has run; cross-compiling the
macOS runtime from Linux needs the macOS SDK.

The test and bench run steps set `TSAN_OPTIONS` to `halt_on_error=1
second_deadlock_stack=1` followed by any value you set, so your flags win one
by one; the first report halts the run (exit 66) and fails the step. The value
is always set, so a changed `TSAN_OPTIONS` reruns a cached passing run.
A sanitizing build reconfigures on every invocation (configure cache:
[Windows SDL Packages](#windows-sdl-packages)). No suppressions ship
(`.claude/rules/threading.md`).

The full suite takes about 3 minutes under TSan (x86_64 Linux, Debug), and
the option is not part of `verify`. When it runs:
`.claude/rules/build-validation.md`.

## Profiling

```sh
zig build bench -Dcallgrind=true -- --group ai --items 256 --warmup 1 --iterations 1 --case serial-direct
callgrind_annotate --inclusive=yes benchmark_outputs/callgrind/callgrind.out | less
```

`-Dcallgrind=true` runs the bench under `valgrind --tool=callgrind` with the
same `--` arguments, writing the profile to
`benchmark_outputs/callgrind/callgrind.out` (`-Dcallgrind-out=<path>`
overrides) and valgrind's messages to that path plus `.log`. Valgrind cannot
decode AVX-512, so the `bench` step fails on a target CPU that has it, as it
does on a non-native-Linux build (a non-Linux host or target, or a foreign-arch
target), without valgrind on `PATH`, or with `-Dsanitize-thread`.

Read the stage's own inclusive line in `callgrind_annotate --inclusive=yes`,
not the program total, which includes process startup. It answers which
functions execute the instructions and how often each is called; it does not
answer wall time or threading (valgrind runs one thread at a time, so profile
serial cases), SIMD or inlining choices (`.claude/rules/memory-performance.md`
§ SIMD and core math), or cache stalls. Callgrind runs about 25× slower than the plain
binary, so use low entity counts only: about 256 to 1,024 items, one warmup,
one iteration.

Source line numbers in the profile are unreliable on Zig 0.17 Debug info
(valgrind misreads its line tables, offset per function), so split a function's
self cost by instruction address, with its call sites as landmarks. That needs
valgrind's `--dump-instr=yes`, which `-Dcallgrind` does not pass: run valgrind on
the bench binary directly for it.

## Benchmarks

`zig build bench` pins its default log level to `warn` in every optimize mode
(per-case debug chatter adds overhead across many cases); pass
`-Dlog-level=debug` when troubleshooting.

It runs non-interactive CPU benchmarks for movement bodies and movement intents,
particles, AI, memory, affect, perception, the spatial index, scoped simulation,
steering, collision and collision response, plane traversal, nav updates,
chunk-owned terrain and its nav reaction, pathfinding (request load and nav
scaling), render prep, the world gate, world creation, and the production fixed
step. The default case set has a serial baseline, fixed-worker, fixed
small/large-range, and adaptive cases. A group lists the cases its workload runs
(`BenchmarkGroup.cases`, default every case): `suite.casesNamed` builds a subset in
default-case order (`suite.serial_cases`, `suite.serial_and_tuned_cases`), and a
case the workload has no path for is left out, never skipped.
`thread-adaptive-fixed-range` isolates adaptive worker-count selection with a
fixed range size; `thread-adaptive-tuned-range` uses the production
processor-owned worker and range tuner. Fixed cases are controls for scheduler
overhead, worker scaling, and range size. Fixed range controls scale from the
group's partition (the default range size, or one chunk for chunk-partitioned
stages): default is the partition, small is half of it (at least 1), large is
4×, each aligned to the stage's range alignment, and
`thread-adaptive-fixed-range` uses the partition too. In a group that declares
its `fixed_range_shape` (default case list only), a fixed case that resolves to
an earlier case's configuration reports `same shape as <case>`, untimed and out
of the best-control pick. Groups that time an edit and its revert (terrain edits, nav
batch, nav dig and update toggles, connectivity toggles) run each half on its
own tuner set, so each tuner takes one sample per step as production does
(`.claude/rules/threading.md`); reported shapes and settle checks follow each
set's own half. A group runs its own `item_counts` list; the processor and
render-prep groups share `suite.event_scale_counts` (1,024, 4,096, and 10,000).
`--items N` runs one config of any group.

Each group's doc comment, beside its `BenchmarkGroup` in `src/benchmarks/`, is
the full statement of its fixture, what one sample times, its item code, its pass
shape, and its `--details` fields (`.claude/rules/tests-benchmarks.md`); the
index below names each group and its file. An item code packs a config's fields in
decimal, most significant first, and the report header prints the group's layout
(`suite.ItemCode`).

Fields shared by every group:

- `main=` is the sample's main-thread time and share: its wall time minus the
  off-main time of the stages that ran on workers.
- Threaded stages under `--details`: each stage's busiest shape, and the
  main-thread time and share (the iteration minus its off-main stage time). The
  tuner cell adds ` probes=N demotes=M` in Debug and ReleaseSafe.

Reading results:

- Output is grouped by workload and count: an aligned table (timing, speedup,
  throughput, worker use, status) and a validation summary of what the run
  proved (winning path, whether adaptive stayed inline, tuner phase and
  profile, measured or skipped flows). It is not an entity-count or batching
  recommendation.
- Adaptive rows are the production scheduling signal: they start inline and use
  workers only when the tuner finds a batch large enough and a threaded profile
  that wins. Fixed-thread rows are forced controls, not evidence that runtime
  will use workers for cheap prep.
- `serial-direct` against the tuned case: serial runs every pass on the calling
  thread, so it cannot show a landing's parallel gain (work moved off main to
  workers) yet pays every pass the landing adds. Debug also lowers `simd.zig`
  lane compares lane by lane: before Slice 84's lane landing, callgrind measured
  a 4-lane normalize at 790 Ir against 90 for one scalar normalize. A serial gap
  after an off-main or SIMD landing is therefore expected; whether it is a
  verdict or a control's gap depends on which path the tuned case reports as
  production at that size (`.claude/rules/tests-benchmarks.md` § Benchmarks).
- `worker_threads` is `active/available` background workers, excluding the main
  thread (which also processes ranges). `0/10` means adaptive stayed inline; it
  can still trail `serial-direct` in tiny ReleaseFast movement workloads because
  `serial-direct` has no ThreadSystem submission overhead.
- A row whose sample spans many stages carries no batch (`production-step`,
  `world-create`): its worker, range, and wait cells print `-`, and the summary
  names no worker use.
- Adaptive cases run `--warmup` iterations, then a bounded settle phase before
  timing, so the mean excludes tuner search. A tuner that fails to settle shows
  its probing phase and candidate: an adaptive coverage failure, not a clean
  timing. Inline batches do not reset tuner state for later processors.
- Multi-stage systems are read per stage: a primary batch may thread while a
  secondary stays `inline`. Pathfinding's request preparation can use SIMD lane
  batches while the A* solve stage owns its own tuner and row.
- `--details` adds scheduler ranges, wait time, items-per-range, tuning phase,
  and workload counters. `--items N` overrides the item counts for the
  selected group; `--group-prefix P` runs every group whose name starts with
  `P` (a family such as `chunk-scale-`); `--fallback-budget N` compares
  hard-fallback caps against the runtime default in ReleaseFast tuning.

Group index (files under `src/benchmarks/`):

- `thread_dispatch.zig`: `thread-dispatch`, one stage dispatch over a trivial job.
- `movement.zig`: `movement`, `movement-apply-intents`, `-sorted`; movement
  bodies and applying AI intents.
- `collision.zig`: `collision`, `collision-sparse`, `collision-tall`,
  `collision-stacked`, `collision-thin`, `collision-static-heavy-sap`,
  `collision-static-heavy`, `collision-static-index-change`; the broadphase and
  its worst-case shapes.
- `collision_response.zig`: `collision-response-stage`; the response step.
- `plane_traversal.zig`: `plane-traversal`, `-falls`, `-dense-falls`,
  `-dense-falls-banded`.
- `steering.zig`: `steering`, `-shuffled`, `-corridor`, `-cluster-outlier`,
  `steering-static-change`, `steering-static-dense`.
- `spatial_index.zig`: `spatial_index`, `-shape`, `-query`; the shared neighbor
  index.
- `scope.zig`: `scope-cognition`; the think set.
- `ai.zig`: `ai`, `ai-cell-ordered`. `ai_memory.zig`: `ai-memory`, `-shuffled`,
  `-sparse`. `affect.zig`: `ai-affect`, `ai-affect-shuffled`.
  `perception.zig`: `perception`, `-los-dense`, `-scattered-dense-index`,
  `-cell-ordered`, `perception-crowd`.
- `production_step.zig`: `production-step`, the production fixed step.
  `world_create.zig`: `world-create`. `world_gate.zig`: `world-gate`.
- `render_prep.zig`: `render-prep`. `render_game_prep.zig`: `render-game-prep`,
  `-dense-deep`, `-offview`. `sparse_window.zig`:
  `render-sparse-window-frame`, `-pan`, `-add`. `particles.zig`: `particles`.
- `chunk_scale.zig`: `chunk-scale-dig`, `-ramp`, `-cave-in`, `-explosion-fill`,
  `chunk-scale-gpu-sync-dig`, `-level-enter`, `-pan`, and the
  `chunk-scale-nav-*` groups (`-dig`, `-ramp`, `-cave-in`, `-explosion-fill`,
  `-enclose`, `-level-add`); terrain change and its nav reaction against level
  side and depth.
- `nav_update.zig`: `nav-update-scattered`, `-entity-obstacles`,
  `-static-population`, `-static-dense`, `-static-dense-tail`.
- `pathfinding/requests.zig`: the request-load groups (`pathfinding`,
  `-shared-goal`, `-drain`, `-cache-open`, `-cache-detour`, `-hard-fallback`,
  `-hard-fallback-budget`, `-escalated-detour`, `-query`, and the
  `-group-field-*` groups).
- `pathfinding/routes.zig`: `pathfinding-level-size`, `-cross-level-depth`,
  `-cross-level-shaft`, `-cross-level-teleport`, `-long-path`, `-link-fold`.
- `pathfinding/cache.zig`: `pathfinding-evict`, `-elastic-ramp`,
  `-elastic-shrink`. `pathfinding/connectivity.zig`:
  `pathfinding-connectivity-split`, `-oneway`. `pathfinding/negative.zig`:
  `pathfinding-negative-steady`, `-dig`, `-burst`.
- `nav_size.zig`: not a group; the nav scaling groups' memory estimate and byte
  checks. A config whose nav storage exceeds the bench nav-size limit fails with
  its figure, never skips.

Shared harness pieces live once, each in its owning file; a group declares its
label and formatter in its definition (`.claude/rules/tests-benchmarks.md`).
`suite.zig` owns options, cases, item codes, labels, stage shapes, and
reporting, including `suite.Warmup` (a case's warmup and adaptive settle loop)
and `suite.DetailLines` (a case's extra report lines, printed under its row by
`--details`); `fixtures.zig` owns worlds, bodies, thread systems, and tuners,
including `fixtures.CommitSeam` (the structural-commit seam a bench drives, since
it holds no `SimulationPipeline`);
`nav_size.zig` owns the nav memory estimate. `src/tests.zig` imports only
`suite.zig` and `nav_size.zig`, so only their tests of their own pure utilities
run under `zig build test`; no group file is called from a test, and fixture
correctness rests on the asserts that fire in a real bench run.

Optional arguments narrow or scale the run. Day-to-day runs target a group
(`.claude/rules/tests-benchmarks.md`); the full-suite forms (bare `zig build bench`,
bare `--details`) are for requested sweeps:

```sh
zig build bench -- --iterations 100
zig build bench -- --case thread-adaptive-tuned-range
zig build bench -- --group movement --items 65536 --details
zig build bench -- --group ai --details
zig build bench -- --group steering --details
zig build bench -- --group render-prep --details
zig build bench -- --group render-game-prep --details
zig build bench -- --group pathfinding-hard-fallback --details
zig build bench -- --group pathfinding-hard-fallback-budget --items 256 --details
zig build bench -- --group nav-update-scattered --details
zig build bench -- --group nav-update-entity-obstacles --details
zig build bench -- --group scope-cognition --details
zig build bench -- --group production-step --case thread-adaptive-tuned-range --details
zig build bench -- --group-prefix chunk-scale- --case serial-direct
zig build bench -- --group-prefix render-sparse-window- --case serial-direct
zig build bench -- --group pathfinding-hard-fallback-budget --items 2000 --fallback-budget 128 --case thread-adaptive-tuned-range --details
zig build bench -- --details
```

Before/after comparisons use `tools/bench_ab.py` (targeted groups, a base ref
against the working tree, Debug): [tools/README.md](../tools/README.md).
Requested full sweeps run `zig build bench` directly.

## GPU Smoke

`zig build gpu-smoke` opens a small window long enough to install runtime
assets/shaders, initialize the renderer path, load platform shader files, draw a
primitive through the sprite pipeline, acquire a swapchain texture, and submit
one frame. SDL still needs a usable video backend and display environment, so
headless shells or CI runners may need display setup before this check can run.
