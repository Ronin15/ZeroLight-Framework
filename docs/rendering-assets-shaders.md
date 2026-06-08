# Rendering, Assets, And Shaders

The app uses SDL_GPU directly and does not call Vulkan or Metal APIs itself.
SDL chooses the backend from the formats and drivers available at runtime.

## Shader Build

Shader sources live in `assets/shaders/*.glsl`.

- On Linux, `glslc` emits installed SPIR-V files under `zig-out/bin/assets/shaders/*.spv`.
- On macOS, `glslc` emits temporary SPIR-V and `spirv-cross` converts it to installed MSL files under `zig-out/bin/assets/shaders/*.msl`.

The renderer tells SDL which shader formats the build produced and passes a null
driver name so SDL chooses the backend. Sprite material and pipeline creation
live under `src/render/gpu/` and load the shader files matching
`SDL_GetGPUShaderFormats()`.

## Sprite Rendering

Sprites and colored rectangles are collected into a CPU sprite batch, uploaded to one
GPU vertex buffer per frame, sorted by layer and submission order, and submitted
by texture and coordinate-presentation groups. Texture ownership is tracked with
generational `TextureId` values so stale or destroyed IDs are rejected
deterministically during batch prep.

`Renderer` remains the game-facing facade. `src/render/sprite_batch.zig` owns
sprite command storage, stable ordering, vertex expansion, and draw group
construction so later UI, tilemap, or effect batchers can be added without
rewriting SDL_GPU device setup.

Use `drawSprite` for textured quads:

```zig
if (self.player_texture == null) {
    self.player_texture = try context.acquireTexture("sprites/player.png");
}

try context.renderer.drawSprite(.{
    .texture = self.player_texture.?.id,
    .dest = .{ .x = 100, .y = 120, .w = 32, .h = 32 },
    .layer = 0,
});
```

`TextureId` values are stable while the texture is alive. Destroying a texture
retires its slot and advances the generation before the slot can be reused, so
old IDs do not accidentally bind a later texture. The built-in white texture is
renderer-internal and backs `drawRect`.

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

For atlases or future tile rendering, keep one `TextureId` for the atlas texture
and draw individual sprites or tiles with `Sprite.source` rectangles. Tilemap
batching should build on the same texture ID plus source-rect model rather than
creating one texture per tile.

## Logical Presentation

The default logical game size is 1280x720. Windows are resizable and request
high pixel density, so SDL window coordinates and SDL_GPU drawable pixels can
differ on macOS Retina and similar displays.

The renderer does not use `SDL_Renderer` or SDL's renderer-only logical
presentation helpers. After each successful SDL_GPU swapchain acquisition it
computes presentation from the acquired drawable size and current SDL window
size. World and logical vertices are transformed into drawable pixels before
upload; SDL_GPU viewport stays in drawable space and scissor clips logical
content to the computed viewport.

Default scale mode is aspect-preserving fit. If the drawable aspect differs from
1280x720, the configured clear color shows through the letterbox or pillarbox
bars.

Integer fit keeps strict whole-number scaling. The app requests a minimum SDL
window size equal to the logical size when integer fit is configured, so normal
user resizing should not produce sub-1x cropped presentation.

Sprite coordinate spaces:

- `.world`: gameplay/world coordinates. The camera is applied, then vertices are
  transformed through the logical presentation into drawable pixels.
- `.logical`: logical UI coordinates. The camera is ignored, and vertices are
  transformed through the logical presentation into drawable pixels.
- `.drawable`: raw swapchain pixel coordinates. The camera and logical viewport
  are ignored; this is for debug overlays that should stay pixel-exact.

## Runtime Assets

The current demo draws primitives, so it has no required PNG asset. The default
text path uses the bundled `assets/fonts/NotoSansMono-Regular.ttf` font. Put
additional PNGs, fonts, and other runtime files under `assets/`, then acquire
renderer-backed resources through the app-owned services from a render context.

Runtime assets are installed under `zig-out/bin/<asset-root>`. The default
asset root is `assets`; change it with `-Dasset-root=content`.

The installed runtime asset tree excludes shader source files and build-only
shader formats. Package source assets separately if your game needs them.

Asset paths are relative to the configured asset root and reject empty paths,
absolute paths, `.` components, and `..` traversal.

PNG image loading uses core SDL3 `SDL_LoadPNG` support in the asset layer; this
project does not require `SDL3_image`.

The asset cache maps validated relative PNG paths to renderer `TextureId` values.
Loading the same path decodes PNG data through `AssetStore`, uploads decoded
RGBA8 pixels through the renderer, reuses the existing texture on later
acquires, and increments a retain count. Store the returned `TextureLease` in
the owning state or service, draw with `lease.id`, and call `release` from that
owner's `deinit`. When the last lease is released, the cache destroys the
renderer texture. Cache lookup and retain/release are setup-time operations;
per-frame rendering should keep using the retained `TextureId` directly.

## Text Rendering

`TextService` owns SDL3_ttf initialization and shutdown, opens fonts through
`AssetStore`, and caches rendered text as renderer textures. Production
`RenderContext` values provide it for menu and UI states; unit-test contexts can
leave it null when text is not part of the contract under test. Load fonts from
`assets/fonts/...`, keep the returned `FontId`, acquire text only when the string
or style changes, draw the returned texture through `Renderer.drawSprite`, and
release the `TextTextureLease` from the owning state or service.

The default font is `fonts/NotoSansMono-Regular.ttf`. System font probing is not
part of the normal runtime path.

## Adding A Shader

Add GLSL source under `assets/shaders/`, then add an entry to the
`shader_programs` table in `build.zig` so the build emits the platform shader
files. Load the resulting installed shader files from the render-owned GPU
pipeline module, such as `src/render/gpu/sprite_pipeline.zig`, while keeping
`Renderer` as the game-facing facade.

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
the drawable-to-window pixel ratio for high-DPI displays. The overlay renders
through the asset-backed text service and bundled default font.
