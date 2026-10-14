#!/usr/bin/env python3
"""Turns the logo into the texture the addon ships.

    python3 Tools/make_logo.py <forevergames.png> .

Writes Images/logo.tga, and the two white shapes the page it is on is dressed with, which
GUI/MainFrame.lua tints: Images/glow.tga, a light that is brightest in the middle and gone at the
edge, Images/nebula.tga, a thin cloud of light with wisps and gaps in it, which is turned behind
the logo, and Images/rule.tga, a line that fades out at both ends.

And what the shine that runs over the logo's gold letters is made of: Images/lettering.tga, the
letters alone, which is all of the logo the shine is let fall on, Images/sheen.tga, the leaning
streak of light that is the shine, and Images/spark.tga, the star a corner of a letter glints with
as it goes by.

The empty space around the logo is cut off, and what is left, which is wider than it is high, is
stretched to fill a square power of two texture, the only kind the game client reads.
GUI/MainFrame.lua draws it back at its own shape: the script prints that shape, which is
LOGO_ASPECT there.

Only the standard library is used, see convert_pieces.py for how the PNG is read. Pass a third
folder to also get a PNG copy there.
"""
import colorsys
import math
import random
import sys
from pathlib import Path

from convert_kenney import resize, write
from convert_pieces import bounds, read_png

SIZE = (512, 512)
GLOW = 128
RULE = (256, 4)
NEBULA = 256
# The cloud is the same one every time. Its biggest wisps are a part of it this many across, and
# there are this many sizes of them, each half the size before and half as strong
NEBULA_SEED, NEBULA_WISPS, NEBULA_SIZES = 11, 4, 5
SHEEN = 128
# How far the streak leans: how much further right its top is than its middle, as a part of its
# width. GUI/MainFrame.lua knows it as SHINE_LEAN
LEAN = 0.17
SPARK = 64
# The hues gold has, in degrees, and how bright a letter's face is at the least, and its darker
# sides, of 1
GOLD_HUES, FACE, SIDE = (18, 62), 0.5, 0.3
# The rows of the logo its two words are in, as parts of its height, and how many pixels a shape
# has to be made of to be a letter rather than a speck
WORDS, LETTER = (0.23, 0.65), 1000


def glow():
    """A round light, falling away smoothly from the middle to nothing at the edge."""
    rows = []
    for y in range(GLOW):
        row = []
        for x in range(GLOW):
            distance = min(1, math.hypot(x + 0.5 - GLOW / 2, y + 0.5 - GLOW / 2) / (GLOW / 2))
            row.append((255, 255, 255, round(255 * (1 - distance * distance * (3 - 2 * distance)) ** 1.5)))
        rows.append(row)
    return rows


def nebula():
    """A thin cloud of light: wisps of it with gaps between them, thickest around the middle
    and gone at the edge."""
    dice = random.Random(NEBULA_SEED)
    span = NEBULA_WISPS * 2 ** NEBULA_SIZES + 2
    lattice = [[dice.random() for _ in range(span)] for _ in range(span)]

    def noise(x, y):
        """Something between 0 and 1 that changes smoothly from place to place."""
        left, top = int(x), int(y)
        across, down = x - left, y - top
        across, down = across * across * (3 - 2 * across), down * down * (3 - 2 * down)
        above = lattice[top][left] * (1 - across) + lattice[top][left + 1] * across
        below = lattice[top + 1][left] * (1 - across) + lattice[top + 1][left + 1] * across
        return above * (1 - down) + below * down

    def cloud(x, y):
        """Wisps of every size on top of each other, from 0 to 1."""
        total, strength, scale = 0, 0.5, NEBULA_WISPS
        for _ in range(NEBULA_SIZES):
            total += strength * noise(x * scale, y * scale)
            strength, scale = strength / 2, scale * 2
        return total / (1 - 0.5 ** NEBULA_SIZES)

    rows = []
    for y in range(NEBULA):
        row = []
        for x in range(NEBULA):
            across, down = (x + 0.5) / NEBULA, (y + 0.5) / NEBULA
            # Bent by a cloud of its own, so the wisps curl rather than lie in a grid
            bend = 0.35 * (cloud(across, down + 0.5 * (1 - down)) - 0.5)
            density = cloud(min(1, max(0, across + bend)), min(1, max(0, down - bend)))
            # Only the thicker half of it shows, which is what leaves the gaps
            density = min(1, max(0, (density - 0.42) / 0.3))
            density = density * density * (3 - 2 * density)
            distance = min(1, math.hypot(2 * across - 1, 2 * down - 1))
            row.append((255, 255, 255, round(255 * density * (1 - distance * distance * (3 - 2 * distance)))))
        rows.append(row)
    return rows


def rule():
    """A line across, solid in the middle and fading out towards both ends."""
    width, height = RULE
    row = [(255, 255, 255, round(255 * math.sin(math.pi * (x + 0.5) / width) ** 2)) for x in range(width)]
    return [list(row) for _ in range(height)]


def lettering(rows):
    """The gold letters of the logo alone, white, with everything else of it clear."""
    width, height = len(rows[0]), len(rows)

    def gold(pixel):
        """How bright a pixel is if it is gold, and nothing if it isn't."""
        red, green, blue, alpha = pixel
        hue, saturation, value = colorsys.rgb_to_hsv(red / 255, green / 255, blue / 255)
        return value if alpha >= 200 and saturation > 0.12 and GOLD_HUES[0] <= hue * 360 <= GOLD_HUES[1] else 0

    bright = [[gold(pixel) for pixel in row] for row in rows]

    # The faces of the letters are the big bright shapes that lie wholly where the words are. The
    # frame is gold too, and so is the infinity sign, but they are elsewhere or reach out of there
    letters = [[False] * width for _ in range(height)]
    seen = [[False] * width for _ in range(height)]
    for top in range(height):
        for left in range(width):
            if bright[top][left] < FACE or seen[top][left]:
                continue
            seen[top][left] = True
            shape, todo = [], [(left, top)]
            while todo:
                x, y = todo.pop()
                shape.append((x, y))
                for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                    if 0 <= nx < width and 0 <= ny < height and bright[ny][nx] >= FACE and not seen[ny][nx]:
                        seen[ny][nx] = True
                        todo.append((nx, ny))
            lines = [y for _, y in shape]
            if len(shape) >= LETTER and min(lines) >= WORDS[0] * height and max(lines) <= WORDS[1] * height:
                for x, y in shape:
                    letters[y][x] = True

    # Their sides are darker: a letter is grown by what gold there is right around its face
    for _ in range(3):
        grown = [list(row) for row in letters]
        for y in range(1, height - 1):
            for x in range(1, width - 1):
                if bright[y][x] >= SIDE and (letters[y][x + 1] or letters[y][x - 1] or letters[y + 1][x] or letters[y - 1][x]):
                    grown[y][x] = True
        letters = grown

    # And its edge is softened, so the shine doesn't end in steps
    result = []
    for y in range(height):
        row = []
        for x in range(width):
            around = [letters[ny][nx] for ny in range(max(0, y - 1), min(height, y + 2)) for nx in range(max(0, x - 1), min(width, x + 2))]
            row.append((255, 255, 255, round(255 * sum(around) / len(around))))
        result.append(row)
    return result


def sheen():
    """A streak of light that leans to the right: a wide soft one, a bright thread down its
    middle, and a thin one that runs along behind it."""
    rows = []
    for y in range(SHEEN):
        middle = SHEEN / 2 + LEAN * SHEEN * (1 - 2 * (y + 0.5) / SHEEN)
        row = []
        for x in range(SHEEN):
            away = x + 0.5 - middle
            light = 0.5 * math.exp(-(away / 13) ** 2) + 0.5 * math.exp(-(away / 6) ** 2) + 0.35 * math.exp(-((away + 25) / 2.5) ** 2)
            row.append((255, 255, 255, round(255 * min(1, light))))
        rows.append(row)
    return rows


def spark():
    """A star of four points, brightest in the middle and gone at the edge."""
    rows = []
    for y in range(SPARK):
        row = []
        for x in range(SPARK):
            across, up = abs(2 * (x + 0.5) / SPARK - 1), abs(2 * (y + 0.5) / SPARK - 1)
            distance = min(1, math.hypot(across, up))
            light = math.exp(-60 * across * up) * (1 - distance) ** 2 + math.exp(-40 * distance * distance) * (1 - distance)
            row.append((255, 255, 255, round(255 * min(1, light))))
        rows.append(row)
    return rows


def main(source, target, preview=None):
    _, _, rows = read_png(Path(source))
    left, top, right, bottom = bounds(rows)
    cut = [row[left:right] for row in rows[top:bottom]]
    preview = Path(preview) if preview else None
    logo = resize(cut, SIZE)
    write(Path(target) / "Images" / "logo.tga", logo, preview)
    write(Path(target) / "Images" / "lettering.tga", lettering(logo), preview)
    write(Path(target) / "Images" / "sheen.tga", sheen(), preview)
    write(Path(target) / "Images" / "spark.tga", spark(), preview)
    write(Path(target) / "Images" / "glow.tga", glow(), preview)
    write(Path(target) / "Images" / "nebula.tga", nebula(), preview)
    write(Path(target) / "Images" / "rule.tga", rule(), preview)
    print(f"width / height = {(right - left) / (bottom - top):.3f}")


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    main(*sys.argv[1:])
