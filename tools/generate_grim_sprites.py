#!/usr/bin/env python3
"""Generate grim-dark fantasy character and item sprite atlases."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Callable

from PIL import Image, ImageDraw

from tileset_common import OUT_DIR, PALETTE, RGB, fill_rect

CHR_W, CHR_H = 32, 48
CHR_COLS, CHR_ROWS = 8, 3

ITEM_SIZE = 16
ITEM_COLS, ITEM_ROWS = 16, 3


def px(img: Image.Image, x: int, y: int, color: RGB, alpha: int = 255) -> None:
    w, h = img.size
    if 0 <= x < w and 0 <= y < h:
        img.putpixel((x, y), (*color.as_tuple(), alpha))


def rect(img: Image.Image, x0: int, y0: int, x1: int, y1: int, color: RGB) -> None:
    draw = ImageDraw.Draw(img)
    draw.rectangle((x0, y0, x1, y1), fill=(*color.as_tuple(), 255))


def blank_character() -> Image.Image:
    return Image.new("RGBA", (CHR_W, CHR_H), (0, 0, 0, 0))


def blank_item() -> Image.Image:
    return Image.new("RGBA", (ITEM_SIZE, ITEM_SIZE), (0, 0, 0, 0))


def draw_shadow_oval(img: Image.Image, cx: int, cy: int, rx: int, ry: int) -> None:
    draw = ImageDraw.Draw(img)
    draw.ellipse((cx - rx, cy - ry, cx + rx, cy + ry), fill=(*PALETTE["shadow"].as_tuple(), 120))


def draw_humanoid_base(
    img: Image.Image,
    *,
    skin: RGB,
    cloth: RGB,
    cloth_hi: RGB,
    cloth_lo: RGB,
    hair: RGB,
    boot: RGB | None = None,
) -> tuple[int, int]:
    """Returns (cx, feet_y) anchor."""
    cx = CHR_W // 2
    boot_color = boot or PALETTE["iron_dark"]
    draw_shadow_oval(img, cx, CHR_H - 6, 9, 3)

    # legs
    rect(img, cx - 5, 34, cx - 2, 43, cloth_lo)
    rect(img, cx + 2, 34, cx + 5, 43, cloth_lo)
    rect(img, cx - 5, 40, cx - 2, 44, boot_color)
    rect(img, cx + 2, 40, cx + 5, 44, boot_color)

    # torso
    rect(img, cx - 7, 20, cx + 7, 35, cloth)
    rect(img, cx - 6, 21, cx - 4, 33, cloth_hi)
    rect(img, cx + 4, 22, cx + 6, 34, cloth_lo.darken(0.1))

    # arms
    rect(img, cx - 10, 22, cx - 7, 32, cloth)
    rect(img, cx + 7, 22, cx + 10, 32, cloth)
    px(img, cx - 10, 32, skin)
    px(img, cx + 10, 32, skin)

    # head
    rect(img, cx - 5, 10, cx + 5, 19, skin)
    rect(img, cx - 4, 8, cx + 4, 11, hair)
    px(img, cx - 2, 14, PALETTE["shadow"])
    px(img, cx + 2, 14, PALETTE["shadow"])
    return cx, 44


def draw_cape(img: Image.Image, cx: int, color: RGB) -> None:
    draw = ImageDraw.Draw(img)
    draw.polygon([(cx - 8, 22), (cx + 8, 22), (cx + 6, 40), (cx - 6, 40)], fill=(*color.as_tuple(), 255))


def draw_adventurer(pose: int = 0) -> Image.Image:
    img = blank_character()
    cx, _ = draw_humanoid_base(
        img,
        skin=RGB(168, 142, 118),
        cloth=PALETTE["iron_dark"],
        cloth_hi=PALETTE["iron_mid"],
        cloth_lo=PALETTE["iron_dark"].darken(0.12),
        hair=RGB(58, 46, 36),
        boot=PALETTE["wood_dark"],
    )
    draw_cape(img, cx, PALETTE["brick_dark"].darken(0.05))
    # sword
    sway = pose % 3
    rect(img, cx + 9, 18 - sway, cx + 11, 36 - sway, PALETTE["iron_light"])
    rect(img, cx + 8, 34 - sway, cx + 12, 37 - sway, PALETTE["wood_mid"])
    # belt
    rect(img, cx - 7, 30, cx + 7, 31, PALETTE["leather"] if "leather" in dir(PALETTE) else PALETTE["wood_dark"])
    return img


def draw_knight() -> Image.Image:
    img = blank_character()
    cx, _ = draw_humanoid_base(
        img,
        skin=RGB(152, 136, 120),
        cloth=PALETTE["iron_mid"],
        cloth_hi=PALETTE["iron_light"],
        cloth_lo=PALETTE["iron_dark"],
        hair=RGB(72, 72, 78),
    )
    rect(img, cx - 6, 8, cx + 6, 16, PALETTE["iron_mid"])
    rect(img, cx - 4, 10, cx - 2, 12, PALETTE["void"])
    rect(img, cx + 2, 10, cx + 4, 12, PALETTE["void"])
    rect(img, cx - 11, 24, cx - 8, 34, PALETTE["iron_light"])
    return img


def draw_rogue() -> Image.Image:
    img = blank_character()
    cx, _ = draw_humanoid_base(
        img,
        skin=RGB(154, 128, 104),
        cloth=RGB(44, 48, 52),
        cloth_hi=RGB(62, 66, 72),
        cloth_lo=RGB(30, 34, 38),
        hair=RGB(34, 30, 28),
    )
    rect(img, cx - 6, 9, cx + 6, 12, RGB(34, 30, 28))
    px(img, cx - 2, 13, PALETTE["void"])
    px(img, cx + 2, 13, PALETTE["void"])
    rect(img, cx + 8, 26, cx + 10, 34, PALETTE["iron_mid"])
    return img


def draw_mage() -> Image.Image:
    img = blank_character()
    cx, _ = draw_humanoid_base(
        img,
        skin=RGB(170, 150, 132),
        cloth=RGB(48, 36, 68),
        cloth_hi=RGB(68, 52, 92),
        cloth_lo=RGB(32, 24, 48),
        hair=RGB(220, 210, 188),
    )
    draw = ImageDraw.Draw(img)
    draw.polygon([(cx - 7, 10), (cx + 7, 10), (cx, 2)], fill=(*RGB(48, 36, 68).as_tuple(), 255))
    rect(img, cx + 9, 12, cx + 11, 40, PALETTE["wood_dark"])
    px(img, cx + 10, 10, PALETTE["water_light"])
    return img


def draw_merchant() -> Image.Image:
    img = blank_character()
    cx, _ = draw_humanoid_base(
        img,
        skin=RGB(176, 148, 120),
        cloth=RGB(92, 64, 40),
        cloth_hi=RGB(118, 84, 52),
        cloth_lo=RGB(68, 46, 30),
        hair=RGB(96, 72, 44),
    )
    rect(img, cx - 9, 28, cx - 6, 36, RGB(118, 84, 52))
    rect(img, cx + 6, 28, cx + 9, 36, RGB(118, 84, 52))
    return img


def draw_priest() -> Image.Image:
    img = blank_character()
    cx, _ = draw_humanoid_base(
        img,
        skin=RGB(160, 140, 124),
        cloth=RGB(72, 72, 80),
        cloth_hi=RGB(96, 96, 104),
        cloth_lo=RGB(52, 52, 58),
        hair=RGB(210, 200, 180),
    )
    rect(img, cx - 8, 18, cx + 8, 38, RGB(88, 88, 96))
    rect(img, cx - 1, 14, cx + 1, 24, PALETTE["highlight"])
    return img


def draw_wounded_soldier() -> Image.Image:
    img = draw_knight()
    cx = CHR_W // 2
    px(img, cx - 3, 24, PALETTE["blood_mid"])
    px(img, cx - 2, 25, PALETTE["blood_dark"])
    px(img, cx + 4, 28, PALETTE["blood_mid"])
    rect(img, cx - 8, 30, cx - 5, 38, PALETTE["cloth_bandage"] if False else PALETTE["bone"])
    return img


def draw_hooded_stranger() -> Image.Image:
    img = blank_character()
    cx = CHR_W // 2
    draw_shadow_oval(img, cx, CHR_H - 6, 9, 3)
    rect(img, cx - 7, 22, cx + 7, 42, RGB(36, 34, 40))
    draw = ImageDraw.Draw(img)
    draw.polygon([(cx - 9, 18), (cx + 9, 18), (cx + 7, 8), (cx - 7, 8)], fill=(*RGB(36, 34, 40).as_tuple(), 255))
    px(img, cx - 2, 14, PALETTE["lava_glow"])
    px(img, cx + 2, 14, PALETTE["lava_glow"])
    return img


def draw_skeleton() -> Image.Image:
    img = blank_character()
    cx = CHR_W // 2
    draw_shadow_oval(img, cx, CHR_H - 6, 9, 3)
    bone, bd = PALETTE["bone"], PALETTE["bone_dark"]
    rect(img, cx - 4, 34, cx - 2, 42, bone)
    rect(img, cx + 2, 34, cx + 4, 42, bone)
    rect(img, cx - 6, 20, cx + 6, 34, bone)
    rect(img, cx - 8, 22, cx - 5, 30, bone)
    rect(img, cx + 5, 22, cx + 8, 30, bone)
    rect(img, cx - 5, 10, cx + 5, 18, bone)
    px(img, cx - 2, 13, PALETTE["void"])
    px(img, cx + 2, 13, PALETTE["void"])
    rect(img, cx + 7, 20, cx + 9, 38, PALETTE["iron_mid"])
    for x in range(cx - 4, cx + 5):
        px(img, x, 18, bd)
    return img


def draw_bone_archer() -> Image.Image:
    img = draw_skeleton()
    cx = CHR_W // 2
    rect(img, cx - 12, 18, cx - 4, 20, PALETTE["wood_mid"])
    px(img, cx - 4, 19, PALETTE["wood_dark"])
    return img


def draw_cultist() -> Image.Image:
    img = blank_character()
    cx, _ = draw_humanoid_base(
        img,
        skin=RGB(140, 120, 108),
        cloth=RGB(58, 24, 32),
        cloth_hi=RGB(82, 34, 42),
        cloth_lo=RGB(40, 16, 22),
        hair=RGB(24, 20, 22),
    )
    draw = ImageDraw.Draw(img)
    draw.polygon([(cx - 8, 12), (cx + 8, 12), (cx, 4)], fill=(*RGB(40, 16, 22).as_tuple(), 255))
    px(img, cx, 16, PALETTE["blood_mid"])
    return img


def draw_dark_hound() -> Image.Image:
    img = blank_character()
    cx = CHR_W // 2
    draw_shadow_oval(img, cx, CHR_H - 4, 12, 4)
    body = RGB(44, 40, 46)
    rect(img, cx - 10, 26, cx + 10, 36, body)
    rect(img, cx + 6, 22, cx + 14, 30, body)
    rect(img, cx + 12, 24, cx + 15, 27, PALETTE["bone"])
    px(img, cx + 14, 25, PALETTE["blood_mid"])
    rect(img, cx - 8, 34, cx - 5, 40, body.darken(0.1))
    rect(img, cx + 3, 34, cx + 6, 40, body.darken(0.1))
    px(img, cx - 4, 28, PALETTE["lava_glow"])
    return img


def draw_plague_rat() -> Image.Image:
    img = blank_character()
    cx = CHR_W // 2
    draw_shadow_oval(img, cx, CHR_H - 4, 8, 3)
    fur = RGB(68, 62, 58)
    rect(img, cx - 8, 30, cx + 8, 38, fur)
    rect(img, cx + 4, 28, cx + 12, 34, fur)
    px(img, cx + 12, 29, PALETTE["bone"])
    px(img, cx - 2, 32, PALETTE["blood_dark"])
    rect(img, cx - 6, 36, cx - 4, 40, fur.darken(0.15))
    rect(img, cx + 2, 36, cx + 4, 40, fur.darken(0.15))
    return img


def draw_revenant() -> Image.Image:
    img = draw_knight()
    cx = CHR_W // 2
    for y in range(10, 18):
        for x in range(cx - 5, cx + 6):
            r, g, b, a = img.getpixel((x, y))
            if a > 0:
                img.putpixel((x, y), (*PALETTE["moss_sick"].lerp(RGB(r, g, b), 0.45).as_tuple(), a))
    px(img, cx - 2, 13, PALETTE["lava_glow"])
    px(img, cx + 2, 13, PALETTE["lava_glow"])
    return img


def draw_wraith() -> Image.Image:
    img = blank_character()
    cx = CHR_W // 2
    mist = PALETTE["fog"]
    draw = ImageDraw.Draw(img)
    draw.ellipse((cx - 10, 10, cx + 10, 42), fill=(*mist.as_tuple(), 180))
    draw.ellipse((cx - 6, 8, cx + 6, 20), fill=(*mist.lighten(0.1).as_tuple(), 200))
    px(img, cx - 2, 14, PALETTE["water_light"])
    px(img, cx + 2, 14, PALETTE["water_light"])
    return img


def draw_bone_golem() -> Image.Image:
    img = blank_character()
    cx = CHR_W // 2
    draw_shadow_oval(img, cx, CHR_H - 5, 11, 4)
    stone = PALETTE["stone_mid"]
    rect(img, cx - 11, 18, cx + 11, 40, stone)
    rect(img, cx - 9, 8, cx + 9, 18, stone.lighten(0.05))
    px(img, cx - 4, 12, PALETTE["lava_glow"])
    px(img, cx + 4, 12, PALETTE["lava_glow"])
    rect(img, cx - 13, 22, cx - 10, 34, stone.darken(0.1))
    rect(img, cx + 10, 22, cx + 13, 34, stone.darken(0.1))
    return img


def draw_witch() -> Image.Image:
    img = draw_mage()
    cx = CHR_W // 2
    for x in range(cx - 6, cx + 7):
        px(img, x, 8, RGB(34, 28, 30))
    px(img, cx + 10, 18, PALETTE["moss_sick"])
    return img


def draw_bandit() -> Image.Image:
    img = draw_rogue()
    cx = CHR_W // 2
    rect(img, cx - 7, 10, cx + 7, 13, PALETTE["cloth_mask"] if False else RGB(50, 40, 34))
    rect(img, cx - 10, 24, cx - 7, 30, PALETTE["wood_mid"])
    return img


def draw_royal_guard() -> Image.Image:
    img = draw_knight()
    cx = CHR_W // 2
    rect(img, cx - 8, 6, cx + 8, 9, PALETTE["brick_mid"])
    px(img, cx, 7, PALETTE["highlight"])
    return img


def draw_ghoul() -> Image.Image:
    img = draw_cultist()
    cx = CHR_W // 2
    for y in range(10, 20):
        for x in range(cx - 5, cx + 6):
            r, g, b, a = img.getpixel((x, y))
            if a > 0:
                img.putpixel((x, y), (*RGB(148, 156, 130).lerp(RGB(r, g, b), 0.3).as_tuple(), a))
    return img


def draw_crow_beast() -> Image.Image:
    img = blank_character()
    cx = CHR_W // 2
    draw_shadow_oval(img, cx, CHR_H - 4, 10, 3)
    dark = RGB(28, 26, 34)
    draw = ImageDraw.Draw(img)
    draw.polygon([(cx - 12, 20), (cx + 12, 20), (cx, 34)], fill=(*dark.as_tuple(), 255))
    draw.polygon([(cx - 4, 12), (cx + 4, 12), (cx, 22)], fill=(*dark.lighten(0.08).as_tuple(), 255))
    px(img, cx - 1, 15, PALETTE["lava_glow"])
    return img


def draw_death_knight() -> Image.Image:
    img = draw_revenant()
    cx = CHR_W // 2
    rect(img, cx - 8, 4, cx + 8, 8, PALETTE["iron_dark"])
    rect(img, cx + 9, 14, cx + 12, 40, PALETTE["iron_light"])
    return img


def draw_torchbearer() -> Image.Image:
    img = draw_cultist()
    cx = CHR_W // 2
    rect(img, cx + 9, 16, cx + 11, 34, PALETTE["wood_dark"])
    rect(img, cx + 8, 12, cx + 12, 18, PALETTE["lava_glow"])
    px(img, cx + 10, 10, PALETTE["highlight"])
    return img


def draw_grave_digger() -> Image.Image:
    img = draw_merchant()
    cx = CHR_W // 2
    rect(img, cx + 8, 14, cx + 12, 40, PALETTE["wood_mid"])
    rect(img, cx + 6, 12, cx + 14, 14, PALETTE["iron_mid"])
    return img


CHARACTER_DEFS: list[tuple[str, str, Callable[[], Image.Image]]] = [
    ("adventurer", "hero", draw_adventurer),
    ("knight", "hero", draw_knight),
    ("rogue", "hero", draw_rogue),
    ("mage", "hero", draw_mage),
    ("merchant", "npc", draw_merchant),
    ("priest", "npc", draw_priest),
    ("wounded_soldier", "npc", draw_wounded_soldier),
    ("hooded_stranger", "npc", draw_hooded_stranger),
    ("skeleton", "enemy", draw_skeleton),
    ("bone_archer", "enemy", draw_bone_archer),
    ("cultist", "enemy", draw_cultist),
    ("dark_hound", "enemy", draw_dark_hound),
    ("plague_rat", "enemy", draw_plague_rat),
    ("revenant", "enemy", draw_revenant),
    ("wraith", "enemy", draw_wraith),
    ("bone_golem", "enemy", draw_bone_golem),
    ("witch", "enemy", draw_witch),
    ("bandit", "enemy", draw_bandit),
    ("royal_guard", "npc", draw_royal_guard),
    ("ghoul", "enemy", draw_ghoul),
    ("crow_beast", "enemy", draw_crow_beast),
    ("death_knight", "enemy", draw_death_knight),
    ("torchbearer", "enemy", draw_torchbearer),
    ("grave_digger", "npc", draw_grave_digger),
]

assert len(CHARACTER_DEFS) == CHR_COLS * CHR_ROWS, (
    f"Expected {CHR_COLS * CHR_ROWS} character defs, got {len(CHARACTER_DEFS)}"
)


def draw_blade(img: Image.Image, vertical: bool = True) -> None:
    if vertical:
        rect(img, 7, 2, 8, 12, PALETTE["iron_light"])
        rect(img, 6, 12, 9, 14, PALETTE["wood_mid"])
    else:
        rect(img, 2, 7, 13, 8, PALETTE["iron_light"])
        rect(img, 13, 6, 15, 9, PALETTE["wood_mid"])


def draw_potion(img: Image.Image, liquid: RGB) -> None:
    draw = ImageDraw.Draw(img)
    draw.ellipse((4, 8, 11, 14), fill=(*liquid.as_tuple(), 255))
    rect(img, 6, 4, 9, 8, PALETTE["bone"])
    rect(img, 7, 3, 8, 5, PALETTE["bone_dark"])
    px(img, 5, 10, liquid.lighten(0.15))


def draw_key(img: Image.Image, color: RGB) -> None:
    rect(img, 4, 6, 6, 12, color)
    draw = ImageDraw.Draw(img)
    draw.ellipse((7, 4, 12, 9), outline=(*color.as_tuple(), 255), width=1)
    px(img, 10, 6, color.lighten(0.1))


def draw_item(name: str) -> Image.Image:
    img = blank_item()
    draw = ImageDraw.Draw(img)

    if name == "sword":
        draw_blade(img)
    elif name == "greatsword":
        rect(img, 6, 1, 9, 13, PALETTE["iron_mid"])
        rect(img, 5, 13, 10, 15, PALETTE["wood_dark"])
    elif name == "axe":
        rect(img, 7, 4, 8, 14, PALETTE["wood_mid"])
        draw.polygon([(9, 3), (14, 6), (9, 9)], fill=(*PALETTE["iron_mid"].as_tuple(), 255))
    elif name == "mace":
        rect(img, 7, 5, 8, 13, PALETTE["wood_dark"])
        draw.ellipse((4, 2, 11, 7), fill=(*PALETTE["iron_dark"].as_tuple(), 255))
    elif name == "war_hammer":
        rect(img, 7, 6, 8, 14, PALETTE["wood_mid"])
        rect(img, 4, 2, 11, 6, PALETTE["iron_mid"])
    elif name == "dagger":
        rect(img, 7, 4, 8, 11, PALETTE["iron_light"])
        rect(img, 6, 11, 9, 13, PALETTE["wood_dark"])
    elif name == "spear":
        rect(img, 7, 2, 8, 14, PALETTE["wood_mid"])
        draw.polygon([(5, 1), (10, 1), (7, 5)], fill=(*PALETTE["iron_light"].as_tuple(), 255))
    elif name == "flail":
        rect(img, 7, 6, 8, 14, PALETTE["wood_dark"])
        draw.ellipse((3, 2, 8, 7), fill=(*PALETTE["iron_mid"].as_tuple(), 255))
        px(img, 8, 5, PALETTE["iron_dark"])
    elif name == "bow":
        draw.arc((3, 3, 12, 13), 300, 60, fill=(*PALETTE["wood_mid"].as_tuple(), 255), width=1)
        draw.line((7, 4, 7, 12), fill=(*PALETTE["wood_dark"].as_tuple(), 255))
    elif name == "crossbow":
        rect(img, 2, 6, 13, 9, PALETTE["wood_mid"])
        rect(img, 6, 4, 9, 11, PALETTE["wood_dark"])
    elif name == "arrows":
        rect(img, 3, 7, 12, 8, PALETTE["wood_mid"])
        draw.polygon([(12, 6), (14, 8), (12, 10)], fill=(*PALETTE["iron_light"].as_tuple(), 255))
        px(img, 3, 7, PALETTE["bone"])
    elif name == "staff":
        rect(img, 7, 2, 8, 14, PALETTE["wood_dark"])
        px(img, 7, 2, PALETTE["water_light"])
    elif name == "wand":
        rect(img, 7, 5, 8, 14, PALETTE["wood_mid"])
        px(img, 7, 4, PALETTE["lava_glow"])
    elif name == "spell_tome":
        rect(img, 3, 4, 12, 12, PALETTE["brick_dark"])
        rect(img, 4, 5, 11, 11, RGB(58, 48, 72))
        px(img, 6, 7, PALETTE["highlight"])
    elif name == "throwing_knife":
        draw.polygon([(2, 8), (13, 7), (13, 9)], fill=(*PALETTE["iron_light"].as_tuple(), 255))
    elif name == "chakram":
        draw.ellipse((3, 3, 12, 12), outline=(*PALETTE["iron_light"].as_tuple(), 255), width=2)
    elif name == "health_potion":
        draw_potion(img, PALETTE["blood_mid"])
    elif name == "greater_health":
        draw_potion(img, PALETTE["blood_light"])
    elif name == "mana_potion":
        draw_potion(img, PALETTE["water_mid"])
    elif name == "stamina_potion":
        draw_potion(img, PALETTE["moss_sick"])
    elif name == "antidote":
        draw_potion(img, RGB(68, 120, 72))
    elif name == "food_ration":
        rect(img, 3, 6, 12, 11, PALETTE["wood_mid"])
        rect(img, 4, 5, 11, 6, PALETTE["wood_dark"])
    elif name == "bandage":
        rect(img, 4, 5, 11, 11, PALETTE["bone"])
        px(img, 5, 7, PALETTE["blood_dark"])
    elif name == "holy_water":
        draw_potion(img, PALETTE["water_light"])
        px(img, 6, 5, PALETTE["highlight"])
    elif name == "iron_key":
        draw_key(img, PALETTE["iron_mid"])
    elif name == "gold_key":
        draw_key(img, RGB(168, 140, 56))
    elif name == "skull_key":
        draw_key(img, PALETTE["bone"])
        px(img, 9, 5, PALETTE["void"])
    elif name == "ruby_gem":
        draw.polygon([(8, 3), (12, 8), (8, 13), (4, 8)], fill=(*PALETTE["blood_light"].as_tuple(), 255))
    elif name == "sapphire_gem":
        draw.polygon([(8, 3), (12, 8), (8, 13), (4, 8)], fill=(*PALETTE["water_light"].as_tuple(), 255))
    elif name == "gold_coins":
        draw.ellipse((3, 6, 8, 11), fill=(*RGB(168, 140, 56).as_tuple(), 255))
        draw.ellipse((7, 5, 12, 10), fill=(*RGB(188, 158, 64).as_tuple(), 255))
    elif name == "silver_coins":
        draw.ellipse((3, 6, 8, 11), fill=(*PALETTE["iron_light"].as_tuple(), 255))
        draw.ellipse((7, 5, 12, 10), fill=(*PALETTE["iron_mid"].as_tuple(), 255))
    elif name == "ancient_scroll":
        rect(img, 4, 4, 11, 12, PALETTE["bone"])
        px(img, 5, 6, PALETTE["wood_dark"])
        px(img, 6, 8, PALETTE["wood_dark"])
    elif name == "round_shield":
        draw.ellipse((3, 3, 12, 12), fill=(*PALETTE["iron_mid"].as_tuple(), 255))
        px(img, 7, 7, PALETTE["iron_dark"])
    elif name == "kite_shield":
        draw.polygon([(8, 2), (12, 5), (11, 13), (5, 13), (4, 5)], fill=(*PALETTE["iron_mid"].as_tuple(), 255))
    elif name == "helm":
        draw.ellipse((4, 4, 11, 10), fill=(*PALETTE["iron_mid"].as_tuple(), 255))
        px(img, 5, 7, PALETTE["void"])
        px(img, 10, 7, PALETTE["void"])
    elif name == "hood":
        draw.polygon([(3, 8), (12, 8), (10, 4), (5, 4)], fill=(*RGB(44, 40, 48).as_tuple(), 255))
    elif name == "cloak":
        draw.polygon([(8, 3), (13, 5), (12, 13), (4, 13), (3, 5)], fill=(*PALETTE["brick_dark"].as_tuple(), 255))
    elif name == "gauntlet":
        rect(img, 5, 5, 10, 11, PALETTE["iron_mid"])
        rect(img, 4, 9, 11, 12, PALETTE["iron_dark"])
    elif name == "boots":
        rect(img, 4, 8, 7, 12, PALETTE["wood_dark"])
        rect(img, 8, 8, 11, 12, PALETTE["wood_dark"])
    elif name == "ring":
        draw.ellipse((5, 6, 10, 11), outline=(*RGB(168, 140, 56).as_tuple(), 255), width=2)
    elif name == "torch":
        rect(img, 7, 6, 8, 13, PALETTE["wood_dark"])
        rect(img, 6, 3, 9, 7, PALETTE["lava_glow"])
    elif name == "bomb":
        draw.ellipse((4, 5, 11, 12), fill=(*PALETTE["iron_dark"].as_tuple(), 255))
        rect(img, 7, 3, 8, 5, PALETTE["wood_mid"])
    elif name == "rope":
        for y in range(3, 13):
            px(img, 7 + (y % 2), y, PALETTE["wood_mid"])
    elif name == "map":
        rect(img, 3, 4, 12, 11, PALETTE["bone"])
        px(img, 5, 6, PALETTE["water_mid"])
        px(img, 8, 8, PALETTE["moss"])
    elif name == "poison_vial":
        draw_potion(img, PALETTE["moss_sick"])
    elif name == "chalice":
        draw.polygon([(5, 10), (10, 10), (9, 5), (6, 5)], fill=(*PALETTE["iron_light"].as_tuple(), 255))
        rect(img, 7, 10, 8, 13, PALETTE["iron_mid"])
    elif name == "reliquary":
        rect(img, 5, 4, 10, 11, PALETTE["highlight"])
        rect(img, 6, 11, 9, 13, PALETTE["gold_trim"] if False else RGB(168, 140, 56))
    elif name == "soul_shard":
        draw.polygon([(8, 2), (12, 8), (8, 14), (4, 8)], fill=(*PALETTE["water_light"].as_tuple(), 255))
        px(img, 8, 8, PALETTE["void"])
    return img


ITEM_DEFS: list[tuple[str, str]] = [
    ("sword", "weapon_melee"),
    ("greatsword", "weapon_melee"),
    ("axe", "weapon_melee"),
    ("mace", "weapon_melee"),
    ("war_hammer", "weapon_melee"),
    ("dagger", "weapon_melee"),
    ("spear", "weapon_melee"),
    ("flail", "weapon_melee"),
    ("bow", "weapon_ranged"),
    ("crossbow", "weapon_ranged"),
    ("arrows", "weapon_ranged"),
    ("staff", "weapon_magic"),
    ("wand", "weapon_magic"),
    ("spell_tome", "weapon_magic"),
    ("throwing_knife", "weapon_ranged"),
    ("chakram", "weapon_ranged"),
    ("health_potion", "consumable"),
    ("greater_health", "consumable"),
    ("mana_potion", "consumable"),
    ("stamina_potion", "consumable"),
    ("antidote", "consumable"),
    ("food_ration", "consumable"),
    ("bandage", "consumable"),
    ("holy_water", "consumable"),
    ("iron_key", "key"),
    ("gold_key", "key"),
    ("skull_key", "key"),
    ("ruby_gem", "treasure"),
    ("sapphire_gem", "treasure"),
    ("gold_coins", "treasure"),
    ("silver_coins", "treasure"),
    ("ancient_scroll", "quest"),
    ("round_shield", "armor"),
    ("kite_shield", "armor"),
    ("helm", "armor"),
    ("hood", "armor"),
    ("cloak", "armor"),
    ("gauntlet", "armor"),
    ("boots", "armor"),
    ("ring", "accessory"),
    ("torch", "tool"),
    ("bomb", "tool"),
    ("rope", "tool"),
    ("map", "tool"),
    ("poison_vial", "consumable"),
    ("chalice", "quest"),
    ("reliquary", "quest"),
    ("soul_shard", "treasure"),
]

assert len(ITEM_DEFS) == ITEM_COLS * ITEM_ROWS, (
    f"Expected {ITEM_COLS * ITEM_ROWS} item defs, got {len(ITEM_DEFS)}"
)


def build_atlas(
    entries: list,
    frame_w: int,
    frame_h: int,
    cols: int,
    rows: int,
    draw_fn: Callable[[str], Image.Image] | None,
    *,
    character_mode: bool,
) -> tuple[Image.Image, dict]:
    atlas = Image.new("RGBA", (cols * frame_w, rows * frame_h), (0, 0, 0, 0))
    sprites: list[dict] = []
    categories: dict[str, list[int]] = {}

    for index, entry in enumerate(entries):
        col = index % cols
        row = index // cols
        if character_mode:
            name, category, fn = entry
            sprite = fn()
        else:
            name, category = entry
            sprite = draw_fn(name) if draw_fn else blank_item()

        atlas.paste(sprite, (col * frame_w, row * frame_h), sprite)
        sprites.append(
            {
                "id": index,
                "name": name,
                "category": category,
                "column": col,
                "row": row,
                "x": col * frame_w,
                "y": row * frame_h,
                "width": frame_w,
                "height": frame_h,
            }
        )
        categories.setdefault(category, []).append(index)

    manifest = {
        "version": 1,
        "frame_width": frame_w,
        "frame_height": frame_h,
        "columns": cols,
        "rows": rows,
        "sprite_count": len(entries),
        "categories": categories,
        "sprites": sprites,
    }
    return atlas, manifest


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    char_atlas, char_meta = build_atlas(
        CHARACTER_DEFS[: CHR_COLS * CHR_ROWS],
        CHR_W,
        CHR_H,
        CHR_COLS,
        CHR_ROWS,
        None,
        character_mode=True,
    )
    char_meta["name"] = "grim_dark_characters"
    char_meta["theme"] = "grim_dark_fantasy"
    char_meta["atlas"] = {
        "path": "sprites/grim_characters.png",
        "sprite_asset_id": "grim_characters",
        "width": CHR_COLS * CHR_W,
        "height": CHR_ROWS * CHR_H,
    }

    item_atlas, item_meta = build_atlas(
        ITEM_DEFS[: ITEM_COLS * ITEM_ROWS],
        ITEM_SIZE,
        ITEM_SIZE,
        ITEM_COLS,
        ITEM_ROWS,
        draw_item,
        character_mode=False,
    )
    item_meta["name"] = "grim_dark_items"
    item_meta["theme"] = "grim_dark_fantasy"
    item_meta["atlas"] = {
        "path": "sprites/grim_items.png",
        "sprite_asset_id": "grim_items",
        "width": ITEM_COLS * ITEM_SIZE,
        "height": ITEM_ROWS * ITEM_SIZE,
    }

    char_png = OUT_DIR / "grim_characters.png"
    char_json = OUT_DIR / "grim_characters.json"
    item_png = OUT_DIR / "grim_items.png"
    item_json = OUT_DIR / "grim_items.json"

    char_atlas.save(char_png, optimize=True)
    item_atlas.save(item_png, optimize=True)
    char_json.write_text(json.dumps(char_meta, indent=2) + "\n", encoding="utf-8")
    item_json.write_text(json.dumps(item_meta, indent=2) + "\n", encoding="utf-8")

    print(f"Wrote {char_png} ({char_atlas.size[0]}x{char_atlas.size[1]}, {char_meta['sprite_count']} sprites)")
    print(f"Wrote {item_png} ({item_atlas.size[0]}x{item_atlas.size[1]}, {item_meta['sprite_count']} sprites)")


if __name__ == "__main__":
    main()