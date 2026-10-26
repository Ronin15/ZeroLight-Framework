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

Canonical guardrails: root `AGENTS.md` and `.grok/rules/`.

**Agents:** `.grok/agents/zig-*.md` (Grok-native source of truth).  
**Presets:** [references/module-presets.md](references/module-presets.md).  
**Multi-phase skills:** `/pathfinder-review`, `/architecture-assessment`,
`/zig-best-practices-review`, `/zig-deep-correctness-review`.

Do not restate full guardrails in `spawn_subagent` prompts. Agents load `agents_md`.

## Inline vs delegate

Work **inline** (no subagent) when ALL are true:

- One or two files, localized change
- No architecture, pipeline-order, or DataSystem contract change
- User did not ask for a specialist or review pass
- Examples: typo, comment, single test fix, rename, fmt-only

**Delegate** when ANY are true:

| Signal | Workflow |
|--------|----------|
| Non-trivial feature or slice | Design → Implement |
| User names a specialist | Matching workflow below |
| `zig build` / test / shader / runtime failure | Debug |
| PR, diff, or standards review | Review |
| Module-wide pathfinder pass | `/pathfinder-review` skill |
| ECS extensibility / roadmap assessment | `/architecture-assessment` skill |
| Large-subsystem best-practice pass | `/zig-best-practices-review` skill |
| Deep correctness / concurrency / algorithm pass | `/zig-deep-correctness-review` skill |
| Touches hot paths, threading, or pipeline stages | Implement (or Design first if unclear) |

When unsure: **Implement** for coding tasks, **Review** after substantive diffs,
**Debug** for any failing command output.

## Shared spawn conventions

Use `spawn_subagent`. Only the parent session may spawn (depth limit 1).
Pass `subagent_type`, `description`, `prompt`, and `background`.

| Subagent | Tools | Next |
|----------|--------|------|
| `zig-design-specialist` | `read_file`, `grep`, `list_dir`, `run_terminal_command`, `write`. No `search_replace`, no `spawn_subagent`. | Implement |
| `zig-specialist` | those, plus `search_replace` and `write`. No `spawn_subagent`. | Review once the code is ready |
| `zig-debug-specialist` | same as implement. No `spawn_subagent`. | Review if the fix is hot-path |
| `zig-review-specialist` | same as design. No `search_replace`, no `spawn_subagent`. | A stated local fix goes to implement; an open choice goes to design |

- Read-only units (design, review) may spawn together with `background: true`.
  Collect them with `get_command_or_subagent_output`.
- `zig-specialist` and `zig-debug-specialist` run one at a time in the main tree.
  Do not run design and implement together on the same files.
- Do not set a model. Each agent sets `model: inherit`. Pins, if any, live in
  `~/.grok/config.toml` under `[subagents.models]`.

## Invocation examples

User says → do:

- "Review my branch" → **Review**, scope `branch changes`
- "Review only uncommitted" → **Review**, scope `uncommitted changes`
- "Fix this test failure" + error output → **Debug**
- "Design the arbitration system before we code" → **Design**
- "Implement slice X" → **Design** first if contracts unclear, else **Implement**
- "Review the pathfinder module" → run `/pathfinder-review` skill steps
- "Best-practices review of hot subsystems" → `/zig-best-practices-review`
- "Deep correctness pass on threading/pathfinding" → `/zig-deep-correctness-review`
- "How ready is this for emergent gameplay?" → `/architecture-assessment`

## Design

```
subagent_type: zig-design-specialist
background: true
```

Prompt: goal, in/out of scope, owning slice, files/areas, constraints.

## Implement

```
subagent_type: zig-specialist
```

Prompt: owning module(s), success criteria, validation commands, prior design if any.

## Debug

```
subagent_type: zig-debug-specialist
```

Prompt: failing command + full first error block (verbatim), recent changes, display
available for `zig build gpu-smoke`?

Skip `zig build verify` until the targeted command is green.

## Review

```
subagent_type: zig-review-specialist
background: true
```

```text
Full Repository Path: <abs path>
Review scope: branch changes | uncommitted changes | <file list>
Base Branch: <only if non-default base>
Custom Instructions: <optional>
```

Summarize as a severity-sorted table; do not fix unless asked.

## Multi-phase workflows

For module / architecture / best-practices / deep-correctness passes, **load the
dedicated skill** (slash or auto-invoke) rather than inlining here. Those skills
own unit tables, verify phases, and synthesis prompts.

Presets shared across skills: [references/module-presets.md](references/module-presets.md).
