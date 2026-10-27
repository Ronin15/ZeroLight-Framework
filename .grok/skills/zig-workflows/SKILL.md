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

The pipeline is `AGENTS.md` § Agent Pipeline. Agents are `.grok/agents/`.
Presets are [references/module-presets.md](references/module-presets.md).

Do not restate a rule or the brief in a spawn prompt. Agents load `AGENTS.md`.
The brief file is the child's whole task. The prompt cites that path.

## Route

Work inline when all are true: one or two files, no design question, and the
user did not ask for a specialist. A typo, a comment, a rename, or a single
test fix stays inline.

| Signal | Route |
|--------|--------|
| The how is open, or the structure fails the cost model | Design, then implement |
| The slice or the brief already names the change | Implement |
| A decision inside an existing owner, how still open | Design on the short path, then implement |
| A command failed | Debug |
| The landing's code is ready | Review, the same turn |
| The slice's programming is done | Docs |
| Pathfinder / best-practices / deep-correctness / architecture | That skill |

A decision inside an existing owner adds no stored result, hot loop, pass, or
budget. The brief's first line says the owner already exists. The brief
states the decision, the measurement that decides, the measurement that
reopens it, the proof, and the line ranges to read. It does not list a file
tour or a host log. The agent reads those ranges and writes the plan from
that code. A settle, merge, or remove the slice names is that design. A new
tuner architecture, a new stage pattern, or a rule edit stops for the owner.

When unsure, implement. Review a substantive diff. Debug a failing command.

## Spawn

`spawn_subagent` with `subagent_type`, `description`, `prompt`, and
`background`. Do not set a model. The prompt is the brief path. Add the
product path only when the brief does not name it. Paste nothing else.

Design, review, and docs use `background: true`. Independent read-only units
spawn together. Implement and debug run one at a time in the main tree. Do
not run design and implement together on the same files.

A review brief names the diff, its sources, and what to check. It carries no
conclusion. A debug prompt may be the failing command and the first error
block when that is the whole failure. Skip `zig build verify` until that
command is green.

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
