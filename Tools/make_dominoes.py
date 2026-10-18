#!/usr/bin/env python3
"""Draws what Dominoes is played with (GUI/Dominoes.lua, Games/Dominoes.lua), its icon, and makes
its sounds.

    python3 Tools/make_dominoes.py Images Sounds

A tile is drawn in parts, so that it can lie at any angle and its pips stay sharp: its body, its
pips and the shadow and light round it. Writes Images/Dominoes/<look><Face|Back><H|V><256|128>.tga,
the body of a tile of each look lying (H) and standing (V), face up with the line across its middle
and the brass pin in it, or face down with a brass diamond on its back, in two sizes. Each is lit
from the top left whichever way it lies, and fills the middle of a square picture so that it can
be turned within it (FILL). The looks are ivory, ebony, jade and sapphire.

Also Images/Dominoes/pip64.tga and pip32.tga, a pip in white to be tinted the colour of a look's
pips; shadow.tga and glow.tga, the shadow under a tile and the light round one that is lit up,
drawn for a tile lying down and turned with it; table.tga, the light on the middle of the table
and the shadow round its edge, laid over the felt; and Images/Icons/dominoes.tga.

The sounds, Sounds/dominoes<Name><take>.ogg, are a tile clacked down onto the table, a tile slid
across it, a wash of all of them stirred face down, two knocks on the table for passing, and a
marimba for a hand won. They need ffmpeg. The drawing and sound helpers are Tools/make_mancala.py's.
Pass a third folder to also get PNG copies of the pictures there.

Every size here is in units of a tile's width: a tile is two long and one wide, and its pictures
are measured the same way in GUI/Dominoes.lua. Change them in both.
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
    marimba,
    mix,
    normalize,
    note,
    ring,
    rounded,
    smoothstep,
    tick,
    value_noise,
    write,
    write_sound,
)

# How much of the side of its picture a tile's length fills, and how much bigger than that the
# light round a lit tile is drawn. GUI/Dominoes.lua has these too
FILL = 224 / 256
GLOW_OVER = 1.2
# A tile lying down: half its length, half its width, and how round its corners are
HALF_LONG, HALF_SHORT, CORNER = 1.0, 0.5, 0.11
# How wide the rounded edge is, and how high it rises
BEVEL, BEVEL_RISE = 0.085, 0.05
# The line across the middle of a face: how far it reaches from the middle, how wide and deep
LINE_REACH, LINE_WIDTH, LINE_DEPTH = 0.37, 0.016, 0.5
# The brass pin in the middle of a face, and the diamond on a back
PIN_RADIUS = 0.06
DIAMOND = 0.17
# The line cut round the edge of a back, in from the edge
BORDER_IN, BORDER_WIDTH = 0.12, 0.012
LIGHT_DIRECTION = normalize((-0.5, -0.62, 0.6))
HALFWAY = normalize((LIGHT_DIRECTION[0], LIGHT_DIRECTION[1], LIGHT_DIRECTION[2] + 1))
BRASS, BRASS_DARK = (236, 198, 112), (120, 84, 34)
EPSILON = 0.004

# Each look: its colour from dark to light, how its grain runs, how shiny it is, and what the
# line across the middle is filled with
LOOKS = {
    "ivory": {"dark": (206, 192, 160), "light": (246, 240, 224), "grain": (3.0, 38.0), "shine": 0.32, "gloss": 26, "inlay": None},
    "ebony": {"dark": (14, 12, 12), "light": (52, 44, 40), "grain": (4.0, 30.0), "shine": 0.55, "gloss": 60, "inlay": BRASS},
    "jade": {"dark": (22, 84, 58), "light": (132, 210, 162), "grain": (2.4, 2.4), "shine": 0.5, "gloss": 48, "inlay": BRASS},
    "sapphire": {"dark": (14, 30, 96), "light": (70, 112, 214), "grain": (2.2, 2.2), "shine": 0.7, "gloss": 72, "inlay": (225, 230, 245)},
}


def bevel(distance):
    """How high the surface is at so far inside the edge: rounding up from the edge to flat"""
    t = clamp(-distance / BEVEL)
    return math.sin(t * math.pi / 2)


def groove(x, y, face):
    """How deep what is cut into the tile is: the line across a face, the border round a back"""
    if face:
        across = math.exp(-((x / LINE_WIDTH) ** 2))
        return across * smoothstep(LINE_REACH + 0.02, LINE_REACH - 0.02, abs(y))
    inner = rounded(x, y, HALF_LONG - BORDER_IN, HALF_SHORT - BORDER_IN, CORNER * 0.6)
    return math.exp(-((inner / BORDER_WIDTH) ** 2))


def brass_at(x, y, face):
    """How much of a point is brass, and how high the brass rises there"""
    if face:
        r = math.hypot(x, y) / PIN_RADIUS
        if r >= 1:
            return 0.0, 0.0
        return smoothstep(1.0, 0.85, r), math.sqrt(max(0.0, 1 - r * r)) * 0.6
    d = (abs(x) * 0.62 + abs(y)) / DIAMOND
    if d >= 1:
        return 0.0, 0.0
    return smoothstep(1.0, 0.9, d), 0.25 + 0.2 * (1 - d)


def surface(x, y, face):
    """The height of the tile at a point lying down, in units of its rise"""
    distance = rounded(x, y, HALF_LONG, HALF_SHORT, CORNER)
    height = bevel(distance) - LINE_DEPTH * groove(x, y, face) * 0.5
    amount, rise = brass_at(x, y, face)
    return height + amount * rise


def shade(look, x, y, face, screen):
    """The colour and coverage of the tile at a point of its picture. (x, y) are along and across
    the tile; screen turns a step along and across it into one across and down the screen"""
    distance = rounded(x, y, HALF_LONG, HALF_SHORT, CORNER)
    if distance > 0.012:
        return (0, 0, 0), 0.0
    coverage = smoothstep(0.012, -0.012, distance)
    # The surface's slope across the screen, from steps along the tile turned onto it
    along = (surface(x + EPSILON, y, face) - surface(x - EPSILON, y, face)) / (2 * EPSILON)
    across = (surface(x, y + EPSILON, face) - surface(x, y - EPSILON, face)) / (2 * EPSILON)
    slope_x, slope_y = screen(along, across)
    normal = normalize((-slope_x * BEVEL_RISE, -slope_y * BEVEL_RISE, 1.0))
    diffuse = max(0.0, sum(normal[i] * LIGHT_DIRECTION[i] for i in range(3)))
    specular = max(0.0, sum(normal[i] * HALFWAY[i] for i in range(3)))

    style = LOOKS[look]
    gx, gy = style["grain"]
    grain = fbm(x * gx + 11.3, y * gy + 3.7, 4)
    clouds = fbm(x * 1.7 + 4.1, y * 1.7 - 2.3, 3)
    base = mix(style["dark"], style["light"], clamp(0.25 + 0.75 * (0.6 * grain + 0.4 * clouds)))
    if look in ("jade", "sapphire"):
        # Light gathers in the far side of something you can see a little way into
        deep = clamp(0.5 + 0.35 * (x * 0.35 + y * 0.9))
        base = mix(base, style["light"], deep * 0.35)
    cut = groove(x, y, face)
    gloss, shine = style["gloss"], style["shine"]
    if cut > 0.05 and style["inlay"]:
        base = mix(base, style["inlay"], cut * 0.85)
    amount, _ = brass_at(x, y, face)
    if amount > 0:
        brass = mix(BRASS_DARK, BRASS, clamp(0.4 + 0.6 * diffuse))
        base = mix(base, brass, amount)
        gloss, shine = 40, max(shine, 0.6)
    light = 0.5 + 0.62 * diffuse
    color = tuple(clamp(c / 255 * light + shine * specular**gloss) * 255 for c in base)
    return color, coverage


def render_body(look, face, lying, size, samples=2):
    """A tile's body in the middle of a square picture"""
    reach = (HALF_LONG / FILL) * 2
    out = []
    for py in range(size):
        row = []
        for px in range(size):
            red = green = blue = alpha = 0.0
            for i in range(samples):
                for j in range(samples):
                    sx = ((px + (i + 0.5) / samples) / size - 0.5) * reach
                    sy = ((py + (j + 0.5) / samples) / size - 0.5) * reach
                    if lying:
                        color, a = shade(look, sx, sy, face, lambda along, across: (along, across))
                    else:
                        # Standing: along the tile is down the screen, across it is across
                        color, a = shade(look, sy, sx, face, lambda along, across: (across, along))
                    red, green, blue, alpha = red + color[0] * a, green + color[1] * a, blue + color[2] * a, alpha + a
            if alpha > 0:
                row.append((round(red / alpha), round(green / alpha), round(blue / alpha), round(255 * alpha / samples**2)))
            else:
                row.append((255, 255, 255, 0))
        out.append(row)
    return out


def halve(rows):
    """A picture at half the size, each pixel the four it stands for"""
    out = []
    for py in range(0, len(rows), 2):
        row = []
        for px in range(0, len(rows[0]), 2):
            quad = [rows[py][px], rows[py][px + 1], rows[py + 1][px], rows[py + 1][px + 1]]
            alpha = sum(p[3] for p in quad)
            if alpha == 0:
                row.append((255, 255, 255, 0))
                continue
            row.append(tuple(round(sum(p[c] * p[3] for p in quad) / alpha) for c in range(3)) + (round(alpha / 4),))
        out.append(row)
    return out


def render_around(size, paint, over):
    """Something drawn round a tile lying down, its picture `over` times as big as the body's"""
    reach = (HALF_LONG / FILL) * 2 * over
    out = []
    for py in range(size):
        row = []
        for px in range(size):
            x = ((px + 0.5) / size - 0.5) * reach
            y = ((py + 0.5) / size - 0.5) * reach
            row.append(paint(rounded(x, y, HALF_LONG, HALF_SHORT, CORNER)))
        out.append(row)
    return out


def shadow(distance):
    """Soft, and darkest under the tile"""
    a = 0.85 * smoothstep(0.1, -0.06, distance)
    return (0, 0, 0, round(255 * a))


def glow(distance):
    """A ring of light round the edge, fading outwards"""
    if distance > 0:
        a = math.exp(-((distance / 0.1) ** 2))
    else:
        a = math.exp(-((distance / 0.03) ** 2))
    return (255, 255, 255, round(255 * clamp(a)))


def pip(x, y):
    """A pip drilled into the tile and filled with paint, in white to be tinted: the rim at the top
    left in the shade of the hole, the far rim catching the light"""
    r = math.hypot(x, y)
    if r >= 0.84:
        return (0, 0, 0), 0.0
    edge = smoothstep(0.84, 0.74, r)
    toward = (x + y) / max(r, 1e-6)
    rim = smoothstep(0.35, 0.8, r)
    light = 0.86 - 0.3 * rim * clamp(-toward) + 0.14 * rim * clamp(toward)
    return (255 * light, 255 * light, 255 * light), edge


def table(x, y):
    """The middle of the table a little lit, its edges in shadow, and the weave of the felt"""
    r = math.hypot(x * 0.9, y * 1.1)
    dark = 0.6 * smoothstep(0.45, 1.35, r)
    weave = value_noise(x * 60, y * 60) - 0.5
    lit = 0.07 * (1 - smoothstep(0.0, 0.45, r))
    if lit > dark:
        return (255, 250, 230), clamp(lit + weave * 0.03)
    return (0, 0, 0), clamp(dark + weave * 0.05)


#############################
# The icon
#############################

ICON_PIPS = {
    0: [],
    1: [(0, 0)],
    2: [(-0.26, -0.26), (0.26, 0.26)],
    3: [(-0.26, -0.26), (0, 0), (0.26, 0.26)],
    4: [(-0.26, -0.26), (0.26, -0.26), (-0.26, 0.26), (0.26, 0.26)],
    5: [(-0.26, -0.26), (0.26, -0.26), (0, 0), (-0.26, 0.26), (0.26, 0.26)],
    6: [(-0.26, -0.26), (0.26, -0.26), (-0.26, 0), (0.26, 0), (-0.26, 0.26), (0.26, 0.26)],
}
# Two tiles: where each lies, its size, its angle, and its ends. The second lies over the first
ICON_TILES = [((0.3, -0.28), 0.4, 1.15, (4, 4)), ((-0.1, 0.14), 0.5, -0.52, (6, 3))]


def icon_tile(x, y, middle, unit, angle, ends):
    cos, sin = math.cos(angle), math.sin(angle)
    dx, dy = x - middle[0], y - middle[1]
    # Along and across the tile, in tile widths
    u, v = (dx * cos + dy * sin) / unit, (-dx * sin + dy * cos) / unit
    distance = rounded(u, v, HALF_LONG, HALF_SHORT, CORNER)
    if distance > 0.03:
        return None
    coverage = smoothstep(0.03, -0.03, distance)
    color, _ = shade("ivory", u, v, True, lambda along, across: (along * cos - across * sin, along * sin + across * cos))
    for half, pips in enumerate(ends):
        centre = -0.5 if half == 0 else 0.5
        for px, py in ICON_PIPS[pips]:
            # Pips laid out across the end, the end being square
            if math.hypot(u - centre - py, v - px) < 0.1:
                color = (24, 20, 18)
    return color, coverage


def icon(x, y):
    """Two ivory tiles on green felt"""
    edge = rounded(x, y, 0.98, 0.98, 0.22)
    if edge > 0:
        return (0, 0, 0), 0.0
    r = math.hypot(x, y)
    felt = mix((22, 82, 54), (8, 40, 26), smoothstep(0.2, 1.3, r))
    color, alpha = felt, smoothstep(0.02, -0.02, edge)
    for middle, unit, angle, ends in ICON_TILES:
        # The shadow first, then the tile
        shadowed = icon_tile(x - 0.05, y - 0.07, middle, unit, angle, ends)
        if shadowed:
            color = mix(color, (0, 0, 0), 0.45 * shadowed[1])
        tile = icon_tile(x, y, middle, unit, angle, ends)
        if tile:
            color = mix(color, tile[0], tile[1])
    return color, alpha


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


#############################
# Sounds
#############################


def clack(rng, gain=1.0):
    """A tile put down hard on a wooden table: the click of the tile and the knock of the wood"""
    pitch = rng.uniform(0.88, 1.14)
    tile = ring([(1650 * pitch, 0.55, 0.018), (2900 * pitch, 0.4, 0.012), (4700 * pitch, 0.25, 0.007)], 0.08, rng)
    wood = ring([(160 * pitch, 0.6, 0.035), (410 * pitch, 0.35, 0.02), (980 * pitch, 0.15, 0.012)], 0.14, rng)
    sound = add(add(wood, tile, gain=0.8), tick(0.005, 0.0011, rng), gain=0.6)
    return [value * gain for value in sound]


def slide(rng, seconds):
    """A tile pushed across the table: the hiss of it on the felt, and a little knock at the end"""
    out, last = [], 0.0
    count = int(44100 * seconds)
    for index in range(count):
        t = index / count
        envelope = math.sin(math.pi * min(1.0, t * 1.4)) ** 1.5 * (1 - t) ** 0.3
        last = last * 0.82 + rng.uniform(-1, 1) * 0.18
        out.append(last * envelope * 0.9)
    return add(out, clack(rng, 0.25), at=seconds * 0.85)


def wash(rng):
    """Every tile stirred face down on the table: hisses and clicks tumbling over each other"""
    sound = slide(rng, 1.3)
    sound = [value * 0.6 for value in sound]
    at = 0.0
    while at < 1.25:
        add(sound, clack(rng, rng.uniform(0.15, 0.5)), at=at)
        at += rng.expovariate(1 / 0.045)
    return sound


def knock(rng):
    """Two knuckle knocks on a wooden table"""
    sound = []
    for index in range(2):
        pitch = rng.uniform(0.95, 1.05)
        hit = ring([(118 * pitch, 0.8, 0.05), (236 * pitch, 0.45, 0.03), (520 * pitch, 0.2, 0.015)], 0.25, rng)
        add(hit, tick(0.008, 0.002, rng), gain=0.35)
        add(sound, hit, at=index * 0.17, gain=1.0 if index == 0 else 0.85)
    return sound


def make_sounds():
    rng = random.Random(11)
    sounds = {}
    for take in range(1, 5):
        sounds["Clack%d" % take] = finish(clack(rng), 0.36)
    for take in range(1, 4):
        sounds["Slide%d" % take] = finish(slide(rng, rng.uniform(0.16, 0.22)), 0.22)
    for take in range(1, 3):
        sounds["Wash%d" % take] = finish(wash(rng), 0.3)
    for take in range(1, 3):
        sounds["Knock%d" % take] = finish(knock(rng), 0.34)
    win = []
    for index, name in enumerate(("C5", "E5", "G5", "C6")):
        add(win, marimba(note(name), rng), at=index * 0.085, gain=0.75 + 0.08 * index)
    sounds["Win1"] = finish(win, 0.3)
    return sounds


if __name__ == "__main__":
    images = Path(sys.argv[1])
    sounds_folder = Path(sys.argv[2])
    preview = Path(sys.argv[3]) if len(sys.argv) > 3 else None
    for sound_name, samples in make_sounds().items():
        write_sound(sounds_folder, sound_name, samples, prefix="dominoes")
    folder = images / "Dominoes"
    write(images / "Icons" / "dominoes.tga", render_square(64, icon), preview)
    write(folder / "table.tga", render_square(256, table, samples=1), preview)
    write(folder / "pip64.tga", render_square(64, pip), preview)
    write(folder / "pip32.tga", render_square(32, pip), preview)
    write(folder / "shadow.tga", render_around(256, shadow, 1.0), preview)
    write(folder / "glow.tga", render_around(256, glow, GLOW_OVER), preview)
    for look in LOOKS:
        for face in (True, False):
            for lying in (True, False):
                big = render_body(look, face, lying, 256)
                name = look + ("Face" if face else "Back") + ("H" if lying else "V")
                write(folder / (name + "256.tga"), big, preview)
                write(folder / (name + "128.tga"), halve(big), preview)
                print(name, flush=True)
