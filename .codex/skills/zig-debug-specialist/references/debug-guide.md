# Zig Game Engine Debug Guide

## Failure Categories

Classify first:

- Build configuration: `build.zig`, `build.zig.zon`, module roots, build options, install steps.
- Zig compile: type errors, imports, visibility, error sets, comptime, API drift.
- Link/system dependency: SDL3, SDL3_ttf, SDL3_mixer, pkg-config, system headers, library paths.
- Shader toolchain: `glslc`, `spirv-cross`, GLSL source, SPIR-V/MSL output, installed shader paths.
- Tests: behavior contract failure, stale test expectation, missing aggregate test import.
- Runtime app: SDL init, window creation, asset resolution, renderer init, pause/frame pacing.
- GPU/display: device creation, swapchain acquisition, present mode, driver, headless environment.

Do not treat an environmental display failure as proof of renderer logic failure without supporting evidence.

## Evidence To Gather

- Exact command and full first error block.
- Current `zig version` if build API behavior is suspicious.
- Relevant build step definition if a command fails before source compilation.
- SDL error call site when a runtime SDL function returns null or false.
- Asset root and resolved path when an asset cannot load.
- Window flags and swapchain frame result when frame pacing or pause behavior is wrong.

## Narrow Commands

- Compile-only: `zig build check`
- Unit behavior: `zig build test`
- Shader-only: `zig build shaders`
- Full non-interactive local validation: `zig build verify`
- Runtime app: `zig build dev`
- Display-gated renderer/GPU path: `zig build gpu-smoke`

If a sandbox or cache path blocks Zig from writing caches, separate that infrastructure problem from compiler output before changing source.

## Debugging Patterns

For import errors, check module roots and whether an aggregate test root should import the file. Avoid solving nested test-root problems by moving unrelated code.

For SDL type mismatches, look for duplicated `@cImport` blocks. A shared SDL import module should provide one C namespace to the rest of the engine.

For missing shader or asset files, verify install steps before changing runtime lookup. The app may be correct while generated assets were never installed.

For frame pacing issues, distinguish visible, occluded/unfocused, hidden, minimized, and no-swapchain frames. Visible rendering should remain swapchain/vsync paced; non-renderable frames can use fallback delay and pause policy.

For input bugs, separate raw SDL events, action mapping, held gameplay state, one-frame commands, router policy, and state-stack dispatch. Clear held movement when a modal policy begins blocking gameplay input.

For GPU smoke failures, record whether the build installed shaders/assets, SDL
created a window, the renderer loaded the platform shader pipeline, SDL created
and claimed the GPU device, the smoke path drew a primitive, acquired the
swapchain texture, encoded a pass, and submitted. Each step points to a
different class of issue.

When a fix improves a runtime boundary, add or preserve scoped `std.log` diagnostics that would make the same class of failure easier to identify next time. Use `debug` for low-frequency lifecycle/config/fallback context, `warn` only for recovered degraded behavior, and `err` only for real failure context. Keep pure helpers and validation helpers log-free unless they are runtime wrappers with useful call-site context.
