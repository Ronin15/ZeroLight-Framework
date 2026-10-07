## Slice 52C: CI Workflows And Release Performance Baseline

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 52A](slice-52a.md), [Slice 49](slice-49.md), [Slice 52B](slice-52b.md) (tag job after 52B) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** The verify, gpu-smoke, shader-artifacts, and
soak-bench workflows depend on **52A**. The `frame-battle` digest depends on
**Slice 49** (`simulationChecksum()` oracle and the session-seed constructor
signature). The tag packaging workflow depends on **52B**.

Goal:

- Every push to `main` and every PR runs the full gate on Linux x86_64,
  Windows x86_64 (native, plus cross from Linux), and macOS arm64.
- A display-gated gpu-smoke runs under Xvfb with Mesa lavapipe.
- Tags produce downloadable per-OS packages.
- A weekly ReleaseSafe soak and release bench archives its outputs.
- The new `frame-battle` bench gives one reproducible full-frame number at the
  production battle-scale population.

### Current foundation (do not rebuild)

- `.github/` holds only `CODEOWNERS` and `FUNDING.yml`; there are no
  workflows. VoidLight has none either.
- `zig build verify` (`build.zig:244-249`) runs check, test, shaders, and both
  lints.
- The Python lints run as `python3` (`build.zig:236-242`). GitHub's Windows
  images do not reliably provide `python3` on `PATH`; they provide `python`.
- The Zig 0.17 changelog's manual residual
  (`docs/changelogs/zig_0_17_upgrade.md:127-129`) is still open: no real
  Windows host has run `test`/`bench`/`run`/`gpu-smoke` with the PATH prepend.
- `gpu-smoke` needs a display (`development-workflow.md:429-435`).
- Benches:
  - `src/benchmarks/runner.zig:26-66` registers the groups.
  - The suite accepts `--group`, `--case`, `--items`, `--profile`,
    `--iterations`, and `--details`.
  - Outputs are gitignored (`benchmark_outputs/`).
  - `tools/bench_run.py:77` always runs `zig build bench` in Debug (no
    optimize passthrough), and `:66` calls `os.uname()`, which does not exist
    on Windows.
- The battle-scale reference is manual: ReleaseSafe 60-second
  `runtime_perf_log` dumps at 2048 movers
  ([Scaling Gaps](../scaling-gaps.md) battle-scale control table). They cannot be reproduced
  across machines or commits.
- No bench drives the full fixed step. The groups are per-system, and
  `render-game-prep` (`src/benchmarks/render_game_prep.zig`) covers CPU render
  prep on synthetic fixtures (`render_prep.collectDynamicRecords` plus
  bench-local emit helpers).
- `GameDemoState` can be built headless:
  - `initProceduralWithRuntimeAssets` (`game_demo_state.zig:323-357`) takes
    the module-level `default_world_build_config` (`:198-206`, fixed seed at
    `world_system.zig:141`) and uses
    `battle_scale_demo_mover_count = 2048` (`:85`).
  - `update(UpdateContext)` (`:512-563`) runs input, the pipeline, audio
    queueing, particles, the camera, and the structural commit.
  - RuntimeAssets can be seeded with metadata only, without a GPU
    (`loading_state.zig:575-596`).
  - A serial `ThreadSystem` is created with `.{ .max_worker_threads = 0 }`
    (`loading_state.zig:299`).

### Architecture notes

- **Owners:**
  - `.github/workflows/` (four files).
  - `build.zig`, for the `-Dpython` option.
  - `tools/bench_run.py`.
  - `src/benchmarks/frame.zig`, registered in `runner.zig`. It reuses
    `render_game_prep.zig`'s emit helpers, made `pub` within
    `src/benchmarks/`.
  - No production `src/` API changes. The bench uses `pub` functions and
    struct fields only.
- **`-Dpython=<exe>`:** defaults to `python` on Windows hosts and `python3`
  everywhere else. Every Python `addSystemCommand` uses it: both lints,
  `check_build_pins`, `check_shader_artifacts`, and `build_sdl`.
- **Workflows:**

  | File | Trigger | Jobs (blocking unless noted) |
  | --- | --- | --- |
  | `ci.yml` | push `main`, `pull_request`, `workflow_dispatch` | `linux`, `linux-tsan`, `linux-gpu-smoke`, `windows`, `macos` |
  | `shader-artifacts.yml` | push/PR touching `assets/shaders/**`, `build.zig`, or `tools/check_shader_artifacts.py`; `workflow_dispatch` | `regenerate` on `windows-2025` |
  | `release.yml` | tags `v*`; `workflow_dispatch` (artifacts only, no publish) | `package-linux`, `package-windows`, `package-macos`, `publish` |
  | `soak-bench.yml` | `workflow_dispatch`; weekly cron once a run duration is recorded | `soak-bench`. Fails on test, assert, safety-panic, or `state_digest` mismatch only; it never fails on timing. |

- **`linux-tsan` job:** Slice 50 lands before 52C, so `ci.yml` runs Slice
  50's documented race gate on `ubuntu-24.04`: `zig build test
  -Dsanitize-thread=true`, then `zig build bench -Dsanitize-thread=true --
  --profile quick --group <g>` for each threaded group Slice 50 lists. It uses
  the same pins, setup-zig, SDL deps, and cache steps as `linux`. If Slice 50's
  toolchain probe narrowed the supported targets, the job follows that
  record.
- **gpu-smoke decision:**
  - It runs on Linux under `xvfb-run` with Mesa lavapipe, plus
    `vulkan-validationlayers` so Debug SDL_GPU validation is live. The job is
    blocking.
  - It does not run on macOS (hosted arm64 runners are VMs with no dependable
    Metal device) or on Windows (no GPU adapter on the runner).
  - Real-GPU smoke stays a manual pre-release gate, alongside Slice 43's
    hardware check.
  - If SDL_GPU refuses lavapipe at landing, delete the job and record the
    reason in `development-workflow.md`. Never leave a red or ignored job
    (`continue-on-error` is banned for gates).
- **Caching:**
  - `mlugg/setup-zig` caches its global cache.
  - `actions/cache` covers `zig-pkg/` and `.zig-cache/`, keyed on runner OS,
    the Zig pin, and `hashFiles('build.zig', 'build.zig.zon', 'tools/build_sdl.py')`.
    The expensive cached item is the SDL CMake Run-step output in
    `.zig-cache`.
- **Pinning:**
  - The Zig version is read from `build.zig.zon` in one step and passed to
    setup-zig, so there is a single pin.
  - GitHub-owned actions are pinned by major tag.
  - Third-party actions (`mlugg/setup-zig`, `humbletim/install-vulkan-sdk`,
    `softprops/action-gh-release`) are pinned by full commit SHA with a version
    comment.
  - The sniper SDK image is pinned by digest.
- **Release builds:**
  - Linux:
    - Builds inside Valve's Steam Runtime 3 "sniper" SDK container (Debian 11,
      glibc 2.31) with `-Dtarget=x86_64-linux-gnu.2.31`. The exe and the
      source-built SDL then share the 2.31 floor, so the package runs in
      Steam's sniper container and on every newer distro.
    - **Fallback:** if the SDK image lacks an SDL backend header,
      `build_sdl.py`'s assertion fails. Then build on `ubuntu-22.04` with
      `-Dtarget=x86_64-linux-gnu.2.35` and document the 2.35 floor.
  - Windows: cross-compiled on `ubuntu-24.04`. It needs only the prebuilt SDL,
    the committed DXIL, and Zig's resource compiler; no Windows toolchain.
  - macOS: built on `macos-15` with `-Dtarget=aarch64-macos.11.0`. macOS 11
    plus `apple_m1` covers every Apple Silicon Mac. That floor is declared, not
    CI-tested, because runners are macOS 15.
  - Archives:
    - Linux: `tar -czf`.
    - Windows: `zip -r`, excluding `.pdb`; a separate `symbols-windows`
      artifact carries the PDB.
    - macOS: `ditto -c -k --keepParent`.
  - `publish` attaches the archives to the GitHub Release on tags only.
- **Soak and bench:**
  - The trigger is `workflow_dispatch` first. Record one manual run's duration
    at landing, against the `timeout-minutes: 240` budget (ReleaseSafe full
    `--profile stress` sweep plus 2 × 36,000 `frame-battle` steps plus the
    digest runs). Add the weekly cron only after that evidence is in
    `development-workflow.md`, adjusting the timeout to about 1.5× the
    measured duration.
  - ReleaseSafe runs:
    - `zig build test`.
    - `frame-battle --iterations 36000`: 10 minutes of 60 Hz simulation per
      case, the deterministic battle soak.
    - The full suite with `--profile stress`. This is the one sanctioned
      full-suite run: coding-standards § Benchmarks allows a full-suite sweep only
      when a slice names it, and this slice names this one.
    - A serial-versus-threaded digest check: one `frame-battle` run with
      `--case thread-adaptive-tuned-range`. The suite adds the `serial-direct`
      baseline row automatically when a non-baseline case is filtered
      (`suite.zig:603-605`), so both rows come from the same run and same
      iteration count, and exactly one unique `state_digest` is required.
    - A cross-baseline digest check: `frame-battle --case serial-direct` under
      `compat` and under `ship`, which must produce equal `state_digest`.
  - ReleaseFast runs `frame-battle` plus the targeted groups.
  - Everything runs through `tools/bench_run.py`, writes to
    `benchmark_outputs/`, and is uploaded with `upload-artifact` (90-day
    retention).
  - Numbers from hosted runners are trend data, because the runners are
    shared VMs. Authoritative release numbers come from the reference machine
    running the same command.
- **`tools/bench_run.py`:**
  - New `--optimize {Debug,ReleaseSafe,ReleaseFast,ReleaseSmall}` and
    `--cpu-baseline {native,ship,compat}` flags, passed as
    `-Doptimize`/`-Dcpu-baseline` before `bench`. The header records both.
  - Replace `os.uname().nodename` with `platform.node()`.
- **Shader artifacts job:**
  - Runs on `windows-2025`.
  - Tools: a pinned LunarG Vulkan SDK (for `glslc` and `spirv-cross`) and a
    pinned official DirectXShaderCompiler release zip. The zip bundles
    `dxil.dll`, so DXIL comes out signed, and its sha256 is verified before
    use.
  - Steps: `zig build shaders-update`, then
    `git diff --exit-code -- assets/shaders`.
  - On failure it uploads the regenerated artifacts, so a contributor without
    the toolchain can commit CI's output.
  - The tool versions are recorded in the workflow env and in
    `development-workflow.md`.
- **`frame-battle` bench** (`src/benchmarks/frame.zig`, the release full-frame
  baseline; render-prep only, no GPU):
  - **Fixture per case:**
    - `AssetStore` rooted at `assets`.
    - RuntimeAssets seeded with metadata only: `world_tileset` plus
      `grim_characters`, following the `loading_state.zig:575-596` pattern.
    - `GameDemoState.initProceduralWithRuntimeAssets(…, game_demo_state.default_world_build_config, &threads, 1280, 720, SimulationSeed.default)`,
      using Slice 49's `session_seed` parameter. When Slice 58 lands, follow
      its constructor signature (the `GeneratedWorld` return) in the same
      change. That is the production world, the production archetype mix,
      the fixed default session seed, and the default logical size
      (`resolution.zig:18-19`).
    - Population: 2048 movers today. After Slice 58 it becomes
      `min(2048, generated candidates)`, plus up to 512 ambient NPCs after
      Slice 62. The fixture asserts the actual live count it measured and
      prints it in the detail row; each of those slices re-baselines
      `frame-battle` and the recorded digests.
  - **Settle:** a fixed `frame_settle_steps: u32 = 600` untimed steps (10 s of
    simulation). This excludes the load spike and lets the adaptive tuners
    converge. It is a fixed constant and is never scaled.
    - frame-battle does **not** use the suite's variable-length adaptive
      settle, so every case runs an identical step count.
    - The detail row reports tuner phase at measurement start.
  - **One timed iteration:**
    1. `demo.update` at `TimeLoop.fixed_delta_seconds` with an idle
       `InputState` and a local `AudioCommandBuffer` cleared each step.
    2. `world.setVisibleChunksForWorldRect` for the render camera at alpha 1
       (`demo.camera_current` before Slice 60, `camera_rig.renderCamera(1)`
       after) and the viewport, using the same formula as
       `game_demo_state.zig:566-572`. It drives render culling only; sim
       scope comes from `simViewRect()` (Slice 49).
    3. `render_prep.collectDynamicRecords` plus the shared emit helpers into a
       `SpriteBatch`.
    The sim and render-prep halves are timed separately in `--details`.
  - **Items:** fixed at `{2048}` for every profile. An `--items` value other
    than 2048 returns `.skipped`, with the reason "population fixed at demo
    battle scale".
  - **Cases:** `serial-direct` (`max_worker_threads = 0`) and
    `thread-adaptive-tuned-range` (production). Every other case returns
    `.skipped` with a reason.
  - **Digest:** `state_digest = demo.simulationChecksum()` (Slice 49), taken
    after the timed loop and printed as `state_digest=0x…` in the detail row.
    The bench defines no hash of its own. Every case of one run executes the
    same `frame_settle_steps + iterations` step count, so digests are
    comparable across cases and baselines. The checksum is a same-binary
    oracle (Slice 49), so it is compared only within one CI job, never
    archived as a reference value.
    - CI asserts, in `soak-bench.yml`, that `serial-direct` and
      `thread-adaptive-tuned-range` produce equal digests within one run, and
      that `compat` and `ship` produce equal digests.
    - A mismatch is a determinism defect. Route it to
      **zig-debug-specialist** before 52C closes; never widen the check.
  - Internal `std.debug.assert`s cover the population and frame-stream
    capacities, as coding-standards § Benchmarks requires for bench-fixture correctness. No
    `zig build test` code calls this file.
  - **Cost:** the default `zig build bench` run includes frame-battle. In
    Debug, that adds a production world build per case. This is documented.

**`ci.yml` skeleton** (resolve the `<…>` placeholders when landing):

```yaml
name: ci
on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true
permissions:
  contents: read

jobs:
  linux:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - id: pins
        shell: bash
        run: echo "zig=$(sed -n 's/.*\.minimum_zig_version = "\(.*\)".*/\1/p' build.zig.zon)" >> "$GITHUB_OUTPUT"
      - uses: mlugg/setup-zig@<sha> # v2
        with:
          version: ${{ steps.pins.outputs.zig }}
      - name: SDL source-build dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y --no-install-recommends cmake pkg-config \
            libasound2-dev libpulse-dev libpipewire-0.3-dev libx11-dev libxext-dev \
            libxrandr-dev libxcursor-dev libxfixes-dev libxi-dev libxss-dev libxtst-dev \
            libxkbcommon-dev libdrm-dev libgbm-dev libegl-dev libgl-dev libdbus-1-dev \
            libibus-1.0-dev libudev-dev libwayland-dev wayland-protocols libdecor-0-dev
      - uses: actions/cache@v4
        with:
          path: |
            zig-pkg
            .zig-cache
          key: zig-linux-${{ steps.pins.outputs.zig }}-${{ hashFiles('build.zig', 'build.zig.zon', 'tools/build_sdl.py') }}
          restore-keys: zig-linux-${{ steps.pins.outputs.zig }}-
      - run: zig fmt --check build.zig build.zig.zon src
      - run: zig build verify
      - run: zig build test -Doptimize=ReleaseSafe
      - name: Release binaries carry the ship CPU baseline
        shell: bash
        run: |
          zig build bench -Doptimize=ReleaseSafe -- --group movement --profile quick --items 1024 --iterations 1 2>&1 | tee header.txt
          grep -q 'cpu_model=x86_64_v2 ' header.txt
      - run: zig build check -Doptimize=ReleaseFast
      - run: zig build check -Doptimize=ReleaseSmall
      - run: zig build check -Doptimize=ReleaseFast -Dcpu-baseline=compat
      - name: Packages refuse native and -Dcpu builds
        shell: bash
        run: |
          # `!` is exempt from errexit, so test explicitly
          if zig build package --release=fast -Dcpu-baseline=native; then exit 1; fi
          if zig build package --release=fast -Dcpu=x86_64_v3; then exit 1; fi
      - name: Windows cross-compile coverage
        run: |
          zig build fetch-sdl -Dtarget=x86_64-windows
          zig build check -Dtarget=x86_64-windows
          zig build check -Dtarget=x86_64-windows -Doptimize=ReleaseFast --cache-poison=disallowed

  linux-tsan:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      # pins, setup-zig, SDL deps, cache: identical to `linux`
      - run: zig build test -Dsanitize-thread=true
      - name: Threaded bench race smoke (Slice 50 group list; timings ignored)
        shell: bash
        run: |
          for g in movement collision steering perception pathfinding-hard-fallback scope thread-dispatch; do
            zig build bench -Dsanitize-thread=true -- --profile quick --group "$g"
          done

  linux-gpu-smoke:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      # pins, setup-zig, SDL deps, cache: identical to `linux`
      - run: sudo apt-get install -y --no-install-recommends xvfb mesa-vulkan-drivers vulkan-validationlayers
      - name: gpu-smoke under Xvfb + lavapipe
        env:
          SDL_VIDEO_DRIVER: x11
          VK_DRIVER_FILES: /usr/share/vulkan/icd.d/lvp_icd.x86_64.json
          VK_ICD_FILENAMES: /usr/share/vulkan/icd.d/lvp_icd.x86_64.json
        run: xvfb-run -a zig build gpu-smoke

  windows:
    runs-on: windows-2025
    steps:
      - uses: actions/checkout@v4
      - id: pins
        shell: bash
        run: echo "zig=$(sed -n 's/.*\.minimum_zig_version = "\(.*\)".*/\1/p' build.zig.zon)" >> "$GITHUB_OUTPUT"
      - uses: mlugg/setup-zig@<sha> # v2
        with:
          version: ${{ steps.pins.outputs.zig }}
      - uses: actions/cache@v4
        with:
          path: |
            zig-pkg
            .zig-cache
          key: zig-windows-${{ steps.pins.outputs.zig }}-${{ hashFiles('build.zig', 'build.zig.zon') }}
          restore-keys: zig-windows-${{ steps.pins.outputs.zig }}-
      - run: zig build fetch-sdl
      - run: zig build verify
      - run: zig build test -Doptimize=ReleaseSafe
      - name: Bench binary runs with the Windows-host PATH prepend
        run: zig build bench -- --group movement --profile quick --items 1024 --iterations 1

  macos:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - id: pins
        shell: bash
        run: echo "zig=$(sed -n 's/.*\.minimum_zig_version = "\(.*\)".*/\1/p' build.zig.zon)" >> "$GITHUB_OUTPUT"
      - uses: mlugg/setup-zig@<sha> # v2
        with:
          version: ${{ steps.pins.outputs.zig }}
      # cmake + Xcode ship on the hosted image
      - uses: actions/cache@v4
        with:
          path: |
            zig-pkg
            .zig-cache
          key: zig-macos-${{ steps.pins.outputs.zig }}-${{ hashFiles('build.zig', 'build.zig.zon', 'tools/build_sdl.py') }}
          restore-keys: zig-macos-${{ steps.pins.outputs.zig }}-
      - run: zig build verify
      - run: zig build test -Doptimize=ReleaseSafe
      - run: zig build check -Doptimize=ReleaseFast
```

**`release.yml` skeleton:**

```yaml
name: release
on:
  push:
    tags: ['v*']
  workflow_dispatch:
permissions:
  contents: write

jobs:
  package-linux:
    runs-on: ubuntu-24.04
    container: registry.gitlab.steamos.cloud/steamrt/sniper/sdk@sha256:<digest>
    steps:
      - uses: actions/checkout@v4
      # pins + setup-zig as in ci.yml
      - run: zig build package --release=fast -Dtarget=x86_64-linux-gnu.2.31
      - shell: bash
        run: |
          cd zig-out/package
          for d in */; do tar -czf "$GITHUB_WORKSPACE/${d%/}.tar.gz" "${d%/}"; done
      - uses: actions/upload-artifact@v4
        with: { name: package-linux, path: '*.tar.gz', if-no-files-found: error }

  package-windows:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      # pins + setup-zig
      - run: zig build fetch-sdl -Dtarget=x86_64-windows
      - run: zig build package --release=fast -Dtarget=x86_64-windows
      - shell: bash
        run: |
          cd zig-out/package
          for d in */; do zip -r "$GITHUB_WORKSPACE/${d%/}.zip" "${d%/}"; done
          cd ../package-symbols
          for d in */; do cp "${d%/}"/*.pdb "$GITHUB_WORKSPACE/"; done
      - uses: actions/upload-artifact@v4
        with: { name: package-windows, path: '*.zip', if-no-files-found: error }
      - uses: actions/upload-artifact@v4
        with: { name: symbols-windows, path: '*.pdb', if-no-files-found: error }

  package-macos:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      # pins + setup-zig
      - run: zig build package --release=fast -Dtarget=aarch64-macos.11.0
      - run: |
          cd zig-out/package
          for d in */; do ditto -c -k --keepParent "${d%/}" "$GITHUB_WORKSPACE/${d%/}.zip"; done
      - uses: actions/upload-artifact@v4
        with: { name: package-macos, path: '*.zip', if-no-files-found: error }

  publish:
    needs: [package-linux, package-windows, package-macos]
    if: startsWith(github.ref, 'refs/tags/')
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/download-artifact@v4
        with: { pattern: package-*, merge-multiple: true, path: dist }
      - uses: actions/download-artifact@v4
        with: { name: symbols-windows, path: dist }
      - uses: softprops/action-gh-release@<sha> # v2
        with: { files: dist/* }
```

**`soak-bench.yml` and `shader-artifacts.yml` skeletons:**

```yaml
name: soak-bench
on:
  workflow_dispatch:
  # Enable only after one recorded workflow_dispatch duration (see notes):
  # schedule:
  #   - cron: '17 6 * * 1'   # weekly, Monday 06:17 UTC
permissions:
  contents: read

jobs:
  soak-bench:
    runs-on: ubuntu-24.04
    timeout-minutes: 240
    steps:
      - uses: actions/checkout@v4
      # pins, setup-zig, SDL deps, cache: identical to ci.yml `linux`
      - run: zig build test -Doptimize=ReleaseSafe
      - name: Deterministic battle soak (ReleaseSafe, 10 min of 60 Hz sim per case)
        run: python3 tools/bench_run.py --optimize ReleaseSafe --keep 100 -- --group frame-battle --iterations 36000 --details
      - name: Capacity / OOM sweep (sanctioned full-suite run)
        run: python3 tools/bench_run.py --optimize ReleaseSafe --keep 100 -- --profile stress
      - name: Serial vs threaded determinism (state_digest must match)
        shell: bash
        run: |
          python3 tools/bench_run.py --optimize ReleaseSafe --keep 100 -- \
            --group frame-battle --case thread-adaptive-tuned-range --iterations 3600 --details | tee digest-threads.txt
          # the suite adds the serial-direct baseline row to this same run
          test "$(grep -o 'state_digest=0x[0-9a-f]*' digest-threads.txt | wc -l)" -eq 2
          test "$(grep -o 'state_digest=0x[0-9a-f]*' digest-threads.txt | sort -u | wc -l)" -eq 1
      - name: Cross-baseline determinism (state_digest must match)
        shell: bash
        run: |
          for b in compat ship; do
            python3 tools/bench_run.py --optimize ReleaseSafe --cpu-baseline "$b" --keep 100 -- \
              --group frame-battle --case serial-direct --iterations 3600 --details | tee "digest-$b.txt"
          done
          test "$(grep -ho 'state_digest=0x[0-9a-f]*' digest-compat.txt digest-ship.txt | sort -u | wc -l)" -eq 1
      - name: Release (ReleaseFast) baseline
        shell: bash
        run: |
          for g in frame-battle movement steering collision perception render-game-prep pathfinding-hard-fallback-budget; do
            python3 tools/bench_run.py --optimize ReleaseFast --keep 100 -- --group "$g" --details
          done
      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: bench-${{ github.run_id }}
          path: benchmark_outputs/bench-*.txt
          retention-days: 90
---
name: shader-artifacts
on:
  push:
    branches: [main]
    paths: ['assets/shaders/**', 'build.zig', 'tools/check_shader_artifacts.py']
  pull_request:
    paths: ['assets/shaders/**', 'build.zig', 'tools/check_shader_artifacts.py']
  workflow_dispatch:
permissions:
  contents: read

jobs:
  regenerate:
    runs-on: windows-2025
    env:
      VULKAN_SDK_VERSION: '<pinned at landing>'
      DXC_ZIP_URL: '<pinned DirectXShaderCompiler release zip URL>'
      DXC_ZIP_SHA256: '<sha256 of that zip>'
    steps:
      - uses: actions/checkout@v4
      # pins + setup-zig as in ci.yml
      - uses: humbletim/install-vulkan-sdk@<sha> # v1.2
        with: { version: '${{ env.VULKAN_SDK_VERSION }}', cache: true }
      - name: Pinned DXC (bundles dxil.dll so DXIL is validator-signed)
        shell: pwsh
        run: |
          Invoke-WebRequest $env:DXC_ZIP_URL -OutFile dxc.zip
          if ((Get-FileHash dxc.zip -Algorithm SHA256).Hash -ne $env:DXC_ZIP_SHA256) { throw 'DXC hash mismatch' }
          Expand-Archive dxc.zip -DestinationPath dxc
          "$PWD\dxc\bin\x64" | Out-File -Append $env:GITHUB_PATH
      - run: zig build shaders-update
      - name: Committed artifacts match the pinned toolchain
        shell: bash
        run: git diff --exit-code -- assets/shaders
      - uses: actions/upload-artifact@v4
        if: failure()
        with: { name: regenerated-shader-artifacts, path: assets/shaders/ }
```

### Checklist

- [ ] **`-Dpython` option.** Add `-Dpython=<exe>` with the host-dependent
      default, and route every Python `addSystemCommand` through it.
- [ ] **`tools/bench_run.py`.** Add `--optimize` and `--cpu-baseline`, put
      both in the header, and switch to `platform.node()`. Update
      `tools/README.md`.
- [ ] **`frame-battle` bench.**
  - Add `src/benchmarks/frame.zig`: the fixture (Slice 49 session-seed
    constructor, `game_demo_state.default_world_build_config`), the fixed
    `frame_settle_steps`, the sim and render-prep timers, the fixed 2048 item
    count, the two-case restriction with skip reasons, the
    `state_digest = demo.simulationChecksum()` detail field, the
    live-population detail field, and the internal asserts.
  - Register it in `runner.zig`.
  - Make the `render_game_prep.zig` emit helpers `pub` for reuse.
- [ ] (added by Slice 64) The `frame-battle` detail row prints `state_nan_values=<n>` from
      `demo.simulationChecksumReport(&threads)` beside `state_digest`.
      `soak-bench.yml` fails when any `state_nan_values` is nonzero.
- [ ] **`ci.yml`.** Add the `linux`, `linux-tsan`, `linux-gpu-smoke`,
      `windows`, and `macos` jobs as specified (every job writes out its pins
      and setup-zig steps), with third-party actions pinned by SHA. The
      `linux` job greps `cpu_model=x86_64_v2` and checks the native/`-Dcpu`
      package refusals.
- [ ] **`shader-artifacts.yml`.** Add it with the pinned Vulkan SDK and the
      hash-checked DXC.
- [ ] **`release.yml`.** Add it with the sniper SDK image pinned by digest,
      the Windows cross package plus the `symbols-windows` artifact copied
      from 52B's `zig-out/package-symbols/`, the macOS package, every upload
      with `if-no-files-found: error`, and the tag-only publish.
- [ ] (added by Slice 66) The macOS release job uploads `zig-out/package-symbols/<stage>/` as
      `symbols-macos` (the `symbols-windows` pattern); acceptance wording
      becomes "three archives plus `symbols-windows` and `symbols-macos`".
      66A later renames both to `symbols-<os>-<arch>`.
- [ ] **`soak-bench.yml`.** Add it (`workflow_dispatch` only) with the
      ReleaseSafe soak, the stress sweep, the serial-versus-threaded digest
      check, the cross-baseline digest check, the ReleaseFast baseline, and
      the artifact upload. Enable the weekly cron after one recorded run
      duration.
- [ ] **Docs.**
  - `docs/development-workflow.md` gets a Continuous Integration section
    covering:
    - what gates;
    - where bench and symbol artifacts live and how to download them;
    - shader regeneration through CI;
    - that hosted-runner numbers are trend data;
    - that the gpu-smoke lavapipe scope is not a real-GPU check.
  - Add a `frame-battle` row next to the 2048-mover control table in
    [Scaling Gaps](../scaling-gaps.md) (ReleaseSafe and ReleaseFast,
    reference machine).
  - Mark the 0.17 changelog's Windows `test`/`bench` residual as closed by
    CI. `run` and `gpu-smoke` on a real Windows host stay manual.

### Acceptance checks

- [ ] `ci.yml` is green on a PR: the `linux` job (including the
      `x86_64_v2` ship-baseline grep, the package refusals, and the Windows
      cross steps), `linux-tsan`, `linux-gpu-smoke`, `windows`, and `macos`.
- [ ] Shader regeneration works in both directions:
  - A PR that edits a `.glsl` without regenerating fails `verify` and fails
    `shader-artifacts`.
  - Committing the CI-uploaded artifacts turns both green.
- [ ] A test tag (`v0.0.0-ci.1`) publishes three archives plus
      `symbols-windows` and `symbols-macos` (Slice 66 addition).
- [ ] Each archive extracts to the 52B layout.
- [ ] The Linux binary from the sniper build runs on the reference Arch host
      (manual, on a display).
- [ ] A manual `soak-bench` run completes. It uploads `bench-<run_id>` with
      the frame-battle, stress, digest, and ReleaseFast outputs, and both
      `state_digest` checks pass. Its duration is recorded in
      `development-workflow.md`, the timeout is set from it, and only then is
      the weekly cron enabled.
- [ ] `frame-battle` digests match for `serial-direct` versus
      `thread-adaptive-tuned-range`, and for `compat` versus `ship`. Any
      mismatch is resolved through **zig-debug-specialist**, not by relaxing
      the check.
- [ ] The reference machine records a `frame-battle` ReleaseFast A/B under
      `compat` (`x86_64`) and `ship` (`x86_64_v2`), completing 52A's baseline
      evidence, and records the ReleaseSafe number next to the control table.
- [ ] `zig build verify` passes.
- [ ] The docs listed in the Checklist are updated.

### VoidLight reference

- VoidLight's `.github/` holds only `CODEOWNERS`, `copilot-instructions.md`,
  `FUNDING.yml`, and `ISSUE_TEMPLATE/`. There are no workflows. CI is net-new
  in both frameworks.
- VoidLight's soak model is the `ReleaseSafe` build type
  (`CMakeLists.txt:68-87`, `BuildSafetyControls.md:14`, `:48-51`), run by hand.
  The `frame-battle --iterations 36000` ReleaseSafe job is its reproducible
  counterpart. It supplements the manual multi-hour soak gate in
  `development-workflow.md:83-88`; it does not replace it.
- **Do not port** VoidLight's `-Wl,--gc-sections` and `-ffunction-sections`
  plumbing (`CMakeLists.txt:56`, `:64`), or its mold and ccache options
  (`:108-140`). Zig's linker and cache already cover these concerns.

