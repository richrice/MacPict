# Task 6 — Delivery — result

## Files created

- `/Users/rich/Repos/MacPict/MacPict/DeliveryService.swift`
- `/Users/rich/Repos/MacPict/MacPictTests/DeliveryServiceTests.swift`

Nothing else was touched. `project.yml` was not edited (XcodeGen enumerates the
`MacPict/` and `MacPictTests/` directories).

## Declarations as actually written

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
    static var defaultDirectory: URL           // FileManager.default.temporaryDirectory/MacPict
    static func fileName(for timestamp: Date) -> String
    let directory: URL
    init(directory: URL = DeliveryService.defaultDirectory, pasteboard: NSPasteboard = .general)
    func copyImage(_ png: Data) throws
    @discardableResult func copyFilePath(_ png: Data, timestamp: Date) throws -> URL
}
```

Matches §5.6 exactly. `DeliveryOutcome` is declared for Task 7 even though
`DeliveryService` never returns it.

## Implementation decisions

- `copyImage` does `clearContents()` → `setData(png, forType: .png)` → `setData(tiff, forType: .tiff)`.
  No `writeObjects:` anywhere (C-7). The `.png` payload is the caller's exact `Data`;
  it is never round-tripped through `NSImage`. The TIFF is derived separately via
  `NSBitmapImageRep(data: png)?.tiffRepresentation`. A `false` return from the PNG
  `setData` throws `.pasteboardWriteFailed`; a failure to derive or set the TIFF is
  logged as an error but does not fail the primary delivery (the PNG is on the board).
- `copyFilePath` creates `directory` with `withIntermediateDirectories: true`, writes the
  caller's exact bytes with `Data.write(to:options: .atomic)`, then `clearContents()` +
  `setString(url.path, forType: .string)` — plain POSIX text, not a file-URL flavour —
  and returns the URL it wrote. Directory-creation and file-write failures are wrapped as
  `.fileWriteFailed(message)` with the offending path and the underlying
  `localizedDescription`. A pasteboard rejection throws `.pasteboardWriteFailed`.
- `fileName(for:)` uses a cached `DateFormatter` pinned to `Locale(identifier: "en_US_POSIX")`,
  `TimeZone.current`, format `yyyy-MM-dd-HHmmss`, producing `MacPict-2026-07-25-143012.png`.
- Logging via `AppLogger.delivery` with `privacy: .public` interpolations, matching MacDictate.

### Same-second collision

`fileName(for:)` delegates to a private `fileName(for:attempt:)`. Attempt 0 is the plain
`MacPict-<stamp>.png`; attempt *n* > 0 appends `-n` before the extension. `copyFilePath`
increments the attempt while `FileManager.fileExists(atPath:)` reports the candidate
present, so it always writes to a name nothing occupies and the returned URL always names
the bytes just written. The service is `@MainActor`, so it is the only writer in the
process and the check-then-write sequence cannot interleave with itself.
`testTwoCapturesInTheSameSecondEachKeepTheirOwnBytes` proves both calls' bytes survive at
their own returned URLs, and asserts the second file is `MacPict-2026-07-25-143012-1.png`.

## Tests

`DeliveryServiceTests` (10 tests, all passing):

1. `testCopyImagePlacesByteIdenticalPNGDataOnThePasteboard` — reads `.png` back off the
   pasteboard and compares to the exact input `Data`.
2. `testCopyImageAlsoProvidesATIFFRepresentation` — decodes the `.tiff` payload and asserts
   4×3 pixel dimensions.
3. `testCopyFilePathWritesTheExactBytesToDisk` — asserts the URL and the on-disk bytes.
4. `testCopyFilePathPutsThePOSIXPathOnThePasteboardAsAString` — pasteboard `.string` equals
   `url.path`, and no `.png` flavour is present.
5. `testFileNameIsStableForAFixedDate` — asserts the full literal
   `MacPict-2026-07-25-143012.png` for a `DateComponents`-built date in `TimeZone.current`.
6. `testDirectoryIsCreatedWhenAbsent` — asserts absent before, present *and a directory* after.
7. `testTwoCapturesInTheSameSecondEachKeepTheirOwnBytes` — see above.
8. `testDefaultDirectoryIsTheTemporaryMacPictFolder`.
9. `testDeliveryOutcomeDistinguishesImageFromPath`.
10. `testFileWriteFailureIsReportedWhenTheDirectoryIsNotWritable` — plants a regular file
    where the directory should be and asserts `.fileWriteFailed` carrying that path.

**No test touches `NSPasteboard.general`.** `setUp` builds
`NSPasteboard(name: NSPasteboard.Name("com.macpict.tests.<UUID>"))` and injects it;
`tearDown` calls `releaseGlobally()`. Each test also gets its own
`temporaryDirectory/MacPictDeliveryTests-<UUID>` which `tearDown` deletes — verified zero
leftover directories after the run.

## Validation (run from /Users/rich/Repos/MacPict)

| Command | Exit code | Notes |
|---|---|---|
| `./scripts/bootstrap.sh` | 0 | `Generated MacPict.xcodeproj` |
| `./scripts/build.sh` | 0 | `** BUILD SUCCEEDED **`; zero Swift compiler warnings (the only "warning:" line in the log is `appintentsmetadataprocessor: Metadata extraction skipped. No AppIntents.framework dependency found.`, a tool note, not a compiler diagnostic) |
| `./scripts/test.sh` | 65 | **`DeliveryServiceTests` passed 10/10 with 0 failures.** The non-zero suite exit comes from another worker's file, see below. |

Whole-suite line: `Executed 44 tests, with 1 failure`. The single failure is
`CanvasGeometryTests.testTallerThanViewImageIsPillarboxed`
(`/Users/rich/Repos/MacPict/MacPictTests/CanvasGeometryTests.swift:27`,
`XCTAssertEqual failed: ("(50.0, 0.0, 300.0, 400.0)") is not equal to ("(100.0, 0.0, 300.0, 400.0)")`)
— Task 3's file, which I do not own and did not touch. My files compile and pass cleanly
inside that same run.

## Failures encountered and corrected

- First test run failed `testTwoCapturesInTheSameSecondEachKeepTheirOwnBytes`: the two PNGs
  I generated were byte-identical. Cause was `NSBitmapImageRep.setColor(_:atX:y:)` leaving
  the buffer unchanged, so both fixtures encoded the same uninitialised bitmap. Fixed by
  filling the rep through an `NSGraphicsContext(bitmapImageRep:)` instead. This was a test
  fixture defect, not a weakened assertion — the assertion `XCTAssertNotEqual(first, second)`
  was kept and now genuinely holds.
- An earlier `./scripts/test.sh` run failed to compile `CanvasGeometryTests.swift`
  (another worker mid-write). Re-running after that worker landed its file resolved it.

## Plan gaps / unowned-caller breakage

None. No caller outside my ownership references `DeliveryService` yet (Task 7 will).
No deviations from the pinned contract.

## Remaining uncertainties

- `fileName(for:)`'s formatter captures `TimeZone.current` once per process. A time-zone
  *change* while the app is running would keep the old zone until relaunch. Not worth a
  fix for a short-lived capture flow; flagged rather than engineered around.
- `copyImage` logs but does not throw when the TIFF companion cannot be produced. The PNG —
  the payload every target actually consumes — is on the pasteboard at that point, so
  failing the delivery would be worse than the degraded state. Stated here so the choice is
  explicit rather than implied.
