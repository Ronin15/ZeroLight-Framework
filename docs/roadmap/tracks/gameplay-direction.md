## Long-Term Gameplay Direction

> [Roadmap index](../../framework-implementation-slices.md)

Future features land as slices (Goal, Checklist, Acceptance before
implementation); the rules they follow are in `.claude/rules/`
(`engine-design.md` § Target scale for scale, `simulation.md` for
controllers, processors, AI, and events). Durable boundaries:
[architecture.md](../../architecture.md); emergent-AI shared contracts:
[Emergent AI Track Overview](emergent-ai.md); VoidLight port shared contracts
(seed, sim view, action claims, inventory transfers, settings) and the
authoritative cross-slice tables: [VoidLight Port Track Overview](voidlight-port.md).

### Direction (owner, fixed)

- **Colony-simulator base, one observer.** The player entity is optional.
  One observer is targeted: the camera focus, or a player when a game has
  one. Fidelity is anchored on the observer; there is no multi-player
  design.
- **Fully simulated, multi-world.** Everything that exists keeps advancing in
  every world. Distance from the observer lowers fidelity, never stops
  progress: far-off AI thinks on slower ticks, movement stays near full rate.
  Worlds the observer is not in still step at lower fidelity.
- **Dormant means inert.** Only things at rest (items on the ground) are
  dormant, and they still change slowly: items decay outdoors.
- **Population.** People, villagers, and NPCs persist and advance wherever
  they are. Only unimportant ambient spawns (stray monsters, animals) may be
  recycled far from the observer; worlds the observer is not in keep ambient
  life at their spawn tables' level.
- **Chunks.** Chunk `(level, cx, cy)` is the unit of terrain and nav storage,
  change, work, threading, and save. Nav covers the whole world; residency is
  a chunk's storage form, never whether it simulates. Nothing is evicted from
  the simulation.
- **Worlds.** Persistent worlds and dungeons are created and destroyed in
  play and own their storage.
- **Composition.** Compose signals rather than hardcode stories: perception,
  memory, and emotion drives feed utility arbitration; locomotion and action
  stay separate streams; goals are per-agent and multi-source; authoring is
  data resolved at load; domain controllers (combat, spawning, rules,
  encounters) orchestrate while SoA processors scale.

### Slices that carry it

| Concern | Slices |
| --- | --- |
| Chunk-owned terrain and nav | [64G](../slices/slice-64g.md) |
| World instances (create, step, destroy in play) | [74](../slices/slice-74.md) |
| Far simulation (fidelity by distance from the observer, every world) | [75](../slices/slice-75.md) |
| Data-driven cognition | [73](../slices/slice-73.md) |
| Worldgen on chunk-owned terrain | [58](../slices/slice-58.md), [69A](../slices/slice-69a.md), [69F](../slices/slice-69f.md) |
| Items at rest (dormant, outdoor decay) | [57](../slices/slice-57.md) |
| Persistent and ambient population | [62](../slices/slice-62.md) |
| Per-world time and weather | [59](../slices/slice-59.md), [69B](../slices/slice-69b.md), [69C](../slices/slice-69c.md) |
