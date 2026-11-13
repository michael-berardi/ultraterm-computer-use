import Foundation

let computerUseNoWindowFoundMessage = "Apple event error -10005: cgWindowNotFound"

public enum ComputerUseError: Error, LocalizedError {
    case message(String)
    case unsupportedTool(String)
    case invalidArguments(String)
    case appNotFound(String)
    case ambiguousApp(String, candidates: [String])
    case permissionDenied(String)
    case stateUnavailable(String)
    /// The caller's state_id is not the current one for the app; nothing was sent.
    case staleState(String)

    public var errorDescription: String? {
        switch self {
        case .message(let value):
            return value
        case .unsupportedTool(let name):
            return "unsupportedTool(\"\(name)\")"
        case .invalidArguments(let message):
            return "invalidArguments(\"\(message)\")"
        case .appNotFound(let app):
            return "appNotFound(\"\(app)\")"
        case .ambiguousApp(let query, let candidates):
            let rendered = candidates.joined(separator: ", ")
            return "ambiguousApp(\"\(query)\", candidates: \(rendered))"
        case .permissionDenied(let message):
            return message
        case .stateUnavailable(let message):
            return message
        case .staleState(let message):
            return "stale_state: \(message)"
        }
    }

    var toolResultIsError: Bool {
        true
    }
}

extension ComputerUseError {
    static func missingArgument(_ name: String) -> ComputerUseError {
        .message("Missing required argument: \(name)")
    }
}

/// The stage of CLI/tool processing at which a failure occurred.
public enum ComputerUseErrorPhase: String, Equatable, Sendable {
    case parse
    case preflight
    case resolve
    case execute
}

/// Structured, machine-readable description of a Computer Use failure.
///
/// Serialized as `{code, phase, call_index, retryable, hint, candidates, message}`.
public struct ComputerUseErrorInfo: Equatable, Sendable {
    public let code: String
    public let phase: ComputerUseErrorPhase
    public let callIndex: Int?
    public let retryable: Bool
    public let hint: String?
    public let candidates: [String]
    public let message: String

    public init(
        code: String,
        phase: ComputerUseErrorPhase,
        callIndex: Int? = nil,
        retryable: Bool,
        hint: String? = nil,
        candidates: [String] = [],
        message: String
    ) {
        self.code = code
        self.phase = phase
        self.callIndex = callIndex
        self.retryable = retryable
        self.hint = hint
        self.candidates = candidates
        self.message = message
    }

    public var asDictionary: [String: Any] {
        var dictionary: [String: Any] = [
            "code": code,
            "phase": phase.rawValue,
            "retryable": retryable,
            "message": message,
        ]

        if let callIndex {
            dictionary["call_index"] = callIndex
        }
        if let hint {
            dictionary["hint"] = hint
        }
        if !candidates.isEmpty {
            dictionary["candidates"] = candidates
        }

        return dictionary
    }
}

/// Stable process exit mapping for CLI failures.
public enum UltraTermComputerUseExitStatus: Int32, Equatable, CaseIterable {
    case success = 0
    case failure = 1
    case usage = 2
    case permissionDenied = 3
    case appNotFound = 4
    case ambiguousTarget = 5
    case stateUnavailable = 6
    case staleState = 7
}

/// Build the structured error payload for any error thrown by Computer Use.
///
/// `phase` describes the stage the caller was in; `callIndex` is the 0-based
/// sequence index when the error surfaced while executing a call sequence.
public func computerUseErrorInfo(
    for error: Error,
    phase: ComputerUseErrorPhase,
    callIndex: Int? = nil
) -> ComputerUseErrorInfo {
    if let cliError = error as? UltraTermComputerUseCLIError {
        return ComputerUseErrorInfo(
            code: "usage",
            phase: phase,
            callIndex: callIndex,
            retryable: false,
            hint: cliError.helpCommand.map { "run `ultraterm-computer-use help \($0)`" },
            message: cliError.message
        )
    }

    guard let computerUseError = error as? ComputerUseError else {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return ComputerUseErrorInfo(
            code: "error",
            phase: phase,
            callIndex: callIndex,
            retryable: false,
            message: message
        )
    }

    switch computerUseError {
    case .message(let message) where message.hasPrefix("Missing required argument:"):
        return ComputerUseErrorInfo(
            code: "invalid_arguments",
            phase: phase,
            callIndex: callIndex,
            retryable: false,
            message: message
        )
    case .message(let message):
        return ComputerUseErrorInfo(
            code: "error",
            phase: phase,
            callIndex: callIndex,
            retryable: false,
            message: message
        )
    case .unsupportedTool(let name):
        return ComputerUseErrorInfo(
            code: "unsupported_tool",
            phase: phase,
            callIndex: callIndex,
            retryable: false,
            hint: "run `ultraterm-computer-use tools` to list supported tools",
            candidates: ToolDefinitions.all.map(\.name),
            message: computerUseError.errorDescription ?? "unsupportedTool(\"\(name)\")"
        )
    case .invalidArguments(let message):
        return ComputerUseErrorInfo(
            code: "invalid_arguments",
            phase: phase,
            callIndex: callIndex,
            retryable: false,
            message: "invalidArguments(\"\(message)\")"
        )
    case .appNotFound(let app):
        return ComputerUseErrorInfo(
            code: "app_not_found",
            phase: phase,
            callIndex: callIndex,
            retryable: true,
            hint: "run `ultraterm-computer-use targets --running-only` to list running apps, then retry",
            message: "appNotFound(\"\(app)\")"
        )
    case .ambiguousApp(let query, let candidates):
        return ComputerUseErrorInfo(
            code: "ambiguous_app",
            phase: phase,
            callIndex: callIndex,
            retryable: false,
            hint: "target an exact candidate with `pid:<pid>` or a bundle identifier",
            candidates: candidates,
            message: computerUseError.errorDescription ?? "ambiguousApp(\"\(query)\")"
        )
    case .permissionDenied(let message):
        return ComputerUseErrorInfo(
            code: "permission_denied",
            phase: phase,
            callIndex: callIndex,
            retryable: false,
            hint: "run `ultraterm-computer-use doctor` to review permissions",
            message: message
        )
    case .stateUnavailable(let message):
        return ComputerUseErrorInfo(
            code: "state_unavailable",
            phase: phase,
            callIndex: callIndex,
            retryable: true,
            hint: "call get_app_state to capture fresh state, then retry",
            message: message
        )
    case .staleState(let message):
        return ComputerUseErrorInfo(
            code: "stale_state",
            phase: phase,
            callIndex: callIndex,
            retryable: true,
            hint: "call get_app_state to refresh state_id, then retry",
            message: computerUseError.errorDescription ?? message
        )
    }
}

/// Map a structured error code (see `ComputerUseErrorInfo.code`) back to a
/// stable process exit status.
public func ultraTermComputerUseExitStatus(forStructuredCode code: String) -> UltraTermComputerUseExitStatus {
    switch code {
    case "usage", "unsupported_tool", "invalid_arguments":
        return .usage
    case "app_not_found":
        return .appNotFound
    case "ambiguous_app":
        return .ambiguousTarget
    case "permission_denied":
        return .permissionDenied
    case "state_unavailable":
        return .stateUnavailable
    case "stale_state":
        return .staleState
    default:
        return .failure
    }
}

/// Map any error thrown by the CLI to a stable process exit status.
public func ultraTermComputerUseExitStatus(for error: Error) -> UltraTermComputerUseExitStatus {
    if error is UltraTermComputerUseCLIError {
        return .usage
    }

    guard let computerUseError = error as? ComputerUseError else {
        return .failure
    }

    switch computerUseError {
    case .message(let message):
        return message.hasPrefix("Missing required argument:") ? .usage : .failure
    case .unsupportedTool, .invalidArguments:
        return .usage
    case .appNotFound:
        return .appNotFound
    case .ambiguousApp:
        return .ambiguousTarget
    case .permissionDenied:
        return .permissionDenied
    case .stateUnavailable:
        return .stateUnavailable
    case .staleState:
        return .staleState
    }
}
