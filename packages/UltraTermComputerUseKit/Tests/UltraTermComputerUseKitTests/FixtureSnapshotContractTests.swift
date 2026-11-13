import XCTest
@testable import UltraTermComputerUseKit

/// Headless fixture-mode snapshots: the fixture bridge is file-driven, so a
/// fabricated fixture descriptor exercises the snapshot pipeline (state_id,
/// element records, no screenshot) without any app, permission, or display.
/// The shared fixture state file is always removed after each test.
final class FixtureSnapshotContractTests: XCTestCase {
    private func withFixtureState<T>(
        _ state: FixtureAppState,
        _ body: () throws -> T
    ) throws -> T {
        try FixtureBridge.writeState(state)
        defer {
            try? FileManager.default.removeItem(at: FixtureBridge.stateFileURL)
        }
        return try body()
    }

    private func fixtureDescriptor(pid: pid_t = 9_001) -> RunningAppDescriptor {
        RunningAppDescriptor(
            name: FixtureBridge.appName,
            bundleIdentifier: "dev.opencodex.opencomputeruse.fixture",
            pid: pid,
            runningApplication: NSRunningApplication.current
        )
    }

    private func makeState() -> FixtureAppState {
        FixtureAppState(
            processIdentifier: 9_001,
            windowTitle: "Fixture Window",
            windowBounds: FixtureRect(rect: CGRect(x: 0, y: 0, width: 400, height: 300)),
            focusedIdentifier: "ok-button",
            elements: [
                FixtureElementState(
                    identifier: "ok-button",
                    index: 1,
                    role: "AXButton",
                    title: "OK",
                    value: nil,
                    actions: ["AXPress"],
                    frame: FixtureRect(rect: CGRect(x: 10, y: 10, width: 80, height: 24))
                ),
            ]
        )
    }

    func testFixtureSnapshotBuildsWithoutPermissionsAppsOrDisplays() throws {
        try withFixtureState(makeState()) {
            let snapshot = try SnapshotBuilder.build(for: fixtureDescriptor())

            XCTAssertTrue(snapshot.mode == .fixture)
            XCTAssertNil(snapshot.screenshotPNGData)
            XCTAssertEqual(snapshot.windowTitle, "Fixture Window")
            XCTAssertEqual(snapshot.elements[1]?.identifier, "ok-button")
        }
    }

    func testFixtureSnapshotCarriesNoStateIDUntilTheServiceAssignsOne() throws {
        // 0.8.0 contract: the builder never mints a state_id; the service assigns one
        // per captured state (short hex, fresh each time).
        try withFixtureState(makeState()) {
            let snapshot = try SnapshotBuilder.build(for: fixtureDescriptor())
            XCTAssertTrue(snapshot.stateID.isEmpty)

            var first = snapshot
            var second = snapshot
            first.stateID = makeSnapshotStateID()
            second.stateID = makeSnapshotStateID()
            XCTAssertNotEqual(first.stateID, second.stateID, "each captured state gets a fresh state_id")
        }
    }

    func testFixtureSnapshotResultOmitsScreenshotButCarriesStateID() throws {
        try withFixtureState(makeState()) {
            // The service-level result shape: text only, state_id at the top
            // level, never an image item when no screenshot was captured.
            var snapshot = try SnapshotBuilder.build(for: fixtureDescriptor())
            snapshot.stateID = makeSnapshotStateID()
            let service = ComputerUseService()
            let result = service.snapshotResult(for: snapshot, style: .fullState)

            // 0.8.0 shape: the rendered text, then a `State-ID: <id>` text item; no image.
            XCTAssertEqual(result.content.count, 2)
            XCTAssertEqual(result.content[0].dictionary["type"] as? String, "text")
            XCTAssertEqual(result.content[1].dictionary["type"] as? String, "text")
            XCTAssertEqual(result.content[1].dictionary["text"] as? String, "State-ID: \(snapshot.stateID)")
            XCTAssertEqual(result.stateID, snapshot.stateID)
            XCTAssertEqual(result.asDictionary["state_id"] as? String, snapshot.stateID)
        }
    }
}
