## Slice 46: Save/Load Persistence

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 49](slice-49.md), [Slice 51](slice-51.md), [Slice 53B](slice-53b.md), [Slice 54](slice-54.md), [Slice 64B](slice-64b.md), [Slice 64G](slice-64g.md), [Slice 74](slice-74.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Completes archive Slice 10's intent (`DataSystem` as
the save/load boundary).

Goal: save a running session and restore it after a restart so it continues
bit-identically: every world instance and all of its simulated state,
including far-simulation state, persisted as stable IDs and scalar/enum data,
never paths or live handles. Saves go to 8 manual slots with readable
metadata through Save/Load menus on 53B widgets; file I/O stays off the main
thread when the background lane has a thread; saving is invisible to the
continuing session and to replay.

### Current foundation

- `DataSystem` holds the SoA stores plus entity slots, generations, and the
  free-slot list (`data_system/system.zig`). `WorldSystem` owns terrain,
  levels, level links, and interest markers; terrain is per-level flat storage
  today and chunk-owned after 64G. `player.zig` owns the player;
  `manifest.zig` owns stable `SpriteAssetId` / `AudioAssetId`.
- `world_tileset_meta.zig` and `sprite_atlas_meta.zig` are the strict,
  versioned load-time validation pattern.
- No serializer exists. The AI archetype catalog (`ai_archetypes.zig`) has no
  content fingerprint.
- From prerequisites (not live yet): 49's seed root, `StepIndex` step count,
  checksum oracle, and completeness lists; 64B's v2 checksum, field classes,
  `normalizeDerivedState`, and `buildFingerprint()`; 54's `UserStorage`
  atomic write under the pref dir; 53B's widgets and confirm dialog; 51's lane
  `submit` / `isDone` / `complete` with an inline fallback.

### Architecture notes

- Owner direction: everything that exists keeps advancing in every world, so a
  save holds every world instance the session has and all of its simulated
  state. Cognition (73), world instances (74), and far-simulation state
  (75) land first and are included in v1; the format is organized per world
  instance.
- Payload: stable IDs, slot + generation, enum/scalar columns only
  (`.claude/rules/simulation.md` § Persistent data). Settings, input bindings,
  UI/theme, and render/audio/thread state are excluded (Slice 54 owns
  settings).
- The saved set is exactly 64B's hashed set plus the header, step count, and
  seed root. Derived state (the nav graph and all path state, caches, indices,
  any in-flight deferred nav work, environment snapshots) is rebuilt on load,
  never saved. Save capture never normalizes the live session; the load-parity
  reference is the uninterrupted run normalized at the save step (64B).
- Terrain saves per chunk, every chunk of every world (64G): save and load
  cost follow the chunks and content that exist, never level area or world
  extent (`.claude/rules/budgets-capacities.md`). Saving only edited chunks
  is 69F's later optimization. The render-only `BlockFill.changed` mark is
  excluded from chunk saves.
- Exact restore of dense-row order, entity slots, and free lists, because the
  checksum hashes them.
- Header layout and version policy: Table T3. The checksum is compared only
  when the build fingerprint matches; a content fingerprint over loaded
  catalogs rejects a mismatch (later catalog slices fold theirs in); a payload
  CRC catches corruption before decode. Validation is strict and nothing is
  installed until it and parity pass.
- No save-size ceiling: a save is never refused for size and only allocator
  OOM fails it, leaving the session intact (`.claude/rules/budgets-capacities.md`).
  The encode buffer is sized from content and reserved once before writing
  (`.claude/rules/memory-performance.md`); a load trusts no length field
  beyond the file's actual size and the format's index widths.
- Cold path, but it scales with content: encode runs at the paused quiescent
  point (no structural commands pending), with per-chunk and per-world work on
  the thread system and a deterministic ordered merge where the cost model
  calls for it (`.claude/rules/threading.md`). File write, read, decode, and
  slot scan run on the lane, observed with `isDone`, with the inline fallback;
  `Engine.deinit` completes outstanding tickets before the lane deinits.
- Capture goes through a state hook answered only by the gameplay state; menus
  decline. No gameplay conditionals in `Engine`
  (`.claude/rules/engine-design.md`).
- Provides: 67C's header-only bump, thumbnail, and named saves.
- VoidLight: port the slot API (save, load, delete, info, exists), a header
  with version and timestamp, and the pref-path save dir; do not port the
  player-only payload, non-atomic `ofstream` writes, string timestamps, or the
  singleton.

### Checklist

- [ ] Versioned writer over every world instance's `DataSystem` stores and
      `WorldSystem` state (per-chunk terrain, levels, links, markers), the
      player, step count, seed root, and 64B's pipeline history; stable IDs
      only.
- [ ] Strict reader: bad magic, unknown version, corrupt section, length
      mismatch, and out-of-range ID each rejected with nothing installed.
- [ ] `SaveSlotHeader` per Table T3, with layout and rejection tests.
- [ ] Build-gated checksum parity, payload CRC, and content fingerprint (adds
      the archetype catalog fingerprint); tests for a tampered section, a
      differing build fingerprint, and a differing content fingerprint.
- [ ] Post-load rebuild of every derived structure; exact-restore test (a store
      with free-slot reuse round-trips order, slots, and free list).
- [ ] Round-trip trace test: save at S, load, and 120 steps of 49's input
      script equal the reference run normalized at S, with a multi-chunk
      cave-in and a runtime ramp an NPC routes through before the save.
- [ ] Save invisibility: a session that saves at S keeps the same trace and
      derived-state counters as one that never saves; a replay recorded across
      a save verifies `matched` with no flag bits set.
- [ ] Save request → gameplay-state capture hook → Engine flow; menus decline.
- [ ] Lane jobs plus inline fallback for write, read and decode, and slot scan;
      `SaveStatus` publication; outstanding tickets completed before the lane
      deinits.
- [ ] `LoadingState` saved-game path; any failure returns to the main menu
      with nothing installed.
- [ ] `SaveLoadMenuState` on 53B: Save in the pause menu (overwrite confirm),
      Load in the main menu and the pause menu (unsaved-progress confirm); the
      save menu renders the game below it (67C needs it).
- [ ] Encode buffer: the computed size equals the bytes written, including an
      empty store; `FailingAllocator` after the reserve proves encode
      allocates nothing; a length disagreeing with the file is rejected before
      allocation.
- [ ] Payload-purity test: no handles, paths, settings, bindings, environment
      snapshots, or derived nav state.
- [ ] (added by Slice 64) `world_environment` section (game clock, per-level
      sky exposure), with round-trip, rejection, and same-environment-transition
      tests; lands with whichever of 46 and 59 lands second.
- [ ] (added by Slice 65B, once landed) A save with a deferred nav job in
      flight is invisible to the saving session, and the load equals the
      normalized reference; no lane, threadless lane, and threaded lane.
- [ ] `save-encode` / `save-decode` bench groups over content size (level
      size, depth, population, world count).
- [ ] Docs: `docs/architecture.md` save/load boundary (what is persisted, by
      which identifiers, what is excluded and rebuilt).
- [ ] Add the new-field save-section rule to `.claude/rules/simulation.md`
      when this lands.

### Acceptance checks

- [ ] Save then load reproduces an identical checksum, and the N-step trace
      parity test passes.
- [ ] Malformed or version-mismatched saves are rejected without mutating live
      state.
- [ ] Manual: save from the pause menu, quit, load from the main menu; the game
      resumes. The slot list shows timestamp, playtime, and level; a corrupt
      slot shows "Corrupt" and loading it returns cleanly to the main menu.
- [ ] Manual: with the lane thread enabled, saving does no file I/O on the main
      thread, and quitting during a save leaves a complete slot file.
- [ ] `save-encode` / `save-decode` grow linearly with saved content across at
      least three sizes (`.claude/rules/tests-benchmarks.md`), as does the
      post-load derived-state rebuild.
- [ ] Payload-purity test passes; `zig build verify` passes.
