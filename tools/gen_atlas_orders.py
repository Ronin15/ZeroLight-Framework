#!/usr/bin/env python3
"""Generate atlas order manifests from the procedural sprite registries."""

from __future__ import annotations

import json
import sys
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS_DIR))

from atlas_pack_common import ORDERS_DIR, write_json
from generate_grim_sprites import CHARACTER_DEFS, ITEM_DEFS
from generate_world_tileset import CATEGORY_INFO, build_tile_registry
from tileset_common import COLS, TILE


def world_order() -> dict:
    tiles = build_tile_registry()
    categories: dict[str, list[str]] = {}
    category_indices: dict[str, list[int]] = {}
    tile_specs: list[dict[str, str]] = []

    for index, (category, name, _fn) in enumerate(tiles):
        tile_specs.append({"name": name, "category": category})
        categories.setdefault(category, []).append(name)
        category_indices.setdefault(category, []).append(index)

    autotile_sets = {
        "grass_dirt": {
            "layout": "transition_16",
            "names": categories["grass_dirt_transitions"],
        },
        "water_shore": {
            "layout": "transition_16",
            "names": categories["water_shore_transitions"],
        },
        "path": {
            "layout": "transition_16",
            "names": categories["paths"],
        },
    }

    return {
        "atlas": {
            "name": "grim_dark_world_tileset",
            "theme": "grim_dark_fantasy",
            "png": "sprites/world_tileset.png",
            "json": "sprites/world_tileset.json",
            "sprite_asset_id": "world_tileset",
            "tile_size": TILE,
            "columns": COLS,
            "append_unlisted": True,
        },
        "category_info": {
            category: {
                **info,
                "row": category_indices[category][0] // COLS,
                "tile_names": categories[category],
            }
            for category, info in CATEGORY_INFO.items()
        },
        "tiles": tile_specs,
        "animations": {
            "water": {
                "frame_duration_ms": 250,
                "names": ["water_1", "water_2", "water_3", "water_4"],
            }
        },
        "autotile_sets": autotile_sets,
    }


def character_order() -> dict:
    return {
        "atlas": {
            "name": "grim_dark_characters",
            "theme": "grim_dark_fantasy",
            "png": "sprites/grim_characters.png",
            "json": "sprites/grim_characters.json",
            "sprite_asset_id": "grim_characters",
            "frame_width": 32,
            "frame_height": 48,
            "columns": 8,
            "append_unlisted": True,
        },
        "sprites": [
            {"name": name, "category": category}
            for name, category, _fn in CHARACTER_DEFS
        ],
    }


def item_order() -> dict:
    return {
        "atlas": {
            "name": "grim_dark_items",
            "theme": "grim_dark_fantasy",
            "png": "sprites/grim_items.png",
            "json": "sprites/grim_items.json",
            "sprite_asset_id": "grim_items",
            "frame_width": 16,
            "frame_height": 16,
            "columns": 16,
            "append_unlisted": True,
        },
        "sprites": [
            {"name": name, "category": category}
            for name, category in ITEM_DEFS
        ],
    }


def main() -> None:
    ORDERS_DIR.mkdir(parents=True, exist_ok=True)
    write_json(ORDERS_DIR / "world_tiles.json", world_order())
    write_json(ORDERS_DIR / "characters.json", character_order())
    write_json(ORDERS_DIR / "items.json", item_order())
    print(f"Wrote atlas orders under {ORDERS_DIR}")


if __name__ == "__main__":
    main()