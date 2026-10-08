## Slice 38: Elevation Above The Surface

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 37](../archive/slice-37.md) · Track: [Long-term gameplay direction](../tracks/gameplay-direction.md)

**Status: not started.** Prerequisite Slice 37 is landed.

Goal: let a world represent levels above the surface (not just underground
depth below it) as an explicit, stable per-level fact, and generalize the
dense render window to a symmetric above/below policy — so elevation, not
append order or storage index, determines what "surface" means.

Depends on: Slice 37 (landed, archive: shader/host sync and the fixed GPU-byte literal).
Elevation uses the existing `k_max_dense_submit_stack_cap`. A world whose
submit window does not fit that cap is refused with `DenseLayerWindowExceeded`.
This slice does not raise the cap.

Problem (current envelope):

- `WorldSystem.level_base_z` / `world_level: u16` is a plain 0-based,
  append-order storage index everywhere (`NavGraph.levels`, `LevelLink`,
  `CellCoord`, `DataSystem.world_level`) — none of that needs to change, since
  it's always treated as an opaque stable index, never a signed or centered
  value.
- But "level 0 is the surface" is not just a storage convention. These live
  sites still treat index 0 as the surface. Slice 48 moved the walk gates out
  of `simulation_pipeline.zig`; this slice does not edit that file for them.
  - `dig_controller.zig`: `process` uses `current_level == 0` to choose
    `clearDenseTile` vs `setDenseTile`, and returns early for a ramp on level
    0. `setEntityLevel` returns immediately when `level == 0`. `digRamp`
    treats `level - 1` as the plane above.
  - `src/game/systems/world_gate.zig`: `gateBodyToWalkableTiles` and
    `gateBodyColumnsToWalkableTiles` return immediately when `level == 0`.
  - `src/game/systems/pathfinding/nav_graph.zig`: the full rebuild calls
    `markStaticBodies` only when `level == 0`. The incremental full-level loop
    also calls `markStaticBodies`.
  - `src/game/systems/pathfinding/nav_grid.zig`: `markStaticBodies` returns
    when `self.level != 0`, so non-zero levels never receive `DataSystem`
    collision bodies.
  A level above index 0 would otherwise inherit the surface's
  no-collision, no-snap, hole-not-tunnel treatment, and non-surface levels
  would stay out of the nav grid.
- `DenseLayerRenderWindow.ceiling_when_underground` is the only existing
  "look upward" mechanic, and it's a narrow, explicitly-documented special
  case (exactly one level above the active level, whole-layer-only —
  "cannot do per-cell shaft cull") — not a pattern to generalize from.

Current foundation (landed):

- Slice 37 (archive): `k_max_dense_submit_stack_cap` is 32, shader/host layer
  offsets are tied to that cap, and the demo's byte budget is the literal
  `k_max_dense_tile_gpu_bytes`. This slice uses that cap. It does not redesign
  compositing and it does not widen the cap.
- `worldZForLevel` already saturates Z to the `i32` range via `i64` math — no
  overflow risk from added elevated levels.
- `addUndergroundLevelStack` / `addLevel` (`world_system.zig`) already
  correctly append levels with negative Z going deeper; this slice adds a
  parallel "above" path, it does not change the existing one.

Architecture notes:

- Add an explicit `level_elevation: std.ArrayList(i32)` column to
  `WorldSystem`, always the same length as `level_base_z` (enforced at the
  single `appendLevelBaseZ` choke point, not by caller convention) — not a
  signed storage index, and not derived from `base_z` or append order.
  `base_z` stays a free-form, caller-supplied render/Z-sort value (existing
  tests already pass arbitrary non-multiple values); coupling elevation to it
  or to build order would make elevation an implicit fact with no compiler or
  runtime signal if a future change reordered level construction — exactly
  the kind of derived-not-stored fact this project's stable-ID discipline
  avoids elsewhere (`LevelLink` / `CellCoord`).
- `addLevel`'s existing signature is unchanged (defaults `elevation = 0`
  internally) so none of its ~30 existing call sites need to change;
  `addUndergroundLevelStack` passes the real negative tier it already
  computes the sign for. New `addElevatedLevelStack` mirrors
  `addUndergroundLevelStack`'s shape for positive elevation — scoped as
  allocation/indexing only in this slice (no default fill tile the way
  underground gets solid dirt; there's no universal "what's above the world"
  content yet, so leave dense-floor authoring for elevated levels to the
  caller via the existing `addDenseLayer`).
- New `pub fn levelElevation(self, level_index: u16) i32` — O(1) lookup, `0`
  at the surface, positive above, negative below.
- `DenseLayerRenderWindow.ceiling_when_underground: bool` is replaced by
  `levels_above: u16 = 0` (default preserves today's behavior byte-for-byte —
  today's default never looks above the active level either way).
  `levelInWindow` is rewritten in elevation-relative terms
  (`world_elevation <= active_elevation` → within `levels_below`; else within
  `levels_above`) instead of raw-index arithmetic, removing the narrow
  "only when underground" conditional entirely.
- Migrate the surface special cases onto `levelElevation(...) == 0`. Do not
  edit `simulation_pipeline.zig` for `gateBodyToWalkableTiles`; that symbol is
  the private `world_gate.gateBodyToWalkableTiles`.
  - `dig_controller.zig`: the hole-vs-tunnel branch and `setEntityLevel`'s
    surface return become `world.levelElevation(level) == 0`.
  - `world_gate.zig`: `gateBodyToWalkableTiles` and
    `gateBodyColumnsToWalkableTiles` use the same elevation check in place of
    `if (level == 0) return`.
  - `nav_graph.zig`: the rebuild's `level == 0` guard around `markStaticBodies`
    follows elevation, and the incremental full-level `markStaticBodies` call
    still runs for every dirty level.
  - `nav_grid.zig`: `markStaticBodies` stamps `DataSystem` collision bodies for
    a non-zero level. Remove the `if (self.level != 0) return` surface
    exemption once the caller passes elevation through.
  **`digRamp`'s "no-op on the surface, nothing above" check needs new logic,
  not a rename** — once index 0 has no privileged geometric meaning, "is
  there a level above this one" must become an elevation-adjacency lookup (a
  level whose elevation is this level's elevation + 1), not an index
  comparison. Do not treat this as mechanical find-replace.
- Explicitly out of scope for this slice (deferred, not silently dropped):
  actual elevated-world demo content/tile authoring (fill tiles, ramps up
  into an elevated stack, any new dig/build tool targeting elevation). The
  GPU-byte ceiling is Slice 37's fixed literal; this slice does not scale it
  from elevation count or from machine RAM/VRAM. A window that does not fit
  `k_max_dense_submit_stack_cap` is refused.

**Sky exposure follows elevation (Slice 59 coordination; added by Slice 69).**

- Slice 59 appends `level_sky_exposed` at `appendLevelBaseZ(base_z,
  sky_exposed)`, with `addLevel` passing `level == 0`.
- Once Slice 38 lands, the choke point becomes `appendLevelBaseZ(base_z,
  elevation: i32)`. It computes `sky_exposed = elevation >= 0` itself. The
  caller-supplied `sky_exposed` parameter is deleted, so no caller can disagree
  with elevation.
- All three lists (`level_base_z`, `level_elevation`, `level_sky_exposed`) are
  reserved with `ensureUnusedCapacity` before any is appended, then filled with
  three `appendAssumeCapacity` calls. This extends Slice 59's two-list rule.
- `addUndergroundLevelStack` passes its negative tier, so its levels are not
  exposed (unchanged). `addElevatedLevelStack` passes positive elevation, so
  its levels are exposed. Both pre-reserve all three lists for their count.

**`addLevel`'s implicit elevation (amends "defaults `elevation = 0`
internally"; added by Slice 69).**

- The rule: elevation 0 when the world has no levels; otherwise one tier below
  the current lowest level (`minElevation() - 1`).
- Why not 0 for every call: a default of 0 would give every later `addLevel`
  in a multi-level fixture elevation 0. Those levels would become sky-exposed
  and, under Slice 38's own `levelElevation == 0` migrations, would also be
  treated as the surface. That silently changes fixtures that build
  underground levels with repeated `addLevel`, including:
  - `src/game/render_prep.zig:1164,1422,1506`;
  - `src/game/world_system.zig:3616,3650,3688,3745`;
  - the multi-level pathfinding and pipeline fixtures.
- With "one below the lowest", an `addLevel`-only world has
  `levelElevation(i) == -i`, so `levelElevation(level) >= 0` ⇔ `level == 0`,
  bit for bit with Slice 59.
- The signature of `addLevel` is unchanged.
- Worlds that need levels above the surface use `addElevatedLevelStack`.

Checklist:

- [ ] Add `WorldSystem.level_elevation` column, populated at the single
      `appendLevelBaseZ` choke point so it can never drift out of
      length-sync with `level_base_z`.
- [ ] Add `levelElevation()` accessor; update `addUndergroundLevelStack` to
      pass real negative elevation.
- [ ] Add `addElevatedLevelStack` (allocation/indexing only, mirroring
      `addUndergroundLevelStack`'s shape) for positive-elevation levels.
- [ ] Replace `DenseLayerRenderWindow.ceiling_when_underground` with
      `levels_above: u16 = 0`; rewrite `levelInWindow` / `maxLevelSpan` in
      elevation-relative terms; confirm `levels_above = 0` reproduces today's
      behavior exactly.
- [ ] Migrate `dig_controller.zig`'s `current_level == 0` hole-vs-tunnel branch,
      its ramp early-return, and `setEntityLevel`'s `level == 0` return to
      `levelElevation(...) == 0`.
- [ ] Migrate `world_gate.gateBodyToWalkableTiles` and
      `gateBodyColumnsToWalkableTiles` off `if (level == 0) return` to the
      same elevation check. Do not edit `simulation_pipeline.zig` for these.
- [ ] Migrate `nav_graph.zig`'s rebuild so `markStaticBodies` is not limited to
      `level == 0`, keep the incremental full-level `markStaticBodies` call,
      and change `nav_grid.markStaticBodies` so `if (self.level != 0) return`
      no longer drops non-surface collision bodies.
- [ ] Migrate demo interest-marker placement
      (`game_demo_state.placeDemoInterestMarkers`) off hardcoded `level = 0` to
      the surface elevation (`levelElevation(...) == 0` / surface level index)
      so elevated stacks above the surface do not leave POIs on the wrong tier.
- [ ] Replace `digRamp`'s raw index-0 "nothing above" check with an
      elevation-adjacency lookup (a reachable level at
      `levelElevation(level) + 1`), verified against a real multi-tier
      (elevated + surface + underground) fixture, not just the current
      surface-and-below-only demo world.
- [ ] Update `docs/architecture.md` / `docs/simulation-tiers-and-pipeline.md`
      wherever they describe level 0 as structurally special, to describe
      elevation instead.
- [ ] (added by Slice 69) `appendLevelBaseZ(base_z, elevation)` derives `sky_exposed = elevation
      >= 0` and appends `level_base_z`, `level_elevation` and
      `level_sky_exposed` only after all three are reserved. Slice 59's
      `sky_exposed` parameter is removed. `levelSkyExposed()` and its
      consumers (weather emission, `EnvironmentModifierLookup.level_sky_exposed`,
      `GameplayScene.weather_visible`, grade) are unchanged.
- [ ] (added by Slice 69) `addLevel` implicit elevation = 0 for the first level, else
      `minElevation() - 1`. `addUndergroundLevelStack` and
      `addElevatedLevelStack` pre-reserve all three lists for their count.
- [ ] (added by Slice 69) Slice 49 / 46 classification:
      - `level_elevation` is hashed and saved;
      - `level_sky_exposed` stays hashed and saved (unchanged classification,
        so no `checksum_format_tag` bump);
      - Slice 46's loader rejects a file where `level_sky_exposed[i] !=
        (level_elevation[i] >= 0)` with `SaveCorrupt`.
- [ ] (added by Slice 69) Tests:
      - an elevated + surface + underground fixture has `levelSkyExposed` true
        exactly where `levelElevation >= 0`;
      - an `addLevel`-only 3-level fixture yields `[true, false, false]`,
        which is Slice 59's parity;
      - a `FailingAllocator` OOM on each of the three reserves leaves all three
        lengths equal and unchanged;
      - with a night lookup, perception range scales on an elevated level and
        not on an underground one.

Acceptance checks:

- [ ] New tests: `levelElevation` correctness for surface/underground/elevated
      levels; `addElevatedLevelStack` index/elevation bookkeeping (parity with
      existing `addUndergroundLevelStack` tests); symmetric `levelInWindow`
      behavior (above only, below only, both at once).
- [ ] The migrated dig sites, both `world_gate` walk gates, and
      `markStaticBodies` are re-proven against a world whose surface is *not*
      index 0 (at least one elevated level above it). A non-zero level receives
      `DataSystem` collision bodies. Today's demo alone would not catch a
      regression back to "surface == index 0". `simulation_pipeline.zig` has
      no `gateBodyToWalkableTiles` edit in this slice.
- [ ] `digRamp`'s elevation-adjacency replacement is verified against a real
      multi-tier fixture (zig-debug-specialist review recommended given this
      is the one non-mechanical change in this slice).
- [ ] `zig build verify` passes.

