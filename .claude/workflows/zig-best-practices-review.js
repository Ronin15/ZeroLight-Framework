export const meta = {
  name: 'zig-best-practices-review',
  description: 'Review large ZeroLight systems for Zig best practices, verify findings, synthesize durable lint/agent guidance',
  whenToUse: 'Deep Zig best-practice pass over the biggest hot subsystems, feeding durable items back into the linter and agents',
  phases: [
    { title: 'Review', detail: 'one review-specialist per large subsystem' },
    { title: 'Verify', detail: 'adversarial verification per finding' },
    { title: 'Synthesize', detail: 'cluster confirmed findings into durable guidance' },
  ],
}

// Larger / hot subsystems. Each unit is reviewed by one zig-review-specialist
// reading the actual files. Grouped so related files review together but no
// single agent is overloaded.
const REVIEW_UNITS = [
  { unit: 'pathfinding-system', files: ['src/game/systems/pathfinding/system.zig'] },
  { unit: 'pathfinding-navgraph', files: ['src/game/systems/pathfinding/nav_graph.zig', 'src/game/systems/pathfinding/nav_grid.zig'] },
  { unit: 'pathfinding-support', files: ['src/game/systems/pathfinding/caches.zig', 'src/game/systems/pathfinding/solve.zig', 'src/game/systems/pathfinding/group_field.zig', 'src/game/systems/pathfinding/scratch.zig', 'src/game/systems/pathfinding/nav_memory.zig', 'src/game/systems/pathfinding/types.zig'] },
  { unit: 'ai', files: ['src/game/systems/ai.zig', 'src/game/systems/ai_memory.zig', 'src/game/ai_archetypes.zig'] },
  { unit: 'perception', files: ['src/game/systems/perception.zig', 'src/game/data_system/perception.zig'] },
  { unit: 'steering-arbitration', files: ['src/game/systems/steering.zig', 'src/game/systems/arbitration.zig'] },
  { unit: 'collision', files: ['src/game/systems/collision.zig', 'src/game/systems/collision_response.zig', 'src/game/systems/spatial_index.zig'] },
  { unit: 'movement-particle-affect', files: ['src/game/systems/movement.zig', 'src/game/systems/particle.zig', 'src/game/systems/affect.zig'] },
  { unit: 'data-system-core', files: ['src/game/data_system/system.zig', 'src/game/data_system/types.zig', 'src/game/data_system/structural.zig'] },
  { unit: 'world-system', files: ['src/game/world_system.zig'] },
  { unit: 'simulation-pipeline', files: ['src/game/simulation_pipeline.zig', 'src/game/simulation.zig', 'src/game/simulation_scope.zig', 'src/game/systems/simulation_scope.zig'] },
  { unit: 'thread-system', files: ['src/app/thread_system.zig'] },
  { unit: 'renderer-batch', files: ['src/render/renderer.zig', 'src/render/sprite_batch.zig'] },
  { unit: 'render-prep', files: ['src/game/render_prep.zig', 'src/render/text.zig', 'src/render/resources.zig'] },
  { unit: 'core-simd-math', files: ['src/core/simd.zig', 'src/core/math.zig', 'src/core/rng.zig'] },
]

const FINDINGS_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    unit: { type: 'string' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          file: { type: 'string' },
          line: { type: 'integer' },
          severity: { type: 'string', enum: ['high', 'medium', 'low'] },
          category: { type: 'string', description: 'kebab-case slug e.g. allocator-discipline, unreachable-ub, mal-hot-path, simd-through-core, naming, stdlib-currency, error-handling' },
          title: { type: 'string' },
          detail: { type: 'string', description: 'what is wrong and why it matters for Zig best practice / this codebase' },
          fix_direction: { type: 'string' },
          durable: { type: 'boolean', description: 'true if this reflects a generalizable pattern a lint rule or agent-guidance update could prevent recurring' },
          durable_mechanism: { type: 'string', enum: ['lint-rule', 'agent-guidance', 'doc', 'none'] },
          durable_rationale: { type: 'string' },
        },
        required: ['file', 'line', 'severity', 'category', 'title', 'detail', 'fix_direction', 'durable', 'durable_mechanism', 'durable_rationale'],
      },
    },
  },
  required: ['unit', 'findings'],
}

const VERDICT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    verdict: { type: 'string', enum: ['CONFIRMED', 'PLAUSIBLE', 'REJECTED'] },
    is_real: { type: 'boolean' },
    reasoning: { type: 'string' },
    corrected_severity: { type: 'string', enum: ['high', 'medium', 'low'] },
    durable_confirmed: { type: 'boolean', description: 'true if the durability claim (lint-rule/agent-guidance) holds up as a low-false-positive, generalizable rule' },
  },
  required: ['verdict', 'is_real', 'reasoning', 'corrected_severity', 'durable_confirmed'],
}

const SYNTHESIS_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    lint_rules: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          name: { type: 'string' },
          description: { type: 'string' },
          detection_hint: { type: 'string', description: 'concrete regex/heuristic a line-scanner could use, plus false-positive exemptions to carve out' },
          rationale: { type: 'string' },
          source_findings: { type: 'array', items: { type: 'string' } },
          confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
        },
        required: ['name', 'description', 'detection_hint', 'rationale', 'source_findings', 'confidence'],
      },
    },
    agent_guidance: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          target_agent: { type: 'string', enum: ['zig-specialist', 'zig-review-specialist', 'both'] },
          guidance: { type: 'string', description: 'concise durable rule to add, in the voice of the existing agent files' },
          rationale: { type: 'string' },
          source_findings: { type: 'array', items: { type: 'string' } },
        },
        required: ['target_agent', 'guidance', 'rationale', 'source_findings'],
      },
    },
    doc_updates: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          doc: { type: 'string' },
          guidance: { type: 'string' },
          rationale: { type: 'string' },
        },
        required: ['doc', 'guidance', 'rationale'],
      },
    },
    top_fixes: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          file: { type: 'string' },
          line: { type: 'integer' },
          title: { type: 'string' },
          severity: { type: 'string', enum: ['high', 'medium', 'low'] },
          fix_direction: { type: 'string' },
        },
        required: ['file', 'line', 'title', 'severity', 'fix_direction'],
      },
    },
    summary: { type: 'string' },
  },
  required: ['lint_rules', 'agent_guidance', 'doc_updates', 'top_fixes', 'summary'],
}

function reviewPrompt(u) {
  return [
    `Review these files for **Zig 0.16 best practices and this codebase's coding standards** (read them fully first):`,
    u.files.map((f) => `  - ${f}`).join('\n'),
    ``,
    `You are the zig-review-specialist — apply your full checklist, but weight this pass toward mechanizable / generalizable best-practice issues, NOT one-off gameplay logic bugs. Concretely hunt for:`,
    `  - allocator discipline: reserve+assumeCapacity/addOneAssumeCapacity pairings lacking a same-change FailingAllocator proof test; hidden per-frame allocation on hot paths; allocator reached mid-function instead of an init-time field.`,
    `  - ReleaseFast UB: reachable unreachable / catch unreachable / orelse unreachable / .? where impossibility is not provable by construction.`,
    `  - std.MultiArrayList hot paths: rows.items(.field) inside a loop instead of a cached rows.slice(); per-row appendAssumeCapacity(row) instead of addOneAssumeCapacity+set().`,
    `  - SIMD/math discipline: raw @Vector or hand-rolled named math (length/normalize/rsqrt/gather/clamp/trig) in a system instead of going through src/core/simd.zig or src/core/math.zig; scalar and SIMD forms drifting apart.`,
    `  - error handling: swallowed errors where diagnosis matters; error sets that lost meaning; missing errdefer on partially-initialized resources.`,
    `  - fixed work budgets scaled to world/map/cell/portal count instead of a fixed constant.`,
    `  - naming / stdlib currency the idiom-lint could catch but currently does not (camelCase fn-pointer fields drifting from snake_case vtables, deprecated spellings, etc.).`,
    `  - threaded-write partitioning: reserve-before-dispatch sizing, per-worker disjoint ranges, worker range asserts.`,
    ``,
    `Use file:line references that actually exist. For each finding, set durable=true ONLY when a linter rule or a durable agent-guidance line could prevent the pattern recurring across the codebase, and say which mechanism (lint-rule vs agent-guidance vs doc) and why. A genuinely one-off local issue is durable=false. Report real findings only — no speculative filler. If a file is clean, return no findings for it.`,
    ``,
    `Return the structured object: {unit: "${u.unit}", findings: [...]}.`,
  ].join('\n')
}

function verifyPrompt(f) {
  return [
    `Adversarially verify this Zig best-practice review finding. Default to skepticism: open the file, read the surrounding code, and try to REFUTE it.`,
    ``,
    `File: ${f.file}:${f.line}`,
    `Severity claimed: ${f.severity}`,
    `Category: ${f.category}`,
    `Title: ${f.title}`,
    `Detail: ${f.detail}`,
    `Claimed durable via: ${f.durable_mechanism} — ${f.durable_rationale}`,
    ``,
    `Check: (1) Does the cited code actually do what the finding says at/near that line? (2) Is it genuinely a Zig best-practice violation for THIS codebase, or is it sanctioned by an existing convention (e.g. a documented handle constructor, a // lint:allow annotation, a deliberate scalar tail, a stated reason)? (3) If durable, would the proposed lint-rule/agent-guidance be low-false-positive and generalizable, or would it misfire on legitimate existing code?`,
    ``,
    `Verdict CONFIRMED only if the code truly exhibits the issue and it matters. PLAUSIBLE if likely but you cannot fully confirm from the code. REJECTED if the code does not exhibit it or it is sanctioned. Set durable_confirmed only if the durability claim survives scrutiny.`,
  ].join('\n')
}

phase('Review')

const perUnit = await pipeline(
  REVIEW_UNITS,
  (u) => agent(reviewPrompt(u), { label: `review:${u.unit}`, phase: 'Review', schema: FINDINGS_SCHEMA, agentType: 'zig-review-specialist' }),
  (review, u) => {
    if (!review || !review.findings || review.findings.length === 0) return { unit: u.unit, verified: [] }
    return parallel(
      review.findings.map((f) => () =>
        agent(verifyPrompt(f), { label: `verify:${u.unit}:${f.category}`, phase: 'Verify', schema: VERDICT_SCHEMA })
          .then((v) => (v ? { ...f, unit: u.unit, verdict: v } : null))
      )
    ).then((rows) => ({ unit: u.unit, verified: rows.filter(Boolean) }))
  }
)

const allVerified = perUnit.filter(Boolean).flatMap((r) => r.verified)
const confirmed = allVerified.filter((f) => f.verdict && (f.verdict.verdict === 'CONFIRMED' || f.verdict.verdict === 'PLAUSIBLE') && f.verdict.is_real)
const durable = confirmed.filter((f) => f.durable && f.verdict.durable_confirmed)

log(`Reviewed ${REVIEW_UNITS.length} units; ${allVerified.length} raw findings, ${confirmed.length} confirmed/plausible, ${durable.length} confirmed-durable.`)

if (confirmed.length === 0) {
  return { confirmed: [], durable: [], synthesis: null, note: 'No findings survived verification.' }
}

phase('Synthesize')

const digest = confirmed.map((f) =>
  `[${f.verdict.verdict}/${f.verdict.corrected_severity}] ${f.file}:${f.line} (${f.category}) ${f.title}` +
  (f.durable && f.verdict.durable_confirmed ? ` <<DURABLE:${f.durable_mechanism}>> ${f.durable_rationale}` : '') +
  `\n    ${f.detail}\n    fix: ${f.fix_direction}`
).join('\n\n')

const synthesis = await agent(
  [
    `You are consolidating verified Zig best-practice review findings for the ZeroLight-Framework into DURABLE guidance.`,
    ``,
    `Existing enforcement you must not duplicate: tools/lint_idioms.py already enforces — deprecated stdlib spellings (ArrayListUnmanaged, usingnamespace, std.mem.copy/set, BoundedArray), snake_case fields/params (fn-pointer-typed fields exempt), C++-style kFoo constants, and catch/orelse unreachable outside test blocks unless on a sanctioned handle constructor or carrying a // lint:allow annotation. The zig-specialist and zig-review-specialist agent files already carry: allocator/FailingAllocator discipline, ReleaseFast unreachable UB, MultiArrayList slice()/addOneAssumeCapacity hot-path rules, fixed work budgets, SIMD-through-core, threaded-write partitioning, no test-only production API tags.`,
    ``,
    `Propose ONLY NET-NEW durable items justified by the findings below. For lint_rules: only propose a rule that a line-scanner can enforce with LOW false positives — give a concrete detection heuristic AND the exemptions it must carve out; if a pattern is real but not mechanically detectable without noise, route it to agent_guidance instead. For agent_guidance: write it in the terse voice of the existing agent files and target the right agent(s). Keep everything concise and non-duplicative. Also list the top concrete one-off fixes (top_fixes) ranked by severity for the human to act on.`,
    ``,
    `Verified findings:`,
    digest,
  ].join('\n'),
  { label: 'synthesize', phase: 'Synthesize', schema: SYNTHESIS_SCHEMA, effort: 'high' }
)

return {
  counts: { units: REVIEW_UNITS.length, raw: allVerified.length, confirmed: confirmed.length, durable: durable.length },
  confirmed,
  synthesis,
}
