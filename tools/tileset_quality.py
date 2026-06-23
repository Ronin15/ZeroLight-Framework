"""High-quality pixel-art rendering helpers for the world tileset generator."""

from __future__ import annotations

import math
import random
from typing import Callable

from PIL import Image, ImageDraw

from tileset_common import PALETTE, RGB, TILE, fill_rect, set_px

BAYER_4 = (
    (0, 8, 2, 10),
    (12, 4, 14, 6),
    (3, 11, 1, 9),
    (15, 7, 13, 5),
)

GRASS_TUFTS = (
    ((0, 0), (0, 1), (1, 0)),
    ((0, 0), (0, 1), (1, 1), (2, 0)),
    ((0, 1), (1, 0), (1, 1)),
    ((0, 0), (1, 0), (2, 0), (1, 1)),
)

TRANSITION_MASKS: list[dict[str, bool]] = [
    {},
    {"north": True},
    {"south": True},
    {"east": True},
    {"west": True},
    {"nw": True},
    {"ne": True},
    {"sw": True},
    {"se": True},
    {"north": True, "south": True},
    {"east": True, "west": True},
    {"inner": True},
    {"north": True, "inner": True},
    {"south": True, "inner": True},
    {"east": True, "inner": True},
    {"west": True, "inner": True},
]


def bayer_threshold(x: int, y: int, t: float) -> bool:
    return (BAYER_4[x % 4][y % 4] / 16.0) < t


def dither_surface(
    img: Image.Image,
    dark: RGB,
    mid: RGB,
    light: RGB,
    seed: int,
    *,
    warp: float = 0.18,
) -> None:
    rng = random.Random(seed)
    for y in range(TILE):
        for x in range(TILE):
            wave = math.sin((x + seed % 7) * 0.55) * math.cos((y + seed % 5) * 0.45)
            t = 0.42 + wave * warp + (rng.random() - 0.5) * 0.08
            if bayer_threshold(x, y, t):
                color = light if t > 0.58 else mid if t > 0.38 else dark
            else:
                color = mid if t > 0.5 else dark
            set_px(img, x, y, color)


def harmonize_edges(img: Image.Image, seed: int) -> None:
    """Nudge opposite edges toward similar tones so tiles repeat more cleanly."""
    rng = random.Random(seed)
    for x in range(TILE):
        top = img.getpixel((x, 0))
        bottom = img.getpixel((x, TILE - 1))
        blend = (
            (top[0] + bottom[0]) // 2,
            (top[1] + bottom[1]) // 2,
            (top[2] + bottom[2]) // 2,
            255,
        )
        if rng.random() < 0.65:
            img.putpixel((x, 0), blend)
            img.putpixel((x, TILE - 1), blend)
    for y in range(TILE):
        left = img.getpixel((0, y))
        right = img.getpixel((TILE - 1, y))
        blend = (
            (left[0] + right[0]) // 2,
            (left[1] + right[1]) // 2,
            (left[2] + right[2]) // 2,
            255,
        )
        if rng.random() < 0.65:
            img.putpixel((0, y), blend)
            img.putpixel((TILE - 1, y), blend)


def vignette(img: Image.Image, strength: float = 0.12) -> None:
    cx, cy = (TILE - 1) / 2, (TILE - 1) / 2
    max_d = math.hypot(cx, cy)
    for y in range(TILE):
        for x in range(TILE):
            d = math.hypot(x - cx, y - cy) / max_d
            if d <= 0.55:
                continue
            r, g, b, a = img.getpixel((x, y))
            shade = 1.0 - (d - 0.55) * strength
            set_px(img, x, y, RGB(int(r * shade), int(g * shade), int(b * shade)), a)


def draw_grass_tuft(img: Image.Image, ox: int, oy: int, tone: RGB, shadow: RGB) -> None:
    pattern = GRASS_TUFTS[(ox + oy) % len(GRASS_TUFTS)]
    for dx, dy in pattern:
        set_px(img, ox + dx, oy + dy, tone)
    set_px(img, ox, oy + 1, shadow)


def draw_pebble(img: Image.Image, cx: int, cy: int, radius: int, seed: int) -> None:
    rng = random.Random(seed)
    base = PALETTE["stone_mid"].lerp(PALETTE["stone_dark"], rng.random() * 0.35)
    hi = base.lighten(0.18)
    lo = base.darken(0.2)
    for y in range(cy - radius, cy + radius + 1):
        for x in range(cx - radius, cx + radius + 1):
            if (x - cx) ** 2 + (y - cy) ** 2 <= radius * radius:
                if x <= cx and y <= cy:
                    set_px(img, x, y, hi)
                elif x >= cx and y >= cy:
                    set_px(img, x, y, lo)
                else:
                    set_px(img, x, y, base)


def draw_cracks(img: Image.Image, seed: int, color: RGB | None = None) -> None:
    crack = color or PALETTE["crack"]
    rng = random.Random(seed)
    x, y = rng.randint(5, TILE - 6), rng.randint(5, TILE - 6)
    length = rng.randint(8, 16)
    dx, dy = rng.choice([(1, 0), (0, 1), (1, 1), (1, -1)])
    for step in range(length):
        set_px(img, x, y, crack)
        if step % 3 == 0 and 0 <= x + dy < TILE and 0 <= y + dx < TILE:
            set_px(img, x + dy, y + dx, crack.darken(0.15))
        x += dx
        y += dy
        if not (0 <= x < TILE and 0 <= y < TILE):
            break
        if rng.random() < 0.2:
            dx, dy = dy, dx


def draw_blood_splatter(img: Image.Image, seed: int) -> None:
    rng = random.Random(seed)
    for _ in range(rng.randint(2, 4)):
        cx, cy = rng.randint(8, 24), rng.randint(8, 24)
        for _ in range(rng.randint(10, 18)):
            x = cx + rng.randint(-4, 4)
            y = cy + rng.randint(-4, 4)
            color = PALETTE["blood_mid"] if rng.random() < 0.55 else PALETTE["blood_dark"]
            set_px(img, x, y, color)
            if rng.random() < 0.35:
                set_px(img, x + 1, y, color.darken(0.12))


def draw_bones(img: Image.Image, seed: int) -> None:
    rng = random.Random(seed)
    x = rng.randint(8, 18)
    y = rng.randint(20, 26)
    for i in range(7):
        set_px(img, x + i, y, PALETTE["bone"])
        if i % 2 == 0:
            set_px(img, x + i, y - 1, PALETTE["bone_dark"])
    sx, sy = x + 2, y - 6
    for dx in range(5):
        for dy in range(4):
            set_px(img, sx + dx, sy + dy, PALETTE["bone"])
    set_px(img, sx + 1, sy + 2, PALETTE["shadow"])
    set_px(img, sx + 3, sy + 2, PALETTE["shadow"])
    set_px(img, sx + 2, sy + 1, PALETTE["bone_dark"])


def draw_moss_cluster(img: Image.Image, seed: int) -> None:
    rng = random.Random(seed)
    cx, cy = rng.randint(8, 22), rng.randint(8, 22)
    for _ in range(24):
        x = cx + rng.randint(-5, 5)
        y = cy + rng.randint(-4, 4)
        if 0 <= x < TILE and 0 <= y < TILE:
            color = PALETTE["moss_sick"] if rng.random() < 0.35 else PALETTE["moss"]
            set_px(img, x, y, color)
            if rng.random() < 0.25 and y + 1 < TILE:
                set_px(img, x, y + 1, color.darken(0.2))


def draw_rock(img: Image.Image, cx: int, cy: int, size: int) -> None:
    draw = ImageDraw.Draw(img)
    outer = PALETTE["stone_mid"]
    inner = PALETTE["stone_light"]
    shade = PALETTE["stone_dark"]
    draw.ellipse((cx - size, cy - size + 1, cx + size - 1, cy + size - 2), fill=(*shade.as_tuple(), 255))
    draw.ellipse((cx - size + 1, cy - size, cx + size - 2, cy + size - 3), fill=(*outer.as_tuple(), 255))
    if size >= 3:
        draw.ellipse((cx - size + 2, cy - size + 1, cx + 1, cy - 1), fill=(*inner.as_tuple(), 255))
    draw.line((cx - size + 1, cy + size - 2, cx + size - 2, cy + size - 2), fill=(*shade.darken(0.1).as_tuple(), 255))


def transition_weight(x: int, y: int, flags: dict[str, bool]) -> float:
    if not flags:
        return 0.0
    wx = 0.0
    wy = 0.0
    if flags.get("west") or flags.get("nw") or flags.get("sw"):
        wx = max(wx, 1.0 - x / 11.0)
    if flags.get("east") or flags.get("ne") or flags.get("se"):
        wx = max(wx, 1.0 - (TILE - 1 - x) / 11.0)
    if flags.get("north") or flags.get("nw") or flags.get("ne"):
        wy = max(wy, 1.0 - y / 11.0)
    if flags.get("south") or flags.get("sw") or flags.get("se"):
        wy = max(wy, 1.0 - (TILE - 1 - y) / 11.0)
    if flags.get("inner"):
        ix = min(x, TILE - 1 - x)
        iy = min(y, TILE - 1 - y)
        inner = min(ix, iy)
        if inner < 11:
            return max(1.0 - inner / 11.0, wx, wy)
    return max(wx, wy)


def blend_layers(base: Image.Image, overlay: Image.Image, mask_fn: Callable[[int, int], float]) -> Image.Image:
    out = base.copy()
    for y in range(TILE):
        for x in range(TILE):
            t = mask_fn(x, y)
            if t <= 0:
                continue
            if t >= 1 or not bayer_threshold(x, y, t):
                out.putpixel((x, y), overlay.getpixel((x, y)))
    return out


def make_grass(seed: int, *, dead: bool = False, rocky: bool = False, bones: bool = False) -> Image.Image:
    img = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    if dead:
        dither_surface(img, PALETTE["grass_dead"], PALETTE["dirt_mid"], PALETTE["grass_mid"], seed, warp=0.14)
    else:
        dither_surface(img, PALETTE["grass_dark"], PALETTE["grass_mid"], PALETTE["grass_light"], seed, warp=0.16)

    rng = random.Random(seed + 11)
    tuft_color = PALETTE["grass_dead"] if dead else PALETTE["grass_light"]
    shadow = PALETTE["grass_dark"] if not dead else PALETTE["dirt_dark"]
    for _ in range(rng.randint(10, 16)):
        draw_grass_tuft(img, rng.randint(1, TILE - 4), rng.randint(1, TILE - 4), tuft_color, shadow)

    if not dead:
        for _ in range(4):
            set_px(img, rng.randrange(TILE), rng.randrange(TILE), PALETTE["moss"].darken(0.15))

    if rocky:
        for i in range(4):
            draw_pebble(img, (seed * 5 + i * 9) % 24 + 4, (seed * 3 + i * 7) % 22 + 5, 2, seed + i)

    if bones:
        draw_bones(img, seed + 99)

    harmonize_edges(img, seed)
    vignette(img, 0.08)
    return img


def make_dirt(seed: int, *, wet: bool = False) -> Image.Image:
    img = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    if wet:
        dither_surface(img, PALETTE["mud_dark"], PALETTE["mud_mid"], PALETTE["dirt_mid"], seed, warp=0.15)
        rng = random.Random(seed)
        for _ in range(8):
            x, y = rng.randrange(TILE), rng.randrange(TILE)
            set_px(img, x, y, PALETTE["water_deep"].lerp(PALETTE["mud_mid"], 0.4))
    else:
        dither_surface(img, PALETTE["dirt_dark"], PALETTE["dirt_mid"], PALETTE["dirt_light"], seed, warp=0.17)
        rng = random.Random(seed + 3)
        for _ in range(6):
            draw_pebble(img, rng.randint(2, TILE - 3), rng.randint(2, TILE - 3), 1, seed + rng.randint(0, 99))

    harmonize_edges(img, seed + 1)
    vignette(img, 0.06)
    return img


def make_stone(seed: int, *, cobble: bool = False, cracked: bool = False, mossy: bool = False) -> Image.Image:
    img = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    if cobble:
        dither_surface(img, PALETTE["cobble_dark"], PALETTE["cobble_mid"], PALETTE["cobble_light"], seed, warp=0.1)
        rng = random.Random(seed)
        for row in range(4):
            for col in range(4):
                cx = col * 8 + 4 + (row % 2) * 2
                cy = row * 8 + 4
                radius = 3 if rng.random() < 0.7 else 2
                draw_pebble(img, cx, cy, radius, seed + row * 4 + col)
        draw = ImageDraw.Draw(img)
        for y in range(0, TILE, 8):
            draw.line((0, y, TILE - 1, y), fill=(*PALETTE["crack"].as_tuple(), 255))
    else:
        dither_surface(img, PALETTE["stone_dark"], PALETTE["stone_mid"], PALETTE["stone_light"], seed, warp=0.13)
        rng = random.Random(seed + 1)
        for _ in range(5):
            draw_pebble(img, rng.randint(3, TILE - 4), rng.randint(3, TILE - 4), 1, seed + rng.randint(0, 50))

    if cracked:
        draw_cracks(img, seed + 10)
        if seed % 2 == 0:
            draw_cracks(img, seed + 20, PALETTE["stone_dark"])
    if mossy:
        draw_moss_cluster(img, seed + 30)

    harmonize_edges(img, seed + 2)
    vignette(img, 0.07)
    return img


def make_wood_planks(seed: int) -> Image.Image:
    img = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    dither_surface(img, PALETTE["wood_dark"], PALETTE["wood_mid"], PALETTE["wood_light"], seed, warp=0.08)
    draw = ImageDraw.Draw(img)
    for row, y in enumerate(range(0, TILE, 8)):
        tone = PALETTE["wood_mid"] if row % 2 == 0 else PALETTE["wood_light"].darken(0.12)
        draw.rectangle((0, y + 1, TILE - 1, y + 6), fill=(*tone.as_tuple(), 255))
        draw.line((0, y, TILE - 1, y), fill=(*PALETTE["wood_dark"].as_tuple(), 255))
        draw.line((0, y + 7, TILE - 1, y + 7), fill=(*PALETTE["wood_dark"].darken(0.1).as_tuple(), 255))
        if seed % 4 == row % 4:
            draw.line((4, y + 2, TILE - 5, y + 2), fill=(*PALETTE["wood_dark"].lerp(tone, 0.4).as_tuple(), 255))
    if seed % 3 == 0:
        draw_cracks(img, seed + 3, PALETTE["wood_dark"])
    return img


def make_blood_floor(seed: int) -> Image.Image:
    img = make_stone(seed, cracked=True)
    draw_blood_splatter(img, seed + 7)
    return img


def make_ash(seed: int) -> Image.Image:
    img = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    dither_surface(img, PALETTE["ash_dark"], PALETTE["ash_mid"], PALETTE["stone_light"].darken(0.25), seed, warp=0.12)
    rng = random.Random(seed)
    for _ in range(10):
        x, y = rng.randrange(TILE), rng.randrange(TILE)
        set_px(img, x, y, PALETTE["void"].lerp(PALETTE["ash_mid"], 0.5))
    return img


def make_sand(seed: int) -> Image.Image:
    img = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    dither_surface(img, PALETTE["sand_dark"], PALETTE["sand_mid"], PALETTE["sand_mid"].lighten(0.08), seed, warp=0.14)
    return img


def make_void() -> Image.Image:
    img = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    fill_rect(img, 0, 0, TILE - 1, TILE - 1, PALETTE["void"])
    rng = random.Random(7)
    for _ in range(8):
        x, y = rng.randrange(TILE), rng.randrange(TILE)
        set_px(img, x, y, PALETTE["fog"].darken(0.35))
    return img


def make_water(frame: int) -> Image.Image:
    img = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    dither_surface(img, PALETTE["water_deep"], PALETTE["water_mid"], PALETTE["water_light"], frame * 17 + 3, warp=0.2)
    draw = ImageDraw.Draw(img)
    offset = frame * 2
    for i, y in enumerate(range(4, TILE, 7)):
        y2 = (y + offset) % (TILE - 2) + 1
        alpha = 200 if i % 2 == 0 else 150
        color = PALETTE["water_light"] if i % 2 == 0 else PALETTE["water_mid"].lighten(0.1)
        draw.arc((-4, y2 - 2, TILE + 3, y2 + 5), 0, 180, fill=(*color.as_tuple(), alpha))
    rng = random.Random(frame + 90)
    for _ in range(5):
        set_px(img, rng.randrange(TILE), rng.randrange(TILE), PALETTE["water_light"].lighten(0.05))
    return img


def make_swamp(seed: int) -> Image.Image:
    img = make_water(0)
    overlay = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    dither_surface(overlay, PALETTE["swamp_dark"], PALETTE["swamp_mid"], PALETTE["moss"].darken(0.1), seed, warp=0.16)
    img = Image.alpha_composite(img, overlay)
    draw_moss_cluster(img, seed + 4)
    return img


def make_sludge(seed: int) -> Image.Image:
    img = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    dither_surface(img, PALETTE["sludge_dark"], PALETTE["sludge_mid"], PALETTE["moss_sick"], seed, warp=0.18)
    rng = random.Random(seed)
    for _ in range(12):
        set_px(img, rng.randrange(TILE), rng.randrange(TILE), PALETTE["moss_sick"].darken(0.1))
    return img


def make_blood_pool(seed: int) -> Image.Image:
    img = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    dither_surface(img, PALETTE["blood_dark"], PALETTE["blood_mid"], PALETTE["blood_light"], seed, warp=0.15)
    draw_blood_splatter(img, seed + 8)
    return img


def make_lava(seed: int) -> Image.Image:
    img = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    dither_surface(img, PALETTE["lava_dark"], PALETTE["lava_mid"], PALETTE["lava_glow"], seed, warp=0.22)
    draw_cracks(img, seed, PALETTE["lava_glow"])
    rng = random.Random(seed)
    for _ in range(10):
        x, y = rng.randrange(4, TILE - 4), rng.randrange(4, TILE - 4)
        set_px(img, x, y, PALETTE["highlight"].lerp(PALETTE["lava_glow"], 0.5))
    return img


def make_fog(seed: int) -> Image.Image:
    base = make_grass(seed, dead=True)
    overlay = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    dither_surface(overlay, PALETTE["fog"], PALETTE["fog"].lighten(0.08), PALETTE["highlight"], seed + 30, warp=0.1)
    return Image.alpha_composite(base, overlay)


def make_grass_dirt_transition(mask_id: int) -> Image.Image:
    grass = make_grass(mask_id)
    dirt = make_dirt(mask_id + 40)
    flags = TRANSITION_MASKS[mask_id % len(TRANSITION_MASKS)]
    return blend_layers(grass, dirt, lambda x, y: transition_weight(x, y, flags))


def make_water_shore(mask_id: int) -> Image.Image:
    water = make_water(0)
    land = make_grass(mask_id + 7, dead=True)
    flags = TRANSITION_MASKS[mask_id % len(TRANSITION_MASKS)]
    shore = blend_layers(water, land, lambda x, y: transition_weight(x, y, flags))
    foam = PALETTE["water_light"].lerp(PALETTE["sand_mid"], 0.25)
    for y in range(TILE):
        for x in range(TILE):
            w = transition_weight(x, y, flags)
            if 0.35 < w < 0.85 and bayer_threshold(x, y, w):
                set_px(shore, x, y, foam)
    return shore


def make_cliff_tile(kind: int) -> Image.Image:
    img = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    top = make_grass(90 + kind)
    face = PALETTE["stone_dark"]
    edge = PALETTE["stone_mid"]
    highlight = PALETTE["stone_light"]

    if kind == 0:
        img.paste(top, (0, 0))
        for y in range(18, TILE):
            for x in range(TILE):
                t = (y - 18) / 14
                color = face.lerp(edge, t * 0.6)
                set_px(img, x, y, color)
        draw = ImageDraw.Draw(img)
        for x in range(0, TILE, 5):
            draw.line((x, 20, x + 2, TILE - 1), fill=(*highlight.darken(0.2).as_tuple(), 255))
    elif kind == 1:
        dither_surface(img, face, edge, highlight, 91, warp=0.1)
        fill_rect(img, 0, 0, TILE - 1, 4, edge.lighten(0.05))
    elif kind == 2:
        dither_surface(img, face.darken(0.08), edge, face, 92, warp=0.1)
        fill_rect(img, 0, TILE - 5, TILE - 1, TILE - 1, face.darken(0.2))
    elif kind == 3:
        dither_surface(img, face, edge, highlight, 93, warp=0.1)
        fill_rect(img, TILE - 5, 0, TILE - 1, TILE - 1, edge)
    elif kind == 4:
        dither_surface(img, face.darken(0.05), edge, highlight, 94, warp=0.1)
        fill_rect(img, 0, 0, 4, TILE - 1, edge.lighten(0.04))
    elif kind == 5:
        dither_surface(img, face, edge, highlight, 95, warp=0.12)
        for y in range(14):
            for x in range(16, TILE):
                img.putpixel((x, y), top.getpixel((x, y)))
        draw_cracks(img, 95)
    elif kind == 6:
        dither_surface(img, face, edge, highlight, 96, warp=0.12)
        for y in range(14):
            for x in range(16):
                img.putpixel((x, y), top.getpixel((x, y)))
    elif kind == 7:
        img.paste(top, (0, 0))
        for y in range(12, TILE):
            for x in range(12, TILE):
                set_px(img, x, y, edge if (x + y) % 3 else face)
    else:
        dither_surface(img, face, edge, highlight, 96 + kind, warp=0.14)
        draw_cracks(img, 96 + kind)
    return img


def make_brick_wall(kind: int) -> Image.Image:
    img = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    mortar = PALETTE["stone_dark"]
    fill_rect(img, 0, 0, TILE - 1, TILE - 1, mortar)
    draw = ImageDraw.Draw(img)
    row = 0
    for y in range(0, TILE, 8):
        offset = 0 if row % 2 == 0 else 8
        for x in range(-8 + offset, TILE, 16):
            base = PALETTE["brick_mid"] if (x + y + kind) % 9 < 5 else PALETTE["brick_dark"]
            draw.rectangle((x + 1, y + 1, x + 13, y + 5), fill=(*base.as_tuple(), 255))
            draw.rectangle((x + 1, y + 1, x + 13, y + 2), fill=(*base.lighten(0.08).as_tuple(), 255))
            draw.point((x + 13, y + 5), fill=(*base.darken(0.15).as_tuple(), 255))
        row += 1
    if kind % 4 == 1:
        fill_rect(img, 0, 0, TILE - 1, 6, PALETTE["void"])
    if kind % 4 == 2:
        fill_rect(img, 0, TILE - 6, TILE - 1, TILE - 1, PALETTE["void"])
    if kind % 4 == 3:
        draw_moss_cluster(img, kind + 5)
    return img


def make_decoration(kind: int) -> Image.Image:
    img = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    floor = make_grass(kind, dead=True)
    img.paste(floor, (0, 0))
    variant = kind % 16

    if variant == 0:
        draw_rock(img, 16, 21, 4)
    elif variant == 1:
        draw_rock(img, 16, 19, 7)
        draw_cracks(img, kind)
    elif variant == 2:
        draw_bones(img, kind)
    elif variant == 3:
        draw_bones(img, kind)
        draw_bones(img, kind + 50)
    elif variant == 4:
        fill_rect(img, 12, 17, 20, 27, PALETTE["wood_dark"])
        fill_rect(img, 10, 14, 22, 17, PALETTE["wood_mid"])
        for x in range(11, 22, 2):
            fill_rect(img, x, 15, x, 16, PALETTE["wood_dark"])
    elif variant == 5:
        fill_rect(img, 13, 8, 19, 28, PALETTE["stone_mid"])
        fill_rect(img, 11, 6, 21, 10, PALETTE["stone_light"])
        draw_cracks(img, kind)
    elif variant == 6:
        fill_rect(img, 12, 10, 20, 27, PALETTE["stone_mid"].darken(0.08))
        fill_rect(img, 13, 8, 19, 12, PALETTE["stone_light"])
        set_px(img, 15, 14, PALETTE["shadow"])
        set_px(img, 17, 14, PALETTE["shadow"])
    elif variant == 7:
        for x in range(6, 26, 5):
            fill_rect(img, x, 6, x + 2, 27, PALETTE["iron_mid"])
            fill_rect(img, x, 6, x, 27, PALETTE["iron_light"])
        fill_rect(img, 4, 8, 27, 10, PALETTE["iron_dark"])
    elif variant == 8:
        fill_rect(img, 4, 4, 8, 28, PALETTE["wood_dark"])
        fill_rect(img, 14, 12, 18, 21, PALETTE["wood_mid"])
        fill_rect(img, 15, 7, 17, 12, PALETTE["lava_glow"])
        set_px(img, 16, 6, PALETTE["highlight"])
        set_px(img, 15, 8, PALETTE["lava_mid"])
    elif variant == 9:
        fill_rect(img, 8, 16, 24, 27, PALETTE["wood_dark"])
        fill_rect(img, 8, 13, 24, 17, PALETTE["wood_mid"])
        fill_rect(img, 14, 18, 18, 21, PALETTE["iron_dark"])
        draw = ImageDraw.Draw(img)
        draw.arc((13, 12, 19, 18), 180, 360, fill=(*PALETTE["wood_light"].as_tuple(), 255))
    elif variant == 10:
        draw = ImageDraw.Draw(img)
        draw.ellipse((10, 12, 22, 27), fill=(*PALETTE["wood_mid"].as_tuple(), 255))
        draw.arc((10, 12, 22, 20), 180, 360, fill=(*PALETTE["wood_light"].as_tuple(), 255))
        fill_rect(img, 10, 12, 22, 14, PALETTE["iron_dark"])
        fill_rect(img, 10, 25, 22, 27, PALETTE["iron_dark"])
    elif variant == 11:
        fill_rect(img, 15, 20, 17, 27, PALETTE["bone"])
        draw = ImageDraw.Draw(img)
        draw.ellipse((9, 11, 23, 19), fill=(*PALETTE["moss_sick"].as_tuple(), 255))
        set_px(img, 12, 13, PALETTE["sludge_mid"])
        set_px(img, 20, 14, PALETTE["sludge_mid"])
    elif variant == 12:
        rng = random.Random(kind)
        for _ in range(9):
            x = rng.randint(8, 22)
            h = rng.randint(4, 8)
            fill_rect(img, x, 27 - h, x + 1, 27, PALETTE["grass_dead"])
    elif variant == 13:
        draw_rock(img, 10, 22, 3)
        draw_rock(img, 21, 24, 4)
        draw_rock(img, 15, 20, 2)
    elif variant == 14:
        fill_rect(img, 8, 20, 25, 22, PALETTE["iron_light"])
        fill_rect(img, 21, 13, 23, 22, PALETTE["iron_mid"])
        fill_rect(img, 6, 20, 10, 25, PALETTE["wood_dark"])
    else:
        fill_rect(img, 6, 18, 26, 28, PALETTE["iron_dark"])
        for x in range(8, 26, 3):
            fill_rect(img, x, 18, x, 28, PALETTE["void"])
        for y in range(18, 28, 3):
            fill_rect(img, 6, y, 26, y, PALETTE["void"])
    return img


def make_path_tile(mask_id: int) -> Image.Image:
    base = make_dirt(200 + mask_id)
    worn = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    dither_surface(worn, PALETTE["dirt_mid"], PALETTE["dirt_light"], PALETTE["dirt_light"].lighten(0.06), mask_id, warp=0.08)
    flags: dict[str, bool] = {}
    if mask_id == 0:
        flags = {"east": True, "west": True}
    elif mask_id == 1:
        flags = {"north": True, "south": True}
    elif mask_id in {2, 3}:
        flags = {"north": True, "south": True, "east": True, "west": True}
    elif mask_id == 4:
        flags = {"north": True, "east": True, "west": True}
    elif mask_id == 5:
        flags = {"south": True, "east": True, "west": True}
    elif mask_id == 6:
        flags = {"north": True, "south": True, "west": True}
    elif mask_id == 7:
        flags = {"north": True, "south": True, "east": True}
    else:
        flags = {"inner": True}
    return blend_layers(base, worn, lambda x, y: transition_weight(x, y, flags) * 0.95)


def make_cave_tile(kind: int) -> Image.Image:
    if kind % 4 == 0:
        img = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
        dither_surface(img, PALETTE["void"], PALETTE["stone_dark"], PALETTE["stone_mid"], 300 + kind, warp=0.14)
        rng = random.Random(kind)
        for _ in range(8):
            set_px(img, rng.randrange(TILE), rng.randrange(TILE), PALETTE["stone_mid"].darken(0.1))
    elif kind % 4 == 1:
        img = make_stone(310 + kind, cracked=True)
    elif kind % 4 == 2:
        img = make_stone(320 + kind, mossy=True)
    else:
        img = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
        dither_surface(img, PALETTE["void"], PALETTE["water_deep"], PALETTE["water_mid"], 330 + kind, warp=0.16)
    if kind % 8 >= 4:
        fill_rect(img, 4 + kind % 6, 0, 6 + kind % 6, 9, PALETTE["stone_mid"])
        fill_rect(img, 18 - kind % 5, 23, 20 - kind % 5, TILE - 1, PALETTE["stone_mid"].darken(0.12))
    return img


def make_structure_tile(kind: int) -> Image.Image:
    img = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    floor = make_stone(400 + kind, cracked=True)
    img.paste(floor, (0, 0))
    draw = ImageDraw.Draw(img)
    variant = kind % 16

    if variant == 0:
        fill_rect(img, 10, 6, 22, 28, PALETTE["wood_dark"])
        fill_rect(img, 12, 8, 20, 26, PALETTE["wood_mid"])
        fill_rect(img, 18, 16, 20, 18, PALETTE["iron_dark"])
        draw.line((12, 8, 12, 26), fill=(*PALETTE["wood_light"].as_tuple(), 255))
    elif variant == 1:
        fill_rect(img, 4, 6, 10, 28, PALETTE["wood_dark"])
        fill_rect(img, 18, 6, 28, 28, PALETTE["void"])
    elif variant == 2:
        fill_rect(img, 8, 4, 24, 28, PALETTE["iron_dark"])
        for y in range(6, 26, 4):
            draw.line((10, y, 22, y), fill=(*PALETTE["iron_mid"].as_tuple(), 255))
    elif variant == 3:
        fill_rect(img, 10, 10, 22, 24, PALETTE["void"])
        draw.arc((10, 6, 22, 18), 180, 0, fill=(*PALETTE["stone_light"].as_tuple(), 255))
        fill_rect(img, 10, 12, 22, 24, PALETTE["water_deep"])
    elif variant == 4:
        for y in range(12, 21):
            tone = PALETTE["wood_mid"] if y % 2 == 0 else PALETTE["wood_light"].darken(0.1)
            fill_rect(img, 0, y, TILE - 1, y, tone)
        for x in range(0, TILE, 6):
            fill_rect(img, x, 12, x, 20, PALETTE["wood_dark"])
    elif variant == 5:
        for x in range(12, 21):
            tone = PALETTE["wood_mid"] if x % 2 == 0 else PALETTE["wood_light"].darken(0.1)
            fill_rect(img, x, 0, x, TILE - 1, tone)
    elif variant == 6:
        fill_rect(img, 4, 14, 28, 15, PALETTE["wood_light"].darken(0.2))
        fill_rect(img, 4, 18, 28, 19, PALETTE["wood_light"].darken(0.2))
        for x in range(6, 28, 4):
            draw.line((x, 15, x + 2, 19), fill=(*PALETTE["wood_dark"].as_tuple(), 255))
    elif variant == 7:
        fill_rect(img, 0, 20, TILE - 1, TILE - 1, PALETTE["stone_mid"])
        draw.pieslice((4, 0, 28, 24), 180, 360, fill=(*PALETTE["void"].as_tuple(), 255))
        draw.arc((4, 0, 28, 24), 180, 360, fill=(*PALETTE["stone_light"].as_tuple(), 255), width=2)
    elif variant == 8:
        fill_rect(img, 8, 6, 24, 28, PALETTE["iron_dark"])
        for x in range(10, 24, 3):
            fill_rect(img, x, 6, x, 28, PALETTE["void"])
    elif variant == 9:
        fill_rect(img, 6, 18, 26, 27, PALETTE["stone_mid"])
        fill_rect(img, 8, 12, 24, 18, PALETTE["stone_light"])
        draw_blood_splatter(img, kind)
    elif variant == 10:
        draw_rock(img, 12, 22, 4)
        draw_rock(img, 20, 22, 3)
        fill_rect(img, 14, 18, 18, 20, PALETTE["ash_mid"])
    elif variant == 11:
        draw_rock(img, 12, 22, 4)
        draw_rock(img, 20, 22, 3)
        fill_rect(img, 14, 16, 18, 22, PALETTE["lava_glow"])
        set_px(img, 16, 14, PALETTE["highlight"])
    elif variant == 12:
        draw.ellipse((8, 14, 24, 28), fill=(*PALETTE["stone_mid"].as_tuple(), 255))
        draw.ellipse((10, 16, 22, 26), fill=(*PALETTE["void"].as_tuple(), 255))
        fill_rect(img, 14, 8, 18, 14, PALETTE["wood_dark"])
    elif variant == 13:
        draw.ellipse((8, 10, 24, 26), outline=(*PALETTE["wood_mid"].as_tuple(), 255), width=2)
        draw.line((16, 10, 16, 26), fill=(*PALETTE["wood_dark"].as_tuple(), 255))
        draw.line((8, 18, 24, 18), fill=(*PALETTE["wood_dark"].as_tuple(), 255))
    elif variant == 14:
        fill_rect(img, 14, 8, 18, 28, PALETTE["wood_dark"])
        fill_rect(img, 6, 8, 26, 11, PALETTE["wood_mid"])
        draw.line((20, 11, 20, 18), fill=(*PALETTE["iron_dark"].as_tuple(), 255))
    else:
        fill_rect(img, 0, 10, TILE - 1, 28, PALETTE["brick_dark"])
        fill_rect(img, 0, 0, TILE - 1, 10, PALETTE["void"])
        draw_cracks(img, kind)
    return img


def make_frost_tile(kind: int) -> Image.Image:
    frost_base = RGB(48, 52, 58)
    frost_hi = RGB(98, 104, 116)
    ice = RGB(72, 88, 108)

    if kind % 4 == 0:
        img = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
        dither_surface(img, frost_base, frost_hi, ice, 500 + kind, warp=0.14)
    elif kind % 4 == 1:
        img = make_grass(kind, dead=True)
        overlay = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
        dither_surface(overlay, frost_hi, RGB(128, 136, 148), RGB(160, 168, 180), 510 + kind, warp=0.1)
        img = Image.alpha_composite(img, overlay)
    elif kind % 4 == 2:
        img = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
        dither_surface(img, ice, frost_hi, RGB(180, 190, 204), 520 + kind, warp=0.12)
        draw_cracks(img, kind, RGB(40, 54, 70))
    else:
        img = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
        dither_surface(img, PALETTE["water_deep"], ice, frost_hi, 530 + kind, warp=0.16)
    return img


def make_tree_tile(kind: int) -> Image.Image:
    img = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    floor = make_grass(kind, dead=True)
    img.paste(floor, (0, 0))
    trunk = PALETTE["wood_dark"]
    bark_hi = PALETTE["wood_mid"]
    fill_rect(img, 14, 18, 17, TILE - 1, trunk)
    set_px(img, 14, 18, bark_hi)

    if kind % 4 == 0:
        fill_rect(img, 8, 6, 10, 16, trunk)
        fill_rect(img, 22, 8, 24, 14, trunk)
        draw = ImageDraw.Draw(img)
        draw.polygon([(12, 5), (20, 5), (18, 12), (14, 12)], fill=(*PALETTE["wood_mid"].as_tuple(), 255))
    elif kind % 4 == 1:
        for x, y, h in [(13, 10, 8), (16, 8, 10), (19, 11, 7)]:
            fill_rect(img, x, y, x + 2, y + h, trunk)
        for x in range(8, 25, 3):
            fill_rect(img, x, 5, x + 1, 8, PALETTE["grass_dead"])
    elif kind % 4 == 2:
        for i in range(10):
            x = 8 + i * 2
            fill_rect(img, x, 22 - i % 4, x + 1, 28, PALETTE["blood_dark"])
            if i % 2 == 0:
                set_px(img, x, 21 - i % 4, PALETTE["blood_mid"])
    else:
        fill_rect(img, 12, 4, 20, 14, bark_hi)
        for x in range(12, 21, 2):
            fill_rect(img, x, 14, x, 22, PALETTE["moss"])
            set_px(img, x, 23, PALETTE["moss"].darken(0.2))
    return img