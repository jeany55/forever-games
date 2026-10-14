#!/usr/bin/env python3
"""Turns Kenney's "Boardgame Pack" into the cards, dice and sounds the addon ships.

    python3 Tools/convert_kenney.py <the unpacked boardgamePack_v2 folder> .

Writes Images/Cards/<rank><suit>.tga for the fifty-two cards (rank A, 2 to 9, T, J, Q, K and suit
S, H, D, C), Images/Cards/back.tga, a pip of each suit as Images/Cards/suit<suit>.tga,
Images/Dice/<colour><face>.tga with Images/Dice/shadow.tga to lie under them, the
Images/Icons/crazyeights.tga made of two of the cards, Images/Icons/yacht.tga made of three dice,
and copies the sounds to Sounds/.

The game client only reads power of two textures, and a card is neither square nor a power of
two: it is stretched to fill one, and drawn back at its own shape. A die is turned as it rolls,
and the client turns a picture inside its own square: it is drawn small enough in the middle of its
texture that no corner leaves it, whichever way round. Only the standard library is
used, see convert_pieces.py for how the PNGs are read. Pass a third folder to also get PNG
copies there, which are easier to look at than TGA.
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
BACK = "cardBack_blue4"
# The part of an ace its one big pip is in: left, top, right, bottom
PIP_BOX = (40, 65, 100, 125)
DICE = {"White": "white", "Red": "red"}
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
    write(images / "Cards" / "back.tga", resize(read_png(cards / f"{BACK}.png")[2], CARD_SIZE), preview)
    eights = [read_png(cards / f"card{suit}8.png")[2] for suit in ("Spades", "Hearts")]
    write(images / "Icons" / "crazyeights.tga", icon(*eights), preview)

    for color, name in DICE.items():
        for face in range(1, 7):
            _, _, rows = read_png(source / "PNG" / "Dice" / f"die{color}_border{face}.png")
            write(images / "Dice" / f"{name}{face}.tga", centred(resize(rows, (DIE_SIDE, DIE_SIDE)), DIE_TEXTURE), preview)
    write(images / "Dice" / "shadow.tga", shadow(), preview)
    write(images / "Icons" / "yacht.tga", yacht_icon(read_png(source / "PNG" / "Dice" / "dieWhite_border6.png")[2]), preview)

    (target / "Sounds").mkdir(exist_ok=True)
    sounds = [path for path in sorted((source / "Bonus").glob("*.ogg")) if path.stem.rstrip("0123456789") in SOUNDS]
    for path in sounds:
        shutil.copyfile(path, target / "Sounds" / path.name)
    print(f"wrote {len(SUITS) * len(RANKS) + 1} cards, {len(SUITS)} suits, {len(DICE) * 6} dice with a shadow and {len(sounds)} sounds")


if __name__ == "__main__":
    main(*sys.argv[1:4])
