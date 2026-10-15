"""Courses for the kart racer: the ground, the road round it and what stands beside it.

    python3 Tools/make_course.py <out dir> [course ...]      courses: meadow, tanaris (both if none said)

A course is a square map WORLD units across. For each one this writes into <out dir>:

  <Id>.lua       what the Lua side needs: how high the ground is every CELL units, the middle of the
                 road every few units round it, the client's ground tile, the pictures and where
                 every model (a cactus, a water tower) stands. Engine/Course.lua registers it
  <id>.tga       the map seen from above, laid over a tile of ground that repeats: see-through where
                 the tile shows, darkened where the sun doesn't reach, the road and rock on top
  <id>full.tga   the same with the course's own tile baked under it, for one picture rather than two
  <id>tile.tga   the course's own tile of ground, which repeats, for when the client's can't be had
  <id>sky.tga    the sky all round, a quarter turn of it across, which repeats. Its bottom row is the
                 haze the far ground fades into

and, for every course, wedgerise.tga and wedgefall.tga: the masks GUI/TerrainView.lua cuts a hill's
outline with, seen below a line across them rising to the right or falling.

How the overlay works: a spot of the map has a colour of its own X (road, rock...) covering `cover`
of it, the tile showing through the rest, all lit by the sun to `shade`. What should be seen there
is shade * (tile * (1 - cover) + X * cover). The overlay, blended over the tile, shows
tile * (1 - a) + C * a, so it is drawn with a = 1 - shade * (1 - cover) and C = X * shade * cover / a.

Beyond the map the ground goes on rising, OUTSIDE_RISE units for every unit further out, and the
renderer stretches the overlay's edge over it. So the heights rise towards the edge at that rate
(the rim), and the overlay's outer ring is the same everywhere: nothing but the flat ground's light.

Map coordinates: x to the right, y down, as the pictures' rows go. A heading is atan2(dy, dx) in
them. The road goes round with point 1 of `track` on the start line; signed distances across it
are positive to the right of the way it is driven.
"""

import math
import random
import struct
import sys
import time
import zlib
from pathlib import Path

WORLD = 1024
SIZE, CELL = 129, 8
PICTURE, TILE = 2048, 256
SKY_WIDTH, SKY_HEIGHT = 1024, 256
HALF, CURB, SHOULDER = 26.0, 4.0, 12.0
BAND = HALF + CURB + SHOULDER
CURB_LENGTH, DASH_LENGTH = 8.0, 14.0
# Units between two points of the road's middle
SPACING = 4.0
SUN = (-0.5, -0.6, 0.62)
# The rim: the last RIM units of the map rise towards its edge as the ground beyond it goes on
# rising (Hills.lua and Engine/Course.lua, rise and highest), RIM_FROM high where they begin
RIM, RIM_FROM, OUTSIDE_RISE, OUTSIDE_HIGHEST = 110.0, 25.0, 0.3, 110
# The outer ring of the overlay, all one: the renderer stretches it beyond the map
EDGE = 60.0
# Rock shows where the ground is this steep, give or take noise that breaks up its edge, and not
# this near the map's edge
STEEP_NOISE, ROCK_FROM = 0.22, 60.0


def sun():
    length = math.sqrt(sum(v * v for v in SUN))
    return tuple(v / length for v in SUN)


SUN_N = sun()
# How light flat ground is, which the rim and the ground beyond the map are
FLAT = 0.45 + 0.6 * SUN_N[2]


# --------------------------------------------------------------------------------------------
# Noise and colour

def grain(x, y, salt):
    h = (x * 73856093) ^ (y * 19349663) ^ (salt * 83492791)
    h = (h ^ (h >> 13)) * 1274126177
    return ((h ^ (h >> 16)) & 255) / 255.0


def value_noise(x, y, salt):
    i, j = math.floor(x), math.floor(y)
    fx, fy = x - i, y - j
    fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    top = grain(i, j, salt) + (grain(i + 1, j, salt) - grain(i, j, salt)) * fx
    bottom = grain(i, j + 1, salt) + (grain(i + 1, j + 1, salt) - grain(i, j + 1, salt)) * fx
    return top + (bottom - top) * fy


def periodic_noise(x, y, period, salt):
    """value_noise that repeats every `period` both ways"""
    i, j = math.floor(x), math.floor(y)
    fx, fy = x - i, y - j
    fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    i0, i1, j0, j1 = i % period, (i + 1) % period, j % period, (j + 1) % period
    top = grain(i0, j0, salt) + (grain(i1, j0, salt) - grain(i0, j0, salt)) * fx
    bottom = grain(i0, j1, salt) + (grain(i1, j1, salt) - grain(i0, j1, salt)) * fx
    return top + (bottom - top) * fy


def smoothstep(edge0, edge1, x):
    t = min(1.0, max(0.0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)


def clamp(v):
    return 0 if v < 0 else 255 if v > 255 else int(v)


def mix(c1, c2, t):
    return tuple(p + (q - p) * t for p, q in zip(c1, c2))


def write_tga(path, rows):
    height, width = len(rows), len(rows[0]) // 4
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, width, height, 32, 8)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as out:
        out.write(header)
        # Rows are written bottom up
        for row in reversed(rows):
            out.write(row)
    print(path)


def write_png(path, rows):
    """For looking at: rows of (r, g, b) tuples"""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    raw = b"".join(b"\0" + bytes(v for px in row for v in px) for row in rows)
    head = struct.pack(">IIBBBBB", len(rows[0]), len(rows), 8, 2, 0, 0, 0)
    Path(path).write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", head) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


# --------------------------------------------------------------------------------------------
# The road's middle

def catmull_rom(points, per=60):
    """A closed curve through `points`, as many short straight pieces"""
    out, n = [], len(points)
    for k in range(n):
        p0, p1, p2, p3 = points[k - 1], points[k], points[(k + 1) % n], points[(k + 2) % n]
        for step in range(per):
            t = step / per
            t2, t3 = t * t, t * t * t
            out.append(tuple(0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                             for a, b, c, d in zip(p0, p1, p2, p3)))
    return out


def resample(dense, start):
    """The closed curve `dense` again at even spacing as near SPACING as comes out whole, from
    the point of it nearest `start`. Returns the points and the spacing"""
    n = len(dense)
    first = min(range(n), key=lambda k: (dense[k][0] - start[0]) ** 2 + (dense[k][1] - start[1]) ** 2)
    dense = dense[first:] + dense[:first]
    lengths = [math.dist(dense[k], dense[(k + 1) % n]) for k in range(n)]
    total = sum(lengths)
    count = round(total / SPACING)
    spacing = total / count
    points, k, walked = [], 0, 0.0
    for index in range(count):
        want = index * spacing
        while walked + lengths[k] < want:
            walked += lengths[k]
            k += 1
        t = (want - walked) / lengths[k]
        a, b = dense[k], dense[(k + 1) % n]
        points.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
    return points, spacing


class Track:
    def __init__(self, points, spacing):
        self.points, self.spacing = points, spacing
        self.count = len(points)
        self.length = self.count * spacing

    def at(self, progress, offset=0.0):
        """Where the road is `progress` units round from the start line, `offset` to the right of
        its middle, and which way it goes there"""
        progress %= self.length
        k = int(progress / self.spacing)
        t = progress / self.spacing - k
        a, b = self.points[k % self.count], self.points[(k + 1) % self.count]
        dx, dy = (b[0] - a[0]) / self.spacing, (b[1] - a[1]) / self.spacing
        x, y = a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t
        # The right of heading (dx, dy), with y down, is (-dy, dx)
        return x - dy * offset, y + dx * offset, math.atan2(dy, dx)

    def nearest(self, x, y):
        """How far (x, y) is from the road's middle, positive to its right, and how far round it is"""
        best = None
        for k in range(self.count):
            a, b = self.points[k], self.points[(k + 1) % self.count]
            dx, dy = b[0] - a[0], b[1] - a[1]
            t = min(1.0, max(0.0, ((x - a[0]) * dx + (y - a[1]) * dy) / (dx * dx + dy * dy)))
            qx, qy = a[0] + dx * t, a[1] + dy * t
            d = (x - qx) ** 2 + (y - qy) ** 2
            if best is None or d < best[0]:
                side = 1 if dx * (y - a[1]) - dy * (x - a[0]) >= 0 else -1
                best = (d, side, (k + t) * self.spacing)
        return math.sqrt(best[0]) * best[1], best[2]

    def field(self, step, n, radius):
        """For every point (i * step, j * step) of an n by n grid within `radius` of the road's
        middle: how far from it, signed, and how far round. Others are None"""
        signed, round_ = [None] * (n * n), [0.0] * (n * n)
        best = [radius * radius] * (n * n)
        for k in range(self.count):
            a, b = self.points[k], self.points[(k + 1) % self.count]
            dx, dy = b[0] - a[0], b[1] - a[1]
            length2 = dx * dx + dy * dy
            i0 = max(0, int((min(a[0], b[0]) - radius) / step))
            i1 = min(n - 1, int((max(a[0], b[0]) + radius) / step) + 1)
            j0 = max(0, int((min(a[1], b[1]) - radius) / step))
            j1 = min(n - 1, int((max(a[1], b[1]) + radius) / step) + 1)
            for j in range(j0, j1 + 1):
                py = j * step
                ry = py - a[1]
                at = j * n
                for i in range(i0, i1 + 1):
                    rx = i * step - a[0]
                    t = (rx * dx + ry * dy) / length2
                    t = 0.0 if t < 0 else 1.0 if t > 1 else t
                    ex, ey = rx - dx * t, ry - dy * t
                    d = ex * ex + ey * ey
                    if d < best[at + i]:
                        best[at + i] = d
                        d = math.sqrt(d)
                        signed[at + i] = d if dx * ry - dy * rx >= 0 else -d
                        round_[at + i] = (k + t) * self.spacing
        return signed, round_

    def check(self):
        lengths = [math.dist(self.points[k], self.points[(k + 1) % self.count]) for k in range(self.count)]
        return min(lengths), max(lengths)


def smooth_loop(values, sigma):
    """A closed run of values, low-passed with a Gaussian `sigma` points wide"""
    n, reach = len(values), int(sigma * 3)
    weights = [math.exp(-0.5 * (k / sigma) ** 2) for k in range(-reach, reach + 1)]
    total = sum(weights)
    return [sum(values[(i + k) % n] * w for k, w in zip(range(-reach, reach + 1), weights)) / total for i in range(n)]


def limit_grade(values, most):
    """A closed run of values changing by at most `most` from one to the next"""
    values = list(values)
    n = len(values)
    for _ in range(60):
        changed = False
        for order in (range(n), range(n - 1, -1, -1)):
            for i in order:
                for j in (i - 1, (i + 1) % n):
                    if values[i] > values[j] + most:
                        values[i] = values[j] + most
                        changed = True
        if not changed:
            break
    return values


# --------------------------------------------------------------------------------------------
# Shared by the courses: lighting, rock, the road's paint

def lighting(heights):
    """How lit every point of the heightmap is, and how steep it is there"""
    shade, steepness = [], []
    for j in range(SIZE):
        shade_row, steep_row = [], []
        for i in range(SIZE):
            left, right = heights[j][max(0, i - 1)], heights[j][min(SIZE - 1, i + 1)]
            up, down = heights[max(0, j - 1)][i], heights[min(SIZE - 1, j + 1)][i]
            nx, ny = -(right - left) / (2 * CELL), -(down - up) / (2 * CELL)
            steep = math.hypot(nx, ny)
            norm = math.sqrt(nx * nx + ny * ny + 1)
            light = (nx * SUN_N[0] + ny * SUN_N[1] + SUN_N[2]) / norm
            # No lighter than the ground beyond the map can be shown, a tint not brightening. Towards
            # the map's edge as the ground beyond it is lit, evenly, as if flat
            lit = min(1.0, max(0.4, 0.45 + 0.6 * light))
            rim = min(i, j, SIZE - 1 - i, SIZE - 1 - j) * CELL
            shade_row.append(lit + (FLAT - lit) * smoothstep(RIM, RIM_FROM, rim))
            steep_row.append(steep)
        shade.append(shade_row)
        steepness.append(steep_row)
    return shade, steepness


def bilinear(grid, gx, gy):
    i, j = min(SIZE - 2, int(gx)), min(SIZE - 2, int(gy))
    fx, fy = gx - i, gy - j
    top = grid[j][i] + (grid[j][i + 1] - grid[j][i]) * fx
    bottom = grid[j + 1][i] + (grid[j + 1][i + 1] - grid[j + 1][i]) * fx
    return top + (bottom - top) * fy


def rock_cover(steepness, x, y, steep_at):
    """How much of a point is rock: where the ground is steep, in outcrops with a sharp, broken edge"""
    rim = min(x, y, WORLD - x, WORLD - y)
    steep = bilinear(steepness, x / CELL, y / CELL)
    if rim < ROCK_FROM or steep < steep_at - STEEP_NOISE:
        return 0.0
    steep += (value_noise(x / 9, y / 9, 41) - 0.5) * STEEP_NOISE * 1.4 + (value_noise(x / 3, y / 3, 42) - 0.5) * STEEP_NOISE * 0.6
    return smoothstep(steep_at - 0.02, steep_at + 0.02, steep) * smoothstep(ROCK_FROM, ROCK_FROM + 30, rim)


ASPHALT = (62, 62, 68)
WHITE_LINE = (225, 225, 210)
RED, WHITE = (200, 40, 36), (235, 235, 235)


def paint_road(s, run, px, qx, qy, dashes, shoulder):
    """The colour and coverage of a point of the road `s` from its middle (signed) and `run` units
    round from the start line (between -length/2 and length/2)"""
    d = abs(s)
    if d < HALF:
        g = (grain(qx, qy, 1) - 0.5) * 18
        colour = tuple(v + g for v in ASPHALT)
        # The start line, a band of black and white squares across the road
        if abs(run) < 6:
            square = (math.floor(s / 4) + math.floor(run / 4)) % 2
            colour = WHITE if square else (20, 20, 20)
        elif d < 0.9 and math.floor(run / DASH_LENGTH) % 2 == 0:
            colour = dashes
        elif abs(d - (HALF - 2.5)) < 0.6:
            colour = WHITE_LINE
        edge = min(1.0, max(0.0, (d - HALF) / px + 0.5))
        if edge > 0:
            colour = mix(colour, RED, edge)
        return colour, 1.0
    if d < HALF + CURB:
        colour = RED if math.floor(run / CURB_LENGTH) % 2 == 0 else WHITE
        g = (grain(qx, qy, 2) - 0.5) * 10
        return tuple(v + g for v in colour), 1.0
    fade = 1 - (d - HALF - CURB) / SHOULDER
    g = (grain(qx, qy, 3) - 0.5) * 40
    return tuple(v + g for v in shoulder), max(0.0, fade) ** 1.5


def heights_for(height_at):
    return [[height_at(i * CELL, j * CELL) for i in range(SIZE)] for j in range(SIZE)]


def rim_blend(x, y, h, base):
    """The rim: towards the map's edge the ground gives way to a slope rising at OUTSIDE_RISE,
    `base` high where it begins"""
    rim = min(x, y, WORLD - x, WORLD - y)
    if rim < RIM:
        h += (base + (RIM - rim) * OUTSIDE_RISE - h) * smoothstep(RIM, 0, rim)
    return h


# --------------------------------------------------------------------------------------------
# Drawing a course's pictures

def pictures(course, heights, tile):
    """The overlay and the full picture, rows of BGRA"""
    shade, steepness = lighting(heights)
    track = course.track
    px = WORLD / PICTURE
    # Where the road is, every 2 units, to look up for each pixel
    step = 2.0
    n = int(WORLD / step) + 1
    signed, round_ = track.field(step, n, BAND + 4)
    length = track.length
    tile_size = len(tile)
    tile_units = course.tile_units
    surface = course.surface
    steep_at = course.steep_at
    overlay_rows, full_rows = [], []
    for py in range(PICTURE):
        y = (py + 0.5) * px
        gy = y / CELL
        j = min(SIZE - 2, int(gy))
        fy = gy - j
        shade_top, shade_bottom = shade[j], shade[j + 1]
        steep_top, steep_bottom = steepness[j], steepness[j + 1]
        fj = min(n - 2, int(y / step))
        ffy = y / step - fj
        tile_row = tile[int((y / tile_units % 1) * tile_size)]
        overlay, full = bytearray(PICTURE * 4), bytearray(PICTURE * 4)
        edge_y = min(y, WORLD - y)
        for qx in range(PICTURE):
            x = (qx + 0.5) * px
            at = int((x / tile_units % 1) * tile_size) * 4
            tb, tg, tr = tile_row[at], tile_row[at + 1], tile_row[at + 2]
            o = qx * 4
            if min(x, WORLD - x, edge_y) < EDGE:
                # The outer ring: flat light only
                a = 1 - FLAT
                overlay[o:o + 4] = (0, 0, 0, clamp(a * 255 + 0.5))
                full[o:o + 4] = (clamp(tb * FLAT), clamp(tg * FLAT), clamp(tr * FLAT), 255)
                continue
            gx = x / CELL
            i = min(SIZE - 2, int(gx))
            fx = gx - i
            top = shade_top[i] + (shade_top[i + 1] - shade_top[i]) * fx
            light = top + (shade_bottom[i] + (shade_bottom[i + 1] - shade_bottom[i]) * fx - top) * fy
            top = steep_top[i] + (steep_top[i + 1] - steep_top[i]) * fx
            steep = top + (steep_bottom[i] + (steep_bottom[i + 1] - steep_bottom[i]) * fx - top) * fy
            # What covers the tile here, layer over layer: the course's own ground, rock, the road
            cr = cg = cb = 0.0
            cover = 0.0
            layer = surface(x, y, qx, py, steep)
            if layer:
                (cr, cg, cb), cover = layer
            if steep > steep_at - STEEP_NOISE:
                stone = rock_cover(steepness, x, y, steep_at)
                if stone > 0:
                    sr, sg, sb = course.rock(x, y, qx, py, heights)
                    keep = cover * (1 - stone)
                    cover = keep + stone
                    cr, cg, cb = (cr * keep + sr * stone) / cover, (cg * keep + sg * stone) / cover, (cb * keep + sb * stone) / cover
            fi = min(n - 2, int(x / step))
            c00 = signed[fj * n + fi]
            if c00 is not None or signed[fj * n + fi + 1] is not None or signed[(fj + 1) * n + fi] is not None \
                    or signed[(fj + 1) * n + fi + 1] is not None:
                corners = [(signed[(fj + b) * n + fi + c], round_[(fj + b) * n + fi + c]) for b in (0, 1) for c in (0, 1)]
                if all(v[0] is not None for v in corners):
                    ffx = x / step - fi
                    base = corners[0][1]
                    runs = []
                    for _, r in corners:
                        if r - base > length / 2:
                            r -= length
                        elif base - r > length / 2:
                            r += length
                        runs.append(r)
                    s = (corners[0][0] * (1 - ffx) + corners[1][0] * ffx) * (1 - ffy) + (corners[2][0] * (1 - ffx) + corners[3][0] * ffx) * ffy
                    run = (runs[0] * (1 - ffx) + runs[1] * ffx) * (1 - ffy) + (runs[2] * (1 - ffx) + runs[3] * ffx) * ffy
                    run = (run + length / 2) % length - length / 2
                    if abs(s) < BAND:
                        (rr, rg, rb), k = paint_road(s, run, px, qx, py, course.dashes, course.shoulder)
                        if k > 0:
                            keep = cover * (1 - k)
                            cover = keep + k
                            cr, cg, cb = (cr * keep + rr * k) / cover, (cg * keep + rg * k) / cover, (cb * keep + rb * k) / cover
            a = 1 - light * (1 - cover)
            if a > 0:
                f = light * cover / a
                overlay[o:o + 4] = (clamp(cb * f), clamp(cg * f), clamp(cr * f), clamp(a * 255 + 0.5))
            full[o:o + 4] = (clamp(light * (tb * (1 - cover) + cb * cover)), clamp(light * (tg * (1 - cover) + cg * cover)),
                             clamp(light * (tr * (1 - cover) + cr * cover)), 255)
        overlay_rows.append(bytes(overlay))
        full_rows.append(bytes(full))
    return overlay_rows, full_rows


def write_lua(path, course, heights):
    values = ",".join("%.1f" % v for row in heights for v in row)
    track = ",".join("%.1f,%.1f" % p for p in course.track.points)
    things = "\n".join("    { model = %d, x = %.1f, y = %.1f, size = %d, facing = %.2f }," % t for t in course.things)
    haze = ", ".join("%.4f" % (v / 255) for v in course.haze)
    name = course.id
    path.write_text(f"""-- Made by Tools/make_course.py: the {course.name} course, its ground, road and what stands beside it
local _, private = ...
private.Course.Register("{name}", {{
  name = "{course.name}",
  world = {WORLD},
  size = {SIZE}, cell = {CELL},
  heights = {{ {values} }},
  rise = {OUTSIDE_RISE}, highest = {OUTSIDE_HIGHEST},
  light = {FLAT:.4f},
  spacing = {course.track.spacing:.6f},
  track = {{ {track} }},
  half = {HALF:g}, curb = {CURB:g}, shoulder = {SHOULDER:g},
  tile = {{ file = {course.tile_file}, units = {course.tile_units:g} }},
  pictures = {{ overlay = "{name}", full = "{name}full", tile = "{name}tile", sky = "{name}sky" }},
  haze = {{ {haze} }},
  things = {{
{things}
  }},
}})
""")
    print(path)


def preview(path, course, full_rows, scale=4):
    """A top-down look at the full picture, the start line and every thing marked"""
    size = PICTURE // scale
    rows = []
    for py in range(size):
        src = full_rows[py * scale]
        rows.append([(src[q * scale * 4 + 2], src[q * scale * 4 + 1], src[q * scale * 4]) for q in range(size)])
    per = PICTURE / WORLD / scale
    for model, x, y, s, _ in course.things:
        cx, cy = int(x * per), int(y * per)
        r = max(1, int(s * per / 2))
        colour = (0, 160, 0) if model in CACTI else (40, 40, 220) if model in ROCKS else (255, 0, 255)
        for yy in range(cy - r, cy + r + 1):
            for xx in range(cx - r, cx + r + 1):
                if 0 <= xx < size and 0 <= yy < size and (abs(yy - cy) == r or abs(xx - cx) == r):
                    rows[yy][xx] = colour
    x, y, _ = course.track.at(0)
    for d in range(-4, 5):
        for e in range(-1, 2):
            xx, yy = int(x * per) + e, int(y * per) + d
            if 0 <= xx < size and 0 <= yy < size:
                rows[yy][xx] = (255, 255, 0)
    write_png(path, rows)


# --------------------------------------------------------------------------------------------
# Meadow: the bench's first circuit, as make_images.py drew it

MEADOW_R, MEADOW_A, MEADOW_B, MEADOW_C = 360.0, 0.18, 0.10, 0.6
KICKER, KICKER_LENGTH, KICKER_HEIGHT = 1.45, 36.0, 9.0
MEADOW_HAZE = (175, 205, 235)


def meadow_radius(a):
    return MEADOW_R * (1 + MEADOW_A * math.cos(2 * a) + MEADOW_B * math.sin(3 * a + MEADOW_C))


def meadow_slope(a):
    return MEADOW_R * (-2 * MEADOW_A * math.sin(2 * a) + 3 * MEADOW_B * math.cos(3 * a + MEADOW_C))


def meadow_across(x, y):
    dx, dy = x - WORLD / 2, y - WORLD / 2
    a = math.atan2(dy, dx)
    r = meadow_radius(a)
    s = meadow_slope(a) / r
    return (math.hypot(dx, dy) - r) / math.sqrt(1 + s * s), a


def meadow_road_height(a):
    height = 26 * math.sin(2 * a + 0.3) + 14 * math.sin(5 * a + 1.1)
    run = ((a - KICKER + math.pi) % (2 * math.pi) - math.pi) * MEADOW_R
    if 0 <= run < KICKER_LENGTH:
        height += KICKER_HEIGHT * (run / KICKER_LENGTH) ** 1.5
    return height


def meadow_height(x, y):
    s, a = meadow_across(x, y)
    hills = 70 * value_noise(x / 256, y / 256, 31) + 30 * value_noise(x / 128, y / 128, 32) + 10 * value_noise(x / 64, y / 64, 33)
    hills = rim_blend(x, y, hills, RIM_FROM + 40)
    road = meadow_road_height(a)
    away = smoothstep(HALF + CURB + SHOULDER + 4, HALF + 130, abs(s))
    return road + (hills - 40 - road) * away


def grass(size=TILE):
    period = 16

    def lattice(i, j):
        return grain(i % period, j % period, 7)

    def smooth(x, y):
        i, j = math.floor(x), math.floor(y)
        fx, fy = x - i, y - j
        fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
        top = lattice(i, j) + (lattice(i + 1, j) - lattice(i, j)) * fx
        bottom = lattice(i, j + 1) + (lattice(i + 1, j + 1) - lattice(i, j + 1)) * fx
        return top + (bottom - top) * fy

    rows = []
    for y in range(size):
        row = bytearray()
        for x in range(size):
            n = smooth(x * period / size, y * period / size)
            fine = grain(x, y, 9)
            g = 0.75 + 0.35 * n + 0.15 * (fine - 0.5)
            r, gr, b = 52 * g, 112 * g, 40 * g
            row += bytes((clamp(b), clamp(gr), clamp(r), 255))
        rows.append(bytes(row))
    return rows


def meadow_sky():
    sky_top, horizon = (58, 108, 196), MEADOW_HAZE
    hills_far, hills_near = (120, 160, 170), (78, 128, 92)

    def lattice(i, j, period, salt):
        return grain(i % period, j, salt)

    def smooth(x, y, period, salt):
        i, j = math.floor(x), math.floor(y)
        fx, fy = x - i, y - j
        fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
        top = lattice(i, j, period, salt) + (lattice(i + 1, j, period, salt) - lattice(i, j, period, salt)) * fx
        bottom = lattice(i, j + 1, period, salt) + (lattice(i + 1, j + 1, period, salt) - lattice(i, j + 1, period, salt)) * fx
        return top + (bottom - top) * fy

    def clouds(u, v):
        total, amount, period = 0.0, 0.5, 6
        for octave in range(5):
            total += amount * smooth(u * period, v * period * 0.35, period, 20 + octave)
            amount, period = amount / 2, period * 2
        return total

    def ridge(u, waves, base, rise):
        return base + rise * sum(math.sin(2 * math.pi * (k * u + phase)) / k for k, phase in waves)

    rows = []
    for y in range(SKY_HEIGHT):
        row = bytearray()
        v = y / (SKY_HEIGHT - 1)
        for x in range(SKY_WIDTH):
            u = x / SKY_WIDTH
            colour = mix(sky_top, horizon, v ** 1.6)
            density = clouds(u, v) - 0.6 + 0.12 * (1 - v)
            cover = min(1.0, max(0.0, density * 3.5)) * (1 - v ** 3)
            if cover > 0:
                lit = mix((255, 255, 255), (205, 215, 232), min(1.0, max(0.0, (density - 0.1) * 2)))
                colour = mix(colour, lit, cover)
            far = ridge(u, ((2, 0.1), (3, 0.6), (5, 0.3), (9, 0.8)), 0.86, 0.035)
            near = ridge(u, ((1, 0.4), (4, 0.15), (7, 0.7), (11, 0.2)), 0.92, 0.03)
            if v > near:
                colour = mix(hills_near, horizon, ((v - near) / (1 - near)) ** 2)
            elif v > far:
                colour = mix(hills_far, horizon, 0.35 + 0.65 * ((v - far) / (1 - far)) ** 2)
            if y >= SKY_HEIGHT - 2:
                colour = horizon
            row += bytes((clamp(colour[2]), clamp(colour[1]), clamp(colour[0]), 255))
        rows.append(bytes(row))
    return rows


MEADOW_ROCK = (122, 112, 98)


class Meadow:
    id, name = "meadow", "Meadow"
    tile_file, tile_units = '"Tileset\\\\Elwynn\\\\ElwynnGrassBase"', 40.0
    haze = MEADOW_HAZE
    dashes, shoulder = WHITE_LINE, (128, 100, 66)
    steep_at = 0.45

    def __init__(self):
        # Point 1 at a = 0, the way round as a grows
        dense = []
        for k in range(20000):
            a = 2 * math.pi * k / 20000
            r = meadow_radius(a)
            dense.append((WORLD / 2 + r * math.cos(a), WORLD / 2 + r * math.sin(a)))
        points, spacing = resample(dense, dense[0])
        self.track = Track(points, spacing)
        self.things = []

    def height(self, x, y):
        return meadow_height(x, y)

    def surface(self, x, y, qx, qy, steep):
        return None

    def rock(self, x, y, qx, qy, heights):
        blotch = (value_noise(x / 5, y / 5, 43) - 0.5) * 36
        crack = -40 * smoothstep(0.06, 0.0, abs(value_noise(x / 7, y / 3.5, 44) - 0.5))
        n = blotch + crack + (grain(qx, qy, 5) - 0.5) * 14
        return MEADOW_ROCK[0] + n, MEADOW_ROCK[1] + n, MEADOW_ROCK[2] + n * 0.9

    def tile(self):
        return grass()

    def sky(self):
        return meadow_sky()


# --------------------------------------------------------------------------------------------
# Tanaris: Gadgetzan's own circuit, out over the dunes, through a canyon and back

CACTI = (202657, 202658, 202659, 202660, 202661, 202662)
ROCKS = (202677, 202679, 202681, 202683)
WALL, POST, WALL_CURVE = 202672, 202676, 202674
WATER_TOWER, STEEL_TOWER, OIL_TANK, PEN = 202687, 307492, 307576, 202670
BOTTLE_ROCKET, LARGE_ROCKET, CRATE, BOMBS = 254405, 254420, 254409, 254423
# Gadgetzan's buildings can't be shown (they are WMOs), so the town is made of what can: goblin
# tents for its houses and stalls, guard towers at its gates, lamp posts, signs, smokestacks and
# machines in its yards
TENTS = (197791, 197792, 197793, 197794, 197795, 197796, 197797)
GUARD_TOWERS = (309145, 309146)
LAMPS = (307162, 307164, 307166, 307167)
SIGNS = (309569, 309571, 309722, 330140, 330141)
BILLBOARDS = (321180, 322189, 326714)
SMOKESTACKS = (332767, 378620, 378621, 378622)
MACHINERY, WEATHERVANE, HUT_BOTTLES = 197767, 197768, 197766
SHREDDERS = (197789, 197790)
ROCKET_CARTS = (197779, 197780, 197781, 197782, 197783)
TNT_WAGON, BATTERY_MACHINE, ROCK_CUTTER = 197799, 311649, 328144
CRAZY_MACHINES = (315224, 317825, 309721, 314504, 309912)
FENCES = tuple(range(307336, 307346))
STANDING_ROCKET = 322442
WARNING_SIGNS = (325249, 325250)
# A length of goblin wall, units: they are laid end to end
WALL_LENGTH = 27.0

TANARIS_HAZE = (222, 200, 160)
SAND = (214, 176, 122)
# The road: Gadgetzan's asphalt with yellow dashes down the middle, edged with packed gravel
GOBLIN_YELLOW = (232, 188, 46)
GRAVEL = (168, 132, 92)
# Sandstone in bands by height, bottom up, each so many units thick, repeating
STRATA = ((196, 136, 86, 9), (171, 103, 64, 6), (214, 168, 116, 11), (150, 84, 54, 5), (188, 124, 78, 8),
          (228, 190, 140, 7), (162, 96, 60, 6), (204, 150, 98, 10))
STRATA_HEIGHT = sum(band[3] for band in STRATA)
CLAY, CRACK = (224, 204, 168), (128, 100, 72)

# Where the road goes through: the start straight in Gadgetzan heading east, up the eastern dunes
# to the jump, west through the canyon, a hairpin in the north-west and down the western dunes
TANARIS_ROAD = ((250, 842), (450, 852), (620, 836), (762, 778), (852, 668), (872, 530), (842, 404),
                (762, 306), (632, 262), (480, 258), (334, 238), (218, 250), (160, 334), (226, 430),
                (164, 528), (238, 624), (164, 724))
START = (330, 846)
# Mesas: middle, radii across and down, how high
MESAS = (((690, 452), (58, 50), 112),
         ((488, 492), (92, 80), 88),
         ((370, 598), (46, 44), 122),
         ((520, 150), (70, 34), 70))
# The canyon: the road between the points of it nearest these two, between walls this high that
# stand this far from its middle, flat-topped and falling away again further out
CANYON_FROM, CANYON_TO = (650, 266), (330, 238)
CANYON_HEIGHT, CANYON_TOP, CANYON_OUT = 92.0, 95.0, 170.0
LAKE, LAKE_RADIUS = (566, 692), 84.0
# The big hill the road climbs on the east, to the jump
EAST_HILL, EAST_HILL_RADIUS, EAST_HILL_HEIGHT = (800, 420), 230.0, 58.0
WIND = math.radians(20)
CANYON_BLEND, BLEND = 34.0, 92.0
# The jump: how far round it is from the start line, how long and high its kicker is, and the
# hollow it throws the karts over
KICK_LENGTH, KICK_HEIGHT, DIP_LENGTH, DIP_DEPTH = 40.0, 12.0, 180.0, 16.0


def dune(x, y):
    """Sand dunes across the wind: a long gentle rise to the crest, a short steeper fall"""
    warp = (value_noise(x / 140, y / 140, 61) - 0.5) * 1.6 + (value_noise(x / 60, y / 60, 62) - 0.5) * 0.35
    t = (x * math.cos(WIND) + y * math.sin(WIND)) / 190 + warp
    f = t - math.floor(t)
    shape = smoothstep(0, 0.68, f) if f < 0.68 else 1 - smoothstep(0.68, 1.0, f)
    strength = 0.45 + 0.75 * value_noise(x / 260, y / 260, 63)
    return 22 * shape * strength


def tanaris_base(x, y):
    """The sand without the mesas: big slow hills, the climb in the east, the dunes over them"""
    h = 46 * value_noise(x / 300, y / 300, 51) + 18 * value_noise(x / 140, y / 140, 52)
    d = math.dist((x, y), EAST_HILL)
    h += EAST_HILL_HEIGHT * smoothstep(EAST_HILL_RADIUS, 0, d)
    h += dune(x, y)
    # The lake bed: flat and low
    d = math.dist((x, y), LAKE)
    h += (8 - h) * smoothstep(LAKE_RADIUS + 50, LAKE_RADIUS - 10, d)
    return h


def mesa_shape(x, y, mesa):
    """How far up a mesa a point is, 0 off it to 1 on its top, in terraces"""
    (cx, cy), (rx, ry), height = mesa
    d = math.hypot((x - cx) / rx, (y - cy) / ry)
    if d > 1.5:
        return 0.0
    d += (value_noise(x / 38, y / 38, 71 + int(cx)) - 0.5) * 0.32 + (value_noise(x / 13, y / 13, 72) - 0.5) * 0.08
    rise = smoothstep(1.0, 0.62, d)
    # Terraces: ledges with steep steps between
    steps = 4
    level = rise * steps
    whole = math.floor(level)
    return min(1.0, (whole + smoothstep(0.45, 1.0, level - whole)) / steps)


def mesas_height(x, y):
    return sum(mesa[2] * mesa_shape(x, y, mesa) for mesa in MESAS)


def sand_tile(size=TILE):
    """Warm sand rippled by the wind, which repeats"""
    rows = []
    for y in range(size):
        row = bytearray()
        for x in range(size):
            u, v = x / size, y / size
            warp = periodic_noise(u * 4, v * 4, 4, 81) * 1.4
            ripple = math.sin(2 * math.pi * (9 * u + 2 * v + warp))
            ripple = ripple * 0.5 + 0.5
            blotch = periodic_noise(u * 8, v * 8, 8, 82) - 0.5
            fine = grain(x, y, 83) - 0.5
            g = 0.93 + 0.07 * ripple + 0.08 * blotch + 0.07 * fine
            speck = grain(x, y, 84)
            r, gr, b = SAND[0] * g, SAND[1] * g, SAND[2] * g
            if speck > 0.985:
                r, gr, b = r * 0.72, gr * 0.68, b * 0.62
            row += bytes((clamp(b), clamp(gr), clamp(r), 255))
        rows.append(bytes(row))
    return rows


def tanaris_sky():
    top, horizon = (74, 132, 204), TANARIS_HAZE
    mesa_far, mesa_near = (196, 162, 128), (172, 124, 88)

    def clouds(u, v):
        total, amount, period = 0.0, 0.5, 5
        for octave in range(4):
            total += amount * periodic_noise(u * period, v * period * 0.12 * period / 5 * 5, period, 90 + octave)
            amount, period = amount / 2, period * 2
        return total

    def mesas(u, salt, count, base, rise, width):
        """Flat-topped shapes along the horizon, repeating round"""
        best = 0.0
        for k in range(count):
            centre = grain(k, salt, 1)
            w = width * (0.5 + grain(k, salt, 2))
            h = rise * (0.45 + 0.55 * grain(k, salt, 3))
            d = abs((u - centre + 0.5) % 1 - 0.5)
            best = max(best, h * smoothstep(w, w * 0.7, d))
        return base - best

    rows = []
    for y in range(SKY_HEIGHT):
        row = bytearray()
        v = y / (SKY_HEIGHT - 1)
        for x in range(SKY_WIDTH):
            u = x / SKY_WIDTH
            colour = mix(top, horizon, v ** 1.35)
            density = clouds(u, v) - 0.62
            cover = min(1.0, max(0.0, density * 2.6)) * (1 - v ** 2) * 0.75
            if cover > 0:
                colour = mix(colour, (250, 246, 236), cover)
            far = mesas(u, 7, 9, 0.93, 0.07, 0.05)
            near = mesas(u, 8, 6, 0.975, 0.07, 0.04)
            if v > near:
                colour = mix(mesa_near, horizon, 0.25 + 0.75 * ((v - near) / (1 - near)) ** 1.5)
            elif v > far:
                colour = mix(mesa_far, horizon, 0.45 + 0.55 * ((v - far) / (1 - far)) ** 1.5)
            if y >= SKY_HEIGHT - 2:
                colour = horizon
            row += bytes((clamp(colour[2]), clamp(colour[1]), clamp(colour[0]), 255))
        rows.append(bytes(row))
    return rows


class Tanaris:
    id, name = "tanaris", "Tanaris"
    tile_file, tile_units = "188870", 24.0
    haze = TANARIS_HAZE
    dashes, shoulder = GOBLIN_YELLOW, GRAVEL
    steep_at = 0.75

    def __init__(self):
        points, spacing = resample(catmull_rom(TANARIS_ROAD), START)
        self.track = Track(points, spacing)
        track = self.track
        count = track.count
        # Where the jump is: the point of the climb in the east nearest its top
        self.kick = min(range(count), key=lambda k: math.dist(track.points[k], (812, 372))) * track.spacing
        # How high the road is: the sand without mesas under it, smoothed and no steeper than a
        # quarter, then the jump
        raw = [tanaris_base(*p) for p in track.points]
        profile = limit_grade(smooth_loop(raw, 55 / track.spacing), 0.22 * track.spacing)
        self.profile = [h + self.feature(k * track.spacing) for k, h in enumerate(profile)]
        # The canyon: how far into it each point of the road is, 0 outside it to 1 well in, and
        # how far each side the ground blends to the road there
        nearest = lambda spot: min(range(count), key=lambda k: math.dist(track.points[k], spot))
        first, last = nearest(CANYON_FROM), nearest(CANYON_TO)
        self.canyon_from, self.canyon_to = first * track.spacing, last * track.spacing
        self.inside = []
        for k in range(count):
            into = (k - first) % count * track.spacing
            span = (last - first) % count * track.spacing
            self.inside.append(smoothstep(0, 70, into) * smoothstep(span, span - 70, into) if into <= span else 0.0)
        self.blend = [BLEND + (CANYON_BLEND - BLEND) * smoothstep(0, 0.5, v) for v in self.inside]
        self.canyon = [k for k, v in enumerate(self.inside) if v > 0.5]
        n = SIZE
        self.signed, self.round = track.field(CELL, n, BAND + CANYON_OUT + 8)
        self.things = []

    def feature(self, progress):
        """The jump: a rise to the kicker's lip, then a hollow the karts fly over"""
        run = (progress - self.kick + self.track.length / 2) % self.track.length - self.track.length / 2
        h = 0.0
        if -KICK_LENGTH <= run < 0:
            h += KICK_HEIGHT * ((run + KICK_LENGTH) / KICK_LENGTH) ** 1.5
        if 0 <= run < DIP_LENGTH:
            h -= DIP_DEPTH * math.sin(math.pi * run / DIP_LENGTH)
        # Round the kicker the dune itself crests
        h += 10 * math.exp(-0.5 * ((run + 20) / 70) ** 2)
        return h

    def road_height(self, progress):
        """How high the road is, how far from it the ground blends into it, and how far into the canyon"""
        k = progress / self.track.spacing
        i = int(k) % self.track.count
        j = (i + 1) % self.track.count
        t = k - int(k)
        return self.profile[i] + (self.profile[j] - self.profile[i]) * t, self.blend[i] + (self.blend[j] - self.blend[i]) * t, \
            self.inside[i] + (self.inside[j] - self.inside[i]) * t

    def natural(self, x, y):
        return rim_blend(x, y, tanaris_base(x, y) + mesas_height(x, y), 40)

    def height(self, x, y):
        h = self.natural(x, y)
        i, j = int(round(x / CELL)), int(round(y / CELL))
        s = self.signed[j * SIZE + i]
        if s is None:
            return h
        road, blend, inside = self.road_height(self.round[j * SIZE + i])
        d = abs(s)
        if inside > 0:
            # The canyon's walls: up from the road, a ledge on the way, flat on top, down further out
            edge = d + (value_noise(x / 30, y / 30, 111) - 0.5) * 14
            wall = smoothstep(BAND + 6, BAND + 18, edge) * 0.45 + smoothstep(BAND + 24, BAND + 36, edge) * 0.55
            wall *= smoothstep(CANYON_OUT, CANYON_TOP, edge)
            top = CANYON_HEIGHT * (0.85 + 0.3 * value_noise(x / 45, y / 45, 112))
            h = max(h, road + top * wall * inside)
        if d > BAND + CANYON_OUT:
            return h
        away = smoothstep(BAND + 4, BAND + blend, d)
        return road + (h - road) * away

    def surface(self, x, y, qx, qy, steep):
        d = math.dist((x, y), LAKE)
        if d < LAKE_RADIUS + 30:
            edge = d + (value_noise(x / 24, y / 24, 91) - 0.5) * 30
            cover = smoothstep(LAKE_RADIUS + 6, LAKE_RADIUS - 14, edge) * 0.92
            if cover <= 0:
                return None
            # Cracks: where a spot is nearly as near the second nearest of scattered points as the nearest
            fx, fy = x / 11, y / 11
            ci, cj = math.floor(fx), math.floor(fy)
            first = second = 9.0
            for b in (-1, 0, 1):
                for c in (-1, 0, 1):
                    px = ci + c + grain(ci + c, cj + b, 92)
                    py = cj + b + grain(ci + c, cj + b, 93)
                    e = (fx - px) ** 2 + (fy - py) ** 2
                    if e < first:
                        first, second = e, first
                    elif e < second:
                        second = e
            gap = math.sqrt(second) - math.sqrt(first)
            n = (grain(qx, qy, 94) - 0.5) * 12 + (value_noise(x / 6, y / 6, 95) - 0.5) * 16
            colour = tuple(v + n for v in CLAY)
            crack = smoothstep(0.09, 0.03, gap)
            colour = mix(colour, CRACK, crack)
            return colour, cover
        # Darker, coarser sand in the dunes' lee
        return None

    def rock(self, x, y, qx, qy, heights):
        z = bilinear(heights, x / CELL, y / CELL)
        z += (value_noise(x / 50, y / 50, 101) - 0.5) * 7 + (value_noise(x / 12, y / 12, 102) - 0.5) * 1.5
        level = z % STRATA_HEIGHT
        colour = STRATA[-1][:3]
        for band in STRATA:
            if level < band[3]:
                colour = band[:3]
                break
            level -= band[3]
        n = (value_noise(x / 4, y / 4, 103) - 0.5) * 22 + (grain(qx, qy, 104) - 0.5) * 12
        crack = -34 * smoothstep(0.05, 0.0, abs(value_noise(x / 9, y / 4, 105) - 0.5))
        return colour[0] + n + crack, colour[1] + n * 0.85 + crack, colour[2] + n * 0.7 + crack * 0.8

    def tile(self):
        return sand_tile()

    def sky(self):
        return tanaris_sky()

    def place(self, heights, steepness):
        """Everything that stands beside the road"""
        track, things = self.track, []
        rng = random.Random(1907)
        length = track.length

        def add(model, x, y, size, facing):
            things.append((model, x, y, size, facing % (2 * math.pi)))

        def beside(progress, offset, model, size, facing=None):
            x, y, heading = track.at(progress, offset)
            add(model, x, y, size, heading if facing is None else heading + facing)

        # Gadgetzan: the straight runs through town. Lamp posts by the curbs, a goblin wall each side
        # with alleys through it, tents behind in rows and round a little square with the water
        # towers in it, machines in the yards, a gate of guard towers and signs at each end
        def town(progress, offset, model, size, turn=0.0, near=BAND + 6):
            """A thing beside the straight, facing the road and then turned by `turn`, unless it
            would stand too near the road anywhere or in the dry lake"""
            x, y, heading = track.at(progress, offset)
            if math.dist((x, y), LAKE) < LAKE_RADIUS + 6 or abs(track.nearest(x, y)[0]) < near:
                return
            toward = heading - math.pi / 2 if offset > 0 else heading + math.pi / 2
            add(model, x, y, size, toward + turn)

        def along(progress, offset, model, size, turn=0.0, near=BAND + 6):
            """A thing beside the straight lying along the road (a wall's long side, a fence's)"""
            x, y, heading = track.at(progress, offset)
            if math.dist((x, y), LAKE) < LAKE_RADIUS + 6 or abs(track.nearest(x, y)[0]) < near:
                return
            add(model, x, y, size, heading + math.pi / 2 + turn)

        kerb = HALF + CURB + 6
        for k, progress in enumerate(range(-170, 321, 49)):
            for side in (1, -1):
                town(progress + (0 if side > 0 else 24), side * kerb, LAMPS[k % len(LAMPS)], 10, near=HALF + CURB + 4)
        alleys = {1: (4, 11), -1: (3, 8, 14)}
        for side in (1, -1):
            for k in range(18):
                progress = -170 + WALL_LENGTH / 2 + k * WALL_LENGTH
                if k in alleys[side]:
                    along(progress - WALL_LENGTH / 2, side * (BAND + 16), POST, 14)
                    along(progress + WALL_LENGTH / 2, side * (BAND + 16), POST, 14)
                else:
                    along(progress, side * (BAND + 16), WALL, 28)
        # The gates: guard towers either side where the road comes into town and leaves it, signs
        for progress in (-200, 340):
            for side in (1, -1):
                town(progress, side * (BAND + 14), GUARD_TOWERS[side > 0], 36)
        town(-184, kerb, SIGNS[0], 9, -math.pi / 2, near=HALF + CURB + 4)
        town(-184, -kerb, SIGNS[3], 9, math.pi / 2, near=HALF + CURB + 4)
        town(322, kerb, SIGNS[1], 9, -math.pi / 2, near=HALF + CURB + 4)
        town(322, -kerb, SIGNS[4], 9, math.pi / 2, near=HALF + CURB + 4)
        town(30, -kerb, SIGNS[2], 9, 0.4, near=HALF + CURB + 4)
        # Billboards seen from the start line, ahead on both sides
        town(150, BAND + 36, BILLBOARDS[0], 30, -0.7)
        town(122, -(BAND + 30), BILLBOARDS[1], 30, 0.7)
        # Tents: a row behind the wall on the right, two on the left, and round the square
        square = 80
        for k, progress in enumerate(range(-150, 300, 40)):
            if not 160 <= progress <= 280:
                town(progress, BAND + 46, TENTS[k % len(TENTS)], 18, rng.uniform(-0.15, 0.15))
        for k, progress in enumerate(range(-150, 300, 42)):
            town(progress, -(BAND + 48), TENTS[(k + 3) % len(TENTS)], 18, rng.uniform(-0.15, 0.15))
        for k, progress in enumerate((-130, -88, 200, 242)):
            town(progress, -(BAND + 88), TENTS[(k + 5) % len(TENTS)], 18, rng.uniform(-0.2, 0.2))
        middle = -(BAND + 128)
        town(square - 48, middle, TENTS[1], 18, -math.pi / 2)
        town(square + 48, middle, TENTS[4], 18, math.pi / 2)
        town(square, middle - 50, TENTS[6], 18, math.pi)
        town(square - 14, middle + 4, WATER_TOWER, 60)
        town(square + 22, middle - 16, STEEL_TOWER, 70)
        town(square + 10, middle + 26, WEATHERVANE, 9)
        town(square - 30, middle - 30, MACHINERY, 10, 0.8)
        # Smokestacks over the roofs
        town(-60, -(BAND + 112), SMOKESTACKS[0], 30)
        town(140, -(BAND + 96), SMOKESTACKS[1], 30)
        town(-140, BAND + 76, SMOKESTACKS[2], 30)
        town(300, BAND + 82, SMOKESTACKS[3], 30)
        # The yard on the right: the big machines, a rocket cart, the oil tank
        town(220, BAND + 64, BATTERY_MACHINE, 36, 0.3)
        town(178, BAND + 48, ROCK_CUTTER, 18, -0.4)
        town(262, BAND + 52, CRAZY_MACHINES[0], 12, 0.5)
        town(196, BAND + 96, CRAZY_MACHINES[1], 12, 1.2)
        town(258, BAND + 92, OIL_TANK, 40)
        town(236, BAND + 30, ROCKET_CARTS[0], 9, 1.3)
        # Shredders standing in the alleys, looking out at the road
        town(-170 + 11 * WALL_LENGTH, BAND + 24, SHREDDERS[0], 12)
        town(-170 + 8 * WALL_LENGTH + WALL_LENGTH / 2, -(BAND + 24), SHREDDERS[1], 12)
        # The left: the holding pen in a paddock of fences, more machines, the TNT by the bombs
        pen = -112
        town(pen, -(BAND + 112), PEN, 40)
        for k, (dp, do, turn) in enumerate(((-22, 0, 0), (22, 0, 0), (0, -22, math.pi / 2), (0, 22, math.pi / 2))):
            along(pen + dp, -(BAND + 112) + do, FENCES[k * 2], 9, turn)
        town(-40, -(BAND + 150), CRAZY_MACHINES[2], 12, 0.6)
        town(-160, -(BAND + 60), CRAZY_MACHINES[3], 12, -0.4)
        town(170, -(BAND + 70), CRAZY_MACHINES[4], 12, 0.9)
        town(-80, -(BAND + 24), ROCKET_CARTS[1], 9, 1.6)
        town(-34, -(BAND + 22), TNT_WAGON, 10, 1.4)
        town(10, BAND + 26, HUT_BOTTLES, 4)
        town(16, BAND + 30, HUT_BOTTLES, 4, 1.0)
        # Crates and bombs about the start line
        for progress, offset in ((-24, -(BAND + 8)), (18, -(BAND + 9)), (-50, BAND + 8), (110, -(BAND + 10)), (40, -(BAND + 30)), (46, -(BAND + 36))):
            town(progress, offset, CRATE, 8, rng.uniform(0, 6.3))
        town(-14, -(BAND + 30), BOMBS, 10, 0.3)
        town(60, BAND + 10, BOMBS, 10, 2.1)
        # The jump: rockets and warning signs either side of the kicker, carts, crates and bombs
        kick = self.kick
        beside(kick - 70, HALF + CURB + 6, WARNING_SIGNS[0], 6, math.pi)
        beside(kick - 70, -(HALF + CURB + 6), WARNING_SIGNS[1], 6, math.pi)
        beside(kick - 30, BAND + 16, BOTTLE_ROCKET, 12)
        beside(kick - 30, -(BAND + 16), BOTTLE_ROCKET, 12)
        beside(kick - 6, BAND + 22, LARGE_ROCKET, 26)
        beside(kick - 6, -(BAND + 22), LARGE_ROCKET, 26)
        beside(kick - 50, -(BAND + 40), STANDING_ROCKET, 18)
        beside(kick - 44, BAND + 30, ROCKET_CARTS[2], 9, -math.pi / 2)
        beside(kick + 40, -(BAND + 26), ROCKET_CARTS[3], 9, 0.8)
        beside(kick + 96, BAND + 28, ROCKET_CARTS[4], 9, 2.4)
        beside(kick - 140, BAND + 70, BILLBOARDS[2], 30, math.pi + 0.6)
        beside(kick + 70, BAND + 18, BOMBS, 10)
        beside(kick + 110, -(BAND + 16), CRATE, 8, 0.7)
        beside(kick + 118, -(BAND + 22), CRATE, 8, 1.9)
        beside(kick + 150, BAND + 20, BOMBS, 10, 2.0)
        # Rocks fallen from the canyon's walls, and about the feet of the mesas
        canyon = self.canyon
        if canyon:
            for k in canyon[::8]:
                side = 1 if rng.random() < 0.5 else -1
                beside(k * track.spacing, side * (BAND + rng.uniform(10, 24)), rng.choice(ROCKS), rng.randint(12, 24), rng.uniform(0, 6.3))
        for (cx, cy), (rx, ry), _ in MESAS:
            for k in range(4):
                a = rng.uniform(0, 2 * math.pi)
                d = rng.uniform(1.0, 1.25)
                x, y = cx + math.cos(a) * rx * d, cy + math.sin(a) * ry * d
                if abs(track.nearest(x, y)[0]) > BAND + 14:
                    add(rng.choice(ROCKS), x, y, rng.randint(14, 30), rng.uniform(0, 6.3))
        # Cacti over the dunes, a few in clumps near the road to tell how fast it goes by
        placed, tries = 0, 0
        while placed < 40 and tries < 5000:
            tries += 1
            x, y = rng.uniform(80, WORLD - 80), rng.uniform(80, WORLD - 80)
            if math.dist((x, y), LAKE) < LAKE_RADIUS + 20 or mesas_height(x, y) > 4:
                continue
            if bilinear(steepness, x / CELL, y / CELL) > 0.35:
                continue
            if abs(track.nearest(x, y)[0]) < BAND + 30:
                continue
            if any(math.dist((x, y), (t[1], t[2])) < 34 for t in things):
                continue
            add(rng.choice(CACTI), x, y, rng.randint(14, 26), rng.uniform(0, 6.3))
            placed += 1
        for k in range(10):
            progress = rng.uniform(0, length)
            if abs(progress - kick) < 200 or progress < 380 or progress > length - 240:
                continue
            side = 1 if rng.random() < 0.5 else -1
            for m in range(rng.randint(1, 3)):
                beside(progress + m * 9, side * (BAND + 14 + m * 7), rng.choice(CACTI), rng.randint(14, 22), rng.uniform(0, 6.3))
        self.things = things


COURSES = {"meadow": Meadow, "tanaris": Tanaris}


def build(course_id, out):
    began = time.time()
    course = COURSES[course_id]()
    heights = heights_for(course.height)
    if hasattr(course, "place"):
        _, steepness = lighting(heights)
        course.place(heights, steepness)
    tile = course.tile()
    write_tga(out / f"{course.id}tile.tga", tile)
    write_tga(out / f"{course.id}sky.tga", course.sky())
    overlay, full = pictures(course, heights, tile)
    write_tga(out / f"{course.id}.tga", overlay)
    write_tga(out / f"{course.id}full.tga", full)
    write_lua(out / f"{course.name}.lua", course, heights)
    shortest, longest = course.track.check()
    print(f"{course.name}: {time.time() - began:.0f} s, lap {course.track.length:.1f} units in {course.track.count} points"
          f" ({shortest:.4f} to {longest:.4f} apart), {len(course.things)} things")
    return course, heights, full


def wedge(rises, size=64):
    """White, seen below a line from one bottom corner to the other top corner and not above it,
    smoothed across a pixel. The line ends a row above the bottom, so that the bottom row is all
    seen, for the mask to go on down from it (TerrainView.lua, WEDGE)"""
    rows = []
    for y in range(size):
        row = bytearray()
        for x in range(size):
            fx, fy = (x + 0.5) / size, (y + 0.5) / size
            line = (1 - fx if rises else fx) * (size - 1) / size
            cover = min(1.0, max(0.0, (fy - line) * size + 0.5))
            row += bytes((255, 255, 255, int(cover * 255 + 0.5)))
        rows.append(bytes(row))
    return rows


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    out = Path(sys.argv[1])
    write_tga(out / "wedgerise.tga", wedge(True))
    write_tga(out / "wedgefall.tga", wedge(False))
    for course_id in sys.argv[2:] or list(COURSES):
        build(course_id, out)


if __name__ == "__main__":
    main()
