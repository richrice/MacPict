# Task 4 — Annotation renderer and PNG exporter

## Files created (nothing outside the ownership list was touched)

- `MacPict/AnnotationRenderer.swift`
- `MacPict/SnapshotExporter.swift`
- `MacPictTests/AnnotationRendererTests.swift`
- `MacPictTests/SnapshotExporterTests.swift`

`git status --porcelain` shows no modification outside those four paths (the repo is still
one empty commit, so everything is untracked; no other worker's file appears as changed by
me). `project.yml` was not edited — XcodeGen picks the new files up from the directory globs.

## Validation (real exit codes, final run on the restored sources)

```
./scripts/bootstrap.sh   -> 0
./scripts/build.sh       -> 0     ** BUILD SUCCEEDED **
./scripts/test.sh        -> 0     ** TEST SUCCEEDED **, Executed 80 tests, 0 failures
```

Zero Swift warnings in either log. The only `warning:` line anywhere is the pre-existing
`appintentsmetadataprocessor: Metadata extraction skipped. No AppIntents.framework
dependency found.`, which is emitted by Xcode's tooling, not by the compiler, and predates
this task.

My two suites: `AnnotationRendererTests` 8 tests, `SnapshotExporterTests` 10 tests, all
passing. No test from any other worker failed, so I had nothing to report as Task 3/5
breakage.

## Declarations as actually written

```swift
enum AnnotationRenderer {
    static let arrowHeadLengthFactor: CGFloat = 4.0
    static let arrowHeadAngle: CGFloat = .pi / 7
    static func draw(_ annotations: [Annotation], in context: NSGraphicsContext, scale: CGFloat)
    static func draw(_ annotation: Annotation, in context: NSGraphicsContext, scale: CGFloat)
    static func font(for style: AnnotationStyle, scale: CGFloat) -> NSFont
    static func textAttributes(for style: AnnotationStyle, scale: CGFloat) -> [NSAttributedString.Key: Any]
    static func textSize(for string: String, style: AnnotationStyle) -> CGSize
    // Addition beyond the pinned contract, see "Deviations" below:
    static func arrowHead(from: CGPoint, to: CGPoint, lineWidth: CGFloat) -> (left: CGPoint, right: CGPoint)?
}

enum SnapshotExporterError: Error, Equatable {
    case bitmapContextCreationFailed
    case imageCreationFailed
    case pngEncodingFailed
    case cropOutOfBounds
}

enum SnapshotExporter {
    static func flatten(image: CGImage, annotations: [Annotation]) throws -> CGImage
    static func png(image: CGImage, annotations: [Annotation]) throws -> Data
    static func flatten(image: CGImage, annotations: [Annotation], cropRect: CGRect?) throws -> CGImage
    static func png(image: CGImage, annotations: [Annotation], cropRect: CGRect?) throws -> Data
}
```

Everything is nonisolated (no `@MainActor`, no `nonisolated(unsafe)`, no global mutable
state). Under `SWIFT_STRICT_CONCURRENCY = complete` this compiles clean: `NSGraphicsContext`,
`NSBezierPath`, `NSColor`, `NSFont` and `NSAttributedString` drawing are not actor-isolated in
this SDK (`NSGraphicsContext.h` carries no `NS_SWIFT_UI_ACTOR`), so nothing had to be forced.
`AnnotationRenderer.draw` swaps `NSGraphicsContext.current` (per-thread) around the drawing
and restores both it and the context's graphics state on exit.

The two-argument exporter entry points delegate to the three-argument ones with
`cropRect: nil`. Export order is exactly the shape mandated by the task: base image drawn in
native bottom-left space inside `saveGState`/`restoreGState`, *then* `translateBy(0, h)` +
`scaleBy(1, -1)`, then `AnnotationRenderer.draw(..., in: NSGraphicsContext(cgContext:
flipped: true), scale: 1.0)`. The renderer contains no flip of its own and no
flip-internally convenience overload.

## `CGImage.cropping(to:)` origin convention — empirically determined, TOP-LEFT

**The plan's assumption is correct: `cropping(to:)` interprets the rect with a top-left
origin (row 0 = the image's top row), matching our storage convention. No code change was
needed.**

How it was proved, rather than assumed:

- `RenderTestSupport.coordinateImage(width:height:)` builds a `CGImage` from raw bytes in
  which every pixel encodes its own coordinates — red == x, green == y — with the byte rows
  written first-row-first. A crop taken from the wrong half of the image therefore reports
  *wrong numbers*, not a plausible-looking picture.
- `testCropUsesTopLeftOriginAndKeepsTheCorrectRegion` crops `CGRect(x: 30, y: 10, width: 40,
  height: 20)` out of a 200×100 image and asserts that output pixel (0,0) still reads
  (r:30, g:10), that (39,19) reads (69,29) and that (10,5) reads (40,15).
- **Mutation-tested.** I temporarily replaced the crop rect with its bottom-left equivalent
  (`y' = height - maxY`) and re-ran: that test failed with green reading 70 where 10 was
  expected (and 89 vs 29, 75 vs 15), and
  `testCropRectPartlyOutsideTheImageIsClampedRatherThanRejected` and
  `testAnnotationOutsideTheCropDoesNotAppear` failed too. The production file was then
  restored and byte-compared against the pre-mutation copy.

The one thing this cannot prove from inside the process is the absolute meaning of "top": the
test suite pins that CGImage byte row 0, `CGBitmapContext` buffer row 0 and
`RenderPixelBuffer.pixel(y: 0)` all denote the same row
(`testTopRowOfRawBytesReadsBackAsTheTopRow`), and ties that row to "the top of the picture"
through `CGContext.draw(image:in:)` in native CG space, which is the one orientation fact
nothing in this app disputes. I have not visually inspected an exported PNG in Preview; that
remains a manual check.

## Other mutation tests run (proof the assertions are load-bearing)

| Injected bug | Result |
|---|---|
| `AnnotationRenderer.draw` applies its own y-flip (the D-1 violation) | 5 failures: renderer box placement, text right-side-up, scale, zero-length-arrow locality, and the end-to-end exported-PNG placement test |
| Arrow head drawn at the `from` end instead of `to` | `testArrowHeadIsDrawnAtTheToEnd` failed (320 vs 807 ink pixels) |
| `cropping(to:)` fed a bottom-left rect | 3 crop tests failed, as above |

Each mutation was reverted from a pre-mutation copy and verified identical with `diff` before
the final validation run.

## Implementation decisions

- **Text legibility: a contrasting stroke outline, not a shadow.** `textAttributes` sets
  `.strokeWidth: -8.0` (negative == fill *and* stroke in AppKit) with `.strokeColor` chosen
  by the relative luminance of the text colour (`0.2126R + 0.7152G + 0.0722B > 0.5` → black
  outline, else white). Reason for outline over shadow: AppKit reads `.strokeWidth` as a
  *percentage of the font size*, so the outline scales with the `scale` parameter for free
  and the canvas preview and the export are identical by construction. A shadow's blur radius
  is absolute, so it would need to be scaled by hand — a second place where preview and export
  could silently diverge, which is exactly what D-1 exists to prevent — and it smears at
  preview scale. For the pinned palette this yields white outlines on red/blue/magenta/black
  and black outlines on yellow/orange/green/white.
- **Export colour space is sRGB**, chosen explicitly rather than inherited from the source
  image, because `AnnotationColor` is defined in sRGB and the exported annotation colours must
  be exactly what was specified. Consequence to be aware of: a Display-P3 screen capture is
  converted to sRGB on export, so very saturated source pixels can shift slightly. That is a
  deliberate trade (deterministic annotation colour over source-gamut preservation) and a
  one-line change if the lead wants the opposite.
- **PNG encoding via ImageIO** (`CGImageDestination`) rather than `NSBitmapImageRep`, so the
  bytes come straight from the `CGImage` with no AppKit representation round trip.
- **Crop clamping**: `cropRect.standardized`, rejected with `.cropOutOfBounds` when it does
  not `intersects` the image (which also covers empty/zero-size rects), otherwise
  `intersection(bounds).integral`. `.integral` cannot escape the image bounds because the
  bounds are themselves integral, and it makes "output dimensions == cropRect.size exactly"
  true for the integral rects the document produces.
- **No guards on `scale`.** `CanvasGeometry.imageScale` already returns 1 for degenerate
  input, so a defensive `scale > 0` check would only hide a caller bug.

## Deviation from the pinned contract (one, additive)

`AnnotationRenderer.arrowHead(from:to:lineWidth:) -> (left: CGPoint, right: CGPoint)?` is
internal API that the plan does not list. It exists because the acceptance criteria require
*proving* that a zero-length arrow produces no NaN, and a NaN coordinate in CoreGraphics is
silently dropped rather than crashing — a pixel-only test would pass vacuously. Exposing the
head geometry lets `testZeroLengthArrowHasNoHeadAndNoNaN` assert `nil` for a zero-length drag
and finite coordinates otherwise. `draw` uses the same function, so the test covers the real
code path. If the lead prefers it private, the test loses its only non-vacuous assertion.

## Shared test helper (worth knowing for review)

`RenderPixelBuffer` and `RenderTestSupport` are declared at the top of
`MacPictTests/AnnotationRendererTests.swift` and are also used by
`MacPictTests/SnapshotExporterTests.swift` (same test target). Both suites must read real
pixels, and two copies of the read-back machinery would be free to drift; the anchor test
that pins the row convention would then only anchor one of them. Names are prefixed `Render*`
to avoid colliding with other workers' test files.

## Uncertainties / not done

- The renderer has never been exercised by `AnnotationCanvasView` — Task 5 owns that file and
  was still in flight. The claim "preview matches export" rests on the contract plus the fact
  that both callers hand the renderer a top-left/flipped context; only Task 5's canvas can
  confirm the other half in practice.
- No visual inspection of an exported PNG (see the origin-convention caveat above).
- `SnapshotExporter` allocates a full-size RGBA bitmap per export. For a 5K display that is
  ~60 MB transiently, on a one-shot path, which §11.4 explicitly accepts. Not measured on
  real capture data.
- `textSize(for:style:)` measures with `NSAttributedString.size()`, which is typographic
  advance/line height, not an ink bounding box. A glyph with a large negative side bearing
  could paint a pixel or two outside the reported box. That matters only if Task 5 relies on
  the box for hit-testing; nothing in this task does.

---

## Repair 1 — single crop rounding policy

### What changed

`MacPict/SnapshotExporter.swift`, `flatten(image:annotations:cropRect:)` only. The block

```swift
let bounds = CGRect(origin: .zero, size: pixelSize)
let requested = cropRect.standardized
guard requested.intersects(bounds) else { throw SnapshotExporterError.cropOutOfBounds }
guard let cropped = flattened.cropping(to: requested.intersection(bounds).integral) else { ... }
```

became

```swift
guard let aligned = AnnotationDocument.pixelAlignedRect(cropRect, imageSize: pixelSize) else {
    throw SnapshotExporterError.cropOutOfBounds
}
guard let cropped = flattened.cropping(to: aligned) else {
    throw SnapshotExporterError.imageCreationFailed
}
```

`.integral` is gone, along with the exporter's own `.standardized`, `intersects` and
`intersection` handling — `pixelAlignedRect` performs all of it. `pixelAlignedRect` is used,
not `canonicalCropRect`, so the `minimumCropSide` gesture policy is not applied to
programmatic crops. `nil` maps to `.cropOutOfBounds`, which preserves the previous behaviour
for non-intersecting and empty rects. A comment states the non-obvious part: the call is
idempotent on the real path because `AnnotationDocument.crop(to:)` already aligned the rect,
and it exists so the exporter has no second opinion.

**Confirmation that no rounding of crop geometry remains anywhere in `SnapshotExporter`:**
`grep -n "integral\|rounded\|floor\|ceil\|\.standardized" MacPict/SnapshotExporter.swift
MacPict/AnnotationRenderer.swift` returns nothing. The only geometry the exporter now derives
itself is `pixelSize` from `image.width/height`, which are already integers.

### New tests

- `testFractionalCropRectIsAlignedByTheDocumentPolicy` — crops the review's numbers
  (x = 30.03, width = 300.30, plus y = 10.4, height = 40.2) out of a 400×200
  coordinate-encoded image, asserts `AnnotationDocument.pixelAlignedRect` yields
  `(30, 10, 301, 41)`, that the decoded PNG measures exactly 301×41, **and** that the first
  and last output pixels report source coordinates (30,10) and (330,50) — so the offset is
  pinned, not just the size.
- `testFractionalAndPreAlignedCropRectsProduceIdenticalBytes` — the fractional rect and
  `CGRect(x: 30, y: 10, width: 301, height: 41)` produce byte-identical PNG `Data` (with an
  annotation present, so the comparison covers drawn content as well as the base image).

Supporting helpers added to the same file: `makeWideImage()` (400×200, red == x % 256,
green == y % 256, blue == 128) and `assertWideCoordinatePixel`. The eight pre-existing
exporter tests are unchanged and still pass; so are the eight renderer tests.

### Mutation check — the requested one does NOT fail, and that is a real finding

I ran the requested check and I am not going to report it as a pass it was not.

1. **Restored the literal `.integral` implementation.** All 12 exporter tests, including both
   new ones, **still passed**. The reason is that `CGRect.integral` is *itself* outward
   rounding — floor the origin, ceil the max edges — which is the same policy
   `pixelAlignedRect` implements. For the review's own worked example both produce
   `(30, 10, 301, 41)`. I probed the edge cases too (fractional rect straddling the image
   edge, sub-pixel rect, zero-width rect, negative origin) and could not construct an input
   where the old exporter and `pixelAlignedRect` disagree.

   So the exporter's `.integral` was never producing a *different* number from the fixed
   policy; the "301 vs 300" divergence the review describes was between the toolbar readout's
   nearest-rounding `Int(_.rounded())` and outward alignment, and that lives in Task 3/Task 5
   code. What was genuinely wrong on my side, and is now fixed, is that the exporter
   **owned a duplicate copy of the policy** — free to drift the moment anyone changed the
   document's rule, with no test tying the two together. The repair is de-duplication, and
   the value of the new tests is that they now fail if the exporter ever diverges from
   `AnnotationDocument.pixelAlignedRect`.

2. **Therefore I ran a second, discriminating mutation**: nearest rounding
   (`clipped.minX.rounded()`, `clipped.width.rounded()`, …), i.e. exactly the toolbar's
   policy. Both new tests failed, with the review's own numbers:
   `XCTAssertEqual failed: ("300") is not equal to ("301")` and
   `("40") is not equal to ("41")`, plus
   `("814 bytes") is not equal to ("819 bytes")` for the byte-identity test. The tests are
   load-bearing against the policy question that actually matters.

Both mutations were reverted from a pre-mutation copy and `diff`-verified identical before
the final run.

### Cross-task note

`AnnotationDocument.pixelAlignedRect` initially landed inside a plain `extension` of the
`@MainActor` class, so it was main-actor-isolated and the build failed with
`call to main actor-isolated static method 'pixelAlignedRect(_:imageSize:)' in a synchronous
nonisolated context`. I did not work around it (marking `SnapshotExporter` `@MainActor` would
have changed a pinned §5.5 contract). Task 3 marked it `nonisolated static` within a couple
of minutes and the build went green. `SnapshotExporter` remains fully nonisolated.

### Validation (real exit codes, final run on restored sources)

```
./scripts/bootstrap.sh   -> 0
./scripts/build.sh       -> 0     ** BUILD SUCCEEDED **
./scripts/test.sh        -> 0     ** TEST SUCCEEDED **, Executed 120 tests, 0 failures
```

Zero Swift warnings (only the pre-existing appintentsmetadataprocessor note). The suite is at
120 tests rather than 99 because Tasks 3, 5 and 7 landed their own repairs concurrently; 20
of them are mine (8 renderer + 12 exporter), all passing.

---

## Repair 2 — bounded pixel sampling in test helpers

Test-infrastructure only. **No production source was changed**: `SnapshotExporter.swift` and
`AnnotationRenderer.swift` are byte-identical to their post-Repair-1 state (`diff`-verified
against pre-mutation copies after the demonstration run).

### The change, and which layer I guarded

I guarded **both** layers, because they solve different halves of the problem.

1. **`RenderPixelBuffer.pixel(x:y:file:line:)`** in
   `MacPictTests/AnnotationRendererTests.swift` — the shared layer, so *every* call site is
   trap-proof, not just the two named in the specification. It now bounds-checks all four
   edges, calls `XCTFail` and returns a `(0, 0, 0, 0)` sentinel. The sentinel cannot make a
   run go green: `XCTFail` has already failed the test before it is returned. This matters
   because the two coordinate-assert helpers were not the only unguarded consumers —
   `isAnnotationInk` (4 call sites, including the crop-edge tests) and
   `RenderPixelBuffer.isInk` also index by explicit coordinates. `inkCount(in:)` was already
   bounds-checked and is unchanged.
2. **`assertCoordinatePixel` and `assertWideCoordinatePixel`** in
   `MacPictTests/SnapshotExporterTests.swift` — the explicit guard from the specification,
   which returns early so a single out-of-range sample yields one clean failure instead of
   two derived ones.

`isInk`, `isAnnotationInk` and both assert helpers now forward `file:`/`line:` down into
`pixel`, so an out-of-range sample is attributed to the calling **test**, not to the helper.

### Mutation output, before and after

Mutation used: nearest rounding substituted for the document's outward alignment, inside
`SnapshotExporter.flatten` (my own file — I did not touch `AnnotationModel.swift`, which
Task 3 owns and is editing concurrently). It makes the crop come back 300×40 where the tests
expect 301×41, so `assertWideCoordinatePixel(at: (x: 300, y: 40))` samples one past both edges.

**Before** (`exit 65`):

```
... testFractionalCropRectIsAlignedByTheDocumentPolicy : XCTAssertEqual failed: ("300") is not equal to ("301")
... testFractionalCropRectIsAlignedByTheDocumentPolicy : XCTAssertEqual failed: ("40") is not equal to ("41")
Swift/ContiguousArrayBuffer.swift:692: Fatal error: Index out of range
2026-07-25 23:33:27.550300-0500 MacPict[35670:403424] Swift/ContiguousArrayBuffer.swift:692: Fatal error: Index out of range
[Default] Unable to initialize test bundle from .../MacPictTests.xctest
[Default] Failed to load test bundle from .../MacPictTests.xctest: (null)
```

`Test Suite 'SnapshotExporterTests' started` appears with **no matching `failed`/`passed`
line**; only 11 of its 12 cases ever reported (`testPNGDecodesBackToTheInputDimensions`
never ran); there is **no whole-run `Executed N tests` total at all**, because the host died
and the relaunch could not reload the bundle. In this environment the relaunch failed to load
the bundle rather than printing the re-review's `Restarting after unexpected exit` line — the
same process death, reported slightly differently.

**After** (`exit 65`, mutation still applied):

```
SnapshotExporterTests.swift:169: error: ... testFractionalCropRectIsAlignedByTheDocumentPolicy : XCTAssertEqual failed: ("300") is not equal to ("301")
SnapshotExporterTests.swift:170: error: ... testFractionalCropRectIsAlignedByTheDocumentPolicy : XCTAssertEqual failed: ("40") is not equal to ("41")
SnapshotExporterTests.swift:176: error: ... testFractionalCropRectIsAlignedByTheDocumentPolicy : failed - sample (x: 300, y: 40) outside 300x40
Test Suite 'SnapshotExporterTests' failed at 2026-07-25 23:34:32.136.
	 Executed 122 tests, with 6 failures (0 unexpected) in 2.033 (2.090) seconds
```

No `Fatal error`, no `Restarting after unexpected exit`, no bundle-reload failure. All 12
exporter cases reported, the suite emitted its summary, and the whole-run total came from a
single launch. Line 176 is the **calling test's** line, and the message states both the
sample and the actual buffer size — which names the real defect (the crop is 300 px wide, not
301) directly.

### Validation (real exit codes, mutation reverted)

```
./scripts/bootstrap.sh   -> 0
./scripts/build.sh       -> 0     ** BUILD SUCCEEDED **
./scripts/test.sh        -> 0     ** TEST SUCCEEDED **, Executed 125 tests, 0 failures
```

Zero Swift warnings (only the pre-existing appintentsmetadataprocessor note). 20 of the 125
are mine — 8 `AnnotationRendererTests` and 12 `SnapshotExporterTests`, unchanged in count
since Repair 1, since this repair hardens existing helpers rather than adding cases. The
total is 125 rather than 120 because Tasks 3 and 5 landed further tests while I worked; no
failure appeared in their files during any of my runs.

---

## Repair 3 — remove the text outline

User-reported defect: red text looked plain in the live editor and gained a white outline the
instant Return was pressed. The outline was real, the mismatch was the bug — the editor is the
preview and it was lying. Resolved the user's way: the render now matches the editor.

### Production change (`MacPict/AnnotationRenderer.swift`, the only production file touched)

- `textAttributes(for:scale:)` now returns `.font` and `.foregroundColor` only. `.strokeColor`
  and `.strokeWidth` are gone, so text is filled in `style.color` with no stroke.
- `private static let textOutlinePercent: CGFloat = 8.0` removed.
- `private static func outlineColor(for:) -> NSColor` removed — the relative-luminance helper.
  **No dead code remained**: `grep -rn "outline\|Outline\|strokeWidth\|strokeColor\|
  textOutlinePercent" --include="*.swift" .` now matches only the doc comment on
  `textAttributes` and the new test's name/messages. `outlineColor` had exactly one caller
  (`textAttributes`) and `textOutlinePercent` exactly one (the same line), both deleted.
  Note Swift does not warn on an unused `private static func`, so the build would have stayed
  green with the helper orphaned; the grep is the check, not the compiler.
- The doc comment no longer describes an outline. It states the fill-only behaviour and, in
  one sentence, why the outline was removed (it appeared only on commit and diverged from the
  live editor).

`SnapshotExporter.swift` unchanged.

### Assertions removed or rewritten, and why each is genuinely obsolete

`MacPictTests/AnnotationRendererTests.swift`

- **Deleted `testTextCarriesAContrastingOutline` entirely** (was lines 249-259), with all four
  of its assertions: `strokeWidth < 0` for a light colour, `strokeWidth < 0` for a dark colour,
  `strokeColor == .black` for yellow, `strokeColor == .white` for blue. Every one of them
  asserted the *presence* and *polarity* of behaviour that the user has now told us is wrong.
  There is no weaker-but-still-true version of "the glyphs carry a contrasting outline" — the
  proposition is now false, not imprecise. This is deletion because the contract changed, not
  because the assertions were inconvenient; the replacement below asserts the *opposite*
  proposition just as strictly, so nothing became unpinned.
- **Added `testTextRendersFillOnlyWithNoOutline`** in its place. It asserts, for yellow and
  blue: `foregroundColor == color.nsColor`, `attributes[.strokeWidth] == nil`,
  `attributes[.strokeColor] == nil`. Then a pixel proof rather than an attribute-only one:
  yellow "Hgy" at 56 px on a white ground, scanning all 300x160 pixels, asserting
  `fillPixels > 0` (r,g > 200, b < 100 — the glyphs really are yellow ink) and
  `darkPixels == 0` (r,g,b all < 100). The removed outline was black for a light colour like
  yellow, so it painted exactly those dark pixels.
- **No assertion was loosened.** `testTextRendersRightSideUp` and `testFontAndTextSizeScale`
  are untouched and still pass unmodified: the first samples black text on white, where the
  ink was the *fill* in both regimes (black's outline was white and invisible on white), and
  the second compares `textSize` against a freshly measured `NSAttributedString` and asserts
  `height >= style.fontSize` — no exact pre-change size anywhere.

**Mutation-tested, so the new test is load-bearing.** I re-added
`.strokeColor: NSColor.black, .strokeWidth: -8.0` to `textAttributes` and re-ran: `exit 65`,
`Executed 125 tests, with 5 failures`, all five inside `testTextRendersFillOnlyWithNoOutline` —
`XCTAssertNil failed: "-8.0"` and `XCTAssertNil failed: "…colorspace 0 1"` once per colour,
plus `XCTAssertEqual failed: ("2555") is not equal to ("0") - dark pixels mean the glyphs carry
a contrasting outline`. 2555 outline pixels vs 0 is a wide margin, not a threshold that barely
trips. The mutation was reverted from a pre-mutation copy and `diff`-verified identical before
the final run.

### `SnapshotExporterTests` — checked, nothing depended on outline ink

`grep -n "text\|Text" MacPictTests/SnapshotExporterTests.swift` returns **nothing**. That suite
draws only boxes and arrows, so no orientation or placement assertion there sampled a pixel
that happened to be outline rather than fill. Nothing to fix, and I did not change the file.

### `textSize` shift — nothing asserts an exact pre-change size

`textSize(for:style:)` measures through `textAttributes`, so dropping the stroke changes the
measurement very slightly (AppKit's advance is stroke-aware). `grep -rn "textSize"` across all
sources and tests shows three call sites: the definition, `testTextRendersRightSideUp` (which
derives its sample rectangle from the measurement, so it tracks the change automatically), and
`testFontAndTextSizeScale` (relative assertions only). No production caller outside the
renderer uses it. All eight renderer tests pass unchanged apart from the one replacement.

### Requested finding — editor vs render font parity

**They agree exactly on family, weight and size. Nothing to route to Task 5 on this point.**
`AnnotationCanvasView.beginTextEditing` (line 310) sets the editor font with
`AnnotationRenderer.font(for: style, scale: 1 / geometry.imageScale)` — literally my function,
not a reconstruction — and `AnnotationCanvasView.draw` (line 119-120) renders with
`scale = 1 / geometry.imageScale`, the same expression. Both therefore resolve to
`NSFont.systemFont(ofSize: style.fontSize / geometry.imageScale, weight: .semibold)`: one
typeface, one weight, one point size, by construction. Colour matches too
(`field.textColor = style.color.nsColor` vs `.foregroundColor: style.color.nsColor`).

Two residual divergences I noticed while checking, **reported not fixed**, both in Task 5's
file:

1. **Glyph position, not typeface.** The render draws the attributed string with its layout
   box top-left at the origin, while `NSTextField` draws inside a cell that insets the text a
   couple of points horizontally and centres it in a frame of
   `ceil(ascender - descender + leading) + 4`. So committed text can shift by ~2 pt relative to
   where it sat while typing. Same class of defect as the outline, far smaller in magnitude.
2. **Window resize during editing.** The field's font is fixed at `beginTextEditing` from the
   `imageScale` of that moment and never refit; the committed render uses the scale at draw
   time. Resizing the window mid-typing therefore changes the size on commit. Narrow, and
   pre-existing.

### Validation (real exit codes, final run on restored sources)

```
./scripts/bootstrap.sh   -> 0
./scripts/build.sh       -> 0     ** BUILD SUCCEEDED **
./scripts/test.sh        -> 0     ** TEST SUCCEEDED **, Executed 125 tests, 0 failures
```

Zero Swift warnings; the only `warning:` line in either log is the pre-existing
`appintentsmetadataprocessor: Metadata extraction skipped` note from Xcode's tooling.

**Test count: 125, unchanged from Repair 2's 125.** The delta accounts exactly: −1 for the
deleted `testTextCarriesAContrastingOutline`, +1 for the added
`testTextRendersFillOnlyWithNoOutline`. My two suites report `Executed 8 tests` for
`AnnotationRendererTests` and `Executed 12 tests` for `SnapshotExporterTests`, both identical
to Repair 2. No failure appeared in `GlobalHotkeyManager.swift`, `AppCoordinator.swift` or any
settings file during these runs, so I had nothing to report from the concurrent hotkey work.
The app was not launched.

---

## Feature — multi-line and wrapped text rendering

### New signatures (exactly as specified)

```swift
static func textSize(for string: String, style: AnnotationStyle, maxWidth: CGFloat?) -> CGSize
static func drawText(_ string: String,
                     at origin: CGPoint,
                     style: AnnotationStyle,
                     maxWidth: CGFloat?,
                     in context: NSGraphicsContext,
                     scale: CGFloat)
```

`textSize(for:style:)` now delegates with `maxWidth: nil`, and the `.text` case in `draw`
routes through `drawText(..., maxWidth: nil)`, so there is one text implementation. Both
changes are behaviour-preserving — see the causality note below for the evidence.
`SnapshotExporter.swift` was not touched.

### Layout API: TextKit 1, and why

`NSTextStorage` + `NSLayoutManager` + `NSTextContainer` (private `TextLayout` in
`AnnotationRenderer.swift`), with `lineBreakMode = .byWordWrapping`,
`maximumNumberOfLines = 0` and `lineFragmentPadding = 0`. These are the objects an
`NSTextView` drives natively, so an editor built on one breaks lines where this does; hand-
rolled measurement could only approximate it. Two facts I verified rather than assumed:

- `NSLayoutManager.usedRect(for:)` with zero padding equals `NSAttributedString.size()`
  exactly — for single-line, multi-line and empty strings — so re-routing `textSize` changed
  no measured value. That is what lets the pre-existing
  `XCTAssertEqual(measured, NSAttributedString(...).size())` assertion pass untouched.
- **The editor must set `lineFragmentPadding = 0` too.** `NSTextView` defaults it to 5
  points, which would silently narrow the wrap width by 10 and break lines earlier than the
  render does. This is the one integration requirement I am handing to whoever builds the
  editor.

Line spacing comes from the font's own metrics, so it scales with `style.fontSize` with no
separate absolute value to keep in step — the same reasoning as the old `.strokeWidth` choice.

### Deviation from the prescribed mechanism, with the measurement that forced it

The brief said to multiply `maxWidth` by `scale` at draw time, as for line widths and fonts.
**That mechanism cannot satisfy the guarantee the brief calls most important**, and I measured
it before deciding. Glyph advances are not linear in point size, so the same string laid out
at 36 pt / 200 px and at 18 pt / 100 px breaks differently:

```
scale 1.0 (36pt / 200px): ["The quick ", "brown fox ", "jumps over ", "the lazy dog"]
scale 0.5 (18pt / 100px): ["The quick ", "brown fox ", "jumps over ", "the lazy ", "dog"]
```

Four lines versus five. Under that mechanism the canvas preview and the export would break
text differently and the agent would receive something the user never saw.

So `drawText` decides **where lines break once, in image pixels**, and then draws each
resulting line at the scaled font size:

- breaking in image pixels makes line breaks identical at every scale (preview == export);
- drawing each line with the scaled font keeps glyph placement identical to the live editor,
  which lays out at that size.

Line origins come from the image-pixel layout and are multiplied by `scale`, so the vertical
rhythm is scale-invariant too. `maxWidth` remains an image-pixel value, as required.

**Causality note — this deviation was not free, and I checked it both ways.** My first
implementation laid the whole block out in image pixels and applied `scale` to the CTM. That
is cleaner, but it broke three of Task 5's tests
(`testCommittedTextLandsWhereTheEditorDrewIt`,
`testTextEditLiveAcrossAResizeCommitsAtTheSizeTheEditorWasShowing`,
`testTextEditLiveAcrossACropCommitsAtTheSizeTheEditorWasShowing`) by 1.5–3.5 px, because
`NSTextField` lays out at the scaled font size and CTM-scaling an image-pixel layout does not
reproduce that. I confirmed the cause by temporarily restoring the old drawing and watching
all three failures disappear, then adopted the split above, which keeps them passing. Note
that at `scale: 1.0` — every export — all three approaches are identical; the difference only
exists in the canvas preview.

**Follow-up for the lead, not implemented:** the fully coherent end state is for the editor to
lay out in image-pixel metrics inside a scaled view, at which point `drawText` could go back
to one CTM-scaled layout and editor, preview and export would agree by construction rather
than to within a pixel. That is a change to `AnnotationCanvasView.swift`, which I do not own.

### An over-long word

TextKit breaks a word that cannot fit **between characters** rather than overflowing or
clipping: "Supercalifragilisticexpialidocious" at 36 pt with `maxWidth: 100` measures
(97.7 × 258) — six lines, none wider than the wrap width. So painted text never crosses
`maxWidth`, however long a single word is. `testWordLongerThanMaxWidthIsBrokenBetweenCharacters`
asserts exactly that.

### New tests (all in `AnnotationRendererTests`)

- `testExplicitNewlineRendersOnSeparateLines` — two ink bands, zero ink in the gap between
  them, both lines in the same columns, and `textSize` accounting for both lines.
- `testTextWrapsAtMaxWidth` — wrapped ink is taller than unwrapped, no ink crosses the wrap
  width, unwrapped is a single band.
- `testTextSizeMatchesWhatDrawTextPaints` — the measured height is a whole number of lines,
  every one of those line boxes contains ink, the box after the last does not, and the ink is
  contained in the measured box.
- `testWrappedTextBreaksAtTheSameWordBoundariesAtEveryScale` — the WYSIWYG guarantee.
- `testWordLongerThanMaxWidthIsBrokenBetweenCharacters`.
- `testDegenerateTextInputsAreSafe` — empty string, and `maxWidth` of 0, negative, infinite
  and NaN all mean "do not wrap" rather than "collapse to nothing"; drawing them paints
  without trapping.

Two test-helper honesty notes, both of which cost me a false green or a false red:

- `RenderPixelBuffer.inkLineBands()` counts runs of inked rows, which is **not** the same as
  text lines: "jumps over" has no ascenders, so the dot of the "j" forms its own band. Tests
  that need typographic lines now slice by row window with the new `inkColumns(inRows:)`,
  which addresses a line by where its line box is and needs no guess about gap sizes. I first
  tried merging bands by a gap threshold and rejected it — a threshold big enough to swallow
  the "j" dot also merged real lines.
- `testTextSizeMatchesWhatDrawTextPaints` allows horizontal ink to exceed the typographic box
  by up to a tenth of the font size. That is not slack for convenience: the sample's "jumps"
  starts a line and the "j" has a negative left side bearing, measured at 2 px of ink left of
  the box at 36 pt. Vertical containment is asserted tightly (±1 px), where no such overhang
  exists.

### Scale-invariance mutation check

Mutation: decide the wrap at the scaled size — `maxWidth * scale` with the font also scaled,
i.e. the mechanism the brief originally prescribed. Result:

```
testWrappedTextBreaksAtTheSameWordBoundariesAtEveryScale
  : XCTAssertEqualWithAccuracy failed: ("140.0") is not equal to ("202.0") +/- ("10.0") - line 3 right edge
  : XCTAssertNil failed: "6...35"
```

The 62 px right-edge difference is exactly the word "dog" moving to a fifth line, and the
`XCTAssertNil` is that fifth line's ink appearing below the last line box at half scale. The
10 px tolerance did not absorb a 62 px word, which is the point of choosing it below the
narrowest word in the sample. No other test failed under the mutation — Task 5's editor tests
are single-line and unaffected — so the guarantee rests on this test alone, and it works.
The mutation was reverted and the file `diff`-verified against the pre-mutation copy.

### Validation

```
./scripts/bootstrap.sh   -> 0
./scripts/build.sh       -> 0     ** BUILD SUCCEEDED **
./scripts/test.sh        -> 0     ** TEST SUCCEEDED **, Executed 174 tests, 0 failures
```

Zero Swift warnings (only the pre-existing appintentsmetadataprocessor note). 26 of the 174
are mine — 14 `AnnotationRendererTests` and 12 `SnapshotExporterTests`. The total is 174
rather than 165 because other tasks landed tests while I worked; no failure remained anywhere,
including in the concurrently edited `AnnotationCanvasView.swift` / `AnnotationWindowController.swift`.
