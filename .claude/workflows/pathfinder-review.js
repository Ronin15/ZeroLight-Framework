export const meta = {
  name: 'pathfinder-review',
  description: 'Multi-agent Zig review of the pathfinder module for coherency, cohesion, and standards adherence',
  whenToUse: 'Module-wide review of src/game/systems/pathfinding/ after substantive pathfinder changes; review-only, produces one severity-ordered report',
  phases: [
    { title: 'Review', detail: 'one zig-review-specialist per file cluster' },
    { title: 'Cross-cut', detail: 'module-wide coherency & cohesion lenses' },
    { title: 'Synthesize', detail: 'merge into one severity-ordered report' },
  ],
}

const FINDING_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    unit: { type: 'string' },
    summary: { type: 'string', description: 'overall read on these files' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          severity: { type: 'string', enum: ['high', 'medium', 'low'] },
          tag: { type: 'string', enum: ['structural', 'local'] },
          category: { type: 'string', enum: ['coherency', 'cohesion', 'standards', 'performance', 'correctness'] },
          file: { type: 'string' },
          line: { type: 'string', description: 'line number or range, or "n/a"' },
          title: { type: 'string' },
          detail: { type: 'string' },
          suggestion: { type: 'string' },
        },
        required: ['severity', 'tag', 'category', 'file', 'line', 'title', 'detail', 'suggestion'],
      },
    },
  },
  required: ['unit', 'summary', 'findings'],
}

const STANDARDS = `Rules: the .claude/rules/ files your agent instructions name; the ones matching this module are pathfinding.md, simulation.md, threading.md, memory-performance.md, budgets-capacities.md, zig-style.md, and tests-benchmarks.md. Cite the rule file in each standards finding.
Described contracts: docs/architecture.md (pathfinding sections) and docs/simulation-tiers-and-pipeline.md.`

const LENSES = `Review along three lenses:
1. COHERENCY — does the logic hold together and behave consistently? Inconsistent invariants, contradictory assumptions across functions, mismatched units/coordinate spaces, off-by-one or edge-case gaps, comments that disagree with code.
2. COHESION — does each file/type carry a single clear responsibility? Misplaced concerns, leaky abstractions across the render/platform/sim boundaries, dead code, duplication that belongs in one place, ownership-boundary violations.
3. STANDARDS ADHERENCE — the rule files above.
Give file:line references. Be specific and severity-honest; do not invent problems where the code is sound.`

const UNITS = [
  { unit: 'system', files: ['src/game/systems/pathfinding/system.zig'], note: 'Per-frame request scheduling, agent state, integration with simulation pipeline. Scrutinize hot-path allocation and dispatch.' },
  { unit: 'nav_graph', files: ['src/game/systems/pathfinding/nav_graph.zig'], note: 'Navigation graph construction/representation.' },
  { unit: 'caches', files: ['src/game/systems/pathfinding/caches.zig'], note: 'Path/result caching. Check invalidation coherency and lifetime.' },
  { unit: 'solve', files: ['src/game/systems/pathfinding/solve.zig'], note: 'The core search/solve (A*/etc). Check allocation discipline and correctness of the search.' },
  { unit: 'nav_grid', files: ['src/game/systems/pathfinding/nav_grid.zig'], note: 'Grid representation and walkability.' },
  { unit: 'types_and_memory', files: ['src/game/systems/pathfinding/types.zig', 'src/game/systems/pathfinding/nav_memory.zig'], note: 'Shared types/contracts and memory/arena management for the module.' },
  { unit: 'group_field_and_scratch', files: ['src/game/systems/pathfinding/group_field.zig', 'src/game/systems/pathfinding/scratch.zig'], note: 'Flow/group field and scratch buffers. Check reuse vs per-frame allocation.' },
  { unit: 'facade_and_test_support', files: ['src/game/systems/pathfinding.zig', 'src/game/systems/pathfinding/test_support.zig'], note: 'Public facade (re-exports/ownership surface) and test-support helpers. Verify no test-only constructs leak into production API.' },
  { unit: 'benchmarks', files: ['src/benchmarks/pathfinding.zig', 'src/benchmarks/nav_update.zig'], note: 'CPU benchmarks for pathfinding/nav update. Check they exercise realistic, destruction-shaped workloads at several sizes.' },
]

phase('Review')
const reviews = await parallel(UNITS.map((u) => () =>
  agent(
    `You are reviewing the "${u.unit}" review unit of the ZeroLight-Framework pathfinder module.

Files to review (read them in full):
${u.files.map((f) => `- ${f}`).join('\n')}

Context: ${u.note}

${STANDARDS}

${LENSES}

Read the assigned files completely and the relevant docs. Return your findings via the structured output. Set unit to "${u.unit}". Order findings by severity (high first). If a file is clean on a lens, say so in the summary rather than padding.`,
    { label: `review:${u.unit}`, phase: 'Review', schema: FINDING_SCHEMA, agentType: 'zig-review-specialist' }
  )
)).then((rs) => rs.filter(Boolean))

phase('Cross-cut')
const CROSS = [
  { key: 'module-coherency', prompt: 'Review the WHOLE pathfinder module for cross-file COHERENCY: invariants that must agree across files (coordinate spaces, units, cell/world conversions, request lifecycle states, error sets), assumptions made in one file that another file violates, and data contracts that drift between producer and consumer. Trace the request lifecycle from system.zig through solve.zig, nav_graph.zig, nav_grid.zig, caches.zig.' },
  { key: 'module-cohesion', prompt: 'Review the WHOLE pathfinder module for cross-file COHESION and architecture: is the split into files (system/nav_graph/nav_grid/solve/caches/types/group_field/scratch/nav_memory) clean and single-responsibility? Find duplication that should be unified, misplaced concerns, ownership-boundary violations (does anything reach outside the pathfinding module improperly, or import render/gpu internals?), and dead or redundant code. Assess whether the public facade (pathfinding.zig) exposes the right minimal surface.' },
  { key: 'standards-and-hotpath', prompt: 'Review the WHOLE pathfinder module for STANDARDS adherence and hot-path discipline against the rule files listed above, module-wide rather than per file: allocation and growth on per-step/per-request paths and their proofs, hot-path dispatch and logging, budgets, capacities, and thresholds, naming and error sets, comments, and tests.' },
]
const allFiles = UNITS.flatMap((u) => u.files)
const crossReviews = await parallel(CROSS.map((c) => () =>
  agent(
    `You are doing a MODULE-WIDE cross-cutting review of the ZeroLight-Framework pathfinder.

All module files:
${allFiles.map((f) => `- ${f}`).join('\n')}

${STANDARDS}

Your specific lens: ${c.prompt}

Read across the files as needed (use Grep/Glob to trace cross-file relationships, Read for detail). Return findings via structured output with unit set to "${c.key}". Give file:line references and concrete cross-file evidence. Severity-honest.`,
    { label: `cross:${c.key}`, phase: 'Cross-cut', schema: FINDING_SCHEMA, agentType: 'zig-review-specialist' }
  )
)).then((rs) => rs.filter(Boolean))

phase('Synthesize')
const corpus = [...reviews, ...crossReviews]
const report = await agent(
  `You are the lead reviewer synthesizing a multi-agent code review of the ZeroLight-Framework pathfinder module.

Here are all reviewer findings as JSON:
${JSON.stringify(corpus, null, 2)}

Produce a single, polished Markdown review report. Requirements:
- Start with a short executive summary: overall health of the module across the three lenses (coherency, cohesion, standards adherence).
- A severity-ordered findings section (High -> Medium -> Low). Merge duplicate findings reported by multiple agents into one entry (note corroboration). Drop anything that is clearly spurious or contradicted by other reviewers, and say briefly what you dropped if notable.
- Each finding: severity, structural/local tag, category, file:line, the problem, and a concrete suggested fix.
- A "Cross-cutting themes" subsection for module-wide coherency/cohesion observations, led by any operation whose cost scales with level, depth, world count, or total links instead of the change (.claude/rules/engine-design.md).
- End with a prioritized action list (top fixes first). Each follow-up (next step, risk, fix, or test gap) names its owning slice id (docs/roadmap/slices/slice-<id>.md) or 'new slice needed: <title>' stated as intent and constraints, never a design; never a Scaling Gaps/backlog line.
Be concise and concrete. Do not invent findings beyond the corpus. Return ONLY the Markdown report.`,
  { label: 'synthesize', phase: 'Synthesize', agentType: 'zig-review-specialist' }
)

return { report, unitCount: UNITS.length, crossCount: CROSS.length, totalFindings: corpus.reduce((n, r) => n + (r.findings?.length || 0), 0) }
