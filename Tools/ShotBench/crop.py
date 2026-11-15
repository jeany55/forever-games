"""Turns Shot Bench's screenshots into pictures for Forever Games' page.

For every screenshot ShotBenchDB keeps (SavedVariables/ShotBench.lua, written on /reload), finds
the client's file for it in the game's Screenshots folder and writes into Shots/:

  <id>-<game>-window.png   the window alone, with a little of the world around it
  <id>-<game>-scene.png    the whole screen as it was
  contact.jpg              every window picture on one sheet, named, to choose from

Run with ./python.sh crop.py [--margin 24] [--only chess,2048] [--from <first id>]
(./python.sh finds a Python with Pillow: WSL's own, or the one installed on Windows).
"""

import argparse
import datetime
import glob
import os
import re
import sys

from PIL import Image, ImageDraw, ImageFont

GAME = "/mnt/c/Program Files (x86)/World of Warcraft/_forever_"
WINDOWS_GAME = "C:/Program Files (x86)/World of Warcraft/_forever_"
HERE = os.path.dirname(os.path.abspath(__file__))


def game_folder():
    """The game's folder as this Python sees it: WSL's path, or Windows' own"""
    for folder in (GAME, WINDOWS_GAME):
        if os.path.isdir(folder):
            return folder
    sys.exit("No game folder at " + GAME)


def read_shots(folder):
    """Every screenshot's fields, from the one line each keeps, across every account"""
    shots = {}
    for path in glob.glob(os.path.join(folder, "WTF", "Account", "*", "SavedVariables", "ShotBench.lua")):
        with open(path, encoding="utf-8") as saved:
            for line in re.findall(r'\["line"\]\s*=\s*"([^"]*)"', saved.read()):
                fields = dict(pair.split("=", 1) for pair in line.split("|") if "=" in pair)
                shots[(fields.get("called"), fields.get("id"))] = fields
    return sorted(shots.values(), key=lambda shot: int(shot["id"]))


def stamp_times(stamp):
    """The seconds around a stamp the client may have named the file by: it can be a second late"""
    when = datetime.datetime.strptime(stamp, "%m%d%y_%H%M%S")
    return [(when + datetime.timedelta(seconds=step)).strftime("%m%d%y_%H%M%S") for step in (0, 1, 2, -1)]


def find_file(folder, shot):
    for stamp in [shot.get("done")] + stamp_times(shot["called"]):
        if not stamp:
            continue
        for extension in ("png", "jpg", "tga"):
            path = os.path.join(folder, "Screenshots", "WoWScrnShot_%s.%s" % (stamp, extension))
            if os.path.exists(path):
                return path
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--margin", type=int, default=24, help="pixels of the world kept around the window")
    parser.add_argument("--only", default="", help="game ids, separated by commas")
    parser.add_argument("--from", dest="first", type=int, default=1, help="the first screenshot id to do")
    args = parser.parse_args()
    only = set(filter(None, args.only.split(",")))

    folder = game_folder()
    out = os.path.join(HERE, "Shots")
    os.makedirs(out, exist_ok=True)
    made = []
    for shot in read_shots(folder):
        name = "-".join(filter(None, [shot.get("game"), shot.get("kind") if shot.get("kind") not in ("game", None) else None, shot.get("vs")]))
        if int(shot["id"]) < args.first or (only and shot.get("game") not in only and name not in only):
            continue
        if shot.get("failed"):
            print("#%s %s: the client said it failed" % (shot["id"], name))
            continue
        path = find_file(folder, shot)
        if not path:
            print("#%s %s: no screenshot for %s" % (shot["id"], name, shot["called"]))
            continue
        image = Image.open(path).convert("RGB")
        base = "%03d-%s" % (int(shot["id"]), name)
        image.save(os.path.join(out, base + "-scene.png"))
        if "left" in shot:
            # Where the window was, in the screen's pixels, scaled to the picture's if the client
            # draws the world at another size
            sx = image.width / float(shot["width"])
            sy = image.height / float(shot["height"])
            box = (
                max(0, round((int(shot["left"]) - args.margin) * sx)),
                max(0, round((int(shot["top"]) - args.margin) * sy)),
                min(image.width, round((int(shot["right"]) + args.margin) * sx)),
                min(image.height, round((int(shot["bottom"]) + args.margin) * sy)),
            )
            window = image.crop(box)
            window.save(os.path.join(out, base + "-window.png"))
            made.append((name, window))
        else:
            made.append((name, image))
        print("#%s %s <- %s" % (shot["id"], name, os.path.basename(path)))

    if made:
        contact(made, os.path.join(out, "contact.jpg"))
        print("%d pictures in %s" % (len(made), out))


def contact(pictures, path, across=5, width=480):
    """Every picture small on one sheet, its name under it"""
    height = max(round(picture.height * width / picture.width) for _, picture in pictures)
    rows = (len(pictures) + across - 1) // across
    sheet = Image.new("RGB", (across * (width + 10) + 10, rows * (height + 36) + 10), (24, 24, 28))
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("arial.ttf", 18)
    except OSError:
        font = ImageFont.load_default()
    for index, (name, picture) in enumerate(pictures):
        small = picture.resize((width, round(picture.height * width / picture.width)), Image.LANCZOS)
        x, y = 10 + (index % across) * (width + 10), 10 + (index // across) * (height + 36)
        sheet.paste(small, (x, y))
        draw.text((x, y + small.height + 6), name, fill=(230, 230, 230), font=font)
    sheet.save(path, quality=90)


if __name__ == "__main__":
    main()
