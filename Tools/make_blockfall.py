#!/usr/bin/env python3
"""Draws what Tetris is played with (Games/Blockfall.lua), its icon, and makes its sounds.

    python3 Tools/make_blockfall.py Images Sounds

Writes Images/Blockfall/block<size>.tga and ghost<size>.tga at the sizes a well picks from: a
square of a piece in white with its light and shade painted in greys, for the game to tint by
the piece, and the outline where a piece would land. Also streak.tga, the light a dropped piece
leaves behind it, flare.tga, the light along a row that is cleared, and Images/Icons/blockfall.tga.

The sounds are made from sine waves and noise, Sounds/blockfall<Name>1.ogg, and need ffmpeg to
be written as Ogg. Only the standard library is used besides. Pass a third folder to also get PNG
copies of the pictures there, which are easier to look at than TGA.
"""
import math
import random
import struct
import subprocess
import sys
import tempfile
import wave
import zlib
from pathlib import Path

SIZES = (32, 64)
SAMPLES = 4
# How round a square's corners are, and how wide its bevel, in a picture from -1 to 1
CORNER, BEVEL = 0.16, 0.2
SLATE = (24, 27, 38)


def clamp(value):
    return max(0.0, min(1.0, value))


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(len(a)))


def rounded(x, y, half, corner):
    """How far a point is outside a square with round corners, below zero inside it"""
    dx, dy = abs(x) - half + corner, abs(y) - half + corner
    return math.hypot(max(dx, 0), max(dy, 0)) + min(max(dx, dy), 0) - corner


def block(x, y):
    """A square of a piece to tint: a face lit from the top left, a bevel round it that is light
    on the top and left and dark on the bottom and right, and a thin dark rim that keeps two
    squares side by side apart"""
    outer = rounded(x, y, 0.97, CORNER)
    if outer > 0:
        return (255, 255, 255), 0.0
    if outer > -0.06:
        return (70, 70, 70), 1.0
    face = rounded(x, y, 0.97 - BEVEL, CORNER * 0.6)
    if face > 0:
        # The bevel: which edge a point is nearest says how it is lit
        if -y > abs(x) * 0.999:
            shade = 1.0
        elif -x > abs(y):
            shade = 0.86
        elif x > abs(y):
            shade = 0.56
        else:
            shade = 0.46
        return (255 * shade,) * 3, 1.0
    # The face: a little brighter towards the top, with a soft shine across its upper part
    shade = 0.93 - 0.1 * (y + 1) / 2
    shine = clamp(1 - abs(y + 0.32) / 0.18) * clamp(1 - abs(x) / 0.62) * 0.1
    return (255 * clamp(shade + shine),) * 3, 1.0


def ghost(x, y):
    """Where a piece would land: a faint square with a bright edge"""
    outer = rounded(x, y, 0.9, CORNER)
    if outer > 0:
        return (255, 255, 255), 0.0
    if outer > -0.13:
        return (255, 255, 255), 0.95
    return (255, 255, 255), 0.13


def streak(x, y):
    """The light a dropped piece leaves: strongest at the bottom, where it landed, soft at the sides"""
    across = clamp(1 - abs(x) / 0.9) ** 1.5
    down = clamp((y + 1) / 2) ** 2.2
    return (255, 255, 255), across * down


def flare(x, y):
    """The light along a row as it is cleared: a bright line with a glow above and below it"""
    across = clamp(1 - abs(x) ** 6)
    core = math.exp(-((y / 0.18) ** 2))
    glow = math.exp(-((y / 0.55) ** 2)) * 0.5
    return (255, 255, 255), clamp((core + glow) * across)


# The icon: a few pieces in a well, a T coming down into the gap it fits
ICON_COLORS = {
    "I": (38, 242, 242),
    "O": (255, 235, 38),
    "T": (209, 82, 255),
    "S": (89, 209, 46),
    "Z": (235, 31, 64),
    "J": (46, 92, 255),
    "L": (255, 143, 26),
}
ICON_ROWS = (
    ". T . . .",
    "T T T . .",
    ". . . . .",
    "I . . O O",
    "I L . O O",
    "I L L Z Z",
)


def icon(x, y):
    """A well of slate with pieces in it"""
    edge = rounded(x, y, 0.98, 0.22)
    if edge > 0:
        return (0, 0, 0), 0.0
    rows = [row.split() for row in ICON_ROWS]
    count, wide = len(rows), len(rows[0])
    side = 1.72 / count
    left, top = -side * wide / 2, -side * count / 2
    column, row = math.floor((x - left) / side), math.floor((y - top) / side)
    color = SLATE if edge < -0.05 else (90, 100, 140)
    if 0 <= row < count and 0 <= column < wide and rows[row][column] != ".":
        tint = ICON_COLORS[rows[row][column]]
        # Where the point is on its own square, from -1 to 1
        sx = ((x - left) / side - column) * 2 - 1
        sy = ((y - top) / side - row) * 2 - 1
        shade, alpha = block(sx, sy)
        if alpha > 0:
            return tuple(tint[i] * shade[i] / 255 for i in range(3)), 1.0
    return color, 1.0


def render(width, height, paint):
    """Rows of (r, g, b, a) from a function of a point in a box from -1 to 1 each way"""
    rows = []
    for py in range(height):
        row = []
        for px in range(width):
            red = green = blue = alpha = 0.0
            for i in range(SAMPLES):
                for j in range(SAMPLES):
                    x = (px + (i + 0.5) / SAMPLES) / width * 2 - 1
                    y = (py + (j + 0.5) / SAMPLES) / height * 2 - 1
                    color, a = paint(x, y)
                    red, green, blue, alpha = red + color[0] * a, green + color[1] * a, blue + color[2] * a, alpha + a
            if alpha > 0:
                row.append((round(red / alpha), round(green / alpha), round(blue / alpha), round(255 * alpha / SAMPLES**2)))
            else:
                # White where nothing is, so that a picture shrunk on screen doesn't get a dark rim
                row.append((255, 255, 255, 0))
        rows.append(row)
    return rows


def write(path, rows, preview):
    height, width = len(rows), len(rows[0])
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


#############################
# Sounds
#############################

RATE = 44100
# The same noise every time the sounds are made
NOISE = random.Random(1)


def note(name):
    """The frequency of a note, "C5" or "Eb4" """
    steps = {"C": -9, "D": -7, "E": -5, "F": -4, "G": -2, "A": 0, "B": 2}
    letter, rest = name[0], name[1:]
    shift = 0
    if rest.startswith("b"):
        shift, rest = -1, rest[1:]
    elif rest.startswith("#"):
        shift, rest = 1, rest[1:]
    return 440.0 * 2 ** ((steps[letter] + shift + (int(rest) - 4) * 12) / 12)


def silence(seconds):
    return [0.0] * int(RATE * seconds)


def add(into, sound, at=0.0, gain=1.0):
    start = int(at * RATE)
    if len(into) < start + len(sound):
        into.extend([0.0] * (start + len(sound) - len(into)))
    for index, value in enumerate(sound):
        into[start + index] += value * gain
    return into


def bell(frequency, seconds, decay, bright=0.35):
    """A struck tone: quick to start, dying away, with a little of its overtones"""
    out = []
    for index in range(int(RATE * seconds)):
        t = index / RATE
        attack = min(1.0, t / 0.004)
        body = math.sin(2 * math.pi * frequency * t) * math.exp(-t / decay)
        body += bright * math.sin(2 * math.pi * frequency * 2.0 * t) * math.exp(-t / (decay * 0.5))
        body += bright * 0.4 * math.sin(2 * math.pi * frequency * 3.01 * t) * math.exp(-t / (decay * 0.3))
        out.append(attack * body)
    return out


def sweep(start, end, seconds, decay, shape="sine"):
    """A tone that slides from one frequency to another as it dies away"""
    out, phase = [], 0.0
    for index in range(int(RATE * seconds)):
        t = index / RATE
        frequency = start * (end / start) ** (t / seconds)
        phase += 2 * math.pi * frequency / RATE
        wave_ = math.sin(phase) if shape == "sine" else (2 / math.pi) * math.asin(math.sin(phase))
        out.append(min(1.0, t / 0.002) * wave_ * math.exp(-t / decay))
    return out


def noise(seconds, decay, smooth=0.5, rising=False):
    """A burst of noise, smoothed to take the hiss off"""
    out, last = [], 0.0
    count = int(RATE * seconds)
    for index in range(count):
        t = index / RATE
        last = last * smooth + NOISE.uniform(-1, 1) * (1 - smooth)
        envelope = math.sin(math.pi * index / count) if rising else math.exp(-t / decay)
        out.append(last * envelope)
    return out


def finish(sound, level):
    """Brought to a level, softly limited, and faded at the very end so it doesn't click"""
    peak = max(abs(value) for value in sound) or 1.0
    out = [math.tanh(value / peak * 1.2) / math.tanh(1.2) * level for value in sound]
    fade = min(len(out), int(RATE * 0.01))
    for index in range(fade):
        out[-1 - index] *= index / fade
    return out


def make_sounds():
    sounds = {}
    sounds["Move"] = finish(add(bell(1650, 0.04, 0.008, 0.1), noise(0.01, 0.002, 0.2), gain=0.3), 0.16)
    sounds["Turn"] = finish(add(sweep(780, 1250, 0.06, 0.03, "triangle"), bell(1560, 0.05, 0.012, 0.1), gain=0.3), 0.22)
    sounds["Land"] = finish(add(sweep(240, 120, 0.1, 0.03), noise(0.05, 0.01, 0.75), gain=0.5), 0.32)
    drop = add(sweep(260, 55, 0.18, 0.05), noise(0.08, 0.018, 0.82), gain=0.7)
    sounds["Drop"] = finish(add(drop, bell(1900, 0.03, 0.006, 0.0), gain=0.25), 0.5)
    hold = add(noise(0.16, 0.0, 0.88, rising=True), sweep(520, 880, 0.16, 0.08, "triangle"), gain=0.35)
    sounds["Hold"] = finish(hold, 0.24)

    clear = []
    for index, name in enumerate(("C6", "E6", "G6")):
        add(clear, bell(note(name), 0.4, 0.12), at=index * 0.045)
    sounds["Clear"] = finish(clear, 0.34)

    quad = []
    for index, name in enumerate(("C5", "E5", "G5", "C6", "E6", "G6", "C7")):
        add(quad, bell(note(name), 0.8, 0.28, 0.3), at=index * 0.04, gain=0.8 if index < 4 else 0.6)
    add(quad, noise(0.5, 0.0, 0.3, rising=True), gain=0.08)
    sounds["Quad"] = finish(quad, 0.45)

    spin = []
    for index, name in enumerate(("A5", "C6", "D6", "E6", "G6", "A6", "C7")):
        add(spin, bell(note(name), 0.45, 0.14, 0.45), at=index * 0.035, gain=0.8)
    sounds["Spin"] = finish(spin, 0.4)

    level = []
    for index, name in enumerate(("G4", "C5", "E5", "G5", "C6")):
        add(level, bell(note(name), 0.6, 0.2, 0.25), at=index * 0.075)
    sounds["Level"] = finish(level, 0.38)

    over = []
    for index, name in enumerate(("G4", "Eb4", "C4", "G3")):
        add(over, sweep(note(name), note(name) * 0.97, 0.7, 0.3, "triangle"), at=index * 0.17)
    add(over, sweep(110, 50, 1.2, 0.5), gain=0.5)
    sounds["Over"] = finish(over, 0.38)

    sounds["Beat"] = finish(bell(note("E5"), 0.18, 0.06, 0.2), 0.28)
    go = add(bell(note("E6"), 0.4, 0.14, 0.25), bell(note("B6"), 0.4, 0.12, 0.2), gain=0.6)
    sounds["Go"] = finish(go, 0.34)
    return sounds


def write_sound(folder, name, sound):
    folder.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as scratch:
        raw = Path(scratch) / "sound.wav"
        with wave.open(str(raw), "wb") as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(RATE)
            out.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, value)) * 32767)) for value in sound))
        target = folder / ("blockfall" + name + "1.ogg")
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(raw), "-c:a", "libvorbis", "-q:a", "5", str(target)], check=True)


images = Path(sys.argv[1])
sounds_folder = Path(sys.argv[2])
preview = Path(sys.argv[3]) if len(sys.argv) > 3 else None
for size in SIZES:
    write(images / "Blockfall" / ("block%d.tga" % size), render(size, size, block), preview)
    write(images / "Blockfall" / ("ghost%d.tga" % size), render(size, size, ghost), preview)
write(images / "Blockfall" / "streak.tga", render(32, 128, streak), preview)
write(images / "Blockfall" / "flare.tga", render(256, 64, flare), preview)
write(images / "Icons" / "blockfall.tga", render(64, 64, icon), preview)
for sound_name, samples in make_sounds().items():
    write_sound(sounds_folder, sound_name, samples)
