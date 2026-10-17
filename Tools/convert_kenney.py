#!/usr/bin/env python3
"""Turns Kenney's "Boardgame Pack" into the cards, dice and sounds the addon ships.

    python3 Tools/convert_kenney.py <the unpacked boardgamePack_v2 folder> .

Writes Images/Cards/<rank><suit>.tga for the fifty-two cards (rank A, 2 to 9, T, J, Q, K and suit
S, H, D, C), a back for each design and colour the player can choose from as
Images/Cards/Backs/<design>_<colour>.tga, a pip of each suit as Images/Cards/suit<suit>.tga,
Images/Dice/<colour><face>.tga with Images/Dice/shadow.tga to lie under them (white and red
as Kenney drew them, the other colours of the backs painted from the red), the
Images/Icons/crazyeights.tga made of two of the cards, Images/Icons/yacht.tga made of three dice,
and copies the sounds to Sounds/.

The game client only reads power of two textures, and a card is neither square nor a power of
two: it is stretched to fill one, and drawn back at its own shape. A die is turned as it rolls,
and the client turns a picture inside its own square: it is drawn small enough in the middle of its
texture that no corner leaves it, whichever way round. Only the standard library is
used, see convert_pieces.py for how the PNGs are read. Pass a third folder to also get PNG
copies there, which are easier to look at than TGA.

Kenney's backs are flat: a grey edge, a white border and inside it a body of one colour with a
pattern on it in two shades of that colour, darker by 0.9 and 0.79. A back is read from the blue
one as how dark each pixel of its body is, and painted in any colour from that, so that every
colour has every design and a design of our own (drawn here, in the same shades) fits in.
"""
import shutil
import struct
import sys
import zlib
from pathlib import Path

from convert_pieces import read_png

CARD_SIZE = (128, 256)
SMALL = (64, 64)
SUITS = {"Spades": "S", "Hearts": "H", "Diamonds": "D", "Clubs": "C"}
RANKS = {"A": "A", "10": "T", "J": "J", "Q": "Q", "K": "K", **{str(n): str(n) for n in range(2, 10)}}
# The colours of a back, as its body and its darkest shade. Kenney's darker 0.79 of the body, a
# dark back has a pattern lighter than itself. GUI/Cards.lua knows the same names. Dice come in
# the same colours, but for red, which Kenney drew, and with white besides (GUI/Dice.lua)
BACK_COLOURS = {
    "blue": ((68, 133, 191), None),
    "red": ((201, 63, 63), None),
    "green": ((82, 152, 72), None),
    "purple": ((126, 86, 186), None),
    "pink": ((226, 104, 166), None),
    "black": ((50, 54, 64), (86, 92, 108)),
}
DARKEST = 0.79
# The designs, Kenney's by the name of the blue back they are read from, ours drawn by a function
# of the shade at a point of the body. GUI/Cards.lua knows the same names, in the same order
KENNEY_BACKS = {"suits": "cardBack_blue4", "pips": "cardBack_blue5", "frame": "cardBack_blue3"}
# The body of a back, left, top, right, bottom, and the frame inside it as Kenney draws it: how
# far in from the body's edge and how thick
BODY = (7, 7, 133, 183)
FRAME_IN, FRAME_WIDTH = 15, 5
# How much of the body is left between the frame and the diamonds of the lattice inside it
LATTICE_GAP = 2
# How many points across and down a pixel of a drawn back is sampled at, for smooth edges
SAMPLES = 4
# The part of an ace its one big pip is in: left, top, right, bottom
PIP_BOX = (40, 65, 100, 125)
DICE = {"White": "white", "Red": "red"}
# Kenney's red die, which the dice of other colours are painted from
DIE_RED = (200, 62, 62)
# A die, and the texture it is drawn in. Games/ and GUI/Dice.lua know the same numbers
DIE_TEXTURE, DIE_SIDE = 128, 88
# The shadow under a die: its corners are about as round as the die's, and its edge this soft
SHADOW_CORNER, SHADOW_BLUR = 10, 6
# Yacht's icon: three sixes on felt, each how big, where its middle is and how far it is turned
FELT = (22, 70, 44)
ICON_DICE = ((27, 19, 22, -14), (27, 44, 21, 11), (27, 32, 44, 3))
SOUNDS = ("cardPlace", "cardSlide", "chipsCollide", "dieThrow", "dieShuffle")


def weights(length, size):
    """For each of `size` output pixels, the source pixels along `length` it is made of and how much of each."""
    table = []
    scale = length / size
    for index in range(size):
        if scale >= 1:
            # Smaller: everything the pixel covers, by how much of it
            low, high = index * scale, (index + 1) * scale
            covered = []
            for source in range(int(low), min(length - 1, int(high)) + 1):
                overlap = min(high, source + 1) - max(low, source)
                if overlap > 1e-9:
                    covered.append((source, overlap / scale))
            table.append(covered)
        else:
            # Larger: between the two nearest
            at = min(max((index + 0.5) * scale - 0.5, 0), length - 1)
            low = min(int(at), length - 2)
            table.append([(low, 1 - (at - low)), (low + 1, at - low)])
    return table


def resize(rows, size):
    """Scales an image to (width, height), on premultiplied colour so edges don't pick up a fringe."""
    width, height = size
    premultiplied = [[(r * a, g * a, b * a, a) for r, g, b, a in row] for row in rows]
    columns, lines = weights(len(rows[0]), width), weights(len(rows), height)
    squeezed = [[tuple(sum(row[x][c] * w for x, w in covered) for c in range(4)) for covered in columns] for row in premultiplied]

    result = []
    for covered in lines:
        line = []
        for x in range(width):
            r, g, b, a = (sum(squeezed[y][x][c] * w for y, w in covered) for c in range(4))
            if a < 0.5:
                line.append((0, 0, 0, 0))
            else:
                line.append(tuple(min(255, round(v / a)) for v in (r, g, b)) + (min(255, round(a)),))
        result.append(line)
    return result


def pip(rows):
    """The big pip in the middle of an ace on its own, with the white of the card made clear."""
    left, top, right, bottom = PIP_BOX
    box = [row[left:right] for row in rows[top:bottom]]
    ink = min((pixel for row in box for pixel in row), key=lambda pixel: pixel[1])
    cut = []
    for row in box:
        # How much ink there is in a pixel shows in how far it is from white
        cut.append([ink[:3] + (round(255 * (255 - pixel[1]) / (255 - ink[1])),) for pixel in row])
    xs = [x for row in cut for x, pixel in enumerate(row) if pixel[3] > 8]
    ys = [y for y, row in enumerate(cut) if any(pixel[3] > 8 for pixel in row)]
    side = max(max(xs) - min(xs), max(ys) - min(ys)) + 5
    x0, y0 = (min(xs) + max(xs) + 1 - side) // 2, (min(ys) + max(ys) + 1 - side) // 2
    clear = (0, 0, 0, 0)
    return [
        [cut[y][x] if 0 <= y < len(cut) and 0 <= x < len(cut[0]) else clear for x in range(x0, x0 + side)]
        for y in range(y0, y0 + side)
    ]


def icon(back, front):
    """Two cards on the table, one half over the other."""
    width, height = 40, 54
    rows = [[(28, 34, 52, 255)] * SMALL[0] for _ in range(SMALL[1])]
    for card, left, top in ((back, 5, 3), (front, 19, 7)):
        for y, row in enumerate(resize(card, (width, height))):
            for x, (r, g, b, a) in enumerate(row):
                under = rows[top + y][left + x]
                rows[top + y][left + x] = tuple((c * a + u * (255 - a)) // 255 for c, u in zip((r, g, b), under)) + (255,)
    return rows


def centred(rows, size):
    """An image in the middle of a clear square of a size."""
    clear = (0, 0, 0, 0)
    top, left = (size - len(rows)) // 2, (size - len(rows[0])) // 2
    result = [[clear] * size for _ in range(size)]
    for y, row in enumerate(rows):
        result[top + y][left : left + len(row)] = row
    return result


def shadow():
    """A soft dark square with round corners, as big as a die. How dark is for the game to say."""
    half, inner = DIE_SIDE / 2, DIE_SIDE / 2 - SHADOW_CORNER
    rows = []
    for y in range(DIE_TEXTURE):
        row = []
        for x in range(DIE_TEXTURE):
            # How far out of the square's rounded edge, negative inside
            dx, dy = abs(x + 0.5 - DIE_TEXTURE / 2) - inner, abs(y + 0.5 - DIE_TEXTURE / 2) - inner
            out = (max(dx, 0) ** 2 + max(dy, 0) ** 2) ** 0.5 + min(max(dx, dy), 0) - SHADOW_CORNER
            t = min(max((SHADOW_BLUR - out) / (2 * SHADOW_BLUR), 0), 1)
            row.append((0, 0, 0, round(255 * t * t * (3 - 2 * t))))
        rows.append(row)
    assert half + SHADOW_BLUR <= DIE_TEXTURE / 2
    return rows


def turned(rows, degrees):
    """An image turned about its middle, on a clear square big enough for any corner."""
    from math import cos, radians, sin

    size, side = len(rows), int(len(rows) * 1.5)
    c, s = cos(radians(degrees)), sin(radians(degrees))
    result = []
    for y in range(side):
        line = []
        for x in range(side):
            # Where this pixel comes from in the image, sampled between the four nearest
            dx, dy = x + 0.5 - side / 2, y + 0.5 - side / 2
            sx, sy = c * dx + s * dy + size / 2 - 0.5, -s * dx + c * dy + size / 2 - 0.5
            x0, y0 = int(sx // 1), int(sy // 1)
            total = [0.0, 0.0, 0.0, 0.0]
            for ox, oy in ((0, 0), (1, 0), (0, 1), (1, 1)):
                px, py = x0 + ox, y0 + oy
                weight = (1 - abs(sx - px)) * (1 - abs(sy - py))
                if 0 <= px < size and 0 <= py < size and weight > 0:
                    r, g, b, a = rows[py][px]
                    for channel, value in enumerate((r * a, g * a, b * a, a)):
                        total[channel] += value * weight
            a = total[3]
            line.append((0, 0, 0, 0) if a < 0.5 else tuple(min(255, round(v / a)) for v in total[:3]) + (min(255, round(a)),))
        result.append(line)
    return result


def yacht_icon(die):
    """Three dice showing the same, thrown on felt: a yacht."""
    size = SMALL[0]
    rows = []
    for y in range(size):
        # The felt is a little darker towards its corners
        rows.append([])
        for x in range(size):
            far = ((x - size / 2) ** 2 + (y - size / 2) ** 2) ** 0.5 / (size * 0.7)
            rows[-1].append(tuple(round(c * (1 - 0.35 * far)) for c in FELT) + (255,))
    for side, middle_x, middle_y, degrees in ICON_DICE:
        picture = turned(resize(die, (side, side)), degrees)
        half = len(picture) // 2
        for shadow, (dx, dy) in ((True, (2, 2)), (False, (0, 0))):
            for y, line in enumerate(picture):
                for x, (r, g, b, a) in enumerate(line):
                    tx, ty = middle_x - half + x + dx, middle_y - half + y + dy
                    if 0 <= tx < size and 0 <= ty < size and a:
                        under = rows[ty][tx]
                        colour = (0, 0, 0) if shadow else (r, g, b)
                        alpha = a * (0.4 if shadow else 1) / 255
                        rows[ty][tx] = tuple(round(c * alpha + u * (1 - alpha)) for c, u in zip(colour, under)) + (255,)
    return rows


def shades(rows, body):
    """How dark each pixel of a back's body is next to the body's own colour, None where it is not body."""
    length = sum(c * c for c in body)
    return [[None if (r == g == b or a == 0) else (r * body[0] + g * body[1] + b * body[2]) / length for r, g, b, a in row] for row in rows]


def framed(x, y):
    """The shade where Kenney's frame is, None inside it, outside it 1. In pixels of the body."""
    width, height = BODY[2] - BODY[0], BODY[3] - BODY[1]
    inset = min(x, y, width - x, height - y)
    if inset < FRAME_IN:
        return 1
    return 0.9 if inset < FRAME_IN + FRAME_WIDTH else None


def lattice(x, y):
    """Argyle: diamonds in two shades, crossed by thin dark lines through their middles."""
    from math import floor, hypot

    inside = framed(x, y)
    if inside is not None:
        return inside
    left, top = FRAME_IN + FRAME_WIDTH, FRAME_IN + FRAME_WIDTH
    width, height = BODY[2] - BODY[0] - 2 * left, BODY[3] - BODY[1] - 2 * top
    # A little of the body between the frame and the diamonds, so that they don't run into it
    if min(x - left, y - top, left + width - x, top + height - y) < LATTICE_GAP:
        return 1
    # Three diamonds across and four down, a diamond being a square of the grid turned on its point.
    # Across one way and the other it is a and b, each diamond between two whole numbers of both
    across, down = width / 3, height / 4
    u, v = (x - left) / across, (y - top) / down
    a, b = u + v, u - v
    # The lines go through the middles of the diamonds, how far from one is measured in pixels
    reach = 1 / hypot(1 / across, 1 / down)
    if min(abs(a % 1 - 0.5), abs(b % 1 - 0.5)) * reach < 0.5:
        return DARKEST
    return 0.9 if (floor(a) + floor(b)) % 2 == 0 else 1


def sunburst(x, y):
    """Rays in two shades out of a ring in the middle, inside the frame."""
    from math import atan2, hypot, pi

    inside = framed(x, y)
    if inside is not None:
        return inside
    dx, dy = x - (BODY[2] - BODY[0]) / 2, y - (BODY[3] - BODY[1]) / 2
    far = hypot(dx, dy)
    if far < 14:
        # A diamond in the middle of the ring
        return DARKEST if abs(dx) / 10 + abs(dy) / 13 < 1 else 1
    if far < 19:
        return DARKEST if far >= 16 else 1
    rays = 28
    return 0.9 if int((atan2(dy, dx) + pi) / (2 * pi) * rays) % 2 == 0 else 1


DRAWN_BACKS = {"lattice": lattice, "sunburst": sunburst}


def drawn(plain, shade):
    """A back of our own: the plain one, its body shaded by a function of where in it a point is."""
    rows = [list(row) for row in plain]
    for y in range(BODY[1], BODY[3]):
        for x in range(BODY[0], BODY[2]):
            total = 0
            for sy in range(SAMPLES):
                for sx in range(SAMPLES):
                    total += shade(x - BODY[0] + (sx + 0.5) / SAMPLES, y - BODY[1] + (sy + 0.5) / SAMPLES)
            rows[y][x] = total / SAMPLES**2
    return rows


def painted(rows, shaded, colour):
    """A back in a colour: the neutral pixels as they were, the body by how dark each pixel of it is."""
    body, darkest = colour
    darkest = darkest or tuple(c * DARKEST for c in body)
    result = []
    for row, shade_row in zip(rows, shaded):
        line = []
        for pixel, shade in zip(row, shade_row):
            if shade is None:
                line.append(pixel)
            else:
                t = (1 - shade) / (1 - DARKEST)
                line.append(tuple(min(255, max(0, round(b + (d - b) * t))) for b, d in zip(body, darkest)) + (pixel[3],))
        result.append(line)
    return result


def backs(cards):
    """Every design of back, read or drawn, as (name, pixels, how dark each pixel of its body is)."""
    blue = BACK_COLOURS["blue"][0]
    result = []
    for name, file in KENNEY_BACKS.items():
        rows = read_png(cards / f"{file}.png")[2]
        result.append((name, rows, shades(rows, blue)))
    plain = read_png(cards / "cardBack_blue1.png")[2]
    for name, shade in DRAWN_BACKS.items():
        result.append((name, plain, drawn(shades(plain, blue), shade)))
    return result


def repainted_die(rows, body):
    """Kenney's red die in another colour. Each of its pixels is white mixed with the red made
    darker, so how much of each there is can be read back and the red put back as another colour."""
    result = []
    for row in rows:
        line = []
        for r, g, b, a in row:
            # The red and green of white are the same, all that is between them is the red
            red = (r - g) / (DIE_RED[0] - DIE_RED[1])
            white = (g - DIE_RED[1] * red) / 255
            line.append(tuple(min(255, max(0, round(255 * white + red * c))) for c in body) + (a,) if a else (0, 0, 0, 0))
        result.append(line)
    return result


def write(path, rows, preview):
    width, height = len(rows[0]), len(rows)
    path.parent.mkdir(parents=True, exist_ok=True)
    # TGA rows run bottom to top
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, width, height, 32, 8)
    path.write_bytes(header + b"".join(bytes((b, g, r, a)) for row in reversed(rows) for (r, g, b, a) in row))
    if preview:
        raw = b"".join(b"\x00" + b"".join(bytes(pixel) for pixel in row) for row in rows)

        def chunk(kind, body):
            return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

        png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        png += chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
        preview.mkdir(parents=True, exist_ok=True)
        (preview / (path.parent.name + "_" + path.stem + ".png")).write_bytes(png)


def main(source, target, preview=None):
    source, target = Path(source), Path(target)
    preview = Path(preview) if preview else None
    cards, images = source / "PNG" / "Cards", target / "Images"

    for suit, letter in SUITS.items():
        for rank, code in RANKS.items():
            _, _, rows = read_png(cards / f"card{suit}{rank}.png")
            write(images / "Cards" / f"{code}{letter}.tga", resize(rows, CARD_SIZE), preview)
            if rank == "A":
                write(images / "Cards" / f"suit{letter}.tga", resize(pip(rows), SMALL), preview)
    for design, rows, shaded in backs(cards):
        for colour, paint in BACK_COLOURS.items():
            write(images / "Cards" / "Backs" / f"{design}_{colour}.tga", resize(painted(rows, shaded, paint), CARD_SIZE), preview)
    eights = [read_png(cards / f"card{suit}8.png")[2] for suit in ("Spades", "Hearts")]
    write(images / "Icons" / "crazyeights.tga", icon(*eights), preview)

    for color, name in DICE.items():
        for face in range(1, 7):
            _, _, rows = read_png(source / "PNG" / "Dice" / f"die{color}_border{face}.png")
            write(images / "Dice" / f"{name}{face}.tga", centred(resize(rows, (DIE_SIDE, DIE_SIDE)), DIE_TEXTURE), preview)
    for colour, (body, _) in BACK_COLOURS.items():
        if colour in DICE.values():
            continue
        for face in range(1, 7):
            _, _, rows = read_png(source / "PNG" / "Dice" / f"dieRed_border{face}.png")
            die = repainted_die(rows, body)
            write(images / "Dice" / f"{colour}{face}.tga", centred(resize(die, (DIE_SIDE, DIE_SIDE)), DIE_TEXTURE), preview)
    write(images / "Dice" / "shadow.tga", shadow(), preview)
    write(images / "Icons" / "yacht.tga", yacht_icon(read_png(source / "PNG" / "Dice" / "dieWhite_border6.png")[2]), preview)

    (target / "Sounds").mkdir(exist_ok=True)
    sounds = [path for path in sorted((source / "Bonus").glob("*.ogg")) if path.stem.rstrip("0123456789") in SOUNDS]
    for path in sounds:
        shutil.copyfile(path, target / "Sounds" / path.name)
    print(f"wrote {len(SUITS) * len(RANKS)} cards, {len(KENNEY_BACKS) + len(DRAWN_BACKS)} designs of back in {len(BACK_COLOURS)} colours, {len(SUITS)} suits, {len(set(DICE.values()) | set(BACK_COLOURS)) * 6} dice with a shadow and {len(sounds)} sounds")


if __name__ == "__main__":
    main(*sys.argv[1:4])
