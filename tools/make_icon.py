"""Build Resources/AppIcon.icns from a character sprite: head and shoulders on a rounded navy plate, laid out on
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

W, inset, radius = 1024, 100, 185
size = W - 2 * inset
top, bottom = np.array([52, 58, 86, 255]), np.array([24, 27, 44, 255])   # navy, like the channel's video backgrounds
g = np.linspace(0, 1, size)[:, None, None]
plate = Image.fromarray(np.broadcast_to(top * (1 - g) + bottom * g, (size, size, 4)).astype(np.uint8))
art = head.resize((round(size * .96),) * 2, Image.LANCZOS)
plate.alpha_composite(art, ((size - art.width) // 2, size - art.height))   # sits on the bottom edge
mask = Image.new("L", (size, size), 0); ImageDraw.Draw(mask).rounded_rectangle((0, 0, size - 1, size - 1), radius, fill=255)
icon = Image.new("RGBA", (W, W), (0, 0, 0, 0)); icon.paste(plate, (inset, inset), mask)
if args.png: icon.save(args.png)

with tempfile.TemporaryDirectory() as tmp:
    iconset = Path(tmp) / "AppIcon.iconset"; iconset.mkdir()
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            icon.resize((pt * scale,) * 2, Image.LANCZOS).save(iconset / f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png")
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", args.out], check=True)
print("wrote", args.out)
