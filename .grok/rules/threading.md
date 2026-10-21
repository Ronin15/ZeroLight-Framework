# Threading

How the thread system works: `docs/architecture.md` § Thread System.

## What runs where

- Work that grows with population, change size, or world size runs on
  workers, across chunks, levels, and world instances. Small fixed or cold
  one-off work may stay serial; the cost model (`engine-design.md`) decides.
- The main thread is never a fallback owner: it holds only orchestration,
  boundaries, and ordered merges with O(1) work per item. Growing per-item work
  threads, even under a per-step budget; scalable work never moves to main to
  ease ordering or testing.
- State transitions, structural changes, platform/GPU/audio calls, I/O, and
  resource ownership stay off workers unless a deferred boundary is designed.
  Workers never change `DataSystem` structure; structural commits batch at the
  commit seam.
- Every threaded stage ships, in its first implementation, a serial path with
  identical results and parity tests, under a named owner with immutable
  inputs and owned outputs. The serial path is the stage's own function run
  inline (no workers), the path production takes below the tuner's gate,
  never a separate entry only tests or benches call. Running inline below the
  gate is a measured choice, not a violation, while the threaded path exists.

## Building a stage

- There is one stage pattern, owned by `ThreadSystem`; new threaded work uses
  it, and a change to threading machinery is a change to `ThreadSystem`, never
  a local variant.
- A stage's items are units of its work (rows, runs, keys), so the item count
  tracks the work; never a fixed partition count with varying work behind it.
- Each production stage owns its tuner and reports its own timing. A step's
  work reaches the tuner as one sample, judged against the gate per dispatch,
  never per step total. A design states dispatches per step, items per
  dispatch, and per-item cost at each bench size.
- Worker participation follows measured timing, never fixed item-count
  floors. Before changing thread policy or a stage's shape, isolate that
  stage's timing and tuner state.
- A dispatch from inside a dispatch runs inline on its caller and touches no
  tuner: a recovered mistake, never a design. A thread that neither owns nor
  serves the thread system never dispatches.

## Writes, capacity, and determinism

- Workers write only to slots they exclusively own (per range or per worker),
  verifiable at the call site, never to a shared appendable collection. Each
  job opens by asserting its write range against the buffer length and its
  range index against the dispatched range count.
- Output capacity is reserved on the main thread before dispatch, sized from
  the value the dispatch uses; an undersized reserve is a data race, not an
  out-of-memory error.
- Output with at most one record per item writes the item's own window; output
  whose size depends on the data keeps per-range slots bounded at the seam by
  the per-item bound times the most items a range can cover (never clamped to
  the total), with counted grow-and-replay on overflow.
- Results merge in range order and never depend on worker count, timing, IDs,
  or global atomics. A batched stream commits once per batch, never per record.
- Events derived from worker-written state are emitted by the main thread
  after the join, in row order. A capped stream emits in canonical order
  before the cap, with parity tests that cross ranges and hit the cap.
- Hot loops iterate dense columns; membership masks never become dynamic
  joins.
- The range shape, not padding, keeps worker ranges off each other's cache
  lines. A stage's `range_alignment_items` is at least one lane batch and
  makes each range span at least one full cache line in every column the
  stage writes (64 B / the narrowest written element), so neighbouring ranges
  share at most the line at their boundary. Rows stay dense, each range
  streams whole lane batches, and only the stage's last range ends in the
  masked tail.
- Pad only per-range and per-worker records (slots, cursors, counters) to the
  cache-line quantum, and a contended shared record to the platform cache
  line. Never pad rows or column elements.
- Writes that land outside a range's own window (keyed by chunk, owner, or
  cell) are first bucketed by destination in range order, so each range then
  writes a contiguous window it owns. Exempt: sparse index maintenance that
  visits only changed items may write disjoint scattered records directly
  (`memory-performance.md` § Data-oriented design).

## Verification and diagnostics

- Threaded code passes ThreadSanitizer with no suppressions for framework
  code; a change to the thread system, a lane thread, or any threaded write
  merges only after a clean run.
- Allocation-free proofs run on the real multi-worker thread system.
- The runtime perf log records each change path's cost-driver stage only;
  every other stage's timing is bench output. Bench output reports an inline
  stage as inline, never as a zero-worker range.
