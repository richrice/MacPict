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

---

# Feature — configurable capture hotkey

The user found `⌃⌥⌘4` hard to hit one-handed. The capture shortcut is now picked from a curated
preset list, MacDictate-style (a `Picker` over hand-written presets — **no `NSEvent` monitor, no
shortcut recorder anywhere**), and the default moved to `⌃⌥ C`.

## Files changed

| File | Change |
|---|---|
| `/Users/rich/Repos/MacPict/MacPict/SettingsStore.swift` | **new** — `HotkeyPresetGroup`, `HotkeyShortcut` (moved here, extended), `SettingsStore` |
| `/Users/rich/Repos/MacPict/MacPict/GlobalHotkeyManager.swift` | four-case `HotkeyRegistrationStatus`, non-optional `status`, revert-on-failure `register(_:)` |
| `/Users/rich/Repos/MacPict/MacPictTests/HotkeyShortcutTests.swift` | rewritten for the new default and the preset table |
| `/Users/rich/Repos/MacPict/MacPictTests/SettingsStoreTests.swift` | **new** — persistence over a suite-named `UserDefaults` |

No file outside the ownership list was touched. `project.yml` needed no edit: both targets take
whole directories as `sources`, so `xcodegen generate` picked the two new files up on its own.

## Contracts as written

Implemented verbatim from the pin, in `SettingsStore.swift`:

```swift
struct HotkeyPresetGroup: Identifiable, Sendable {
    let name: String
    let shortcuts: [HotkeyShortcut]
    var id: String { name }
}

struct HotkeyShortcut: Codable, Hashable, Identifiable, Sendable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let displayString: String
    var id: String { "\(keyCode)-\(carbonModifiers)" }
    static let captureDefault: HotkeyShortcut
    static let presetGroups: [HotkeyPresetGroup]
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var hotkey: HotkeyShortcut { didSet { persistHotkey() } }
    init(defaults: UserDefaults = .standard)
    func restoreDefaultHotkey()
}
```

and in `GlobalHotkeyManager.swift`:

```swift
enum HotkeyRegistrationStatus: Equatable, Sendable {
    case notRegistered, registered(String), conflict(String), failed(String)
    var displayText: String { get }
    var isRegistered: Bool { get }
}

@MainActor
final class GlobalHotkeyManager: ObservableObject {
    var onTrigger: (() -> Void)?
    @Published private(set) var status: HotkeyRegistrationStatus = .notRegistered
    @discardableResult func register(_ shortcut: HotkeyShortcut) -> HotkeyRegistrationStatus
    func unregister()
}
```

`displayString` kept its MacPict name (MacDictate calls the same field `displayName`); no rename.
`HotkeyShortcut` gained `Codable`/`Hashable`/`Identifiable` in place of bare `Equatable`
(`Hashable` implies `Equatable`, so existing `==` comparisons still work).

`displayText` strings, matching MacDictate word-for-word: `"Not registered"`,
`"Registered: <s>"`, `"Shortcut conflict: <s> is already in use"`, `"Registration failed: <detail>"`.

## The preset table (full)

Default: **`⌃⌥ C`** — `kVK_ANSI_C` + `controlKey | optionKey`, `displayString` `"⌃⌥ C"`. Two
adjacent left-hand modifiers plus a letter under the index finger, so it is comfortably
one-handed, and C is mnemonic for Capture.

| Group | `displayString` | `keyCode` | Carbon modifiers |
|---|---|---|---|
| Letters | `⌃⌥ C` *(default)* | `kVK_ANSI_C` | `controlKey \| optionKey` |
| Letters | `⌥ C` | `kVK_ANSI_C` | `optionKey` |
| Letters | `⌃⌥ S` | `kVK_ANSI_S` | `controlKey \| optionKey` |
| Letters | `⌥ S` | `kVK_ANSI_S` | `optionKey` |
| Letters | `⌃⌥ A` | `kVK_ANSI_A` | `controlKey \| optionKey` |
| Space | `⌃ Space` | `kVK_Space` | `controlKey` |
| Space | `⌃⌥ Space` | `kVK_Space` | `controlKey \| optionKey` |
| Space | `⌘⇧ Space` | `kVK_Space` | `cmdKey \| shiftKey` |
| Space | `⌥⇧ Space` | `kVK_Space` | `optionKey \| shiftKey` |
| Space | `⌃⇧ Space` | `kVK_Space` | `controlKey \| shiftKey` |
| Function keys | `F13` … `F19` (7 entries) | `kVK_F13` … `kVK_F19` | `0` — none |
| Screenshot style | `⌃⌥⌘ 4` | `kVK_ANSI_4` | `controlKey \| optionKey \| cmdKey` |
| Screenshot style | `⇧⌘ 2` | `kVK_ANSI_2` | `cmdKey \| shiftKey` |

21 presets, all ids distinct. Every `displayString` is a literal typed at its construction site —
there is no keycode→glyph lookup table, deliberately, exactly as in MacDictate.

Plain `⌥ Space` is **absent on purpose**: it is MacDictate's own default and this user runs both
apps, so it would collide on their machine. The reason is written in a comment above
`presetGroups` and pinned by `testNoPresetIsOptionSpaceAlone`, so nobody re-adds it later.

The old `⌃⌥⌘4` survives as the "Screenshot style" preset `⌃⌥⌘ 4` (note the space before the digit,
per the pin) — a user who liked the muscle memory can pick it back.

## Persistence

- Key: **`"captureHotkey"`**, in the injected `UserDefaults`.
- Encoding: `JSONEncoder` → `Data`, decoded with `JSONDecoder`. Whole struct, three fields.
- Absent **or** undecodable ⇒ `captureDefault`, mirroring `MacDictate/SettingsStore.swift:150-155`.
  This is the one place a `try?` is right: a corrupt preference must not stop the app launching,
  and the fallback is the documented default rather than a masked error.
- Writes happen in `didSet`, so any assignment persists immediately; `restoreDefaultHotkey()` goes
  through the same `didSet`. Construction alone never writes (asserted).
- `init(defaults:)` is the seam that keeps tests off `UserDefaults.standard`.

## Revert-on-failure — the deliberate divergence from MacDictate

MacDictate's `register(_:)` unregisters first and, if the new shortcut fails, leaves the user with
**no working hotkey at all**. With a picker in front of the user that is a real trap, so:

```swift
let outcome = attemptRegistration(of: shortcut)
if outcome.isRegistered {
    lastGoodShortcut = shortcut
} else if let previous = lastGoodShortcut, previous != shortcut {
    let reverted = attemptRegistration(of: previous)
    if reverted.isRegistered { /* log */ } else { lastGoodShortcut = nil }
}
status = outcome
return outcome
```

Behaviour, stated plainly:

1. `status` and the return value always describe the **attempted** shortcut — a `.conflict("F13")`
   tells the user *their* choice did not take. The silent revert never overwrites that message.
2. Carbon registration afterwards points at the **last shortcut that registered successfully**, so
   capture keeps working while the user tries another preset.
3. No last-good shortcut (first-ever registration fails) ⇒ ends in the failure state with nothing
   registered, which is the honest outcome.
4. `previous != shortcut` guards the pointless case of reverting to the very shortcut that just
   failed.
5. If the revert *also* fails, `lastGoodShortcut` is cleared — it has been proven no longer good,
   and keeping it would make later failures retry a dead shortcut forever.
6. `unregister()` clears `lastGoodShortcut` and sets `status = .notRegistered`, so a deliberate
   teardown can never be resurrected by a later failed `register(_:)`.

Structure supporting review: `attemptRegistration(of:)` performs the Carbon work and **returns** a
status without touching `status` or `lastGoodShortcut`; `register(_:)` is the only place that
decides what the user is told and what is restored. The policy is therefore one nine-line block
with no Carbon calls inline. The `eventHotKeyExistsErr` → `.conflict` / other non-`noErr` →
`.failed("Carbon error <OSStatus>")` mapping lives in the single `switch` in
`attemptRegistration(of:)`. The divergence is documented in a doc comment on `register(_:)`.

**What of it is testable here:** the policy itself is not — it is gated on real
`RegisterEventHotKey` results, and registering a live Carbon hotkey is global process state that
would make the suite flaky and order-dependent, so per instruction no such test was written. What
*is* covered without touching Carbon is the status vocabulary the policy speaks in:
`testRegistrationStatusReportsTheAttemptedShortcut` asserts `isRegistered` is true only for
`.registered`, and that `.conflict`/`.failed` `displayText` carries the shortcut and the OSStatus
into the message the user reads. Making the policy fully unit-testable would mean injecting a
registration function — a seam with exactly one production implementation, which is the
speculative generality YAGNI rules out; noted here as a possible follow-up if the logic grows.

## Commands run (real exit codes)

Run from `/Users/rich/Repos/MacPict`:

| Command | Exit code |
|---|---|
| `./scripts/bootstrap.sh` | **0** |
| `./scripts/build.sh` | **0** |
| `./scripts/test.sh` | **0** |

**`Executed 137 tests, with 0 failures (0 unexpected) in 4.182 seconds`** (up from 98; my 12 net-new
tests — 14 owned tests where there were 2 — plus other workers' concurrent additions). `Test Suite 'HotkeyShortcutTests' passed`
(8 tests), `Test Suite 'SettingsStoreTests' passed` (6 tests). Zero Swift compiler warnings in
either log — the only `warning:` line remains the toolchain's
`appintentsmetadataprocessor … No AppIntents.framework dependency found.`

Test inventory: `HotkeyShortcutTests` — default is `⌃⌥ C` with exactly `control|option`; no
`cmd`/`shift`/`alphaLock` bits; the default appears in the presets; all preset ids unique; every
`displayString` non-empty; no `⌥ Space` preset; group names unique; status vocabulary.
`SettingsStoreTests` — fresh store yields `captureDefault` and does not write; assignment persists
immediately as decodable JSON; a second store over the same defaults reads the value back; garbage
`Data` falls back to the default; a wrong-typed (`String`) stored value falls back too;
`restoreDefaultHotkey()` resets and persists. All use `UserDefaults(suiteName:
"com.macpict.tests.settingsstore")`, wiped with `removePersistentDomain` in **both** `setUp` and
`tearDown`; `UserDefaults.standard` is never touched.

## Unowned callers — observations, not edits

`AppCoordinator.swift` is another worker's file and still holds its pre-feature wiring. It happens
to **compile** against the new API (hence my green build), but two things there are stale and are
that worker's to finish:

- `AppCoordinator.swift:80` still calls `hotkey.register(.captureDefault)` rather than registering
  `SettingsStore.hotkey`, so the user's choice would not be applied at launch.
- `AppCoordinator.swift:276-282` `updateHotkeyItem(for:)` matches only `case let .failed(code)` and
  hides the menu row otherwise. `.conflict` — now the *most likely* failure, and the whole reason
  the case was added — would therefore show the user nothing. It also hardcodes
  `HotkeyShortcut.captureDefault.displayString` in the message instead of the attempted shortcut;
  `status.displayText` already says the right thing.

I did not edit either line. No other caller broke.

## Plan gaps and remaining uncertainties

- **Untestable by construction:** whether `⌃⌥ C`, or any given preset, actually registers on the
  user's machine. Only they can confirm no other app owns it; the conflict path now tells them.
- **`⇧⌘ 2` in "Screenshot style" is very likely to conflict** — macOS assigns `⇧⌘3`/`⇧⌘4`/`⇧⌘5`
  system-wide and `⇧⌘2` is close enough to that family that a user may have bound it themselves. It
  is in the pinned preset list so I implemented it as specified; the revert-on-failure path means
  choosing it is now recoverable rather than a dead end. Flagging, not changing.
- The `.conflict` mapping relies on Carbon returning `eventHotKeyExistsErr`; it does so only when
  the same combination is registered through the Carbon hot key API. A shortcut claimed by macOS's
  own Symbolic Hot Keys can register "successfully" here and simply never fire. Nothing in this
  task's scope detects that, and no fallback was invented for it.
- Concurrent workers were editing `SettingsView.swift`, `AppCoordinator.swift` and
  `AnnotationRenderer.swift` during my run; the 137-test green result reflects the tree at
  `2026-07-25 23:55`, and a later integration run is the authoritative one.

---

# Follow-up — expose the active shortcut

`register(_:)` reverted the Carbon registration but told no one *what it reverted to*, so the
coordinator could not keep the persisted selection in step with reality: a failed choice stayed in
`settings.hotkey`, and on the next launch it would be re-applied into a fresh process with no
last-good shortcut to fall back on — the MacDictate trap, one level up. `GlobalHotkeyManager` now
publishes live Carbon state.

## Declaration

`/Users/rich/Repos/MacPict/MacPict/GlobalHotkeyManager.swift`:

```swift
/// The shortcut currently registered with Carbon, or nil when none is.
@Published private(set) var activeShortcut: HotkeyShortcut?
```

`HotkeyRegistrationStatus` is untouched, and `status` still describes the *attempted* shortcut's
outcome. The two answer different questions: `status` is "did your choice take?", `activeShortcut`
is "what fires right now?".

## Collapsed with `lastGoodShortcut` — yes

`lastGoodShortcut` is **gone**; `activeShortcut` is the single stored property and serves as both
the published live state and the revert target. They were never actually two facts: every
successful registration replaces the previous one, and every failure or teardown leaves nothing
registered, so at every point in the old code the two held identical values. Keeping both would
have been two properties that could only ever drift by way of a bug — exactly what the pin warned
against. One property means the revert target cannot disagree with what callers are told is live.

The property's doc comment records this so nobody re-splits them later.

## Every site that mutates it

| Site | Mutation | Why |
|---|---|---|
| `attemptRegistration(of:)`, `case noErr` | `= shortcut` | the only successful `RegisterEventHotKey` in the file, so it covers the initial registration **and** the silent revert path — both funnel through here |
| `releaseHotkey()` | `= nil` | the only place it is cleared |

That is the complete list — two lines. `releaseHotkey()` is a new private helper that unregisters
`hotkeyRef`, nils it, and nils `activeShortcut` together, so the published value cannot outlive the
Carbon registration behind it. It is called from exactly two places:

- the top of `attemptRegistration(of:)` (was previously an inline `UnregisterEventHotKey`), which
  means a *failed* attempt ends with `activeShortcut == nil` before the revert is tried, and a
  failed **revert** therefore leaves it `nil` with nothing registered — no extra bookkeeping needed
- `unregister()`, which now reduces to `releaseHotkey()` plus `status = .notRegistered`

`register(_:)` reads `activeShortcut` into `previous` **before** attempting, since the attempt
releases the current registration; the `previous != shortcut` guard and the "report the attempt,
restore the last good one" policy are otherwise unchanged. The `else { lastGoodShortcut = nil }`
branch disappeared because `releaseHotkey()` already clears the state a failed revert leaves behind.

`deinit` still tears down `hotkeyRef` and `eventHandler` directly; it cannot touch main-actor state
and does not need to, as the object is going away.

One incidental behaviour change worth knowing: re-registering now logs "Global hotkey unregistered"
before "…registered", because the release log moved into the shared helper. Accurate, just chattier.

## Test coverage — what is and is not proven

Added to `/Users/rich/Repos/MacPict/MacPictTests/HotkeyShortcutTests.swift`:

- `testAFreshManagerHasNoActiveShortcut` — `activeShortcut == nil`, `status == .notRegistered`
- `testUnregisterLeavesNoActiveShortcut` — `unregister()` returns both to that state

Both are Carbon-free by construction, and a comment in the test file says why: a fresh manager
installs no event handler until `register(_:)` is called, and `unregister()` on it has no live
hotkey to release. They are `@MainActor` methods on the otherwise non-isolated suite.

**Still unproven, deliberately:** that `activeShortcut` is set on a real successful registration,
that it holds the *previous* shortcut after a revert, and that it is `nil` when a revert also
fails. All three require a live `RegisterEventHotKey` — process-global state that would make the
suite order-dependent and flaky, and per instruction no such test was written. Proving them would
need an injected registration function, a seam with exactly one production implementation; I judged
that speculative generality before, the coordinator agreed, and I have not added it now. The
mitigation remains structural: the two mutation sites above are the whole story, and both are one
line inside methods with no other state to coordinate.

## Validation

Run from `/Users/rich/Repos/MacPict`:

| Command | Exit code |
|---|---|
| `./scripts/bootstrap.sh` | **0** |
| `./scripts/build.sh` | **0** |
| `./scripts/test.sh` | **0** |

**`Executed 148 tests, with 0 failures (0 unexpected) in 4.508 seconds`** — the 146 tests present
in the tree plus my 2 new ones, all passing. `Test Suite 'HotkeyShortcutTests' passed` (10 tests),
`Test Suite 'SettingsStoreTests' passed` (6 tests). Zero `error:` lines and zero Swift compiler
warnings in both logs; the single `warning:` line is again the toolchain's
`appintentsmetadataprocessor … No AppIntents.framework dependency found.`

Files changed in this follow-up: `MacPict/GlobalHotkeyManager.swift` and
`MacPictTests/HotkeyShortcutTests.swift`. `SettingsStore.swift` and `SettingsStoreTests.swift`
needed no change. Nothing outside my ownership was touched, and no caller outside it broke —
`AppCoordinator.swift` (Task 7), `SettingsView.swift` (Task 8) and `AnnotationCanvasView.swift`
(Task 5) all compiled in this run at the state they held at `2026-07-26 00:13`.
