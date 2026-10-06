## Slice 71: AI Behavior Parity And Navigation/Collision Static Fast Paths

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 55](slice-55.md), [Slice 56](slice-56.md), [Slice 61](slice-61.md), [Slice 62](slice-62.md), [Slice 63](slice-63.md) · Track: [VoidLight port](../tracks/voidlight-port.md) · [Emergent AI](../tracks/emergent-ai.md)

Umbrella for two independently landable halves (same shape as Slice 52):

- **71A** closes the VoidLight → ZeroLight AI behavior parity audit: patrol,
  follow, guard (home + leash + return-home), and the guard help call. Every
  new behavior is an arbitration table row and a `resolveGoal` arm. No
  exclusive FSMs and no per-agent cursor or timer state.
- **71B** adds the static fast paths: one shared static-collider index
  (consumed by steering, with a level gate), the collision static/dynamic
  split, and fixed-budget group-field prewarm for authored shared goals. Its
  ungated first part (71B.1) also fixes a live rule violation: the
  world-scaled group-field threshold becomes a fixed constant.

Two further sections remove the last unowned AI follow-ups:

- **71C** wires the reserved `cover` marker kind into flee and ranged-pursue
  goal resolution.
- **71D** adds AI merchant selling on Slice 63's trade substrate.

None of the four sections reshapes the Slice 32 contract (`scoreBehaviors` /
`selectSticky` / `resolveGoal`), and none adds a world-scaled budget.

### Cross-slice pointers (applied to the owning slices)

| Owner | Pointer |
| --- | --- |
| [62](slice-62.md) | **Deferred** home/leash signal → 71A |
| [61](slice-61.md) | VoidLight merchant leash → 71A |
| [63](slice-63.md) | **Deferred** guard theft alert → 71A; AI↔merchant trade emission → 71D |
| [56](slice-56.md) | Future AI trade arm → 71D |

Tables (VoidLight port track): 71A bumps the save `format_version` (v12) and
`checksum_format_tag` and appends `ai_post` (25 of 32); 71D's `gain_trade`
bumps both once (v13); 71B and 71C add no hashed or saved state; T4 places
`guard_alarm` at position 26.
