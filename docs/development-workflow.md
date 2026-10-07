# Development Workflow

## Common Commands

```sh
zig build           # build and install the app, runtime assets, and shaders
zig build run       # build, install assets/shaders, and run the app
zig build dev       # build shaders, install assets, and run the app
zig build check     # compile the game, GPU smoke, and benchmark executables
zig build test      # run Zig unit tests
zig build bench     # run CPU gameplay and render-prep benchmarks
zig build verify    # run check, test, shader compilation, atlas + idiom lint
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

`zig build idiom-lint` (`tools/lint_idioms.py`, also part of `verify`) enforces
the naming/currency/`catch unreachable` rules from `docs/coding-standards.md`:
snake_case fields/params, `k_snake_case` constants, current stdlib spellings, and
`catch`/`orelse unreachable` only on a sanctioned handle constructor, inside a
`test` block, or with a `// lint:allow catch-unreachable: <reason>` annotation.

`zig build package` installs the selected-mode game binary and runtime assets.
It does not install the `gpu-smoke` development executable.

On Windows, `package`, `run`, `dev`, and normal build steps install the required
`SDL3.dll`, `SDL3_ttf.dll`, and `SDL3_mixer.dll` beside the app binary when
using the pinned package SDL path. Optional SDL_mixer codec DLLs are not copied
by this slice because current runtime audio assets are WAV-based.

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
the binary. The asset root must stay a **relative**, traversal-safe path
(default `assets`); `AppConfig` rejects absolute roots at startup.

## Release Modes

The default optimize mode is `Debug`. Use an explicit release mode only for a
release candidate or shipping build:

```sh
zig build --release=safe
zig build --release=fast
zig build --release=small
zig build -Doptimize=ReleaseFast
```

Release builds use the same pinned packages in `zig-pkg/` as Debug builds. They do
not download SDL again unless a required package is missing and Zig fetching is
enabled by the current `--fetch` mode.

**Packaged builds ship `ReleaseFast`.** It strips the assert behind every
`assumeCapacity`/`addOneAssumeCapacity` and disables bounds/overflow checks, so
hot-path reserves need the `FailingAllocator` proofs in
`docs/coding-standards.md` § Allocator Discipline.

LTO: on Linux (ELF), `build.zig` enables `-flto=full` for the shipped **app
executable only** in `ReleaseFast`, explicitly selecting LLVM + LLD (which LTO
requires). `gpu-smoke`, benchmarks, and tests get no LTO and use Zig's default
backend and linker. macOS skips LTO (LLD cannot link Mach-O in Zig 0.17);
Windows skips it (under Zig 0.17, LTO with libc fails at `lld-link` on mingw
libc/libm symbols, while non-LTO ReleaseFast links and emits its PDB). Debug,
ReleaseSafe, and ReleaseSmall leave LTO off.

**Release gate:** before cutting a ReleaseFast release candidate, run a
multi-hour `--release=safe` soak (not just `zig build test`) across realistic
to extreme entity counts and spawn/despawn churn. A clean ReleaseSafe run is the
gate, because ReleaseFast corrupts memory silently instead of reporting a
capacity or bounds violation.

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
compile much faster; release builds use LLVM and LLD. The one explicit override is the app
executable in `ReleaseFast` with LTO, which always sets LLVM and LLD because
LTO requires them.

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
`zig build` there. Non-Windows hosts, including Windows cross-builds, are
unaffected.

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

**Soaking / scale perf:** ReleaseSafe — `zig build run -Doptimize=ReleaseSafe`,
one 60s dump after load when you deliberately want ranking and absolute numbers.
Longer compile; do not use for every edit. Multi-cycle soaks only when comparing
settle vs load, not as the default.

**Ship:** ReleaseFast packages (runtime perf fully compiled out).

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

Tests follow Zig conventions: small unit tests live beside the code they cover
as `test` blocks. Run them with `zig build test`. Test standards live in
`docs/coding-standards.md` § Tests.

## Validation Cadence

- While iterating, prefer `zig build check` for fast compile feedback.
- Per commit: `zig build check` + `zig build test` + `zig build idiom-lint`.
- Once per multi-commit batch, and before a slice or broad change is
  considered complete: `zig build verify` (compile coverage, unit tests,
  shader compilation, atlas lint, idiom lint).
- `zig build shaders` after shader source or shader build-wiring changes.
- `zig build gpu-smoke` only when display/GPU validation is relevant and a
  display exists; report it as not run otherwise.
- Cost savings never drop proof: keep every proof test, every
  `FailingAllocator` proof, and the fails-with-the-fix-reverted check.
- Benchmarks follow `docs/coding-standards.md` § Benchmarks.

## Benchmarks

`zig build bench` pins its default log level to `warn` in every optimize mode
(per-case debug chatter adds overhead across many cases); pass
`-Dlog-level=debug` when troubleshooting.

It runs non-interactive CPU benchmarks for movement bodies, particles, AI and
steering agents, dense and sparse collision bodies, collision-response
contacts, scoped simulation gathers, incremental nav rebuilds, renderer sprite
CPU prep, and pathfinding (open-list, common-goal, cached-result,
hard-fallback, production-scale nav). Each case set has a serial baseline,
fixed-worker, fixed small/large-range, and adaptive cases.
`thread-adaptive-fixed-range` isolates adaptive worker-count selection with a
fixed range size; `thread-adaptive-tuned-range` uses the production
processor-owned worker and range tuner. Fixed cases are controls for scheduler
overhead, worker scaling, and range size. Processor and render-prep benchmarks
share a count ladder: quick runs 1,024, 4,096, and 10,000 items; standard adds
25,000 and 50,000; stress keeps 10,000, 25,000, and 50,000.

What rows report:

- AI: bounded separation checks (transient spatial grid, bounded neighbor and
  candidate samples), emitted navigation intents, and intent-stage worker/range
  tuning.
- Collision: candidate-pair and contact counts, and narrowphase as
  `narrow=inline` or `narrow=worker_threads/items_per_range` (broadphase and
  narrowphase tune independently).
- Steering: avoidance candidate checks, accepted samples, emitted movement
  intents (a threaded stage with serial fallback and range-owned output).
- Render-prep (CPU only, no window or GPU submission): draw commands, valid
  sprites, skipped invalid resources, vertices, draw groups, worker usage, range
  size, tuner state. Each iteration submits an ordered sprite stream into one
  `SpriteBatch`, then snapshots, emits vertices, and builds draw groups.
  `render-game-prep` adds production-shaped work: dynamic record collection,
  depth-bucket emit, sparse visible-tile submission through `WorldSystem`,
  realistic `mergeDrawList` group counts, and phase timings (entity_collect,
  merge, snapshot, vertex_emit). The benchmark owns those phase timers; the
  production renderer does not run them.
- Pathfinding hard-fallback: true fallback requests, requests deferred by the
  per-step budget, pending work, results, and cache evictions.
  `pathfinding-hard-fallback` measures raw A* throughput;
  `pathfinding-hard-fallback-budget` caps solves at the runtime frame budget, so
  solved count and `deferred` backlog are expected signals.

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
- `worker_threads` is `active/available` background workers, excluding the main
  thread (which also processes ranges). `0/10` means adaptive stayed inline; it
  can still trail `serial-direct` in tiny ReleaseFast movement workloads because
  `serial-direct` has no ThreadSystem submission overhead.
- Adaptive cases run `--warmup` iterations, then a bounded settle phase before
  timing, so the mean excludes tuner search. A tuner that fails to settle shows
  its probing phase and candidate: an adaptive coverage failure, not a clean
  timing. Inline batches do not reset tuner state for later processors.
- Multi-stage systems are read per stage: a primary batch may thread while a
  secondary stays `inline`. Pathfinding's request preparation can use SIMD lane
  batches while the A* solve stage owns its own tuner and row.
- `--details` adds scheduler ranges, wait time, items-per-range, tuning phase,
  and workload counters. `--items N` overrides the profile counts for the
  selected group; `--fallback-budget N` compares hard-fallback caps against the
  runtime default in ReleaseFast tuning.

Use other optional arguments only to narrow or scale the run:

```sh
zig build bench -- --profile quick
zig build bench -- --profile standard --iterations 100
zig build bench -- --case thread-adaptive-tuned-range
zig build bench -- --group movement --items 65536 --details
zig build bench -- --group ai --details
zig build bench -- --group steering --details
zig build bench -- --group render-prep --details
zig build bench -- --group render-game-prep --details
zig build bench -- --group pathfinding-hard-fallback --details
zig build bench -- --group pathfinding-hard-fallback-budget --items 256 --details
zig build bench -- --group nav-update-scattered --details
zig build bench -- --group nav-update-multichunk --details
zig build bench -- --group scope --details
zig build -Doptimize=ReleaseFast bench -- --group pathfinding-hard-fallback-budget --items 2000 --fallback-budget 128 --case thread-adaptive-tuned-range --details
zig build bench -- --details
```

For scripted benchmark capture with timestamped output under `benchmark_outputs/`,
use `tools/bench_run.py` (see [tools/README.md](../tools/README.md)).

## GPU Smoke

`zig build gpu-smoke` opens a small window long enough to install runtime
assets/shaders, initialize the renderer path, load platform shader files, draw a
primitive through the sprite pipeline, acquire a swapchain texture, and submit
one frame. SDL still needs a usable video backend and display environment, so
headless shells or CI runners may need display setup before this check can run.
