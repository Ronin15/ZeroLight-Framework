---
name: pathfinder-review
description: >-
  Multi-agent Zig review of the pathfinder module for coherency, cohesion, and
  standards adherence. Use when the user asks for pathfinder review, pathfinding
  module review, /pathfinder-review, or a module-wide pass on
  src/game/systems/pathfinding/.
---

# Pathfinder Review

Orchestrate a multi-phase review of the pathfinder module. **You (parent) spawn
all subagents** — children cannot nest. Do not edit code unless the user asks for
fixes after the report.

Agents: `zig-review-specialist` (`.grok/agents/`).  
Unit table: `.grok/skills/zig-workflows/references/module-presets.md` → **pathfinder**.

## Standards preamble (include in every unit prompt)

```text
Before reviewing, read:
- docs/coding-standards.md
- docs/simulation-tiers-and-pipeline.md
- docs/architecture.md
Hot/frame paths must be allocation-free after init/reserve/warmup; no per-frame
string lookups, hash-map dispatch, broad dynamic dispatch, or formatted logging
on hot paths. Production APIs expose runtime concepts only.
```

## Lenses (every unit)

1. **COHERENCY** — consistent invariants, units/coordinate spaces, edge cases
2. **COHESION** — single responsibility, ownership boundaries, duplication
3. **STANDARDS** — Zig style, hot-path discipline, explicit error sets, tests

## Phase 1 — Per-unit review (parallel)

Spawn one `zig-review-specialist` per preset unit (`system`, `nav_graph`,
`caches`, `solve`, `nav_grid`, `types_and_memory`, `group_field_and_scratch`,
`facade_and_test_support`, `benchmarks`).

```
subagent_type: zig-review-specialist
capability_mode: read-only
background: true
description: pathfinder review <unit>
```

**Prompt template:**

```text
Review unit "<unit>" of the ZeroLight-Framework pathfinder module.

Files (read in full):
- <files from preset>

Context: <note from preset>

<standards preamble>
<lenses>

Return severity-ordered findings (critical → nit). Each finding: severity,
category (coherency|cohesion|standards|performance|correctness), file, line,
title, detail, suggestion. If clean on a lens, say so in the summary — do not pad.
```

Collect all results with `get_command_or_subagent_output` before Phase 2.

## Phase 2 — Cross-cut (parallel)

Three more `zig-review-specialist` spawns (`background: true`):

| Unit | Focus |
|------|--------|
| `module-coherency` | Cross-file invariants; request lifecycle system → solve/nav_graph/nav_grid/caches |
| `module-cohesion` | File split, facade surface, boundary violations, dead/duplicated code |
| `standards-and-hotpath` | Post-warmup alloc, hot-path logging, naming, co-located tests |

List all pathfinder + benchmark files from the preset in each prompt.

## Phase 3 — Synthesize (parent or one specialist)

Either synthesize yourself or spawn one `zig-review-specialist` with the full
corpus. Output **one Markdown report**:

1. Executive summary (health across three lenses)
2. Severity-ordered findings (merge duplicates; drop spurious; note corroboration)
3. Each finding: severity, category, `file:line`, problem, concrete fix
4. Cross-cutting themes
5. Prioritized action list

Do not invent findings beyond the corpus. Do not fix code unless asked.

## Done criteria

- All Phase 1 units completed (or explicitly noted as failed/skipped)
- Cross-cuts completed
- Single severity-ordered report delivered to the user
