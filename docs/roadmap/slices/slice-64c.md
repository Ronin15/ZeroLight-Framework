## Slice 64C: Session Descriptor And New Game Seed Flow

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 49](slice-49.md), [Slice 53B](slice-53b.md), [Slice 74](slice-74.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** The headless replay runner and replay header were
dropped with replay (owner decision 2026-10-14).

Goal: a session starts from a descriptor holding its seed root and the
creation inputs of its initial worlds and content. Players start a New Game
from a random seed root chosen once on the main thread and stored in the
save.

### Current foundation

- Session entry: `MainMenuState` ("Start Game", "Settings", "Quit") →
  `LoadingState.init(..., default_world_build_config, ...)` → `loadGameDemo` →
  `GameDemoState.initProceduralWithRuntimeAssets`, which always spawns
  `battle_scale_demo_mover_count` into `default_world_build_config`. Those are
  demo-harness values, never format, validation, or sizing inputs
  (`.claude/rules/engine-design.md` § Target scale).
- 49 adds the session seed to that chain.
- Zig 0.17 `std.Io.random` provides seeding entropy (not guaranteed CSPRNG,
  which is fine for an unpredictable game seed).

### Architecture notes

- Session descriptor (`src/game/`): the kind, seed, and every creation input
  of the session's initial worlds and content (world build configs,
  population content), validated only against field widths and internal
  consistency (the world seed derives from the root), never against demo
  sizes; the New Game descriptor is today's demo content.
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
- [ ] Seed source, `AppConfig` fixed root, `-Dsession-seed` with its
      configure-time refusals, `Engine` ownership, the `UpdateContext` field,
      and the 53B "New Game" button; tests for a fixed root, distinct random
      draws, and a menu activation producing the expected descriptor, plus
      keyboard and gamepad activation.
- [ ] Docs: DW `-Dsession-seed`; `docs/architecture.md` seed ownership;
      Determinism Contract (descriptor, New Game root).

### Acceptance checks

- [ ] `zig build verify` passes.
- [ ] Every Checklist test passes in Debug and ReleaseSafe.
- [ ] Manual: two New Games log different roots; with `-Dsession-seed` both
      use it and generate the same world.
