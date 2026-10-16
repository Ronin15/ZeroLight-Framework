# Core Systems Changelog

Branch: `core_systems`

Range: `main..core_systems`

Base: `5673672` (`Merge pull request #12 from Ronin15/module_layout`)

Tip: in progress. Slice 50 landed (programming complete); its ReleaseFast
`zig build test` and the owner's Windows and Mac runs are open in the slice.
The measuring landing benched the branch's baseline; Slice 83 landed, its
`verify` open in the slice.

## Summary

The Engine-Core core branch, opened by Slice 50 so the branch's threaded
rework runs under the race detector. `ThreadSystem` is now safe against
nested and foreign callers in every build mode, its dispatch is lock-free with
the claim counter on its own cache line, workers carry names, tests and
benches run under ThreadSanitizer, and the tuner gate is derived from the
measured dispatch floor. A bench-only measuring landing then measured today's
code and wrote each finding into its slice, and Slice 83 split steering and the
pipeline tests and gave every production stage its own tuner. Measured numbers
are Debug unless labelled.

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
  - `production-step` tuned: spread P 16,384 9.8 ms (collision 2.7, clamp
    1.9 ms); crowd P 16,384 38.8 ms (collision 11.0, spatial index 8.0, AI
    4.8 ms); main carries 75–88% of the step in every config. Half the rows
    are dormant at the base config, 87% at 32 levels.
  - `perception-crowd`: 0/1,024 observers find their hostile behind 256 allies
    or at 32 levels (the hostile scratch fills before the level check).
  - Collision per body, serial: 2.9 → 26.2 µs as aspect goes 1 → 256, and
    2.0 → 18.2 µs as levels go 1 → 16.
  - `render-game-prep-offview`: collect 0.44 → 8.6 ms as off-view rows go
    4,096 → 262,144 with 1,088 collected.
  - `world-gate` serial: 17.2 ms at 65,536 bodies.
  - `world-create` tuned: 142 ms at 2048² × 8 (nav 122 ms); 0 bytes after
    destroy.

## Slice 83: Core-Branch Prep

- `3c42b4f`: `steering.zig` (4,538 lines) becomes `systems/steering/`
  (`system`, `selection`, `directions`, `agent_grid`, `avoidance`,
  `test_support`), with the agent grid whole in `agent_grid.zig` for 85;
  no facade, no behavior change. Test counts unchanged.
- `176ed03`: the pipeline's scenario fixtures move to
  `pipeline_test_support.zig`; `simulation_pipeline.zig` 7,599 → 6,328
  lines. Test names and order unchanged.
- `13e88ad`: every production stage dispatches with a tuner it owns: nine
  caller-settable tuner fields and four fallbacks to the shared tuner are
  gone, and scope's `deriveChunks` gets the same treatment. An own-tuner
  test per stage, and a pipeline test that 11 stage batches ran on workers
  with the shared tuner untouched. Debug A/B on nine groups: nothing slower.

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
