---
paths:
  - "src/assets/**"
  - "src/app/audio.zig"
  - "src/game/audio_controller.zig"
  - "src/game/ai_archetypes.zig"
  - "assets/**"
  - "tools/**"
---

# Assets, Atlases, Audio

How the pipeline works: `docs/atlas-asset-workflow.md`,
`docs/rendering-assets-shaders.md`.

## Loading

- Asset paths and image decode stay in `src/assets/`; the renderer creates
  textures from decoded pixels and owns only GPU resources.
- Runtime asset paths stay relative and traversal-safe.
- Authoring names never reach hot data: they resolve to numeric IDs at setup.
  A missing ID or name returns null and never guesses a position.
- Cache lookup and retain/release happen at setup only; every lease is
  released through `AssetCache.releaseTextureWithContext` before the renderer
  tears down.
- Every registered metadata file parses at startup, even when its texture
  falls back. Missing world atlas data is an error, never a fallback.
- Missing declared content is logged and marked unavailable; a fatal preload
  error rolls back its partial work.
- Data catalogs parse strictly at load (an unknown key is an error) into
  enum-indexed tables validated by the runtime validators, never on a hot
  path.

## Atlases

- Never one texture per tile.
- Atlas identity is structural: name = file stem, category = subfolder, slot =
  order position. Names are unique within an atlas and listed files exist.
- Animation and autotile data reference names, never grid indices or
  hard-coded counts. World tiles are 32×32. Catalog IDs and paths match the
  asset manifest.
- Art swaps never require code changes.
- After packing or editing a catalog, run `--lint` and `zig build verify`.

## Audio

- Audio requests go through `AudioCommandBuffer` with an `AudioAssetId`;
  commands carry only ID, gain, priority, frequency, and position. States and
  controllers never own `MIX_*` handles.
