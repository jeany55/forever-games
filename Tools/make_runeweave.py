#!/usr/bin/env python3
"""Draws Runeweave's pictures and makes its sounds, for Forever Games (Games/Runeweave).

    python3 Tools/make_runeweave.py . [preview-folder]

Given the addon's folder, writes into its Images/Runeweave/ (the icon into Images/Icons/runeweave.tga):
  rune1..rune6    the runes of the six schools, 64 square, each a cut stone of its own shape and
                  colour with its sign glowing in it, so that no two are told apart by colour
                  alone: fire a flame, frost a hexagon, nature a leaf, arcane a diamond, holy a
                  sun, shadow a rounded square
  prism           the prism: a clear stone with every colour in its facets
  charged, nova   the marks laid over a rune of power: a bolt with an arrow at each end, and a
                  ring with rays. White, to be tinted and added
  select          the ring round a rune that is picked up, or the keys' cursor
  glow, ring, spark
                  light to be added over the rest: a soft glow, a ring for bursts and a twinkle
  beam, beamDown  a bolt's light across a row, and down a column
  ley             the ley meter's fill, light running up it
  board           the slab the runes lie on, 512 square: dark stone in squares, with lines of
                  ley light faint in it
  icon            the game's icon, 64 square, and a PNG copy for the README
                  (.github/readme/icons/runeweave.png)
and into its Sounds/Runeweave/, as Ogg (ffmpeg writes them):
  pick, swap, bad a rune picked up, two swapped, and a swap that does nothing
  match1..match8  a line cleared, a step up a pentatonic scale for each step down the chain
  made, land      a rune of power made, and the runes landing after they fall
  bolt, nova, prism
                  the runes of power going off
  shuffle, surge, over
                  the board shuffled, the ley meter surging, and the game over
Uses the drawing and sound helpers of make_starfall.py, so only the standard library besides
ffmpeg. Pass a second folder to get PNG copies of the pictures there. Everything is made from
fixed seeds, so it comes out the same every time.
"""
import math
import random
import sys
from pathlib import Path

from make_starfall import (
    Noise, Picture, bell, mix, noise, note, place, pluck, radial, reverb, smooth, spark,
    write_png, write_sound, write_tga,
)

# The schools: the colour of the stone, light and dark, and of the sign in it
SCHOOLS = [
    ("fire", (1.0, 0.55, 0.2), (0.45, 0.04, 0.02), (1.0, 0.95, 0.6)),
    ("frost", (0.6, 0.9, 1.0), (0.05, 0.22, 0.5), (0.95, 1.0, 1.0)),
    ("nature", (0.5, 0.95, 0.35), (0.04, 0.3, 0.06), (0.95, 1.0, 0.75)),
    ("arcane", (1.0, 0.5, 0.95), (0.35, 0.02, 0.4), (1.0, 0.9, 1.0)),
    ("holy", (1.0, 0.92, 0.45), (0.55, 0.32, 0.02), (1.0, 1.0, 0.9)),
    ("shadow", (0.68, 0.48, 1.0), (0.1, 0.03, 0.25), (0.9, 0.8, 1.0)),
]


# --------------------------------------------------------------------------------------------
# Shapes, as distances: less than 0 inside, in units where the picture runs from -1 to 1
# --------------------------------------------------------------------------------------------

def convex(points):
    """The distance to the inside of a convex polygon, its corners going clockwise on screen"""
    edges = []
    for (x1, y1), (x2, y2) in zip(points, points[1:] + points[:1]):
        nx, ny = y2 - y1, -(x2 - x1)
        length = math.hypot(nx, ny)
        edges.append((x1, y1, nx / length, ny / length))

    def distance(x, y):
        return max((x - ex) * nx + (y - ey) * ny for ex, ey, nx, ny in edges)
    return distance


def circle(cx, cy, r):
    return lambda x, y: math.hypot(x - cx, y - cy) - r


def union(*shapes):
    return lambda x, y: min(s(x, y) for s in shapes)


def meet(*shapes):
    return lambda x, y: max(s(x, y) for s in shapes)


def rounded(shape, r):
    return lambda x, y: shape(x, y) - r


def regular(sides, radius, turn=0.0):
    return convex([(radius * math.cos(turn + 2 * math.pi * i / sides), radius * math.sin(turn + 2 * math.pi * i / sides)) for i in range(sides)])


def segment(x1, y1, x2, y2, width):
    def distance(x, y):
        dx, dy = x2 - x1, y2 - y1
        t = max(0.0, min(1.0, ((x - x1) * dx + (y - y1) * dy) / (dx * dx + dy * dy)))
        return math.hypot(x - x1 - dx * t, y - y1 - dy * t) - width
    return distance


def strokes(*lines):
    return union(*[segment(*line) for line in lines])


def ring(cx, cy, r, width):
    return lambda x, y: abs(math.hypot(x - cx, y - cy) - r) - width


# The outline of each school's stone, and the sign in it
def outlines():
    flame = union(circle(0, 0.22, 0.56), convex([(0, -0.86), (0.5, -0.02), (0, 0.6), (-0.5, -0.02)]))
    flame_sign = union(circle(0, 0.3, 0.2), convex([(0, -0.3), (0.19, 0.24), (-0.19, 0.24)]))
    hexagon = rounded(regular(6, 0.76, -math.pi / 2), 0.06)
    snow = strokes(*[(0.36 * math.cos(a), 0.36 * math.sin(a), -0.36 * math.cos(a), -0.36 * math.sin(a), 0.045) for a in (math.pi / 2, math.pi / 6, -math.pi / 6)])
    leaf_shape = meet(circle(-0.42, 0.42, 1.06), circle(0.42, -0.42, 1.06))
    # The midrib from the stalk to the tip, and veins off it on both sides, leaning to the tip
    veins = []
    for m in (-0.18, 0.06):
        for side in (1, -1):
            veins.append((m, -m, m + 0.2 * 0.707 + side * 0.24 * 0.707, -m - 0.2 * 0.707 + side * 0.24 * 0.707, 0.035))
    leaf_sign = union(segment(-0.42, 0.42, 0.36, -0.36, 0.045), strokes(*veins))
    diamond = rounded(convex([(0, -0.84), (0.6, 0), (0, 0.84), (-0.6, 0)]), 0.04)
    star = union(convex([(0, -0.38), (0.09, -0.09), (0.38, 0), (0.09, 0.09), (0, 0.38), (-0.09, 0.09), (-0.38, 0), (-0.09, -0.09)]))
    sun = circle(0, 0, 0.74)
    sun_sign = union(ring(0, 0, 0.2, 0.04), strokes(*[(0.3 * math.cos(a), 0.3 * math.sin(a), 0.44 * math.cos(a), 0.44 * math.sin(a), 0.035) for a in [i * math.pi / 4 for i in range(8)]]))
    square = rounded(regular(4, 0.78, math.pi / 4), 0.14)
    eye = union(ring(0, 0, 0.27, 0.04), circle(0, 0, 0.11))
    return [(flame, flame_sign), (hexagon, snow), (leaf_shape, leaf_sign), (diamond, star), (sun, sun_sign), (square, eye)]


# --------------------------------------------------------------------------------------------
# Pictures
# --------------------------------------------------------------------------------------------

SAMPLES = ((0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75))


def gem(size, shape, sign, light, dark, glyph, facets=None):
    """A cut stone of a shape: bevelled at its edges, lit from the top left, its sign glowing"""
    picture = Picture(size, size)
    half = size / 2
    bevel = 0.2
    step = 2.0 / size

    def height(x, y):
        return smooth(-shape(x, y) / bevel)

    for py in range(size):
        for px in range(size):
            total = [0.0, 0.0, 0.0, 0.0]
            for sx, sy in SAMPLES:
                x, y = (px + sx - half) / half, (py + sy - half) / half
                d = shape(x, y)
                if d > 0:
                    continue
                h = height(x, y)
                gx = (height(x + step, y) - height(x - step, y)) / (2 * step)
                gy = (height(x, y + step) - height(x, y - step)) / (2 * step)
                nx, ny, nz = -gx * 0.18, -gy * 0.18, 1.0
                length = math.sqrt(nx * nx + ny * ny + nz * nz)
                nx, ny, nz = nx / length, ny / length, nz / length
                lx, ly, lz = -0.45, -0.55, 0.7
                lambert = max(0.0, nx * lx + ny * ly + nz * lz)
                # Deeper in the middle, lighter towards the light
                body = mix(dark, light, min(1.0, 0.25 + 0.75 * lambert * (0.55 + 0.45 * (1 - (x + y) * 0.35))))
                if facets:
                    body = facets(x, y, body)
                # The table of the stone catches the light
                spec = max(0.0, nx * -0.4 + ny * -0.5 + nz * 0.77) ** 40 * 0.9
                shine = math.exp(-((x + 0.3) ** 2 + (y + 0.38) ** 2) / 0.03) * 0.5 * h
                color = [min(1.0, c + spec + shine) for c in body]
                if sign:
                    g = sign(x, y)
                    if g < 0.06:
                        inner = smooth((0.06 - g) / 0.06)
                        color = mix(color, glyph, inner * 0.9)
                    elif g < 0.16:
                        # A glow round the sign
                        color = mix(color, glyph, (1 - (g - 0.06) / 0.1) * 0.25)
                # A dark line at the very edge, so a stone stands off the next
                edge = smooth(-d / 0.05)
                color = mix([c * 0.35 for c in dark], color, edge)
                for i in range(3):
                    total[i] += color[i]
                total[3] += 1
            if total[3] > 0:
                a = total[3] / len(SAMPLES)
                picture.pixels[py * size + px] = [total[0] / total[3], total[1] / total[3], total[2] / total[3], a]
    return picture


def prism(size=64):
    shape = rounded(regular(8, 0.74, math.pi / 8), 0.03)

    def facets(x, y, body):
        angle = math.atan2(y, x)
        sector = math.floor((angle + math.pi) / (math.pi / 4))
        hue = sector / 8 + math.hypot(x, y) * 0.3
        rainbow = [0.55 + 0.45 * math.sin(2 * math.pi * (hue + k / 3)) for k in range(3)]
        return mix(body, rainbow, 0.55)
    sign = union(regular(4, 0.3, 0), ring(0, 0, 0.42, 0.025))
    return gem(size, shape, sign, (1.0, 1.0, 1.0), (0.35, 0.35, 0.5), (1.0, 1.0, 1.0), facets)


def light_picture(size, distance, soft=0.05, core=None):
    """White light in a shape, for adding: `distance` as the shapes are"""
    picture = Picture(size, size)
    half = size / 2
    for py in range(size):
        for px in range(size):
            x, y = (px + 0.5 - half) / half, (py + 0.5 - half) / half
            d = distance(x, y)
            a = math.exp(-max(0.0, d) ** 2 / (soft * soft)) if d > 0 else 1.0
            picture.pixels[py * size + px] = [1.0, 1.0, 1.0, a]
    return picture


def charged(size=64):
    zig = strokes((-0.86, 0.0, -0.45, -0.16, 0.05), (-0.45, -0.16, -0.12, 0.14, 0.05), (-0.12, 0.14, 0.18, -0.14, 0.05), (0.18, -0.14, 0.5, 0.14, 0.05), (0.5, 0.14, 0.86, 0.0, 0.05))
    arrows = union(convex([(-0.98, 0), (-0.72, -0.2), (-0.72, 0.2)]), convex([(0.98, 0), (0.72, 0.2), (0.72, -0.2)]))
    return light_picture(size, union(zig, arrows), 0.08)


def nova_mark(size=64):
    rays = strokes(*[(0.55 * math.cos(a), 0.55 * math.sin(a), 0.9 * math.cos(a), 0.9 * math.sin(a), 0.035) for a in [i * math.pi / 4 + math.pi / 8 for i in range(8)]])
    return light_picture(size, union(ring(0, 0, 0.82, 0.03), rays), 0.08)


def select(size=64):
    frame = lambda x, y: abs(max(abs(x), abs(y)) - 0.9) - 0.035
    return light_picture(size, frame, 0.07)


def beam(length=256, thick=32, down=False):
    width, height = (thick, length) if down else (length, thick)
    picture = Picture(width, height)
    for py in range(height):
        for px in range(width):
            along = (py + 0.5) / height if down else (px + 0.5) / width
            across = ((px + 0.5) / width if down else (py + 0.5) / height) * 2 - 1
            ends = smooth(min(along, 1 - along) / 0.12)
            a = (math.exp(-across * across / 0.02) + math.exp(-across * across / 0.2) * 0.5) * ends
            picture.pixels[py * width + px] = [1.0, 1.0, 1.0, min(1.0, a)]
    return picture


def ley(width=32, height=128):
    picture = Picture(width, height)
    streaks = Noise(7, 32)
    for py in range(height):
        for px in range(width):
            t = py / height
            u = (px + 0.5) / width * 2 - 1
            c = mix((0.75, 0.95, 1.0), (0.15, 0.45, 0.95), t)
            s = streaks.fractal(px / 6, py / 10, 3)
            c = [min(1.0, v + (s - 0.5) * 0.3) for v in c]
            core = 1 - u * u * 0.6
            picture.pixels[py * width + px] = [c[0] * core, c[1] * core, c[2] * core, 1.0]
    return picture


def board(size=512):
    picture = Picture(size, size)
    stone, veins = Noise(13), Noise(29)
    cell = size // 8
    for py in range(size):
        for px in range(size):
            row, column = py // cell, px // cell
            fx, fy = (px % cell + 0.5) / cell, (py % cell + 0.5) / cell
            n = stone.fractal(px / 40, py / 40, 5)
            base = (0.09, 0.08, 0.14) if (row + column) % 2 == 0 else (0.12, 0.11, 0.18)
            c = [v * (0.75 + 0.5 * n) for v in base]
            # Each square sunk a little into the slab: a dark seam at the edge, light at its top left
            edge = min(fx, fy, 1 - fx, 1 - fy)
            c = [v * (0.55 + 0.45 * smooth(edge / 0.06)) for v in c]
            if fx < 0.05 or fy < 0.05:
                c = [v + 0.03 for v in c]
            # Ley lines running through the stone
            v = veins.fractal(px / 90, py / 90, 3)
            line = math.exp(-((v - 0.5) ** 2) / 0.0004)
            c = mix(c, (0.3, 0.6, 1.0), line * 0.14)
            # Darker towards the corners
            dx, dy = px / size - 0.5, py / size - 0.5
            c = [x * (1 - 0.6 * (dx * dx + dy * dy)) for x in c]
            picture.pixels[py * size + px] = [c[0], c[1], c[2], 1.0]
    return picture


def paste(picture, piece, left, top, add=False):
    for y in range(piece.height):
        for x in range(piece.width):
            r, g, b, a = piece.get(x, y)
            if add:
                picture.add(left + x, top + y, (r, g, b), a)
            else:
                picture.over(left + x, top + y, (r, g, b), a)


def icon(runes, size=64):
    """Three runes of fire in a line, flaring, above a frost rune and an arcane one"""
    picture = Picture(size, size)
    for y in range(size):
        for x in range(size):
            c = mix((0.06, 0.05, 0.12), (0.14, 0.1, 0.24), y / size)
            picture.pixels[y * size + x] = [c[0], c[1], c[2], 1.0]
    glow = radial(64, lambda d: math.exp(-(d * d) / 0.25) * 0.7, (1.0, 0.6, 0.25))
    small = {}
    for index, picture_of in enumerate(runes):
        small[index] = shrink(picture_of, 20)
    paste(picture, shrink(glow, 60), 2, -4, add=True)
    for k in range(3):
        paste(picture, small[0], 2 + k * 21, 12)
    paste(picture, small[1], 12, 38)
    paste(picture, small[3], 33, 38)
    return picture


def shrink(picture, size):
    """A picture drawn smaller, by averaging"""
    out = Picture(size, size)
    scale = picture.width / size
    for y in range(size):
        for x in range(size):
            total, weight = [0.0, 0.0, 0.0], 0.0
            alpha = 0.0
            count = 0
            for sy in range(int(y * scale), int((y + 1) * scale)):
                for sx in range(int(x * scale), int((x + 1) * scale)):
                    r, g, b, a = picture.get(sx, sy)
                    total[0] += r * a
                    total[1] += g * a
                    total[2] += b * a
                    weight += a
                    alpha += a
                    count += 1
            if weight > 0:
                out.pixels[y * size + x] = [total[0] / weight, total[1] / weight, total[2] / weight, alpha / count]
    return out


def pictures(folder, preview):
    images = folder / "Images" / "Runeweave"
    images.mkdir(parents=True, exist_ok=True)
    icons = folder / "Images" / "Icons"
    icons.mkdir(parents=True, exist_ok=True)
    made = {}
    runes = []
    for index, ((name, light, dark, glyph), (shape, sign)) in enumerate(zip(SCHOOLS, outlines())):
        runes.append(gem(64, shape, sign, light, dark, glyph))
        made["rune%d" % (index + 1)] = runes[-1]
    made["prism"] = prism()
    made["charged"] = charged()
    made["nova"] = nova_mark()
    made["select"] = select()
    made["glow"] = radial(64, lambda d: math.exp(-(d * d) / 0.18) * (1 - smooth((d - 0.85) / 0.15)))
    made["ring"] = radial(128, lambda d: math.exp(-((d - 0.82) ** 2) / 0.006) * (1 - smooth((d - 0.97) / 0.03)))
    made["spark"] = spark()
    made["beam"] = beam()
    made["beamDown"] = beam(down=True)
    made["ley"] = ley()
    made["icon"] = icon(runes)
    made["board"] = board()
    for name, picture in made.items():
        write_tga(icons / "runeweave.tga" if name == "icon" else images / (name + ".tga"), picture)
        if preview:
            write_png(preview / (name + ".png"), picture)
    readme = Path(__file__).resolve().parent.parent / ".github" / "readme" / "icons" / "runeweave.png"
    write_png(readme, made["icon"])


# --------------------------------------------------------------------------------------------
# Sounds
# --------------------------------------------------------------------------------------------

def tone(frequency, seconds, loud, fall=0.0, decay=8.0):
    """A sine that dies away, sliding down by `fall` of itself"""
    out, phase = [], 0.0
    count = int(seconds * 44100)
    for i in range(count):
        t = i / 44100
        f = frequency * (1 - fall * t / seconds)
        phase += 2 * math.pi * f / 44100
        out.append(math.sin(phase) * loud * math.exp(-t * decay) * min(1.0, t / 0.003))
    return out


def sounds(folder):
    out_dir = folder / "Sounds" / "Runeweave"
    out_dir.mkdir(parents=True, exist_ok=True)
    made = {}
    made["pick"] = bell(note(7), 0.18, 0.25, 0.4)
    swap = noise(0.16, 0.5, 300, 4000, lambda t, lo, hi: (lo + 900 * t, hi, math.sin(math.pi * t) ** 2))
    place(swap, tone(620, 0.08, 0.25, 0.3, 30), 0.1)
    made["swap"] = swap
    bad = []
    place(bad, tone(170, 0.14, 0.6, 0.2, 18), 0)
    place(bad, tone(150, 0.16, 0.6, 0.2, 16), 0.13)
    made["bad"] = bad
    for cascade in range(8):
        chord = []
        place(chord, bell(note(cascade * 2), 0.9, 0.45, 1.0), 0)
        place(chord, bell(note(cascade * 2 + 2), 0.8, 0.3, 0.8), 0.04)
        place(chord, noise(0.18, 0.25, 1500, 9000, lambda t, lo, hi: (lo, hi, (1 - t) ** 2), seed=cascade + 3), 0)
        made["match%d" % (cascade + 1)] = reverb(chord, 0.3)
    sparkle = []
    for i, step in enumerate((7, 9, 12, 14, 16)):
        place(sparkle, bell(note(step), 0.5, 0.25, 0.6), i * 0.04)
    made["made"] = reverb(sparkle, 0.35)
    land = []
    place(land, tone(220, 0.08, 0.35, 0.4, 40), 0)
    place(land, noise(0.05, 0.25, 200, 1500, lambda t, lo, hi: (lo, hi, (1 - t) ** 3), seed=9), 0)
    made["land"] = land
    bolt = noise(0.45, 0.8, 800, 12000, lambda t, lo, hi: (lo, hi * (1 - 0.7 * t), (1 - t) ** 1.5 * (0.6 + 0.4 * math.sin(t * 90) ** 2)), seed=11)
    place(bolt, tone(1400, 0.35, 0.3, 0.8, 6), 0)
    made["bolt"] = reverb(bolt, 0.25)
    nova = noise(0.7, 0.9, 40, 1800, lambda t, lo, hi: (lo, hi * (1 - 0.8 * t), (1 - t) ** 2), seed=13)
    place(nova, tone(90, 0.6, 0.7, 0.5, 5), 0)
    place(nova, bell(note(4, 261.63), 1.0, 0.25), 0.05)
    made["nova"] = reverb(nova, 0.35, 1.2)
    glass = []
    for i in range(14):
        place(glass, bell(note(i + 3), 0.6, 0.22, 0.9), i * 0.035)
    place(glass, noise(0.7, 0.2, 3000, 12000, lambda t, lo, hi: (lo, hi, math.sin(math.pi * t))), 0)
    made["prism"] = reverb(glass, 0.4, 1.3)
    swirl = noise(0.6, 0.6, 300, 6000, lambda t, lo, hi: (lo + 2000 * math.sin(math.pi * t), hi, math.sin(math.pi * t) ** 2), seed=17)
    made["shuffle"] = reverb(swirl, 0.3)
    surge = []
    for i, step in enumerate((0, 2, 4, 5, 7, 9, 10, 12)):
        place(surge, pluck(note(step, 261.63), 1.6, 0.4, seed=30 + step), i * 0.05)
    for step in (10, 12, 14):
        place(surge, bell(note(step), 1.4, 0.25), 0.4)
    made["surge"] = reverb(surge, 0.4, 1.4)
    over = []
    for i, step in enumerate((12, 9, 7, 4, 2, 0)):
        place(over, pluck(note(step, 261.63), 2.0, 0.4, seed=50 + step), i * 0.16)
    place(over, bell(note(0, 261.63), 2.2, 0.3, 0.5), 0.96)
    made["over"] = reverb(over, 0.45, 1.6)
    for name, samples in made.items():
        write_sound(out_dir / (name + ".ogg"), samples)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    random.seed(1)
    folder = Path(sys.argv[1])
    preview = Path(sys.argv[2]) if len(sys.argv) > 2 else None
    if preview:
        preview.mkdir(parents=True, exist_ok=True)
    pictures(folder, preview)
    sounds(folder)


if __name__ == "__main__":
    main()
