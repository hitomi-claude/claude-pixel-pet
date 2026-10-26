"""Scale and place a new full-body pose so it lines up with closed.png.
Two anchors that a pose redraws least: a rigid mark on the head (Claude's sunflower) and the soles. The mark is found
by template matching, the soles are the lowest opaque row; the pose is scaled so mark-to-soles matches closed.png,
then moved so the soles and the middle of the feet match. Image edits don't keep the figure's size or place (more so
with a padded source), so nothing here relies on the source image.
A pose that reaches past closed.png (raised arms) grows the canvas upwards and equally to both sides, so the bottom
edge and the horizontal centre stay those of closed.png: that is how the app lines frames up.
Usage: python3 fit_frame.py closed.png pose_cut.png out.png [--mark 200,27,258,85] [--face 100:165,118:212] [--preview p.png]
  pose_cut.png  the pose cut out with tools/cutout.py (full resolution)
  --mark        box around the head mark in closed.png pixels (default: Claude's sunflower)
  --face        eyes-and-mouth box in closed.png pixels; printed back in pose_cut.png pixels for defringe.py --face"""
import argparse
import cv2, numpy as np
from PIL import Image

ap = argparse.ArgumentParser()
ap.add_argument("closed"); ap.add_argument("pose"); ap.add_argument("out")
ap.add_argument("--mark", default="200,27,258,85"); ap.add_argument("--face", default="100:165,118:212"); ap.add_argument("--preview")
args = ap.parse_args()

def flat(im):   # RGBA over grey
    a = np.asarray(im).astype(np.float32); return a[..., :3] * a[..., 3:] / 255 + 128 * (1 - a[..., 3:] / 255)
def feet(im):   # (soles y, middle of the feet x): the lowest opaque row and the opaque pixels just above it
    a = np.asarray(im.getchannel("A")) > 128; y = np.nonzero(a.any(1))[0].max()
    return y, np.nonzero(a[y - round(im.height * 0.03):y + 1])[1].mean()

base, pose = Image.open(args.closed).convert("RGBA"), Image.open(args.pose).convert("RGBA")
box = pose.getchannel("A").point(lambda v: 255 * (v > 128)).getbbox(); pose = pose.crop(box)
W, H = base.size
m = tuple(map(int, args.mark.split(",")))
tpl, (cy, cx) = flat(base.crop(m)), feet(base)
best = None
for s in H / pose.height * np.arange(0.75, 1.45, 0.005):   # raised arms make the pose taller than closed.png
    q = pose.resize((round(pose.width * s), round(pose.height * s)), Image.LANCZOS); img = flat(q)
    if img.shape[0] < tpl.shape[0] or img.shape[1] < tpl.shape[1]: continue
    e, _, (_, my), _ = cv2.minMaxLoc(cv2.matchTemplate(img, tpl, cv2.TM_SQDIFF))
    if best is None or e < best[0]: best = (e, s, my, q)
e, s, my, q = best
py, _ = feet(q)
k = s * (cy - m[1]) / (py - my)   # mark top to soles, as in closed.png
p = pose.resize((round(pose.width * k), round(pose.height * k)), Image.LANCZOS)
py, px = feet(p)
ax, ay = round(cx - px), round(cy - py)   # pose pixel (0, 0) lands here on closed.png
print(f"scale {k:.4f} (mark rms {np.sqrt(e / tpl.size):.0f}; much above 40 means the mark wasn't found), at {ax},{ay}")
(fy0, fy1), (fx0, fx1) = [map(int, r.split(":")) for r in args.face.split(",")]
back = lambda v, a, o: round((v - a) / k + o)   # closed.png pixel -> pose_cut.png pixel
print(f"face in pose_cut.png: --face {back(fy0, ay, box[1])}:{back(fy1, ay, box[1])},{back(fx0, ax, box[0])}:{back(fx1, ax, box[0])}")
x0, y0, x1, y1 = p.getbbox(); y1 = min(y1, H - ay)
ext = max(0, -(ax + x0), ax + x1 - W)   # same on both sides keeps the centre
top = max(0, -(ay + y0))
out = Image.new("RGBA", (W + 2 * ext, H + top))
out.alpha_composite(p.crop((x0, y0, x1, y1)), (ax + x0 + ext, ay + y0 + top))
out.save(args.out); print("wrote", args.out, out.size)
if args.preview:   # closed.png faintly over the new frame
    pv = Image.new("RGBA", out.size, (40, 44, 60, 255)); pv.alpha_composite(out)
    ghost = base.copy(); ghost.putalpha(base.getchannel("A").point(lambda v: v * 0.45)); pv.alpha_composite(ghost, (ext, top))
    pv.convert("RGB").save(args.preview)
