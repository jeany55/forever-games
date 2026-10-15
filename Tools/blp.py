#!/usr/bin/env python3
"""Writes and reads the client's own picture format, BLP2, compressed as DXT1: four bits a pixel
rather than the 24 of a TGA, so a panorama ships at about a sixth of the size. The client takes
these as it takes a TGA, by the same path without the extension.

The layout is wowdev.wiki/BLP's: a header of 148 bytes, a palette of 256 colours that DXT
doesn't use (left zeros), then each size of the picture in turn, from the whole of it halved
down to one pixel, each as DXT1 blocks. A block is 4 by 4 pixels in 8 bytes: two colours of 16
bits (5 red, 6 green, 5 blue) and for each pixel which of four colours between them it is.

    header    "BLP2", version 1 (uint32), colour encoding 2 = DXT, alpha depth 0,
              alpha type 0 = DXT1, has mips 1 (uint8 each), width, height (uint32),
              16 mip offsets, 16 mip sizes (uint32 each), palette 256 x uint32

The encoder finds each block's two colours along the line its pixels lie closest to (their main
axis), then improves them a few times by least squares against which colour each pixel took:
good enough that a panorama looks like itself, quick enough for a 4096 x 1024 one in seconds.

    python blp.py <in.tga|png|jpg> <out.blp>     one picture
    python blp.py --check <in> [<out.png>]       encodes, decodes and says how close it came

Needs numpy and Pillow (run through GeoBench/python.sh from its folder, or any Python with them).
"""
import struct
import sys
from pathlib import Path

import numpy as np

HEADER = struct.Struct("<4sIBBBBII16I16I")
PALETTE_BYTES = 256 * 4
DATA_START = HEADER.size + PALETTE_BYTES
# Blocks done at once, not to need more memory than that for the distances
CHUNK = 32768
REFINE = 3


def mips(image):
    """The picture and every half of it after, down to one pixel, each the mean of the four
    pixels it is made of (two at the edge of a picture only one pixel across or down)"""
    levels = [image.astype(np.float32)]
    while levels[-1].shape[0] > 1 or levels[-1].shape[1] > 1:
        last = levels[-1]
        h, w = last.shape[:2]
        if h > 1:
            last = (last[0::2] + last[1::2]) / 2
        if w > 1:
            last = (last[:, 0::2] + last[:, 1::2]) / 2
        levels.append(last)
    return levels


def blocks_of(image):
    """The picture cut into 4 x 4 blocks, each its 16 pixels row by row. A picture smaller than a
    block is filled out with its own edge"""
    h, w = image.shape[:2]
    bh, bw = max(4, h), max(4, w)
    if (bh, bw) != (h, w):
        image = np.pad(image, ((0, bh - h), (0, bw - w), (0, 0)), mode="edge")
    rows, cols = bh // 4, bw // 4
    return image.reshape(rows, 4, cols, 4, 3).transpose(0, 2, 1, 3, 4).reshape(rows * cols, 16, 3), rows, cols


def to565(colours):
    c = np.clip(np.rint(colours * np.array([31 / 255, 63 / 255, 31 / 255])), 0, [31, 63, 31]).astype(np.uint32)
    return (c[..., 0] << 11) | (c[..., 1] << 5) | c[..., 2]


def from565(packed):
    r = (packed >> 11) & 31
    g = (packed >> 5) & 63
    b = packed & 31
    return np.stack([(r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)], axis=-1).astype(np.float32)


# How much of the first colour each of the four is: 0 is the first, 1 the second, 2 and 3 between
WEIGHTS = np.array([1, 0, 2 / 3, 1 / 3], np.float32)


def palettes(c0, c1):
    w = WEIGHTS[None, :, None]
    return c0[:, None, :] * w + c1[:, None, :] * (1 - w)


def nearest(pixels, palette):
    distance = ((pixels[:, :, None, :] - palette[:, None, :, :]) ** 2).sum(axis=-1)
    return distance.argmin(axis=-1)


def encode_chunk(pixels):
    n = pixels.shape[0]
    mean = pixels.mean(axis=1)
    centred = pixels - mean[:, None, :]
    # The main axis, by a few rounds of the power method on each block's covariance
    cov = np.einsum("npi,npj->nij", centred, centred)
    axis = np.ones((n, 3), np.float32) / np.sqrt(3)
    for _ in range(8):
        axis = np.einsum("nij,nj->ni", cov, axis)
        axis /= np.maximum(np.linalg.norm(axis, axis=1, keepdims=True), 1e-12)
    along = np.einsum("npi,ni->np", centred, axis)
    c0 = np.clip(mean + along.max(axis=1)[:, None] * axis, 0, 255)
    c1 = np.clip(mean + along.min(axis=1)[:, None] * axis, 0, 255)
    for _ in range(REFINE):
        q0, q1 = from565(to565(c0)), from565(to565(c1))
        index = nearest(pixels, palettes(q0, q1))
        # Least squares for the two colours, given which of the four each pixel is
        a = WEIGHTS[index]
        b = 1 - a
        aa, bb, ab = (a * a).sum(1), (b * b).sum(1), (a * b).sum(1)
        ap = (a[..., None] * pixels).sum(1)
        bp = (b[..., None] * pixels).sum(1)
        det = aa * bb - ab * ab
        ok = np.abs(det) > 1e-6
        safe = np.where(ok, det, 1)[:, None]
        n0 = (bb[:, None] * ap - ab[:, None] * bp) / safe
        n1 = (aa[:, None] * bp - ab[:, None] * ap) / safe
        c0 = np.where(ok[:, None], np.clip(n0, 0, 255), c0)
        c1 = np.where(ok[:, None], np.clip(n1, 0, 255), c1)
    p0, p1 = to565(c0), to565(c1)
    index = nearest(pixels, palettes(from565(p0), from565(p1)))
    # Four colours only when the first is the greater, else the client reads three and black:
    # swapped round where it isn't, and where the two are one colour every pixel is the first
    swap = p0 < p1
    p0, p1 = np.where(swap, p1, p0), np.where(swap, p0, p1)
    index = np.where(swap[:, None], np.array([1, 0, 3, 2])[index], index)
    index = np.where((p0 == p1)[:, None], 0, index)
    bits = (index.astype(np.uint32) << (2 * np.arange(16, dtype=np.uint32))).sum(axis=1).astype(np.uint32)
    out = np.zeros((n, 8), np.uint8)
    out[:, 0:2] = p0.astype("<u2").view(np.uint8).reshape(n, 2)
    out[:, 2:4] = p1.astype("<u2").view(np.uint8).reshape(n, 2)
    out[:, 4:8] = bits.astype("<u4").view(np.uint8).reshape(n, 4)
    return out


def dxt1(image):
    pixels, _, _ = blocks_of(image)
    parts = [encode_chunk(pixels[i:i + CHUNK]) for i in range(0, len(pixels), CHUNK)]
    return np.concatenate(parts).tobytes()


def write_blp(path, rgb):
    """Writes an RGB picture (height x width x 3, uint8, both powers of two) as a BLP2 in DXT1,
    with every smaller size of it"""
    rgb = np.asarray(rgb)
    h, w = rgb.shape[:2]
    assert rgb.ndim == 3 and rgb.shape[2] == 3, "RGB only"
    assert w & (w - 1) == 0 and h & (h - 1) == 0, f"{w} x {h} isn't a power of two each way"
    levels = [dxt1(level) for level in mips(rgb)][:16]
    offsets, sizes, at = [], [], DATA_START
    for data in levels:
        offsets.append(at)
        sizes.append(len(data))
        at += len(data)
    offsets += [0] * (16 - len(offsets))
    sizes += [0] * (16 - len(sizes))
    header = HEADER.pack(b"BLP2", 1, 2, 0, 0, 1, w, h, *offsets, *sizes)
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as out:
        out.write(header)
        out.write(bytes(PALETTE_BYTES))
        for data in levels:
            out.write(data)


def decode_dxt1(data, w, h):
    bw, bh = max(1, (w + 3) // 4), max(1, (h + 3) // 4)
    raw = np.frombuffer(data, np.uint8)[:bw * bh * 8].reshape(-1, 8)
    p0 = raw[:, 0:2].copy().view("<u2")[:, 0].astype(np.uint32)
    p1 = raw[:, 2:4].copy().view("<u2")[:, 0].astype(np.uint32)
    bits = raw[:, 4:8].copy().view("<u4")[:, 0].astype(np.uint32)
    c0, c1 = from565(p0), from565(p1)
    four = (p0 > p1)[:, None]
    third = np.where(four, (2 * c0 + c1) / 3, (c0 + c1) / 2)
    last = np.where(four, (c0 + 2 * c1) / 3, 0)
    palette = np.stack([c0, c1, third, last], axis=1)
    index = (bits[:, None] >> (2 * np.arange(16, dtype=np.uint32))) & 3
    pixels = np.take_along_axis(palette, index[..., None].astype(np.int64).repeat(3, axis=2), axis=1)
    image = pixels.reshape(bh, bw, 4, 4, 3).transpose(0, 2, 1, 3, 4).reshape(bh * 4, bw * 4, 3)
    return np.clip(np.rint(image[:h, :w]), 0, 255).astype(np.uint8)


def read_blp(path):
    """The header's fields and the whole-size picture of a BLP2 in DXT1, as RGB"""
    data = Path(path).read_bytes()
    fields = HEADER.unpack_from(data)
    magic, version, encoding, alpha_depth, alpha_type, has_mips, w, h = fields[:8]
    offsets, sizes = fields[8:24], fields[24:40]
    header = {"magic": magic, "version": version, "encoding": encoding, "alphaDepth": alpha_depth,
              "alphaType": alpha_type, "hasMips": has_mips, "width": w, "height": h,
              "offsets": offsets, "sizes": sizes}
    assert magic == b"BLP2" and encoding == 2 and alpha_type == 0, f"not a BLP2 in DXT1: {header}"
    return header, decode_dxt1(data[offsets[0]:offsets[0] + sizes[0]], w, h)


def psnr(a, b):
    mse = float(((a.astype(np.float64) - b.astype(np.float64)) ** 2).mean())
    return float("inf") if mse == 0 else 10 * np.log10(255 ** 2 / mse)


def main():
    from PIL import Image

    args = sys.argv[1:]
    if len(args) >= 2 and args[0] == "--check":
        import tempfile
        import time

        source = np.asarray(Image.open(args[1]).convert("RGB"))
        out = Path(tempfile.gettempdir()) / "blp_check.blp"
        began = time.time()
        write_blp(out, source)
        spent = time.time() - began
        header, decoded = read_blp(out)
        print(f"{args[1]}: {source.shape[1]} x {source.shape[0]}, {Path(args[1]).stat().st_size} bytes ->"
              f" {out.stat().st_size} bytes of BLP in {spent:.1f} s, {sum(1 for s in header['sizes'] if s)} sizes,"
              f" PSNR {psnr(source, decoded):.2f} dB")
        if len(args) >= 3:
            Image.fromarray(decoded).save(args[2])
        return
    if len(args) != 2:
        sys.exit(__doc__)
    write_blp(args[1], np.asarray(Image.open(args[0]).convert("RGB")))


if __name__ == "__main__":
    main()
