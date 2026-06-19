# Extend Changelog

Branch: `extend`

Range: `main..extend`

Base: `e6bec53` (`Merge pull request #4 from Ronin15/emerge`)

Tip: `5fe85c4` (`final architecture planning updates updated in guding files and docs.`)

## Summary

`extend` moves ZeroLight from a gameplay-systems foundation into a broader
runnable game-framework base. The branch adds the first AI decision processor,
frame-delayed grid pathfinding, steering and local avoidance, a main-menu and
settings flow, startup runtime asset IDs, stronger audio/text ownership, Windows
SDL/DXIL build support, and benchmark visibility for the new CPU systems.

The branch keeps the core direction consistent: gameplay facts stay in
`DataSystem`, per-step communication stays in typed `SimulationFrame` streams,
SDL/GPU/audio resources stay behind app/render/asset services, and hot gameplay
processors work over dense SoA slices with deterministic merge points.

## Highlights

- Added Slice 14 AI intent processing with `AiAgent` component data,
  deterministic navigation-intent output through `SimulationFrame`, local
  separation, and separate adaptive tuning for separation and intent emission.
- Reworked AI separation around a transient spatial grid with bounded neighbor
  sampling, independent separation/intent adaptive tuning, and explicit future
  guidance for staged scalable perception, pathfinding, and rule processors.
- Added Slice 18 frame-delayed pathfinding with typed path requests, completed
  result views, request/result caches, unavailable-path caching, connected
  component rejection, shared goal fields, portal detours, and bounded fallback
  solving.
- Added Slice 19 steering and local avoidance above pathfinding, including
  waypoint following, local agent/obstacle avoidance, stuck detection, replan
  cooldowns, unavailable-path backoff, and deterministic final NPC movement
  intents.
- Added Slice 16 main-menu and settings states using the existing state stack,
  named UI actions, text service, logical renderer drawing, and fixed-step audio
  command buffer for live gain changes.
- Made the main menu the default startup state and launched gameplay through
  state transitions instead of booting directly into `GameDemoState`.
- Added Slice 17 startup runtime asset catalog with stable `SpriteAssetId` and
  `AudioAssetId` values, manifest-declared demo assets, sprite preload through
  `AssetCache`, and audio preload through `AudioService`.
- Changed gameplay/render/audio paths to resolve stable asset IDs through
  `RuntimeAssets` instead of doing string path lookup or carrying live renderer
  or mixer handles through `DataSystem`.
- Preserved primitive sprite fallback for unavailable declared sprites and
  tightened missing-asset behavior so missing content is recorded without
  aborting startup while fatal preload errors roll back retained resources.
- Reworked audio commands to target preloaded audio IDs, preserving bounded
  fixed-step command buffers while moving path validation and loading into the
  startup/catalog path.
- Simplified text use around app-lifetime prepared text instead of caller-owned
  text leases, matching menu/debug UI usage and reducing per-state lifetime
  hazards.
- Added Windows build support through pinned SDL3/SDL3_ttf/SDL3_mixer packages,
  optional system/custom SDL paths, DXIL shader generation, and DLL installation
  for runnable/package outputs.
- Updated benchmarks and workflow guidance for AI workloads, multi-stage
  adaptive tuning, pathfinding, steering, and the collision
  broadphase/narrowphase reporting contract.
- Refreshed README, architecture, state/input, rendering/assets/shaders, setup,
  workflow, and roadmap docs to match the current project behavior and durable
  ownership boundaries.

## Gameplay Systems

### AI Intent Processing

Slice 14 now exists as a concrete first AI processor rather than a broad future
bucket. `DataSystem` owns dense `AiAgent` rows and membership masks. `AiSystem`
gathers AI and movement slices, builds a deterministic spatial grid, computes
bounded local separation samples, and emits navigation intents through
`SimulationFrame`.

The processor is staged so separation work and intent-emission work each have
their own adaptive tuning path. The gameplay state runs AI after player input
and before movement integration, keeping player input direct while non-player
intent remains data-driven.

Coverage added in this area includes deterministic output tests, serial versus
threaded consistency checks, bounded separation sampling, and AI benchmark cases
with visible candidate/intention counters.

### Frame-Delayed Pathfinding

Slice 18 adds `PathfindingSystem` as state-owned gameplay infrastructure. AI and
future rule systems can emit typed `PathRequest` records into `SimulationFrame`
without blocking current-step movement on a fresh solve. The pathfinder merges
requests deterministically, solves them through cached and fast-path routes where
possible, and exposes later-step path status through stable views.

The pathfinder owns navigation-grid state, request queues, result caches,
unavailable-path cache entries, connected components, portals, goal fields,
fixed scratch, and adaptive tuners. None of that solver state is stored in
`DataSystem`.

Common requests avoid heap A* through cache hits, unavailable-key caching,
request dedupe, pending dedupe, open-grid direct paths, disconnected-component
rejection, line-of-sight paths, shared goal fields, and portal detours. Hard
fallback A* remains scalar and bounded, with roadmap follow-up work calling out
true hard-path fixtures, solve budgets, and cache aging.

### Steering And Local Avoidance

Slice 19 adds `SteeringSystem` above AI and pathfinding. AI now emits
`NavigationIntent` goals; steering selects the active intent per agent, consumes
pathfinding status, requests paths when needed, follows available waypoints, and
emits the final NPC `MovementIntent` stream.

Steering keeps runtime rows, waypoint progress, stuck/replan counters, local
avoidance scratch, and cooldown/backoff policy outside persistent component
storage. Persistent tuning values such as radius, speed, avoidance radius,
avoidance weight, waypoint tolerance, stuck distance, and sample limits live in
dense `SteeringAgent` component storage.

The system includes bounded agent and obstacle candidate checks, deterministic
priority arbitration, no per-frame unavailable-path request loops, serial and
threaded update paths, and steering-specific benchmarks that report avoidance
checks, samples, emitted intents, and worker/range detail.

### Collision And Threading Hardening

Collision detection was refactored around clearer broadphase and narrowphase
stages. Sweep-and-prune broadphase emits deterministic candidate pairs, while a
separate narrowphase computes contact math over candidate pairs and merges
range-owned contact buffers for same-step response.

Broadphase and narrowphase now keep separate adaptive tuners and batch stats.
The thread system no longer uses a static minimum item count to block worker
participation; structural constraints and measured batch timing decide whether
work stays inline or uses worker threads.

The dense 50k collision validation work recorded strong ReleaseFast performance
while preserving the important benchmark signal: candidate pairs, contacts,
stage-specific worker/range detail, and response outputs remain visible instead
of being hidden behind aggregate timing.

## Runtime App Flow

### Main Menu

The app now boots into `MainMenuState` instead of going straight to the demo
state. The menu is an opaque state with three actions: start gameplay, open
settings, and quit. It uses the normal state vtable, state transitions, named
input actions, prepared text, logical-space rendering, and shared menu drawing
helpers.

Selection wraps, Enter/Space activates, Escape quits from the root menu, and
launching gameplay uses a normal state replacement path. This gives the project
a usable first screen without introducing a separate UI framework or bypassing
the state stack.

### Settings Menu

`SettingsMenuState` is a modal overlay for runtime audio controls. It exposes
master, SFX, and music volume rows plus Back. Left/right changes queue audio gain
commands during update, labels update from the current values, and Back/Escape
pops the modal state.

Runtime audio settings are owned by the main menu so they persist across
settings reopen and into launched gameplay. Tests cover selection wrapping,
named input action routing, volume clamping, emitted gain commands, command
failure consistency, and pop transitions.

### Pause Policy

Pause handling is now explicitly gated on an active gameplay-policy state. User
pause and window-policy pause no-op while an opaque menu or non-gameplay modal is
on top, so the pause overlay and gameplay `onPause`/`onResume` callbacks are not
misapplied to menu states.

`StateStack` tracks gameplay state policy separately from event/render routing,
and pause/resume targets the gameplay recipient rather than blindly notifying
the top state. Tests cover non-gameplay pause no-ops, policy pause gating,
overlay behavior, stale-handle cleanup, and consumed events suppressing fallback
frame-command routing.

## Runtime Assets, Audio, And Text

### Startup Runtime Asset Catalog

Slice 17 adds `src/assets/manifest.zig` and `src/assets/runtime_assets.zig`.
The manifest declares stable sprite and audio IDs, paths, dimensions, audio kind,
and predecode policy. `Engine` preloads that manifest at startup and exposes the
loaded catalog through render contexts and audio commands.

Gameplay stores stable sprite/audio IDs rather than string paths, `TextureId`,
`TextureLease`, prepared sprite records, SDL_mixer handles, or loaded audio
handles. Rendering resolves sprite IDs through `RuntimeAssets`, with primitive
fallback when a declared sprite is unavailable. Audio commands drain by
preloaded `AudioAssetId`.

Missing declared content logs once and marks the asset unavailable. Invalid
paths, allocation failures, and service initialization failures still propagate
as real startup errors. Partial preload rolls back retained resources so failed
startup does not leak renderer/cache ownership.

### Texture Lease Safety

The runtime asset cleanup path releases sprite leases through the live
`AssetCache` and renderer owner rather than through copied/self-owned lease
pointers. Tests cover duplicate sprite preload rejection, missing sprite
availability, partial preload rollback, and exact-once release behavior.

### Audio IDs

`AudioCommandBuffer` now stores stable audio asset IDs instead of copying and
validating paths per command. `AudioService` preloads audio IDs, records
available/unavailable slots, checks expected audio kind at playback, tracks
current music by `AudioAssetId`, and keeps failed path memoization inside the
loading path.

The disabled audio backend context is now stable even if the service value is
moved, and tests cover command value clamping, command caps, disabled backend
move safety, preload/missing behavior, music idempotence, spatial SFX, frequency
ratios, gain controls, and invalid kind checks.

### Prepared Text

The text service was simplified from caller-retained text leases to
app-lifetime cached `PreparedText` values. UI states prepare text when content or
style changes, then draw the prepared texture through `drawPreparedText` with
top-left or top-center anchoring.

This matches the menu/debug-overlay usage model: text rendering remains
synchronous on cache misses, cached for reuse, and intentionally avoided as a
per-frame hot-path operation.

## Build And Platform Support

### Windows SDL Packages

Windows now defaults to pinned SDL3, SDL3_ttf, and SDL3_mixer packages declared
in `build.zig.zon`. The build can validate/fetch them through `zig build
fetch-sdl`, use global SDL installs with `-Dsystem-sdl=true`, or use custom
extracted SDL archives through `-Dsdl-root=<path>`.

Runnable and packaged Windows outputs install the required SDL DLLs beside the
executable. The build also validates expected package headers, import libraries,
and DLL paths so incomplete package layouts fail early with actionable guidance.

### DXIL Shader Output

The shader pipeline now supports Windows DXIL. Linux still installs SPIR-V,
macOS still installs MSL through `spirv-cross`, and Windows converts GLSL to
SPIR-V, SPIR-V to HLSL, and HLSL to DXIL through `dxc`.

Runtime shader format selection remains SDL-driven. Generated runtime shader
files install under the runtime asset tree, while source shader files and
build-only intermediate formats are excluded from normal runtime asset install.

### Packaging And Asset Install

`zig build`, `run`, `dev`, `package`, `verify`, and `gpu-smoke` now consistently
include generated shaders and runtime assets where needed. `package` installs
selected-mode binaries and runtime assets, and the workflow docs now explain
asset-root behavior, compiler override options, Windows SDL fetch behavior, and
platform shader requirements.

## Benchmarks And Validation Surfaces

The benchmark suite now covers movement, particles, AI, steering, collision
detection, collision response, pathfinding, pathfinding cache profiles, and hard
fallback pathfinding profiles. The CLI supports group filters, item filters,
case filters, profile selection, and detail output.

Detail tables expose scheduler and workload information: worker use, active and
available workers, range size, main-thread ranges, wait time, candidate pairs,
contacts, cache hits, fallback requests, avoidance checks, samples, emitted
intents, and stage-specific tuning where a workload has multiple independently
timed stages.

Adaptive benchmark rows run after serial and fixed-worker controls so the output
can call attention to failed tuning, skipped worker cases, or regressions against
explicit baselines. The docs emphasize that the benchmark suite is a regression
detector and diagnostic surface, not a hidden runtime policy source.

## Data And Simulation Contracts

`DataSystem` now includes dense aligned stores for AI and steering components in
addition to movement, collision, particle, and render-facing data. Structural
commands can set or update AI and steering components, with validation for
finite values, non-negative weights, radius bounds, sample limits, and component
consistency.

`SimulationFrame` now carries specialized typed streams for movement intents,
navigation intents, path requests, collision triggers, and deferred structural
commands. The roadmap explicitly preserves these high-volume streams instead of
collapsing everything into a generic event bus.

Future domain communication is mapped toward a typed simulation event layer
owned by a state or state-owned simulation pipeline. The docs are explicit that
future events should carry stable IDs and value payloads, not pointers, app,
render, audio, allocator, asset-path, or service references.

## Documentation

Project documentation was updated to describe the branch's current behavior:

- `README.md` now presents the project as ZeroLight Framework with current
  feature coverage, Windows requirements, updated commands, and the current
  source layout.
- `docs/setup.md` documents macOS, Linux, and Windows dependencies, including
  pinned Windows SDL packages and shader compiler needs.
- `docs/development-workflow.md` documents build/package behavior, release
  modes, asset root behavior, shader commands, Windows fetch behavior,
  benchmark usage, detail-table interpretation, and GPU smoke expectations.
- `docs/architecture.md` now reflects the main menu startup, runtime asset
  catalog, current gameplay processor order, and future pipeline/event
  direction.
- `docs/state-stack-and-input.md` now reflects gameplay policy, menu/modal
  input routing, consumed event behavior, and pause policy.
- `docs/rendering-assets-shaders.md` now reflects stable runtime asset IDs,
  prepared text, Windows DXIL shaders, and installed runtime asset layout.
- `docs/framework-implementation-slices.md` records completed slices 14, 16, 17,
  18, and 19, adds hardening Slice 20, and adds typed simulation event Slice 21.

## Validation Recorded In Branch Docs

The branch docs record successful validation for the major completed slices,
including:

- `zig build fmt`
- `zig build test`
- `zig build test --summary all`
- `zig build check`
- `zig build verify`
- `zig build bench -- --profile quick --group steering --details`
- pathfinding Debug and ReleaseFast benchmark checks for open, detour, and
  unreachable fixtures
- manual `zig build dev` smoke covering menu navigation, settings, gameplay,
  sprite rendering, audio, pause, debug overlay, and repeated transitions

## Follow-Up Work Left Explicit

`extend` finishes substantial runtime and gameplay foundation work, but it also
leaves several intentionally visible follow-ups:

- Slice 7 parallel CPU render prep remains incomplete until serial and parallel
  prep prove identical draw order, grouping, and invalid-resource behavior.
- Navigation hardening needs true-A*-required fixtures, per-frame fallback solve
  budgets, cache/goal-field aging or capacity policy, and hard-path regression
  thresholds.
- A typed simulation event layer should land before broad tile, weather,
  obstacle, perception, combat, spawning, resource, or rule-system interactions
  depend on cross-system communication.
- Renderer batch capacity, text-cache lifetime policy, collision-response
  merge/apply behavior, and manual registry guardrails remain hardening tracks.
- Shader/material metadata still has some parallel registries and should
  eventually consolidate when more pipelines exist.

## Commit List

- `2fe1d72` implemented slice 14 -- needs review and AI needs threaded re-vamp
- `e10ec8f` implemented slice 16 main menu and settings states and basic ui structureing
- `5fad1ca` pause can only be entered during gameplay
- `b0de1d6` branch review changes
- `a0f011e` collision refactor and multple thread system tuners
- `cb36961` thread system algo cleanup
- `1d52e3f` more thread system tunning
- `8f219c7` final thread system tunning tweak and doc bench update for dual tunners
- `68244d3` thread system and collision system review fixes. Strong 50k dense perf at mean 3.77ms
- `9ffeb95` roadmap 17 slice updated content loading
- `fd6e5f2` slice 17 implemented and texture release segfault fixed
- `6daf484` text service cleanup
- `dbbf550` text service clean up
- `5d28483` review fixes
- `a206b2d` docs update
- `db9b7b8` fixed a unit test failure as expected, for missing sprites
- `f0bf703` docs, skills, and steering guidance updated for current state of the project
- `8051567` review fixes and AI system refactor for multi-stage tunning and a spatial neibour check
- `13c95ec` Benchmark numbers conistentcy
- `f74ca0e` skill and doc review for durable guidance
- `9e24011` removing showcase img
- `3b616d3` Pathfinder implemented and AI system adapted to use it
- `b7333e8` removed hard min items for threading as it defeats the adaptive idea behind the thread system
- `1daea5a` updated bench metrics history
- `e812893` Windows support added!
- `c4a9f03` steering system added
- `270eae9` updated docs and main readme
- `233de47` updated architecture doc with current game loop order.
- `8dd7230` updated project architecture data
- `259f9fd` updated design skill with the go forward architecutre enforcement
- `5fe85c4` final architecture planning updates updated in guding files and docs.
