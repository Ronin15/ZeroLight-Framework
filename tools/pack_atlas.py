#!/usr/bin/env python3
"""Pack loose filename-driven source sprites into atlas PNG + JSON manifests."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any

from PIL import Image

TOOLS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS_DIR))

from atlas_pack_common import (
    ORDERS_DIR,
    SOURCE_DIR,
    SPRITES_DIR,
    PackedEntry,
    build_sprite_entries,
    lint_atlas_manifest,
    load_entry_image,
    load_order,
    names_to_ids,
    pack_grid,
    resolve_ordered_entries,
    write_json,
)
from generate_world_tileset import CATEGORY_INFO, tile_properties


def pack_world(input_dir: Path, sprites_dir: Path, order_path: Path, *, lint_only: bool) -> list[str]:
    order = load_order(order_path)
    atlas_cfg = order["atlas"]

    tile_specs, source_paths, extra = resolve_ordered_entries(
        input_dir,
        order["tiles"],
        append_unlisted=atlas_cfg.get("append_unlisted", False),
    )

    tile_size = atlas_cfg["tile_size"]
    columns = atlas_cfg["columns"]
    packed_entries: list[PackedEntry] = []
    for spec, source in zip(tile_specs, source_paths, strict=True):
        packed_entries.append(
            PackedEntry(
                name=spec["name"],
                category=spec["category"],
                image=load_entry_image(source, tile_size, tile_size),
            )
        )

    atlas, columns, rows = pack_grid(packed_entries, tile_size, tile_size, columns)
    tile_entries: list[dict[str, Any]] = []
    categories: dict[str, list[int]] = {}

    for index, entry in enumerate(packed_entries):
        col = index % columns
        row = index // columns
        tile_entries.append(
            {
                "id": index,
                "name": entry.name,
                "category": entry.category,
                "column": col,
                "row": row,
                "x": col * tile_size,
                "y": row * tile_size,
                "width": tile_size,
                "height": tile_size,
                "properties": tile_properties(entry.category, entry.name),
            }
        )
        categories.setdefault(entry.category, []).append(index)

    category_info: dict[str, Any] = {}
    for category, ids in categories.items():
        if category == "unlisted":
            continue
        info = dict(CATEGORY_INFO.get(category, {"label": category, "description": ""}))
        info["row"] = ids[0] // columns
        info["tile_ids"] = ids
        category_info[category] = info

    animations: dict[str, Any] = {}
    for animation_name, animation in order.get("animations", {}).items():
        animations[animation_name] = {
            "tile_ids": names_to_ids(animation["names"], tile_entries),
            "frame_duration_ms": animation["frame_duration_ms"],
        }

    autotile_sets: dict[str, Any] = {}
    for set_name, autotile in order.get("autotile_sets", {}).items():
        autotile_sets[set_name] = {
            "layout": autotile["layout"],
            "tile_ids": names_to_ids(autotile["names"], tile_entries),
        }

    manifest: dict[str, Any] = {
        "version": 1,
        "name": atlas_cfg["name"],
        "theme": atlas_cfg["theme"],
        "atlas": {
            "path": atlas_cfg["png"],
            "sprite_asset_id": atlas_cfg["sprite_asset_id"],
            "width": columns * tile_size,
            "height": rows * tile_size,
        },
        "tile_size": tile_size,
        "columns": columns,
        "rows": rows,
        "tile_count": len(tile_entries),
        "category_info": category_info,
        "categories": categories,
        "animations": animations,
        "autotile_sets": autotile_sets,
        "tiles": tile_entries,
    }

    png_path = sprites_dir / Path(atlas_cfg["png"]).name
    json_path = sprites_dir / Path(atlas_cfg["json"]).name

    if lint_only:
        issues = lint_atlas_manifest(
            png_path,
            json_path,
            manifest,
            frame_w=tile_size,
            frame_h=tile_size,
            count_key="tile_count",
            entries_key="tiles",
        )
        if extra:
            print(f"note: appended {len(extra)} unlisted tiles: {', '.join(extra)}")
        return issues

    sprites_dir.mkdir(parents=True, exist_ok=True)
    atlas.save(png_path, optimize=True)
    write_json(json_path, manifest)
    print(
        f"Packed {len(tile_entries)} tiles -> {png_path} ({atlas.size[0]}x{atlas.size[1]})"
    )
    if extra:
        print(f"Appended {len(extra)} unlisted tiles: {', '.join(extra)}")
    return lint_atlas_manifest(
        png_path,
        json_path,
        manifest,
        frame_w=tile_size,
        frame_h=tile_size,
        count_key="tile_count",
        entries_key="tiles",
    )


def pack_sprites(
    *,
    kind: str,
    input_dir: Path,
    sprites_dir: Path,
    order_path: Path,
    lint_only: bool,
) -> list[str]:
    order = load_order(order_path)
    atlas_cfg = order["atlas"]

    sprite_specs, source_paths, extra = resolve_ordered_entries(
        input_dir,
        order["sprites"],
        append_unlisted=atlas_cfg.get("append_unlisted", False),
    )

    frame_w = atlas_cfg["frame_width"]
    frame_h = atlas_cfg["frame_height"]
    columns = atlas_cfg["columns"]

    packed_entries = [
        PackedEntry(
            name=spec["name"],
            category=spec["category"],
            image=load_entry_image(source, frame_w, frame_h),
        )
        for spec, source in zip(sprite_specs, source_paths, strict=True)
    ]

    atlas, columns, rows = pack_grid(packed_entries, frame_w, frame_h, columns)
    sprites, categories = build_sprite_entries(packed_entries, frame_w, frame_h, columns)

    manifest: dict[str, Any] = {
        "version": 1,
        "name": atlas_cfg["name"],
        "theme": atlas_cfg["theme"],
        "atlas": {
            "path": atlas_cfg["png"],
            "sprite_asset_id": atlas_cfg["sprite_asset_id"],
            "width": columns * frame_w,
            "height": rows * frame_h,
        },
        "frame_width": frame_w,
        "frame_height": frame_h,
        "columns": columns,
        "rows": rows,
        "sprite_count": len(sprites),
        "categories": categories,
        "sprites": sprites,
    }

    png_path = sprites_dir / Path(atlas_cfg["png"]).name
    json_path = sprites_dir / Path(atlas_cfg["json"]).name

    if lint_only:
        issues = lint_atlas_manifest(
            png_path,
            json_path,
            manifest,
            frame_w=frame_w,
            frame_h=frame_h,
            count_key="sprite_count",
            entries_key="sprites",
        )
        if extra:
            print(f"note: appended {len(extra)} unlisted sprites: {', '.join(extra)}")
        return issues

    sprites_dir.mkdir(parents=True, exist_ok=True)
    atlas.save(png_path, optimize=True)
    write_json(json_path, manifest)
    print(
        f"Packed {len(sprites)} {kind} sprites -> {png_path} ({atlas.size[0]}x{atlas.size[1]})"
    )
    if extra:
        print(f"Appended {len(extra)} unlisted sprites: {', '.join(extra)}")
    return lint_atlas_manifest(
        png_path,
        json_path,
        manifest,
        frame_w=frame_w,
        frame_h=frame_h,
        count_key="sprite_count",
        entries_key="sprites",
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--kind",
        choices=("world", "characters", "items", "all"),
        required=True,
    )
    parser.add_argument("--input", type=Path, default=None, help="Source sprite root")
    parser.add_argument("--out", type=Path, default=SPRITES_DIR, help="Atlas output dir")
    parser.add_argument("--order", type=Path, default=None, help="Order manifest path")
    parser.add_argument("--lint", action="store_true", help="Validate without writing")
    args = parser.parse_args()

    jobs: list[tuple[str, Path, Path]] = []
    if args.kind in ("world", "all"):
        jobs.append(
            (
                "world",
                args.input or SOURCE_DIR / "world_tiles",
                args.order or ORDERS_DIR / "world_tiles.json",
            )
        )
    if args.kind in ("characters", "all"):
        jobs.append(
            (
                "characters",
                args.input or SOURCE_DIR / "characters",
                args.order or ORDERS_DIR / "characters.json",
            )
        )
    if args.kind in ("items", "all"):
        jobs.append(
            (
                "items",
                args.input or SOURCE_DIR / "items",
                args.order or ORDERS_DIR / "items.json",
            )
        )

    if args.kind == "all" and args.input is not None:
        parser.error("--input cannot be used with --kind all")

    had_issue = False
    for kind, input_dir, order_path in jobs:
        if not input_dir.is_dir():
            raise FileNotFoundError(f"missing source directory: {input_dir}")
        if not order_path.is_file():
            raise FileNotFoundError(
                f"missing order manifest: {order_path} (run tools/gen_atlas_orders.py)"
            )

        if kind == "world":
            issues = pack_world(input_dir, args.out, order_path, lint_only=args.lint)
        else:
            issues = pack_sprites(
                kind=kind,
                input_dir=input_dir,
                sprites_dir=args.out,
                order_path=order_path,
                lint_only=args.lint,
            )

        for issue in issues:
            print(f"{kind}: {issue}")
            had_issue = True

    if had_issue:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
