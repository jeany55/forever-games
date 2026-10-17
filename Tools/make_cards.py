#!/usr/bin/env python3
"""Draws what a card table needs besides the cards themselves, and the icons of Solitaire and FreeCell.

    python3 Tools/make_cards.py .

Writes Images/Cards/blank.tga, a card with nothing on it, Images/Cards/slot.tga, the outline of a
place a card can be put, and Images/Cards/again.tga, an arrow that goes round, for a deck that can
be turned over and gone through again. All three are white for the table to tint: the blank card
is the shadow under a card and the light on one. Images/Icons/solitaire.tga is three of the cards
convert_kenney.py made, laid on each other in the order a column of them is built, and
Images/Icons/freecell.tga the four aces fanned out on a darker felt.

The blank card and the outline are drawn at the shape of a card and stretched to the texture the
way the cards are.
Only the standard library is used. Pass a second folder to also get PNG copies there.
"""
import math
import struct
import sys
from pathlib import Path

from convert_kenney import CARD_SIZE, SMALL, resize, write

# A card as Kenney drew it, and how round its corners are
CARD = (140, 190)
CORNER = 12
LINE = 5
SAMPLES = 4
WHITE = (255, 255, 255)
ICON_CARDS = ("KS", "QH", "JS")
ICON_BACKGROUND = (28, 34, 52, 255)
FREECELL_CARDS = ("AS", "AH", "AC", "AD")
FREECELL_BACKGROUND = (13, 51, 56, 255)


def read_tga(path):
    """Rows of (r, g, b, a) from an uncompressed 32 bit TGA, top row first."""
    data = path.read_bytes()
    width, height = struct.unpack("<HH", data[12:16])
    rows = []
    for y in range(height):
        start = 18 + y * width * 4
        row = data[start : start + width * 4]
        rows.append([(row[x * 4 + 2], row[x * 4 + 1], row[x * 4], row[x * 4 + 3]) for x in range(width)])
    return list(reversed(rows))


def shape(size, inside):
    """A white picture of a shape: how much of each pixel it covers is how solid the pixel is."""
    width, height = size
    rows = []
    for y in range(height):
        row = []
        for x in range(width):
            hits = sum(
                inside(x + (i + 0.5) / SAMPLES, y + (j + 0.5) / SAMPLES) for i in range(SAMPLES) for j in range(SAMPLES)
            )
            row.append(WHITE + (round(255 * hits / SAMPLES**2),))
        rows.append(row)
    return rows


def rounded(x, y, inset):
    """Whether a point is within a card, less this much all the way round."""
    width, height = CARD
    radius = max(0, CORNER - inset)
    dx = max(inset + radius - x, x - (width - inset - radius), 0)
    dy = max(inset + radius - y, y - (height - inset - radius), 0)
    return dx * dx + dy * dy <= radius * radius and inset <= x <= width - inset and inset <= y <= height - inset


def blank(x, y):
    return rounded(x, y, 0)


def slot(x, y):
    return rounded(x, y, 2) and not rounded(x, y, 2 + LINE)


def again(x, y):
    """Most of a ring, and an arrowhead where it ends."""
    dx, dy = x - 32, y - 32
    distance, angle = math.hypot(dx, dy), math.degrees(math.atan2(-dy, dx)) % 360
    if 15 <= distance <= 22 and not 20 < angle < 80:
        return True
    # The head is where the ring ends, pointing on round it the way a clock goes
    points = [(32 + r * math.cos(math.radians(a)), 32 - r * math.sin(math.radians(a))) for r, a in ((18.5, 36), (8, 82), (29, 82))]
    signs = []
    for index in range(3):
        (x1, y1), (x2, y2) = points[index], points[(index + 1) % 3]
        signs.append((x2 - x1) * (y - y1) - (y2 - y1) * (x - x1) >= 0)
    return all(signs) or not any(signs)


def icon(cards):
    """Cards one on the other, each showing the corner of the one below."""
    width, height = 34, 46
    rows = [[ICON_BACKGROUND] * SMALL[0] for _ in range(SMALL[1])]
    for index, card in enumerate(cards):
        left, top = 3 + index * 12, 3 + index * 6
        for y, row in enumerate(resize(resize(card, CARD), (width, height))):
            for x, (r, g, b, a) in enumerate(row):
                under = rows[top + y][left + x]
                rows[top + y][left + x] = tuple((c * a + u * (255 - a)) // 255 for c, u in zip((r, g, b), under)) + (255,)
    return rows


def fan(cards):
    """Cards side by side, each covering most of the one before it, rising to the middle."""
    width, height = 30, 41
    rows = [[FREECELL_BACKGROUND] * SMALL[0] for _ in range(SMALL[1])]
    for index, card in enumerate(cards):
        left, top = 3 + index * 9, 14 - min(index, len(cards) - 1 - index) * 4
        for y, row in enumerate(resize(resize(card, CARD), (width, height))):
            for x, (r, g, b, a) in enumerate(row):
                under = rows[top + y][left + x]
                rows[top + y][left + x] = tuple((c * a + u * (255 - a)) // 255 for c, u in zip((r, g, b), under)) + (255,)
    return rows


def main(target, preview=None):
    images = Path(target) / "Images"
    preview = Path(preview) if preview else None
    write(images / "Cards" / "blank.tga", resize(shape(CARD, blank), CARD_SIZE), preview)
    write(images / "Cards" / "slot.tga", resize(shape(CARD, slot), CARD_SIZE), preview)
    write(images / "Cards" / "again.tga", shape(SMALL, again), preview)
    cards = [read_tga(images / "Cards" / f"{card}.tga") for card in ICON_CARDS]
    write(images / "Icons" / "solitaire.tga", icon(cards), preview)
    aces = [read_tga(images / "Cards" / f"{card}.tga") for card in FREECELL_CARDS]
    write(images / "Icons" / "freecell.tga", fan(aces), preview)
    print("wrote a blank card, a slot, an arrow and two icons")


if __name__ == "__main__":
    main(*sys.argv[1:3])
