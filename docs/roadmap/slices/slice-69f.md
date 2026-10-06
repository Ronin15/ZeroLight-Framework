## Slice 69F: Paged World Regions For Worlds Beyond One Bounded World

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 46](slice-46.md), [Slice 51](slice-51.md), [Slice 58](slice-58.md), [Slice 64B](slice-64b.md), [Slice 65C](slice-65c.md) (gated on a world exceeding the bounded budgets) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started — gated.** Gate: a game's minimum shipped world cannot
be one bounded `WorldSystem` at its design size. Either
`validateDenseRenderBudget` refuses it (`DenseTileGpuBudgetExceeded` at
`k_max_dense_tile_gpu_bytes = 64 MiB`, or `DenseLayerWindowExceeded`), or the
nav gate returns `NavWorldTooLarge` at that game's shipping
`max_nav_memory_bytes`. Depends on:

- **46**: save sections, `UserStorage`, `content_fingerprint`;
- **51**: lane `submit` / `isDone` / `complete` for app-layer consumers;
- **58**: the generator;
- **64B**: `normalizeDerivedState` and the hashed `"pipeline_history"`
  fields, which define what crosses a swap;
- **65C**: `WorldGenStream`, the streaming generation path a swap uses;
- **69A**, when a game uses structures.

**Decision: seamless chunk streaming is rejected.** The replacement is paged
regions joined by loading seams. Reasons, from live code:

- The GPU tile-data buffer is built once from the whole flat
  `dense_tile_ids` array, and `addDenseLayer` refuses layers after upload
  (`src/game/world_system.zig:1625-1636`). Partial uploads would need a
  toroidal resident buffer with remapped `denseLayerOffset` every frame.
- `NavGraph.rebuild` is whole-world at init
  (`systems/pathfinding/nav_graph.zig:456-560`), and patches mutate the live
  graph while queries read it. Slice 65B's front/back double buffer and
  fence patch an existing graph of fixed geometry. Inserting chunks would
  also need growing geometry and slot renumbering, which paging avoids.
- Every position column, `previous_x/y`, path cache, marker, anchor and node
  index uses absolute world `f32` coordinates. A sliding origin would rebase
  all of them.
- Paging reuses whole pieces that already exist: Slice 58's pure generator
  (keyed globally), Slice 46 sections as region images, the Slice 51 lane, and
  `LoadingState`.

Goal: the world is an unbounded-by-design (bounded by `i16` coordinates) grid
of equal-size regions. Exactly one region is resident. Crossing a region edge
swaps regions through `LoadingState`. Visited regions persist as region images.
Regions that are not resident are frozen. Generation is continuous across
seams.

### Architecture notes

**Model.**

- `RegionCoord = struct { x: i16, y: i16 }`.
- `RegionWorldConfig { region_width_tiles, region_height_tiles,
  chunk_size_tiles, underground_level_count }` is fixed per game. Every region
  has the same dimensions.
- Validation:
  - dimensions are multiples of `chunk_size_tiles` and of 69A's
    `site_cell_tiles`, so no chunk, feature block or structure site straddles a
    seam;
  - one region passes `validateDenseRenderBudget` and the nav gate.
- `k_resident_regions = 1` (fixed).

**Global keying.**

- `WorldBuildConfig` gains `keying: WorldGenKeying = .local` and
  `region: RegionCoord = .{0,0}`. `.local` is Slice 58 unchanged, with its
  goldens.
- `.region_global` uses global cells
  `gx = rx * W + x`, `gy = ry * H + y` (`i32`):
  - Noise uses `noise.valueNoise2Global(seed, gx, gy, cell_size, octaves)`,
    whose lattice key is `rng.mix64(seed, @bitCast(lx), @bitCast(ly),
    noise_lattice_salt + octave)`.
  - Per-cell draws use `rng.mix64(level_seed, @bitCast(gx), @bitCast(gy),
    salt)`, where `level_seed = rng.mix64(field_seed, level, 0,
    level_salt)`.
  - Edge biomes recompute neighbours globally, so they are continuous across
    seams.
- Region-paged worlds get their own three pinned goldens: region (0,0),
  region (−1,0), and the seam-adjacent edge cells of both.
- `chunk_biomes` is per region.

**Seam crossing.**

- **Detection** runs in `GameDemoState` after the structural commit. The
  player's body can never leave the region rect: `bounds_and_tile_gate`
  clamps it to the world bounds every step (`world_gate.zig:24-25`,
  `Player.clampToBounds`, `player.zig:74-88`). So the trigger is "pressing
  against an edge", not "leaving":
  - the clamped player AABB touches a region edge, that is, its center is
    within `half_extent + 1 px` of that border on that axis; **and**
  - the player's held movement input this step points outward across that
    edge (`move_left` at the west edge, `move_right` at the east edge,
    `move_up` at the north edge, `move_down` at the south edge; a diagonal
    hold at a corner picks the x-axis edge first, a fixed rule).
  - The edge must have a neighbour region inside the `i16` coordinate range
    and the file cap; otherwise it stays a plain clamped wall.
  - On the first such step it requests
    `StateTransitions.replace(LoadingState.regionSwap(.{ .to, .entry_cell,
    .level }))` exactly once (the transition replaces the state, so no latch
    is needed). `entry_cell` mirrors the exit cell onto the opposite edge,
    placed `region_seam_hysteresis_cells = 1` cell inside it.
  - The inputs are the committed pose and this step's held bits, which
    replays record, so a replay reproduces the swap step.
- Steps inside `LoadingState`:
  1. Encode the outgoing `RegionImage` on the main thread (cold path). Its
     content is Slice 46's payload sections restricted to region-owned
     state:
     - every `WorldSystem` field classified as hashed, except `clock`;
     - every `DataSystem` entity except the player and entities the player
       holds (57 inventory/equipment);
     - the Slice 68C `pending_drops` entries whose position lies in the
       region rect (all of them, since positions are clamped to the region),
       in FIFO order; the incoming region's image restores its own entries
       (`head = 0`).
     The image is written by a lane job (`submit`, then `isDone` each frame,
     then `complete`).
  2. Obtain the incoming region. If a stored image exists, a lane job reads,
     CRC-checks, validates and decodes it. Otherwise it is generated with
     `.region_global` keying, through Slice 65C's `WorldGenStream` when a lane
     thread exists, else Slice 58's threaded `LoadingState` path (same golden
     hashes).
  3. Install the player on `level` at `entry_cell`. If that cell is blocked,
     use Slice 58's ring search (radius 32) on that level. If no cell is
     found, the swap is cancelled: the outgoing image just encoded is
     re-installed, and the player is placed one cell back inside the outgoing
     edge.
  4. Carry session state across: `step_count`, `seed_root`, `clock.game_ms`,
     the player's rows, `FactionRelations` (Slice 63), and the hashed
     pipeline-history fields (Slice 64B: input latches, sensory, dig, AI,
     steering history) carried across verbatim. The swap is a normalization
     point: `normalizeDerivedState` (64B B5) runs on the installed region,
     and the next recording's first frame sets replay `flags` bit1
     (`normalized_before_step`).
  5. Rebuild derived state through Slice 64B's `normalizeDerivedState` (nav
     graph, pathfinding caches, perception caches, the steering snapshot),
     plus `ResourceNodeIndex` and `EnvironmentController.resync`.
- **Frozen regions.** Absolute-step schedules in a region that is not resident
  catch up lazily on re-entry through `stepReached`:
  - Slice 61 nodes become available;
  - Slice 62 anchors become eligible;
  - Slice 57 world items despawn on the first sweep.
  Non-resident regions are never simulated (decided).
- Entities other than the player never cross a seam (decided non-goal).

**Storage.**

- Region images live under `UserStorage` at
  `regions/working/r_<x>_<y>.zlregion` for the live session.
- A Slice 46 save copies `working/` into `saves/slot_<n>.regions/`. A load
  copies it back. Both are lane jobs.
- The slot header gains `region_x: i16` at offset 122 and `region_y: i16` at
  offset 124, taken from Slice 67C's `reserved` bytes; the remaining
  `reserved` is `[2]u8` at 126, validated zero (Table T3). Non-paged games
  write 0. This is a `format_version` bump (live value + 1; header plus the
  region-image payload).

**Replay.** A Slice 49 recording ends at a seam. The recorder closes its
chunk, and a new recording starts with the region in its header. That is a
`replay_format_version` bump (live value + 1; v5 in the merged order, Table
T1): `header_bytes = 88`, with offset 80 `region_x: i16`, 82 `region_y: i16`,
and 84 `reserved3: u32 = 0`. `decode` validates `reserved3 == 0`. Offsets
are pinned by comptime `@offsetOf` asserts.

**Checksum.** `simulationChecksum()` folds the resident `RegionCoord` into its
header under a bumped `checksum_format_tag`.

**Fixed caps.**

- `k_resident_regions = 1`;
- region coordinates are `i16`;
- `k_max_region_files = 4096`. Entering a new region beyond the cap is refused:
  the seam acts as a blocked edge, with one `warn`;
- the `RegionImage` encode buffer is a capacity sized from the region's
  content with Slice 46's `encodedSaveBytes` over the region-owned sections,
  reserved once per swap; `k_max_save_file_bytes` (64 MiB) is only Slice 46's
  loud safety ceiling (`RegionImageTooLarge` on encode; rejected before
  allocation on an untrusted read);
- `region_seam_hysteresis_cells = 1`: the player is placed one cell inside the
  incoming edge, so an immediate swap back needs a new crossing.

**Errors.**

- `RegionError = error{ RegionEntryBlocked, RegionFileCapExceeded,
  RegionImageCorrupt, RegionImageTooLarge }`, merged with Slice 46's
  `LoadError`.

### Checklist

- [ ] `RegionCoord`, `RegionWorldConfig` and its validation; `WorldGenKeying`.
      `noise.valueNoise2Global`, and global per-cell keys in
      `generate.zig`.
- [ ] Goldens for `.region_global` (three) and a seam-continuity test: the
      biome and edge tiles of both sides of a seam match a single-world
      generation of the same global cells.
- [ ] `RegionImage` encode/decode on Slice 46 sections (region-owned subset,
      including the 68C `pending_drops` entries), with strict validation and
      no partial apply.
- [ ] Seam detection: the edge-contact plus outward-held-input trigger, the
      corner rule, and the no-neighbour wall case. Tests: holding
      `move_right` with the clamped player touching the east edge requests
      exactly one `regionSwap` with `to = (rx+1, ry)` on that step; touching
      the edge without outward input, or holding outward one pixel short of
      `half_extent + 1 px`, requests none; at the `i16` limit the edge stays
      a wall.
- [ ] `LoadingState.regionSwap` steps 1–5, including the cancel path. Lane
      jobs plus inline fallback; generation through `WorldGenStream` when a
      lane thread exists.
- [ ] Session carry-over: `step_count`, seed, clock, the player and held
      items, `FactionRelations`, and the 64B hashed pipeline-history fields
      verbatim; `normalizeDerivedState` on the installed region.
- [ ] (added by Slice 64) Pin replay `ReplayInputFrame.flags` bit1 = `normalized_before_step`
      (`replay_flag_normalized: u8 = 2`; bits 2–7 stay 0; appending a flag
      bit needs no version bump by 49's pinned-bit rule). The region swap
      calls 64B's `normalizeDerivedState` and sets a
      `GameDemoState.normalize_pending` latch that Slice 51's capture writes
      as bit1 on the next recorded frame, then clears.
- [ ] (added by Slice 64) `replay.verify` calls a new stepper method `replayNormalize()` before
      a step whose bit1 is set; `HeadlessSession` (64C) and the Slice 49
      test adapter implement it through `normalizeDerivedState`. Tests: a
      recording across a region swap verifies `matched`, and the same
      recording with bit1 cleared reports `diverged`.
- [ ] Slice 46 slot header `region_x` / `region_y` at offsets 122 / 124 (with
      `@offsetOf` asserts and the zero-validated `[2]u8` tail) and the
      region-folder copy jobs; save `format_version` bump. Slice 49 header and
      checksum fold (`checksum_format_tag` bump). Replay seam split with the
      88-byte v5 header and `reserved3` validation.
- [ ] Caps and errors (the `RegionImage` buffer from `encodedSaveBytes`, and a
      pure `saveSizeBound` test at the game's `RegionWorldConfig` asserting at
      most half of `k_max_save_file_bytes`). Diagnostics: `info` per swap with the coordinates,
      `generated` or `loaded`, and duration via `loading_build`; `warn` on a
      cap or a blocked entry.
- [ ] Docs: `docs/architecture.md` (regions, residency, frozen-region rule).

### Acceptance checks

- [ ] Crossing a seam (triggered by held outward input at the clamped edge)
      and back restores the outgoing region byte-identically. The
      `simulationChecksum()` of the region state matches the pre-swap
      capture, and a held input latch carried across the swap produces no
      spurious edge on the far side.
- [ ] Generating region (1,0) fresh and generating it after visiting (0,0)
      gives the same hash. Generation is identical across thread counts.
- [ ] A depleted node in a region left for N steps is available on re-entry
      once `regrow_at_step` has passed.
- [ ] A blocked entry cell falls back through the ring search, or cancels
      cleanly with no partial install.
- [ ] Save, quit and load with 3 visited regions restores all of them.
- [ ] Bench: new group `region-swap` (encode + decode + generate one
      128×128×8 region): `zig build bench -- --group region-swap`.
- [ ] `zig build verify` passes.

