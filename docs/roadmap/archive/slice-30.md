## Slice 30: AI Memory And Scope-Aware AI State Policy

Goal: give agents short-term memory of recent contacts and last-known positions
with decay, and define what happens to AI state when an entity leaves the
cognition tier.

Current foundation:

- No per-entity memory exists; AI reacts only to current-frame inputs.
- Slice 24 introduces tier promotion/demotion; this slice defines the state
  policy across those transitions.

Checklist:

- [x] Add an `AiMemory` component with fixed-size scalar columns: last-known
      target position + staleness timer, a small fixed-capacity recent-contact
      ring (entity id + last-seen pos + age), and a spatial familiarity scalar —
      no per-entity `ArrayList` on the hot path.
- [x] Refresh memory from perception transitions and decay it each step
      (staleness++, familiarity toward baseline); vectorizable column math.
- [x] Feed memory to AI when perception is cold (e.g. pursue last-known
      position).
- [x] Implement the scope ↔ AI-state policy: freeze memory/affect decay on
      demotion out of cognition, resync on promotion, routed through the Slice 24
      deferred-commit path; no background per-frame work for out-of-scope agents.
- [ ] Optional `memory_expired` event (scalar-only, `domain_reaction`) if a
      reaction needs it; otherwise memory stays purely columnar. Deferred: no
      current reaction consumes ring-contact expiry, which stays a pure
      columnar decay (entity id cleared on the row, no event). Revisit if
      Slice 32 (arbitration) or Slice 33 (debug introspection) needs to react
      to a contact going stale.

Acceptance checks:

- [x] Memory updates and decay are deterministic and allocation-free; fixed-size
      storage never grows per frame.
- [x] Demoted entities preserve state with decay paused and resume correctly on
      promotion.
- [x] `zig build test` covers refresh-from-perception, decay, ring eviction, and
      demotion/promotion state continuity.

**Status: landed.** `AiMemory` component + `AiMemoryStore` (SoA, ring buffer
flattened into parallel columns) land in `data_system/`; `AiMemorySystem`
(`src/game/systems/ai_memory.zig`) runs between perception and AI in
`SimulationPipeline`, decaying staleness/familiarity/ring contacts for the
cognition-scoped `AiPerception`+`AiMemory` subset and refreshing from this
step's perception-acquisition events. `AiSystem`'s `seek` behavior retargets
toward `AiMemory.last_known_x/y` when perception reports the target cold and
memory is still fresh. Scope freeze/resync falls out of reusing the same
cognition-scope dense-index list perception/AI already gate on: a demoted
entity is simply not gathered, so its memory row is untouched until it
re-enters scope. The `memory_expired` event stays deferred (see Checklist).
A dedicated `ai-memory` bench group (`src/benchmarks/ai_memory.zig`) now
isolates decay throughput (`processed_count`) from event-driven ring refresh
(`refreshed_count`, injected for every 8th agent per step). Measured
(`--profile quick`, 10,000 agents): serial-direct 802.76us, best-threaded
(thread-large-range) 506.09us (1.58x).


