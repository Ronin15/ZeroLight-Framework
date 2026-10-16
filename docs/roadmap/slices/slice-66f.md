## Slice 66F: Steamworks Runtime Integration

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 66D](slice-66d.md), the VoidLight port slices (owner 2026-10-16); per item: [Slice 64A](slice-64a.md) (overlay pause), [Slice 46](slice-46.md) and [Slice 54](slice-54.md) (cloud), [Slice 67C](slice-67c.md) (gamepad text input) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started. Gated on a Steamworks app ID existing**, as 66D is,
and lands after the VoidLight port slices (owner 2026-10-16). 66D uploads
builds; this slice is the runtime Steamworks API in the game.

Goal: an opt-in build links the Steamworks SDK and gives the game
achievements and stats, overlay-aware pause, cloud saves and settings, and
Steam Deck readiness; a build without it is unchanged.

### Current foundation

- No Steamworks API code, SDK, or `steam_appid.txt` exists (66D).
- SDL wrappers live in `src/platform/` and C headers come through
  `build.zig`'s TranslateC step (`sdl_c`); a compile-time no-op pattern
  exists (`debug_overlay_stub.zig`).
- SDL3 already exposes Steam Input's virtual controllers as gamepads.
- Saves are 46's; settings are 54's (app preferences, never save data).
- Pause that simulation cannot see is 64A's.

### Constraints

- Ownership and dependency direction: `.claude/rules/engine-design.md`
  § Ownership boundaries. The Steamworks SDK qualifies as a dependency only
  because neither stdlib nor SDL3 provides it.
- The SDK and its redistributable libraries are never committed
  (`.claude/rules/build-validation.md`); the build takes them from a local
  path, and packaging (52B, 66D) ships the redistributable beside the
  executable.
- Steam calls stay off workers (`.claude/rules/threading.md`).
- No Steam state feeds simulation (`.claude/rules/simulation.md`
  § Determinism); simulation emits, Steam receives.
- Shipping builds do no per-frame logging (`.claude/rules/zig-style.md`
  § Logging).

### Checklist

- [ ] Build: `-Dsteam` (default off) and an SDK path option. Off builds the
      no-op form and links nothing; on with an unsupported target or no SDK
      path fails the build loudly. The flat C API (`steam_api_flat.h`)
      comes through TranslateC.
- [ ] `src/platform/` wrapper over the flat API, plus an engine-owned
      `src/app/` service: init (with the release-build restart-through-Steam
      check), one manual callback pump per frame on the main thread outside
      the fixed step, and shutdown.
- [ ] Steam not running: the failure mode is an owner call (continue
      without Steam, or quit). Open question below.
- [ ] Achievements and stats: game code sends unlocks and stat updates
      through the service; they are queued and stored in batches, never
      per step. Unlocks can be tested against Valve's Spacewar app (480).
- [ ] Overlay: activation pauses through 64A's pause policy and resumes on
      close. Rendering is checked on Vulkan, D3D12, and Metal through SDL_GPU,
      with each OS reported separately (`gpu-smoke` where a display exists).
- [ ] Cloud: Steam Auto-Cloud covers 46's save directory and 54's settings
      file through Steamworks configuration, with no API code; the paths are
      documented, and a save written on one machine loads on another.
- [ ] Steam Deck: 1280×800 layout, controller-first menus, and the
      gamepad text keyboard for 67C's text widget.
- [ ] Rich presence: a status string from the active state.
- [ ] Docs: `docs/development-workflow.md` (the build option, SDK setup,
      dev `steam_appid.txt` kept out of git); `docs/architecture.md` (the
      service).

### Out of scope until confirmed

Workshop and mods (no mod loading exists), Steam networking and lobbies,
leaderboards, DLC and in-game purchases, and the Steam Input action-set API
(SDL3's gamepad layer covers controllers).

### Open questions (owner)

- If Steam isn't running when a Steam build starts, should the game keep
  going without Steam or quit?

### Acceptance checks

- [ ] `-Dsteam=false` builds, tests, and runs as before, and links no Steam
      symbols.
- [ ] `-Dsteam=true` on Windows, Linux, and macOS: init, an achievement
      unlock (app 480), overlay open and close with pause, clean shutdown.
- [ ] Auto-Cloud round trip of a save and the settings file.
- [ ] The Steam Deck checklist items pass on a Deck.
- [ ] `zig build verify` passes.
