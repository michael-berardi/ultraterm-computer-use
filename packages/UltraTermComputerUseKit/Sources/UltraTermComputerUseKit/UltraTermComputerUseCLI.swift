import Foundation

public enum UltraTermComputerUseCLICommand: Equatable {
    case launchOnboarding
    case mcp
    case doctor(json: Bool = false)
    case lockedUseStatus(json: Bool)
    case lockedUseManagement(action: String, validation: Bool)
    case listApps
    case snapshot(app: String, textLimit: SnapshotTextLimit = .defaults, treeLimits: AccessibilityTreeLimits = .defaults, observation: SnapshotObservationOptions = .defaults)
    case call(UltraTermComputerUseCallInvocation)
    case turnEnded(payload: String?)
    case help(command: String?)
    case version
}

public enum UltraTermComputerUseCallInvocation: Equatable {
    case single(toolName: String, argumentsJSON: String?, argumentsFile: String?)
    case sequence(callsJSON: String?, callsFile: String?, interCallDelay: TimeInterval)
}

/// Every action already waits for the app to settle before it reads the result back, so a
/// sequence needs only a short gap between steps.
public let ultraTermComputerUseDefaultInterCallDelay: TimeInterval = 0.2

public func shouldUseMacOSAppAgentProxy(
    command: UltraTermComputerUseCLICommand,
    proxyDisabled: Bool,
    appBundleAvailable: Bool,
    runningFromLaunchServicesAppInstance: Bool
) -> Bool {
    guard !proxyDisabled, appBundleAvailable else {
        return false
    }

    switch command {
    case .launchOnboarding:
        return !runningFromLaunchServicesAppInstance
    case .mcp, .doctor, .lockedUseStatus, .listApps, .snapshot, .call:
        return true
    case .lockedUseManagement, .turnEnded, .help, .version:
        return false
    }
}

/// The app agent is launched through LaunchServices and does not share the
/// caller's working directory, so relative `--args-file` / `--calls-file`
/// paths are resolved here before the arguments are proxied.
public func resolvingUltraTermComputerUseCallFilePaths(
    _ arguments: [String],
    currentDirectory: String = FileManager.default.currentDirectoryPath
) -> [String] {
    guard arguments.first == "call" else { return arguments }
    var resolved = arguments
    var index = 1
    while index < arguments.count {
        let option = arguments[index]
        if ["--args-file", "--calls-file", "--args", "--calls", "--sleep"].contains(option) {
            guard index + 1 < arguments.count else { break }
            if option == "--args-file" || option == "--calls-file" {
                resolved[index + 1] = URL(
                    fileURLWithPath: arguments[index + 1],
                    relativeTo: URL(fileURLWithPath: currentDirectory, isDirectory: true)
                ).path
            }
            // Values are opaque, even when they happen to look like another option.
            index += 2
        } else {
            index += 1
        }
    }
    return resolved
}

public struct UltraTermComputerUseCLIError: LocalizedError, Equatable {
    public let message: String
    public let helpCommand: String?

    public init(message: String, helpCommand: String? = nil) {
        self.message = message
        self.helpCommand = helpCommand
    }

    public var errorDescription: String? {
        var lines = [message]
        lines.append("")
        lines.append(ultraTermComputerUseHelpText(command: helpCommand))
        return lines.joined(separator: "\n")
    }
}

public func parseUltraTermComputerUseCLI(arguments: [String]) throws -> UltraTermComputerUseCLICommand {
    guard let first = arguments.first else {
        return .launchOnboarding
    }

    switch first {
    case "-h", "--help", "help":
        if arguments.count > 2 {
            throw UltraTermComputerUseCLIError(message: "help accepts at most one command", helpCommand: nil)
        }

        return .help(command: arguments.dropFirst().first)
    case "-v", "--version", "version":
        guard arguments.count == 1 else {
            throw UltraTermComputerUseCLIError(message: "version does not accept any arguments", helpCommand: nil)
        }

        return .version
    case "mcp":
        return try parseSimpleCommand(name: "mcp", arguments: Array(arguments.dropFirst()), result: .mcp)
    case "doctor":
        if Array(arguments.dropFirst()) == ["--json"] {
            return .doctor(json: true)
        }
        return try parseSimpleCommand(name: "doctor", arguments: Array(arguments.dropFirst()), result: .doctor())
    case "locked-use":
        return try parseLockedUse(arguments: Array(arguments.dropFirst()))
    case "list-apps":
        return try parseSimpleCommand(name: "list-apps", arguments: Array(arguments.dropFirst()), result: .listApps)
    case "call":
        return try parseCall(arguments: Array(arguments.dropFirst()))
    case "turn-ended":
        return try parseTurnEnded(arguments: Array(arguments.dropFirst()))
    case "snapshot":
        return try parseSnapshot(arguments: Array(arguments.dropFirst()))
    default:
        if first.hasPrefix("-") {
            throw UltraTermComputerUseCLIError(message: "Unknown option: \(first)", helpCommand: nil)
        }

        throw UltraTermComputerUseCLIError(message: "Unknown command: \(first)", helpCommand: nil)
    }
}

public func ultraTermComputerUseHelpText(command: String? = nil) -> String {
    switch command {
    case nil:
        return """
        UltraTerm Computer Use

        Usage:
          ultraterm-computer-use [command] [options]
          ultraterm-computer-use

        Commands:
          mcp                  Start the stdio MCP server.
          doctor               Print permission status and launch onboarding if needed.
          list-apps            Print running or recently used apps.
          snapshot <app>       Print the current accessibility snapshot for an app.
          call <tool>           Call one tool, or run a JSON array of tool calls.
          turn-ended           Notify the running MCP process that the host turn ended.
          help [command]       Show general or command-specific help.
          version              Print the CLI version.

        Global options:
          -h, --help           Show help.
          -v, --version        Show version.

        Notes:
          Running without a command launches the permission onboarding app.
          Use `ultraterm-computer-use help <command>` for command-specific help.
        """
    case "mcp":
        return """
        Usage:
          ultraterm-computer-use mcp

        Start the stdio MCP server.
        """
    case "doctor":
        return """
        Usage:
          ultraterm-computer-use doctor [--json]

        Print the current Accessibility and Screen Recording permission state.
        If permissions are missing, this also launches the onboarding app.
        --json prints a permission snapshot without launching onboarding (macOS only).
        Read allGranted to determine readiness; missing permissions still exit successfully.
        """
    case "locked-use":
        return """
        Usage:
          ultraterm-computer-use locked-use status [--json]

        Read-only macOS session, permission, and system-component diagnostics.
          ultraterm-computer-use locked-use enable
          ultraterm-computer-use locked-use disable
          ultraterm-computer-use locked-use recover
          ultraterm-computer-use locked-use certify
          ultraterm-computer-use locked-use settings

        Installation and removal require macOS administrator authentication.
        enable installs signed components and requests macOS permissions.
        Automatic unlock requires an approved client and both display guards.
        recover restores an interrupted installation only after safe drainage.
        """
    case "list-apps":
        return """
        Usage:
          ultraterm-computer-use list-apps

        Print running apps plus recently used apps that can be targeted by Computer Use.
        """
    case "snapshot":
        return """
        Usage:
          ultraterm-computer-use snapshot [--include-ax true|false] [--include-screenshot true|false] [--text-limit <positive-int|max>] [--max-tree-nodes <positive-int>] [--max-tree-depth <positive-int>] <app>

        Arguments:
          <app>                App name or bundle identifier to inspect.

        Options:
          --include-ax         Include AX/focus/selection (true by default). False invalidates prior indexes.
          --include-screenshot Include screenshot capture (true by default). At least one channel must be true.
          --text-limit         Override the default 500 character text limit. Use `max` for full text.
          --max-tree-nodes     Override the default 1200 node accessibility tree budget.
          --max-tree-depth     Override the default 64 level accessibility tree depth.

        Print the current accessibility snapshot for the target app.
        """
    case "call":
        return """
        Usage:
          ultraterm-computer-use call <tool> [--args '<json-object>']
          ultraterm-computer-use call <tool> [--args-file <path>]
          ultraterm-computer-use call --calls '<json-array>' [--sleep <seconds>]
          ultraterm-computer-use call --calls-file <path> [--sleep <seconds>]

        Examples:
          ultraterm-computer-use call list_apps
          ultraterm-computer-use call get_app_state --args '{"app":"TextEdit"}'
          ultraterm-computer-use call --calls '[{"tool":"get_app_state","args":{"app":"TextEdit"}},{"tool":"press_key","args":{"app":"TextEdit","key":"Return"}}]'
          ultraterm-computer-use call --calls-file examples/textedit-overlay-seq.json --sleep 0.5

        The JSON array form keeps all calls in one process so follow-up actions
        can reuse the app state and element indices captured by get_app_state.
        Sequence execution stops after the first tool result with isError=true.
        Sequence runs sleep \(formatUltraTermComputerUseDelay(ultraTermComputerUseDefaultInterCallDelay)) between successful operations by default.
        """
    case "turn-ended":
        return """
        Usage:
          ultraterm-computer-use turn-ended [--previous-notify <argv>] [payload]

        Notify a running local MCP process that the current host turn has ended.
        Codex legacy notify appends the after-agent JSON payload as the last argument.
        """
    case "version":
        return """
        Usage:
          ultraterm-computer-use version
          ultraterm-computer-use --version
          ultraterm-computer-use -v

        Print the CLI version.
        """
    case "help":
        return """
        Usage:
          ultraterm-computer-use help [command]

        Show general help or help for a specific command.
        """
    default:
        return """
        Unknown help topic: \(command ?? "")

        \(ultraTermComputerUseHelpText())
        """
    }
}

private func parseSimpleCommand(
    name: String,
    arguments: [String],
    result: UltraTermComputerUseCLICommand
) throws -> UltraTermComputerUseCLICommand {
    if arguments.isEmpty {
        return result
    }

    if arguments.count == 1, let option = arguments.first, option == "-h" || option == "--help" {
        return .help(command: name)
    }

    throw UltraTermComputerUseCLIError(message: "\(name) does not accept any arguments", helpCommand: name)
}

private func parseTurnEnded(arguments: [String]) throws -> UltraTermComputerUseCLICommand {
    if arguments.count == 1, let option = arguments.first, option == "-h" || option == "--help" {
        return .help(command: "turn-ended")
    }

    var payload: String?
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]

        switch argument {
        case "--previous-notify":
            let valueIndex = index + 1
            guard valueIndex < arguments.count else {
                throw UltraTermComputerUseCLIError(message: "--previous-notify requires a value", helpCommand: "turn-ended")
            }
            index = valueIndex
        case "-h", "--help":
            throw UltraTermComputerUseCLIError(message: "turn-ended help must be requested as `ultraterm-computer-use turn-ended --help`", helpCommand: "turn-ended")
        default:
            if argument.hasPrefix("-") {
                throw UltraTermComputerUseCLIError(message: "Unknown turn-ended option: \(argument)", helpCommand: "turn-ended")
            }

            guard payload == nil else {
                throw UltraTermComputerUseCLIError(message: "turn-ended accepts at most one payload argument", helpCommand: "turn-ended")
            }

            payload = argument
        }

        index += 1
    }

    return .turnEnded(payload: payload)
}

private func parseSnapshot(arguments: [String]) throws -> UltraTermComputerUseCLICommand {
    if arguments.isEmpty {
        throw UltraTermComputerUseCLIError(message: "snapshot requires an app name or bundle identifier", helpCommand: "snapshot")
    }

    if arguments.count == 1, let value = arguments.first, value == "-h" || value == "--help" {
        return .help(command: "snapshot")
    }

    var observation = SnapshotObservationOptions.defaults
    var app: String?
    var textLimit = SnapshotTextLimit.defaults
    var maxTreeNodes: Int?
    var maxTreeDepth: Int?

    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--include-ax", "--include-screenshot":
            index += 1
            guard index < arguments.count, let value = Bool(arguments[index].lowercased()) else {
                throw UltraTermComputerUseCLIError(message: "\(argument) requires true or false", helpCommand: "snapshot")
            }
            if argument == "--include-ax" { observation.includeAX = value }
            else { observation.includeScreenshot = value }
        case "--text-limit":
            index += 1
            guard index < arguments.count else {
                throw UltraTermComputerUseCLIError(message: "--text-limit requires a positive integer or max value", helpCommand: "snapshot")
            }
            textLimit = try parseTextLimitOption(arguments[index], option: "--text-limit")
        case "--max-tree-nodes":
            index += 1
            guard index < arguments.count else {
                throw UltraTermComputerUseCLIError(message: "--max-tree-nodes requires a positive integer value", helpCommand: "snapshot")
            }
            maxTreeNodes = try parsePositiveIntegerOption(arguments[index], option: "--max-tree-nodes")
        case "--max-tree-depth":
            index += 1
            guard index < arguments.count else {
                throw UltraTermComputerUseCLIError(message: "--max-tree-depth requires a positive integer value", helpCommand: "snapshot")
            }
            maxTreeDepth = try parsePositiveIntegerOption(arguments[index], option: "--max-tree-depth")
        case "-h", "--help":
            throw UltraTermComputerUseCLIError(message: "snapshot help must be requested as `ultraterm-computer-use snapshot --help`", helpCommand: "snapshot")
        default:
            if argument.hasPrefix("-") {
                throw UltraTermComputerUseCLIError(message: "Unknown snapshot option: \(argument)", helpCommand: "snapshot")
            }

            guard app == nil else {
                throw UltraTermComputerUseCLIError(message: "snapshot accepts exactly one <app> argument", helpCommand: "snapshot")
            }

            app = argument
        }
        index += 1
    }

    guard let app else {
        throw UltraTermComputerUseCLIError(message: "snapshot requires an app name or bundle identifier", helpCommand: "snapshot")
    }

    guard observation.includeAX || observation.includeScreenshot else {
        throw UltraTermComputerUseCLIError(message: "At least one of include_ax or include_screenshot must be true", helpCommand: "snapshot")
    }
    return .snapshot(
        app: app,
        textLimit: textLimit,
        treeLimits: AccessibilityTreeLimits.defaults.replacing(
            maxNodeCount: maxTreeNodes,
            maxDepth: maxTreeDepth
        ),
        observation: observation
    )
}

private func parseTextLimitOption(_ value: String, option: String) throws -> SnapshotTextLimit {
    if value.lowercased() == SnapshotTextLimit.maxKeyword {
        return .max
    }

    guard let integer = Int(value), integer > 0 else {
        throw UltraTermComputerUseCLIError(message: "\(option) must be a positive integer or max", helpCommand: "snapshot")
    }
    return SnapshotTextLimit(maxCount: integer)
}

private func parsePositiveIntegerOption(_ value: String, option: String) throws -> Int {
    guard let integer = Int(value), integer > 0 else {
        throw UltraTermComputerUseCLIError(message: "\(option) must be a positive integer", helpCommand: "snapshot")
    }
    return integer
}

private func parseCall(arguments: [String]) throws -> UltraTermComputerUseCLICommand {
    if arguments.count == 1, let option = arguments.first, option == "-h" || option == "--help" {
        return .help(command: "call")
    }

    var toolName: String?
    var argumentsJSON: String?
    var argumentsFile: String?
    var callsJSON: String?
    var callsFile: String?
    var interCallDelay = ultraTermComputerUseDefaultInterCallDelay

    var index = 0
    while index < arguments.count {
        let argument = arguments[index]

        switch argument {
        case "--args":
            argumentsJSON = try parseOptionValue("--args", arguments: arguments, index: &index)
        case "--args-file":
            argumentsFile = try parseOptionValue("--args-file", arguments: arguments, index: &index)
        case "--calls":
            callsJSON = try parseOptionValue("--calls", arguments: arguments, index: &index)
        case "--calls-file":
            callsFile = try parseOptionValue("--calls-file", arguments: arguments, index: &index)
        case "--sleep":
            interCallDelay = try parseTimeIntervalOptionValue("--sleep", arguments: arguments, index: &index)
        case "-h", "--help":
            throw UltraTermComputerUseCLIError(message: "call help must be requested as `ultraterm-computer-use call --help`", helpCommand: "call")
        default:
            if argument.hasPrefix("-") {
                throw UltraTermComputerUseCLIError(message: "Unknown call option: \(argument)", helpCommand: "call")
            }

            guard toolName == nil else {
                throw UltraTermComputerUseCLIError(message: "call accepts at most one tool name", helpCommand: "call")
            }

            toolName = argument
        }

        index += 1
    }

    let hasSequenceInput = callsJSON != nil || callsFile != nil
    if hasSequenceInput {
        if callsJSON != nil, callsFile != nil {
            throw UltraTermComputerUseCLIError(message: "Use either --calls or --calls-file, not both", helpCommand: "call")
        }

        if toolName != nil || argumentsJSON != nil || argumentsFile != nil {
            throw UltraTermComputerUseCLIError(
                message: "call sequence does not accept a tool name, --args, or --args-file",
                helpCommand: "call"
            )
        }

        return .call(.sequence(
            callsJSON: callsJSON,
            callsFile: callsFile,
            interCallDelay: interCallDelay
        ))
    }

    if argumentsJSON != nil, argumentsFile != nil {
        throw UltraTermComputerUseCLIError(message: "Use either --args or --args-file, not both", helpCommand: "call")
    }

    if interCallDelay != ultraTermComputerUseDefaultInterCallDelay {
        throw UltraTermComputerUseCLIError(
            message: "--sleep is only supported with --calls or --calls-file",
            helpCommand: "call"
        )
    }

    guard let toolName else {
        throw UltraTermComputerUseCLIError(message: "call requires a tool name or --calls/--calls-file", helpCommand: "call")
    }

    return .call(.single(toolName: toolName, argumentsJSON: argumentsJSON, argumentsFile: argumentsFile))
}

private func parseOptionValue(
    _ option: String,
    arguments: [String],
    index: inout Int
) throws -> String {
    let valueIndex = index + 1
    guard valueIndex < arguments.count else {
        throw UltraTermComputerUseCLIError(message: "\(option) requires a value", helpCommand: "call")
    }

    index = valueIndex
    return arguments[valueIndex]
}

private func parseTimeIntervalOptionValue(
    _ option: String,
    arguments: [String],
    index: inout Int
) throws -> TimeInterval {
    let rawValue = try parseOptionValue(option, arguments: arguments, index: &index)
    guard let value = Double(rawValue), value.isFinite, value >= 0 else {
        throw UltraTermComputerUseCLIError(
            message: "\(option) requires a non-negative number of seconds",
            helpCommand: "call"
        )
    }

    return value
}

private func formatUltraTermComputerUseDelay(_ delay: TimeInterval) -> String {
    if delay.rounded() == delay {
        return "\(Int(delay))s"
    }

    return "\(delay)s"
}

private func parseLockedUse(arguments: [String]) throws -> UltraTermComputerUseCLICommand {
    if arguments == ["--help"] || arguments == ["-h"] || arguments == ["status", "--help"] {
        return .help(command: "locked-use")
    }
    if arguments == ["status"] { return .lockedUseStatus(json: false) }
    if arguments == ["status", "--json"] { return .lockedUseStatus(json: true) }
    if arguments.count == 1, let action = arguments.first,
       ["enable", "disable", "recover", "certify", "settings"].contains(action) {
        return .lockedUseManagement(action: action, validation: false)
    }
    throw UltraTermComputerUseCLIError(message: "Expected locked-use status, enable, disable, recover, certify, or settings", helpCommand: "locked-use")
}
