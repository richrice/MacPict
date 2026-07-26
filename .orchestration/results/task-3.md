# Task 3 — Annotation model and canvas geometry

## Files created (all within ownership; nothing else touched)

- `/Users/rich/Repos/MacPict/MacPict/AnnotationModel.swift`
- `/Users/rich/Repos/MacPict/MacPict/CanvasGeometry.swift`
- `/Users/rich/Repos/MacPict/MacPictTests/AnnotationModelTests.swift`
- `/Users/rich/Repos/MacPict/MacPictTests/CanvasGeometryTests.swift`

`project.yml` untouched (XcodeGen picks up the directories). No other file edited.

## Validation (real exit codes, run from `/Users/rich/Repos/MacPict`)

| Command | Exit | Notes |
|---|---|---|
| `./scripts/bootstrap.sh` | 0 | `Created project at .../MacPict.xcodeproj` |
| `./scripts/build.sh` | 0 | `** BUILD SUCCEEDED **`, zero `warning:` / `error:` lines in the log |
| `./scripts/test.sh` | 0 | `** TEST SUCCEEDED **`, 44 tests total across the whole target, 0 failures. `AnnotationModelTests` (14 tests) passed, `CanvasGeometryTests` (10 tests) passed. Only warning in the log is xcodebuild's `appintentsmetadataprocessor … No AppIntents.framework dependency found`, not a Swift compiler warning. |

## Declarations as actually written (for parallel tasks to check against)

```swift
enum AnnotationTool: String, CaseIterable, Identifiable, Sendable {
    case arrow, box, ellipse, line, text
    var id: String { rawValue }
    var symbolName: String
    var title: String
    var keyEquivalent: String
}

enum AnnotationColor: String, CaseIterable, Identifiable, Sendable {
    case red, orange, yellow, green, blue, magenta, white, black
    var id: String { rawValue }
    var nsColor: NSColor
}

enum AnnotationSize: String, CaseIterable, Identifiable, Sendable {
    case small, medium, large
    var id: String { rawValue }
    var lineWidth: CGFloat
    var fontSize: CGFloat
    var title: String
}

struct AnnotationStyle: Equatable, Sendable {
    var color: AnnotationColor
    var size: AnnotationSize
    var lineWidth: CGFloat { size.lineWidth }
    var fontSize: CGFloat { size.fontSize }
    static let `default` = AnnotationStyle(color: .red, size: .medium)
    // synthesized memberwise init(color:size:) is available
}

struct Annotation: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case line(from: CGPoint, to: CGPoint)
        case arrow(from: CGPoint, to: CGPoint)
        case box(CGRect)
        case ellipse(CGRect)
        case text(origin: CGPoint, string: String)
    }
    let id: UUID
    var kind: Kind
    var style: AnnotationStyle
    init(id: UUID = UUID(), kind: Kind, style: AnnotationStyle)
}

@MainActor
final class AnnotationDocument: ObservableObject {
    let image: CGImage
    let imageSize: CGSize                              // CGSize(width: image.width, height: image.height)
    @Published private(set) var annotations: [Annotation] = []
    @Published var tool: AnnotationTool = .arrow       // initial tool
    @Published var style: AnnotationStyle = .default   // initial style
    init(image: CGImage)
    var canUndo: Bool
    var canRedo: Bool
    var isEmpty: Bool
    func append(_ annotation: Annotation)
    func undo()
    func redo()
    func clear()
    func cycleSize(forward: Bool)
}

struct CanvasGeometry: Equatable, Sendable {
    let imageSize: CGSize
    let viewSize: CGSize
    init(imageSize: CGSize, viewSize: CGSize)
    var displayRect: CGRect
    var imageScale: CGFloat
    func imagePoint(fromView point: CGPoint) -> CGPoint
    func viewPoint(fromImage point: CGPoint) -> CGPoint
    func imageRect(fromView rect: CGRect) -> CGRect
    func viewRect(fromImage rect: CGRect) -> CGRect
    func clampToImage(_ point: CGPoint) -> CGPoint
}
```

`AnnotationModel.swift` imports `AppKit`, `CoreGraphics`, `Foundation`; `CanvasGeometry.swift`
imports `CoreGraphics`, `Foundation` only (no AppKit dependency, so it stays trivially `Sendable`).

## Concrete values chosen

| Tool | symbolName | title | keyEquivalent |
|---|---|---|---|
| arrow | `arrow.up.right` | Arrow | `1` |
| box | `rectangle` | Box | `2` |
| ellipse | `circle` | Ellipse | `3` |
| line | `line.diagonal` | Line | `4` |
| text | `textformat` | Text | `5` |

All five symbol names are asserted to resolve via `NSImage(systemSymbolName:accessibilityDescription:)`
in `testToolSymbolNamesResolveToRealSystemSymbols`, so a bogus symbol fails the test suite.

| Size | lineWidth (image px) | fontSize (image px) | title |
|---|---|---|---|
| small | 4 | 24 | Small |
| medium | 8 | 36 | Medium |
| large | 14 | 56 | Large |

Colours, all `NSColor(srgbRed:green:blue:alpha:)` with alpha 1.0 (no catalog/dynamic colours):
red `(1.0, 0.20, 0.20)`, orange `(1.0, 0.58, 0.0)`, yellow `(1.0, 0.87, 0.0)`,
green `(0.20, 0.78, 0.35)`, blue `(0.0, 0.48, 1.0)`, magenta `(1.0, 0.18, 0.80)`,
white `(1, 1, 1)`, black `(0, 0, 0)`. A test asserts each colour's CG colour space name is
`CGColorSpace.sRGB`, alpha is exactly 1.0, and the eight component triples are distinct.

## Implementation decisions

- **Undo is snapshot-based exactly as specified.** `private var undoStack: [[Annotation]]` /
  `private var redoStack: [[Annotation]]`. `append` and `clear` push the *previous* array and
  empty the redo stack; `undo`/`redo` are `popLast()`-guarded so both boundaries are no-ops.
  `clear()` is deliberately **not** guarded on `isEmpty` — the spec says it always pushes, and
  the literal reading was preferred over adding unspecified behaviour. Consequence worth
  knowing for Task 5/7: pressing ⌘⌫ on an already-empty document creates an undo entry that
  restores an empty array (a harmless but visible "undo is enabled" state). If the lead wants
  that suppressed, it is a one-line `guard !annotations.isEmpty else { return }`.
- **`keyEquivalent` is an explicit switch**, not derived from `allCases.firstIndex(of:)`, to
  avoid an unreachable `?? 0` fallback. `testToolKeyEquivalentsMatchCaseIterableOrder` locks
  the alignment with `CaseIterable` order (`tool.keyEquivalent == String(index + 1)` for every
  case), so drift fails the suite.
- **`CanvasGeometry` degeneracy is centralised** in one `private var fitScale: CGFloat?`
  (view points per image pixel, nil when either size has a non-finite or `<= 0` dimension).
  `displayRect` returns `.zero` and `imageScale` returns `1` when it is nil, so no division by
  zero and no NaN can escape. `imageScale == 1 / fitScale`, and `viewPoint(fromImage:)` divides
  by exactly the same scalar that `imagePoint(fromView:)` multiplies by, so the two are exact
  inverses up to float rounding.
- **No y-inversion anywhere** (D-2). There is a dedicated test,
  `testNoYInversionInEitherDirection`, that would fail if one were introduced.
- `clampToImage` is a plain `min(max(...))` into `[0, imageSize]`; with a degenerate negative
  `imageSize` it returns that negative bound rather than special-casing. No crash, and the
  degenerate case is not reachable from a real `CGImage`.

## Tests written

`AnnotationModelTests` (14): initial state and `imageSize` from the `CGImage`; `append` clears
the redo stack; undo/redo round-trip to an identical array (including identical `id`s);
`clear()` as a single undo step restoring all three annotations; `canUndo`/`canRedo` at both
boundaries; undo-at-bottom and redo-at-top no-ops; `cycleSize` wrapping forward and backward
across all three sizes; `cycleSize` not disturbing the colour; `AnnotationStyle.default` is
`.red`/`.medium` with `lineWidth 8`/`fontSize 36` and forwarding for every size; the exact
size metric table; tool ordering/key equivalents/ids/titles; SF Symbol resolution; colour
space, alpha and distinctness; `Annotation` identity/equality semantics.
Synthetic `CGImage` built inline via a `CGContext` helper (`XCTUnwrap`, no force-unwraps).

`CanvasGeometryTests` (10): letterboxing for a wider-than-view image
(800×600 in 400×400 → `(0, 50, 400, 300)`, scale 2); pillarboxing for a taller-than-view image
(600×800 in 400×400 → `(50, 0, 300, 400)`, scale 2); all four `displayRect` corners mapping to
`(0,0)`…`(w,h)` and back; exact inverses for interior points with `accuracy: 1e-9` in both
directions on a non-integer scale (2560×1600 in 900×700); rect conversions round-tripping;
the no-y-inversion assertion; degenerate `viewSize == .zero` giving `.zero`/`1` with no NaN;
five more degenerate combinations (zero, negative, infinite, NaN dimensions);
`clampToImage` on all four sides plus both corners and an interior no-op; `Equatable`.

## Failures encountered and corrected

1. `CGSize(width: .infinity, …)` and `XCTAssertEqual(rect, .zero)` failed to type-check inside
   a heterogeneous test array (`ambiguous use of 'infinity'`, `type 'Equatable' has no member
   'zero'`). Fixed by spelling `CGFloat.infinity` / `CGFloat.nan` / `CGRect.zero`.
2. `testTallerThanViewImageIsPillarboxed` initially expected `x = 100`; the correct centred
   origin for a 300-wide fit inside a 400-wide view is `x = 50`. The **test expectation** was
   wrong arithmetic on my part, not the code — corrected the expectation, production code
   unchanged.

## Plan gaps / unowned-caller breakage

- None. No file outside my ownership list needed changing, and nothing I added breaks an
  existing caller (these are new types with no callers yet).
- Note for Task 4/5: `AnnotationStyle` only carries `color` and `size`; the renderer's
  contrasting outline/shadow (§5.4) has no style knob and must be derived internally, as §5.4
  already implies.

## Remaining uncertainties

- The `clear()`-on-empty undo entry described above is the only intentional behavioural edge I
  would flag for the lead's judgement.
- Symbol name choices are cosmetic; all five verified to resolve on this OS.

---

# Amendment 1 — crop (§11.2, §11.5, §11.6)

## Validation (real exit codes, after the amendment)

| Command | Exit | Notes |
|---|---|---|
| `./scripts/bootstrap.sh` | 0 | regenerated the project |
| `./scripts/build.sh` | 0 | `** BUILD SUCCEEDED **`; zero `warning:`/`error:` Swift compiler lines |
| `./scripts/test.sh` | 0 | `** TEST SUCCEEDED **`, 62 tests target-wide, 0 failures. `AnnotationModelTests` 25 tests passed, `CanvasGeometryTests` 17 tests passed. The only `warning:` anywhere in the log is xcodebuild's `appintentsmetadataprocessor … No AppIntents.framework dependency found`. |

**Every pre-amendment test still passes unchanged.** The only edit to an existing test was
extending `testToolKeyEquivalentsMatchCaseIterableOrder` from `1…5` to `1…6` (the assertion
was strengthened, not weakened: full `allCases` order, ids, titles, key equivalents and
uniqueness are all still asserted, now over six cases). All ten original
`CanvasGeometryTests` are byte-identical and green, which is the regression guard the
amendment asked for on the `sourceRect` change. The one existing model test whose *behaviour*
changed by instruction is `clear()` on an empty document, now covered by a new test.

## Changes made

### `AnnotationTool`
`case crop` appended last: `case arrow, box, ellipse, line, text, crop`. `symbolName` is
`"crop"`, `title` is `"Crop"`, `keyEquivalent` is `"6"`. Arrow…text keep `1…5`. The existing
`testToolSymbolNamesResolveToRealSystemSymbols` covers `crop` too, so the symbol name is
proven to resolve on this OS rather than assumed.

### `AnnotationDocument` — new declarations, verbatim

```swift
    /// Smallest accepted crop, in image pixels, on either side.
    static let minimumCropSide: CGFloat = 16

    /// Visible sub-rect of `image`, in full-image pixels, top-left origin.
    @Published private(set) var cropRect: CGRect

    var isCropped: Bool { cropRect != fullImageRect }
    /// Size actually delivered to the agent.
    var outputSize: CGSize { cropRect.size }

    /// Annotations are never rewritten: they stay in full-image coordinates, which is what
    /// makes a nested crop and an undone crop both work without any fix-up (§11.2).
    func crop(to rect: CGRect) {
        let clamped = rect.standardized.intersection(fullImageRect)
        guard clamped.width >= Self.minimumCropSide, clamped.height >= Self.minimumCropSide else { return }
        pushUndo()
        cropRect = clamped
    }

    func resetCrop() {
        guard isCropped else { return }
        pushUndo()
        cropRect = fullImageRect
    }
```

`cropRect` is initialised to `CGRect(origin: .zero, size: imageSize)` in `init(image:)`.
`crop(to:)` uses `standardized` for normalisation (handles a right-to-left or bottom-to-top
drag) and `intersection(fullImageRect)` for clamping; a rect entirely outside the image
intersects to `.null`, whose zero extent then trips the minimum-side rejection, so
out-of-bounds and sub-minimum are handled by the same guard with no special case.

### Undo stack now carries the pair

```swift
    private struct Snapshot {
        var annotations: [Annotation]
        var cropRect: CGRect
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    private var currentSnapshot: Snapshot { Snapshot(annotations: annotations, cropRect: cropRect) }
    private func pushUndo() { undoStack.append(currentSnapshot); redoStack.removeAll() }
    private func apply(_ snapshot: Snapshot) { annotations = snapshot.annotations; cropRect = snapshot.cropRect }
```

`append`/`clear`/`crop`/`resetCrop` all funnel through `pushUndo()`; `undo()`/`redo()` push
`currentSnapshot` onto the opposite stack and `apply` the popped one. The public
`undo()`/`redo()`/`canUndo`/`canRedo` surface is byte-identical to what Tasks 4, 5 and 7 were
written against. `clear()` gained the agreed `guard !annotations.isEmpty else { return }`.

### `CanvasGeometry`

```swift
struct CanvasGeometry: Equatable, Sendable {
    let imageSize: CGSize
    let sourceRect: CGRect
    let viewSize: CGSize

    /// Uncropped: the source rect is the whole image.
    init(imageSize: CGSize, viewSize: CGSize) {
        self.init(imageSize: imageSize, sourceRect: CGRect(origin: .zero, size: imageSize), viewSize: viewSize)
    }

    init(imageSize: CGSize, sourceRect: CGRect, viewSize: CGSize)
```

`displayRect` is the centred aspect-fit of `sourceRect` in `viewSize`; `imageScale` is source
pixels per view point; conversions are
`imagePoint = sourceOrigin + (p - displayRect.origin) * imageScale` and its exact inverse,
both in **full-image** coordinates. `clampToImage` still bounds to the full image (the pinned
§5.3 contract did not change), with a test asserting that explicitly for a cropped geometry.

Degeneracy is still centralised in the single `private var fitScale: CGFloat?`, now also
gated on `isSourceUsable` (finite origin, positive finite size, and contained within
`imageSize`). One addition: `private var sourceOrigin` returns `.zero` while degenerate, so a
NaN or out-of-range source origin cannot leak into a mouse coordinate — without it a
`sourceRect` with a NaN origin would have produced NaN points even though `displayRect` and
`imageScale` were safe.

## New tests

`AnnotationModelTests` (14 → 25): `clear()` on an empty document pushes nothing (and a second
`clear()` with nothing left pushes nothing); initial crop is the full image with
`isCropped == false`, `outputSize == imageSize`, `minimumCropSide == 16`; clamping past the
top-left and past the bottom-right edges; rejection of a narrow rect, a short rect, a rect
that only becomes sub-minimum *after* clamping, and a rect entirely outside the image — each
asserted to leave `cropRect` untouched, push no undo step **and not disturb a pending redo**;
an exactly-16×16 crop is accepted; normalisation of a negative-width/negative-height drag;
crop as a single undo step restoring the previous `cropRect` and redoable; a crop after
annotations exist leaves `annotations` and their `id`s identical, before *and* after undo;
two successive nested crops undoing and redoing one at a time in order; `resetCrop()` on an
uncropped document pushing nothing, and after a crop restoring the full image as one step
that undoes back to the crop rather than past it; `undo()` restoring annotations and crop as
a consistent pair across an append/crop/append sequence; `clear()` not changing the crop.

`CanvasGeometryTests` (10 → 17): the two-argument initialiser yields
`sourceRect == CGRect(origin: .zero, size: imageSize)` and is `==` to the explicit
three-argument form (and `!=` when the source differs); with a non-zero `sourceRect`,
`imagePoint(fromView:)` returns full-image coordinates; `displayRect`'s four corners map to
`sourceRect`'s four corners and back; exact inverses under a non-zero source origin at a
non-integer scale, plus the invariant that a point inside `displayRect` maps inside
`sourceRect`; `imageRect`/`viewRect` carrying the source origin; eight degenerate
`sourceRect`s (zero, zero-width, zero-height, negative origin, overhanging right, overhanging
bottom, NaN origin, infinite width) each giving `displayRect == .zero`, `imageScale == 1` and
a NaN-free identity conversion; `clampToImage` still bounding to the full image when cropped.

## Judgement calls where §11.5 was silent

1. **`crop(to:)` with a rect equal to the current `cropRect`** is not called out as a
   rejection case, so it is *not* guarded — it pushes an undo step like any other accepted
   crop. Only the sub-minimum case is rejected, exactly as specified. Re-dragging a
   pixel-identical rect is effectively unreachable from the UI, so a guard would be dead code;
   say the word if you want the symmetry with `resetCrop()` anyway.
2. **`clampToImage` remains bound to the full image, not to `cropRect`.** §11.5 amended only
   `displayRect`, `imageScale` and the two point conversions, and §5.3's `clampToImage`
   contract is unchanged. Task 5 should be aware that clamping a drag with a crop active still
   allows points outside the visible region — which is correct, since a `⌘`-drag crop is
   itself clamped by `crop(to:)`, and annotations legitimately live in full-image space.
3. **`sourceOrigin` falling back to `.zero` while degenerate** is an addition beyond the
   literal text; without it "no NaN, no crash" would have held for `displayRect`/`imageScale`
   but not for `imagePoint(fromView:)`. It also keeps the pre-amendment degenerate tests
   passing verbatim.
4. **A `sourceRect` merely *overhanging* `imageSize` is treated as degenerate**, per "outside
   `imageSize` is degenerate", rather than being silently intersected with the image. Callers
   get `.zero`/`1` instead of a quietly different crop. `AnnotationDocument.cropRect` is
   always clamped, so a legitimate caller never hits this.

---

# Repair 1 — pixel-aligned crop rectangles

## The policy, in one sentence

A crop rect is standardised, rounded **outward** to whole image pixels (`floor` the origin,
`ceil` the max edges), then clamped to the image — once, in `AnnotationDocument`, so
`cropRect` is integral by construction and no downstream consumer ever rounds again.

## The two helpers as written

```swift
// The single rounding policy for crops. A drag on a resizable canvas produces fractional
// image coordinates, so the rect is aligned to whole pixels here, once, and every consumer
// — preview, exporter, and the W × H readout — then agrees by construction.
extension AnnotationDocument {
    /// Rounds `rect` outward to whole image pixels and clamps it to `imageSize`.
    /// Returns nil when the result is empty or does not intersect the image.
    nonisolated static func pixelAlignedRect(_ rect: CGRect, imageSize: CGSize) -> CGRect? {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0 else { return nil }

        let standardized = rect.standardized
        guard standardized.minX.isFinite, standardized.minY.isFinite,
              standardized.width.isFinite, standardized.height.isFinite,
              standardized.width > 0, standardized.height > 0 else { return nil }

        // Outward, not nearest: a crop must never lose a pixel row the user dragged over.
        let minX = max(standardized.minX.rounded(.down), 0)
        let minY = max(standardized.minY.rounded(.down), 0)
        let maxX = min(standardized.maxX.rounded(.up), imageSize.width)
        let maxY = min(standardized.maxY.rounded(.up), imageSize.height)
        guard maxX > minX, maxY > minY else { return nil }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// `pixelAlignedRect` plus the `minimumCropSide` policy.
    /// Returns nil when the crop should be rejected.
    nonisolated static func canonicalCropRect(_ rect: CGRect, imageSize: CGSize) -> CGRect? {
        // Alignment first: the accept/reject decision must be made on the rect that will
        // actually be used, not on the raw fractional one.
        guard let aligned = pixelAlignedRect(rect, imageSize: imageSize) else { return nil }
        guard aligned.width >= minimumCropSide, aligned.height >= minimumCropSide else { return nil }
        return aligned
    }
}
```

`crop(to:)` is now:

```swift
    func crop(to rect: CGRect) {
        guard let canonical = Self.canonicalCropRect(rect, imageSize: imageSize) else { return }
        pushUndo()
        cropRect = canonical
    }
```

A rejected crop still returns before `pushUndo()`, so it mutates nothing, pushes no undo step
and does not clear a pending redo — the existing test that asserts all three is unchanged and
green.

### One deviation, forced by the compiler and required by the repair's stated purpose

`AnnotationDocument` is `@MainActor`, so both helpers and `minimumCropSide` inherited main-actor
isolation and Task 4's `SnapshotExporter` (a nonisolated `enum`) could not call them:

```
MacPict/SnapshotExporter.swift:74:48: error: call to main actor-isolated static method
'pixelAlignedRect(_:imageSize:)' in a synchronous nonisolated context
```

I added `nonisolated` to `pixelAlignedRect`, `canonicalCropRect` **and**
`static let minimumCropSide` (which `canonicalCropRect` reads). The declarations are otherwise
exactly as pinned, and the spec's own rationale — "static and pure so Task 4 can call
`pixelAlignedRect` from `SnapshotExporter`" — requires it. Main-actor callers (Task 5's
toolbar, Task 7) are unaffected. The concurrent Task 4 repair compiled and its suite passes.

`CanvasGeometry` was **not** touched: it still accepts an arbitrary `sourceRect`, and the
integrality guarantee stays with the document. Annotations are still never rebased by a crop
(§11.2) — `testCroppingLeavesExistingAnnotationsIdentical` is unchanged and green.

## New tests (11 added; `AnnotationModelTests` 25 → 34)

- `testInitialCropRectIsPixelAligned` — confirms rather than assumes: the initial full-image
  rect is integral and is its own `pixelAlignedRect` fixed point.
- `testFractionalCropIsAlignedToWholePixels` — the review's own numbers, x=30.03 width=300.30
  (plus y=20.5 height=100.25) on a 400×200 image: `cropRect == (30, 20, 301, 101)`,
  `outputSize == 301 × 101` exactly, every component integral, and the aligned rect
  `contains` the requested fractional rect.
- `testFractionalCropRoundsOutwardOnEverySide` — (100.9, 50.9, 100.2, 60.2) → (100, 50, 102, 62),
  asserting containment so an inward or nearest rounding fails.
- `testFractionalCropThatAlignsPastTheEdgeIsClampedAndStaysIntegral` — aligned edges beyond the
  image are clamped, result still integral and inside `imageSize`.
- `testFractionalCropBelowTheMinimumAfterAlignmentIsRejected` — aligned width 15: no mutation,
  `isCropped == false`, `canUndo == false`.
- `testFractionalCropThatRoundsOutwardUpToTheMinimumIsAccepted` — **the ordering guard**. Raw
  size 15.2 is below `minimumCropSide`, but aligns outward to exactly 16, so the crop must be
  accepted as `(10, 10, 16, 16)`. Checking the minimum before alignment rejects 15.2 and this
  test fails; it is the test that fails under the reverse order.
- `testCanonicalCropRectAppliesTheMinimumAfterAlignment` — the same ordering property asserted
  directly on the pure helper, plus a rect that only falls below the minimum *after* clamping,
  plus the full image as a canonical fixed point.
- `testPixelAlignedRectRejectsEmptyAndNonIntersectingRects` — nil for `.zero`, zero width, zero
  height, entirely right of the image, entirely above-and-left of it, a NaN origin, and a
  degenerate `imageSize`.
- `testPixelAlignedRectNormalisesAlignsAndClamps` — fractional align, a fractional
  bottom-right-to-top-left drag, an already-integral rect returned untouched, and a partially
  out-of-bounds rect clamped.
- Plus a private `assertIntegral(_:)` helper asserting each of `minX`, `minY`, `width`,
  `height` equals its own `rounded()`.

**Every pre-repair test passes unchanged**, including all the integral-rect crop tests and all
17 `CanvasGeometryTests`.

## Validation (real exit codes)

| Command | Exit | Notes |
|---|---|---|
| `./scripts/bootstrap.sh` | 0 | |
| `./scripts/build.sh` | 0 | `** BUILD SUCCEEDED **`. First attempt exited **65** on the `SnapshotExporter` actor-isolation error quoted above; fixed with `nonisolated` and rebuilt clean. |
| `./scripts/test.sh` | 0 | `** TEST SUCCEEDED **`, **113 tests, 0 failures**, whole target. `AnnotationModelTests` 34 passed, `CanvasGeometryTests` 17 passed. Zero `warning:` lines anywhere in the log. |

All eleven suites in the target passed, including the concurrently repaired
`SnapshotExporterTests`, `AnnotationRendererTests`, `AnnotationWindowControllerTests` and
`CoordinatorTests`. No failures attributable to Task 4, 5 or 7, and no file outside my
ownership was edited.

---

# Repair 2 — no-op crop pushes no undo step

## The change

`MacPict/AnnotationModel.swift`, `crop(to:)` — one guard added after canonicalisation:

```swift
    func crop(to rect: CGRect) {
        guard let canonical = Self.canonicalCropRect(rect, imageSize: imageSize) else { return }
        // Outward pixel alignment makes two nearly-identical drags collapse to the same
        // integral rect, so a re-crop that changes nothing must not cost the user a ⌘Z.
        guard canonical != cropRect else { return }
        pushUndo()
        cropRect = canonical
    }
```

Nothing else changed. The rejection path is untouched, and `canonicalCropRect` /
`pixelAlignedRect` were not modified — Task 4's exporter depends on their exact behaviour.
This applies the same rule the model already used for `resetCrop()` on an uncropped document
and `clear()` on an empty one, and it reverses my own Amendment 1 judgement call #1, which the
lead has now decided.

## New test

`testRecroppingToTheSameAlignedRectPushesNoUndoStep` — crop to
`CGRect(x: 10.2, y: 10.2, width: 40.1, height: 40.1)`, which aligns to `(10, 10, 41, 41)`,
then crop again to `CGRect(x: 10.7, y: 10.4, width: 39.6, height: 39.8)`, a different
fractional rect that aligns to the same integral one. Asserts `cropRect` is unchanged, that a
**single** `undo()` restores the full image, and that `canUndo` is then false.

## Mutation check

Removed the new guard, rebuilt, and ran `-only-testing:MacPictTests/AnnotationModelTests`:

```
MUTATION_EXIT=65
AnnotationModelTests.swift:443: error: -[… testRecroppingToTheSameAlignedRectPushesNoUndoStep]
  : XCTAssertEqual failed: ("(10.0, 10.0, 41.0, 41.0)") is not equal to ("(0.0, 0.0, 200.0, 100.0)")
  - one undo must undo the one visible crop
AnnotationModelTests.swift:444: error: -[… testRecroppingToTheSameAlignedRectPushesNoUndoStep]
  : XCTAssertFalse failed
Executed 35 tests, with 2 failures (0 unexpected)
```

Exactly the intended result: **only** the new test failed, on the discriminating single-undo
assertion, and all 34 other model tests — every existing crop test included — still passed.
The guard was then restored and the file re-verified.

## Validation (real exit codes)

| Command | Exit | Notes |
|---|---|---|
| `./scripts/bootstrap.sh` | 0 | |
| `./scripts/build.sh` | 0 | `** BUILD SUCCEEDED **`, no Swift `warning:`/`error:` lines |
| `./scripts/test.sh` | 0 at 23:32 — **121 tests, 0 failures**, whole target green with the repair in place | |
| `./scripts/test.sh` (re-run at 23:33 and 23:34) | 65 | 122 tests, 8 failures, **all eight inside `MacPictTests/SnapshotExporterTests.swift`** — see below |

`AnnotationModelTests` 35 tests passed and `CanvasGeometryTests` 17 tests passed in **every**
one of those runs, including the failing ones.

## Not mine: concurrent Task 4 breakage, reported and untouched

The first post-repair full run (23:32) was completely green at 121 tests. The next runs, one
and two minutes later, failed with 8 failures and one `Fatal error: Index out of range` crash,
all confined to `SnapshotExporterTests`:

- `testFractionalCropRectIsAlignedByTheDocumentPolicy` — expects 301×41, gets 300×40, then
  reads a sample at `(300, 40)` outside the 300×40 image it got back, which is the crash
- `testFractionalAndPreAlignedCropRectsProduceIdenticalBytes` — 814 vs 819 bytes
- `testCropRectOutsideTheImageThrows` — gets `.imageCreationFailed`, expects `.cropOutOfBounds`

`MacPict/SnapshotExporter.swift` was rewritten at 23:33:15 and, at the time of writing, no
longer contains any `pixelAlignedRect` call, while `SnapshotExporterTests.swift` was touched
again at 23:34:19 — Task 4 is mid-edit, with its tests already asserting the shared alignment
policy its source has not yet re-adopted. Those expectations are exactly what my
`pixelAlignedRect` produces (30.03/300.30 → 301 px), so the tests are right and the exporter
is behind them.

This cannot originate from Repair 2: `crop(to:)` is never called by the exporter, and the only
symbol `SnapshotExporter` shares with me — `pixelAlignedRect` — was not modified. Per the
constraints I have reported it and touched nothing in Task 4's files. Once Task 4's edit lands,
the target should return to fully green; my two suites need no further change.

---

# Change — crop is the initial tool

## Production change (one line)

`MacPict/AnnotationModel.swift`, `AnnotationDocument`:

```swift
    // Crop first: the capture is tightened to what matters, then annotated.
    @Published var tool: AnnotationTool = .crop
```

Previously `= .arrow`. Nothing else was touched: `cropRect`, the undo model,
`canonicalCropRect`, `pixelAlignedRect`, `CanvasGeometry` and the `keyEquivalent` mapping are
all unchanged. `1`…`5` remain arrow/box/ellipse/line/text and crop remains `6`.

## Tests updated: exactly one

- `testDocumentStartsEmptyWithImagePixelSize` — `XCTAssertEqual(document.tool, .arrow)` became
  `XCTAssertEqual(document.tool, .crop)`. **Direct consequence** of the contract change. The
  assertion was inverted, not deleted, so the initial tool stays pinned by a test.

## No latent assumptions surfaced, and here is why

I searched both of my test files for every reference to `tool` and to `.arrow`. There is
exactly one other hit, in `testToolKeyEquivalentsMatchCaseIterableOrder`
(`XCTAssertEqual(AnnotationTool.allCases, [.arrow, .box, .ellipse, .line, .text, .crop])`),
which asserts declaration order rather than document state and is unaffected.

Nothing else in `AnnotationModelTests` reads or writes `document.tool` at all. That is
structural rather than lucky: `AnnotationDocument` never consults `tool` — it is pure UI state
that Task 5's canvas reads to decide what to draw — so `append`, `undo`, `redo`, `clear`,
`crop`, `resetCrop` and `cycleSize` cannot behave differently under a different default. The
tests build `Annotation` values directly and hand them to `append`, so no test path was
implicitly routed through arrow mode. `CanvasGeometryTests` does not reference
`AnnotationDocument` at all.

So the honest answer to the interesting question is: this change exposed **zero** hidden
assumptions in the files I own. The one edited assertion is the whole of it.

## Validation (real exit codes)

| Command | Exit | Notes |
|---|---|---|
| `./scripts/bootstrap.sh` | 0 | |
| `./scripts/build.sh` | 0 | `** BUILD SUCCEEDED **`, zero Swift `warning:`/`error:` lines |
| `./scripts/test.sh` | 0 | `** TEST SUCCEEDED **`, **157 tests, 0 failures**, whole target. `AnnotationModelTests` 35 passed, `CanvasGeometryTests` 17 passed. The only `warning:` in the log is xcodebuild's `appintentsmetadataprocessor … No AppIntents.framework dependency found`. |

No failures anywhere, including Task 5's concurrently edited `AnnotationCanvasView.swift` work;
nothing outside my four files was touched.

---

# Fix — clamp to the visible crop, not the full image

I flagged this exact hazard in Amendment 1, judgement call #2, before the bug shipped; the
record now closes it.

## The new declaration

`MacPict/CanvasGeometry.swift` — `clampToImage(_:)` **renamed and rebounded**, not added
alongside, so there is exactly one clamping concept and no second bound to drift:

```swift
    /// Clamps a point into `sourceRect`, the region currently visible and the only one that
    /// survives cropping into the exported image. Still full-image coordinates: this changes
    /// the bounds, not the space. A degenerate source has no meaningful bounds to clamp into,
    /// so the point passes through rather than being forced against an inverted range.
    func clampToSource(_ point: CGPoint) -> CGPoint {
        guard isSourceUsable else { return point }
        return CGPoint(
            x: min(max(point.x, sourceRect.minX), sourceRect.maxX),
            y: min(max(point.y, sourceRect.minY), sourceRect.maxY)
        )
    }
```

Degeneracy reuses the type's existing `isSourceUsable` predicate (finite origin, positive
finite size, contained in `imageSize`) rather than inventing a second rule, so the clamp can
never emit NaN or clamp against an inverted range. Note it is gated on the *source* being
usable rather than on `fitScale`, because clamping does not depend on `viewSize` — a
pre-layout geometry with a valid crop still clamps correctly.

`imagePoint`, `viewPoint`, `displayRect`, `imageScale`, the crop alignment helpers and the
full-image storage invariant are all untouched. When uncropped, `sourceRect` is the whole
image, so behaviour is bit-identical to the old method.

## Tests: 1 renamed, 1 rewritten, 1 added (`CanvasGeometryTests` 17 → 18)

- **Renamed** `testClampToImageBoundsAllFourSides` → `testClampToSourceBoundsAllFourSidesWhenUncropped`.
  Same seven assertions, unchanged values. This is the regression guard proving the rename
  changed nothing for the uncropped case.
- **Rewritten** `testClampToImageStillBoundsToTheFullImageWhenCropped` →
  `testClampToSourceBoundsToTheCropOnAllFourSides`. The old test asserted the buggy contract
  literally (`(700, 500)` returned unchanged), so it had to be inverted rather than kept. With
  a crop inset from every image edge it now asserts all four sides plus both corners clamp to
  the crop's bounds — a point left of `sourceRect.minX` clamps to `minX`, **not** to 0 — that
  an interior point and an on-edge point are returned unchanged, and that three dead-band
  points land within the crop.
- **Added** `testClampToSourceIsNaNFreeForDegenerateSourceRects` — five degenerate source rects
  (zero, zero-width, NaN origin, infinite width, overhanging the image), each asserting the
  result is NaN-free and passes through unchanged.

One self-inflicted failure worth recording: my first version of the dead-band assertion used
`CGRect.contains`, which is half-open, so a point clamped exactly onto the crop's far corner
`(300, 300)` was reported as outside. The clamp was correct and my predicate was wrong; I
replaced it with explicit inclusive bound checks rather than loosening what was being asserted.

## Mutation check

Restored the full-image bounds inside `clampToSource` and ran
`-only-testing:MacPictTests/CanvasGeometryTests`:

```
MUTATION_EXIT=65
Executed 18 tests, with 12 failures (0 unexpected)
… testClampToSourceBoundsToTheCropOnAllFourSides : XCTAssertEqual failed:
   ("(50.0, 200.0)") is not equal to ("(100.0, 200.0)") - left
   ("(700.0, 200.0)") is not equal to ("(300.0, 200.0)") - right
   ("(200.0, 20.0)")  is not equal to ("(200.0, 100.0)") - top
   ("(200.0, 500.0)") is not equal to ("(200.0, 300.0)") - bottom
   ("(0.0, 0.0)")     is not equal to ("(100.0, 100.0)") - top-left corner
   ("(800.0, 600.0)") is not equal to ("(300.0, 300.0)") - bottom-right corner
   … plus the three dead-band points reported outside the crop
```

All 12 failures are inside the crop test; the renamed uncropped test and the degenerate test
passed, confirming the guard is specific to the bug. Implementation restored and re-verified.

## Validation (real exit codes)

| Command | Exit | Notes |
|---|---|---|
| `./scripts/build.sh` (before Task 5's call site landed) | 65 | `AnnotationCanvasView.swift:331: error: value of type 'CanvasGeometry' has no member 'clampToImage'` — the expected transient breakage in Task 5's file. Reported, not touched; I polled until they switched to `clampToSource` at line 332. |
| `./scripts/bootstrap.sh` | 0 | |
| `./scripts/build.sh` | 0 | `** BUILD SUCCEEDED **`, zero Swift `warning:`/`error:` lines |
| `./scripts/test.sh` | 0 | `** TEST SUCCEEDED **`, **162 tests, 0 failures**, whole target. `AnnotationModelTests` 35 passed, `CanvasGeometryTests` 18 passed. Only `warning:` in the log is the usual `appintentsmetadataprocessor` note. |

162 rather than 161 because this change adds one net new test. No `clampToImage` reference
remains anywhere in the repository.

---

# Change — text annotations carry a wrap width

## The case as written

`MacPict/AnnotationModel.swift`, `Annotation.Kind`:

```swift
        /// `wrapWidth` is in image pixels; nil means no wrapping, honouring only explicit
        /// newlines. It is frozen at commit time and stored rather than derived from the
        /// current crop, so undoing a crop can never silently reflow committed text.
        case text(origin: CGPoint, string: String, wrapWidth: CGFloat?)
```

That is the entire production change. `cropRect`, the undo model, the alignment helpers,
`clampToSource` and `CanvasGeometry` are all untouched. `wrapWidth` is in image pixels, the
same space as every other geometry value in the type, so it scales with the rest of the
annotation and needs no separate conversion.

## Tests: 0 updated, 2 added (`AnnotationModelTests` 35 → 37)

Nothing in my two test files needed a mechanical fix, because **none of them constructed or
matched `.text`** — the model suite exercises undo, crop and style behaviour with `.box` and
`.line` values, and `CanvasGeometryTests` never touches `Annotation` at all. The `.text`
construction sites were `AnnotationCanvasView.swift`, `AnnotationRenderer.swift`,
`AnnotationRendererTests.swift` and `AnnotationWindowControllerTests.swift`, all owned by
Tasks 4 and 5.

Added:

- `testTextAnnotationEqualityDistinguishesWrapWidth` — same width compares equal; **different**
  widths do not; `nil` versus a numeric width differs in both directions; `nil` versus `nil`
  compares equal. This is the assertion that stops undo/redo silently collapsing two different
  layouts into one.
- `testWrapWidthSurvivesUndoAndRedo` — a wrapped (120) and an unwrapped (`nil`) text annotation
  appended, undone to empty, redone, then destructured to confirm the widths came back as `120`
  and `nil` respectively. The snapshot undo stack copies whole `Annotation` values, so this
  passes structurally, but it pins the property against any future stack change.

## Did anything break non-mechanically?

**No — and this time there was nothing mechanical either.** Zero tests of mine broke, for the
reason given above: my suites never constructed a `.text` annotation, so the signature change
was invisible to them. The interesting category is empty for this change. (For contrast, the
crop-default change had exactly one mechanical update and no hidden assumptions; this one has
neither.)

## Validation (real exit codes)

| Command | Exit | Notes |
|---|---|---|
| `./scripts/build.sh` (immediately after my edit) | 65 | `AnnotationCanvasView.swift:531:78: error: missing argument for parameter 'wrapWidth' in call` — the expected transient break in Task 5's file. Task 4's renderer had already landed `case let .text(origin, string, wrapWidth)`. Reported, not touched. |
| `./scripts/build.sh` (while polling) | 65 | Task 5's own in-flight errors, unrelated to me: `NSTextContainer has no member 'widthTracksTextContainer'`, `cannot assign value of type 'AnnotationCanvasView' to type '(any NSTextViewDelegate)?'`. Polled until clean. |
| `./scripts/bootstrap.sh` | 0 | |
| `./scripts/build.sh` | 0 | `** BUILD SUCCEEDED **`, zero Swift `warning:`/`error:` lines |
| `./scripts/test.sh` | 0 | `** TEST SUCCEEDED **`, **184 tests, 0 failures**, whole target green |

A later re-run (Tasks 4 and 5 still editing) exited 65 with 10 failures, **all** in
`AnnotationRendererTests.swift`, `SnapshotExporterTests.swift` and
`AnnotationWindowControllerTests.swift` — their in-flight wrap tests
(`testAnnotationWrapWidthReachesTheRendererThroughDraw`,
`testExportedPNGBreaksLinesLikeADirectDrawTextCall`,
`testOverWideStringWrapsAtTheSameBreaksInEditorAndExport`). Reported, not touched.

`AnnotationModelTests` 37 passed and `CanvasGeometryTests` 18 passed in **every** run,
including the ones that were red elsewhere.
