## Slice 25E: Per-Entity NPC Level And Autonomous Z-Traversal

**Status: landed**, with one superseded item. All Checklist and Acceptance
checks below are `[x]` for the record, but `PathView.next_cell_level`
(checklist items below referencing it) was later found to have zero
production consumers — `steering.zig`'s `directionFromPathStatus`, the only
real caller of `statusForWorld`/`statusForKeyAndStart`, never read it — and was
removed as dead code. The actual NPC level-transition mechanism is, and always
was, `DigController.applyEntityPlaneTraversal` (invoked from
`SimulationPipeline.applyNpcPlaneTraversal`), which drives transitions from the
entity's real physical-cell world geometry with no lag/latency gap. See
`docs/coding-standards.md`/project convention: code is authoritative for doc
drift, so this note replaces the earlier "landed" claim for the
`next_cell_level` field specifically; the rest of the slice (per-entity level
column, steering `start_level` sourcing, render cull by entity level) is
unaffected and still landed as described.

Goal: give each NPC entity its own Z-level so it can request cross-level paths,
traverse ramps and stairs autonomously, and be culled to its own floor instead
of always rendering on the player's level.

Prerequisite context: Slice 23B scales **dense floor** submission (~120 layers);
this slice scales **entity** level columns and NPC draw cull. Player floor
policy (`GameplayScene.player_level` → `submitStaticDenseGeometry`) stays in
23B; NPCs need their own level column and render-prep filter here.

Current foundation:

- Slice 25 provides a fully correct two-tier nav substrate with `LevelLink`
  records and cross-level A* corridor stitching.
- `PathRequest`/`NavigationIntent` already carry `start_level`/`goal_level`
  fields (added in 25C); steering hardcodes `start_level = 0`.
- The per-level portal graph, `PathView`, and link-edge traversal are complete.

Problem (confirmed silent-behavior gap):

- `steering.zig` `writePathRequests` hardcodes `start_level = 0` and
  `statusForEntityWorld(..., 0, ...)` ignores the entity's actual floor.
- `PathView` exposes `next_waypoint` XY but no level; an agent crossing a link
  cannot detect the level transition and update its own Z.
- Ramp/fall plane-traversal logic is player-only (`game_demo_state.zig`).
- NPCs are drawn at their XY on whatever level the player occupies, so an NPC
  pursuing the player underground appears to teleport along its level-0 path.
  This produces wrong-but-non-crashing behavior that attributes to AI logic,
  not a routing defect.

Checklist:

- [x] Add a per-entity level (Z) column to `DataSystem` (cold metadata, default
      surface level `0`), following the component-store pattern; initialize in
      `createEntity`.
- [x] Steering sources `start_level` from the entity's level column rather than
      the hardcoded `0`.
- [x] Extend `PathView` to expose `next_cell_level` alongside `next_waypoint`
      so an agent can detect a link crossing and commit a level update. (Later
      removed: no production consumer ever read this field — see status note
      above.)
- [x] Update the per-step movement/traversal pass to apply NPC level transitions
      at link cells (mirroring the player ramp/fall logic); update the entity
      level column through an explicit main-thread commit, not inside worker
      ranges. (Landed via `DigController.applyEntityPlaneTraversal` driven by
      physical-cell world geometry, not via the removed `next_cell_level`.)
- [x] Render and cull each NPC on its own level, not the player's.
- [x] Add tests covering same-level NPC pathing (no regression), cross-level
      pathfinding, and NPC render cull matching entity level. (The
      `next_cell_level`-specific assertions were removed alongside the field;
      the remaining status/waypoint/render-cull assertions still cover this.)
- [x] Demo stress: procedural world `addUndergroundLevelStack(31)` (32 levels),
      32 movers, GPU budget gate, scaled pipeline reserves.

Acceptance checks:

- [x] Cross-level path queries route through link cells correctly (pathfinding
      + caches tests); NPC traversal commits `world_level` on ramp/fall cell
      entry via `DigController.applyEntityPlaneTraversal`, not via
      `next_cell_level` (removed — see status note above).
- [x] Intra-level NPC behavior is unchanged (steering parity tests).
- [x] NPCs are culled to their own level, not the player's (`render_prep` test).
- [x] No steady-state allocation on hot paths.
- [x] `zig build test`, `zig build check`, and `zig build verify` pass.


