# MacPict — Result

## Outcome

Delivered and in daily use. A native macOS menu-bar app that collapses "screenshot → annotate →
hand to an AI agent" into a few keystrokes: `⌃⌥ C` captures the display under the pointer, a
floating window opens in crop mode, and `⌘↩` puts the annotated PNG on the clipboard.

Repository: <https://github.com/richrice/MacPict> (public, `main`).

## Final validation — run by the lead, not taken from worker reports

| Command | Exit | Result |
|---|---|---|
| `./scripts/bootstrap.sh` | 0 | project generated |
| `./scripts/build.sh` | 0 | `BUILD SUCCEEDED`, zero Swift warnings |
| `./scripts/test.sh` | 0 | `TEST SUCCEEDED`, 196 tests, 0 failures |

Suites: AnnotationWindowController 44, AnnotationModel 37, Coordinator 25, CanvasGeometry 23,
AnnotationRenderer 15, SnapshotExporter 13, DeliveryService 10, HotkeyShortcut 10,
SettingsStore 9, DisplayLocator 5, AppLogger 3, ScreenCaptureService 2 — summing to 196.

## The finding that shaped the architecture

`CGDisplayCreateImage`, `CGDisplayCreateImageForRect`, `CGWindowListCreateImage` and
`CGWindowListCreateImageFromArray` are **obsoleted** as of macOS 15.0 — not deprecated.
Referencing one is a hard compile error that `@available` cannot rescue. Established by reading
the macOS 26.5 SDK headers and confirming with `swiftc -typecheck` before any code was written.
ScreenCaptureKit is the only capture route; there is no fallback to design around.

## Architecture

**One renderer**, drawing into a caller-flipped top-left-origin context, serves both the canvas
and the exporter — so preview/export agreement is structural rather than maintained by hand.

**One storage space**: all annotation geometry in full-image pixels, top-left origin, with a
single conversion type. Crop is a `cropRect` in that same space with annotations never rebased,
which is why nested crops, crop-undo and crop-after-annotate all work with no special-casing.

**One rounding policy** for crop rectangles (outward to whole pixels, in the document), so the
toolbar readout, the on-screen preview and the exported PNG cannot disagree.

## Features

Capture of the display under the pointer; a floating annotation window; line, box, ellipse,
arrow and text; crop with two entry paths (`6` or `⌘`-drag), instant apply, auto-revert to the
previous tool, and the same undo stack as annotations; multi-line text with `⇧↩` and auto-wrap;
per-tool cursors; a configurable capture hotkey with 21 presets; delivery as clipboard image
(`⌘↩`) or clipboard file path (`⌥⌘↩`).

## Review history

**Round 1 — Codex `gpt-5.6-sol`, effort `xhigh`, one invocation. Verdict: needs-attention.**
Three findings, all confirmed against the code before repair: a failed replacement capture
destroyed the open annotated snapshot (cause: the lead's brief said "close it and capture
fresh"); toolbar delivery bypassed the text commit, so clicking Copy mid-typing lost the text;
crop rects stayed fractional with three consumers rounding differently, a guarantee that passed
only because every crop test used integral rectangles.

**Round 2 — `opus-adversary`, scoped, briefed cold. Verdict: pass with concerns.** Codex's
review runtime has no resume path, so round 2 went to a fresh reviewer with an explicit briefing
and hard scope boundary. It re-ran every worker mutation itself rather than trusting the reports.
All three repairs verified; four Low findings, all fixed — including one the crop fix had itself
introduced (pixel-alignment widened the "same rect" collision basin, so auto-revert stopped
firing and stranded the user in crop mode).

**Rounds 3+ — the user, using the app.** Every subsequent defect came from real use, and they
were the ones that mattered most: the text outline appearing only on commit; text drifting 2 pt;
the letterbox being indistinguishable from image content; text allowed past the crop edge when
arrows were not; the editor oscillating between wrapped and unwrapped on every keystroke.

## Corrections in both directions

Workers corrected the lead repeatedly, always with measurement:

- `NSImage.draw(in:from:operation:fraction:)` renders **mirrored** in a flipped context; the
  lead's brief would have shipped upside-down screenshots.
- Multiplying the wrap width by `scale` cannot preserve line breaks, because glyph advances are
  not linear in point size — demonstrated with the same string breaking differently at two
  scales, which was the exact divergence the instruction was meant to prevent.
- `drawingRect(forBounds:)` returns bare bounds on a borderless field, so the suggested way to
  derive the text inset does not work; the real derivation is an empty cell's width.
- A sub-minimum crop drag *does* reach the tool-revert site, contrary to the lead's claim.
- Asserting "all ink inside the crop" against a *cropped* export is true by construction.
- The lead's diagnosis that arrows were being lost outside the crop was wrong; the drag path was
  already clamped. The real leak was the text tool.

A worker also corrected the round-1 reviewer: `CGRect.integral` already *is* outward rounding, so
the exporter's policy was duplicated rather than wrong. The round-2 reviewer independently
re-derived this.

## Testing lessons recorded

The suite reached 183 passing tests while text entry was unusable, because **every text test set
a whole string at once** and the defect was a per-keystroke oscillation. Progressive-typing tests
now exist and are the primary guard.

Other vacuous tests caught by mutation rather than inspection: a pixel check reading premultiplied
little-endian bytes positionally, so alpha registered as brightness and it matched every pixel of
any image; a boundary test passing with the fix removed because a 14 px stroke bled across the
boundary being asserted; a whitespace-trim test that passed whether or not the code it tested ever
ran; and a first render set that validated the letterbox treatment without including the one case
that mattered — an image whose edge tone matches the surround.

## Known and accepted

- A shortcut reserved by macOS's Symbolic Hot Keys can register successfully through Carbon and
  never fire. Nothing detects it; the settings window would say "Registered".
- The editor and renderer agree on line breaking to within a pixel rather than by construction.
  The structural fix — laying the editor out in image-pixel metrics inside a scaled view — needs
  the renderer to move to a single CTM-scaled layout in the same change, across two owners.
  Measured at 2.87% metric difference; deferred, nothing lost by waiting.
- `⌘,` reaching an accessory app was reasoned about, not observed.

## Not built

Capture-time region select; blur/redaction, highlighter, freehand, numbered badges; selecting or
moving a committed annotation; drag-out; capture history; multiple simultaneous windows; app
icon; launch-at-login; notarization; CI.

## Effort split

Lead (Opus 5, max effort): SDK contract verification, architecture, task decomposition and
contract pinning, crop and hotkey design, finding validation, fix specifications, every gate
validation, README accuracy. Swarm (Opus 5 high, 8 workers): every line of implementation and
every test. Scouts (Opus 5 low): MacDictate surveys and the SDK header investigation.
Reviewers: Codex `gpt-5.6-sol` round 1, `opus-adversary` round 2, the user thereafter.
