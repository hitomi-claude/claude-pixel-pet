"""Cut a sprite out of its plain white background and crop it to the character.
Background is near-white connected to the image border, plus enclosed white gaps: big ones (under an arm) whose
surroundings are not white cloth, and gaps of any size between hair strands (surrounded mostly by hair, or partly by
hair and not by white cloth, like a gap between a strand and the skirt's outline). Specks left outside the character are dropped.
Usage: python3 cutout.py in.png out.png [--white 232] [--min-gap 4000] [--height 600] [--bg X,Y ...] [--preview p.png]
  --white    how white a pixel must be (min channel) to count as background. Raise it (246) for white clothes or hats
             that lack a dark outline, or the cutout eats into them.
  --min-gap  smallest enclosed white area (px) treated as background unless it sits in hair
  --height   scale the result to this height (sprites ship at 600 px)
  --bg       a point (in the input image) inside a white pocket that is background but the rules keep, for example a thin
             sliver beside a strand of hair that sits near white cloth. Repeat it for each pocket. `--list-gaps` prints the
             pockets that are kept, with a point inside each (pockets under 150 px are never removed or listed)."""
import argparse, numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage

ap = argparse.ArgumentParser()
ap.add_argument("src"); ap.add_argument("out")
ap.add_argument("--white", type=int, default=232); ap.add_argument("--min-gap", type=int, default=4000)
ap.add_argument("--height", type=int); ap.add_argument("--preview")
ap.add_argument("--bg", action="append", default=[], metavar="X,Y", type=lambda s: tuple(map(int, s.split(",")))); ap.add_argument("--list-gaps", action="store_true")
args = ap.parse_args()

im = Image.open(args.src).convert("RGB")
a = np.asarray(im).astype(np.int16)
lab, n = ndimage.label((a.min(axis=2) > args.white) & ((a.max(axis=2) - a.min(axis=2)) < 18))
border = set(np.unique(np.concatenate([lab[0], lab[-1], lab[:, 0], lab[:, -1]]))) - {0}
bg = np.isin(lab, list(border))
cloth = (a.min(axis=2) > 170) & ((a.max(axis=2) - a.min(axis=2)) < 45)
hair = (a[..., 0] - a[..., 2] > 90) & (a[..., 0] > 150)   # same orange as defringe.py
sizes = np.bincount(lab.ravel())
for i, sl in enumerate(ndimage.find_objects(lab), start=1):
    if i in border or sizes[i] < 150: continue
    ys, xs = slice(max(sl[0].start - 18, 0), sl[0].stop + 18), slice(max(sl[1].start - 18, 0), sl[1].stop + 18)
    comp = lab[ys, xs] == i
    ring = ndimage.binary_dilation(comp, iterations=16) & ~ndimage.binary_dilation(comp, iterations=2)
    near = ring & ~bg[ys, xs]   # what it touches besides background
    h = hair[ys, xs][near].mean() if near.any() else 0; c = cloth[ys, xs][ring].mean()
    if h > 0.5 or c < 0.25 and (sizes[i] >= args.min_gap or h > 0.35): bg[ys, xs] |= comp
    elif args.list_gaps:
        y, x = np.unravel_index(ndimage.distance_transform_edt(comp).argmax(), comp.shape)   # the deepest point: surely inside
        print(f"kept: {sizes[i]} px, hair {h:.2f}, cloth {c:.2f}; --bg {x + xs.start},{y + ys.start}")
for x, y in args.bg:
    if not (0 <= x < lab.shape[1] and 0 <= y < lab.shape[0]) or lab[y, x] == 0 or lab[y, x] in border: raise SystemExit(f"--bg {x},{y}: that point is not in an enclosed white pocket")
    bg |= lab == lab[y, x]
bg = ndimage.binary_opening(bg, iterations=2)
fg, m = ndimage.label(~bg)
keep = np.bincount(fg.ravel())[1:]
bg |= ~np.isin(fg, 1 + np.flatnonzero(keep >= keep.max() * 0.01))   # specks off the character would stretch the crop
alpha = Image.fromarray((~bg).astype(np.uint8) * 255).filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(1.2))
# the soft edge keeps the background's white in its colour, a white rim on a dark desktop: give every pixel that isn't
# solid the colour of the nearest solid one a few pixels inside the edge
core = ndimage.binary_erosion(np.asarray(alpha) == 255, iterations=3)
_, (iy, ix) = ndimage.distance_transform_edt(~core, return_indices=True)
rgba = Image.fromarray(np.where(core[..., None], a, a[iy, ix]).astype(np.uint8)); rgba.putalpha(alpha)
rgba = rgba.crop(Image.fromarray(np.asarray(alpha) > 8).getbbox())
if args.height: rgba = rgba.resize((round(rgba.width * args.height / rgba.height), args.height), Image.LANCZOS)
rgba.save(args.out); print("wrote", args.out, rgba.size)
if args.preview:
    p = Image.new("RGBA", rgba.size, (40, 44, 60, 255)); p.alpha_composite(rgba); p.convert("RGB").save(args.preview)
