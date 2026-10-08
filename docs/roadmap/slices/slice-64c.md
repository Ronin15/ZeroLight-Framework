## Slice 64C: Headless Replay Runner, Session Descriptor, And New Game Seed Flow

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 49](slice-49.md), [Slice 51](slice-51.md), [Slice 53B](slice-53b.md), [Slice 64A](slice-64a.md), [Slice 64B](slice-64b.md), [Slice 74](slice-74.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Owns the next `replay_format_version` (live + 1, v2
in the merged order; Table T1). Lands before 57B, which takes the following
version.

Goal: `zig build replay -- <file>` rebuilds a recorded session headlessly (no
window, GPU, audio device, or `Engine`), replays every frame through 49's
`verify`, and reports `matched`, the first divergent checkpoint, a session or
build mismatch, or non-finite state, with an exit code for scripts and CI.
The replay header carries every creation input needed to rebuild the session
(its initial worlds and content); worlds created later in play are rebuilt by
replaying the inputs, never stored. Players start a New Game from a random
seed root chosen once on the main thread and recorded in the replay header
and the save.

### Current foundation

- Session entry: `MainMenuState` ("Start Game", "Settings", "Quit") →
  `LoadingState.init(..., default_world_build_config, ...)` → `loadGameDemo` →
  `GameDemoState.initProceduralWithRuntimeAssets`, which always spawns
  `battle_scale_demo_mover_count` into `default_world_build_config`. Those are
  demo-harness values, never format, validation, or sizing inputs
  (`.claude/rules/engine-design.md` § Target scale).
- 49 adds the session seed to that chain and the replay v1 header, whose
  session holds the seed root, start step, fixed delta, and sim-view size,
  ending in a reserved `u32`; `verify` drives a duck-typed stepper.
- Headless prerequisites: world building and atlas-reference validation need
  only atlas metadata; textures are render-only.
  `RuntimeAssets.loadAtlasMetadata` (private) fails whenever a required
  startup sprite (`world_tileset`) has no texture, so it cannot serve a
  headless host; the per-sprite `loadMetadataFor` has no texture gate. Tests
  seed metadata by hand (`loading_state.zig`).
- `UpdateContext` (`src/app/state.zig`) is the full service set a gameplay
  state reads; `Engine` owns SDL, window, renderer, and audio and builds it
  per step.
- `benchmark_runner.zig` is the top-level executable-root pattern; no
  `app_version` build option exists yet (52B or 64B adds it).
- Zig 0.17 `std.Io.random` provides seeding entropy (not guaranteed CSPRNG,
  which is fine for an unpredictable game seed).

### Architecture notes

- Headless host (decision): an app-layer `HeadlessSession` drives one gameplay
  state through the same `UpdateContext` contract, with metadata-only assets,
  its own `ThreadSystem`, a never-played audio buffer, and no lane (deferred
  lane work runs inline, which lane slices prove trace-equal). Rejected: an
  `Engine` headless mode, which would spread SDL/window/renderer/audio
  conditionals through `Engine` (`.claude/rules/engine-design.md`). A comptime
  check fails the build when a new `UpdateContext` field is not supplied by the
  host. A gameplay state requesting a transition is an error. It asserts the
  FP environment at init (64A).
- Session descriptor (`src/game/`): the kind, seed, and every creation input
  of the session's initial worlds and content (world build configs,
  population content), validated only against the format's field widths and
  internal consistency (the world seed derives from the root), never against
  demo sizes; the New Game descriptor is today's demo content. A comptime
  completeness check fails the build when a descriptor or world-config field is
  neither encoded nor listed as derived, so a later field cannot silently
  make `matched` meaningless; encoding one bumps the version.
- Header: carries the descriptor and `buildFingerprint()` (64B, single owner);
  decode validates reserved fields, enums, and the descriptor. Session
  equality ignores the build fingerprint; a mismatched fingerprint replays
  inputs only (crash repro) and compares nothing.
- Runner (`zl-replay`, `zig build replay`): reads the file with a refusal bound
  derived from the format's frame and chunk sizes (never a literal; a slice
  that grows a frame updates it with its version bump); flags for worker
  count, pinned range size, stop step (bisection), and per-checkpoint trace;
  distinct exit codes for matched/stopped, diverged, session mismatch,
  decode/IO error, non-finite state, and build mismatch. A recording that
  starts from a loaded save cannot be rebuilt from the header and reports a
  session mismatch by design; loaded-session determinism is 46's round-trip
  trace test.
- New Game seed: an app-owned seed source draws the root once per new session
  on the main thread; simulation code never reads it (the root reaches the
  sim only as `SimulationSeed`). `-Dsession-seed` fixes the root for Debug dev
  and repro only; any other optimize mode and `package` refuse it at
  configure. Tests, benches, and the default constructor keep the default
  root.

### Checklist

- [ ] Session descriptor with validation and `newGame`, plumbed through
      `LoadingState` and `GameDemoState`; tests for each rejection, existing
      small fixtures validating, and 49's loading tests passing unchanged.
- [ ] Replay header (live + 1): descriptor and build-fingerprint encode/decode,
      session fields, and the comptime completeness check; tests for round
      trip, nonzero reserved fields, bad enum or flag bytes, unknown kind,
      truncated header, fingerprint ignored by session equality, fingerprint
      written from 64B.
- [ ] `HeadlessSession`, a metadata-only asset loader, and the `UpdateContext`
      completeness check; tests: a recorded 120-step run with a pause boundary
      replays to a match on a multi-worker pinned host with zero NaN; a flipped
      input bit reports the right divergent checkpoint; a requested transition
      errors; metadata-only loading leaves sprites unavailable with no leak.
- [ ] `zl-replay` executable and `replay` step with pure, tested argument
      parsing and exit-code mapping, and a test that the file bound covers a
      minimum-chunk capture.
- [ ] Seed source, `AppConfig` fixed root, `-Dsession-seed` with its
      configure-time refusals, `Engine` ownership, the `UpdateContext` field,
      and the 53B "New Game" button; tests for a fixed root, distinct random
      draws, and a menu activation producing the expected descriptor, plus
      keyboard and gamepad activation.
- [ ] Docs: DW "Replay runner" (command, flags, exit codes, fingerprint rule,
      cross-machine procedure, `-Dsession-seed`); `docs/architecture.md`
      (`HeadlessSession` and why it is not an `Engine` mode; seed ownership);
      Determinism Contract (descriptor, New Game root); `CLAUDE.md` command.

### Acceptance checks

- [ ] `zig build verify` passes and `zig build check` compiles `zl-replay`.
- [ ] Every Checklist test passes in Debug and ReleaseSafe.
- [ ] Manual: with 51's capture on, two minutes of ReleaseSafe play with one
      pause replays `matched` at default threads and with `--threads 0`;
      steps/s noted in the landing commit.
- [ ] Cross-machine: a capture recorded on x86_64 Linux (ReleaseSafe, `ship`)
      verifies `matched` on Apple Silicon and on Windows x86_64 from the same
      commit and toolchain (manual or 52C's macOS job).
- [ ] Manual: two New Games log different roots; with `-Dsession-seed` both
      use it and generate the same world.
