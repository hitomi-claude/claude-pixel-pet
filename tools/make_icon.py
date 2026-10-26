"""Build Resources/AppIcon.icns from a character sprite: head and shoulders on a rounded cream plate, laid out on
Apple's 1024 grid (100 px inset, 185 px corners), then every size from 16 to 512 @1x/@2x through iconutil.
Usage: python3 make_icon.py sprite.png [out.icns] [--png preview.png]
  sprite.png  the full-body sprite with a transparent background; use the largest version you have (the shipped
              Resources/closed.png works, a higher-resolution original is sharper). The crop is given for a
              600 px tall sprite and scales with the image."""
import argparse, subprocess, tempfile
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw

ap = argparse.ArgumentParser()
ap.add_argument("sprite"); ap.add_argument("out", nargs="?", default=str(Path(__file__).parent.parent / "Resources/AppIcon.icns"))
ap.add_argument("--png")
args = ap.parse_args()

src = Image.open(args.sprite).convert("RGBA")
k = src.height / 600
head = src.crop((round(40 * k), 0, round(320 * k), round(280 * k)))   # whole head, sunflower, ribbon, book, down to the chest

top, bottom = np.array([255, 243, 226, 255]), np.array([255, 213, 168, 255])   # cream to peach, warm like her hair

def render(W):   # the icon at W px: Apple's grid scaled from 1024 (100 px inset, 185 px corners)
    inset, radius = round(W * 100 / 1024), round(W * 185 / 1024)
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
with tempfile.TemporaryDirectory() as tmp:   # each size drawn at its own resolution: a downscaled 1024 brings the colours back
    iconset = Path(tmp) / "AppIcon.iconset"; iconset.mkdir()
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            render(pt * scale).save(iconset / f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png", optimize=True)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", args.out], check=True)
print("wrote", args.out)
