# Task 2 — System input and screen capture

## Files created (all within the ownership list; nothing else touched)

- `MacPict/DisplayLocator.swift`
- `MacPict/ScreenCapturePermission.swift`
- `MacPict/ScreenCaptureService.swift`
- `MacPict/GlobalHotkeyManager.swift`
- `MacPictTests/DisplayLocatorTests.swift`
- `MacPictTests/HotkeyShortcutTests.swift`

`git status --porcelain` shows only untracked top-level entries (the repo has a single empty
commit), and no modification to `project.yml`, `AppCoordinator.swift`, `MacPictApp.swift`, or
any other worker's file.

## Declarations as actually written

```swift
enum DisplayLocator {
    static func indexOfScreen(containing point: CGPoint, frames: [CGRect]) -> Int?
    @MainActor static func screen(containing point: CGPoint, screens: [NSScreen]) -> NSScreen?
    @MainActor static func screenUnderPointer() -> NSScreen?
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID?
}

enum ScreenCapturePermissionStatus: String, Sendable {
    case granted = "Granted"
    case denied = "Not granted"
}

@MainActor
final class ScreenCapturePermission: ObservableObject {
    @Published private(set) var status: ScreenCapturePermissionStatus = .denied
    init()
    func refresh()
    @discardableResult func requestIfNeeded() -> Bool
    func openSettings()
}

enum ScreenCaptureError: Error {
    case permissionDenied
    case noScreenUnderPointer
    case displayNotShareable
    case captureFailed(any Error)
}

struct CapturedSnapshot: Sendable {
    let image: CGImage
    let pixelSize: CGSize
    let screenFrame: CGRect
    let displayID: CGDirectDisplayID
}

@MainActor protocol ScreenCapturing: AnyObject {
    func captureDisplayUnderPointer() async throws -> CapturedSnapshot
}

@MainActor final class ScreenCaptureService: ScreenCapturing {
    init(permission: ScreenCapturePermission)
    func captureDisplayUnderPointer() async throws -> CapturedSnapshot
}

struct HotkeyShortcut: Equatable, Sendable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let displayString: String
    static let captureDefault = HotkeyShortcut(
        keyCode: UInt32(kVK_ANSI_4),
        carbonModifiers: UInt32(controlKey | optionKey | cmdKey),
        displayString: "⌃⌥⌘4"
    )
}

enum HotkeyRegistrationStatus: Equatable, Sendable {
    case registered
    case failed(OSStatus)
}

@MainActor final class GlobalHotkeyManager {
    var onTrigger: (() -> Void)?
    private(set) var status: HotkeyRegistrationStatus?
    @discardableResult func register(_ shortcut: HotkeyShortcut) -> HotkeyRegistrationStatus
    func unregister()
}
```

All signatures match §5.7–§5.10 exactly. `ScreenCapturePermission` gained a no-argument `init()`
that calls `refresh()` (matching MacDictate's permission managers); this is additive and does not
change the pinned surface.

## Validation — real exit codes

Run from `/Users/rich/Repos/MacPict`:

| Command | Exit code | Notes |
|---|---|---|
| `./scripts/bootstrap.sh` | **0** | XcodeGen picked up the four new `MacPict/` sources and two new `MacPictTests/` sources without a `project.yml` edit |
| `./scripts/build.sh` | **0** | Zero Swift compiler warnings. The only `warning:` line in the log is `appintentsmetadataprocessor … Metadata extraction skipped. No AppIntents.framework dependency found.`, which is a toolchain note, not a Swift diagnostic |
| `./scripts/test.sh` | **0** at 22:16:30 (see caveat) | `Executed 24 tests, with 0 failures`. `DisplayLocatorTests` 5/5 passed, `HotkeyShortcutTests` 2/2 passed |

Caveat, reported honestly: three later `./scripts/test.sh` runs (22:16:41, 22:17:xx) exited **65**,
in every case because of files owned by *other, still-in-flight* Wave-2 workers, never mine:

- `MacPictTests/DeliveryServiceTests.swift:117` — `XCTAssertNotEqual failed: ("150 bytes") is equal to ("150 bytes")` (Task 6).
- `MacPictTests/CanvasGeometryTests.swift:135` — `error: ambiguous use of 'infinity'`, and `:139` — `error: type 'Equatable' has no member 'zero'` (Task 3, test target no longer compiles).

In each of those runs `Test Suite 'DisplayLocatorTests' passed` / `Test Suite 'HotkeyShortcutTests'
passed` where the target compiled, and `./scripts/build.sh` (which compiles all four of my app-target
sources) exited 0 throughout. The lead should re-run `./scripts/test.sh` after Tasks 3 and 6 settle.

## How each constraint was resolved in code

**C-1 (no CoreGraphics capture fallback).** No CG capture symbol appears anywhere in my files;
verified with `grep -rn "CGDisplayCreateImage\|CGWindowListCreateImage" MacPict/{DisplayLocator,ScreenCaptureService,GlobalHotkeyManager,ScreenCapturePermission}.swift` → no matches (exit 1).
`SCScreenshotManager.captureImage(contentFilter:configuration:)` is the sole capture route, and a
failure there is wrapped, not substituted:

```swift
} catch {
    AppLogger.capture.error("Screenshot capture failed: \(error.localizedDescription, privacy: .public)")
    throw ScreenCaptureError.captureFailed(error)
}
```

**C-3 (`NSScreenNumber` is undeclared, read optional-safely).** `DisplayLocator.displayID(of:)`:

```swift
let key = NSDeviceDescriptionKey("NSScreenNumber")
guard let number = screen.deviceDescription[key] as? NSNumber else {
    AppLogger.capture.error("Screen has no NSScreenNumber device description entry")
    return nil
}
return CGDirectDisplayID(number.uint32Value)
```

No force-cast and no force-unwrap; `grep` for `as! ` / `try!` across my four sources returns nothing.

**C-4 (two coordinate spaces; match on display ID only).** `ScreenCaptureService` never compares an
`NSScreen.frame` to an `SCDisplay.frame`:

```swift
// C-4/D-3: AppKit frames and SCDisplay frames use opposite y directions,
// so displays are matched on their ID and never on their geometry.
guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
```

`screenFrame` is captured once from `screen.frame` and carried through to `CapturedSnapshot`
unmodified, staying entirely inside AppKit's space. `screenUnderPointer()` compares
`NSEvent.mouseLocation` only against `NSScreen.frame`, which is the same space.

**C-8 (`pointPixelScale` / `contentRect` are authoritative).**

```swift
let scale = CGFloat(filter.pointPixelScale)
let configuration = SCStreamConfiguration()
configuration.width = Int((filter.contentRect.width * scale).rounded())
configuration.height = Int((filter.contentRect.height * scale).rounded())
configuration.showsCursor = false
configuration.captureResolution = .best
configuration.scalesToFit = false
configuration.preservesAspectRatio = true
```

`NSScreen.backingScaleFactor` is not referenced anywhere. The returned snapshot's `pixelSize` comes
from the image the system actually produced, not from the config:
`let pixelSize = CGSize(width: image.width, height: image.height)`.

**C-9 (permission comes only from the preflight call).** `ScreenCapturePermission.refresh()` is
`status = CGPreflightScreenCaptureAccess() ? .granted : .denied`, and the capture path gates on that
value alone:

```swift
permission.refresh()
guard permission.status == .granted else {
    AppLogger.capture.error("Capture refused: Screen Recording permission is not granted")
    throw ScreenCaptureError.permissionDenied
}
```

`SCStreamError`, `SCStreamErrorCode`, and `-3801` appear nowhere. Every capture-path error is either
a specific pre-flight case or `.captureFailed(error)`; nothing is swallowed — each `guard`/`catch`
logs through `AppLogger.capture` before throwing.

**C-6 / hotkey.** `RegisterEventHotKey` + `InstallEventHandler(GetApplicationEventTarget(), …)` for
`kEventHotKeyPressed` only (no `kEventHotKeyReleased`, so no `isPressed` latch is needed). Signature
is `OSType(0x4D_50_43_54)` (`MPCT`), distinct from MacDictate's `0x4D_44_49_43`. `eventHandler` and
`hotkeyRef` are `nonisolated(unsafe)` so `deinit` can tear both down, exactly as MacDictate does; the
C handler resolves `self` with `Unmanaged.…takeUnretainedValue()` and hops via
`MainActor.assumeIsolated`.

One deliberate divergence from MacDictate: the event handler is installed lazily inside
`register(_:)` rather than in `init`. MacDictate installs in `init` and records the failure in a
separate published property; with this task's pinned single `status` field, installing in `init`
would let a later successful `RegisterEventHotKey` overwrite an install failure and report
`.registered` for a hotkey that could never fire. Installing inside `register` makes an install
failure return `.failed(installStatus)` from the same call.

## SDK member names verified against headers

Checked in `MacOSX26.5.sdk/System/Library/Frameworks/ScreenCaptureKit.framework/Headers`:

- `SCShareableContent.h:36` — `@property (readonly) NSString *bundleIdentifier;` on
  `SCRunningApplication` (also `applicationName`, `processID`). The prompt's `bundleIdentifier`
  match is correct.
- `SCShareableContent.h:96` — `@property (readonly) CGDirectDisplayID displayID;` on `SCDisplay`.
- `SCShareableContent.h:162` — `getShareableContentExcludingDesktopWindows:onScreenWindowsOnly:completionHandler:`,
  imported as `SCShareableContent.excludingDesktopWindows(_:onScreenWindowsOnly:)`.
- `SCStream.h:180` — `initWithDisplay:excludingApplications:exceptingWindows:`.
- `SCStream.h:114,119` — `pointPixelScale` (float, macOS 14.0+), `contentRect` (CGRect, 14.0+).
- `SCStream.h:212,217,239,244,254,325` — `width`/`height` (`size_t` → Swift `Int`), `scalesToFit`,
  `preservesAspectRatio`, `showsCursor`, `captureResolution`.
- `SCScreenshotManager.h:152` — `NS_SWIFT_NAME(captureImage(contentFilter:configuration:completionHandler:))`.

No member name differed from the prompt. `NSScreen` carries no `MAIN_ACTOR` annotation in
`NSScreen.h` or `AppKit.apinotes`, which is why the nonisolated `displayID(of:)` in the pinned
contract compiles as specified.

## Tests

`DisplayLocatorTests` (5 tests, all passing) covers: point inside a single frame → 0; point inside
the second of two frames → 1; point in no frame → nil (three variants, including an empty frame
array); the seam case; and negative-origin frames.

The seam behaviour is documented rather than assumed. `CGRect.contains` is half-open, so for
abutting frames `[0…1920)` and `[1920…4480)` the point `(1920, 500)` is contained by the *second*
frame only — the test asserts `primary.contains(...) == false`, `secondary.contains(...) == true`,
and that the locator returns `1`. The same test also asserts the genuinely ambiguous case (two
identical, mirrored frames), where `firstIndex(where:)` deterministically returns the earlier array
index `0`. The doc comment on `indexOfScreen` states both rules.

The negative-origin test uses a display to the left (`x: -2560, y: -180`) and one above
(`y: 1080`) the primary, and asserts four hits plus two misses.

`HotkeyShortcutTests` (2 tests, passing) asserts `keyCode == UInt32(kVK_ANSI_4)`,
`carbonModifiers == UInt32(controlKey | optionKey | cmdKey)`, `displayString == "⌃⌥⌘4"`, that each
of control/option/command is individually set, that `shiftKey` and `alphaLock` are clear, and that
`modifiers & ~UInt32(controlKey | optionKey | cmdKey) == 0` (no stray bits).

No test requires Screen Recording permission, a real capture, or a real hotkey delivery, per §9.

## Plan gaps, unowned-caller breakage, uncertainties

- **No plan gaps found.** Every declaration in §5.7–§5.10 was implementable as written.
- **No unowned caller broken.** These are all new types; `AppCoordinator` (Task 1 stub) does not
  reference any of them yet, and Task 7 wires them up.
- Not verified because it is out of the automated gate (§9): actual ScreenCaptureKit capture, the
  TCC prompt, real multi-monitor pointer targeting, and Carbon hotkey delivery from another
  frontmost app. These need `./scripts/run.sh` on a real desktop.
- `ScreenCaptureError.displayNotShareable` vs `.noScreenUnderPointer` for a screen with no
  `NSScreenNumber`: I chose `.noScreenUnderPointer`, on the grounds that a screen with no display ID
  can never be matched to an `SCDisplay` and is therefore indistinguishable from having located no
  screen at all. This is documented in a comment at the call site. `.displayNotShareable` is
  reserved for the case where the ID exists but no `SCDisplay` carries it.
- `SCContentFilter(display:excludingApplications:exceptingWindows:)` is given the app's own
  `SCRunningApplication` entries filtered by `bundleIdentifier == Bundle.main.bundleIdentifier`.
  If the app is not currently in `content.applications` (e.g. no window on screen yet), the array is
  simply empty, which is harmless. Whether the exclusion actually removes an open annotation window
  from a live capture is a runtime behaviour I could not verify without a real capture.

---

# Repair round 1 (coordinator follow-up)

## Repair 1 — permission protocol so the denied branch can be tested

**Files changed:** `MacPict/ScreenCapturePermission.swift`, `MacPict/ScreenCaptureService.swift`,
new `MacPictTests/ScreenCaptureServiceTests.swift` (a test file for my own types, now mine).

Protocol added, exactly as specified, above the concrete class:

```swift
@MainActor
protocol ScreenCapturePermissionProviding: AnyObject {
    var status: ScreenCapturePermissionStatus { get }
    func refresh()
    @discardableResult func requestIfNeeded() -> Bool
    func openSettings()
}

@MainActor
final class ScreenCapturePermission: ObservableObject, ScreenCapturePermissionProviding {
```

The existing `@Published private(set) var status: ScreenCapturePermissionStatus = .denied` was
**not** changed. I verified rather than assumed this: `./scripts/build.sh` exits 0 with the
conformance in place, so a `private(set)` published property does satisfy a get-only protocol
requirement, and neither `@Published` nor the setter's access level needed touching.

`ScreenCaptureService` now takes the existential:

```swift
private let permission: any ScreenCapturePermissionProviding

init(permission: any ScreenCapturePermissionProviding) {
```

**No call site needed editing, confirmed by building, not by reasoning.** `AppCoordinator.swift:54`
still reads `ScreenCaptureService(permission: permission)` with a concrete `ScreenCapturePermission`,
and `MacPictTests/CoordinatorTests.swift:70` still passes `ScreenCapturePermission()`; both compile
untouched because the concrete class conforms. `AppCoordinator.swift` was not modified — Task 7 owns
it and will adopt the protocol in its own initialiser separately. `git status` still shows no file
outside my ownership list as changed by me.

### New test file: `MacPictTests/ScreenCaptureServiceTests.swift`

`StubScreenCapturePermission` (fileprivate, declared inline above the test class per §9) implements
the protocol over a fixed status and counts `refresh()`, `status` reads, `requestIfNeeded()`, and
`openSettings()`.

- **`testCaptureThrowsPermissionDeniedWithoutReachingScreenCaptureKit`** — injects a stub reporting
  `.denied`, calls `captureDisplayUnderPointer()`, and asserts it throws
  `ScreenCaptureError.permissionDenied`. What makes this a proof that ScreenCaptureKit is never
  reached: `.permissionDenied` is thrown at exactly one place, the pre-flight gate, and every
  downstream outcome carries a different case — an unresolvable display gives
  `.noScreenUnderPointer`, a missing `SCDisplay` gives `.displayNotShareable`, and *every* failure at
  or beyond `SCShareableContent`/`SCScreenshotManager` is wrapped as `.captureFailed`. Receiving
  `.permissionDenied` therefore excludes any SCK call having happened. The test additionally asserts
  `refreshCount == 1` and `statusReadCount > 0`, which prove the gate consults the *injected*
  provider and not the process's real TCC state — on this machine, where Screen Recording is
  actually granted, a service that ignored the stub would have returned a snapshot and failed the
  test. Finally it asserts `requestCount == 0` and `openSettingsCount == 0`: capture must never
  raise a TCC prompt of its own, since requesting is the coordinator's user-driven job.
- **`testConcreteScreenCapturePermissionSatisfiesTheProvidingProtocol`** — binds a real
  `ScreenCapturePermission()` to `any ScreenCapturePermissionProviding` and feeds it to
  `ScreenCaptureService`, so the production wiring `AppCoordinator` relies on breaks at compile time
  if the conformance is ever dropped.

No test performs a real capture, raises a TCC prompt, or depends on the grant state of the machine,
per PLAN.md §9. C-9 is intact: the gate is still `CGPreflightScreenCaptureAccess()` only; no
`SCStreamError` code appears anywhere in my files.

## Repair 2 — log privacy

`GlobalHotkeyManager` interpolated `shortcut.displayString`, a `String`, which `os.Logger` redacts by
default — hence `Global hotkey <private> registered`. Both shortcut interpolations now carry
`privacy: .public`:

```swift
AppLogger.hotkey.info("Global hotkey \(shortcut.displayString, privacy: .public) registered")
```
```swift
AppLogger.hotkey.error(
    "Registration of \(shortcut.displayString, privacy: .public) failed with status \(registerStatus)"
)
```

I audited every other `AppLogger.hotkey` / `AppLogger.capture` call site in my four files
(15 in total). The rest need no change and none were churned:

- `\(installStatus)` and `\(registerStatus)` are `OSStatus` (`Int32`), and `\(image.width)` /
  `\(image.height)` are `Int` — numeric interpolations are **public by default** in `os.Logger`, so
  they were never redacted.
- `\(displayID, privacy: .public)`, `\(error.localizedDescription, privacy: .public)` (twice), and
  the `\(image.width…)x\(image.height…)` line already carried explicit `.public`.
- The remaining nine are literal format strings with no interpolation.

Nothing was made public that should not be: the only values now public are a hard-coded keyboard
shortcut string, Carbon status codes, a display ID, and framework error descriptions — no user
content, no file paths, no captured image data.

## Repair validation — real exit codes

Run from `/Users/rich/Repos/MacPict`:

| Command | Exit code |
|---|---|
| `./scripts/bootstrap.sh` | **0** |
| `./scripts/build.sh` | **0** |
| `./scripts/test.sh` | **0** |

Zero Swift compiler warnings in both logs; the sole `warning:` line remains the toolchain's
`appintentsmetadataprocessor … No AppIntents.framework dependency found.` note.

Final count: **`Executed 98 tests, with 0 failures (0 unexpected) in 1.521 seconds`** — up from the
coordinator's 89 by my 2 new tests plus 7 added by other workers in the same window. Every suite
passed, including the concurrently-edited ones: `AnnotationModelTests`, `AnnotationRendererTests`,
`AnnotationWindowControllerTests`, `AppLoggerTests`, `CanvasGeometryTests`, `CoordinatorTests`,
`DeliveryServiceTests`, `DisplayLocatorTests`, `HotkeyShortcutTests`, `ScreenCaptureServiceTests`,
`SnapshotExporterTests`. No failure appeared in `AnnotationWindowController.swift` or anywhere else
outside my ownership, so there is nothing to report on that front.

Both `ScreenCaptureServiceTests` cases passed (0.103 s and 0.001 s).
