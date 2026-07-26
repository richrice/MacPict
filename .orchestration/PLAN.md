# MacPict — Implementation Plan

## 1. Original requested outcome

A native macOS app that collapses the "screenshot → annotate → hand to an AI agent" loop
into a few keystrokes:

1. One global hotkey grabs an image of **the display the mouse pointer is currently on**.
2. The snapshot appears immediately in **its own window floating over all other windows**.
3. The user annotates it fast: **lines, boxes, circles, text, arrows**.
4. The annotated result goes to an **AI agent** — a CLI agent (Claude Code, Codex CLI) or a
   desktop app (Claude, Codex) — with no file-system round trip.

The pain being removed: macOS's built-in capture requires a chord, a multi-second delay, a
file dropped on the Desktop, an image editor not designed for annotation, an export, and a
copy-paste. Every one of those steps must be gone.

Reference project: `/Users/rich/Repos/MacDictate` — an existing XcodeGen-based, LSUIElement,
Carbon-hotkey menu-bar app by the same user. MacPict mirrors its structure and conventions.

## 2. Current system

Greenfield. `/Users/rich/Repos/MacPict` was empty. A git repository was initialized with a
single **empty** commit (`e67dbed "Initialize repository"`) so the review tooling has a `HEAD`
to diff against. No project work is committed.

### Toolchain (verified, not assumed)

| Item | Value |
|---|---|
| macOS | 26.5.2 (build 25F84) |
| Xcode | 26.6 (17F113), at `/Applications/Xcode_26.6.app` — **not** `/Applications/Xcode.app` |
| Swift | 6.3.3, default target `arm64-apple-macosx26.0` |
| SDK | `MacOSX26.5.sdk` |
| XcodeGen | 2.44.1 at `/opt/homebrew/bin/xcodegen` |
| Codex CLI | 0.145.0, authenticated, `model = gpt-5.6-sol`, `model_reasoning_effort = xhigh` |

### Known constraints that the work must account for

These were established by reading the actual SDK headers on disk and by
`swiftc -typecheck` against them. They are facts, not recollections.

**C-1 — There is no CoreGraphics capture fallback. It is a compile error, not a warning.**
`CGDisplayCreateImage`, `CGDisplayCreateImageForRect`, `CGWindowListCreateImage`, and
`CGWindowListCreateImageFromArray` are annotated
`SCREEN_CAPTURE_OBSOLETE(…, deprecated=14.x, obsoleted=15.0)` with message
*"Please use ScreenCaptureKit instead."* (`CGWindow.h:223,271,280`;
`CGDirectDisplay.h:383,391`). Compiling a reference produces
`error: 'CGDisplayCreateImage' is unavailable in macOS`. `@available` cannot rescue an
obsoleted symbol. **ScreenCaptureKit is the sole capture route. No task may add a CG
fallback "for safety" — it will not build.**

**C-2 — `SCScreenshotManager.captureImage(contentFilter:configuration:)` is macOS 14.0+.**
`SCScreenshotManager.h:147`, `NS_SWIFT_NAME(captureImage(contentFilter:configuration:completionHandler:))`.
Swift async form verified to typecheck. This is the capture primitive.

**C-3 — `"NSScreenNumber"` is not declared anywhere in the SDK.** Grepping all of
`$SDK/System/Library/Frameworks` returns zero matches. `NSGraphics.h:189-195` declares
`NSDeviceDescriptionKey` as `NS_TYPED_EXTENSIBLE_ENUM` and only six keys, none of them this
one. The string literal must be written by hand. The boxed value is an `NSNumber`; read it as
`as? NSNumber` then `.uint32Value`, **never** `as! CGDirectDisplayID`.

**C-4 — Two different global coordinate spaces are in play.** `NSEvent.mouseLocation`
(`NSEvent.h:522`, comment reads only `// global mouse coordinates`) and `NSScreen.frame`
share AppKit's bottom-left-origin space anchored at `NSScreen.screens[0]`. CoreGraphics and
`SCDisplay.frame` use a top-left-origin space. **The plan sidesteps the flip entirely by
matching displays on `CGDirectDisplayID`, never on frame geometry.** No task may introduce a
frame-based AppKit↔CG comparison.

**C-5 — `NSScreen.mainScreen` is nullable and means "screen with key window", not "primary
display"** (`NSScreen.h:26`). `NSScreen.screens[0]` is the coordinate-origin screen. Do not
conflate them.

**C-6 — Carbon `RegisterEventHotKey` is present and carries no deprecation attribute** in
this SDK (`CarbonEvents.h:15483`, `AVAILABLE_MAC_OS_X_VERSION_10_0_AND_LATER`, which expands
to nothing). Verified to compile warning-free. There is no modern replacement:
`NSEvent.addGlobalMonitorForEvents` cannot consume the event and requires Input Monitoring
TCC. Carbon is the correct choice, and it is what MacDictate already uses.
Caveat: `CarbonEvents.h` is ISO-8859 encoded, so plain UTF-8 `grep` gives false negatives.

**C-7 — `NSPasteboard.PasteboardType.png` exists** (`NSPasteboard.h:27`,
`NSPasteboardTypePNG`, macOS 10.6+, not deprecated). `NSPasteboard.h:216` warns that
`declareTypes:owner:` must **not** be mixed with `writeObjects:`. Pick one; this plan uses
`clearContents()` + `setData(_:forType:)`.

**C-8 — `SCContentFilter.pointPixelScale` and `.contentRect` are macOS 14.0+**
(`SCStream.h`). These are the authoritative points→pixels factor and content bounds for a
filter, and are more reliable than `NSScreen.backingScaleFactor` for sizing the capture.

**C-9 — Which `SCStreamErrorCode` `SCShareableContent` throws on TCC denial is *not*
specified by any header.** `SCStreamErrorUserDeclined = -3801` (`SCError.h`) is the
semantically correct candidate but is unconfirmed for this call path. Therefore permission
state is determined by `CGPreflightScreenCaptureAccess()`, and capture errors are surfaced
generically — **no task may branch on a specific `SCStreamError` code as its permission
check.**

**C-10 — `CGPreflightScreenCaptureAccess()` / `CGRequestScreenCaptureAccess()` are current**
(`CGWindow.h:295,298`, macOS 10.15+, no deprecation).

## 3. Assumptions

The user was asked to confirm the open product decisions but the question was declined, so
these are resolved conservatively and stated here. Each is a one-line change if wrong.

- **A-1 — Hotkey is `⌃⌥⌘4`,** fixed at compile time in
  `HotkeyShortcut.captureDefault`. Rationale: macOS reserves `⌘⇧3/4/5/6`; a four-modifier
  chord is effectively never claimed by third-party apps; the trailing `4` matches existing
  muscle memory. If registration fails, the failure is surfaced in the menu-bar menu rather
  than swallowed, and the menu item remains a working trigger.
- **A-2 — Capture scope is the full display under the pointer.** Literally what was asked
  for. No region select, no crop.
- **A-3 — Two delivery actions.** `⌘↩` copies the annotated PNG to the clipboard (primary —
  works with Claude Code, Codex CLI, and the Claude/Codex desktop apps, all of which accept a
  pasted image). `⌥⌘↩` writes the PNG to a temp directory and copies its POSIX path (for CLI
  flows where a path beats a binary blob). The request explicitly named both "a CLI program"
  and "a standalone program", so both are in scope.
- **A-4 — Exactly the five named tools:** line, box, ellipse, text, arrow. Plus undo/redo,
  clear, a colour palette, and a three-step size control — these are not extras, they are the
  minimum required for "quick" annotation to be usable (a mis-drawn box with no undo, or a
  red box on a red UI, defeats the purpose).
- **A-5 — Deployment target macOS 15.0.** Every API used is ≤14.0, so nothing is gated;
  15.0 sits cleanly above the C-1 obsoletion boundary, which removes any ambiguity about
  which capture APIs are legal. The user runs 26.5.
- **A-6 — Unsandboxed, hardened runtime on, `DEVELOPMENT_TEAM = M3TWZT9C7B`,** matching
  MacDictate. Screen Recording is a TCC grant, not an entitlement; there is no
  usage-description Info.plist key for it.
- **A-7 — Annotations are commit-only.** Once drawn, an annotation is not selectable,
  movable, or individually deletable. Undo/redo/clear cover the mistake case. This is a
  deliberate scope boundary, not an oversight.

## 4. Architecture

```
   ⌃⌥⌘4  ──▶ GlobalHotkeyManager (Carbon)
                    │
                    ▼
             AppCoordinator ──▶ ScreenCapturePermission (CGPreflight/CGRequest)
                    │
                    ▼
             ScreenCaptureService ──▶ DisplayLocator (mouse ▶ NSScreen ▶ CGDirectDisplayID)
                    │                       │
                    │                       ▼
                    │                 SCShareableContent ▶ SCDisplay (match on displayID)
                    │                 SCContentFilter(display:excludingApplications:[self])
                    │                 SCStreamConfiguration(pixel size from pointPixelScale)
                    │                 SCScreenshotManager.captureImage(...)
                    ▼
             CapturedSnapshot(CGImage, pixelSize, screenFrame, displayID)
                    │
                    ▼
             AnnotationDocument (model: [Annotation], tool, style, undo/redo)
                    │
        ┌───────────┴────────────┐
        ▼                        ▼
  AnnotationWindowController   SnapshotExporter
   ├ AnnotationToolbarView      └─ AnnotationRenderer  ◀── SHARED
   └ AnnotationCanvasView ─────────┘
        (isFlipped = true)                             │
                    │                                  ▼
                    ▼                            PNG @ native resolution
             DeliveryService ──▶ NSPasteboard (.png/.tiff) or temp file + path
```

### Rationale for the load-bearing decisions

**D-1 — One renderer, used by both the screen and the export.**
`AnnotationRenderer` draws into an `NSGraphicsContext` whose CTM already places the origin at
the **top-left with +y downward** and whose `isFlipped` is `true`. Two callers satisfy that
contract:

- the canvas view, because `AnnotationCanvasView.isFlipped == true`, so AppKit hands it a
  context already in that space;
- the exporter, because it applies `translateBy(x: 0, y: h)` + `scaleBy(x: 1, y: -1)` to a
  bitmap `CGContext` and wraps it in `NSGraphicsContext(cgContext:flipped: true)`.

This makes "what you saw is what you exported" a structural guarantee rather than a pair of
drawing routines someone has to keep in sync. It is the single most important design decision
here, because divergence between preview and export is the classic failure mode of this kind
of app.

**D-2 — One coordinate space for stored geometry: image pixels, top-left origin.**
Every `Annotation` stores its geometry in the captured image's pixel raster. `CanvasGeometry`
owns the *only* two conversion functions (view↔image). Because the canvas view is flipped,
both spaces share a top-left origin and the conversion is a pure scale-and-translate with no
y-inversion anywhere. Export then draws at `scale: 1.0`; the canvas draws at
`scale: 1 / geometry.imageScale`.

**D-3 — Displays are matched on `CGDirectDisplayID`, never on frames.** Per C-4, comparing
an AppKit frame to an `SCDisplay.frame` invites a silent off-by-a-screen-height bug on
multi-monitor setups. `displayID` is unambiguous in both worlds.

**D-4 — The app excludes itself from its own capture** via
`SCContentFilter(display:excludingApplications:exceptingWindows:)`, so a still-open
annotation window never appears inside the next snapshot.

**D-5 — Success feedback is a status-item flash, not a banner.** After `⌘↩` the window
closes immediately and the menu-bar icon swaps to a checkmark for ~800 ms. A modal
confirmation or an in-window banner would add latency to the exact step the app exists to
make fast.

**D-6 — AppKit for the canvas, SwiftUI for the toolbar.** Precise mouse-drag handling and an
inline text editor are materially easier and more reliable in `NSView`; the toolbar is
declarative chrome where SwiftUI is a clear win. MacDictate uses the same hybrid.

## 5. Pinned public contracts

These are frozen. Tasks implement against them in parallel; changing one requires coming back
to the lead. Every declaration below is the exact shape to write.

### 5.1 `AppLogger.swift` — Task 1

```swift
import OSLog

enum AppLogger {
    static let app: Logger
    static let capture: Logger
    static let annotation: Logger
    static let delivery: Logger
    static let hotkey: Logger
}
```
Subsystem: `Bundle.main.bundleIdentifier ?? "com.macpict.app"`. Categories match the property
names.

### 5.2 `AnnotationModel.swift` — Task 3

```swift
enum AnnotationTool: String, CaseIterable, Identifiable, Sendable {
    case arrow, box, ellipse, line, text
    var id: String { get }
    var symbolName: String { get }     // SF Symbol
    var title: String { get }
    var keyEquivalent: String { get }  // "1"…"5", in CaseIterable order
}

enum AnnotationColor: String, CaseIterable, Identifiable, Sendable {
    case red, orange, yellow, green, blue, magenta, white, black
    var id: String { get }
    var nsColor: NSColor { get }       // sRGB, alpha 1.0
}

enum AnnotationSize: String, CaseIterable, Identifiable, Sendable {
    case small, medium, large
    var id: String { get }
    var lineWidth: CGFloat { get }     // image pixels: 4, 8, 14
    var fontSize: CGFloat { get }      // image pixels: 24, 36, 56
    var title: String { get }
}

struct AnnotationStyle: Equatable, Sendable {
    var color: AnnotationColor
    var size: AnnotationSize
    var lineWidth: CGFloat { get }     // == size.lineWidth
    var fontSize: CGFloat { get }      // == size.fontSize
    static let `default`: AnnotationStyle   // .red, .medium
}

/// All geometry is in IMAGE PIXELS with a TOP-LEFT origin (y grows downward).
struct Annotation: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case line(from: CGPoint, to: CGPoint)
        case arrow(from: CGPoint, to: CGPoint)
        case box(CGRect)
        case ellipse(CGRect)
        case text(origin: CGPoint, string: String)   // origin = top-left of the text box
    }
    let id: UUID
    var kind: Kind
    var style: AnnotationStyle
    init(id: UUID = UUID(), kind: Kind, style: AnnotationStyle)
}

@MainActor
final class AnnotationDocument: ObservableObject {
    let image: CGImage
    let imageSize: CGSize              // pixels

    @Published private(set) var annotations: [Annotation]
    @Published var tool: AnnotationTool
    @Published var style: AnnotationStyle

    init(image: CGImage)

    var canUndo: Bool { get }
    var canRedo: Bool { get }
    var isEmpty: Bool { get }

    func append(_ annotation: Annotation)
    func undo()
    func redo()
    func clear()
    func cycleSize(forward: Bool)      // ] / [
}
```

Undo model is **snapshot-based**: `append` and `clear` push the *previous* `annotations`
array onto an undo stack and empty the redo stack; `undo()` moves current→redo and pops
undo; `redo()` moves current→undo and pops redo. This makes `clear()` a single undoable step
for free. Arrays of small value types; memory cost is negligible.

### 5.3 `CanvasGeometry.swift` — Task 3

```swift
/// Maps between the canvas view's space (points, TOP-LEFT origin because the
/// canvas NSView is flipped) and the image's pixel space (also TOP-LEFT origin).
/// The image is aspect-fit inside the view.
struct CanvasGeometry: Equatable, Sendable {
    let imageSize: CGSize    // pixels
    let viewSize: CGSize     // points

    init(imageSize: CGSize, viewSize: CGSize)

    var displayRect: CGRect { get }    // aspect-fit rect, view points; .zero if degenerate
    var imageScale: CGFloat { get }    // image pixels per view point; 1 if degenerate

    func imagePoint(fromView point: CGPoint) -> CGPoint
    func viewPoint(fromImage point: CGPoint) -> CGPoint
    func imageRect(fromView rect: CGRect) -> CGRect
    func viewRect(fromImage rect: CGRect) -> CGRect
    func clampToImage(_ point: CGPoint) -> CGPoint   // into [0, imageSize]
}
```
`imagePoint(fromView:)` == `((p.x - displayRect.minX) * imageScale, (p.y - displayRect.minY) * imageScale)`.
Degenerate means either dimension of `imageSize` or `viewSize` is `<= 0` or non-finite.

### 5.4 `AnnotationRenderer.swift` — Task 4

```swift
/// Draws annotations into a TOP-LEFT-origin, flipped graphics context.
/// The caller guarantees the CTM and `isFlipped`; the renderer never flips.
enum AnnotationRenderer {
    static let arrowHeadLengthFactor: CGFloat   // 4.0 × lineWidth
    static let arrowHeadAngle: CGFloat          // .pi / 7

    /// - scale: multiply image-pixel geometry by this to reach context units.
    ///   1.0 for the export bitmap; `1 / geometry.imageScale` for the canvas.
    static func draw(_ annotations: [Annotation], in context: NSGraphicsContext, scale: CGFloat)
    static func draw(_ annotation: Annotation, in context: NSGraphicsContext, scale: CGFloat)

    static func font(for style: AnnotationStyle, scale: CGFloat) -> NSFont
    static func textAttributes(for style: AnnotationStyle, scale: CGFloat) -> [NSAttributedString.Key: Any]
    static func textSize(for string: String, style: AnnotationStyle) -> CGSize   // image pixels
}
```
Text must stay legible over arbitrary screenshot content, so `textAttributes` includes a
contrasting outline/shadow. Line caps and joins are round.

### 5.5 `SnapshotExporter.swift` — Task 4

```swift
enum SnapshotExporterError: Error, Equatable {
    case bitmapContextCreationFailed
    case imageCreationFailed
    case pngEncodingFailed
}

enum SnapshotExporter {
    /// Composites `annotations` over `image` at the image's native pixel size.
    static func flatten(image: CGImage, annotations: [Annotation]) throws -> CGImage
    static func png(image: CGImage, annotations: [Annotation]) throws -> Data
}
```
Export order: draw `image` in native bottom-left CG space (correct orientation), *then* apply
the flip and hand the wrapped `NSGraphicsContext` to `AnnotationRenderer` at `scale: 1.0`.

### 5.6 `DeliveryService.swift` — Task 6

```swift
enum DeliveryError: Error, Equatable {
    case pasteboardWriteFailed
    case fileWriteFailed(String)
}

enum DeliveryOutcome: Equatable, Sendable {
    case image
    case path(URL)
}

@MainActor
protocol SnapshotDelivering: AnyObject {
    func copyImage(_ png: Data) throws
    @discardableResult func copyFilePath(_ png: Data, timestamp: Date) throws -> URL
}

@MainActor
final class DeliveryService: SnapshotDelivering {
    static var defaultDirectory: URL { get }        // temporaryDirectory/MacPict
    static func fileName(for timestamp: Date) -> String   // "MacPict-2026-07-25-143012.png"

    let directory: URL
    init(directory: URL = DeliveryService.defaultDirectory, pasteboard: NSPasteboard = .general)

    func copyImage(_ png: Data) throws
    @discardableResult func copyFilePath(_ png: Data, timestamp: Date) throws -> URL
}
```
`copyImage` uses `clearContents()` then `setData(_:forType: .png)` **and** `.tiff` for
maximum receiver compatibility, never `writeObjects:` (C-7). `copyFilePath` writes the PNG,
then puts the **POSIX path as a plain string** on the pasteboard (`.string`) — a CLI agent
needs text it can paste into a prompt, not a file-URL flavour. The injectable `pasteboard`
parameter exists so tests can use a named pasteboard instead of clobbering the user's real
clipboard. `fileName(for:)` uses a fixed `en_US_POSIX` locale and the current time zone.

### 5.7 `DisplayLocator.swift` — Task 2

```swift
enum DisplayLocator {
    /// Pure, testable core: index into `frames` whose rect contains `point`.
    /// AppKit global coordinates (bottom-left origin). nil when none contains it.
    static func indexOfScreen(containing point: CGPoint, frames: [CGRect]) -> Int?

    @MainActor static func screen(containing point: CGPoint, screens: [NSScreen]) -> NSScreen?
    @MainActor static func screenUnderPointer() -> NSScreen?

    /// deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber → uint32Value
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID?
}
```
`screen(containing:screens:)` falls back to `NSScreen.main`, then `screens.first`.
Per C-3, the `NSScreenNumber` read must be fully optional-safe — no force casts.

### 5.8 `ScreenCapturePermission.swift` — Task 2

```swift
enum ScreenCapturePermissionStatus: String, Sendable {
    case granted = "Granted"
    case denied  = "Not granted"
}

@MainActor
final class ScreenCapturePermission: ObservableObject {
    @Published private(set) var status: ScreenCapturePermissionStatus
    func refresh()                                    // CGPreflightScreenCaptureAccess()
    @discardableResult func requestIfNeeded() -> Bool // preflight, else CGRequestScreenCaptureAccess()
    func openSettings()                               // Privacy_ScreenCapture pane
}
```
Settings URL:
`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`.

### 5.9 `ScreenCaptureService.swift` — Task 2

```swift
enum ScreenCaptureError: Error {
    case permissionDenied
    case noScreenUnderPointer
    case displayNotShareable
    case captureFailed(any Error)
}

struct CapturedSnapshot: Sendable {
    let image: CGImage
    let pixelSize: CGSize
    let screenFrame: CGRect          // AppKit global coordinates
    let displayID: CGDirectDisplayID
}

@MainActor
protocol ScreenCapturing: AnyObject {
    func captureDisplayUnderPointer() async throws -> CapturedSnapshot
}

@MainActor
final class ScreenCaptureService: ScreenCapturing {
    init(permission: ScreenCapturePermission)
    func captureDisplayUnderPointer() async throws -> CapturedSnapshot
}
```
Required implementation shape:
`SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)` →
match `SCDisplay.displayID` → build
`SCContentFilter(display:excludingApplications:exceptingWindows:)` excluding this app's own
`SCRunningApplication` (match on `bundleIdentifier == Bundle.main.bundleIdentifier`) →
`SCStreamConfiguration` with `width/height` derived from
`filter.contentRect` × `filter.pointPixelScale` (C-8), `showsCursor = false`,
`captureResolution = .best`, `scalesToFit = false`, `preservesAspectRatio = true` →
`SCScreenshotManager.captureImage(contentFilter:configuration:)`.

### 5.10 `GlobalHotkeyManager.swift` — Task 2

```swift
struct HotkeyShortcut: Equatable, Sendable {
    let keyCode: UInt32           // Carbon virtual key code
    let carbonModifiers: UInt32   // controlKey | optionKey | cmdKey | shiftKey
    let displayString: String
    static let captureDefault: HotkeyShortcut   // ⌃⌥⌘4
}

enum HotkeyRegistrationStatus: Equatable, Sendable {
    case registered
    case failed(OSStatus)
}

@MainActor
final class GlobalHotkeyManager {
    var onTrigger: (() -> Void)?
    private(set) var status: HotkeyRegistrationStatus?
    @discardableResult func register(_ shortcut: HotkeyShortcut) -> HotkeyRegistrationStatus
    func unregister()
}
```
Follow MacDictate's `GlobalHotkeyManager.swift` structure: `InstallEventHandler` on
`GetApplicationEventTarget()` for `kEventHotKeyPressed`, a C-compatible handler function, and
correct unretained-pointer teardown. Signature `OSType` is distinct from MacDictate's.

### 5.11 `AnnotationWindowController.swift` — Task 5

```swift
@MainActor
protocol AnnotationWindowDelegate: AnyObject {
    func annotationWindowDidRequestCopyImage(_ controller: AnnotationWindowController)
    func annotationWindowDidRequestCopyPath(_ controller: AnnotationWindowController)
    func annotationWindowDidCancel(_ controller: AnnotationWindowController)
}

@MainActor
final class AnnotationWindowController: NSWindowController {
    let document: AnnotationDocument
    weak var annotationDelegate: AnnotationWindowDelegate?

    init(document: AnnotationDocument, screen: NSScreen)
    func present()      // activate app, key + order front
}
```

### 5.12 `AnnotationCanvasView.swift` / `AnnotationToolbarView.swift` — Task 5

```swift
@MainActor
final class AnnotationCanvasView: NSView {
    init(document: AnnotationDocument)
    override var isFlipped: Bool { get }   // true — load-bearing, see D-1/D-2
    var geometry: CanvasGeometry { get }
}

struct AnnotationToolbarView: View {
    @ObservedObject var document: AnnotationDocument
    let onCopyImage: () -> Void
    let onCopyPath: () -> Void
    let onCancel: () -> Void
}
```

### 5.13 `AppCoordinator.swift` — Task 1 (stub) → Task 7 (real)

```swift
@MainActor
final class AppCoordinator: NSObject {
    override init()
    func start()
    func stop()
}
```
The public shape is frozen at Task 1 so `MacPictApp.swift` never needs to change.

## 6. UX specification

### Window
- `NSPanel` subclass overriding `canBecomeKey` and `canBecomeMain` to `true`.
- `styleMask = [.titled, .closable, .resizable]`, title `"MacPict"`.
- `level = .floating` (raw 3). **Not** `.statusBar`/`.screenSaver` — those cover the menu bar
  and are hostile.
- `collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]`.
- Initial frame: image aspect-fit inside `screen.visibleFrame.insetBy(dx: 40, dy: 40)`,
  centred on that screen, never exceeding `visibleFrame`.
- Content: 44 pt toolbar strip pinned to the top (`NSHostingView`), canvas filling the rest,
  Auto Layout.
- `present()` calls `NSApp.activate()` then `makeKeyAndOrderFront(nil)`. The app is
  `.accessory`, which can still take key focus.

### Keyboard
Handled via the window's/canvas's `performKeyEquivalent(with:)` — the app is LSUIElement and
has no menu bar to host these.

| Key | Action |
|---|---|
| `1`…`5` | select arrow / box / ellipse / line / text (CaseIterable order) |
| `6` or `C` | select the crop tool (§11) |
| `⌘`-drag | crop from any tool, without switching tools (§11) |
| `⇧⌘R` | reset crop to the full image (§11) |
| `⌘Z` / `⇧⌘Z` | undo / redo — including crops |
| `⌘⌫` | clear all (one undo step) |
| `[` / `]` | previous / next size |
| `⌘↩` | copy image to clipboard, close |
| `⌥⌘↩` | copy file path to clipboard, close |
| `Esc` | cancel active text edit if editing, otherwise close |
| `⌘W` | close |

### Drawing
- `mouseDown` records the start point, converted to image space and clamped.
- `mouseDragged` updates an in-progress annotation and redraws.
- `mouseUp` commits only if non-degenerate (≥ 3 view points of extent), else discards.
- Text tool: `mouseDown` places a borderless, transparent `NSTextField` at that point, sized
  `style.fontSize / geometry.imageScale` and coloured `style.color`. `Return` commits into a
  `.text` annotation; `Esc` cancels; clicking elsewhere commits.

### Menu bar
- `NSStatusItem` with SF Symbol `camera.viewfinder`.
- Menu: **Capture Display Under Pointer ⌃⌥⌘4** / separator / hotkey-registration status
  (disabled row, only when registration failed) / Screen Recording permission status +
  **Open Screen Recording Settings…** / separator / **Quit ⌘Q**.
- On successful delivery the symbol swaps to `checkmark.circle.fill` for ~800 ms (D-5).

## 7. Tasks

Ownership is **exclusive**. A worker may create and edit only the files listed for its task,
and must not touch any other file. Waves are strict barriers.

### Wave 1

#### Task 1 — Build system and app shell
**Owns:** `project.yml`, `.gitignore`, `README.md`, `scripts/bootstrap.sh`,
`scripts/build.sh`, `scripts/run.sh`, `scripts/test.sh`,
`MacPict/MacPict.entitlements`, `MacPict/AppLogger.swift`, `MacPict/MacPictApp.swift`,
`MacPict/AppCoordinator.swift` *(stub — ownership transfers to Task 7)*,
`MacPictTests/AppLoggerTests.swift`

Mirror MacDictate's `project.yml` and `scripts/*.sh` exactly in shape, substituting MacPict
names, `PRODUCT_BUNDLE_IDENTIFIER = com.macpict.app`, `MACOSX_DEPLOYMENT_TARGET = "15.0"`,
`INFOPLIST_KEY_LSUIElement: YES`, `ENABLE_HARDENED_RUNTIME: YES`,
`DEVELOPMENT_TEAM: M3TWZT9C7B`, `SWIFT_VERSION: "6.0"`,
`SWIFT_STRICT_CONCURRENCY: complete`. SDK dependencies: `ScreenCaptureKit.framework`,
`Carbon.framework`, `CoreGraphics.framework`, `AppKit.framework`, `UniformTypeIdentifiers.framework`.
Entitlements file contains **no** `com.apple.security.app-sandbox` key (A-6).
`MacPictApp.swift` is `@main struct MacPictApp: App` with
`@NSApplicationDelegateAdaptor(AppDelegate.self)`, a `Settings { EmptyView() }` scene, and an
`AppDelegate` that guards with `guard NSClassFromString("XCTestCase") == nil else { return }`
before constructing and starting `AppCoordinator`.
The `AppCoordinator` stub must set `.accessory` activation policy and install the status item
with a Quit entry, and log "not yet wired" for capture.

**Acceptance:** `./scripts/bootstrap.sh`, `./scripts/build.sh`, and `./scripts/test.sh` all
exit 0. `./scripts/run.sh` launches an app with a menu-bar icon and no Dock icon.
`git status` shows nothing outside the ownership list.

### Wave 2 (parallel; each depends on Task 1)

#### Task 2 — System input and screen capture
**Owns:** `MacPict/GlobalHotkeyManager.swift`, `MacPict/ScreenCapturePermission.swift`,
`MacPict/DisplayLocator.swift`, `MacPict/ScreenCaptureService.swift`,
`MacPictTests/DisplayLocatorTests.swift`, `MacPictTests/HotkeyShortcutTests.swift`

Implements §5.7–§5.10. Constraints C-1 through C-6, C-9, C-10 apply directly and are
binding.

**Acceptance:** builds and tests green. `DisplayLocatorTests` covers
`indexOfScreen(containing:frames:)` for: point inside a single frame; point inside the second
of two frames; point in no frame (nil); a point on a shared edge resolving deterministically
to the first containing frame; and negative-origin frames (a display placed left of or above
the primary). `HotkeyShortcutTests` asserts `captureDefault` carries exactly
`control|option|command` and the `kVK_ANSI_4` key code, and that `displayString == "⌃⌥⌘4"`.
No CoreGraphics capture symbol appears anywhere (C-1). No force-unwrap or force-cast in the
`NSScreenNumber` read (C-3). Permission state comes from `CGPreflightScreenCaptureAccess`,
not from an `SCStreamError` code (C-9).

#### Task 3 — Annotation model and canvas geometry
**Owns:** `MacPict/AnnotationModel.swift`, `MacPict/CanvasGeometry.swift`,
`MacPictTests/AnnotationModelTests.swift`, `MacPictTests/CanvasGeometryTests.swift`

Implements §5.2–§5.3.

**Acceptance:** builds and tests green. `AnnotationModelTests` proves: `append` clears the
redo stack; `undo`/`redo` round-trip to the identical array; `clear()` is a **single** undo
step that restores every annotation; `canUndo`/`canRedo` are correct at the stack boundaries;
undo at empty and redo at top are no-ops rather than crashes.
`CanvasGeometryTests` proves: `imagePoint(fromView:)` and `viewPoint(fromImage:)` are exact
inverses for interior points; `displayRect` is correctly letterboxed for a wider-than-view
image **and** pillarboxed for a taller-than-view image; the four `displayRect` corners map to
`(0,0)` and `(imageSize.width, imageSize.height)`; a degenerate `viewSize` of `.zero` yields
`displayRect == .zero` and `imageScale == 1` without dividing by zero; `clampToImage` bounds
out-of-range points on all four sides.

#### Task 6 — Delivery
**Owns:** `MacPict/DeliveryService.swift`, `MacPictTests/DeliveryServiceTests.swift`

Implements §5.6.

**Acceptance:** builds and tests green. Tests use an injected **named** pasteboard — they
must not touch `NSPasteboard.general`. Tests prove: `copyImage` puts byte-identical PNG data
under `.png`; `copyFilePath` creates the file on disk with the exact bytes passed in, and
places that file's POSIX path on the pasteboard as a string; `fileName(for:)` is stable and
correctly formatted for a fixed `Date`; the target directory is created if absent; a second
capture in the same second does not silently overwrite in a way that loses the caller's URL
(the returned URL must always point at the bytes just written). Tests clean up their
temporary directory.

### Wave 3 (parallel; depend on Task 3's pinned types)

#### Task 4 — Renderer and exporter
**Owns:** `MacPict/AnnotationRenderer.swift`, `MacPict/SnapshotExporter.swift`,
`MacPictTests/AnnotationRendererTests.swift`, `MacPictTests/SnapshotExporterTests.swift`

Implements §5.4–§5.5. D-1's contract is binding: the renderer never applies a flip of its
own.

**Acceptance:** builds and tests green. Tests build a synthetic `CGImage` and assert on
actual pixels. They must prove: a `.box` annotation drawn at a known image rect lands at the
**same** pixel coordinates in the exported PNG (top-left origin — a y-flip bug must fail this
test); `flatten` returns an image whose pixel dimensions equal the input's exactly; the
exported PNG decodes back to those dimensions; an empty annotation array leaves the base
image byte-comparable; a `.text` annotation renders right-side-up (assert that ink appears in
the expected half of the text's bounding box, so an upside-down draw fails); the arrow head
is drawn at the `to` end, not the `from` end.

#### Task 5 — Annotation window and canvas UI
**Owns:** `MacPict/AnnotationCanvasView.swift`, `MacPict/AnnotationToolbarView.swift`,
`MacPict/AnnotationWindowController.swift`

Implements §5.11–§5.12 and §6.

**Acceptance:** builds green. `AnnotationCanvasView.isFlipped` returns `true`. Window level
is `.floating`. The initial frame never exceeds the target screen's `visibleFrame`. All
keyboard shortcuts in §6 are handled without a menu bar. The text editor commits on Return
and cancels on Escape without closing the window.

### Wave 4

#### Task 7 — Integration and coordinator
**Owns:** `MacPict/AppCoordinator.swift` *(taken over from Task 1)*,
`MacPictTests/CoordinatorTests.swift`

Replaces the stub with the real coordinator: owns the status item and its menu, registers the
hotkey, drives permission → capture → document → window, implements
`AnnotationWindowDelegate`, exports via `SnapshotExporter`, delivers via `DeliveryService`,
and flashes the status item on success (D-5). Capture errors and hotkey-registration failures
must be surfaced in the menu and logged — never silently swallowed.

**Acceptance:** `./scripts/build.sh` and `./scripts/test.sh` exit 0 for the **whole** app.
`CoordinatorTests` substitutes a fake `ScreenCapturing` and a fake `SnapshotDelivering` and
proves: a capture request that succeeds produces exactly one delivery call with PNG bytes
that decode to the captured image's pixel dimensions; a capture that throws produces **zero**
delivery calls and leaves no window on screen; the copy-path action calls `copyFilePath` and
not `copyImage`, and vice versa.

## 8. Explicitly NOT being built

Named so no worker can claim the plan implied them:

- Region select **at capture time** (the hotkey never dims the screen and never asks you to
  drag before the snapshot exists). In-window crop **is** in scope — see §11.
- Blur/pixelate redaction, highlighter, freehand pen, numbered step badges.
- Selecting, moving, resizing, or individually deleting a committed annotation (A-7).
- A Settings window, a shortcut recorder, or any persisted user preference.
- Drag-the-image-out-of-the-window.
- Auto-saving captures to a user-visible folder, or any capture history/browser.
- Multiple simultaneous annotation windows.
- An asset catalog or app icon.
- Launch-at-login, Sparkle/updates, notarization, or a CI workflow.
- Window capture or multi-display composite capture — full single display only.
- The macOS 26-only `SCScreenshotConfiguration` / HDR path.
- Any CoreGraphics capture fallback (C-1 — it cannot compile).

## 9. Test strategy and validation commands

XCTest, host-app unit tests, mirroring MacDictate (`import XCTest`,
`@testable import MacPict`, `final class …: XCTestCase`). One test file per concern; fakes
declared inline above the test class in the same file.

The lead runs these verbatim from `/Users/rich/Repos/MacPict` and records real exit codes:

```
./scripts/bootstrap.sh
./scripts/build.sh
./scripts/test.sh
```

Not automatically testable, and therefore explicitly out of the automated gate — to be
confirmed by manual run (`./scripts/run.sh`): the TCC permission prompt, actual
ScreenCaptureKit capture, real multi-monitor pointer targeting, and Carbon hotkey delivery
from another frontmost app.

## 10. Risks

| # | Risk | Mitigation |
|---|---|---|
| R-1 | A y-flip inversion between preview and export | D-1's shared renderer plus Task 4's pixel-position assertion, which fails on inversion |
| R-2 | Wrong display picked on a multi-monitor rig | Match on `CGDirectDisplayID` only (D-3); Task 2 tests negative-origin frames |
| R-3 | `⌃⌥⌘4` already claimed | `RegisterEventHotKey` returns `eventHotKeyExistsErr`; status surfaced in the menu, menu item still triggers capture. One-constant fix |
| R-4 | Screen Recording not yet granted | Preflight before capture; menu shows status and opens the right Settings pane. macOS may require a relaunch after granting — README says so |
| R-5 | Swift 6 strict concurrency friction across the `SCScreenshotManager` boundary | `CapturedSnapshot` is `Sendable`; capture service is `@MainActor`; `CGImage` crosses as an immutable reference |
| R-6 | Test target runs inside the app host and could start the real app | `NSClassFromString("XCTestCase")` guard in `AppDelegate`, as MacDictate does |

---

# 11. Amendment 1 — In-window crop

Added at the user's explicit request after Wave 2 was dispatched: *"I do want to quickly be
able to crop the image, which I think will provide greater focus to the AI agent… Everything
needs to be very quick actions."*

This section **supersedes** the "region select or drag-to-crop" exclusion in §8 for the
in-window case only. Capture-time region select remains out of scope.

## 11.1 Design goals, in priority order

1. **One gesture.** Drag, release, done. There is no confirm step, no Apply button, no handle
   dragging, no Return to commit.
2. **No mode trap.** Cropping must never leave the user in a state they have to escape from
   before they can keep annotating.
3. **Undoable by the mechanism that already exists.** `⌘Z` must undo a crop exactly the way
   it undoes a box. No second, crop-specific reset ritual to learn.
4. **Zero new coordinate spaces.** The app already has exactly one storage space (full-image
   pixels, top-left origin) and one conversion type. Crop must not add a third.

## 11.2 The model

`AnnotationDocument` gains a `cropRect` in **full-image pixel coordinates**. Annotations
continue to store their geometry against the **full image, never the crop**. This is the
decision that makes everything else simple:

- Cropping never rewrites existing annotations, so it cannot corrupt them.
- Undoing a crop needs no annotation fix-up.
- A second crop drawn inside an already-cropped view is *already* expressed as a sub-rect of
  the first, because view→image conversion always yields full-image coordinates. **Nested
  cropping therefore works with no special-casing, and `⌘Z` walks back through crops one at a
  time.**

The undo stack element changes from `[Annotation]` to a small value type carrying **both**
`annotations` and `cropRect`, so one `⌘Z` restores a consistent pair. The public
`undo()`/`redo()`/`canUndo`/`canRedo` surface is unchanged.

## 11.3 Interaction

| Path | Gesture | Cost |
|---|---|---|
| Crop tool | `6` (or `C`), drag, release | 1 key + 1 drag |
| Modifier crop | `⌘`-drag from **any** tool | 1 drag, no mode switch |

Both apply **on mouse-up, immediately**. After a crop-tool crop, the document
**automatically reverts to the previously selected tool** so the user keeps annotating
without a second keystroke. `⌘`-drag never changes the selected tool at all.

`⇧⌘R` resets to the full image (also a single undo step). A crop drag smaller than 16×16
image pixels is treated as an accidental click and discarded — it must not produce a
degenerate window.

Feedback while dragging: the region **outside** the pending crop rect dims. Without this the
gesture feels approximate; with it, it feels like a selection.

The toolbar shows a live **`W × H` pixel readout** of what will actually be delivered, and a
reset-crop control that appears only when cropped. The readout is not decoration — it is how
the user judges whether the image is tight enough to be worth an agent's attention, which is
the stated reason for wanting crop at all.

The window resizes to the new aspect ratio on every crop change: recompute the aspect-fit
content size within `screen.visibleFrame.insetBy(dx: 40, dy: 40)`, keep the window's centre
fixed, set the frame **without animation**. Animation here is latency the user can feel.

## 11.4 Export

`SnapshotExporter` flattens the **full** image with **all** annotations first, then crops the
resulting `CGImage` to `cropRect`. Annotations that extend past the crop are clipped, which is
the correct and expected behaviour.

The alternative — building a crop-sized context and translating by `-cropRect.origin` — saves
one intermediate allocation but adds transform math to the one code path where a coordinate
bug is invisible until it reaches the agent. Per D-1, structural obviousness wins; a full
flatten of a 5K image is a single ~10 ms operation on a one-shot export path.

`CGImage.cropping(to:)` is believed to take a **top-left-origin** rect, matching our storage
convention exactly — but this is an assumption, not an SDK-verified fact, so Task 4 must prove
it with a pixel-content assertion rather than take it on faith.

## 11.5 Amended contracts

### `AnnotationDocument` — additive (Task 3)

```swift
/// Visible sub-rect of `image`, in full-image pixels, top-left origin.
/// Equals `CGRect(origin: .zero, size: imageSize)` when uncropped.
@Published private(set) var cropRect: CGRect

var isCropped: Bool { get }
/// Size actually delivered to the agent — `cropRect.size`.
var outputSize: CGSize { get }

/// Normalises, clamps to the image, and rejects rects smaller than
/// `AnnotationDocument.minimumCropSide` on either side. Pushes one undo step.
func crop(to rect: CGRect)
/// Restores the full image. Pushes one undo step. No-op when already uncropped.
func resetCrop()

static let minimumCropSide: CGFloat   // 16, image pixels
```

Everything already pinned in §5.2 stays exactly as it is. Only the internal undo-stack
element type changes, from `[Annotation]` to a private state struct holding both fields.

### `CanvasGeometry` — additive (Task 3)

```swift
struct CanvasGeometry: Equatable, Sendable {
    let imageSize: CGSize        // full image, pixels
    let sourceRect: CGRect       // visible sub-rect, full-image pixels
    let viewSize: CGSize         // points

    /// Uncropped: sourceRect = CGRect(origin: .zero, size: imageSize).
    init(imageSize: CGSize, viewSize: CGSize)
    init(imageSize: CGSize, sourceRect: CGRect, viewSize: CGSize)
    ...
}
```

`displayRect` becomes the aspect-fit of **`sourceRect`** within `viewSize`; `imageScale`
becomes source pixels per view point. Conversions gain the source origin:

```
imagePoint(fromView: p) = sourceRect.origin + (p - displayRect.origin) * imageScale
viewPoint(fromImage: q) = displayRect.origin + (q - sourceRect.origin) / imageScale
```

Both still return **full-image** coordinates (§11.2). The existing two-argument initialiser
must be kept and must delegate with the full rect, so every §7 Task 3 test written against it
continues to pass unchanged. A `sourceRect` that is empty, non-finite, or outside `imageSize`
is degenerate and yields `displayRect == .zero`, `imageScale == 1`.

### `SnapshotExporter` — additive (Task 4)

```swift
static func flatten(image: CGImage, annotations: [Annotation], cropRect: CGRect?) throws -> CGImage
static func png(image: CGImage, annotations: [Annotation], cropRect: CGRect?) throws -> Data
```

`nil` means the full image. The existing two-argument forms are kept as
`cropRect: nil` conveniences so Task 4's already-written tests keep compiling and passing.
Add `SnapshotExporterError.cropOutOfBounds` for a `cropRect` that does not intersect the
image.

### `AnnotationTool` — additive (Task 3)

`case crop` is appended **last** in the `CaseIterable` declaration order, so the existing
`1…5` → arrow/box/ellipse/line/text mapping is untouched and crop takes `6`.
`symbolName` is `crop`.

## 11.6 Amended acceptance criteria

**Task 3** additionally proves: `crop(to:)` clamps a rect extending past the image edge;
rejects a sub-minimum rect without mutating state; normalises a rect dragged right-to-left or
bottom-to-top; is a single undo step that restores the previous `cropRect`; a crop applied
*after* annotations exist leaves `annotations` byte-identical; two successive crops undo one
at a time in order; `resetCrop()` on an uncropped document is a no-op that does **not** push a
spurious undo step. `CanvasGeometry` additionally proves: with a non-zero `sourceRect`,
`imagePoint(fromView:)` still returns full-image coordinates, `displayRect`'s corners map to
`sourceRect`'s corners, and view↔image remain exact inverses.

**Task 4** additionally proves: a known-coloured region survives cropping at the **correct**
pixel offset (this is the test that catches a top-left/bottom-left origin error in
`CGImage.cropping(to:)` — it must be written to fail if the origin convention is flipped);
output pixel dimensions equal `cropRect.size` exactly; an annotation lying entirely outside
the crop does not appear in the output; an annotation straddling the crop edge is clipped
rather than dropped.

**Task 5** additionally implements: the crop tool, `⌘`-drag crop from any tool, the dim-outside
overlay, auto-revert to the previous tool, `⇧⌘R`, the `W × H` readout, the conditional
reset-crop control, and centre-fixed window resize on crop change.

---

# 12. Amendment 2 — corrections found during implementation

Two errors in this plan were found by workers and are corrected here. Both were caught by
measurement rather than by review, which is worth recording.

## 12.1 §5.11 was not implementable as pinned

`NSWindowController` already declares `document: AnyObject?`, so
`final class AnnotationWindowController: NSWindowController { let document: AnnotationDocument }`
fails with *"property 'document' with type 'AnnotationDocument' cannot override a property with
type 'AnyObject?'"*. Task 5 verified that `@nonobjc`, an extension property, and a covariant
read-only override all fail as well.

**Resolution (accepted):** `AnnotationWindowController` derives from `NSObject`, not
`NSWindowController`, keeping the `document` member name that Task 7 reads. It gains
`private(set) var window: NSWindow?` and `func close()` to replace what `NSWindowController`
would have supplied. Nothing in the app used nib loading or `showWindow(_:)`, so no capability
is lost. `AnnotationWindowDelegate` is unchanged.

The amended §5.11:

```swift
@MainActor
final class AnnotationWindowController: NSObject {
    let document: AnnotationDocument
    weak var annotationDelegate: AnnotationWindowDelegate?
    private(set) var window: NSWindow?

    init(document: AnnotationDocument, screen: NSScreen)
    func present()
    func close()
}
```

## 12.2 The canvas drawing instruction was wrong and would have shipped mirrored screenshots

The Task 5 brief specified `NSImage.draw(in:from:operation:fraction:)` on the grounds that
`NSImage` honours a flipped context. Measured in both a synthetic flipped context and a real
`isFlipped` `NSView`, that overload renders the image **mirrored**. The overload taking
`respectFlipped:` is required, with `respectFlipped: true`.

Two further consequences, established by the same measurement:

- `NSImage.draw`'s `from:` source rect is **bottom-left origin**, so the top-left-origin
  `cropRect` must be converted with `y: imageSize.height - crop.maxY` before being passed.
- Because annotations are stored in **full-image** coordinates (§11.2), the canvas must clip to
  `displayRect` and translate by `geometry.viewPoint(fromImage: .zero)` before calling
  `AnnotationRenderer`. Passing `scale` alone is insufficient once a crop is active.

`SnapshotExporter` is unaffected — it draws the base image *before* applying its flip, so it
never enters the mirrored path. This asymmetry between the two callers is precisely the class of
divergence D-1 exists to prevent, and it is the strongest argument for keeping the shared
renderer and the pixel-level orientation tests that guard it.

