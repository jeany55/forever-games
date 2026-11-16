"""Picks Shot Bench's pictures for Forever Games' pages, after crop.py has made them.

For each picture named in GALLERY it takes the latest one there is in Shots/ (the highest number),
and writes:

  Shots/gallery/NN-<name>.png           full size, numbered in order, for the CurseForge gallery
                                        (a .jpg instead when the PNG is over CurseForge's 2 MB)
  Shots/gallery/00-banner.png           the banner: the logo, a line, and three games over Azeroth
  .github/readme/screenshots/<name>.jpg smaller, for the README
  .github/readme/banner.jpg
  Shots/gallery/banner-<game>.png and .github/readme/banner-<game>.jpg, for the games that are
                                        projects of their own (COMPANIONS)

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
# CurseForge turns away pictures over 2 MB
LARGEST = 1900 * 1000  # "2 MB", with room to spare however they count it
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


# The games that are projects of their own: what crop.py named the window, the part of it that is the
# game's own view (the background, blurred), the big icon, the name and the line under it
COMPANIONS = [
    ("where", "where-window", (55, 142, 1097, 737), "Where in Azeroth",
     "You're dropped somewhere in the world. Look around, then pin where you are."),
    ("freedoom", "freedoom-window", (225, 155, 928, 600), "Freedoom",
     "Run for the exit inside World of Warcraft, and race your friends' ghosts."),
]
COMPANION_LINE = "A game for Forever Games"


def companion_banner(window, view, icon, title, tagline):
    """A banner like Forever Games' own, for a game that is a project of its own"""
    width, height = BANNER
    window = Image.open(window).convert("RGB")
    # Behind it all, the game's own view, filling the banner, out of focus
    back = window.crop(view)
    cover = max(width / back.width, height / back.height)
    back = back.resize((round(back.width * cover), round(back.height * cover)), Image.LANCZOS)
    left, top = (back.width - width) // 2, (back.height - height) // 2
    back = back.crop((left, top, left + width, top + height)).filter(ImageFilter.GaussianBlur(10)).convert("RGBA")
    shade = Image.new("RGBA", (width, height))
    draw = ImageDraw.Draw(shade)
    for x in range(width):
        alpha = round(225 - 110 * min(1, max(0, (x - 600) / 600)))
        draw.line((x, 0, x, height), fill=(8, 8, 14, alpha))
    canvas = Image.alpha_composite(back, shade)

    # The window without the bit of the world around its frame
    framed = window.crop((22, 20, window.width - 22, window.height - 20))
    shadowed(canvas, scaled(framed, 640), (880, 66))

    mark = Image.open(icon).convert("RGBA").resize((150, 150), Image.LANCZOS)
    shadowed(canvas, mark, (100, 80), blur=10, offset=(0, 6))
    draw = ImageDraw.Draw(canvas)
    y = 80 + 150 + 30
    # Big enough to read at half size, as CurseForge shows it
    for text, face, colour, gap in ((title, font(64), (255, 214, 102), 18),
                                     (tagline, font(34, bold=False), (235, 235, 240), 22),
                                     (COMPANION_LINE, font(28, bold=False), (190, 190, 200), 0)):
        for line in wrap(draw, text, face, 680):
            draw.text((100, y), line, font=face, fill=colour)
            y += face.size + 10
        y += gap
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


def save_for_curseforge(picture, stem):
    """As a PNG, or as a JPEG as good as fits when the PNG is too big for CurseForge"""
    path = os.path.join(GALLERY, stem + ".png")
    picture.save(path)
    if os.path.getsize(path) <= LARGEST:
        return path
    os.remove(path)
    path = os.path.join(GALLERY, stem + ".jpg")
    for quality in (95, 92, 90, 87, 84, 80):
        picture.save(path, quality=quality, optimize=True, subsampling=0 if quality >= 90 else 2)
        if os.path.getsize(path) <= LARGEST:
            break
    return path


def main():
    os.makedirs(GALLERY, exist_ok=True)
    shots = os.path.join(README, "screenshots")
    os.makedirs(shots, exist_ok=True)
    # Only the numbered pictures it made before: anything else kept there (avatars) stays
    for old in glob.glob(os.path.join(GALLERY, "[0-9][0-9]-*.png")) + glob.glob(os.path.join(GALLERY, "[0-9][0-9]-*.jpg")):
        os.remove(old)
    pictures = {}
    for number, (source, name) in enumerate(PICKS, 1):
        picture = Image.open(latest(source)).convert("RGB")
        pictures[name] = picture
        save_for_curseforge(picture, "%02d-%s" % (number, name))
        wide = README_SCENE_WIDTH if source.endswith("-scene") else README_WIDTH
        scaled(picture, min(wide, picture.width)).save(os.path.join(shots, name + ".jpg"), quality=86, optimize=True)
        print("%02d %s <- %s" % (number, name, os.path.basename(latest(source))))
    made = banner(pictures)
    save_for_curseforge(made, "00-banner")
    made.save(os.path.join(README, "banner.jpg"), quality=88, optimize=True)
    print("banner and %d pictures in %s, README copies in %s" % (len(PICKS), GALLERY, shots))
    for name, window, view, title, tagline in COMPANIONS:
        made = companion_banner(latest(window), view, os.path.join(README, "icons", "large", name + ".png"), title, tagline)
        save_for_curseforge(made, "banner-" + name)
        # CurseForge's descriptions take pictures up to 800 wide
        scaled(made, 800).save(os.path.join(README, "banner-" + name + ".jpg"), quality=90, optimize=True)
        print("banner-" + name)


if __name__ == "__main__":
    main()
