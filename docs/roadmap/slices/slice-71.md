## Slice 71: AI Behavior Parity And Navigation/Collision Static Fast Paths

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 71A](slice-71a.md), [Slice 71B](slice-71b.md), [Slice 71C](slice-71c.md), [Slice 71D](slice-71d.md) · Track: [VoidLight port](../tracks/voidlight-port.md) · [Emergent AI](../tracks/emergent-ai.md)

**Status: not started (umbrella over 71A, 71B, 71C, 71D);** closes when all
four are archived.

Goal: close the VoidLight → ZeroLight AI behavior parity audit and add the
static fast paths, as four independently landable sections:

- **71A**: patrol, follow, guard (home, leash, return home), and the guard
  help call, as Slice 73 behavior content plus the signals they need
  (after 55, 56, 61, 62, 63, 73).
- **71B**: one chunk-owned static-collider structure shared by steering and
  collision, the collision static/dynamic split (bench-gated), and
  fixed-budget path prewarm for authored shared goals; its fixed group-field
  threshold has landed (after 62, 71A, 64G for the prewarm part).
- **71C**: `cover` markers in flee and ranged-pursue goals (after 56B, 73).
- **71D**: AI merchant selling on Slice 63's trade substrate (after 63, 61,
  71A, 73).

### Architecture notes

- None of the four reshapes the utility contract (`scoreBehaviors` /
  `selectSticky` / `resolveGoal`; `.claude/rules/simulation.md` § AI and
  affect), and none adds a world-scaled budget
  (`.claude/rules/budgets-capacities.md`).
- Cross-slice pointers already applied in the owning slices: 62's home and
  leash signal and 63's guard theft alert are 71A; 63's AI trade emission
  and 56's AI trade action are 71D.
- Version numbers, `stage_order` positions, and component tags follow
  Tables T1–T6 (71A appends `ai_post` and the `guard_alarm` stage; 71A and
  71D each bump the checksum tag and save format; 71B and 71C add no hashed
  or saved state).
