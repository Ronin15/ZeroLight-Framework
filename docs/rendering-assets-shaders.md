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
by texture and coordinate-presentation groups.

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

## Logical Presentation

The default logical game size is 1280x720. Windows are resizable and request
high pixel density, so SDL window coordinates and SDL_GPU drawable pixels can
differ on macOS Retina and similar displays.

The renderer does not use `SDL_Renderer` or SDL's renderer-only logical
presentation helpers. After each successful SDL_GPU swapchain acquisition it
computes presentation from the acquired drawable size and current SDL window
size, then applies `SDL_SetGPUViewport` and `SDL_SetGPUScissor` for draw
submission.

Default scale mode is aspect-preserving fit. If the drawable aspect differs from
1280x720, the configured clear color shows through the letterbox or pillarbox
bars.

Integer fit keeps strict whole-number scaling. The app requests a minimum SDL
window size equal to the logical size when integer fit is configured, so normal
user resizing should not produce sub-1x cropped presentation.

Sprite coordinate spaces:

- `.world`: gameplay/world coordinates. The camera is applied, then drawing uses
  the logical viewport.
- `.logical`: logical UI coordinates. The camera is ignored, and drawing uses
  the logical viewport.
- `.drawable`: raw swapchain pixel coordinates. The camera and logical viewport
  are ignored; this is for debug overlays that should stay pixel-exact.

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
the fixed update tick rate. The overlay uses drawable coordinates so its
SDL3_ttf texture remains independent of game scaling, and it scales font size by
the drawable-to-window pixel ratio for high-DPI displays. The current overlay
probes common system monospace font paths.
