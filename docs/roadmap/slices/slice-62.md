## Slice 62: NPC Population, Spawning, And Spawn Tables

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 49](slice-49.md), [Slice 57](slice-57.md), [Slice 58](slice-58.md), [Slice 59](slice-59.md), [Slice 63](slice-63.md), [Slice 64G](slice-64g.md), [Slice 75](slice-75.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Needs 49 (seed domain, `sim_view`), 58 (spec and
per-chunk biome), 59 (day phase), 63 (merchant profiles and ledgers), 57
(merchant stock), and 64G (walkability over chunk-owned nav). Slice 75 sets
the fidelity at which spawned agents run far from the observer; 69A places
village anchors; 71A adds home and leash.

Goal: data-driven, deterministic population in every world. World-anchored
spawn points draw from spawn tables: weighted tables (archetype × faction ×
biome × time) and roster tables with fixed counts (VoidLight's merchant + 2
guards + 4 villagers). Population that matters (people, villagers, guards,
merchants) persists and advances wherever it is, whether or not the
observer is in its world, and roster anchors replace losses on their
interval. Only ambient spawns (stray monsters, animals) appear near the
observer out of view and may be recycled far from it, with hysteresis;
worlds the observer is not in keep ambient life at their spawn tables'
level. All of it flows through
deferred create and destroy commands from one pipeline controller, reading
only committed state and the fixed-step sim view.

### Current foundation

- Tier bands `cognition/locomotion/kinematic_halo_chunks = 16/32/48`,
  `SimulationTier` (still with a `dormant` tier), `tierForChunkDistance`
  (`src/game/simulation_scope.zig`); Slice 75 removes dormancy for agents.
- `tier_policy` reads Slice 49's `simViewRegion`; `visibleChunkRegion()` is
  render-only after 49.
- Deferred structure: `StructuralCommand.create_entity` / `destroy_entity`
  with all-or-fail preflight; destroy-then-create slot reuse is
  allocation-free after preflight (`data_system/system.zig` test).
- Archetype bundles (`AiArchetypeCatalog.bundleForId`, `ai_archetypes.zig`);
  the archetype JSON has no body or visual block; demo spawn builds
  templates by hand and sizes from `battle_scale_demo_mover_count`.
- `InterestMarkerStore` (`world_interest.zig`) is the generational world-store
  precedent (fixed 128 inline slots).
- Placement predicates: `world_gate.rectOverlapsSolidTile` and nav cell
  blocking (`NavGrid.isBlockedCell`, replaced by 64G).

### Architecture notes

- Owner direction: important population persists and advances wherever it
  is; only ambient spawns may be recycled far from the observer. Every world
  simulates; distance lowers fidelity, never stops progress
  (`.claude/rules/engine-design.md` § Target scale).
- Each spawned row carries its anchor, entry, and class: `important`
  (never despawned by population) or `ambient` (recyclable). The class is
  table content, and stale anchors never turn important rows ambient.
- Spawn anchors are per-world content (worldgen, 69A villages, demo
  anchors), stored with their world and released with it; the store grows at
  the seam, and only its index width is a format bound
  (`.claude/rules/budgets-capacities.md`). Per-step anchor work is
  chunk-local and independent of world size and total anchor count.
- Important roster refill runs wherever the anchor is, in every world, on the
  anchor's interval; it needs no observer.
- In the observer's world, ambient spawning happens only outside its view
  and inside a band near it; recycling happens only beyond a farther band,
  with hysteresis so nothing flaps (75's far-from-observer signal). Owner
  decision (2026-10-08): worlds the observer is not in keep ambient life at
  their spawn tables' level. Worldgen's initial population carries its
  table's class.
- No global or per-world population cap: totals follow anchor content
  (`max_alive` per anchor). Per-step spawn, recycle, and evaluation counts are
  fixed budgets with deterministic deferral; a group that does not fit this
  step waits, never starves.
- Placement is integer-only and seeded on `seed.derive(.population)` by
  anchor and member, never entity or worker order; candidates on blocking
  terrain or overlapping this step's accepted ones are rejected; an
  all-rejected group defers.
- Population capacity grows at Slice 72's commit-seam sync point; spawned
  inventories rely on 57's seam growth.
- No new events: spawns surface as entity create/destroy commit events.
- Persistent: anchors (live slots) and spawn origin are hashed and saved;
  derived indexes are rebuilt on load (Slices 49 / 46, same change); the
  table catalog fingerprint joins Slice 46's content fingerprint.
- VoidLight: port the settlement roster, wilderness tables, no-stacking,
  bounded seeded placement, respawn, `once`, time windows, and merchants as
  ordinary entries; do not port thread-local RNG, frame-assumed timers,
  string overrides, world-sized grids, or whole-world block scans.

### Checklist

- [ ] Per-world spawn anchor store with generational IDs and a chunk-local
      band query; grows at the seam.
- [ ] Spawn-origin component (anchor, entry, `important` / `ambient`).
- [ ] Slice 49 / 46 classification and save sections; derived index rebuilt
      on load.
- [ ] `SeedDomain.population` (Slice 49 reserved value).
- [ ] Archetype `body` / `visual` / `steering` blocks; `merchant`, `guard`,
      `villager` archetypes.
- [ ] Strict spawn-table loader (weighted and roster modes, biome and time
      filters, class per entry, merchant profiles via 63).
- [ ] Population controller stage: important refill everywhere, ambient
      spawn near the observer and recycle far from it, ambient life at table
      level in worlds the observer is not in, fixed per-step budgets, integer
      placement, deferral.
- [ ] Worldgen anchor placement (58 spec extension) at content density.
- [ ] Merchant roster entry with 63's ledger and 57's stock.
- [ ] Population capacity terms flow through the commit-seam sync; structural
      share for spawn and recycle bursts.
- [ ] (added by Slice 67) Strings as `StringId`s if this lands after 67E.
- [ ] Docs: `docs/architecture.md` (anchors, classes, controller),
      `docs/simulation-tiers-and-pipeline.md` (stage, bands, sim-view
      source).

### Acceptance checks

- [ ] An anchor fills to `max_alive` across evaluations within per-step
      budgets; `once` anchors spawn once.
- [ ] Roster counts hold: a killed guard is replaced after its interval in a
      world the observer is not in.
- [ ] A world the observer is not in holds ambient life at its spawn
      tables' level.
- [ ] Important rows are never despawned at any distance; ambient rows
      beyond the recycle band are, and moving the view across both bands
      never loops spawn and recycle (hysteresis).
- [ ] No ambient row spawns inside the observer's view.
- [ ] Render-window changes between steps leave the spawn and recycle
      streams identical.
- [ ] Same seed gives identical spawns, positions, and templates; a
      different seed differs.
- [ ] All-blocked placement defers deterministically with stats.
- [ ] Anchors outside the band (any count) leave the selected anchors and
      spawn stream unchanged.
- [ ] Steady spawn and recycle churn allocates nothing (`FailingAllocator`);
      whole-pipeline serial == threaded with spawning enabled.
- [ ] Benches `population-anchor-sweep` (per-step cost flat across total
      anchor count) and `population-spawn-burst`.
- [ ] (added by Slices 68A–68C) The 68A re-baseline procedure is run and this
      slice's rows recorded.
- [ ] `zig build verify` passes.
