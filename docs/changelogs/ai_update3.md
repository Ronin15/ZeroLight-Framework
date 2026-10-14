# AI Update 3 Changelog

Branch: `ai_update3`

Range: `main..ai_update3`

Base: `b39a46f` (`Merge pull request #10 from Ronin15/ai_update2`)

Tip: in progress; Slice 64G programming landed, its seal gate remains

## Summary

`ai_update3` finishes the post-`ai_update2` cleanup slices, moves the toolchain
to Zig 0.17, and then shifts focus from new gameplay features to making the
engine scale correctly:

- **Capacity:** a best-practice capacity model replaces fixed sizes. Each world
  instance is right-sized at load, and runtime-growing stores grow only at the
  structural-commit seam.
- **Determinism:** simulation scope no longer depends on the render camera.
- **Chunk ownership (Slice 64G):** terrain, the GPU tile store, and nav are
  owned per chunk, built from main's nav model, so a dig, ramp, cave-in, or
  explosion costs the chunks it touches; reachability is maintained per batch
  and answered in O(1), and far goals advance by partial hops.

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
  Sprite drift accounting is compiled out of shipping builds.

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

## Slice 64G: Chunk-Owned Terrain, Render, And Nav

Nav work on this branch from 2026-10-05..07 is superseded; 64G rebuilds from
main's model. Numbers are Debug unless noted.

Terrain and render:

- S0 `2c09cec`: main's nav, link, and apply code restored; the 64E/64F link and
  edge-window code and tests removed.
- S2 `23c24ec`: one power-of-two chunk edge (at most 16) and tile-sized nav cells
  shared by terrain, nav, and scope; index widths fail loudly at world create,
  level add, and nav build.
- S3 `453993f`: terrain stored per chunk (tile blocks with uniform chunks,
  composed blocked bits, link endpoints indexed per chunk).
- S4 `9bbfdc0`: per-world GPU tile store laid out by chunk; the GPU byte gate
  became a report.
- S3b `e06a5bd`: dense one-step changes (cave-in, explosion) planned and written
  per chunk on the thread system; serial equals threaded.
- S2–S4 follow-ups `1ced421`: world-sourced nav extent, blocks re-uniform at any
  tile, one dig reserve, `chunk-scale-ramp`.
- Render B0 `c026ef0`, (a) `bcd569a` `5439e36`, (c) `ea38364`, R3 `ee01c5f`, R4
  `693363e`, R5 `89f5c9a`: generational `TileDataId` with a per-frame claim and
  sweep; gpu-smoke imports no game code; GPU tile residency follows the camera
  window; growable dense bands; change marks replace the GPU edit queue; sparse
  tiles draw from a per-window list; geometric tile-upload growth without a
  device drain.
- K1 `736a939`: SIMD and kernel retrofit (row-mask `rectMask`, hoisted sparse
  blocked bits, `simd.countUnequalU16`, `@memcpy` tile packing).
- P1 `46d3b7f`, `83f36a6`: every release mode defaults to the shipped CPU floor.

Nav storage and the reaction:

- N1 `1e97b65`: line of sight reads chunk terrain (no LOS cache); a nav failure
  no longer skips the steering reaction. N2 `c45d5fe`: nav scaling benches.
- N3 `fe2d99e`: a ramp dig opens its exit cell on the level above; link endpoints
  iterate per chunk; sparse tiles remove in O(1).
- N4a-0 `b530f24`, N4a `1305fa9`: the post-commit reaction runs as threaded,
  transactional stages (mark, plan, remask, patch); the nav memory gate is gone;
  a level add builds only that level (85.8 → 1.2 ms at 256²); dense changes -78 to
  -92%.
- N4b `5db9025`: per-chunk nav cell store; `StaticColliderSystem` and
  `ChunkListMap`; terrain writers reserve and record their nav marks, so no change
  is lost (static move at 10k statics 77 ms → 18 µs, flat). N4b-1 `3d0e8f5`: plane
  traversal's per-agent cell-entry test on workers (16,384 agents threaded
  24.8 ms → 538 µs).
- N5 `10bbbc7`: budget-sized search tables, chunk-block group fields (13 B per
  covered cell in an open crowd), the tier-1 corridor pool (72 G1).
- N6-B0 `0ee5a6d`, N6 `22ac6ae`, N6b `8358b37`: a consistent cross-level
  heuristic with level-aware long-link bounds and 16 coupled link pairs
  (cross-level depth -53%; every teleport config solves).

Steering, movement, collision, and the tuner:

- N4c-0 `e9b24f6`, N4c-1 `18a4702`, N4c `173cc17`: steering reads the shared
  static rows through a size-class query map (static change at 10k statics
  17.8 → 10.4 ms, flat).
- N4d-1 `ede5509`, N4d-2a `97caa40`, N4d-2 `df7f1ea`: steering's prepare phase and
  agent grid run as threaded stages (main at 16,384 agents 6.9 → 0.42 ms).
- N4d-3a `64c914c`, N4d-3 `cc58f38`: AI movement intents apply as a threaded stage
  (serial -86%). N4d-4a `6722603`, N4d-4 `ff670b4`: collision response is a
  threaded gather and band apply (adaptive -70 to -86%); the tuner's
  wait-dominated demotion is removed.
- TS1 `4b15d88`, TS2-0 `69e7ed2`, TS2a `c31d8b1`, TS2b `15362e7`: the tuner holds
  its profile under varying load, judges a demotion by the next inline window,
  and re-bases a shifted retune on the incumbent; probe and demotion counters.

Requests, caches, and eviction:

- T1 `8ee993a`, `9c245e6`: request intake and group-field expansion are threaded
  stages. C1 `f638ff3`: cached paths stored exactly; elastic resizes keep the
  cache (72 G2, E2; elastic-ramp 4000 re-solves 3,937 → 0).
- N7a-0 `230a4bd`, N7a `870ac61`, N7a-1 `8b59c3c`: chunk-scoped eviction through a
  16-shard path registry, a paged result cache, threaded publish copy, resize
  copy, and registry flush (evict 50,000 results 5.64 ms → 132 µs).
- L1 `69dba4f`: the runtime perf log records each change path's cost-driver stage.
- N7b-0 `e98e4e1`, N7b-1 `9f7de20`, N7b-2 `83172ce`: unit-weighted flushes; group
  fields and pending requests survive a local change (the goal-side negative
  cache it added was later replaced by reachability).

Reachability:

- N7c-0 `8a28fd1`, N7c-1 `e793590`, N7c-1b `a294a7a`, N7c-2 `2c1a9c1`: connectivity
  ids with a balanced, threaded flood (a removal costs about its smaller side,
  flat in level side), the exact one-way closure, and O(1) reach at intake,
  status, and solve with one goal projection per goal key per step; the negative
  cache and goal flood are deleted (unreachable bursts -97 to -99.9%).
- A5 `285b1d2`, `309a1a5`: each H-component owns its closure block; the shared
  arena's world-scale compaction is gone (timed close 94/292/992 → 65/65/70 µs).

Dense changes, long links, and combined review:

- B2a-0 `1657d63`, B2a-1 `d11f1d9`: the reaction's main time split by section;
  level-owned ordered plan sets replace the heap merge (plan 824 → 228 µs at 256
  chunks).
- Std-first `3be2d5c`; N6c-0 `b76d06d` layout and link-fold benches; `408b5a0`
  O(1) link-endpoint dedupe; B2 rest `639f55d` (GPU sync axes, one bench world
  builder, honest nav storage bounds); staging release `e40845d` (resident nav 6.82 →
  1.79 MB after a dense change and 240 quiet steps); exact half-open cell spans `685df2d`; stage helpers and
  one dispatch pattern in `ThreadSystem` `819d8d8`, `2496824`.
- Areas A `eaa4a80`, B `a869e15`, C `08c01c2`, D `adf883d`: proven nav id widths
  and one pool grower; per-level rebuild eviction and config-only capacity; plane
  traversal O(1) per entry with one threaded carve batch and drain-free GPU
  stream growth; every pipeline tuner pinned by a comptime walk. M1 `ab9f01f`: ids
  stay u32 and exhaustion fails as OOM at the growth seam.
- ChunkGeometry `19256c5`: one chunk tiling for terrain, nav, and static
  colliders. Bench cohesion `0c85293`: production-read estimates, per-group
  labels, single-axis sweeps, world-backed request-load groups.

Long paths:

- L0 `982d934`: `pathfinding-long-path` baseline. Partial paths `1a5241f`, the
  crossing-aware heuristic `41afa5f` (cross-level depth -57.5% serial), least-h
  partial `ac48f66`: every walk and hop chain arrives, hops linear in route
  length. Heap sift `e2b9b2c`: sifts move a hole (pathfinding 1024 -24.9%).
- Init sizing `4c247e7`: pipeline init sizes pathfinding's elastic pools for the
  committed crowd, so the first update after load grows nothing (the demo's one-off
  5.5 ms ReleaseSafe spike at 2,000 entities).


## Rendering And Build

- `drawSprite` grows its command buffer instead of failing the frame. The
  reservation-drift diagnostics exist only in Debug and ReleaseSafe.
- Tile-data edits carried over a skipped frame merge in place, and a new test
  covers it.
- Windows ReleaseFast builds no longer use LTO. Outside LTO, the default
  backend and linker selection is used.

## Roadmap, Standards, And Tooling

- The roadmap is split into an index, one file per slice, an archive and
  tracks. Slices 49–72 plan the next feature set (VoidLight is a feature
  parity reference only). Full localization is under Deferred By Owner.
- **Rules move to `.claude/rules/`:** `docs/coding-standards.md` is replaced
  by one rule file per topic, path-scoped where a rule is area-specific, with
  the conflicts between rule texts resolved. Docs describe and cite rules.
- **Direction:** a fully simulated, multi-world colony-simulator base with an
  optional player; one observer (the camera focus, or a player) is targeted.
  Everything that exists keeps advancing in every world; distance from the
  observer lowers fidelity
  (far-off AI thinks on slower ticks, movement stays near full rate); dormant
  is for inert things; important population persists, only ambient spawns may
  be recycled far away; the chunk is the unit of terrain and nav storage,
  work, threading, and save; nav is processed per chunk so threading scales
  with requests under a fixed, worker-independent budget. Rules state these
  as short guiding principles.
- **Roadmap back to main's format:** slices hold intent and data only (goal,
  current foundation, constraints, intent-level checklist, acceptance), never
  internal designs; the design pass runs right before implementation. Open
  slices went from about 26,800 lines to about 7,400; index rows and the
  merged order are rebuilt from each slice's header dependencies. Prior text
  is at tag `pre-main-shape`.
- **New slices:** 73 (data-driven cognition), 74 (world instances), 75 (far
  simulation), 76 (cave-ins), 77 (explosions), 78 (comptime assessment), 79
  (fixed-step input edges), 80 (observer and optional player), 81 (split the
  pathfinding module); the engine-core overhaul branch order (pathfinding, core
  systems, AI) and its findings are in the roadmap index. Slice 62 keeps villagers and NPCs and recycles only ambient
  spawns; 69F's region paging became chunk storage forms that never leave
  the simulation; 57's world items persist and decay outdoors.
- **Rules added or clarified:** the cost model and target scale come first;
  the chunk owns terrain and nav storage and work; budgets, capacities, and
  thresholds are separate; no backlog dumping; terse comments; plain code over
  clever code; one bench comparison protocol.
- **Rules during 64G:** rules and `docs/architecture.md` win over code, and the
  default is keep; the cost model covers a population's per-step load, stores a
  computed result at the unit it covers, measures new algorithms at worst-case
  shapes, and runs a pre-implementation check; reachability maintenance is the
  one local-change cost exception; the main thread does O(1) work per item; a
  tuner judges a stage's median dispatch, and a step reaches it as one sample;
  each change path's cost-driver stage is perf-logged; dependencies point down
  (game may use the app services it runs on); tests and benches run in Debug,
  ReleaseFast only for a question Debug cannot answer; SIMD or scalar follows the
  loop's shape; nanosecond constants are reported, not redesigned; std comes
  before hand-rolled code; a u32 pool index exhausts as `OutOfMemory`; tests and
  benches drive production sequences, read production values, and fail rather
  than skip; per-commit validation runs only the touched tests
  (`-Dtest-filter`).
- **Tooling:** CLAUDE.md is a short index; the four specialists keep only role,
  procedure, and output format and read the matching rule files; the review
  workflows share one severity scale and a structural/local tag and propose
  rule-file edits instead of agent guidance; a shared `settings.json` and a
  `zig fmt` hook.
- **Tooling during 64G:** `tools/bench_ab.py` for targeted before/after benches
  (base ref vs tree, one Debug run per side, 3 reps only to confirm a slower
  case, `--optimize ReleaseFast` for the targeted question, each side's runs
  cached by build inputs, `--fresh`); the agent pipeline is design (only when a
  design is open) → implement → one review per landing, with one docs commit per
  slice; design and review reports live in `.claude/reports/`; `idiom-lint`
  rejects deprecated std names.
- **Governance review fixes:**
  - The churn stop now counts a second fix or redesign of one subsystem
    across slices.
  - Rules stop describing today's implementation:
    - nav node ids and versioning are principles;
    - platform checks never refuse a world, level, or change;
    - index caps are proven over growth;
    - the tier test wording is fixed.
  - Review and design agents require three-size scaling benches for claimed
    orders and a measured baseline before replacing a structure.
  - Roadmap:
    - 75 (in-world far simulation) now precedes 74, and 74 depends on 50 and
      75;
    - 72's index row matches its header, and its K6 record is restored;
    - the `SeedDomain` 1/2 values are back in the track table;
    - the direction track cites the rule instead of copying it.
  - `zig build verify` runs `zig fmt --check`.
- The README was updated to the current feature set.

## Known Open Items

- **64G:** the seal gate (verify, ReleaseFast test, gpu-smoke, the acceptance
  benches, the owner demo check); measured limits are in its slice file.
- **81:** split the pathfinding module, after 64G.
- **73, 74, 75:** the fully simulated direction's planning slices (cognition,
  world instances, far simulation); not started.
- **65B:** re-scoped against 64G's chunk storage at its design pass.
- **72:** its open items, re-scoped against 64G and 75.

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
- 37 nav commits (2026-10-05..07), superseded by Slice 64G (`git log main..ai_update3`)
- `21a918f` Fix the group-field threshold to a constant (Slice 71B.1)
- `47e331f` Merge branch 'worktree-agent-a9bf9adb34b42d270' into ai_update3
- `ef21356` Split the fixed-budget rule into budgets, capacities, and thresholds
- `4edca97` Record capacity audit as the next roadmap task
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
- `c9496b8` Slice 72 C5: per-range outputs never warm in-stage
- `78ed7e5` Slice 72 C5 follow-up: collision staging reserved to the per-item pair bound
- `b070a85` Slice 71B.1 follow-up: nav-memory benefit test compares unrounded bytes
- `3dc8fb2` Slice 72: C5 review follow-up record; C6 contact streams to the pair bound
- `c4c5677` Slice 72 C6: contact streams and response reserves to the pair bound
- `161624b` Slice 72 C6 follow-up: broadphase slots reserved per item, slot growth counted
- `33f855c` Slice 72: own the in-demo contact density check as manual item C7
- `33e0b98` Correct manual-check records: the run was a Debug build
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
- `b8ae306` Branch review: count pipeline-stage structural commands in the pipeline share
- `cd38a09` Branch review: describe commandOverflowGrows as a lifetime diagnostic
- `95c8441` Branch review: cite padding constants and helpers by symbol, not line
- `aad4acb` Branch review: count projectile, world-item, and harvest structural commands in the pipeline share
- `403cef7` Trim comment, plan, and report verbosity; verify once per batch
- `84cafcc` Coding standards: prefer the plain, obvious form over clever code
- `b471443` README: current pipeline, scoped simulation, dig-aware pathfinding, docs index
- `10e5d8c` README: keep feature bullets at overview level
- `7ae6be1` README: one-line AI and interactables bullets; list Python 3 requirement
- `3d95821` README: frame destructibles as the destruction/construction foundation
- `c87b867` Add the ai_update3 changelog
- `6a18c73` Align agent, workflow, and rule files with current owner decisions
- `0b00252` Rename file-namespace imports to snake_case per coding standards
- `d56e634` Give every guidance rule one owner and point everywhere else at it
- `d6a7305` Concise, context-aware guidance: one owner per rule, directory CLAUDE.md files
- `334e8d0` Drop slice and review references from code comments
- `edba22b` Directory guidance fixes
- `b6a5b5c` Coding standards: terse rule lists per section
- `40064d5` Single root CLAUDE.md: fold directory guidance back into its owner docs
- `ecbac6c` Guidance: design for target scale and multiple worlds; local changes cost local work
- `1580fe0` tooling updates
- `ec362ea` Rules in .claude/rules; CLAUDE.md, agents, workflows, and docs point to them
- `529d032` Roadmap: main's slice shape, no rules or logs in slices, Slice 64G
- `fe4d63a` Changelog fixes; remove the accidentally committed seal notes
- `bd8cf25` update for AI issue found
- `53bc399` Direction and roadmap shape: fully simulated worlds, intent-only slices
- `e7effa0` Direction: colony-simulator base, fidelity anchored on the observer
- `6a51eaf` Roadmap: main's slice format, intent and data only; Slices 73, 74, 75
- `64bf59d` more tooling updates
- `0a06d88` Rules: test and bench in Debug; ReleaseFast only at the branch commit
- `5978533` Slice 64G: treat 64E/64F churn as code to delete, main as reference
- `af1c3c1` fixing tooling yet again
- `5af3b4e` Slice 64G: main's nav defects from the rules review; request caps to 72
- `3594176` Rules and architecture win over code; default is keep; design stays out of slices
- `7895334` Slice 64G: create/destroy acceptance is linear in their own chunks
- `2c09cec` Slice 64G S0: restore main's nav, link, and apply code
- `23c24ec` Slice 64G S2: one chunk size and cell resolution; loud index widths
- `6af2685` Slice 52D: chunk_size_tiles is a power of two after 64G S2
- `453993f` Slice 64G S3: terrain stored per chunk
- `8c640e6` Agents: check serial and threaded paths for scaling work
- `caaefe9` Threading: new threaded work follows the existing stage pattern
- `9311582` Slice 64G: check off S0, S2, S3 landings
- `9bbfdc0` Slice 64G S4: per-chunk GPU tile store and window residency
- `607001c` Slices 64G, 74: S4 landed; per-world GPU store release owned by 64G
- `9646f08` Process: review before commit, small slices, extend the architecture's owner
- `5cfbe2e` Render rule: world render state lives in WorldSystem's render path
- `c131b47` Docs and tooling: fixes from the review of this session's doc commits
- `045f097` CLAUDE.md: drop the redundant re-review clause
- `9a13e4e` Review agent: check the owning system before flagging a missing guard
- `e06a5bd` Slice 64G S3b: threaded dense terrain edits, chunk-major
- `87559d0` Tooling: targeted A/B bench tool, agent report files, finding tracking
- `1ced421` Slice 64G S2-S4 follow-ups: local fixes from the step reviews
- `4b968ee` claude md tweaks
- `c026ef0` Slice 64G render B0: window pan and sparse window baseline benches
- `19af66f` Roadmap: Slice 76 cave-ins; 64G ramp-exit and steering items
- `25c5b75` Roadmap: cave-ins and explosions belong to DestructibleController
- `a7be8d4` Render rule: only the camera-focused world renders
- `c44a841` Render rule: a mini view may show the focused world or another
- `bcd569a` Slice 64G render (a): generational tile store ids, per-frame claim, sweep
- `5439e36` gpu-smoke: no game imports; dependency direction rule
- `4cd9258` Roadmap: nav design review decisions for 64G, 71B, 74
- `ea38364` Slice 64G render (c): GPU tile residency follows the camera window
- `472e124` bench_ab: shared build cache, two default cases
- `47fb095` bench_ab: default to 2 warmup and 10 timed iterations per run
- `41a34ac` bench_ab: refuse full-grid runs unless asked
- `ee01c5f` Slice 64G render R3: growable dense bands; change marks replace the GPU edit queue
- `693363e` Slice 64G render R4: sparse tiles draw from a per-window list
- `89f5c9a` Slice 64G render R5: geometric tile upload transfer growth without a device drain
- `1e97b65` Slice 64G nav N1: LOS reads chunk terrain; reactions never skip steering
- `c45d5fe` Slice 64G nav N2: nav scaling bench groups; SIMD and threading required in every design
- `736a939` Slice 64G K1: SIMD and kernel retrofit of the landed terrain and render loops
- `8ee993a` Slice 64G nav T1: request-side pathfinding work runs on the thread system
- `9c245e6` Slice 64G nav T1: keep the 4-lane SIMD intake cell conversion
- `4b15d88` Slice 64G TS1: adaptive tuner holds its profile under varying load
- `fe2d99e` Slice 64G nav N3: ramp digs open their exit; link endpoints per chunk
- `46d3b7f` Slice 64G P1: shipping builds default to the packaged CPU floor
- `e9b24f6` Slice 64G N4c-0: steering-static-change bench measures the old static rebuild
- `f638ff3` Slice 64G nav C1: path cache stores results exactly; resizes keep the cache
- `b530f24` Slice 64G N4a-0: batched nav benches run the real post-commit reaction
- `83f36a6` Slice 64G P1: CPU floor follows Slice 52A's recorded baseline
- `1305fa9` Slice 64G nav N4a: nav applies change batches as threaded, transactional stages
- `5a8221c` Guidance: right-sized bench curve points; implementer doc edits wait until programming is done
- `48dd28c` Rules: pre-implementation check in the cost model; main thread keeps O(1) work per item
- `5db9025` Slice 64G nav N4b: per-chunk nav cell store, StaticColliderSystem, no change lost to nav
- `3d0e8f5` Slice 64G N4b-1: plane traversal's per-agent cell-entry test runs on workers
- `18a4702` Slice 64G N4c-1: steering-static-dense bench measures the static obstacle query by density
- `c1936e8` Rules: a Debug bench never reverts a SIMD loop to scalar
- `45aa9c4` Rules: nanosecond-per-item constants are reported, never redesigned
- `173cc17` Slice 64G N4c: steering reads the shared static-collider rows through a size-class query map
- `ede5509` Slice 64G N4d-1: steering's prepare phase runs as threaded stages
- `97caa40` Slice 64G N4d-2a: steering benches time steering only and add clustered layouts
- `df7f1ea` Slice 64G N4d-2: steering's agent grid builds in count-balanced bands off the main thread
- `64c914c` Slice 64G N4d-3a: movement-apply-intents bench measures the AI movement intent apply
- `e2bfd7c` bench_ab: runs started in the same second get distinct output directories
- `c591d50` Rules: contract-disjoint scattered row writes from worker ranges are allowed
- `cc58f38` Slice 64G N4d-3: AI movement intents apply as a threaded stage
- `339d373` Rules: scattered row writes are measured against the same stream in row order
- `c62561c` Tooling: standard design/review checklist in the agents; targeted ReleaseFast A/B
- `a10cd2a` CLAUDE.md: owner process decisions made durable beyond the seal plan
- `6722603` Slice 64G N4d-4a: collision-response-stage bench measures today's collision response
- `ff670b4` Slice 64G N4d-4: collision response runs as a threaded gather and band apply
- `10bbbc7` Slice 64G N5: budget-sized search tables, chunk-block group fields, tier-1 pool
- `69e7ed2` Slice 64G TS2-0: tuner probe-window and demotion counters for --details
- `c31d8b1` Slice 64G TS2a: the first inline window after a demotion judges it
- `15362e7` Slice 64G TS2b: the retune after a sustained shift re-bases on the incumbent
- `0ee5a6d` Slice 64G N6-B0: cross-level shaft and teleport-count benches measure today's heuristic
- `53ecdb5` Rules and agents: tuner-inline stages, material constants, Debug as release proxy
- `22ac6ae` Slice 64G N6: consistent cross-level heuristic with level-aware long-link bounds
- `230a4bd` Slice 64G N7a-0: elastic-shrink and cold-unreachable benches, long_results size term
- `870ac61` Slice 64G N7a: chunk-scoped path eviction through a path registry, paged result cache
- `dcf56ff` CLAUDE.md: the design-pass trigger breaks a failing fix loop
- `8b59c3c` Slice 64G N7a-1: shrink registry flush on workers, batched registry adds
- `69dba4f` Slice 64G L1: runtime perf log records each change path's cost-driver stage
- `e98e4e1` Slice 64G N7b-0: negative-cache base benches on a sealed goal pocket
- `9f7de20` Slice 64G N7b-1: registry and evict flush over unit-weighted (index, shard) pairs
- `83172ce` Slice 64G N7b-2: goal-side negative cache, goal-enclosure flood, scoped eviction
- `167ec51` zig-design-specialist: results are stored at the unit they cover and shared
- `d213492` engine-design: computed results are stored at the unit they cover and shared
- `23909a3` engine-design: cost model covers a population's per-step load
- `8358b37` Slice 64G N6b: coupled long-link pairs in the cross-level heuristic
- `8a28fd1` Slice 64G N7c-0: unreachable-burst, connectivity-split and one-way benches
- `8403683` Roadmap: engine-core overhaul branch order and cost-model findings
- `be345f2` threading: a stage releases every ready item; adaptive case must thread
- `205fd1c` Agent pipeline: prove a design's threading and assumptions before code
- `05d81a6` threading: state the tuner mechanism; guidance lives in the rule
- `9725756` Tighten the tuner-mechanism rule and the pre-check step
- `2c9e408` engine-design: measure new algorithms at worst-case shapes before code
- `fb546d8` CLAUDE.md: decision criteria and rule-writing guidance live in the project
- `06616a0` tests-benchmarks: judge a threaded stage on its adaptive-tuned case
- `9368f5d` zig-design-specialist: no code or prototypes; derived numbers go to the pre-check
- `f2de262` Agent pipeline: design, implement, review; no pre-check step
- `57419bb` Agent pipeline: briefs ask only for the agent's own work on the landing
- `48546eb` Agent pipeline: rule departures and anything unclear go to the owner
- `d52429a` Drop reminder lines that restated existing guidance
- `adf855d` CLAUDE.md: drop meta lines that added nothing
- `478150d` Agent pipeline: redesign only when the design missed a critical project need
- `cbd8822` Rules: align tuner and bench wording with owner rulings
- `e793590` Pathfinding: maintained connectivity IDs with a balanced, threaded flood
- `ef200db` Agent pipeline: a design plan per landing, written right before it
- `2a84100` Agent pipeline: no less work for perf goals; major redesigns go to the owner
- `a6ce9da` zig-design-specialist: plans estimate lines changed per file
- `f79f4fc` engine-design: game may import the app services it runs on
- `9e5b67f` Targeted tests: -Dtest-filter, per-commit runs of touched code only
- `a294a7a` Pathfinding: exact one-way reachability closure
- `d0e7c84` bench_ab: cache each side's reps by build inputs
- `0ba7a2c` tests-benchmarks: state the comparison requirement, not tool mechanics
- `3762e1f` Align CLAUDE.md and the debug agent with targeted tests and the bench cache
- `c53bb96` Design plans cover what the change adds or changes
- `e84f233` Roadmap agent workflow: plan per landing, one docs commit per slice
- `20da335` Document the test filter and bench cache where all work reads them
- `9087fc6` Bench A/B: one run per side; 3 reps only to confirm a slower case
- `5c6fef0` Agents: review reads code only, implementer reads the plan, A/B lists touched groups
- `2c1a9c1` N7c-2: O(1) reach at intake, status, and solve; shared goal projection
- `7308a69` zig-style: use std before hand-rolling containers and algorithms
- `178573a` CLAUDE.md: decision criteria may depart from a rule, reported as a decision made
- `2424a35` Agents: plans name the std API or why not; reviews check std usage
- `1657d63` B2a-0: nav reaction main-thread split by section; bench fixture on the writer path
- `3be2d5c` Pathfinding: std-first — replace std duplicates, state reasons where std can't serve
- `d11f1d9` B2a-1: level-owned ordered plan sets replace the heap merge; mark assert off main
- `b76d06d` N6c-0: cross-level layout benches and pathfinding-link-fold baseline
- `408b5a0` Nav patch: O(1) link-endpoint dedupe per chunk with a 256-bit seen set
- `1539c91` Guidance: recurring criteria departures become rule edits; design never prototypes or benches
- `3a902df` Workflows: drop deleted nav_memory.zig; cover connectivity.zig and goal_table.zig
- `5d6d0e9` zig-style: replace a std duplicate as soon as it is found
- `639f55d` B2 rest: GPU sync axes, one bench world builder, honest nav storage bounds, sorted-intent control
- `e40845d` Nav staging follows the current need: counted growth, sustained-window release, builds freed at step end
- `685df2d` Exact half-open cell spans: lastCellOfSpan replaces the 0.001 max-corner epsilons
- `1432445` agents: design hot-loop table only when the change adds or changes a loop
- `a1961de` CLAUDE.md: design runs only for an open design; decided work goes to zig-specialist
- `819d8d8` Shared stage helpers in ThreadSystem: one copy of record alignment, padded slots, band partition, inline/accumulated batch stats
- `2496824` Stage dispatch converges on ThreadSystem: Dispatch, StageThreads, runStage, RoundDispatch; per-stage worker caps on nav, splice, terrain edit
- `c8bb47e` Roadmap: Slice 50 (thread hardening, TSan workflow) opens the core-systems branch
- `eaa4a80` Area A fixes: proven nav id widths, one growPool, counted growth, one ChunkGeometry, edge-only plan stream
- `285b1d2` Bench: pathfinding-connectivity-oneway .ballast variant (closure arena baseline)
- `a869e15` Area B fixes: per-level rebuild eviction, config-only capacity, active group fields kept, one intake classifier, derived budgets
- `982d934` Bench: pathfinding-long-path, long-route baseline on the flat chunk-portal search
- `1af3750` budgets-capacities: a pool's u32 row index exhausts as OutOfMemory at its growth seam
- `08c01c2` Area C fixes: plane traversal O(1) per entry on main with one threaded carve batch, tile uploads that cannot desync, drain-free GPU growth, per-level chunk state
- `eee3f60` simd.zig: zig fmt
- `ab9f01f` M1 remainder: ids stay u32; running out of a pool's index space fails as OutOfMemory at its growth seam
- `1a5241f` Partial paths: a tier-1 stitch past its cell or segment cap publishes its prefix as partial; steering follows it and asks again from its end
- `b5aaf48` Roadmap: Slice 79 for sub-step input edges, frame-time snapping, and the TimeLoop cap invariant
- `0422d9e` Roadmap: drop replay and cross-machine determinism; add Slice 80 observer and optional player
- `41afa5f` Crossing-aware heuristic: per-level crossing boxes and a lazy relaxed-graph Dijkstra put each level's ramps into the cross-level bound
- `ac48f66` Least-h partial: a saturated tier-1 search publishes a partial toward its least-estimate expanded node when that node is below the start's estimate
- `309a1a5` A5: each H-component owns its closure block; the shared arena and its world-scale compaction are gone
- `19256c5` ChunkGeometry: one chunk tiling for terrain, nav and static colliders, u32 sides, validated at every create path
- `adf883d` Area D fixes: every pipeline tuner pinned by a comptime walk, stream range reserves sized from their writers, std-first searches, deprecated std names and dead code swept
- `e099cc4` memory-performance, build-validation: SIMD or scalar follows the loop's shape; Debug timings never decide, a choice needing a number gets the ReleaseFast run
- `6489789` idiom-lint, zig-style: reject std.ArrayListAligned(Unmanaged) and std.mem.copyForwards/copyBackwards; assets-audio names releaseTextureWithContext
- `0c85293` Bench cohesion: production-read memory estimate checked whole, per-group labels and formatters, one item code and fixture set, single-axis right-sized sweeps, world-backed request-load groups
- `e21c5ce` tests-benchmarks: tests and benches drive production sequences and rules; benches read production values, check estimates whole, fail rather than skip, share one harness, sweep one axis
- `e2b9b2c` Open-heap sifts move a hole instead of swapping; every pathfinding search's heap work drops
- `75be288` build.zig LTO comment back on ltoSupportedForTarget; teleport bench states the random-pad limit
- `f7e46df` Slice 64G docs: write the landings' doc notes from the code as landed; checklist, limits, core-systems items, Slice 81
- `b83dd86` Slice 64G acceptance: chunk-scale and path-cost checks pass; the cave clause becomes arrival within the node caps
- `feeabd0` Slice 64G acceptance: the manual demo check passes
- `4c247e7` Pipeline init sizes pathfinding's elastic pools for the committed steering agents; the first update after load grows nothing
