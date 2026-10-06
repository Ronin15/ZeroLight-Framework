## Slice 46: Save/Load Persistence

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 49](slice-49.md), [Slice 51](slice-51.md), [Slice 53B](slice-53b.md), [Slice 54](slice-54.md), [Slice 64B](slice-64b.md), [Slice 64E](slice-64e.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Completes the design intent from archive **Slice
10** (`DataSystem` as the save/load streaming boundary). Depends on Slice 49
(`SimulationSeed`, `simulationChecksum()`, completeness lists), Slice 51
(background lane; inline fallback when threadless), Slice 53B (widgets,
`ConfirmDialogState`), and Slice 54 (`UserStorage`: pref dir + atomic
write). Independent of Slice 44: settings and input bindings belong to
Slice 54 and are never in a save. Every later slice that adds a
`DataSystem`/`WorldSystem` field classifies it in Slice 49's completeness
lists and adds its save section here in the same change. The merged order
also places it after **Slice 64B** (it saves exactly 64B's hashed set and
writes 64B's `buildFingerprint()`) and **Slice 64E** (load-time link-slot
validation); when **Slice 65B** has landed, its mid-job trace test is part of
this slice.

Goal: serialize and restore a running simulation to/from disk so gameplay state
survives a restart, reconstructing a **byte-identical** simulation — persisting
only stable IDs and enum/scalar columns, never paths or live handles. Saves go
into one of `k_save_slot_count = 8` manual slots with readable metadata, through
a Save/Load menu on 53B widgets, and file I/O never blocks the main thread when
the background lane has a thread.

### Current foundation (do not rebuild)

- `DataSystem` holds default-initialized SoA stores (`movement_bodies`,
  `facings`, `asset_refs`, `collision_*`, `ai_agents`, `steering_agents`,
  `world_levels`, `factions`, `ai_perceptions`, `ai_memories`, `ai_affects`,
  `destructibles`, …) plus entity slots + generations.
- `WorldSystem` owns tile / level storage; `player.zig` owns player state;
  `core/rng.zig` owns deterministic per-entity RNG; `RuntimeAssets` /
  `manifest.zig` own stable `SpriteAssetId` / `AudioAssetId`.
- The atlas / tileset metadata loaders (`world_tileset_meta.zig`,
  `sprite_atlas_meta.zig`) are the pattern for strict, versioned, load-time
  validation.
- Slice 49's `SimulationSeed` (persisted as `seed_root` = `SimulationSeed.root`),
  `GameDemoState.simulationChecksum()`, `checksum_format_tag`, and the
  `DataSystem`/`WorldSystem` checksum completeness lists. The checksum is a
  Wyhash same-binary oracle (Slice 49): it may change across Zig releases or
  checksum-format changes, so a save never treats it as a cross-version
  identifier.
- Slice 54's `UserStorage.readFile` / `writeFileAtomic` (temp + fsync +
  rename).
- Slice 53B's `UiScreen` / `ConfirmDialogState`, and `src/app/state.zig`'s
  `TransitionApplyResult` request pattern (`quit_requested`;
  `resume_requested` from 53B).
- Slice 51's background lane through `submit` / `isDone` / `complete`, never
  `background_handoff`. Saves run while paused, where due steps do not
  advance, and loads run in `LoadingState`; both are app-layer consumers,
  which is the only use Slice 51 allows for `isDone`.

### Architecture notes

- Serialize by **stable asset IDs, entity slot + generation, and enum/scalar
  columns** — never file paths, live SDL/GPU/mixer handles, or prepared draw
  records (CLAUDE.md hard rule). This is what makes `DataSystem` the correct
  boundary rather than the renderer or asset layer.
- Versioned container: header (magic + format version) and per-store
  length-prefixed sections; strict validation on load (reject unknown version,
  out-of-range IDs, length mismatch) with **no partial apply** on failure —
  mirror the atlas-metadata loader discipline.
- Round-trip must reproduce an identical simulation checksum: persist enough sim
  state (step counter, RNG state, deferred-command-free quiescent snapshot point)
  that `save → load` yields byte-for-byte parity.
- Serialization is a **cold-path** operation (explicit save/load, not per-frame),
  so normal allocator use is fine — this is not a hot-path allocation-free
  constraint — but it must round-trip every persistent store and the world tile
  grid, not a subset.
- **Excluded from saves:** `RuntimeSettings`, input bindings, theme/UI state,
  and render/audio/thread state. The payload-purity test asserts the file
  holds only:
  - the slot header
  - every field classified *hashed* by Slice 49's `DataSystem`/`WorldSystem`
    completeness lists (the sim stores, world tiles/levels, and the fields
    later slices add there, such as 58 `chunk_biomes`, 59 `clock`, 62
    `spawn_anchors`, and 63 `faction_relations`)
  - the player
  - the step counter (`SimulationScopeSystem.step_count`)
  - the seed root
- **Exact restore.** Restore every store's dense-row order, entity slots, and
  free-slot list exactly. Slice 49 hashes dense order, so a load that
  compacts or reorders rows fails parity.
- **Seed and checksum parity.** The header stores `seed_root` (Slice 49
  `SimulationSeed.root`), `build_fingerprint: u32`, and `sim_checksum: u64`
  computed at the quiescent capture point. `build_fingerprint` is
  `simulation_checksum.buildFingerprint()` (Slice 64B is the single owner; it
  covers the zon `.version` string, `builtin.zig_version_string`, and the
  live `checksum_format_tag`), never a second Crc32 here.
  - On load, when `build_fingerprint` matches the running build,
    `simulationChecksum()` is recomputed on the rebuilt, not-yet-installed
    `GameDemoState`, and a mismatch fails the load (`SaveChecksumMismatch`);
    nothing is installed.
  - When it differs, parity is skipped (one `debug` log) and the load relies
    on the payload CRC32 plus strict section validation.
  - Separately, a `std.hash.Crc32` over the section bytes catches corruption
    before any decode.
- **Content fingerprint.** The header stores `content_fingerprint: u64`, a
  fold of the content catalog fingerprints present in the build. At landing
  that is the AI archetype catalog (`src/game/ai_archetypes.zig`, Slice 33),
  which has no fingerprint today, so this slice adds a `fingerprint()` that
  Crc32-hashes its archetype ids and tuning values. Each later catalog slice
  folds its own in when it
  lands (57 `ItemCatalog.fingerprint()` plus loot tables, 61 node kinds, 62
  spawn tables, 63 merchant profiles). A mismatch rejects the load with
  `SaveContentMismatch`, because stable IDs would otherwise resolve against
  different content.
- **Post-load rebuild.** Derived state is rebuilt from the restored data,
  never saved: the nav graph, perception caches, and the steering static
  snapshot, plus each later slice's derived structures as it lands (61
  `ResourceNodeIndex`, 59 `EnvironmentController.resync(world)`, 63
  `stance_cache`).
- **Slots and metadata.**
  - Files are `saves/slot_{0..7}.zlsave` under the pref dir.
  - Each starts with a fixed 128-byte little-endian `SaveSlotHeader` (extern
    struct):

    | Field | Type / notes |
    | --- | --- |
    | `magic` | "ZLSV" |
    | `format_version` | u16 |
    | `header_bytes` | u16 |
    | `saved_unix_ms` | i64; `SDL_GetCurrentTime`, stamped by Engine |
    | `playtime_steps` | u64; the persisted `step_count` (`StepIndex`, Slice 49), stored directly (it counts unpaused fixed steps), not a second counter |
    | `seed_root` | u64; Slice 49 `SimulationSeed.root` |
    | `build_fingerprint` | u32; `buildFingerprint()` (Slice 64B owner) |
    | `sim_checksum` | u64; Slice 49 `simulationChecksum()`, compared on same build only |
    | `content_fingerprint` | u64; catalog fingerprint fold |
    | `payload_bytes` | u64 |
    | `payload_crc32` | u32 |
    | `player_level` | u16 |
    | `world_width`, `world_height`, `world_levels` | u16 each |
    | reserved | zero, and validated as zero |

  - **No thumbnail in v1.** Slice 67C adds a header-only `format_version`
    bump (thumbnail section and slot name) and replaces the save-mode
    overwrite confirm with `SaveNameDialogState`.
  - Offsets are pinned by comptime asserts; the authoritative byte layout
    (including the explicit `reserved_pad0` at 36 and the later 67C/69F
    fields) is Table T3 in the
    [VoidLight port track](../tracks/voidlight-port.md#t3-save-file).
- **Capture hook.**
  - New `StateTransitions.saveGame(slot)` sets
    `TransitionApplyResult.save_slot: ?SaveSlot`.
  - Engine then calls `StateStack.captureSave(&capture)`, which targets the
    unique `gameplay`-flag state (same walk as `pauseRecipient`,
    `state.zig:457-466`).
  - `State.VTable` gains a required `capture_save: *const fn (*anyopaque,
    *SaveCapture) anyerror!bool`. Menus return `false`. No `@hasDecl` gating
    (`docs/coding-standards.md:48-51`).
- **Encoding.**
  - Runs on the main thread at the paused quiescent point. Save is offered
    only from the pause menu, so no update is in flight and no structural
    commands are pending.
  - Writes into an Engine-owned buffer. Cold path.
  - Hard cap `k_max_save_file_bytes = 64 MiB`: a fixed constant, independent
    of world size; a save over it is refused with `error.SaveTooLarge`.
  - Measured by `zig build bench -- --group save-encode` (and
    `save-decode`).
- **Streaming on the Slice 51 lane.**
  - **Save:** the immutable encoded buffer plus the slot name go to a
    background-lane job (`submit`) that runs `writeFileAtomic`. Engine owns
    the ticket, checks `isDone(ticket)` once per frame on the app layer, then
    `complete`s it and publishes `SaveStatus { idle, saving, saved, failed }`
    through `RenderContext`/`UpdateContext.saves: *const SaveStatus`. Buffer
    ownership returns to Engine at `complete`.
  - **Load:** `LoadingState` gains `LoadTarget.saved_game: SaveSlot`. A lane
    job reads the file, checks the CRC, validates the header and sections, and
    decodes into a staged `SaveImage`. `LoadingState` checks `isDone` each
    frame and then `complete`s the ticket. On success, the main thread runs
    `GameDemoState.initFromSave`, applies the build-gated checksum parity
    above, and only then calls `replaceOwnedGameplay`. Any failure moves to
    `.failed` and then back to the main menu.
  - **Slot scan:** reading the eight 128-byte headers is a lane job too,
    observed the same way.
  - **Fallback:** when the lane has no thread
    (`BackgroundLaneConfig.thread_enabled = false` or `builtin.single_threaded`;
    tests), `complete` runs the same job inline.
  - **Shutdown:** Engine `complete`s any outstanding save/load/scan ticket in
    `Engine.deinit` **before** `background_lane.deinit` (Slice 51 lifetime
    rule), so quitting during a write finishes the atomic write instead of
    dropping it.
- **Menus.** `SaveLoadMenuState` (modal; mode `save` or `load`) is a 53B
  scroll of 8 slot buttons plus Back. It needs no `list` widget, since the
  slot count is known at comptime. Button text looks like "Slot 3 — Level 4 —
  2026-10-05 14:03 — 1:23:45", or "Empty", "Incompatible version", "Corrupt".
  - **Save Game** is in the pause menu; overwriting asks for confirmation.
  - **Requirement (added by Slice 67):** the pause state and save-mode
    `SaveLoadMenuState` use `render_below = true` policies, so
    `GameDemoState` renders under the save menu (Slice 67C thumbnail capture
    depends on it).
  - **Load Game** is in the main menu, and in the pause menu with a "Unsaved
    progress will be lost" confirm.
- **Errors.** Explicit sets:
  - `SaveError = error{ SaveTooLarge, PersistenceUnavailable }` merged with
    the named `std.Io` write errors
  - `LoadError = error{ SaveBadMagic, SaveVersionUnsupported, SaveCorrupt,
    SaveSectionLengthMismatch, SaveOutOfRangeId, SaveChecksumMismatch,
    SaveContentMismatch, SaveTooLarge }`

### Checklist

- [ ] Versioned save writer over `DataSystem` stores + `WorldSystem` tiles/levels
      + player + sim step / RNG state; stable-ID mapping (no paths/handles).
- [ ] Strict-validation reader; corrupt / unknown-version / out-of-range
      rejection tests with no partial apply.
- [ ] Round-trip determinism test: `save → load → checksum-equal` against a
      hand-built fixture world.
- [ ] Settings and bindings are excluded: no settings or input sections exist,
      and the payload-purity test asserts their absence.
- [ ] `SaveSlotHeader`, with tests: layout is 128 bytes; bad magic, a future
      version, nonzero reserved bytes, and a payload length mismatch are each
      rejected.
- [ ] `saveGame` request → `captureSave` hook → Engine flow, with tests
      (menus return `false`; only the gameplay-flag state is asked).
- [ ] Lane jobs plus inline fallback for write, read+decode, and slot scan
      through `submit`/`isDone`/`complete`, with tests on the inline path.
      `SaveStatus` publication. A test that `Engine.deinit` completes an
      outstanding save ticket before the lane deinits.
- [ ] `LoadingState.saved_game` path, plus tests: a tampered section with a
      valid CRC fails cleanly with `SaveChecksumMismatch` and installs
      nothing on the same build; a differing `build_fingerprint` skips parity
      and loads through CRC + validation; a differing `content_fingerprint`
      fails with `SaveContentMismatch`.
- [ ] `content_fingerprint` fold + archetype-catalog `fingerprint()`, with a
      test that changing one archetype value changes the fingerprint.
- [ ] Round-trip trace test (Slice 49 rule): save at step S, load, run
      N = 120 steps with the Slice 49 determinism input script, and require
      the per-step `simulationChecksum()` trace to equal the uninterrupted
      run's steps S+1…S+120. Once Slice 64B has landed, the reference is the
      uninterrupted run with `normalizeDerivedState` called at S (64B B5; see
      the Slice 64 additions below).
- [ ] Exact-restore test: a store with free-slot reuse round-trips its dense
      order, entity slots, and free list unchanged.
- [ ] `SaveLoadMenuState` + Save/Load items in the main and pause menus +
      confirm flows. `playtime_steps` from the persisted `step_count`.
- [ ] Bench groups `save-encode` and `save-decode` (one group per workload,
      `suite.zig` convention) on a mid-size fixture.
- [ ] Docs: `docs/architecture.md` records the save/load boundary contract
      (what is persisted, by which stable identifiers, and what is deliberately
      excluded).

**Added by Slice 64 — `WorldSystem.clock.game_ms` and `level_sky_exposed`** (lands with
whichever of 46 and 59 lands second):

- [ ] Save section `"world_environment"` (format: `game_ms: u64`, then
      `level_count: u32`, then `level_count` bytes of `level_sky_exposed`,
      each 0 or 1). It is written after the world tile sections. Adding it
      is a payload change, so the slice that lands second bumps the save
      `format_version` to the live value + 1 (Slice 59's bump, v6 in the
      merged order) and older files are rejected with
      `SaveVersionUnsupported` per Slice 46's version policy.
  - On load, `level_count` must equal the restored `level_base_z.len`, else
    `SaveSectionLengthMismatch`. Any other byte value fails with
    `SaveCorrupt`. Nothing is installed in either case.
  - The section is restored into `WorldSystem.clock` and
    `level_sky_exposed` **before** `GameDemoState.initFromSave` builds the
    pipeline, so `EnvironmentController.init(config, env_seed,
    world.clock.game_ms)` sees the saved clock. After the rebuild,
    `EnvironmentController.resync(world)` runs.
  - The `EnvironmentController` `previous`/`current` snapshots are never
    saved (derived from `(env_seed, game_ms)`).
- [ ] Test `"save round-trips the game clock and sky exposure"`:
  - set `clock.game_ms = 3 * 86_400_000 + 63_900_000` (day 3, 17:45);
  - build a level stack with surface `true` and two underground levels
    `false` (`addLevel(0)` + `addUndergroundLevelStack(&meta, 2)` on the
    minimal 1×1-chunk fixture);
  - save, load, and assert equal `game_ms`, equal `level_sky_exposed`, and
    equal `simulationChecksum()`.
- [ ] Test `"loaded clock emits the same environment transitions"`: save at
      the step before a day-phase boundary (`game_ms` = sunrise − 60 min −
      1 step for the current season). Run 2 steps after load and in the
      reference run that calls `normalizeDerivedState` at the save point
      (64B's load-parity reference). Both runs emit one
      `environment_transition.day_phase_changed` at the same step, and the
      2-step checksum traces are equal.
- [ ] Tests: a `"world_environment"` length mismatch and a sky byte of `2`
      are rejected with nothing installed. The payload-purity test asserts
      that no `EnvironmentController` snapshot bytes appear.

**Added by Slice 64 — pipeline history, normalized saved image, link-slot validation,
and build fingerprint** (from 64B/64C/64E):

- [ ] Save section `"pipeline_history"`: every field 64B classifies
      `checksum_hashed_fields`, restored verbatim. That covers
      `interact_held_last`, the `SensoryBus` live deferred/sticky entries
      with their counts and remaining linger, the `DigController` latches +
      `player_last_cell`, `AiSystem.snapped_goal`/`snapped_goal_initialized`,
      and `SteeringSystem.runtime_rows` in list order, plus later slices'
      hashed latches. A `runtime_rows` entity that is not alive after restore
      → `SaveOutOfRangeId`.
- [ ] **Normalized saved image; the live session is untouched** (64B B5
      decision). `SaveCapture` encodes the hashed and persistent state only.
      It never writes a `normalized`-class field (`PathfindingSystem`
      lifecycle, caches, group fields, dirty marks, nav graph, 65B deferred
      job) and never calls `normalizeDerivedState` on the live session, so
      no cache is cleared, no deferred job is abandoned, and no nav rebuild
      runs at save time. On load, the freshly initialized pipeline is the
      normalized image (64B's B5 contract). No replay flag is set: a save is
      not a simulation event.
- [ ] Test `"saving is invisible to the continuing session"`: run A pauses
      and runs `SaveCapture` at step 40 (with one cached path, one pending
      request, one building group field, and, once 65B has landed, one
      deferred nav job in flight); run B never saves. Their 120-step
      per-step `simulationChecksum()` traces are equal, and A's
      `PathfindingSystem` lifecycle counters, `nav_version`, and (with 65B)
      swap step equal B's.
- [ ] Test `"save trace parity across a runtime ramp"` (after 64E): dig a
      ramp (runtime `LevelLink`, routable since 64E) at step 10 so an
      underground NPC is mid-corridor through it, save at step 40, and
      load. The reference run is the uninterrupted session with
      `normalizeDerivedState` called at step 40 (64B's load-parity
      reference). The 120-step post-load trace equals the reference's. The
      un-normalized continuing session is **not** the oracle: its warm
      caches legitimately diverge from a load (64B B5 stated effect).
- [ ] Test: a replay recorded across a save (capture spanning the paused
      `SaveCapture`) verifies `matched` with no flag bits set, which proves
      the save is invisible to replay as well.
- [ ] **Load-time link-slot validation (64E).** After `world_meta` restores
      `level_links`, the loader checks every link endpoint with
      `nav_graph.interiorLinkSlotsAvailable` over the links before it, using
      the session's nav geometry; a violation (impossible from a save made
      by this build, because `DigController` refuses it) fails the load with
      `SaveCorrupt`, nothing installed. Test: a hand-built payload whose 9th
      link exceeds one 8-tile nav chunk's interior slots is rejected.
- [ ] `SaveSlotHeader.build_fingerprint` is
      `simulation_checksum.buildFingerprint()` (64B single owner), not a
      second Crc32.

**Added by Slice 65B:**

- [ ] (65B) Round-trip trace test, mid-job variant: with `nav_deferred_patch_min_changed_chunks = 1`, dig a multi-tile batch at S−5 and another at S−2 (held by the fence), then save at S with the job in flight. (1) Invisibility: the saving session's per-step `simulationChecksum()` trace for S+1…S+120 and its swap step (S−5+30) equal a run that never saved. (2) Load parity: the reference run (the uninterrupted session with 64B's `normalizeDerivedState` called at S, which abandons the job and rebuilds) and the loaded session have equal traces for S+1…S+120, and neither swaps after S. Run with no lane, a thread-less lane, and a threaded lane.

### Acceptance checks

- [ ] Save then load reproduces an identical simulation checksum on a fixture
      world.
- [ ] Malformed / version-mismatched saves reject loudly without partially
      mutating live state.
- [ ] Save from the pause menu → quit → Load from the main menu restores the
      game (manual). The N-step trace parity test passes.
- [ ] The slot list shows timestamp, playtime, and level. A corrupt slot shows
      "Corrupt", and loading it falls back cleanly to the main menu.
- [ ] Manual check: with the lane thread enabled, saving a large world causes
      no frame-time spike from file I/O (ReleaseSafe perf log), and quitting
      during a save leaves a complete slot file.
- [ ] Serialized form contains no handles or filesystem paths (payload-purity
      inspection/test); `zig build verify` passes.
- [ ] (added by Slice 64) Record the post-load `rebuildStaticNavGridWithWorld` time
      on the 256×256×32 production world in Status (the only nav rebuild a
      save/load cycle performs).

### VoidLight reference

- **Port:**
  - `include/managers/SaveGameManager.hpp:18-30` — header with version and
    timestamp.
  - `:68-101` — the slot API (save, load, delete, slot info, exists).
  - VL `src/core/GameEngine.cpp:590-599` — pref-path save directory.
- **Do not port:**
  - the player-only payload
  - non-atomic `std::ofstream` writes (`src/managers/SaveGameManager.cpp:77`)
  - the `test_write.tmp` writability probe (`:421-424`)
  - string timestamps
  - the singleton

