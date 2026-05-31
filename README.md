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
- Optional F2-toggle debug FPS overlay rendered with SDL_ttf
- Policy-based state stack for gameplay, menus, tools, and overlays
- Pause state for player-controlled and non-renderable window pauses
- Keyboard action mapping with held gameplay input and latched frame commands
- Runtime asset loading from the installed `assets/` directory
- GPU smoke executable for checking SDL_GPU device creation

## Requirements

- Zig 0.16.0 or newer compatible 0.16.x build
- SDL3 development headers and library discoverable by the compiler/linker
- SDL3_ttf development headers and library when the debug overlay is enabled
- `glslc` for shader compilation during the default build/run/package flow
- `spirv-cross` for macOS Metal shader generation

Platform package notes:

- macOS/Homebrew: install `sdl3`, `sdl3_ttf`, `shaderc`, and `spirv-cross`.
  SDL_GPU should select Metal when the build provides MSL shaders.
- Linux/Arch: install `sdl3`, `sdl3_ttf`, `shaderc`, `vulkan-headers`,
  `vulkan-loader`, and a working Vulkan GPU driver. SDL_GPU should select
  Vulkan when the build provides SPIR-V shaders.

Other Linux distributions use different package names, but the required pieces
are SDL3 development files, optional SDL3_ttf development files, `glslc`, the
Vulkan loader/headers, and a vendor Mesa or proprietary Vulkan driver.

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
zig build fmt       # format build.zig and src/
zig build shaders   # compile GLSL shader sources to platform GPU shaders
zig build gpu-smoke # create an SDL_GPU device and submit one frame
```

`zig build package` installs the selected-mode game binary and runtime assets.
It does not install the `gpu-smoke` development executable. Pass
`--release=fast`, `--release=safe`, `--release=small`, or
`-Doptimize=ReleaseFast` explicitly when producing a release candidate.

`zig build gpu-smoke` opens a small window long enough to submit a frame. SDL
still needs a usable video backend and display environment, so headless shells or
CI runners may need platform setup before this check can run.

The default optimize mode is `ReleaseSafe`. Override it when needed:

```sh
zig build -Doptimize=Debug
zig build -Doptimize=ReleaseFast
zig build -Doptimize=ReleaseSmall
```

Customize app metadata at build time:

```sh
zig build -Dapp-name=my-game -Dwindow-title="My Game"
```

Disable the SDL_ttf debug overlay if a target does not ship it:

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
- `src/main.zig` owns SDL startup, the window, event polling, and the main loop.
- `src/renderer.zig` owns SDL_GPU device setup, shader loading, texture upload,
  and the batched 2D draw API.
- `src/state.zig` defines the borrowed state stack and stack policies.
- `src/demo_state.zig` contains the initial movable-player state.
- `src/pause_state.zig` contains the background/inactive pause overlay.
- `src/pause_controller.zig` owns pause enter/exit behavior and forced pause handling.
- `src/input.zig` maps SDL key events to held input actions and latched frame commands.
- `src/debug_overlay.zig` owns debug-only overlay state.
- `src/assets.zig` resolves runtime asset paths and loads installed files.
- `src/camera.zig` contains the 2D camera transform used by the renderer.
- `src/config.zig` centralizes app/window/GPU configuration.
- `src/time_loop.zig` provides a fixed-step update loop with interpolation.
- `src/frame_pacer.zig` coordinates renderability checks and fallback loop
  pacing for hidden, minimized, background, or swapchain-unavailable frames.
- `src/fps_counter.zig` owns SDL_ttf-backed FPS text for the debug overlay.
- `src/root.zig` contains reusable game-agnostic helpers.
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
- `src/renderer.zig` tells SDL which shader formats the app built, passes a
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
pub fn handleEvent(self: *MyState, event: *const c.SDL_Event) bool {}
pub fn update(self: *MyState, input: *const InputState, delta_seconds: f32) void {}
pub fn render(self: *MyState, renderer: *Renderer, alpha: f32) !void {}
pub fn onPause(self: *MyState) void {}
```

Return `true` from `handleEvent` when the state consumes an event. Use
`try states.pushModal(State.from(MyState, &my_state))` for blocking menus,
`try states.pushOverlay(...)` for pass-through overlays, and
`try states.replaceGameplay(...)` for full state changes.

`StateStack` stores borrowed state pointers and returns handles for removal.
Keep each state value alive until its handle is removed or replaced. The stack
does not deinitialize borrowed states; callers own state lifetime and should
call state-specific `deinit` functions directly when needed.

## Input Model

Keyboard input maps to named `Action` values in `src/input.zig`. Gameplay code
reads held actions through `InputState`, while app-level commands such as pause,
resume, quit, and debug overlay toggle are latched for one frame through
`FrameCommands`.

The default bindings are WASD for movement, P for pause, Enter or Space for
resume, Escape for quit, and F2 for the debug overlay.

## Starting Your Game

This repository is intended to be cloned and edited into a game:

- Rename or replace `src/demo_state.zig`, then update the `DemoState` import and
  initialization in `src/main.zig`.
- Set your default app name and window title in `build.zig`, or pass
  `-Dapp-name=... -Dwindow-title=...` while iterating.
- Put reusable gameplay modules under `src/` and keep SDL/GPU ownership in
  `main.zig` and `renderer.zig` unless you have a reason to split it.
- When you publish a fork as a distinct package, regenerate the
  `build.zig.zon` fingerprint per Zig's package identity guidance.

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
and load the resulting platform shader file from `src/renderer.zig`.

Keep shader resource bindings aligned with SDL_GPU's layout rules:

- vertex uniform buffers: set 1
- fragment sampled textures/samplers: set 2
- fragment uniform buffers: set 3

The build converts those SPIR-V bindings to SDL-compatible MSL resource
bindings for macOS through `spirv-cross`.

## License

This project is licensed under the MIT License. See `LICENSE` for details.
