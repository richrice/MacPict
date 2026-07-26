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

---

# Feature — configurable capture hotkey wiring

Applied. Ownership unchanged: `MacPict/AppCoordinator.swift` and
`MacPictTests/CoordinatorTests.swift` only. `MacPictApp.swift`, `SettingsStore.swift`,
`GlobalHotkeyManager.swift` and `SettingsView.swift` were **not** touched;
`override convenience init()` still resolves and `AppDelegate` compiles unchanged, verified by
`./scripts/build.sh` exiting 0.

## The three reported defects, closed

1. **`start()` ignored the stored choice.** `hotkey.register(.captureDefault)` is gone.
   `start()` now calls `apply(settings.hotkey)`.
2. **`updateHotkeyItem(for:)` matched only `.failed`, so a `.conflict` displayed nothing.**
   It now hides the row only when the status `isRegistered`; `.conflict`, `.failed` and
   `.notRegistered` are all shown.
3. **The row hardcoded `HotkeyShortcut.captureDefault.displayString`.** It now uses
   `status.displayText`, which names the shortcut that actually failed.

## What changed in `AppCoordinator.swift`

**Ownership.** `private let settings: SettingsStore` added; the injection initialiser gained a
trailing `settings: SettingsStore` parameter and `override convenience init()` constructs
`SettingsStore()`. `private var settingsWindowController: SettingsWindowController?` is built on
first open and retained:

```swift
@objc private func openSettingsWindow() {
    let controller = settingsWindowController ?? SettingsWindowController(settings: settings, hotkey: hotkey)
    settingsWindowController = controller
    controller.show()
}
```

It is deliberately **not** cleared in `stop()`: dropping the last reference to a controller whose
window may still be on screen (`isReleasedWhenClosed = false`, so the controller is the only
owner) would deallocate a visible window.

**One funnel for shortcut changes.** Every path to the hotkey manager goes through:

```swift
private func apply(_ shortcut: HotkeyShortcut) {
    registeredShortcuts.append(shortcut)
    hotkey.register(shortcut)
    updateCaptureItem(for: shortcut)
}
```

so the menu title, the record of what was asked for, and the registration cannot drift apart.

## The Combine subscriptions and their teardown

Two `AnyCancellable`s, both established in `start()` after `apply(settings.hotkey)` has already
registered the current value, matching MacDictate's `AppCoordinator.swift:127-134`:

```swift
hotkeyCancellable = settings.$hotkey
    .dropFirst()
    .removeDuplicates()
    .sink { [weak self] shortcut in
        MainActor.assumeIsolated { self?.apply(shortcut) }
    }
statusCancellable = hotkey.$status
    .sink { [weak self] status in
        MainActor.assumeIsolated { self?.updateHotkeyItem(for: status) }
    }
```

- `.dropFirst()` — `@Published` replays the current value on subscribe, and `apply` above has
  already registered it; without this, launch would register twice.
- `.removeDuplicates()` — re-selecting the shortcut already in force would otherwise unregister a
  working Carbon hotkey and re-register it for no reason.
- `hotkey.$status` is **not** dropped: its immediate replay is the launch status, which is exactly
  what the menu row should show. The status is no longer written once at launch — every
  re-registration rewrites it — so the row follows the publisher instead of a return value.
- Teardown: `stop()` sets both cancellables to `nil` **first**, before `hotkey.unregister()` and
  before the menu is dismantled, so the `.notRegistered` that `unregister()` publishes cannot
  write into a half-torn-down menu. `registeredShortcuts` is also cleared there.

Delivery is synchronous: `@Published` fires from `willSet` on the main actor, so a test can assert
immediately after assigning `settings.hotkey`. `MainActor.assumeIsolated` is sound for the same
reason — both publishers are only ever mutated on the main actor.

## How the capture item presents the shortcut, and why that way

Title text, **not** a key equivalent. The item is now built with `keyEquivalent: ""` and no
modifier mask, and its title is rewritten by `updateCaptureItem(for:)` to
`"Capture Display Under Pointer (⌃⌥ C)"` — from `settings.hotkey.displayString` — at menu
construction and on every change.

The old code set `keyEquivalent: "4"` with `[.control, .option, .command]`. Reproducing that for
an arbitrary chosen shortcut would be a lie: an `NSMenuItem` key equivalent is AppKit's own
mechanism, handled by AppKit independently of the Carbon registration, so a shortcut that failed
to register would still appear to be a live accelerator; and seven of the twenty-one presets are
bare function keys (F13-F19), which have no honest key-equivalent character at all. The title is
descriptive and cannot be mistaken for a second, separately-handled binding.

## The Settings… item

Added between "Open Screen Recording Settings…" and the separator that precedes Quit, with
`keyEquivalent: ""` — no `⌘,` handler, which would need `MacPictApp.swift`. Menu order is now:
capture / separator / error row / hotkey-status row / permission row / Open Screen Recording
Settings… / **Settings…** / separator / Quit.

## Preserved from the earlier repairs (re-verified by the existing tests, unchanged)

- Single-flight capture guard (`testASecondRequestWhileACaptureIsInFlightIsIgnored`).
- The permission gate running unconditionally in the real flow (`permission.requestCount`
  assertions).
- Replacement-capture ordering — `closeActiveWindow()` still happens only after the new
  `AnnotationWindowController` exists (`testCaptureFailureLeavesAnAlreadyOpenSnapshotAndItsAnnotationsIntact`,
  `testPermissionDenialOnALaterCaptureLeavesAnOpenSnapshotIntact`,
  `testSuccessfulReplacementClosesThePreviousWindowExactlyOnce`). `performCapture()` was not
  touched by this change at all.

No existing assertion was weakened, deleted or reordered.

## Not asserting on Carbon, as instructed

`GlobalHotkeyManager` is `final` and pinned in the initialiser, so it cannot be faked or
subclassed; the six new tests call `start()`, which does perform a real `RegisterEventHotKey`.
What they **assert** on is the coordinator's decision, not Carbon's answer: whether a given
combination registers depends on what else is running on the machine (another app owning F19, or
the user's own MacPict already holding ⌃⌥ C), so `hotkey.status` is not a stable oracle. Two
internal seams make the decision observable:

```swift
/// Every shortcut handed to `GlobalHotkeyManager`, in order.
private(set) var registeredShortcuts: [HotkeyShortcut] = []
private(set) var captureItem: NSMenuItem?
private(set) var hotkeyItem: NSMenuItem?
func updateHotkeyItem(for status: HotkeyRegistrationStatus)   // was private
```

`registeredShortcuts` is an ordered list rather than a single value precisely so `.dropFirst()`
and `.removeDuplicates()` are falsifiable — a redundant re-registration shows up as an extra
element. `updateHotkeyItem(for:)` became internal because a `.conflict` cannot be produced on
demand; driving it directly is the only deterministic way to assert the message the user sees.
`registeredShortcuts` is cleared in `stop()`, so it is not an unbounded launch-to-quit log.

## New tests (`MacPictTests/CoordinatorTests.swift`, 6 added → 19 in the class)

The fixture now builds `SettingsStore(defaults:)` on a suite-named `UserDefaults`,
`"com.macpict.tests.CoordinatorTests"`, whose persistent domain is removed in both `setUp` and
`tearDown`. `.standard` is never referenced by this suite. Shortcuts come from
`HotkeyShortcut.presetGroups` via a `preset(_:)` lookup, so a test cannot assert against a
combination the settings window would not offer.

| Test | Proves |
|---|---|
| `testStartRegistersTheStoredShortcutRatherThanTheBuiltInDefault` | store holds F19 → `registeredShortcuts == [F19]` (exactly one registration, and not `.captureDefault`); capture title reads `Capture Display Under Pointer (F19)` |
| `testChangingTheStoredShortcutReRegistersWithTheNewOne` | assigning F18 appends it → `[⌃⌥ C, F18]`, title follows; re-assigning F18 leaves the list at two — `.removeDuplicates()` |
| `testAConflictIsShownInTheMenuWithTheShortcutThatFailed` | `.conflict("⌃⌥ C")` → row visible with the exact text `"Shortcut conflict: ⌃⌥ C is already in use"`; `.registered` hides it again |
| `testNotRegisteredIsAlsoShownRatherThanLeavingTheRowBlank` | `.notRegistered` → visible, `"Not registered"` |
| `testTheCaptureMenuItemStillCapturesWhileTheHotkeyIsInAFailedState` | with the row showing `"Registration failed: Carbon error -50"`, firing the item's own target/action (`perform(item.action)`, not `requestCapture()` directly) still yields `capture.callCount == 1` and a live window |
| `testTheMenuOffersSettingsAboveTheQuitSeparator` | a `Settings…` item exists before Quit, is followed by the separator, and has an empty key equivalent (no `⌘,`) |

These six are the only tests in the suite that call `start()`; the status item they install is
removed by `stop()` in `tearDown`.

### Falsification — the new tests are load-bearing

Both original defects were temporarily reintroduced together (`apply(.captureDefault)`, and
`updateHotkeyItem` restored to `guard case let .failed(code)` with the hardcoded default string),
and `-only-testing:MacPictTests/CoordinatorTests` run:

```
Executed 19 tests, with 7 failures (0 unexpected)
  testStartRegistersTheStoredShortcutRatherThanTheBuiltInDefault      failed
  testAConflictIsShownInTheMenuWithTheShortcutThatFailed              failed
  testNotRegisteredIsAlsoShownRatherThanLeavingTheRowBlank            failed
  testTheCaptureMenuItemStillCapturesWhileTheHotkeyIsInAFailedState   failed
```

Exactly the four tests aimed at those defects, and nothing else. The temporary lines were then
reverted from a saved copy; `grep -c "TEMPORARY-FALSIFICATION" MacPict/AppCoordinator.swift` → 0.
(`testChangingTheStoredShortcutReRegistersWithTheNewOne` correctly stayed green: the subscription
was not part of the reintroduced defect, and the falsified value coincided with the default.)

## Validation (final, real output, from `/Users/rich/Repos/MacPict`)

| Command | Exit code | Result |
|---|---|---|
| `./scripts/bootstrap.sh` | 0 | project regenerated |
| `./scripts/build.sh` | 0 | `** BUILD SUCCEEDED **` |
| `./scripts/test.sh` | 0 | `** TEST SUCCEEDED **`, **Executed 146 tests, with 0 failures (0 unexpected)** |

146 distinct tests across twelve suites; `CoordinatorTests` contributes 19 (13 previous + 6 new).
`grep -E "warning:"` over both logs, excluding the `appintentsmetadataprocessor` tool note →
no output, so zero Swift warnings.

### Red gates seen on the way, all from Task 5's concurrent work

Four earlier full-suite runs failed with 3, then 3, then 3, then 2 failures, always in
`MacPictTests/AnnotationWindowControllerTests.swift`
(`testCommittedTextLandsWhereTheEditorDrewIt`,
`testTextEditLiveAcrossACropCommitsAtTheSizeTheEditorWasShowing`,
`testTextEditLiveAcrossAResizeCommitsAtTheSizeTheEditorWasShowing`) — text-annotation pixel
assertions such as `failed - no annotation-coloured pixels were drawn at all`. That file does not
mention `AppCoordinator` at all (`grep -c AppCoordinator` → 0), and `CoordinatorTests` passed
19/19 in every one of those runs. I waited and re-ran rather than touching anything; the count
fell 3 → 2 → 0 as Task 5's edits to `AnnotationCanvasView.swift` landed. The final run above was
made against their settled state.

`SettingsWindowController` was already present in `MacPict/SettingsView.swift` when I started, so
no retry loop for Task 8 was needed.

## Plan gaps and unowned-caller breakage

None. No caller in a file I do not own was broken: `MacPictApp.swift` only uses
`AppCoordinator()` / `start()` / `stop()`, all unchanged.

One observation, not a defect and not fixed (it is outside my ownership): `MacPictApp.swift`
still declares a `Settings { EmptyView() }` scene, so macOS puts a `⌘,` "Settings…" item in the
application menu that opens an empty window. Now that a real settings window exists, that stock
item is misleading — but pointing it at `SettingsWindowController` needs `MacPictApp.swift`,
which PLAN §8 and this task both put out of bounds. Flagging it for the lead.

## Remaining uncertainties

- **Carbon registration is exercised but not asserted.** `start()` in the six new tests performs
  a real `RegisterEventHotKey` for whatever shortcut the test stored (F19/F18/⌃⌥ C), unregistered
  again by `stop()` in `tearDown`. `GlobalHotkeyManager` is `final` and pinned into the
  initialiser, so there is no seam to avoid this without changing a file I do not own. The
  consequence is bounded: pressing F18/F19 during a test run could fire a capture. If the lead
  wants that gone, the one-line change is a `HotkeyRegistering` protocol on the injected
  parameter, mirroring what was already done for `ScreenCapturePermissionProviding`.
- **`GlobalHotkeyManager.register`'s revert-to-last-good behaviour is invisible to the
  coordinator.** When a new shortcut fails, the manager silently restores the previous one, but
  `status` — and therefore the menu row and `SettingsView` — reports the failure of the shortcut
  the user picked, with no indication that the *old* one is still live. The user sees "Shortcut
  conflict: X is already in use" and is not told that Y still works. That is Task 2's design and
  its file; I implemented against it faithfully rather than papering over it in the menu text.
- **Not verified by me:** the settings window actually appearing and the picker driving a
  re-registration end to end (opening it calls `NSApp.activate`, which would seize focus mid-run,
  so no test opens it); the hotkey firing from another frontmost application; and the on-screen
  appearance of the new capture-item title. I did not launch the app, as instructed.

---

# Follow-up — persisted-conflict recovery and ⌘, routing

Both items applied. Ownership unchanged: `MacPict/AppCoordinator.swift` and
`MacPictTests/CoordinatorTests.swift` only. `MacPictApp.swift`, `GlobalHotkeyManager.swift`,
`SettingsStore.swift` and `SettingsView.swift` were not touched; `.macPictOpenSettings` and
`activeShortcut` had both landed by the time I built, so no retry loop was needed.

## Item 1 — the write-back, and the bug it exposed on the way

`apply(_:)` now reads what is really live and pulls the stored selection back to it:

```swift
private func apply(_ shortcut: HotkeyShortcut) {
    registeredShortcuts.append(shortcut)
    let status = hotkey.register(shortcut)
    let live = hotkey.activeShortcut
    updateHotkeyItem(for: status)
    updateCaptureItem(for: live)

    guard !status.isRegistered, let live, live != shortcut else { return }
    revertStoredShortcut(to: live)
}
```

`status` is still the *attempted* shortcut's outcome, so the user is still told their pick did not
take. `live` is read after `register(_:)` returns rather than inside the `$status` sink: Task 2's
`register` does settle `activeShortcut` before it publishes `status`, but relying on that ordering
from another file is the kind of coupling that breaks silently.

### The first attempt was wrong, and the test caught it

My first version wrote `settings.hotkey` synchronously inside the sink. It failed
`testAFailedShortcutIsNotLeftPersistedWhileAnotherIsStillLive` with the store still holding the
dead shortcut, and the reason is worth recording: **`@Published` publishes from `willSet`**. The
sink therefore runs *inside* the store's own assignment, so a write from the sink is flattened the
instant that assignment completes — and `SettingsStore.hotkey`'s `didSet { persistHotkey() }` then
writes the dead shortcut to disk. A synchronous write-back cannot work at all; it is not a matter
of ordering luck.

### The re-entrancy guard

```swift
private func revertStoredShortcut(to shortcut: HotkeyShortcut) {
    Task { @MainActor [weak self] in
        guard let self else { return }
        self.isRevertingStoredShortcut = true
        defer { self.isRevertingStoredShortcut = false }
        self.settings.hotkey = shortcut
        AppLogger.hotkey.info("Stored selection reverted to …")
    }
}
```

and in the sink:

```swift
// The one value that must not be acted on: the coordinator's own write-back
// of a shortcut the manager already reverted to. See `revertStoredShortcut`.
guard !self.isRevertingStoredShortcut else { return }
```

- The hop onto the next turn of the main actor is what makes the write stick, per the `willSet`
  problem above.
- The flag brackets **exactly one assignment**, and that assignment's sink delivery is synchronous
  with it, so the flag is true for precisely the callback it has to suppress and false everywhere
  else. It is set in this one method and read in one place.
- `removeDuplicates()` cannot do this job — the reverted shortcut genuinely differs from the one
  that just failed, so the sink would register it again. Mutation B below shows exactly that.
- `dropFirst()` / `removeDuplicates()` semantics are otherwise unchanged.

Cost, stated plainly: between the failed registration and the next main-actor turn the store still
holds the dead shortcut, so a hard kill inside that window would persist it. It is microseconds on
the main actor and there is no way to close it from my side — the fix would be for
`SettingsStore.hotkey` to publish from `didSet` instead.

## What happens when nothing is live

`activeShortcut == nil` — the fresh-launch conflict, where there is nothing to revert *to*:

- **The selection is left alone.** `guard … let live` simply does not fire, so the user's own
  choice stays in the picker where they can see and change it.
- **The menu says so outright.** The status row now appends the live state, because `status` alone
  cannot distinguish "your change failed but the old shortcut still works" from "you have no
  shortcut at all":
  - something live → `"Shortcut conflict: F18 is already in use — still using ⌃⌥ C"`
  - nothing live → `"Shortcut conflict: F17 is already in use — no capture shortcut is active"`
- **The capture item promises nothing.** `updateCaptureItem(for:)` now takes `HotkeyShortcut?` and
  is driven by `activeShortcut`, so with nothing registered the title is a bare
  `"Capture Display Under Pointer"`. Naming a shortcut there while the row two lines below says it
  is unavailable would have been a direct contradiction.
- **The menu item still captures**, which is what makes the state survivable — covered by a test.

## Item 2 — ⌘, routing

`start()` observes `.macPictOpenSettings` (declared by Task 1 in `MacPictApp.swift`; I did not
declare it) and routes it into the same `openSettingsWindow()` the status-menu item uses, so both
reach the one retained `SettingsWindowController`. `stop()` removes the observer alongside the two
cancellables, before the rest of the teardown.

`openSettingsWindow()` gained the `Self.suppressesWindowPresentation` guard already used for the
annotation window (PLAN R-6): the controller is still built and retained under test — which is the
routing the tests care about — but `show()`, which calls `NSApp.activate` and takes key focus, is
skipped so a test run cannot seize the developer's screen.

## New tests (5 added → 24 in `CoordinatorTests`)

Deterministic failure on demand comes from a `block(_:)` helper that occupies a shortcut with a
second `GlobalHotkeyManager`. I verified the premise with a standalone Carbon probe before relying
on it: a second `RegisterEventHotKey` for the same combination **in the same process** returns
`eventHotKeyExistsErr` (-9878) whether or not the `EventHotKeyID` matches, while a bogus key code
(`0xFFFF`) registers successfully — so duplicate registration is the only way to force a failure.
Assertions remain on the coordinator's decisions (`registeredShortcuts` ordering, `settings.hotkey`,
the persisted value, the menu text), never on whether Carbon happened to accept something.

| Test | Proves |
|---|---|
| `testAFailedShortcutIsNotLeftPersistedWhileAnotherIsStillLive` | F18 blocked, then selected: `registeredShortcuts == [⌃⌥ C, F18]` (asked once, no recursion), `settings.hotkey == ⌃⌥ C`, **and a freshly constructed `SettingsStore` on the same defaults also reads ⌃⌥ C** — i.e. the next launch cannot inherit the dead choice; row reads `"… — still using ⌃⌥ C"`; title reads `(⌃⌥ C)` |
| `testAConflictWithNothingLiveKeepsTheSelectionAndSaysNoShortcutIsActive` | F17 blocked and pre-loaded into the store: selection *and* persisted value stay F17, `activeShortcut == nil`, row reads `"… — no capture shortcut is active"`, title names no shortcut |
| `testTheCaptureMenuItemStillCapturesWhenNoShortcutCouldBeRegistered` | with nothing registered, the item's own target/action still produces `capture.callCount == 1` and a live window |
| `testTheOpenSettingsNotificationOpensTheSameWindowControllerAsTheMenuItem` | controller is nil before; posting `.macPictOpenSettings` builds it; firing the menu item afterwards yields the **same instance** (`===`) |
| `testTheOpenSettingsNotificationIsIgnoredAfterStop` | after `stop()`, a post builds nothing — the observer really is removed |

The persisted-value assertion goes through `SettingsStore(defaults:)` rather than a hand-decoded
`UserDefaults` key, so it exercises the production read path and does not hard-code Task 2's key
name. The suite-named defaults (`com.macpict.tests.CoordinatorTests`) are unchanged; `.standard` is
still never touched by this suite.

### Existing assertions that had to change, and why that is not a weakening

Three tests asserted the status row's old text, which the new live-state clause extends. Each was
updated to the new **exact** string, not relaxed:

- `testAConflictIsShownInTheMenuWithTheShortcutThatFailed` → `"Shortcut conflict: F13 is already
  in use — still using ⌃⌥ C"`. The synthetic status was changed from `.conflict("⌃⌥ C")` to
  `.conflict("F13")` because with the live shortcut also being ⌃⌥ C the message read "conflict:
  ⌃⌥ C … still using ⌃⌥ C", which is nonsense to enshrine in a test.
- `testNotRegisteredIsAlsoShownRatherThanLeavingTheRowBlank` → rebuilt on a nothing-live fixture
  (F15 blocked) so `.notRegistered` produces the coherent `"Not registered — no capture shortcut
  is active"` instead of claiming a shortcut was simultaneously live and not registered.
- `testTheCaptureMenuItemStillCapturesWhileTheHotkeyIsInAFailedState` → `"Registration failed:
  Carbon error -50 — still using ⌃⌥ C"`.

Two assertions were **added**, not removed: `XCTAssertEqual(hotkeyManager.activeShortcut, chosen)`
in the two tests that assert the capture-item title. The title now follows `activeShortcut`, so on
a machine where F19/F18 is already owned by something else those tests fail — and they now fail on
a line that names the cause rather than looking like a title bug. That is the one environment
dependence I introduced; it is the price of the title telling the truth.

## Mutation checks (each mutation applied alone, `-only-testing:MacPictTests/CoordinatorTests`)

| Mutation | Result |
|---|---|
| A — `revertStoredShortcut(to:)` call removed | exit 65, **`testAFailedShortcutIsNotLeftPersistedWhileAnotherIsStillLive` fails** (store and persisted value stay F18) |
| B — re-entrancy guard removed from the sink | exit 65, same test fails with `registeredShortcuts == [⌃⌥ C, F18, ⌃⌥ C]` — the write-back came straight back round as a second registration, exactly the loop the flag exists to stop |
| C — `.macPictOpenSettings` observer removed from `start()` | exit 65, **`testTheOpenSettingsNotificationOpensTheSameWindowControllerAsTheMenuItem` fails** |
| D — observer removal dropped from `stop()` | exit 65, **`testTheOpenSettingsNotificationIsIgnoredAfterStop` fails** |

No mutation failed a test other than the one aimed at it. All were reverted from a saved copy;
`grep -c MUTATION MacPict/AppCoordinator.swift` → 0 before the final gate.

## Validation (final, real output)

| Command | Exit code | Result |
|---|---|---|
| `./scripts/bootstrap.sh` | 0 | project regenerated |
| `./scripts/build.sh` | 0 | `** BUILD SUCCEEDED **` |
| `./scripts/test.sh` | 0 | `** TEST SUCCEEDED **`, **Executed 153 tests, with 0 failures (0 unexpected)** |

153 distinct tests, `CoordinatorTests` 24 of them (19 → 24). No failures anywhere in the suite this
time — Task 5's three text-annotation tests are green again. `grep -E "warning:"` over both logs,
excluding the `appintentsmetadataprocessor` tool note → no output.

## One thing I did wrong, and put back

Checking whether the tests leak into real preferences, I found
`"NSWindow Frame MacPictSettingsWindow" = "863 285 420 264 0 0 1728 1084 "` in the
`com.macpict.app` domain and deleted it to see whether my test would recreate it. It did not — the
key came from a real session in which someone opened the settings window, not from the suite — so I
**restored it byte-for-byte** with `defaults write`, and `defaults read com.macpict.app` now shows
the original value. Nothing else in that domain was touched. The useful half of the result stands:
building `SettingsWindowController` under test writes nothing to the user's defaults, because the
window is never shown.

## Remaining uncertainties

- The revert write-back's one-turn window (above) is unclosable from my file.
- The `.conflict` path is proven with an in-process duplicate registration. Whether macOS returns
  `eventHotKeyExistsErr` for a *cross-process* duplicate — the case the user will actually hit —
  is not something I can test from here, and the wording "is already in use by another
  application" assumes it does.
- Untested by me, unchanged from the previous round: the settings window actually appearing, ⌘,
  from the app menu end to end, and the hotkey firing from another frontmost application. I did
  not launch the app.

---

# Follow-up — synchronous write-back on the settled channel

Applied. Ownership unchanged: `MacPict/AppCoordinator.swift` and
`MacPictTests/CoordinatorTests.swift` only. `SettingsStore.swift` was not touched; I waited for
Task 2's `hotkeyDidChange` to land before building, then verified their ordering — `persistHotkey()`
runs *before* `send`, so the nested write-back's own `persistHotkey()` is the last thing to reach
`UserDefaults`.

## What changed

```swift
hotkeyCancellable = settings.hotkeyDidChange
    .removeDuplicates()
    .sink { [weak self] shortcut in
        MainActor.assumeIsolated {
            guard let self else { return }
            guard !self.isRevertingStoredShortcut else { return }
            self.apply(shortcut)
        }
    }
```

- Subscribed to `settings.hotkeyDidChange` instead of `settings.$hotkey`.
- `.dropFirst()` removed.
- `.removeDuplicates()` kept.
- The re-entrancy guard kept, its doc comment rewritten — it no longer describes an async hop.
- `revertStoredShortcut(to:)` is now a plain synchronous method; the `Task { @MainActor … }` is
  gone. `grep -n "Task {"` over the file finds only the pre-existing capture and flash tasks.
- `stop()` still clears `hotkeyCancellable` first, unchanged.

## `dropFirst` on a `PassthroughSubject` — verified, not assumed

You asked me to check rather than take your word for it. I ran a standalone Combine probe.

```
sends            : ["F19", "F18", "F17"]
with dropFirst   : ["F18", "F17"]     ← the user's first real change is gone
without dropFirst: ["F19", "F18", "F17"]
```

A late subscriber attached after three sends received `[]`, confirming there is no replay to skip.
So your reading is right: with `dropFirst()` the first shortcut the user picks after launch would
be silently ignored — the picker would move, nothing would register, and the old shortcut would
stay live with no error shown anywhere.

**One thing worth adding, because it makes the bug nastier than it looks.** I first probed with the
sequence `F19, F19, F18` and got *identical* output with and without `dropFirst()`:

```
sends            : ["F19", "F19", "F18"]
with dropFirst   : ["F19", "F18"]
without dropFirst: ["F19", "F18"]
```

`dropFirst` ate the first `F19` and `removeDuplicates` would have eaten the second, so the two
operators cancel out. A user who picked a shortcut and then re-picked the same one — or any test
written with a repeated value — would see correct behaviour and never suspect the defect. My probe
very nearly told me the operator was harmless. It is not; it just hides when the first change is
immediately repeated.

I also confirmed the nested-send timing the guard depends on: sending from inside a subject's own
sink is delivered **synchronously and re-entrantly**, so the flag is set for exactly the nested
callback it has to suppress (`["in:outer", "in:inner", "guardWas:true", "guardWas:false"]`).

## Tests changed, and why

- **`testAFailedShortcutIsNotLeftPersistedWhileAnotherIsStillLive`** was `async throws` with a
  bounded `awaitStoredShortcut(…)` wait between the assignment and the assertions. That wait
  existed *only* to accommodate the hop, so it is now `throws`, with nothing at all between
  `settings.hotkey = doomed` and the assertions. The assertions themselves are untouched. The
  `awaitStoredShortcut` helper was deleted rather than left unused.
- **`testTheRevertedShortcutIsStoredAndPersistedBeforeTheAssignmentReturns`** — new, and the one
  you asked for. F14 is blocked and selected; the very next statements assert
  `settings.hotkey == .captureDefault` and that a **second `SettingsStore` over the same defaults**
  reads `.captureDefault`. No `await`, no `yield`, no `sleep` — if any part of the write-back were
  deferred, the test would read the dead shortcut.

No other test changed. No assertion was weakened anywhere.

## Mutation checks (each applied alone, `-only-testing:MacPictTests/CoordinatorTests`)

| Mutation | Result |
|---|---|
| E — `.dropFirst()` put back on `hotkeyDidChange` | exit 65, **`testChangingTheStoredShortcutReRegistersWithTheNewOne` fails** (the first change is swallowed: `registeredShortcuts == [⌃⌥ C]`). Two more tests fall with it, since every test that makes a change loses its first one |
| F — re-entrancy guard removed from the sink | exit 65, **`testAFailedShortcutIsNotLeftPersistedWhileAnotherIsStillLive` fails** — the nested `send` comes straight back round as a second registration, exactly as it did on the `$hotkey` channel |
| G — the async hop reinstated in `revertStoredShortcut` | exit 65, **`testTheRevertedShortcutIsStoredAndPersistedBeforeTheAssignmentReturns` fails**, along with the now-synchronous persistence test. This is the check that the new test really does pin the closed window rather than passing by luck |

All reverted from a saved copy; `grep -c MUTATION MacPict/AppCoordinator.swift` → 0 before the
final gate.

## The window is closed — and here is why, precisely

Walking the whole nested sequence for `settings.hotkey = doomed`:

1. the stored property is updated to `doomed`; outer `didSet` begins;
2. `persistHotkey()` writes `doomed`;
3. `hotkeyDidChange.send(doomed)` → sink → `apply(doomed)` → registration fails, manager reverts,
   `activeShortcut == ⌃⌥ C`;
4. `revertStoredShortcut(to: ⌃⌥ C)` sets the guard and assigns `settings.hotkey = ⌃⌥ C`;
5. inner `didSet`: `persistHotkey()` writes `⌃⌥ C` — **the last write to reach `UserDefaults`** —
   then `send(⌃⌥ C)`, which the guard swallows;
6. the outer `didSet` returns.

Control never leaves the main actor between (1) and (6), so there is no turn of the run loop, and
no point at which anything outside this stack could observe or crash with the dead shortcut stored
or persisted. The residual hole I reported at the end of the previous round — "a hard kill inside
that window would persist a shortcut that does not work" — no longer exists. It required the store
to publish from `willSet`; on the settled channel it cannot arise.

## Validation (final, real output)

| Command | Exit code | Result |
|---|---|---|
| `./scripts/bootstrap.sh` | 0 | project regenerated |
| `./scripts/build.sh` | 0 | `** BUILD SUCCEEDED **` |
| `./scripts/test.sh` | 0 | `** TEST SUCCEEDED **`, **Executed 157 tests, with 0 failures (0 unexpected)** |

`CoordinatorTests`: 25 tests, 0 failures (24 → 25). 157 total, up from 153 — my one new test plus
three added by other workers in the same window. `grep -E "warning:"` over both logs, excluding the
`appintentsmetadataprocessor` tool note → no output.

## Remaining uncertainties

- Unchanged from the previous round: whether macOS returns `eventHotKeyExistsErr` for a
  *cross-process* duplicate — the case the user will actually hit — is not testable from here; the
  conflict path is proven with an in-process duplicate.
- The capture-item title still follows `activeShortcut`, so the two tests asserting it depend on
  F19/F18 being free on the machine; each asserts `activeShortcut` first so such a failure names
  its own cause.
- I did not launch the app.
