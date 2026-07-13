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
the binary, or invoke with `-Dasset-root=<absolute-path>` at build time to
bake an absolute path into the binary.

## Release Modes

The default optimize mode is `Debug`, matching standard Zig build behavior. Use
an explicit release mode only when preparing a release candidate or shipping
build:

```sh
zig build --release=safe
zig build --release=fast
zig build --release=small
zig build -Doptimize=ReleaseFast
```

Release builds use the same pinned Zig package cache as Debug builds. They do
not download SDL again unless a required package is missing and Zig fetching is
enabled by the current `--fetch` mode.

**Packaged builds ship `ReleaseFast`.** That mode strips the debug assert
backing every `assumeCapacity`/`addOneAssumeCapacity` call and disables
bounds/overflow safety checks — see `docs/coding-standards.md`'s allocator
discipline rules for the `FailingAllocator` proof-test coverage this requires
before hot-path code can rely on it safely. Before cutting a ReleaseFast
release candidate, run an extended soak session in `--release=safe` (not just
`zig build test`) across realistic-to-extreme entity counts and spawn/despawn
churn. A clean multi-hour ReleaseSafe run is the actual release gate:
ReleaseFast itself will not report a capacity or bounds violation if one
exists, it will just corrupt memory silently.

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

On native **Linux GNU** targets, `build.zig` forces LLVM and LLD for the game,
benchmark, test, and GPU-smoke executables. This is a temporary Debug-build
workaround; other targets use Zig's default backend selection.

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

The default `--fetch=needed` behavior fetches only missing lazy packages, then
re-runs the build with package paths available. After that, normal builds are
offline and deterministic unless the package cache is removed. Pass
`-Dsystem-sdl=true` to use globally installed SDL libraries instead, or
`-Dsdl-root=<path>` for custom extracted SDL archives.

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
behavior through the weight table in `src/game/systems/arbitration.zig`. Give an
archetype a `perception` block with a longer `vision_range` (keen-eyed sentry)
or a near-zero `vision_range` with a large `hearing_range` (blind tracker) to
differentiate senses. After editing, run `zig build test` to re-validate the
catalog.

Press **F2** (or gamepad **BACK**) at runtime to toggle the debug overlay: it
draws each nearby agent's vision cone, emotion drive bars, memory markers, and
active behavior label, plus scope/tier counts — read-only, so it never changes
simulation.

## Testing

Tests follow Zig conventions: small unit tests live beside the code they cover
as `test` blocks. Run them with:

```sh
zig build test
```

For a broader local check before sharing changes:

```sh
zig build shaders
zig build check
zig build test
zig build verify
```

`verify` runs compile coverage, unit tests, shader compilation, and atlas lint.

Coding style, performance standards, comment policy, test standards, and
generated-output rules live in `docs/coding-standards.md`.

## Benchmarks

`zig build bench` pins its own default log level to `warn` regardless of
optimize mode (Debug included), rather than inheriting the game's `auto`
default — per-case debug logging (e.g. `ThreadSystem` re-init chatter) adds
real overhead across many bench cases/items and isn't useful in a benchmark
table. Pass `-Dlog-level=debug` to override this explicitly for
troubleshooting.

`zig build bench` runs non-interactive CPU benchmarks for movement bodies,
transient particle rows, AI agents, steering agents, dense collision bodies,
sparse collision bodies, collision-response contacts, scoped simulation gathers,
incremental nav rebuilds, and renderer sprite CPU prep, plus pathfinding
open-list, common-goal, cached-result, hard-fallback, and production-scale nav
workloads. The default run exercises one serial baseline, fixed-worker, fixed
small-range, fixed large-range, and adaptive cases so the full processor flow can
be checked for regressions.
`thread-adaptive-fixed-range` isolates adaptive worker-count selection with a
fixed range size, while `thread-adaptive-tuned-range` uses the same
processor-owned adaptive worker and range tuner path as production systems. The
fixed cases are controls for scheduler overhead, worker-count scaling, and
range-size effects. Gameplay processor and render-prep benchmarks use a shared
event-scale count ladder so each system shows a performance curve across small,
medium, and high counts: quick runs 1,024, 4,096, and 10,000 items; standard
adds 25,000 and 50,000; stress keeps the high-count 10,000, 25,000, and 50,000
signal points.
AI separation uses a transient spatial grid with bounded neighbor and candidate
samples, then intent emission runs as its own stage.
Collision output includes candidate-pair and contact counts so dense stress
cases can be compared against sparse gameplay-shaped distributions. Detail rows
also report narrowphase as `narrow=inline` or `narrow=worker_threads/items_per_range`
because collision has independently tuned broadphase and narrowphase stages. AI
detail rows similarly report intent-stage worker/range tuning, while AI output
reports bounded separation checks and emitted navigation-intent counts.
Steering output reports bounded avoidance candidate checks, accepted avoidance
samples, and emitted movement-intent counts. Steering movement emission is a
threaded processor stage with serial fallback, per-system adaptive tuning, and
deterministic range-owned output.
Render-prep output reports draw commands, valid sprites, skipped invalid
resources, generated vertices, draw groups, worker usage, range size, and the
render-owned adaptive tuner state. It is a CPU-only render-prep benchmark and
does not open a window or submit SDL_GPU command buffers. Each measured
iteration submits an already ordered sprite stream into the same `SpriteBatch`
command storage, then snapshots, emits vertices, and builds draw groups.
`render-game-prep` extends that coverage with production-shaped game render
work: dynamic record collection and depth-bucket sparse/dynamic emit, sparse
visible-tile submission through `WorldSystem`, realistic static+dynamic
`mergeDrawList` group counts, and phase timings for entity_collect, merge,
snapshot, and vertex_emit.
Current production world rendering submits already ordered commands from
explicit z-layer passes instead of a separate general ordering queue. The
benchmark owns its phase timers around that shared path and reports ordered
submission, snapshot, vertex-emission, and draw-group timings; the production
renderer does not run those benchmark timers.
For runtime performance judgment, read the adaptive rows as the production-style
scheduling signal: they start from measured inline work and only use workers
when the adaptive tuner finds a batch large enough and a threaded profile that
wins. The fixed-thread rows are forced controls for scheduler/range behavior,
not evidence that runtime rendering will force worker participation for cheap
sprite/rect prep.

Benchmark output is grouped by workload and count. Each block prints an aligned
plain-text table with per-case timing, speedup, throughput, worker-thread use,
and status, then ends with a concise validation summary. The summary reports
what the run proved, such as which path won, whether adaptive stayed inline or
used worker threads, the adaptive tuner phase and selected profile, and whether
the expected flows were measured or skipped. It is not an entity-count or
batching recommendation.

The `worker_threads` column is `active/available` background workers. It does
not include the main thread, which can also process ranges while waiting for the
synchronous batch to complete. For example, `1/10` means one background worker
was active out of ten available workers; if the main thread also processed
ranges, the batch had two executing CPU participants. `0/10` means the adaptive
path stayed inline through the ThreadSystem. That can still be slower than
`serial-direct` in very small ReleaseFast movement workloads because
`serial-direct` is the raw single-thread control path with no ThreadSystem
submission overhead.

For regression checking, adaptive benchmark cases first run the explicit
`--warmup` iterations, then run a bounded adaptive settle phase before the
timed measurement loop. This keeps the adaptive rows focused on the selected
steady-state profile instead of averaging the tuner search cost into the mean.
If the tuner still fails to settle within that budget, the detail table reports
the probing phase and selected candidate so the run is treated as an adaptive
coverage failure, not a clean steady-state timing.
Use `--details` when you need scheduler ranges, wait time, items-per-range,
tuning phase, and workload counters. In adaptive cases, processors may stay
inline until measured completion time shows that active worker threads are worth
the synchronization cost; fixed worker/range cases are benchmark controls only,
not production scheduling policy. Inline batches are timing samples for that
batch only and do not reset adaptive work-tuner state for later processors.
For multi-stage systems, read each stage independently: an adaptive row can have
a threaded primary batch while a secondary batch still reports `inline`, or both
stages can settle on separate threaded profiles. This is expected when the
stages have different work shapes. Pathfinding follows this same rule: request
preparation/grid marking can use SIMD lane batches, while the branch-heavy A*
solve stage owns its own pathfinding tuner and benchmark row instead of sharing
another system's profile. Hard-fallback pathfinding rows expose true fallback
requests, fallback requests deferred by the per-step budget, total pending work,
results, and cache evictions so rare A* cost stays visible instead of being
hidden by cache-shaped or field-reuse workloads. Use
`pathfinding-hard-fallback` for raw true-A* throughput and
`pathfinding-hard-fallback-budget` for budget-pressure regression tracking; the
budgeted group uses the same hard fixture but caps fallback solves at the runtime
frame budget so solved fallback count and total `deferred` backlog are expected
signals under larger request counts. `--items N` overrides the registered profile counts for
the selected group, and `--fallback-budget N` lets ReleaseFast tuning compare
candidate hard-fallback caps against the runtime default.
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
