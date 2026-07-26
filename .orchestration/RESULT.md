# MacPict — Result

## Outcome

Delivered. A native macOS menu-bar app that collapses "screenshot → annotate → hand to an AI
agent" into a few keystrokes: `⌃⌥⌘4` captures the display under the pointer, a floating window
opens for annotation (line, box, ellipse, text, arrow, crop), and `⌘↩` puts the annotated PNG on
the clipboard.

Repository: <https://github.com/richrice/MacPict> (public).

## Final validation — run by the lead, not taken from worker reports

From `/Users/rich/Repos/MacPict`:

| Command | Exit | Result |
|---|---|---|
| `./scripts/bootstrap.sh` | 0 | project generated |
| `./scripts/build.sh` | 0 | `** BUILD SUCCEEDED **`, zero Swift warnings |
| `./scripts/test.sh` | 0 | `** TEST SUCCEEDED **`, Executed 125 tests, 0 failures |

Suites: AnnotationModel 35, AnnotationWindowController 18, CanvasGeometry 17, Coordinator 13,
SnapshotExporter 12, DeliveryService 10, AnnotationRenderer 8, DisplayLocator 5, AppLogger 3,
HotkeyShortcut 2, ScreenCaptureService 2 — summing to 125.

Independent spot-checks: no obsoleted CoreGraphics capture symbols anywhere; no `isRunningInTests`
branch in the capture flow; no local rounding in `SnapshotExporter`; no leftover mutation or TODO
markers; `finish(_:)` has exactly one caller.

## The finding that shaped the architecture

`CGDisplayCreateImage`, `CGDisplayCreateImageForRect`, `CGWindowListCreateImage` and
`CGWindowListCreateImageFromArray` are **obsoleted** as of macOS 15.0 — not deprecated. Referencing
one is a hard compile error and `@available` cannot rescue it. Established by reading the macOS
26.5 SDK headers and confirming with `swiftc -typecheck`, before any code was written.

Consequence: ScreenCaptureKit is the only capture route and there is no fallback path to design
around. Had this been assumed rather than verified, it would have surfaced as an unfixable build
failure after the swarm had run.

## Architecture, and the two decisions that carry it

**D-1 — one renderer, shared by screen and export.** `AnnotationRenderer` draws into a graphics
context the *caller* has already flipped to top-left origin, and never flips on its own. The canvas
satisfies that by being `isFlipped`; the exporter by flipping a bitmap context manually. Preview and
export therefore cannot drift — it is structural, not a pair of routines kept in sync by hand.

That decision paid for itself twice. Task 5 measured that `NSImage.draw(in:from:operation:fraction:)`
renders **mirrored** in a flipped context (`respectFlipped: true` is required) — an error in the
lead's own brief that would have shipped upside-down screenshots. The exporter was unaffected
because it draws the base image before flipping. The asymmetry between two callers of the same
image-drawing API is exactly the divergence class D-1 exists to prevent.

**D-2 — one storage space.** All annotation geometry lives in full-image pixels, top-left origin.
`CanvasGeometry` owns the only two conversion functions. Crop is a `cropRect` in that same space
with annotations never rebased — which is why nested crops, crop-undo, and crop-after-annotate all
work with no special-casing.

## Crop (added mid-run at the user's request)

Two entry paths, both applying on mouse-up with no confirm step: the crop tool (`6`/`C`), which
auto-reverts to the previous tool, and `⌘`-drag from any tool, which leaves the tool untouched.
Crops go on the same snapshot undo stack as annotations, so `⌘Z` undoes a crop exactly as it undoes
a box. The region outside the pending crop dims while dragging, and the toolbar carries a live
`W × H px` readout of what the agent will actually receive.

## Adversarial review

### Round 1 — Codex `gpt-5.6-sol`, effort `xhigh`, one invocation. Verdict: needs-attention

All three findings were confirmed against the code by the lead before any repair was specified.

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | high | `performCapture` closed the open annotated window *before* the permission gate and the capture await, so a failed second capture destroyed the user's annotations irrecoverably | Close moved to after the replacement controller is constructed; every early return now leaves the old controller live and intact. 3 tests incl. `===` identity and preserved-annotation assertions. **Cause was the lead's brief**, which said "close it and capture fresh" |
| 2 | high | Toolbar Copy/Path called `finish` directly, bypassing `commitTextEditing`; clicking Copy mid-typing exported without the text and closed the window, losing it | Single `deliver(_:)` funnel commits pending text on copy and discards it on cancel; all six wirings routed through it, `finish` left with one caller. 7 tests |
| 3 | medium | Crop rects stayed fractional and three consumers rounded differently; the "exact dimensions" criterion passed only because every crop test used integral rectangles | One rounding policy: `nonisolated static pixelAlignedRect` (outward), `canonicalCropRect` layering the minimum **after** alignment; `cropRect` integral by construction; `.integral` removed from the exporter |

**A worker corrected the reviewer on finding 3.** Task 4 reported that restoring `.integral` did
*not* fail its new tests, because `CGRect.integral` already *is* outward rounding. The round-2
reviewer independently re-derived that the two are provably equal on every input given an integral
`imageSize`. Codex's 301-vs-300 example was actually the *toolbar's* nearest-rounding versus outward
alignment. The real defect was a duplicated policy free to drift; the repair addresses that root
cause, and the discriminating mutation lives in the model where it belongs.

### Round 2 — `opus-adversary`, scoped, briefed cold. Verdict: pass with concerns

Codex's `adversarial-review` runtime has no resume path, so round 2 went to a fresh Opus reviewer
with an explicit briefing and a hard scope boundary: verify the repairs, hunt regressions from
them, re-check only the criteria the round-1 findings put in doubt. It re-ran every worker mutation
itself against an rsync copy rather than trusting the reports.

All three repairs verified present and correct. Four Low findings, all fixed:

| # | Finding | Resolution |
|---|---|---|
| 1 | Pixel-alignment widened the "same rect" collision basin to a full pixel, so a re-crop over a near-identical region pushed a phantom undo step **and** left the user stranded in crop mode — the mode trap the design exists to prevent, reintroduced by a fix for something else | `guard canonical != cropRect else { return }` in the model; revert condition dropped in the canvas |
| 2 | `testWhitespaceOnlyPendingTextIsNotCommittedByADelivery` passed whether or not the code it tested ever ran — the only test of the whitespace-trim rule | Editor-teardown assertion added; verified it now fails under the mutation it previously survived |
| 3 | A crop-geometry regression **crashed the test host** (index out of range) instead of failing, truncating the summary and hiding the real cause | Bounds-guarded the shared pixel accessor; a regression now reports `sample (x: 300, y: 40) outside 300x40` at the calling test's line |
| 4 | `windowWillClose` was a fourth delegate exit bypassing `deliver`, contradicting its own doc comment — a latent trap for future maintenance | `cancelTextEditing()` added there; comment corrected to describe what is actually true |

**A worker corrected the lead's spec on finding 1.** The repair brief asserted that a sub-minimum
drag was already discarded before the revert site. Task 5 verified otherwise — the degeneracy guard
sat *below* the crop branch, so a pure click with the crop tool reached it. It fixed both halves
rather than implementing the spec as written, which alone would have traded one wrong behaviour for
another.

## Known behaviour, deliberately accepted

A crop-tool drag longer than the 3-point degeneracy threshold but smaller than `minimumCropSide`
(roughly a 3–8 view-point band) reverts the tool even though the crop was rejected. Staying in crop
mode is arguably better there, but distinguishing the cases requires `crop(to:)` to report
acceptance across two ownership boundaries, which is disproportionate for a slip-input case. One
line each in `AnnotationModel.swift` and `AnnotationCanvasView.swift` if the preference changes.

## Not built (PLAN.md §8)

Capture-time region select; blur/redaction, highlighter, freehand, numbered badges; selecting or
moving a committed annotation; settings window or shortcut recorder; drag-out; capture history;
multiple simultaneous windows; app icon; launch-at-login; notarization; CI. All are additive.

## Manual verification still outstanding

Not automatable and outside the test gate: the TCC prompt on first capture, a real ScreenCaptureKit
capture, multi-monitor pointer targeting, and Carbon hotkey delivery from another frontmost app.
macOS commonly requires relaunching an app after Screen Recording is granted — the README says so.

## Effort split

Lead (Opus 5, max effort): SDK contract verification, architecture, task decomposition and contract
pinning, the crop design, finding validation, fix specifications, all gate validation, README
accuracy. Swarm (Opus 5 high, 7 workers): every line of implementation and every test, across 4
waves and 7 repair round-trips. Scouts (Opus 5 low): MacDictate survey and the SDK header
investigation. Reviewers: Codex `gpt-5.6-sol` round 1, `opus-adversary` round 2.
