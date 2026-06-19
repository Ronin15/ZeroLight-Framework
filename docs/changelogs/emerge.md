# Emerge Changelog

Branch: `emerge`

Range: `main..emerge`

Base: `ab1c078` (`repo image`)

Tip: `ff4c155` (`cleaned up image loading`)

## Summary

`emerge` lands the core gameplay-systems slices and supporting infrastructure for deterministic simulation, high-throughput collision, and app-owned audio. It delivers Slice 12 (simulation contracts, `SimulationFrame`, `RangeOutputStream`, deferred structural changes behind `DataSystem`), Slice 13 (spatial queries and collision contacts via `CollisionSystem` sweep-and-prune and `CollisionResponseSystem`), and Slice 15 (SDL3_mixer `AudioService` + `AudioCommandBuffer` with pause ducking and spatial SFX). ThreadSystem receives extensive adaptive tuning, naming unification, and stability work; a full benchmark suite and `zig build bench` target are added for movement, particles, collision detection, and response. Asset/image loading is cleaned up, the architecture and workflow docs are expanded with the new runtime contracts and processor boundaries, AGENTS.md is updated with audio and thread ownership, Zig best practices and project policy are enforced via build checks and review passes.

## Highlights

- Added `src/game/simulation.zig` with `SimulationFrame`, `SimulationPhase`, `SimulationEvent`, `SimulationIntent`, `CollisionContact`, `CollisionTriggerEvent`, `RangeOutputStream(T)` (count/prefix/write collection), and deterministic range-index merge so processors can emit high-volume transient outputs without per-command atomics or hash maps.
- Added `DataSystem` structural command support (`StructuralCommand`, `applyStructuralCommands`, `StructuralCommitStats`) so deferred entity/component creation, destruction, and component changes are validated and applied only on the main thread after processor phases complete.
- Added `src/game/systems/collision.zig` (`CollisionSystem`, `CollisionConfig`, `CollisionStats`) implementing deterministic sweep-and-prune collision over entities with both movement bodies and collision bounds. It builds 64-byte-aligned AABB proxies, maintains warm sorted order, threads SIMD broadphase anchor ranges into range-owned candidate buffers, runs a separate threaded SIMD narrowphase over candidate pairs, and emits contacts through `SimulationFrame` using the Slice 12 output pattern.
- Added `src/game/systems/collision_response.zig` (`CollisionResponseSystem`) that consumes the completed same-step contact stream, reads explicit `collision_response` components (modes and mobility), computes corrections with `src/core/simd.zig`, emits trigger events, and applies sparse movement writes in deterministic contact order before structural commands commit.
- Added dedicated collision bounds and response-policy columns to `src/game/data_system.zig` (plus `CollisionResponseMode`, `CollisionResponseMobility`, and hot SoA alignment constants) so collision data lives in persistent gameplay storage while transient contact and trigger streams stay in `SimulationFrame`.
- Added `src/app/audio.zig` as the app-owned SDL3_mixer service (`AudioService`, `AudioCommandBuffer`, `AudioBus`, `PlaySfxRequest`, `MusicRequest`, `LoopingSfxId`, owned track pool, loaded-audio cache, bus gains, failed-load memoization). States queue traversal-safe relative paths and parameters during fixed-step updates; `Engine` drains the buffer on the main thread after state dispatch and transitions.
- Integrated audio into the fixed-step flow and demo: music starts looping once, listener position follows the player, and collision triggers emit debounced positional SFX. Pause policy stops active SFX and ducks/resumes music gain.
- Added runtime audio assets under `assets/audio/` (`music/demo_loop.wav`, `sfx/collision.wav`, `sfx/player_jet.wav`) resolved through the same `AssetStore` traversal-safe paths used for images and fonts.
- Added comprehensive audio tests (command validation and caps, load caching, failed-load memoization, music idempotence, pause ducking, spatial positioning) and wired SDL3_mixer through `src/platform/sdl.zig`.
- Reworked `ThreadSystem` across multiple passes (adaptive tuning, naming, stability/solidify, determinism framing): added `AdaptiveWorkTuner`/`AdaptiveWorkProfile`, refined `parallelFor`/`parallelForWithOptions`, per-worker scratch slot indexing, main-thread participation while waiting, `BatchStats`, stricter range alignment, and guarantees that batch execution performs no allocations after init.
- Added the full benchmark suite: `src/benchmarks/{suite.zig,runner.zig,movement.zig,particles.zig,collision.zig,collision_response.zig}`, `src/benchmark_runner.zig`, and the `zig build bench` step. Supports quick/standard/stress profiles, `--case`, `--group`, `--items`, `--iterations`, `--details`, serial-direct vs fixed-worker vs adaptive-tuned-range controls, and produces aligned tables with timing, speedup, throughput, worker usage, and a concise validation summary.
- Updated `build.zig` to build the benchmark executable, include it in `zig build check`, and expose `zig build bench` (with passthrough args). Added `benchBuildOptions` and updated `zig build verify` to run check + test + shaders.
- Expanded `src/game/game_demo_state.zig` to own a `SimulationFrame`, run the ordered processor pipeline (Movement, Particle, Collision, CollisionResponse), apply deferred structural commands, and emit audio commands (player jet, collision SFX) through `UpdateContext`. `pause_state.zig` also participates in audio/pause policy.
- Updated `src/app/engine.zig`, `src/app/state.zig`, and context types to expose `thread_system`, `audio` command buffer, and simulation-relevant services to states while keeping SDL/GPU/audio ownership and structural mutation on the main thread.
- Cleaned up image loading (`src/assets/image.zig`) and refined `src/assets/cache.zig` so PNG decode + texture upload paths are tighter and consistent with the asset root policy.
- Added `src/config.zig` (including `AudioConfig` and thread-system defaults) and expanded `src/core/logging.zig` scopes; updated `src/app/pause_controller.zig`, `src/app/frame_pacer.zig`, and `src/app/input_router.zig` for audio, visibility, and policy interactions.
- Performed a dedicated stability/solidify pass, state leakage fix, unified system ownership and naming, and more specific naming in thread system and benchmarks.
- Updated `AGENTS.md` with explicit ownership for the audio service (`src/app/`) and ThreadSystem, plus reinforced performance rules around SoA columns, cache-line alignment, structural-change boundaries, and hot-path constraints.
- Updated `docs/architecture.md` (source layout for `audio.zig`, `simulation.zig`, `Collision*`, `config.zig`; frame flow audio drain step; simulation/collision processor descriptions) and `docs/development-workflow.md` (new "Benchmarks" section with profiles, adaptive cases, output interpretation, and example invocations; updated command lists and verify guidance).
- Updated `docs/framework-implementation-slices.md` with full Slice 12, 13, and 15 sections (implemented foundations, architecture notes, checklists, acceptance checks, and "landed" summary paragraphs), plus roadmap wording after Slice 13, high-level roadmap updates, and the current Suggested Order through Slice 15.
- Updated `README.md` (SDL3_mixer added to requirements, `zig build bench` added to commands and features list describing threaded/SIMD collision) and performed repo image replacement plus minor doc tweaks in rendering, state-stack, setup, and changelogs.
- Enforced Zig best practices and project policy via a dedicated pass (style, direct imports, ownership boundaries, no broad structural mutation in hot paths, etc.) plus branch review changes that tightened audio, benchmarks, collision response, and several modules.

## Commit List

- `70eb2ad` 1st benchmark pass
- `9519589` Adaptive batch/grain tunning added
- `a8253c5` benchmark and adaptive tunning reviewed and tightened up
- `a3e97dc` adaptive tunning
- `28473e1` thread system and system state tunning
- `a47f38e` unified system ownership and naming
- `4c14974` state leakage fix
- `9e86df1` more specific naming in thread system and benchmarks
- `a712b0d` Architecture update
- `0882bb7` simulation determinism frame put in places
- `ca8a9db` stablize review pass
- `132052b` replaceing repo img. it was deleted somehow
- `fbcf7bd` dedicated stabiity and solidify pass
- `7c463e5` collision system added
- `5b069df` roadmap updates
- `f3c153a` collison response and collision triggers added as well.
- `46e7a82` updated the roadmap slice wording after slice 13 complete
- `e05634b` roadmap high level update
- `1bdd7fa` benchmark output rework. much cleaner
- `3bb00b3` updated git ignore
- `05b6d06` fixed threading adaptive algorithim -- maybe
- `3e7836f` SDL3 Mixer added and some basic audio tones are working.
- `f282499` player jet update and SDL Mixer review fixes
- `ff4c155` cleaned up image loading
