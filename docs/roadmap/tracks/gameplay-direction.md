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

The direction is `.claude/rules/engine-design.md` § Target scale (summary:
`docs/architecture.md` § Target Model). Owner decisions it does not state:

- One observer only; there is no multi-player design.
- Worlds the observer is not in keep ambient life at their spawn tables'
  level.
- Compose signals rather than hardcode stories; domain controllers (combat,
  spawning, rules, encounters) orchestrate while SoA processors scale
  (`.claude/rules/simulation.md`).

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
