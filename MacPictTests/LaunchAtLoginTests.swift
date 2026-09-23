import Foundation
import ServiceManagement
import XCTest
@testable import MacPict

/// Records calls instead of changing the real login items of the user.
final class FakeLoginItemService: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var error: (any Error)?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    func register() throws {
        registerCount += 1
        if let error { throw error }
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if let error { throw error }
        status = .notRegistered
    }
}

@MainActor
final class LaunchAtLoginTests: XCTestCase {
    private static let suiteName = "com.macpict.tests.launchatlogin"
    private var defaults: UserDefaults!
    private var service: FakeLoginItemService!

    override func setUp() async throws {
        try await super.setUp()
        defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
        service = FakeLoginItemService()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: Self.suiteName)
        defaults = nil
        service = nil
        try await super.tearDown()
    }

    func testFirstLaunchTurnsLaunchAtLoginOn() {
        let launchAtLogin = LaunchAtLogin(service: service, defaults: defaults)

        launchAtLogin.enableOnFirstLaunch()

        XCTAssertEqual(service.registerCount, 1)
        XCTAssertTrue(launchAtLogin.isEnabled)
    }

    func testALaterLaunchDoesNotTurnItOnAgainAfterTheUserTurnedItOff() {
        LaunchAtLogin(service: service, defaults: defaults).enableOnFirstLaunch()
        let launchAtLogin = LaunchAtLogin(service: service, defaults: defaults)
        launchAtLogin.setEnabled(false)

        LaunchAtLogin(service: service, defaults: defaults).enableOnFirstLaunch()

        XCTAssertEqual(service.registerCount, 1)
        XCTAssertEqual(service.status, .notRegistered)
    }

    func testTheToggleRegistersAndUnregisters() {
        let launchAtLogin = LaunchAtLogin(service: service, defaults: defaults)

        launchAtLogin.setEnabled(true)
        XCTAssertTrue(launchAtLogin.isEnabled)

        launchAtLogin.setEnabled(false)
        XCTAssertFalse(launchAtLogin.isEnabled)
        XCTAssertEqual(service.unregisterCount, 1)
    }

    func testAFailureIsShownAndTheStatusStaysAsTheSystemReportsIt() {
        service.error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        let launchAtLogin = LaunchAtLogin(service: service, defaults: defaults)

        launchAtLogin.setEnabled(true)

        XCTAssertEqual(launchAtLogin.errorText, "Operation not permitted")
        XCTAssertFalse(launchAtLogin.isEnabled)
    }

    /// macOS still has the item registered, but the user must allow it in System Settings.
    func testRequiresApprovalCountsAsOn() {
        service.status = .requiresApproval

        XCTAssertTrue(LaunchAtLogin(service: service, defaults: defaults).isEnabled)
    }

    func testRefreshReadsAChangeMadeInSystemSettings() {
        service.status = .enabled
        let launchAtLogin = LaunchAtLogin(service: service, defaults: defaults)

        service.status = .notRegistered
        launchAtLogin.refresh()

        XCTAssertFalse(launchAtLogin.isEnabled)
    }
}
