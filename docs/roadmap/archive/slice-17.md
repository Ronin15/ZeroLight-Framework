## Slice 17: Startup Runtime Asset Catalog

Goal: preload the declared runtime asset set during `Engine.init` and make an
Engine-owned `RuntimeAssets` app service the source of stable sprite/audio
handles for gameplay, render prep, and audio commands. Missing declared content
should log once and mark that asset unavailable, but should not fail app
initialization.

Current foundation:

- `AssetStore` resolves traversal-safe runtime asset paths under the configured
  asset root.
- `AssetCache` decodes PNGs, uploads renderer textures, and returns retained
  `TextureLease` values.
- `AudioService` owns SDL3_mixer lifecycle, track pools, loaded audio handles,
  bus gains, and pause ducking.
- `Renderer` owns live GPU textures and draw submission.
- `DataSystem` stores persistent asset-reference component rows as stable
  `SpriteAssetId` values, but it does not own live renderer or audio resources.
- `RenderContext` exposes `RuntimeAssets`; `AudioCommandBuffer` carries stable
  `AudioAssetId` values plus playback parameters.

Architecture notes:

- `RuntimeAssets` lives under `src/assets/` and is an app service/catalog, not a
  gameplay processor under `src/game/systems/`.
- Add a typed code manifest for startup assets. It assigns stable IDs such as
  `SpriteAssetId` and `AudioAssetId` to relative asset paths.
- `Engine` owns `RuntimeAssets`. It preloads declared sprites/images through
  `AssetCache` after `Renderer` exists and preloads declared audio through
  `AudioService` after the mixer service exists.
- `RuntimeAssets` owns startup texture lease tokens, releases them explicitly
  through the live `AssetCache`/`Renderer` owner, and exposes prepared sprite
  metadata such as `{ texture, source_rect }`. Today each sprite can use a full
  texture; future atlas work can map the same `SpriteAssetId` to an atlas texture
  and source rectangle.
- `DataSystem` stores only stable sprite asset IDs as persistent entity component
  data. It may keep those component rows dense, but it must not store
  `TextureId`, `TextureLease`, prepared sprite records, SDL_mixer handles, or
  loaded audio handles.
- Runtime gameplay and render prep should use stable asset IDs, not string
  paths. Path validation, PNG decode, GPU upload, audio load/predecode, and
  string/hash lookup stay out of fixed update and hot render paths.
- Missing declared assets are logged and exposed as unavailable handles;
  allocation failures, invalid config, and SDL/GPU/audio service initialization
  failures still return errors.
- Startup preload remains in `Engine.init`; `LoadingState` now covers
  runtime-asset-backed gameplay construction. Larger streamed asset sets can
  extend that state with visible progress using the existing catalog status
  without changing ownership.

Checklist:

- [x] Add a typed startup asset manifest with stable sprite and audio IDs.
- [x] Add Engine-owned `RuntimeAssets` that preloads declared sprite/image
      assets during `Engine.init`, owns their texture leases, and releases them
      before renderer teardown.
- [x] Add audio preload support so declared music and SFX IDs resolve to loaded
      `AudioService` handles without path lookup during command drain.
- [x] Change render-facing code to resolve `SpriteAssetId` through
      `RuntimeAssets` instead of acquiring textures by relative path.
- [x] Change audio commands to carry `AudioAssetId` instead of copied relative
      paths.
- [x] Change `DataSystem` asset-reference component data from relative paths to
      stable `SpriteAssetId` values.
- [x] Add the first demo sprite asset under `assets/sprites/` and assign sprite
      IDs to player, AI squares, and obstacles.
- [x] Update render-facing demo code so deterministic entity drawing resolves
      sprite IDs through `RuntimeAssets` with primitive fallback for unavailable
      sprite IDs.
- [x] Update architecture and rendering/assets docs to describe startup preload,
      stable IDs, missing-asset behavior, and atlas-ready source rectangles.

Acceptance checks:

- [x] Engine startup attempts to preload every declared sprite and audio asset
      once.
- [x] Missing declared content logs once, marks the asset unavailable, and does
      not abort app initialization.
- [x] Gameplay state, render-facing drawing, and audio commands use stable asset
      IDs rather than runtime string paths.
- [x] `DataSystem` contains no live renderer texture IDs, texture leases,
      prepared sprite records, SDL_mixer handles, or loaded audio handles.
- [x] Render-facing drawing resolves `SpriteAssetId` to
      `{ texture, source_rect }` and preserves deterministic draw ordering.
- [x] Future atlas mapping can change the catalog resolution without changing
      entity component storage.
- [x] `zig build fmt`, `zig build test`, `zig build check`, and
      `zig build verify` pass.
- [x] Manual `zig build dev` smoke confirms menu, gameplay, sprite rendering,
      audio, pause, debug overlay, and repeated transitions still work.

Slice 17 lands the startup runtime asset catalog. `Engine` now preloads the
manifest-declared demo sprite and audio set, gameplay stores stable sprite IDs,
rendering resolves IDs through `RuntimeAssets` with primitive fallback, and
audio commands drain by preloaded `AudioAssetId` instead of copied paths. The
catalog release path uses the live cache/renderer owner rather than
self-releasing lease pointers. Manual `zig build dev` validation confirmed menu,
gameplay, sprite rendering, audio, pause, debug overlay, and repeated
transitions.

---

