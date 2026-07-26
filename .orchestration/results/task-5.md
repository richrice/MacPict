# Task 5 — Annotation window, canvas, toolbar

## Files created (all three, no other file touched)

- `MacPict/AnnotationCanvasView.swift`
- `MacPict/AnnotationToolbarView.swift`
- `MacPict/AnnotationWindowController.swift`

`project.yml` picks the new sources up automatically; `./scripts/bootstrap.sh` regenerated the
project. No test file is owned by this task.

## Validation actually run (from `/Users/rich/Repos/MacPict`)

| Command | Result |
|---|---|
| `./scripts/bootstrap.sh` | exit 0 |
| `./scripts/build.sh` | exit 0, `** BUILD SUCCEEDED **` |
| `./scripts/test.sh` | exit 0, `** TEST SUCCEEDED **`, 80 tests / 0 failures (whole suite, other tasks' tests included) |
| `xcodebuild … clean build \| grep -E "\.swift.*(warning\|error)"` | no output — zero Swift diagnostics |

The only line in the build output containing "warning" is
`appintentsmetadataprocessor … Metadata extraction skipped. No AppIntents.framework dependency
found.`, which is a tool note, not a Swift warning.

Beyond the gate I compiled the real source files into three throwaway harnesses in the session
scratchpad (nothing written into the repo) and asserted behaviour:

- **Pixel harness** (renders `AnnotationCanvasView` offscreen via `cacheDisplay`): the raster's
  top-left marker lands at the view's top-left (upright); after `crop(to: (200,0,200,100))` the
  marker at image (200,0) lands at view (0,0); a box stored at full-image (260,20) draws at view
  (120,40) at scale 2; a box lying entirely outside the crop is absent; `imagePoint(fromView:
  .zero) == (200,0)`; `isFlipped == true`.
- **Interaction harness** (synthesised `NSEvent`s into `mouseDown/Dragged/Up`, `keyDown`,
  `performKeyEquivalent`): 41 assertions, 0 failures. Covers commit of a box drag, discard of a
  <3 pt drag, `⌘`-drag crop from the box tool (crop applied, tool unchanged, no annotation
  appended), undo of a crop, `6` → crop tool → drag → crop applied **and tool auto-reverted to
  box**, sub-minimum crop rejected with the crop tool retained, `⇧⌘R`, `1`–`6`, `c`, `[`/`]`,
  `⌘Z`, `⇧⌘Z`, `⌘⌫` (clear + undoable), `⌘↩`/`⌥⌘↩`/`⌘W`/`Esc` callbacks firing exactly once
  each, `⌘Q` and `⌃⌥⌘4` *declined* so they still reach the rest of the app, text editor placed
  on click, Return commits trimmed text, Escape cancels the edit **without** firing the cancel
  callback, whitespace-only text discarded.
- **Window harness** (constructs the controller, never calls `present()`, so nothing appeared on
  screen): panel is an `NSPanel`, `canBecomeKey`/`canBecomeMain` true, `level == .floating`
  (raw 3), title `MacPict`, style mask titled+closable+resizable, `collectionBehavior ==
  [.fullScreenAuxiliary, .moveToActiveSpace]`, `isMovableByWindowBackground == false`,
  `hidesOnDeactivate == false`; initial frame `(98,24,1531,1036)` inside `visibleFrame
  (0,0,1728,1084)` and centred on it; toolbar subview is exactly 44 pt pinned to the top with
  the canvas below; a crop resizes the window with the **centre fixed to within 1 pt** and stays
  inside `visibleFrame`; **undo of that crop restores the original size** (the observer is on
  `document.$cropRect`, not on the crop handler); a 40×30 crop still yields a usable 840×252
  window; the delegate receives exactly `["image"]` for a copy followed by `close()` (no
  trailing cancel), and exactly `["cancel"]` when the window is closed by its close button.

## Declarations as written

```swift
@MainActor
protocol AnnotationWindowDelegate: AnyObject {
    func annotationWindowDidRequestCopyImage(_ controller: AnnotationWindowController)
    func annotationWindowDidRequestCopyPath(_ controller: AnnotationWindowController)
    func annotationWindowDidCancel(_ controller: AnnotationWindowController)
}

private final class AnnotationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AnnotationWindowController: NSObject {   // ← NOT NSWindowController; see gap G-1
    let document: AnnotationDocument
    weak var annotationDelegate: AnnotationWindowDelegate?
    private(set) var window: NSWindow?
    init(document: AnnotationDocument, screen: NSScreen)
    func present()
    func close()
}
extension AnnotationWindowController: NSWindowDelegate { func windowWillClose(_:) }

@MainActor
final class AnnotationCanvasView: NSView {
    var onCopyImage: (() -> Void)?
    var onCopyPath: (() -> Void)?
    var onCancel: (() -> Void)?
    init(document: AnnotationDocument)
    override var isFlipped: Bool { true }
    var geometry: CanvasGeometry { CanvasGeometry(imageSize: document.imageSize,
                                                  sourceRect: document.cropRect,
                                                  viewSize: bounds.size) }
}
extension AnnotationCanvasView: NSTextFieldDelegate { … }

struct AnnotationToolbarView: View {
    @ObservedObject var document: AnnotationDocument
    let onCopyImage: () -> Void
    let onCopyPath: () -> Void
    let onCancel: () -> Void
}
```

## Plan gaps and deviations (read these)

**G-1 — `AnnotationWindowController: NSWindowController` and `let document:
AnnotationDocument` are mutually exclusive. The pinned §5.11 shape cannot be written.**
`NSWindowController` already declares a settable `document: AnyObject?`, so the stored property
is treated as an illegal override:
`error: property 'document' with type 'AnnotationDocument' cannot override a property with type
'AnyObject?'`. I verified all three escape routes fail: `@nonobjc` in the class body (same
error), a computed property in an extension (same error), and a covariant read-only override
(illegal — cannot drop settability). Only `override var document: AnyObject?` compiles, which
would leave callers with `AnyObject?`.

I kept the **member** (Task 7 almost certainly does `controller.document.annotations` /
`.cropRect` to export) and changed the **base class** to `NSObject`, adding
`private(set) var window: NSWindow?` and `func close()` so the parts of the
`NSWindowController` surface a coordinator would reach for still resolve. `present()` is
unchanged. If the lead prefers the base class over the member, the fix is a rename
(`annotationDocument`) plus a matching change in Task 7 — one line each; say the word.

**G-2 — the drawing instruction in my brief was wrong, and it would have shipped an
upside-down screenshot.** The brief said "NSImage honours the context's flippedness; raw
`CGContext.draw` does not". Measured, not assumed: in a flipped context (CTM flipped +
`NSGraphicsContext(cgContext:flipped: true)`, and in a real `isFlipped` `NSView`),
`draw(in:from:operation:fraction:)` renders the image **vertically mirrored**;
`draw(in:from:operation:fraction:respectFlipped: true, hints:)` renders it upright. Separately,
the `from:` rect is in the image's **bottom-left-origin** space, so the top-left-origin
`cropRect` has to be flipped into it:
`CGRect(x: crop.minX, y: imageSize.height - crop.maxY, width: crop.width, height: crop.height)`.
Both facts are asserted by the pixel harness above and commented at the call site.
`SnapshotExporter` (Task 4) is unaffected — §5.5 has it draw the image *before* flipping.

**G-3 — annotations are stored in full-image coordinates, so the renderer needs a translate.**
Passing `scale: 1 / geometry.imageScale` alone puts image (0,0) at view (0,0), which is only
right for an uncropped image exactly filling the view. The canvas clips to `displayRect`, then
translates by `geometry.viewPoint(fromImage: .zero)` before calling `AnnotationRenderer`. Not a
contradiction of the plan, but it is not stated in it either, and getting it wrong is invisible
until you crop.

No breakage of callers in files I do not own: nothing outside my three files referenced these
types (the Task 1 `AppCoordinator` stub does not construct a window yet).

## How the required behaviours are implemented

**Crop dimming.** During a crop drag only, `drawCropOverlay` builds `NSBezierPath(rect:
displayRect)`, appends the pending rect, sets `windingRule = .evenOdd` and fills with 50 % black,
then strokes a 1 pt white border around the pending rect. Ordinary annotation drags never reach
this path (`drag.isCrop` is false), so nothing dims while drawing a box.

**Auto-revert.** The canvas subscribes to `document.$tool` and records the tool that was
selected immediately before `.crop` became current — so it works whether crop was chosen with
`6`/`c` or with the toolbar button. `Drag.revertsTool` is set only when `document.tool == .crop`
at `mouseDown`, so a `⌘`-drag never touches the tool. On mouse-up the tool is restored only if
`document.cropRect` actually changed, so an accidental click with the crop tool selected leaves
the user in crop rather than silently switching modes on a no-op.

**Centre-fixed resize.** `cropObserver` sinks `document.$cropRect.dropFirst().removeDuplicates()`
— on the published property, so undo/redo of a crop resizes too, which the harness asserts. The
handler recomputes the aspect-fit content size in `screen.visibleFrame.insetBy(dx: 40, dy: 40)`,
places the new frame so its midpoint equals the old midpoint, clamps it into `visibleFrame`, and
calls `setFrame(_:display: true, animate: false)`.

**Escape vs close.** Structural, not a flag: while editing, the field editor is first responder,
so Escape arrives at `control(_:textView:doCommandBy:)` with `cancelOperation(_:)`; that discards
the edit and returns `true`, and the event goes no further. The canvas's `keyDown` only sees
Escape when nothing is being edited, and then calls `onCancel`. Return commits via
`insertNewline(_:)`; losing focus any other way (a click on the canvas or in the toolbar) commits
through `controlTextDidEndEditing`. Commit trims whitespace and appends nothing for an empty
string. All four paths are asserted in the interaction harness.

**One-shot delegate.** `finish(_:)` guards with `hasFinished`, and `windowWillClose` routes
through it. So the coordinator closing the window after a copy cannot produce a spurious
`…DidCancel`, closing by the red button still reports a cancel, and there is no re-entrant
close loop.

## Judgement calls worth reviewing

- **Minimum content size 840×220.** The toolbar's measured `fittingSize` is 791 pt (819 pt with
  the reset-crop control showing). A very tight crop therefore letterboxes inside an 840 pt-wide
  window rather than clipping toolbar controls. If the lead prefers small crops to yield small
  windows, the toolbar has to shed controls or wrap.
- **Never magnifies past natural size.** The aspect-fit scale is capped at
  `1 / screen.backingScaleFactor`, so a 200 px crop does not become a full-screen window.
- **`panel.hidesOnDeactivate = false`** — `NSPanel` defaults this to `true`, which would make the
  window vanish the moment the user clicked another app. Not in the plan, plainly required by
  "floating over all other windows".
- **`animationBehavior = .none`, `acceptsFirstMouse == true`** — both remove a step/frame from
  the interaction the app exists to make fast.
- Drag points are clamped into `displayRect` before conversion, then through `clampToImage`, so
  nothing can be drawn into the letterbox and a crop cannot be dragged back out past what is
  visible.

## Remaining uncertainties

- Nothing here has been exercised through real AppKit event routing: the harnesses call
  `performKeyEquivalent`/`keyDown`/`mouseDown` directly. Key-equivalent delivery to a subview of
  the panel's content view is standard AppKit behaviour, but it is unproven until Task 7 wires
  the coordinator and the app is run manually. `NSHostingView` sits earlier in `subviews` than the
  canvas; SwiftUI buttons here declare no `.keyboardShortcut`, so they should not intercept
  anything.
- While a text field is being edited, `⌘Z` is consumed by the canvas and undoes the *document*
  rather than the field editor's typing. Cheap to change if it annoys; I judged document undo the
  more useful default.
- The text field's glyph origin and the committed `.text` annotation's origin can differ by a
  point or two of `NSTextField` inset, so text may nudge slightly on commit. Removing that
  entirely means measuring the field editor's text origin; not worth the complexity unless it
  reads badly in use.
- Appearance was not eyeballed in light or dark mode — the toolbar uses `.bar` background,
  `Color.primary`, and `Color.accentColor` for selection, all appearance-reactive, but a human
  should look at it once.

---

## Repair 1 — inert window after failed delivery

### The defect, as fixed

`finish(_:)` latched `hasFinished = true` before calling the delegate, so a delivery that threw
left the window visible but deaf: `⌘↩`, `⌥⌘↩`, `⌘W` and `Esc` were swallowed forever, and a
red-button close afterwards reported nothing, stranding the coordinator's
`activeWindowController`. The latch now means *closed*, not *requested*.

### Changes to `MacPict/AnnotationWindowController.swift`

- `private var hasFinished = false` → `private var isClosed = false`, with a comment stating why
  it latches on close rather than on a finish request.
- `finish(_:)` now only *reads* the latch: `guard !isClosed else { return }`, then dispatches to
  the delegate. It no longer sets it, so after a delegate that declines to close, every shortcut
  keeps working and the user can retry.
- `close()` latches **before** tearing down: `guard !isClosed else { return }; isClosed = true;
  window?.close()`. The `windowWillClose` this triggers therefore sees the window as already
  closed and stays silent.
- `windowWillClose(_:)` no longer routes through `finish(.cancel)` (which would refuse to fire on
  a live controller's own teardown ordering). It guards on the latch, sets it, then calls
  `annotationDelegate?.annotationWindowDidCancel(self)` directly — so a red-button close still
  clears `activeWindowController`, and the coordinator's own `close()` from inside that handler
  hits the guard and does nothing.

Public shape is unchanged: `document`, `annotationDelegate`, `window`, `init(document:screen:)`,
`present()`, `close()`. `MacPict/AppCoordinator.swift` was not touched; no coordinator change was
needed.

### New tests — `MacPictTests/AnnotationWindowControllerTests.swift` (now owned by Task 5)

Inline `RecordingWindowDelegate` records `[.copyImage/.copyPath/.cancel]` and has
`closesOnCopy` / `closesOnCancel` switches so it can model both the coordinator that closes on
success and the one that leaves the window standing after a throw. `present()` is never called.
Actions are driven through the real key path: the canvas is pulled out of
`window.contentView.subviews` and fed synthesised `NSEvent`s via `performKeyEquivalent` /
`keyDown`.

1. `testCopyImageWhoseDelegateDoesNotCloseLeavesTheControllerLiveForARetry` — the regression
   guard: two `⌘↩` presses with a non-closing delegate produce `[.copyImage, .copyImage]`.
2. `testEveryActionKeepsWorkingWhileTheDelegateDeclinesToClose` — `⌘↩`, `⌥⌘↩`, `Esc`, `⌘W`
   produce `[.copyImage, .copyPath, .cancel, .cancel]`.
3. `testControllerIsInertOnceTheDelegateHasClosedIt` — after a closing `⌘↩`, further `⌘↩`,
   `⌥⌘↩`, `⌘W` and `Esc` add nothing.
4. `testUserInitiatedCloseReportsCancelExactlyOnce` — `window.close()` yields `[.cancel]`.
5. `testUserInitiatedCloseWhoseDelegateCallsCloseReportsCancelExactlyOnce` — the coordinator
   pattern from the red-button direction: still exactly `[.cancel]`.
6. `testKeyboardCancelWhoseDelegateCallsCloseReportsCancelExactlyOnce` — the same recursion from
   the `⌘W` direction, and asserts the window ends up not visible.
7. `testSuccessfulCopyFollowedByCloseReportsNoCancel` — success stays one-shot with no trailing
   cancel.

### The recursion was verified empirically, not by inspection

Tests 5 and 6 exercise the exact double-callback path (delegate's `…DidCancel` calls `close()`,
which closes the window, which fires `windowWillClose`) and assert the message list is exactly
`[.cancel]`. Both pass.

I also proved the guards bite: I temporarily patched `finish(_:)` back to the pre-fix behaviour
(`isClosed = true` inside `finish`), ran
`xcodebuild … -only-testing:MacPictTests/AnnotationWindowControllerTests test`, and observed
`** TEST FAILED **` with tests 1 and 2 failing on exactly the swallowed-retry assertion
(`["copyImage"] is not equal to ["copyImage", "copyImage"]`), while 3–7 still passed. The file
was restored from a scratchpad backup in the same command, and the restored copy contains
`isClosed = true` at only the two intended sites (`close()` and `windowWillClose`).

### Validation (real exit codes, after restore)

| Command | Result |
|---|---|
| `./scripts/bootstrap.sh` | exit 0 |
| `./scripts/build.sh` | exit 0, `** BUILD SUCCEEDED **`, no `.swift` warnings or errors in the log |
| `./scripts/test.sh` | exit 0, `** TEST SUCCEEDED **`, **98 tests, 0 failures** |

98 = the pre-repair suite plus my 7. The suite stood at 89 when the repair was specified and at
91 when I started; Task 2 was concurrently adding tests to files it owns, which accounts for the
rest. No failure appeared in `GlobalHotkeyManager.swift`, `ScreenCapturePermission.swift` or
`ScreenCaptureService.swift`.

---

## Repair 2 — toolbar delivery must commit pending text

### The defect, as fixed

The toolbar's `onCopyImage`/`onCopyPath` closures called `finish(_:)` directly, while pending
inline text only reached `document.annotations` through `AnnotationCanvasView.commitTextEditing()`
— which the keyboard handlers called explicitly and the toolbar path never did. Typing a comment
and then clicking **Copy** instead of pressing Return delivered the screenshot without it, and
the window then closed, losing the sentence permanently.

### The unified delivery path

`AnnotationWindowController` gained one private method that every route now funnels through:

```swift
private func deliver(_ action: Finish) {
    switch action {
    case .copyImage, .copyPath: canvas.commitTextEditing()
    case .cancel: canvas.cancelTextEditing()
    }
    finish(action)
}
```

All six wirings — the three canvas callbacks (`canvas.onCopyImage/onCopyPath/onCancel`) and the
three toolbar closures — now call `deliver(_:)`; `finish(_:)` is reached from nowhere else and
keeps the `isClosed` semantics from Repair 1 untouched (`deliver` does not latch either, so a
failed delivery still leaves the window live and retryable). Because the keyboard routes through
the same method, I removed the now-redundant `commitTextEditing()` calls from
`performKeyEquivalent`'s `⌘↩` and `⌥⌘↩` cases rather than leaving two mechanisms to drift apart;
`testKeyboardCopyImageStillCommitsPendingText` and `testKeyboardCopyPathStillCommitsPendingText`
guard that removal.

`AnnotationCanvasView.commitTextEditing()` and `cancelTextEditing()` were promoted from `private`
to internal — the minimum API this needs. The other commit paths inside the canvas (click
elsewhere, Return, focus loss) are unchanged, and `commitTextEditing()` is a no-op when nothing is
being edited, so `deliver` is safe on every action. Whitespace-only text is still discarded: the
trim-and-`guard !string.isEmpty` in `commitTextEditing()` was not touched, and
`testWhitespaceOnlyPendingTextIsNotCommittedByADelivery` locks it.

One related hardening: `commitTextEditing()` now reads
`editing.field.currentEditor()?.string ?? editing.field.stringValue` **before** tearing the field
down. While an edit is live the field editor is the authoritative copy of what was typed. I could
not exercise a live field editor headlessly — `currentEditor()` is nil unless the window is key,
and making it key steals focus from the user — so this is belt-and-braces on the one path where
being wrong costs the user their sentence, not a verified-necessary change.

### Cancel semantics — decided, not fallen into

**An explicit cancel discards pending text.** `deliver(.cancel)` calls `cancelTextEditing()`, not
`commitTextEditing()`. Cancel means "throw this session away", and the half-typed sentence is part
of the session; committing it into a document that is about to be discarded would be busywork
that could also fire a spurious `objectWillChange`. This matches Escape's existing behaviour
while editing (the field editor cancels the edit), so the two never contradict each other.
`testCancelDiscardsPendingTextRatherThanCommittingIt` and `testKeyboardCancelDiscardsPendingText`
assert it explicitly rather than leaving it implied.

### New tests (in `MacPictTests/AnnotationWindowControllerTests.swift`)

Helpers added: `toolbar()` reads the real `AnnotationToolbarView` off the
`NSHostingView<AnnotationToolbarView>` in the window's content view, so the tests invoke the
actual wired closures rather than a copy of them; `beginTextEdit(_:)` lays the window out, clicks
with the text tool and fills the field **without** pressing Return, asserting the text is still
uncommitted before the delivery. `RecordingWindowDelegate` now also records
`textsWhenNotified` — the document's text annotations *at the moment* each delegate message
arrives — which is what proves the commit happens **before** notification, not merely eventually.

1. `testToolbarCopyImageCommitsPendingTextBeforeNotifyingTheDelegate` (regression guard)
2. `testToolbarCopyPathCommitsPendingTextBeforeNotifyingTheDelegate`
3. `testKeyboardCopyImageStillCommitsPendingText`
4. `testKeyboardCopyPathStillCommitsPendingText`
5. `testCancelDiscardsPendingTextRatherThanCommittingIt`
6. `testKeyboardCancelDiscardsPendingText`
7. `testWhitespaceOnlyPendingTextIsNotCommittedByADelivery`

### Mutation check

I temporarily reverted exactly the defect — the three toolbar closures rewired to
`self?.finish(...)`, leaving the keyboard on `deliver` — and ran
`xcodebuild … -only-testing:MacPictTests/AnnotationWindowControllerTests test`:
`** TEST FAILED **`, with
`testToolbarCopyImageCommitsPendingTextBeforeNotifyingTheDelegate` failing on
`("[]") is not equal to ("["this button is misaligned"]")` **and** on
`("[[]]") is not equal to ("[["this button is misaligned"]]")` (the delegate observing a document
without the text), `testToolbarCopyPathCommitsPendingTextBeforeNotifyingTheDelegate` failing the
same way, and `testCancelDiscardsPendingTextRatherThanCommittingIt` failing because the editor was
left standing. The keyboard tests and all Repair 1 tests still passed under the mutation, which is
the correct discrimination. The file was restored from a scratchpad backup in the same command;
the restored copy has all six wirings on `deliver(.…)` and no direct `finish(.…)` call sites
outside `deliver`.

### Validation (real exit codes, after restore)

| Command | Result |
|---|---|
| `./scripts/bootstrap.sh` | exit 0 |
| `./scripts/build.sh` | exit 0, `** BUILD SUCCEEDED **`, no `.swift` warnings or errors |
| `./scripts/test.sh` | exit 0, `** TEST SUCCEEDED **`, **120 tests, 0 failures** |

`AnnotationWindowControllerTests` is now 14 tests (7 from Repair 1 + 7 here). The suite total rose
from 99 to 120: my 7 plus tests added concurrently by the other repairs. No failure appeared in
`AppCoordinator.swift`, `AnnotationModel.swift` or `SnapshotExporter.swift`, none of which I
touched.

---

## Repair 3 — crop mode trap, vacuous whitespace test, close-path text resolution

### Item 1 — crop tool stranding the user in crop mode

**Your premise was wrong, and I did not assume it.** The spec said "a rejected sub-minimum drag
is already discarded earlier as a degenerate drag and never reaches this point". It does reach it:
in `mouseUp` the `extent >= minimumDragExtent` guard sat *below* the `if drag.isCrop { … return }`
branch, so it only ever governed annotations. A pure click with the crop tool selected reached the
revert site, and the `document.cropRect != before` condition was the only thing stopping that
click from handing the tool back.

So dropping the condition alone would have traded one wrong behaviour for another. I did both
halves:

- moved the degeneracy guard **above** the crop branch, so a click that missed neither draws, nor
  crops, nor reverts the tool, whichever tool is selected;
- then dropped the condition exactly as specified — `if drag.revertsTool { document.tool =
  toolBeforeCrop }`, with no dependence on whether the aligned rect changed.

`AnnotationModel.swift` was not touched.

Residual behaviour worth knowing: a drag longer than 3 view points but smaller than
`minimumCropSide` (16 image pixels) now reverts the tool even though `crop(to:)` rejected the
rect. At typical scales that band is roughly 3–8 view points. I judged that the right side to err
on — §11.1 goal 2 forbids stranding the user in a mode; nothing in the plan asks crop to be sticky
after a too-small drag — but say the word if you want it narrowed.

### Item 2 — vacuous whitespace test

Added to `testWhitespaceOnlyPendingTextIsNotCommittedByADelivery`:

```swift
XCTAssertTrue(try canvas().subviews.isEmpty, "the editor must be torn down even when the trimmed text is empty")
```

which is false unless the commit path actually ran. No existing assertion was weakened.

### Item 3 — `windowWillClose` bypassing the text-resolution rule

`windowWillClose` now calls `canvas.cancelTextEditing()` immediately after `isClosed = true` and
before the delegate call, so all four exits resolve pending text. The `deliver(_:)` comment no
longer claims to be "the one route out"; it now says every *user-initiated* route comes through it
and that the fourth exit discards pending text in `windowWillClose` for the same reason. The
`isClosed` semantics from Repair 1 and the single-`deliver` structure from Repair 2 are unchanged.

### New tests

- `testCropToolDragProducingAnUnchangedRectStillRestoresThePreviousTool` (item 1 guard)
- `testCropToolDragAppliesTheCropAndRestoresThePreviousTool` (the ordinary path still works)
- `testCropToolClickWithoutADragLeavesTheCropAndTheToolAlone` (guards the half your spec assumed
  was already handled)
- `testSystemInitiatedCloseWhileTypingTearsDownTheEditor` (item 3 guard)

Helpers added: `mouseEvent(_:at:_:)`, `drag(from:to:modifiers:)` (window coordinates, as a real
event carries), `windowPoint(fromCanvas:)`, `selectCropTool()`.

### Mutation checks — all three run, not reasoned

| Mutation | Result |
|---|---|
| **A** — revert condition restored to `if drag.revertsTool, document.cropRect != before` | `** TEST FAILED **`; `testCropToolDragProducingAnUnchangedRectStillRestoresThePreviousTool` failed with `("crop") is not equal to ("box")` — the user left in crop mode, exactly the reported defect. All other tests passed. |
| **B** — commit/cancel switch removed from `deliver(_:)` | `** TEST FAILED **`; `testWhitespaceOnlyPendingTextIsNotCommittedByADelivery` **now fails** on the new teardown assertion (line 384), where before this repair it passed under the same mutation. The Repair 2 tests failed alongside it, as they should. |
| **C** — `cancelTextEditing()` removed from `windowWillClose` (my own check on item 3) | `** TEST FAILED **`; `testSystemInitiatedCloseWhileTypingTearsDownTheEditor` failed on the `subviews.isEmpty` assertion, confirming that test bites rather than passing vacuously. |

Each mutation was applied to a scratchpad-backed copy and restored in the same command; the
restored files were re-grepped to confirm (`if drag.revertsTool {` with no condition, the
commit/cancel switch present, two `cancelTextEditing` call sites in the controller).

### Validation (real exit codes, after restore)

| Command | Result |
|---|---|
| `./scripts/bootstrap.sh` | exit 0 |
| `./scripts/build.sh` | exit 0, `** BUILD SUCCEEDED **`, no `.swift` warnings or errors |
| `./scripts/test.sh` | exit 0, `** TEST SUCCEEDED **`, **125 tests, 0 failures** |

`AnnotationWindowControllerTests` is now 18 tests. One intermediate run during this repair showed
6 failures in `MacPictTests/SnapshotExporterTests.swift`
(`testFractionalCropRectIsAlignedByTheDocumentPolicy` and friends, off-by-one on aligned crop
dimensions) — a transient mid-edit state of Task 4's concurrent alignment repair. It cleared on
the next run with no action from me, and I touched none of those files.

---

## Repair 4 — text position and size parity with the live editor

Files changed: `MacPict/AnnotationCanvasView.swift`,
`MacPictTests/AnnotationWindowControllerTests.swift`. Nothing else was touched — in
particular not `AnnotationRenderer.swift` or `SnapshotExporter.swift`, and no outline was
re-added.

### Item 1 — how the inset was derived

**Measured, from the cell, not hard-coded.**

```swift
private static func textInset(of field: NSTextField) -> CGFloat {
    guard let cell = field.cell else { return 0 }
    return cell.cellSize.width / 2
}
```

read once in `beginTextEditing` while the field is still empty and carried on `TextEditing`.
Three facts behind that one line, each established by running code rather than by reasoning:

1. **`drawingRect(forBounds:)` cannot supply the inset, contrary to the brief's suggestion.**
   On this borderless, non-background-drawing field it returns the bare bounds —
   `(0, 0, 200, 33)` for a `(x, y, 200, 33)` frame — as does `titleRect(forBounds:)`. Measured
   at 24/36/56 pt.
2. **The real offset is the field editor's line-fragment padding, and it is horizontal only.**
   Rendering the same string twice into an 8×-supersampled flipped context — once through
   `NSTextFieldCell.draw(withFrame:in:)`, once through `NSAttributedString.draw(at:)` with
   `AnnotationRenderer`'s attributes — gives ink boxes of **identical size** offset by exactly
   `dx = 2.0, dy = 0.0` at 24 pt, 36 pt and 56 pt. Independently, a live field editor reports
   `textContainerOrigin == (0, 0)` in the field's coordinates and
   `textContainer.lineFragmentPadding == 2.0`. Both routes agree, which is why only x is
   compensated and there is no vertical fudge.
3. **An empty cell's width is exactly that padding on each side.** `cell.cellSize.width == 4.0`
   for system font sizes 8/12/24/36/56/120 at regular, semibold and bold weight, and for Menlo,
   Helvetica and Times New Roman; and `cellSize.width - NSAttributedString(...).size().width ==
   4.0` for every one of those with a non-empty string. So `cellSize.width / 2` *is* the
   per-side inset, read from the cell that will do the drawing, and it tracks a change in the
   padding instead of enshrining 2.0.

The commit now converts the **glyph** corner rather than the field's:

```swift
let origin = geometry.imagePoint(fromView: CGPoint(
    x: editing.field.frame.minX + editing.textInset,
    y: editing.field.frame.minY
))
```

Reading the field's *current* frame and the *current* geometry (rather than the image point
captured at begin) is what makes items 1 and 2 compose: a resize or a crop mid-edit commits
where the user was last shown the text.

Empirical confirmation that the fix lands, not just an argument that it should: in the standalone
harness the field's ink on a canvas identical to the app's is `(316.5, 43.0, 133.0, 69.5)` in
view points, and the committed annotation renders at `(316.5, 43.0, 133.0, 69.5)`. Pre-fix the
committed render sat at `x = 314.5`.

### Item 2 — keeping the live editor in step with the geometry

`beginTextEditing` no longer computes the frame and font inline. Both now come from
`fitEditor(_:)`, which reads `self.geometry` each time, and `AnnotationCanvasView.layout()` —
the view's own size-change hook, not a new observer — calls it for the lifetime of the edit:

```swift
override func layout() {
    super.layout()
    if let textEditing { fitEditor(textEditing) }
}
```

**Crop during a live edit: yes, it is reachable, and it is covered.** A crop *drag* cannot land
mid-edit (`mouseDown` commits the text and returns before any drag starts), but `⇧⌘R` and a `⌘Z`
over an earlier crop are key equivalents, and `performKeyEquivalent` reaches the canvas whatever
holds first responder — the field editor does not consume them. Both change `cropRect`, hence
`imageScale` and `displayRect`, under a live editor.
`testTextEditLiveAcrossACropCommitsAtTheSizeTheEditorWasShowing` drives exactly that path and
asserts the reset actually moved the scale first.

The existing `document.objectWillChange` sink additionally sets `needsLayout` while an edit is
live. That notification arrives *before* the document has changed, so refitting inside it would
read the pre-change crop; deferring to the next layout pass reads the settled value. **Honest
caveat: no test isolates that line.** Removing it leaves all 21 tests green, because the field's
own autoresizing-generated constraints incidentally dirty layout on every `layoutIfNeeded`. It
is there for the case the layout hook alone does not cover — a crop that changes `imageScale`
without changing the window's content size, which `AnnotationWindowController.contentSize(for:)`
produces whenever both the old and the new crop clamp to `minimumContentSize`. I judged relying
on an incidental autolayout side effect worse than one explicit line; say the word if you want
it gone.

### New tests (3, all in `MacPictTests/AnnotationWindowControllerTests.swift`)

The assertion in all three is a **photograph, not a formula**: `redInk(of:)` renders the canvas
via `cacheDisplay` — which includes the `NSTextField` subview — and returns the bounding box, in
view points, of every pixel drawn in the annotation colour (red 1/0.2/0.2 over 0.3 grey on
black). The same glyphs are measured off the canvas with the editor live and again after the
commit, and the two boxes must coincide within 1 pt. Nothing re-derives the offset the fix
applies.

- `testCommittedTextLandsWhereTheEditorDrewIt`
- `testTextEditLiveAcrossAResizeCommitsAtTheSizeTheEditorWasShowing` — also asserts the resize
  actually changed `imageScale` and that the editor's ink grew, so it cannot pass by the resize
  being a no-op
- `testTextEditLiveAcrossACropCommitsAtTheSizeTheEditorWasShowing`

New helpers: `redInk(of:)` and `beginTextEdit(_:atImagePoint:)`. The existing
`beginTextEdit(_:)` and every Repair 1–3 test are untouched.

**One thing that had to change to make the editor measurable, and it is worth knowing.** The
existing helper types by assigning `field.stringValue`. With a live field editor — which
`makeFirstResponder` installs even in a non-key window, contrary to the note in Repair 2 —
that updates the cell's value and `currentEditor()?.string`, but the field editor renders
**nothing**: the text does not pick up the cell's attributes. The new helper types the way a
user does, `editor.insertText(_:replacementRange:)`, after which the field editor draws, and it
draws in *exactly* the place the cell does (harness: cell ink `(316.5, 43.0, 133.5, 69.5)`,
field-editor ink `(316.5, 43.0, 133.0, 69.5)`). So the test measures what the user actually
looks at.

### Mutation checks — all three run, none reasoned

| Mutation | Result |
|---|---|
| **A** — commit reverted to `let origin = editing.origin` (item 1 undone) | `** TEST FAILED **`, 3 failures. `testCommittedTextLandsWhereTheEditorDrewIt`: `("314.5") is not equal to ("316.5") +/- ("1.0") - committed glyphs moved horizontally` — the reported 2 pt jump, to the point. Both geometry-change tests failed on x too. Everything else passed. |
| **B** — `fitEditor` call removed from `layout()` (item 2 undone) | `** TEST FAILED **`, 9 failures. `testTextEditLiveAcrossAResizeCommitsAtTheSizeTheEditorWasShowing` failed first on `("69.5") is not greater than ("83.4") - the editor must have grown with the canvas`, then on ink height `("140.5") is not equal to ("69.5")` — the editor previewing half the size it committed. `testCommittedTextLandsWhereTheEditorDrewIt` still **passed**, which is the correct discrimination between the two items. |
| **C** — `needsLayout` line removed from the `objectWillChange` sink | exit 0, 21/21 pass. Reported above rather than papered over. |

Mutations A and B were applied to a scratchpad-backed copy and restored in the same command;
the restored file was re-grepped for `x: editing.field.frame.minX + editing.textInset` and
`if let textEditing { fitEditor(textEditing) }`.

### Validation (real exit codes, after restore)

| Command | Result |
|---|---|
| `./scripts/bootstrap.sh` | exit 0 |
| `./scripts/build.sh` | exit 0, `** BUILD SUCCEEDED **` |
| `xcodebuild … clean build` | exit 0; `grep -E "\.swift.*(warning\|error)"` → no output. The single line containing "warning" is the `appintentsmetadataprocessor` tool note. |
| `./scripts/test.sh` | exit 0, `** TEST SUCCEEDED **`, **146 tests, 0 failures** |

`AnnotationWindowControllerTests` is now 21 tests (18 + 3). The suite total rose from 125 to
146: my 3 plus 18 added concurrently by the hotkey-settings tasks. No failure appeared in
`SettingsStore.swift`, `SettingsView.swift`, `GlobalHotkeyManager.swift` or
`AppCoordinator.swift`, none of which I touched.

### Remaining uncertainties

- The parity is measured with the window never presented and never key. The field editor is
  live in that state and draws identically to the cell, so I believe it generalises, but the
  final word is the user looking at a real edit.
- `textInset(of:)` returns 0 if `field.cell` is ever nil. `NSTextField` always has one; the
  guard exists only because the API is optional.

---

## Feature — per-tool mouse cursors

### Mapping

| Tool | Cursor |
|---|---|
| `crop` | `NSCursor.crosshair` |
| `arrow`, `box`, `ellipse`, `line` | `NSCursor.crosshair` |
| `text` | `NSCursor.iBeam` |

Exposed as `static func cursor(for tool: AnnotationTool) -> NSCursor` on `AnnotationCanvasView`
so the mapping is directly assertable, and applied through
`resetCursorRects()` → `addCursorRect(bounds, cursor:)`.

### Custom cursors: built, rendered, rejected on the evidence

I did build the badged candidates before deciding — a white-outlined crosshair with each tool's
`AnnotationTool.symbolName` as a bottom-right badge (white dilation under a black glyph, hot spot
at the crosshair centre) — and rendered a contact sheet of all six over white, black, 50 % grey and
saturated blue, with the system crosshair in the last column for comparison. Written to
`cursor-evidence-2x.png` in the session scratchpad.

At 3× magnification the badges look fine, which is exactly the trap. Rendered at **true device
pixels** (2×, the density a Retina screen actually draws a cursor at) they are mush: the crop badge
is an unreadable smudge, `box` and `ellipse` collapse into the same small rounded blob, and `line`
and `arrow` are indistinguishable strokes. The badge also crowds the crosshair's lower-right arm,
and my hand-drawn crosshair reads thinner and weaker than the system one on grey. The system
crosshair stayed crisp and unmistakable on all four backgrounds.

So: plain `NSCursor.crosshair` for the shape tools, exactly as your fallback instruction allowed.
The toolbar already shows which shape is armed with a highlighted button; the cursor's job here is
the mode distinction (drawing vs. typing vs. selecting a region), and it does that. Crosshair is
also what macOS's own ⌘⇧4 uses for this gesture, so it is the convention as well as the legible
choice.

### Tool changed while the pointer is already inside

`invalidateCursorRects(for:)` alone only takes effect the next time the pointer moves, so picking
a tool with `1`…`6` or from the toolbar while the pointer sits over the canvas would leave the old
cursor until the user jiggled the mouse. `trackTool(_:)` — already driven by the `document.$tool`
sink, so it covers keyboard *and* toolbar changes — now calls `refreshCursor(for:)`, which
invalidates the rects and then, if the pointer is inside, calls `.set()` directly.

The decision that gates the direct set is factored out as a pure function,
`shouldApplyCursorImmediately(pointerInView:bounds:isEditingText:)`, following this codebase's
`DisplayLocator.indexOfScreen(containing:frames:)` precedent, and is unit-tested. **The AppKit half
is not verifiable headlessly**: `mouseLocationOutsideOfEventStream` reports wherever the machine's
physical pointer happens to be, so a test asserting on it would be non-deterministic, and I was
asked not to launch the app — so I have **not** manually confirmed the on-screen behaviour. What is
proven is the mapping, the gating decision, and that the tool change is observed at all. The
remaining risk is confined to whether `.set()` sticks, which is a two-line path.

### Text editor and toolbar

The `isEditingText` guard means a live inline editor is never fought over — the field manages its
own cursor. The canvas's tool cursor is the I-beam in that mode anyway, so the two agree rather
than compete. The toolbar is a separate `NSHostingView` and gets no cursor rect from me; it keeps
the ordinary arrow. `testKeyboardToolChangeLeavesTheCanvasCursorRectMatchingTheNewTool` asserts the
canvas frame does not intersect the toolbar frame, so the rect I add cannot reach it.

### ⌘-held crop cursor: deliberately skipped

Not worth it, and the mapping is why: crosshair now covers crop *and* all four shape tools, so a
⌘-held indicator would change nothing for five of the six tools. The only case it would alter is
⌘ held with the text tool armed — I-beam becoming crosshair. Paying for that with a
`flagsChanged`-driven modifier state machine, which only receives events while the canvas is first
responder and would flicker on every incidental ⌘ press (⌘Z, ⌘↩), is a bad trade for one tool. If
the user asks for it later, the honest implementation is `flagsChanged(with:)` plus a
`isCommandHeld` flag feeding the same `refreshCursor` path.

### Tests (4 new, suite now 22)

- `testNoToolShowsThePlainArrowCursor` — the user's literal complaint, over every tool.
- `testCropAndShapeToolsUseTheCrosshairAndTextUsesTheIBeam` — the exact mapping.
- `testCursorIsForcedOnlyWhenThePointerIsInsideAndNoEditorIsUp` — inside, outside, no window, and
  editing-in-progress.
- `testKeyboardToolChangeLeavesTheCanvasCursorRectMatchingTheNewTool` — `5` then `6` through the
  real key path, `resetCursorRects()` exercised, plus the toolbar-untouched assertion.

**Mutation check** (you flagged two vacuous tests in this file previously, so I ran it): with
`cursor(for:)` forced to return `.arrow` for every tool and `shouldApplyCursorImmediately` forced
to `true`, `** TEST FAILED **` — **all four** new tests failed, on the specific assertions
(`"crop still shows the default arrow"`, the crosshair/iBeam identities, and all three negative
cases of the gating predicate). None of them passes regardless of the fix. Restored from a
scratchpad backup in the same command and re-grepped.

Everything preserved: the `isClosed` latch, the single `deliver(_:)` path, crop auto-revert, the
text-position parity fix, and `fitEditor` tracking geometry changes. `AnnotationModel.swift` was
not touched and `toolBeforeCrop` was not adjusted.

### Validation (real exit codes, after restore)

| Command | Result |
|---|---|
| `./scripts/bootstrap.sh` | exit 0 |
| `./scripts/build.sh` | exit 0, `** BUILD SUCCEEDED **`, no `.swift` warnings or errors |
| `./scripts/test.sh` | exit 0, `** TEST SUCCEEDED **`, **161 tests, 0 failures** (157 + 4) |

---

## Fix — letterbox is drawable-area-ambiguous and swallows annotations

### Item 1 — audit of every view→image conversion site

There are exactly two places a view point becomes an image point. I measured both with a harness
built from the real sources (400×200 image, crop `(150, 0, 100, 200)` inside a 400×200 canvas, so
the bands are 150 pt wide either side) before changing anything.

**`imagePoint(for:geometry:)` (the drag path) was already safe.** It clamps the *view* point into
`displayRect` before converting, and `displayRect` maps onto `sourceRect` exactly, so the result
was already inside the crop. Measured: a drag begun at view x=20 — deep in the left band — and
ended at x=380 produced `arrow from (150.0, 100.0) to (250.0, 140.0)`, both on/inside the
`sourceRect` x-range 150…250. So the reported mechanism ("maps to a point outside `sourceRect` but
inside the full image, so it is accepted… never appears in the exported PNG") is **not** what the
code did; the annotation was clamped to the crop edge, not lost. I switched the call to
`clampToSource` anyway — it is the right invariant to state, `clampToImage` no longer exists, and
it makes the guarantee independent of the view-space pre-clamp — but it is not the user's bug.

**The text-editor path at line 435 was leaking, exactly as you suspected.** It converted with no
clamp at all, and the committed origin is the field's frame shifted right by `textInset`. Measured
on the same geometry: clicking at the right edge of `displayRect` committed
`text origin = (252.0, 100.0)` against a `sourceRect` ending at **x = 250** — 2 pt outside the
crop, invisible in the export. A crop applied mid-edit can move the field out of the visible
region the same way. Now clamped with `clampToSource`.

No other site converts view→image. `fitEditor` and the renderer offset go the other way
(`viewPoint(fromImage:)`), and `drawCropOverlay` converts an already-clamped image rect.

### Item 2 — the boundary treatment

Chosen: **two adjacent hairlines straddling the edge** — white at 85 % just outside, black at 55 %
just inside — over a surround lifted off pure black to `NSColor(white: 0.16)`, with a soft drop
shadow (12 pt blur, 60 % black) under the image. Fixed tones, not semantic colours: this surface
sits against arbitrary screenshot pixels, so it must not shift with the system appearance.

The hairline pair is the guarantee; the shadow and the lifted surround are only depth cues. That
distinction matters, and the renders are why:

- **First render** (`letterbox.png`, pure black / pure white / mid-grey, light and dark
  appearance): boundary visible in all six. But the test set was wrong — none of the images had an
  edge tone matching the surround, which is *precisely* the user's bug ("those bars are the same
  background color as the little image I captured"). Passing that set proved little.
- **Second render** (`letterbox-evidence-zoom.png`, 6× zoom straddling the left boundary, with a
  fourth case whose image tone is exactly the surround's 0.16): all four rows show an unambiguous
  edge, including the adversarial one, where the surround and the image are indistinguishable in
  tone and the hairline alone carries the boundary. That render is the evidence for the design.

The light and dark rows are pixel-identical, as intended.

Rejected: a flat surround colour on its own (the brief forbids it and it is the bug); shadow alone
(invisible when a black image sits on a dark surround — it fails the black case outright); a
checkerboard or hatch (never tried past sketching: it competes with the screenshot for attention,
and the hairline already meets the bar at a fraction of the visual noise). The letterbox itself is
not removable — the toolbar's ~819 pt fitting width floors the window at 840 pt content width, so
a narrow crop always letterboxes, and the window is not resized below that.

### New tests

- `testDragStartedInALetterboxBandStaysInsideTheCrop`
- `testAnnotationDrawnFromTheLetterboxBandSurvivesTheExport` — flattens through `SnapshotExporter`
  and looks for red ink, i.e. the user-visible property
- `testTextPlacedAtTheImageEdgeCommitsInsideTheCrop`

### Mutation checks — and two tests that were vacuous until they were not

| Mutation | Result |
|---|---|
| **X** — drop `clampToSource` from the drag path, keeping the view-space pre-clamp (i.e. the exact pre-fix behaviour) | `** TEST SUCCEEDED **`. This is the measurement above, restated as a mutation: **the band-drag test does not fail against the pre-fix code**, contrary to the spec's expectation, because the pre-clamp already guaranteed it. |
| **Y** — drop the clamp on the text origin | `** TEST FAILED **`, `testTextPlacedAtTheImageEdgeCommitsInsideTheCrop`. This is the real defect and it is guarded. |
| **Z** — drop *both* clamps from the drag path | `** TEST FAILED **`, both `testDragStartedInALetterboxBandStaysInsideTheCrop` and `testAnnotationDrawnFromTheLetterboxBandSurvivesTheExport`. The drag invariant is genuinely tested; it simply has two redundant mechanisms behind it. |

Getting the export test to that state took two corrections, both of which I would have missed by
inspection:

1. Its pixel check read the exporter's raw bytes positionally, but that bitmap is
   premultiplied-first little-endian, so an opaque pixel's **alpha** looked like a bright channel
   and the check matched *every* pixel of *any* image. It now redraws into an sRGB
   premultiplied-last context this test controls and looks for `r > 150, g < 90, b < 90`.
2. Even then it passed under mutation Z, because the drag ended at the band's inner edge and a
   14 px stroke bled across the boundary into the crop. The drag now stops mid-band, clear of the
   stroke, with an assertion that the band is wide enough for that to mean something.

### Validation (real exit codes, after restore)

| Command | Result |
|---|---|
| `./scripts/bootstrap.sh` | exit 0 |
| `./scripts/build.sh` | exit 0, `** BUILD SUCCEEDED **`, no `.swift` warnings or errors |
| `./scripts/test.sh` | exit 0, `** TEST SUCCEEDED **`, **165 tests, 0 failures** |

Everything preserved: the `isClosed` latch, the single `deliver(_:)` path, crop auto-revert, text
position/size parity, `fitEditor` tracking geometry, and the per-tool cursors.

---

## Fix — text extent must stay inside the visible crop

### Design: (a), text constrained the way a dragged arrow is

The user's clarification settles it, and it matches what I had already built: text is now bounded
by extent, not just by anchor, so it comes to rest against the crop edge exactly as an arrow
endpoint does. Option (b) is dropped — clipping honestly would still leave text as the one tool
that behaves differently from the other five, which is the thing being objected to.

### Implementation

One placement function, `glyphOrigin(for:editing:geometry:)`, used by **both** the live editor and
the commit, so they cannot disagree:

- measures with `AnnotationRenderer.textSize(for:style:)` and nothing else — the previously unused
  API, now wired up;
- shifts the origin left and up so `origin + textSize` fits inside `sourceRect`;
- when the string is wider or taller than the whole visible image, pins to `sourceRect.origin` and
  lets it clip, since shifting cannot help.

`controlTextDidChange` re-fits on every keystroke, so the preview tracks the constraint live.
`fitEditor` sizes the field to end exactly at `displayRect.maxX`, so the editor clips where the
export clips. `commitTextEditing` now derives the origin from the shared function against the
geometry in force at commit, instead of reading it back out of the field's frame — same value when
nothing has moved, and one less round trip through `textInset`.

### Two corrections that only rendering could have found

1. **"This" drew as "Thi".** With the field width set to `displayRect.maxX - glyph.x + textInset`,
   a string the shift had made room for still lost its last character: the cell reserves its inset
   at *both* ends. Caught in the filmstrip, not in the code.
2. **Editor and export clipped in different places.** For an over-wide string the editor stopped at
   the last whole word — measured ink ending at image x=285 against a crop edge at x=320, a 35 px
   disagreement — because the cell word-breaks while `AnnotationRenderer` clips mid-glyph. Fixed
   with `usesSingleLineMode = true` and `lineBreakMode = .byClipping`. That in turn removed the
   trailing inset reservation, so the width is now `+ textInset` (leading only); measured after:
   editor ink ends at image **x=319.94**, crop edge **x=320.0**.

### How it feels while typing

Assessed from a rendered filmstrip of the editor as the string grows (`text-extent-evidence.png`
in the session scratchpad): `T` → `This` → `This can` → `This cannot fit`, each complete, each
hugging the right edge, with the field origin moving 240 → 228 → 161 → 66 pt. Because the right
edge stays pinned, the per-keystroke shift is exactly the width of the character just typed — the
same motion as typing at the end of any macOS text field, except nothing is hidden, because the
whole string moves rather than sliding out of a fixed box. Only once the string exceeds the entire
visible width does it pin and clip, and the last two filmstrip frames show that clip landing in the
same place for two different over-long strings.

### Arrows — measured, not changed

A clamped arrow *can* paint past the boundary, by exactly half its stroke width. Crop right edge at
x=300, arrow `to` clamped onto it:

| Size | lineWidth | Ink ends (full image) | Past the crop edge | Cropped export |
|---|---|---|---|---|
| Small | 4 | x=301 | 2 px | ink touches the last column |
| Medium | 8 | x=303 | 4 px | ink touches the last column |
| Large | 14 | x=306 | 7 px | ink touches the last column |

Exactly `lineWidth / 2`, and the head contributes nothing extra because it is drawn *backwards*
from the `to` point. So a correctly-clamped arrow ends in a flat cut against the crop edge rather
than a taper — cosmetic, not a data loss, and matching the user's "that's fine". **No change made**;
if you ever want it, insetting the clamp by `lineWidth / 2` would do it, at the cost of arrows no
longer quite reaching the edge.

### New tests

- `testTextTypedNearTheRightEdgeIsWholeInTheExport` — asserts on exported pixels, using the same
  string placed comfortably inside as the yardstick, so a truncated edge case shows up as narrower
  ink regardless of coordinates
- `testTextTypedNearTheBottomEdgeIsWholeInTheExport`
- `testStringWiderThanTheVisibleImageClipsIdenticallyInEditorAndExport`

Helpers added: `useLargeDocument()` (the 120×80 setUp document cannot hold a 24 px font, so every
string there would be over-wide and the interesting cases would collapse), `redInkBounds`,
`exportedInk`, `exportedInkForTextNear`, and a `width`/`height` parameter on `makeImage`.

### Mutation check

Extent handling removed — `textSize` replaced with `.zero`, leaving the previous origin-only clamp:
`** TEST FAILED **`, with

- `testTextTypedNearTheRightEdgeIsWholeInTheExport`: ink width **25 px against the interior
  baseline's 125**, and ink running to the last column (599 of 600);
- `testTextTypedNearTheBottomEdgeIsWholeInTheExport`: ink height **2 against 17**, running to the
  last row.

Every interior-placement test, including `testCommittedTextLandsWhereTheEditorDrewIt`, still
passed. That is the discrimination asked for: the fix moves text that would overflow and leaves
text that fits exactly where it was.

### A concurrent failure I diagnosed but did not touch

Mid-validation `AnnotationRenderer.swift` stopped compiling (`cannot find 'TextLayout' in scope`),
and once it built again, three of my Repair-4 parity tests failed by 1.5–3.5 pt — alongside Task 4's
own `testTextSizeMatchesWhatDrawTextPaints` failing on the same root cause (their renderer was
painting narrower than `textSize` reported).

Rather than widen my tolerances — which would have buried a real parity regression — I probed:
with my `usesSingleLineMode`/`.byClipping` change temporarily reverted, those three tests failed
with **identical numbers** (134.5 vs 133.0, 135.0 vs 133.0, 272.5 vs 269.0), proving the cause was
in Task 4's file and not mine. I left their file alone, waited for their repair to land, and all
three went green on their own.

### Validation (real exit codes, final state)

| Command | Result |
|---|---|
| `./scripts/bootstrap.sh` | exit 0 |
| `./scripts/build.sh` | exit 0, `** BUILD SUCCEEDED **`, no `.swift` warnings or errors |
| `./scripts/test.sh` | exit 0, `** TEST SUCCEEDED **`, **174 tests, 0 failures** |

Everything preserved: `isClosed`, the single `deliver(_:)` path, crop auto-revert, text
position/size parity, `fitEditor` tracking geometry, per-tool cursors, and the letterbox hairlines.

---

## Feature — multi-line and wrapping text

### The view: a bare `NSTextView`, no scroll view

The editor is a live preview of the committed annotation, and a preview that can scroll is one
that can show text at a position the export will not — so it is sized to its content instead and
never scrolls. It is added directly as a subview. It also drives the same TextKit 1
storage/layout-manager/container objects `AnnotationRenderer` lays out with, so line breaking is
the same code rather than a second implementation to keep in step.

Configured with `isRichText = false`, `importsGraphics = false`, `allowsUndo = false` (⌘Z belongs
to the document and the canvas takes it first; a second undo stack could only disagree),
`textContainerInset = .zero`, `lineFragmentPadding = 0`, `.byWordWrapping`,
`widthTracksTextView = true`.

Keys, via `textView(_:doCommandBy:)`: `insertNewline:` commits (the fast path is untouched),
`insertLineBreak:` inserts a line break, `cancelOperation:` cancels without closing the window.
⇧↩ inserts a plain `"\n"` rather than letting AppKit insert its U+2028 line separator — both lay
out identically, but U+2028 is a surprise to anything that later reads the string.

### Measured inset: (0, 0), and the old constant does not carry over

The `NSTextField` inset was `cellSize.width / 2` — 2 pt horizontal, 0 vertical. `NSTextView` does
not have it: text is positioned by `textContainerOrigin` plus the container's
`lineFragmentPadding`. Measured with both zeroed, `textContainerOrigin` is **(0, 0)** and the
padding is **0**, so the glyph origin is the view's frame origin. It is still read from the view
at every placement rather than hard-coded, since anything non-zero there shifts every committed
annotation, and `testEditorLineFragmentPaddingAndInsetAreZero` pins all three values.

### Wrap-width policy, and short text

Measure with `maxWidth: nil` (which already honours typed newlines); if the natural width fits in
`sourceRect.width`, commit `wrapWidth: nil` and keep the existing shift-to-fit; otherwise commit
`wrapWidth: sourceRect.width` with the origin at `sourceRect.minX`. The vertical shift then runs in
both cases, which matters more now that several lines can overflow the bottom where one could not.
Short text is therefore untouched: no wrap width, no reflow, and it still drifts left to stay whole
against an edge — `testShortTextNearAnEdgeIsNotWrapped` asserts both the `nil` wrap width and that
the origin stays where it was typed instead of jumping to the left edge.

### The editor gets the width the renderer *used*, not the width it was allowed

This is the one place I did something the brief did not describe, and it is the difference between
the feature working and quietly lying.

Handing the editor `wrapWidth × scale` looked obviously right and was wrong. Glyph advances are not
linear in point size, so at the preview's smaller font a word the renderer rejected still fits.
Measured on `"far wider than this narrow crop can ever hold"` in a 220 px crop:

| | line 1 | longest line |
|---|---|---|
| editor at `wrapWidth × scale` | `far wider than this ` | 215.6 px |
| renderer at image metrics | `far wider than ` | 199.8 px |

Same line *count*, different breaks — which no line-count assertion would have caught. The editor's
container is now `textSize(for:style:maxWidth:).width × scale`, the width the renderer's own layout
actually occupied. That closes the gap in both directions: every line the renderer kept fits,
because no line is wider than the longest one; and every word it rejected still overflows, because
the used width is stricter than the wrap width it was rejected against. After the change the breaks
agree exactly (`far wider than / this narrow crop / can ever hold`).

The **committed** `wrapWidth` remains `sourceRect.width`, not the used width — the renderer
re-derives its layout from it, and the used width is a *consequence* of that layout, not an input
to it. Committing the used width would re-wrap the text one notch tighter on every render.

A ~3 % residual remains between the editor's block width and the export's: the same characters are
genuinely ~3 % narrower at the preview font than at image metrics. That is inherent to the renderer
drawing each line at the scaled font, it is what keeps the *committed* annotation aligned with the
editor on screen, and the export is the only place image metrics are used. The wrap test's tolerance
sits between that 3 % and the ≥8 % a moved word produces.

### New tests

- `testShiftReturnStartsASecondLineUnderTheFirst` — the literal request: ⇧↩ then more text; asserts
  the committed string is `"Hello\nWorld"` and, on the exported pixels, that the second line's ink
  starts at the same x as the first (bands split from the ink box, not counted, since a descender
  can form its own band)
- `testReturnCommitsAndDoesNotInsertANewline` — the fast path
- `testOverWideStringWrapsAtTheSameBreaksInEditorAndExport` — replaces
  `testStringWiderThanTheVisibleImageClipsIdenticallyInEditorAndExport`, which asserted the old
  clipping behaviour this feature deliberately supersedes. The assertion was **replaced, not
  relaxed**: same failure mode, new contract.
- `testShortTextNearAnEdgeIsNotWrapped`
- `testMultiLineTextOverflowingTheBottomShiftsUpAndIsWholeInTheExport`
- `testEditorLineFragmentPaddingAndInsetAreZero`

### Mutation checks

| Mutation | Result |
|---|---|
| **A** — `lineFragmentPadding = 5` restored | `** TEST FAILED **`: the padding pin, the wrap-parity test, and all three editor/render parity tests. Exactly the divergence Task 4 warned about. |
| **B** — editor laid out with the allowed wrap width instead of the used width | `** TEST FAILED **`, and **only** `testOverWideStringWrapsAtTheSameBreaksInEditorAndExport` — the precise divergence, isolated. |
| **C** — ⇧↩ left to AppKit's U+2028 | `** TEST FAILED **`, and only `testShiftReturnStartsASecondLineUnderTheFirst`. |

Each applied to a scratchpad-backed copy and restored in the same command.

### Validation (real exit codes, final state)

| Command | Result |
|---|---|
| `./scripts/bootstrap.sh` | exit 0 |
| `./scripts/build.sh` | exit 0, `** BUILD SUCCEEDED **`, no `.swift` warnings or errors |
| `./scripts/test.sh` | exit 0, `** TEST SUCCEEDED **`, **183 tests, 0 failures** |

Tasks 3 and 4 had both landed before I started, so the only transient red was my own
`missing argument for parameter 'wrapWidth'` while migrating to the new `.text` case.

Everything preserved: `isClosed`, the single `deliver(_:)` path, crop auto-revert, text
position/size parity, `fitEditor` tracking geometry changes, per-tool cursors, the letterbox
hairlines, and the extent clamping.
