import XCTest
@testable import UltraTermComputerUseKit

/// Stdio MCP server contract: JSON-RPC framing semantics over single lines,
/// tool schema exposure (state_id / include_screenshot), and structured tool
/// errors. All inputs are hand-written JSON lines; nothing reaches apps.
final class MCPServerContractTests: XCTestCase {
    private let server = StdioMCPServer()

    private func handle(_ payload: [String: Any]) throws -> [String: Any] {
        let line = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let response = try XCTUnwrap(server.handle(line: line))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    }

    func testToolsListExposesStateIDAndIncludeScreenshotSchema() throws {
        let response = try handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])

        let click = try XCTUnwrap(tools.first { $0["name"] as? String == "click" })
        let clickProperties = try XCTUnwrap(
            (click["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
        )
        XCTAssertNotNil(clickProperties["state_id"], "click must advertise the state_id argument")

        let getAppState = try XCTUnwrap(tools.first { $0["name"] as? String == "get_app_state" })
        let stateProperties = try XCTUnwrap(
            (getAppState["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
        )
        XCTAssertNotNil(stateProperties["include_screenshot"], "get_app_state must advertise include_screenshot")
        XCTAssertNotNil(stateProperties["max_tree_nodes"])
        XCTAssertNotNil(stateProperties["max_tree_depth"])
    }

    func testUnknownToolReturnsStructuredToolError() throws {
        let response = try handle([
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": ["name": "not_a_tool", "arguments": [:]],
        ])

        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "unsupportedTool(\"not_a_tool\")")
        let error = try XCTUnwrap(result["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "unsupported_tool")
        XCTAssertEqual(error["phase"] as? String, "preflight")
    }

    func testMissingRequiredArgumentReturnsStructuredInvalidArguments() throws {
        let response = try handle([
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": ["name": "click", "arguments": ["x": 1, "y": 2]],
        ])

        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(
            content.first?["text"] as? String,
            "Missing required argument: app"  // 0.8.0 official text; the schema preflight is CLI-only
        )
        let error = try XCTUnwrap(result["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalid_arguments")
        XCTAssertEqual(error["phase"] as? String, "preflight")
        XCTAssertEqual(error["retryable"] as? Bool, false)
    }

    /// Every schema-invalid click must fail as structured invalid_arguments at
    /// the preflight phase. The targeted app does not exist: if validation were
    /// skipped, the failure would surface as app_not_found at the execute phase
    /// instead, so the code/phase pair proves no app lookup or UI mutation ran.
    func testInvalidClickArgumentsReturnStructuredInvalidArgumentsBeforeMutation() throws {
        let cases: [[String: Any]] = [
            // CFBoolean smuggled in as a number.
            ["app": "no-such-app-mcp-contract", "x": true, "y": 2],
            ["app": "no-such-app-mcp-contract", "x": 1, "y": false],
            // Fractional click_count (previously truncated to 1).
            ["app": "no-such-app-mcp-contract", "element_index": "1", "click_count": 1.9],
            // Zero / negative click_count.
            ["app": "no-such-app-mcp-contract", "element_index": "1", "click_count": 0],
            ["app": "no-such-app-mcp-contract", "element_index": "1", "click_count": -2],
            // Boolean click_count.
            ["app": "no-such-app-mcp-contract", "element_index": "1", "click_count": true],
            // Unknown mouse_button (previously fell back to left).
            ["app": "no-such-app-mcp-contract", "element_index": "1", "mouse_button": "bogus"],
        ]

        for (index, arguments) in cases.enumerated() {
            let response = try handle([
                "jsonrpc": "2.0",
                "id": 100 + index,
                "method": "tools/call",
                "params": ["name": "click", "arguments": arguments],
            ])

            let result = try XCTUnwrap(response["result"] as? [String: Any], "case \(index)")
            XCTAssertEqual(result["isError"] as? Bool, true, "case \(index)")
            let error = try XCTUnwrap(result["error"] as? [String: Any], "case \(index)")
            XCTAssertEqual(error["code"] as? String, "invalid_arguments", "case \(index)")
            XCTAssertEqual(error["phase"] as? String, "preflight", "case \(index)")
            XCTAssertEqual(error["retryable"] as? Bool, false, "case \(index)")
            let content = try XCTUnwrap(result["content"] as? [[String: Any]], "case \(index)")
            let text = try XCTUnwrap(content.first?["text"] as? String, "case \(index)")
            XCTAssertTrue(text.hasPrefix(#"invalidArguments("#), "case \(index): \(text)")
        }
    }

    func testMalformedJSONLineYieldsParseError() throws {
        let response = try XCTUnwrap(server.handle(line: "{not json"))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let error = try XCTUnwrap(parsed["error"] as? [String: Any])

        XCTAssertEqual(error["code"] as? Int, -32700)
        XCTAssertTrue(parsed["id"] is NSNull)
    }

    func testUnknownMethodYieldsMethodNotFound() throws {
        let response = try handle(["jsonrpc": "2.0", "id": 4, "method": "resources/list"])
        let error = try XCTUnwrap(response["error"] as? [String: Any])

        XCTAssertEqual(error["code"] as? Int, -32601)
    }

    func testPingReturnsEmptyResult() throws {
        let response = try handle(["jsonrpc": "2.0", "id": 5, "method": "ping"])

        XCTAssertNotNil(response["result"])
        XCTAssertNil(response["error"])
    }

    func testNotificationWithoutIDGetsNoResponse() {
        XCTAssertNil(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
    }

    func testEveryResponseIsASingleLine() throws {
        // Newline-delimited framing: one response per line, never embedded \n.
        let response = try XCTUnwrap(server.handle(line: #"{"jsonrpc":"2.0","id":9,"method":"ping"}"#))

        XCTAssertFalse(response.contains("\n"))
        XCTAssertFalse(response.hasSuffix("\n"))
    }
}
