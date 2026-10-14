#!/usr/bin/env python3
"""Turns the logo into the texture the addon ships.

    python3 Tools/make_logo.py <forevergames.png> .

Writes Images/logo.tga, and the two white shapes the page it is on is dressed with, which
GUI/MainFrame.lua tints: Images/glow.tga, a light that is brightest in the middle and gone at the
edge, and Images/rule.tga, a line that fades out at both ends.

The empty space around the logo is cut off, and what is left, which is wider than it is high, is
stretched to fill a square power of two texture, the only kind the game client reads.
GUI/MainFrame.lua draws it back at its own shape: the script prints that shape, which is
LOGO_ASPECT there.

Only the standard library is used, see convert_pieces.py for how the PNG is read. Pass a third
folder to also get a PNG copy there.
"""
import math
import sys
from pathlib import Path

from convert_kenney import resize, write
from convert_pieces import bounds, read_png

SIZE = (512, 512)
GLOW = 128
RULE = (256, 4)


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


def rule():
    """A line across, solid in the middle and fading out towards both ends."""
    width, height = RULE
    row = [(255, 255, 255, round(255 * math.sin(math.pi * (x + 0.5) / width) ** 2)) for x in range(width)]
    return [list(row) for _ in range(height)]


def main(source, target, preview=None):
    _, _, rows = read_png(Path(source))
    left, top, right, bottom = bounds(rows)
    cut = [row[left:right] for row in rows[top:bottom]]
    preview = Path(preview) if preview else None
    write(Path(target) / "Images" / "logo.tga", resize(cut, SIZE), preview)
    write(Path(target) / "Images" / "glow.tga", glow(), preview)
    write(Path(target) / "Images" / "rule.tga", rule(), preview)
    print(f"width / height = {(right - left) / (bottom - top):.3f}")


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    main(*sys.argv[1:])
