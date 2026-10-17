#!/usr/bin/env python3
"""Draws the icons of the games that have no pictures of their own to come with them: Where in
Azeroth (Games/Where.lua), Sketch (Games/Sketch.lua) and Trivia (Games/Trivia.lua), and the
addon's own.

    python3 Tools/make_icons.py Images

Writes Images/Icons/where.tga, a map with a pin in it, sketch.tga, a pencil over a drawing, and
trivia.tga, the four answers in the colours and marks Trivia gives them. And Images/icon.tga, the
gold infinity of the logo with its loops lit, which the addon list, the minimap button and
private.ICON show. Only the standard library is used. Pass a second folder to also get PNG copies there, which are easier to look at
than TGA.
"""
import math
import struct
import sys
import zlib
from pathlib import Path

SAMPLES = 4
SLATE = (34, 38, 48)


def clamp(value):
    return max(0.0, min(1.0, value))


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def rounded(x, y, half, corner):
    """How far a point is outside a square with round corners, below zero inside it"""
    dx, dy = abs(x) - half + corner, abs(y) - half + corner
    return math.hypot(max(dx, 0), max(dy, 0)) + min(max(dx, dy), 0) - corner


def to_segment(x, y, a, b):
    (ax, ay), (bx, by) = a, b
    t = clamp(((x - ax) * (bx - ax) + (y - ay) * (by - ay)) / ((bx - ax) ** 2 + (by - ay) ** 2))
    return math.hypot(x - ax - t * (bx - ax), y - ay - t * (by - ay))


def to_line(x, y, points):
    return min(to_segment(x, y, a, b) for a, b in zip(points, points[1:]))


def wobble(x, y, seed):
    """A smooth bumpiness from -1 to 1, for coastlines and paper"""
    return (
        math.sin(x * 5.1 + seed) * math.cos(y * 4.3 - seed * 0.7) * 0.6
        + math.sin(x * 11.7 - y * 9.2 + seed * 1.3) * 0.4
    )


def background(x, y):
    """The slate square with round corners that most of the icons sit on, or None outside it"""
    edge = rounded(x, y, 0.98, 0.22)
    if edge > 0:
        return None
    return SLATE if edge < -0.05 else (90, 100, 140)


#############################
# Where in Azeroth
#############################

SEA, SHALLOWS = (44, 116, 186), (92, 168, 208)
LAND, HILLS, SAND = (104, 168, 64), (70, 128, 46), (226, 206, 140)
PARCHMENT, PARCHMENT_EDGE = (226, 204, 156), (150, 112, 64)
PIN, PIN_DARK = (222, 44, 44), (130, 20, 24)
TRAIL = [(-0.52, 0.5), (-0.36, 0.22), (-0.42, -0.06), (-0.18, -0.24), (0.04, -0.1), (0.14, 0.08)]


def land(x, y):
    """How far a point is inside the land, above zero on it: two continents across a sea"""
    west = 0.5 - math.hypot((x + 0.42) / 0.62, (y - 0.08) / 0.95)
    east = 0.42 - math.hypot((x - 0.5) / 0.52, (y + 0.22) / 0.72)
    return max(west, east) + wobble(x, y, 1.0) * 0.09


def where(x, y):
    """A map unrolled on slate, with a dotted trail across it to a red pin"""
    color = background(x, y)
    if color is None:
        return (0, 0, 0), 0.0
    # The map: a sheet of parchment with a ragged edge, the world drawn on it
    sheet = rounded(x, y, 0.82, 0.06) + wobble(x * 3, y * 3, 4.0) * 0.015
    if sheet < 0:
        if sheet > -0.06:
            color = PARCHMENT_EDGE
        elif sheet > -0.13:
            color = mix(PARCHMENT, PARCHMENT_EDGE, 0.35)
        else:
            height = land(x, y)
            if height > 0.1:
                color = HILLS if wobble(x * 2, y * 2, 7.0) > 0.35 else LAND
            elif height > 0.03:
                color = LAND
            elif height > 0:
                color = SAND
            elif height > -0.06:
                color = SHALLOWS
            else:
                color = SEA
            # Faded towards the edges, like old paper
            color = mix(color, PARCHMENT, 0.08 + 0.3 * clamp((sheet + 0.4) / 0.27))
            # The trail, dots along the way
            along = to_line(x, y, TRAIL)
            if along < 0.045:
                steps = sum(math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in zip(TRAIL, TRAIL[1:]))
                if math.sin((x + y) * 42 / steps) > -0.1:
                    color = (120, 30, 24)
    # The pin, its point in the middle of the land and its head above it, with a shadow
    tip = (0.14, 0.24)
    shadow = math.hypot((x - tip[0] - 0.08) / 0.16, (y - tip[1]) / 0.06)
    if shadow < 1:
        color = mix(color, (0, 0, 0), 0.35 * (1 - shadow))
    head = (0.14, -0.3)
    radius = 0.27
    distance = math.hypot(x - head[0], y - head[1])
    # The body narrows from the head down to the point
    if tip[1] >= y >= head[1]:
        t = (y - head[1]) / (tip[1] - head[1])
        half = radius * math.sqrt(max(0, 1 - t * t)) * (1 - t) + 0.008
        body = abs(x - head[0]) - half
    else:
        body = 1
    if distance < radius or body < 0:
        shade = clamp(0.55 + 0.6 * (-(x - head[0]) - (y - head[1])) / (radius * 2))
        if min(distance - radius, body) > -0.04:
            return PIN_DARK, 1.0
        color = mix(PIN_DARK, PIN, shade)
        # A shine on the head, and the hole in it
        if math.hypot(x - head[0] + 0.09, y - head[1] + 0.09) < 0.06:
            color = mix(color, (255, 255, 255), 0.7)
        if math.hypot(x - head[0], y - head[1]) < 0.085:
            color = (250, 236, 220) if math.hypot(x - head[0], y - head[1]) < 0.06 else PIN_DARK
    return color, 1.0


#############################
# Sketch
#############################

PAPER, PAPER_SHADE = (246, 242, 230), (196, 188, 170)
PENCIL, PENCIL_DARK = (250, 196, 40), (196, 130, 20)
WOOD, LEAD = (238, 200, 150), (50, 50, 56)
ERASER, FERRULE = (240, 128, 140), (176, 180, 188)
# A house the pencil is drawing, line by line, in the box the paper fills
HOUSE = [
    [(-0.52, 0.42), (-0.52, -0.08), (-0.14, -0.42), (0.24, -0.08), (0.24, 0.42), (-0.52, 0.42)],
    [(-0.3, 0.42), (-0.3, 0.12), (-0.12, 0.12), (-0.12, 0.42)],
]
SUN = (0.42, -0.48)
# Where the pencil's point touches the paper and which way it leans
POINT = (0.24, 0.18)
LEAN = (math.cos(math.radians(-40)), math.sin(math.radians(-40)))


def pencil(x, y):
    """A pencil from its point up and to the right: colour, alpha"""
    rx, ry = x - POINT[0], y - POINT[1]
    along = rx * LEAN[0] + ry * LEAN[1]
    across = -rx * LEAN[1] + ry * LEAN[0]
    half = 0.11
    if along < 0 or along > 1.3:
        return None
    # The sharpened end: lead, then wood, widening to the pencil's width
    if along < 0.26:
        if abs(across) > half * along / 0.26:
            return None
        return (LEAD if along < 0.09 else WOOD), 1.0
    if abs(across) > half:
        return None
    if along < 1.0:
        # Three faces, lit from the top left
        face = PENCIL if across < -half / 3 else (PENCIL_DARK if across > half / 3 else mix(PENCIL, PENCIL_DARK, 0.4))
        return face, 1.0
    if along < 1.1:
        return (FERRULE if int(along * 60) % 2 else (140, 144, 152)), 1.0
    return ERASER, 1.0


def sketch(x, y):
    """A sheet of paper on slate with a house and a sun drawn on it, and the pencil drawing them"""
    color = background(x, y)
    if color is None:
        return (0, 0, 0), 0.0
    # The paper, turned a little and with a shadow under it
    turn = math.radians(-6)
    px, py = x * math.cos(turn) - y * math.sin(turn), x * math.sin(turn) + y * math.cos(turn)
    if rounded(px - 0.04, py - 0.05, 0.74, 0.05) < 0:
        color = mix(color, (0, 0, 0), 0.4)
    sheet = rounded(px, py, 0.74, 0.05)
    if sheet < 0:
        color = mix(PAPER, PAPER_SHADE, clamp((py + 0.74) / 1.48) * 0.35)
        # The drawing, in the paper's own turn so that it lies on the sheet
        ink = min(to_line(px, py, line) for line in HOUSE)
        ring = abs(math.hypot(px - SUN[0], py - SUN[1]) - 0.13)
        if ink < 0.04:
            color = (40, 70, 160)
        elif ring < 0.035:
            color = (232, 120, 30)
        else:
            for k in range(8):
                angle = k * math.pi / 4
                ray = [(SUN[0] + math.cos(angle) * 0.2, SUN[1] + math.sin(angle) * 0.2),
                       (SUN[0] + math.cos(angle) * 0.27, SUN[1] + math.sin(angle) * 0.27)]
                if to_line(px, py, ray) < 0.025:
                    color = (232, 120, 30)
    # The pencil's shadow, then the pencil
    shade = pencil(x - 0.05, y - 0.06)
    if shade is not None:
        color = mix(color, (0, 0, 0), 0.35)
    drawn = pencil(x, y)
    if drawn is not None:
        return drawn
    return color, 1.0


#############################
# Trivia
#############################

# The answers' colours, as Games/Trivia.lua gives them, each with its raid mark: star, circle,
# diamond and triangle
ANSWERS = ((242, 204, 26), (242, 128, 26), (178, 76, 230), (64, 191, 64))


def mark(kind, x, y):
    """How far a point is outside a mark, below zero inside it, in a box from -1 to 1"""
    if kind == 0:
        # A star of five points
        angle = math.atan2(x, -y)
        spoke = math.pi / 5
        t = abs(((angle % (2 * spoke)) - spoke) / spoke)
        reach = 0.32 + 0.38 * t ** 2.2
        return math.hypot(x, y) - reach
    if kind == 1:
        return math.hypot(x, y) - 0.52
    if kind == 2:
        return (abs(x) / 0.5 + abs(y) / 0.68 - 1) * 0.4
    # A triangle with its point up at (0, -0.55) and its base along y = 0.42
    return max(y - 0.42, 0.87 * abs(x) - 0.493 * (y + 0.55))


def trivia(x, y):
    """Four answer tiles on slate, each with its mark in white"""
    color = background(x, y)
    if color is None:
        return (0, 0, 0), 0.0
    column, row = (0 if x < 0 else 1), (0 if y < 0 else 1)
    index = row * 2 + column
    tx, ty = (x - (column - 0.5) * 0.9) / 0.4, (y - (row - 0.5) * 0.9) / 0.4
    tile = rounded(tx, ty, 0.98, 0.22)
    if tile > 0:
        return color, 1.0
    tint = ANSWERS[index]
    # A little lighter at the top of each tile, and a darker lip at the bottom
    face = mix(tint, (255, 255, 255), 0.15 * clamp(-ty))
    if ty > 0.72 and tile > -0.26:
        face = mix(tint, (0, 0, 0), 0.25)
    inside = mark(index, tx, ty + 0.04)
    if inside < 0:
        return (255, 255, 255), 1.0
    if mark(index, tx - 0.06, ty - 0.02) < 0:
        return mix(face, (0, 0, 0), 0.25), 1.0
    return face, 1.0


#############################
# Forever Games
#############################

GOLD, GOLD_LIGHT, GOLD_DARK = (214, 160, 70), (255, 232, 160), (110, 66, 24)
DEEP, NIGHT = (22, 62, 112), (6, 16, 38)
CYAN, CYAN_DARK = (150, 250, 255), (20, 130, 170)
# The infinity: a lemniscate this wide, as points along it
REACH = 0.74
LOOP = [
    (REACH * math.cos(t) / (1 + math.sin(t) ** 2), REACH * math.sin(t) * math.cos(t) / (1 + math.sin(t) ** 2))
    for t in (k * 2 * math.pi / 160 for k in range(161))
]
BAND = 0.11


def gem(x, y, cx, cy, size):
    """A cut gem, a diamond lit from the top left: colour, or None off it"""
    dx, dy = (x - cx) / size, (y - cy) / (size * 1.4)
    if abs(dx) + abs(dy) > 1:
        return None
    if abs(dx) + abs(dy) > 0.72:
        return GOLD_DARK
    return mix(CYAN, CYAN_DARK, clamp(0.5 + (dx + dy) * 0.6))


def forevergames(x, y):
    """The infinity of the logo in gold on deep blue, its loops glowing, in a gold frame"""
    edge = rounded(x, y, 0.98, 0.22)
    if edge > 0:
        return (0, 0, 0), 0.0
    # The frame, lit at the top and a dark groove inside it
    if edge > -0.1:
        return mix(GOLD_LIGHT, GOLD_DARK, clamp(0.3 + y * 0.4 + abs(edge + 0.05) * 6)), 1.0
    if edge > -0.14:
        return GOLD_DARK, 1.0
    color = mix(DEEP, NIGHT, clamp(math.hypot(x, y * 1.2) / 1.1))
    # The loops, filled with a light that is brightest in the middle of each
    inside = (x * x + y * y) ** 2 - REACH**2 * (x * x - y * y)
    if inside < 0:
        heart = math.hypot((abs(x) - REACH * 0.62) / 0.3, y / 0.2)
        color = mix(CYAN, CYAN_DARK, clamp(heart * 0.85))
    else:
        color = mix(color, CYAN_DARK, 0.5 * clamp(1 - math.hypot(x / 0.95, y / 0.5)))
    for spot in ((0, -0.6, 0.13), (0, 0.6, 0.13)):
        shine = gem(x, y, *spot)
        if shine is not None:
            return shine, 1.0
    if abs(y) > 0.42 or abs(x) > REACH + BAND:
        return color, 1.0
    # The band, rounded: light along its middle, dark at its rim, and lit from above
    along = to_line(x, y, LOOP)
    if along < BAND:
        if along > BAND - 0.03:
            return GOLD_DARK, 1.0
        round_ = 1 - (along / BAND) ** 2
        face = mix(GOLD_DARK, GOLD, clamp(round_ * 2.2))
        return mix(face, GOLD_LIGHT, clamp((round_ - 0.55) * 1.6 - y * 0.7)), 1.0
    return color, 1.0


def render(size, paint):
    """Rows of (r, g, b, a) from a function of a point in a square from -1 to 1"""
    rows = []
    for py in range(size):
        row = []
        for px in range(size):
            red = green = blue = alpha = 0.0
            for i in range(SAMPLES):
                for j in range(SAMPLES):
                    x = (px + (i + 0.5) / SAMPLES) / size * 2 - 1
                    y = (py + (j + 0.5) / SAMPLES) / size * 2 - 1
                    color, a = paint(x, y)
                    red, green, blue, alpha = red + color[0] * a, green + color[1] * a, blue + color[2] * a, alpha + a
            if alpha > 0:
                row.append((round(red / alpha), round(green / alpha), round(blue / alpha), round(255 * alpha / SAMPLES**2)))
            else:
                # White where nothing is, so that an icon shrunk on screen doesn't get a dark rim
                row.append((255, 255, 255, 0))
        rows.append(row)
    return rows


def write(path, rows, preview):
    size = len(rows)
    path.parent.mkdir(parents=True, exist_ok=True)
    # TGA rows run bottom to top
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, size, size, 32, 8)
    path.write_bytes(header + b"".join(bytes((b, g, r, a)) for row in reversed(rows) for (r, g, b, a) in row))
    if preview:
        raw = b"".join(b"\x00" + b"".join(bytes(pixel) for pixel in row) for row in rows)

        def chunk(kind, body):
            return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

        png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
        png += chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
        preview.mkdir(parents=True, exist_ok=True)
        (preview / (path.stem + ".png")).write_bytes(png)


target = Path(sys.argv[1])
preview = Path(sys.argv[2]) if len(sys.argv) > 2 else None
for name, paint in (("where", where), ("sketch", sketch), ("trivia", trivia)):
    write(target / "Icons" / (name + ".tga"), render(64, paint), preview)
write(target / "icon.tga", render(64, forevergames), preview)
