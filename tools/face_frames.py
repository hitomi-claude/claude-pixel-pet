"""Give a new outfit every expression frame by moving the eyes and mouth over from a reference set.
The reference set is a folder of PNGs that differ from its closed.png only in the face (Resources/ for Claude). The new
outfit's face is found by matching (scale and offset), then each frame's eye and mouth areas are pasted on with soft
edges. Only pixels that the frame actually changes are copied, so hair and clothes around the face stay the outfit's own.
Usage: python3 face_frames.py outfit/closed.png [--ref Resources] [--out outfit/] [--regions ...] [--preview sheet.png]
  --regions  eye and mouth ellipses in reference pixels, "x0,y0,x1,y1;..." (default: Claude's left eye, right eye, mouth)
  --fit      skip matching and use "scale,dx,dy" (reference point (x, y) lands on ((x + dx) * scale, (y + dy) * scale))"""
import argparse
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ap = argparse.ArgumentParser()
ap.add_argument("outfit"); ap.add_argument("--ref", default=str(Path(__file__).parent.parent / "Resources"))
ap.add_argument("--out"); ap.add_argument("--regions", default="123,112,154,140;172,102,203,132;152,134,178,158")
ap.add_argument("--fit"); ap.add_argument("--preview")
args = ap.parse_args()

ref = Path(args.ref); out = Path(args.out or Path(args.outfit).parent)
base = Image.open(ref / "closed.png").convert("RGBA")
outfit = Image.open(args.outfit).convert("RGBA")
boxes = [tuple(map(int, r.split(","))) for r in args.regions.split(";")]
face = (min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes))

def fit():
    """Scale and offset that best lay the reference face over the outfit's, by mean colour difference."""
    tpl = np.asarray(base.convert("RGB").crop(face)).astype(np.float32); th, tw = tpl.shape[:2]
    s0, best = outfit.height / base.height, None
    for s in s0 * np.arange(0.85, 1.155, 0.01):
        a = np.asarray(outfit.convert("RGB").resize((round(outfit.width / s), round(outfit.height / s)), Image.LANCZOS)).astype(np.float32)
        for dy in range(-60, 61):
            for dx in range(-60, 61):
                x, y = face[0] + dx, face[1] + dy
                if x < 0 or y < 0 or y + th > a.shape[0] or x + tw > a.shape[1]: continue
                e = np.abs(a[y:y + th, x:x + tw] - tpl).mean()
                if best is None or e < best[0]: best = (e, s, dx, dy)
    print(f"fit: scale {best[1]:.2f}, offset {best[2]},{best[3]} (mean diff {best[0]:.1f}; above ~25 the faces probably differ too much)")
    return best[1:]

s, dx, dy = map(float, args.fit.split(",")) if args.fit else fit()
region = Image.new("L", base.size, 0)
for b in boxes: ImageDraw.Draw(region).ellipse(b, fill=255)
B = np.asarray(base).astype(int)
size, at = (round(base.width * s), round(base.height * s)), (round(dx * s), round(dy * s))
view = tuple(round(v) for v in ((face[0] + dx - 25) * s, (face[1] + dy - 15) * s, (face[2] + dx + 25) * s, (face[3] + dy + 25) * s))
sheet = [outfit.crop(view)]
for png in sorted(ref.glob("*.png")):
    if png.name == "closed.png": continue
    pose = Image.open(png).convert("RGBA")
    if pose.size != base.size: continue
    changed = Image.fromarray(((np.abs(np.asarray(pose).astype(int) - B).sum(2) > 40) * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(7))
    mask = Image.fromarray(np.minimum(np.asarray(changed), np.asarray(region))).filter(ImageFilter.GaussianBlur(1.5))
    layer, m = Image.new("RGBA", outfit.size), Image.new("L", outfit.size, 0)
    layer.paste(pose.resize(size, Image.NEAREST), at); m.paste(mask.resize(size, Image.BILINEAR), at)
    frame = Image.composite(layer, outfit, m); frame.save(out / png.name); sheet.append(frame.crop(view))
    print("wrote", out / png.name)
if args.preview:
    w, h = sheet[0].size; im = Image.new("RGBA", (w * len(sheet), h), (200, 200, 200, 255))
    for i, f in enumerate(sheet): im.alpha_composite(f, (i * w, 0))
    im.resize((im.width * 2, im.height * 2), Image.NEAREST).save(args.preview)
