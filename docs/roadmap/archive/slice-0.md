## Slice 0: Runtime Diagnostics Policy

Goal: use Zig's compile-time `std.log` filtering so debug builds can show useful
diagnostics while release builds stay quiet except for warnings and errors.

Current foundation:

- [x] Add `-Dlog-level=auto|err|warn|info|debug`.
- [x] Default `auto` to `debug` for Debug and `warn` for release modes.
- [x] Apply the policy through root `std_options` for the app, tests, and GPU smoke executable.
- [x] Add project log scopes for app, assets, core, game, render, platform, and debug overlay.
- [x] Use scoped logs for current render, platform, and debug-overlay diagnostics.
- [x] Keep routine startup facts such as the SDL_GPU driver at debug level.
- [x] Keep warnings for recovered degraded behavior and errors for real failure context.
- [x] Keep shader/config helper functions log-free where tests use pure logic.

Checklist:

- [x] Audit app, assets, game, core, render, and platform code for actionable diagnostics.
- [x] Add scoped logs only where they report startup facts, recovered degraded behavior, or real failure context.
- [x] Keep normal frame/update/render hot paths free of per-frame string formatting.
- [x] Keep pure helpers and validation helpers log-free unless they are runtime wrappers.
- [x] Keep release builds quiet by default while preserving warnings and errors.

Acceptance checks:

- [x] `zig build test` compiles the test root with the shared log policy.
- [x] `zig build check` compiles the app, GPU smoke, and benchmark executables.
- [x] `zig build check --release=safe` verifies the release log-level default.
- [x] Project-wide diagnostic audit confirms no meaningful subsystem still uses default-scope logging or noisy warning/error severity.

