import XCTest
@testable import UltraTermComputerUseKit

/// The agent-facing `call` surface: direct tool commands, schema-driven flags, per-tool help,
/// compact output, stable exit codes, and state shared between one-shot calls. No desktop,
/// app, permission or pointer is touched.
final class CLICallAgentContractTests: XCTestCase {
    private func parsedSingle(_ arguments: [String]) throws -> (tool: String, arguments: [String: Any], options: UltraTermComputerUseCallOptions) {
        guard case let .call(.single(tool, json, file, options)) = try parseUltraTermComputerUseCLI(
            arguments: normalizedUltraTermComputerUseArguments(arguments)
        ) else {
            XCTFail("not a single call: \(arguments)")
            return ("", [:], .init())
        }
        XCTAssertNil(file)
        return (tool, try readUltraTermComputerUseToolArguments(json: json, file: nil), options)
    }

    // MARK: direct tool commands and flags

    func testToolNameWorksWithoutCall() {
        XCTAssertEqual(normalizedUltraTermComputerUseArguments(["click", "--app", "X"]), ["call", "click", "--app", "X"])
        XCTAssertEqual(normalizedUltraTermComputerUseArguments(["call", "click"]), ["call", "click"])
        XCTAssertEqual(normalizedUltraTermComputerUseArguments(["doctor"]), ["doctor"])
        XCTAssertEqual(normalizedUltraTermComputerUseArguments(["--version"]), ["--version"])
        XCTAssertEqual(normalizedUltraTermComputerUseArguments([]), [])
        // `list-apps` is the command; `list_apps` is the tool.
        XCTAssertEqual(normalizedUltraTermComputerUseArguments(["list-apps"]), ["list-apps"])
        XCTAssertEqual(normalizedUltraTermComputerUseArguments(["list_apps"]), ["call", "list_apps"])
    }

    func testFlagsBecomeTypedArguments() throws {
        let parsed = try parsedSingle([
            "click", "--app", "TextEdit", "--element-index", "3", "--state-id", "abc123",
            "--click_count", "2", "--mouse-button", "right", "--x=10.5",
        ])
        XCTAssertEqual(parsed.tool, "click")
        XCTAssertEqual(parsed.arguments["app"] as? String, "TextEdit")
        XCTAssertEqual(parsed.arguments["element_index"] as? String, "3")
        XCTAssertEqual(parsed.arguments["state_id"] as? String, "abc123")
        XCTAssertEqual(parsed.arguments["click_count"] as? Int, 2)
        XCTAssertEqual(parsed.arguments["mouse_button"] as? String, "right")
        XCTAssertEqual(parsed.arguments["x"] as? Double, 10.5)
        XCTAssertEqual(parsed.options, UltraTermComputerUseCallOptions())
    }

    func testBooleanAndTextLimitFlags() throws {
        let parsed = try parsedSingle([
            "get_app_state", "--app", "A", "--include-screenshot", "false", "--include-ax", "--text-limit", "max", "--max-tree-nodes", "50",
        ])
        XCTAssertEqual(parsed.arguments["include_screenshot"] as? Bool, false)
        XCTAssertEqual(parsed.arguments["include_ax"] as? Bool, true)
        XCTAssertEqual(parsed.arguments["text_limit"] as? String, "max")
        XCTAssertEqual(parsed.arguments["max_tree_nodes"] as? Int, 50)
        let numeric = try parsedSingle(["get_app_state", "--app", "A", "--text-limit", "1000"])
        XCTAssertEqual(numeric.arguments["text_limit"] as? Int, 1000)
    }

    func testFlagsMergeOverArgsAndKeepExistingInvocationsWorking() throws {
        let merged = try parsedSingle(["call", "get_app_state", "--args", #"{"app":"A","text_limit":10}"#, "--text-limit", "20"])
        XCTAssertEqual(merged.arguments["app"] as? String, "A")
        XCTAssertEqual(merged.arguments["text_limit"] as? Int, 20)
        XCTAssertEqual(
            try parseUltraTermComputerUseCLI(arguments: ["call", "get_app_state", "--args", #"{"app":"TextEdit"}"#]),
            .call(.single(toolName: "get_app_state", argumentsJSON: #"{"app":"TextEdit"}"#, argumentsFile: nil))
        )
        XCTAssertEqual(
            try parseUltraTermComputerUseCLI(arguments: ["call", "list_apps"]),
            .call(.single(toolName: "list_apps", argumentsJSON: nil, argumentsFile: nil))
        )
    }

    func testOutputOptionsParseOnSingleAndSequence() throws {
        let single = try parsedSingle(["list_apps", "--json", "--media-dir", "/tmp/shots"])
        XCTAssertEqual(single.options, UltraTermComputerUseCallOptions(json: true, mediaDir: "/tmp/shots"))
        XCTAssertEqual(
            try parseUltraTermComputerUseCLI(arguments: ["call", "--calls", "[]", "--json"]),
            .call(.sequence(callsJSON: "[]", callsFile: nil, interCallDelay: ultraTermComputerUseDefaultInterCallDelay,
                            options: UltraTermComputerUseCallOptions(json: true)))
        )
        XCTAssertEqual(
            resolvingUltraTermComputerUseCallFilePaths(["call", "list_apps", "--media-dir", "shots"], currentDirectory: "/work"),
            ["call", "list_apps", "--media-dir", "/work/shots"]
        )
    }

    func testBadFlagsAreUsageErrorsThatNameTheOptions() {
        XCTAssertThrowsError(try parseUltraTermComputerUseCLI(arguments: ["call", "click", "--bogus", "1"])) { error in
            let cli = error as? UltraTermComputerUseCLIError
            XCTAssertTrue(cli?.message.contains("--element-index") == true, cli?.message ?? "")
            XCTAssertEqual(cli?.helpCommand, "click")
            XCTAssertEqual(ultraTermComputerUseExitStatus(for: error), .usage)
        }
        XCTAssertThrowsError(try parseUltraTermComputerUseCLI(arguments: ["call", "click", "--click-count", "two"]))
        XCTAssertThrowsError(try parseUltraTermComputerUseCLI(arguments: ["call", "click", "--mouse-button", "back"]))
        XCTAssertThrowsError(try parseUltraTermComputerUseCLI(arguments: ["call", "click", "--app"]))
        XCTAssertThrowsError(try parseUltraTermComputerUseCLI(arguments: ["call", "click", "--app", "A", "--args-file", "a.json"]))
        // Flags that need a tool: without one the old error stays.
        XCTAssertThrowsError(try parseUltraTermComputerUseCLI(arguments: ["call", "--app", "A"]))
    }

    func testUsageErrorsStayShort() {
        let text = UltraTermComputerUseCLIError(message: "bad", helpCommand: "call").errorDescription ?? ""
        XCTAssertEqual(text, "bad\nRun `ultraterm-computer-use help call` for usage.")
    }

    // MARK: per-tool help from the schema

    func testEveryToolHasHelpGeneratedFromItsSchema() throws {
        for definition in ToolDefinitions.all {
            XCTAssertEqual(try parseUltraTermComputerUseCLI(arguments: ["call", definition.name, "--help"]), .help(command: definition.name))
            XCTAssertEqual(try parseUltraTermComputerUseCLI(arguments: ["help", definition.name]), .help(command: definition.name))
            let help = ultraTermComputerUseHelpText(command: definition.name)
            XCTAssertTrue(help.hasPrefix("Usage:"), definition.name)
            let properties = definition.inputSchema["properties"] as? [String: Any] ?? [:]
            for key in properties.keys {
                XCTAssertTrue(help.contains("--" + key.replacingOccurrences(of: "_", with: "-")), "\(definition.name) help lacks \(key)")
            }
            for required in definition.inputSchema["required"] as? [String] ?? [] {
                XCTAssertTrue(help.contains("--\(required.replacingOccurrences(of: "_", with: "-")) <\(required)>"), "\(definition.name): \(required)")
            }
            // Every schema property can be passed as a flag (no tool needs raw JSON).
            for key in properties.keys {
                XCTAssertNotNil(toolFlagSpec(forTool: definition.name, option: "--" + key), "\(definition.name) \(key)")
            }
        }
        XCTAssertTrue(ultraTermComputerUseHelpText(command: "click").contains("exit 7"))
        XCTAssertNil(ultraTermComputerUseToolHelpText("no_such_tool"))
        XCTAssertTrue(ultraTermComputerUseHelpText(command: "no_such_tool").contains("Unknown help topic"))
    }

    func testToolsTextIsCompactListOrFullHelp() throws {
        let list = try ultraTermComputerUseToolsText(name: nil)
        XCTAssertEqual(list.split(separator: "\n").count, ToolDefinitions.all.count)
        XCTAssertFalse(list.contains("This tool is part of plugin"))
        XCTAssertTrue(try ultraTermComputerUseToolsText(name: "click").contains("--element-index"))
        XCTAssertThrowsError(try ultraTermComputerUseToolsText(name: "nope"))
    }

    // MARK: tool inventory parity (MCP server vs CLI)

    func testEveryMCPToolIsReachableThroughTheCLI() throws {
        let server = StdioMCPServer(backgroundStateReset: {})
        let listed = try XCTUnwrap(server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(listed.utf8)) as? [String: Any])
        let tools = try XCTUnwrap((object["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertFalse(tools.isEmpty)
        for tool in tools {
            let name = try XCTUnwrap(tool["name"] as? String)
            XCTAssertTrue(ToolSchemaValidator.isKnownTool(name), name)
            guard case .call(.single(let parsedTool, _, _, _)) = try parseUltraTermComputerUseCLI(
                arguments: normalizedUltraTermComputerUseArguments([name])
            ) else { return XCTFail("\(name) does not parse as a call") }
            XCTAssertEqual(parsedTool, name)
            XCTAssertNotNil(ultraTermComputerUseToolHelpText(name))
        }
    }

    // MARK: compact output and exit codes

    private func textResult(_ text: String, stateID: String? = nil) -> ToolCallResult {
        ToolCallResult(content: [.text(text)], stateID: stateID)
    }

    private func errorResult(code: String, message: String, retryable: Bool = false, hint: String? = nil, candidates: [String] = [], phase: ComputerUseErrorPhase = .execute, callIndex: Int? = nil) -> ToolCallResult {
        let info = ComputerUseErrorInfo(code: code, phase: phase, callIndex: callIndex, retryable: retryable, hint: hint, candidates: candidates, message: message)
        return .text(message, errorInfo: info)
    }

    private func single(_ result: ToolCallResult, tool: String = "get_app_state") -> UltraTermComputerUseCallOutput {
        UltraTermComputerUseCallOutput(
            jsonObject: result.asDictionary, hasToolError: result.isError, errorInfo: result.errorInfo,
            steps: [UltraTermComputerUseCallStep(tool: tool, result: result)]
        )
    }

    func testCompactSuccessPrintsOnlyTheText() throws {
        let response = try ultraTermComputerUseCallResponse(
            for: single(textResult("App=Notes\nState-ID: 3f9a", stateID: "3f9a")), options: .init()
        )
        XCTAssertEqual(response, UltraTermComputerUseCallResponse(stdout: "App=Notes\nState-ID: 3f9a\n", stderr: "", exitCode: 0))
        // A state_id that is not in the text is still shown.
        let appended = try ultraTermComputerUseCallResponse(for: single(textResult("ok", stateID: "9999")), options: .init())
        XCTAssertEqual(appended.stdout, "ok\nState-ID: 9999\n")
    }

    func testCompactOutputNeverPrintsBase64AndReferencesSavedImages() throws {
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4])
        let withImage = ToolCallResult(content: [.text("state"), .pngImage(png)])
        let inline = try ultraTermComputerUseCallResponse(for: single(withImage), options: .init())
        XCTAssertTrue(inline.stdout.contains("screenshot omitted"))
        XCTAssertTrue(inline.stdout.contains("--media-dir"))
        XCTAssertFalse(inline.stdout.contains(png.base64EncodedString()))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cu-cli-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let saved = try externalizeToolResultImages(withImage, mediaDir: directory, stem: "Notes-get_app_state-1")
        let response = try ultraTermComputerUseCallResponse(for: single(saved), options: .init(mediaDir: directory))
        XCTAssertEqual(response.stdout, "state\nimage: \(directory)/Notes-get_app_state-1-1.png\n")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: directory + "/Notes-get_app_state-1-1.png")), png)

        // --json keeps the envelope, base64 included, exactly as before.
        let json = try ultraTermComputerUseCallResponse(for: single(withImage), options: .init(json: true))
        XCTAssertEqual(json.stdout, try single(withImage).jsonText() + "\n")
        XCTAssertTrue(json.stdout.contains(png.base64EncodedString()))
    }

    func testFailuresGoToStderrWithStableExitCodes() throws {
        let cases: [(String, Int32)] = [
            ("usage", 2), ("unsupported_tool", 2), ("invalid_arguments", 2), ("permission_denied", 3),
            ("app_not_found", 4), ("ambiguous_app", 5), ("state_unavailable", 6), ("stale_state", 7), ("error", 1),
        ]
        for (code, exit) in cases {
            let response = try ultraTermComputerUseCallResponse(
                for: single(errorResult(code: code, message: "boom", retryable: true, hint: "try again", candidates: ["A", "B"])),
                options: .init()
            )
            XCTAssertEqual(response.exitCode, exit, code)
            XCTAssertEqual(response.stdout, "", code)
            XCTAssertEqual(response.stderr, "error[\(code)] (execute, retryable): boom\nhint: try again\ncandidates: A, B\n", code)
            let json = try ultraTermComputerUseCallResponse(for: single(errorResult(code: code, message: "boom")), options: .init(json: true))
            XCTAssertEqual(json.exitCode, exit, code)
            XCTAssertTrue(json.stdout.contains("\"code\" : \"\(code)\""), code)
        }
    }

    func testSequenceAndPreflightRendering() throws {
        let ok = textResult("one")
        let bad = errorResult(code: "stale_state", message: "old", retryable: true, callIndex: 1)
        let sequence = UltraTermComputerUseCallOutput(
            jsonObject: [], hasToolError: true, errorInfo: bad.errorInfo,
            steps: [UltraTermComputerUseCallStep(tool: "get_app_state", result: ok), UltraTermComputerUseCallStep(tool: "click", result: bad)],
            isSequence: true
        )
        let response = try ultraTermComputerUseCallResponse(for: sequence, options: .init())
        XCTAssertEqual(response.stdout, "== 1. get_app_state ==\none\n== 2. click ==\n")
        XCTAssertEqual(response.stderr, "error[stale_state] (execute, call 2, retryable): old\nSequence stopped at the first error.\n")
        XCTAssertEqual(response.exitCode, 7)

        let info = ComputerUseErrorInfo(code: "invalid_arguments", phase: .preflight, callIndex: 2, retryable: false, message: "bad arg")
        let refused = UltraTermComputerUseCallOutput(jsonObject: [:], hasToolError: true, errorInfo: info, preflightError: info)
        let refusal = try ultraTermComputerUseCallResponse(for: refused, options: .init())
        XCTAssertEqual(refusal.stderr, "error[invalid_arguments] (preflight, call 3): bad arg\nNo call was run.\n")
        XCTAssertEqual(refusal.exitCode, 2)
    }

    func testRealPreflightFailureRendersWithoutADesktop() throws {
        let response = try runUltraTermComputerUseCallCommand(
            .single(toolName: "click", argumentsJSON: #"{"app": 42}"#, argumentsFile: nil)
        )
        XCTAssertEqual(response.exitCode, 2)
        XCTAssertEqual(response.stdout, "")
        XCTAssertTrue(response.stderr.contains("error[invalid_arguments] (preflight, call 1)"), response.stderr)
        XCTAssertTrue(response.stderr.contains("No call was run."))
    }

    // MARK: state_id across separate one-shot calls

    /// Each one-shot `call` used to build its own `ComputerUseService`, so a state_id from one
    /// call was always `stale_state` in the next. The app agent now keeps one service, and
    /// two separate `runUltraTermComputerUseCall` invocations on it share the captured state.
    func testStateIDSurvivesSeparateCallsOnTheSharedService() throws {
        let shared = UltraTermComputerUseSharedCallService()
        var snapshot = makeContractSnapshot(stateID: "feedc0de")
        snapshot.observation = SnapshotObservationOptions(includeAX: true, includeScreenshot: false)

        // Call 1 (stands in for `call get_app_state`): the app's state is captured.
        shared.perform { $0.rememberSnapshot(snapshot, for: "ContractApp") }

        let click = { (stateID: String) -> UltraTermComputerUseCallOutput in
            try shared.perform { service in
                try runUltraTermComputerUseCall(.single(
                    toolName: "click",
                    argumentsJSON: #"{"app":"ContractApp","state_id":"\#(stateID)"}"#,
                    argumentsFile: nil
                ), service: service)
            }
        }

        // Call 2, separate invocation, right id: the state gate passes (it fails later and
        // harmlessly because the screenshot channel is off), so it is not a stale_state.
        let accepted = try click("feedc0de")
        XCTAssertNotEqual(accepted.errorInfo?.code, "stale_state")
        XCTAssertEqual(accepted.errorInfo?.code, "state_unavailable")

        // Call 3, wrong id: refused before anything is sent.
        let refused = try click("00000000")
        XCTAssertEqual(refused.errorInfo?.code, "stale_state")
        XCTAssertEqual(refused.errorInfo.map { ultraTermComputerUseExitStatus(forStructuredCode: $0.code) }, .staleState)
    }

    func testAFreshServicePerCallRefusesTheSameStateID() throws {
        // The behaviour without an agent-held service: each call starts empty.
        let output = try runUltraTermComputerUseCall(.single(
            toolName: "click", argumentsJSON: #"{"app":"ContractApp","state_id":"feedc0de"}"#, argumentsFile: nil
        ), service: ComputerUseService())
        XCTAssertEqual(output.errorInfo?.code, "stale_state")
    }

    func testSharedServiceIsReusedThenExpiresWhenIdle() {
        var clock = Date(timeIntervalSince1970: 1_000)
        var made = 0
        let shared = UltraTermComputerUseSharedCallService(idleTimeout: 600, now: { clock }, make: { made += 1; return ComputerUseService() })
        let first = shared.perform { $0 }
        clock += 599
        XCTAssertTrue(shared.perform { $0 } === first)
        clock += 599  // idle time counts from the last call, not from creation
        XCTAssertTrue(shared.perform { $0 } === first)
        XCTAssertEqual(made, 1)
        clock += 601
        XCTAssertFalse(shared.perform { $0 } === first)
        XCTAssertEqual(made, 2)
        shared.reset()
        _ = shared.perform { $0 }
        XCTAssertEqual(made, 3)
    }

    private final class ConcurrencyProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private(set) var peak = 0
        func enter() { lock.lock(); active += 1; peak = max(peak, active); lock.unlock() }
        func leave() { lock.lock(); active -= 1; lock.unlock() }
    }

    func testSharedServiceSerializesCalls() {
        let shared = UltraTermComputerUseSharedCallService()
        let probe = ConcurrencyProbe()
        let group = DispatchGroup()
        for _ in 0..<8 {
            DispatchQueue.global().async(group: group) {
                shared.perform { _ in
                    probe.enter()
                    Thread.sleep(forTimeInterval: 0.01)
                    probe.leave()
                }
            }
        }
        group.wait()
        XCTAssertEqual(probe.peak, 1)
    }

    // MARK: MCP stays an optional command

    func testMCPCommandStillParses() throws {
        XCTAssertEqual(try parseUltraTermComputerUseCLI(arguments: ["mcp"]), .mcp)
        XCTAssertTrue(ultraTermComputerUseHelpText().contains("Optional: start the stdio MCP server"))
    }
}
