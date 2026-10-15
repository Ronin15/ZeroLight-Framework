## Slice 69B: Regional (Biome) Weather

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 58](slice-58.md), [Slice 59](slice-59.md) (grade and weather visuals: [Slice 60](slice-60.md)) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Needs 58 (per-chunk biome, spec loader) and 59
(environment model, modifiers, events, weather pool, grade, audio). Slice 42's
caution and this slice both read the modifier lookup; whichever lands second
migrates the other's call site.

Goal: weather is a property of place. A world with authored weather regions
rolls independent, phase-staggered weather per region; perception range, AI
move speed, and caution read the modifiers of the region under each entity,
in every world and at every fidelity. The player sees, hears, and feels the
weather of the region they stand in, with cross-faded borders. Weather stays
a pure function of `(config, env_seed, game_ms, per-chunk biome)`, so nothing
new persists. A single-region world is identical to Slice 59.

### Current foundation

- `WorldSystem.chunkCoordForWorldPos` composes `math.worldPosToCell` with
  `chunkCoordForCell` (`src/game/world_system.zig`).
- Perception gather rows carry position and level per observer
  (`systems/perception.zig`).
- Slice 59 (not landed): global weather rolls, lightning, wind, modifiers by
  level exposure, transition events, weather pool, grade, and audio.
- Slice 58 (not landed): per-chunk biome, `.none` on non-generated worlds;
  strict spec loader.
- Slice 46 folds sim-affecting, unsaved content into its content
  fingerprint.

### Architecture notes

- Region 0 is the default and reproduces Slice 59 exactly; authored regions
  map from biomes in the 58 spec. The region count is content with a
  load-time format bound; per-step cost is O(regions) and independent of
  world size (`.claude/rules/budgets-capacities.md`).
- Calendar, season, and day phase stay one per world (umbrella non-goal);
  regions differ in weather only, phase-staggered so borders do not flip
  together.
- The modifier lookup resolves a region from position and level through the
  same chunk math as `WorldSystem` (one shared pure function, so they cannot
  drift); elevated sky-exposed levels use the surface column. It replaces
  59's per-level lookup at every caller; it is row-local, so serial ==
  threaded.
- Weather and lightning events carry their region; the per-step event bound
  covers every region flipping at once.
- Presentation follows the player's region only and never feeds simulation:
  grade, air velocity, emission, thunder, and audio loops cross-fade at a
  border; emission samples region by position so rain stops at a border.
  A pool-wide air velocity is the decided model.
- Persistent: nothing new; the presentation latch is excluded; region tables
  join Slice 46's content fingerprint.
- VoidLight: port region-scoped weather re-keyed to biome regions; do not
  port player-position-triggered weather, runtime string regions, or
  singleton dispatch.

### Checklist

- [ ] Regional config and validation; per-region time base, salts, rolls,
      wind, lightning, flash, and modifiers in the pure model.
- [ ] Shared chunk-index function used by `WorldSystem` and the lookup, with
      a parity test at edges and out of bounds.
- [ ] Spec keys for weather regions and biome mapping, with rejection tests;
      one shipped region.
- [ ] Every modifier caller migrated to the positional lookup (perception,
      AI movement, 42's caution if landed).
- [ ] Events carry the region; event bound updated.
- [ ] Presentation: player-region latch and cross-fade, region-sampled
      emission, air velocity, grade, lightning filter, level-triggered audio
      loops.
- [ ] Slice 46 content fingerprint includes the region tables.
- [ ] Slice 67B event-log arm covers only the player's region.
- [ ] Docs: `docs/architecture.md` (regional model, presentation follows the
      player), `docs/simulation-tiers-and-pipeline.md` (region-keyed
      modifiers, event bound).

### Acceptance checks

- [ ] With one region, snapshots, modifiers, events, and emission equal the
      Slice 59 baseline over two game days.
- [ ] Per-region weather is deterministic, differs between regions, never
      rolls zero-weight kinds, staggers flips, and satisfies N steps == one
      jump per region.
- [ ] Lookup: region modifiers inside a mapped chunk, identity underground,
      region 0 without biomes, parity with `WorldSystem` at chunk edges.
- [ ] Two observers at night in a storm region and a clear region perceive
      a hostile differently; perception serial == threaded.
- [ ] A multi-day jump flipping every region publishes one range within
      the bound.
- [ ] A border crossing cross-fades over the fixed step count; no rain
      remains in a clear region; thunder only for player-region strikes.
- [ ] `FailingAllocator` proofs for the stage, regional emission, and render
      prep with a full pool.
- [ ] Benches: `perception` no regression with a multi-region lookup;
      `particles-weather` recorded with region sampling.
- [ ] `zig build verify` passes.
