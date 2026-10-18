"""Paints the bench's pinball playfield (Tools/pinball_table.py) for Tools/make_pinball.py: its
print alone, playfieldBare.tga, which Tools/pinball_blender.py lays under the table it builds in
3D. Everything is painted where the physics has it, so a hole in the picture is where the ball
drops into it.

The table is a night sky over Moonglade: deep blue and violet, stars, a moon, rings of gold runes
round the saucer and the bumpers, and the world tree over the flippers. The light comes from the
top left.

Shapes are drawn by how far each pixel is from their edge (below zero inside), which gives smooth
edges with one sample a pixel; each is only worked out over the rectangle it covers. The sky,
which covers everything, is worked out on all the computer's cores at once.

Only the standard library is used.
"""
import math
import multiprocessing
import random
import struct
import zlib
from array import array
from pathlib import Path

import pinball_table as T

SCALE = 2  # Pixels a millimetre on the playfield
PW, PH = T.WIDTH * SCALE, T.HEIGHT * SCALE

COLOURS = {
    "gold": (1.0, 0.78, 0.25),
    "red": (1.0, 0.22, 0.18),
    "blue": (0.25, 0.55, 1.0),
    "green": (0.25, 0.95, 0.45),
    "purple": (0.75, 0.35, 1.0),
    "orange": (1.0, 0.55, 0.12),
}

GOLD = (0.95, 0.74, 0.3)
GOLD_DARK = (0.45, 0.3, 0.08)


def clamp(v, lo=0.0, hi=1.0):
    return lo if v < lo else (hi if v > hi else v)


def mix(a, b, t):
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t)


def smooth(e0, e1, x):
    t = clamp((x - e0) / (e1 - e0))
    return t * t * (3 - 2 * t)


def scale(c, k):
    return (c[0] * k, c[1] * k, c[2] * k)


#############################
# Pictures
#############################

class Picture:
    """Colour and cover of every pixel, with what is drawn laid over what was"""

    def __init__(self, width, height, per_mm_x=SCALE, per_mm_y=None, left=0.0, top=0.0):
        self.width, self.height = width, height
        self.sx = per_mm_x
        self.sy = per_mm_y or per_mm_x
        self.left, self.top = left, top
        n = width * height
        self.r = array("d", bytes(8 * n))
        self.g = array("d", bytes(8 * n))
        self.b = array("d", bytes(8 * n))
        self.a = array("d", bytes(8 * n))

    def paint(self, left, top, right, bottom, shader):
        """Lays what `shader(x, y, px)` gives, (r, g, b, a) or None, over the pixels of a rectangle
        in millimetres. px is how many millimetres a pixel is, for soft edges"""
        x0 = max(0, int((left - self.left) * self.sx) - 1)
        x1 = min(self.width, int((right - self.left) * self.sx) + 2)
        y0 = max(0, int((top - self.top) * self.sy) - 1)
        y1 = min(self.height, int((bottom - self.top) * self.sy) + 2)
        px = 1.0 / min(self.sx, self.sy)
        R, G, B, A = self.r, self.g, self.b, self.a
        for py in range(y0, y1):
            y = self.top + (py + 0.5) / self.sy
            base = py * self.width
            for qx in range(x0, x1):
                c = shader(self.left + (qx + 0.5) / self.sx, y, px)
                if c is None:
                    continue
                al = c[3]
                if al <= 0:
                    continue
                if al > 1:
                    al = 1.0
                i = base + qx
                k = 1 - al
                R[i] = c[0] * al + R[i] * k
                G[i] = c[1] * al + G[i] * k
                B[i] = c[2] * al + B[i] * k
                A[i] = al + A[i] * k

    def rows(self):
        """Rows of 0-255 (r, g, b, a), straight colour (not multiplied by cover)"""
        out = []
        for py in range(self.height):
            row = []
            for qx in range(self.width):
                i = py * self.width + qx
                al = self.a[i]
                if al > 0.0005:
                    row.append((int(clamp(self.r[i] / al) * 255 + 0.5), int(clamp(self.g[i] / al) * 255 + 0.5),
                                int(clamp(self.b[i] / al) * 255 + 0.5), int(clamp(al) * 255 + 0.5)))
                else:
                    row.append((255, 255, 255, 0))
            out.append(row)
        return out


def write(path, rows, preview=None):
    """A 32 bit TGA, rows bottom to top as the client reads them, and a PNG beside it to look at"""
    height, width = len(rows), len(rows[0])
    path = Path(path)
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, width, height, 32, 8)
    path.write_bytes(header + b"".join(bytes((b, g, r, a)) for row in reversed(rows) for (r, g, b, a) in row))
    if preview:
        raw = b"".join(b"\x00" + b"".join(bytes(p) for p in row) for row in rows)

        def chunk(kind, body):
            return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

        png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        png += chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
        Path(preview).mkdir(parents=True, exist_ok=True)
        (Path(preview) / (path.stem + ".png")).write_bytes(png)
    print(path, f"{width}x{height}")


#############################
# Distances
#############################

def seg(x, y, ax, ay, bx, by):
    """How far a point is from a segment, and how far along it the nearest point is, 0 to 1"""
    dx, dy = bx - ax, by - ay
    l2 = dx * dx + dy * dy
    t = 0.0 if l2 == 0 else clamp(((x - ax) * dx + (y - ay) * dy) / l2)
    qx, qy = ax + dx * t - x, ay + dy * t - y
    return math.sqrt(qx * qx + qy * qy), t


def cover(d, px):
    """How much of a pixel `d` from an edge is inside"""
    return clamp(0.5 - d / px)


#############################
# The sky the table is painted with
#############################

NOISE_W, NOISE_H = 64, 128


def _noise_grids():
    rng = random.Random(11)
    return [[rng.random() for _ in range((NOISE_W + 1) * (NOISE_H + 1))] for _ in range(4)]


GRIDS = _noise_grids()


def noise(x, y, grid, freq):
    """Smooth noise over the table, 0 to 1"""
    u = (x / T.WIDTH) * NOISE_W * freq / 8
    v = (y / T.HEIGHT) * NOISE_H * freq / 8
    i, j = int(u) % NOISE_W, int(v) % NOISE_H
    fu, fv = u - int(u), v - int(v)
    fu, fv = fu * fu * (3 - 2 * fu), fv * fv * (3 - 2 * fv)
    w = NOISE_W + 1
    a, b = grid[j * w + i], grid[j * w + i + 1]
    c, d = grid[(j + 1) * w + i], grid[(j + 1) * w + i + 1]
    return a + (b - a) * fu + (c - a) * fv + (a - b - c + d) * fu * fv


def fbm(x, y):
    total, amp, freq = 0.0, 0.5, 2.0
    for grid in GRIDS:
        total += noise(x, y, grid, freq) * amp
        amp *= 0.5
        freq *= 2.1
    return total / 0.9375


def inside_cabinet(x, y):
    """How far inside the cabinet's walls a point is, below zero outside"""
    if y >= 256:
        return min(x - T.LEFT_WALL, T.RIGHT_WALL - x)
    return 244 - math.hypot(x - 256, y - 256)


SKY_TOP, SKY_BOTTOM = (0.04, 0.03, 0.12), (0.03, 0.10, 0.20)
NEBULA_A, NEBULA_B = (0.36, 0.14, 0.52), (0.06, 0.42, 0.55)
WOOD_DARK, WOOD_LIGHT = (0.13, 0.06, 0.03), (0.30, 0.15, 0.07)


def sky_pixel(x, y):
    d = inside_cabinet(x, y)
    if d < -6:
        # The cabinet's wood beyond the rail, its grain running down the table
        g = math.sin(x * 0.9 + 6 * math.sin(y * 0.013) + 3 * fbm(x * 3, y * 0.4))
        g = 0.5 + 0.5 * g
        return mix(WOOD_DARK, WOOD_LIGHT, g * 0.7 + 0.15 * fbm(x * 5, y * 5))
    t = y / T.HEIGHT
    c = mix(SKY_TOP, SKY_BOTTOM, t)
    n = fbm(x, y)
    m = fbm(x + 300, y * 0.7 + 90)
    cloud = smooth(0.45, 0.85, n)
    c = mix(c, NEBULA_A, cloud * 0.55 * (1 - t * 0.6))
    c = mix(c, NEBULA_B, smooth(0.5, 0.9, m) * 0.45 * (0.4 + t * 0.6))
    # Darker towards the walls and the shooter lane, lighter in the middle
    edge = clamp(d / 70)
    c = scale(c, 0.55 + 0.45 * edge)
    if x > T.LANE and y > 330:
        c = mix(c, WOOD_DARK, 0.75)
    if d < 0:
        # The rail round the cabinet: a chrome tube seen from above, leaning outwards on its outer
        # half
        u = clamp((-d - 3) / 3, -1, 1)
        if y >= 256:
            ox, oy = (-1, 0) if x - T.LEFT_WALL < T.RIGHT_WALL - x else (1, 0)
        else:
            r = math.hypot(x - 256, y - 256) or 1
            ox, oy = (x - 256) / r, (y - 256) / r
        c = tube(u * ox, u * oy)
    return c


def chrome(s):
    """A chrome tube across from -1 to 1, lit from the top left"""
    n = clamp(1 - s * s) ** 0.5
    base = 0.25 + 0.55 * n
    spec = math.exp(-((s + 0.35) / 0.18) ** 2) * 0.9
    dark = math.exp(-((s - 0.6) / 0.25) ** 2) * 0.25
    v = clamp(base + spec - dark)
    return (v * 0.92, v * 0.95, v)


# Halfway between the light, up and to the top left, and the eye straight above, seen from above
HALF_X, HALF_Y = -0.22, -0.26


def tube(ux, uy):
    """Chrome at a point of a tube or dome whose surface leans by (ux, uy) from flat, seen from
    above: as bright as it faces the light, with a hard shine where it faces halfway between the
    light and the eye"""
    l2 = ux * ux + uy * uy
    if l2 > 1:
        ux, uy, l2 = ux / math.sqrt(l2), uy / math.sqrt(l2), 1.0
    nz = math.sqrt(1 - l2)
    base = 0.22 + 0.5 * nz + 0.18 * clamp(-(ux + uy) * 0.7)
    spec = math.exp(-((ux - HALF_X) ** 2 + (uy - HALF_Y) ** 2) / 0.03) * 0.95
    glint = math.exp(-((ux + 0.75) ** 2 + (uy + 0.6) ** 2) / 0.05) * 0.3
    v = clamp(base + spec + glint)
    return (v * 0.92, v * 0.95, v)


def _sky_rows(band):
    y0, y1 = band
    out = []
    for py in range(y0, y1):
        y = (py + 0.5) / SCALE
        row = array("d")
        for qx in range(PW):
            row.extend(sky_pixel((qx + 0.5) / SCALE, y))
        out.append(row)
    return y0, out


def paint_sky(pic):
    bands = [(y, min(PH, y + 32)) for y in range(0, PH, 32)]
    with multiprocessing.Pool() as pool:
        for y0, rows in pool.imap_unordered(_sky_rows, bands):
            for k, row in enumerate(rows):
                base = (y0 + k) * PW
                for qx in range(PW):
                    i = base + qx
                    pic.r[i], pic.g[i], pic.b[i] = row[3 * qx], row[3 * qx + 1], row[3 * qx + 2]
                    pic.a[i] = 1.0


#############################
# What is painted on the playfield
#############################

def stars(pic):
    rng = random.Random(3)
    for _ in range(420):
        x, y = rng.uniform(14, 498), rng.uniform(14, 1000)
        if inside_cabinet(x, y) < 8 or (x > T.LANE - 4 and y > 320):
            continue
        size = rng.random() ** 3 * 1.6 + 0.35
        tint = mix((1, 1, 1), (0.7, 0.85, 1.0) if rng.random() < 0.5 else (1.0, 0.85, 0.7), rng.random() * 0.6)

        def shader(px_, py_, px, x=x, y=y, size=size, tint=tint):
            d = math.hypot(px_ - x, py_ - y)
            a = math.exp(-(d / size) ** 2) + 0.25 * math.exp(-(d / (size * 3)) ** 2)
            return tint + (clamp(a * 0.9),) if a > 0.01 else None

        r = size * 5
        pic.paint(x - r, y - r, x + r, y + r, shader)
    # A few bright ones with spikes
    for _ in range(14):
        x, y = rng.uniform(30, 450), rng.uniform(40, 700)
        if inside_cabinet(x, y) < 20:
            continue

        def flare(px_, py_, px, x=x, y=y):
            dx, dy = abs(px_ - x), abs(py_ - y)
            d = math.hypot(dx, dy)
            a = math.exp(-(d / 0.9) ** 2) + 0.5 * math.exp(-dx / 0.35) * math.exp(-dy / 5) + 0.5 * math.exp(-dy / 0.35) * math.exp(-dx / 5)
            return (0.9, 0.95, 1.0, clamp(a)) if a > 0.01 else None

        pic.paint(x - 12, y - 12, x + 12, y + 12, flare)


def moon(pic, x=128, y=330, r=34):
    """A crescent moon with a glow round it"""

    def shader(px_, py_, px):
        d = math.hypot(px_ - x, py_ - y)
        glow = 0.35 * math.exp(-max(0, d - r) / 22)
        body = cover(d - r, px)
        bite = cover(math.hypot(px_ - (x + 14), py_ - (y - 9)) - r * 0.92, px)
        lit = body * (1 - bite)
        n = fbm(px_ * 8, py_ * 8)
        face = mix((0.75, 0.82, 0.95), (1.0, 1.0, 0.97), n)
        if lit > 0:
            return face + (clamp(lit + glow * (1 - lit)),)
        return (0.55, 0.65, 1.0, glow)

    pic.paint(x - r - 70, y - r - 70, x + r + 70, y + r + 70, shader)


def rune_ring(pic, x, y, r1, r2):
    """A ring of gold with runes between two circles, painted thinly on the sky"""
    rng = random.Random(9)
    glyphs = [[(rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1)) for _ in range(3)]
              for _ in range(28)]
    mid, half = (r1 + r2) / 2, (r2 - r1) / 2

    def shader(px_, py_, px):
        dx, dy = px_ - x, py_ - y
        d = math.hypot(dx, dy)
        a = 0.0
        for rr in (r1, r2, r2 + 4):
            a = max(a, cover(abs(d - rr) - 0.45, px))
        if r1 < d < r2:
            ang = math.atan2(dy, dx) % (2 * math.pi)
            k = int(ang / (2 * math.pi) * len(glyphs))
            centre = (k + 0.5) / len(glyphs) * 2 * math.pi
            # Into the glyph's own square, the ring's way and across it
            u = (ang - centre) * mid / (half * 0.8)
            v = (d - mid) / (half * 0.8)
            for (ax, ay, bx, by) in glyphs[k]:
                e, _ = seg(u, v, ax * 0.7, ay * 0.7, bx * 0.7, by * 0.7)
                a = max(a, cover(e * half * 0.8 - 0.5, px))
        if a <= 0:
            return None
        return GOLD + (a * 0.55,)

    pic.paint(x - r2 - 6, y - r2 - 6, x + r2 + 6, y + r2 + 6, shader)


def trim(pic):
    """A thin gold line inside the cabinet's rail all the way round"""

    def shader(px_, py_, px):
        d = inside_cabinet(px_, py_)
        if px_ > T.LANE - 8 and py_ > 300:
            return None
        a = max(cover(abs(d - 9) - 0.5, px), 0.6 * cover(abs(d - 12) - 0.25, px))
        return GOLD + (a * 0.8,) if a > 0 else None

    # Only over the band near the walls
    pic.paint(T.LEFT_WALL, 0, T.LEFT_WALL + 16, T.HEIGHT, shader)
    pic.paint(T.LANE - 16, 0, T.RIGHT_WALL, 300, shader)
    pic.paint(T.LEFT_WALL, 0, T.RIGHT_WALL, 270, shader)


def apron(pic):
    """The plate at the bottom of the table the ball drains under, with its gold edge"""
    top = 992

    def shader(px_, py_, px):
        d = py_ - top
        if d < -3:
            return None
        if px_ < T.LEFT_WALL or px_ > T.LANE:
            return None
        if d < 0:
            return (0, 0, 0, 0.5 * (1 + d / 3))
        g = mix((0.08, 0.07, 0.1), (0.16, 0.13, 0.18), fbm(px_ * 6, py_ * 6))
        if d < 2.5:
            g = mix(GOLD_DARK, GOLD, 1 - abs(d - 1.2) / 1.3)
        return g + (1.0,)

    pic.paint(T.LEFT_WALL, top - 4, T.LANE, T.HEIGHT, shader)


def glow_lines(pic, segments, colour, strength, soft=0.6):
    """Lines of light painted together, each pixel as bright as the nearest line makes it, so
    that where they meet isn't brighter. Each is x1, y1, x2, y2 and how wide"""
    mask = {}
    for (ax, ay, bx, by, w) in segments:
        reach = w + soft * 3
        x0, x1 = int((min(ax, bx) - reach) * SCALE), int((max(ax, bx) + reach) * SCALE) + 1
        y0, y1 = int((min(ay, by) - reach) * SCALE), int((max(ay, by) + reach) * SCALE) + 1
        for py in range(max(0, y0), min(PH, y1)):
            y = (py + 0.5) / SCALE
            for qx in range(max(0, x0), min(PW, x1)):
                d, _ = seg((qx + 0.5) / SCALE, y, ax, ay, bx, by)
                a = 1 - smooth(w - soft, w + soft * 2, d)
                if a > 0:
                    key = py * PW + qx
                    if a > mask.get(key, 0):
                        mask[key] = a
    r, g, b = colour
    for key, a in mask.items():
        a *= strength
        k = 1 - a
        pic.r[key] = r * a + pic.r[key] * k
        pic.g[key] = g * a + pic.g[key] * k
        pic.b[key] = b * a + pic.b[key] * k


def world_tree(pic, x=T.MIDDLE, y=884):
    """Nordrassil in faint gold, rising from the shoot again light between the slingshots, its
    leaves points of teal light"""
    rng = random.Random(21)
    branches, leaves = [], []

    def grow(x, y, angle, length, width, depth):
        ex, ey = x + length * math.cos(angle), y + length * math.sin(angle)
        branches.append((x, y, ex, ey, width))
        if depth == 0:
            leaves.append((ex, ey))
            return
        count = 3 if depth > 3 and rng.random() < 0.35 else 2
        spread = math.radians(rng.uniform(22, 34))
        for k in range(count):
            turn = -spread + 2 * spread * k / (count - 1) + math.radians(rng.uniform(-8, 8))
            grow(ex, ey, angle + turn * (0.85 if depth > 4 else 1.1), length * rng.uniform(0.66, 0.78), width * 0.66, depth - 1)

    grow(x, y, math.radians(-90), 66, 7, 7)
    # Roots spreading over the ground
    for angle in (160, 135, 45, 20):
        a = math.radians(angle)
        mx, my = x + 26 * math.cos(a), y + 12 * math.sin(a) + 2
        branches.append((x, y, mx, my, 3.2))
        branches.append((mx, my, mx + 14 * math.cos(a), my + 6, 1.6))
    glow_lines(pic, [(ax, ay, bx, by, w * 1.8 + 1.5) for (ax, ay, bx, by, w) in branches], GOLD, 0.08, 2.5)
    glow_lines(pic, [(ax, ay, bx, by, max(0.5, w * 0.5)) for (ax, ay, bx, by, w) in branches], GOLD, 0.32)
    for (lx, ly) in leaves:
        size = rng.uniform(1.2, 2.6)

        def leaf(px_, py_, px, lx=lx, ly=ly, size=size):
            d = math.hypot(px_ - lx, py_ - ly)
            a = math.exp(-(d / size) ** 2) * 0.6 + math.exp(-(d / (size * 3)) ** 2) * 0.12
            return (0.45, 1.0, 0.85, a) if a > 0.01 else None

        pic.paint(lx - size * 6, ly - size * 6, lx + size * 6, ly + size * 6, leaf)


def plaque(pic, x, y, w, h):
    """A dark plate with a gold edge for a row of lights to sit on"""
    r = h / 2

    def shader(px_, py_, px):
        dx, dy = abs(px_ - x) - (w / 2 - r), abs(py_ - y)
        d = math.hypot(max(dx, 0), dy) + min(dx, 0) - r if dx > 0 else dy - r
        if d > 2:
            return None
        if d > -1.6:
            return mix(GOLD_DARK, GOLD, clamp(1 - abs(d + 0.4) / 1.2)) + (cover(d - 0.6, px),)
        return (0.03, 0.03, 0.07, 0.7)

    pic.paint(x - w / 2 - 3, y - h / 2 - 3, x + w / 2 + 3, y + h / 2 + 3, shader)


def chevrons(pic, x, top, count, gap=13, w=8):
    """Gold arrows down a lane, the way the ball goes"""
    segs = []
    for k in range(count):
        y = top + k * gap
        segs.append((x - w, y, x, y + w * 0.6, 0.9))
        segs.append((x, y + w * 0.6, x + w, y, 0.9))
    glow_lines(pic, segs, GOLD, 0.45 * 1.0)


def hole(pic, x, y, r):
    """The saucer: a cup with a metal rim, black at the bottom"""

    def shader(px_, py_, px):
        d = math.hypot(px_ - x, py_ - y)
        if d > r + 4:
            return None
        if d > r:
            s = (d - r) / 4 * 2 - 1
            return chrome(s) + (cover(d - r - 3.5, px),)
        t = d / r
        c = mix((0.0, 0.0, 0.0), (0.25, 0.22, 0.3), t ** 2.5)
        # The cup lit from the top left: its far (bottom right) wall catches the light
        k = ((px_ - x) + (py_ - y)) / (r * 1.4)
        c = mix(c, (0.5, 0.45, 0.55), clamp(k) * t ** 2 * 0.6)
        return c + (1.0,)

    pic.paint(x - r - 5, y - r - 5, x + r + 5, y + r + 5, shader)


def slot(pic, left, top, right, bottom):
    """A dark slot in the wood a target drops into"""

    def shader(px_, py_, px):
        d = max(left - px_, px_ - right, top - py_, py_ - bottom)
        if d > 1.2:
            return None
        if d > 0:
            return (0.6, 0.6, 0.65, cover(d - 0.8, px))
        return (0.02, 0.02, 0.03, 1.0)

    pic.paint(left - 2, top - 2, right + 2, bottom + 2, shader)


def kicker(pic, x, y):
    """The kickback: a chrome plate with a slot the kicker's arm comes up out of"""

    def shader(px_, py_, px):
        dx, dy = px_ - x, py_ - y
        plate_d = math.hypot(max(abs(dx) - 9, 0), max(abs(dy) - 5, 0)) - 3
        if plate_d > 1:
            return None
        slot_d = max(abs(dx) - 6.5, abs(dy) - 1.6)
        if slot_d < 0:
            return (0.02, 0.02, 0.03, 1.0)
        u = clamp(dx / 12, -1, 1) * 0.5
        v = clamp(dy / 8, -1, 1) * 0.6
        c = tube(u, v)
        if slot_d < 0.8:
            c = scale(c, 0.5)
        return c + (cover(plate_d, px),)

    pic.paint(x - 14, y - 10, x + 14, y + 10, shader)


#############################
# The print
#############################


def make_bare(folder, preview=None):
    """The playfield's print alone, for Tools/pinball_blender.py to lay under the table it builds
    in 3D: the sky, the moon, the rune rings, the tree, the plaques, the holes and slots cut into
    the wood, but none of what stands on it, nor the lights, which it makes itself"""
    shapes = T.shapes()
    pic = Picture(PW, PH)
    paint_sky(pic)
    stars(pic)
    moon(pic)
    rune_ring(pic, T.MIDDLE, 450, 52, 68)
    rune_ring(pic, 256, 248, 96, 104)
    trim(pic)
    world_tree(pic)
    level = [l for l in T.lamps() if l["name"].startswith("level")]
    xs = [l["x"] for l in level]
    plaque(pic, (min(xs) + max(xs)) / 2, level[0]["y"], max(xs) - min(xs) + 30, 26)
    for x in (32, 2 * T.MIDDLE - 32):
        chevrons(pic, x, 712, 3)
    for x in (71, 2 * T.MIDDLE - 71):
        chevrons(pic, x, 742, 3)
    for s in shapes:
        role = s.get("role")
        if role == "saucer":
            hole(pic, s["x"], s["y"], 15)
        elif role == "target":
            p = s["points"]
            slot(pic, p[0] - 3.5, p[1] - 1, p[0] + 3.5, p[3] + 1)
        elif role == "kickback":
            kicker(pic, s["x"], s["y"] + 12)
    apron(pic)
    write(Path(folder) / "playfieldBare.tga", pic.rows(), preview)
