# AI Update 3 Changelog

Branch: `ai_update3`

Range: `main..ai_update3`

Base: `b39a46f` (`Merge pull request #10 from Ronin15/ai_update2`)

Tip: the README commit `3d95821` plus this changelog commit

## Summary

`ai_update3` finishes the post-`ai_update2` cleanup slices, moves the toolchain
to Zig 0.17, and then shifts focus from new gameplay features to making the
engine scale correctly:

- **Capacity:** a best-practice capacity model replaces fixed sizes. Each world
  instance is right-sized at load, and runtime-growing stores grow only at the
  structural-commit seam.
- **Determinism:** simulation scope no longer depends on the render camera.
- **Pathfinding:** runtime ramps become routable in the same step.
- **Nav edge storage:** rebuilt so dense, destructive terrain can never be
  refused.

The roadmap was split into one file per slice. It gained the VoidLight feature
port plan (Slices 49–72) and an explicit three-way rule for budgets, capacities
and thresholds.

These contracts are unchanged:

- persistent data lives in `DataSystem`;
- per-step communication uses typed `SimulationFrame` streams;
- hot processors stay dense SoA, and their serial and threaded paths give
  identical results;
- per-step work budgets are fixed counts;
- allocation-free claims carry `FailingAllocator` proofs.

## Highlights

- **Zig 0.17.** The build and sources are upgraded, Windows ReleaseFast LTO is
  disabled to fix a link failure, and the upgrade has its own changelog
  ([zig_0_17_upgrade.md](zig_0_17_upgrade.md)).
- **Slices 37, 47 and 48 landed and archived:**
  - the dense render-window cap with shader/host sync;
  - un-staggered shared sensing;
  - the `SimulationPipeline` thin-composer restoration (intents, the tile gate
    and plane traversal moved out of the pipeline, and fixed event budgets).
- **Simulation scope decoupled from rendering (Slice 49 part).** Scope follows
  a fixed-step `sim_view` taken from the previous step's camera. It is a
  required field and never reads the interpolated render window.
- **Runtime ramps are routable the same step (Slice 64E).**
  - Runtime level links fold into the nav abstract tier, with 8 fixed interior
    link slots per chunk, both-level dirtying, and a per-step link budget with
    deterministic deferral.
  - Incremental patches match a full rebuild.
  - Nav dirty buffers and level links grow at the dig commit seam.
- **Nav edge storage simplified (Slice 64F).**
  - Edge windows are per level, and a level is repacked when a window
    overflows. The edge arena is runtime-growing data that is never refused;
    the only fixed cap is the u32 edge index, checked at load.
  - Holes, compaction, relocation and the refusal ceiling are deleted.
  - Effect: about 450 fewer lines in `nav_graph.zig`, and demo nav-edge memory
    down 34%.
- **Live capacity sizing pass (Slice 72, Batches A, B, C1–C7, I1, I2).**
  - One population growth seam (`syncPopulationCapacity`) and one exhaustive
    per-step event bound.
  - Per-range threaded outputs that never warm inside a stage.
  - Collision pair bounds, and `drawSprite` growth instead of a frame failure.
  - Perception and affect events derived from per-row columns, which removes
    about 3.2 MB of reserved scratch at 2k agents.
- **Steering and group fields (Slice 71B.1).** Static-obstacle avoidance is
  gated by world level, the group-field threshold is a fixed constant, and the
  agent ceiling is sized from content.
- **Branch review remediation.** Factionless agents no longer pass
  faction-restricted markers. The pipeline owns its structural event share.
  The dig admission seam is private again. Sprite drift accounting is compiled
  out of shipping builds.

## Simulation Pipeline And Capacity

- `syncPopulationCapacity` grows population-sized stores at the main-thread
  structural-commit seam, geometrically and ahead of need. Multi-worker
  `FailingAllocator` proofs cover the first post-growth step and a partition
  retune.
- One owner (`eventCapacitySum`) bounds per-step events. The structural commit
  runs through `StructuralCommitBudget`, an all-or-fail preflight before any
  mutation. Pipeline-stage structural commands count in
  `pipeline_structural_event_share`; a caller's `structural_headroom` covers
  only that caller's own commands.
- Threaded outputs (scope, spatial index, collision, perception, affect) are
  reserved for every partition the tuner can pick. Thread-shared records follow
  one 64-byte alignment policy.
- Behavior gates compare stored logical limits, never `.capacity`.

## AI, Perception, And Steering

- Perception transitions and affect threshold crossings are now emitted by the
  main thread after the join, in row order, from per-row columns. The per-range
  event slots and affect's sort are gone, and threaded output is byte-identical
  to serial.
- Steering ignores obstacles on other levels. Its static snapshot is reserved to
  responder capacity.
- The investigate-marker scan moved into the separation job, and it keeps
  factionless agents out of faction-restricted markers.

## Pathfinding

- **Slice 64E:**
  - runtime level links patch both levels incrementally, using fixed interior
    link slots and a link cursor;
  - the dig refuses a ninth distinct interior ramp per chunk;
  - incremental patches match a full rebuild, serial and threaded;
  - a failed growth still patches the whole dirty set;
  - link-cursor and growth stats survive a failed step;
  - the completed path cache is cleared after a degraded apply.
- **Slice 64F:** per-level windows, `repackLevelEdges` on overflow (allocate
  before mutate, so an OOM leaves the old layout valid), and a level-by-level
  relabel.
- **New benches:** `nav-update-links`, `nav-update-links-dense`,
  `nav-update-cave-in` and `nav-update-cave-in-warm`.

## Rendering And Build

- `drawSprite` grows its command buffer instead of failing the frame. The
  reservation-drift diagnostics exist only in Debug and ReleaseSafe.
- Tile-data edits carried over a skipped frame merge in place, and a new test
  covers it.
- Windows ReleaseFast builds no longer use LTO. Outside LTO, the default
  backend and linker selection is used.

## Roadmap, Standards, And Tooling

- The roadmap is split into an index, one file per slice, an archive and
  tracks.
- Slices 49–72 hold the VoidLight feature port. Full localization is under
  Deferred By Owner.
- **New rules:**
  - budgets, capacities and thresholds are three separate rules;
  - no backlog dumping, so every follow-up is a checklist item in a slice;
  - comments stay as short as their contract allows;
  - code takes the plain, obvious form over clever code.
- **Agent definitions:**
  - the implementer runs `check` + `test` + `idiom-lint` per commit and a full
    `verify` once per batch;
  - design plans are sized to the decision.
- The README was updated to the current feature set.

## Known Open Items

- **64E:** a post-fix manual ramp check on current code (display-gated).
- **64F:**
  - a recorded cave-in bench;
  - a repack prefix trim;
  - a threaded level repack, gated on the Slice 69A soak.
- **65B:**
  - non-fatal failure states;
  - the swap rule on a refusal.
- **72:** batches D–H, J, K1–K5 and M are not started.

## Commit List

- `c1f9845` slice 47 completed and implemented.
- `06d871c` slice 48 pt 1
- `0d31250` slice 48 pt 2: move intents, tile gate, and plane traversal out of the pipeline
- `5de789a` slice 48 pt 3: fixed event budgets, cognition reserve, and order tests
- `5011d2d` slice 48 pt 4: sensory emit, marker scan, and allocation proof
- `a1c0528` slice 48 completed: archive the thin-composer restoration
- `2b3a5a4` forward assement workflow and update of roadmap to help the project move forward cohesively.
- `4acba9b` claude zig tooling update and removed cursor dir
- `61a0e43` finished off/fixed slice 37.
- `57a98bf` render world packing update
- `2bae057` agent workflow required
- `77a99f7` shader update
- `4d82115` Upgrade build and sources to Zig 0.17.0
- `829b32c` Apply Zig 0.17 zig fmt migration
- `7cf59cb` Lint removed and deprecated Zig 0.17 spellings
- `0bcfbaf` Document the Zig 0.17 upgrade
- `aefb5e3` Apply pkg-config to the SDL translate-c step for system SDL
- `29a22e6` Apply Zig 0.17 upgrade review cleanups
- `e7c0384` Merge branch 'zig-0.17-upgrade' into ai_update3
- `99e6959` Use Zig default backend/linker selection outside LTO
- `6c843a0` Split roadmap per slice and plan VoidLight feature port (Slices 49-71)
- `01754ec` Disable ReleaseFast LTO for Windows targets under Zig 0.17
- `81c7272` Gate steering static-obstacle avoidance by world level (Slice 71B.1)
- `fb9158f` Merge branch 'worktree-agent-ae19b04eeec1cd86d' into ai_update3
- `fa4c064` Decouple simulation scope from the render visibility window
- `3ca132a` Merge branch 'worktree-agent-a9f3ca2bf2cd45e36' into ai_update3
- `9859496` Document that production callers must set SimulationContext.sim_view
- `172d1af` Fold runtime LevelLinks into the nav abstract tier (Slice 64E)
- `21a918f` Fix the group-field threshold to a constant (Slice 71B.1)
- `47e331f` Merge branch 'worktree-agent-a9bf9adb34b42d270' into ai_update3
- `ef21356` Split the fixed-budget rule into budgets, capacities, and thresholds
- `4edca97` Record capacity audit as the next roadmap task
- `fe721f9` Address Slice 64E review: link capacity, ordering, admission
- `2c345f0` Merge branch 'worktree-agent-a9bf9adb34b42d270' into ai_update3
- `6a10f3e` Capacity audit: right-size per world instance with engine best practice
- `c648f61` Add Slice 72: live capacity sizing pass from best-practice src/ sweep
- `3a665fb` Slice 72 A1: preflight plane-traversal landing scratch before any carve
- `decf93d` Slice 72 A2: drawSprite grows past capacity instead of failing the frame
- `aeb295c` Slice 72 A3: gate pathfinding request intake on the logical frame cap
- `0e6a74e` Slice 72 A4: logical spill/saturation limits in search; Batch A bench record
- `f66b7cf` Slice 72 B1: one owner for the per-step event bound
- `0ce18d7` Slice 72 C1: CollisionSystem.reserve
- `ab0638c` Slice 72 C2: steering static snapshot sized to statics
- `223e0ae` Slice 72 C3: syncPopulationCapacity population growth seam
- `7635978` Slice 72 C4: perception and affect event shares derived from content
- `b19e5a9` Slice 72 A follow-up: drift counters compare against the reservation
- `3ef211d` Slice 72 A follow-up: SearchScratch on the 64 B thread-shared rule
- `87f85c5` Slice 72 A follow-up: failure-atomic ProbeTable/ResultCache resize
- `d2ef832` Slice 72 A follow-up: bench record corrections and false-sharing items
- `d292af8` Slice 72 C3 follow-up: steering static snapshot reserved to responder capacity
- `832d140` Slice 72 B1 follow-up: structural event share sized in events and enforced alone
- `ebeb3c7` Slice 72 C3 follow-up: growth proof covers the world allocator and a real multi-range path
- `a3031ab` Slice 72 B1/C3 follow-up: demo budget and seam tests on a minimal fixture
- `2c1b552` Slice 72 B/C final-review follow-ups: status, checklist and bench record
- `466e94b` Slice 72: own the per-range slot warming gap as checklist item C5
- `1e951ba` Roadmap bookkeeping: index and status reflect landed 52A, 71B, 72 work
- `91138df` Slice 71B.1 capacity-audit follow-up: content-sized agent ceiling, threshold frozen at reserve
- `daac4ae` Slice 64E: nav dirty buffers sized by the structural-stage event bound
- `5c4fa8c` Slice 64E: level links grow at the dig commit seam
- `c9496b8` Slice 72 C5: per-range outputs never warm in-stage
- `78ed7e5` Slice 72 C5 follow-up: collision staging reserved to the per-item pair bound
- `b070a85` Slice 71B.1 follow-up: nav-memory benefit test compares unrounded bytes
- `92da19d` Slice 64E follow-up: link growth only for an admitted dig, before promote
- `3dc8fb2` Slice 72: C5 review follow-up record; C6 contact streams to the pair bound
- `c4c5677` Slice 72 C6: contact streams and response reserves to the pair bound
- `161624b` Slice 72 C6 follow-up: broadphase slots reserved per item, slot growth counted
- `33f855c` Slice 72: own the in-demo contact density check as manual item C7
- `c28b4d0` Record owner's manual checks: 72 C7 contact density, 64E ramp pathing
- `33e0b98` Correct manual-check records: the run was a Debug build
- `b39e016` Slice 64E: grow an overflowing nav chunk edge window in place
- `58f24a5` Slice 64E review: prove and bound in-place nav edge-window growth
- `e513298` Slice 64E: assert the nav edge-hole bound instead of a dead compaction trigger
- `12016da` Branch review: keep factionless agents out of faction-restricted markers
- `1ba327e` Branch review: count the pipeline's own destructible share in the structural budget
- `10d8581` Branch review: make the pipeline update context's sim_view required
- `7450e14` Branch review: remove the test-only DigController.process wrapper
- `e7c969a` Branch review: compile sprite reservation-drift accounting out of shipping builds
- `03bd24f` Branch review: test uploadTileDataEdits carry-over rewrite and drops
- `dfeb1c1` Branch review: fix doc drift and promote world-gate SIMD into Slice 35
- `144de0f` Slice 72 I1: perception transitions derived from per-row columns
- `3ddb983` Slice 72 I2: affect crossings from per-row bits, no sort
- `82ea89c` Slice 72 I1/I2 follow-up: pipeline growth proof covers perception and affect
- `3f54b79` Branch review: pin the cognition phase in single-step AI pipeline tests
- `dbaddd0` Slice 64E M4: patch the whole dirty set before surfacing a growth failure
- `f5b1cb7` Slice 64E M6: gate edge-arena re-admission on live slots, not physical capacity
- `c67b294` Slice 64E M5: fail a build whose measured edge arena exceeds the nav memory gate
- `cf1107f` Slice 64E M7: carry link-cursor stats across a failed nav apply
- `b1fab5c` Slice 64E: record M4-M7 benches and reopen a post-fix manual check
- `2c66e5e` Branch review: make the dig admission seam private again
- `b8ae306` Branch review: count pipeline-stage structural commands in the pipeline share
- `cd38a09` Branch review: describe commandOverflowGrows as a lifetime diagnostic
- `95c8441` Branch review: cite padding constants and helpers by symbol, not line
- `aad4acb` Branch review: count projectile, world-item, and harvest structural commands in the pipeline share
- `393f1de` Slice 64E M10: report edge-window growths and compactions of a failed step on the next success
- `ad017a2` Slice 64E M8: size edge windows by a slacked -> unslacked -> refuse ladder in the build and relocation
- `5ac317b` Slice 64E M11: log a refused nav update once per step
- `44c0f70` Slice 64E M9: keep every edge arena's capacity within the nav memory gate's ceiling
- `0c32383` Slice 64E M12: drop the completed path cache after a degraded nav apply
- `3c31040` Slice 64E M13: check the tombstone oracle in the OOM sweeps
- `c29b19b` Slice 64E: record M8-M13 benches
- `403cef7` Trim comment, plan, and report verbosity; verify once per batch
- `987351b` Slice 64E/65B: own the M8-M13 review follow-ups
- `20b5d68` Slice 64F: decide nav edge storage before 65B builds on it
- `7ae44ef` Slice 64F: take the nav edge arena out of the memory gate
- `1529862` Slice 64F: per-level edge windows, repack a level on overflow
- `e0aef77` Slice 64F: readable names in the repack and its tests
- `08e64bc` Slice 64F: cheaper repack measure and rebase
- `3e29b2d` Slice 64F: record the edge storage decision, benches, and memory
- `84cafcc` Coding standards: prefer the plain, obvious form over clever code
- `6d5ee8c` Slice 64F: keep edge windows packed and relabel level by level
- `8328a30` Slice 64F: test the u32 edge-index cap at its boundary
- `c6138db` Slice 64F: cave-in repack bench and open review follow-ups
- `4604730` Slice 64F: fix a stale repack comment, note why step 1 is not reused
- `60a8aab` Slice 64F: gate the threaded level repack on a demo-scale trigger
- `2e9b07b` Slice 64F: status matches its open follow-ups
- `b471443` README: current pipeline, scoped simulation, dig-aware pathfinding, docs index
- `10e5d8c` README: keep feature bullets at overview level
- `7ae6be1` README: one-line AI and interactables bullets; list Python 3 requirement
- `3d95821` README: frame destructibles as the destruction/construction foundation
