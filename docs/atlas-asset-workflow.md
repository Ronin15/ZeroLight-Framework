# Atlas Asset Workflow

This project packs loose source sprites into runtime atlas PNGs plus JSON sidecar
manifests. Gameplay resolves sprites and tiles by **filename** (the PNG stem), not
by hardcoded numeric IDs in Zig.

Build tools live under `tools/`. Runtime atlases install to `assets/sprites/` and
are registered in `src/assets/manifest.zig`.

## Goals

- Swap placeholder art without changing Zig gameplay code.
- Keep one stable atlas handle per sheet (`SpriteAssetId`) while names and slot
  layout stay data-driven in JSON.
- Enforce a 32×32 pixel grid for world tiles; character and item frame sizes are
  declared per atlas in the order manifest.
- Allow sheets to grow: new trailing slots can be appended when
  `append_unlisted` is enabled.

## Directory Layout

```
source_assets/               # artist-facing loose PNGs (not installed at runtime)
  world_tiles/
      terrain_base/grass.png
      fluids/water_1.png
      ...
    characters/
      hero/adventurer.png
      enemy/skeleton.png
      ...
    items/
      weapon_melee/sword.png
      consumable/health_potion.png
      ...

assets/
  sprites/                   # packed runtime atlases (output + installed assets)
    world_tileset.png
    world_tileset.json
    grim_characters.png
    grim_characters.json
    grim_items.png
    grim_items.json

tools/
  atlas_orders/              # pack order + animation/autotile wiring
    world_tiles.json
    characters.json
    items.json
  pack_atlas.py
  export_source_sprites.py
  gen_atlas_orders.py
  atlas_pack_common.py
```

`source_assets/` is the working tree for filename-driven art (gitignored by default).
`assets/sprites/` is what the game loads at runtime.

## Identity Contract

| Concept | Rule |
|---------|------|
| Sprite/tile name | PNG filename without extension (`grass.png` → `"grass"`) |
| Category | Subfolder under the source root (`terrain_base/grass.png` → `"terrain_base"`) |
| Atlas handle | Stable `SpriteAssetId` in `manifest.zig` (`.world_tileset`, `.grim_characters`, `.grim_items`) |
| Grid slot | Position in the order manifest; drives `id`, `column`, `row`, and `x/y` rects |
| Uniqueness | Names must be **globally unique within an atlas** |

Gameplay should store `SpriteAssetId` plus a name string (for example `"grass"` or
`"adventurer"`). Resolve source rectangles at load or setup time through the
metadata loaders:

- `world_tileset_meta.zig` — `tileByName`, `sourceRectByName`, `sourceRectForId`,
  `animationByName` (JSON-driven animation table built at load)
- `sprite_atlas_meta.zig` — `spriteByName`, `sourceRectByName`, `sourceRectForId`

Metadata paths resolve through `manifest.spriteSpec(id).metadata_path`. Name lookup
uses load-time hash indexes; missing IDs or names return null instead of guessing
grid positions.

`Engine.init()` preloads every registered sprite texture and atlas JSON metadata
through `RuntimeAssets.preload(...)`. Gameplay reads prepared textures by
`SpriteAssetId` and filename lookups through `worldTilesetMeta()` /
`spriteAtlasMeta(...)`. When a sprite texture is available, its JSON sidecar must
also load successfully or startup fails.

## Order Manifests

Order files in `tools/atlas_orders/` define:

1. **Pack sequence** — which filenames occupy which grid indices.
2. **Atlas metadata** — output paths, frame sizes, column count, theme name.
3. **World-only extras** — animation frame lists and autotile sets, expressed as
   filename lists that the packer resolves to numeric tile IDs.

Example world-tile animation entry:

```json
"animations": {
  "water": {
    "frame_duration_ms": 250,
    "names": ["water_1", "water_2", "water_3", "water_4"]
  }
}
```

Regenerate order files from the procedural registries when the placeholder
catalog changes:

```sh
cd tools
python3 gen_atlas_orders.py
```

After editing an order file by hand, run the packer to refresh `assets/sprites/`.
The default packer input is `source_assets/`, which is local generated source
art. Bootstrap it from the checked-in atlases first when starting from a clean
checkout:

```sh
cd tools
python3 export_source_sprites.py
```

## Packing Commands

Pack all atlases from the default source tree:

```sh
cd tools
python3 pack_atlas.py --kind all
```

Pack or validate one atlas:

```sh
python3 pack_atlas.py --kind world
python3 pack_atlas.py --kind characters
python3 pack_atlas.py --kind items
python3 pack_atlas.py --kind world --lint
```

Custom paths:

```sh
python3 pack_atlas.py --kind world \
  --input ../source_assets/world_tiles \
  --out ../assets/sprites \
  --order atlas_orders/world_tiles.json
```

The packer:

1. Resolves each ordered entry to `{category}/{name}.png` (falls back to a single
   unambiguous recursive match).
2. Validates frame dimensions (`32×32` tiles, `32×48` characters, `16×16` items).
3. Writes the atlas PNG and JSON manifest.
4. Appends any unlisted source PNGs at the end when `append_unlisted` is true.
5. Lints manifest consistency (dimensions, counts, duplicate names).

## Bootstrap And Round-Trip

To slice existing runtime atlases into loose source PNGs:

```sh
cd tools
python3 export_source_sprites.py
```

Full placeholder refresh (procedural generators → source → pack):

```sh
cd tools
python3 generate_world_tileset.py
python3 generate_grim_sprites.py
python3 gen_atlas_orders.py
python3 export_source_sprites.py
python3 pack_atlas.py --kind all
```

Use the procedural scripts for dev placeholders. Use `pack_atlas.py` for final
artist-authored PNGs.

## Swapping Art

### Same names, new pixels

Replace PNGs under `source_assets/...` and repack:

```sh
cd tools && python3 pack_atlas.py --kind all
```

No Zig changes required.

### Renamed files

1. Rename source PNGs.
2. Update the matching entries in `tools/atlas_orders/*.json`.
3. Repack.
4. Update gameplay name strings if any call sites used the old filename.

### Additional trailing slots

1. Add PNGs under `source_assets/...`.
2. Either add them to the order file or rely on `append_unlisted: true`.
3. Repack. JSON `rows` / `tile_count` / `sprite_count` grow as needed.

World tileset Zig validation requires `tile_size == 32` and internal consistency;
it no longer hardcodes a fixed tile count.

### Grid order changes (autotiles, water animation)

Update `tools/atlas_orders/world_tiles.json` so tile names appear in the correct
sequence, then repack. Autotile and animation sections reference **names**, not
grid indices, so they stay stable across reorders as long as those names still
exist.

## Runtime Registration

`src/assets/manifest.zig` maps each atlas to:

- `path` — runtime PNG relative to the asset root
- `metadata_path` — JSON sidecar
- `metadata_kind` — loader dispatch (`world_tileset` or `sprite_atlas`)

JSON `atlas.sprite_asset_id` and `atlas.path` must match the manifest entry.
The metadata loaders call `validateAtlasMetadata` at load time to catch mismatches.

## Validation

After packing:

```sh
python3 tools/pack_atlas.py --kind all --lint
zig build test
```

`zig build verify` always runs atlas lint (see `tools/lint_assets_if_changed.py`).
Lint validates the registered runtime atlas PNG/JSON sidecars directly. When
`source_assets/` is present, lint also compares the source-driven generated
manifests against the runtime sidecars so new source PNGs, removals, and art
swaps are caught before commit. Use `zig build assets-lint` to run the atlas
check directly.

`--lint` checks an existing packed atlas against a manifest that would be
generated from the current source tree. It is useful before committing asset
changes.

## Common Pitfalls

- **Duplicate filenames across categories** — not allowed in the packed JSON even
  if source folders differ. Use globally unique stems (`deco_16` not a second
  `deco_0`).
- **Wrong frame size** — the packer rejects PNGs that do not match the atlas
  frame size declared in the order file.
- **Missing order entry** — ordered tiles/sprites must exist under
  `{category}/{name}.png`. Unlisted extras only append when `append_unlisted` is
  true.
- **Forgot to repack** — runtime loads `assets/sprites/`; editing source PNGs alone
  does not change the installed game assets until you pack and rebuild/install.

## Related Docs

- `docs/rendering-assets-shaders.md` — `SpriteAssetId`, `RuntimeAssets`, and GPU
  sprite drawing.
- `docs/development-workflow.md` — build, test, and asset-root commands.
