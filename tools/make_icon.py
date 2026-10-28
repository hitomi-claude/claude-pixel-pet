"""Build Resources/AppIcon.icns from a character sprite: head and shoulders on a rounded cream plate, laid out on
Apple's 1024 grid (100 px inset, 185 px corners), then every size from 16 to 512 @1x/@2x through iconutil.
Usage: python3 make_icon.py sprite.png [out.icns] [--pixel K] [--png preview.png] [--square avatar.png]
  sprite.png  the full-body sprite with a transparent background; use the largest version you have (the shipped
              Resources/closed.png works, a higher-resolution original is sharper). The crop is given for a
              600 px tall sprite and scales with the image.
  --pixel K   pixelate the sprite first, as the app's Pixel size does (K x K blocks from the bottom centre, 64 colours)
  --square    also a 1024 px square with no inset or rounded corners (a profile picture; GitHub crops it to a circle)."""
import argparse, subprocess, tempfile
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw

ap = argparse.ArgumentParser()
ap.add_argument("sprite"); ap.add_argument("out", nargs="?", default=str(Path(__file__).parent.parent / "Resources/AppIcon.icns"))
ap.add_argument("--png"); ap.add_argument("--square"); ap.add_argument("--pixel", type=int)
args = ap.parse_args()

src = Image.open(args.sprite).convert("RGBA")
if args.pixel:   # as the app's Pixelate: a block's mean, or its dark pixels' when they fill 30 % of it (outlines survive), then 64 colours
    b, (w, h) = args.pixel, src.size; ox, oy = (w // 2) % b, h % b; bw, bh = (w - ox) // b, (h - oy) // b
    a = np.asarray(src, np.float32)[oy:oy + bh * b, ox:ox + bw * b].reshape(bh, b, bw, b, 4).transpose(0, 2, 1, 3, 4).reshape(bh, bw, b * b, 4)
    rgb, al = a[..., :3], a[..., 3:] / 255
    solid = al.sum((2, 3)) > b * b / 2
    mean = (rgb * al).sum(2) / np.maximum(al.sum(2), 1e-6)
    lum = np.array([0.299, 0.587, 0.114], np.float32)
    dark = (al[..., 0] > 0.5) & ((rgb @ lum) < (mean @ lum)[..., None] - 45)
    n = dark.sum(2); dmean = (rgb * dark[..., None]).sum(2) / np.maximum(n, 1)[..., None]
    col = np.where((n >= 0.3 * b * b)[..., None], dmean, mean).clip(0, 255).astype(np.uint8)
    blocks = Image.fromarray(col).quantize(64, method=Image.Quantize.MEDIANCUT).convert("RGBA")
    blocks.putalpha(Image.fromarray(np.where(solid, 255, 0).astype(np.uint8)))
    src = Image.new("RGBA", (w, h), (0, 0, 0, 0)); src.paste(blocks.resize((bw * b, bh * b), Image.NEAREST), (ox, oy))
k = src.height / 600
cx = src.width / 2   # the head is centred on the sprite
head = src.crop((round(cx - 165 * k), round(-10 * k), round(cx + 165 * k), round(320 * k)))   # whole head, sunflower, ribbon, book, down to the chest

top, bottom = np.array([255, 243, 226, 255]), np.array([255, 213, 168, 255])   # cream to peach, warm like her hair

def render(W, square=False):   # the icon at W px: Apple's grid scaled from 1024 (100 px inset, 185 px corners)
    inset, radius = (0, 0) if square else (round(W * 100 / 1024), round(W * 185 / 1024))
    size = W - 2 * inset
    g = np.linspace(0, 1, size)[:, None, None]
    plate = Image.fromarray(np.broadcast_to(top * (1 - g) + bottom * g, (size, size, 4)).astype(np.uint8))
    art = head.resize((round(size * .96),) * 2, Image.LANCZOS)
    if W >= 64: art = art.quantize(256, method=Image.Quantize.FASTOCTREE).convert("RGBA")   # resampling leaves ~170k colours
    plate.alpha_composite(art, ((size - art.width) // 2, size - art.height))   # sits on the bottom edge
    mask = Image.new("L", (size, size), 0); ImageDraw.Draw(mask).rounded_rectangle((0, 0, size - 1, size - 1), radius, fill=255)
    icon = Image.new("RGBA", (W, W), (0, 0, 0, 0)); icon.paste(plate, (inset, inset), mask)
    return icon

if args.png: render(1024).save(args.png)
if args.square: render(1024, square=True).save(args.square)
with tempfile.TemporaryDirectory() as tmp:   # each size drawn at its own resolution: a downscaled 1024 brings the colours back
    iconset = Path(tmp) / "AppIcon.iconset"; iconset.mkdir()
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            render(pt * scale).save(iconset / f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png", optimize=True)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", args.out], check=True)
print("wrote", args.out)
