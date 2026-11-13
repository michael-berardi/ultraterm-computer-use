import XCTest
@testable import UltraTermComputerUseKit

final class BackgroundAndStateIDTests: XCTestCase {
    // MARK: Background by default

    func testForegroundActivationIsOffUnlessTheSwitchIsSet() {
        XCTAssertFalse(foregroundActivationAllowed(environment: [:]))
        XCTAssertFalse(foregroundActivationAllowed(environment: [foregroundActivationEnvironmentKey: "0"]))
        XCTAssertFalse(foregroundActivationAllowed(environment: [foregroundActivationEnvironmentKey: "maybe"]))
        for value in ["1", "true", " YES ", "on"] {
            XCTAssertTrue(foregroundActivationAllowed(environment: [foregroundActivationEnvironmentKey: value]), value)
        }
    }

    func testSnapshotsNeverRecoverByActivatingUnlessAllowed() {
        XCTAssertEqual(effectiveSnapshotRecoveryPolicy(.allowActivation, environment: [:]), .readOnly)
        XCTAssertEqual(effectiveSnapshotRecoveryPolicy(.readOnly, environment: [foregroundActivationEnvironmentKey: "1"]), .readOnly)
        XCTAssertEqual(effectiveSnapshotRecoveryPolicy(.allowActivation, environment: [foregroundActivationEnvironmentKey: "1"]), .allowActivation)
    }

    func testBackgroundRefusalNamesItsCauseAndTheSwitch() {
        let message = noWindowFoundMessage(for: .readOnly)
        XCTAssertTrue(message.contains("hidden, minimized"), message)
        XCTAssertTrue(message.contains("Call get_app_state again"), message)
        XCTAssertTrue(message.contains("Nothing was changed"), message)
        XCTAssertTrue(message.contains("\(foregroundActivationEnvironmentKey)=1"), message)
        XCTAssertEqual(noWindowFoundMessage(for: .allowActivation), computerUseNoWindowFoundMessage)
    }

    func testRaiseIsRefusedUnlessForegroundIsAllowed() {
        XCTAssertTrue(secondaryActionTakesForeground("AXRaise"))
        XCTAssertTrue(secondaryActionTakesForeground("axraise"))
        for action in ["AXPress", "AXShowMenu", "AXScrollDownByPage", "AXCancel"] {
            XCTAssertFalse(secondaryActionTakesForeground(action), action)
            XCTAssertNoThrow(try requireForegroundAllowed(forSecondaryAction: action, environment: [:]))
        }
        XCTAssertThrowsError(try requireForegroundAllowed(forSecondaryAction: "AXRaise", environment: [:])) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("Nothing was sent"), message)
            XCTAssertTrue(message.contains("\(foregroundActivationEnvironmentKey)=1"), message)
        }
        XCTAssertNoThrow(try requireForegroundAllowed(forSecondaryAction: "AXRaise", environment: [foregroundActivationEnvironmentKey: "1"]))
    }

    func testDoctorOmitsLockedUseWhenItIsNeitherBundledNorInstalled() {
        // The test host bundles no Locked Use components; the report must not describe them
        // unless a system-wide install exists on this machine.
        let diagnostics = LockedUseDiagnostics.current()
        XCTAssertNil(diagnostics.bundledPluginVersion)
        if diagnostics.installedPluginVersion == nil, !diagnostics.enabled {
            XCTAssertNil(diagnostics.doctorSummary)
        } else {
            XCTAssertEqual(diagnostics.doctorSummary, diagnostics.summary)
        }
        XCTAssertTrue(diagnostics.summary.hasPrefix("Locked Use:"))
    }

    func testABackgroundReadIsRetriedBeforeItIsReportedAsNoWindow() {
        var calls = 0
        var slept: [TimeInterval] = []
        // Fails twice (a busy app timing out), then answers.
        let value: String? = retryingBackgroundRead(delays: [0.1, 0.25, 0.4], sleep: { slept.append($0) }) {
            calls += 1
            return calls < 3 ? nil : "window"
        }
        XCTAssertEqual(value, "window")
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(slept, [0.1, 0.25])

        // An app that really has no window is asked once per delay and no more.
        calls = 0; slept = []
        let none: String? = retryingBackgroundRead(delays: [0.1, 0.25, 0.4], sleep: { slept.append($0) }) { calls += 1; return nil }
        XCTAssertNil(none)
        XCTAssertEqual(calls, 4)
        XCTAssertLessThanOrEqual(slept.reduce(0, +), 0.8)

        // A first answer costs no wait.
        slept = []
        XCTAssertEqual(retryingBackgroundRead(sleep: { slept.append($0) }) { 1 }, 1)
        XCTAssertEqual(slept, [])
        XCTAssertTrue(computerUseBackgroundWindowUnavailableMessage.contains("did not answer in time"))
    }

    func testVisualCursorMoveIsShortAndBounded() {
        XCTAssertEqual(visualCursorMoveDuration(environment: [:]), 0.18, accuracy: 0.0001)
        XCTAssertLessThan(defaultVisualCursorMoveDuration, 0.25)
        XCTAssertEqual(visualCursorMoveDuration(environment: [visualCursorMoveDurationEnvironmentKey: "0"]), 0)
        XCTAssertEqual(visualCursorMoveDuration(environment: [visualCursorMoveDurationEnvironmentKey: "0.5"]), 0.5, accuracy: 0.0001)
        XCTAssertEqual(visualCursorMoveDuration(environment: [visualCursorMoveDurationEnvironmentKey: "60"]), maximumVisualCursorMoveDuration)
        XCTAssertEqual(visualCursorMoveDuration(environment: [visualCursorMoveDurationEnvironmentKey: "-3"]), 0)
        XCTAssertEqual(visualCursorMoveDuration(environment: [visualCursorMoveDurationEnvironmentKey: "nan"]), defaultVisualCursorMoveDuration)
        XCTAssertEqual(visualCursorMoveDuration(environment: [visualCursorMoveDurationEnvironmentKey: "soon"]), defaultVisualCursorMoveDuration)
    }

    func testIdleCursorKeepsItsSpeedAtAThirdOfTheWakeups() {
        XCTAssertGreaterThanOrEqual(visualCursorIdleUpdateInterval, 1.0 / 20.0)
        // Phase advanced per second matches the earlier 0.05 per tick at 60 Hz.
        XCTAssertEqual(Double(visualCursorIdlePhaseStep) / visualCursorIdleUpdateInterval, 0.05 * 60, accuracy: 0.0001)
        // The cursor is re-ordered above a raised target window within 0.1 s.
        XCTAssertLessThanOrEqual(Double(visualCursorIdleOrderingRefreshTicks) * visualCursorIdleUpdateInterval, 0.1001)
    }

    func testSequencesDoNotPauseASecondBetweenSteps() {
        XCTAssertLessThanOrEqual(ultraTermComputerUseDefaultInterCallDelay, 0.25)
    }

    // MARK: state_id

    func testStateIDsAreShortHexAndDoNotRepeat() {
        let ids = (0..<200).map { _ in makeSnapshotStateID() }
        XCTAssertEqual(Set(ids).count, ids.count)
        for id in ids {
            XCTAssertNotNil(id.range(of: "^[0-9a-f]{12}$", options: .regularExpression), id)
        }
    }

    func testStateIDIsDeclaredOnActionToolsOnly() {
        for tool in ToolDefinitions.all {
            let properties = tool.inputSchema["properties"] as? [String: Any] ?? [:]
            let declared = properties["state_id"] as? [String: Any]
            XCTAssertEqual(declared != nil, ComputerUseToolDispatcher.stateCheckedTools.contains(tool.name), tool.name)
            if let declared {
                XCTAssertEqual(declared["type"] as? String, "string")
                XCTAssertEqual(declared["description"] as? String, stateIDArgumentDescription)
            }
        }
        XCTAssertEqual(
            ComputerUseToolDispatcher.stateCheckedTools.subtracting(ToolDefinitions.all.map(\.name)), [],
            "every state-checked tool must exist"
        )
    }

    func testAStaleStateIDIsRefusedBeforeTheActionRuns() {
        let dispatcher = ComputerUseToolDispatcher(service: ComputerUseService())
        // No state was captured for this app, so any id is stale. The app does not exist: a
        // result other than stale_state would mean the action went on to resolve or launch it.
        for tool in ComputerUseToolDispatcher.stateCheckedTools.sorted() {
            let result = dispatcher.callToolAsResult(name: tool, arguments: [
                "app": "zz-no-such-app-\(UUID().uuidString)", "state_id": "000000000000",
                "element_index": "0", "text": "x", "key": "a", "value": "v", "action": "Raise", "direction": "down",
                "from_x": 1, "from_y": 1, "to_x": 2, "to_y": 2,
            ])
            XCTAssertTrue(result.isError, tool)
            XCTAssertTrue(result.primaryText?.hasPrefix("stale_state: ") == true, "\(tool): \(result.primaryText ?? "")")
            XCTAssertTrue(result.primaryText?.contains("get_app_state") == true, tool)
            XCTAssertNil(result.stateID, tool)
        }
    }

    func testANonStringStateIDIsRejected() {
        let dispatcher = ComputerUseToolDispatcher(service: ComputerUseService())
        let result = dispatcher.callToolAsResult(name: "click", arguments: ["app": "zz-no-such-app", "state_id": 7, "element_index": "0"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.primaryText?.contains("state_id must be a string") == true, result.primaryText ?? "")
    }

    func testStateIDIsNotCheckedOnReadOnlyTools() {
        let dispatcher = ComputerUseToolDispatcher(service: ComputerUseService())
        let result = dispatcher.callToolAsResult(name: "list_apps", arguments: ["state_id": "000000000000"])
        XCTAssertFalse(result.primaryText?.hasPrefix("stale_state") == true)
    }

    func testToolResultCarriesStateIDOnlyWhenItHasOne() {
        let with = ToolCallResult(content: [.text("state")], stateID: "0123456789ab")
        XCTAssertEqual(with.asDictionary["state_id"] as? String, "0123456789ab")
        XCTAssertNil(ToolCallResult.text("ok").asDictionary["state_id"])
        XCTAssertEqual(ComputerUseError.staleState("x").errorDescription, "stale_state: x")
    }

    func testDragNoteKeepsTheStateID() {
        let result = appendingDragDeliveryNote(
            to: ToolCallResult(content: [.text("state"), .text("State-ID: 0123456789ab")], stateID: "0123456789ab"),
            path: .appPost
        )
        XCTAssertEqual(result.stateID, "0123456789ab")
    }
}
