import Foundation

// The agent-facing side of `ultraterm-computer-use call`: schema-driven flags, plain-text
// output, per-tool help and the agent-held service that lets one-shot calls share state.

/// How `call` prints its result. Compact plain text is the default; `--json` prints the
/// MCP-style result envelope; `--media-dir` writes screenshots to files.
public struct UltraTermComputerUseCallOptions: Equatable {
    public var json: Bool
    public var mediaDir: String?

    public init(json: Bool = false, mediaDir: String? = nil) {
        self.json = json
        self.mediaDir = mediaDir
    }
}

/// Everything the process needs to write after a `call`.
public struct UltraTermComputerUseCallResponse: Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

// MARK: - Direct tool commands

/// `ultraterm-computer-use click --app X ...` is shorthand for `call click --app X ...`.
/// Returns the arguments with `call` inserted when the first one names a tool.
public func normalizedUltraTermComputerUseArguments(_ arguments: [String]) -> [String] {
    guard let first = arguments.first, !first.hasPrefix("-"), first != "call",
          ToolSchemaValidator.isKnownTool(first)
    else {
        return arguments
    }
    return ["call"] + arguments
}

// MARK: - Schema-driven flags

struct ToolFlagSpec {
    let key: String
    let property: [String: Any]
}

/// Maps `--element-index`, `--element_index` or `--element-index=3` onto a schema property.
func toolFlagSpec(forTool tool: String, option: String) -> ToolFlagSpec? {
    guard option.hasPrefix("--"),
          let definition = ToolDefinitions.all.first(where: { $0.name == tool })
    else {
        return nil
    }
    let name = String(option.dropFirst(2)).replacingOccurrences(of: "-", with: "_")
    let properties = definition.inputSchema["properties"] as? [String: Any] ?? [:]
    guard let property = properties[name] as? [String: Any] else {
        return nil
    }
    return ToolFlagSpec(key: name, property: property)
}

func toolFlagNames(forTool tool: String) -> [String] {
    guard let definition = ToolDefinitions.all.first(where: { $0.name == tool }) else { return [] }
    let properties = definition.inputSchema["properties"] as? [String: Any] ?? [:]
    return properties.keys.sorted().map { "--" + $0.replacingOccurrences(of: "_", with: "-") }
}

private func propertyTypeNames(_ property: [String: Any]) -> [String] {
    if let anyOf = property["anyOf"] as? [[String: Any]] {
        return anyOf.flatMap(propertyTypeNames)
    }
    if let allowed = property["enum"] as? [String] {
        return ["one of " + allowed.joined(separator: "|")]
    }
    return [property["type"] as? String ?? "value"]
}

/// Coerces a flag value to the JSON type the property declares. Booleans accept a bare flag.
func coerceToolFlagValue(_ raw: String, option: String, property: [String: Any]) throws -> Any {
    if let anyOf = property["anyOf"] as? [[String: Any]] {
        var lastError: Error?
        for option_ in anyOf {
            do { return try coerceToolFlagValue(raw, option: option, property: option_) } catch { lastError = error }
        }
        throw lastError ?? UltraTermComputerUseCLIError(message: "\(option) has an invalid value", helpCommand: "call")
    }
    if let allowed = property["enum"] as? [String] {
        guard allowed.contains(raw) else {
            throw UltraTermComputerUseCLIError(
                message: "\(option) must be one of \(allowed.joined(separator: ", "))", helpCommand: "call"
            )
        }
        return raw
    }
    switch property["type"] as? String {
    case "integer":
        guard let value = Int(raw) else {
            throw UltraTermComputerUseCLIError(message: "\(option) must be an integer", helpCommand: "call")
        }
        return value
    case "number":
        guard let value = Double(raw), value.isFinite else {
            throw UltraTermComputerUseCLIError(message: "\(option) must be a number", helpCommand: "call")
        }
        return value
    case "boolean":
        guard let value = Bool(raw.lowercased()) else {
            throw UltraTermComputerUseCLIError(message: "\(option) must be true or false", helpCommand: "call")
        }
        return value
    default:
        return raw
    }
}

func isBooleanToolProperty(_ property: [String: Any]) -> Bool {
    property["type"] as? String == "boolean"
}

/// Merges `--args` JSON (if any) with flag values; flags win.
func mergedToolArgumentsJSON(argumentsJSON: String?, flags: [String: Any]) throws -> String {
    var arguments = try readUltraTermComputerUseToolArguments(json: argumentsJSON, file: nil)
    for (key, value) in flags { arguments[key] = value }
    let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Per-tool help, generated from the same schema the MCP server lists

public func ultraTermComputerUseToolHelpText(_ name: String) -> String? {
    guard let definition = ToolDefinitions.all.first(where: { $0.name == name }) else {
        return nil
    }
    let schema = definition.inputSchema
    let required = schema["required"] as? [String] ?? []
    let properties = schema["properties"] as? [String: Any] ?? [:]

    var lines = ["Usage:"]
    var usage = "  ultraterm-computer-use call \(name)"
    for key in required {
        usage += " --\(key.replacingOccurrences(of: "_", with: "-")) <\(key)>"
    }
    if properties.count > required.count { usage += " [options]" }
    lines.append(usage)
    lines.append("  ultraterm-computer-use call \(name) --args '<json-object>'")
    lines.append("")
    lines.append(definition.description.replacingOccurrences(of: " This tool is part of plugin `Computer Use`.", with: ""))
    if !properties.isEmpty {
        lines.append("")
        lines.append("Options (a flag takes the JSON type shown; --snake_case spelling also works):")
        for key in properties.keys.sorted() {
            let property = properties[key] as? [String: Any] ?? [:]
            let flag = "--" + key.replacingOccurrences(of: "_", with: "-")
            let type = propertyTypeNames(property).joined(separator: " or ")
            let mark = required.contains(key) ? ", required" : ""
            lines.append("  \(flag) (\(type)\(mark))")
            if let description = property["description"] as? String {
                lines.append("      \(description)")
            }
        }
    }
    lines.append("")
    lines.append("Common options: --json (print the result envelope), --media-dir <dir> (write screenshots to files).")
    if ComputerUseToolDispatcher.stateCheckedTools.contains(name) {
        lines.append("Pass --state-id from the last get_app_state or action result; a stale one is refused with exit 7 before anything is sent.")
    }
    return lines.joined(separator: "\n")
}

// MARK: - Rendering

private func ultraTermComputerUseErrorText(_ info: ComputerUseErrorInfo) -> String {
    var header = "error[\(info.code)]"
    var details: [String] = [info.phase.rawValue]
    if let index = info.callIndex { details.append("call \(index + 1)") }
    if info.retryable { details.append("retryable") }
    header += " (\(details.joined(separator: ", "))): \(info.message)"
    var lines = [header]
    if let hint = info.hint { lines.append("hint: \(hint)") }
    if !info.candidates.isEmpty { lines.append("candidates: \(info.candidates.joined(separator: ", "))") }
    return lines.joined(separator: "\n")
}

/// Plain text for one tool result: its text items, `image: <path>` for files written to
/// `--media-dir`, and a one-line note for screenshots that were not saved.
func ultraTermComputerUseCompactText(_ result: ToolCallResult) -> String {
    var lines: [String] = []
    for item in result.content {
        switch item.dictionary["type"] as? String {
        case "text":
            if let text = item.dictionary["text"] as? String { lines.append(text) }
        case "image_path":
            if let path = item.dictionary["path"] as? String { lines.append("image: \(path)") }
        case "image":
            let mime = item.dictionary["mimeType"] as? String ?? "image"
            let bytes = (item.dictionary["data"] as? String).map { $0.utf8.count * 3 / 4 } ?? 0
            lines.append("[screenshot omitted: \(mime), about \(bytes) bytes; pass --media-dir <dir> to save it]")
        default:
            break
        }
    }
    if let stateID = result.stateID, !lines.contains(where: { $0.contains(stateID) }) {
        lines.append("State-ID: \(stateID)")
    }
    return lines.joined(separator: "\n")
}

public func ultraTermComputerUseCallResponse(
    for output: UltraTermComputerUseCallOutput,
    options: UltraTermComputerUseCallOptions
) throws -> UltraTermComputerUseCallResponse {
    let exitCode: Int32 = output.hasToolError
        ? (output.errorInfo.map { ultraTermComputerUseExitStatus(forStructuredCode: $0.code).rawValue }
            ?? ultraTermComputerUseExitStatus(forStructuredCode: "error").rawValue)
        : 0

    if options.json {
        return UltraTermComputerUseCallResponse(stdout: try output.jsonText() + "\n", stderr: "", exitCode: exitCode)
    }

    var stdoutLines: [String] = []
    var stderrLines: [String] = []

    if let preflight = output.preflightError {
        stderrLines.append(ultraTermComputerUseErrorText(preflight))
        stderrLines.append("No call was run.")
    } else if output.isSequence {
        for (index, step) in output.steps.enumerated() {
            stdoutLines.append("== \(index + 1). \(step.tool) ==")
            if step.result.isError {
                if let info = step.result.errorInfo {
                    stderrLines.append(ultraTermComputerUseErrorText(info))
                } else {
                    stderrLines.append("error: \(step.result.textContent)")
                }
            } else {
                stdoutLines.append(ultraTermComputerUseCompactText(step.result))
            }
        }
        if output.hasToolError { stderrLines.append("Sequence stopped at the first error.") }
    } else if let step = output.steps.first {
        if step.result.isError {
            if let info = step.result.errorInfo {
                stderrLines.append(ultraTermComputerUseErrorText(info))
            } else {
                stderrLines.append("error: \(step.result.textContent)")
            }
        } else {
            stdoutLines.append(ultraTermComputerUseCompactText(step.result))
        }
    }

    return UltraTermComputerUseCallResponse(
        stdout: stdoutLines.isEmpty ? "" : stdoutLines.joined(separator: "\n") + "\n",
        stderr: stderrLines.isEmpty ? "" : stderrLines.joined(separator: "\n") + "\n",
        exitCode: exitCode
    )
}

/// Runs a `call` invocation and renders it. The CLI process and the app agent both use this,
/// so the two routes print the same bytes.
public func runUltraTermComputerUseCallCommand(
    _ invocation: UltraTermComputerUseCallInvocation,
    service: ComputerUseService = ComputerUseService()
) throws -> UltraTermComputerUseCallResponse {
    let output = try runUltraTermComputerUseCall(invocation, service: service)
    return try ultraTermComputerUseCallResponse(for: output, options: invocation.options)
}

extension UltraTermComputerUseCallInvocation {
    public var options: UltraTermComputerUseCallOptions {
        switch self {
        case let .single(_, _, _, options): return options
        case let .sequence(_, _, _, options): return options
        }
    }
}

// MARK: - Agent-held state for one-shot calls

/// What the app agent runs for a proxied `cli` request whose arguments parse to `call`.
/// Every request goes through the agent's one shared service, so separate one-shot CLI
/// invocations see each other's captured state. Kept here, not in the app target, so a test
/// can drive two requests through it without a desktop.
public func runUltraTermComputerUseAgentCall(
    _ invocation: UltraTermComputerUseCallInvocation,
    shared: UltraTermComputerUseSharedCallService
) throws -> UltraTermComputerUseCallResponse {
    try shared.perform { service in
        try runUltraTermComputerUseCallCommand(invocation, service: service)
    }
}

/// One `ComputerUseService` that outlives a single `call`. The app agent keeps it, so a
/// `state_id` and the element indexes from one `call get_app_state` are still valid in the
/// next `call click` without an MCP session. Calls are serialized (the service is not
/// thread safe) and the state is dropped after `idleTimeout` seconds without a call, so an
/// old screen is never acted on.
public final class UltraTermComputerUseSharedCallService: @unchecked Sendable {
    public static let defaultIdleTimeout: TimeInterval = 600

    private let lock = NSLock()
    private let idleTimeout: TimeInterval
    private let now: () -> Date
    private let make: () -> ComputerUseService
    private var service: ComputerUseService?
    private var lastUsed = Date.distantPast

    public init(
        idleTimeout: TimeInterval = UltraTermComputerUseSharedCallService.defaultIdleTimeout,
        now: @escaping () -> Date = Date.init,
        make: @escaping () -> ComputerUseService = { ComputerUseService() }
    ) {
        self.idleTimeout = idleTimeout
        self.now = now
        self.make = make
    }

    public func perform<T>(_ body: (ComputerUseService) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        let current = now()
        if service == nil || current.timeIntervalSince(lastUsed) > idleTimeout {
            service = make()
        }
        lastUsed = current
        defer { lastUsed = now() }
        return try body(service!)
    }

    public func reset() {
        lock.lock()
        service = nil
        lock.unlock()
    }
}

// MARK: - Bounded wait for the agent

/// The longest one tool call may take before the CLI stops waiting for the app agent. A hung
/// agent (a stuck accessibility read) must end in a named error, not a CLI that never returns.
public let ultraTermComputerUseAgentCallLimit: TimeInterval = 120

/// Whole seconds the CLI waits for the agent's reply to `arguments`: the limit for each call
/// plus the `--sleep` pauses between the calls of a sequence.
public func ultraTermComputerUseAgentReplyTimeout(arguments: [String]) -> Int {
    var callCount = 1
    var pauses: TimeInterval = 0
    if case let .call(.sequence(callsJSON, callsFile, interCallDelay, _))? = try? parseUltraTermComputerUseCLI(arguments: arguments),
       let calls = try? readUltraTermComputerUseCallSequence(json: callsJSON, file: callsFile) {
        callCount = max(calls.count, 1)
        pauses = interCallDelay * Double(callCount - 1)
    }
    return Int((ultraTermComputerUseAgentCallLimit * Double(callCount) + pauses).rounded(.up))
}
