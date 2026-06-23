"""Shared constants and helpers for world tileset generation."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw

TILE = 32
COLS = 16
ROWS = 14
OUT_DIR = Path(__file__).resolve().parent.parent / "assets" / "sprites"


@dataclass(frozen=True)
class RGB:
    r: int
    g: int
    b: int

    def as_tuple(self) -> tuple[int, int, int]:
        return (self.r, self.g, self.b)

    def lerp(self, other: RGB, t: float) -> RGB:
        return RGB(
            int(self.r + (other.r - self.r) * t),
            int(self.g + (other.g - self.g) * t),
            int(self.b + (other.b - self.b) * t),
        )

    def darken(self, amount: float) -> RGB:
        return self.lerp(RGB(0, 0, 0), amount)

    def lighten(self, amount: float) -> RGB:
        return self.lerp(RGB(255, 255, 255), amount)


PALETTE = {
    "void": RGB(10, 8, 14),
    "grass_dark": RGB(30, 40, 26),
    "grass_mid": RGB(46, 56, 34),
    "grass_light": RGB(60, 72, 44),
    "grass_dead": RGB(54, 48, 32),
    "dirt_dark": RGB(36, 28, 22),
    "dirt_mid": RGB(56, 44, 32),
    "dirt_light": RGB(76, 60, 42),
    "mud_dark": RGB(30, 26, 20),
    "mud_mid": RGB(44, 38, 28),
    "stone_dark": RGB(40, 40, 44),
    "stone_mid": RGB(60, 60, 66),
    "stone_light": RGB(80, 80, 86),
    "cobble_dark": RGB(46, 44, 50),
    "cobble_mid": RGB(66, 64, 70),
    "cobble_light": RGB(86, 84, 90),
    "crack": RGB(22, 20, 26),
    "moss": RGB(50, 60, 38),
    "moss_sick": RGB(66, 76, 40),
    "ash_dark": RGB(34, 34, 38),
    "ash_mid": RGB(52, 52, 56),
    "wood_dark": RGB(42, 32, 24),
    "wood_mid": RGB(62, 48, 34),
    "wood_light": RGB(82, 66, 48),
    "blood_dark": RGB(54, 14, 16),
    "blood_mid": RGB(88, 26, 30),
    "blood_light": RGB(116, 38, 42),
    "water_deep": RGB(14, 26, 44),
    "water_mid": RGB(26, 40, 60),
    "water_light": RGB(40, 58, 78),
    "swamp_dark": RGB(22, 30, 24),
    "swamp_mid": RGB(34, 46, 32),
    "sludge_dark": RGB(26, 36, 20),
    "sludge_mid": RGB(42, 56, 28),
    "lava_dark": RGB(44, 16, 6),
    "lava_mid": RGB(84, 30, 10),
    "lava_glow": RGB(136, 56, 16),
    "bone": RGB(136, 128, 116),
    "bone_dark": RGB(96, 90, 82),
    "iron_dark": RGB(50, 52, 58),
    "iron_mid": RGB(76, 78, 86),
    "iron_light": RGB(102, 104, 112),
    "brick_dark": RGB(50, 30, 26),
    "brick_mid": RGB(76, 46, 38),
    "brick_light": RGB(96, 60, 50),
    "fog": RGB(56, 52, 60),
    "sand_dark": RGB(60, 54, 42),
    "sand_mid": RGB(82, 74, 56),
    "highlight": RGB(176, 168, 148),
    "shadow": RGB(12, 10, 14),
}


def set_px(img: Image.Image, x: int, y: int, color: RGB, alpha: int = 255) -> None:
    if 0 <= x < TILE and 0 <= y < TILE:
        img.putpixel((x, y), (*color.as_tuple(), alpha))


def fill_rect(img: Image.Image, x0: int, y0: int, x1: int, y1: int, color: RGB) -> None:
    draw = ImageDraw.Draw(img)
    draw.rectangle((x0, y0, x1, y1), fill=(*color.as_tuple(), 255))