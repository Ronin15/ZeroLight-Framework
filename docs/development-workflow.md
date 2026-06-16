# Development Workflow

## Common Commands

```sh
zig build           # build and install the app, runtime assets, and shaders
zig build run       # build, install assets/shaders, and run the app
zig build dev       # build shaders, install assets, and run the app
zig build check     # compile the game, GPU smoke, and benchmark executables
zig build test      # run Zig unit tests
zig build bench     # run CPU gameplay processor benchmarks
zig build verify    # run check, test, and shader compilation
zig build package   # install selected-mode binaries and runtime assets
```

Useful supporting commands:

```sh
zig build fmt       # format build.zig, build.zig.zon, and src/
zig build shaders   # compile GLSL shader sources to platform GPU shaders
zig build gpu-smoke # run a display-gated renderer pipeline smoke
```

`zig build package` installs the selected-mode game binary and runtime assets.
It does not install the `gpu-smoke` development executable.

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
```

SDL_GPU debug validation is enabled by default in Debug builds. Override it with:

```sh
zig build -Dgpu-debug=false
zig build -Dgpu-debug=true
```

Runtime diagnostics use Zig `std.log` filtering. The default `auto` level keeps
Debug builds at `debug` and release builds at `warn`, which still includes
errors. Debug logs can include detailed startup and fallback context, but
warning and error logs should stay rare and actionable. Override the level when
you need a different signal:

```sh
zig build -Dlog-level=warn
zig build -Dlog-level=debug
zig build --release=safe -Dlog-level=err
```

## Testing

Tests follow Zig conventions: small unit tests live beside the code they cover
as `test` blocks. Run them with:

```sh
zig build test
```

For a broader local check before sharing changes:

```sh
zig build verify
```

`verify` runs compile coverage, unit tests, and shader compilation.

## Benchmarks

`zig build bench` runs non-interactive CPU benchmarks for movement bodies,
transient particle rows, AI agents, dense collision bodies, sparse collision
bodies, and collision-response contacts. The default run exercises one serial baseline,
fixed-worker, fixed small-range, fixed large-range, and adaptive cases so the
full processor flow can be checked for regressions.
`thread-adaptive-fixed-range` isolates adaptive worker-count selection with a
fixed range size, while `thread-adaptive-tuned-range` uses the same
processor-owned adaptive worker and range tuner path as production systems. The
fixed cases are controls for scheduler overhead, worker-count scaling, and
range-size effects. Gameplay processor benchmarks use a shared event-scale
count ladder so each system shows a performance curve across small, medium, and
high counts: quick runs 1,024, 4,096, and 10,000 items; standard adds 25,000 and
50,000; stress keeps the high-count 10,000, 25,000, and 50,000 signal points.
AI separation uses a transient spatial grid with bounded neighbor and candidate
samples, then intent emission runs as its own stage.
Collision output includes candidate-pair and contact counts so dense stress
cases can be compared against sparse gameplay-shaped distributions. Detail rows
also report narrowphase as `narrow=inline` or `narrow=worker_threads/items_per_range`
because collision has independently tuned broadphase and narrowphase stages. AI
detail rows similarly report intent-stage worker/range tuning, while AI output
reports bounded separation checks and emitted movement-intent counts.

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
another system's profile.
Use other optional arguments only to narrow or scale the run:

```sh
zig build bench -- --profile quick
zig build bench -- --profile standard --iterations 100
zig build bench -- --case thread-adaptive-tuned-range
zig build bench -- --group movement --items 65536 --details
zig build bench -- --group ai --details
zig build bench -- --details
```

## GPU Smoke

`zig build gpu-smoke` opens a small window long enough to install runtime
assets/shaders, initialize the renderer path, load platform shader files, draw a
primitive through the sprite pipeline, acquire a swapchain texture, and submit
one frame. SDL still needs a usable video backend and display environment, so
headless shells or CI runners may need display setup before this check can run.
