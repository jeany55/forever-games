#!/usr/bin/env python3
"""Makes Run, Freedoom's map of the addon's own: one way through, no turnings to get lost in, a
dash to the exit with whatever lives on the way in the way. It is built with Tools/mapkit.py, in
Freedoom's pictures, into a WAD of its own that Tools/import_wad.py turns into a sector map with
those pictures (Tools/import_freedoom.sh does both).

    python3 Tools/make_run.py run.wad [--picture run.png]

The way, as it is walked:

1. The bay the player starts in, and a fast door out.
2. A hall with strips of light across its ceiling, turning north at a corner cut across.
3. A computer room, four pillars and a lit platform in the middle with the shotgun on it.
4. Stairs up, the ceiling stepping up over them, to a door.
5. Out under the sky: a canyon that winds down to a building, imps on ledges in its sides.
6. Inside, the nukage plant: a bridge that zig-zags over the nukage (that hurts, but not much,
   and can be climbed out of anywhere) to a lift.
7. Up the lift to a corridor with windows looking back down over the plant.
8. A warehouse where stacks of crates make a lane that winds through it, with the chaingun.
9. A dark corridor whose walls open behind the player and let out what waits in them.
10. The gate: an arena under the sky, a causeway over lava (which hurts more, and can be climbed
    out of too) past an island to the exit.

What is there on which skill: the easiest skills have fewer monsters (EASY), Doom's middle one
more (NORMAL), the hardest the most (HARD). Only the standard library is used.
"""
import argparse
import math
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mapkit import ALL, AMBUSH, EASY, HARD, LOWER_UNPEGGED, NORMAL, Map  # noqa: E402

NAME = "RUN"
SKY = "F_SKY1"
# Monsters and the rest, by Doom's numbers
PLAYER, ZOMBIE, SERGEANT, IMP, DEMON, SPECTRE, LOST_SOUL, BARON = 1, 3004, 9, 3001, 3002, 58, 3006, 3003
SHOTGUN, CHAINGUN = 2001, 2002
CLIP, CLIP_BOX, SHELLS, SHELL_BOX = 2007, 2048, 2008, 2049
STIMPACK, MEDIKIT, BONUS, ARMOR_BONUS, ARMOR, SOULSPHERE = 2011, 2012, 2014, 2015, 2018, 2013
BARREL, BURNING_BARREL, LAMP, TECH_COLUMN = 2035, 70, 2028, 48
RED_TORCH, SHORT_RED_TORCH, STALAGMITE, BURNT_TREE, CANDELABRA = 46, 57, 47, 43, 35
# Which skills: the middle and up, the hardest only
UP = NORMAL | HARD
# Doors: fast ones that shut again, and what opens for good when walked over; lifts and the way out
FAST_DOOR, OPEN_FAST_ONCE, LIFT_AGAIN, EXIT = 117, 109, 88, 52
# Floors that hurt, a little and more
NUKAGE_HURTS, LAVA_HURTS = 7, 5


def rect(x1, y1, x2, y2):
    return [(x1, y1), (x2, y1), (x2, y2), (x1, y2)]


def doorway(kit, x1, y1, x2, y2, floor, across, picture="BIGDOOR2", height=128, light=160, lintel=None, lintel_far=None,
            jamb="DOORSTOP", ceiling_flat="FLAT20"):
    """A door in a frame: 8 deep of frame, 16 of door, 8 of frame, from (x1, y1) to (x2, y2). Across
    is True for a door gone through along x. Lintel is what shows over the frame from the near
    side (x1 or y1), lintel_far from the far one"""
    if across:
        parts = [(x1, x1 + 8), (x1 + 8, x2 - 8), (x2 - 8, x2)]
        box = [rect(a, y1, b, y2) for a, b in parts]
        faces = [((x1 + 8, y1), (x1 + 8, y2)), ((x2 - 8, y1), (x2 - 8, y2))]
    else:
        parts = [(y1, y1 + 8), (y1 + 8, y2 - 8), (y2 - 8, y2)]
        box = [rect(x1, a, x2, b) for a, b in parts]
        faces = [((x1, y1 + 8), (x2, y1 + 8)), ((x1, y2 - 8), (x2, y2 - 8))]
    near = kit.sector(box[0], floor, floor + height, ceiling_flat, ceiling_flat, light, jamb, upper=lintel or jamb)
    kit.sector(box[1], floor, floor, ceiling_flat, ceiling_flat, light, "DOORTRAK", upper=picture, lower=picture, door=True, peg=LOWER_UNPEGGED)
    far = kit.sector(box[2], floor, floor + height, ceiling_flat, ceiling_flat, light, jamb, upper=lintel_far or lintel or jamb)
    for start, end in faces:
        kit.wall(start, end, special=FAST_DOOR)
    return near, far


def light_panel(kit, room, x1, y1, x2, y2, flat="TLITE6_4", light=208, rise=8, rim="METAL"):
    """A light set into a room's ceiling: a sector of its own, the floor under it lit too. The room
    is told to leave a hole for it"""
    panel = kit.sector(rect(x1, y1, x2, y2), room.floor, room.ceiling + rise, room.floor_flat, flat, light, room.wall)
    for start, end in zip(rect(x1, y1, x2, y2), rect(x1, y1, x2, y2)[1:] + rect(x1, y1, x2, y2)[:1]):
        kit.wall(start, end, facing=panel, upper=rim)
    return panel


def build():
    kit = Map()
    rng = random.Random(1993)

    # 1. The bay
    bay = kit.sector(rect(0, 0, 384, 384), 0, 192, "FLOOR4_8", "CEIL3_5", 160, "STARTAN2", upper="STARTAN2", holes=[rect(128, 128, 256, 256)])
    light_panel(kit, bay, 128, 128, 256, 256, flat="FLAT17", light=224, rise=16)
    for x, y in ((40, 40), (344, 40), (40, 344), (344, 344)):
        kit.thing(x, y, LAMP)
    kit.thing(64, 192, PLAYER, 0)
    kit.thing(320, 96, CLIP)
    doorway(kit, 384, 128, 416, 256, 0, True, lintel="STARTAN2", lintel_far="GRAY5")

    # 2. The hall of lights, east, then north round a corner cut across
    hall = dict(floor_flat="FLAT5_4", ceiling_flat="CEIL5_1", wall="GRAY5")
    edges = [416, 480, 512, 608, 640, 736, 768, 864, 896, 992, 1024, 1152]
    for index, (a, b) in enumerate(zip(edges, edges[1:])):
        lit = index % 2 == 1
        kit.sector(rect(a, 128, b, 256), 0, 136 if lit else 128, hall["floor_flat"], "FLAT17" if lit else hall["ceiling_flat"], 200 if lit else 128,
                   "LITE3" if lit else hall["wall"], upper="METAL")
    kit.sector([(1152, 128), (1216, 128), (1280, 192), (1280, 256), (1152, 256)], 0, 128, hall["floor_flat"], hall["ceiling_flat"], 128,
               hall["wall"], upper="METAL")
    edges = [256, 384, 416, 576, 608, 768]
    for index, (a, b) in enumerate(zip(edges, edges[1:])):
        lit = index % 2 == 1
        kit.sector(rect(1152, a, 1280, b), 0, 136 if lit else 128, hall["floor_flat"], "FLAT17" if lit else hall["ceiling_flat"],
                   200 if lit else 128, "LITE3" if lit else hall["wall"], upper="METAL")
    for x in (576, 704, 832, 960):
        kit.thing(x, 192, BONUS)
    kit.thing(1100, 192, CLIP)
    kit.thing(1216, 600, ZOMBIE, 270)
    kit.thing(1184, 680, ZOMBIE, 270, UP)
    kit.thing(1248, 690, SERGEANT, 270, HARD)

    # 3. The computer room
    pillars = [rect(1120, 864, 1184, 928), rect(1376, 864, 1440, 928), rect(1120, 1120, 1184, 1184), rect(1376, 1120, 1440, 1184)]
    computers = kit.sector(rect(1024, 768, 1536, 1280), 0, 224, "FLOOR0_3", "CEIL3_5", 144, "COMPTALL", holes=pillars + [rect(1216, 960, 1344, 1088)])
    for pillar in pillars:
        for start, end in zip(pillar, pillar[1:] + pillar[:1]):
            kit.wall(start, end, facing=computers, middle="COMPSTA1")
    kit.wall((1152, 768), (1280, 768), facing=computers, upper="COMPTALL")
    kit.sector(rect(1216, 960, 1344, 1088), 16, 240, "FLAT20", "TLITE6_5", 208, "COMPTALL", lower="STEP6", upper="METAL")
    kit.thing(1280, 1024, SHOTGUN)
    kit.thing(1280, 880, SHELLS)
    kit.thing(1072, 816, STIMPACK)
    kit.thing(1088, 1216, IMP, 270)
    kit.thing(1472, 1216, IMP, 270, UP)
    kit.thing(1280, 1216, ZOMBIE, 270)
    kit.thing(1472, 992, SERGEANT, 180, UP)
    kit.thing(1088, 1008, IMP, 0, HARD)
    for x, y in ((1056, 1248), (1504, 800)):
        kit.thing(x, y, TECH_COLUMN)

    # 4. Stairs up, east, the ceiling stepping up with them, and a landing
    for step in range(8):
        floor = 16 * (step + 1)
        kit.sector(rect(1536 + 32 * step, 960, 1568 + 32 * step, 1088), floor, floor + 160, "STEP1", "CEIL5_1", 144 - 4 * step, "BROWN1",
                   lower="STEP6", upper="BROWN1")
    kit.wall((1536, 960), (1536, 1088), facing=computers, upper="COMPTALL")
    kit.sector(rect(1792, 944, 1920, 1104), 128, 288, "FLOOR7_1", "CEIL5_1", 112, "BROWN1")
    kit.thing(1856, 1024, ARMOR_BONUS)
    doorway(kit, 1920, 960, 1952, 1088, 128, True, picture="BIGDOOR4", lintel="BROWN1", lintel_far="TANROCK5", height=128)

    # 5. The canyon, out under the sky, down to the plant: cross sections along the way, each a
    # middle, how far either side the walls are and its floor
    way = [(1952, 1024, 64), (2112, 1024, 160), (2336, 992, 224), (2576, 1088, 240), (2768, 1264, 224), (2864, 1504, 208),
           (2864, 1776, 224), (2768, 2048, 240), (2672, 2288, 192), (2656, 2480, 128)]
    lefts, rights = [], []
    for index, (x, y, half) in enumerate(way):
        if index == 0:
            dx, dy = 1, 0
        elif index == len(way) - 1:
            dx, dy = 0, 1
        else:
            dx, dy = way[index + 1][0] - way[index - 1][0], way[index + 1][1] - way[index - 1][1]
        length = math.hypot(dx, dy)
        nx, ny = -dy / length, dx / length
        lefts.append((round((x + nx * half) / 8) * 8, round((y + ny * half) / 8) * 8))
        rights.append((round((x - nx * half) / 8) * 8, round((y - ny * half) / 8) * 8))
    lefts[0], rights[0] = (1952, 1088), (1952, 960)
    lefts[-1], rights[-1] = (2528, 2480), (2784, 2480)
    ledges = {3: "right", 6: "left"}
    canyon = []
    for index in range(len(way) - 1):
        floor = 128 - 16 * index
        right = [rights[index]]
        left = [lefts[index + 1]]

        def rocky(start, end, outward, into):
            # Rock jutting out of the side, two corners along it
            for part in (0.35, 0.7):
                out = rng.randint(16, 56)
                x = start[0] + (end[0] - start[0]) * part + outward[0] * out
                y = start[1] + (end[1] - start[1]) * part + outward[1] * out
                into.append((round(x / 8) * 8, round(y / 8) * 8))

        def outward(start, end, side):
            dx, dy = end[0] - start[0], end[1] - start[1]
            length = math.hypot(dx, dy)
            # The right of the way is clockwise of going along it
            return (dy / length, -dx / length) if side == "right" else (-dy / length, dx / length)

        if ledges.get(index) != "right":
            rocky(rights[index], rights[index + 1], outward(rights[index], rights[index + 1], "right"), right)
        right.append(rights[index + 1])
        if ledges.get(index) != "left":
            rocky(lefts[index + 1], lefts[index], outward(lefts[index], lefts[index + 1], "left"), left)
        left.append(lefts[index])
        cell = kit.sector(right + left, floor, floor + 224, "FLAT5_7", SKY, 200, "TANROCK5", lower="TANROCK5")
        canyon.append(cell)
        middle = ((lefts[index][0] + rights[index][0] + lefts[index + 1][0] + rights[index + 1][0]) / 4,
                  (lefts[index][1] + rights[index][1] + lefts[index + 1][1] + rights[index + 1][1]) / 4)
        kit.thing(middle[0], middle[1], BONUS)
        side = ledges.get(index)
        if side:
            a, b = (rights[index], rights[index + 1]) if side == "right" else (lefts[index], lefts[index + 1])
            ox, oy = outward(a, b, side)
            far_a = (round((a[0] + ox * 112) / 8) * 8, round((a[1] + oy * 112) / 8) * 8)
            far_b = (round((b[0] + ox * 112) / 8) * 8, round((b[1] + oy * 112) / 8) * 8)
            kit.sector([a, b, far_b, far_a], floor + 72, floor + 224, "FLAT5_7", SKY, 200, "TANROCK5", lower="TANROCK5")
            ledge_x, ledge_y = (a[0] + b[0] + far_a[0] + far_b[0]) / 4, (a[1] + b[1] + far_a[1] + far_b[1]) / 4
            kit.thing(ledge_x, ledge_y, IMP, math.degrees(math.atan2(-oy, -ox)), ALL if index == 3 else UP)
            kit.thing(ledge_x + ox * 24 - oy * 40, ledge_y + oy * 24 + ox * 40, STALAGMITE)
    # What else is in the canyon, by cross section and how far across it (-1 right to 1 left)
    def across(index, part, side):
        x = way[index][0] + (way[index + 1][0] - way[index][0]) * part
        y = way[index][1] + (way[index + 1][1] - way[index][1]) * part
        l = (lefts[index][0] + (lefts[index + 1][0] - lefts[index][0]) * part, lefts[index][1] + (lefts[index + 1][1] - lefts[index][1]) * part)
        r = (rights[index][0] + (rights[index + 1][0] - rights[index][0]) * part, rights[index][1] + (rights[index + 1][1] - rights[index][1]) * part)
        middle = ((l[0] + r[0]) / 2, (l[1] + r[1]) / 2)
        reach = l if side > 0 else r
        return middle[0] + (reach[0] - middle[0]) * abs(side), middle[1] + (reach[1] - middle[1]) * abs(side)

    for index, part, side, kind in ((1, 0.5, 0.75, BURNT_TREE), (2, 0.3, -0.8, STALAGMITE), (2, 0.8, 0.8, BURNT_TREE), (4, 0.5, -0.75, BURNT_TREE),
                                    (5, 0.3, 0.8, STALAGMITE), (7, 0.6, 0.75, BURNT_TREE), (8, 0.4, -0.7, STALAGMITE)):
        kit.thing(*across(index, part, side), kind)
    for index, part, side, kind, angle, skills in ((4, 0.5, 0.3, ZOMBIE, 225, ALL), (4, 0.7, -0.3, ZOMBIE, 225, UP), (5, 0.6, 0.4, BARREL, 0, ALL),
                                                   (5, 0.7, 0.55, BARREL, 0, ALL), (5, 0.8, 0.2, ZOMBIE, 270, ALL), (7, 0.5, 0, DEMON, 270, UP),
                                                   (8, 0.6, 0.4, SERGEANT, 270, HARD), (2, 0.6, 0, SHELLS, 0, ALL), (6, 0.5, -0.4, STIMPACK, 0, ALL),
                                                   (7, 0.3, -0.5, IMP, 300, HARD)):
        kit.thing(*across(index, part, side), kind, angle, skills)

    # 6. The nukage plant: in under an awning, a bridge over the nukage to a landing and a lift
    plant = dict(floor_flat="FLOOR5_1", ceiling_flat="CEIL5_1", wall="BROWN96")
    kit.sector(rect(2528, 2480, 2784, 2544), 0, 160, "FLOOR7_1", "CEIL5_1", 176, "SUPPORT2", upper="METAL")
    pool = dict(floor=-16, ceiling=288, floor_flat="NUKAGE1", ceiling_flat="CEIL5_1", light=176, wall="BROWN96", lower="SUPPORT2",
                upper="SUPPORT2", special=NUKAGE_HURTS)
    # Columns hold the roof up out of the nukage
    west_columns = [rect(2496, 2752, 2544, 2800), rect(2496, 3056, 2544, 3104), rect(2688, 3056, 2736, 3104)]
    east_columns = [rect(3088, 2672, 3136, 2720), rect(3088, 3008, 3136, 3056), rect(2832, 2704, 2880, 2752)]
    kit.sector([(2464, 2544), (2528, 2544), (2528, 2672), (2608, 2672), (2608, 2960), (2864, 2960), (2864, 3136), (2752, 3136), (2752, 3264),
                (2464, 3264)], holes=west_columns, **pool)
    kit.sector([(2784, 2544), (3200, 2544), (3200, 3264), (3072, 3264), (3072, 3136), (2960, 3136), (2960, 2864), (2704, 2864), (2704, 2672),
                (2784, 2672)], holes=east_columns, **pool)
    for column in west_columns + east_columns:
        for start, end in zip(column, column[1:] + column[:1]):
            kit.wall(start, end, middle="SUPPORT3")
    walkway = dict(floor_flat="FLOOR5_1", ceiling_flat="CEIL5_1", wall="BROWN96", lower="SUPPORT3", upper="SUPPORT2")
    kit.sector(rect(2528, 2544, 2784, 2672), 0, 288, light=144, **walkway)
    kit.sector(rect(2608, 2672, 2704, 2960), 0, 288, light=128, **walkway)
    kit.sector(rect(2704, 2864, 2960, 2960), 0, 288, light=128, **walkway)
    kit.sector(rect(2864, 2960, 2960, 3136), 0, 288, light=128, **walkway)
    kit.sector(rect(2752, 3136, 3072, 3200), 0, 288, light=144, **walkway)
    kit.sector(rect(2752, 3200, 3072, 3264), 0, 288, "STEP1", "CEIL5_1", 192, "BROWN96", lower="SUPPORT3", upper="SUPPORT2")
    kit.wall((2752, 3200), (3072, 3200), special=LIFT_AGAIN, tag=7)
    lift = kit.sector(rect(2848, 3264, 2976, 3392), 128, 288, "STEP1", "CEIL5_1", 160, "SUPPORT2", lower="SUPPORT3", tag=7, moves=True)
    kit.thing(2656, 2600, SHELLS)
    kit.thing(2656, 2800, BONUS)
    kit.thing(2800, 2912, ZOMBIE, 180)
    kit.thing(2912, 3040, BONUS)
    kit.thing(2912, 3220, IMP, 270)
    kit.thing(3024, 3220, SERGEANT, 225, UP)
    kit.thing(2800, 3168, MEDIKIT)
    for x in (2824, 3000):
        kit.thing(x, 3240, LAMP)
    kit.thing(3104, 2720, IMP, 135, UP)
    kit.thing(2480, 3000, IMP, 0, HARD)
    for x, y in ((2544, 2560), (2768, 2560)):
        kit.thing(x, y, BARREL)

    # 7. Up the lift, and west along a corridor with windows over the plant
    upper_hall = kit.sector(rect(2464, 3392, 2976, 3520), 128, 256, "FLAT5_4", "CEIL3_5", 160, "STARG3", upper="STARG3")
    kit.sector(rect(2464, 3264, 2784, 3392), 160, 224, "FLAT5_4", "CEIL3_5", 160, "STARG3", lower="BROWN96", upper="BROWN96")
    kit.wall((2464, 3392), (2784, 3392), facing=upper_hall, lower="STARG3", upper="STARG3")
    kit.thing(2624, 3456, CLIP_BOX)
    doorway(kit, 2432, 3392, 2464, 3520, 128, True, picture="BIGDOOR2", lintel="BROWN1", lintel_far="STARG3")

    # 8. The warehouse: a grid of crates, each this high over the floor ("." for the lane), the
    # bottom row first, west to east
    crates = ["3 2 3 2 3 2",
              "2 . . . . .",
              "3 . 2 3 2 3",
              "2 . . . . 2",
              "3 2 3 2 . 3",
              "2 . . . . 2",
              "3 . 2 3 2 3"]
    heights = {"2": 96, "3": 160}
    skylights = {(2, 3), (3, 5)}
    for row, line in enumerate(crates):
        for column, cell in enumerate(line.split()):
            x, y = 1664 + 128 * column, 3264 + 128 * row
            if cell == ".":
                sky = (column, row) in skylights
                kit.sector(rect(x, y, x + 128, y + 128), 128, 448 if sky else 384, "FLAT5_4", SKY if sky else "CEIL5_1", 176 if sky else 128,
                           "BRONZE1", upper="SUPPORT2")
            else:
                kit.sector(rect(x, y, x + 128, y + 128), 128 + heights[cell], 384, "CRATOP1" if cell == "2" else "CRATOP2", "CEIL5_1",
                           128, "BRONZE1", lower="CRATE1" if cell == "2" else "CRATE2", upper="SUPPORT2")

    def lane(column, row):
        return 1664 + 128 * column + 64, 3264 + 128 * row + 64

    kit.thing(*lane(1, 1), CHAINGUN)
    kit.thing(*lane(3, 1), BONUS)
    kit.thing(*lane(1, 2), CLIP)
    kit.thing(*lane(2, 3), DEMON, 0, ALL)
    kit.thing(*lane(4, 3), DEMON, 180, UP)
    kit.thing(*lane(3, 4), IMP, 270, ALL)
    kit.thing(lane(0, 2)[0], lane(0, 2)[1], IMP, 0, UP)
    kit.thing(*lane(4, 4), CLIP_BOX)
    kit.thing(*lane(2, 5), SPECTRE, 0, HARD)
    kit.thing(*lane(3, 5), DEMON, 0, UP)
    kit.thing(*lane(1, 5), STIMPACK)
    kit.thing(lane(4, 1)[0] + 40, lane(4, 1)[1] + 40, BARREL)
    kit.thing(lane(1, 3)[0] - 40, lane(1, 3)[1] + 40, BARREL)
    doorway(kit, 1792, 4160, 1920, 4192, 128, False, picture="BIGDOOR2", lintel="BRONZE1", lintel_far="STONE2")

    # 9. The dark corridor, and the walls that open behind whoever walks it
    dark = dict(floor_flat="FLAT1", ceiling_flat="CEIL5_1", wall="STONE2", upper="STONE2")
    kit.sector(rect(1792, 4192, 1920, 4320), 128, 256, light=144, **dark)
    pools = [rect(1824, y, 1888, y + 48) for y in (4376, 4600, 4824)]
    kit.sector(rect(1792, 4320, 1920, 4896), 128, 256, light=112, holes=pools, **dark)
    for x1, y1, x2, y2 in ((a[0][0], a[0][1], a[2][0], a[2][1]) for a in pools):
        kit.sector(rect(x1, y1, x2, y2), 128, 264, "FLAT1", "TLITE6_6", 184, "STONE2", upper="METAL")
    kit.wall((1792, 4320), (1920, 4320), special=OPEN_FAST_ONCE, tag=9)
    for y, west, east in ((4448, (IMP, ALL), (ZOMBIE, UP)), (4672, (DEMON, UP), (IMP, ALL))):
        for side, (kind, skills) in (("west", west), ("east", east)):
            if side == "west":
                mouth, room = rect(1776, y, 1792, y + 96), rect(1712, y, 1776, y + 96)
                facing = 0
            else:
                mouth, room = rect(1920, y, 1936, y + 96), rect(1936, y, 2000, y + 96)
                facing = 180
            kit.sector(mouth, 128, 128, "FLAT1", "CEIL5_1", 96, "STONE2", upper="STONE2", lower="STONE2", tag=9, door=True)
            kit.sector(room, 128, 256, "FLAT1", "CEIL5_1", 160, "SKINEDGE", upper="SKINEDGE")
            kit.thing((room[0][0] + room[1][0]) / 2, y + 48, kind, facing, skills)
    kit.thing(1856, 4800, ARMOR)
    kit.thing(1856, 4500, BONUS)
    kit.thing(1856, 4620, BONUS)
    kit.thing(1856, 4740, SHELLS)
    kit.thing(1808, 4210, SHORT_RED_TORCH)
    kit.thing(1904, 4210, SHORT_RED_TORCH)
    kit.thing(1856, 4880, ZOMBIE, 270, HARD)
    doorway(kit, 1792, 4896, 1920, 4928, 128, False, picture="BIGDOOR1", lintel="STONE2", lintel_far="MARBLE1", light=128)

    # 10. The gate: lava either side of a causeway, an island halfway, and the exit
    lava = dict(floor=112, ceiling=400, floor_flat="LAVA1", ceiling_flat=SKY, light=208, wall="MARBLE1", lower="MARBLE1", special=LAVA_HURTS)
    kit.sector([(1600, 4928), (1792, 4928), (1792, 5216), (1664, 5344), (1664, 5472), (1792, 5600), (1792, 5920), (1600, 5920), (1344, 5664),
                (1344, 5184)], **lava)
    kit.sector([(1920, 4928), (2112, 4928), (2368, 5184), (2368, 5664), (2112, 5920), (1920, 5920), (1920, 5600), (2048, 5472), (2048, 5344),
                (1920, 5216)], **lava)
    stone = dict(floor_flat="FLOOR7_2", ceiling_flat=SKY, wall="MARBLE1", lower="GSTONE1")
    kit.sector(rect(1792, 4928, 1920, 5216), 128, 400, light=176, **stone)
    kit.sector([(1792, 5216), (1920, 5216), (2048, 5344), (2048, 5472), (1920, 5600), (1792, 5600), (1664, 5472), (1664, 5344)], 136, 400,
               "FLOOR6_1", SKY, 192, "MARBLE1", lower="GSTONE1")
    kit.sector(rect(1792, 5600, 1920, 5920), 128, 400, light=176, **stone)
    # The exit: a gate in the north wall, EXIT over it, and the way out through it
    kit.sector(rect(1792, 5920, 1920, 5936), 128, 256, "FLOOR7_2", "FLAT20", 208, "MARBLE1", upper="MARBLE1")
    kit.sector(rect(1792, 5936, 1920, 5952), 128, 240, "FLOOR7_2", "FLAT20", 208, "EXITSTON", upper="EXITSIGN")
    kit.sector(rect(1760, 5952, 1952, 6112), 128, 240, "GATE1", "FLAT20", 255, "EXITSTON", upper="EXITSTON")
    kit.wall((1792, 5952), (1920, 5952), special=EXIT)
    kit.thing(1856, 5408, SOULSPHERE)
    for x, y in ((1680, 5344), (2032, 5344), (1680, 5472), (2032, 5472)):
        kit.thing(x, y, RED_TORCH)
    for x, y in ((1776, 5900), (1936, 5900)):
        kit.thing(x, y, BURNING_BARREL)
    for x, y, kind, angle, skills in ((1856, 5300, DEMON, 270, ALL), (1856, 5700, DEMON, 270, UP), (1500, 5300, IMP, 0, ALL), (2200, 5300, IMP, 180, ALL),
                                      (1500, 5700, IMP, 315, UP), (2200, 5700, IMP, 225, UP), (1856, 5520, BARON, 270, HARD),
                                      (1600, 5100, LOST_SOUL, 45, HARD), (2112, 5100, LOST_SOUL, 135, HARD), (1856, 5820, SERGEANT, 270, UP)):
        kit.thing(x, y, kind, angle, skills)
    kit.thing(1856, 5000, BONUS)
    kit.thing(1856, 5120, BONUS)
    return kit


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("out", type=Path)
    parser.add_argument("--picture", type=Path, default=None, help="A picture of the map from above, to look at")
    args = parser.parse_args()
    made = build().write(args.out, NAME, args.picture)
    print(f"{args.out}: " + ", ".join(f"{count} {what}" for what, count in made.items()))


if __name__ == "__main__":
    main()
