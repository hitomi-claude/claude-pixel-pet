# Making a character or outfit

How the sprites in `Resources/` were made, written so it works for other characters too (claude-bili uses the same art). The result is a folder of 600 px tall transparent PNGs, one per `Pose`, that drops into `Resources/Characters/<name>/` or "Add Character…".

```
original art ──(1) 3 heads tall──(2) pixelize──┐
                                               ├─(4) cutout ─(5) face frames ─(6) check in the app
base sprite ──────(3) change the outfit────────┘
```

Steps 1 to 3 use `qwen-image-3.0` through DashScope (`gen/aliyun_img.py` in claude-bili, key in `~/.config/claude-bili/keys.env`; never print or commit it). Steps 4 and 5 are scripts in `tools/` (Python 3 with Pillow, NumPy, SciPy). The art and everything made from it is ZipZipPipe's, CC BY-NC-SA 4.0: no commercial use, keep the credit.

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
