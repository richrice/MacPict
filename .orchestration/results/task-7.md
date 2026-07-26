# Task 7 — Integration and coordinator

## Files changed (nothing outside the ownership list)

- `MacPict/AppCoordinator.swift` — stub replaced entirely (ownership taken over from Task 1).
- `MacPictTests/CoordinatorTests.swift` — new, 9 tests.

`MacPictApp.swift` was **not** touched and did not need to be: `AppCoordinator()` /
`start()` / `stop()` still resolve exactly as before. `git status --porcelain` shows only the
pre-existing untracked top-level entries (the repo has a single empty commit, so everything is
untracked); no file outside my two was modified.

A temporary `MacPictTests/DiagnosticTemp.swift` existed for one `xcodebuild` invocation (see
"Was the test-host guard load-bearing?") and was deleted; `MacPictTests/` now contains exactly
the nine expected test files and `./scripts/bootstrap.sh` was re-run afterwards.

## Validation actually run, from `/Users/rich/Repos/MacPict`

Final run, in this order, after the diagnostic file was removed:

| Command | Exit code | Result |
|---|---|---|
| `./scripts/bootstrap.sh` | 0 | project regenerated |
| `./scripts/build.sh` | 0 | `** BUILD SUCCEEDED **` |
| `./scripts/test.sh` | 0 | `** TEST SUCCEEDED **`, **Executed 89 tests, with 0 failures (0 unexpected)** |

89 = the 80 pre-existing tests + my 9. `CoordinatorTests` reports
`Executed 9 tests, with 0 failures`.

Warning check: `grep -E "\.swift.*(warning|error):"` over both logs → **no output**. The only
line in either log containing "warning" is
`appintentsmetadataprocessor … Metadata extraction skipped. No AppIntents.framework dependency
found.`, a tool note, not a Swift diagnostic.

Beyond the gate (this is a manual observation, not part of the automated gate): I launched the
built app once (`open DerivedData/Build/Products/Debug/MacPict.app`), confirmed the process
stayed alive for ~4 s, and read the unified log:

```
[com.macpict.app:hotkey] Global hotkey <private> registered
[com.macpict.app:app] MacPict started
```

then `pkill -x MacPict` (verified terminated). So `start()` sets the activation policy, builds
the status item and registers ⌃⌥⌘4 successfully on this machine without crashing. I did **not**
visually inspect the menu bar, exercise the hotkey, or perform a real ScreenCaptureKit capture —
those remain the human-confirmation items §9 already lists.

## Declarations as written

```swift
@MainActor
final class AppCoordinator: NSObject {
    override convenience init()
    init(permission: ScreenCapturePermission,
         capture: any ScreenCapturing,
         delivery: any SnapshotDelivering,
         hotkey: GlobalHotkeyManager)

    private(set) var activeWindowController: AnnotationWindowController?
    private(set) var captureTask: Task<Void, Never>?      // ← added; see "extra members"

    func start()
    func stop()
    @objc func requestCapture()                            // ← added; see "extra members"
}

extension AppCoordinator: NSMenuDelegate { func menuWillOpen(_ menu: NSMenu) }
extension AppCoordinator: AnnotationWindowDelegate {
    func annotationWindowDidRequestCopyImage(_ controller: AnnotationWindowController)
    func annotationWindowDidRequestCopyPath(_ controller: AnnotationWindowController)
    func annotationWindowDidCancel(_ controller: AnnotationWindowController)
}
```

The pinned members are exactly as specified. Everything else is `private`.

### Extra members beyond the pinned shape, and why

- **`@objc func requestCapture()`** — the single capture entry point shared by
  `hotkey.onTrigger` and the menu item's `#selector`. It has to be `@objc` for the selector; it
  is internal rather than private so a test can drive the flow without calling `start()` (which
  would install a real status item and register the real global hotkey during a test run).
- **`private(set) var captureTask: Task<Void, Never>?`** — this *is* the "already in flight"
  flag (`guard captureTask == nil`), and the tests `await` it to know the asynchronous flow has
  finished. Reading it immediately after `requestCapture()` is deterministic: everything is
  `@MainActor`, so the task cannot start until the caller suspends.

## Implementation decisions

**Menu (built in `configureMenuBar`, order as in §6).** Capture Display Under Pointer
(`keyEquivalent: "4"`, `keyEquivalentModifierMask: [.control, .option, .command]`, so AppKit
renders "⌃⌥⌘4" itself) / separator / error row (disabled, `isHidden` until something fails) /
hotkey-registration row (disabled, `isHidden` unless `register` returned `.failed`, title
`"⌃⌥⌘4 is unavailable (error <OSStatus>)"`) / `"Screen Recording: Granted|Not granted"`
(disabled) / Open Screen Recording Settings… / separator / Quit MacPict ⌘Q
(`#selector(NSApplication.terminate(_:))`, no target). `menu.delegate = self`;
`menuWillOpen` calls `permission.refresh()` (preflight only — it never prompts) and rewrites the
permission row, so it cannot go stale.

**Hotkey failure is never swallowed.** `GlobalHotkeyManager` already logs the `OSStatus`; the
coordinator additionally un-hides the status row with the code in it, and the menu item is a
fully independent trigger, so a claimed ⌃⌥⌘4 degrades the app to "menu only" rather than
breaking it.

**Error surfacing.** One private `report(_:to:)` writes the message to the given `Logger`
(`AppLogger.capture` for capture, `AppLogger.delivery` for export/delivery) *and* un-hides the
menu row with the same text. A successful capture and a successful delivery both call
`clearMessage()`. Menu text uses `String(describing: error)` rather than
`error.localizedDescription`: the domain enums are not `LocalizedError`, so `localizedDescription`
renders as "The operation couldn't be completed. (MacPict.ScreenCaptureError error 2.)", whereas
`String(describing:)` gives "displayNotShareable". I did not add a `LocalizedError` conformance
because those types belong to other tasks.

**Capture flow.** `requestCapture()` ignores the request when `captureTask != nil` (logged at
info). `performCapture()` then: closes any open window first (a hotkey press always means "new
snapshot"), gates on permission, `try await capture.captureDisplayUnderPointer()`, picks the
`NSScreen` whose `DisplayLocator.displayID` equals `snapshot.displayID` (falling back to
`NSScreen.main` then `screens.first` — D-3 forbids matching on frames), builds
`AnnotationDocument(image:)` and `AnnotationWindowController(document:screen:)`, sets
`annotationDelegate = self`, retains it in `activeWindowController`, clears the error row, and
presents. Any thrown error clears `activeWindowController`, presents no window, logs, and
surfaces.

**Export.** `SnapshotExporter.png(image:annotations:cropRect: document.isCropped ? document.cropRect : nil)`.

**Delivery-failure handling** (`deliver(_:from:)`): export and delivery are inside one `do`; the
`catch` reports and **returns without dismissing**, so the window and the user's annotations
survive a failed write. Only the success path calls `dismiss` + `flashSuccess`.

**Re-entrancy of dismissal.** `dismiss(_:)` clears `activeWindowController` *before* calling
`controller.close()`, because closing re-enters through `NSWindowDelegate.windowWillClose` →
`AnnotationWindowController.finish(.cancel)` → `annotationWindowDidCancel`. With the field
already nil, the re-entrant `dismiss` is a no-op on a controller that is not the active one.

## Status-item flash re-entrancy safety

```swift
private func flashSuccess() {
    flashTask?.cancel()                 // ← the whole trick
    setStatusSymbol(Self.successSymbol)
    flashTask = Task { [weak self] in
        try? await Task.sleep(for: Self.flashDuration)   // 800 ms
        guard !Task.isCancelled else { return }
        self?.setStatusSymbol(Self.idleSymbol)
        self?.flashTask = nil
    }
}
```

A second delivery cancels the first restore before starting its own, so the icon can never be
left on the checkmark, and the earlier task cannot fire a late "restore" that would cut the
newer flash short: everything runs on the main actor, so if the older task's sleep expired
before the newer flash was scheduled, the older task resumes only after the newer flash has
already set `Task.isCancelled`, and it returns at the guard. `stop()` also cancels the pending
flash so nothing writes to a removed status item.

## Presentation and TCC during tests, and the one contract that proved awkward

`AppCoordinator` has one private flag:

```swift
private static let isRunningInTests = NSClassFromString("XCTestCase") != nil
```

used in exactly two places: `controller.present()` is skipped, and `hasCapturePermission()`
returns `true` without calling `permission.requestIfNeeded()`. This is PLAN R-6's own mechanism
(the same guard `AppDelegate` already uses), applied to the two steps of the flow that reach
outside the process.

**Why presentation is skipped:** `AnnotationWindowController.present()` calls `NSApp.activate()`
and `makeKeyAndOrderFront`, which would steal focus from the developer mid-run. Everything else
is real in the tests: the real `AnnotationWindowController`, its real `NSPanel`, hosting view,
canvas, and the real delegate wiring. Only the ordering-front is skipped.

**Why the permission request is skipped — this is the awkward contract.** The amended
initialiser takes the **concrete** `ScreenCapturePermission`, which is a `final class` reading
`CGPreflightScreenCaptureAccess()` / `CGRequestScreenCaptureAccess()`. It cannot be faked or
subclassed. I measured the host: `CGPreflightScreenCaptureAccess() == false`,
`bundle == com.macpict.app`, and the system TCC database has **no** `kTCCServiceScreenCapture`
row for `com.macpict.app`. So without the guard, every capture test would call
`CGRequestScreenCaptureAccess()` — putting a TCC dialog on screen mid-test-run — get `false`
back, and abort before the fake capture was ever reached, making all seven required assertions
impossible.

**Was the test-host guard load-bearing?** Yes, and I verified it rather than assuming:
a temporary `DiagnosticTests` compiled into the test target reported
`preflight=false xctestLoaded=true bundle=com.macpict.app`; the file was then deleted and the
project regenerated.

**What the lead may want to change.** Two options, both one line, neither taken because the
signature is pinned and deviating was explicitly out of bounds:
1. Change the injection parameter to a protocol (`any ScreenCapturePermitting`) that
   `ScreenCapturePermission` conforms to. Call sites are unchanged (`AppCoordinator(permission:
   ScreenCapturePermission(), …)` still compiles), the production path loses its
   test-conditional entirely, and the denial branch — currently **untested** — becomes testable.
2. Accept the guard as is.

The cost of the current state, stated plainly: the "permission denied → log, update menu, stop"
branch has no automated coverage, and production code contains a branch that behaves differently
under XCTest.

## Defects found in other workers' code (reported, not fixed — I do not own these files)

**D-1 (real, user-visible) — `MacPict/AnnotationWindowController.swift`: after a failed
delivery the window survives but becomes inert.** `finish(_:)` sets `hasFinished = true` *before*
calling the delegate and guards every later call:

```swift
private func finish(_ action: Finish) {
    guard !hasFinished else { return }
    hasFinished = true
    …
}
```

That guard is correct for the success path (it stops `close()` from reporting a spurious cancel).
But my `deliver` failure path deliberately leaves the window open, and at that point
`hasFinished` is already `true`, so ⌘↩, ⌥⌘↩, ⌘W and Esc all do nothing for the rest of the
window's life. The user keeps their annotations but can never retry the copy — which is most of
the value of leaving the window open. It also means closing that window with the red button
never reports a cancel, so `activeWindowController` stays set until the next capture.
Suggested fix, in Task 5's file: have `finish` reset the flag when the delegate declines to
close — e.g. `annotationDelegate` returning a `Bool` from the two copy methods, or a small
`func resumeAfterFailedDelivery()` that the coordinator calls in its `catch`. Either changes both
files, so it needs the lead's call. My tests cover the coordinator half of this
(`testDeliveryThatThrowsLeavesTheWindowOpen` passes); the inertness is in the window controller.

**D-2 (cosmetic) — `MacPict/GlobalHotkeyManager.swift`:** `AppLogger.hotkey.info("Global hotkey
\(shortcut.displayString) registered")` logs as `Global hotkey <private> registered` (os_log
redacts non-literal interpolations by default). Other call sites in the app pass
`privacy: .public`. Harmless, one word to fix, not mine.

No caller in a file I do not own was broken by my change.

## Tests written (`MacPictTests/CoordinatorTests.swift`, 9 tests, all passing)

Inline fakes above the class, matching the other test files' style: `FakeScreenCapture`
(returns a synthetic 120×80 `CGImage` as a `CapturedSnapshot`, counts calls, throws on demand)
and `FakeDelivery` (records the PNG bytes for each of `copyImage` / `copyFilePath`, throws on
demand). The coordinator is built with the injection initialiser, a real
`ScreenCapturePermission` and a real, never-registered `GlobalHotkeyManager`. No test calls
`start()`, so no status item is installed and no global hotkey is registered by the suite.

| Test | Proves |
|---|---|
| `testSuccessfulCaptureDeliversExactlyOnePNGAtTheCapturedPixelSize` | one delivery call; PNG decodes to 120×80; window cleared |
| `testCaptureThatThrowsDeliversNothingAndLeavesNoWindow` | zero deliveries, `activeWindowController == nil` |
| `testCopyImageActionCallsCopyImageAndNotCopyFilePath` | image path only |
| `testCopyPathActionCallsCopyFilePathAndNotCopyImage` | path path only |
| `testCancelDeliversNothingAndClosesTheWindow` | zero deliveries, window cleared |
| `testDeliveryThatThrowsLeavesTheWindowOpen` | annotation-preservation guarantee |
| `testCroppedDocumentIsDeliveredAtTheCropSize` | 60×40 crop exports 60×40, not 120×80 |
| `testASecondRequestWhileACaptureIsInFlightIsIgnored` | `capture.callCount == 1` |
| `testANewCaptureReplacesTheWindowLeftOpenByThePreviousOne` | second controller ≠ first, no delivery from the discarded one |

The last two are beyond the listed required tests but cover two behaviours the brief mandates
("no overlapping captures", "close it and capture fresh") that would otherwise ship unverified.
No assertion was weakened at any point; the suite passed on its first full run.

## Remaining uncertainties

- The permission-denied branch is not covered (see above).
- The status-item flash, the menu rows and their hidden/shown states are not asserted by tests:
  building them requires `start()`, which installs a real status item into the user's menu bar
  during a test run. I judged that a worse trade than leaving them to the manual check. They are
  exercised only by the manual launch, which showed startup and successful hotkey registration.
- Key-equivalent delivery of ⌘↩ / ⌥⌘↩ from the panel to the coordinator has been proven at both
  ends separately (Task 5's harness fired the canvas callbacks; my tests drive the delegate
  methods) but never through a real running window. Same for the real ScreenCaptureKit capture
  and the hotkey arriving from another frontmost app — §9 already lists these as manual.
- `screen(for:)` falls back to `NSScreen.main` then `screens.first` when no screen matches the
  captured display ID (a display disconnected between capture and presentation); the window then
  appears on another display rather than not at all. If no screen exists at all the flow reports
  "No screen is available to show the snapshot" and presents nothing.

---

# Repair 1 — live permission gate / Repair 2 — denial coverage

Both repairs applied. Ownership unchanged: only `MacPict/AppCoordinator.swift` and
`MacPictTests/CoordinatorTests.swift` were edited. `MacPict/MacPictApp.swift` was **not**
touched and still reads `AppCoordinator()` / `start()` / `stop()` — verified by building, not by
reasoning: `./scripts/build.sh` compiles `MacPictApp.swift` against the amended initialiser and
exits 0.

## Repair 1 — what changed in `AppCoordinator.swift`

Amended initialiser (the only signature change; `override convenience init()` is untouched and
still hands it the real `ScreenCapturePermission`):

```swift
private let permission: any ScreenCapturePermissionProviding

override convenience init() {
    let permission = ScreenCapturePermission()
    self.init(permission: permission,
              capture: ScreenCaptureService(permission: permission),
              delivery: DeliveryService(),
              hotkey: GlobalHotkeyManager())
}

init(permission: any ScreenCapturePermissionProviding,
     capture: any ScreenCapturing,
     delivery: any SnapshotDelivering,
     hotkey: GlobalHotkeyManager)
```

The `hasCapturePermission()` wrapper is **deleted**. `performCapture()` now calls the gate
directly and unconditionally:

```swift
// The gate every user meets on first launch: it is what raises the TCC prompt, and
// it runs unconditionally so the tests exercise the same path production does.
guard permission.requestIfNeeded() else {
    refreshPermissionItem()
    report("Screen Recording permission is not granted", to: AppLogger.capture)
    return
}
```

The flag survives for presentation only, renamed and re-commented to say exactly that:

```swift
/// PLAN R-6: the unit tests run inside this app as their own host, and presenting the
/// annotation window activates the app and takes key focus — which would yank the
/// developer out of whatever they are doing mid-run. Presentation is the only step
/// skipped; everything else in the capture flow, the permission gate included, runs
/// under test exactly as it runs in production.
private static let suppressesWindowPresentation = NSClassFromString("XCTestCase") != nil
```

`grep` over the final file confirms exactly one use of the flag (`if
!Self.suppressesWindowPresentation { controller.present() }`) and no remaining
`isRunningInTests`.

## Repair 1 — what changed in `CoordinatorTests.swift`

- New inline `FakePermission: ScreenCapturePermissionProviding` (same pattern as Task 2's
  `StubScreenCapturePermission`): a fixed `status`, and counters for `requestIfNeeded`,
  `refresh` and `openSettings`.
- The fixture now injects `FakePermission(status: .granted)` and builds the coordinator through
  a `makeCoordinator()` helper, so the eight capture-reaching tests pass the **real** gate
  rather than bypassing it. The concrete `ScreenCapturePermission` is no longer referenced
  anywhere in the file (`grep -c "ScreenCapturePermission("` → 0).
- `testSuccessfulCaptureDeliversExactlyOnePNGAtTheCapturedPixelSize` gained
  `XCTAssertEqual(permission.requestCount, 1)`, pinning that the success path runs through the
  gate rather than around it.
- No existing assertion was weakened or deleted; the eight original tests are unchanged apart
  from that one addition, and all still pass.

## Repair 2 — the denial test

`testDeniedPermissionStopsBeforeAnyCaptureIsAttempted` — rebuilds the coordinator with
`FakePermission(status: .denied)`, runs a capture request, and asserts:

| Assertion | What it proves |
|---|---|
| `permission.requestCount == 1` | the gate actually ran — without this the test would also pass if the flow had never started |
| `capture.callCount == 0` | `captureDisplayUnderPointer()` was never reached |
| `delivery.copiedImages.count == 0`, `delivery.copiedPaths.count == 0` | zero delivery calls |
| `coordinator.activeWindowController == nil` | no window |
| `permission.refreshCount == 1` | the menu's permission row is re-read on the way out, so it reflects the denial that stopped the capture |

## No TCC dialog — confirmed, with evidence

No permission dialog appeared during the run, and this is checkable rather than merely observed:

- **The system TCC database still has no row for the app after the run.**
  `sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "select service, client,
  auth_value from access where client like '%macpict%';"` → **empty**. A real
  `CGRequestScreenCaptureAccess()` would have prompted and recorded the user's answer there.
- **The real `ScreenCapturePermission` never ran its request path.** It logs
  "Screen Recording permission was requested and is still not granted" on a denied request;
  `/usr/bin/log show --predicate 'subsystem == "com.macpict.app"' --last 5m --info` contains
  **0** such lines.
- **Structurally, it cannot happen from this suite:** every coordinator in `CoordinatorTests`
  is constructed with `FakePermission`, whose `requestIfNeeded()` only increments a counter.
  The one place the concrete class is still constructed in the whole test target is Task 2's
  `testConcreteScreenCapturePermissionSatisfiesTheProvidingProtocol`, which only triggers
  `refresh()` (preflight — never prompts).

Injecting a granting fake was sufficient; the skip was not reinstated in any form.

## Validation after the repairs (real output)

| Command | Exit code | Result |
|---|---|---|
| `./scripts/bootstrap.sh` | 0 | project regenerated |
| `./scripts/build.sh` | 0 | `** BUILD SUCCEEDED **` |
| `./scripts/test.sh` | 0 | `** TEST SUCCEEDED **`, **Executed 99 tests, with 0 failures (0 unexpected)** |

99 = the 98 that existed when the repair was dispatched + the one new denial test.
`grep -E "\.swift.*(warning|error):"` over both logs → no output; the only "warning" line
remains the `appintentsmetadataprocessor` tool note.

`CoordinatorTests` now holds 10 tests. The earlier report's defect **D-1** (the window going
inert after a failed delivery) is closed by Task 5's `isClosed` change: the latch now moves in
`close()` rather than in `finish(_:)`, so a delegate that declines to close leaves the window
retryable. `testDeliveryThatThrowsLeavesTheWindowOpen` still passes against the new behaviour,
and `dismiss(_:)` still clears `activeWindowController` before calling `close()`, which the
rewritten `windowWillClose` handles correctly.

---

# Repair 3 — failed replacement capture must not destroy the open snapshot

Applied. Ownership unchanged: `MacPict/AppCoordinator.swift` and
`MacPictTests/CoordinatorTests.swift` only.

## What changed in `AppCoordinator.swift`

`performCapture()` was restructured so that **nothing is destroyed until the replacement
exists**. `closeActiveWindow()` moved from the first statement to immediately after the new
`AnnotationWindowController` has been constructed, and the `catch` no longer clears
`activeWindowController`:

```swift
/// A window left open by a previous capture stays open, live and untouched until a
/// replacement is certain. Every early return below is a failure of the *new* capture,
/// and none of them may destroy annotations the user has already made. Leaving that
/// window on screen during the capture is safe: the content filter excludes this
/// application outright, so it cannot appear in the new snapshot (PLAN D-4).
private func performCapture() async {
    guard permission.requestIfNeeded() else { … ; return }      // old window untouched

    let snapshot: CapturedSnapshot
    do {
        snapshot = try await capture.captureDisplayUnderPointer()
    } catch {
        report("Capture failed: …", to: AppLogger.capture)
        return                                                   // old window untouched
    }

    guard let screen = screen(for: snapshot.displayID) else { … ; return }  // untouched

    let controller = AnnotationWindowController(
        document: AnnotationDocument(image: snapshot.image), screen: screen)
    controller.annotationDelegate = self
    // The replacement exists and nothing else can fail from here, so now — and only
    // now — the previous snapshot goes.
    closeActiveWindow()
    activeWindowController = controller
    clearMessage()
    if !Self.suppressesWindowPresentation { controller.present() }
    …
}
```

The single-flight guard is untouched: `requestCapture()` still returns early while
`captureTask != nil`, and `testASecondRequestWhileACaptureIsInFlightIsIgnored` still passes.
The only two `closeActiveWindow()` call sites are now the post-construction replacement and
`stop()`.

## New tests (no existing assertion weakened or deleted)

- **`testCaptureFailureLeavesAnAlreadyOpenSnapshotAndItsAnnotationsIntact`** — captures, appends
  a real `.box` annotation to the first document, then makes the fake throw
  `ScreenCaptureError.displayNotShareable` on a second capture. Asserts
  `coordinator.activeWindowController === first` (object identity, not merely non-nil),
  `first.document.annotations == [annotation]` (the user's work itself, not just a pointer),
  `capture.callCount == 2`, and zero delivery calls.
- **`testPermissionDenialOnALaterCaptureLeavesAnOpenSnapshotIntact`** — same shape, with a
  `.arrow` annotation and `permission.status = .denied` before the second capture. Asserts
  `permission.requestCount == 2` (the gate ran), `capture.callCount == 1` (it stopped before
  ScreenCaptureKit), identity of the surviving controller, the preserved annotation, and zero
  deliveries. `FakePermission.status` became settable so one coordinator can be flipped from
  granted to denied mid-test.
- **`testSuccessfulReplacementClosesThePreviousWindowExactlyOnce`** — observes
  `NSWindow.willCloseNotification` for the first controller's window through a small
  `WindowCloseCounter` (a reference type, because the notification block is `@Sendable`), then
  runs a second successful capture. Asserts `first !== second`, `closes.count == 1`, and
  `firstWindow.isVisible == false` — so the fix cannot regress into never replacing, or into
  double-closing.

`CoordinatorTests` is now 13 tests.

## Verified empirically, not by inspection

I temporarily restored the defect — re-added `closeActiveWindow()` as the first statement of
`performCapture()` — and ran
`xcodebuild … -only-testing:MacPictTests/CoordinatorTests test`:

```
Executed 13 tests, with 2 failures (0 unexpected)
Test Case '-[MacPictTests.CoordinatorTests testCaptureFailureLeavesAnAlreadyOpenSnapshotAndItsAnnotationsIntact]' failed
Test Case '-[MacPictTests.CoordinatorTests testPermissionDenialOnALaterCaptureLeavesAnOpenSnapshotIntact]' failed
```

Exactly the two preservation tests failed, and nothing else did — they are load-bearing, and the
other eleven are not accidentally covering the same ground. The temporary line was then removed;
`grep -n "TEMPORARY" MacPict/AppCoordinator.swift` → no matches, and the final gate below was run
after the revert.

## Validation (final, real output)

| Command | Exit code | Result |
|---|---|---|
| `./scripts/bootstrap.sh` | 0 | project regenerated |
| `./scripts/build.sh` | 0 | `** BUILD SUCCEEDED **` |
| `./scripts/test.sh` | 0 | `** TEST SUCCEEDED **`, **Executed 120 tests, with 0 failures (0 unexpected)** |

`grep -E "\.swift.*(warning|error):"` over both logs → no output.
`CoordinatorTests`: 13 tests, 0 failures.

## Interference from concurrent repairs (reported, not touched)

While this repair was in flight I hit two transient red gates caused entirely by other workers'
files, and waited them out rather than editing anything:

1. `MacPict/SnapshotExporter.swift:74: error: type 'AnnotationDocument' has no member
   'pixelAlignedRect'`, then `… call to main actor-isolated static method 'pixelAlignedRect'
   in a synchronous nonisolated context`, then `AnnotationModel.swift:260: main actor-isolated
   static property 'minimumCropSide' can not be referenced from a nonisolated context` — the
   Task 3 / Task 4 crop-alignment repair landing in two steps. Resolved on its own.
2. Five failures in `MacPictTests/AnnotationWindowControllerTests.swift`
   (`testCancelDiscardsPendingTextRatherThanCommittingIt`,
   `testToolbarCopyImage/PathCommitsPendingTextBeforeNotifyingTheDelegate`) — the Task 5
   toolbar text-commit repair mid-flight. `CoordinatorTests` passed 13/13 in that same run.
   Resolved on its own before the final gate.

One further transient, not attributable to anyone's source: a single `./scripts/test.sh`
invocation died with `Unable to initialize test bundle … MacPictTests.xctest`, a build-race
against a concurrent worker's build writing the same `DerivedData`. Re-running it immediately
gave exit 0. Worth knowing if the review sees it: it is a parallel-build artefact, not a code
defect.
