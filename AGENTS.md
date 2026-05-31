# Repository Guidelines

## Project Structure & Module Organization

This is a Zig SDL3 template. The build entry point is `build.zig`, with package metadata in `build.zig.zon`.

- `src/main.zig` contains the executable entry point and SDL3 window/render loop.
- `src/root.zig` is the reusable package module with library helpers and tests.
- `assets/` contains runtime assets and is installed to `zig-out/bin/assets`.
- `zig-out/` is generated build output and should not be edited by hand.
- Add modules under `src/`; keep executable-only code near `main.zig` and reusable logic in modules imported by `root.zig`.

## Build, Test, and Development Commands

- `zig build` builds the executable and installs it to `zig-out/bin/my-sdl3-game`.
- `zig build run` builds, installs runtime assets/shaders, and runs the SDL3 example window.
- `zig build dev` builds shaders, installs assets, and runs the app.
- `zig build test` runs reusable module tests plus SDL-linked compile coverage.
- `zig build check` compiles the game and GPU smoke executable without installing.
- `zig build verify` runs check, tests, and shader compilation.
- `zig build package` installs selected-mode game binaries and runtime assets.
- `zig build shaders` compiles platform GPU shaders.
- `zig build gpu-smoke` runs a display-gated SDL_GPU frame submission check.
- `zig build fmt` formats `build.zig`, `build.zig.zon`, and `src/`.

Default optimize mode is `ReleaseSafe`; override with `zig build --release=fast` or `zig build -Doptimize=ReleaseFast` when needed. SDL3 is a system dependency; install the platform SDL3 development package before building. Shader tools are required for the default runnable build.

## Coding Style & Naming Conventions

Follow `zig fmt`; use 4-space indentation and avoid manual alignment that the formatter will rewrite. Use Zig-style lowerCamelCase for variables and functions, `PascalCase` for types, and short, descriptive names. Keep error sets explicit when practical, as in `error{SdlError}`.

Prefer small functions with clear ownership of SDL resources. Pair SDL creation calls with `defer` cleanup close to the creation site.

For frame-loop policy, use SDL window flags as current state: throttle visible background windows, but only skip rendering or force pause for hidden, minimized, or no-swapchain frames.

Keep scalable game boundaries explicit: map raw input to named actions, keep latched frame commands separate from held gameplay input, keep debug state in debug UI, and let stack policies decide whether lower states receive update, input, or render passes.

## Testing Guidelines

Use Zig's built-in `test` blocks and `std.testing`. Name tests by behavior, for example `test "player movement clamps to window bounds"`. Put reusable module tests beside the code they cover. Run `zig build test` before submitting changes.

## Commit & Pull Request Guidelines

This checkout does not include Git history, so no repository-specific commit convention is established. Use concise, imperative commit messages such as `Add SDL input handling` or `Fix renderer cleanup`.

Pull requests should include a short description, testing performed, and any platform details relevant to SDL3 linking or runtime behavior. For visual changes, include a screenshot or short recording of the SDL window when useful.

## Security & Configuration Tips

Do not commit generated binaries from `zig-out/` or local machine paths. If adding dependencies to `build.zig.zon`, keep hashes accurate and review changes to the package fingerprint carefully because it affects package identity.
