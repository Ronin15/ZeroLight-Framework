# Development Workflow

## Common Commands

```sh
zig build           # build and install a runnable app into zig-out/bin
zig build run       # build, install assets/shaders, and run the app
zig build dev       # build shaders, install assets, and run the app
zig build check     # compile the game and GPU smoke executable
zig build test      # run Zig unit tests
zig build bench     # run CPU entity and particle processor benchmarks
zig build verify    # run check, test, and shader compilation
zig build package   # install selected-mode binaries and runtime assets
```

Useful supporting commands:

```sh
zig build fmt       # format build.zig, build.zig.zon, and src/
zig build shaders   # compile GLSL shader sources to platform GPU shaders
zig build gpu-smoke # create an SDL_GPU device and submit one frame
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

`zig build bench` runs non-interactive CPU benchmarks for the movement entity
processor and transient particle processor. The default run automatically
exercises serial, inline, fixed-worker, adaptive thread-count,
adaptive+tuned-grain, small-grain, and large-grain thread-system cases.
Movement runs a count sweep so threshold changes can be compared across entity
counts; particles use one representative count per profile. Output is grouped
by workload and count, then explains what to tune: per-system parallel
thresholds, adaptive thread count, and batch grain size. The
adaptive+tuned-grain case keeps adaptive thread-count selection enabled, layers
an external grain tuner on top, settles on the best measured grain before
timing when possible, and reports phase, initial, final, best, and candidate
grain sizes. In adaptive cases, low-count processors may stay inline until
measured completion time shows that active worker threads are worth the
synchronization cost; forced-inline batches are timing samples for that batch
only and do not reset adaptive thread-count state for later processors. Use
`--details` only when you need the supporting per-case timings. Use other
optional arguments only to narrow or scale the run:

```sh
zig build bench -- --profile quick
zig build bench -- --profile standard --iterations 100
zig build bench -- --case thread-adaptive
zig build bench -- --details
```

## GPU Smoke

`zig build gpu-smoke` opens a small window long enough to create an SDL_GPU
device, acquire a swapchain texture, and submit one frame. SDL still needs a
usable video backend and display environment, so headless shells or CI runners
may need display setup before this check can run.
