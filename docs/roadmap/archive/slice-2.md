## Slice 2: Logical Resolution And Viewport Policy

Goal: make logical game coordinates deliberate before real UI, resizing, or
high-DPI behavior depends on them.

Current foundation:

- `AppConfig` owns a `ResolutionPolicy` plus resizable and high-pixel-density
  window defaults.
- `resolution.zig` defines logical size, scale mode, viewport math,
  presentation state, and pure coordinate conversion helpers.
- Renderer computes presentation from SDL_GPU swapchain drawable size and SDL
  window size on each submitted frame.
- World and logical drawing is transformed through the logical presentation into
  drawable pixels, then clipped to the logical viewport; drawable overlays use
  raw swapchain pixels.
- Integer-fit windows request a logical-size minimum client area so user
  resizing should not normally crop below 1x scale.

Checklist:

- [x] Add a `ResolutionPolicy` to `AppConfig`.
- [x] Compute the current `Viewport` when swapchain/window size changes.
- [x] Apply the viewport through SDL_GPU render pass or draw transform as
      appropriate for SDL_GPU.
- [x] Keep world/game drawing in logical coordinates.
- [x] Decide whether debug overlay is logical-space or screen-space and document it.
- [x] Add tests for fit, integer-fit, stretch, small windows, and invalid sizes.
- [x] Update README with resize/logical-resolution behavior.
- [x] Prevent normal sub-logical integer-fit resizing with SDL window minimum size.

Acceptance checks:

- [x] Existing demo renders correctly at the default 1280x720 logical size.
- [x] Resizable windows preserve the configured scale policy.
- [x] Letterbox offsets are centered and stable.
- [x] Hidden/minimized windows still skip rendering and use fallback pacing;
      visible no-swapchain frames enter render-blocked gameplay pause before
      the next update.
- [x] `zig build test`, `zig build check`, `zig build verify`, and
      `zig build gpu-smoke` cover unit, compile, shader, and one-frame GPU smoke
      validation. Manual `zig build dev` resize/pause smoke confirmed Retina
      1280x720 -> 2560x1440 and resized 1800x1130 -> 3600x2260 fit presentation.

