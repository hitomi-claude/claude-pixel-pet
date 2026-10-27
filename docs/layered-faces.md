# Plan: layered faces

Status: paused. Recorded 2026-10-27. Step 1 was tried: qwen removed the eyes and mouth from the standing and work heads without changing the face outline. The approach was then paused, because editing pixel-art frames with this model keeps drifting. It needs a stronger model or hand-drawn parts. The non-pixel original doesn't help directly, because it is 8 heads tall and the pet is a 3-head chibi with different face proportions.

## Why

Today every frame is a whole image. Expressions are made by pasting one image's eyes and mouth onto another (`tools/face_frames.py`), and poses are generated as whole images. This keeps producing the same three kinds of defect:

- **Leftover lids.** The pasted closed eye doesn't fully cover the open eye underneath, so its upper lid line stays above the new one and reads as wrinkles. Every outfit copied this from Claude's frames until the eyes were redrawn on a blank face.
- **Doubled or sliding eyes in poses.** Each pose puts and tilts the head differently, so eyes pasted from the standing set never line up (`work.png` on every outfit).
- **Faces drifting between poses.** A regenerated pose can change the face itself (Autumn's work pose came out with round cheeks).

## Why not Live2D

- It needs a layered source drawing (eyes, brows, mouth, each bang, back hair, arms, with the hidden parts painted in) plus days of rigging in Cubism Editor. Our tools only produce flat images, and there is no layered source for the design.
- It animates by smooth mesh deformation, which blurs pixel art. It suits a smooth anime pet, not this one.
- The Cubism SDK is C++ with a Metal renderer and its own licence; AGENTS.md keeps the app AppKit-only with no dependencies.

## The idea

Take Live2D's split into parts, keep pixel art and plain bitmaps:

```
pose body (blank face)  +  eyes part  +  mouth part   →  frame, composed at draw time
```

1. **Faceless bodies.** One per pose (closed/standing, sleep, work, stretch): the full character with no eyes and no mouth, clean skin where they go. Made with the blank-face step that fixed Claude's eyes (ask the model to remove the eyes and mouth, keep everything else).
2. **Face parts.** Small transparent PNGs, drawn on the blank standing face and cut to their area:
   - eyes: `open`, `half`, `closed`, `down` (reading/writing), `wide` (surprised), `yawn`
   - mouth: `closed`, `half`, `open`, `yawn`, `o` (surprised)
3. **Anchors.** Per pose, where the eyes and the mouth go and at what angle, in that pose's pixels. A small `face.json` next to the PNGs, written by the tool that makes the bodies.
4. **Drawing.** `PetView.draw` draws the body for the current pose, then the eyes part and the mouth part at the pose's anchors. `Pose` splits into body pose × eye state × mouth state; `play(_:_:)` sequences keep working by mapping today's poses onto those (e.g. `blink_half` = current body + `half` eyes + `closed` mouth).

## What it gets us

- No leftover lids or doubled eyes: there is nothing under the parts.
- Every pose can show every expression. Blinking or talking while writing, sleeping, stretching comes for free, where today each combination would be its own image.
- A new outfit needs only its faceless bodies; the face parts are shared per character.
- The face can't drift between poses, because it is the same parts everywhere.

## Costs and risks

- **Code:** about 20 lines in `draw()` plus the pose mapping. Folders without `face.json` keep working as whole frames, so user characters made the old way don't break.
- **Art, once:** faceless bodies for 8 characters × 4 poses, plus one set of face parts per character (the outfits share Claude's face, so probably one set overall).
- **Tilted heads.** Sleep and work tilt the head. A part rotated in pixel art gets jaggy; the anchor may need its own pre-rotated parts per pose, or those poses keep a baked face for the closed-eye states only. This is the open question to answer first.
- **Faceless generation must keep the head shape.** Same risk as Autumn's cheeks: the blank-face step can change the face outline. Check each body against its standing frame before use.

## Trial first

Do Claude only, standing and work:

1. Faceless standing body and faceless work body.
2. Eye and mouth parts from the blank standing face.
3. Anchors for both poses, by hand if needed.
4. A preview sheet composing every expression on both poses, before touching the app.

If the work pose looks natural with the shared parts (or with work-specific parts), wire it into `draw()` behind `face.json` and convert the outfits. If the tilted head can't be made to look right, keep whole frames for tilted poses and use parts only for standing.
