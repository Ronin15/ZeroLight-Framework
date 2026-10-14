## Slice 64G: Chunk-Owned Terrain And Nav

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: none · Before: [Slice 65B](slice-65b.md), [Slice 46](slice-46.md), [Slice 76](slice-76.md), [Slice 77](slice-77.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: in progress.** Programming landed through `e2b9b2c`; the seal gate
(verify, ReleaseFast test, gpu-smoke, the acceptance benches, the owner demo)
remains. Kept as one slice by owner decision (2026-10-08).

Goal: terrain and nav storage and work owned per chunk `(level, cx, cy)`, so a
dig, ramp, cave-in, or explosion costs work only in the chunks it touches,
memory follows content rather than level area, and nav processes per chunk so
threading scales with any number of updates and path requests
(`.claude/rules/engine-design.md` § Target scale).

### Current foundation

Reference: main's nav (`main:src/game/systems/pathfinding/`). The branch's
nav storage, level-link, and nav-apply changes since main are replaced, never
extended, reused, or used as a baseline (owner decision, 2026-10-08). The Zig
0.17 migration and the Slice 72 and 71B.1 changes in the same files stay.

Main already partitions nav by chunk: positional per-chunk portal slots,
chunk-local components (a flood never crosses a chunk border), a dirty-chunk
patch that re-derives touched chunks from the world, threaded remask and patch
stages with per-stage tuners, cell-keyed level links, goal-keyed caches, and
fixed node budgets with a two-attempt retry. Its storage, fallbacks, and
per-change work are still sized by level, world, or content totals. Numbers are
derived for one 2048² level (4,194,304 cells, 16-cell nav chunks, 16,384
chunks); multiply by depth and world count. The defect lists describe main
(`b39a46f`), the replaced baseline; the Checklist records what landed against
each, and § Landed nav: measured limits records what the landed nav still leaves
(numbers from the landing commits, Debug unless noted).

Storage sized to level area:

- `NavGrid` (`nav_grid.zig:43,47,53`): `blocked` 1 B + `components` 4 B per
  cell, plus `static_blocked` 1 B per cell on level 0 → 20 MiB per level.
- `NavLevelGraph.cell_to_portal` (`nav_graph.zig:83`): 4 B per cell → 16 MiB
  per level.
- Slot geometry (`nav_graph.zig:355`, `computePortalGeometry` `:1116`): 64
  slots for every chunk (60 perimeter cells), all-solid or uniform included,
  × 32 B (portal, edge range, order, label keys and starts,
  `nav_graph.zig:1163-1168`) = 32 MiB per level. Every level also reserves the
  interior link endpoints of every level (`:367-372,1122-1171`).
- Together ≈ 68 MiB per level before edges, ≈ 8.5 GiB for 128 levels of one
  world, whatever the content.
- `SearchScratch.cells` (`scratch.zig:218`, `system.zig:280,413`): a level's
  cell count per participant (workers + main), 13 B per cell ≈ 52 MiB each.
- Group flow fields (`group_field.zig:90-106`, `system.zig:404-406`): every
  field up to `max_group_fields` reserved at nav build, 21 B per cell ≈ 84 MiB
  each.
- Terrain: `WorldSystem.dense_tile_ids` is one flat array, 2 B per cell per
  dense layer, up to `max_dense_bands_per_level` (2) layers per level → up to
  16 MiB per level; the uniform-fill flag is per layer and one dig clears it
  (`world_system.zig:127,291,1187`).
- Perception: line of sight reads the level's chunk terrain directly
  (`WorldSystem.levelBlockedView`, O(1) per cell); it holds no LOS state.
- Render: one world-wide dense tile buffer, 4 B per cell per dense layer,
  uploaded once at load; `addDenseLayer` is refused after the upload
  (`world_system.zig:643,1227-1234,1585`).

Work sized to the world, a level, or content totals:

- Every incremental apply clears every pending request and negative result
  and drops every group field, world-wide (`system.zig:494-495`).
- Cached-path eviction scans the whole result cache per batch on the main
  thread (`ResultCache.evictCrossing`).
- The blocked query behind every chunk remask scans every dense layer in the
  world and the level's sparse tiles per cell (`world_system.zig:1413-1428`).
- Static obstacles: the coverage refresh scans every static body per covered
  cell (`nav_grid.zig:150-158,382-392`); an unresolvable rect marks the whole
  level dirty (`system.zig:579-583`); `markStaticBodies` covers level 0 only
  and builds an `AutoHashMap` per call (`nav_grid.zig:105,116`).
- Links: each patched chunk scans every world link (`nav_graph.zig:1477-1484`);
  endpoint dedupe is O(links²) (`:1174-1184`); `rebuildLinkEdges` rebuilds
  every link edge per batch (`:740,1249`); `WorldSystem.rampLinkOtherLevel`
  scans every link on every entity cell entry (`world_system.zig:1396`,
  `dig_controller.zig:226,261`).
- An edge-window overflow rebuilds every level's abstract graph, doubles the
  edge slack of every chunk on every level for good, and bumps `nav_version`,
  which clears every cache, pending request, and group field
  (`nav_graph.zig:725-737,744-749`, `system.zig:479-482`).
- A batch touching more than 8 levels relabels and rebuilds every level, with
  the same version bump (`nav_graph.zig:702-709`, `types.zig:142`).
- Runtime ramps: an interior endpoint is skipped until a full rebuild, which
  runs only at init or in the fallbacks above (`nav_graph.zig:1497`, test
  `:2215`); `digRamp` edits only the dug level, so the partner level is not
  patched (`dig_controller.zig:169`); a ramp on walkable floor flips no
  `blocks_movement`, so nav filters its tile event (`system.zig:684`).
- Cross-level search uses a zero heuristic off the goal level
  (`solve.zig:401-404`), so it explores every level it reaches within its node
  budget and far cross-level goals exhaust both attempts. Replaced by a
  consistent cross-level heuristic (`22ac6ae`, `8358b37`, `41afa5f`); far goals
  past the tier-1 caps advance by partial hops (`1a5241f`, `ac48f66`).
- Creating a level or world: the abstract build is serial per chunk and level
  (`nav_graph.zig:580-593`), perception prebuilds every level serially
  (`perception.zig:543-548`), and a nav rebuild clears all runtime state
  (`system.zig:420`).
- Perception rebuilds a whole level when dirty area passes 25% of it
  (`perception.zig:394-404`).

Failure and limits:

- Not all-or-nothing: `NavGraph.rebuild` bumps the version and writes
  dimensions and every level's arrays before steps that can fail
  (`nav_graph.zig:466-500`); `applyNavUpdates` remasks before patching, a
  worker OOM is treated as an edge overflow (`:237-243`), and
  `rebuildLinkEdges` clears before it appends (`:1250-1268`).
- A nav-apply error skips that step's perception and steering reactions
  (`game_demo_state.zig:673-675`).
- Load gates sized to level area refuse worlds: `NavMemoryBudget.check`
  (`nav_memory.zig:191`) and `validateDenseRenderBudget`
  (`world_system.zig:647`). The nav gate is also the only loud check on index
  widths (cell, label, slot, edge); elsewhere they are Debug asserts
  (`nav_graph.zig:1118`).
- Chunk edge sizes differ by system: `chunk_size_tiles` 16 in
  `WorldBuildConfig` and 8 in `default_chunk_size_tiles`
  (`world_system.zig:48,125`), nav chunks 16 nav cells (`types.zig:130`) with
  the nav cell size set apart from the tile size
  (`simulation_pipeline.zig:288`), test fixtures 4 and 8.
- No bench varies level size or depth at a fixed change: `nav-update-*` runs
  one 256² world (`nav_update.zig:52`), and `pathfinding*` stays at or below
  256² on one level.

Landed nav: measured limits (each kept by an owner or main-session call; none is
a design open for this slice):

- **Long links.** `pathfinding-cross-level-teleport` at side 256 (`b76d06d`, the
  N6c-0 benches are the record): random pads at 64 or more teleports solve 0/64
  routes at the 4096-node tier-0 cap; the border band at 15,000 teleports solves
  54/64; band up to 4,096, strip, and random 16 solve 64/64. The band residual
  is 16-pair merge precision (`8358b37`: T = 4,096 claims 2,415 nodes against
  1,884 with an ideal h). Not re-run on the dense layouts since the
  crossing-aware heuristic (`41afa5f`) and least-h partials (`ac48f66`). Owner
  2026-10-12: the game's long links are one-off world gates and dungeon
  entrances, never dense fields; the trie and cut designs (N6c-1, N6c-2) are
  dropped.
- **Dense-change main floor.** After B2a every main section left in the
  dense-change reaction is an O(1)-per-item ordered merge or commit, linear in
  what changed (`threading.md` allows it); together they are the floor, a one-step
  cost, not a growing order (B2a-2 dropped). Measured at `2c1a9c1`, tuned:
  connectivity merge 218 µs (cave-in 256 chunks) and 412 µs (enclose P = 196),
  connectivity layout/open 249 µs and flood merge 735 µs (P = 196, 2× the flood's
  threaded search), eviction removal 385 µs (2.7k evictions,
  `pathfinding-evict 640010000`). Main totals then were 2.3–3.7 ms, including the
  plan merge and mark loop B2a-1 then removed (plan 824 → 228 µs, mark 428 → 24 µs,
  `d11f1d9`).
- **Dense-dig threading.** `pathfinding-evict 640010000 --details` (`83172ce`):
  the eviction stage costs about 0.7 ms inline, above the 250 µs gate; the tuner
  probes workers, they do not win on wall time beyond spread (2.62–2.91 ms across
  cases), and it settles inline or threaded run to run: a measured choice with the
  threaded path present.
- **Long paths** (`pathfinding-long-path`, `ac48f66`): every walk and hop chain
  arrives. Walks: open diagonal and cave at 512/1024/2032; serpentine 1/4/15 walls
  in 3/9/32 solves, 6.3/45.4/200.9 ms. Hop chains (hops, claims, ms): descent
  16/64/127 levels 3/9/18, 32.6k/167k/341k, 46/239/480; wide 512/1024/2048 1/2/4,
  9.1k/27.5k/60.4k, 13/37/77; deep wide 4/8/16 3/5/9, 35.4k/84.0k/174k, 48/116/238:
  linear in route length, about 18.6k claims per hop. One attempt still ends
  `.missing` at the caps for descent 64/127, wide 1024/2048, and deep wide, which
  the hops serve. On wide levels H about halves the claims (layout 4:
  2,175 → 1,439, 34,851 → 18,637, 139,347 → 71,275 at 256/1024/2048, `41afa5f`)
  but they still grow about as D²: graph distance runs above octile. Owner
  2026-10-14: no optimization loop on long paths; what remains is recorded:
  - pocket floor: an h-minimum pocket deeper than the tier-1 budget walks to its
    floor, drops, and retries each cooldown;
  - cut-induced creep: a capped stitch climbing above h(start) keeps only its
    descending head (not seen measured);
  - shared partials: an off-corridor agent outside the end window steers to the
    corridor's first cell (`cachedView`), as shared full paths do (kept);
  - a nav change between hops voids the hop chain's descent argument;
  - a long route costs about route length / hop reach hops, each up to the full
    ladder (about 18.6k claims, about 25 ms on descent).
- **Region layer shelved** (owner 2026-10-12,
  `.claude/reports/64g-long-path-owner.md`): region corridors and windows return
  only if long routes fail again.
- **One-way closure** (`a294a7a`): a tail toggle of a 4,096-terminal chain costs
  20.7 ms (its SCC plan is level-serial, accepted), a head toggle 2.44 ms tuned; a
  dense opening reserves about 2.1× the merged block it creates; a system of k
  terminals holds about k²/32 words. A single dominant one-way system's Tarjan is
  one item, so it runs where the thread system places one item; its rows thread.
- **Accepted constants.** Reach and the goal check cost status and cache hits a
  fixed O(1) per query (`pathfinding-query` 4096 +117 ns per query, `2c1a9c1`).
  Path registration costs `pathfinding` 512 about +0.33 ms tuned per step (3,072
  registrations) and the query +8% (`870ac61`, owner). Connectivity maintenance
  adds a flat +22–29 µs per dig and about +200 µs per ramp (`e793590`). A level add
  pays about +15 µs for its own plan sets, flat in depth (`d11f1d9`).
- **Traversal classes.** Reach is keyed by traversal class with one connectivity
  instance per class; `walk` is the only one, so a class that moves differently
  adds an instance.

### Architecture notes

- Owner direction (2026-10-07, 2026-10-08): the chunk is the unit of terrain
  and nav storage, change, work, threading, and save; nav covers the whole
  world; nothing is evicted from the simulation
  (`.claude/rules/engine-design.md`, `.claude/rules/budgets-capacities.md`).
- A level holds a directory of its chunks; nothing is sized to level area or
  world extent. Uniform and all-solid chunks stay cheap.
- A local change touches only its chunks; a dense change processes its dirty
  chunks in parallel; creating or destroying a level or world costs its own
  chunks.
- A ramp dug at runtime is routable the same step on both levels, perimeter or
  interior endpoint, and is never refused.
- A step's nav apply is all-or-nothing: OOM leaves the graph intact and the
  edits buffered for retry; no degraded state and no level- or world-wide
  fallback rebuild.
- Path requests fan out against the read-only chunked graph; a request's
  scratch follows its node budget, never level cells
  (`.claude/rules/pathfinding.md`).
- Serial equals threaded, and incremental equals a full rebuild
  (`.claude/rules/threading.md`, `.claude/rules/simulation.md`).
- Render presentation pools may be sized from the viewport; nothing in render
  is sized to level area (`.claude/rules/render.md`).
- Provides: 65B copies and swaps only dirty chunks; 46 saves terrain per
  chunk; 64B rebuilds derived nav from chunk storage (perception holds no LOS
  state); 38 gets static collision bodies in nav on every level; 74 creates and
  destroys worlds by their chunks; 75 paths far-off agents over the whole-world
  graph.
- Accessor contracts used by gameplay, perception, and render stay the same.
- Owner decision (2026-10-09): a ramp dig always digs out its exit cell on
  the level above, so a ramp never leads into rock. A blocking obstacle or
  sparse tile at the exit is cleared with the floor; a static body there
  leaves the ramp dug but unroutable until it moves; a hole at the exit still
  links, and the fall rule applies on arrival.
- Owner decision (2026-10-09): one shared static-collider structure (rows of
  entity, level, and bounds in entity order) is built here with nav as its
  first consumer; [Slice 71B](slice-71b.md).1 moves steering and collision
  onto it.
- Owner decision (2026-10-09): Slice 72 items D3, G1, G2, E2, and E3 land
  with the nav work that rewrites the same code; level destroy moves to
  [Slice 74](slice-74.md).
- Owner decision (2026-10-09): cave-ins ([Slice 76](slice-76.md)) and
  explosions ([Slice 77](slice-77.md)) belong to `DestructibleController`;
  64G provides the dense terrain path they write through.

### Checklist

- [x] One chunk edge size (power of two, at most 16) and tile-sized nav cells
      shared by terrain, nav, and scope (`23c24ec`); one `ChunkGeometry` with u32
      sides for terrain, nav, and static colliders, validated at every create
      path (`19256c5`).
- [x] Terrain stored per chunk behind the existing accessors; the blocked
      query costs its chunk (`453993f`).
- [x] Uniform and all-solid chunks stay cheap after edits elsewhere on their
      level: terrain (`453993f`); nav chunks OPEN or BLOCKED hold no cells, and a
      chunk with no portal holds no record (`5db9025`).
- [x] Level links stored with their endpoint chunks; a link lookup, including
      on entity cell entry, costs the chunk, not the world's links: world
      (`453993f`, `fe2d99e`), nav records (`1305fa9`, `5db9025`), O(1) endpoint
      dedupe per chunk (`408b5a0`).
- [x] Nav storage per chunk; a level holds only a directory of its chunks, and
      nothing in nav is sized to level cells: per-chunk cells and records
      (`5db9025`), budget-sized search scratch and chunk-block group fields
      (`10bbbc7`), level-owned plan sets (`d11f1d9`), staging released after use
      (`e40845d`), counted pool growth (`eaa4a80`).
- [x] Runtime ramps routable the same step on both levels, perimeter or
      interior, never refused (`fe2d99e`, `1305fa9`).
- [x] Nav apply per step all-or-nothing over dirty chunks, threaded; no relabel
      or full-rebuild fallback (`1305fa9`).
- [x] A local nav change leaves pending requests, group fields, and cached paths
      outside its chunks untouched; path eviction costs the results that touch its
      chunks, not the cache size (`870ac61`, `8b59c3c`, `9f7de20`, `83172ce`); a
      level rebuilt by a content revision evicts only that level's results and
      fields (`a869e15`). Negative results no longer exist: reachability answers
      unreachable goals (`2c1a9c1`).
- [x] A static obstacle add, move, or destroy costs its footprint chunks,
      independent of static-body and entity counts, on every level, with no
      whole-level fallback and no per-call map (`5db9025`: 77 ms → 18 µs at 10k
      statics, flat).
- [x] Path search crosses chunks and levels through the chunked graph with
      budget-sized scratch; a cross-level path's cost follows path length, not
      levels explored; group flow fields not sized to level cells: scratch and
      fields (`10bbbc7`), cross-level heuristic (`22ac6ae`, `8358b37`,
      `41afa5f`), partial and least-h hops for routes past the tier-1 caps
      (`1a5241f`, `ac48f66`), long-route baseline (`982d934`), hole-moving heap
      sifts (`e2b9b2c`). Limits above.
- [x] A level added in play builds only its own chunks, threaded, and is never
      refused; other levels' nav, caches, and runtime state are untouched
      (`1305fa9`: 85.8 ms → 1.2 ms at 256², `d11f1d9`, `a869e15`); a replaced
      world releases all its storage.
- [x] Render terrain uploaded per chunk for the render window; dense layers
      added in play; GPU byte gate replaced by a report (`9bbfdc0`).
- [x] A world's GPU tile store is released when its world is destroyed or
      replaced, never only at renderer shutdown (render step (a)).
- [x] GPU tile memory follows the camera's window, independent of level
      size, depth, and world count; no layer or draw cap beyond the store's
      u32 width fit (render step (c)).
- [x] The GPU sync after one dig is back within spread of `5439e36`
      (`chunk-scale-gpu-sync-dig` was 4–12% slower after render step (c);
      +0.5%, within spread, once change marks replaced the edit queue).
- [x] The GPU sync's edit cost is measured on its own axes: linear in window
      chunks per edit and in written layers for a batched change (`639f55d`).
- [x] Dense one-step terrain changes (cave-in, explosion) written per chunk on
      the thread system, serial equals threaded (S3b). Their gameplay
      producers are [Slice 76](slice-76.md) and [Slice 77](slice-77.md).
- [x] Perception's line-of-sight state lives on chunk storage, not a
      level-area bitmap; its rebuild threshold derives from operation cost, not
      level area (nav N1: LOS reads chunk terrain; no LOS state or threshold).
- [x] A nav-apply failure leaves that step's perception and steering
      reactions intact (nav N1: steering runs before the nav error returns;
      perception has no reaction).
- [x] Nav's request side threads like other systems: request intake and
      group-field expansion are threaded stages with their own tuners, serial
      equals threaded, solve outputs sit at their ordinals, pending compaction
      costs the solve window (`8ee993a`), and the stages engage under varying
      load (`4b15d88`); publish copies and registry flushes thread (`870ac61`,
      `8b59c3c`, `9f7de20`); the step's goal projections thread (`2c1a9c1`).
- [x] Tuner resets learning when an inline batch's item count changes
      (`thread_system.zig:1134-1137`, `:229-237`: the inline shape's range size
      is the item count, so `record` sees a new profile): nav intake and group
      fields stay inline whenever the request or field count varies, e.g. the
      elastic ramp at 4,000 agents runs intake inline every ramp step.
      Landed (TS1): inline batches are one profile; an out-of-band batch is
      not sampled; a sustained same-side shift re-tunes a threaded stage.
- [x] Tuner window-minimum demotion (`thread_system.zig:241-249`, `:399-410`,
      `:599-610`): four lockstep group fields finish in one near-empty batch, the
      advance pass demotes to inline and stays there for 360 batches.
      Landed (TS1): windows read the median batch.
- [x] Tuner judges a demotion and a shift correctly: the first inline window
      after a settled demotion restores a wrongly dropped threaded profile; a
      sustained shift's retune re-bases on the incumbent; probe and demotion
      counters for `--details` (`69e7ed2`, `c31d8b1`, `15362e7`); a
      wait-dominated demotion no longer drops a threaded profile (`ff670b4`).
- [x] The runtime perf log records each change path's cost-driver stage:
      `path_intake`, `path_registry_flush`, `nav_remask`, `nav_evict`,
      `static_collider_splice` (`69dba4f`), `nav_connect` (`e793590`),
      `nav_closure` (`a294a7a`). Group-field batches stay bench-only: they drive
      no change path (`threading.md`).
- [x] One shared static-collider structure, synced once per entity per step,
      with nav as its first consumer; a static add, move, or destroy costs its
      own rows and chunks (`5db9025`); steering reads it through a size-class
      query map (`173cc17`). Collision moves onto it in 71B.1.
- [x] Steering's prepare phase, its agent grid, AI movement-intent apply, and
      collision response run as threaded stages with main O(1) per item
      (`ede5509`, `df7f1ea`, `cc58f38`, `ff670b4`); plane traversal's per-agent
      cell-entry test runs on workers, main O(1) per entry (`3d0e8f5`, `08c01c2`).
- [x] Runtime ramps dig out their exit cell on the level above in the same
      dig, with the edge cases above (owner decision).
- [x] Slice 72 D3, G1, G2, E2, and E3 closed with the nav landings that
      rewrite the same code: D3 (`1e97b65`), G1 (`10bbbc7`), G2 and E2
      (`f638ff3`), E3 superseded (no negative cache, `2c1a9c1`).
- [x] Level-sized load gates retired, so creating a world in play (74) and
      adding a link are never refused for capacity (`1305fa9`, `ab9f01f`); index
      and format widths (cell, chunk, label, slot, edge offsets, level) fail
      loudly at world create, load, and growth (`23c24ec`, `eaa4a80`,
      `19256c5`); ids that grow in play fail as `OutOfMemory` at their growth
      seam (`ab9f01f`).
- [x] World creation and dense-layer adds in play are never refused for
      capacity: band lists grow, and edits hold no GPU memory for unrendered
      worlds (render R3).
- [x] Replaced branch nav code and its tests removed; main's nav restored
      (`2c09cec`).
- [x] Reachability is maintained at every nav batch and answered in O(1) at
      intake, status, and solve, never by a failed search: benches (`8a28fd1`),
      connectivity ids with a balanced threaded flood (`e793590`), the exact
      one-way closure (`a294a7a`), reach checks and one shared goal projection
      per goal key per step (`2c1a9c1`), per-H-component closure blocks with no
      world-scale compaction (`309a1a5`, base `285b1d2`).
- [x] The dense-change reaction's main thread is split by section, and its
      growing main work threads: level-owned ordered plan sets replace the heap
      merge, the mark assert moves into the per-event loops (`1657d63`,
      `d11f1d9`). The floor left is recorded above.
- [x] Long-link heuristic: level-aware link bounds (`0ee5a6d`, `22ac6ae`),
      coupled long-link pairs (`8358b37`), layout benches and the link-fold
      baseline (`b76d06d`). The trie and cut follow-ups are dropped (owner); the
      limits are recorded above.
- [x] Nav storage bounds are honest: an `@sizeOf`-based bound beside each
      structure fed by the built world's content, checked whole against live
      bytes in every nav group (`639f55d`, `0c85293`); one bench world builder
      (`639f55d`).
- [x] Combined-review fixes since the 2026-10-07 branch review: exact half-open
      cell spans (`685df2d`), shared stage helpers and one dispatch pattern
      (`819d8d8`, `2496824`), std-first pathfinding (`3be2d5c`), staging release
      (`e40845d`), and areas A–D (`eaa4a80`, `a869e15`, `08c01c2`, `adf883d`).
      Core-system findings went to the core-systems branch checklist.
- [x] Benches cohere: production-read estimates, per-group labels and
      formatters, one item code and fixture set, single-axis right-sized sweeps,
      world-backed request-load groups (`0c85293`).
- [x] H's per-node cost on capped searches (+137% Debug / +29.5% ReleaseFast on
      `pathfinding-long-path` 2000064, `41afa5f`): the open-heap sifts move a hole
      (`e2b9b2c`: descent 64 at caps 29.75 → 26.54 ms, its hop chain
      239.2 → 207.5 ms, `pathfinding` 1024 serial 41.7 → 31.4 ms, cross-level depth
      256032 serial 24.8 → 20.9 ms).
- [x] Tests: incremental equals a full rebuild, serial equals threaded; OOM at
      every allocation leaves state intact and the retry equals a rebuild; one
      chunk's change leaves every other chunk untouched; a multi-level cave-in
      in one step; a runtime ramp routable the same step on both levels; one
      dig leaves unrelated pending requests, group fields, and cache entries
      intact; a static-obstacle move patches a constant chunk set at any static
      count (each beside its landing).
- [ ] Followers of a shared goal's partial path keep following when another
      agent re-solves it from the end window. Today the re-solve replaces the
      cached partial, and followers still on the old path, now off the new one,
      steer toward its first cell; a TTL re-solve of a full path does the same.
      Gated on a crowd walk in `pathfinding-long-path` that shows followers
      orphaned.
- [ ] The nav estimate's level-build staging peak is measured, not derived:
      `buildLevel` shrinks its staging before it returns, so `checkNavBytes` never
      sees the peak its bound charges (`639f55d`).
- [x] Docs: `docs/architecture.md` terrain and pathfinding sections; 65B, 46,
      and 64B checked against chunk storage.

### Acceptance checks

- [x] `chunk-scale-*` bench groups at 256², 1024², 2048², and 8 / 32 / 128
      levels (`.claude/rules/tests-benchmarks.md`): dig, ramp, cave-in, and
      explosion fill flat across sizes; level create flat across depth and
      linear in its own chunks (level destroy and the world-count axis are
      74's).
      Fixtures build once outside the timed loop and the groups run quickly in
      Debug. Measured at `75be288` (Debug, serial): dig 152 µs and ramp 226 µs
      at every side and depth (nav 434 / 730 µs); cave-in and explosion fill
      linear in region chunks and flat in side and depth (64 chunks:
      3.43–3.47 ms / 2.33–2.39 ms); level add flat in depth (400–414 µs at
      256²) and at most linear in its own chunks (0.41 / 2.1 / 7.5 ms at
      256² / 1024² / 2048²).
- [x] An A\* path of the same length costs the same at 2048² as at 256²
      (`pathfinding-level-size`), and a cross-level path of the same length costs
      the same at 8, 32, and 128 levels (`pathfinding-cross-level-depth`,
      `pathfinding-long-path` layout 3), and a cave route arrives with each
      search within the node caps (`pathfinding-long-path` layout 5 and its
      walks; owner 2026-10-14, replacing "a cave route's cost follows its
      length"). Measured at `75be288` (Debug, serial): level size 1.20 / 1.17 /
      1.16 ms at 256² / 1024² / 2048²; cross-level depth 20.8 / 20.2 / 20.2 ms
      and layout 3 7.8 / 8.1 / 7.9 ms at 8 / 32 / 128 levels; cave walks arrive
      at 512 / 1024 / 2032. Recorded limit: one cave search's claims grow about
      as length squared (287 / 8,344 / 19,820 claims, 0.35 / 5.4 / 13.0 ms at
      256 / 1024 / 2032 cells; tier 1 4,248 → 15,724 for 2× length), since graph
      distance runs above octile; the region layer that would remove it is
      shelved.
- [ ] `zig build verify` and `zig build test -Doptimize=ReleaseFast` pass.
- [x] Manual (display, Debug): digs and ramps in the demo; NPCs route over
      the changes. The in-demo cave-in check is Slice 76's. Owner 2026-10-14
      at `b83dd86`: dug one layer deep and built ramps up; entities used the
      ramps (60 s: 40 dig events, 202 chunks patched, 44,826 paths available,
      none dropped or budget-exhausted).
