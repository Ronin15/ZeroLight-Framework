---
name: zig-workflows
description: >-
  ZeroLight-Framework (Zig 0.16, SDL3, SDL_GPU) specialist routing: design, implement,
  debug, PR/diff review, and multi-phase review passes. Use when the user asks for
  zig-design-specialist, zig-specialist, zig-debug-specialist, or zig-review-specialist;
  when zig build, zig test, or shader compile fails; when reviewing a PR or branch diff;
  when planning ECS, DataSystem, SimulationPipeline, pathfinding, collision, AI, or
  threading changes; or when assessing emergent-gameplay architecture readiness.
  Slash: /zig-workflows.
---

# Zig Workflows (Grok-native)

Canonical guardrails: root `AGENTS.md` / `Agents.md` and `docs/coding-standards.md`.

**Agents:** `.grok/agents/zig-*.md` (Grok-native source of truth).  
**Presets:** [references/module-presets.md](references/module-presets.md).  
**Multi-phase skills:** `/pathfinder-review`, `/architecture-assessment`,
`/zig-best-practices-review`, `/zig-deep-correctness-review`.

Do not restate full guardrails in `spawn_subagent` prompts — agents load `agents_md`.

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

Use the `spawn_subagent` tool. Only the **parent** session may spawn (depth limit 1).

| Subagent | `capability_mode` | Typical next step |
|----------|-------------------|-------------------|
| `zig-design-specialist` | `read-only` (or omit; agent is `permission_mode: plan`) | Implement |
| `zig-specialist` | omit / `all` | Review if risky |
| `zig-debug-specialist` | omit / `all` | Review if hot-path fix |
| `zig-review-specialist` | `read-only` (or omit; agent is `permission_mode: plan`) | Debug or Design |

- Prefer `background: true` for parallel multi-unit work; collect with
  `get_command_or_subagent_output`.
- One subagent per logical unit unless a multi-phase skill says otherwise.
- Do not run Design + Implement in parallel on the same feature unless the user asks.
- Model pins (Grok 4.5 vs Composer 2.5) live in user `~/.grok/config.toml`
  `[subagents.models]` — do not invent model overrides in skills.

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
capability_mode: read-only
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
capability_mode: read-only
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
