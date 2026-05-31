# Zig SDL3 GPU Framework

A Zig 0.16.0 + SDL3 starter framework for SDL_GPU-first 2D games.

The project uses SDL3 for windowing, input, image loading, and GPU rendering. It
builds GLSL shaders into SPIR-V at build time and renders through SDL_GPU.

## Features

- SDL3 window and event loop
- SDL_GPU renderer with SPIR-V shaders
- Batched sprite and rectangle drawing
- Fixed 60Hz update loop with interpolation
- Vsync-driven rendering with 60Hz fallback pacing when not renderable
- Scene stack for gameplay, menus, tools, and overlays
- Frame-stable input state
- Runtime asset loading from the installed `assets/` directory
- GPU smoke executable for checking SDL_GPU device creation

## Requirements

- Zig 0.16.0 or newer compatible 0.16.x build
- SDL3 development headers and library discoverable by the compiler/linker
- `glslc` for shader compilation when running, packaging, or verifying shaders

On Arch Linux, the SDL3 package is `sdl3`. `glslc` is commonly provided by
`shaderc` or a Vulkan SDK package, depending on platform.

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
zig build           # build and install the app into zig-out/bin
zig build run       # build, install assets/shaders, and run the app
zig build dev       # build shaders, install assets, and run the app
zig build check     # compile the game and GPU smoke executable
zig build test      # run Zig unit tests
zig build verify    # run check, test, and shader compilation
zig build package   # install binaries and runtime assets into zig-out/bin
```

Useful supporting commands:

```sh
zig build fmt       # format build.zig and src/
zig build shaders   # compile GLSL shader sources to SPIR-V
zig build gpu-smoke # create an SDL_GPU device and submit one hidden-window frame
```

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

Use a non-default shader compiler path:

```sh
zig build shaders -Dshader-compiler=/path/to/glslc
```

## Project Layout

- `build.zig` defines executables, tests, formatting, shader compilation, and
  install steps.
- `build.zig.zon` contains package metadata.
- `src/main.zig` owns SDL startup, the window, event polling, and the main loop.
- `src/renderer.zig` owns SDL_GPU device setup, shader loading, texture upload,
  and the batched 2D draw API.
- `src/scene.zig` defines the push/pop scene stack.
- `src/demo_scene.zig` contains the initial movable-player scene.
- `src/input.zig` converts SDL input events into a frame-stable input state.
- `src/assets.zig` resolves runtime asset paths and loads installed files.
- `src/camera.zig` contains the 2D camera transform used by the renderer.
- `src/config.zig` centralizes app/window/GPU configuration.
- `src/time_loop.zig` provides a fixed-step update loop with interpolation.
- `src/frame_pacer.zig` coordinates renderability checks and fallback loop
  pacing for hidden, minimized, occluded, or swapchain-unavailable frames.
- `src/root.zig` contains reusable game-agnostic helpers.
- `assets/` contains runtime assets and shader sources.

Generated build output goes under `zig-out/` and should not be committed.

## Rendering Notes

The app uses SDL_GPU directly and does not call Vulkan APIs itself.

- Shader sources live in `assets/shaders/*.glsl`.
- `zig build shaders` compiles GLSL to SPIR-V with `glslc`.
- Compiled shader binaries are installed as
  `zig-out/bin/assets/shaders/*.spv`.
- `src/renderer.zig` creates an SDL_GPU device with
  `SDL_GPU_SHADERFORMAT_SPIRV`.
- On Linux, SDL_GPU normally selects its Vulkan backend for SPIR-V shaders.
- Game code should draw through `Renderer` instead of calling SDL_GPU directly.
- PNG texture loading uses core SDL3 `SDL_LoadPNG`/`SDL_LoadSurface` support;
  this project does not require `SDL3_image`.

Sprites and colored rectangles are collected into a CPU batch, uploaded to one
GPU vertex buffer per frame, and submitted by texture/layer groups.

The visible render loop is paced by SDL_GPU swapchain acquisition with the
default vsync present mode. Simulation remains fixed at 60Hz through
`TimeLoop`, while rendering may follow higher refresh displays and interpolate
between fixed updates. When the window is hidden, minimized, occluded, or SDL
cannot provide a swapchain texture, the app skips GPU rendering and uses
`SDL_DelayNS` to keep the loop at a 60Hz fallback cadence.

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

## Adding A Scene

Create a struct with this shape and push or replace it through `SceneStack`:

```zig
pub fn deinit(self: *MyScene) void {}
pub fn handleEvent(self: *MyScene, event: *const c.SDL_Event) void {}
pub fn update(self: *MyScene, input: *const InputState, delta_seconds: f32) void {}
pub fn render(self: *MyScene, renderer: *Renderer, alpha: f32) !void {}
```

Use `try scenes.push(Scene.from(MyScene, &my_scene))` for overlays and
`try scenes.replace(...)` for full state changes.

## Adding Art

Put PNGs under `assets/`, then load them through the renderer after it is
initialized:

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
and load the resulting `.spv` from `src/renderer.zig`.

Keep shader resource bindings aligned with SDL_GPU's SPIR-V layout rules:

- vertex uniform buffers: set 1
- fragment sampled textures/samplers: set 2
- fragment uniform buffers: set 3

## License

This project is licensed under the MIT License. See `LICENSE` for details.
