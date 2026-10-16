# Core Systems Changelog

Branch: `core_systems`

Range: `main..core_systems`

Base: `5673672` (`Merge pull request #12 from Ronin15/module_layout`)

Tip: in progress. Slice 50 landed (programming complete); its full TSan suite,
`verify`, ReleaseFast `zig build test`, and the owner's Windows and Mac runs are
open in the slice.

## Summary

The Engine-Core core branch, opened by Slice 50 so the branch's threaded
rework runs under the race detector. `ThreadSystem` is now safe against
nested and foreign callers in every build mode, its dispatch is lock-free with
the claim counter on its own cache line, workers carry names, tests and
benches run under ThreadSanitizer, and the tuner gate is derived from the
measured dispatch floor. Measured numbers are Debug unless labelled.

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

## Other Changes

- `7ee55b0`: `chunk-scale-nav-level-add` charges one open added level, not
  every added level, so the 2048-side replace point charges 290 MiB (was
  530 MiB against the 512 MiB limit) and all 10 points run.
- `5989a6a`: the Engine-Core core-branch list gains a whole-subsystem
  collision pass, with the measured main-thread gather and sort (32,768
  agents: 11.4 ms Debug, 0.53 ms ReleaseFast).

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
