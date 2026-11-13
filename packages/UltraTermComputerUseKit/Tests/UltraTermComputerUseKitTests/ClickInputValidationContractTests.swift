import XCTest
@testable import UltraTermComputerUseKit

/// Defense-in-depth input validation for click arguments on the direct
/// dispatcher and service paths. The target app never exists, so any skipped
/// validation would surface as app_not_found at the execute phase; observing
/// invalid_arguments (preflight at the dispatcher, a throw before the snapshot
/// at the service) proves rejection happens before any app lookup or UI
/// mutation. All paths are UI-free.
final class ClickInputValidationContractTests: XCTestCase {
    private let missingApp = "no-such-app-validation-contract"

    // MARK: direct dispatcher path (callToolAsResult)

    func testDispatcherRejectsBooleanArgumentsAsInvalidArguments() {
        let dispatcher = ComputerUseToolDispatcher()
        for arguments: [String: Any] in [
            ["app": missingApp, "x": true, "y": 2],
            ["app": missingApp, "x": 1, "y": false],
            ["app": missingApp, "x": NSNumber(value: true), "y": 2],
            ["app": missingApp, "element_index": NSNumber(value: true)],
        ] {
            let result = dispatcher.callToolAsResult(name: "click", arguments: arguments)

            XCTAssertTrue(result.isError, "\(arguments)")
            XCTAssertEqual(result.errorInfo?.code, "invalid_arguments", "\(arguments)")
            XCTAssertEqual(result.errorInfo?.phase, .preflight, "\(arguments)")
        }
    }

    func testDispatcherRejectsFractionalAndNonPositiveClickCount() {
        let dispatcher = ComputerUseToolDispatcher()
        for count in [1.9, 0, -2, 0.5, true, NSNumber(value: true)] as [Any] {
            let arguments: [String: Any] = ["app": missingApp, "element_index": "1", "click_count": count]
            let result = dispatcher.callToolAsResult(name: "click", arguments: arguments)

            XCTAssertTrue(result.isError, "click_count \(count)")
            XCTAssertEqual(result.errorInfo?.code, "invalid_arguments", "click_count \(count)")
            XCTAssertEqual(result.errorInfo?.phase, .preflight, "click_count \(count)")
        }
    }

    func testDispatcherRejectsUnknownMouseButton() {
        let dispatcher = ComputerUseToolDispatcher()
        let result = dispatcher.callToolAsResult(
            name: "click",
            arguments: ["app": missingApp, "element_index": "1", "mouse_button": "bogus"]
        )

        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.errorInfo?.code, "invalid_arguments")
        XCTAssertEqual(result.errorInfo?.phase, .preflight)
        XCTAssertEqual(
            result.primaryText,
            #"invalidArguments("mouse_button must be one of left, right, middle")"#
        )
    }

    /// Valid click arguments must keep flowing past validation to the service.
    /// A stale state_id fails with stale_state before any app lookup,
    /// proving the new guards do not over-reject while staying UI-free and
    /// instant (a nonexistent app would otherwise trigger a launch scan).
    func testDispatcherStillAdmitsValidClickArguments() {
        let dispatcher = ComputerUseToolDispatcher()
        for arguments: [String: Any] in [
            ["app": missingApp, "element_index": "1", "click_count": 2, "mouse_button": "right", "state_id": "1:2:stale"],
            ["app": missingApp, "x": 10, "y": 20, "click_count": 2.0, "mouse_button": "middle", "state_id": "1:2:stale"],
            ["app": missingApp, "element_index": "1", "state_id": "1:2:stale"],
        ] {
            let result = dispatcher.callToolAsResult(name: "click", arguments: arguments)

            XCTAssertTrue(result.isError, "\(arguments)")
            XCTAssertEqual(result.errorInfo?.code, "stale_state", "\(arguments)")
            XCTAssertEqual(result.errorInfo?.phase, .execute, "\(arguments)")
        }
    }

    // MARK: service boundary (direct ComputerUseService callers)

    /// An unknown button must throw invalidArguments instead of falling back
    /// to left, and must do so before snapshotForAction — otherwise the
    /// nonexistent app would raise appNotFound first.
    func testServiceRejectsUnknownMouseButtonBeforeSnapshot() {
        let service = ComputerUseService()
        XCTAssertThrowsError(
            try service.click(
                app: missingApp,
                elementIndex: "1",
                x: nil,
                y: nil,
                clickCount: 1,
                mouseButton: "bogus"
            )
        ) { error in
            guard case let ComputerUseError.invalidArguments(message) = error else {
                return XCTFail("expected invalidArguments, got \(error)")
            }
            XCTAssertEqual(message, "mouse_button must be one of left, right, middle")
        }
    }

    func testServiceRejectsNonPositiveClickCountBeforeSnapshot() {
        let service = ComputerUseService()
        for count in [0, -3] {
            XCTAssertThrowsError(
                try service.click(
                    app: missingApp,
                    elementIndex: "1",
                    x: nil,
                    y: nil,
                    clickCount: count,
                    mouseButton: "left"
                )
            ) { error in
                guard case let ComputerUseError.invalidArguments(message) = error else {
                    return XCTFail("expected invalidArguments for clickCount \(count), got \(error)")
                }
                XCTAssertEqual(message, "click_count must be a positive integer")
            }
        }
    }

    /// Button normalization at the service boundary: surrounding whitespace
    /// and case still resolve, so the guards tighten only genuinely unknown
    /// buttons. (0.8.0: the state_id check moved from the service call to the
    /// dispatcher, so this call carries no state_id.)
    func testServiceNormalizesMouseButtonBeforeLookup() {
        let service = ComputerUseService()
        XCTAssertThrowsError(
            try service.click(
                app: missingApp,
                elementIndex: "1",
                x: nil,
                y: nil,
                clickCount: 1,
                mouseButton: " Right "
            )
        ) { error in
            XCTAssertFalse(
                "\(error)".contains("mouse_button"),
                "the button normalizes before lookup, so the failure must come from the missing app, got \(error)"
            )
        }
    }

    /// 0.8.0 contract: a stale state_id is refused at the dispatcher before any
    /// app lookup, with the staleState error.
    func testDispatcherRefusesStaleStateIDBeforeAppLookup() {
        let dispatcher = ComputerUseToolDispatcher()
        XCTAssertThrowsError(
            try dispatcher.callTool(
                name: "click",
                arguments: ["app": missingApp, "element_index": "1", "state_id": "stale"]
            )
        ) { error in
            guard case ComputerUseError.staleState = error else {
                return XCTFail("expected staleState, got \(error)")
            }
        }
    }
}
