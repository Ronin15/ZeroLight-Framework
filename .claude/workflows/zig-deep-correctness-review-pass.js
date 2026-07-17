export const meta = {
  name: 'zig-deep-correctness-review-pass',
  description: 'Pass 3: deep behavioral correctness review — concurrency, algorithms, SIMD parity, pipeline/determinism contracts, resource lifetime, outliers, and test-coverage gaps',
  whenToUse: 'Third pass going beyond idiom/surface (covered by passes 1-2) into cross-cutting correctness themes and untested invariants',
  phases: [
    { title: 'Review', detail: 'one deep-review specialist per correctness theme' },
    { title: 'Verify', detail: 'adversarial verification per finding' },
    { title: 'Synthesize', detail: 'rank real bugs + test gaps, cluster durable items' },
  ],
}

// Passes 1-2 already covered idioms/naming/stdlib-currency/ReleaseFast-surface
// across every src file. This pass is theme-based DEEP correctness: each unit
// spans multiple files and reasons about behavior, not per-file style.
const REVIEW_UNITS = [
  {
    unit: 'thread-pool-core',
    files: ['src/app/thread_system.zig'],
    focus: 'The thread pool itself: dispatch/claim/join correctness, atomic memory ordering (are Acquire/Release/atomics used correctly, any torn reads or missing fences?), work-range claiming races, adaptive-profiling state races, barrier/quiescence correctness, and whether a worker can ever observe partially-published batch state. Prove or refute data-race freedom of the claim/complete protocol.',
  },
  {
    unit: 'threaded-processor-dispatch',
    files: ['src/game/systems/movement.zig', 'src/game/systems/steering.zig', 'src/game/systems/collision.zig', 'src/game/systems/particle.zig'],
    focus: 'Threaded processor dispatch correctness: are per-worker write ranges provably DISJOINT, is every shared output buffer reserved before dispatch sized from the value dispatch uses, is the serial-vs-threaded result bit-identical (deterministic merge, no worker-order dependence), and does any worker read a column another worker is concurrently writing? Flag nondeterminism across worker counts.',
  },
  {
    unit: 'threaded-gather-processors',
    files: ['src/game/systems/ai.zig', 'src/game/systems/perception.zig', 'src/game/systems/affect.zig', 'src/game/systems/ai_memory.zig'],
    focus: 'Gather-heavy processors: correctness of gather-into-scratch, per-range event/output buffer partitioning and merge, range.index vs buffer-length invariants, and serial-vs-threaded parity. Check the perception/AI decision logic for correctness bugs (wrong index, stale snapshot read, off-by-one in candidate windows), not just threading.',
  },
  {
    unit: 'pathfinding-search-correctness',
    files: ['src/game/systems/pathfinding/system.zig', 'src/game/systems/pathfinding/solve.zig', 'src/game/systems/pathfinding/nav_grid.zig', 'src/game/systems/pathfinding/caches.zig', 'src/game/systems/pathfinding/group_field.zig'],
    focus: 'Algorithmic correctness: A* admissibility/termination within the fixed node budget, correctness of the abstract/portal search, cache coherence (are cached paths/keys invalidated correctly, any stale-hit returning a wrong path?), group flow-field correctness, and graceful degradation when the fixed budget is exhausted (deterministic deferral, never a wrong/partial path silently returned as complete).',
  },
  {
    unit: 'nav-graph-invalidation',
    files: ['src/game/systems/pathfinding/nav_graph.zig', 'src/game/systems/pathfinding/nav_memory.zig'],
    focus: 'Nav-graph structural correctness: incremental-dig chunk-patch correctness vs a full rebuild (does the patched graph equal a from-scratch rebuild?), nav-invalidation classification correctness (are all affected portals/edges recomputed, none missed or double-counted?), the threaded chunk-patch race, and portal/edge consistency across chunk borders. This is the highest-risk correctness area.',
  },
  {
    unit: 'pipeline-ordering-determinism',
    files: ['src/game/simulation_pipeline.zig', 'src/game/simulation.zig', 'src/game/simulation_scope.zig', 'src/game/systems/simulation_scope.zig', 'src/game/systems/arbitration.zig', 'src/game/dig_controller.zig'],
    focus: 'Integration/determinism: does every stage declare the PipelineResource read/write tags it actually touches; is stage_order a correct topological order of real data dependencies; are deferred structural changes (spawn/destroy) committed in a deterministic order that is frame-to-frame reproducible; do controllers (arbitration/dig) apply conflict policy deterministically; and is there any read-before-write or stale-this-frame hazard between stages that the resource graph does not catch?',
  },
  {
    unit: 'simd-numerical-parity',
    files: ['src/core/simd.zig', 'src/core/math.zig', 'src/game/systems/collision_response.zig', 'src/game/systems/spatial_index.zig'],
    focus: 'Numerical correctness: is every SIMD kernel bit- or tolerance-equivalent to its scalar form (including the scalar tail and masked lanes), are NaN/inf/zero-length edge cases handled identically, is accumulation order preserved where determinism is required, and do saturating/clamping conversions match between scalar and vector paths? Flag any scalar/SIMD divergence or an untested parity claim.',
  },
  {
    unit: 'gpu-and-render-lifetime',
    files: ['src/render/renderer.zig', 'src/render/sprite_batch.zig', 'src/render/resources.zig', 'src/render/text.zig', 'src/game/render_prep.zig'],
    focus: 'Cross-frame resource correctness: GPU resource (buffer/texture/sampler/pipeline/transfer-buffer) creation-destruction pairing across resize/reload/error paths, swapchain acquire-fail/skip determinism, transfer-buffer and frame-in-flight reuse safety (no CPU overwrite of in-flight GPU data), upload validation completeness, and render-prep ordering/z-layer determinism. Flag any leak or use-after-free window on a non-happy path.',
  },
  {
    unit: 'data-lifetime-and-handles',
    files: ['src/game/data_system/system.zig', 'src/game/data_system/structural.zig', 'src/game/data_system/agents.zig', 'src/game/world_system.zig'],
    focus: 'Entity/data correctness: generational-handle reuse safety (can a stale handle ever alias a recycled slot?), structural add/remove (swap-remove index fixups, mask consistency across parallel SoA columns), dense/sparse world-tile index consistency, and whether any store column can desync from another after spawn/destroy. Flag determinism hazards in entity iteration order.',
  },
  {
    unit: 'anomalies-and-test-gaps',
    files: ['whole repo — you choose what to read'],
    focus: 'OUTLIERS + META. (1) Anomalies: TODO/FIXME/HACK/XXX markers, dead/unreachable code, commented-out blocks, two sibling modules that should be consistent but diverged, suspiciously large/complex functions, magic numbers that look wrong, and any code that contradicts its own comment. Use grep/glob widely. (2) The highest-VALUE untested invariants: identify load-bearing contracts (determinism, budget-independence, allocation-freeness, parity, ordering) that have weak or no test coverage, and for each give the narrow scenario a test should assert. Prioritize by blast radius if the invariant silently broke.',
  },
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
          kind: { type: 'string', enum: ['bug', 'race', 'determinism', 'numerical', 'leak', 'test-gap', 'anomaly', 'contract'] },
          title: { type: 'string' },
          detail: { type: 'string', description: 'the concrete failure: inputs/state → wrong behavior, or the exact untested invariant and its blast radius' },
          fix_direction: { type: 'string' },
          durable: { type: 'boolean', description: 'true if a lint rule or durable agent-guidance line could prevent this class recurring' },
          durable_mechanism: { type: 'string', enum: ['lint-rule', 'agent-guidance', 'doc', 'none'] },
          durable_rationale: { type: 'string' },
        },
        required: ['file', 'line', 'severity', 'kind', 'title', 'detail', 'fix_direction', 'durable', 'durable_mechanism', 'durable_rationale'],
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
    durable_confirmed: { type: 'boolean' },
  },
  required: ['verdict', 'is_real', 'reasoning', 'corrected_severity', 'durable_confirmed'],
}

const SYNTHESIS_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    top_bugs: {
      type: 'array',
      description: 'Confirmed real bugs/races/leaks/numerical/determinism issues, ranked by severity',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          file: { type: 'string' },
          line: { type: 'integer' },
          title: { type: 'string' },
          severity: { type: 'string', enum: ['high', 'medium', 'low'] },
          kind: { type: 'string' },
          fix_direction: { type: 'string' },
        },
        required: ['file', 'line', 'title', 'severity', 'kind', 'fix_direction'],
      },
    },
    test_gaps: {
      type: 'array',
      description: 'Highest-value untested invariants, ranked by blast radius',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          invariant: { type: 'string' },
          where: { type: 'string' },
          scenario: { type: 'string', description: 'the narrow test to add' },
          blast_radius: { type: 'string' },
        },
        required: ['invariant', 'where', 'scenario', 'blast_radius'],
      },
    },
    durable_items: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          mechanism: { type: 'string', enum: ['lint-rule', 'agent-guidance', 'doc'] },
          target: { type: 'string' },
          guidance: { type: 'string' },
          rationale: { type: 'string' },
        },
        required: ['mechanism', 'target', 'guidance', 'rationale'],
      },
    },
    summary: { type: 'string' },
  },
  required: ['top_bugs', 'test_gaps', 'durable_items', 'summary'],
}

function reviewPrompt(u) {
  return [
    `DEEP CORRECTNESS review (pass 3). Passes 1-2 already covered idioms, naming, stdlib currency, and the ReleaseFast unreachable/cast/allocator SURFACE across every file — do NOT re-report those classes. Go deeper.`,
    ``,
    `Files in scope:`,
    (Array.isArray(u.files) ? u.files : [u.files]).map((f) => `  - ${f}`).join('\n'),
    ``,
    `Your focus for this unit:`,
    u.focus,
    ``,
    `Read the files (and any adjacent test/helper they depend on) and REASON about behavior, not style. For each finding give the concrete failure: the inputs/state that trigger it and the wrong output/crash/leak/nondeterminism that results — a vague "could be risky" is not a finding. Cite real file:line. Prefer a few high-confidence, well-argued findings over a long speculative list. If, after genuinely digging, the unit is correct, say so and return few or no findings (that is a valid, valuable result — do not manufacture findings). For test-gap findings, name the exact untested invariant and the narrow scenario that would expose a regression, and rank by blast radius.`,
    ``,
    `Return the structured object: {unit: "${u.unit}", findings: [...]}.`,
  ].join('\n')
}

function verifyPrompt(f) {
  return [
    `Adversarially verify this DEEP-correctness review finding. Default to skepticism: open the file, trace the actual control/data flow, and try to REFUTE it. Deep-correctness claims are often wrong or already-handled — hold this to a high bar.`,
    ``,
    `File: ${f.file}:${f.line}`,
    `Kind: ${f.kind}   Severity claimed: ${f.severity}`,
    `Title: ${f.title}`,
    `Detail: ${f.detail}`,
    `Fix direction: ${f.fix_direction}`,
    ``,
    `Check: (1) Trace the code — does the claimed failure actually occur, or is it prevented by a guard/invariant/ordering the finding missed? (2) For a race: is there really concurrent access to the same location with at least one write, and no happens-before edge (mutex, join, atomic, disjoint range) preventing it? (3) For a determinism/numerical claim: does the divergence actually manifest, or is order/rounding preserved? (4) For a test-gap: is the invariant genuinely untested (search the tests) AND load-bearing? Reproduce the reasoning concretely.`,
    ``,
    `Verdict CONFIRMED only if you can construct the concrete failing case (or confirm the exact coverage gap). PLAUSIBLE if likely but not fully provable from the code. REJECTED if a guard prevents it or the invariant is already tested. Correct the severity.`,
  ].join('\n')
}

phase('Review')

const perUnit = await pipeline(
  REVIEW_UNITS,
  (u) => agent(reviewPrompt(u), { label: `review:${u.unit}`, phase: 'Review', schema: FINDINGS_SCHEMA, agentType: 'zig-review-specialist', effort: 'high' }),
  (review, u) => {
    if (!review || !review.findings || review.findings.length === 0) return { unit: u.unit, verified: [] }
    return parallel(
      review.findings.map((f) => () =>
        agent(verifyPrompt(f), { label: `verify:${u.unit}:${f.kind}`, phase: 'Verify', schema: VERDICT_SCHEMA, effort: 'high' })
          .then((v) => (v ? { ...f, unit: u.unit, verdict: v } : null))
      )
    ).then((rows) => ({ unit: u.unit, verified: rows.filter(Boolean) }))
  }
)

const allVerified = perUnit.filter(Boolean).flatMap((r) => r.verified)
const confirmed = allVerified.filter((f) => f.verdict && (f.verdict.verdict === 'CONFIRMED' || f.verdict.verdict === 'PLAUSIBLE') && f.verdict.is_real)

log(`Pass 3: reviewed ${REVIEW_UNITS.length} themes; ${allVerified.length} raw findings, ${confirmed.length} confirmed/plausible.`)

if (confirmed.length === 0) {
  return { counts: { units: REVIEW_UNITS.length, raw: allVerified.length, confirmed: 0 }, confirmed: [], synthesis: null, note: 'No findings survived verification — the deep-correctness surface reviewed is clean.' }
}

phase('Synthesize')

const digest = confirmed.map((f) =>
  `[${f.verdict.verdict}/${f.verdict.corrected_severity}] ${f.kind} ${f.file}:${f.line} — ${f.title}` +
  `\n    ${f.detail}\n    fix: ${f.fix_direction}`
).join('\n\n')

const synthesis = await agent(
  [
    `Consolidate verified DEEP-correctness findings (PASS 3) for ZeroLight-Framework. Passes 1-2 handled idiom/surface; this pass is behavioral correctness, concurrency, numerics, determinism, resource lifetime, and test gaps.`,
    ``,
    `Split the output cleanly: top_bugs (confirmed real defects ranked by severity, each with a concrete fix direction), test_gaps (highest-value untested load-bearing invariants ranked by blast radius, each with the narrow scenario to add), and durable_items (only genuinely net-new lint/agent-guidance/doc items — the linter already has 7 rules and both agents carry extensive allocator/threading/ReleaseFast/SIMD/errdefer/validation guidance, so do not duplicate). Be precise and non-duplicative; a clean result with few items is fine.`,
    ``,
    `Verified findings:`,
    digest,
  ].join('\n'),
  { label: 'synthesize', phase: 'Synthesize', schema: SYNTHESIS_SCHEMA, effort: 'high' }
)

return {
  counts: { units: REVIEW_UNITS.length, raw: allVerified.length, confirmed: confirmed.length },
  confirmed,
  synthesis,
}
