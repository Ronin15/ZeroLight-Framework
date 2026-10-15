## Slice 4: Asset Cache

Goal: make runtime asset ownership explicit enough for real projects without
building a broad content pipeline too early.

Current foundation:

- `AssetStore` resolves safe relative paths from repo root or executable-relative
  install location.
- `AssetStore` resolves and decodes PNGs into transient CPU `LoadedImage` data.
- `AssetCache` maps validated relative PNG paths to retained renderer
  `TextureId` values by decoding through assets and asking render to upload
  already-decoded pixels.
- `Engine` owns the cache. Slice 17 later moved gameplay-facing render lookup
  to stable `RuntimeAssets` IDs exposed through `RenderContext`.
- `assets/test/cache_probe.png` provides a tiny installed PNG fixture for cache
  and asset-root checks.

Render-data boundary:

- Entity creation and world loading should bind stable sprite or atlas-region
  IDs before render-time. `DataSystem` render data should store stable asset
  references plus source intent such as tint, typed render-depth intent, and
  coordinate-space intent, not live renderer handles or raw layer numbers.
- State-owned render-prep code reads immutable `DataSystem` slices, resolves
  stable IDs through `RuntimeAssets`, and submits commands to `Renderer` only
  after an explicit ordered render-prep phase. The renderer should not look up
  gameplay entities, world data, asset paths, or texture assignments.
- Atlas and tile work should build on the same boundary: assets decode source
  images, atlas code packs CPU pixels, render uploads the final atlas texture,
  entities or tile cells reference atlas regions, and render prep converts those
  IDs into ordered commands with explicit `RenderOrder`.

Checklist:

- [x] Add an asset/resource cache module that maps stable asset paths to
      renderer resource IDs.
- [x] Keep path validation in `AssetStore`; do not duplicate traversal checks.
- [x] Decide cache ownership: app-level service owned by `Engine` is the default.
- [x] Add explicit load/unload or retain/release policy before adding hot reload.
- [x] Keep synchronous load first; defer async/staged loading until needed.
- [x] Add tests for duplicate path reuse, unload behavior, and invalid paths.

Acceptance checks:

- [x] Loading the same PNG twice can reuse the existing texture.
- [x] Asset paths remain relative and traversal-safe.
- [x] Installed-binary asset lookup still works with `-Dasset-root`.

