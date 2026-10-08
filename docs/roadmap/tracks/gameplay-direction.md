## Long-Term Gameplay Direction

> [Roadmap index](../../framework-implementation-slices.md)

Future features land as slices (Goal, Checklist, Acceptance before
implementation); the rules they follow are in `.claude/rules/`
(`simulation.md` for controllers, processors, AI, and events). Durable boundaries:
[architecture.md](../../architecture.md); emergent-AI shared contracts:
[Emergent AI Track Overview](emergent-ai.md); VoidLight port shared contracts
(seed, sim view, action claims, inventory transfers, settings) and the
authoritative cross-slice tables: [VoidLight Port Track Overview](voidlight-port.md).

Direction: compose signals rather than hardcode stories — perception, memory,
and emotion drives feed utility arbitration; locomotion and action stay
separate streams; goals are per-agent and multi-source; authoring is data
resolved at load; domain controllers (combat, spawning, rules, encounters)
orchestrate while SoA processors scale.

