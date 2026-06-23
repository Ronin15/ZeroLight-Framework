#!/usr/bin/env python3
"""Export loose source PNGs from installed atlas sheets + JSON manifests."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image

from atlas_pack_common import SOURCE_DIR, SPRITES_DIR, safe_asset_component, safe_child_path


def export_world_tiles(sprites_dir: Path, source_dir: Path) -> int:
    png_path = sprites_dir / "world_tileset.png"
    json_path = sprites_dir / "world_tileset.json"
    manifest = json.loads(json_path.read_text(encoding="utf-8"))
    atlas = Image.open(png_path).convert("RGBA")

    count = 0
    for tile in manifest["tiles"]:
        category = safe_asset_component(tile["category"], "tile category")
        name = safe_asset_component(tile["name"], "tile name")
        out_dir = safe_child_path(source_dir, "world_tiles", category)
        out_dir.mkdir(parents=True, exist_ok=True)
        out_path = safe_child_path(out_dir, f"{name}.png")
        frame = atlas.crop(
            (
                tile["x"],
                tile["y"],
                tile["x"] + tile["width"],
                tile["y"] + tile["height"],
            )
        )
        frame.save(out_path, optimize=True)
        count += 1

    return count


def export_sprite_atlas(
    png_name: str,
    json_name: str,
    source_subdir: str,
    sprites_dir: Path,
    source_dir: Path,
) -> int:
    png_path = sprites_dir / png_name
    json_path = sprites_dir / json_name
    manifest = json.loads(json_path.read_text(encoding="utf-8"))
    atlas = Image.open(png_path).convert("RGBA")

    count = 0
    for sprite in manifest["sprites"]:
        category = safe_asset_component(sprite["category"], "sprite category")
        name = safe_asset_component(sprite["name"], "sprite name")
        out_dir = safe_child_path(source_dir, source_subdir, category)
        out_dir.mkdir(parents=True, exist_ok=True)
        out_path = safe_child_path(out_dir, f"{name}.png")
        frame = atlas.crop(
            (
                sprite["x"],
                sprite["y"],
                sprite["x"] + sprite["width"],
                sprite["y"] + sprite["height"],
            )
        )
        frame.save(out_path, optimize=True)
        count += 1

    return count


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--sprites-dir",
        type=Path,
        default=SPRITES_DIR,
        help="Directory containing installed atlas png/json files",
    )
    parser.add_argument(
        "--source-dir",
        type=Path,
        default=SOURCE_DIR,
        help="Directory to write loose source sprites",
    )
    parser.add_argument(
        "--kind",
        choices=("world", "characters", "items", "all"),
        default="all",
    )
    args = parser.parse_args()

    total = 0
    if args.kind in ("world", "all"):
        total += export_world_tiles(args.sprites_dir, args.source_dir)
    if args.kind in ("characters", "all"):
        total += export_sprite_atlas(
            "grim_characters.png",
            "grim_characters.json",
            "characters",
            args.sprites_dir,
            args.source_dir,
        )
    if args.kind in ("items", "all"):
        total += export_sprite_atlas(
            "grim_items.png",
            "grim_items.json",
            "items",
            args.sprites_dir,
            args.source_dir,
        )

    print(f"Exported {total} source sprites to {args.source_dir}")


if __name__ == "__main__":
    main()
