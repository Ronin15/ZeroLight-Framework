# AI Update 2 Changelog

Branch: `ai_update2`

Range: `main..ai_update2`

Base: `5908f05` (`Clarify framework's approach to game development`)

Tip: `230d30f` (`branch review and edits made`)

## Summary

`ai_update2` continues the emergent-AI track after `ai_update`: it lands
data-driven AI archetypes and debug introspection (Slice 33), expands the world
sensory bus beyond dig-only hearing (Slice 39), adds a typed action/interaction
intent substrate (Slice 40), durable world interest / affordance markers for
investigate goals (Slice 41), and the first real action-intent consumer —
pipeline-owned destructibles (Slice 45). Alongside those slices the branch
ships first-class gamepad input, a multi-pass Zig hygiene and standards true-up,
a movement/adaptive-tuner rewrite that treats Z as a discrete vertical plane
(not continuous movement), substantial steering and separation optimizations,
pipeline stage-order hardening for multi-level worlds, and dual-harness agent
tooling for Grok Build and Cursor.

The closing commit (`230d30f`) is a multi-agent review-and-fix pass over the
full branch: continuous AI memory last-known tracking, familiarity growth,
sticky archetype authoring, ReleaseFast-safe dig tile guards, same-level
steering avoidance, plane-traversal attach preflight, SIMD chunk derive, GPU
tile-edit staging order, gamepad hot-plug completeness, jet-loop pause/resume
audio edges, and a batch of FailingAllocator / dual-assert / causal tests so
the new contracts stay proven under `ReleaseFast`.

Durable direction is unchanged: persistent gameplay facts live in `DataSystem`,
per-step communication uses typed `SimulationFrame` streams and events, domain
controllers own dig / audio / destructible reactions through the pipeline,
hot processors stay dense SoA with serial/threaded parity, fixed work budgets
never scale with world size, and allocation-free claims carry
`FailingAllocator` proofs rather than comments.

## Highlights

- Landed **Slice 33** — data-driven AI archetypes (`assets/ai/archetypes.json`
  + `ai_archetypes.zig`) and a read-only AI debug overlay
  (`ai_debug_overlay.zig`) under the existing F2 / gamepad-Back toggle.
- Landed **Slice 39** — multi-producer sensory stimuli (dig, footstep, deferred
  collision impact) with fixed capacities and hearing ranking in perception.
- Landed **Slice 40** — parallel `action_intents` stream (`ActionKind` /
  `ActionIntent`), player R / left-shoulder rising-edge interact capture,
  contract-only `action_intent_capture` + real `action_react` consumer stage.
- Landed **Slice 41** — `world_interest.zig` markers embedded on `WorldSystem`
  (not `DataSystem`); investigate goals use stimulus → marker → ring priority.
- Landed **Slice 45** — `Destructible` component + pipeline-owned
  `DestructibleController` consuming interact/attack into deferred structural
  destroys, domain events, and local nav reaction via `entity_destroyed`.
- Added **gamepad** support (`gamepad.zig`, input router policy, pause/menu
  bindings) with single-pad first-connected-wins ownership and disconnect
  release of held gameplay.
- Removed continuous Z from movement integration: Z is a **vertical level
  indicator**; plane traversal and `world_level` own multi-floor pose.
- Reworked the **adaptive work tuner** and full-range movement path (dormant
  rows rely on zeroed velocity; chunk derive is a separate late stage).
- Hardened `SimulationPipeline` stage contracts: collision after pose writers,
  plane traversal after bounds/tile gate, late `deriveChunks` after pose settle,
  richer `stageContract` freshness (including `world_tiles` / movement poses).
- Broad **steering** work: event-driven static obstacles, movement-index cache,
  separation/candidate caps, multi-level path `start_level` from scope.
- **Agent tooling**: Grok Build under `.grok/` (agents, multi-phase skills,
  module presets) and Cursor under `.cursor/`; shared contract in
  `Agents.md` / `AGENTS.md` / `CLAUDE.md`.
- **`tools/lint_idioms.py`** + `zig build idiom-lint` gate (naming, NaN idiom,
  EntityId equality, `catch unreachable` allow with reason).
- LTO build options, test stderr suppress, roadmap archive cleanup for settled
  slices 39–41 and 45 (33 remains frontier pending live visual/`gpu-smoke`
  confirmation).
- Closing multi-agent **branch review fix pass** (`230d30f`) — see
  "Branch Review Fixes" below; parent `zig build verify` green after integrate.

## Slice 33: Data-Driven AI Archetypes And Debug Introspection

- `src/game/ai_archetypes.zig` loads strict JSON at asset/loading time into a
  fixed catalog of prevalidated component bundles (faction, perception, memory,
  affect baselines, behavior gains, sticky fields).
- Demo spawns resolve named archetypes (`timid`, `curious`, `aggressive`,
  `cohesive`, etc.) instead of hardcoded `demoArchetypeForIndex` literals;
  loader parity tests assert field-for-field match to the deleted bundles.
- `src/game/ai_debug_overlay.zig` gathers const DataSystem slices only: vision
  cone/range, emotion bars, last-known memory, active behavior, fixed annotated
  agent budget — no sim mutation, no hot-path JSON.
- Authoring remains load-time only; fixed-step update stays enum/scalar.

## Slice 39: Sensory Stimulus Ecosystem

- Extended `WorldStimulus.kind` with `.dig`, `.footstep`, `.impact`.
- Same-step producers before perception: dig controller, player footstep (when
  velocity is non-trivial), plus promotion of prior-step deferred impacts.
- Deferred producer: after collision response, player-involving contacts enqueue
  `.impact` for the next step start (fixed deferred capacity).
- Perception ranks hearing with fixed falloff; capacities and drop policy live
  in `simulation.zig` and are demo-warmed — not map-scaled.
- Cognition does not depend on `AudioController` for stimulus emission.

## Slice 40: Action And Interaction Intent Substrate

- `ActionKind` / `ActionIntent` and
  `action_intents: RangeOutputStream(ActionIntent)` on `SimulationFrame`.
- Movement `SimulationIntent` stays movement-only (no dual-write / no action
  union arm on the locomotion stream).
- Fixed `action_intent_live_capacity` (64); dual-axis reserve like stimuli.
- Player **R** / **left shoulder** rising-edge → `.interact` via
  `captureActionIntent` (latch advances only on successful append).
- Pipeline: capture is wall-clock before `update` (contract stage in
  `stage_order`); `action_react` is the merge/consume point for controllers.
- AI action emission remains an explicit future expansion (not half-wired).

## Slice 41: World Interest And Affordance Markers

- New `src/game/world_interest.zig` embedded on `WorldSystem` as
  `interest_markers` — generational IDs, fixed inline capacity (128), level +
  faction gating, alloc-free query by construction.
- Investigate scoring priority: heard stimulus → nearest marker → memory ring.
- Demo places surface investigate markers; pipeline passes the store read-only
  into AI config. Null store preserves pre-41 behavior.

## Slice 45: Destructible Domain Controller

- `Component.destructible` + dense store (`hit_points`, interact/attack destroy
  flags); structural `set_destructible` / template / capacity projection.
- Pipeline-owned `DestructibleController` at `action_react`:
  - Resolves interact/attack to entity target or cell-local scan (level-aware).
  - Same-step multi-hit HP netting; one deferred destroy or HP write per entity.
  - Preflights structural + event capacity; emits `destructible_destroyed` then
    commit-time `entity_destroyed` for local nav remask of static obstacles.
  - Optional soft particle burst; no SDL/audio handles on the controller.
- Demo crates marked destructible; fixed event/structural headroom from action
  capacity (not world-scaled).

## Gamepad And Input Stack

- New `src/app/gamepad.zig`: single active pad, first-connected-wins, disconnect
  → `releaseGamepadInput`, engine delivery gate before menu `handleEvent`.
- `input.zig` / `input_router.zig`: shared `routeAction` for keyboard and
  gamepad; held gameplay UP under modal/opaque (dig-trap fix); axis gated on
  gameplay; `releaseHeldGameplay` clears dig/move/stick/interact.
- Pause policy targets the gameplay entry under overlays; menus do not steal
  pause incorrectly; OOM enter paths avoid partial pause side effects.
- Docs (`state-stack-and-input.md`) document bindings including Left Shoulder →
  interact and pause/resume gamepad South/Start/East.

## Movement, Scope, And Multi-Level Pose

- Continuous `previous_z` / z-integration removed from movement: integrate x/y
  only; discrete plane via `position_z` / `world_level` / plane traversal.
- Movement can run full dense SoA with dormant rows kept at zero velocity
  (`setSimulationTier` contract); chunk coordinates derived late after pose
  settle (`deriveChunks`), so early gathers intentionally use prior-step chunks.
- Collision same-level gating on gather + broadphase (SIMD and scalar).
- Plane-traversal batching: preflight capacity and (after review) pre-attach
  missing `world_level` rows before any world carve; single
  `publishWorldTileChanges` after successful batch.

## Steering, Separation, And Spatial Index

- Steering setup: event-driven static obstacle spatial, `steering_movement_index`
  cache with post-commit invalidation, fixed neighbor/candidate check budgets.
- Separation and AI intent stages keep sequential order with disjoint dense
  writes and dual worker range asserts.
- `DenseCellLookup` is camera-relative dense-window occupancy (from prior AI
  track); this branch hardens re-`reserve` so a second call does not append a
  second grid.

## Pathfinding And Dig

- Nav invalidation classification + post-commit reaction remain owned by
  `PathfindingSystem` (not the demo state).
- `world_obstacle_changed` O(1) dirty via `markNavTileRectDirty`; entity
  destroy/component-changed obstacle rects carry **level** after review (full
  `markStaticBodies` rasterize remains level-0 for static entity bodies today).
- Dig: event/stimulus preflight before mutate; level-link capacity before ramp
  tile; shared `facedCellForEntity` for dig and interact; unresolved dig tiles
  return `error.UnresolvedDigTiles` (not assert-only) so ReleaseFast cannot
  write `invalid_tile_id` as a carve.

## Simulation Pipeline Hardening

- Richer `stageContract` / `stage_order`: pose writers (movement, collision
  response, bounds/tile gate, plane) ordered so `chunk_derive` sees settled pose;
  `action_react` then `tier_policy` as multi-producer structural append stages.
- Comptime freshness for derived `chunk_columns` vs `movement_positions`.
- Causal tests for collision push across chunk boundary → scope chunks, multi-
  fall plane batch ranges, reserved multi-fall FailingAllocator proofs.
- Scope banner and `docs/simulation-tiers-and-pipeline.md` document one-step
  chunk lag and late-stage order including `action_react`.

## Rendering, Text, And GPU Lifetime

- GPU remediation track on this branch: idle-before-free/grow for tile-edit
  transfers and texture replace; non-destructive `SpriteBatch.reserveStorage`;
  `buildSerial` returns errors instead of `catch unreachable` on recoverable OOM.
- Tile-edit values stage into the transfer pool **before** acquire (same order
  as dynamic verts); post-acquire only records copy-pass uploads.
- Sprite prep workers assert `range.index < range_count` plus write spans.
- FPS counter prepares fixed digit glyphs; deinit retires them via TextService
  (idle once when live) so overlay teardown does not leak retain counts until
  service force-free.
- Atlas meta common validation (grid product overflow, duplicate names/ids).

## Tooling, Build, And Agent Harness

- `tools/lint_idioms.py` + `zig build idiom-lint` in verify: snake_case fields,
  camelCase callables, no NaN self-compare, `EntityId.eql`, no noop catch,
  `catch unreachable` only with `// lint:allow catch-unreachable: <reason>`.
- LTO options in `build.zig` (Mach-O full LTO skipped where inappropriate).
- Test stderr suppress for cleaner suite output.
- Grok-native specialists and multi-phase skills under `.grok/`; Cursor agents
  and rules under `.cursor/`; root `Agents.md` / `AGENTS.md` / `CLAUDE.md` share
  ownership, hot-path, and bench≠test rules without requiring one tree to load
  the other.
- Roadmap: slices 39–41 and 45 archived; Slice 33 remains frontier pending
  live visual confirmation of archetype differentiation / F2 overlay.

## Branch Review Fixes (`230d30f`)

Multi-agent review of `main..ai_update2` then parallel implement units;
orchestrator ran `zig build fmt`, `check`, `test`, and `verify`.

### High

- **AI memory last-known refresh:** while the same threat stays visible, memory
  copies continuous `last_seen_*` into `last_known_*` and holds staleness at 0;
  on `entity_lost`, snapshot last seen so pursue/flee memory goals match the
  end of a chase, not first acquisition. Multi-step test added.

### Medium (gameplay / contracts)

- Familiarity **gains** under sustained same-identity visibility (was decay-only
  → perpetual max curiosity novelty for memory agents).
- Shipped archetypes author non-zero `commitment_max_steps` / `sticky_bonus`
  (sticky hysteresis was dead at defaults of 0).
- Invalid pursue/flee goal write-back sets `active_behavior = .wander` so affect
  fatigue and debug overlay match actual locomotion.
- Steering local avoidance **same-level gate** (mirrors collision); agent–agent
  only — static obstacle snapshot remains pure XY residual.
- Dig unresolved tiles: real `error.UnresolvedDigTiles` before mutate.
- Plane traversal: preflight `world_level` attach for all cell-entry candidates
  before any carve; multi-fall reserved FA proof.
- Nav structural events stamp **level**; pathfinding dirty marks use it.
- Destructible cell resolve uses fixed scan budget (256) with deterministic
  degrade; invalid cell sentinel instead of (0,0); DataSystem dense compact test.
- Gamepad fallback walks **all** available ids (not only first open attempt).
- Jet loop: stop SFX before unduck on pause/resume; keep
  `jet_loop_stop_pending` until stop succeeds.
- Tile-edit GPU staging pre-acquire; sprite-prep dual-assert; FPS glyph deinit.

### Medium / low (proofs, docs, polish)

- SIMD `deriveChunks` via `worldPosToCell4` + scalar tail; serial/threaded parity.
- Causal pipeline test: collision moves body across chunk → scope matches pose.
- Collision-response solid-intent FailingAllocator success path (was trigger-only).
- `DenseCellLookup.reserve` re-entrancy + test.
- Path request `start_level` regression drives real multi-level emission path.
- Docs: late-stage `chunk_derive` → `action_react` → `tier_policy`; gamepad
  interact binding; pause copy mentions gamepad.
- Lint: bare `lint:allow catch-unreachable` rejected without reason.

### Known residuals after review

- Static obstacle steering not level-gated; multi-level static entity full
  remask (`markStaticBodies`) still level-0-centric.
- Destructible cell scan budget is fixed degrade, not a spatial index.
- Text cache still has no hard entry ceiling (caller discipline).
- Slice 33 live on-screen/`gpu-smoke` visual acceptance still pending.

## Commit List

- `09d665b` initial gamepad support
- `92638e0` roadmap/guidance sync
- `4a4db07` slice 33 implemented
- `dd90995` 1 round of zig code hygiene done
- `9619170` round 2 Zig hygiene trueup
- `90d7349` more cleanup
- `dc60162` deeper review
- `48d8b45` round 2 review
- `617515b` workflow update
- `d5082b1` updated cursor tooling
- `11a5506` deeper review and fixes
- `382e2ae` affect perf tweak after review
- `ee3d7c1` re-worked broken Adaptive tuner, and movement system
- `1c27ed0` removed z level coords from movement systems; Z is vertical level
- `a7094a5` grok 4.5 entire codebase review and fixes
- `622d895` updated agents.md for grok/cursor split
- `d2dcd76` grok fixes and optimizations; ReleaseSafe debug console dumps only
- `d54ad10` more optimizations and logging for steering and separation work
- `0837009` steering optimizations
- `068b3c8` grok tooling re-work
- `f866726` agents md update for grok
- `f9ab67c` more tooling edits
- `10b17d0` test std err suppress for tests
- `9515904` lto build options added
- `b9161f6` Merge branch `ai_update2` of origin into `ai_update2`
- `d56c552` slice 39 Implemented and reviewed
- `fa985f1` Slice 41: World Interest And Affordance Markers reviewed and completed
- `f92ee9d` cleaned up roadmap and archive docs
- `f1e8769` slice 40 implemented/reviewed and committed
- `e1af4ea` comprehensive cohesion and correctness review after larger review fixes
- `d7a176f` branch update and review/direction consolidation
- `5c0d28b` slice 45 implemented and reviewed
- `230d30f` branch review and edits made
