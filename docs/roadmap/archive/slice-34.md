## Slice 34: Core SIMD Primitive Layer Expansion And Dense-Path Wins

**Status: landed, with two items deferred/reverted by evidence.** The gather/
scatter, rsqrt/normalize, sprite-transform, and AI-memset items were already
shipped pre-existing. The packed-SoA-scratch idiom doc landed. The batched
`lerpVec2Float4` primitive landed (correct, tested) but its `render_prep.zig`
consumer was **built, benchmarked, and reverted** — see item 6 below. The
sin/cos polynomial stays deferred to Slice 29.

> Doc-drift note: this section previously listed every item below as `[ ]`
> "Not started." Direct code reading found most of this slice had already
> shipped in earlier commits without the roadmap being updated — the gather/
> scatter helper, rsqrt/normalize, the sprite vertex-transform vectorization,
> and the AI separation-grid `@memset` all predate this correction pass (see
> commit `a723821`, "updated collisions hand rolled gather 4 into SIMD.zig",
> and the `world` branch changelog's "Expanded `src/core/simd.zig` and
> `src/core/math.zig` with reusable gather, normalize, sin/cos, and tail
> helpers"). This pass corrects the stale checkboxes and lands the packed-
> SoA-scratch idiom documentation. It also attempted the batched-lerp item
> (item 6) with a `render_prep.zig` consumer, measured it rigorously, found no
> real win, and reverted the consumer — see item 6 for the full account,
> including a caution about benchmark methodology worth reading before trying
> this again. Two items are **reinterpreted, not implemented as originally
> worded** — see the notes on items 3 and 5 below.

Goal: extend `src/core/simd.zig` with the vector primitives the SIMD-first
gameplay/AI stages will need, and land the layout-independent dense-path
vectorization wins that are measurable today. This is foundational and should
land before the SIMD-first emergent-AI stages (Slices 29–32) so they build on
shared primitives instead of each hand-rolling gather/rsqrt/normalize. The
applicability policy itself already lives in `docs/coding-standards.md`.

Why now: the primitive layer is foundation — its absence forces every new stage
to reinvent gather and normalize and risks drift. The dense-path wins
(sprite_batch, batched lerp) are low-risk and benchmarkable now via the existing
render-prep profile. Restructuring the existing AI/steering hot loops is NOT in
this slice — that is optimization that must be validated at battle scale and is
deferred to Slice 35.

Current foundation (already vectorized through `src/core/simd.zig`, with scalar
tails, no raw `@Vector` in systems):

- `systems/movement.zig` — position/velocity integration over SoA columns.
- `systems/collision.zig` — broadphase AABB sweep and narrowphase contact math,
  both ported onto the shared `simd.gatherFloat4`/`scatterFloat4` helpers
  (`a723821`) — no local hand-rolled `gather4` remains.
- `systems/collision_response.zig` — normal/penetration/velocity correction math.
- `systems/particle.zig` — particle integration and color/size lerp.
- `systems/pathfinding.zig` — flow-field octile heuristic and nav-grid marking;
  `pathfinding_range_alignment_items = simd.lane_count`.
- `game/render_prep.zig`'s `collectDynamicRecords` interpolation loops remain
  scalar `math.lerp` per entity/particle — a batched version was built and
  reverted; see item 6 below for why.
- The helper exposes `Float4/Int4/Mask4`, arithmetic, compare, select, clamp,
  gather/scatter, reciprocal-sqrt/normalize, sin/cos, lerp (including the
  `Vec2x4` batched `lerpVec2Float4`), and tail helpers, with a single
  `lane_count` source of width and a documented packed-SoA-scratch idiom on
  `gatherFloat4`.

Checklist:

- [x] Add gather/scatter helpers to `core/simd.zig`, generalizing collision's
      local `gather4`; port collision to the shared helper. Landed pre-existing
      (`a723821`); `gatherFloat4`/`gatherInt4`/`scatterFloat4` are in
      `core/simd.zig`, collision's broadphase/narrowphase call them directly.
- [x] Add reciprocal-sqrt / inverse-length and a vectorized 2D normalize with a
      masked zero-guard (matching the scalar `normalizeOrZero` semantics).
      Landed pre-existing: `reciprocalSqrtFloat4`/`normalizeOrZero2Float4`.
- [ ] Add a vector sin/cos (or sincos) approximation with a documented error
      bound and a scalar fallback path. **Deferred, not implemented.**
      `sinFloat4`/`cosFloat4`/`sinCosFloat4` exist as thin `@sin`/`@cos`
      vector-builtin wrappers (correct, but not a polynomial approximation),
      and have **zero production callers** today. Building a bespoke
      polynomial with no consumer would be unmeasurable, premature
      optimization. Deferred to Slice 29 (AI Perception), the first stage
      needing batched-angle FOV trig across many agents — implement and
      benchmark it there, against a real workload, not here.
- [x] Document the packed-SoA-scratch idiom in `core/simd.zig` (or a sibling
      helper) so later stages reuse one gather-into-lanes pattern. Landed this
      pass: a worked-example doc block on `gatherFloat4` citing
      `CollisionSystem.buildBroadphaseCandidatesSimd`/
      `writeNarrowphaseContactsSimd` as the canonical existing example.
- [x] Vectorize the sprite vertex transform in `render/sprite_batch.zig`
      (`writePreparedSpriteVertices` / `fillPreparedRange`). **Reinterpreted:**
      `writeSpriteQuad` already vectorizes the 4-corner rotation+translation via
      `Float4` math (landed pre-existing). The "camera transform" and
      "coordinate_space branch" clauses in the original wording no longer map
      onto the code as it evolved — the camera transform is baked into the GPU
      vertex uniform (no CPU-side camera math exists to vectorize), and
      `coordinate_space` is read only in `buildDrawGroups` for draw-group
      boundaries, not in the per-vertex emit path, so there is no branch there
      to mask.
- [x] Replace the AI separation-grid zero-fill (`systems/ai.zig`) with `@memset`
      or a vector fill. Landed pre-existing: `resetSeparationScratch` already
      zero-fills via `@memset` (the separation grid itself was replaced by
      `SpatialIndexSystem` in Slice 28).
- [x] Add a batched `lerpVec2` path in `core/math.zig` for render interpolation
      when the interpolation pass iterates many entities over contiguous
      columns. **Primitive landed, consumer reverted.** `lerpVec2Float4`
      landed in `core/simd.zig` (co-located with the other `Vec2x4` SIMD
      primitives it mirrors, not `core/math.zig` as originally worded) — it is
      correct and bit-exact parity-tested, and stays, currently without a
      production caller (same situation as `sinCosFloat4`, item 3).
      `game/render_prep.zig`'s `collectDynamicRecords` was restructured to
      consume it (buffer `simd.lane_count` already-scalar-filtered candidates
      → `gatherFloat4` → `lerpVec2Float4` → per-lane finish, scalar tail for
      the remainder) and initially reported as a ~6–9% `entity_collect` win.
      That result did not reproduce and the consumer was reverted:
      - The original comparison was against a stale `benchmark_outputs/`
        file from a non-adjacent ancestor commit, 9 commits and 226 unrelated
        `render_prep.zig` lines removed from the true parent — the true
        unmodified parent commit, measured in isolation, was itself ~2–6%
        faster than that stale baseline at every scale, which alone accounts
        for most of the falsely-reported win. Lesson: a benchmark file's age
        isn't the issue (that's what `benchmark_outputs/` history is for);
        comparing against a **non-adjacent commit with unrelated changes in
        the exact function under test** is.
      - The first "real" comparison also ran under the default `Debug`
        optimize mode, where per-element safety checks can dominate and mask
        (or invert) whatever a vectorized change would show under the
        `ReleaseFast` mode this project actually ships.
      - A corrected, controlled comparison (`git worktree` at the true parent
        commit, 8 repeated runs per side, both `Debug` and `--release=fast`)
        found **no reliable win at any scale, and a real ~5–15% regression at
        two of three scales under `--release=fast`** — confirmed
        independently by a `zig-review-specialist` review that reproduced the
        regression before the corrected comparison above was even run.
      - Root cause: `collectDynamicRecords`'s interpolation loop is
        memory-bound and dominated by non-vectorizable branchy work (asset-
        reference resolution, AABB cull, draw-record construction) — the two
        float lerps being batched were never the bottleneck. The batching
        overhead (scattered-index gather lowers to scalar loads + vector
        inserts, not a hardware gather; per-lane extract to feed the still-
        scalar finish work; stack-buffer bookkeeping; a by-value 4-candidate
        struct array passed to a non-trivially-sized function that may not
        fully inline) cost more than the ~24 scalar flops it replaced could
        ever save. This is a poor fit for the packed-SoA-scratch idiom
        compared to collision.zig's canonical use (compare/select-bound over
        many candidates, not memory/branch-bound over a few).
      Before retrying this consumer, either (a) profile first to confirm
      `collectDynamicRecords` is actually a hot path at real gameplay scale
      (not bench-fixture scale), or (b) extend the batch to vectorize the
      AABB cull alongside the lerp (gather `visual_index`-indexed
      `size_x`/`size_y`, compute the overlap mask in-lane) so the vectorized
      portion amortizes its own gather/extract cost over more work — both
      unverified, next-step ideas, not requirements.

Acceptance checks:

- [x] New primitives have unit tests and scalar-vs-SIMD parity tests; numeric
      approximations (rsqrt, sin/cos) document error bounds and keep a scalar
      fallback. `lerpVec2Float4` has a bit-exact parity test against
      `math.lerpVec2` (no fast-math in this codebase, so `expectEqual`, not an
      approximate tolerance, is the correct — and stronger — check). Sin/cos
      approximation remains deferred per above.
- [x] Collision narrowphase produces identical contacts after porting to the
      shared gather helper (parity test) — landed pre-existing.
- [x] `zig build bench` shows a render-prep win at 10k–50k sprites with no
      regression at low counts. **Not satisfied by `render_prep.zig`'s
      interpolation loop** — see item 6's full account: a controlled
      before/after comparison found no reliable win and a real regression at
      two of three scales, so that consumer was reverted rather than kept
      against this acceptance bar. The primitive-layer items (gather/scatter,
      rsqrt/normalize, sprite-transform vectorization) that this check was
      originally written against were already landed pre-existing and are
      unaffected by the revert.
- [x] Systems use `src/core/simd.zig` helpers, not raw `@Vector`.
- [x] `zig build verify` passes.


