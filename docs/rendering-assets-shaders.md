# Rendering, Assets, And Shaders

The app uses SDL_GPU directly and does not call Vulkan or Metal APIs itself.
SDL chooses the backend from the formats and drivers available at runtime.

## Shader Build

Shader sources live in `assets/shaders/*.glsl`.

- On Linux, `glslc` emits installed SPIR-V files under `zig-out/bin/assets/shaders/*.spv`.
- On macOS, `glslc` emits temporary SPIR-V and `spirv-cross` converts it to installed MSL files under `zig-out/bin/assets/shaders/*.msl`.

`src/render/renderer.zig` tells SDL which shader formats the build produced,
passes a null driver name so SDL chooses the backend, and loads the shader files
matching `SDL_GetGPUShaderFormats()`.

## Sprite Rendering

Sprites and colored rectangles are collected into a CPU batch, uploaded to one
GPU vertex buffer per frame, sorted by layer and submission order, and submitted
by texture/layer groups.

Use `drawSprite` for textured quads:

```zig
const texture = try renderer.createTextureFromPng(assets, "sprites/player.png");

try renderer.drawSprite(.{
    .texture = texture,
    .dest = .{ .x = 100, .y = 120, .w = 32, .h = 32 },
    .layer = 0,
});
```

Use `drawRect` for debug or simple primitive rendering. It goes through the same
sprite batch via a built-in white texture:

```zig
try renderer.drawRect(.{
    .x = 40,
    .y = 40,
    .w = 64,
    .h = 64,
}, .{ .r = 0.9, .g = 0.2, .b = 0.2, .a = 1.0 }, 0);
```

## Runtime Assets

The current demo draws primitives, so it has no required PNG asset. Put PNGs
under `assets/`, then load them through the renderer after it is initialized.

Runtime assets are installed under `zig-out/bin/<asset-root>`. The default
asset root is `assets`; change it with `-Dasset-root=content`.

The installed runtime asset tree excludes shader source files and build-only
shader formats. Package source assets separately if your game needs them.

Asset paths are relative to the configured asset root and reject empty paths,
absolute paths, `.` components, and `..` traversal.

PNG texture loading uses core SDL3 `SDL_LoadPNG`/`SDL_LoadSurface` support; this
project does not require `SDL3_image`.

## Adding A Shader

Add GLSL source under `assets/shaders/`, then add an entry to the
`shader_programs` table in `build.zig` so the build emits the platform shader
files. Load the resulting installed shader files from `src/render/renderer.zig`.

Keep shader resource bindings aligned with SDL_GPU's layout rules:

- vertex uniform buffers: set 1
- fragment sampled textures/samplers: set 2
- fragment uniform buffers: set 3

The build converts those SPIR-V bindings to SDL-compatible MSL resource bindings
for macOS through `spirv-cross`.

## Debug Overlay

Press F2 to toggle the yellow FPS overlay. It reports render-loop cadence, not
the fixed update tick rate. The current overlay uses SDL3_ttf and probes common
system monospace font paths.
