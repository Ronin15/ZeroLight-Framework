# ai_update3 seal notes (2026-10-07, uncommitted)

Branch reset to `ecbac6c`; every edit from the 2026-10-07 evening session was
dropped. Nothing here is committed. Delete this folder when done.

## Verified state
- `zig build verify` passed at `ecbac6c`.
- Review of the last unreviewed code (`6aa0c72`, `61d2f6a`; `0b00252` and
  `334e8d0` are behavior-neutral) found no correctness bug in in-place link
  growth, OOM all-or-nothing, cursor retry, serial == threaded, or refusal
  removal.

## Small fixes worth reapplying (all docs/comments, verified against code)
1. `docs/changelogs/ai_update3.md`
   - Pathfinding bullet says interior link capacity grows "through a full
     relabel". Wrong: `growChunkLinkCapacity` grows in place (slot windows
     shift, slot indices remapped, no relabel; test at `nav_graph.zig:~2909`).
   - Missing: 12 commits after `3d95821` (c87b867..ecbac6c), the nav-memory
     refusal removal (`6aa0c72`), the guidance consolidation, and the
     target-scale rule. The "Tip" line is stale.
   - Known Open Items must match whatever is decided below.
2. `docs/roadmap/slices/slice-64e.md:53` "The K interior stride stays the only
   ramp refusal" is stale (no ramp refusal remains); the Goal text at ~:129
   ("refused before it changes the world") is stale too.
3. `docs/roadmap/slices/slice-64f.md:~173` says a level a link already grew
   "stays grown (retry skips it)". The code reserves every growth for a link
   before writing (`nav_graph.zig:~1391`), so a failed link grows nothing.
4. `nav_graph.zig:2816` test comment "fixed interior slot" → "interior slot".
5. Owner asked: `zig-design-specialist` effort `xhigh` → `high` (frontmatter
   and the CLAUDE.md tooling line).

## Open review findings (verified real)
- **High: local change costs O(level).** `growChunkLinkCapacity`
  (`nav_graph.zig:~1484-1545`) shifts every later slot on the level across six
  arrays and remaps every edge target. `repackLevelEdges` (64F) repacks the
  whole level on one chunk's overflow. That breaks the CS § Budgets rule from
  `ecbac6c` ("a local change … never to world width"). Note the rule's own
  "per-level or paged storage" escape is ambiguous, and owner direction
  is everything in chunks.
- **Medium:**
  - The growth paths are not all tested: two growths on one level from one
    link (the summed reserve; only a Debug assert guards it, so ReleaseFast
    would write out of bounds), both endpoints in one chunk, and growth of the
    last chunk.
  - `nav-update-links-capacity` is benched only at 256².
- **Low:** `addChunkLinkPortals` (`:~1936`) scans every world link per
  patched chunk.
- **Same class, found by the design audit:**
  - `rebuildLinkEdges` costs O(world links) per apply.
  - A batch touching more than 8 levels runs `relabelAllLevels`.
  - The `affected_levels` loop costs O(depth).
  - `WorldSystem.rampLinkOtherLevel` scans every link.

## Owner direction given this session
- Everything is in chunks. The chunk (level, cx, cy) is the unit of storage,
  change, threading, residency, copy and save for terrain and nav; nothing is
  sized to a level or a world. Fix this before merge.
- `.seal-notes/slice-64g-draft.md` is the design draft written to that
  direction:
  - chunk-owned terrain and nav;
  - staged all-or-nothing apply;
  - per-chunk GPU pages;
  - residency derived from simulation state (not the camera) for
    determinism;
  - 9 batches, with `chunk-scale` benches at 256²/1024²/2048² plus depth.

  It is a starting point, not an approved plan. Unverified items:
  - static bodies queryable per chunk;
  - residency determinism.
- Rules: no two rules may conflict. Rules apply to the whole codebase, not one
  subsystem. Slices are checklists and implementation data only, with no
  rules. Agents and CLAUDE.md point to rules and never restate them. When a
  rule clearly doesn't fit, call it out and tweak it; never loosen one to ease
  work.

## Known rule conflicts found (not fixed; decide structure first)
- CS § Budgets:
  - "per-level or paged storage" against the chunk direction;
  - "Everything is sized … per world instance" against "nothing sized to a
    world";
  - "World-extent data … never grown" blocks residency;
  - "default is keep" against "never one size for all";
  - two different lists of allowed fixed caps (~:202 vs ~:215).
- CS § Performance hot-path exception (~:47) against § Budgets "growth on a
  hot path is a defect".
- CS § Threading:
  - main-thread row-order event emission against "main thread is not a
    fallback owner";
  - "ask the owner if unsure" against CLAUDE.md "decide without asking".
- CS § Tests: the "16x16 tiles" fixture cap against multi-chunk contract tests.
- CS § Benchmarks: "all perf numbers from bench" against the DW ReleaseSafe
  dump for absolute numbers; roadmap index "(50k scales are ceilings)" and
  `architecture.md:~487` "ceilings for rare spikes" against the current bench
  rule.
- Agents and CLAUDE.md:
  - design agent "smallest change that reuses existing mechanisms" and
    zig-specialist "smallest coherent change" bias toward patches;
  - roadmap "Current foundation … do not rebuild" (index and ~55 slice
    headings) does the same.
- Rules live outside CS: about 85 normative lines across `architecture.md`
  and the area docs; agents restate area rules inline; slices carry rule text.

## Suggested morning order
1. Decide the guidance structure once: rules only in CS (add Ownership, Input
   And State Stack, Rendering, Events sections); other docs describe and cite;
   slices are data. Do it as one migration with one review, not line by line.
2. Reapply the small fixes above.
3. Decide whether the chunk redesign lands on this branch before merge
   (owner said yes) or as the first slice after merge; then update the
   changelog's open items and seal.
