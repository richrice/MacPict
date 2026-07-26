# MacPict

MacPict is a native macOS menu-bar utility that collapses the "screenshot → annotate → hand it to an AI agent" loop into a few keystrokes.

Press **⌃⌥⌘4**. MacPict captures the display the mouse pointer is currently on and opens the snapshot in a floating window. Annotate it with lines, boxes, circles, arrows, and text, crop it down to just the part that matters, then send it straight to a CLI agent (Claude Code, Codex CLI) or a desktop app (Claude, Codex) — no file on the Desktop, no image editor, no export step.

## Requirements

- macOS 15 Sequoia or newer
- Xcode 16 or newer with Command Line Tools selected
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.44 or newer
- Screen Recording permission

MacPict uses Swift, SwiftUI, AppKit, ScreenCaptureKit, CoreGraphics, and Carbon. It has no runtime third-party dependencies. XcodeGen is a build-time project generator only.

## Bootstrap, build, test, and run

From the repository root:

```sh
./scripts/bootstrap.sh
./scripts/build.sh
./scripts/test.sh
./scripts/run.sh
```

If XcodeGen is missing, install it and retry:

```sh
brew install xcodegen
./scripts/bootstrap.sh
```

The Debug app is produced at:

```text
DerivedData/Build/Products/Debug/MacPict.app
```

To work in Xcode:

```sh
open MacPict.xcodeproj
```

MacPict is an `LSUIElement` app: it has no Dock icon and no menu bar of its own. It lives in the status bar as a `camera.viewfinder` icon.

## Screen Recording permission

Capture uses ScreenCaptureKit, which requires the Screen Recording privacy grant. On the first capture macOS prompts for it; you can also grant it in **System Settings → Privacy & Security → Screen & System Audio Recording**, or from MacPict's menu-bar menu.

macOS often does not apply a newly granted Screen Recording permission to an already-running app. **If capture still fails right after you grant it, quit MacPict and launch it again.**

## Using it

| Key | Action |
|---|---|
| `⌃⌥⌘4` | capture the display under the pointer |
| `1`…`5` | arrow / box / ellipse / line / text tool |
| `6` or `C` | crop tool |
| `⌘`-drag | crop without leaving the tool you are on |
| `⇧⌘R` | reset the crop back to the full display |
| `⌘Z` / `⇧⌘Z` | undo / redo — crops included |
| `⌘⌫` | clear all annotations |
| `[` / `]` | smaller / larger stroke and text size |
| `⌘↩` | copy the annotated image to the clipboard, close the window |
| `⌥⌘↩` | write the annotated PNG to a temp file and copy its path, close the window |
| `Esc` | cancel the current text edit, otherwise close the window |
| `⌘W` | close the window |

`⌘↩` is the primary route: Claude Code, Codex CLI, and the Claude and Codex desktop apps all accept a pasted image. `⌥⌘↩` is for flows where a file path is easier to hand over than a binary blob.

## Cropping

A whole 5K display handed to an agent buries the thing you are pointing at. Cropping is one gesture and never traps you in a mode:

- press `6`, drag, release — the crop applies immediately, with no confirm step, and the tool snaps back to whatever you were using before;
- or just hold `⌘` and drag from any tool, which does not change your tool selection at all.

Crops go on the same undo stack as annotations, so `⌘Z` steps back through them exactly the way it steps back through a box. Cropping an already-cropped image works too, and undoes one level at a time. While you drag, everything outside the pending crop dims, and the toolbar shows a live `W × H px` readout of exactly what the agent will receive.

The capture is taken at the display's native pixel resolution, and the exported PNG is written at that same resolution, so annotations land exactly where you drew them. Crop rectangles are snapped outward to whole pixels, so the size in the toolbar, the image on screen, and the exported PNG always agree.
