## Slice 69: World Generation Breadth And Regional Environment

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 58](slice-58.md), [Slice 59](slice-59.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Umbrella for **69A–69F**. 69A, 69B, and 69C are
ungated and land in Suggested Order; 69D, 69E, and 69F are gated on the
trigger in their own Status line. Additions this group made to Slices 42
and 58 live in those files, marked "(added by Slice 69)": 42 (environment
caution), 58 (resource interest markers).

Goal: widen Slice 58's generator with caves, structures and villages, and
autotiled biome edges (69A); make Slice 59's weather regional through
per-chunk biomes (69B); add a deterministic time skip that fast-forwards
the world at reduced fidelity (69C); and keep three gated features specified
as intent: scripted weather override (69D), a per-zoom weather spawn rect
(69E), and chunk storage forms for worlds whose chunks do not all fit
expanded in memory (69F). Every generated and environment value is a pure
function of seed, spec, and clock (`.claude/rules/simulation.md` § Determinism).

| Concern | Outcome | Owner |
| --- | --- | --- |
| Caves | Walkable underground pockets with surface entrances (ramp links), cave nodes, and in-cave spawns | 69A |
| Structures and villages | Authored templates and village layouts stamped at site cells, with sockets for spawns, nodes, markers, and a settlement anchor | 69A |
| Autotile edge sets | Biome edges use the tileset's existing 16-tile transition sets | 69A |
| Regional weather | Weather regions mapped from biomes; rolls, lightning, wind, and modifiers per region; no new persistent state | 69B |
| Time skip | Fast-forwards the world's simulation at reduced fidelity to the next dusk or dawn; a game with a player may call it rest | 69C |
| Scripted weather override | A persistent per-region override window | 69D (gated) |
| Per-zoom weather spawn rect | Weather spawns over what the zoomed camera shows | 69E (gated) |
| Large worlds | Chunk storage forms chosen by activity; every form keeps simulating | 69F (gated) |
| Environment caution → affect | Per-entity fear gain | 42 |
| Sky exposure from elevation | Derived where a level is appended | 38 |
| Resource markers at node clusters | Placed by worldgen after node selection | 58 |

**Decided non-goals.**

- Roads and rivers: order-dependent cross-chunk walks (Slice 58 rejects
  VoidLight's river walk).
- Re-autotiling at runtime after digs: a hole is drawn by the level below.
- Per-region calendars, seasons, or day length: one calendar per world.
- Temperature: no consumer (Slice 59).
- Per-row weather air velocity: the pool-wide, player-region air velocity of
  69B is the model.
