---
name: zig-workflows
description: >-
  ZeroLight-Framework (Zig 0.17, SDL3, SDL_GPU) specialist routing: design, implement,
  debug, PR/diff review, and multi-phase review passes. Use when the user asks for
  zig-design-specialist, zig-specialist, zig-debug-specialist, or zig-review-specialist;
  when zig build, zig test, or shader compile fails; when reviewing a PR or branch diff;
  when planning ECS, DataSystem, SimulationPipeline, pathfinding, collision, AI, or
  threading changes; or when assessing emergent-gameplay architecture readiness.
  Slash: /zig-workflows.
---

# Zig Workflows (Grok-native)

The constraints are `.grok/rules/`. The pipeline is `AGENTS.md` § Agent
Pipeline. Agents are `.grok/agents/`. Presets are
[references/module-presets.md](references/module-presets.md). This file only
routes and bounds the read.

The spawn prompt is the child's whole task (`AGENTS.md` § Agent Pipeline).
Agents load `AGENTS.md`. Do not restate a rule or the agent's job in it.

## Route

Work inline when all are true: one or two files, no design question, and the
user did not ask for a specialist. A typo, a comment, a rename, or a single
test fix stays inline.

| Signal | Route |
|--------|--------|
| A slice item, including an audit finding | Design, then implement. The short path when the owner exists. The long path when it does not, and for a big feature. A finding's fix sentence does not skip design. |
| A review finding with a stated local fix on the current landing | Implement |
| An open choice in a review | Design, then implement |
| A command failed | Debug |
| The landing's code is ready | Review, the same turn |
| The slice's programming is done | Docs |
| Pathfinder / best-practices / deep-correctness / architecture | That skill |

When unsure whether the owner exists, design on the long path. Review a substantive diff. Debug a failing command.

Spawn, review split, and the parent's check are `AGENTS.md` § Agent
Pipeline. The spawn prompt does not restate this skill or the agent's job.

## Multi-phase

Load the dedicated skill rather than inlining it: `/pathfinder-review`,
`/architecture-assessment`, `/zig-best-practices-review`,
`/zig-deep-correctness-review`. Each unit reads only its preset files.
