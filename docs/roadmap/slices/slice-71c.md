## Slice 71C: Cover-Aware Flee And Ranged Pursue (`cover` Interest Markers)

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 73](slice-73.md), [Slice 56B](slice-56b.md), [Slice 41](../archive/slice-41.md) · Track: [VoidLight port](../tracks/voidlight-port.md) · [Emergent AI](../tracks/emergent-ai.md)

**Status: not started.** Independent of 71A, 71B, and 71D.

Goal: the reserved `cover` marker kind feeds exactly two goals, with no score
term and no investigate input:

- **Flee:** a fleeing agent runs to the nearest authored cover that lies away
  from its threat and adds real distance, instead of a point straight away.
- **Ranged pursue:** a ranged pursuer moves to the nearest cover within its
  attack range of the target instead of closing to melee, so Slice 56's
  attack fires from there.

With no `cover` markers every score, behavior, goal, and intent is
byte-identical to today.

### Current foundation

- `InterestMarkerKind.cover` is reserved with no consumer; a marker's radius
  is its authored footprint, not a discovery gate; the faction filter is
  "restricted unless proven" with a slot-order tie-break
  (`src/game/world_interest.zig`). Investigate ignores the reserved kinds,
  pinned by a test in `src/game/systems/ai.zig`.
- Flee resolves `self + normalize(self − threat) × 96 px` from a visible
  threat, else fresh memory; pursue resolves visible → fresh memory matching
  focus → focus fallback (`src/game/systems/arbitration.zig`).
- `resolveRowArbitration` runs inside the threaded intent job and builds its
  `Signals` per row before scoring; the marker store is a read-only external
  resource of `ai_decide`.
- From earlier slices: 56B's ranged attack mode and range (≤ 256 px); 73's
  goal primitives.

### Architecture notes

- Cover is a goal-only input: flee and ranged pursue gain a cover goal
  primitive in Slice 73 behavior data; scoring and selection never see it.
- Cover is queried only for rows that selected flee or ranged pursue, after
  selection, so other rows pay nothing.
- Flee cover must lie away from the threat (never past it), within a fixed
  query radius, and add real distance from the threat; otherwise the
  straight lead stays.
- Ranged cover lies inside the attack range with a reach margin, so an
  archer stopping near the marker is always in reach; an empty band falls
  back to the normal pursue goal.
- Constants are fixed, never derived from world or content size; queries
  carry a fixed per-query budget (`.claude/rules/budgets-capacities.md`).
- Flee and pursue already wake coasting agents, so Slice 55 needs no change.
- No new persistent state; cover markers are already hashed with the marker
  store.
- Serial == threaded (`.claude/rules/threading.md`).
- VoidLight reference: the idea of fleeing toward an authored safe point;
  not its direction blend, crowd-scaled distances, or delta-time modifiers.
  Ranged cover-holding is a ZeroLight extension.

### Checklist

- [ ] Flee-cover and ranged-cover queries; module doc and `cover` tag
      comment updated.
- [ ] Cover goal primitive used by flee and ranged-pursue behavior data;
      focus-tier pursue never uses cover.
- [ ] Ranged attack range gathered for ranged pursuers only; queries after
      selection.
- [ ] Demo cover markers; pipeline test for a timid ally and an archer.
- [ ] Bench `ai-cover`.
- [ ] Docs: `docs/architecture.md` marker paragraph; Emergent AI track row.

### Acceptance checks

- [ ] Query tests: direction gate, minimum gain boundary, radius, level,
      faction, slot tie-break, ranged band boundaries, empty band, non-cover
      kinds ignored.
- [ ] A timid ally flees to a qualifying marker; an archer moves to cover
      in range, then attacks; a level-1 marker is never chosen from level 0.
- [ ] Zero-cover parity; investigate never reads cover; scores unchanged by
      cover.
- [ ] Serial == threaded; `FailingAllocator` proof passes.
- [ ] `ai-cover` recorded; `ai` within run-to-run spread; non-fleeing,
      non-pursuing rows pay nothing.
- [ ] `zig build verify` passes.
