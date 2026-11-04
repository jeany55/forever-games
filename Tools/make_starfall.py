#!/usr/bin/env python3
"""Draws Starfall's pictures and makes its sounds, for Forever Games (Games/Starfall).

    python3 Tools/make_starfall.py . [preview-folder]

Given the addon's folder, writes into its Images/Starfall/ (the icon into Images/Icons/starfall.tga):
  sky.tga         the night the stones hang in, 1024 by 768 in the top of a 1024 square: deep blue
                  going to violet low down, drifts of nebula, a great many small stars, and the
                  dark shapes of hills and trees along the bottom
  stone, star, wisp (and each again ...Lit)
                  the stones, 64 square: a pale moonstone, a gold star-stone with a four-pointed
                  star set in it, a green wisp; lit, each is bright and glowing
  glow, ring, spark, comet
                  light to be added over the rest: a soft round glow, a ring for bursts, a little
                  four-pointed twinkle and the falling star itself
  crescent        the crescent the stars are fired from, its open side down
  well, wellGlow  the Moonwell's pool, and the light standing over it
  icon            the game's icon, 64 square, and a PNG copy for the README
                  (.github/readme/icons/starfall.png)
and into its Sounds/Starfall/, as Ogg (ffmpeg writes them):
  chime1..chime14 a bell for each stone lit in a shot, every one a step up a pentatonic scale
  tick, pop       a stone touched again, and one vanishing
  fire, wisp      a star fired, and a wisp flying off
  well, wake      a star caught by the Moonwell, and a constellation waking: harps
  count, won, dawn
                  the score counting up, the night won, and dawn breaking on a night not won
Only the standard library is used besides ffmpeg. Pass a second folder to get PNG copies of the
pictures there, which are easier to look at than TGA. Everything is made from fixed seeds, so it
comes out the same every time.
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

RATE = 44100


# --------------------------------------------------------------------------------------------
# Pictures
# --------------------------------------------------------------------------------------------

class Picture:
    """RGBA, each a float from 0 to 1, in rows from the top"""

    def __init__(self, width, height):
        self.width, self.height = width, height
        self.pixels = [[0.0, 0.0, 0.0, 0.0] for _ in range(width * height)]

    def get(self, x, y):
        return self.pixels[y * self.width + x]

    def over(self, x, y, color, alpha):
        """Lays a colour over a pixel, as paint"""
        if alpha <= 0 or x < 0 or y < 0 or x >= self.width or y >= self.height:
            return
        alpha = min(1.0, alpha)
        p = self.pixels[y * self.width + x]
        out = alpha + p[3] * (1 - alpha)
        if out <= 0:
            return
        for i in range(3):
            p[i] = (color[i] * alpha + p[i] * p[3] * (1 - alpha)) / out
        p[3] = out

    def add(self, x, y, color, amount):
        """Adds light to a pixel of an opaque picture"""
        if amount <= 0 or x < 0 or y < 0 or x >= self.width or y >= self.height:
            return
        p = self.pixels[y * self.width + x]
        for i in range(3):
            p[i] = min(1.0, p[i] + color[i] * amount)

    def bytes_tga(self, rows=None):
        rows = rows or self.height
        out = bytearray()
        for y in range(rows - 1, -1, -1):
            for x in range(self.width):
                if y >= self.height:
                    out += b"\0\0\0\0"
                    continue
                r, g, b, a = self.get(x, y)
                out += bytes((clamp8(b), clamp8(g), clamp8(r), clamp8(a)))
        return out


def clamp8(value):
    return max(0, min(255, int(value * 255 + 0.5)))


def write_tga(path, picture, height=None):
    """32-bit uncompressed, rows from the bottom; `height` pads the picture to a taller texture"""
    height = height or picture.height
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, picture.width, height, 32, 8)
    path.write_bytes(header + picture.bytes_tga(height))


def write_png(path, picture):
    raw = bytearray()
    for y in range(picture.height):
        raw.append(0)
        for x in range(picture.width):
            r, g, b, a = picture.get(x, y)
            raw += bytes((clamp8(r), clamp8(g), clamp8(b), clamp8(a)))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", picture.width, picture.height, 8, 6, 0, 0, 0)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


def smooth(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def mix(a, b, t):
    return [a[i] + (b[i] - a[i]) * t for i in range(len(a))]


class Noise:
    """Value noise that wraps round, a few octaves of it"""

    def __init__(self, seed, size=64):
        chance = random.Random(seed)
        self.size = size
        self.grid = [chance.random() for _ in range(size * size)]

    def at(self, x, y):
        size = self.size
        x0, y0 = int(math.floor(x)), int(math.floor(y))
        fx, fy = smooth(x - x0), smooth(y - y0)
        g = self.grid
        a = g[(y0 % size) * size + x0 % size]
        b = g[(y0 % size) * size + (x0 + 1) % size]
        c = g[((y0 + 1) % size) * size + x0 % size]
        d = g[((y0 + 1) % size) * size + (x0 + 1) % size]
        return (a + (b - a) * fx) + ((c + (d - c) * fx) - (a + (b - a) * fx)) * fy

    def fractal(self, x, y, octaves=4):
        total, scale, weight, weights = 0.0, 1.0, 1.0, 0.0
        for _ in range(octaves):
            total += self.at(x * scale, y * scale) * weight
            weights += weight
            scale *= 2.03
            weight *= 0.5
        return total / weights


def sky():
    """The night, 1024 by 768"""
    width, height = 1024, 768
    picture = Picture(width, height)
    clouds, wisps, ground = Noise(11), Noise(23), Noise(37)
    top, middle, low = (0.015, 0.02, 0.07), (0.04, 0.05, 0.16), (0.12, 0.07, 0.22)
    violet, teal = (0.42, 0.2, 0.62), (0.1, 0.42, 0.55)
    for y in range(height):
        v = y / height
        base = mix(top, middle, smooth(v / 0.6)) if v < 0.6 else mix(middle, low, smooth((v - 0.6) / 0.4))
        for x in range(width):
            u = x / width
            # A band of nebula across the sky, leaning, violet with teal at its edges
            band = math.exp(-((v - 0.35 - (u - 0.5) * 0.35) ** 2) / 0.03)
            n = clouds.fractal(u * 6, v * 4.5, 5)
            m = wisps.fractal(u * 9 + 3, v * 7, 4)
            dust = max(0.0, n - 0.42) * 2.2 * (0.35 + band)
            color = [base[i] + violet[i] * dust * 0.32 + teal[i] * max(0.0, m - 0.55) * 0.5 * band for i in range(3)]
            picture.pixels[y * width + x] = [color[0], color[1], color[2], 1.0]
    # Stars: many faint, a few bright with a soft glow, more of them in the band
    chance = random.Random(5)
    for _ in range(4200):
        x, y = chance.random() * width, chance.random() * height * 0.86
        v = y / height
        band = math.exp(-((v - 0.35 - (x / width - 0.5) * 0.35) ** 2) / 0.03)
        if chance.random() > 0.35 + band * 0.65:
            continue
        bright = chance.random() ** 3
        tint = mix((0.75, 0.82, 1.0), (1.0, 0.92, 0.78), chance.random())
        radius = 0.6 + bright * 1.8
        reach = int(radius * 3) + 1
        for dy in range(-reach, reach + 1):
            for dx in range(-reach, reach + 1):
                px, py = int(x) + dx, int(y) + dy
                d = math.hypot(px + 0.5 - x, py + 0.5 - y)
                picture.add(px, py, tint, (0.25 + bright * 0.75) * math.exp(-(d * d) / (radius * radius * 0.55)))
    # Hills and trees along the bottom, black-blue, with moonlight on their tops
    for x in range(width):
        u = x / width
        hill = 0.9 - 0.05 * math.sin(u * 7.1 + 1.0) - 0.035 * math.sin(u * 17.3) - 0.02 * ground.fractal(u * 12, 0.5, 3)
        tree = 0.0
        # Tall trees here and there, each a cone of rough edges
        for centre, tall, wide in ((0.06, 0.13, 0.05), (0.13, 0.09, 0.035), (0.86, 0.12, 0.05), (0.94, 0.15, 0.06), (0.31, 0.05, 0.03), (0.7, 0.06, 0.03)):
            d = abs(u - centre) / wide
            if d < 1:
                tree = max(tree, tall * (1 - d) * (0.85 + 0.15 * ground.at(u * 160, centre * 50)))
        line = (hill - tree) * height
        for y in range(int(line) - 2, height):
            p = picture.pixels[y * width + x]
            depth = (y - line) / 40
            shade = (0.01, 0.012, 0.035)
            rim = math.exp(-max(0.0, y - line) / 2.5) * 0.45
            t = smooth(depth + 0.6) if y >= line else max(0.0, 1 - (line - y))
            for i in range(3):
                p[i] = p[i] * (1 - t) + shade[i] * t + (0.35, 0.4, 0.75)[i] * rim * t
    return picture


def sphere(size, light, dark, shine, glow_color=None, glow=0.0, rim=0.0, face=None):
    """A round stone lit from the top left, with a glow round it"""
    picture = Picture(size, size)
    middle = size / 2
    radius = size * 0.31
    for y in range(size):
        for x in range(size):
            dx, dy = (x + 0.5 - middle) / radius, (y + 0.5 - middle) / radius
            d = math.hypot(dx, dy)
            if glow and glow_color:
                # Fading to nothing before the edge of the picture, so that no square shows
                g = math.exp(-max(0.0, d - 0.9) ** 2 / 0.35) * glow * smooth((1.58 - d) / 0.4)
                picture.over(x, y, glow_color, g if d > 1 else 0)
            if d < 1.06:
                edge = smooth((1.06 - d) / 0.08)
                z = math.sqrt(max(0.0, 1 - min(1.0, d) ** 2))
                lit = max(0.0, -0.45 * dx - 0.55 * dy + 0.7 * z)
                color = mix(dark, light, lit)
                # The light in it, and its rim lit from behind
                spec = max(0.0, -0.4 * dx - 0.5 * dy + 0.77 * z) ** 30 * shine
                color = [min(1.0, c + spec + rim * (d ** 4) * 0.6) for c in color]
                if face:
                    color = face(dx, dy, d, color)
                picture.over(x, y, color, edge)
    return picture


def star_face(bright):
    """A four-pointed star set into a stone"""
    def face(dx, dy, d, color):
        ax, ay = abs(dx), abs(dy)
        # Inside a four-pointed star: the sum of square roots stays under a limit
        s = math.sqrt(ax) + math.sqrt(ay)
        inside = smooth((0.86 - s) / 0.08)
        if inside > 0:
            light = mix((1.0, 0.86, 0.45), (1.0, 1.0, 0.92), bright)
            return mix(color, light, inside * (0.75 + 0.25 * bright))
        return color
    return face


def wisp_face(bright):
    def face(dx, dy, d, color):
        a = math.atan2(dy, dx)
        swirl = 0.5 + 0.5 * math.sin(a * 2 + d * 7)
        return mix(color, mix((0.7, 1.0, 0.9), (1.0, 1.0, 1.0), bright), swirl * 0.35 * (1 - d))
    return face


def radial(size, falloff, color=(1, 1, 1)):
    picture = Picture(size, size)
    middle = size / 2
    for y in range(size):
        for x in range(size):
            d = math.hypot(x + 0.5 - middle, y + 0.5 - middle) / middle
            picture.pixels[y * size + x] = [color[0], color[1], color[2], max(0.0, falloff(d))]
    return picture


def comet(size=64):
    """The falling star: a white core, a blue halo and four thin rays"""
    picture = Picture(size, size)
    middle = size / 2
    for y in range(size):
        for x in range(size):
            dx, dy = (x + 0.5 - middle) / middle, (y + 0.5 - middle) / middle
            d = math.hypot(dx, dy)
            core = math.exp(-(d * d) / 0.012)
            halo = math.exp(-(d * d) / 0.09) * 0.75
            rays = (math.exp(-(dy * dy) / 0.0009) + math.exp(-(dx * dx) / 0.0009)) * max(0.0, 1 - d) ** 2 * 0.8
            a = min(1.0, core + halo + rays)
            color = mix((0.55, 0.7, 1.0), (1.0, 1.0, 1.0), min(1.0, core * 1.5 + rays * 0.5))
            picture.pixels[y * size + x] = [color[0], color[1], color[2], a]
    return picture


def spark(size=32):
    picture = Picture(size, size)
    middle = size / 2
    for y in range(size):
        for x in range(size):
            dx, dy = (x + 0.5 - middle) / middle, (y + 0.5 - middle) / middle
            d = math.hypot(dx, dy)
            a = math.exp(-(d * d) / 0.03) + (math.exp(-(dy * dy) / 0.004) + math.exp(-(dx * dx) / 0.004)) * max(0.0, 1 - d) ** 1.5 * 0.7
            picture.pixels[y * size + x] = [1.0, 1.0, 1.0, min(1.0, a)]
    return picture


SEAS = Noise(41)


def crescent(size=128):
    """A silver crescent moon, its open side facing down, the star cradled in the middle"""
    picture = Picture(size, size)
    middle = size / 2
    outer, inner = size * 0.42, size * 0.33
    # The inner circle that cuts it is lower, so that the horns point down
    shift = size * 0.15
    for y in range(size):
        for x in range(size):
            px, py = x + 0.5 - middle, y + 0.5 - middle
            d1 = math.hypot(px, py)
            d2 = math.hypot(px, py - shift)
            inside = smooth((outer - d1) / 1.5) * smooth((d2 - inner) / 1.5)
            glow = math.exp(-max(0.0, d1 - outer) ** 2 / (size * 0.4)) * 0.35 * smooth((d2 - inner + 6) / 8) * smooth((middle - d1) / (size * 0.08))
            if inside > 0:
                # Lit from above, craters faintly
                t = smooth((outer - d1) / (outer - inner + shift))
                color = mix((0.62, 0.68, 0.92), (0.98, 0.98, 1.0), 1 - t * 0.6 + (-py / size) * 0.4)
                # Faint seas on its face
                sea = max(0.0, SEAS.fractal(px / size * 5 + 2, py / size * 5 + 2, 3) - 0.5) * 0.5
                color = [max(0.0, min(1.0, c - sea)) for c in color]
                picture.over(x, y, (0.6, 0.7, 1.0), glow)
                picture.over(x, y, color, inside)
            else:
                picture.over(x, y, (0.6, 0.7, 1.0), glow)
    return picture


def well(width=128, height=64):
    """The Moonwell: a pool of light in a rim of pale stone, seen from the side and above"""
    picture = Picture(width, height)
    cx, cy = width / 2, height * 0.55
    rx, ry = width * 0.46, height * 0.3
    for y in range(height):
        for x in range(width):
            dx, dy = (x + 0.5 - cx) / rx, (y + 0.5 - cy) / ry
            d = math.hypot(dx, dy)
            if d < 1.0:
                water = mix((0.25, 0.35, 0.95), (0.75, 0.9, 1.0), smooth(1 - d) * 0.9)
                ripple = 0.08 * math.sin(d * 18)
                water = [min(1.0, c + ripple) for c in water]
                picture.over(x, y, water, 1.0)
            elif d < 1.25:
                t = (d - 1.0) / 0.25
                rim = mix((0.75, 0.75, 0.85), (0.3, 0.3, 0.45), t + max(0.0, dy) * 0.4)
                picture.over(x, y, rim, smooth((1.25 - d) / 0.06))
            # The stone going down into the dark below the rim
            if dy > 0 and abs(dx) < 1.18 and d >= 1.2:
                depth = (y + 0.5 - cy) / (height - cy)
                picture.over(x, y, mix((0.3, 0.3, 0.45), (0.05, 0.05, 0.1), depth), 1.0 - depth * 0.3)
    return picture


def well_glow(width=128, height=128):
    """Light standing over the Moonwell, brightest at the bottom"""
    picture = Picture(width, height)
    for y in range(height):
        for x in range(width):
            u = (x + 0.5) / width * 2 - 1
            v = (y + 0.5) / height
            a = math.exp(-(u * u) / (0.18 + (1 - v) * 0.2)) * (v ** 2.2) * 0.8
            picture.pixels[y * width + x] = [0.55, 0.7, 1.0, a]
    return picture


def icon(size=64):
    """A night with a constellation, the crescent at the top and a star falling from it"""
    picture = Picture(size, size)
    for y in range(size):
        for x in range(size):
            v = y / size
            c = mix((0.03, 0.04, 0.14), (0.18, 0.1, 0.32), v)
            picture.pixels[y * size + x] = [c[0], c[1], c[2], 1.0]
    chance = random.Random(3)
    for _ in range(40):
        picture.add(chance.randrange(size), chance.randrange(size), (0.8, 0.85, 1), chance.random() * 0.6)
    # The constellation's lines and stars
    points = [(14, 46), (24, 38), (36, 44), (46, 34), (52, 48)]
    for (x1, y1), (x2, y2) in zip(points, points[1:]):
        steps = int(math.hypot(x2 - x1, y2 - y1) * 2)
        for i in range(steps):
            t = i / steps
            picture.add(int(x1 + (x2 - x1) * t), int(y1 + (y2 - y1) * t), (1.0, 0.85, 0.5), 0.35)
    stone = sphere(12, (1.0, 0.86, 0.4), (0.6, 0.38, 0.08), 0.8, face=star_face(0.6))
    for px, py in points:
        paste(picture, stone, px - 6, py - 6)
    moon = crescent(26)
    paste(picture, moon, 32 - 13, 1)
    falling = comet(24)
    paste(picture, falling, 26 - 12, 18 - 12, add=True)
    paste(picture, comet(12), 21 - 6, 12 - 6, add=True)
    return picture


def paste(picture, piece, left, top, add=False):
    for y in range(piece.height):
        for x in range(piece.width):
            r, g, b, a = piece.get(x, y)
            if add:
                picture.add(left + x, top + y, (r, g, b), a)
            else:
                picture.over(left + x, top + y, (r, g, b), a)


def pictures(folder, preview):
    images = folder / "Images" / "Starfall"
    images.mkdir(parents=True, exist_ok=True)
    icons = folder / "Images" / "Icons"
    icons.mkdir(parents=True, exist_ok=True)
    made = {}
    made["stone"] = sphere(64, (0.86, 0.9, 1.0), (0.28, 0.32, 0.46), 0.7, rim=0.4)
    made["stoneLit"] = sphere(64, (0.9, 1.0, 1.0), (0.45, 0.65, 0.9), 1.0, (0.6, 0.85, 1.0), 0.8, rim=0.8)
    made["star"] = sphere(64, (1.0, 0.84, 0.36), (0.5, 0.3, 0.05), 0.8, rim=0.3, face=star_face(0.2))
    made["starLit"] = sphere(64, (1.0, 0.97, 0.75), (0.95, 0.6, 0.2), 1.0, (1.0, 0.85, 0.4), 0.9, rim=0.8, face=star_face(1.0))
    made["wisp"] = sphere(64, (0.55, 1.0, 0.8), (0.05, 0.38, 0.32), 0.8, (0.3, 1.0, 0.7), 0.25, rim=0.5, face=wisp_face(0.2))
    made["wispLit"] = sphere(64, (0.85, 1.0, 0.95), (0.2, 0.75, 0.6), 1.0, (0.4, 1.0, 0.8), 0.9, rim=0.9, face=wisp_face(1.0))
    made["glow"] = radial(64, lambda d: math.exp(-(d * d) / 0.18) * (1 - smooth((d - 0.85) / 0.15)))
    made["ring"] = radial(128, lambda d: math.exp(-((d - 0.82) ** 2) / 0.006) * (1 - smooth((d - 0.97) / 0.03)))
    made["spark"] = spark()
    made["comet"] = comet()
    made["crescent"] = crescent()
    made["well"] = well()
    made["wellGlow"] = well_glow()
    made["icon"] = icon()
    for name, picture in made.items():
        write_tga(icons / "starfall.tga" if name == "icon" else images / (name + ".tga"), picture)
        if preview:
            write_png(preview / (name + ".png"), picture)
    readme = Path(__file__).resolve().parent.parent / ".github" / "readme" / "icons" / "starfall.png"
    write_png(readme, made["icon"])
    night = sky()
    write_tga(images / "sky.tga", night, 1024)
    if preview:
        write_png(preview / "sky.png", night)


# --------------------------------------------------------------------------------------------
# Sounds
# --------------------------------------------------------------------------------------------

def bell(frequency, seconds, loud=0.5, bright=1.0):
    """A small bell: partials at a bell's ratios, the high ones dying first"""
    count = int(seconds * RATE)
    partials = ((1.0, 1.0, 2.2), (2.0, 0.45 * bright, 3.5), (2.76, 0.3 * bright, 5.0), (5.4, 0.15 * bright, 9.0), (8.9, 0.06 * bright, 14.0))
    out = []
    for i in range(count):
        t = i / RATE
        attack = min(1.0, t / 0.002)
        value = 0.0
        for ratio, weight, decay in partials:
            value += math.sin(2 * math.pi * frequency * ratio * t) * weight * math.exp(-t * decay)
        out.append(value * attack * loud * 0.5)
    return out


def pluck(frequency, seconds, loud=0.5, seed=1):
    """A harp string, by Karplus and Strong"""
    chance = random.Random(seed)
    period = max(2, int(RATE / frequency))
    line = [chance.uniform(-1, 1) for _ in range(period)]
    out = []
    count = int(seconds * RATE)
    index = 0
    for _ in range(count):
        a = line[index]
        b = line[(index + 1) % period]
        line[index] = (a + b) * 0.5 * 0.996
        out.append(a * loud)
        index = (index + 1) % period
    # Take the edge off the pluck
    smoothed, last = [], 0.0
    for v in out:
        last = last + (v - last) * 0.5
        smoothed.append(last)
    return smoothed


def noise(seconds, loud, low, high, shape, seed=2):
    """Noise between two cutoffs that move as `shape` says, faded by it too"""
    chance = random.Random(seed)
    count = int(seconds * RATE)
    out, lp1, lp2 = [], 0.0, 0.0
    for i in range(count):
        t = i / count
        lo, hi, amp = shape(t, low, high)
        a1 = min(1.0, 2 * math.pi * hi / RATE)
        a2 = min(1.0, 2 * math.pi * lo / RATE)
        x = chance.uniform(-1, 1)
        lp1 += (x - lp1) * a1
        lp2 += (lp1 - lp2) * a2
        out.append((lp1 - lp2) * amp * loud)
    return out


def place(out, sound, at, loud=1.0):
    start = int(at * RATE)
    need = start + len(sound)
    if len(out) < need:
        out.extend([0.0] * (need - len(out)))
    for i, v in enumerate(sound):
        out[start + i] += v * loud


def reverb(sound, amount=0.25, seconds=0.9):
    """A small hall: a few echoes, each fainter"""
    out = list(sound) + [0.0] * int(seconds * RATE)
    for delay, gain in ((0.031, 0.5), (0.047, 0.42), (0.071, 0.34), (0.113, 0.26), (0.167, 0.18), (0.241, 0.12)):
        d = int(delay * RATE)
        for i in range(len(sound)):
            out[i + d] += sound[i] * gain * amount
    return out


# A pentatonic scale from the C above middle C, for the stones a shot lights in turn
PENTATONIC = [0, 2, 4, 7, 9]


def note(step, base=523.25):
    octave, degree = divmod(step, len(PENTATONIC))
    return base * 2 ** (octave + PENTATONIC[degree] / 12)


def write_sound(path, samples):
    peak = max(1e-6, max(abs(v) for v in samples))
    gain = min(1.0, 0.89 / peak)
    frames = b"".join(struct.pack("<h", int(max(-1.0, min(1.0, v * gain)) * 32767)) for v in samples)
    with tempfile.TemporaryDirectory() as temp:
        raw = Path(temp) / "sound.wav"
        with wave.open(str(raw), "wb") as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(RATE)
            out.writeframes(frames)
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(raw), "-c:a", "libvorbis", "-q:a", "4", str(path)], check=True)


def sounds(folder):
    out_dir = folder / "Sounds" / "Starfall"
    out_dir.mkdir(parents=True, exist_ok=True)
    made = {}
    for step in range(14):
        made["chime%d" % (step + 1)] = reverb(bell(note(step), 0.9, 0.5, 1.0 - step * 0.03), 0.3)
    made["tick"] = bell(2600, 0.12, 0.18, 0.4)
    pop = noise(0.09, 0.6, 400, 3000, lambda t, lo, hi: (lo, hi * (1 - t * 0.7), (1 - t) ** 2))
    place(pop, [math.sin(2 * math.pi * (900 - 500 * i / 2000) * i / RATE) * 0.3 * (1 - i / 2000) for i in range(2000)], 0)
    made["pop"] = pop
    fire = noise(0.45, 0.8, 300, 5000, lambda t, lo, hi: (lo + 600 * t, hi * (1 - t * 0.6), math.sin(math.pi * min(1.0, t * 1.4)) ** 2))
    place(fire, bell(note(10), 0.5, 0.25), 0.02)
    made["fire"] = reverb(fire, 0.2)
    wisp = []
    for i in range(8):
        place(wisp, bell(note(12 + (i % 3) * 2), 0.25, 0.25, 0.3), i * 0.035)
    place(wisp, noise(0.35, 0.3, 2000, 9000, lambda t, lo, hi: (lo, hi, (1 - t))), 0)
    made["wisp"] = reverb(wisp, 0.35)
    well = []
    for i, step in enumerate((5, 7, 9, 10, 12, 14)):
        place(well, pluck(note(step), 1.4, 0.45, seed=step), i * 0.06)
    place(well, bell(note(15), 1.2, 0.3), 0.36)
    made["well"] = reverb(well, 0.35, 1.2)
    wake = []
    for i, step in enumerate((0, 2, 4, 5, 7, 9, 10, 12)):
        place(wake, pluck(note(step, 261.63), 2.0, 0.45, seed=20 + step), i * 0.07)
    for step in (10, 12, 14):
        place(wake, bell(note(step), 1.6, 0.25), 0.56)
    made["wake"] = reverb(wake, 0.4, 1.4)
    count = []
    for i in range(10):
        place(count, bell(3200 + i * 120, 0.08, 0.12, 0.3), i * 0.05)
    made["count"] = count
    won = []
    for i, step in enumerate((0, 2, 4, 5, 7, 9, 10, 12, 14, 15)):
        place(won, pluck(note(step, 261.63), 2.5, 0.4, seed=40 + step), i * 0.09)
    for step in (5, 7, 9, 10):
        place(won, bell(note(step), 2.5, 0.3, 0.8), 0.95)
    made["won"] = reverb(won, 0.45, 1.6)
    dawn = []
    for i, step in enumerate((9, 7, 5, 4, 2)):
        place(dawn, pluck(note(step, 261.63), 2.0, 0.4, seed=60 + step), i * 0.22)
    place(dawn, bell(note(0, 261.63), 2.2, 0.3, 0.5), 1.1)
    made["dawn"] = reverb(dawn, 0.45, 1.6)
    for name, samples in made.items():
        write_sound(out_dir / (name + ".ogg"), samples)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    folder = Path(sys.argv[1])
    preview = Path(sys.argv[2]) if len(sys.argv) > 2 else None
    if preview:
        preview.mkdir(parents=True, exist_ok=True)
    pictures(folder, preview)
    sounds(folder)


if __name__ == "__main__":
    main()
