## Slice 69: World Generation Breadth And Regional Environment

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 58](slice-58.md), [Slice 59](slice-59.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Umbrella for **69A–69F**. 69A, 69B and 69C are
ungated and land in Suggested Order. 69D, 69E and 69F are complete
implementation specs that are gated on the trigger named in their own Status
line. Checklist additions to Slices 38, 42 and 58 come from the same backlog
group and are folded into those slice files, marked "(added by Slice 69)":
[38](slice-38.md) (sky exposure from elevation, `addLevel` implicit elevation), [42](slice-42.md)
(environment caution), and [58](slice-58.md) (resource interest markers).

Goal: widen Slice 58's load-time generator with caves, structures and
villages, and autotiled biome edges (69A). Make Slice 59's global weather
regional through Slice 58's `chunk_biomes` (69B). Add a deterministic time skip
with a real consumer (69C). Fully specify the three environment and world
features that have no consumer or measured need yet: scripted weather override
(69D), a per-zoom weather spawn rect (69E), and worlds larger than one bounded
`WorldSystem` (69F). Every value stays a pure function of seed, spec and clock.
Every cap is a fixed constant.

**Why six sub-slices.** Each one has its own owner files, dependencies and
acceptance evidence. The three gated ones must not keep an ungated slice open.

| Concern | Decision | Owner |
| --- | --- | --- |
| Caves | Per-stratum integer-noise pockets. The floor tile defaults to the dig tunnel tile `cave_0`. At most 16 ramp `LevelLink` entrances connect the surface and depth 1. Cave nodes and cave spawn candidates are added. AI navigation goals carry the agent's own level, so cave populations stay in their caves. The nav memory gate is unchanged because it is structural; entrances enter its `link_count` term. | 69A |
| Structures and villages | `assets/world/structures.json` holds templates and village layouts. Each fixed site cell gets at most one placement. Site selection runs in Slice 65C's `plan`, jobs suppress features under footprints, and stamping happens in `finish`. Sockets emit spawns, nodes, markers and anchors. All caps are fixed. | 69A |
| Autotile edge sets | Parse the tileset's existing `autotile_sets` (`transition_16`). Biomes get an `edge_set` key. A 4-neighbour mask maps to a pinned index table; a diagonal-only contact selects one of four inner-corner tiles, which take over the four duplicate slots 12–15. | 69A |
| Regional weather | At most 8 weather regions, mapped from biomes through `chunk_biomes`. Rolls, lightning, wind and modifiers are computed per region. No new persistent state. | 69B |
| Time skip | `Action.rest` (`SDL_SCANCODE_T`, replay bit 12) rests until dusk or dawn unless a nearby same-level hostile is tracking the player. It is applied by `environment_update`, which stays the only clock writer. Only the calendar moves; step-domain schedules do not advance. The `rest_held_last` latch is hashed and saved. | 69C |
| Scripted weather override | A persistent per-region override window on `WorldSystem`. Gated on the first scripted consumer. | 69D |
| Per-zoom weather spawn rect | The rig's presentation rect, area-scaled emission and a zoom-out prefill. Gated on a bench threshold. | 69E |
| Streaming / infinite worlds | Seamless chunk streaming is rejected. The replacement is paged regions with loading seams. Gated on a game whose world cannot be one bounded `WorldSystem`. | 69F |
| Environment caution → affect | A per-entity fear appraisal gain on Slice 42. | 42 (folded into [42](slice-42.md)) |
| `level_sky_exposed` from elevation | Derived inside `appendLevelBaseZ` from Slice 38's elevation. | 38 (folded into [38](slice-38.md)) |
| Resource interest markers at node clusters | Worldgen places them after node selection under a fixed marker cap. | 58 (folded into [58](slice-58.md)) |

**Decided non-goals.** These are decisions, not deferrals.

- Roads and rivers. Both are cross-chunk walks that depend on order; Slice 58
  already rejects VoidLight's `RIVER_MAX_FLOW_STEPS` walk.
- Re-autotiling at runtime after digs. A hole is drawn by the level below it.
- Per-region calendars, seasons or day length. There is one global calendar.
- Temperature. It has no consumer (Slice 59's ruling stands).
- NPCs crossing a 69F region seam. Only the player crosses.
- AI agents choosing navigation goals on another level. AI goals are own-level
  (69A writes `goal_level` = the row's level); levels change only through
  plane traversal and ramps. Slice 71A's out-of-scope line points here.
- Per-row weather air velocity. The pool-wide, player-region air velocity of
  69B is the decided model (see 69B Presentation).

