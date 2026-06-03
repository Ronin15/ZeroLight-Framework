# Zig SDL3 GPU 2D Game Framework

A Zig 0.16.0 + SDL3 starter framework for SDL_GPU-first 2D games.

The project uses SDL3 for windowing, input, image loading, and GPU rendering. It
builds target-native shaders at build time and renders through SDL_GPU.

## Features

- SDL3 window and event loop
- SDL_GPU renderer with Metal shaders on macOS and SPIR-V shaders on Linux
- Batched sprite and rectangle drawing
- Fixed 60Hz update loop with interpolation
- Vsync-driven rendering with 60Hz background throttling
- Text rendering for UI and debug overlays
- Policy-based state stack for gameplay, menus, tools, and overlays
- Pause state for player-controlled and non-renderable window pauses
- Keyboard action mapping with held gameplay input and latched frame commands
- Runtime asset loading from the installed `assets/` directory
- GPU smoke executable for checking SDL_GPU device creation

## Requirements

- Zig 0.16.0 or newer compatible 0.16.x build
- SDL3 development headers and library discoverable by the compiler/linker
- SDL3_ttf development headers and library discoverable by the compiler/linker
- `glslc` for shader compilation during the default build/run/package flow
- `spirv-cross` for macOS Metal shader generation

Platform package notes:

- macOS/Homebrew: install `sdl3`, `sdl3_ttf`, `shaderc`, and `spirv-cross`.
  SDL_GPU should select Metal when the build provides MSL shaders.
- Linux/Arch: install `sdl3`, `sdl3_ttf`, `shaderc`, `vulkan-headers`,
  `vulkan-loader`, and a working Vulkan GPU driver. SDL_GPU should select
  Vulkan when the build provides SPIR-V shaders.

Other Linux distributions use different package names, but the required pieces
are SDL3 and SDL3_ttf development files, `glslc`, the Vulkan loader/headers,
and a vendor Mesa or proprietary Vulkan driver.

## Quick Start

Clone the repository and build the example:

```sh
git clone git@github.com:Ronin15/Zig_SDL3_GPU_FrameWork.git
cd Zig_SDL3_GPU_FrameWork
zig build
```

Run the example window:

```sh
zig build run
```

For the normal edit/run loop, use:

```sh
zig build dev
```

`zig build dev` compiles shaders, installs assets, builds the executable, and
runs the app.

## Commands

```sh
zig build           # build and install a runnable app into zig-out/bin
zig build run       # build, install assets/shaders, and run the app
zig build dev       # build shaders, install assets, and run the app
zig build check     # compile the game and GPU smoke executable
zig build test      # run Zig unit tests
zig build verify    # run check, test, and shader compilation
zig build package   # install selected-mode binaries and runtime assets
```

Useful supporting commands:

```sh
zig build fmt       # format build.zig, build.zig.zon, and src/
zig build shaders   # compile GLSL shader sources to platform GPU shaders
zig build gpu-smoke # create an SDL_GPU device and submit one frame
```

`zig build package` installs the selected-mode game binary and runtime assets.
It does not install the `gpu-smoke` development executable. Pass
`--release=fast`, `--release=safe`, `--release=small`, or
`-Doptimize=ReleaseFast` explicitly when producing a release candidate or
shipping build.

`zig build gpu-smoke` opens a small window long enough to submit a frame. SDL
still needs a usable video backend and display environment, so headless shells or
CI runners may need platform setup before this check can run.

The default optimize mode is `Debug`, matching standard Zig build behavior.
Use an explicit release mode only when preparing a release candidate or shipping
build:

```sh
zig build
zig build --release=safe
zig build --release=fast
zig build -Doptimize=ReleaseFast
```

Customize app metadata at build time:

```sh
zig build -Dapp-name=my-game -Dwindow-title="My Game"
```

Disable the debug overlay feature when you do not want debug UI in a build.

```sh
zig build -Ddebug-overlay=false
```

The default runtime asset directory is `assets`. If you pass
`-Dasset-root=content`, generated shaders and copied runtime assets are installed
under `zig-out/bin/content`, and the executable looks there at runtime.

Use a non-default shader compiler path:

```sh
zig build shaders -Dshader-compiler=/path/to/glslc
zig build shaders -Dshader-cross-compiler=/path/to/spirv-cross
```

## Project Layout

- `build.zig` defines executables, tests, formatting, shader compilation, and
  install steps.
- `build.zig.zon` contains package metadata.
- `src/main.zig` owns the executable entry point and high-level fixed-step timing loop.
- `src/app/` owns app coordination, input, timing, frame pacing, pause policy,
  and the owned state stack.
- `src/render/` owns SDL_GPU rendering, camera transforms, the FPS counter, and
  debug overlay rendering.
- `src/game/` contains game/application states such as the temporary demo and
  pause overlay.
- `src/platform/` contains SDL startup/shared C imports and platform helper
  implementations.
- `src/assets/` resolves runtime asset paths and loads installed files.
- `src/core/` contains small reusable helpers such as math primitives.
- `src/config.zig` centralizes app/window/GPU configuration.
- `src/gpu_smoke.zig` is the executable wrapper for the platform smoke test.
- `src/tests.zig` imports modules for aggregate unit-test coverage.
- `src/root.zig` is the minimal package root for shared starter helpers and tests.
- `assets/` contains runtime assets and shader sources.

Generated build output goes under `zig-out/` and should not be committed.

## Rendering Notes

The app uses SDL_GPU directly and does not call Vulkan APIs itself.

- Shader sources live in `assets/shaders/*.glsl`.
- `zig build shaders` compiles GLSL to platform-native runtime shader files.
- On macOS, `glslc` emits temporary SPIR-V and `spirv-cross` converts it to
  installed MSL files under `zig-out/bin/assets/shaders/*.msl`.
- On Linux, `glslc` emits installed SPIR-V files under
  `zig-out/bin/assets/shaders/*.spv`.
- `src/render/renderer.zig` tells SDL which shader formats the app built, passes a
  null driver name so SDL chooses the backend, then loads the shader files that
  match `SDL_GetGPUShaderFormats()`.
- SDL should select Metal on macOS when MSL shaders are available and Vulkan on
  Linux when SPIR-V shaders are available.
- Game code should draw through `Renderer` instead of calling SDL_GPU directly.
- The installed runtime asset tree excludes shader source files and build-only
  shader formats; package source assets separately if your game needs them.
- PNG texture loading uses core SDL3 `SDL_LoadPNG`/`SDL_LoadSurface` support;
  this project does not require `SDL3_image`.

Sprites and colored rectangles are collected into a CPU batch, uploaded to one
GPU vertex buffer per frame, and submitted by texture/layer groups.

The visible render loop is paced by SDL_GPU swapchain acquisition with the
default vsync present mode. Simulation remains fixed at 60Hz through
`TimeLoop`, while rendering may follow higher refresh displays and interpolate
between fixed updates. Hidden, minimized, or swapchain-unavailable frames skip
GPU rendering, use `SDL_DelayNS` for a 60Hz fallback cadence, and enter the
pause controller so gameplay cannot advance while the player cannot see it.
Occluded or unfocused visible windows keep rendering but apply the same 60Hz cap
to avoid background render runaway. Press P during active play to toggle pause;
after a forced pause, press P, Enter, or Space once the window is visible again.

Press F2 to toggle the yellow FPS overlay. It reports render-loop cadence, not
the fixed update tick rate.

## Testing

Tests follow Zig conventions: small unit tests live beside the code they cover
in `src/*.zig` as `test` blocks. Run them with:

```sh
zig build test
```

Use behavior-focused test names, for example:

```zig
test "player movement clamps to window bounds" {
    // ...
}
```

## Adding A State

Create a struct with this shape and push or replace it through `StateStack`:

```zig
pub fn handleEvent(self: *MyState, event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
    _ = self;
    _ = event;
    _ = transitions;
    return false;
}

pub fn update(self: *MyState, input: *const InputState, delta_seconds: f32, transitions: *StateTransitions) !void {
    _ = self;
    _ = input;
    _ = delta_seconds;
    _ = transitions;
}

pub fn render(self: *MyState, renderer: *Renderer, alpha: f32) !void {
    _ = self;
    _ = renderer;
    _ = alpha;
}

pub fn onPause(self: *MyState) void {
    _ = self;
}

pub fn deinit(self: *MyState) void {
    _ = self;
}
```

Return `true` from `handleEvent` when the state consumes an event. Use
`try states.pushModal(MyState, MyState.init(...))` for blocking menus,
`try states.pushOverlay(...)` for pass-through overlays, and
`try states.replaceGameplay(...)` for full state changes.

`StateStack` owns state allocation and destruction. It returns handles for
targeted removal, calls `deinit` when states are removed or replaced, and
destroys any remaining states when the stack shuts down. States can request
changes through `StateTransitions`; queued transitions are applied after the
current event or update dispatch completes.

## Input Model

Keyboard input maps to named `Action` values in `src/app/input.zig`. Gameplay code
reads held actions through `InputState`, while app-level commands such as pause,
resume, quit, and debug overlay toggle are latched for one frame through
`FrameCommands`.

The default bindings are WASD for movement, P for pause, Enter or Space for
resume, Escape for quit, and F2 for the debug overlay.

## Starting Your Game

This repository is intended to be cloned and edited into a game:

- Rename or replace `src/game/demo_state.zig`, then update the startup-state
  bootstrap in `src/app/engine.zig`. A real game will usually replace the demo
  with a `MainMenuState` that transitions into gameplay.
- Set your default app name and window title in `build.zig`, or pass
  `-Dapp-name=... -Dwindow-title=...` while iterating.
- Put reusable gameplay modules under `src/` and keep SDL/GPU ownership in
  `engine.zig` and `renderer.zig` unless you have a reason to split it further.
- When a clone becomes a distinct project, rename it and regenerate the
  `build.zig.zon` fingerprint.

## Adding Art

The starter demo draws primitives so it has no required PNG asset. Put PNGs
under `assets/`, then load them through the renderer after it is initialized:

```zig
const texture = try renderer.createTextureFromPng(assets, "sprites/player.png");
```

Draw using `drawSprite`:

```zig
try renderer.drawSprite(.{
    .texture = texture,
    .dest = .{ .x = 100, .y = 120, .w = 32, .h = 32 },
    .layer = 0,
});
```

Use `drawRect` for debug or simple primitive rendering. It goes through the same
sprite batch via a built-in white texture.

## Adding A Shader

Add GLSL source under `assets/shaders/`, extend `addShaderSteps` in `build.zig`,
and load the resulting platform shader file from `src/render/renderer.zig`.

Keep shader resource bindings aligned with SDL_GPU's layout rules:

- vertex uniform buffers: set 1
- fragment sampled textures/samplers: set 2
- fragment uniform buffers: set 3

The build converts those SPIR-V bindings to SDL-compatible MSL resource
bindings for macOS through `spirv-cross`.

## License

This project is licensed under the MIT License. See `LICENSE` for details.
