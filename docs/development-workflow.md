# Development Workflow

## Common Commands

```sh
zig build           # build and install the app, runtime assets, and shaders
zig build run       # build, install assets/shaders, and run the app
zig build dev       # build shaders, install assets, and run the app
zig build check     # compile the game, GPU smoke, and benchmark executables
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
it enforces.

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

CPU floor: every release mode (ReleaseSafe soaks included) defaults to the
shipped CPU minimum, `x86_64_v2` (SSE4.2, POPCNT) on x86-64, `apple_m1` on
macOS arm64, and the baseline model (NEON) on other aarch64, so gates and
soaks test what ships. Debug builds for the native CPU. `-Dcpu` or `-Dtarget` overrides; moving the floor
(for example to v3) is a deliberate decision.

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
`-Dtest-filter=systems.pathfinding` selects the pathfinding modules. Test
rules: `.claude/rules/tests-benchmarks.md`.

## Validation Cadence

The cadence (which step when) is `.claude/rules/build-validation.md`.
`zig build verify` runs compile coverage, unit tests, shader compilation, atlas
lint, idiom lint, and a `zig fmt --check` over `build.zig`, `build.zig.zon`, and
`src/` (files edited outside the format hook fail here; `zig build fmt` fixes
them).

## Benchmarks

`zig build bench` pins its default log level to `warn` in every optimize mode
(per-case debug chatter adds overhead across many cases); pass
`-Dlog-level=debug` when troubleshooting.

It runs non-interactive CPU benchmarks for movement bodies and movement intents,
particles, AI, memory, affect, perception, the spatial index, scoped simulation,
steering, collision and collision response, plane traversal, nav updates,
chunk-owned terrain and its nav reaction, pathfinding (request load and nav
scaling), and render prep. Each case set has a serial baseline, fixed-worker,
fixed small/large-range, and adaptive cases.
`thread-adaptive-fixed-range` isolates adaptive worker-count selection with a
fixed range size; `thread-adaptive-tuned-range` uses the production
processor-owned worker and range tuner. Fixed cases are controls for scheduler
overhead, worker scaling, and range size. Some groups take their sizes from the
profile: the processor and render-prep groups share a count ladder
(quick 1,024, 4,096, and 10,000; standard adds 25,000 and 50,000; stress 10,000,
25,000, and 50,000), and most pathfinding request-load groups keep their own lists
per profile. Every other group (the item-code groups and the right-sized stage
and scaling groups below) runs one fixed config list, so `--profile` does not
change it; `--items N` runs one config of any group.

Each group's doc comment, beside its `BenchmarkGroup` in `src/benchmarks/`, is
the full statement of its fixture, what one sample times, its item code, its pass
shape, and its `--details` fields; the list below indexes them. An item code packs
a config's fields in decimal, most significant first, and the report header prints
the group's layout (`suite.ItemCode`).

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
  selected group; `--group-prefix P` runs every group whose name starts with
  `P` (a family such as `chunk-scale-`); `--fallback-budget N` compares
  hard-fallback caps against the runtime default in ReleaseFast tuning.

Stage groups (counts 1,024, 4,096, and 16,384 unless noted; each passes linear in
its count, the adaptive case judged against its controls):

- `movement-apply-intents`: one AI movement intent per moving agent in a scattered
  row order; `movement-apply-intents-sorted` is the same stream in row order, its
  control for worker ranges writing scattered rows.
- `collision-response-stage`: one response step over a contact stream where every
  body sits in several contacts as `a` and `b`; `--details` prints intents,
  triggers, the gather and apply shapes, and the main time outside the stage
  batches. The `collision-response-solid`/`-bounce`/`-trigger`/`-mixed` groups run
  the serial case only.
- `plane-traversal` (no traversals), `-falls` (a fixed 64 falls per step), and
  `-dense-falls` (every 4th agent falls): the plane stage's entry gather, reserve,
  and commit with its carve batch; `plane-traversal-dense-falls-banded` fixes 4,096
  agents and varies the landing level's dense bands (4, 32, 256), passing when
  main time per entry is flat in bands.
- `steering` (profile counts 128 to 10,000), `-shuffled`, `-corridor`,
  `-cluster-outlier`: one steering step on a grid, in shuffled creation order, in
  one cell-row corridor, and in a cluster with one far outlier; navigation intents
  are written untimed. `--details`
  prints each prepare stage, `band_max=`, `bucket=`, and `sort=`.
- `steering-static-change` (10, 1,000, or 10,000 statics; flat) and
  `steering-static-dense` (4, 16, or 64 statics per chunk): a static moved through
  the commit seam then a steering step, and a steering step among dense statics.

Terrain and nav scaling groups (a config the bench's nav size limit, 512 MiB, cannot
hold fails with its figure, never skips; every nav group checks each part of the
nav's bytes against its production byte bound after the build and at run end):

- `chunk-scale-*` time one fixed terrain change at every level side (256, 1024,
  2048 at 8 levels) and depth (8, 32, 128 levels at 256²), one axis at a time; each
  code ends in `level side * 1000 + levels`. `-dig` (64 single-cell digs and
  refills), `-ramp` (64 ramp digs with their exits and links), and the GPU sync
  groups run serial only; `-cave-in` and `-explosion-fill` time one batched edit
  over 4, 64, or 256 chunks at 256² × 8 (the scale axes at 64), plus one
  explosion case with 32 blocking sparse props per chunk; all flat in side and
  depth, the batched ones linear in region chunks.
- `chunk-scale-gpu-sync-dig` (the dig workload plus a GPU sync; a window-edge axis
  of 2, 6, or 14 chunks, and a batched-change axis at 2, 8, or 32 resident written
  layers at 256² × 128), `-level-enter`, and `-pan` (a 2-, 6-, or 14-chunk window
  panning one chunk; the pan and level-enter groups also run 8 and 32 resident
  layers), against a headless store; upload counts are checked.
- `chunk-scale-nav-*` add the post-commit nav reaction over every level: `-dig`,
  `-ramp`, `-cave-in`, `-explosion-fill`, `-enclose` (P pockets of 4×4 chunks, one
  pocket of edge E, or a one-chunk tunnel of L chunks, each walled off by one
  doorway that one edit fills and the next reopens: linear in P, in the pocket's
  area, and in L, flat in side), and `-level-add` (a level added with a solid band,
  depth growing by one per iteration; its replace case, item prefix `1 * 10^7`,
  times a blocking band added to the newest walkable level). `--details` prints the
  terrain stages, the reaction's stage shapes, its connectivity and closure block,
  and `main_split=` (the reaction's main time by section: mark, plan, reserve,
  commit, conn_merge, conn_layout, flood, closure, evict; `inline:` for the stages
  the tuner kept inline, a serial run's flood and closure rounds included;
  `rest:` for O(1) glue).
- `nav-update-scattered` (16 to 1,000 digs over 256 chunks) and
  `nav-update-multichunk` (one compact block of 256 to 16,384 cells): a dirty
  footprint toggled open then blocked through the terrain-writer record, linear in
  dirty chunks. `nav-update-entity-obstacles` (10, 1,000, or 10,000 other statics)
  and `nav-update-static-population` (1,000, 10,000, or 50,000 dynamic bodies): one
  static moved through the commit seam, flat. `nav-update-static-dense` and
  `-dense-tail` (64, 1,024, or 16,384 statics changed in one commit): linear.
- `pathfinding-level-size` (side 256, 1024, 2048; flat in side),
  `-cross-level-depth` (256² of 8, 32, or 128 levels; flat in depth),
  `-cross-level-shaft` (a ramp shaft plus an unusable one-way teleport; flat in
  depth), and `-cross-level-teleport` (the depth configs with one far teleport,
  then three teleport layouts: 0 a border band of 64, 256, or 1,024 teleports at
  256², flat in count; 1 a strip mirrored to the deepest level at sides 256, 1024,
  2048, flat in side; 2 random pads of 16, 64, or 256, judged at 16 and 64, 256
  reported; code `layout * 10^12 + teleports * 10^7 + side * 1000 + levels`) time
  one cold step of 64 routes. The level-size and depth groups fail unless every
  route solves within the step; the teleport and shaft groups count a route whose
  search exhausted its budget as unsolved (`routes solved= unsolved=` under
  `--details`).
- `pathfinding-long-path`: one far goal per route length on the flat chunk-portal
  search (`variant * 10^7 + layout * 10^6 + parameter`). Layouts: 0 serpentine
  (2048², a wall every 128 rows), 1 open diagonal (2048²), 2 descent (128 levels of
  256²), 3 depth (a 4-level descent on stacks of the parameter's levels), 4 wide
  descent (3 levels of side S), 5 seeded blob caves (2048²), 6 deep wide descent
  (1024² levels). Variants: 0 library caps; 1 a probe raising only the tier-1
  abstract cap (fails if it still saturates); 2 a 32-request fold check; 3 a walk
  of one agent through partial hops (open diagonal, cave, serpentine; a sample is
  the whole walk, which must arrive); 4 a hop chain for the cross-level layouts
  (descent, wide, deep wide; restarts at each partial's end, a dropped hop fails
  the case). Three route lengths per layout per variant, serial only. `--details`
  prints, per attempt, abstract claims, corridor nodes, stitched cells, segments,
  `settles=` and `frozen=` (the crossing search), the outcome (`abstract_partial`
  is a saturated tier-1 search published toward its least-estimate node), and the
  step time; a walk prints steps, held steps, solves, partial and full results,
  escalations, and claims; a hop chain prints hops (`least_hops`), solves,
  escalations, and claims.
- `pathfinding-link-fold`: one reaction applying 64 random pads on a 512² × 8
  world; a uniform axis (1,024, 8,192, or 32,768 background pads) and a probe axis
  fixing endpoints per touched chunk (preload 16 over three backgrounds, then 4 and
  64 over 8,192). Passes when the `commit` section is flat per pad, the reaction is
  flat in background pads at a fixed preload, and at most linear in endpoints per
  touched chunk.
- `pathfinding-evict`: one dig on a 256² level holding 1,000, 10,000, or 50,000
  cached short paths (flat), then a chunk-aligned square of 4, 16, or 64 chunks at
  10,000 results (linear in region chunks and the registrations visited); items/s is
  registry entries visited. `--details` prints `evict_count=`, `evict=`,
  `evict_flush=`, and the reaction's main time.
- `pathfinding-elastic-ramp` (the agent count ramps to 1,000, 4,000, or 16,000;
  linear with no re-solve) and `pathfinding-elastic-shrink` (the same ramp, then a
  drop to the youngest eighth; the timed step shrinks the capacity, passing at most
  linear in the capacity it shrinks from; `--details` adds the hold step,
  `resize_copy=`, and `resize_main=`).
- `pathfinding-negative-steady` (256, 1,024, or 4,096 requests to a sealed pocket;
  linear), `pathfinding-negative-dig` (`side * 1000 + requests`: 256064, 256128,
  256256, 1024064, 2048064; a far toggle plus the reaction and update; flat in side,
  linear in requests), and `pathfinding-negative-burst` (1,024, 4,096, or 12,288
  unreachable requests in one step over four pockets; variant 1, code `10^6 + N`,
  is a blocked crowd with four projections, labelled `projections=`/`fallbacks=`):
  intake answers every request unavailable from reach, with no search and nothing
  pending or cached (`unavailable=`).
- `pathfinding-connectivity-split`: a gap chunk blocked then reopened, sealing a
  room of edge² chunks (2, 8, 32 at side 1024; 8 at 256 and 2048), cutting a ring
  without splitting it (edges 2, 8, 32), or sealing a one-chunk tunnel (8, 32, 62 at
  1024; 8 at 256 and 2048). Passes when no config grows faster than its room,
  ring, or tunnel and every config is flat in side; `--details` prints the flood's
  rounds, searches per round, its tuner, and `build_visits=`.
- `pathfinding-connectivity-oneway` (`variant * 10^10 + terminals * 10^5 +
  systems`): locality (16, 256, 2,048 systems of 8 terminals; flat), tail and head
  toggles of one 64-, 512-, or 4,096-terminal chain (head at most linear, tail at
  most terminals² / 32), a far dig (flat), shrunk (a chain cut to 64 rooms, peak
  512, 2,048, 4,096; flat in peak), fan (64, 128, 256; at most terminals² / 32),
  dense (2, 8, 32 merged systems; at most their merged rows; block resizes and the
  reserve ratio reported), and ballast (variant 7 at 64, 512, 2,048 background
  systems: a ballast block retired untimed before every sample; the timed toggle
  must land, allocate, and free no block, its reserve and closure stages flat in
  systems). `--details` prints the closure stages and, for ballast, the retire (the
  reopen's landing and tail use, the close's free) and the timed block reaction's
  split (reserve, closure stages, landing, rest).
- `render-sparse-window-frame`, `-pan`, and `-add` time one frame's sparse-tile
  prep on a 2048² world of 8 levels holding 1,000, 16,000, or 256,000 sparse tiles
  (exactly 256 inside a fixed 1280×720 window): a still frame, a one-chunk pan and
  back, and one tile added outside the window. Serial only; flat.

Pathfinding request-load groups run world-backed nav at one fixed level side, so
only the request count varies (escalated-detour keeps level side as its axis, at
most quadratic in side): `pathfinding` (a cold step of distinct goals, linear to
the per-step solve ceiling and flat past it), `-shared-goal` (one goal, one solve;
the field threshold sits above the count), `-drain` (a carried queue of at least
two ceilings; flat in depth), `-cache-open` and `-cache-detour` (warm hits),
`-hard-fallback` and `-hard-fallback-budget` (cold hard routes, the latter at a
capped admission; `--fallback-budget` overrides it), `-escalated-detour` (one
tier-1 detour per level side), `-query` (per-agent status against a warm cache),
`-group-field-detour` and its `-moving` and `-moving-hysteresis` variants (a pack
sampling a ready field), `-group-field-packs` (1, 4, or 16 packs of 16 agents, each
field building at once; `--details` prints coverage, blocks, resident bytes, and
pool growths), and `-group-field-tunnel` (four fields on a 1-wide corridor lattice
capped at 2,048, 16,384, or 65,536 cells; linear in the cap). Their `--details`
prints the update's stages (`publish_copy=`, `registry_flush=`, whose item counts
are flush work units, not the 16 shards) and the main time per phase; a configured
range size (the fixed controls, `PathfindingConfig.items_per_range`) counts flush
units too. `candidates` on route groups includes the tier-1 pool.

The nav memory estimate (`nav_size.navStorageParts`) only sums production byte bounds:
each nav structure and the request side (`requestStorageBytesBound`) owns an
`@sizeOf`-based worst-case bound beside it, fed by the built world's content
(`NavGraph.storageContentOf`), with `runs_per_result` defaulting to one run per
stored cell; `checkNavBytes` asserts every part's live bytes stay within its charge.

Optional arguments narrow or scale the run. Day-to-day runs target a group
(`.claude/rules/tests-benchmarks.md`); the full-suite forms (`--profile`, bare
`--details`) are for requested sweeps:

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
zig build bench -- --group-prefix chunk-scale- --case serial-direct
zig build bench -- --group-prefix render-sparse-window- --case serial-direct
zig build bench -- --group pathfinding-hard-fallback-budget --items 2000 --fallback-budget 128 --case thread-adaptive-tuned-range --details
zig build bench -- --details
```

Before/after comparisons use `tools/bench_ab.py`: targeted groups only, a base
ref vs the working tree, one Debug run per side (`--reps 3` confirms a slower
case with medians and spread). Each side's runs are
cached by its build inputs (`src/`, `build.zig*`, `assets/`) for six hours, so
a landing's measured tree is reused as the next landing's base; `--fresh`
reruns both sides interleaved. Full-suite
capture with timestamped output under `benchmark_outputs/` uses
`tools/bench_run.py`. Both: [tools/README.md](../tools/README.md).

## GPU Smoke

`zig build gpu-smoke` opens a small window long enough to install runtime
assets/shaders, initialize the renderer path, load platform shader files, draw a
primitive through the sprite pipeline, acquire a swapchain texture, and submit
one frame. SDL still needs a usable video backend and display environment, so
headless shells or CI runners may need display setup before this check can run.
