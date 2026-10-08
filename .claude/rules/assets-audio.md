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

- Asset paths and PNG decode stay in `src/assets`; the renderer creates
  textures from decoded pixels and owns only the GPU texture.
- Runtime asset paths stay relative and traversal-safe.
- Never one texture per tile. Authoring names never appear in hot data; they
  resolve to numeric IDs at setup. Missing IDs or names return null and never
  guess grid positions.
- Cache lookup and retain/release are setup-time only; lease holders release
  through `AssetCache.releaseTexture` before renderer teardown.
- Every registered metadata sidecar parses at startup, even when its texture
  falls back. Missing world atlas data is an error, never a fallback.
- Missing declared content is logged and marked unavailable; fatal preload
  errors roll back partial work.
- Data catalogs (JSON) parse strictly at load (unknown key is an error) into
  enum-indexed tables, validated with the runtime validators, never on a hot
  path.
- Atlas identity: name = filename stem, category = subfolder, slot = order
  position. Names are unique within an atlas, and listed files exist at
  `{category}/{name}.png`.
- Animation and autotile sections reference names, never grid indices; never
  hardcode tile counts. World tiles are 32×32. JSON `sprite_asset_id` and
  `path` match `manifest.zig`.
- Art swaps never require Zig changes.
- After packing or editing a catalog, run `--lint` and `zig build verify`.
- Audio requests go through `AudioCommandBuffer` with `AudioAssetId`;
  commands carry only ID, gain, priority, frequency, and position. States and
  controllers never own `MIX_*` handles.
