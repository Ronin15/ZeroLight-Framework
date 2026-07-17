---
name: zig-deep-correctness-review
description: >-
  Deep behavioral correctness review (pass 3): concurrency, algorithms, SIMD parity,
  pipeline determinism, resource lifetime, outliers, and test-coverage gaps. Use when
  the user asks for deep correctness, concurrency review, determinism audit, race
  hunting, or /zig-deep-correctness-review. Goes beyond idiom/surface reviews.
---

# Zig Deep-Correctness Review

**Pass 3.** Do **not** re-report idiom/naming/stdlib/surface ReleaseFast issues
already covered by best-practices or idiom-lint. Focus on behavioral correctness.

Agents: `zig-review-specialist`.  
Themes: `.grok/skills/zig-workflows/references/module-presets.md` →
**deep-correctness-review**.

## Phase 1 — Per-theme review (parallel)

One `zig-review-specialist` per theme unit (`background: true`,
`capability_mode: read-only`). Use the preset focus text as the unit brief.

For each finding give **concrete failure**: inputs/state → wrong behavior / crash /
leak / nondeterminism. Cite real `file:line`. Prefer few high-confidence findings
over speculation. Clean units with zero findings are valid.

Kinds: `bug`, `race`, `determinism`, `numerical`, `leak`, `test-gap`, `anomaly`,
`contract`. Severity: `high|medium|low`. Also: title, detail, fix_direction,
`durable`, `durable_mechanism`, `durable_rationale`.

## Phase 2 — Adversarial verify (high bar)

For each finding, spawn a verifier that defaults to skepticism:

- Trace control/data flow; try to refute
- Races: concurrent access + write, no happens-before?
- Determinism/numerical: does divergence actually manifest?
- Test-gap: truly untested **and** load-bearing? (search tests)

`CONFIRMED` only with a concrete failing case or confirmed coverage gap.
Keep CONFIRMED/PLAUSIBLE with `is_real`.

## Phase 3 — Synthesize

Split cleanly:

1. **top_bugs** — real defects ranked by severity + fix direction
2. **test_gaps** — highest-value untested invariants + narrow scenario + blast radius
3. **durable_items** — only net-new lint/agent/doc items (no duplicates of existing guidance)
4. **summary**

If nothing survives verification, report that the reviewed surface is clean — that
is a valuable result.

## Done criteria

- All themes reviewed and verified
- Ranked bugs / test gaps / durable items delivered as Markdown
- No code edits unless the user asks
