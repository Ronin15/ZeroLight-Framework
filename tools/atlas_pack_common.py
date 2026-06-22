"""Shared helpers for filename-driven atlas packing."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from PIL import Image

REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCE_DIR = REPO_ROOT / "source_assets"
SPRITES_DIR = REPO_ROOT / "assets" / "sprites"
ORDERS_DIR = Path(__file__).resolve().parent / "atlas_orders"


@dataclass(frozen=True)
class PackedEntry:
    name: str
    category: str
    image: Image.Image


def load_order(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def safe_asset_component(value: str, label: str) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{label} must be a string")
    if value in ("", ".", ".."):
        raise ValueError(f"{label} must be a non-empty filename component")
    if "/" in value or "\\" in value or Path(value).name != value:
        raise ValueError(f"{label} must not contain path separators: {value!r}")
    return value


def safe_child_path(root: Path, *components: str) -> Path:
    root_resolved = root.resolve(strict=False)
    path = root.joinpath(*components)
    resolved = path.resolve(strict=False)
    try:
        resolved.relative_to(root_resolved)
    except ValueError as err:
        raise ValueError(f"path escapes root {root}: {path}") from err
    return path


def canonical_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def compare_json_manifest(path: Path, expected: dict[str, Any]) -> list[str]:
    if not path.is_file():
        return [f"missing atlas json: {path}"]

    try:
        actual = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as err:
        return [f"{path.name} is invalid json: {err}"]

    if canonical_json(actual) == canonical_json(expected):
        return []

    return [f"{path.name} does not match generated atlas manifest"]


def resolve_source_png(input_dir: Path, name: str, category: str) -> Path | None:
    safe_name = safe_asset_component(name, "sprite name")
    safe_category = safe_asset_component(category, "sprite category")
    candidates = [
        safe_child_path(input_dir, safe_category, f"{safe_name}.png"),
        safe_child_path(input_dir, f"{safe_name}.png"),
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate

    matches = [png for png in input_dir.rglob("*.png") if png.stem == safe_name]
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        raise ValueError(
            f"Ambiguous sprite filename '{safe_name}' under {input_dir}; "
            f"use {safe_category}/{safe_name}.png"
        )
    return None


def discover_unlisted_pngs(
    input_dir: Path,
    listed: set[tuple[str, str]],
) -> list[tuple[str, str, Path]]:
    extras: list[tuple[str, str, Path]] = []
    for png in sorted(input_dir.rglob("*.png")):
        category = png.parent.name if png.parent != input_dir else "unlisted"
        key = (png.stem, category)
        if (png.stem, category) in listed or (png.stem, "unlisted") in listed:
            continue
        if any(name == png.stem for name, _cat in listed):
            continue
        extras.append((png.stem, category, png))
    return extras


def load_entry_image(path: Path, frame_w: int, frame_h: int) -> Image.Image:
    image = Image.open(path).convert("RGBA")
    if image.size != (frame_w, frame_h):
        raise ValueError(
            f"{path.name} is {image.size[0]}x{image.size[1]}, expected {frame_w}x{frame_h}"
        )
    return image


def pack_grid(
    entries: list[PackedEntry],
    frame_w: int,
    frame_h: int,
    columns: int,
) -> tuple[Image.Image, int, int]:
    if columns <= 0:
        raise ValueError("columns must be > 0")
    if not entries:
        raise ValueError("no entries to pack")

    rows = (len(entries) + columns - 1) // columns
    atlas = Image.new("RGBA", (columns * frame_w, rows * frame_h), (0, 0, 0, 0))

    for index, entry in enumerate(entries):
        col = index % columns
        row = index // columns
        atlas.paste(entry.image, (col * frame_w, row * frame_h), entry.image)

    return atlas, columns, rows


def resolve_ordered_entries(
    input_dir: Path,
    ordered_specs: list[dict[str, str]],
    *,
    append_unlisted: bool,
) -> tuple[list[dict[str, str]], list[Path], list[str]]:
    missing: list[str] = []
    resolved: list[dict[str, str]] = []
    paths: list[Path] = []
    listed: set[tuple[str, str]] = set()

    for spec in ordered_specs:
        name = spec["name"]
        category = spec["category"]
        listed.add((name, category))
        source = resolve_source_png(input_dir, name, category)
        if source is None:
            missing.append(f"{category}/{name}")
            continue
        resolved.append(spec)
        paths.append(source)

    if missing:
        raise FileNotFoundError(
            "Missing source PNGs for ordered entries: " + ", ".join(missing)
        )

    extra: list[str] = []
    if append_unlisted:
        for name, category, source in discover_unlisted_pngs(input_dir, listed):
            extra.append(f"{category}/{name}")
            resolved.append({"name": name, "category": category})
            paths.append(source)

    return resolved, paths, extra


def build_sprite_entries(
    packed: list[PackedEntry],
    frame_w: int,
    frame_h: int,
    columns: int,
) -> tuple[list[dict[str, Any]], dict[str, list[int]]]:
    sprites: list[dict[str, Any]] = []
    categories: dict[str, list[int]] = {}

    for index, entry in enumerate(packed):
        col = index % columns
        row = index // columns
        sprites.append(
            {
                "id": index,
                "name": entry.name,
                "category": entry.category,
                "column": col,
                "row": row,
                "x": col * frame_w,
                "y": row * frame_h,
                "width": frame_w,
                "height": frame_h,
            }
        )
        categories.setdefault(entry.category, []).append(index)

    return sprites, categories


def names_to_ids(names: list[str], sprites: list[dict[str, Any]]) -> list[int]:
    by_name = {sprite["name"]: sprite["id"] for sprite in sprites}
    missing = [name for name in names if name not in by_name]
    if missing:
        raise ValueError("Animation/autotile names missing from packed atlas: " + ", ".join(missing))
    return [by_name[name] for name in names]


def lint_atlas_manifest(
    png_path: Path,
    json_path: Path,
    manifest: dict[str, Any],
    *,
    frame_w: int,
    frame_h: int,
    count_key: str,
    entries_key: str,
) -> list[str]:
    issues: list[str] = compare_json_manifest(json_path, manifest)

    if not png_path.is_file():
        issues.append(f"missing atlas png: {png_path}")
        return issues

    image = Image.open(png_path)
    columns = manifest["columns"]
    rows = manifest["rows"]
    expected_size = (columns * frame_w, rows * frame_h)
    if image.size != expected_size:
        issues.append(
            f"{png_path.name} is {image.size[0]}x{image.size[1]}, expected {expected_size[0]}x{expected_size[1]}"
        )

    entries = manifest[entries_key]
    if manifest[count_key] != len(entries):
        issues.append(f"{count_key} ({manifest[count_key]}) != len({entries_key}) ({len(entries)})")

    seen_names: set[str] = set()
    for entry in entries:
        if entry["name"] in seen_names:
            issues.append(
                f"duplicate entry name '{entry['name']}' (filenames must be globally unique)"
            )
        seen_names.add(entry["name"])

        if entry["width"] != frame_w or entry["height"] != frame_h:
            issues.append(f"{entry['name']} has unexpected frame size")

    return issues
