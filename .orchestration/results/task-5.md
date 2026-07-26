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
