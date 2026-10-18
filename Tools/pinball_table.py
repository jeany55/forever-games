"""The bench's pinball table: where everything on it is, in one place, for Tools/make_pinball.py to
write out as what the physics meets (Engine/Physics.lua) and to draw.

Measured in millimetres, x across to the right and y down the table towards the player, as the
physics has them. The table is 512 wide and 1024 long, about the size of a real one. The
playfield proper is from x = 12 to 464; the shooter lane, where the ball is plunged, is beside it
on the right, from 464 to 500. Its middle, where the flippers are, is x = 238.

Every shape is a dict with a "kind":
  line     walls through "points" (x, y, x, y...), each to the next
  circle   a round post or sensor at x, y, radius r
  box      a sensor over a rectangle, left, top, right, bottom
  paddle   a flipper turning at x, y
and what the physics is told of it (layers, sensor, bounce, friction, kick, trigger, oneWay, push,
pull, hole, front, back, active), a "material" whose bounce and friction it takes unless it says
its own (MATERIALS, which the bench can change while it runs), a "name" the bench knows it by, and
a "role" saying what it is to the table, for the bench and the pictures: rail, rubber, post,
bumper, sling, target, standup, gate, spinner, rollover, orbit, saucer, ramp, kickback, drain,
plunger, flipper.

Beside the shapes are rails(), the wires through the air that a ball rides (Physics:Rail),
each a way through x, y and z: the ramp's wire, which crosses the top of the table and winds down
a corkscrew to the left inlane, and the Moonwell's, up a glass tube from the saucer, over the ramp
and down the right side. Then what only the pictures need: lamps(), the lights set into the
playfield; flashers(), the domes that flash; and RAMPS, how high the ramp's plastic is along its
way, which the bench also uses to draw a ball on it as high as it is.

Layer 1 is the playfield and layer 2 the ramp over it. A shape on both says layers 3.
"""
import math

WIDTH, HEIGHT = 512, 1024
BALL = 13.5
MIDDLE = 238
LEFT_WALL, LANE, RIGHT_WALL = 12, 464, 500

MATERIALS = {
    # Steel guides and the cabinet's walls
    "metal": {"bounce": 0.35, "friction": 0.06},
    # Rubber rings round posts and slingshots
    "rubber": {"bounce": 0.75, "friction": 0.18},
    # The flippers' rubber, which grips the ball to aim it
    "flipper": {"bounce": 0.55, "friction": 0.3},
    # Plastic: the ramp, drop targets
    "plastic": {"bounce": 0.45, "friction": 0.08},
}


def arc(cx, cy, r, start, end, steps):
    """Points round a circle from one angle to another in degrees, clockwise as y is down"""
    points = []
    for index in range(steps + 1):
        a = math.radians(start + (end - start) * index / steps)
        points += [round(cx + r * math.cos(a), 3), round(cy + r * math.sin(a), 3)]
    return points


def mirror(points):
    """The same points on the other side of the middle"""
    out = []
    for index in range(0, len(points), 2):
        out += [2 * MIDDLE - points[index], points[index + 1]]
    return out


def line(points, material="metal", **fields):
    return {"kind": "line", "points": points, "material": material, **fields}


def circle(x, y, r, material="rubber", **fields):
    return {"kind": "circle", "x": x, "y": y, "r": r, "material": material, **fields}


def sensor_circle(x, y, r, **fields):
    return {"kind": "circle", "x": x, "y": y, "r": r, "sensor": True, **fields}


def box(left, top, right, bottom, **fields):
    return {"kind": "box", "left": left, "top": top, "right": right, "bottom": bottom, "sensor": True, **fields}


# The pull down towards the table, mm/s each second, that a ball climbing the ramp or a rail goes
# against: the table's slope pulls down it with `gravity` (Build.lua), and the rest of gravity
# into it, about nine times that on a real table
LIFT = 9000
# How high the top of the ramp's plastic is, where the ball goes onto its wire
RAMP_TOP = 93
RAMP_MOUTH, RAMP_END = 600, 292


def catmull(control, step=5.0):
    """A smooth way through x, y, z control points, a point every `step` mm or so"""
    pts = [tuple(control[i:i + 3]) for i in range(0, len(control), 3)]
    out = [pts[0]]
    for i in range(len(pts) - 1):
        p0, p1, p2 = pts[max(0, i - 1)], pts[i], pts[i + 1]
        p3 = pts[min(len(pts) - 1, i + 2)]
        length = math.dist(p1, p2)
        count = max(1, int(length / step))
        for k in range(1, count + 1):
            t = k / count
            t2, t3 = t * t, t * t * t
            out.append(tuple(0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                             for a, b, c, d in zip(p0, p1, p2, p3)))
    return out


def helix(cx, cy, r, start, turns, z0, z1, step=5.0):
    """Round a post, from angle `start` (degrees) the way of the sun as seen from below the table, so
    against it as y is down, falling from z0 to z1"""
    length = abs(turns) * 2 * math.pi * r
    count = max(2, int(length / step))
    out = []
    for k in range(count + 1):
        t = k / count
        a = math.radians(start - 360 * turns * t)
        out.append((cx + r * math.cos(a), cy + r * math.sin(a), z0 + (z1 - z0) * t))
    return out


# The table's own pull down it, mm/s each second, as Build.lua has it, for crest()
GRAVITY = 1500


def crest(points):
    """How far along a way the hardest point to get past is: the highest, counting going up the table
    as climbing too. A ball past it goes on to the end"""
    best, at, along = -1e9, 0.0, 0.0
    for index, (x, y, z) in enumerate(points):
        if index:
            along += math.dist(points[index - 1], (x, y, z))
        height = LIFT * z - GRAVITY * y
        if height > best:
            best, at = height, along
    return round(at + 2, 2)


def flat(points):
    return [round(c, 3) for point in points for c in point]


# The corkscrew in the top left corner: once round a post
CORKSCREW = {"x": 100, "y": 245, "r": 42, "top": RAMP_TOP - 11, "bottom": 42}


def rails():
    """The wires through the air, each the way the ball's underside goes, and where a ball that
    gets off is put"""
    c = CORKSCREW
    # The ramp's: from the top of the plastic, round to the left in an arch over the bumpers, once
    # down round the corkscrew, and down the left side over the orbit to the inlane
    across = catmull([359, RAMP_END, RAMP_TOP, 356, 268, RAMP_TOP - 1, 342, 248, RAMP_TOP - 2, 316, 236, RAMP_TOP - 3,
                      280, 229, RAMP_TOP - 4.5, 240, 226, RAMP_TOP - 6, 200, 224, RAMP_TOP - 7.5, 160, 217, RAMP_TOP - 9,
                      128, 207, RAMP_TOP - 10, c["x"], c["y"] - c["r"], c["top"]])
    screw = helix(c["x"], c["y"], c["r"], -90, 1, c["top"], c["bottom"])
    down = catmull([c["x"], c["y"] - c["r"], c["bottom"], 75, 210, 42, 52, 238, 41, 40, 290, 41, 34, 350, 40, 34, 420, 40,
                    34, 500, 39, 35, 580, 38, 40, 640, 36, 50, 680, 33, 63, 718, 16, 71, 750, 0])
    ramp_wire = across + screw[1:] + down[1:]
    # The Moonwell's: straight up a glass tube from the saucer, over the ramp, round and down the
    # right side over the orbit to the right inlane
    x, y = MIDDLE, 450
    tube = [(x, y, z) for z in range(0, 129, 8)]
    over = catmull([x, y, 128, 240, 446, 133, 250, 432, 136, 272, 410, 136, 310, 378, 134.5, 359, 345, 133,
                    402, 322, 131, 432, 330, 128, 446, 365, 124, 450, 420, 118, 450, 500, 106, 448, 570, 92,
                    443, 630, 76, 432, 680, 54, 418, 715, 28, 408, 738, 8, 405, 752, 0])
    well_wire = tube + over[1:]
    return [
        {"name": "rampWire", "points": flat(ramp_wire), "layer": 1, "back": 2, "drag": 0.3, "role": "rail",
         "marks": [crest(ramp_wire)]},
        {"name": "wellWire", "points": flat(well_wire), "layer": 1, "back": 1, "drag": 0.3, "role": "rail", "tube": 128},
    ]


def supports():
    """What holds the wires up: a chrome post stood at x, y on what is there, `base` mm high, with
    an arm out to the wire nearest it. Each stands where no ball goes: on a wall's top, a post of
    the table, or in the corner of the cabinet"""
    return [
        # The ramp's wire: the top lanes' end posts, the orbit's wall, and down the left side
        {"x": 196, "y": 115, "base": 26}, {"x": 316, "y": 115, "base": 26},
        {"x": 56, "y": 330, "base": 32}, {"x": 56, "y": 470, "base": 32}, {"x": 34, "y": 645, "base": 26},
        # The Moonwell's: the ramp's outer wall, and the right orbit's wall
        {"x": 335, "y": 380, "base": 0, "onRamp": True}, {"x": 420, "y": 330, "base": 32}, {"x": 420, "y": 470, "base": 32},
        {"x": 442, "y": 645, "base": 26},
    ]


def shapes():
    made = []
    add = made.append

    # The cabinet: up the left side, round the top, down the right side
    top = arc(256, 256, 244, 180, 360, 48)
    add(line([LEFT_WALL, HEIGHT] + top + [RIGHT_WALL, HEIGHT], role="rail", layers=3, name="cabinet"))

    # The shooter lane, its floor the plunger, and the gate at its top that lets the ball out but
    # not back in. The gate's front is up: a ball coming down onto it is kept out of the lane
    add(line([LANE, HEIGHT, LANE, 340], role="rail", name="lane"))
    add(circle(LANE, 340, 3, material="metal", role="post"))
    add(line([LANE, 1000, RIGHT_WALL, 1000], role="plunger", name="plunger"))
    add(box(LANE, 940, RIGHT_WALL, 1000, name="shooter", role="plunger"))
    # Sloping down to the playfield, so that a ball coming down onto it rolls off rather than resting
    add(line([LANE, 336, RIGHT_WALL, 306], oneWay=True, role="gate", name="gate"))

    # The left orbit: a lane up the left side that the arch carries round to the top. A spinner
    # across it, a line the ball turns as it goes through
    orbit = [56, 560, 56, 256] + arc(256, 256, 200, 180, 215, 6)[2:]
    add(line(orbit, role="rail", name="orbit"))
    add(circle(56, 560, 4, material="rubber", role="post"))
    add(line([LEFT_WALL, 420, 56, 420], sensor=True, role="spinner", name="spinner"))

    # The right orbit, the same up the right side: a ball shot up one comes down the other. Its lane
    # opens at the top into the shooter lane's, beside the gate
    orbit = [420, 560, 420, 256] + arc(256, 256, 164, 360, 325, 6)[2:]
    add(line(orbit, role="rail", name="rightOrbitWall"))
    add(circle(420, 560, 4, material="rubber", role="post"))
    add(line([420, 420, LANE, 420], sensor=True, role="orbit", name="rightOrbit"))

    # Two standup targets closing the lane between the ramp's mouth and the right orbit, facing down
    # it. They are hit and stay up
    add(line([384, 470, 400, 470], material="rubber", role="standup", name="standup1"))
    add(line([403, 470, 419, 470], material="rubber", role="standup", name="standup2"))
    add(circle(401.5, 470, 2, material="metal", role="post"))
    # Behind them, a cap sloping down to the left, so a ball coming down onto them rolls off
    add(line([383, 470, 420, 442], role="rail"))

    # Three lanes at the top, a rollover in each
    for x in (196, 236, 276, 316):
        add(line([x, 70, x, 115], role="rail"))
        add(circle(x, 70, 4, role="post"))
        add(circle(x, 115, 4, role="post"))
    for index, x in enumerate((216, 256, 296)):
        add(sensor_circle(x, 95, 8, role="rollover", name=f"lane{index + 1}"))

    # Three pop bumpers
    for index, (x, y) in enumerate(((200, 210), (312, 210), (256, 285))):
        add(circle(x, y, 24, material="rubber", kick=1400, trigger=150, role="bumper", name=f"bumper{index + 1}"))

    # Three drop targets on the left, against the orbit's wall
    for index, y in enumerate((462, 492, 522)):
        add(line([66, y, 66, y + 25], material="plastic", role="target", name=f"target{index + 1}"))
    add(line([56, 457, 66, 459], role="rail"))
    add(line([56, 552, 66, 550], role="rail"))

    # The saucer, the trainer: a hole that holds a slow ball and pulls a little round it
    add(sensor_circle(MIDDLE, 450, 18, hole=650, pull=1200, role="saucer", name="saucer"))

    # The ramp, on the right: straight up from its mouth to its top, where the ball goes onto the
    # wire (rails()). Crossing the mouth going up puts the ball on the ramp, coming back down puts it
    # back on the playfield. Its lane is 48 wide, with room either side of the ball for a shot that
    # comes in at an angle
    top = RAMP_END - 22
    add(line([335, RAMP_MOUTH, 335, top, 383, top, 383, RAMP_MOUTH], material="plastic", layers=2, role="ramp", name="ramp"))
    # Under the ramp near its mouth, where it is too low to roll under: peaked, so nothing rests on it
    add(line([335, 600, 335, 540, 359, 520, 383, 540, 383, 600], material="plastic", layers=1, role="ramp"))
    add(circle(335, 600, 4, material="metal", layers=3, role="post"))
    add(circle(383, 600, 4, material="metal", layers=3, role="post"))
    add(line([335, 600, 383, 600], sensor=True, layers=3, front=2, back=1, role="ramp", name="rampIn"))
    # Across the top of its plastic: up through it, onto the wire
    add(line([335, RAMP_END, 383, RAMP_END], sensor=True, layers=2, front=2, back=2, rail="rampWire", role="ramp",
             name="rampTop"))
    # Uphill: the slope of its plastic pulls the ball back down it, as much more than the table's as
    # the plastic is steep
    add(box(335, RAMP_END, 383, RAMP_MOUTH, layers=2, slope=round(RAMP_TOP / (RAMP_MOUTH - RAMP_END), 4), role="ramp",
            name="rampHill"))

    # The post the corkscrew winds round, which a ball meets on the playfield under it
    add(circle(CORKSCREW["x"], CORKSCREW["y"], 6, material="metal", role="post", name="corkscrewPost"))

    # The bottom of the table, the same on both sides but for the kickback, which is the left's
    for side in ("left", "right"):
        flip = (lambda points: points) if side == "left" else mirror
        sep_x = 52
        # The wall between the outlane and the inlane, down to the drain, and the inlane's floor
        # down to the flipper
        add(line(flip([sep_x, 690, sep_x, HEIGHT]), role="rail"))
        add(circle(*flip([sep_x, 690]), 5, role="post"))
        # It ends where it meets the top of the flipper's round end going the same way, so the ball
        # rolls on down the flipper rather than settling between the two
        add(line(flip([sep_x, 851, 146.9, 894]), role="rail"))
        # The slingshot: a triangle, its long side facing the middle kicking the ball away
        a, b, c = [90, 720], [90, 822], [120, 840]
        add(line(flip(a + b + c), material="rubber", role="sling"))
        add(line(flip(a + c), material="rubber", kick=1300, trigger=250, role="sling", name=f"{side}Sling"))
        for point in (a, b, c):
            add(circle(*flip(point), 6, role="post"))
        # A guide off the wall above the outlane that throws a ball coming down the side out
        # towards the inlane, though it may still fall into the outlane
        add(line(flip([LEFT_WALL, 610, 34, 645]), role="rail"))
        add(circle(*flip([34, 645]), 4, role="post"))
        add(paddle(side))
        # Rollovers across the outlane and the inlane
        add(line(flip([LEFT_WALL, 760, sep_x, 760]), sensor=True, role="rollover", name=f"{side}Outlane"))
        add(line(flip([sep_x, 760, 90, 760]), sensor=True, role="rollover", name=f"{side}Inlane"))
    add(sensor_circle(32, 940, 12, role="kickback", name="kickback"))

    # A small flipper on the left, under the drop targets, shooting up at the bumpers and the saucer
    add({"kind": "paddle", "x": 74, "y": 600, "length": 56, "base": 9, "tip": 5,
         "rest": round(math.radians(25), 6), "up": round(math.radians(-30), 6),
         "material": "flipper", "role": "flipper", "name": "upperFlipper", "side": "left"})

    # The post that rises between the flippers, down unless the bench raises it
    add(circle(MIDDLE, 975, 6, material="metal", active=False, role="post", name="centerPost"))
    add(box(LEFT_WALL, 1005, LANE, HEIGHT, role="drain", name="drain"))
    return made


def paddle(side):
    rest, up = 30, -25
    x = 142
    if side == "right":
        x, rest, up = 2 * MIDDLE - x, 180 - rest, 180 - up
    return {"kind": "paddle", "x": x, "y": 905, "length": 76, "base": 12, "tip": 6.5,
            "rest": round(math.radians(rest), 6), "up": round(math.radians(up), 6),
            "material": "flipper", "role": "flipper", "name": side + "Flipper", "side": side}


def lamps():
    """The lights set into the playfield: where, how big, what colour, and what they are. A
    "label" is an oblong insert with words on it, w by h"""
    made = []
    for index, x in enumerate((216, 256, 296)):
        made.append({"name": f"lane{index + 1}", "x": x, "y": 140, "r": 8, "color": "gold", "shape": "round"})
    for index, y in enumerate((474, 504, 534)):
        made.append({"name": f"target{index + 1}", "x": 92, "y": y, "r": 7, "color": "red", "shape": "round"})
    made.append({"name": "saucer", "x": MIDDLE, "y": 505, "r": 14, "color": "blue", "shape": "arrow", "angle": -90})
    made.append({"name": "ramp", "x": 359, "y": 640, "r": 14, "color": "green", "shape": "arrow", "angle": -90})
    made.append({"name": "spinner", "x": 34, "y": 470, "r": 11, "color": "purple", "shape": "arrow", "angle": -90})
    made.append({"name": "kickback", "x": 32, "y": 890, "r": 9, "color": "orange", "shape": "round"})
    made.append({"name": "shootAgain", "x": MIDDLE, "y": 900, "r": 13, "color": "red", "shape": "round"})
    for index in range(5):
        made.append({"name": f"level{index + 1}", "x": MIDDLE - 60 + index * 30, "y": 760, "r": 8,
                     "color": "gold", "shape": "round"})
    made.append({"name": "rightOrbit", "x": 442, "y": 588, "r": 11, "color": "purple", "shape": "arrow", "angle": -90})
    for index, x in enumerate((392, 411)):
        made.append({"name": f"standup{index + 1}", "x": x, "y": 495, "r": 6, "color": "orange", "shape": "round"})
    for side, x, colour in (("leftOutlane", 32, "red"), ("leftInlane", 71, "gold"),
                            ("rightInlane", 2 * MIDDLE - 71, "gold"), ("rightOutlane", 2 * MIDDLE - 32, "red")):
        made.append({"name": side, "x": x, "y": 795, "r": 7, "color": colour, "shape": "round"})
    # Round the saucer, a light for each quest of the eight
    for index in range(8):
        a = math.radians(-90 + index * 45)
        made.append({"name": f"quest{index + 1}", "x": round(MIDDLE + 75 * math.cos(a), 2),
                     "y": round(450 + 75 * math.sin(a), 2), "r": 6, "color": "blue", "shape": "round"})
    for index in range(4):
        made.append({"name": f"bonus{index + 2}x", "x": MIDDLE - 45 + index * 30, "y": 822, "r": 9, "w": 24, "h": 14,
                     "color": "orange", "shape": "label", "text": f"{index + 2}X"})
    made.append({"name": "extraBall", "x": 359, "y": 690, "r": 12, "w": 40, "h": 16, "color": "red", "shape": "label",
                 "text": "EXTRA BALL"})
    made.append({"name": "jackpot", "x": 350, "y": 735, "r": 12, "w": 40, "h": 16, "color": "green", "shape": "label",
                 "text": "JACKPOT"})
    made.append({"name": "superJackpot", "x": MIDDLE, "y": 560, "r": 12, "w": 56, "h": 16, "color": "gold",
                 "shape": "label", "text": "SUPER JACKPOT"})
    made.append({"name": "raid", "x": MIDDLE, "y": 610, "r": 12, "w": 44, "h": 18, "color": "purple", "shape": "label",
                 "text": "RAID"})
    return made


def flashers():
    """The domes that flash: in the cabinet's top corners, beyond the playfield, and at the top of
    the ramp; and the Moonwell's glass tube, which lights up all along. How high each stands, mm"""
    return [
        {"name": "flashLeft", "x": 40, "y": 50, "z": 30, "color": "purple"},
        {"name": "flashRight", "x": 472, "y": 50, "z": 30, "color": "gold"},
        {"name": "flashRamp", "x": 400, "y": 300, "z": 112, "color": "green"},
        {"name": "flashWell", "x": MIDDLE, "y": 450, "z": 30, "top": 128, "color": "blue", "kind": "tube"},
    ]


# How high the ramp's plastic floor is along its middle, x, y and height in mm, from its mouth to
# its top, where the wire takes the ball
RAMPS = [
    {"name": "ramp", "width": 48, "layer": 2,
     "path": [359, RAMP_MOUTH, 0, 359, RAMP_END, RAMP_TOP]},
]


TABLE = {"id": "bench", "width": WIDTH, "height": HEIGHT, "ball": BALL, "middle": MIDDLE,
         "start": [482, 1000 - BALL - 0.5], "materials": MATERIALS, "ramps": RAMPS, "lift": LIFT}
