## Slice 5: Text And Font Service

Goal: move from FPS-only SDL_ttf usage to asset-backed text rendering suitable
for menus, buttons, and UI.

Current foundation:

- SDL3_ttf is a core dependency.
- `TextService` owns SDL3_ttf lifecycle, asset-backed font loading, and cached
  renderer text textures.
- `FpsCounter` consumes the text service instead of probing system fonts or
  owning raw SDL_ttf resources.
- `assets/fonts/NotoSansMono-Regular.ttf` is the bundled default text font.

Checklist:

- [x] Add a centralized text/font service that owns `TTF_Init` and `TTF_Quit`.
- [x] Load fonts from `assets/fonts/...` through `AssetStore`.
- [x] Add `FontId` allocation and validation using generational IDs.
- [x] Render text into cached renderer textures.
- [x] Define cache invalidation for text string, font, color, wrap width, and
      layout options.
- [x] Move `FpsCounter` to consume the text service.
- [x] Add at least one bundled font or document the asset requirement clearly.
- [x] Add tests for descriptor validation and cache keys where possible.

Acceptance checks:

- [x] F2 overlay still renders yellow FPS text.
- [x] No system font path probing remains in normal text flow.
- [x] Text texture lifetime is centralized and cleaned up by the owning service.

