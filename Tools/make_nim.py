#!/usr/bin/env python3
"""Draws what Nim is played with (Games/Nim.lua), its icon, and makes its sounds.

    python3 Tools/make_nim.py Images Sounds

Writes Images/Nim/slate.tga, a tablet of dark slate lit from the top left, with a line cut round
its edge and a carved bowl at each end for the stones each player takes. The rows aren't on it:
how many there are depends on the game, and each stone lies in a hollow drawn on its own,
Images/Nim/hollow.tga. The slate lies in the top of its texture with its shadow round it, see
BOARD_ROWS. Also Images/Nim/stones64.tga and stones32.tga, every look a stone can have, a river
pebble in one of eight colours and four shapes, eight to a row; and Images/Icons/nim.tga.

The sounds, Sounds/nimClack<take>.ogg, are a pebble knocked down onto slate. They need ffmpeg.
The drawing and sound helpers are Tools/make_mancala.py's. Pass a third folder to also get PNG
copies of the pictures there.

The slate is measured in units, a stone's spot with the room round it. Games/Nim.lua knows the
same numbers: change them in both.
"""
import math
import random
import sys
from pathlib import Path

from make_mancala import (
    add,
    clamp,
    fbm,
    finish,
    mix,
    normalize,
    render_square,
    ring,
    rounded,
    smoothstep,
    tick,
    value_noise,
    write,
    write_sound,
)

# The slate, in units. Games/Nim.lua has these too
MARGIN_X, MARGIN_Y = 0.4, 0.5
BOWL, GAP = 1.9, 0.45
SPOT, PITCH = 0.82, 0.92
LONGEST, ROWS = 7, 4
WIDTH = 2 * MARGIN_X + 2 * BOWL + 2 * GAP + LONGEST * SPOT
HEIGHT = 2 * MARGIN_Y + ROWS * PITCH
PAD, CORNER = 0.22, 0.3
BOARD_TEXTURE = (1024, 512)
BOARD_ROWS = 449
BOWL_DEPTH = 0.3
BEVEL, BEVEL_DEPTH = 0.07, 0.05
# The line cut round the slate: how far in, and how wide
GROOVE_IN, GROOVE_WIDTH = 0.18, 0.035
LIGHT_DIRECTION = normalize((-0.5, -0.62, 0.6))
LIGHT_FLAT = math.hypot(LIGHT_DIRECTION[0], LIGHT_DIRECTION[1])
LIGHT_ACROSS = (LIGHT_DIRECTION[0] / LIGHT_FLAT, LIGHT_DIRECTION[1] / LIGHT_FLAT)
LIGHT_SLOPE = LIGHT_DIRECTION[2] / LIGHT_FLAT
HALFWAY = normalize((LIGHT_DIRECTION[0], LIGHT_DIRECTION[1], LIGHT_DIRECTION[2] + 1))
SLATE_DARK, SLATE_LIGHT = (40, 46, 56), (104, 114, 130)
SAMPLES = 2

BOWLS = [(MARGIN_X + BOWL / 2, HEIGHT / 2), (WIDTH - MARGIN_X - BOWL / 2, HEIGHT / 2)]


def stone_colour(x, y):
    """The colour of the slate at a point: split along its layers into broad, wavering bands, with
    a fine grain and flecks of mica"""
    tone = fbm(x * 0.3, y * 0.5)
    ripple = fbm(x * 0.5 + 4, y * 1.6) * 3.0
    layers = 0.5 + 0.5 * math.sin((y * 2.6 + ripple) * math.pi)
    seams = smoothstep(0.92, 1.0, 0.5 + 0.5 * math.sin((y * 5.3 + ripple * 1.3) * math.pi))
    grain = value_noise(x * 18, y * 30)
    shade = clamp(0.24 + 0.42 * tone + 0.14 * layers + 0.12 * grain - 0.1 * seams)
    color = mix(SLATE_DARK, SLATE_LIGHT, shade)
    if value_noise(x * 70 + 7, y * 70) > 0.9:
        color = mix(color, (196, 204, 220), 0.3)
    return color


def height(x, y):
    """How high the slate is at a point: bowls carved into it, its edge bevelled"""
    edge = rounded(x - WIDTH / 2, y - HEIGHT / 2, WIDTH / 2, HEIGHT / 2, CORNER)
    if edge > 0:
        return -1.0
    for cx, cy in BOWLS:
        t = math.hypot(x - cx, y - cy) / (BOWL / 2)
        if t < 1:
            return -BOWL_DEPTH * (1 - t * t) ** 1.4
    groove = abs(-edge - GROOVE_IN) - GROOVE_WIDTH / 2
    if groove < 0:
        return -0.02 * (1 - (groove / (GROOVE_WIDTH / 2)) ** 2)
    if edge > -BEVEL:
        return -BEVEL_DEPTH * (1 + edge / BEVEL) ** 2
    return 0.0


def lit(x, y):
    """How much light a point of the slate gets, and how much shine it gives back"""
    eps = 0.008
    dx = (height(x + eps, y) - height(x - eps, y)) / (2 * eps)
    dy = (height(x, y + eps) - height(x, y - eps)) / (2 * eps)
    normal = normalize((-dx, -dy, 1.0))
    diffuse = max(0.0, sum(normal[i] * LIGHT_DIRECTION[i] for i in range(3)))
    here = height(x, y)
    shade = 1.0
    if here < -0.01:
        for step in range(1, 30):
            t = step * 0.025
            ray = here + t * LIGHT_SLOPE
            if ray > 0.005:
                break
            above = height(x + LIGHT_ACROSS[0] * t, y + LIGHT_ACROSS[1] * t) - ray
            if above > 0:
                shade = 0.0
                break
            shade = min(shade, clamp(-above / t * 9))
    shine = max(0.0, sum(normal[i] * HALFWAY[i] for i in range(3))) ** 30
    hollow = clamp(1 + here / 0.35)
    light = (0.32 + 1.1 * diffuse * (0.2 + 0.8 * shade)) * (0.65 + 0.35 * hollow)
    return light, shine * 0.12 * (0.3 + 0.7 * shade)


def slate(x, y):
    edge = rounded(x - WIDTH / 2, y - HEIGHT / 2, WIDTH / 2, HEIGHT / 2, CORNER)
    if edge > 0:
        cast = rounded(x - WIDTH / 2 - 0.05, y - HEIGHT / 2 - 0.09, WIDTH / 2, HEIGHT / 2, CORNER)
        return (0, 0, 0), 0.6 * (1 - smoothstep(-0.05, PAD * 0.95, cast))
    light, shine = lit(x, y)
    color = stone_colour(x, y)
    if height(x, y) < -0.01:
        # Carved and smoothed: darker, without the flecks showing as much
        color = mix(color, SLATE_DARK, 0.2)
    return tuple(clamp(c / 255 * light + shine) * 255 for c in color), 1.0


def render_slate():
    width, rows = BOARD_TEXTURE[0], BOARD_ROWS
    scale_x = (WIDTH + 2 * PAD) / width
    scale_y = (HEIGHT + 2 * PAD) / rows
    out = []
    for py in range(BOARD_TEXTURE[1]):
        row = []
        for px in range(width):
            if py >= rows:
                row.append((255, 255, 255, 0))
                continue
            red = green = blue = alpha = 0.0
            for i in range(SAMPLES):
                for j in range(SAMPLES):
                    x = (px + (i + 0.5) / SAMPLES) * scale_x - PAD
                    y = (py + (j + 0.5) / SAMPLES) * scale_y - PAD
                    color, a = slate(x, y)
                    red, green, blue, alpha = red + color[0] * a, green + color[1] * a, blue + color[2] * a, alpha + a
            if alpha > 0:
                row.append((round(red / alpha), round(green / alpha), round(blue / alpha), round(255 * alpha / SAMPLES**2)))
            else:
                row.append((0, 0, 0, 0))
        out.append(row)
    return out


def hollow(x, y):
    """A shallow cup cut into the slate, to lie over it: its side in shadow where the rim is
    between it and the light, lit on the far side where the light falls in, its floor a little
    darker than the slate round it"""
    r = math.hypot(x, y) / 0.9
    if r >= 1:
        return (0, 0, 0), 0.0
    edge = smoothstep(1.0, 0.93, r)
    # How much a point of the side faces the light, which comes from the top left
    facing = clamp((x + y) / max(0.001, math.hypot(x, y)) * 0.7071)
    away = clamp(-(x + y) / max(0.001, math.hypot(x, y)) * 0.7071)
    wall = smoothstep(0.45, 0.85, r)
    if facing * wall > 0.05:
        return (225, 232, 245), edge * facing * wall * 0.38
    return (0, 0, 0), edge * (0.16 + away * wall * 0.42)


# River pebbles: chalk, sand, rust, sage, slate blue, charcoal, rose and ochre
STONE_COLORS = [
    (232, 226, 212),
    (206, 182, 144),
    (184, 104, 74),
    (138, 160, 126),
    (116, 140, 168),
    (92, 96, 104),
    (212, 160, 156),
    (206, 160, 76),
]
STONE_SHAPES = [(0.86, 0.3, 0.02), (0.78, -0.4, 0.03), (0.92, 1.2, 0.035), (0.82, 2.1, 0.025)]


def pebble(x, y, color, shape, seed):
    """A smooth river pebble, rounded and a little flat, lit from the top left"""
    squash, turn, lumpy = shape
    cos, sin = math.cos(turn), math.sin(turn)
    u, v = x * cos + y * sin, -x * sin + y * cos
    v /= squash
    radius = 0.88 + lumpy * math.sin(math.atan2(v, u) * 2 + seed)
    r = math.hypot(u, v) / radius
    if r >= 1:
        return (0, 0, 0), 0.0
    edge = smoothstep(1.0, 0.95, r)
    # A low dome: its normal from how far out a point is
    z = math.sqrt(max(0.0, 1 - r * r)) * 0.8 + 0.2
    normal = normalize((x * 0.9, y * 0.9, z))
    light = max(0.0, sum(normal[i] * LIGHT_DIRECTION[i] for i in range(3)))
    speckle = value_noise(x * 9 + seed * 3, y * 9) - 0.5
    body = tuple(c * (0.35 + 0.8 * light) * (1 + speckle * 0.16) for c in color)
    shine = max(0.0, sum(normal[i] * HALFWAY[i] for i in range(3))) ** 18 * 0.32
    return tuple(clamp(c / 255 + shine) * 255 for c in body), edge


def render_stones(cell):
    columns = len(STONE_COLORS)
    out = [[(255, 255, 255, 0)] * (cell * columns) for _ in range(cell * len(STONE_SHAPES))]
    samples, fill = 4, 0.86
    for row, shape in enumerate(STONE_SHAPES):
        for column, color in enumerate(STONE_COLORS):
            for py in range(cell):
                for px in range(cell):
                    red = green = blue = alpha = 0.0
                    for i in range(samples):
                        for j in range(samples):
                            x = ((px + (i + 0.5) / samples) / cell * 2 - 1) / fill
                            y = ((py + (j + 0.5) / samples) / cell * 2 - 1) / fill
                            c, a = pebble(x, y, color, shape, row * 1.7 + column)
                            red, green, blue, alpha = red + c[0] * a, green + c[1] * a, blue + c[2] * a, alpha + a
                    if alpha > 0:
                        pixel = (round(red / alpha), round(green / alpha), round(blue / alpha), round(255 * alpha / samples**2))
                    else:
                        pixel = (255, 255, 255, 0)
                    out[row * cell + py][column * cell + px] = pixel
    return out


def icon(x, y):
    """Rows of one, two and three pebbles on slate, the last one lifted"""
    edge = rounded(x, y, 0.98, 0.98, 0.22)
    if edge > 0:
        return (0, 0, 0), 0.0
    color = stone_colour(x * 2 + 5, y * 2 + 3)
    light = 1.0 if edge < -0.07 else 0.7 + 0.6 * clamp((-x - y) * 0.6 + 0.4)
    base = tuple(c * light for c in color)
    stones = []
    for row, count in enumerate((1, 2, 3)):
        for index in range(count):
            stones.append((-0.55 * (count - 1) / 2 + 0.55 * index, -0.55 + 0.55 * row, (row * 3 + index) % 8))
    for index, (cx, cy, which) in enumerate(stones):
        lifted = index == len(stones) - 1
        lift = 0.12 if lifted else 0.0
        # Its shadow first, down and to the right of it
        if math.hypot(x - cx - 0.06 - lift * 0.4, y - cy - 0.07 - lift * 0.4) < 0.22:
            base = mix(base, (0, 0, 0), 0.35)
    for index, (cx, cy, which) in enumerate(stones):
        lifted = index == len(stones) - 1
        size = 0.25 if lifted else 0.22
        c, a = pebble((x - cx) / size, (y - cy + (0.12 if lifted else 0)) / size, STONE_COLORS[which], STONE_SHAPES[0], index)
        if a > 0:
            base = mix(base, c, a)
    return base, 1.0


def clack(rng):
    """A pebble knocked down onto slate: the tock of the stone over the slate's low knock"""
    pitch = rng.uniform(0.88, 1.15)
    stone = ring([(1650 * pitch, 0.5, 0.012), (2700 * pitch, 0.35, 0.008), (3900 * pitch, 0.2, 0.005)], 0.05, rng)
    slab = ring([(320 * pitch, 0.5, 0.02), (760 * pitch, 0.3, 0.012)], 0.08, rng)
    sound = add(add(slab, stone, gain=0.9), tick(0.005, 0.0011, rng), gain=0.45)
    if rng.random() < 0.5:
        # It settles with a smaller knock
        add(sound, ring([(1900 * pitch, 0.4, 0.006), (3100 * pitch, 0.2, 0.004)], 0.03, rng), at=rng.uniform(0.03, 0.05), gain=0.25)
    return sound


if __name__ == "__main__":
    images = Path(sys.argv[1])
    sounds_folder = Path(sys.argv[2])
    preview = Path(sys.argv[3]) if len(sys.argv) > 3 else None
    rng = random.Random(11)
    for take in range(1, 5):
        write_sound(sounds_folder, "Clack%d" % take, finish(clack(rng), 0.32), prefix="nim")
    write(images / "Icons" / "nim.tga", render_square(64, icon), preview)
    write(images / "Nim" / "hollow.tga", render_square(64, hollow), preview)
    write(images / "Nim" / "stones32.tga", render_stones(32), preview)
    write(images / "Nim" / "stones64.tga", render_stones(64), preview)
    write(images / "Nim" / "slate.tga", render_slate(), preview)
