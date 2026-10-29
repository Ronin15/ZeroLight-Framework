## Slice 85: Steering On The Shared Neighbor Index

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 84](slice-84.md), [Slice 86](slice-86.md) (branch order) · Track: standalone (engine core; [Engine-Core Overhaul](../../framework-implementation-slices.md#engine-core-overhaul))

**Status: landed** (`21851e4`, `608337b`, `50225b9`, `0aabf95`, `8244f75`,
`76646ef`). Debug, `x86_64_v2`. The index switch's `production-step`
(`1024008016384`) was not judged: both sides stayed unsettled at warmup 484
on tuners that change does not own. `zig build verify --summary all` passed
after `55720b8`: 28/28 steps, 2032/2032 tests.

Goal: steering queries 84's shared index instead of building and sorting a
private grid; an entity create or destroy invalidates only what it changed in
steering's caches; steering's movement intents reach movement in an order that
keeps the apply local.

### Current foundation

Landed behavior. Measured numbers below are Debug, `x86_64_v2`.

- Avoidance queries the shared index (`avoidance.zig:272`, `visitLanes`
  `:444`). The private grid, its tuners, and the movement-index cache are
  gone. One `NeighborBlock` per avoidance range; the other agent's radius is
  an index entry column, masked-gathered.
- `steering_update` reads `spatial_index` and carries `movement_positions`
  and `world_level` (`simulation_pipeline.zig:246-249`). `reserve` past
  `max_step_items` returns `OutOfMemory` (`system.zig:219`); the step keeps
  the assert (`:252`).
- `select_resolve` and `select_claim` are the only selection path, inline
  when no worker is available (`selection.zig:38-44`). Claim's items are the
  placed intents (`:78-80`); a range owns whole bands (`:220`).
- Avoidance writes movement intents in selected order, then a place and a
  sort order them by `movement_row` (`avoidance.zig:99-111`). The apply reads
  that row (`movement.zig:128`). Path requests stay in selected order, which
  is steering-row order (`76646ef`).
- `directions` walks steering rows and writes runtime columns only for
  claimed rows in that span (`directions.zig:218-286`). The smooth tail is
  `smoothDirectionLanes` (`:369`). Agents align at 32, directions at 64,
  other steering stages at 16 (`system.zig:54-57`).
- An empty batch shapes to zero ranges (`thread_system.zig:2449`).
- `stuck_step_threshold` above `max_steering_cooldown_steps` is
  `InvalidSteeringAgent` (`agents.zig:58`). The two `validateAiAgent` gaps
  (`last_score`, `commitment_remaining`) stay on the AI findings in the
  roadmap index.

### Architecture notes

- Neighbor queries use the shared index (`.grok/rules/simulation.md`).
- A create costs work in what it changed (`.grok/rules/engine-design.md`
  § Cost model).
- Each hot loop carries a SIMD verdict (`.grok/rules/memory-performance.md`
  § SIMD).
- The serial path is the stage run inline (`.grok/rules/threading.md`,
  `.grok/rules/tests-benchmarks.md`).

### Checklist

- [x] Steering reads the shared index; the private grid and its sort are
      gone (`21851e4`). `steering` tuned faster at 128, 512, and 1024;
      `steering-levels` keeps 63 checks and 0 samples per selected intent at
      1, 4, and 16 levels. `production-step` was not judged (acceptance).
- [x] The movement-index cache and its post-commit reaction left with the
      snapshot (`21851e4`). Selection resolves each intent's movement row;
      runtime rows rekey only the rows a commit moved.
- [x] The agent avoidance accumulate is `visitLanes` over the index's lane
      groups, ending in the masked last batch (`avoidance.zig:444`).
- [x] Movement intents reach the apply in movement-row order (`0aabf95`).
      The apply reads the stored row and does not look one up
      (`movement.zig:128`). Ordering is the steering place and sort.
- [x] Movement and particle updates drop the scalar remainder (`da2adfb`).
- [x] `steering_update` carries positions and level and reads
      `spatial_index` (`simulation_pipeline.zig:246-249`).
- [x] No per-step width error. `reserve` returns `OutOfMemory` past
      `max_step_items` (`system.zig:219`, `608337b`).
- [x] `select_claim` counts placed intents, and a range owns whole bands
      (`selection.zig:78-80`, `:220`, `50225b9`). The `steering` bench
      asserts the claim item count equals the navigation intent count
      (`src/benchmarks/steering.zig:517`).
- [x] Directions writes the claimed rows' runtime columns in its steering-row
      window; the smooth tail is `smoothDirectionLanes` (`76646ef`). Path
      requests follow that steering-row order.
- [x] An empty batch shapes to zero ranges (`thread_system.zig:2449`,
      `8244f75`).
- [x] Subsystem check (owner 2026-10-16). The two `validateAiAgent` gaps
      stay on the AI findings in the roadmap index. `stuck_step_threshold`
      is capped with the other cooldown fields (`agents.zig:58`).
- [x] `buildAgentGridDirect` left with the grid (`21851e4`).
- [x] The zero-worker selection pass is gone (`608337b`). Serial `steering`
      at 128, 512, and 1024 stayed within noise.
- [x] Tests: serial equals threaded, including no workers
      (`system.zig:1013`); allocation-free after reserve on the real
      multi-worker system (`:843`).
- [x] Docs: `docs/architecture.md` steering and movement;
      `docs/simulation-tiers-and-pipeline.md` commit seam.

### Acceptance checks

- [x] `steering` tuned, Debug, `x86_64_v2`, index switch: 128 agents 193.6
      to 131.2 µs, 512 664.6 to 390.1 µs, 1024 644.4 to 445.3 µs. Serial
      +6.9% to +8.9%, within noise. Later landings on the same host: one
      selection path, serial 128 +5.9%, 512 +3.6%, 1024 +3.6%, within noise;
      tuned 512 within spread over 3 reps. Claim items, `steering-shuffled`
      tuned 1024, 4096, and 16384 within noise; tuned 128 and 512 within
      spread over 3 reps; tuned 1024 593.0 to 473.2 µs. Apply,
      `movement-apply-intents` serial: 1024 51.3 to 36.1 µs, 4096 206.8 to
      144.8 µs, 16384 922.8 to 560.6 µs; the sorted control fell by the same
      kind of amount, and the two tree medians at 4096 sit inside each
      other's spread. Directions, tuned: `steering` 1024 612.1 to 524.2 µs;
      `steering-shuffled` 4096 1.52 to 1.58 ms, within noise.
      `production-step` for the index switch was not judged (status).
- [x] `zig build verify` passes. After `55720b8`, `--summary all`: 28/28 steps,
      2032/2032 tests.
