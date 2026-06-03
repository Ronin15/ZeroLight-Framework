# Clone And Edit

This repository is intended to be cloned and edited into a game.

## Replace The Demo

The startup state is created in `src/app/engine.zig`:

```zig
fn bootstrapStartupState(states: *StateStack, app_config: config.AppConfig) !void {
    _ = try states.replaceGameplay(DemoState, DemoState.init(
        @floatFromInt(app_config.logical_width),
        @floatFromInt(app_config.logical_height),
    ));
}
```

Replace `DemoState` with your first real state. A typical game starts with a
`MainMenuState` that transitions into gameplay.

## Rename The App

Set default app identity in `build.zig`, or override it while iterating:

```sh
zig build -Dapp-name=my-game -Dwindow-title="My Game"
```

The default executable name is `my-sdl3-game`, and the default window title is
`SDL3 Zig Game`.

## Add Gameplay Code

Put reusable gameplay modules under the matching `src/` area. Keep SDL window
and GPU coordination code in `src/app/` and `src/render/`, and keep game-specific state
under `src/game/`.

The current demo renders a movable primitive player, so there is no required PNG
asset to replace before the app runs.

## Package Identity

When a clone becomes a distinct project, update `build.zig.zon`:

- Rename `.name`.
- Set the starter version you want.
- Regenerate `.fingerprint`.
- Keep `.minimum_zig_version` accurate.
- Add dependencies only when the game needs them.

The package fingerprint has security and trust implications, so regenerate it
intentionally when publishing a renamed clone.
