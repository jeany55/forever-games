#!/usr/bin/env python3
"""Makes the bench's test panoramas, before there are any of the game's own: a made-up place all
the way round, with what shows whether the viewer draws it right. The four quarters have posts
and letters (N red, E green, S blue, W yellow), there are ticks every 10 degrees along the
horizon, hills behind, and rings and spokes on the ground: rings round where you stand should
look like a floor, not bend, and the posts should stay upright and straight as you turn.

    test2048    2048 x 512, one picture, 24 bits
    test4096    4096 x 1024, four pictures of 1024 x 1024, 32 bits (and whether 32 loads too)

Needs numpy (run through python.sh, which finds a Python that has it).
"""
import math

import numpy as np

import panos

TOP, BOTTOM = 0.6, -0.6
# How high above the ground the camera is, for the rings
EYE = 1.7

# 5 x 7 letters
LETTERS = {
    "N": ["X...X", "XX..X", "X.X.X", "X..XX", "X...X", "X...X", "X...X"],
    "E": ["XXXXX", "X....", "X....", "XXXX.", "X....", "X....", "XXXXX"],
    "S": [".XXXX", "X....", "X....", ".XXX.", "....X", "....X", "XXXX."],
    "W": ["X...X", "X...X", "X...X", "X.X.X", "X.X.X", "XX.XX", "X...X"],
}
POSTS = [(0, "N", (230, 60, 50)), (90, "E", (60, 200, 70)), (180, "S", (60, 110, 240)), (270, "W", (240, 210, 50))]


def panorama(width, height):
    azimuth = (np.arange(width) + 0.5) / width * 360.0
    h = TOP - (np.arange(height) + 0.5) / height * (TOP - BOTTOM)
    a, hh = np.meshgrid(azimuth, h)
    image = np.zeros((height, width, 3), np.float64)
    # Sky: deeper upward
    up = np.clip(hh / TOP, 0, 1)[..., None]
    image[:] = (1 - up) * np.array([200, 220, 240]) + up * np.array([70, 120, 200])
    # Hills on the horizon
    rad = np.radians(azimuth)
    ridge = 0.06 + 0.04 * np.sin(3 * rad + 1) + 0.03 * np.sin(7 * rad + 2) + 0.015 * np.sin(17 * rad)
    hills = (hh >= 0) & (hh < ridge[None, :])
    image[hills] = np.array([110, 100, 140])
    # Ground: rings every 2 units out, spokes every 15 degrees
    ground = hh < 0
    distance = np.where(ground, EYE / np.maximum(-hh, 1e-6), 0)
    shade = np.clip(1 - distance / 60, 0.3, 1)[..., None]
    floor = np.array([70, 140, 60]) * shade + np.array([150, 170, 190]) * (1 - shade)
    image[ground] = floor[ground]
    ring = ground & (np.abs((distance % 2) - 1) > 0.94) & (distance < 40)
    image[ring] = np.array([235, 235, 220])
    spoke = ground & (np.abs(((a + 7.5) % 15) - 7.5) < 0.25) & (distance < 40)
    image[spoke] = np.array([235, 235, 220])
    # Ticks along the horizon every 10 degrees, taller every 30
    tick = (np.abs(((a + 5) % 10) - 5) < 0.12) & (np.abs(hh) < 0.02)
    tick |= (np.abs(((a + 15) % 30) - 15) < 0.15) & (np.abs(hh) < 0.05)
    image[tick] = np.array([255, 255, 255])
    # Posts and their letters
    for degrees, letter, colour in POSTS:
        off = (a - degrees + 180) % 360 - 180
        post = (np.abs(off) < 1.2) & (hh > -0.12) & (hh < 0.3)
        image[post] = np.array(colour)
        rows = LETTERS[letter]
        # Each cell of the letter 0.6 degrees across, 0.012 high, above the post
        for r, line in enumerate(rows):
            for c, cell in enumerate(line):
                if cell == "X":
                    x0 = (c - 2.5) * 0.6
                    y0 = 0.46 - r * 0.018
                    block = (off >= x0) & (off < x0 + 0.6) & (hh <= y0) & (hh > y0 - 0.018)
                    image[block] = np.array(colour)
    # A grid line at the horizon itself
    image[np.abs(hh) < 0.0025] = np.array([255, 120, 120])
    return np.clip(image, 0, 255).astype(np.uint8)


def write(name, width, height, tiles, bits):
    image = panorama(width, height)
    tile_width = width // tiles
    for t in range(tiles):
        part = image[:, t * tile_width:(t + 1) * tile_width, ::-1]
        if bits == 32:
            part = np.concatenate([part, np.full(part.shape[:2] + (1,), 255, np.uint8)], axis=2)
        rows = [part[r].tobytes() for r in range(height)]
        path = panos.IMAGES / f"{name}_{t + 1}.tga"
        panos.write_tga(path, tile_width, height, rows, bits)
        print(path)
    panos.register({"name": name, "file": name, "tiles": tiles, "width": width, "height": height, "top": TOP,
                    "bottom": BOTTOM, "facing": 0.0, "zone": "Test pattern", "sky": [200 / 255, 220 / 255, 240 / 255],
                    "ground": [150 / 255, 170 / 255, 190 / 255]})


def main():
    write("test2048", 2048, 512, 1, 24)
    write("test4096", 4096, 1024, 4, 32)


if __name__ == "__main__":
    main()
