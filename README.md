# claude-pixel-pet

A small pixel-art Claude that lives on your macOS desktop. You can chat with it, and it keeps an eye on your Claude Code sessions.

一只住在 macOS 桌面上的像素 Claude：点它可以聊天，它也会盯着你的 Claude Code 在干什么。

<img src="docs/preview.png" width="220" alt="preview">

## Usage

| | |
|---|---|
| Click the pet | open the input box; Enter sends, Esc closes. Left empty for 30 s, it closes by itself |
| Right-click the pet | usage panel: plan limits, today's tokens, what's running |
| Drag the pet | move it; she opens there next time (clicks on the transparent area around her go through) |
| Menu-bar ✦ | Session (switch, start one in a folder, Open in Terminal), Stop, Character, Size, Pixel Size, Voice, Settings… (⌘,), Quit |

**Stop** interrupts the turn the pet is running right now, like Esc in Claude Code. The session stays attached, so you can send the next message. Sessions open in your terminal or IDE are not affected.

## What it does

- **Chat, or drive a real session.** Click the pet and type; press Enter to send and Esc to close. By default you're in "Pet chat", a session of its own with no tools. Use "Session" in the menu to attach to any recent Claude Code session, or start a new one in a folder. The pet then runs Claude Code there with its normal tools. When a tool needs approval, a card pops up above the pet's head with **Allow / Deny**. Your own permission settings still apply. "Stop" interrupts the current turn.
  Under the hood this is the same stream-json protocol the IDE extensions use: one long-lived `claude -p --input-format stream-json --output-format stream-json --permission-prompt-tool stdio` process per attached session.
  Attaching to a session that is still open in a terminal or IDE forks it: both continue from the same history.
- **Claude Code activity.** While a session is working, a small label above the pet's head shows the project and the current step (for example `my-app: Bash · Run tests`). When a task that ran for more than 20 seconds finishes, the pet tells you. With the hook below, she also tells you the moment one of those sessions asks for permission (`my-app needs your permission: Bash · Run tests`).
- **Open in Terminal** (under Session). Opens the session the pet is attached to in Terminal: it `cd`s to its directory and runs `claude --resume` for it. It is greyed out in Pet chat, which has no tools on purpose.
- **Usage.** The menu-bar ✦ shows today's output tokens. The menu breaks usage down per account (output, input including cache, number of sessions) and shows the context size of the latest session.
- **Usage panel.** Right-click the pet for a panel with your plan limits per account (5-hour and weekly, with Opus / Sonnet when your plan has them), the same percentages and reset times as `/usage` in Claude Code, plus today's tokens and what is running now. The first time, macOS asks whether ClaudePet may read Claude Code's login from the keychain; choose Always Allow.
- **Voice.** What she says types into the bubble a character at a time, about 11 a second, with a short pause at commas and sentence ends; long text speeds up so it finishes in about 5 seconds. Her mouth moves while it types. Pick the sound under Voice in Settings or the menu: **Off**, **Soft** or **8-bit**. **Soft** is a 50 ms sine on a note from C5 to A5, at most every 0.18 s (about every other Chinese character); **8-bit** is a 25% pulse on G5, slightly detuned, with a quick fade, one per character, like an old game's text box. The notes are picked from the text itself, so the same line always has the same tune.
- **Pixel animation.** She blinks every few seconds. Now and then she reads her book, and very rarely she yawns. While a Claude Code session works she mostly writes in her book with a quill. After 5 minutes with nothing going on she dozes off hugging the book; clicking her startles her awake, and a message or a new task wakes her with a big yawn, still hugging the book. When a task finishes she yawns the same way. A full-body pose stays up at least a second, so she never flickers between them. Every pose is a full frame with only the eyes and mouth changed, so nothing gets stretched.
- **Settings.** ✦ → Settings… opens one window with a live preview of the pet and: **Size** (Small, Medium, Large), **Character**, **Voice**, **Opacity** (30% to 100%, always), **Always on top**, **See-through on hover** and **Pixel size**: Off (the smooth frames), Fine (2×2 blocks), Medium (3×3) or Coarse (4×4). Everything applies at once and is remembered.
- **Characters.** Pick one under Character in the menu or in Settings: Claude, or Claude in another outfit: Spring (sakura haori), Summer (straw hat), Autumn (cardigan), Winter (white fur hat), Hoodie, Lab Coat or Librarian, each with the full set of faces and poses. Add your own with **Add Character…**: choose a folder laid out as below and it is copied into `~/Library/Application Support/ClaudePet/Characters/` ("Open Characters Folder…" shows it). Characters stay on your Mac, so art you can't share works too. The shipped characters are smooth 600 px frames; **Pixel size** turns them into pixel art when they load (blocks of 2 to 4 pixels, outlines kept, 64 colours taken from `closed.png` so talking and blinking don't flicker). It applies to every character, including ones you add; set it to Off to show their PNGs as they are.

  ```
  My Character/          the folder name is the character's name
    closed.png           required: the neutral frame, transparent background
    half.png  open.png   mouth half / fully open while talking
    blink_half.png  blink_closed.png
    read.png  yawn.png  surprised.png
    sleep.png  work.png  stretch.png    full-body poses: dozing, writing, waking up (yawning)
  ```
  Every PNG but `closed.png` is optional; a missing one shows `closed.png` (a missing sleep, work or stretch shows blink_closed, read or yawn). Face frames are the same size as `closed.png` with only the face changed, so nothing jumps. The full-body poses may be bigger (raised arms): they are drawn at the same scale with the same bottom centre. [docs/character-pipeline.md](docs/character-pipeline.md) shows how the outfits were made, including generating the faces from Claude's.
- Drag the pet to move it; she reopens where you left her. The transparent area around the character is click-through. Size (in Settings) is Small, Medium or Large. It can stay on top, shows on every desktop, and has no Dock icon. With **See-through on hover** checked she fades to 30% while the pointer is over her (and back when it leaves), so you can see what is behind; she still takes clicks.

Activity and today's tokens come from reading the local transcripts in `~/.claude/projects/**/*.jsonl`. The only network traffic is the chat, which goes through your own `claude` CLI, and, while the usage panel is open, at most one request a minute per account to `api.anthropic.com/api/oauth/usage` (the endpoint Claude Code's own `/usage` calls) with that account's login. The token is read from the keychain and not stored anywhere else. That endpoint is undocumented, so the plan limits can stop working after a Claude Code update.

## Build

Requirements: macOS 14 or later, the Xcode command line tools (`xcode-select --install`), and [Claude Code](https://docs.claude.com/en/docs/claude-code) on your `PATH` for chat.

```sh
./build.sh      # builds build/ClaudePet.app, installs it to ~/Applications and launches it
```

To start it at login, add it in System Settings → General → Login Items.

### Several Claude Code accounts

Only `~/.claude` is watched by default. If you keep more than one config dir (for example with `CLAUDE_CONFIG_DIR`), list them in order. The first one is also used for chat.

```sh
defaults write io.github.kirigirihitomi.claude-pixel-pet configDirs -array ~/.claude-personal ~/.claude
```

### Permission prompts from your terminal / IDE sessions

The transcripts don't show that a session is waiting on a permission prompt, so this needs one Claude Code hook. It appends each permission request to a file the pet watches. It prints nothing, so it never answers a request for you. The bubble goes away once the session's transcript shows the answer. Add this to `~/.claude/settings.json` (and to the `settings.json` of each other config dir); it needs `jq` (built into macOS 15 and later):

```json
"hooks": {
  "PermissionRequest": [{ "hooks": [{ "type": "command", "timeout": 5,
    "command": "mkdir -p \"$HOME/Library/Application Support/ClaudePet\" && jq -c \"{hook_event_name, session_id, cwd, tool_name, tool_input: (.tool_input | {command, description, file_path, pattern, url})}\" >> \"$HOME/Library/Application Support/ClaudePet/events.jsonl\"" }] }]
}
```

Sessions the pet runs itself don't need it: their permission requests already pop up as the Allow / Deny card. (The `Notification` hook's `permission_prompt` is not a substitute: Claude Code sends it only after a prompt has waited 6 seconds.)

## Files

| | |
|---|---|
| `main.swift` | the whole app (AppKit, no dependencies) |
| `build.sh` | compiles with `swiftc` and packages the `.app` |
| `Resources/` | smooth sprite frames (the app pixelates them): mouth closed / half / open, plus face poses (blinks, reading, yawn, surprised) and full-body poses; `Characters/<name>/` holds the outfits; `AppIcon.icns` is the app icon |
| `tools/make_icon.py` | builds `Resources/AppIcon.icns` from a sprite: head and shoulders on a cream plate, every size through `iconutil`; `--pixel 3` pixelates it like the app (the shipped icon), `--square` also writes a square profile picture (numpy, Pillow) |
| `tools/cutout.py` | cuts a sprite out of its white background and scales it to 600 px; `--white 246` for white clothes (numpy, scipy, Pillow) |
| `tools/fit_frame.py` | scales and places a full-body pose so its head mark and soles line up with `closed.png`, growing the canvas for raised arms (numpy, OpenCV, Pillow) |
| `tools/face_frames.py` | gives a new outfit all the face frames by matching its face to Claude's and pasting each frame's eyes and mouth (numpy, Pillow) |
| `tools/defringe.py` | cleans leftover white background out of the hair in a cut-out sprite; `--face` protects a region, `--fill-face-holes` repairs punched-out eye whites (numpy, scipy, Pillow) |

## License

- **Code** (`main.swift`, `build.sh`, `tools/`): MIT. See `LICENSE`.
- **Character art** (`Resources/`, `docs/preview.png`): derived from the Claude character design by **ZipZipPipe**, which is published under [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/). The 3-heads-tall pixel version is a derivative work under the same license. **No commercial use.** See `LICENSE-ART`.

This is a fan project. It is not affiliated with or endorsed by Anthropic. "Claude" is a trademark of Anthropic.
