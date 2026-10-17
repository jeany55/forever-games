#!/usr/bin/env python3
"""Draws what Mancala is played with (Games/Mancala.lua), its icon, and makes its sounds.

    python3 Tools/make_mancala.py Images Sounds

Writes Images/Mancala/board.tga, a board of oiled walnut lit from the top left, with a brass line
inlaid round its edge, six carved pits along each side and a long store at each end. The board
lies in the top of the texture with its shadow round it, see BOARD_ROWS for how much of it.
Also Images/Mancala/seeds64.tga and seeds32.tga, every look a seed can have, a glass stone in
one of eight colours and four shapes, eight to a row; pit.tga and store.tga, the light round a
pit or a store that is lit up; and Images/Icons/mancala.tga.

The sounds are made from the ringing of wood and glass, Sounds/mancala<Name><take>.ogg, and need
ffmpeg to be written as Ogg: a stone dropped into a pit, a handful of them swept into a store,
and a marimba for going again. Only the standard library is used besides. Pass a third folder to
also get PNG copies of the pictures there, which are easier to look at than TGA.

The board is measured in units, a pit's width with the room round it. Games/Mancala.lua knows
the same numbers: change them in both.
"""
import math
import random
import struct
import subprocess
import sys
import tempfile
import wave
import zlib
from pathlib import Path

# The board, in units. Games/Mancala.lua has these too
MARGIN_X, MARGIN_Y = 0.42, 0.5
STORE_CELL, GAP, ROW_GAP = 0.96, 0.16, 0.2
PIT_RADIUS = 0.42
STORE_WIDTH, STORE_HEIGHT = 0.86, 2.04
WIDTH = 2 * MARGIN_X + 2 * STORE_CELL + 2 * GAP + 6
HEIGHT = 2 * MARGIN_Y + 2 + ROW_GAP
# Room round the board for its shadow, and how round its corners are
PAD, CORNER = 0.22, 0.34
# The texture the board is drawn into: it fills its width and this many of its rows
BOARD_TEXTURE = (1024, 512)
BOARD_ROWS = 392
# How deep a pit and a store are carved, and how wide the bevel round the board's edge is
PIT_DEPTH, STORE_DEPTH = 0.2, 0.22
BEVEL, BEVEL_DEPTH = 0.07, 0.05
# The brass line round the board: how far in from the edge, and how wide
INLAY_IN, INLAY_WIDTH = 0.17, 0.03
# Where the light comes from: the top left, and above
LIGHT = (-0.5, -0.62, 0.6)
# Oiled walnut, from its light grain to its dark, and brass
WOOD_LIGHT, WOOD_DARK, WOOD_DEEP = (158, 98, 56), (98, 56, 30), (58, 30, 16)
BRASS, BRASS_DARK = (232, 196, 118), (128, 92, 40)
# How many samples a pixel is made of, along each side
SAMPLES = 2


def clamp(value, low=0.0, high=1.0):
    return max(low, min(high, value))


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(len(a)))


def smoothstep(edge0, edge1, value):
    t = clamp((value - edge0) / (edge1 - edge0))
    return t * t * (3 - 2 * t)


def normalize(vector):
    length = math.sqrt(sum(c * c for c in vector))
    return tuple(c / length for c in vector)


LIGHT_DIRECTION = normalize(LIGHT)
# The way the light goes across the board, and how steeply it comes down
LIGHT_FLAT = math.hypot(LIGHT_DIRECTION[0], LIGHT_DIRECTION[1])
LIGHT_ACROSS = (LIGHT_DIRECTION[0] / LIGHT_FLAT, LIGHT_DIRECTION[1] / LIGHT_FLAT)
LIGHT_SLOPE = LIGHT_DIRECTION[2] / LIGHT_FLAT
HALFWAY = normalize((LIGHT_DIRECTION[0], LIGHT_DIRECTION[1], LIGHT_DIRECTION[2] + 1))


def rounded(x, y, half_width, half_height, corner):
    """How far a point is outside a box with round corners, below zero inside it"""
    dx, dy = abs(x) - half_width + corner, abs(y) - half_height + corner
    return math.hypot(max(dx, 0), max(dy, 0)) + min(max(dx, dy), 0) - corner


#############################
# Noise
#############################

HASH = list(range(256))
random.Random(7).shuffle(HASH)
HASH += HASH


def lattice(ix, iy):
    return HASH[(HASH[ix & 255] + iy) & 255] / 255.0


def value_noise(x, y):
    """Smooth noise from 0 to 1"""
    ix, iy = math.floor(x), math.floor(y)
    fx, fy = x - ix, y - iy
    fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    top = lattice(ix, iy) + (lattice(ix + 1, iy) - lattice(ix, iy)) * fx
    bottom = lattice(ix, iy + 1) + (lattice(ix + 1, iy + 1) - lattice(ix, iy + 1)) * fx
    return top + (bottom - top) * fy


def fbm(x, y, octaves=3):
    total, amplitude, scale = 0.0, 0.5, 1.0
    for _ in range(octaves):
        total += value_noise(x * scale, y * scale) * amplitude
        scale, amplitude = scale * 2.03, amplitude * 0.5
    return total


def walnut(x, y):
    """The colour of the wood at a point, its grain running along the board in long waves"""
    warp = fbm(x * 0.21, y * 0.75) * 3.4 + math.sin(x * 0.37 + 1.3) * 0.5
    ring = y * 2.9 + warp
    # Soft bands of early and late wood, and finer lines within them
    band = (0.5 + 0.5 * math.sin(ring * 2 * math.pi)) ** 1.6
    line = (0.5 + 0.5 * math.sin(ring * 6 * math.pi + fbm(x * 0.9, y * 4) * 3)) ** 6
    fibre = value_noise(x * 3.0, y * 70.0)
    patch = fbm(x * 0.14 + 11, y * 0.45)
    dark = clamp(0.32 * band + 0.16 * line + 0.2 * fibre + 0.55 * (patch - 0.45))
    color = mix(WOOD_LIGHT, WOOD_DARK, dark)
    # Now and then a darker streak, as walnut has
    streak = smoothstep(0.6, 0.82, fbm(x * 0.5 + 3, y * 2.4 + 5))
    return mix(color, WOOD_DEEP, streak * 0.5)


#############################
# The board
#############################

PITS = []
for row_y in (MARGIN_Y + 0.5, MARGIN_Y + 1.5 + ROW_GAP):
    for column in range(6):
        PITS.append((MARGIN_X + STORE_CELL + GAP + 0.5 + column, row_y))
STORES = [(MARGIN_X + STORE_CELL / 2, HEIGHT / 2), (WIDTH - MARGIN_X - STORE_CELL / 2, HEIGHT / 2)]
FIRST_PIT_X = MARGIN_X + STORE_CELL + GAP + 0.5


def carving(x, y):
    """How far a point lies inside a hole, as a part of the way from its rim to its bottom: 0 on
    the rim or outside, 1 at the bottom. And how deep that hole is"""
    column = round(x - FIRST_PIT_X)
    if 0 <= column <= 5:
        cx = FIRST_PIT_X + column
        for cy in (MARGIN_Y + 0.5, MARGIN_Y + 1.5 + ROW_GAP):
            t = math.hypot(x - cx, y - cy) / PIT_RADIUS
            if t < 1:
                return 1 - t * t, PIT_DEPTH
    for cx, cy in STORES:
        half = STORE_WIDTH / 2
        straight = STORE_HEIGHT / 2 - half
        along = max(0.0, abs(y - cy) - straight)
        t = math.hypot(x - cx, along) / half
        if t < 1:
            return 1 - t * t, STORE_DEPTH
    return 0.0, 0.0


def height(x, y):
    """How high the board is at a point, 0 on its top. Holes are carved bowls whose sides roll
    over smoothly at the rim, the edge of the board is bevelled, and off the board is far down"""
    edge = rounded(x - WIDTH / 2, y - HEIGHT / 2, WIDTH / 2, HEIGHT / 2, CORNER)
    if edge > 0:
        return -1.0
    inside, depth = carving(x, y)
    if inside > 0:
        return -depth * inside**1.4
    if edge > -BEVEL:
        return -BEVEL_DEPTH * (1 + edge / BEVEL) ** 2
    return 0.0


def lit(x, y):
    """How much light a point of the board gets, and how much shine it gives back"""
    eps = 0.008
    dx = (height(x + eps, y) - height(x - eps, y)) / (2 * eps)
    dy = (height(x, y + eps) - height(x, y - eps)) / (2 * eps)
    normal = normalize((-dx, -dy, 1.0))
    diffuse = max(0.0, sum(normal[i] * LIGHT_DIRECTION[i] for i in range(3)))
    here = height(x, y)
    shade = 1.0
    if here < 0:
        # The rim between the point and the light throws a shadow into the hole: look along the
        # way the light comes for anything higher than the ray, softly
        for step in range(1, 26):
            t = step * 0.022
            ray = here + t * LIGHT_SLOPE
            if ray > 0.005:
                break
            above = height(x + LIGHT_ACROSS[0] * t, y + LIGHT_ACROSS[1] * t) - ray
            if above > 0:
                shade = 0.0
                break
            shade = min(shade, clamp(-above / t * 9))
    shine = max(0.0, sum(normal[i] * HALFWAY[i] for i in range(3))) ** 45
    # Deep in a hole is a little darker however it is lit
    hollow = clamp(1 + here / 0.25)
    light = (0.42 + 0.95 * diffuse * (0.25 + 0.75 * shade)) * (0.75 + 0.25 * hollow)
    return light, shine * 0.22 * (0.3 + 0.7 * shade)


def inlay(x, y):
    """How much of a point is brass: the line round the board, and a diamond in its middle"""
    edge = rounded(x - WIDTH / 2, y - HEIGHT / 2, WIDTH / 2, HEIGHT / 2, CORNER)
    line = abs(-edge - INLAY_IN) - INLAY_WIDTH / 2
    diamond = (abs(x - WIDTH / 2) + abs(y - HEIGHT / 2) * 1.6) - 0.085
    return min(line, diamond)


def board(x, y):
    """A point of the board's texture, in units from the board's top left corner"""
    edge = rounded(x - WIDTH / 2, y - HEIGHT / 2, WIDTH / 2, HEIGHT / 2, CORNER)
    if edge > 0:
        # Its shadow on whatever it lies on, falling down and to the right
        cast = rounded(x - WIDTH / 2 - 0.05, y - HEIGHT / 2 - 0.09, WIDTH / 2, HEIGHT / 2, CORNER)
        return (0, 0, 0), 0.6 * (1 - smoothstep(-0.05, PAD * 0.95, cast))
    light, shine = lit(x, y)
    color = walnut(x, y)
    inside, _ = carving(x, y)
    if inside > 0:
        # End grain and oil: the inside of a hole is darker and smoother
        color = mix(color, WOOD_DARK, 0.25)
    brass = inlay(x, y)
    if brass < 0.004:
        # Rounded, so lit across its width
        across = clamp(-brass / 0.012)
        metal = mix(BRASS_DARK, BRASS, 0.45 + 0.55 * across)
        color = mix(color, metal, smoothstep(0.004, -0.004, brass))
        shine += 0.25 * across
    out = tuple(clamp(c / 255 * light + shine) * 255 for c in color)
    return out, 1.0


def render_board():
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
                    color, a = board(x, y)
                    red, green, blue, alpha = red + color[0] * a, green + color[1] * a, blue + color[2] * a, alpha + a
            if alpha > 0:
                row.append((round(red / alpha), round(green / alpha), round(blue / alpha), round(255 * alpha / SAMPLES**2)))
            else:
                row.append((0, 0, 0, 0))
        out.append(row)
    return out


#############################
# Seeds
#############################

# Glass stones: ruby, sapphire, emerald, amber, amethyst, aqua, rose and milk glass
SEED_COLORS = [
    (214, 32, 52),
    (44, 96, 232),
    (28, 168, 92),
    (244, 158, 28),
    (150, 64, 214),
    (36, 188, 206),
    (240, 96, 164),
    (226, 228, 236),
]
# How each shape is squashed, turned and lumpy
SEED_SHAPES = [(1.0, 0.0, 0.0), (0.9, 0.5, 0.025), (0.84, -0.7, 0.03), (0.94, 1.6, 0.045)]
SEED_ROWS = 4


def seed(x, y, color, shape):
    """A flat backed glass stone, lit from the top left: colour, alpha"""
    squash, turn, lumpy = shape
    cos, sin = math.cos(turn), math.sin(turn)
    u, v = x * cos + y * sin, -x * sin + y * cos
    v /= squash
    radius = 0.86 + lumpy * math.sin(math.atan2(v, u) * 3 + turn * 2)
    r = math.hypot(u, v) / radius
    if r >= 1:
        return (0, 0, 0), 0.0
    edge = smoothstep(1.0, 0.94, r)
    # A low dome: the light goes through it and gathers on the far side
    dome = math.sqrt(max(0.0, 1 - r * r))
    body = mix(tuple(c * 0.35 for c in color), color, 0.35 + 0.65 * dome)
    glow = math.exp(-(((x - 0.28) ** 2 + (y - 0.32) ** 2) / 0.16))
    body = mix(body, tuple(min(255, c * 1.35 + 60) for c in color), glow * 0.75)
    rim = smoothstep(0.78, 1.0, r)
    body = mix(body, tuple(c * 0.3 for c in color), rim * 0.6)
    # The shine of the light on its top, sharp, and a softer one around it
    shine = math.exp(-(((x + 0.32) ** 2 + (y + 0.36) ** 2 * 1.6) / 0.018))
    soft = math.exp(-(((x + 0.22) ** 2 + (y + 0.26) ** 2) / 0.12)) * 0.25
    body = mix(body, (255, 255, 255), clamp(shine * 0.95 + soft))
    return body, edge


def render_seeds(cell):
    columns = len(SEED_COLORS)
    out = [[(255, 255, 255, 0)] * (cell * columns) for _ in range(cell * SEED_ROWS)]
    samples = 4
    # The stone fills this much of its cell, leaving room so its neighbours never bleed in
    fill = 0.84
    for row, shape in enumerate(SEED_SHAPES):
        for column, color in enumerate(SEED_COLORS):
            for py in range(cell):
                for px in range(cell):
                    red = green = blue = alpha = 0.0
                    for i in range(samples):
                        for j in range(samples):
                            x = ((px + (i + 0.5) / samples) / cell * 2 - 1) / fill
                            y = ((py + (j + 0.5) / samples) / cell * 2 - 1) / fill
                            c, a = seed(x, y, color, shape)
                            red, green, blue, alpha = red + c[0] * a, green + c[1] * a, blue + c[2] * a, alpha + a
                    if alpha > 0:
                        pixel = (round(red / alpha), round(green / alpha), round(blue / alpha), round(255 * alpha / samples**2))
                    else:
                        pixel = (255, 255, 255, 0)
                    out[row * cell + py][column * cell + px] = pixel
    return out


#############################
# Lights
#############################

# How much bigger than its hole the light round it is drawn (GUI/Heaps.lua)
GLOW_OVER = 1.18


def glow_at(distance):
    """The light at so far outside a hole's rim, in units: a ring on the rim, a little inside"""
    ring = math.exp(-((distance / 0.05) ** 2))
    fill = 0.22 * smoothstep(0.0, -0.25, distance)
    return clamp(ring + fill)


def render_glow(width_px, height_px, hole_width, hole_height):
    out = []
    samples = 3
    for py in range(height_px):
        row = []
        for px in range(width_px):
            total = 0.0
            for i in range(samples):
                for j in range(samples):
                    x = ((px + (i + 0.5) / samples) / width_px - 0.5) * hole_width * GLOW_OVER
                    y = ((py + (j + 0.5) / samples) / height_px - 0.5) * hole_height * GLOW_OVER
                    half = min(hole_width, hole_height) / 2
                    straight = abs(hole_height - hole_width) / 2
                    if hole_height > hole_width:
                        distance = math.hypot(x, max(0.0, abs(y) - straight)) - half
                    else:
                        distance = math.hypot(max(0.0, abs(x) - straight), y) - half
                    total += glow_at(distance)
            row.append((255, 255, 255, round(255 * total / samples**2)))
        out.append(row)
    return out


#############################
# Icon
#############################

ICON_SEEDS = [
    # Pit, then where in it as a part of its radius, and which colour
    (0, -0.3, -0.2, 0), (0, 0.32, 0.1, 1), (0, -0.05, 0.38, 3),
    (1, 0.0, 0.0, 2), (1, 0.3, -0.35, 4),
    (2, -0.2, 0.25, 5), (2, 0.25, -0.15, 6), (2, -0.25, -0.3, 1), (2, 0.25, 0.4, 3),
    (3, 0.05, 0.0, 0),
    (4, -0.3, 0.15, 7), (4, 0.3, 0.2, 2), (4, 0.0, -0.32, 4),
    (5, -0.2, -0.1, 5), (5, 0.28, 0.25, 6),
]


def icon(x, y):
    """Two rows of three pits on walnut, glass stones in them"""
    edge = rounded(x, y, 0.98, 0.98, 0.22)
    if edge > 0:
        return (0, 0, 0), 0.0
    color = walnut(x * 1.6 + 3, y * 0.9 + 1)
    light = 1.0
    if edge > -0.07:
        light = 0.7 + 0.6 * clamp((-x - y) * 0.6 + 0.4)
    pits = [(-0.58 + 0.58 * column, -0.42 + 0.84 * row) for row in range(2) for column in range(3)]
    radius = 0.25
    for index, (cx, cy) in enumerate(pits):
        t = math.hypot(x - cx, y - cy) / radius
        if t < 1:
            # Dark at the top left where the rim shades it, lit on its far side
            side = ((x - cx) + (y - cy)) / radius
            light = 0.45 + 0.35 * clamp(side * 0.8 + 0.3) - 0.15 * (1 - t)
            color = mix(color, WOOD_DARK, 0.3)
            for pit, sx, sy, which in ICON_SEEDS:
                if pit == index:
                    stone, a = seed((x - cx - sx * radius) / 0.13, (y - cy - sy * radius) / 0.13, SEED_COLORS[which], SEED_SHAPES[0])
                    if a > 0:
                        return mix(tuple(c * light for c in color), stone, a), 1.0
            break
    return tuple(clamp(c / 255 * light) * 255 for c in color), 1.0


def render_square(size, paint, samples=4):
    out = []
    for py in range(size):
        row = []
        for px in range(size):
            red = green = blue = alpha = 0.0
            for i in range(samples):
                for j in range(samples):
                    x = (px + (i + 0.5) / samples) / size * 2 - 1
                    y = (py + (j + 0.5) / samples) / size * 2 - 1
                    color, a = paint(x, y)
                    red, green, blue, alpha = red + color[0] * a, green + color[1] * a, blue + color[2] * a, alpha + a
            if alpha > 0:
                row.append((round(red / alpha), round(green / alpha), round(blue / alpha), round(255 * alpha / samples**2)))
            else:
                row.append((255, 255, 255, 0))
        out.append(row)
    return out


def write(path, rows, preview):
    height_px, width_px = len(rows), len(rows[0])
    path.parent.mkdir(parents=True, exist_ok=True)
    # TGA rows run bottom to top
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, width_px, height_px, 32, 8)
    path.write_bytes(header + b"".join(bytes((b, g, r, a)) for row in reversed(rows) for (r, g, b, a) in row))
    if preview:
        raw = b"".join(b"\x00" + b"".join(bytes(pixel) for pixel in row) for row in rows)

        def chunk(kind, body):
            return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

        png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width_px, height_px, 8, 6, 0, 0, 0))
        png += chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
        preview.mkdir(parents=True, exist_ok=True)
        (preview / (path.parent.name + "_" + path.stem + ".png")).write_bytes(png)


#############################
# Sounds
#############################

RATE = 44100


def ring(partials, seconds, rng):
    """Something struck that rings at a few frequencies, each dying away at its own pace:
    (frequency, loudness, seconds to die to a third)"""
    out = [0.0] * int(RATE * seconds)
    for frequency, loudness, decay in partials:
        phase = rng.uniform(0, 2 * math.pi)
        step = 2 * math.pi * frequency / RATE
        for index in range(len(out)):
            t = index / RATE
            envelope = math.exp(-t / decay)
            if envelope < 0.001:
                break
            out[index] += loudness * envelope * math.sin(phase + step * index)
    return out


def tick(seconds, decay, rng):
    """The noise of the moment two hard things meet"""
    out, last = [], 0.0
    for index in range(int(RATE * seconds)):
        last = last * 0.25 + rng.uniform(-1, 1) * 0.75
        out.append(last * math.exp(-index / RATE / decay))
    return out


def add(into, sound, at=0.0, gain=1.0):
    start = int(at * RATE)
    if len(into) < start + len(sound):
        into.extend([0.0] * (start + len(sound) - len(into)))
    for index, value in enumerate(sound):
        into[start + index] += value * gain
    return into


def stone_on_wood(rng):
    """A glass stone dropped into a wooden pit: the knock of the wood under the click of the glass"""
    pitch = rng.uniform(0.9, 1.12)
    wood = ring([(215 * pitch, 0.6, 0.03), (540 * pitch, 0.4, 0.022), (1040 * pitch, 0.22, 0.012)], 0.12, rng)
    glass = ring([(2900 * pitch, 0.4, 0.014), (4450 * pitch, 0.3, 0.01), (6200 * pitch, 0.2, 0.007)], 0.06, rng)
    sound = add(add(wood, glass, gain=0.7), tick(0.006, 0.0012, rng), gain=0.5)
    if rng.random() < 0.6:
        # It knocks against a stone already there
        add(sound, stone_on_stone(rng), at=rng.uniform(0.025, 0.05), gain=rng.uniform(0.2, 0.4))
    return sound


def stone_on_stone(rng):
    """Two glass stones knocking together"""
    pitch = rng.uniform(0.85, 1.2)
    clink = ring([(3400 * pitch, 0.5, 0.03), (5150 * pitch, 0.35, 0.02), (7300 * pitch, 0.2, 0.012)], 0.1, rng)
    return add(clink, tick(0.004, 0.0008, rng), gain=0.4)


def pour(rng):
    """A handful of stones swept into a store: knocks and clinks tumbling over one another"""
    sound, at = [], 0.0
    for index in range(rng.randint(13, 17)):
        gain = rng.uniform(0.45, 1.0) * (1 - index / 24)
        hit = stone_on_wood(rng) if rng.random() < 0.45 else stone_on_stone(rng)
        add(sound, hit, at=at, gain=gain)
        at += rng.expovariate(1 / 0.028)
    return sound


def marimba(frequency, rng):
    """A note on a marimba: a round tone with its high overtone quickly gone, and the mallet"""
    tone = ring([(frequency, 1.0, 0.32), (frequency * 3.93, 0.28, 0.06), (frequency * 9.2, 0.08, 0.02)], 0.7, rng)
    return add(tone, tick(0.005, 0.001, rng), gain=0.15)


def note(name):
    """The frequency of a note, "C5" or "Eb4" """
    steps = {"C": -9, "D": -7, "E": -5, "F": -4, "G": -2, "A": 0, "B": 2}
    letter, rest = name[0], name[1:]
    shift = 0
    if rest.startswith("b"):
        shift, rest = -1, rest[1:]
    elif rest.startswith("#"):
        shift, rest = 1, rest[1:]
    return 440.0 * 2 ** ((steps[letter] + shift + (int(rest) - 4) * 12) / 12)


def finish(sound, level):
    """Brought to a level, softly limited, and faded at the very end so it doesn't click"""
    peak = max(abs(value) for value in sound) or 1.0
    out = [math.tanh(value / peak * 1.2) / math.tanh(1.2) * level for value in sound]
    fade = min(len(out), int(RATE * 0.01))
    for index in range(fade):
        out[-1 - index] *= index / fade
    return out


def make_sounds():
    rng = random.Random(3)
    sounds = {}
    for take in range(1, 5):
        sounds["Sow%d" % take] = finish(stone_on_wood(rng), 0.3)
    for take in range(1, 3):
        sounds["Pour%d" % take] = finish(pour(rng), 0.34)
    again = []
    for index, name in enumerate(("G5", "D6")):
        add(again, marimba(note(name), rng), at=index * 0.09, gain=0.8 if index == 0 else 1.0)
    sounds["Again1"] = finish(again, 0.3)
    return sounds


def write_sound(folder, name, sound, prefix="mancala"):
    folder.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as scratch:
        raw = Path(scratch) / "sound.wav"
        with wave.open(str(raw), "wb") as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(RATE)
            out.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, value)) * 32767)) for value in sound))
        target = folder / (prefix + name + ".ogg")
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(raw), "-c:a", "libvorbis", "-q:a", "5", str(target)], check=True)


if __name__ == "__main__":
    images = Path(sys.argv[1])
    sounds_folder = Path(sys.argv[2])
    preview = Path(sys.argv[3]) if len(sys.argv) > 3 else None
    for sound_name, samples in make_sounds().items():
        write_sound(sounds_folder, sound_name, samples)
    write(images / "Icons" / "mancala.tga", render_square(64, icon), preview)
    write(images / "Mancala" / "pit.tga", render_glow(128, 128, 2 * PIT_RADIUS, 2 * PIT_RADIUS), preview)
    write(images / "Mancala" / "store.tga", render_glow(128, 256, STORE_WIDTH, STORE_HEIGHT), preview)
    write(images / "Mancala" / "seeds32.tga", render_seeds(32), preview)
    write(images / "Mancala" / "seeds64.tga", render_seeds(64), preview)
    write(images / "Mancala" / "board.tga", render_board(), preview)
