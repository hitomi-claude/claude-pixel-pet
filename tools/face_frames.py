"""Give a new outfit every expression frame by moving the eyes and mouth over from a reference set.
The reference set is a folder of PNGs that differ from its closed.png only in the face (Resources/ for Claude). The new
outfit's face is found by matching (scale and offset), then each eye or mouth area that the frame changes is pasted on
whole, with a soft edge. Whole, not just the changed pixels: the outfit's own eye is never exactly where the reference
one is, and the bits of it left next to a closed lid smear. Hair and clothes around the face stay the outfit's own.
Usage: python3 face_frames.py outfit/closed.png [--ref Resources] [--out outfit/] [--only read,yawn] [--regions ...] [--preview sheet.png]
  --only     make just these frames (default: all seven face frames; e.g. the eyes looking down from read.png onto a
             full-body pose, written as read.png)
  --regions  eye and mouth ellipses in reference pixels, "x0,y0,x1,y1;..." (default: Claude's left eye, right eye, mouth)
  --fit      skip matching and use "scale,dx,dy" (reference point (x, y) lands on ((x + dx) * scale, (y + dy) * scale))"""
import argparse
from pathlib import Path
import cv2, numpy as np
from PIL import Image, ImageDraw, ImageFilter

ap = argparse.ArgumentParser()
ap.add_argument("outfit"); ap.add_argument("--ref", default=str(Path(__file__).parent.parent / "Resources"))
ap.add_argument("--out"); ap.add_argument("--regions", default="120,106,158,136;168,98,208,131;150,136,180,162")
ap.add_argument("--fit"); ap.add_argument("--only"); ap.add_argument("--preview")
args = ap.parse_args()

ref = Path(args.ref); out = Path(args.out or Path(args.outfit).parent)
base = Image.open(ref / "closed.png").convert("RGBA")
outfit = Image.open(args.outfit).convert("RGBA")
boxes = [tuple(map(int, r.split(","))) for r in args.regions.split(";")]
face = (min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes))
only = (args.only or "half,open,blink_half,blink_closed,read,yawn,surprised").split(",")   # not the full-body poses

ref_rgb = np.asarray(base.convert("RGB")).astype(np.float32)
def match(img, tpl, x, y, r):
    """Best place for tpl in img within r px of (x, y): (squared error, x, y)."""
    x0, y0 = max(0, x - r), max(0, y - r)
    win = img[y0:y + tpl.shape[0] + r, x0:x + tpl.shape[1] + r]
    if win.shape[0] < tpl.shape[0] or win.shape[1] < tpl.shape[1]: return None
    e, _, (mx, my), _ = cv2.minMaxLoc(cv2.matchTemplate(win, tpl, cv2.TM_SQDIFF))
    return e, x0 + mx, y0 + my
def shrunk(s): return np.asarray(outfit.convert("RGB").resize((round(outfit.width / s), round(outfit.height / s)), Image.LANCZOS)).astype(np.float32)

def fit():
    """Scale and offset that best lay the reference face over the outfit's: the face matched within 60 px of where it
    is in the reference."""
    tpl, best = ref_rgb[face[1]:face[3], face[0]:face[2]], None
    for s in outfit.height / base.height * np.arange(0.85, 1.155, 0.01):
        m = match(shrunk(s), tpl, face[0], face[1], 60)
        if m and (best is None or m[0] < best[0]): best = (m[0], s, m[1] - face[0], m[2] - face[1])
    e, s, dx, dy = best
    print(f"fit: scale {s:.2f}, offset {dx},{dy} (rms {np.sqrt(e / tpl.size):.0f}; above ~45 the faces probably differ too much)")
    return s, dx, dy

s, dx, dy = map(float, args.fit.split(",")) if args.fit else fit()
def ellipse(b):
    im = Image.new("L", base.size, 0); ImageDraw.Draw(im).ellipse(b, fill=255); return np.asarray(im) > 0
areas = [ellipse(b) for b in boxes]
B = np.asarray(base).astype(int)
size = (round(base.width * s), round(base.height * s))
masks = [Image.fromarray((a * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1)).resize(size, Image.BILINEAR) for a in areas]
# each eye and the mouth sit a little differently on every outfit: line each area up on its own, within 8 px
def nudge(img, b):
    m = match(img, ref_rgb[b[1]:b[3], b[0]:b[2]], round(b[0] + dx), round(b[1] + dy), 8)
    return (m[1] - round(b[0] + dx), m[2] - round(b[1] + dy)) if m else (0, 0)
if args.fit: shifts = [(0, 0)] * len(boxes)
else: img = shrunk(s); shifts = [nudge(img, b) for b in boxes]; print("per-area nudge", shifts)
view = tuple(round(v) for v in ((face[0] + dx - 25) * s, (face[1] + dy - 15) * s, (face[2] + dx + 25) * s, (face[3] + dy + 25) * s))
sheet = [outfit.crop(view)]
for png in sorted(ref.glob("*.png")):
    if png.stem not in only: continue
    pose = Image.open(png).convert("RGBA")
    changed = np.abs(np.asarray(pose).astype(int) - B).sum(2) > 40
    frame, scaled = outfit, pose.resize(size, Image.NEAREST)
    for a, mask, (ox, oy) in zip(areas, masks, shifts):
        if (changed & a).sum() <= 6: continue
        at = (round((dx + ox) * s), round((dy + oy) * s))
        layer, m = Image.new("RGBA", outfit.size), Image.new("L", outfit.size, 0)
        layer.paste(scaled, at); m.paste(mask, at)
        frame = Image.composite(layer, frame, m)
    frame.save(out / png.name); sheet.append(frame.crop(view))
    print("wrote", out / png.name)
if args.preview:
    w, h = sheet[0].size; im = Image.new("RGBA", (w * len(sheet), h), (200, 200, 200, 255))
    for i, f in enumerate(sheet): im.alpha_composite(f, (i * w, 0))
    im.resize((im.width * 2, im.height * 2), Image.NEAREST).save(args.preview)
