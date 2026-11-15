"""Picks Shot Bench's pictures for Forever Games' pages, after crop.py has made them.

For each picture named in GALLERY it takes the latest one there is in Shots/ (the highest number),
and writes:

  Shots/gallery/NN-<name>.png           full size, numbered in order, for the CurseForge gallery
  Shots/gallery/00-banner.png           the banner: the logo, a line, and three games over Azeroth
  .github/readme/screenshots/<name>.jpg smaller, for the README
  .github/readme/banner.jpg

Run with ./python.sh gallery.py (./python.sh finds a Python with Pillow).
"""

import glob
import os
import re

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SHOTS = os.path.join(HERE, "Shots")
GALLERY = os.path.join(SHOTS, "gallery")
README = os.path.join(ROOT, ".github", "readme")

# In the order they are shown: what crop.py named each, and what it is called here
PICKS = [
    ("home-window", "home"),
    ("social-scene", "social"),
    ("chess-small-scene", "small"),
    ("words-window", "words"),
    ("realms-window", "carcassonne"),
    ("crazyeights-window", "crazyeights"),
    ("chess-window", "chess"),
    ("backgammon-window", "backgammon"),
    ("warcraftstein-window", "warcraftstein"),
    ("pinball-window", "pinball"),
    ("starfall-window", "pegshooter"),
    ("runeweave-window", "matchthree"),
    ("freecell-window", "freecell"),
    ("reversi-computer-window", "computer"),
]
# How wide the README's copies are: a window, and a whole screen
README_WIDTH, README_SCENE_WIDTH = 900, 1400
BANNER = (1600, 600)
TAGLINE = "Challenge your guild. Turns wait while you're offline."
SUBLINE = "30+ games inside World of Warcraft"


def latest(name):
    """The latest picture crop.py made by this name"""
    found = []
    for path in glob.glob(os.path.join(SHOTS, "*-" + name + ".png")):
        match = re.match(r"(\d+)-(.+)\.png$", os.path.basename(path))
        if match and match.group(2) == name:
            found.append((int(match.group(1)), path))
    if not found:
        raise SystemExit("No picture named " + name + " in " + SHOTS + ": run crop.py")
    return max(found)[1]


def font(size, bold=True):
    for name in (("georgiab.ttf" if bold else "georgia.ttf"), "DejaVuSerif-Bold.ttf"):
        for folder in ("C:/Windows/Fonts", "/mnt/c/Windows/Fonts", "/usr/share/fonts/truetype/dejavu"):
            path = os.path.join(folder, name)
            if os.path.exists(path):
                return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def shadowed(canvas, picture, at, blur=18, offset=(0, 10)):
    """Puts a picture on the canvas with a soft shadow under it"""
    shadow = Image.new("RGBA", (picture.width + blur * 4, picture.height + blur * 4), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rectangle(
        (blur * 2, blur * 2, blur * 2 + picture.width, blur * 2 + picture.height), fill=(0, 0, 0, 190))
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    canvas.alpha_composite(shadow, (at[0] - blur * 2 + offset[0], at[1] - blur * 2 + offset[1]))
    canvas.alpha_composite(picture.convert("RGBA"), at)


def scaled(picture, width):
    return picture.resize((width, round(picture.height * width / picture.width)), Image.LANCZOS)


def banner(pictures):
    width, height = BANNER
    # Azeroth behind it all, out of focus and darker towards the words
    scene = Image.open(latest("chess-small-scene")).convert("RGB")
    scene = scene.crop((0, 0, scene.width, round(scene.width * height / width)))
    back = scaled(scene, width).filter(ImageFilter.GaussianBlur(6)).convert("RGBA")
    shade = Image.new("RGBA", (width, height))
    draw = ImageDraw.Draw(shade)
    for x in range(width):
        # Dark under the words on the left, lighter where the games are
        alpha = round(225 - 120 * min(1, max(0, (x - 500) / 700)))
        draw.line((x, 0, x, height), fill=(8, 8, 14, alpha))
    canvas = Image.alpha_composite(back, shade)

    # Three games, overlapping, on the right
    for name, w, at in (("words", 560, (1000, 40)), ("home", 470, (780, 150)), ("carcassonne", 470, (1110, 280))):
        shadowed(canvas, scaled(pictures[name], w), at)

    logo = Image.open(os.path.join(README, "logo.png")).convert("RGBA")
    logo = scaled(logo, 470)
    canvas.alpha_composite(logo, (95, 40))
    draw = ImageDraw.Draw(canvas)
    big, small = font(34), font(24, bold=False)
    y = 40 + logo.height + 10
    for text, face, colour in ((TAGLINE, big, (255, 214, 102)), (SUBLINE, small, (225, 225, 230))):
        lines = wrap(draw, text, face, 600)
        for line in lines:
            draw.text((100, y), line, font=face, fill=colour)
            y += face.size + 10
        y += 8
    return canvas.convert("RGB")


def wrap(draw, text, face, width):
    lines, line = [], ""
    for word in text.split():
        trial = (line + " " + word).strip()
        if draw.textlength(trial, font=face) > width and line:
            lines.append(line)
            line = word
        else:
            line = trial
    return lines + [line]


def main():
    os.makedirs(GALLERY, exist_ok=True)
    shots = os.path.join(README, "screenshots")
    os.makedirs(shots, exist_ok=True)
    # Only the numbered pictures it made before: anything else kept there (avatars) stays
    for old in glob.glob(os.path.join(GALLERY, "[0-9][0-9]-*.png")):
        os.remove(old)
    pictures = {}
    for number, (source, name) in enumerate(PICKS, 1):
        picture = Image.open(latest(source)).convert("RGB")
        pictures[name] = picture
        picture.save(os.path.join(GALLERY, "%02d-%s.png" % (number, name)))
        wide = README_SCENE_WIDTH if source.endswith("-scene") else README_WIDTH
        scaled(picture, min(wide, picture.width)).save(os.path.join(shots, name + ".jpg"), quality=86, optimize=True)
        print("%02d %s <- %s" % (number, name, os.path.basename(latest(source))))
    made = banner(pictures)
    made.save(os.path.join(GALLERY, "00-banner.png"))
    made.save(os.path.join(README, "banner.jpg"), quality=88, optimize=True)
    print("banner and %d pictures in %s, README copies in %s" % (len(PICKS), GALLERY, shots))


if __name__ == "__main__":
    main()
