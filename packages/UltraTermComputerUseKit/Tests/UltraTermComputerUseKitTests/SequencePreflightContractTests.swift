import XCTest
@testable import UltraTermComputerUseKit

/// All-or-nothing sequence preflight: every call is schema-validated before
/// the first one executes, so an invalid later call produces zero mutations.
final class SequencePreflightContractTests: XCTestCase {
    private func spec(_ tool: String, _ arguments: [String: Any] = [:]) -> UltraTermComputerUseCallSpec {
        UltraTermComputerUseCallSpec(tool: tool, arguments: arguments)
    }

    // MARK: ToolSchemaValidator

    func testValidatorAcceptsAllKnownTools() {
        for tool in ToolDefinitions.all.map(\.name) {
            XCTAssertTrue(ToolSchemaValidator.isKnownTool(tool), "\(tool) should be known")
        }
        XCTAssertFalse(ToolSchemaValidator.isKnownTool("not_a_tool"))
    }

    func testValidatorAcceptsMinimalValidCalls() throws {
        XCTAssertNoThrow(try ToolSchemaValidator.validate(tool: "list_apps", arguments: [:]))
        XCTAssertNoThrow(try ToolSchemaValidator.validate(tool: "get_app_state", arguments: ["app": "TextEdit"]))
        XCTAssertNoThrow(try ToolSchemaValidator.validate(
            tool: "click",
            arguments: ["app": "TextEdit", "element_index": "3", "click_count": 2, "mouse_button": "left", "click_method": "auto"]
        ))
        XCTAssertNoThrow(try ToolSchemaValidator.validate(
            tool: "scroll",
            arguments: ["app": "TextEdit", "element_index": 1, "direction": "down", "pages": 1.5]
        ))
        XCTAssertNoThrow(try ToolSchemaValidator.validate(
            tool: "drag",
            arguments: ["app": "TextEdit", "from_x": 0, "from_y": 0, "to_x": 10.5, "to_y": 20]
        ))
    }

    func testValidatorAcceptsStateIDOnEveryActionTool() throws {
        let actions: [(String, [String: Any])] = [
            ("click", ["app": "A", "element_index": "1"]),
            ("perform_secondary_action", ["app": "A", "element_index": "1", "action": "Raise"]),
            ("scroll", ["app": "A", "element_index": "1", "direction": "up"]),
            ("drag", ["app": "A", "from_x": 0, "from_y": 0, "to_x": 1, "to_y": 1]),
            ("type_text", ["app": "A", "text": "hi"]),
            ("press_key", ["app": "A", "key": "return"]),
            ("set_value", ["app": "A", "element_index": "1", "value": "v"]),
        ]

        for (tool, base) in actions {
            var arguments = base
            arguments["state_id"] = "1:2:state"
            XCTAssertNoThrow(try ToolSchemaValidator.validate(tool: tool, arguments: arguments), "\(tool) must accept state_id")
        }
    }

    func testValidatorAcceptsIncludeScreenshotOnGetAppState() throws {
        XCTAssertNoThrow(try ToolSchemaValidator.validate(
            tool: "get_app_state",
            arguments: ["app": "TextEdit", "include_screenshot": false]
        ))
        XCTAssertThrowsError(try ToolSchemaValidator.validate(
            tool: "get_app_state",
            arguments: ["app": "TextEdit", "include_screenshot": "no"]
        )) { error in
            guard case ComputerUseError.invalidArguments = error else {
                return XCTFail("expected invalidArguments, got \(error)")
            }
        }
    }

    func testValidatorRejectsMissingRequiredArgument() {
        XCTAssertThrowsError(try ToolSchemaValidator.validate(tool: "click", arguments: ["x": 1, "y": 2])) { error in
            guard case let ComputerUseError.invalidArguments(message) = error else {
                return XCTFail("expected invalidArguments, got \(error)")
            }
            XCTAssertTrue(message.contains("'app'"), "message should name the missing key: \(message)")
        }
    }

    func testValidatorRejectsUnknownTool() {
        XCTAssertThrowsError(try ToolSchemaValidator.validate(tool: "delete_everything", arguments: [:])) { error in
            guard case let ComputerUseError.unsupportedTool(name) = error else {
                return XCTFail("expected unsupportedTool, got \(error)")
            }
            XCTAssertEqual(name, "delete_everything")
        }
    }

    func testValidatorRejectsBadEnumValue() {
        XCTAssertThrowsError(try ToolSchemaValidator.validate(
            tool: "click",
            arguments: ["app": "A", "click_method": "telepathy"]
        )) { error in
            guard case ComputerUseError.invalidArguments = error else {
                return XCTFail("expected invalidArguments, got \(error)")
            }
        }
    }

    func testValidatorRejectsWrongTypesAndNonPositiveIntegers() {
        // max_tree_nodes must be a positive integer.
        for bad: [String: Any] in [["app": "A", "max_tree_nodes": 0], ["app": "A", "max_tree_nodes": -3], ["app": "A", "max_tree_nodes": 1.5], ["app": "A", "max_tree_nodes": true]] {
            XCTAssertThrowsError(try ToolSchemaValidator.validate(tool: "get_app_state", arguments: bad)) { error in
                guard case ComputerUseError.invalidArguments = error else {
                    return XCTFail("expected invalidArguments for \(bad), got \(error)")
                }
            }
        }
        XCTAssertNoThrow(try ToolSchemaValidator.validate(tool: "get_app_state", arguments: ["app": "A", "max_tree_nodes": 500]))
    }

    func testValidatorToleratesElementIndexCoercionsLikeDispatcher() {
        XCTAssertNoThrow(try ToolSchemaValidator.validate(tool: "click", arguments: ["app": "A", "element_index": "7"]))
        XCTAssertNoThrow(try ToolSchemaValidator.validate(tool: "click", arguments: ["app": "A", "element_index": 7]))
        XCTAssertNoThrow(try ToolSchemaValidator.validate(tool: "click", arguments: ["app": "A", "element_index": 7.0]))
        XCTAssertThrowsError(try ToolSchemaValidator.validate(tool: "click", arguments: ["app": "A", "element_index": 7.5]))
        XCTAssertThrowsError(try ToolSchemaValidator.validate(tool: "click", arguments: ["app": "A", "element_index": true]))
    }

    func testValidatorSkipsNSNullPlaceholders() throws {
        XCTAssertNoThrow(try ToolSchemaValidator.validate(
            tool: "click",
            arguments: ["app": "A", "state_id": NSNull()]
        ))
    }

    func testValidatorRejectsBooleanNumericArguments() {
        // NSNumber(value:) mirrors what JSONSerialization hands the MCP path;
        // it bridge-casts to Int/Double, so every layer must check CFBoolean
        // before any numeric coercion.
        for bad: [String: Any] in [
            ["app": "A", "x": true, "y": 2],
            ["app": "A", "x": 1, "y": false],
            ["app": "A", "x": NSNumber(value: true), "y": 2],
            ["app": "A", "click_count": true],
            ["app": "A", "click_count": NSNumber(value: true)],
            ["app": "A", "element_index": NSNumber(value: true)],
        ] {
            XCTAssertThrowsError(try ToolSchemaValidator.validate(tool: "click", arguments: bad)) { error in
                guard case ComputerUseError.invalidArguments = error else {
                    return XCTFail("expected invalidArguments for \(bad), got \(error)")
                }
            }
        }
    }

    func testValidatorRejectsFractionalAndNonPositiveClickCount() {
        for badCount in [1.9, 0, -2, 0.5] as [Any] {
            XCTAssertThrowsError(try ToolSchemaValidator.validate(
                tool: "click",
                arguments: ["app": "A", "click_count": badCount]
            )) { error in
                guard case ComputerUseError.invalidArguments = error else {
                    return XCTFail("expected invalidArguments for click_count \(badCount), got \(error)")
                }
            }
        }

        XCTAssertNoThrow(try ToolSchemaValidator.validate(tool: "click", arguments: ["app": "A", "click_count": 1]))
        XCTAssertNoThrow(try ToolSchemaValidator.validate(tool: "click", arguments: ["app": "A", "click_count": 2.0]))
    }

    func testValidatorRejectsUnknownMouseButton() {
        XCTAssertThrowsError(try ToolSchemaValidator.validate(
            tool: "click",
            arguments: ["app": "A", "mouse_button": "bogus"]
        )) { error in
            guard case ComputerUseError.invalidArguments = error else {
                return XCTFail("expected invalidArguments, got \(error)")
            }
        }
    }

    // MARK: preflightUltraTermComputerUseCalls

    func testPreflightPassesForFullyValidSequence() {
        let calls = [
            spec("get_app_state", ["app": "TextEdit"]),
            spec("click", ["app": "TextEdit", "element_index": "1", "state_id": "1:2:x"]),
            spec("type_text", ["app": "TextEdit", "text": "hello"]),
        ]

        XCTAssertNil(preflightUltraTermComputerUseCalls(calls))
    }

    func testPreflightReportsFirstInvalidCallWithZeroBasedIndex() {
        let calls = [
            spec("get_app_state", ["app": "TextEdit"]),
            spec("click", ["app": "TextEdit", "click_method": "telepathy"]),
            spec("not_a_tool"),
        ]

        let info = preflightUltraTermComputerUseCalls(calls)
        XCTAssertEqual(info?.code, "invalid_arguments")
        XCTAssertEqual(info?.phase, .preflight)
        XCTAssertEqual(info?.callIndex, 1)
        XCTAssertEqual(info?.retryable, false)
    }

    /// 0.8.0 behaviour: an unknown tool is not refused up front; the sequence runs
    /// until it reaches it and then stops with the unsupported_tool execute error.
    func testPreflightLeavesUnknownToolsToExecution() {
        XCTAssertNil(preflightUltraTermComputerUseCalls([spec("list_apps"), spec("obliterate")]))
    }

    func testPreflightEmptySequenceIsValid() {
        XCTAssertNil(preflightUltraTermComputerUseCalls([]))
    }

    // MARK: runUltraTermComputerUseCall all-or-nothing

    func testSequenceWithInvalidSecondCallExecutesNothing() throws {
        var slept: [TimeInterval] = []
        let output = try runUltraTermComputerUseCall(
            .sequence(
                callsJSON: """
                [
                  {"tool": "list_apps", "args": {}},
                  {"tool": "click", "args": {"app": "TextEdit", "click_method": "telepathy"}}
                ]
                """,
                callsFile: nil,
                interCallDelay: 5
            ),
            sleepHandler: { slept.append($0) }
        )

        XCTAssertTrue(output.hasToolError)
        XCTAssertEqual(output.errorInfo?.phase, .preflight)
        XCTAssertEqual(output.errorInfo?.callIndex, 1)

        let object = try XCTUnwrap(output.jsonObject as? [String: Any])
        XCTAssertEqual(object["calls_executed"] as? Int, 0)
        XCTAssertNotNil(object["error"])
        XCTAssertTrue(slept.isEmpty, "no inter-call sleep may happen when nothing executed")
    }

    func testSingleCallIsPreflightedBeforeExecution() throws {
        let output = try runUltraTermComputerUseCall(
            .single(toolName: "get_app_state", argumentsJSON: "{\"app\": 42}", argumentsFile: nil)
        )

        XCTAssertTrue(output.hasToolError)
        XCTAssertEqual(output.errorInfo?.phase, .preflight)
        XCTAssertEqual(output.errorInfo?.callIndex, 0)
        XCTAssertEqual(output.errorInfo?.code, "invalid_arguments")

        let object = try XCTUnwrap(output.jsonObject as? [String: Any])
        XCTAssertEqual(object["calls_executed"] as? Int, 0)
    }

    func testSequenceToolErrorCarriesExecutePhaseAndCallIndex() throws {
        // Valid sequence whose first action fails at execute time: the
        // supplied state_id matches nothing cached, so the action fails with
        // state_unavailable before any app lookup or mutation. The failure
        // must be tagged phase=execute with the 0-based call index, and the
        // sequence stops.
        let output = try runUltraTermComputerUseCall(
            .sequence(
                callsJSON: """
                [
                  {"tool": "type_text", "args": {"app": "no-such-app-contract-xyz", "text": "hi", "state_id": "1:2:stale"}},
                  {"tool": "list_apps", "args": {}}
                ]
                """,
                callsFile: nil,
                interCallDelay: 0
            )
        )

        XCTAssertTrue(output.hasToolError)
        XCTAssertEqual(output.errorInfo?.phase, .execute)
        XCTAssertEqual(output.errorInfo?.callIndex, 0)
        XCTAssertEqual(output.errorInfo?.code, "stale_state")

        let outputs = try XCTUnwrap(output.jsonObject as? [[String: Any]])
        XCTAssertEqual(outputs.count, 1, "the sequence must stop after the first tool error")
        XCTAssertEqual(outputs[0]["tool"] as? String, "type_text")
    }

    func testValidSequenceStillRunsEndToEnd() throws {
        var slept: [TimeInterval] = []
        let output = try runUltraTermComputerUseCall(
            .sequence(
                callsJSON: """
                [
                  {"tool": "list_apps", "args": {}},
                  {"tool": "list_apps", "args": {}}
                ]
                """,
                callsFile: nil,
                interCallDelay: 0.25
            ),
            sleepHandler: { slept.append($0) }
        )

        XCTAssertFalse(output.hasToolError)
        XCTAssertNil(output.errorInfo)
        let outputs = try XCTUnwrap(output.jsonObject as? [[String: Any]])
        XCTAssertEqual(outputs.count, 2)
        XCTAssertEqual(slept, [0.25])
    }
}
