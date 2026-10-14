#!/usr/bin/env python3
"""Draws Wormcraft (Games/Wormcraft.lua): the squads, what they throw, the islands and the icon.

    python3 Tools/make_wormcraft.py Images

Writes Images/Wormcraft/<name>.tga. First sprites, 64 pixels square each and eight to a row of a
512 pixel square sheet, everybody seen from the side and facing right (the game turns them round
for the left). Row by row: a warrior, a paladin, a hunter and a rogue, standing and stepping
each; a priest, a shaman, a mage and a warlock; a druid, a recruit who hasn't said what they are
yet, a grave, a crate of health, a crate of something else, and a trap; then a fireball, an iron
grenade, a thorium one, the holy one, a seaforium charge, an explosive sheep twice (its legs a
moment apart) and a bomblet; then a shard of ice, a drop of fire, a meteor, a kodo, and the
crosshair. Feet are at the bottom of a picture, and a body a little under two thirds as tall as
it is.

Then the ground of every island, a tile of rock 128 pixels square that the game repeats, and the
edge of it, what grows or lies on top of it, 128 across and 16 down, also repeated: Elwynn's
grass, Durotar's red dust, Winterspring's snow and the ash of the Burning Steppes. And the sky
over each, 256 by 128 and stretched, with what is far away on the horizon. Also
Images/Icons/wormcraft.tga. Only the standard library is used. Pass a second folder to also get
PNG copies there, which are easier to look at than TGA.
"""
import math
import struct
import sys
import zlib
from pathlib import Path

SIZE, TILE, EDGE, SKY_W, SKY_H = 64, 128, 16, 256, 128

OUTLINE = (24, 18, 16)
SKIN, SKIN_DARK = (226, 176, 138), (180, 126, 96)
IRON, IRON_DARK, IRON_PALE = (150, 152, 162), (84, 86, 98), (214, 218, 228)
WOOD, WOOD_DARK = (128, 84, 46), (78, 48, 26)
GOLD, GOLD_DARK = (236, 190, 76), (150, 108, 34)
WHITE = (238, 236, 228)
LEATHER, LEATHER_DARK = (116, 76, 44), (70, 44, 26)
FLAME, FLAME_CORE, FLAME_DEEP = (255, 150, 40), (255, 240, 160), (210, 60, 20)


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def clamp(value):
    return max(0.0, min(1.0, value))


def noise(x, y, salt=0):
    """The same number between 0 and 1 for the same pixel every time"""
    n = (int(x) * 374761393 + int(y) * 668265263 + salt * 1442695041) & 0xFFFFFFFF
    n = ((n ^ (n >> 13)) * 1274126177) & 0xFFFFFFFF
    return ((n ^ (n >> 16)) & 0xFFFF) / 0xFFFF


def smooth(x, y, period, cell, salt=0):
    """Noise that changes gently, and comes round again every `period` pixels so a tile repeats"""
    cells = period // cell
    gx, gy = x / cell, y / cell
    x0, y0 = int(math.floor(gx)), int(math.floor(gy))
    fx, fy = gx - x0, gy - y0
    fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)

    def at(cx, cy):
        return noise(cx % cells, cy % cells, salt)

    top = at(x0, y0) + (at(x0 + 1, y0) - at(x0, y0)) * fx
    bottom = at(x0, y0 + 1) + (at(x0 + 1, y0 + 1) - at(x0, y0 + 1)) * fx
    return top + (bottom - top) * fy


def layered(x, y, period, salt=0):
    return (smooth(x, y, period, 32, salt) * 0.5 + smooth(x, y, period, 16, salt + 1) * 0.3 + smooth(x, y, period, 8, salt + 2) * 0.2)


# -----------------------------------------------------------------------------
# Sprites
# -----------------------------------------------------------------------------


class Canvas:
    """A picture with nothing on it to begin with, drawn on a shape at a time"""

    def __init__(self):
        self.pixels = {}

    def dot(self, x, y, color, alpha=255):
        x, y = int(x), int(y)
        if 0 <= x < SIZE and 0 <= y < SIZE:
            self.pixels[(x, y)] = (color, alpha)

    def ellipse(self, cx, cy, rx, ry, color, salt=0, alpha=255, lit=True):
        """Lit from the top left, and a little rough"""
        for y in range(int(cy - ry) - 1, int(cy + ry) + 2):
            for x in range(int(cx - rx) - 1, int(cx + rx) + 2):
                across, down = (x + 0.5 - cx) / rx, (y + 0.5 - cy) / ry
                if across * across + down * down <= 1:
                    shade = (across * 0.2 + down * 0.28 if lit else 0) + 0.08 * (noise(x, y, salt) - 0.5)
                    self.dot(x, y, mix(color, (0, 0, 0) if shade > 0 else (255, 255, 255), clamp(abs(shade))), alpha)

    def box(self, left, top, right, bottom, color, salt=0, alpha=255):
        for y in range(int(top), int(bottom) + 1):
            for x in range(int(left), int(right) + 1):
                light = 0.12 * (1 - (x - left) / max(1, right - left)) - 0.06
                self.dot(x, y, mix(mix(color, (255, 255, 255) if light > 0 else (0, 0, 0), abs(light)), (0, 0, 0), 0.1 * noise(x, y, salt)), alpha)

    def line(self, x0, y0, x1, y1, width, color, salt=0, alpha=255):
        length = max(0.01, math.hypot(x1 - x0, y1 - y0))
        for y in range(int(min(y0, y1) - width) - 1, int(max(y0, y1) + width) + 2):
            for x in range(int(min(x0, x1) - width) - 1, int(max(x0, x1) + width) + 2):
                along = clamp(((x + 0.5 - x0) * (x1 - x0) + (y + 0.5 - y0) * (y1 - y0)) / (length * length))
                if math.hypot(x + 0.5 - x0 - along * (x1 - x0), y + 0.5 - y0 - along * (y1 - y0)) <= width / 2:
                    self.dot(x, y, mix(color, (0, 0, 0), 0.1 * noise(x, y, salt)), alpha)

    def shape(self, test, color, salt=0, alpha=255):
        for y in range(SIZE):
            for x in range(SIZE):
                if test(x + 0.5, y + 0.5):
                    self.dot(x, y, mix(color, (0, 0, 0), 0.1 * noise(x, y, salt)), alpha)

    def glow(self, cx, cy, radius, inner, outer):
        """Light that fades out, under whatever is drawn after it"""
        for y in range(int(cy - radius), int(cy + radius) + 1):
            for x in range(int(cx - radius), int(cx + radius) + 1):
                away = math.hypot(x + 0.5 - cx, y + 0.5 - cy) / radius
                if away < 1:
                    self.dot(x, y, mix(inner, outer, away), int(255 * (1 - away) ** 1.5))

    def rows(self, outline=True):
        """With a dark line round everything solid, which is what makes it read from far away"""
        rows = []
        for y in range(SIZE):
            row = []
            for x in range(SIZE):
                pixel = self.pixels.get((x, y))
                if pixel:
                    color, alpha = pixel
                    row.append(tuple(round(clamp(c / 255) * 255) for c in color) + (alpha,))
                elif outline and any(self.pixels.get((x + dx, y + dy), (0, 0))[1] == 255 for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
                    row.append(OUTLINE + (255,))
                else:
                    row.append((0, 0, 0, 0))
            rows.append(row)
        return rows


# What every class looks like: what they wear on their body, legs and head, and what they hold
LOOKS = {
    "WARRIOR": {"body": (150, 60, 44), "under": IRON, "legs": IRON_DARK, "head": "helm", "held": "sword", "shield": (120, 40, 30)},
    "PALADIN": {"body": IRON_PALE, "under": IRON_PALE, "legs": IRON, "head": "helm_gold", "held": "hammer", "trim": GOLD},
    "HUNTER": {"body": (84, 112, 52), "under": LEATHER, "legs": LEATHER_DARK, "head": "hood_green", "held": "bow"},
    "ROGUE": {"body": (54, 46, 62), "under": (40, 34, 46), "legs": (34, 30, 40), "head": "mask", "held": "daggers"},
    "PRIEST": {"body": WHITE, "under": WHITE, "legs": WHITE, "head": "bare", "held": "staff_gold", "robe": True, "trim": GOLD},
    "SHAMAN": {"body": (52, 92, 170), "under": (110, 120, 140), "legs": LEATHER_DARK, "head": "fur", "held": "mace"},
    "MAGE": {"body": (70, 90, 190), "under": (70, 90, 190), "legs": (70, 90, 190), "head": "hat", "held": "staff_orb", "robe": True, "trim": (210, 220, 255)},
    "WARLOCK": {"body": (84, 44, 110), "under": (84, 44, 110), "legs": (84, 44, 110), "head": "horns", "held": "fel", "robe": True, "trim": (120, 220, 60)},
    "DRUID": {"body": (120, 90, 50), "under": (90, 120, 60), "legs": LEATHER_DARK, "head": "antlers", "held": "staff_wood"},
    "RECRUIT": {"body": (150, 140, 120), "under": (150, 140, 120), "legs": (110, 100, 86), "head": "bare", "held": None},
}


def unit(look, stepping):
    """Somebody of a squad, side on and facing right: a big head on a small body, as in Worms"""
    canvas = Canvas()
    ground, cx = 62, 28
    # Legs, apart when stepping
    spread = 6 if stepping else 2
    for side in (-1, 1):
        x = cx + side * spread
        canvas.line(cx, 46, x, ground - 3, 6, look["legs"], 1)
        canvas.ellipse(x + 2, ground - 2, 4.5, 2.5, LEATHER_DARK, 2)
    # The body, a robe down to the ground for those who wear one
    if look.get("robe"):
        canvas.shape(lambda x, y: 34 <= y <= ground - 3 and abs(x - cx) < 8 + (y - 34) * 0.3, look["body"], 3)
        canvas.shape(lambda x, y: 34 <= y <= ground - 3 and abs(x - cx - 1) < 1.6, look["trim"], 4)
    canvas.ellipse(cx, 41, 10, 11, look["under"], 5)
    canvas.box(cx - 7, 32, cx + 7, 50, look["body"], 6)
    if look.get("trim"):
        canvas.box(cx - 7, 32, cx + 7, 33, look["trim"])
    canvas.box(cx - 8, 47, cx + 8, 49, LEATHER_DARK, 7)
    if look.get("shield"):
        canvas.ellipse(cx - 9, 42, 5, 8, look["shield"], 8)
        canvas.ellipse(cx - 9, 42, 1.8, 2.5, GOLD, 9)

    # The head, big, and what is on it
    head = look["head"]
    hx, hy = cx + 2, 20
    canvas.ellipse(hx, hy, 11, 11, SKIN, 10)
    canvas.dot(hx + 6, hy - 1, OUTLINE)
    canvas.dot(hx + 6, hy, OUTLINE)
    canvas.line(hx + 4, hy + 6, hx + 8, hy + 5, 1.2, SKIN_DARK)
    if head in ("helm", "helm_gold"):
        metal = GOLD if head == "helm_gold" else IRON
        canvas.shape(lambda x, y: (x - hx) ** 2 + (y - hy) ** 2 < 12.5 ** 2 and y < hy - 1, metal, 11)
        canvas.box(hx - 12, hy - 2, hx + 11, hy, metal, 12)
        if head == "helm":
            canvas.line(hx - 9, hy - 9, hx - 15, hy - 17, 3, WHITE, 13)
            canvas.line(hx + 7, hy - 10, hx + 10, hy - 18, 3, WHITE, 14)
    elif head == "hood_green":
        canvas.shape(lambda x, y: (x - hx + 2) ** 2 + (y - hy) ** 2 < 13 ** 2 and not ((x - hx - 3) ** 2 + (y - hy - 2) ** 2 < 8.5 ** 2), (70, 96, 44), 15)
    elif head == "mask":
        canvas.shape(lambda x, y: (x - hx) ** 2 + (y - hy) ** 2 < 12 ** 2 and y < hy - 3, (40, 34, 46), 16)
        canvas.box(hx - 4, hy + 3, hx + 10, hy + 7, (40, 34, 46), 17)
    elif head == "fur":
        canvas.ellipse(hx - 2, hy - 9, 12, 5, (220, 210, 190), 18)
        canvas.ellipse(cx, 32, 12, 4, (220, 210, 190), 19)
    elif head == "hat":
        canvas.shape(lambda x, y: hy - 30 < y < hy - 6 and abs(x - hx + (y - hy + 6) * 0.25) < (y - hy + 30) * 0.45, look["body"], 20)
        canvas.box(hx - 14, hy - 8, hx + 12, hy - 6, look["body"], 21)
        canvas.dot(hx - 4, hy - 20, GOLD)
    elif head == "horns":
        canvas.shape(lambda x, y: (x - hx + 2) ** 2 + (y - hy) ** 2 < 13 ** 2 and not ((x - hx - 3) ** 2 + (y - hy - 2) ** 2 < 8.5 ** 2), look["body"], 22)
        canvas.line(hx - 6, hy - 10, hx - 13, hy - 19, 3.5, (200, 190, 170), 23)
        canvas.line(hx + 4, hy - 11, hx + 9, hy - 20, 3.5, (200, 190, 170), 24)
    elif head == "antlers":
        canvas.ellipse(hx - 1, hy - 8, 10, 4, (90, 120, 60), 25)
        for side, base in ((-1, hx - 5), (1, hx + 4)):
            canvas.line(base, hy - 10, base + side * 6, hy - 22, 2.5, (176, 146, 96), 26)
            canvas.line(base + side * 3, hy - 16, base + side * 10, hy - 18, 2, (176, 146, 96), 27)
    elif head == "bare":
        canvas.shape(lambda x, y: (x - hx) ** 2 + (y - hy) ** 2 < 11.5 ** 2 and y < hy - 5 and x < hx + 6, (110, 70, 40), 28)

    # The arm in front, and what it holds
    held = look["held"]
    canvas.line(cx + 2, 36, cx + 11, 43, 5, look["under"], 29)
    hand = (cx + 12, 43)
    canvas.ellipse(hand[0], hand[1], 2.6, 2.6, SKIN, 30)
    if held == "sword":
        canvas.line(hand[0], hand[1], hand[0] + 14, hand[1] - 18, 3, IRON_PALE, 31)
        canvas.line(hand[0] - 3, hand[1] - 1, hand[0] + 3, hand[1] + 2, 2.5, GOLD_DARK)
    elif held == "hammer":
        canvas.line(hand[0], hand[1] + 4, hand[0] + 6, hand[1] - 16, 2.5, WOOD, 32)
        canvas.box(hand[0] + 1, hand[1] - 22, hand[0] + 12, hand[1] - 15, GOLD, 33)
    elif held == "bow":
        canvas.shape(lambda x, y: abs(math.hypot(x - hand[0] + 8, y - hand[1]) - 14) < 1.5 and x > hand[0] - 1, WOOD, 34)
        canvas.line(hand[0] - 1, hand[1] - 13, hand[0] - 1, hand[1] + 13, 0.8, WHITE)
    elif held == "daggers":
        canvas.line(hand[0], hand[1], hand[0] + 9, hand[1] - 6, 2.2, IRON_PALE, 35)
        canvas.line(cx - 6, 44, cx - 1, 50, 2.2, IRON_PALE, 36)
    elif held in ("staff_gold", "staff_orb", "staff_wood"):
        wood = GOLD_DARK if held == "staff_gold" else WOOD
        canvas.line(hand[0], hand[1] + 16, hand[0] + 2, hand[1] - 22, 2.5, wood, 37)
        if held == "staff_orb":
            canvas.glow(hand[0] + 2, hand[1] - 24, 7, (220, 240, 255), (80, 120, 255))
            canvas.ellipse(hand[0] + 2, hand[1] - 24, 3, 3, (200, 230, 255), 38)
        elif held == "staff_gold":
            canvas.ellipse(hand[0] + 2, hand[1] - 23, 3.5, 3.5, GOLD, 39)
        else:
            canvas.ellipse(hand[0] + 2, hand[1] - 23, 4, 3, (80, 140, 60), 40)
    elif held == "mace":
        canvas.line(hand[0], hand[1] + 2, hand[0] + 8, hand[1] - 12, 2.5, WOOD, 41)
        canvas.ellipse(hand[0] + 9, hand[1] - 14, 4, 4, IRON, 42)
    elif held == "fel":
        canvas.glow(hand[0] + 4, hand[1] - 4, 9, (210, 255, 160), (60, 200, 40))
        canvas.ellipse(hand[0] + 4, hand[1] - 4, 3.5, 3.5, (150, 255, 90), 43, lit=False)
    return canvas.rows()


def grave():
    canvas = Canvas()
    canvas.shape(lambda x, y: 26 < y < 62 and abs(x - 32) < 11 and (y > 34 or math.hypot(x - 32, y - 34) < 11), (150, 150, 158), 50)
    canvas.box(29, 36, 35, 54, (110, 110, 118))
    canvas.box(24, 41, 40, 45, (110, 110, 118))
    canvas.box(16, 59, 48, 62, (96, 76, 52), 51)
    return canvas.rows()


def crate(health):
    canvas = Canvas()
    canvas.box(14, 30, 50, 62, WOOD, 52)
    for y in (31, 46, 61):
        canvas.box(14, y, 50, y + 1, WOOD_DARK)
    for x in (14, 49):
        canvas.box(x, 30, x + 1, 62, IRON_DARK)
    if health:
        canvas.box(24, 38, 40, 54, WHITE)
        canvas.box(29, 40, 35, 52, (210, 30, 30))
        canvas.box(26, 43, 38, 49, (210, 30, 30))
    else:
        canvas.ellipse(32, 46, 8, 8, IRON_DARK, 53)
        canvas.line(36, 39, 40, 34, 1.5, WOOD_DARK)
        canvas.dot(41, 33, FLAME_CORE)
        canvas.dot(42, 32, FLAME)
    return canvas.rows()


def trap():
    canvas = Canvas()
    canvas.ellipse(32, 58, 16, 5, IRON_DARK, 54)
    canvas.ellipse(32, 56, 12, 4, (170, 60, 30), 55)
    canvas.glow(32, 54, 8, FLAME_CORE, FLAME_DEEP)
    return canvas.rows()


def fireball():
    canvas = Canvas()
    canvas.glow(32, 32, 22, FLAME_CORE, FLAME_DEEP)
    canvas.ellipse(32, 32, 9, 9, FLAME, 56, lit=False)
    canvas.ellipse(30, 30, 4, 4, FLAME_CORE, 57, lit=False)
    return canvas.rows(outline=False)


def bomb(color, mark=None):
    canvas = Canvas()
    canvas.ellipse(32, 36, 11, 11, color, 58)
    canvas.box(29, 22, 35, 26, IRON_DARK, 59)
    canvas.line(32, 22, 36, 14, 1.5, WOOD_DARK)
    canvas.glow(37, 13, 5, FLAME_CORE, FLAME)
    if mark == "cross":
        canvas.box(30, 29, 34, 43, WHITE)
        canvas.box(26, 33, 38, 36, WHITE)
    elif mark == "band":
        canvas.box(21, 35, 43, 37, GOLD_DARK)
    return canvas.rows()


def charge():
    canvas = Canvas()
    for index, x in enumerate((24, 32, 40)):
        canvas.box(x - 3, 34, x + 3, 58, (180, 40, 30), 60 + index)
    canvas.box(20, 42, 44, 45, (60, 50, 40))
    canvas.line(32, 34, 38, 24, 1.5, WOOD_DARK)
    canvas.glow(39, 22, 5, FLAME_CORE, FLAME)
    return canvas.rows()


def sheep(stepping):
    canvas = Canvas()
    spread = 5 if stepping else 2
    for x in (22, 40):
        canvas.line(x - spread / 2, 48, x - spread / 2 + (spread if x > 30 else -spread) / 2, 61, 3.5, (50, 44, 40), 62)
        canvas.line(x + spread / 2, 48, x + spread / 2, 61, 3.5, (50, 44, 40), 63)
    for bx, by in ((22, 40), (30, 36), (38, 38), (26, 46), (36, 46), (44, 43), (18, 45)):
        canvas.ellipse(bx, by, 8, 7, WHITE, 64)
    canvas.ellipse(50, 36, 6, 7, (60, 52, 48), 65)
    canvas.dot(52, 34, WHITE)
    canvas.ellipse(46, 31, 3, 2, (60, 52, 48), 66)
    # And what makes it explosive
    canvas.box(26, 30, 36, 34, (180, 40, 30))
    canvas.line(31, 30, 33, 22, 1.5, WOOD_DARK)
    canvas.glow(33, 21, 4, FLAME_CORE, FLAME)
    return canvas.rows()


def shard():
    canvas = Canvas()
    canvas.glow(32, 30, 18, (220, 245, 255), (80, 150, 230))
    canvas.shape(lambda x, y: 12 < y < 56 and abs(x - 32) < (56 - y) * 0.2, (190, 230, 255), 67)
    canvas.shape(lambda x, y: 12 < y < 50 and abs(x - 30) < (50 - y) * 0.06, WHITE)
    return canvas.rows()


def flame():
    canvas = Canvas()
    canvas.glow(32, 40, 18, FLAME_CORE, FLAME_DEEP)
    canvas.shape(lambda x, y: (x - 32) ** 2 + (y - 44) ** 2 < 64 or (16 < y < 44 and abs(x - 32) < (y - 16) * 0.28), FLAME, 68)
    canvas.ellipse(32, 45, 4, 4, FLAME_CORE, 69, lit=False)
    return canvas.rows(outline=False)


def meteor():
    canvas = Canvas()
    canvas.glow(32, 32, 26, (200, 255, 120), (40, 140, 20))
    canvas.ellipse(32, 34, 13, 12, (70, 60, 56), 70)
    for x, y in ((27, 31), (36, 37), (33, 28)):
        canvas.ellipse(x, y, 2.5, 2, (150, 255, 80), 71, lit=False)
    return canvas.rows()


def kodo():
    canvas = Canvas()
    canvas.ellipse(30, 38, 20, 14, (130, 120, 112), 72)
    canvas.ellipse(50, 34, 9, 10, (120, 110, 104), 73)
    canvas.line(54, 28, 60, 18, 3, (230, 220, 200), 74)
    canvas.line(46, 27, 44, 17, 3, (230, 220, 200), 75)
    for x in (16, 26, 36, 44):
        canvas.line(x, 46, x, 60, 6, (110, 100, 94), 76)
    canvas.dot(54, 32, OUTLINE)
    canvas.box(14, 28, 40, 32, (150, 60, 40), 77)
    return canvas.rows()


def crosshair():
    canvas = Canvas()
    canvas.shape(lambda x, y: abs(math.hypot(x - 32, y - 32) - 14) < 2.2, (255, 60, 50))
    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        canvas.line(32 + dx * 8, 32 + dy * 8, 32 + dx * 22, 32 + dy * 22, 2.6, (255, 60, 50))
    return canvas.rows()


# -----------------------------------------------------------------------------
# Islands
# -----------------------------------------------------------------------------

# Rock, a darker one, what lies on top, the light in the sky from the top down, and what is far off
THEMES = {
    "elwynn": {"rock": (124, 88, 56), "dark": (82, 56, 36), "stone": (150, 144, 132), "top": (78, 150, 52), "top_dark": (46, 104, 36),
               "sky": ((88, 150, 222), (196, 226, 246)), "far": ((92, 132, 120), (60, 104, 72))},
    "durotar": {"rock": (176, 92, 54), "dark": (120, 58, 36), "stone": (200, 140, 96), "top": (216, 150, 88), "top_dark": (170, 104, 60),
                "sky": ((230, 150, 80), (250, 222, 160)), "far": ((190, 110, 76), (150, 76, 52))},
    "winterspring": {"rock": (104, 112, 132), "dark": (64, 70, 92), "stone": (150, 160, 180), "top": (240, 246, 252), "top_dark": (196, 214, 236),
                     "sky": ((120, 160, 210), (220, 236, 248)), "far": ((200, 214, 232), (150, 170, 200))},
    "steppes": {"rock": (70, 58, 56), "dark": (40, 32, 32), "stone": (110, 96, 90), "top": (96, 86, 82), "top_dark": (64, 56, 54),
                "sky": ((60, 20, 24), (200, 90, 40)), "far": ((54, 34, 34), (34, 20, 22)), "embers": True},
}


def ground(theme):
    def paint(x, y):
        value = layered(x, y, TILE, 80)
        color = mix(theme["dark"], theme["rock"], clamp(value * 1.3 - 0.05))
        # Pebbles in it, here and there
        stone = smooth(x, y, TILE, 8, 90) * smooth(x, y, TILE, 32, 91)
        if stone > 0.38:
            color = mix(color, theme["stone"], clamp((stone - 0.38) * 4))
        if theme.get("embers") and smooth(x, y, TILE, 8, 95) > 0.86:
            color = mix(color, (255, 110, 30), 0.7)
        return mix(color, (0, 0, 0), 0.08 * noise(x, y, 81))

    return [[tuple(round(c) for c in paint(x, y)) + (255,) for x in range(TILE)] for y in range(TILE)]


def edge(theme):
    """Whatever lies on top of the ground, ragged at the top so blades of grass stick up"""
    rows = []
    for y in range(EDGE):
        row = []
        for x in range(TILE):
            reach = 4 + 5 * smooth(x, 0, TILE, 4, 100) + 3 * noise(x, 0, 101)
            if y < EDGE - reach - 4:
                row.append((0, 0, 0, 0))
                continue
            shade = (y - (EDGE - reach - 4)) / (reach + 4)
            color = mix(theme["top"], theme["top_dark"], clamp(shade * 0.9 + 0.2 * noise(x, y, 102)))
            row.append(tuple(round(c) for c in color) + (255,))
        rows.append(row)
    return rows


def sky(theme):
    high, low = theme["sky"]
    far, near = theme["far"]

    def ridge(x, salt, base, height):
        return base - height * (smooth(x, 0, SKY_W, 64, salt) * 0.7 + smooth(x, 0, SKY_W, 16, salt + 1) * 0.3)

    rows = []
    for y in range(SKY_H):
        row = []
        for x in range(SKY_W):
            color = mix(high, low, (y / SKY_H) ** 1.3)
            if y > ridge(x, 110, SKY_H * 0.95, SKY_H * 0.45):
                color = mix(far, color, 0.35)
            if y > ridge(x, 120, SKY_H * 1.05, SKY_H * 0.35):
                color = mix(near, color, 0.15)
            row.append(tuple(round(c) for c in color) + (255,))
        rows.append(row)
    return rows


def icon():
    canvas = Canvas()
    canvas.shape(lambda x, y: True, (88, 150, 222))
    canvas.glow(42, 24, 22, FLAME_CORE, FLAME_DEEP)
    canvas.shape(lambda x, y: y > 46 + 6 * math.sin(x / 9), (124, 88, 56), 120)
    canvas.shape(lambda x, y: 46 + 6 * math.sin(x / 9) < y < 50 + 6 * math.sin(x / 9), (78, 150, 52))
    rows = canvas.rows(outline=False)
    little = sheep(False)
    for y in range(SIZE):
        for x in range(SIZE):
            source = little[min(SIZE - 1, int((y - 14) * 1.3))][min(SIZE - 1, int(x * 1.3))] if y >= 14 else (0, 0, 0, 0)
            if source[3] == 255 and x < SIZE / 1.3:
                rows[y][x] = source
    return rows


def beside(*pictures):
    return [sum((picture[y] for picture in pictures), []) for y in range(len(pictures[0]))]


def below(*rows):
    return [row for picture in rows for row in picture]


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


target = Path(sys.argv[1])
preview = Path(sys.argv[2]) if len(sys.argv) > 2 else None
EMPTY = [[(0, 0, 0, 0)] * SIZE for _ in range(SIZE)]


def pair(name):
    return [unit(LOOKS[name], False), unit(LOOKS[name], True)]


sheet = below(
    beside(*pair("WARRIOR"), *pair("PALADIN"), *pair("HUNTER"), *pair("ROGUE")),
    beside(*pair("PRIEST"), *pair("SHAMAN"), *pair("MAGE"), *pair("WARLOCK")),
    beside(*pair("DRUID"), *pair("RECRUIT"), grave(), crate(True), crate(False), trap()),
    beside(fireball(), bomb(IRON_DARK), bomb((190, 110, 50), "band"), bomb(GOLD, "cross"), charge(), sheep(False), sheep(True), bomb(IRON_DARK)),
    beside(shard(), flame(), meteor(), kodo(), crosshair(), EMPTY, EMPTY, EMPTY),
    *([beside(*([EMPTY] * 8))] * 3),
)
write(target / "Wormcraft" / "sprites.tga", sheet, preview)
for name, theme in THEMES.items():
    write(target / "Wormcraft" / (name + ".tga"), ground(theme), preview)
    write(target / "Wormcraft" / (name + "_edge.tga"), edge(theme), preview)
    write(target / "Wormcraft" / (name + "_sky.tga"), sky(theme), preview)
write(target / "Icons" / "wormcraft.tga", icon(), preview)
