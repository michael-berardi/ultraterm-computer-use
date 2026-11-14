import CoreGraphics
import Foundation

func normalizedElementIndexArgument(_ value: Any?) -> String? {
    if let string = value as? String {
        return string.isEmpty ? nil : string
    }

    // CFBoolean NSNumbers (JSON true/false) bridge-cast to Int/Double, so the
    // boolean check must run before any numeric branch.
    if let number = value as? NSNumber, CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
        return nil
    }

    if let integer = value as? Int {
        return String(integer)
    }

    if let number = value as? NSNumber {
        return normalizedElementIndexNumber(number.doubleValue)
    }

    if let double = value as? Double {
        return normalizedElementIndexNumber(double)
    }

    return nil
}

private func normalizedElementIndexNumber(_ value: Double) -> String? {
    guard value.isFinite, value.rounded(.towardZero) == value else {
        return nil
    }

    guard value >= Double(Int.min), value <= Double(Int.max) else {
        return nil
    }

    return String(Int(value))
}

public final class ComputerUseToolDispatcher {
    private let service: ComputerUseService

    public init(service: ComputerUseService = ComputerUseService()) {
        self.service = service
    }

    public func callTool(name: String, arguments: [String: Any]) throws -> ToolCallResult {
        // Calls run on threads whose autorelease pool never drains (the stdio read loop, an
        // app-agent connection), so without one per call every screenshot's bitmap and
        // encoded data stayed alive for the whole session.
        try autoreleasepool { try dispatchTool(name: name, arguments: arguments) }
    }

    /// Runs a call and folds every failure into a `ToolCallResult` carrying a
    /// structured `error` payload (phase `execute`). The result text is exactly the
    /// error's own description, so the tool contract is unchanged; schema preflight
    /// is the CLI's job (`preflightUltraTermComputerUseCalls`).
    public func callToolAsResult(name: String, arguments: [String: Any]) -> ToolCallResult {
        callToolAsResult(name: name, arguments: arguments, callIndex: nil)
    }

    func callToolAsResult(name: String, arguments: [String: Any], callIndex: Int?) -> ToolCallResult {
        callValidatedToolAsResult(name: name, arguments: arguments, callIndex: callIndex)
    }

    /// Executes a call after schema validation has already completed. Sequence
    /// execution uses this after its all-calls preflight, avoiding another
    /// identical validation pass while preserving the public dispatch contract.
    fileprivate func callValidatedToolAsResult(
        name: String,
        arguments: [String: Any],
        callIndex: Int?
    ) -> ToolCallResult {
        let result: ToolCallResult
        do {
            result = try callTool(name: name, arguments: arguments)
        } catch {
            // Argument and tool-name failures never mutate anything, so they report as
            // `preflight`; everything else failed while executing.
            let info = computerUseErrorInfo(for: error, phase: dispatchFailurePhase(for: error), callIndex: callIndex)
            result = ToolCallResult.text(info.message, errorInfo: info)
        }
        return result
    }

    /// Tools that change the app and so accept `state_id`.
    public static let stateCheckedTools: Set<String> = [
        "click", "perform_secondary_action", "scroll", "drag", "type_text", "press_key", "set_value", "select_text",
    ]

    private func dispatchTool(name: String, arguments: [String: Any]) throws -> ToolCallResult {
        if Self.stateCheckedTools.contains(name), let rawStateID = arguments["state_id"], !(rawStateID is NSNull) {
            guard let stateID = rawStateID as? String else {
                throw ComputerUseError.invalidArguments("state_id must be a string")
            }
            try service.requireCurrentState(stateID, app: requireString("app", in: arguments))
        }

        switch name {
        case "list_apps":
            return service.listApps()
        case "query":
            let matches = try service.query(
                app: requireString("app", in: arguments),
                text: try validatedQueryString(arguments["text"], key: "text"),
                role: try validatedQueryString(arguments["role"], key: "role"),
                exact: try validatedQueryExact(arguments["exact"]),
                limit: try optionalPositiveInt("limit", in: arguments) ?? 20,
                maxNodes: try optionalPositiveInt("max_nodes", in: arguments) ?? 500,
                windowID: try validatedQueryWindowID(arguments["window_id"])
            )
            return .text(try renderedQueryMatches(matches))
        case "get_app_state":
            return try service.getAppState(
                app: requireString("app", in: arguments),
                textLimit: try optionalTextLimit("text_limit", in: arguments) ?? .defaults,
                treeLimits: AccessibilityTreeLimits.defaults.replacing(
                    maxNodeCount: try optionalPositiveInt("max_tree_nodes", in: arguments),
                    maxDepth: try optionalPositiveInt("max_tree_depth", in: arguments)
                ),
                windowPlacement: try parseWindowPlacement(optionalString("window_placement", in: arguments)),
                observation: SnapshotObservationOptions(
                    includeAX: try strictObservationBool("include_ax", in: arguments),
                    includeScreenshot: try strictObservationBool("include_screenshot", in: arguments)
                )
            )
        case "click":
            return try service.click(
                app: requireString("app", in: arguments),
                elementIndex: try optionalElementIndex(in: arguments),
                x: try optionalDouble("x", in: arguments),
                y: try optionalDouble("y", in: arguments),
                clickCount: try optionalPositiveInt("click_count", in: arguments) ?? 1,
                mouseButton: try optionalMouseButton(in: arguments) ?? MouseButtonKind.left.rawValue,
                clickMethod: try parseClickMethod(optionalString("click_method", in: arguments))
            )
        case "perform_secondary_action":
            return try service.performSecondaryAction(
                app: requireString("app", in: arguments),
                elementIndex: requireElementIndex(in: arguments),
                action: requireString("action", in: arguments)
            )
        case "scroll":
            return try service.scroll(
                app: requireString("app", in: arguments),
                direction: requireString("direction", in: arguments),
                elementIndex: requireElementIndex(in: arguments),
                pages: try optionalDouble("pages", in: arguments) ?? 1
            )
        case "drag":
            return try service.drag(
                app: requireString("app", in: arguments),
                fromX: requireDouble("from_x", in: arguments),
                fromY: requireDouble("from_y", in: arguments),
                toX: requireDouble("to_x", in: arguments),
                toY: requireDouble("to_y", in: arguments)
            )
        case "type_text":
            return try service.typeText(
                app: requireString("app", in: arguments),
                text: requireString("text", in: arguments),
                keyMethod: try parseKeyMethod(optionalString("key_method", in: arguments))
            )
        case "press_key":
            return try service.pressKey(
                app: requireString("app", in: arguments),
                key: requireString("key", in: arguments),
                keyMethod: try parseKeyMethod(optionalString("key_method", in: arguments))
            )
        case "set_value":
            return try service.setValue(
                app: requireString("app", in: arguments),
                elementIndex: requireElementIndex(in: arguments),
                value: requireString("value", in: arguments, allowEmpty: true)
            )
        case "select_text":
            return try service.selectText(
                app: requireString("app", in: arguments),
                elementIndex: requireElementIndex(in: arguments),
                text: requireString("text", in: arguments),
                prefix: try selectionString("prefix", in: arguments),
                suffix: try selectionString("suffix", in: arguments),
                selection: try parseSelectionMode(try selectionString("selection", in: arguments))
            )
        default:
            throw ComputerUseError.unsupportedTool(name)
        }
    }

    private func requireString(_ key: String, in arguments: [String: Any], allowEmpty: Bool = false) throws -> String {
        guard let value = arguments[key] as? String, allowEmpty || !value.isEmpty else {
            throw ComputerUseError.missingArgument(key)
        }

        return value
    }

    private func strictObservationBool(_ key: String, in arguments: [String: Any]) throws -> Bool {
        guard let value = arguments[key] else { return true }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw ComputerUseError.invalidArguments("\(key) must be a boolean")
        }
        return number.boolValue
    }

    private func optionalBool(_ key: String, in arguments: [String: Any]) -> Bool? {
        switch arguments[key] {
        case let value as Bool: return value
        case let value as NSNumber: return value.boolValue
        case let value as String: return Bool(value.lowercased())
        default: return nil
        }
    }

    /// Machine-readable matches with explicit completeness metadata.
    private func renderedQueryMatches(_ matches: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: matches, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw ComputerUseError.stateUnavailable("Query response could not be encoded")
        }
        return text
    }

    private func optionalString(_ key: String, in arguments: [String: Any]) -> String? {
        arguments[key] as? String
    }

    private func selectionString(_ key: String, in arguments: [String: Any]) throws -> String? {
        guard let value = arguments[key] else { return nil }
        guard let string = value as? String else {
            throw ComputerUseError.invalidArguments("\(key) must be a string")
        }
        return string
    }

    private func parseSelectionMode(_ raw: String?) throws -> TextSelectionMode {
        guard let raw else { return .text }

        guard let mode = TextSelectionMode(rawValue: raw) else {
            throw ComputerUseError.message(
                "selection must be one of \(TextSelectionMode.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        }

        return mode
    }

    private func optionalTextLimit(_ key: String, in arguments: [String: Any]) throws -> SnapshotTextLimit? {
        guard let value = arguments[key] else {
            return nil
        }

        if let string = value as? String {
            guard string.lowercased() == SnapshotTextLimit.maxKeyword else {
                throw ComputerUseError.invalidArguments("\(key) must be a positive integer or max")
            }
            return .max
        }

        let maxCount = try positiveInt(from: value, key: key, expectedDescription: "a positive integer or max")
        return SnapshotTextLimit(maxCount: maxCount)
    }

    private func requireElementIndex(in arguments: [String: Any]) throws -> String {
        guard let value = try optionalElementIndex(in: arguments) else {
            throw ComputerUseError.missingArgument("element_index")
        }

        return value
    }

    private func optionalElementIndex(in arguments: [String: Any]) throws -> String? {
        // A JSON boolean is never an index; refuse it instead of treating it as absent.
        if let number = arguments["element_index"] as? NSNumber, CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
            throw ComputerUseError.invalidArguments("element_index must be a string or a whole number")
        }
        return normalizedElementIndexArgument(arguments["element_index"])
    }

    private func requireDouble(_ key: String, in arguments: [String: Any]) throws -> Double {
        guard let value = try optionalDouble(key, in: arguments) else {
            throw ComputerUseError.missingArgument(key)
        }

        return value
    }

    private func optionalDouble(_ key: String, in arguments: [String: Any]) throws -> Double? {
        guard let raw = arguments[key] else {
            return nil
        }

        if let number = raw as? NSNumber, CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
            throw ComputerUseError.invalidArguments("\(key) must be a number")
        }

        if let double = raw as? Double {
            return double
        }

        if let integer = raw as? Int {
            return Double(integer)
        }

        if let number = raw as? NSNumber {
            return number.doubleValue
        }

        return nil
    }

    private func optionalMouseButton(in arguments: [String: Any]) throws -> String? {
        guard let raw = optionalString("mouse_button", in: arguments) else {
            return nil
        }

        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard MouseButtonKind(rawValue: normalized) != nil else {
            throw ComputerUseError.invalidArguments(
                "mouse_button must be one of \(MouseButtonKind.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        }

        return normalized
    }

    private func optionalPositiveInt(_ key: String, in arguments: [String: Any]) throws -> Int? {
        guard let value = arguments[key] else {
            return nil
        }

        return try positiveInt(from: value, key: key, expectedDescription: "a positive integer")
    }

    private func positiveInt(from value: Any, key: String, expectedDescription: String) throws -> Int {
        // CFBoolean NSNumbers (JSON true/false) bridge-cast to Int/Double, so
        // the boolean check must run before any numeric branch.
        if let number = value as? NSNumber, CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
            throw ComputerUseError.invalidArguments("\(key) must be \(expectedDescription)")
        }

        if let integer = value as? Int {
            return try validatePositiveInt(integer, key: key, expectedDescription: expectedDescription)
        }

        if let double = value as? Double {
            return try validatePositiveWholeNumber(double, key: key, expectedDescription: expectedDescription)
        }

        if let number = value as? NSNumber {
            return try validatePositiveWholeNumber(number.doubleValue, key: key, expectedDescription: expectedDescription)
        }

        throw ComputerUseError.invalidArguments("\(key) must be \(expectedDescription)")
    }

    private func validatePositiveWholeNumber(_ value: Double, key: String, expectedDescription: String) throws -> Int {
        guard value.isFinite, value.rounded(.towardZero) == value else {
            throw ComputerUseError.invalidArguments("\(key) must be \(expectedDescription)")
        }

        guard value >= Double(Int.min), value <= Double(Int.max) else {
            throw ComputerUseError.invalidArguments("\(key) is outside the supported integer range")
        }

        return try validatePositiveInt(Int(value), key: key, expectedDescription: expectedDescription)
    }

    private func validatePositiveInt(_ value: Int, key: String, expectedDescription: String) throws -> Int {
        guard value > 0 else {
            throw ComputerUseError.invalidArguments("\(key) must be \(expectedDescription)")
        }
        return value
    }
}

public struct UltraTermComputerUseCallSpec {
    public let tool: String
    public let arguments: [String: Any]

    public init(tool: String, arguments: [String: Any]) {
        self.tool = tool
        self.arguments = arguments
    }
}

public struct UltraTermComputerUseCallStep {
    public let tool: String
    public let result: ToolCallResult

    public init(tool: String, result: ToolCallResult) {
        self.tool = tool
        self.result = result
    }
}

public struct UltraTermComputerUseCallOutput {
    public let jsonObject: Any
    public let hasToolError: Bool
    public let errorInfo: ComputerUseErrorInfo?
    /// Every executed call with its result, in order. Empty when preflight refused the run.
    public let steps: [UltraTermComputerUseCallStep]
    public let isSequence: Bool
    /// Set when schema preflight refused the run before any call executed.
    public let preflightError: ComputerUseErrorInfo?

    public init(
        jsonObject: Any,
        hasToolError: Bool,
        errorInfo: ComputerUseErrorInfo? = nil,
        steps: [UltraTermComputerUseCallStep] = [],
        isSequence: Bool = false,
        preflightError: ComputerUseErrorInfo? = nil
    ) {
        self.jsonObject = jsonObject
        self.hasToolError = hasToolError
        self.errorInfo = errorInfo
        self.steps = steps
        self.isSequence = isSequence
        self.preflightError = preflightError
    }

    public func jsonText() throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: jsonObject,
            options: [.prettyPrinted, .withoutEscapingSlashes]
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw ComputerUseError.message("Failed to encode call output as JSON.")
        }
        return text
    }
}

public typealias UltraTermComputerUseSleepHandler = (TimeInterval) -> Void

/// Validate every call in a sequence against the tool schemas before any
/// call executes. Returns nil when all calls are valid; otherwise the
/// structured failure for the first invalid call (0-based `callIndex`).
public func preflightUltraTermComputerUseCalls(_ calls: [UltraTermComputerUseCallSpec]) -> ComputerUseErrorInfo? {
    for (index, call) in calls.enumerated() {
        // An unknown tool is reported when it is reached, like any other tool error:
        // the sequence stops there instead of being refused up front.
        guard ToolSchemaValidator.isKnownTool(call.tool) else { continue }
        do {
            try ToolSchemaValidator.validate(tool: call.tool, arguments: call.arguments)
        } catch {
            return computerUseErrorInfo(for: error, phase: .preflight, callIndex: index)
        }
    }

    return nil
}

public func runUltraTermComputerUseCall(
    _ invocation: UltraTermComputerUseCallInvocation,
    service: ComputerUseService = ComputerUseService(),
    sleepHandler: UltraTermComputerUseSleepHandler = { Thread.sleep(forTimeInterval: $0) }
) throws -> UltraTermComputerUseCallOutput {
    let dispatcher = ComputerUseToolDispatcher(service: service)

    switch invocation {
    case let .single(toolName, argumentsJSON, argumentsFile, options):
        let arguments = try readUltraTermComputerUseToolArguments(
            json: argumentsJSON,
            file: argumentsFile
        )

        if let preflightError = preflightUltraTermComputerUseCalls([
            UltraTermComputerUseCallSpec(tool: toolName, arguments: arguments),
        ]) {
            return UltraTermComputerUseCallOutput(
                jsonObject: [
                    "error": preflightError.asDictionary,
                    "calls_executed": 0,
                ],
                hasToolError: true,
                errorInfo: preflightError,
                preflightError: preflightError
            )
        }

        if let mediaError = prepareUltraTermComputerUseMediaDirectory(options.mediaDir) {
            return UltraTermComputerUseCallOutput(
                jsonObject: ["error": mediaError.asDictionary, "calls_executed": 0],
                hasToolError: true,
                errorInfo: mediaError,
                preflightError: mediaError
            )
        }

        let result = externalizedCallResult(
            dispatcher.callValidatedToolAsResult(name: toolName, arguments: arguments, callIndex: nil),
            tool: toolName, arguments: arguments, index: 0, options: options
        )
        return UltraTermComputerUseCallOutput(
            jsonObject: result.asDictionary,
            hasToolError: result.isError,
            errorInfo: result.errorInfo,
            steps: [UltraTermComputerUseCallStep(tool: toolName, result: result)]
        )

    case let .sequence(callsJSON, callsFile, interCallDelay, options):
        let calls = try readUltraTermComputerUseCallSequence(json: callsJSON, file: callsFile)

        if let preflightError = preflightUltraTermComputerUseCalls(calls) {
            return UltraTermComputerUseCallOutput(
                jsonObject: [
                    "error": preflightError.asDictionary,
                    "calls_executed": 0,
                ],
                hasToolError: true,
                errorInfo: preflightError,
                preflightError: preflightError
            )
        }

        if let mediaError = prepareUltraTermComputerUseMediaDirectory(options.mediaDir) {
            return UltraTermComputerUseCallOutput(
                jsonObject: ["error": mediaError.asDictionary, "calls_executed": 0],
                hasToolError: true,
                errorInfo: mediaError,
                preflightError: mediaError
            )
        }

        var steps: [UltraTermComputerUseCallStep] = []
        var outputs: [[String: Any]] = []
        var hasToolError = false
        var firstErrorInfo: ComputerUseErrorInfo?

        for (index, call) in calls.enumerated() {
            let result = externalizedCallResult(
                dispatcher.callValidatedToolAsResult(name: call.tool, arguments: call.arguments, callIndex: index),
                tool: call.tool, arguments: call.arguments, index: index, options: options
            )
            steps.append(UltraTermComputerUseCallStep(tool: call.tool, result: result))
            outputs.append([
                "tool": call.tool,
                "result": result.asDictionary,
            ])

            if result.isError {
                hasToolError = true
                firstErrorInfo = result.errorInfo
                break
            }

            if index < calls.count - 1, interCallDelay > 0 {
                sleepHandler(interCallDelay)
            }
        }

        return UltraTermComputerUseCallOutput(
            jsonObject: outputs,
            hasToolError: hasToolError,
            errorInfo: firstErrorInfo,
            steps: steps,
            isSequence: true
        )
    }
}

/// `--media-dir` is created and checked before the first call runs, so an unusable folder is a
/// usage error (exit 2) and no action has happened yet. Returns nil when there is nothing to fix.
func prepareUltraTermComputerUseMediaDirectory(
    _ mediaDir: String?,
    fileManager: FileManager = .default
) -> ComputerUseErrorInfo? {
    guard let mediaDir else { return nil }
    do {
        try fileManager.createDirectory(atPath: mediaDir, withIntermediateDirectories: true)
        guard fileManager.isWritableFile(atPath: mediaDir) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        return nil
    } catch {
        return ComputerUseErrorInfo(
            code: "usage",
            phase: .preflight,
            retryable: false,
            hint: "Pass a --media-dir this user can write to. No call was run.",
            message: "--media-dir \(mediaDir) cannot be used: \(error.localizedDescription)"
        )
    }
}

/// With `--media-dir`, screenshots are written to files and the result carries `image_path`
/// items instead of base64. File names are unique per call so nothing is overwritten.
/// The action has already run when this is called, so a failed write never discards the result
/// (and its new state_id): the result is kept with an `image not saved: <reason>` line.
func externalizedCallResult(
    _ result: ToolCallResult,
    tool: String,
    arguments: [String: Any],
    index: Int,
    options: UltraTermComputerUseCallOptions
) -> ToolCallResult {
    guard let mediaDir = options.mediaDir else { return result }
    let app = (arguments["app"] as? String) ?? "app"
    let stamp = Int(Date().timeIntervalSince1970 * 1000)
    do {
        return try externalizeToolResultImages(result, mediaDir: mediaDir, stem: "\(app)-\(tool)-\(stamp)-\(index + 1)")
    } catch {
        return ToolCallResult(
            content: result.content + [.text("image not saved: \(error.localizedDescription)")],
            isError: result.isError,
            errorInfo: result.errorInfo,
            stateID: result.stateID
        )
    }
}

public func readUltraTermComputerUseToolArguments(
    json: String?,
    file: String?
) throws -> [String: Any] {
    guard let source = try readUltraTermComputerUseJSONSource(json: json, file: file) else {
        return [:]
    }

    let object = try decodeUltraTermComputerUseJSONObject(source)
    guard let arguments = object as? [String: Any] else {
        throw UltraTermComputerUseCLIError(message: "--args must be a JSON object", helpCommand: "call")
    }

    return arguments
}

public func readUltraTermComputerUseCallSequence(
    json: String?,
    file: String?
) throws -> [UltraTermComputerUseCallSpec] {
    guard let source = try readUltraTermComputerUseJSONSource(json: json, file: file) else {
        throw UltraTermComputerUseCLIError(message: "call sequence requires --calls or --calls-file", helpCommand: "call")
    }

    let object = try decodeUltraTermComputerUseJSONObject(source)
    guard let array = object as? [Any] else {
        throw UltraTermComputerUseCLIError(message: "--calls must be a JSON array", helpCommand: "call")
    }

    return try array.enumerated().map { index, item in
        guard let dictionary = item as? [String: Any] else {
            throw UltraTermComputerUseCLIError(
                message: "call sequence item #\(index + 1) must be a JSON object",
                helpCommand: "call"
            )
        }

        guard let tool = (dictionary["tool"] ?? dictionary["name"]) as? String, !tool.isEmpty else {
            throw UltraTermComputerUseCLIError(
                message: "call sequence item #\(index + 1) requires a non-empty tool",
                helpCommand: "call"
            )
        }

        let rawArguments = dictionary["args"] ?? dictionary["arguments"] ?? [:]
        guard let arguments = rawArguments as? [String: Any] else {
            throw UltraTermComputerUseCLIError(
                message: "call sequence item #\(index + 1) args must be a JSON object",
                helpCommand: "call"
            )
        }

        return UltraTermComputerUseCallSpec(tool: tool, arguments: arguments)
    }
}

private func readUltraTermComputerUseJSONSource(json: String?, file: String?) throws -> String? {
    if json != nil, file != nil {
        throw UltraTermComputerUseCLIError(message: "Use either inline JSON or a JSON file, not both", helpCommand: "call")
    }

    if let json {
        return json
    }

    guard let file else {
        return nil
    }

    do {
        return try String(contentsOfFile: file, encoding: .utf8)
    } catch {
        throw UltraTermComputerUseCLIError(
            message: "Unable to read JSON file \(file): \(error.localizedDescription)",
            helpCommand: "call"
        )
    }
}

private func decodeUltraTermComputerUseJSONObject(_ source: String) throws -> Any {
    guard let data = source.data(using: .utf8) else {
        throw UltraTermComputerUseCLIError(message: "JSON input must be UTF-8 text", helpCommand: "call")
    }

    do {
        return try JSONSerialization.jsonObject(with: data)
    } catch {
        throw UltraTermComputerUseCLIError(
            message: "Invalid JSON input: \(error.localizedDescription)",
            helpCommand: "call"
        )
    }
}

func validatedQueryWindowID(_ value: Any?) throws -> CGWindowID? {
    guard let value else { return nil }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite, number.doubleValue >= 1,
          number.doubleValue <= Double(UInt32.max), number.doubleValue.rounded(.down) == number.doubleValue else {
        throw ComputerUseError.invalidArguments("window_id must be an integer from 1 to \(UInt32.max)")
    }
    return CGWindowID(number.doubleValue)
}

func validatedQueryString(_ value: Any?, key: String) throws -> String? {
    guard let value else { return nil }
    guard let string = value as? String, string.utf16.count <= 1000 else {
        throw ComputerUseError.invalidArguments("\(key) must be a string of at most 1000 UTF-16 code units")
    }
    return string
}

func validatedQueryExact(_ value: Any?) throws -> Bool {
    guard let value else { return false }
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
        throw ComputerUseError.invalidArguments("exact must be true or false")
    }
    return number.boolValue
}

func dispatchFailurePhase(for error: Error) -> ComputerUseErrorPhase {
    switch error as? ComputerUseError {
    case .invalidArguments, .unsupportedTool:
        return .preflight
    case .message(let text) where text.hasPrefix("Missing required argument:"):
        return .preflight
    default:
        return .execute
    }
}
