# Making a character or outfit

How the sprites in `Resources/` were made, written so it works for other characters too (claude-bili uses the same art). The result is a folder of 600 px tall transparent PNGs, one per `Pose`, that drops into `Resources/Characters/<name>/` or "Add Character…".

```
original art ──(1) 3 heads tall──(2) pixelize──┐
                                               ├─(4) cutout ─(5) face frames ─(6) check in the app
base sprite ──────(3) change the outfit────────┘
base sprite ──────(7) full-body poses ── cutout ── fit to closed.png ──┘
```

Steps 1 to 3 use `qwen-image-3.0` through DashScope (`gen/aliyun_img.py` in claude-bili, key in `~/.config/claude-bili/keys.env`; never print or commit it). Steps 4, 5 and 7 use scripts in `tools/` (Python 3 with Pillow, NumPy, SciPy; `fit_frame.py` also OpenCV). The art and everything made from it is ZipZipPipe's, CC BY-NC-SA 4.0: no commercial use, keep the credit.

## 1. Three heads tall (new character only)

Input: the original standing art flattened onto **pure white**, as JPG. Change the proportions first and pixelize second, never the other way round.

```
把这个角色重新绘制成约三头身的Q版比例（头部较大，全身高度约为三个头长），保持同样的动漫插画画风和线稿质感，不要做成像素风。完整保留全部服装与细节：【角色描述，含表情】。全身站姿，正面略侧，纯白色背景，不要文字。
```
negative: `像素风, 模糊, 低质量, 文字, 水印, 写实, 改变服装, 改变发色, 张嘴`

The character description lists everything from top to bottom: hair, eyes, expression, headwear, accessories, clothes, what each hand holds, shoes. Anything not named tends to get dropped. **Ask for a closed mouth and a calm face**: this image becomes `closed.png`, and every other frame is derived from it. Run it twice and pick one.

## 2. Pixelize

Halve the step 1 result (LANCZOS, JPG q93) so the pixels come out coarser, then:

```
把这个角色转换成高分辨率的像素画（pixel art）风格立绘。保持角色的姿势、三头身比例、表情和构图完全不变，保留全部服装细节：【角色描述，可不含表情】。清晰锐利的像素边缘，有限调色板，像素级的明暗与高光，纯白色背景，不要文字。
```
negative: `模糊, 低质量, 文字, 水印, 写实, 改变服装, 改变发色, 改变比例`

## 3. Change the outfit

Input: the pixel base sprite on white (halved, JPG). Only the clothes change; the face, hair and pose must stay put so step 5 can find the face.

```
把角色的服装换成【季节/主题】：【衣服，从上到下】。只修改服装，其他全部保持不变：同一个角色的脸、【发型发色】、【眼睛】、【表情】、【发饰】、三头身比例、站姿、构图、手里拿着书，保持高分辨率像素画（pixel art）风格和清晰的像素边缘，纯白色背景，不要文字。
```
negative: `改变脸, 改变发型, 改变发色, 改变表情, 改变姿势, 改变比例, 写实, 模糊, 文字, 水印`

Used so far for Claude:
- Summer: 白色无袖连衣裙，橘色腰带，草编凉鞋，可以戴一顶带向日葵的草帽
- Winter: 奶白色的毛绒短大衣，橘色格纹围巾，深棕色连裤袜和棕色短靴. The hat came from a second edit on that result: 只添加帽子 (白色毛皮方筒帽, sunflower kept on its side), followed by the same "其他全部保持不变" list.
- Pajamas (rejected): 宽松的奶白色带橘色小向日葵图案的长袖睡衣套装，毛绒拖鞋

One thing per edit works better than everything at once (outfit first, then the hat). Make two variants and pick one. Two requests in parallel are fine; more get rate-limited.

## 4. Cut out

```sh
python3 tools/cutout.py outfit.png "Resources/Characters/Claude (Summer)/closed.png" --height 600 --preview check.png
python3 tools/defringe.py closed.png closed.png --face y0:y1,x0:x1     # if white chips stay between hair strands
```

Look at `check.png` (dark background). White clothes or a white hat without a dark outline get eaten at the default threshold; use `--white 246` (both Claude outfits needed it).

## 5. Face frames

```sh
python3 tools/face_frames.py "Resources/Characters/Claude (Summer)/closed.png" --preview sheet.png
```

This writes the eight other frames (talking, blinking, read, yawn, smile, surprised) next to `closed.png` by matching the outfit's face to the reference set (`Resources/`, Claude's own frames) and pasting each frame's eyes and mouth onto it. It prints the scale and offset it found and the mean difference; Claude's outfits matched at about 17 to 20. Check `sheet.png`: the first face is the outfit's own, the others should line up with it without seams.

For a different character, make its reference set first (a closed-mouth `closed.png` and the other frames, which must differ from it only in the face), then pass `--ref` and `--regions` with ellipses around its eyes and mouth in reference pixels.

## 6. Check

Put the folder in `Resources/Characters/` (built in, run `./build.sh`) or use "Add Character…", pick it in the Character menu, and watch it talk, blink and idle. Without the step 5 frames a character still works but never moves its face.

## 7. Full-body poses

`sleep.png`, `work.png` and `stretch.png` change the arms and the head, so they are generated, not pasted. Edit the white-background image that `closed.png` was cut from (for Claude: the pixel base sprite, halved), **padded with white above the head and on both sides** (Claude: 320 px above, 200 px each side on the 880×1176 image). Without that room the model makes space for the arms and the book by shrinking or narrowing the figure. One pose per request, two variants each:

```
只修改姿势和表情：【姿势】。其他全部保持不变：同一个角色的脸、【发型发色】、【发饰、耳坠】、全部服装（【衣服，从上到下】）、三头身比例、人物在画面中的大小、宽度和位置（双脚位置不变，伸出的手臂和书伸进周围的空白处），保持高分辨率像素画（pixel art）风格和清晰的像素边缘，纯白色背景，不要文字。
```
negative: `改变脸, 改变发型, 改变发色, 改变服装, 改变比例, 缩小人物, 人物变瘦, 写实, 模糊, 文字, 水印, 多余的手, 多余的手指`

Poses used for Claude:
- sleep: 角色站着打瞌睡，头微微向一侧低垂，双眼轻轻闭合，嘴巴闭合，表情安详，双手把书抱在胸前
- work: 角色低头专注地看着摊开的书，一只手托着打开的书，另一只手拿着羽毛笔在书页上写字，嘴巴闭合，表情认真平静. The model keeps her eyes on the viewer anyway, so `read.png`'s downcast eyes are pasted on afterwards (below).
- stretch: 角色双臂举过头顶伸懒腰，书拿在举起的一只手里，双眼闭合，嘴巴微张像在打哈欠，表情放松

Then cut out, clean the hair gaps at full resolution, line up with `closed.png`:

```sh
python3 tools/cutout.py work_raw.png work_cut.png --white 246
python3 tools/fit_frame.py Resources/closed.png work_cut.png work.png --preview check.png   # also prints the face box for the next line
python3 tools/defringe.py work_cut.png work_cut.png --face <printed box>
python3 tools/fit_frame.py Resources/closed.png work_cut.png work.png --preview check.png
python3 tools/face_frames.py work.png --only read --fit 1,<ext>,<top> --out tmp/ && mv tmp/read.png Resources/work.png
```

Clean before scaling down: at 600 px the leftover white blends into light orange and defringe no longer sees it. `cutout.py` gives the soft edge the colour of the solid pixels next to it (otherwise the background's white stays in it as a rim around the hair) and removes enclosed white gaps of any size that sit in hair.

`fit_frame.py` finds the head mark (`--mark`, Claude's sunflower by default) and the soles, scales the pose so the distance between them matches `closed.png`, and puts the soles and the middle of the feet where `closed.png` has them. It prints the mark's match: much above 40 means it wasn't found (it happened once, on a stretch variant; use the other one). `check.png` shows `closed.png` faintly over the pose: head and shoes should sit on it. `ext` and `top` are how much the canvas grew on each side and on top (`(width − 359) / 2` and `height − 600` for Claude); `--fit` tells face_frames the face is already in place.

Lining up on the source image instead (assuming the edit keeps the layout) worked only without padding, and matching on the skirt hem, shoes or head colours alone was unreliable: each edit redraws them a little differently.

Check the result on magenta and on near-black: white left between hair strands is easy to miss on dark grey, and a white rim shows on a dark desktop.
