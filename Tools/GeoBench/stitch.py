#!/usr/bin/env python3
"""Stitches the bench's captures (Capture.lua) into panoramas the bench can show (Pano.lua).

A capture is a ring of screenshots from one spot, the camera turned the same step between each.
Nothing is matched up by looking for the same things in two of them: how far apart they were
turned is known, so all that isn't is how wide the camera saw (the client's field of view is
not quite what its setting says) and how far up or down it was looking. Both are found by trying
them: the pair that makes the screenshots agree best where they overlap (the detail in them, not
their colours, so that the sky's sameness doesn't count) is the one. Which way the camera turned
is found the same way.

Then each pixel of the panorama is looked for in every screenshot that saw it, and those that
did are blended, more of whichever saw it nearer its middle. The panorama is cut into pictures of
1024 across (Images/c<id>_<n>.tga) and listed in Images/Panos.lua, with a smaller picture of it
whole in Previews/ to look at.

    ./python.sh stitch.py                 every capture not stitched yet
    ./python.sh stitch.py 3 4             those captures, again if they were
    ./python.sh stitch.py --width 2048    narrower (4096 if not said)
    --game <folder>                       the game's _classic_beta_ folder, if not the usual one
    --account <name>                      which account's saved variables, if there are several
    --blp                                 the client's own BLP (DXT1) rather than TGA, a fifth of the size
    --from <folder> --tag <name>          somebody else's captures: their GeoBench.lua and their
                                          screenshots anywhere in the folder, as they sent them.
                                          Their panoramas are <name><id>, apart from your own c<id>

Runs where the screenshots are: once the panorama is made, the screenshots can go.
"""
import argparse
import json
import math
import os
import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image

import panos

# The client's own format, written by Tools/blp.py
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import blp  # noqa: E402

HERE = Path(__file__).resolve().parent
TILE = 1024
# How wide the screenshots are made for finding the field of view
SEARCH_WIDTH = 480
SEARCH_PANO = (900, 260)
# How badly the screenshots of a capture may disagree before it is called a bad one
BAD = 0.5


def game_folder(given):
    if given:
        return Path(given)
    if os.name == "nt":
        return Path(r"C:\Program Files (x86)\World of Warcraft\_classic_beta_")
    return Path("/mnt/c/Program Files (x86)/World of Warcraft/_classic_beta_")


def saved_file(game, account, given):
    """The saved variables to read: the newest account's under the game, or wherever in a folder
    somebody sent theirs"""
    if given:
        found = sorted(Path(given).rglob("GeoBench.lua"), key=lambda p: p.stat().st_mtime)
        where = given
    else:
        found = sorted((game / "WTF" / "Account").glob("*/SavedVariables/GeoBench.lua"), key=lambda p: p.stat().st_mtime)
        if account:
            found = [p for p in found if p.parent.parent.name == account]
        where = game / "WTF" / "Account"
    if not found:
        sys.exit(f"No GeoBench.lua under {where}: capture, then /reload or log out")
    return found[-1]


def captures(path):
    text = path.read_text(encoding="utf-8", errors="replace")
    out = {}
    for match in re.finditer(r'\["line"\]\s*=\s*"((?:[^"\\]|\\.)*)"', text):
        line = re.sub(r"\\(.)", r"\1", match.group(1))
        fields = dict(part.split("=", 1) for part in line.split("|") if "=" in part)
        out[int(fields["id"])] = fields
    return out


def number(fields, key):
    try:
        return float(fields[key])
    except (KeyError, ValueError):
        return None


def shot_index(folder):
    """Every screenshot anywhere in a folder, by its name without the extension"""
    return {p.stem: p for p in Path(folder).rglob("WoWScrnShot_*") if p.suffix.lower() in (".tga", ".jpg", ".jpeg", ".png")}


def screenshots(shots, fields):
    names = fields["names"].split(",")
    called = fields.get("called", "").split(",")
    files = []
    for index, name in enumerate(names):
        tries = [name] + ([called[index]] if index < len(called) else [])
        # A shot written late can be named for the same second as the next: that one is the
        # next's, and this one's is the second it was called in
        if names.count(name) > 1 and len(tries) > 1 and tries[1] != name:
            tries.reverse()
        path = None
        for stamp in tries:
            path = shots.get(f"WoWScrnShot_{stamp}")
            if path:
                break
        if not path:
            sys.exit(f"Capture {fields['id']}: no screenshot {tries} among the {len(shots)} there are")
        files.append(path)
    return files


def load(paths):
    return [np.asarray(Image.open(p).convert("RGB"), np.float32) for p in paths]


def shrink(image, width):
    height = round(image.shape[0] * width / image.shape[1])
    return np.asarray(Image.fromarray(image.astype(np.uint8)).resize((width, height), Image.BILINEAR), np.float32)


def detail(image):
    """The luminance less its blur: where things are, not what colour"""
    lum = image @ np.array([0.299, 0.587, 0.114], np.float32)
    blurred = np.asarray(Image.fromarray(lum.astype(np.uint8)).resize(
        (max(1, lum.shape[1] // 8), max(1, lum.shape[0] // 8)), Image.BILINEAR).resize(
        (lum.shape[1], lum.shape[0]), Image.BILINEAR), np.float32)
    return (lum - blurred)[..., None]


def sample(image, x, y):
    """Bilinear: the image at x, y (arrays), and which of them were inside it"""
    h, w = image.shape[:2]
    inside = (x >= 0) & (x <= w - 1) & (y >= 0) & (y <= h - 1)
    x = np.clip(x, 0, w - 1.001)
    y = np.clip(y, 0, h - 1.001)
    x0, y0 = x.astype(np.int32), y.astype(np.int32)
    fx, fy = (x - x0)[..., None], (y - y0)[..., None]
    a = image[y0, x0]
    b = image[y0, x0 + 1]
    c = image[y0 + 1, x0]
    d = image[y0 + 1, x0 + 1]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy, inside


def project(phi, h, yaw, pitch, f, cx, cy):
    """Where on a screenshot taken looking `yaw` round and `pitch` up a point of the panorama is
    (phi round clockwise, h up the cylinder), and whether it is in front of the camera"""
    x, y, z = np.sin(phi), h, np.cos(phi)
    # Turned back by the yaw, then by the pitch
    x1 = x * math.cos(yaw) - z * math.sin(yaw)
    z1 = x * math.sin(yaw) + z * math.cos(yaw)
    y2 = y * math.cos(pitch) - z1 * math.sin(pitch)
    z2 = y * math.sin(pitch) + z1 * math.cos(pitch)
    ahead = z2 > 1e-3
    z2 = np.where(ahead, z2, 1)
    return cx + f * x1 / z2, cy - f * y2 / z2, ahead


def compose(images, step, sign, fov, pitch, width, top, bottom, height, weights_only=False):
    """The panorama, `width` round by `height` from `top` to `bottom`; with it how much of each
    pixel any screenshot saw, and how much the screenshots disagree where more than one did"""
    ih, iw = images[0].shape[:2]
    f = iw / 2 / math.tan(math.radians(fov) / 2)
    cx, cy = (iw - 1) / 2, (ih - 1) / 2
    phi = (np.arange(width) + 0.5) / width * 2 * math.pi
    h = top - (np.arange(height) + 0.5) / height * (top - bottom)
    P, H = np.meshgrid(phi, h)
    total = np.zeros((height, width, images[0].shape[2]), np.float32)
    squares = np.zeros_like(total)
    weight = np.zeros((height, width, 1), np.float32)
    seen = np.zeros((height, width), np.int32)
    for k, image in enumerate(images):
        yaw = sign * k * math.radians(step)
        x, y, ahead = project(P, H, yaw, pitch, f, cx, cy)
        value, inside = sample(image, x, y)
        inside &= ahead
        # More of it the nearer its middle
        wx = np.clip(1 - np.abs(x - cx) / (iw / 2), 0, 1)
        wy = np.clip(1 - np.abs(y - cy) / (ih / 2), 0, 1)
        w = (np.where(inside, wx * wx * np.sqrt(wy), 0))[..., None]
        total += value * w
        squares += value * value * w
        weight += w
        seen += inside
    mean = total / np.maximum(weight, 1e-6)
    variance = squares / np.maximum(weight, 1e-6) - mean * mean
    return mean, weight[..., 0], seen, variance


def disagreement(images, step, sign, fov, pitch):
    """How unlike each screenshot is the next where they overlap, at this field of view and pitch:
    their difference against how much detail there is, so that a bare overlap doesn't win"""
    width, height = SEARCH_PANO
    ih, iw = images[0].shape[:2]
    f = iw / 2 / math.tan(math.radians(fov) / 2)
    cx, cy = (iw - 1) / 2, (ih - 1) / 2
    phi = (np.arange(width) + 0.5) / width * 2 * math.pi
    h = 0.5 - (np.arange(height) + 0.5) / height
    P, H = np.meshgrid(phi, h)
    seen = []
    for k, image in enumerate(images):
        x, y, ahead = project(P, H, sign * k * math.radians(step), pitch, f, cx, cy)
        value, inside = sample(image, x, y)
        seen.append((value[..., 0], inside & ahead))
    difference = energy = 0.0
    overlap = 0
    for k in range(len(images)):
        a, inside_a = seen[k]
        b, inside_b = seen[(k + 1) % len(images)]
        both = inside_a & inside_b
        count = int(both.sum())
        if count < 0.02 * width * height:
            return float("inf")
        overlap += count
        difference += float(((a[both] - b[both]) ** 2).sum())
        energy += float((a[both] ** 2 + b[both] ** 2).sum())
    return difference / max(energy, 1e-6)


def calibrate(images, step, said_fov):
    small = [detail(shrink(image, SEARCH_WIDTH)) for image in images]
    best = None
    # Which way round and about how wide, looking level
    for sign in (1, -1):
        for fov in np.arange(40, 131, 3):
            score = disagreement(small, step, sign, fov, 0)
            if best is None or score < best[0]:
                best = (score, sign, fov, 0.0)
    score, sign, fov, pitch = best
    # Then closer, the width and the pitch in turn
    for span, steps in ((3, 13), (0.6, 13), (0.12, 13)):
        for _ in range(2):
            fov = min(np.linspace(fov - span, fov + span, steps), key=lambda v: disagreement(small, step, sign, v, pitch))
            pitch = min(np.linspace(pitch - math.radians(span * 3), pitch + math.radians(span * 3), steps),
                        key=lambda v: disagreement(small, step, sign, fov, v))
    score = disagreement(small, step, sign, fov, pitch)
    level = disagreement(small, step, sign, said_fov, 0) if said_fov else None
    return sign, float(fov), float(pitch), score, level


def extent(images, step, sign, fov, pitch):
    """How far up and down every way round some screenshot saw"""
    width, height = 720, 800
    _, _, seen, _ = compose([image[..., :1] for image in images], step, sign, fov, pitch, width, 2.0, -2.0, height)
    h = 2.0 - (np.arange(height) + 0.5) / height * 4.0
    covered = seen.min(axis=1) > 0
    middle = height // 2
    up = middle
    while up > 0 and covered[up - 1]:
        up -= 1
    down = middle
    while down < height - 1 and covered[down + 1]:
        down += 1
    # A little inside, for the blending to have something to blend
    return float(h[up]) * 0.98, float(h[down]) * 0.98


def stitch(index, fields, width, as_blp=False, tag=None):
    capture = int(fields["id"])
    step = number(fields, "step") or 30
    said_fov = number(fields, "fov")
    paths = screenshots(index, fields)
    print(f"Capture {capture}: {fields.get('zone')} / {fields.get('subzone')}, {len(paths)} screenshots, {step} degrees apart")
    images = load(paths)
    sign, fov, pitch, score, level = calibrate(images, step, said_fov)
    print(f"  field of view {fov:.2f} degrees across (the setting said {said_fov}), looking {math.degrees(pitch):+.2f} up,"
          f" turned {'clockwise' if sign > 0 else 'anticlockwise'}; disagreement {score:.3f}"
          + (f" (at the setting's, level: {level:.3f})" if level else ""))
    # A good capture's screenshots agree to under 0.3, moving water and all: past this, no field
    # of view made them agree, because something near moved or the camera did
    if score > BAD:
        print(f"  NOT STITCHED WELL: the screenshots don't agree whatever the field of view. Something close"
              f" in front, something walking past or the camera tipping does this: take it again")
    top, bottom = extent(images, step, sign, fov, pitch)
    natural = width * (top - bottom) / (2 * math.pi)
    height = 1 << max(8, math.ceil(math.log2(natural)))
    print(f"  {math.degrees(math.atan(top)):.1f} up to {math.degrees(math.atan(bottom)):.1f} down: {width} x {height}"
          f" ({natural:.0f} rows of detail)")
    # A band at a time, not to need the whole of it at once more than once
    image = np.zeros((height, width, 3), np.float32)
    band = 128
    for start in range(0, height, band):
        rows = min(band, height - start)
        t = top - start / height * (top - bottom)
        b = top - (start + rows) / height * (top - bottom)
        mean, _, _, _ = compose(images, step, sign, fov, pitch, width, t, b, rows)
        image[start:start + rows] = mean
    picture = np.clip(image + 0.5, 0, 255).astype(np.uint8)
    name = f"{tag or 'c'}{capture}"
    tiles = max(1, width // TILE)
    tile_width = width // tiles
    for t in range(tiles):
        part = picture[:, t * tile_width:(t + 1) * tile_width, ::-1]
        if as_blp:
            blp.write_blp(panos.IMAGES / f"{name}_{t + 1}.blp", np.ascontiguousarray(part[:, :, ::-1]))
        else:
            panos.write_tga(panos.IMAGES / f"{name}_{t + 1}.tga", tile_width, height, [part[r].tobytes() for r in range(height)])
    previews = Path(os.environ.get("GEOBENCH_PREVIEWS", HERE / "Previews"))
    previews.mkdir(exist_ok=True)
    preview = previews / f"{name}.jpg"
    Image.fromarray(picture).resize((min(width, 2400), round(height * min(width, 2400) / width)), Image.LANCZOS).save(preview, quality=88)

    def colour(rows):
        return [round(float(v) / 255, 4) for v in rows.reshape(-1, 3).mean(axis=0)]

    entry = {"name": name, "file": name, "tiles": tiles, "width": width, "height": height, "top": top, "bottom": bottom,
             "capture": capture, "source": tag, "zone": fields.get("zone"), "subzone": fields.get("subzone"),
             "mapID": number(fields, "mapID"), "x": number(fields, "x"), "y": number(fields, "y"),
             "continent": number(fields, "continent"), "worldX": number(fields, "worldX"),
             "worldY": number(fields, "worldY"), "facing": number(fields, "facing"),
             "fov": round(fov, 3), "pitch": round(math.degrees(pitch), 3), "sky": colour(picture[:4]),
             "ground": colour(picture[-4:])}
    panos.register(entry)
    print(f"  {name}: {tiles} pictures, preview {preview}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("ids", nargs="*", type=int)
    parser.add_argument("--width", type=int, default=4096, choices=(1024, 2048, 4096, 8192))
    parser.add_argument("--game")
    parser.add_argument("--account")
    parser.add_argument("--blp", action="store_true", help="BLP (DXT1) pictures rather than TGA, about a fifth of the size")
    parser.add_argument("--from", dest="source", help="a folder of somebody else's captures")
    parser.add_argument("--tag", help="what their panoramas are called, before the capture's number")
    args = parser.parse_args()
    tag = None
    if args.source:
        if not args.tag or not re.fullmatch(r"[a-z][a-z]{1,11}", args.tag) or args.tag == "c" or args.tag == "test":
            sys.exit("Somebody else's captures need a --tag of 2 to 12 lower case letters (not c or test), e.g. --tag bob")
        tag = args.tag
    game = game_folder(args.game)
    found = captures(saved_file(game, args.account, args.source))
    index = shot_index(args.source or game / "Screenshots")
    listing = panos.IMAGES / "panos.json"
    done = {p["name"] for p in json.loads(listing.read_text())} if listing.exists() else set()
    ids = args.ids or [i for i in sorted(found) if f"{tag or 'c'}{i}" not in done]
    if not ids:
        print(f"Nothing new to stitch ({len(found)} captures, all stitched): give their numbers to do them again")
    for capture in ids:
        if capture not in found:
            sys.exit(f"No capture {capture} (there are {sorted(found)})")
        stitch(index, found[capture], args.width, args.blp, tag)
    if ids:
        print("Then ./install.sh; a new picture needs the game restarted, /reload is enough for one stitched again")


if __name__ == "__main__":
    main()
