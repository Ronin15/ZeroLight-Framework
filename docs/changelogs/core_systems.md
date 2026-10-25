# Core Systems Changelog

Branch: `core_systems`

Range: `main..core_systems`

Base: `5673672` (`Merge pull request #12 from Ronin15/module_layout`)

Tip: in progress. Slice 50 landed (programming complete); its ReleaseFast
`zig build test` and the owner's Windows and Mac runs are open in the slice.
The measuring landing benched the branch's baseline; Slice 83 landed
(`verify` passes at `13e88ad`); Slice 84's programming landed, with its open
items in the slice.

## Summary

The Engine-Core core branch, opened by Slice 50 so the branch's threaded
rework runs under the race detector. `ThreadSystem` is now safe against
nested and foreign callers in every build mode, its dispatch is lock-free with
the claim counter on its own cache line, workers carry names, tests and
benches run under ThreadSanitizer, and the tuner gate is derived from the
measured dispatch floor. A bench-only measuring landing then measured today's
code and wrote each finding into its slice, Slice 83 split steering and the
pipeline tests and gave every production stage its own tuner, and Slice 84
rebuilt the shared neighbor index as a level- and faction-keyed chunk index
built on workers and shared per cell. A tuner and slot series then gave
each pass its own tuner, sized collision's range slots from the dispatch, made
`PaddedSlot` line-aligned by type, and gated the fixed-shape dispatch seam out
of production with idiom-lint rule 13. Measured numbers are Debug unless
labelled.

## Slice 50: Thread System Hardening

- `e56e37b`: the `thread-dispatch` bench group, one stage dispatch through
  `Dispatch.select` and `Dispatch.run` over a trivial range-local job on a
  64 to 262,144-item ladder; the before-baseline for the later landings.
- `4ae3d60`: `-Dsanitize-thread` instruments the unit-test and bench
  artifacts, forces LLVM on them, fails unsupported targets with one message,
  and sets `TSAN_OPTIONS` (defaults, then the user's value) on the run steps.
  The full suite (1743 tests) and the `thread-dispatch` and `movement` groups
  ran clean; no suppressions.
- `4e62442`: caller roles. A nested batch from a participant runs forced
  inline on its own `WorkerId`, touching no tuner, with a per-batch stat, a
  per-system counter, and one warning per lifetime; a foreign thread panics.
  Workers name themselves `zl-worker-<index>`. The owner path costs about
  40–60 ns per dispatch on the 64-item inline rows; gated rows within spread.
- `a66d87c`: `Shared` is four `std.atomic.cache_line` blocks (512 B per
  system); each participant copies a `BatchView` and counts its ranges
  locally, so the claim is the claim loop's only RMW. Faster beyond spread
  where participants contend (262,144 items: fixed-auto 177 → 141 µs, tuned
  208 → 118 µs; movement 10,000 tuned 65 → 44 µs), nothing slower.
  ReleaseFast (labelled): 262,144 fixed-2 −19.5%, fixed-auto −16.5%. 64 vs
  128 B singleton alignment within spread; 128 stays.
- `b42ef15`: lock-free publication and completion: a per-worker generation
  (release/acquire), a countdown that includes main, and a `done` event main
  waits on only when it is not last. Serialized lock handoffs per dispatch
  2N+2 → 0. `wait` faster beyond spread on every gated row (fixed-auto 16,384:
  11.4–16.9 → 8.7–9.9 µs); nothing slower. The per-worker generation makes a
  stale-wake data race and the old desync branch impossible by construction.
  Full TSan suite 1761/1761 clean.
- `7946511`: wake tests at every worker count 1–23 and 5,000 back-to-back
  batches with stale permits. The tree wake they came from measured slower
  at every worker count (a tree level costs a wake round trip, about
  3.5–4 µs, against about 0.9 µs per flat post saved) and was not landed.
  Flat floor, ReleaseFast: about 6.6 µs + 0.9 µs per worker.
- `18c1d5c`, `13a2a67`: slice items for owner hardware runs of a planned
  core low-power wait module were added, then dropped with the module, which
  was never built. Measured on a scratch prototype, spin-within-step-then-park
  saved
  0.04–0.07 ms per step at the release shape (within spread) while roughly
  doubling worker CPU and slowing main's serial work 9–41%; pure park stays.
- `58ff9e1`: tuner gate 250 → 60 µs, twice the measured Debug full-pool
  dispatch floor (29.8 µs at 23 workers), so a batch at the gate clears the
  5% commit margin at every worker count. The demotion bound subtracts the
  overhead a settled profile measured. Full 76-group sweep: nothing slower
  beyond spread on 3-rep reruns; many tuned cases faster or newly threaded
  (movement 4096/10000 −42%, apply-intents −62 to −67%, particles −37%).
  `chunk-scale-cave-in` 640256008 tuned 1.00 ms → 690 µs (fixed-auto 679 µs,
  gap closed). ReleaseFast spot-check (labelled): cave-in tuned −35%.
- `65434f7`: a winning one-worker first probe climbs up instead of settling
  at one worker; a losing one-worker retune probe reverses upward from the
  best.

## Measuring Landing

- `5d5a089`: bench-only (the one production change makes
  `GameDemoState.initWithWorld` `pub`). New groups `production-step`,
  `world-create`, `world-gate`, `collision-tall`, `collision-stacked`,
  `perception-crowd`, `render-game-prep-offview`; collision prints
  `per_body`, `gather`, `sort`, `main`, and the spatial index `main`; groups
  list only the cases they run (`BenchmarkGroup.cases`). Baseline (23-worker
  host):
  - `production-step` tuned, one run (wall step, main per stage): spread P
    16,384 9.8 ms (collision 2.95, clamp 1.92 ms main); crowd P 16,384 38.8 ms
    (collision 11.6, spatial index 8.15 ms main); main carries 75–88% of the
    step in every config. Half the rows are dormant at the base config, 87% at
    32 levels.
  - `perception-crowd`: 0/1,024 observers find their hostile behind 256 allies
    or at 32 levels (the hostile scratch fills before the level check).
  - Collision per body, serial: 2.9 → 26.2 µs as aspect goes 1 → 256, and
    2.0 → 18.2 µs as levels go 1 → 16.
  - `render-game-prep-offview`: collect 0.44 → 8.6 ms as off-view rows go
    4,096 → 262,144 with 1,088 collected.
  - `world-gate` serial: 17.2 ms at 65,536 bodies.
  - `world-create` tuned: 141.7 ms at 2048² × 8 (nav 117.5 ms); 0 bytes
    after destroy.

## Slice 83: Core-Branch Prep

- `3c42b4f`: `steering.zig` (4,538 lines) becomes `systems/steering/`
  (`system`, `selection`, `directions`, `agent_grid`, `avoidance`,
  `test_support`), with the agent grid whole in `agent_grid.zig` for 85;
  no facade, no behavior change. Test counts unchanged.
- `176ed03`: the pipeline's scenario fixtures move to
  `pipeline_test_support.zig`; `simulation_pipeline.zig` 7,599 → 6,328
  lines. Test names and order unchanged.
- `13e88ad`: every production stage dispatches with a tuner it owns: ten
  caller-settable tuner fields and four fallbacks to the shared tuner are
  gone, and scope's `deriveChunks` gets the same treatment. An own-tuner
  test per stage, and a pipeline test that 11 stage batches ran on workers
  with the shared tuner untouched. Debug A/B on nine groups: nothing slower.

## Slice 84: Level-Aware Shared Neighbor Index

- `c52a5ff`: the index builds on workers on steering's banded pattern (bucket
  and sort stages under tuners the index owns, main holding the ordered merge),
  with a content-sized row-segment lookup in place of `DenseCellLookup`, a
  comptime visitor, and the halo side tables gone from AI and perception; visit
  order and every test expectation unchanged. Against `b745929`:
  `production-step` crowd P 16,384 tuned main 32.07 → 20.72 ms (spatial index
  0.27 ms main, 30/30 steps on workers); `spatial_index` tuned 184 / 474 /
  952 µs at 1,024 / 4,096 / 10,000 entities.
- `08e4799`: entries keyed level | chunk | faction | local cell | slot, per-chunk
  records with faction row masks, one run per (piece, faction); queries per
  level and faction set; self as a cleared lane; the lane-group visit
  (`NeighborLanes`), with separation and cohere summing in lanes; sorts on
  `core/sort.zig`; `perception_update` and `ai_decide` carry positions and
  levels. `perception-crowd` (1,024 observers) finds every hostile behind 256
  allies and at 32 levels, where `5d5a089` found none. Against `b745929`, tuned:
  `perception` 928 → 772 µs at 2,048; `spatial_index` 4.09 ms → 863 µs at
  10,000; `spatial_index-query dense_cell` 0.72 / 3.71 / 34.1 → 0.46 / 1.87 /
  7.48 ms at 256 / 1,024 / 4,096 bodies (against the pre-lane tree), quadratic
  to linear.
- `3efa1e4`: per-cell shared `NeighborBlock`s, the cell-major think set
  (`ai_cognition_order` on workers), the AI and perception gathers on workers,
  perception's FOV in lanes, and AI memory in ascending row order for any think
  order; memory's row cap fails as `OutOfMemory`. Against `08e4799`, tuned, at
  2,048 entities: `ai` 2.28–2.71 → 1.11–1.40 ms; `perception` 755–824 →
  363–528 µs; `perception-crowd` allies 256 (1,024 observers) 9.25–9.94 →
  1.31–1.52 ms. `spatial_index` at 10,000 798 → 898 µs (the `population_row`
  column, planned cost); `ai-memory` −37% at 10,000, +20% at 1,024 (inline,
  the row ordering's planned cost). ReleaseFast (labelled): `ai` tuned at
  10,000 986 → 433 µs.
- `6d9f0da`: `plane_entry` compacts its windows through
  `thread_system.compactSliceWindows`.
- `320023a` (rule `eb061b9`): production per-step and per-change sorts move to
  `core/sort.zig`'s whole-element swaps (43 sites in 22 files at the sweep);
  stable total-order sorts become `pdq`, tie-holding ones keep `std.mem.sort`.
  `perception` at 2,048: serial 2.62 → 2.26 ms; tuned within noise.

## Thread System And World Gate

- `f1fb2bd`: every stored diagnostic `BatchStats` sits behind its owner's perf
  switch (collision, triggers, static colliders, scope, nav update, pathfinding,
  connectivity, resize copy); tuners keep their samples as locals, tests read
  none, and the bench build reads them through new dispatch checks (listed in
  `docs/development-workflow.md` § Benchmarks). An update-path trigger rebuild
  left the patch query record stale; it now clears it.
- `f59cf3b`: the `production-step` census records every per-step dispatch
  (bench batch tags, `BatchAggregate` min/max items), a bench-only stage-timer
  channel (`BenchTiming`) keeps stage timing out of the runtime log, and every
  case runs the same pre-measure steps. Debug, 16,384 tuned: `untimed`
  13-20% to 0%.
- `f0adc9a`: the world gate's bounds clamp and tile gate run as threaded lane
  batches over movement rows on the collision bounds (mirrored into movement
  columns by `DataSystem`); the player row runs on main after the join. Debug,
  16,384 tuned step 5.13 to 3.60 ms; clamp on main 1.84 ms to 2.8 us.
  `world-gate` serial +25% Debug, -36% ReleaseFast (lane lowering in Debug).
- `60d7078`: the timer re-probe is removed; a settled stage re-tunes only on
  evidence. The inline probe cooldown keeps its own field
  (`inline_probe_cooldown_windows`). Nothing slower beyond spread (Debug).
- `83ef090`: the tuner is a batch tuner: it tunes the batch count with a
  continuous nudge, workers follow the batches, and demotion uses the upper
  bound only (`docs/architecture.md` § Thread System). Debug, 3,003-step
  `production-step` 16,384: 0 demote/restore pairs (base 13-15), steps 100+
  median 3.21-3.39 ms (base 3.29-3.39). ReleaseFast, 65,536: steps 100+ median
  1.394 ms (base 1.474), steps over 2.5 ms 3 (9). ReleaseFast `thread-dispatch`
  1M 65.3 to 59.3 us; `movement` 262k 35.2 to 49.3 us and `world-gate` 65k
  167 to 193 us (ranges overlap). Open: `world-gate` 65,536 ReleaseFast tuned
  +31-44% over fixed controls (`slice-35.md`). `thread-adaptive-fixed-range`
  removed from the benches.
- `d359430`: rules: thread-policy changes get a ReleaseFast run, unsettled
  tuned cases are rerun, layout findings in new code are fixed in their
  landing.
- `d420933`: the pathfinding registry publish and level open/close cost what
  changed, never depth: growth is read from the reserve returns,
  `openRegistryLevels` is O(1) at unchanged counts, `truncateLevels` frees
  closed levels and halves header storage. Debug `chunk-scale-nav-dig` 256² at
  8/32/128 levels flat on both sides.
- `42192b2`, `0012864`: collision's five data-dependent range-slot sets size
  from the dispatch's own selection through `RangeSlots` (prepare, counted
  grow, replay); the capacity seam warms only the inline slot, and the bound
  counters count total-bound overflow only. The trigger patch groups gain the
  tuned case, pinned controls, and work and growth asserts.
- `54f8298`, `4eda9f8`, `9c84b9b`, `fbafc72`: bench reporting. Every group
  reports its stages per measured step (`[threaded/dispatched]`), settles on the
  tuners its step runs, and proves dispatch with error returns; the census
  counts a tuner only if it recorded in the measured window (`record_count`,
  `idle=`); one-off stages measured fresh print `settled=fresh`; the fixed-length
  nav groups settle on ordinary reactions and then arrive as one-off jumps.
- `95b9fcd`: pathfinding tuners follow the work: level builds run on their own
  fresh set (`nav_build`), registry flushes own per-phase sets plus one shared
  one-off set, the closure copy and registry rename have their own tuners, and
  the group field's stall rounds fold into their pass. Debug `world-create`
  1024x8 39.22 to 31.73 ms.
- `36307ef`: a repeated unsustained jump's own skipped records judge its held
  shape (`judgeJump`), final within two records. Debug `pathfinding-link-fold`
  1016008192 tuned 243.2 to 143.1 us; ReleaseFast 1064008192 72.3 to 41.5 us.
  The earlier bench-settle verdict that the link-fold gap was "planned cost"
  from a held inline shape learned on one-cell toggles was wrong: the cause was
  the jump prediction (plan over-predicted threaded, patch under-predicted
  inline). The 1016 and 1064 gaps sat within run-to-run spread, and 1064 was
  not rerun at the time.
- `4998400`: `PaddedSlot` aligns to the cache line by its type, which fixes
  `PathIndex.counts` sharing lines in ReleaseFast; six pathfinding tallies use
  `SlotList`.
- `faa3200`: the worldgen paint is a tuned one-off stage on the world's fresh
  `ground_build_tuner` at 32-chunk alignment; the collision response place is
  an ordered merge on main.
- `de8d308`: collision trigger emission has no count pass (page and node count
  columns, `emittedCursorAt`); nodes are written by a merge on main; refresh
  ranges own pages at 1,024-pair alignment. Debug `collision-static-triggers`
  16,384 pairs 900.2 to 998.5 us (3 reps 939.0 to 977.8, within spread).
- `19fe22a`, `166075c`: `ThreadSystem`'s fixed-shape options are the one
  sanctioned test and bench seam; idiom-lint rule 13 fails production code that
  sets them to anything but a forward of its stage's controls. Steering's band
  stages forward `band_items_per_range`.

## Other Changes

- `7ee55b0`: `chunk-scale-nav-level-add` charges one open added level, not
  every added level, so the 2048-side replace point charges 290 MiB (was
  530 MiB against the 512 MiB limit) and all 10 points run.
- `5989a6a`: the Engine-Core core-branch list gains a whole-subsystem
  collision pass, with the measured main-thread gather and sort (32,768
  agents: 11.4 ms Debug, 0.53 ms ReleaseFast).
- `95aaa95`, `b07f1cc`, `57b3e16`: the measured findings become Slices
  83–87 and items in 35, 56, 57, 61, 62, 72, 74, 75, 76, and 77; Slice 88
  covers `DataSystem`, the step contracts, the pipeline, and the core
  kernels; every system gets a whole-subsystem pass, with a coverage map in
  the index. Core order (owner): 83 → 84 → 86 → 85 → tile gate (35) → 87 →
  88 → inert rows → 75's tier mechanics.
- `9af57be`, `041c5e3`: Slice 66F, Steamworks runtime integration behind an
  opt-in `-Dsteam` build; a Steam build requires Steam (owner).

## Conventions And Tooling

- **ThreadSanitizer (`4ae3d60`).** `-Dsanitize-thread=true` for tests and
  benches; a sanitizing build reconfigures on every invocation; not part of
  `verify` (`docs/development-workflow.md` § Thread Sanitizer).
  `threading.md` gains the TSan suppression policy and the nesting and
  foreign-thread rule (the Slice 50 docs commit).
- **Singleton alignment (`a66d87c`).** `threading.md`: a contended singleton
  shared record aligns to `std.atomic.cache_line`; per-range and per-row
  slots keep the 64-byte quantum (owner approved).
- **Bench controls (`ce877e5`, `2af2b8a`, `58ff9e1`).** One shared fixed
  range-size helper on `BenchmarkCase`; fixed controls scale from each
  group's partition, and a control that resolves to an earlier case's shape
  is reported as its duplicate, untimed; the forward and revert halves of
  edit benches run on separate tuner sets, one sample per step per tuner.
- **std swaps (`71f2871`).** `@divCeil`, `std.mem.alignForwardAnyAlign` /
  `alignBackwardAnyAlign` / `alignForward`, and `std.math.clamp` replace the
  hand-rolled ceil-div, alignment, and clamp helpers tree-wide; the bench
  `rangeCount` is gone and bench reserves call `thread_system.maxRangeCount`.
- **Measuring landings (`5d5a089`).** `tests-benchmarks.md` (owner
  approved): a branch's measuring landing states each finding's pass shape
  in the group doc and asserts only fixture invariants; the shape assert
  lands with the fix. A group lists the cases its workload runs
  (`BenchmarkGroup.cases`, `suite.casesNamed`), and a row with no batch
  prints `-`.
- **`std.mem.print` (`43f9a11`).** The 14 deprecated `std.fmt.bufPrint`
  calls move to `std.mem.print`; idiom-lint rejects `bufPrint`,
  `bufPrintSentinel`, and `BufPrintError`, and `zig-style.md` lists the
  pairing.

## Commit List

- `e56e37b` Slice 50: thread-dispatch bench group (measure-first baseline)
- `ce877e5` Benchmarks: one shared fixed range-size helper on BenchmarkCase
- `2af2b8a` Benchmarks: fixed controls scale from each group's own partition
- `7ee55b0` chunk-scale-nav-level-add: charge one open added level, not every added level
- `4ae3d60` Slice 50: -Dsanitize-thread build option (ThreadSanitizer for tests and benches)
- `71f2871` Use std for ceil-div, alignment, and clamp across the tree
- `4e62442` Slice 50: caller roles, forced-inline nesting, foreign-thread panic, worker names
- `43f9a11` std.mem.print for the deprecated std.fmt.bufPrint; idiom-lint rejects it
- `a66d87c` Slice 50: claim-line isolation and per-participant range counts
- `b42ef15` Slice 50: lock-free batch publication and completion
- `7946511` ThreadSystem tests: every counted worker wakes once at every worker count
- `18c1d5c` Slice 50: owner hardware runs of the core low-power wait module (Windows, Mac)
- `13a2a67` Slice 50: drop the low-power wait hardware runs; pure park stays
- `5989a6a` Engine-Core core branch: whole-subsystem collision pass, with the measured main-thread gather and sort
- `58ff9e1` Slice 50: tuner gate 250 -> 60 us, derived from the measured dispatch floor
- `65434f7` Slice 50: tuner climb goes up from a winning one-worker first probe
- `987b342` Slice 50 docs: thread system architecture, TSan workflow, rules, changelog
- `ddd551d` Slice 50 docs: status reflects passing TSan and verify; ReleaseFast and owner runs stay open
- `5d5a089` Engine-Core core branch: measuring landing (baseline benches on today's code)
- `95aaa95` Engine-Core core branch: measured findings into slices 83-87 and their owning slices
- `3c42b4f` Slice 83: split steering.zig into systems/steering/ by stage
- `b07f1cc` Engine-Core: slices 84, 85, 87 audit their whole subsystem against the cost model
- `57b3e16` Engine-Core: every system gets a whole-subsystem pass; Slice 88 covers DataSystem, contracts, pipeline, kernels
- `176ed03` Slice 83: move the pipeline's scenario fixtures to pipeline_test_support.zig
- `9af57be` Roadmap: Slice 66F, Steamworks runtime integration
- `041c5e3` Slice 66F: a Steam build requires Steam; the non-Steam build is -Dsteam=false (owner 2026-10-16)
- `13e88ad` Slice 83: every production stage dispatches with a tuner it owns
- `b745929` Slice 83 docs: steering package, pipeline test support, stage-owned tuners, measuring-landing bench groups
- `c52a5ff` Slice 84: the neighbor index builds on workers, with row-segment lookup; no outcome change
- `1a50197` Debug builds at the shipped CPU floor; bench_ab compares at one CPU; -Dcallgrind profiles benches
- `6a9ea07` Profiling docs: one line on why valgrind needs a CPU without AVX-512, nowhere else
- `50b3857` engine-design.md: a flagged part is redesigned to the rules, then tuned within reason against the code it replaces
- `336333b` CLAUDE.md: zig-review-specialist checks each design plan against the rules before implementation
- `c9f481d` Revert the CLAUDE.md design-plan review step
- `89f34c5` memory-performance.md: sorted stores and indexes are ordered so hot queries read contiguous runs
- `7c27a40` zig-review-specialist: a contiguity check on every sorted store and index, in every review and design
- `d51e8ae` zig-review-specialist: the contiguity check cites the rule instead of restating it
- `a8489d2` Roadmap: the 2026-10-16 audits and Slice 84 review routed into their slices, in fix order
- `555992b` Roadmap: DataSystem hot-pass contiguity is an engineering item in 88, not an owner question
- `9b0d0fa` Roadmap: audit items kept only where a rule backs them; the calls the rules decide are made
- `7805239` memory-performance.md: data-oriented design is the bar for every hot loop; the contiguity bullet folds into it
- `21c5eb5` Roadmap: every audit item verified against the rules and live code; fixes, restores, and the 83 archive
- `2463ebb` Roadmap: 84's docs commit keeps one place per explanation
- `b85bc93` Slice 66F: restore the owner's later Steam features section as written in 9af57be
- `10ae134` build-validation.md: modes compare only with themselves, and a ReleaseFast run never excuses a Debug finding
- `f828085` memory-performance.md: data groups by its storage unit, filter keys order it within the unit; SIMD results stay in lanes through their consumer
- `01fee45` memory-performance.md: a loop feeding a lane consumer ends in one masked lane batch, not a scalar tail
- `74f847e` Shared results include intermediate work; design settles data layout before kernels
- `c26c3c1` Bench A/B separates code from fixture; perf attribution checks data shape first
- `732bf1f` Rules: one verdict per Debug gap; storage-unit grouping only where data has one; short runs are a layout fix
- `08e4799` Slice 84: level- and faction-major chunk index built on workers; lane-group neighbor visit
- `b530d86` tests-benchmarks.md: the tuned case's inline/threaded report decides whether serial is production or a control
- `a939342` Agents: callgrind only for a regression tests-benchmarks.md says to act on, never a control's constant gap
- `d665b87` Bench verdicts: one A/B per landing, one verdict per slower case, one round per regression
- `339c804` zig-specialist runs the landing's one A/B and gives the verdicts; profiling stays with zig-debug-specialist
- `0f6f721` zig-design-specialist: state each requester kind's measured sharing factor; a near-one factor must earn the sharing form's cost
- `a42a8c9` tests-benchmarks.md: verdicts name noise, planned cost, immaterial constant, and regression (what gets optimized)
- `453aa14` Design covers every consumer of a changed order, with a fallback for bench-gated allowances; findings route by their fix
- `9f24388` Rules: one definition of a Debug regression, in tests-benchmarks.md
- `2b8a2ba` Routing: findings and failures route by their fix; a regression is one debug-specialist unit
- `35033b7` Agents can do what the rules ask: shape runs, review-fix reruns, derived sharing factors
- `236f168` TSan cadence lives in build-validation.md; DW cites it
- `a22c808` Close scalar loopholes: no "simple logic" scalar exception, no sanctioned scalar tail, right-sized ReleaseFast runs
- `9f7103c` Rules live in rule files: agents and CLAUDE.md cite them
- `2ab6fa0` Guidance: workflow-set outputs win over single-landing defaults; stale citations fixed
- `ef82fc1` bench_ab: tuned rows show each side's worker_threads cell; defaults to warmup 1, iterations 3
- `3efa1e4` Slice 84: per-cell shared neighbor blocks, cell-major think set, gathers and memory order on workers
- `6d9f0da` plane_entry: window compaction through thread_system.compactSliceWindows
- `eb061b9` zig-style: production sorts use core/sort.zig
- `320023a` Slice 84: production sorts on core/sort.zig whole-element swaps
- `b40c71e` Slice 71A: stimulus pools grow and over-budget stimuli defer
- `908ac83` Comments: trim module docs to their contracts
- `ad67f3c` Agents: docs-specialist on Sonnet writes docs commits and roadmap routing
- `f1fb2bd` Diagnostics: batch records sit behind each owner's perf switch; tests never read them.
- `f59cf3b` Benches, perf: the production-step census records every dispatch and both cases measure one state.
- `f0adc9a` World gate: the bounds clamp and tile gate run as threaded lane batches over movement rows.
- `60d7078` Tuner: no timer re-probe; a settled stage re-tunes only on evidence.
- `83ef090` Tuner: a batch tuner; workers follow the batches; demote only on the upper bound.
- `d359430` Rules: thread-policy changes get a release run; unsettled tuned cases are not judged; layout findings are not deferred.
- `d420933` Pathfinding: registry publish and level open/close cost what changed, never depth (F-75).
- `42192b2` Collision: per-range slots sized from the selection through ThreadSystem's RangeSlots (slot L1).
- `0012864` Benches: trigger patch groups get the tuned case, pinned controls, work and growth asserts (trigger store step 5).
- `54f8298` Benches: shared harness reports the batch tuner per measured step; fresh one-off tuners are judged (bench reporting landing 1).
- `4eda9f8` Benches: every group reports its stages per measured step, settles on the tuners its step runs, and proves dispatch (bench reporting landing 2).
- `9c84b9b` Benches: the tuner census counts a tuner only if it recorded in the measured window (bench settle landing 1).
- `fbafc72` Benches: fixed-length nav groups measure after production's settled state (bench settle landing 2).
- `19fe22a` Rules: ThreadSystem's fixed-shape dispatch options are the one sanctioned test/bench seam, gated out of production by the idiom lint.
- `95b9fcd` Pathfinding: each pass owns its tuner; one-off flushes share one set, level builds start fresh.
- `36307ef` ThreadSystem: a repeated jump's own records judge its held shape.
- `4998400` ThreadSystem: PaddedSlot carries cache-line alignment; pathfinding tallies use SlotList.
- `faa3200` Worldgen paint is a tuned one-off stage; collision response place merges on main.
- `de8d308` Collision triggers: emission without a count pass; node merge on main.
- `166075c` Lint rule 13: production dispatch shapes only forward stage controls; steering band forward.
