---
name: zig-best-practices-review
description: >-
  Multi-agent Zig best-practices review of large hot subsystems: review, adversarial
  verify, then synthesize durable lint/agent/doc guidance. Use when the user asks for
  best-practices review, Zig idioms pass, durable lint guidance, or
  /zig-best-practices-review.
---

# Zig Best-Practices Review

Weight toward **mechanizable / generalizable** best-practice issues, not one-off
gameplay bugs. Parent orchestrates all spawns.

Agents: `zig-review-specialist`.  
Units: `.grok/skills/zig-workflows/references/module-presets.md` →
**best-practices-review**.

## Phase 1 — Per-unit review (parallel)

One `zig-review-specialist` per preset unit (`background: true`,
`capability_mode: read-only`).

Hunt for:

- Allocator discipline: reserve + `assumeCapacity` without same-change
  `FailingAllocator` proof; hidden per-frame alloc; mid-function allocator grab
- ReleaseFast UB: reachable `unreachable` / `catch unreachable` / `orelse unreachable` / `.?`
- MultiArrayList: `items(.field)` inside loops vs cached `slice()`; wrong append patterns
- SIMD/math not through `src/core/simd.zig` / `math.zig`
- Swallowed errors; missing `errdefer` on partial init
- Work budgets scaled to world/map size instead of fixed constants
- Naming/stdlib currency beyond current idiom-lint
- Threaded-write partitioning: reserve-before-dispatch, disjoint ranges

Each finding: `file`, `line`, severity (`high|medium|low`), category slug, title,
detail, fix_direction, `durable` (bool), `durable_mechanism`
(`lint-rule|agent-guidance|doc|none`), `durable_rationale`.

## Phase 2 — Adversarial verify

For each finding (batch in parallel groups if many), spawn a
`zig-review-specialist` that tries to **refute** it:

- Does the code at/near the line actually do that?
- Sanctioned by convention / `// lint:allow` / deliberate scalar tail?
- If durable: low false-positive and generalizable?

Verdict: `CONFIRMED` | `PLAUSIBLE` | `REJECTED`, plus `is_real`,
`corrected_severity`, `durable_confirmed`.

Keep only CONFIRMED/PLAUSIBLE with `is_real`.

## Phase 3 — Synthesize durable guidance

One synthesis agent over confirmed findings. **Do not duplicate** existing
`tools/lint_idioms.py` rules or guidance already in `.grok/agents/zig-*.md`
(allocator proofs, ReleaseFast UB, MultiArrayList, fixed budgets, SIMD-through-core,
threaded writes, no test-only production APIs).

Output:

- `lint_rules` — only low-FP mechanical rules with detection heuristic + exemptions
- `agent_guidance` — terse lines targeting zig-specialist / zig-review-specialist / both
- `doc_updates` — if needed
- `top_fixes` — ranked one-off concrete fixes
- `summary`

Deliver a readable Markdown report to the user. Do not apply code changes unless asked.

## Done criteria

- All units reviewed; findings verified; synthesis delivered
