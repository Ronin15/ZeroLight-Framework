---
paths:
  - "src/**/*.zig"
---

# Threading

- Work scaling with population, terrain change, or world size runs through the
  thread system (across chunks, levels, and independent world instances) and
  ships serial and threaded paths with parity tests in its first
  implementation, under a named owner with immutable inputs and deterministic
  owned outputs. Small fixed or cold one-off work may stay serial; the cost
  model (`engine-design.md`) decides.
- Multi-threaded writes go, verifiably at the call site, to disjoint per-worker
  or per-range slots, never a shared appendable collection.
- Reserve on the main thread strictly before dispatch, sized from the value the
  dispatch uses; an undersized threaded reserve is a data race, not a clean
  OOM.
- Each worker job opens by asserting its write range against buffer length and
  `range.index` against the dispatched range count.
- The `FailingAllocator` proof exercises the real multi-worker `ThreadSystem`.
- Merged output is deterministic from range order (count, prefix offsets,
  write, range-index merge, batch commit), never worker timing, IDs, or global
  atomics.
- Call a batched `RangeOutputStream`/`SimulationEvents` `finishWrite` once per
  commit, after every range writes; per-record `finishWrite` is O(N²).
- A pass with at most one output per item writes its `[range.start, range.end)`
  window of one aligned item-capacity buffer, counting into a padded tally
  sized by `thread_system.maxRangeCount`; the main thread compacts or streams
  the windows in range order.
- Only data-dependent output (broadphase pairs) keeps per-range slots, reserved
  at the seam to the per-item bound times the most items any range can cover
  (never clamped to the total), with counted grow-and-replay on overflow.
- Events that are a pure function of worker-written row state are emitted by
  the main thread in row order after the join, with no event scratch (an
  ordered merge, O(changed rows)).
- A partitioned processor with a capped event stream emits in canonical row and
  sub-kind order before the cap, with parity tests crossing event kinds across
  ranges plus a capped case.
- Hot loops iterate dense SoA columns; component masks are membership only,
  never dynamic joins.
- Worker ranges never share writable cache lines; pad to 64 bytes only shared
  records with real false-sharing risk.
- Keep state transitions, structural changes, SDL/GPU/audio, asset and save
  I/O, and resource ownership off workers unless a deferred boundary is
  designed. Workers never mutate `DataSystem` structurally; structural commits
  batch at the commit seam.
- The main thread is not a fallback owner: it holds only those boundaries,
  orchestration, and ordered merge/commit proportional to what changed. Never
  move scalable work to the main thread to ease ordering or testing.
- Multi-stage processors have per-stage tuners and visible timing stats; a
  production processor owns its tuner state (`ThreadSystem`'s shared tuner is
  for generic callers). A stage that preselects a thread profile passes its own
  tuner with it.
- Before changing thread policy or algorithm shape, isolate per-stage timing
  and tuner state.
- Worker participation follows measured timing and structural constraints,
  never static item-count floors.
- Bench and diagnostic output reports inline stages as `inline`, never as a
  zero-worker range size.
