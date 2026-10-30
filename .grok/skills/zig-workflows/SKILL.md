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
| The how is open, or the structure fails the cost model | Design, then implement |
| The change is already decided | Implement |
| A decision inside an existing owner, how still open | Design on the short path, then implement |
| A command failed | Debug |
| The landing's code is ready | Review, the same turn |
| The slice's programming is done | Docs |
| Pathfinder / best-practices / deep-correctness / architecture | That skill |

When unsure, implement. Review a substantive diff. Debug a failing command.

## Spawn

`spawn_subagent` with `subagent_type`, `description`, `prompt`, and
`background`. Do not set a model. The prompt is the task in `AGENTS.md`
§ Agent Pipeline.

Design, review, and docs use `background: true`. Independent read-only units
spawn together. Implement and debug run one at a time in the main tree. Do
not run design and implement together on the same files.

A large diff is two review prompts, spawned together, split on files that
do not share a write. The parent merges the reports into one finding list.
A debug prompt is the failing command and the first error block when that
is the whole failure. Skip `zig build verify` until that command is green.

The parent checks a load-bearing claim against the function it cites and
against the command output. It does not re-walk the file.

## After

A review finding with a stated local fix goes to implement and folds into
the landing commit. An open choice goes to design. Do not start a second
review round. Docs notes ride the landing commit. The docs specialist writes
the slice's docs commit from the code as landed and does not commit.

## Multi-phase

Load the dedicated skill rather than inlining it: `/pathfinder-review`,
`/architecture-assessment`, `/zig-best-practices-review`,
`/zig-deep-correctness-review`. Each unit reads only its preset files.
