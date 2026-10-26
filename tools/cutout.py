"""Cut a sprite out of its plain white background and crop it to the character.
Background is near-white connected to the image border, plus enclosed white gaps (between hair strands, under an arm)
whose surroundings are not white cloth. Specks left outside the character are dropped.
Usage: python3 cutout.py in.png out.png [--white 232] [--min-gap 4000] [--height 600] [--preview p.png]
  --white    how white a pixel must be (min channel) to count as background. Raise it (246) for white clothes or hats
             that lack a dark outline, or the cutout eats into them.
  --min-gap  smallest enclosed white area (px) treated as background
  --height   scale the result to this height (sprites ship at 600 px)"""
import argparse, numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage

ap = argparse.ArgumentParser()
ap.add_argument("src"); ap.add_argument("out")
ap.add_argument("--white", type=int, default=232); ap.add_argument("--min-gap", type=int, default=4000)
ap.add_argument("--height", type=int); ap.add_argument("--preview")
args = ap.parse_args()

im = Image.open(args.src).convert("RGB")
a = np.asarray(im).astype(np.int16)
lab, n = ndimage.label((a.min(axis=2) > args.white) & ((a.max(axis=2) - a.min(axis=2)) < 18))
border = set(np.unique(np.concatenate([lab[0], lab[-1], lab[:, 0], lab[:, -1]]))) - {0}
bg = np.isin(lab, list(border))
cloth = (a.min(axis=2) > 170) & ((a.max(axis=2) - a.min(axis=2)) < 45)
sizes = ndimage.sum(np.ones_like(lab), lab, index=np.arange(n + 1))
for i, sl in enumerate(ndimage.find_objects(lab), start=1):
    if i in border or sizes[i] < args.min_gap: continue
    ys, xs = slice(max(sl[0].start - 18, 0), sl[0].stop + 18), slice(max(sl[1].start - 18, 0), sl[1].stop + 18)
    comp = lab[ys, xs] == i
    ring = ndimage.binary_dilation(comp, iterations=16) & ~ndimage.binary_dilation(comp, iterations=2)
    if cloth[ys, xs][ring].mean() < 0.25: bg[ys, xs] |= comp
bg = ndimage.binary_opening(bg, iterations=2)
fg, m = ndimage.label(~bg)
keep = ndimage.sum(np.ones_like(fg), fg, index=np.arange(1, m + 1))
bg |= ~np.isin(fg, 1 + np.flatnonzero(keep >= keep.max() * 0.01))   # specks off the character would stretch the crop
alpha = Image.fromarray((~bg).astype(np.uint8) * 255).filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(1.2))
rgba = im.copy(); rgba.putalpha(alpha)
rgba = rgba.crop(Image.fromarray(np.asarray(alpha) > 8).getbbox())
if args.height: rgba = rgba.resize((round(rgba.width * args.height / rgba.height), args.height), Image.LANCZOS)
rgba.save(args.out); print("wrote", args.out, rgba.size)
if args.preview:
    p = Image.new("RGBA", rgba.size, (40, 44, 60, 255)); p.alpha_composite(rgba); p.convert("RGB").save(args.preview)
