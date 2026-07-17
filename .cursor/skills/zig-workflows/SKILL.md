---
name: zig-workflows
description: >-
  ZeroLight-Framework (Zig 0.16, SDL3, SDL_GPU) specialist workflows: design
  plans, implementation, debug/triage, PR/diff review, pathfinder module review,
  architecture assessment. Use when the user asks for zig-design-specialist,
  zig-specialist, zig-debug-specialist, or zig-review-specialist; when zig build,
  zig test, or shader compile fails; when reviewing a PR or branch diff; when
  planning ECS, DataSystem, SimulationPipeline, pathfinding, collision, AI, or
  threading changes; or when assessing emergent-gameplay architecture readiness.
---

# Zig Workflows

Canonical guardrails: @AGENTS.md and `docs/coding-standards.md`. Subagent prompts:
`.cursor/agents/` (kept in sync with `.claude/agents/`). Do not restate guardrails in
Task prompts.

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
| Module-wide pass (pathfinder, etc.) | Module review |
| ECS extensibility / roadmap assessment | Architecture assessment |
| Large-subsystem best-practice pass | Best-practices review |
| Deep correctness / concurrency / algorithm pass | Deep-correctness review |
| Touches hot paths, threading, or pipeline stages | Implement (or Design first if unclear) |

When unsure: **Implement** for coding tasks, **Review** after substantive diffs,
**Debug** for any failing command output.

## Shared conventions

Launch via Task tool unless the user asked you to work inline:

| Subagent | `readonly` | Typical next step |
|----------|------------|-------------------|
| `zig-design-specialist` | `true` | Implement |
| `zig-specialist` | `false` | Review if risky |
| `zig-debug-specialist` | `false` | Review if hot-path fix |
| `zig-review-specialist` | `true` | Debug or Design |

Defaults: `run_in_background: false`. One subagent per step unless multi-phase says parallel.
Do not run Design + Implement in parallel on the same feature unless the user asks.

## Invocation examples

User says → do:

- "Review my branch" → **Review**, scope `branch changes`
- "Review only uncommitted" → **Review**, scope `uncommitted changes`
- "Fix this test failure" + error output → **Debug**
- "Design the arbitration system before we code" → **Design**
- "Implement slice X" → **Design** first if contracts unclear, else **Implement**
- "Review the pathfinder module" → **Module review**, pathfinder preset
- "Best-practices review of hot subsystems" → **Best-practices review** preset
- "Deep correctness pass on threading/pathfinding" → **Deep-correctness review** preset
- "How ready is this for emergent gameplay?" → **Architecture assessment**

## Design

```
subagent_type: zig-design-specialist
readonly: true
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
readonly: true
```

```text
Full Repository Path: <abs path>
Review scope: branch changes | uncommitted changes | <file list>
Base Branch: <only if non-default base>
Custom Instructions: <optional>
```

Summarize as a severity-sorted table; do not fix unless asked.

## Architecture assessment

Multi-phase `zig-design-specialist` (`readonly: true`). Mirrors
`.claude/workflows/architecture-assessment.js`.

**Phase 1 — docs (parallel):** architecture+simulation, state+standards, roadmap,
render+assets.

**Phase 2 — code (parallel):** data_system+pipeline, gameplay systems, engine+threads,
world+pathfinding, controllers+render_prep.

**Phase 3 — synthesize:** executive summary (/10), strengths, gaps/risks, scalability,
readiness by domain (AI, collision, world, multi-agent, events), next steps, top-5 risk register.

## Module review (multi-phase)

Multiple `zig-review-specialist` (`readonly: true`) + synthesis. Standards are in the
review subagent — only add file lists from [module-presets.md](module-presets.md).

1. **Per-unit (parallel):** one subagent per preset row
2. **Cross-cut (parallel):** coherency, cohesion, standards-and-hotpath (pathfinder preset)
3. **Synthesize:** merge severity-ordered report; drop spurious findings

Presets: [module-presets.md](module-presets.md) — `pathfinder`, `best-practices-review`,
`deep-correctness-review`.

## Best-practices review

Multi-phase module review using the `best-practices-review` preset. One
`zig-review-specialist` per unit (parallel), adversarial verify pass, then synthesize
durable lint/agent/doc items and ranked one-off fixes.

## Deep-correctness review

Multi-phase theme review using the `deep-correctness-review` preset. Goes beyond
idiom/surface into concurrency, algorithms, SIMD parity, pipeline determinism, resource
lifetime, and test-coverage gaps. Verify findings before synthesizing.
