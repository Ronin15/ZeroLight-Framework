## Slice 64C: Headless Replay Runner, Session Descriptor, And New Game Seed Flow

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 49](slice-49.md), [Slice 51](slice-51.md), [Slice 53B](slice-53b.md), [Slice 64B](slice-64b.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Depends on **49** (replay format, `verify`,
`SimulationSeed`), **51** (captured `.zlrp` files are the runner's main input;
the capture writes the header through `replaySession()`), **53B** (main menu
`UiScreen`, where "New Game" lives), and **64B** (`ChecksumReport`,
`nan_values`, `buildFingerprint()`). It owns the next
`replay_format_version` bump: live value + 1, which is **v2** in the merged
order (Slice 49 ships v1; 64C lands before 57B, which takes v3, and 63, which
takes v4; see Checklist additions (d)).

Goal:
- `zig build replay -- <file>` rebuilds the recorded session headlessly (no
  window, GPU, audio device, or Engine). It replays every frame through
  `replay.verify` and reports `matched`, the first divergent checkpoint, or a
  session/build mismatch, with an exit code for scripts and CI.
- The replay header carries everything needed to rebuild the session.
- Players start a New Game from a random seed root chosen once on the main
  thread. That root is recorded in the replay header (and in the save,
  Slice 46).

### Current foundation (do not rebuild)

- Session entry (live): `main_menu_state.zig:36-41` (items "Start Game",
  "Settings", "Quit"), `:145-170` (`activate` → `LoadingState.init(...,
  default_world_build_config, audio_settings)`); `loading_state.zig:186-215`
  `loadGameDemo` → `GameDemoState.initProceduralWithRuntimeAssets`
  (`game_demo_state.zig:323-353`), which always spawns
  `battle_scale_demo_mover_count = 2048` (`:85`) into
  `default_world_build_config` (`:198-206`: 256×256 tiles, chunk 16,
  31 underground levels, 1 dense band, `levels_below = 31`,
  `max_dense_tile_gpu_bytes = 64 MiB`).
- Slice 49 adds `session_seed: SimulationSeed` to that chain;
  `LoadingState.init` derives `world_build_config.seed =
  session_seed.derive(.worldgen_procedural)`; `MainMenuState` passes
  `SimulationSeed.default`. The header has 48 bytes ending in `reserved: u32`;
  `ReplaySession` holds `seed_root`, `start_step`, `fixed_delta_bits`, and
  `sim_view_width_bits`/`height_bits`; `verify(stepper, log)` uses the
  duck-typed stepper `replaySession`/`replayChecksum`/`replayResync`/
  `replayStep`.
- Headless prerequisites (live): `WorldSystem.initProcedural` and
  `GameDemoState.validateAtlasReferences` need only atlas **metadata**
  (`world_system.zig:432,446`, `render_prep.zig:180,205`); textures are
  render-only (`world_system.zig:897,1117`).
  - `RuntimeAssets.loadAtlasMetadata(asset_store, options: PreloadOptions)`
    is private (`runtime_assets.zig:151-172`) and **cannot** serve a
    headless host: it returns `error.RequiredStartupSpriteUnavailable`
    whenever a required startup sprite's texture is not `.available`, and
    `isRequiredStartupSprite` (`:310-315`) is true for `.world_tileset`, so
    with no textures it always fails.
  - The per-sprite loader it calls, `loadMetadataFor(asset_store, spec)`
    (`:175-190`), has no texture gate. Sprite slots default to
    `status = .not_loaded` (`SpriteSlot`, `:286-290`).
  - Tests seed metadata by hand (`loading_state.zig:575-596`). `AssetStore`
    resolves the installed asset root with an executable-directory fallback
    (`assets/assets.zig:40-70`).
- Test fixture rule (`docs/coding-standards.md:414-427`): a procedural entry
  point under `zig build test` uses at most 16×16 tiles and 1 underground
  level. The existing `LoadingState` fixture is 8×8 tiles, chunk 8, 0
  underground levels (`loading_state.zig:241-246`).
- `UpdateContext` (`state.zig:62-73`) is the full set of services a gameplay
  state reads. `Engine` (`engine.zig:42-63`) owns SDL, window, renderer, and
  audio, and builds `UpdateContext` per step.
- Build: `benchmark_runner.zig` is a top-level executable root built through
  `createSdlModule` (`build.zig:154-158`). Run steps use `addRunArtifact` +
  `addPassthruArgs` (`:225-234`). Build options are at `:104-111`; no
  `app_version` option exists yet (Slice 52B or 64B adds one).
- Zig 0.17 entropy: `std.Io.random(io, buffer)` (`lib/std/Io.zig:2660-2668`),
  documented as seeded by `randomSecure`, or by a less secure mechanism if
  that fails, and thread-safe. It is not a guaranteed CSPRNG, which is fine
  for a game seed root (unpredictability across sessions, not secrecy).

### Architecture notes

**C1. No Engine "headless mode" (decision).** A flag inside `Engine` would
put SDL/window/renderer/audio conditionals through `init`, `update`, `render`,
and `deinit` — the broad Engine conditionals the architecture forbids — and
the runner needs none of the state stack. Instead an app-layer host drives one
gameplay state through the same `UpdateContext` contract:

```zig
// src/app/headless_session.zig (new)
pub const HeadlessSessionConfig = struct {
    asset_root: []const u8,                // relative, validated like AppConfig.asset_root
    threading: ThreadSystemConfig = .{},
    // One owner for the literal: config.zig's AudioConfig default (32 today).
    audio_max_commands_per_step: u32 = (AudioConfig{}).max_commands_per_step,
};
pub const HeadlessSessionError = error{ UnexpectedStateTransition, UnsupportedSessionKind } || ...;
pub const HeadlessSession = struct {
    allocator: std.mem.Allocator,
    asset_store: AssetStore,
    runtime_assets: RuntimeAssets,       // metadata only
    thread_system: ThreadSystem,
    audio_commands: AudioCommandBuffer,  // cleared after every step, never played
    transitions: StateTransitions,       // must stay empty
    session_seeds: SessionSeedSource,    // .{ .io = io, .fixed_root = session.seed_root } (C5)
    game: *GameDemoState,                // heap-allocated, stable address
    pub fn init(allocator, io, config: HeadlessSessionConfig, session: ReplaySession) !HeadlessSession;
    pub fn deinit(self: *HeadlessSession) void;
    // replay.verify stepper protocol:
    pub fn replaySession(self: *const HeadlessSession) ReplaySession;
    pub fn replayChecksum(self: *HeadlessSession) u64;      // game.simulationChecksumReport(&thread_system).value
    pub fn replayResync(self: *HeadlessSession) void;       // game.onPause(); game.onResume();
    pub fn replayStep(self: *HeadlessSession, input: *const InputState) !void;
    pub fn lastReport(self: *const HeadlessSession) ChecksumReport;
};
```

- `init` steps:
  1. `fp_env.assertDefault("headless session")`.
  2. Validate `session.descriptor` (`UnsupportedSessionKind` for an unknown
     kind).
  3. Open `AssetStore`, then call the new
     `RuntimeAssets.loadMetadataOnly(asset_store) !void`. It iterates
     `manifest.sprite_assets`, skips specs with `metadata_kind == null`, and
     calls `loadMetadataFor(asset_store, spec)` directly for the rest. It
     deliberately bypasses `loadAtlasMetadata`'s required-texture gate
     (`runtime_assets.zig:151-172`), because headless has no textures by
     design. It sets every sprite slot's `status = .unavailable` (no
     texture will ever load in this host), so `sprite(id)` returns `null`
     for all IDs. A missing or malformed sidecar still fails `init` with
     `loadMetadataFor`'s error. `errdefer` frees any metadata already
     loaded (`deinitAtlasMetaSlots`).
  4. `ThreadSystem.init`, `AudioCommandBuffer.init` + `reserve`, and
     `StateTransitions.init`.
  5. `GameDemoState.initProceduralWithRuntimeAssets(allocator,
     &runtime_assets, asset_store, session.descriptor, &thread_system,
     viewport_w, viewport_h)`, where the viewport comes from the header's
     `sim_view_width_bits`/`height_bits` (the zoom-1 anchor size by Slice
     60's construction).
- `replayStep` builds an `UpdateContext` with `delta_seconds =
  @bitCast(session.fixed_delta_bits)`, `perf = .{}`, and `session_seeds =
  &self.session_seeds` (C5's required field; the fixed root makes it
  deterministic, and gameplay states never read it anyway), then calls
  `game.update`. Afterwards it clears `audio_commands`, and if `transitions`
  holds any request it returns `error.UnexpectedStateTransition` (a gameplay
  state never requests transitions on its own).
- `UpdateContext` construction goes through one private
  `updateContextFor(self, input) UpdateContext` that names every field
  explicitly (no field relies on a default). A comptime block in
  `headless_session.zig` walks `@typeInfo(UpdateContext).@"struct".fields`
  and fails compilation unless every field name is in the helper's
  `headless_update_context_fields` list, so a later `UpdateContext` field
  (Slice 51 `background_lane`, 67B `ui_theme`, …) cannot be
  missed by the headless host. The host passes `background_lane = null`:
  Slice 65B's deferred nav job then runs inline at its due step, which
  Slice 65B proves gives the same trace as any lane speed.
- `src/app` already imports `src/game` (`engine.zig:13-15`), so the
  dependency direction is unchanged.

**C2. `GameSessionDescriptor` (`src/game/game_session.zig`, new).**

```zig
pub const GameSessionKind = enum(u8) { procedural_demo = 1 }; // append-only; no placeholder tags
pub const GameSessionDescriptor = struct {
    kind: GameSessionKind = .procedural_demo,
    seed: SimulationSeed,
    world: WorldBuildConfig,    // .seed is overwritten with seed.derive(.worldgen_procedural)
    mover_count: u32,
    pub fn newGame(seed: SimulationSeed) GameSessionDescriptor; // default_world_build_config + 2048 movers
    pub fn validate(self: GameSessionDescriptor) error{InvalidGameSession}!void;
};
pub const max_session_mover_count: u32 = 2048; // == battle_scale_demo_mover_count (comptime assert)
```

- `validate` requires `chunk_size_tiles >= 1`, `width_tiles >=
  chunk_size_tiles`, `height_tiles >= chunk_size_tiles`, `1 <= mover_count
  <= max_session_mover_count`, and `world.seed ==
  seed.derive(.worldgen_procedural)`. There is no 32-tile floor: the existing
  8×8, chunk 8, 0-underground `LoadingState` test fixture
  (`loading_state.zig:241-246`) is a valid descriptor, and so is any fixture
  inside the 16×16 / 1-underground-level test cap. It is cold and runs at
  `LoadingState.init` and `HeadlessSession.init`.
- Plumbing:
  - `initProceduralWithRuntimeAssets` replaces its `world_build_config` and
    Slice 49 `session_seed` parameters with `descriptor:
    GameSessionDescriptor`;
  - `battle_scale_demo_mover_count` becomes `descriptor.mover_count`;
  - `GameDemoState` stores `session: GameSessionDescriptor` (cold) for
    `replaySession()`;
  - `LoadingState.init(..., descriptor, audio_settings)` replaces Slice 49's
    `(world_build_config, session_seed)` pair. Slice 49's
    "incoming `world_build_config.seed` must be the default" assert becomes
    `descriptor.validate()`.

**C3. Replay header extension (`replay_format_version` = live value + 1; v2
in the merged order).**
`header_bytes = 80`. Bytes 0–43 are unchanged from Slice 49. Bytes 44–47
(`reserved` in 49) become `build_fingerprint`, and a 32-byte session block
is appended:

| Offset | Field | Type / value |
| --- | --- | --- |
| 44 | `build_fingerprint` | `u32`, `simulation_checksum.buildFingerprint()` (64B) |
| 48 | `session_kind` | `u8` (`GameSessionKind`) |
| 49 | `reserved0` | `u8`, 0 |
| 50 | `width_tiles` | `u16` |
| 52 | `height_tiles` | `u16` |
| 54 | `chunk_size_tiles` | `u16` |
| 56 | `underground_level_count` | `u16` |
| 58 | `max_dense_bands_per_level` | `u8` |
| 59 | `render_ceiling_when_underground` | `u8`, 0/1 |
| 60 | `render_levels_below` | `u16` |
| 62 | `reserved1` | `u16`, 0 |
| 64 | `mover_count` | `u32` |
| 68 | `max_dense_tile_gpu_bytes` | `u64` |
| 76 | `reserved2` | `u32`, 0 |

- The world seed is not stored: it is `seed_root` derived through
  `.worldgen_procedural`. Fields are little-endian and written one at a time
  (49's rule).
- `decode` validates: the zero reserved fields, the 0/1 byte, a known
  `session_kind`, and the descriptor passing `validate()`
  (`InvalidReplayHeader`, a new `ReplayDecodeError` tag).
- `ReplaySession` gains `descriptor: GameSessionDescriptor` and
  `build_fingerprint: u32`. Session equality in `verify` compares every
  field **except** `build_fingerprint`.
- `build_fingerprint` comes from Slice 64B's `buildFingerprint()` (single
  owner, beside `checksum_format_tag`); this slice only writes and reads it.
- **Header completeness guard.** The session block hand-lists today's
  complete `WorldBuildConfig` (`world_system.zig:137-148`) and
  `DenseLayerRenderWindow` (`:99-107`) coverage. So that a later field (for
  example a Slice 58 spec ID or biome config) cannot be silently dropped,
  making `matched` meaningless, `replay.zig` carries a comptime block that
  walks `@typeInfo` of `WorldBuildConfig`, `DenseLayerRenderWindow`, and
  `GameSessionDescriptor` and fails compilation unless every
  `Type.field` name is in the header encoder's `encoded_session_fields`
  list or in the explicit `derived_header_fields` list. Today
  `derived_header_fields` is exactly `WorldBuildConfig.seed` (derived from
  `seed_root` through `.worldgen_procedural`);
  `GameSessionDescriptor.seed` is encoded as Slice 49's `seed_root`,
  `GameSessionDescriptor.world` and `WorldBuildConfig.render_window` are
  listed as encoded through their own walked types. Adding a field to any of the three types therefore requires
  encoding it and a `replay_format_version` bump (live value + 1) in the
  same change, the same pattern as 64B's B3 classification.

**C4. Runner executable and CLI.**

- `src/replay_runner.zig` (new top-level root, like
  `benchmark_runner.zig`), built with `createSdlModule` (game modules
  reference SDL types; the runner never calls `SDL_Init`).
- `build.zig`:
  - `replay_exe` (name `zl-replay`) is added to `check_step`;
  - `const replay_run = b.addRunArtifact(replay_exe);
    replay_run.addPassthruArgs();
    replay_run.step.dependOn(b.getInstallStep());` (installed assets)
    plus `addWindowsSdlRunRuntime`;
  - `b.step("replay", "Verify a recorded replay headlessly")`.
  - No cwd override: relative replay paths resolve against the invoking
    directory, and assets resolve through `AssetStore`'s executable-dir
    fallback.
- CLI: `zl-replay <file> [--threads N] [--fixed-range N] [--stop-step S]
  [--trace]`.
  - `--threads N`: `ThreadSystemConfig.max_worker_threads = N`; `0` runs
    serially.
  - `--fixed-range N`: `adaptive = false`, `items_per_range = N` (Slice 49's
    `ThreadSystemConfig.adaptive`).
  - `--stop-step S`: replay frames only up to step S (crash bisection),
    reported as `stopped`.
  - `--trace`: print every checkpoint comparison.
  - Unknown flags or a missing file print usage; exit 64.
- Flow:
  1. Read the file (cold; `std.Io.Dir.cwd().readFileAlloc` with limit
     `replay_max_file_bytes = 8 MiB` ≥ the 6.9 MB frame bound plus
     checkpoints and headers).
  2. `decode`.
  3. `HeadlessSession.init`. The host builds sessions from the header only
     (New Game sessions). A recording captured by a session that was
     restored from a Slice 46 save has `start_step > 0` and an initial state
     that lives in the save file, so `verify` returns `session_mismatch`
     (exit 2) for it by design; loaded-session determinism is proven by
     Slice 46's in-process round-trip trace tests, not by this runner.
  4. If `log.session.build_fingerprint != buildFingerprint()`, print
     `build mismatch: checkpoints skipped` and replay inputs only (crash
     repro), comparing nothing.
  5. Otherwise run `replay.verify`. After each checkpoint the runner reads
     `lastReport().nan_values`; a nonzero count ends the run as
     `non_finite_state`.
- Output: one stdout result line, plus a summary with steps replayed,
  wall time, and steps/s. It is written through a buffered
  `std.Io.File.stdout()` writer (tool output, not logging). Lifecycle and
  failure context go through `logging.app`.
- Exit codes: 0 `matched` (or `stopped`); 1 `diverged` (prints step,
  expected, actual); 2 `session_mismatch` or `initial_state_mismatch`;
  3 decode/IO/build error; 4 `non_finite_state`; 5 build mismatch
  (inputs replayed without error).

**C5. New Game seed flow.**

```zig
// src/app/session_seed.zig (new)
pub const SessionSeedSource = struct {
    io: std.Io,
    fixed_root: ?u64 = null,
    /// Called once per new session, on the main thread. Never called by simulation code.
    pub fn newSessionRoot(self: *const SessionSeedSource) u64 {
        if (self.fixed_root) |root| return root;
        var bytes: [8]u8 = undefined;
        self.io.random(&bytes);
        return std.mem.readInt(u64, &bytes, .little);
    }
};
```

- `AppConfig.fixed_session_seed: ?u64 = null`, fed by the build option
  `-Dsession-seed=<u64>` (unset → random) through `main.zig`. It exists for
  reproducible dev sessions and bug repro, so it never ships a fixed root:
  when `-Dsession-seed` is set with a non-Debug optimize mode, `build.zig`
  fails configuration with `std.debug.panic("-Dsession-seed is a Debug-only
  development option; remove it for {t} builds", .{optimize})`, the same
  configure-time rejection style as `-Dlog-level` (`build.zig:758`). The
  `package` step additionally depends on `b.addFail("package never bakes
  -Dsession-seed")` when the option is set, like the `fetch-sdl` guards
  (`build.zig:124-129`).
- `Engine` owns `session_seeds: SessionSeedSource` (from
  `process_init.io` + config). `UpdateContext` gains `session_seeds:
  *const SessionSeedSource`.
- Main menu (53B `UiScreen`): the first button becomes `new_game` (label
  "New Game"). On its `activated` event in `MainMenuState.update`:
  1. `root = context.session_seeds.newSessionRoot()`;
  2. `logging.game.info("new game session seed root=0x{x:0>16}", .{root})`;
  3. `LoadingState.init(..., GameSessionDescriptor.newGame(.init(root)),
     ...)`.
- The root reaches the replay header through `replaySession()` (Slice 51
  capture) and the save header `seed_root` (Slice 46). Simulation code never
  reads the seed source: `SimulationSeed` stays the only path into the sim.
- `SimulationSeed.default` remains the seed for tests, benches, and
  `initWithRuntimeAssets`.

### Checklist

- [ ] **C2.** `game_session.zig` with `validate` and `newGame`, and the
      `initProceduralWithRuntimeAssets`/`LoadingState`/`GameDemoState.session`
      plumbing. Tests:
  - [ ] every `validate` rejection (`chunk_size_tiles = 0`, `width_tiles <
        chunk_size_tiles`, `height_tiles < chunk_size_tiles`, `mover_count`
        0 and 2049, mismatched `world.seed`);
  - [ ] the existing 8×8 / chunk 8 / 0-underground `LoadingState` fixture
        and a 16×16 / chunk 8 / 1-underground fixture both pass `validate`;
  - [ ] `newGame` matches `default_world_build_config` + 2048 movers with
        the derived world seed;
  - [ ] Slice 49's loading tests pass with the descriptor (unchanged
        fixture sizes).
- [ ] **C3.** Header (`replay_format_version` live + 1): encoder, decoder,
      `ReplaySession` fields, the `encoded_session_fields` /
      `derived_header_fields` comptime completeness block. Tests:
  - [ ] encode→decode round trip of every session-block field;
  - [ ] nonzero `reserved0`/`reserved1`/`reserved2` → `InvalidReplayHeader`;
  - [ ] `render_ceiling_when_underground = 2` → `InvalidReplayHeader`;
  - [ ] unknown `session_kind` → `InvalidReplayHeader`;
  - [ ] `header_bytes = 48` → `TruncatedReplay`;
  - [ ] `verify` ignores `build_fingerprint` when comparing sessions;
  - [ ] the encoder writes 64B's `buildFingerprint()` at offset 44.
- [ ] **C1.** `headless_session.zig` + `RuntimeAssets.loadMetadataOnly` +
      the `UpdateContext` field-completeness comptime block. Tests in
      `headless_session.zig` (tiny descriptor inside the coding-standards
      fixture cap: 16×16 tiles, chunk 8, `underground_level_count = 1`,
      `mover_count = 8`, seed `default_root`):
  - [ ] `test "headless session replays a recorded run to a match"`: session
        A records 120 steps of Slice 49's input script (pause boundary at
        step 100) with `ReplayRecorder`, encodes it, and decodes it; session B
        (3 workers, `--fixed-range 16` equivalent) verifies →
        `.matched{ .steps = 120 }`, `nan_values == 0`;
  - [ ] `test "headless session reports a divergent checkpoint"`: one flipped
        held bit at step 70 → `.diverged` at step 120;
  - [ ] `test "headless session refuses state transitions"`: a test-local
        stepper wrapper queues a transition on the session's `transitions`
        before `replayStep` returns → `error.UnexpectedStateTransition`;
  - [ ] `loadMetadataOnly` with no textures loaded: `world_tileset` (a
        required startup sprite, which `loadAtlasMetadata` would refuse)
        and `grim_characters` metadata load (`worldTilesetMeta() != null`,
        `atlasMetaLoaded(.grim_characters)`),
        `spriteStatus(.world_tileset) == .unavailable`, and
        `sprite(.world_tileset) == null`. It uses the same
        `AssetStore.init(std.testing.allocator, std.testing.io, "assets")`
        root as `loading_state.zig:578`, with a `std.testing.allocator` leak
        check.
- [ ] **C4.** `replay_runner.zig`, the `zl-replay` exe, and the `replay`
      step. CLI parsing is a pure `parseArgs([]const []const u8)
      ParseError!RunnerOptions`, tested for every flag, defaults, unknown
      flag, and missing file. Exit-code mapping is a pure
      `exitCodeFor(outcome) u8`, tested for every outcome.
- [ ] **C5.** `SessionSeedSource`, `AppConfig.fixed_session_seed`,
      `-Dsession-seed`, Engine ownership, `UpdateContext.session_seeds`, and
      the 53B main menu `new_game` button. Tests:
  - [ ] `fixed_root = 0x1234` returns it on every call;
  - [ ] two random draws from `std.testing.io` differ;
  - [ ] `build.zig` rejection: `zig build -Doptimize=ReleaseFast
        -Dsession-seed=1` fails configuration with the Debug-only message,
        and `zig build package -Dsession-seed=1` fails (recorded in Status
        as a manual configure check, since build-script failures are not
        unit-testable);
  - [ ] main menu activation with a fixed source builds a `LoadingState`
        whose descriptor has `seed.root == 0x1234` and `world.seed ==
        SimulationSeed.init(0x1234).derive(.worldgen_procedural)`;
  - [ ] keyboard and gamepad activation tests are ported to the `new_game`
        widget.
- [ ] **Docs.**
  - `docs/development-workflow.md` "## Replay runner": the command, flags,
    exit codes, the build-fingerprint rule, and the cross-machine verification
    procedure. Also `-Dsession-seed`.
  - `docs/architecture.md`: `HeadlessSession` in App (why it is not an Engine
    mode); session seed ownership.
  - Determinism Contract: the header descriptor and the New Game root.
  - `CLAUDE.md` command list: `zig build replay`.

### Acceptance checks

- [ ] `zig build verify` passes. `zig build check` compiles `zl-replay`.
- [ ] Every Checklist test passes in Debug and ReleaseSafe.
- [ ] Manual: with Slice 51 capture enabled, play 2 minutes in a ReleaseSafe
      build with one pause/resume. Then `zig build -Doptimize=ReleaseSafe
      replay -- <capture>` exits 0 (`matched`) at default threads and with
      `--threads 0`. Record steps/s in Status.
- [ ] Cross-machine: a capture recorded on x86_64 Linux (ReleaseSafe,
      `ship`) verifies `matched` on Apple Silicon (ReleaseSafe) and on
      Windows x86_64, from the same commit and toolchain. This is either
      manual or the 52C macOS job running the runner on an artifact capture.
      Recorded in Status; until then this check stays `[ ]`.
- [ ] Manual: New Game twice gives two different seed roots in the log; with
      `-Dsession-seed=0x1234` both are `0x1234`, and the procedural layout is
      identical.

---

