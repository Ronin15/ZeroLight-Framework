#!/usr/bin/env python3
"""Lint registered runtime atlas PNG/JSON files and optional source sprites."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any

from PIL import Image

REPO_ROOT = Path(__file__).resolve().parent.parent
PACK_SCRIPT = REPO_ROOT / "tools" / "pack_atlas.py"
SOURCE_ASSETS_DIR = REPO_ROOT / "source_assets"
SPRITES_DIR = REPO_ROOT / "assets" / "sprites"

REGISTERED_ATLASES = (
    {
        "kind": "world",
        "sprite_asset_id": "world_tileset",
        "runtime_path": "sprites/world_tileset.png",
        "json": SPRITES_DIR / "world_tileset.json",
        "png": SPRITES_DIR / "world_tileset.png",
        "entries_key": "tiles",
        "count_key": "tile_count",
        "width_key": "tile_size",
        "height_key": "tile_size",
    },
    {
        "kind": "characters",
        "sprite_asset_id": "grim_characters",
        "runtime_path": "sprites/grim_characters.png",
        "json": SPRITES_DIR / "grim_characters.json",
        "png": SPRITES_DIR / "grim_characters.png",
        "entries_key": "sprites",
        "count_key": "sprite_count",
        "width_key": "frame_width",
        "height_key": "frame_height",
    },
    {
        "kind": "items",
        "sprite_asset_id": "grim_items",
        "runtime_path": "sprites/grim_items.png",
        "json": SPRITES_DIR / "grim_items.json",
        "png": SPRITES_DIR / "grim_items.png",
        "entries_key": "sprites",
        "count_key": "sprite_count",
        "width_key": "frame_width",
        "height_key": "frame_height",
    },
)


def issue(label: str, message: str) -> str:
    return f"{label}: {message}"


def load_json(path: Path, label: str) -> tuple[dict[str, Any] | None, list[str]]:
    if not path.is_file():
        return None, [issue(label, f"missing json sidecar: {path}")]
    try:
        return json.loads(path.read_text(encoding="utf-8")), []
    except json.JSONDecodeError as err:
        return None, [issue(label, f"invalid json: {err}")]


def validate_entry_grid(
    label: str,
    entry: dict[str, Any],
    columns: int,
    rows: int,
    frame_w: int,
    frame_h: int,
) -> list[str]:
    issues: list[str] = []
    name = entry.get("name", "<unnamed>")
    entry_id = entry.get("id")
    if not isinstance(entry_id, int) or entry_id < 0:
        return [issue(label, f"{name} has invalid id {entry_id!r}")]

    if entry_id >= columns * rows:
        issues.append(issue(label, f"{name} id {entry_id} is outside {columns}x{rows} grid"))

    expected_column = entry_id % columns
    expected_row = entry_id // columns
    expected_x = expected_column * frame_w
    expected_y = expected_row * frame_h

    expected = {
        "column": expected_column,
        "row": expected_row,
        "x": expected_x,
        "y": expected_y,
        "width": frame_w,
        "height": frame_h,
    }
    for key, value in expected.items():
        if entry.get(key) != value:
            issues.append(issue(label, f"{name} {key}={entry.get(key)!r}, expected {value!r}"))

    return issues


def validate_id_lists(
    label: str,
    table_name: str,
    table: Any,
    valid_ids: set[int],
) -> list[str]:
    issues: list[str] = []
    if not isinstance(table, dict):
        return issues
    for name, value in table.items():
        ids = value.get("tile_ids") if isinstance(value, dict) else value
        if not isinstance(ids, list):
            issues.append(issue(label, f"{table_name}.{name} is not an id list"))
            continue
        for item in ids:
            if not isinstance(item, int) or item not in valid_ids:
                issues.append(issue(label, f"{table_name}.{name} references unknown id {item!r}"))
    return issues


def validate_runtime_atlas(spec: dict[str, Any]) -> list[str]:
    label = str(spec["sprite_asset_id"])
    meta, issues = load_json(Path(spec["json"]), label)
    if meta is None:
        return issues

    png_path = Path(spec["png"])
    if not png_path.is_file():
        issues.append(issue(label, f"missing png atlas: {png_path}"))
        return issues

    atlas = meta.get("atlas")
    if not isinstance(atlas, dict):
        issues.append(issue(label, "missing atlas object"))
        return issues

    if atlas.get("path") != spec["runtime_path"]:
        issues.append(issue(label, f"atlas.path={atlas.get('path')!r}, expected {spec['runtime_path']!r}"))
    if atlas.get("sprite_asset_id") != spec["sprite_asset_id"]:
        issues.append(issue(label, f"atlas.sprite_asset_id={atlas.get('sprite_asset_id')!r}, expected {spec['sprite_asset_id']!r}"))

    entries_key = str(spec["entries_key"])
    count_key = str(spec["count_key"])
    entries = meta.get(entries_key)
    if not isinstance(entries, list):
        issues.append(issue(label, f"{entries_key} is not a list"))
        return issues

    columns = meta.get("columns")
    rows = meta.get("rows")
    frame_w = meta.get(str(spec["width_key"]))
    frame_h = meta.get(str(spec["height_key"]))
    for field_name, value in (("columns", columns), ("rows", rows), ("frame width", frame_w), ("frame height", frame_h)):
        if not isinstance(value, int) or value <= 0:
            issues.append(issue(label, f"{field_name} must be a positive integer"))
    if issues:
        return issues

    expected_size = (columns * frame_w, rows * frame_h)
    with Image.open(png_path) as image:
        if image.size != expected_size:
            issues.append(issue(label, f"{png_path.name} is {image.size[0]}x{image.size[1]}, expected {expected_size[0]}x{expected_size[1]}"))

    atlas_width = atlas.get("width")
    atlas_height = atlas.get("height")
    if (atlas_width, atlas_height) != expected_size:
        issues.append(issue(label, f"atlas dimensions {(atlas_width, atlas_height)!r}, expected {expected_size!r}"))

    if meta.get(count_key) != len(entries):
        issues.append(issue(label, f"{count_key}={meta.get(count_key)!r}, expected {len(entries)}"))
    if len(entries) > columns * rows:
        issues.append(issue(label, f"{len(entries)} entries exceed {columns}x{rows} grid"))

    names: set[str] = set()
    ids: set[int] = set()
    categories: dict[str, list[int]] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            issues.append(issue(label, f"entry {entry!r} is not an object"))
            continue

        name = entry.get("name")
        entry_id = entry.get("id")
        category = entry.get("category")
        if not isinstance(name, str) or not name:
            issues.append(issue(label, f"entry id {entry_id!r} has invalid name {name!r}"))
        elif name in names:
            issues.append(issue(label, f"duplicate entry name {name!r}"))
        else:
            names.add(name)

        valid_entry_id = isinstance(entry_id, int)
        if valid_entry_id:
            if entry_id in ids:
                issues.append(issue(label, f"duplicate entry id {entry_id}"))
            ids.add(entry_id)

        if isinstance(category, str) and valid_entry_id:
            categories.setdefault(category, []).append(entry_id)
        elif isinstance(category, str):
            pass
        else:
            issues.append(issue(label, f"{name!r} has invalid category {category!r}"))

        issues.extend(validate_entry_grid(label, entry, columns, rows, frame_w, frame_h))

    json_categories = meta.get("categories", {})
    if isinstance(json_categories, dict):
        for category, listed_ids in json_categories.items():
            if not isinstance(listed_ids, list) or not all(isinstance(item, int) for item in listed_ids):
                issues.append(issue(label, f"categories.{category} is not an integer id list"))
                continue
            if set(listed_ids) != set(categories.get(category, [])):
                issues.append(issue(label, f"categories.{category} does not match entry ids"))
        for category in categories:
            if category not in json_categories:
                issues.append(issue(label, f"categories missing {category!r}"))
    else:
        issues.append(issue(label, "categories is not an object"))

    issues.extend(validate_id_lists(label, "animations", meta.get("animations"), ids))
    issues.extend(validate_id_lists(label, "autotile_sets", meta.get("autotile_sets"), ids))
    return issues


def run_source_consistency_lint() -> None:
    if not SOURCE_ASSETS_DIR.is_dir():
        print("source_assets/ not present; skipped source-to-runtime atlas comparison")
        return

    subprocess.run(
        [sys.executable, str(PACK_SCRIPT), "--kind", "all", "--lint"],
        cwd=REPO_ROOT / "tools",
        check=True,
    )


def main() -> None:
    issues: list[str] = []
    for spec in REGISTERED_ATLASES:
        issues.extend(validate_runtime_atlas(spec))

    if issues:
        for found in issues:
            print(found, file=sys.stderr)
        raise SystemExit(1)

    print(f"Validated {len(REGISTERED_ATLASES)} registered runtime atlases")
    run_source_consistency_lint()


if __name__ == "__main__":
    main()
