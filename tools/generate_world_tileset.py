#!/usr/bin/env python3
"""Generate a grim-dark fantasy 32x32 world tileset atlas."""

from __future__ import annotations

import json
import random
from typing import Callable

from PIL import Image

from tileset_common import COLS, OUT_DIR, ROWS, TILE
from tileset_quality import (
    make_ash,
    make_blood_floor,
    make_blood_pool,
    make_brick_wall,
    make_cave_tile,
    make_cliff_tile,
    make_decoration,
    make_dirt,
    make_fog,
    make_frost_tile,
    make_grass,
    make_grass_dirt_transition,
    make_lava,
    make_path_tile,
    make_sand,
    make_sludge,
    make_stone,
    make_structure_tile,
    make_swamp,
    make_tree_tile,
    make_void,
    make_water,
    make_water_shore,
    make_wood_planks,
)


TileFn = Callable[[], Image.Image]

CATEGORY_INFO = {
    "terrain_base": {
        "label": "Terrain Base",
        "description": "Core walkable ground tiles for overworld and dungeon floors.",
    },
    "fluids": {
        "label": "Fluids",
        "description": "Water, swamp, blood, sludge, lava, and atmospheric fluid tiles.",
    },
    "grass_dirt_transitions": {
        "label": "Grass/Dirt Transitions",
        "description": "16-tile edge blend set for grass meeting dirt.",
    },
    "water_shore_transitions": {
        "label": "Water Shores",
        "description": "16-tile shoreline blend set for water meeting land.",
    },
    "cliffs": {
        "label": "Cliffs",
        "description": "Cliff tops, vertical faces, and rocky elevation edges.",
    },
    "dungeon_walls": {
        "label": "Dungeon Walls",
        "description": "Brick wall segments for interior and ruin construction.",
    },
    "decorations_a": {
        "label": "Decorations A",
        "description": "Small props: rocks, bones, fences, containers, and hazards.",
    },
    "decorations_b": {
        "label": "Decorations B",
        "description": "Additional prop variants and dungeon clutter.",
    },
    "decorations_c": {
        "label": "Decorations C",
        "description": "More prop variants for scene dressing.",
    },
    "paths": {
        "label": "Paths",
        "description": "Dirt road and trail junction tiles.",
    },
    "trees_foliage": {
        "label": "Trees & Foliage",
        "description": "Large organic obstacles and dead woodland features.",
    },
    "cave_underground": {
        "label": "Cave Underground",
        "description": "Cavern floors, stone, and underground hazard tiles.",
    },
    "structures": {
        "label": "Structures",
        "description": "Doors, bridges, altars, and interactive set pieces.",
    },
    "frost_wasteland": {
        "label": "Frost Wasteland",
        "description": "Frozen ground, ice, and frost-covered terrain.",
    },
}

FLUID_TILE_NAMES = {
    "water_1",
    "water_2",
    "water_3",
    "water_4",
    "swamp_water",
    "blood_pool",
    "toxic_sludge",
    "lava_cracks",
    "murky_depths",
}

BLOCKING_CATEGORIES = {
    "cliffs",
    "dungeon_walls",
    "trees_foliage",
    "structures",
}

DECORATION_CATEGORIES = {
    "decorations_a",
    "decorations_b",
    "decorations_c",
    "trees_foliage",
    "structures",
}


def tile_properties(category: str, name: str) -> dict:
    layer = "ground"
    walkable = True
    blocks_vision = False
    blocks_movement = False
    terrain = "generic"

    if category in BLOCKING_CATEGORIES:
        blocks_movement = True
        blocks_vision = category in {"dungeon_walls", "trees_foliage", "structures"}
        layer = "collision"
        if category == "cliffs":
            terrain = "cliff"
        elif category == "dungeon_walls":
            terrain = "wall"
        elif category == "trees_foliage":
            terrain = "tree"
            layer = "object"
        else:
            terrain = "structure"
            layer = "object"
    elif category in DECORATION_CATEGORIES:
        layer = "object"
        terrain = "prop"
        if name.startswith("deco_"):
            blocks_movement = True
    elif category == "fluids":
        walkable = False
        blocks_movement = True
        terrain = "fluid"
        if name.startswith("water") or name in {"swamp_water", "murky_depths"}:
            terrain = "water"
        elif name == "blood_pool":
            terrain = "blood"
        elif name == "toxic_sludge":
            terrain = "sludge"
        elif name == "lava_cracks":
            terrain = "lava"
    elif category == "terrain_base":
        if name == "void_pit":
            walkable = False
            blocks_movement = True
            terrain = "void"
        elif name in {"grass", "grass_patchy", "grass_bones", "grass_rocky"}:
            terrain = "grass"
        elif name in {"dirt", "dirt_dark", "mud"}:
            terrain = "dirt"
        elif "stone" in name or name == "cobblestone":
            terrain = "stone"
        elif name == "rotten_planks":
            terrain = "wood"
        elif name == "ash_waste":
            terrain = "ash"
        elif name == "dark_sand":
            terrain = "sand"
    elif category == "grass_dirt_transitions":
        terrain = "grass_dirt"
    elif category == "water_shore_transitions":
        terrain = "water_shore"
        if name.endswith("_0"):
            walkable = False
    elif category == "paths":
        terrain = "path"
    elif category == "cave_underground":
        terrain = "cave"
    elif category == "frost_wasteland":
        terrain = "frost"

    return {
        "layer": layer,
        "terrain": terrain,
        "walkable": walkable,
        "blocks_movement": blocks_movement,
        "blocks_vision": blocks_vision,
    }


def build_tile_registry() -> list[tuple[str, str, TileFn]]:
    tiles: list[tuple[str, str, TileFn]] = []

    def add_row(row_name: str, entries: list[tuple[str, TileFn]]) -> None:
        for col, (name, fn) in enumerate(entries):
            tiles.append((row_name, name, fn))

    add_row(
        "terrain_base",
        [
            ("grass", lambda: make_grass(1)),
            ("grass_patchy", lambda: make_grass(2, dead=True)),
            ("grass_bones", lambda: make_grass(3, bones=True)),
            ("grass_rocky", lambda: make_grass(4, rocky=True)),
            ("dirt", lambda: make_dirt(5)),
            ("dirt_dark", lambda: make_dirt(6)),
            ("mud", lambda: make_dirt(7, wet=True)),
            ("cobblestone", lambda: make_stone(8, cobble=True)),
            ("stone_floor", lambda: make_stone(9)),
            ("stone_cracked", lambda: make_stone(10, cracked=True)),
            ("stone_mossy", lambda: make_stone(11, mossy=True)),
            ("blood_stained_stone", lambda: make_blood_floor(12)),
            ("rotten_planks", lambda: make_wood_planks(13)),
            ("ash_waste", lambda: make_ash(14)),
            ("dark_sand", lambda: make_sand(15)),
            ("void_pit", make_void),
        ],
    )

    add_row(
        "fluids",
        [
            ("water_1", lambda: make_water(0)),
            ("water_2", lambda: make_water(1)),
            ("water_3", lambda: make_water(2)),
            ("water_4", lambda: make_water(3)),
            ("swamp_water", lambda: make_swamp(20)),
            ("blood_pool", lambda: make_blood_pool(21)),
            ("toxic_sludge", lambda: make_sludge(22)),
            ("lava_cracks", lambda: make_lava(23)),
            ("foggy_grass", lambda: make_fog(24)),
            ("dungeon_floor", lambda: make_stone(25, cracked=True, mossy=True)),
            ("gravel", lambda: make_sand(26)),
            ("deep_mud", lambda: make_dirt(27, wet=True)),
            ("charred_earth", lambda: make_ash(28)),
            ("broken_cobble", lambda: make_stone(29, cobble=True, cracked=True)),
            ("slick_stone", lambda: make_stone(30)),
            ("murky_depths", lambda: make_water(4)),
        ],
    )

    transitions = [(f"grass_dirt_{i}", lambda i=i: make_grass_dirt_transition(i)) for i in range(16)]
    add_row("grass_dirt_transitions", transitions)

    shores = [(f"water_shore_{i}", lambda i=i: make_water_shore(i)) for i in range(16)]
    add_row("water_shore_transitions", shores)

    cliffs = [(f"cliff_{i}", lambda i=i: make_cliff_tile(i)) for i in range(16)]
    add_row("cliffs", cliffs)

    walls = [(f"brick_wall_{i}", lambda i=i: make_brick_wall(i)) for i in range(16)]
    add_row("dungeon_walls", walls)

    deco_row1 = [(f"deco_{i}", lambda i=i: make_decoration(i)) for i in range(16)]
    add_row("decorations_a", deco_row1)

    deco_row2 = [(f"deco_{i + 16}", lambda i=i: make_decoration(i + 16)) for i in range(16)]
    add_row("decorations_b", deco_row2)

    deco_row3 = [(f"deco_{i + 32}", lambda i=i: make_decoration(i + 32)) for i in range(16)]
    add_row("decorations_c", deco_row3)

    paths = [(f"path_{i}", lambda i=i: make_path_tile(i)) for i in range(16)]
    add_row("paths", paths)

    trees = [(f"tree_{i}", lambda i=i: make_tree_tile(i)) for i in range(16)]
    add_row("trees_foliage", trees)

    caves = [(f"cave_{i}", lambda i=i: make_cave_tile(i)) for i in range(16)]
    add_row("cave_underground", caves)

    structures = [(f"structure_{i}", lambda i=i: make_structure_tile(i)) for i in range(16)]
    add_row("structures", structures)

    frost = [(f"frost_{i}", lambda i=i: make_frost_tile(i)) for i in range(16)]
    add_row("frost_wasteland", frost)

    return tiles


def compose_atlas(tiles: list[tuple[str, str, TileFn]]) -> tuple[Image.Image, dict]:
    expected = COLS * ROWS
    if len(tiles) != expected:
        raise ValueError(f"Expected {expected} tiles, got {len(tiles)}")

    atlas = Image.new("RGBA", (COLS * TILE, ROWS * TILE), (0, 0, 0, 0))
    categories: dict[str, list[int]] = {}
    tile_entries: list[dict] = []

    for index, (category, name, fn) in enumerate(tiles):
        col = index % COLS
        row = index // COLS
        tile = fn()
        atlas.paste(tile, (col * TILE, row * TILE), tile)
        tile_entries.append(
            {
                "id": index,
                "name": name,
                "category": category,
                "column": col,
                "row": row,
                "x": col * TILE,
                "y": row * TILE,
                "width": TILE,
                "height": TILE,
                "properties": tile_properties(category, name),
            }
        )
        categories.setdefault(category, []).append(index)

    category_info = {}
    for category, ids in categories.items():
        info = dict(CATEGORY_INFO[category])
        info["row"] = ids[0] // COLS
        info["tile_ids"] = ids
        category_info[category] = info

    manifest: dict = {
        "version": 1,
        "name": "grim_dark_world_tileset",
        "theme": "grim_dark_fantasy",
        "atlas": {
            "path": "sprites/world_tileset.png",
            "sprite_asset_id": "world_tileset",
            "width": COLS * TILE,
            "height": ROWS * TILE,
        },
        "tile_size": TILE,
        "columns": COLS,
        "rows": ROWS,
        "tile_count": len(tiles),
        "category_info": category_info,
        "categories": categories,
        "animations": {
            "water": {
                "tile_ids": [entry["id"] for entry in tile_entries if entry["name"] in FLUID_TILE_NAMES and entry["name"].startswith("water")],
                "frame_duration_ms": 250,
            },
        },
        "autotile_sets": {
            "grass_dirt": {
                "layout": "transition_16",
                "tile_ids": categories["grass_dirt_transitions"],
            },
            "water_shore": {
                "layout": "transition_16",
                "tile_ids": categories["water_shore_transitions"],
            },
            "path": {
                "layout": "transition_16",
                "tile_ids": categories["paths"],
            },
        },
        "tiles": tile_entries,
    }

    return atlas, manifest


def main() -> None:
    random.seed(0xA17A)
    tiles = build_tile_registry()
    atlas, manifest = compose_atlas(tiles)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    png_path = OUT_DIR / "world_tileset.png"
    json_path = OUT_DIR / "world_tileset.json"

    atlas.save(png_path, optimize=True)
    json_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    print(f"Wrote {png_path} ({atlas.size[0]}x{atlas.size[1]})")
    print(f"Wrote {json_path} ({len(manifest['tiles'])} tiles)")


if __name__ == "__main__":
    main()