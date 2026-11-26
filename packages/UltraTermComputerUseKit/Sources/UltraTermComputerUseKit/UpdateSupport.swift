import CommonCrypto
import Darwin
import Foundation

/// Update contract v1 for the signed macOS app (docs/updates.md). Copies inside an npm package are
/// updated by the npm launcher, so everything here is inactive unless this is a release app bundle.
public enum UpdateSupport {
    public static let tool = "ultraterm-computer-use"
    public static let checkInterval: TimeInterval = 24 * 60 * 60
    static let checkTimeout: TimeInterval = 4
    static let downloadTimeout: TimeInterval = 120
    static let userAgent = "ultraterm-computer-use-update-check"
    static let installerName = "install-ultraterm-computer-use.sh"
    /// Agent hosts that run shell commands; their output goes to a model, not a person.
    static let agentEnvironment = ["CLAUDECODE", "CODEX_SANDBOX", "GEMINI_CLI"]

    // MARK: Versions

    /// Stable `x.y.z` only (optional leading `v`); prereleases and garbage never count as newer.
    public static func parseVersion(_ raw: String?) -> [Int]? {
        guard let raw, raw.range(of: #"^v?\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else { return nil }
        let parts = raw.drop(while: { $0 == "v" }).split(separator: ".").compactMap { Int($0) }
        return parts.count == 3 ? parts : nil
    }

    public static func isNewer(_ latest: String?, than current: String?) -> Bool {
        guard let latest = parseVersion(latest), let current = parseVersion(current) else { return false }
        return latest.lexicographicallyPrecedes(current) == false && latest != current
    }

    // MARK: Where this copy runs

    /// The GitHub owner/repo the release build stamps into Info.plist. Nil for development builds,
    /// the placeholder, and app bundles inside an npm package.
    public static func releaseSlug(bundlePath: String, infoValue: Any?) -> String? {
        guard bundlePath.hasSuffix(".app"), !bundlePath.contains("/node_modules/"),
              let slug = infoValue as? String,
              slug.range(of: #"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil,
              !slug.hasPrefix("your-org/") else { return nil }
        return slug
    }

    public static func releaseSlug(bundle: Bundle = .main) -> String? {
        releaseSlug(bundlePath: bundle.bundlePath, infoValue: bundle.object(forInfoDictionaryKey: "UltraTermComputerUseReleaseRepo"))
    }

    public static func stateURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Caches/\(tool)/update-state.json")
    }

    // MARK: When to check and notify

    public static func checksAllowed(environment: [String: String], interactive: Bool) -> Bool {
        guard interactive, (environment["CI"] ?? "").isEmpty else { return false }
        if let optOut = environment["ULTRATERM_COMPUTER_USE_NO_UPDATE_CHECK"], !optOut.isEmpty, optOut != "0" { return false }
        if agentEnvironment.contains(where: { !(environment[$0] ?? "").isEmpty }) { return false }
        // `"updates": {"check": false}` in config.json is the persistent switch.
        guard let url = try? OCUConfiguration.fileURL(environment: environment),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let check = (root["updates"] as? [String: Any])?["check"] as? Bool else { return true }
        return check
    }

    public static func checkDue(_ state: UpdateState, now: Date = Date()) -> Bool {
        guard let last = parseDate(state.lastCheckAt) else { return true }
        let age = now.timeIntervalSince(last)
        return !(age >= 0 && age < checkInterval)
    }

    public static func noticeDue(_ state: UpdateState, current: String, now: Date = Date()) -> Bool {
        guard let latest = state.latestVersion, isNewer(latest, than: current) else { return false }
        if let skipped = state.skippedVersion, !isNewer(latest, than: skipped) { return false }
        if state.lastShownVersion == latest, let shown = parseDate(state.lastShownAt),
           now.timeIntervalSince(shown) < checkInterval {
            return false
        }
        return true
    }

    /// Automatic installs are not offered here (installing the package needs an administrator
    /// password), so the second line only names skip.
    public static func noticeText(current: String, latest: String, environment: [String: String]) -> String {
        let hint = "skip: \(tool) update --skip"
        return "\(tool) \(latest) available (you have \(current)) · run: \(tool) update\n"
            + ((environment["NO_COLOR"] ?? "").isEmpty ? "\u{1B}[2m\(hint)\u{1B}[22m" : hint)
    }

    // MARK: Check

    public enum CheckResult: Equatable, Sendable {
        case available(version: String, notes: String)
        case current
        case failed(cause: String)
    }

    /// One anonymous GET; the result or the failure cause is recorded either way.
    public static func check(
        slug: String,
        current: String,
        stateURL: URL,
        fetch: (URL, TimeInterval) throws -> Data = get,
        now: Date = Date()
    ) -> CheckResult {
        var state = UpdateState.read(stateURL)
        state.lastCheckAt = formatDate(now)
        do {
            let data = try fetch(URL(string: "https://api.github.com/repos/\(slug)/releases/latest")!, checkTimeout)
            guard let release = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw UpdateFailure("the release record is not JSON")
            }
            let stable = release["draft"] as? Bool != true && release["prerelease"] as? Bool != true
            let version = stable ? parseVersion(release["tag_name"] as? String)?.map(String.init).joined(separator: ".") : nil
            state.latestVersion = version
            state.lastError = nil
            state.write(stateURL)
            guard let version, isNewer(version, than: current) else { return .current }
            let notes = ((release["body"] as? String) ?? "").split(whereSeparator: \.isNewline).prefix(6).joined(separator: "\n")
            return .available(version: version, notes: notes)
        } catch {
            let cause = describe(error)
            state.lastError = "check failed: \(cause)"
            state.write(stateURL)
            return .failed(cause: cause)
        }
    }

    // MARK: Install

    /// Downloads the release's signed-package installer into a private temp folder (removed on every
    /// path), checks it against the release SHA256SUMS, and runs it. That installer verifies the
    /// package checksum, Developer ID team, notarization and designated requirement before
    /// `installer` replaces the app.
    public static func install(
        version: String,
        slug: String,
        fetch: (URL, TimeInterval) throws -> Data = get,
        runInstaller: (URL) throws -> Void = runScript
    ) throws {
        let base = URL(string: "https://github.com/\(slug)/releases/download/v\(version)")!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(tool)-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let sums = String(decoding: try fetch(base.appendingPathComponent("SHA256SUMS"), downloadTimeout), as: UTF8.self)
        let script = try fetch(base.appendingPathComponent(installerName), downloadTimeout)
        try verifyChecksum(script, sums: sums, name: installerName)
        let file = directory.appendingPathComponent(installerName)
        try script.write(to: file)
        try runInstaller(file)
    }

    public static func verifyChecksum(_ data: Data, sums: String, name: String) throws {
        let expected = sums.split(whereSeparator: \.isNewline).lazy.compactMap { line -> String? in
            let fields = line.split(separator: " ", maxSplits: 1)
            guard fields.count == 2, fields[0].count == 64 else { return nil }
            let file = fields[1].drop(while: { $0 == " " || $0 == "*" })
            return file == name ? fields[0].lowercased() : nil
        }.first
        guard let expected else { throw UpdateFailure("SHA256SUMS has no entry for \(name); nothing was installed") }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        guard digest.map({ String(format: "%02x", $0) }).joined() == expected else {
            throw UpdateFailure("checksum mismatch for \(name); nothing was installed")
        }
    }

    // MARK: The update command

    public static func run(
        _ action: UpdateCommandAction,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        slug: String? = releaseSlug(),
        current: String = resolvedUltraTermComputerUseVersion(),
        interactive: Bool = isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0,
        fetch: (URL, TimeInterval) throws -> Data = get,
        runInstaller: (URL) throws -> Void = runScript,
        ask: (String) -> String = askLine,
        output: (String) -> Void = { print($0) },
        errorOutput: (String) -> Void = { FileHandle.standardError.write(Data("\($0)\n".utf8)) },
        now: Date = Date()
    ) -> Int32 {
        let stateURL = stateURL(environment: environment)
        switch action {
        case .help:
            output(updateHelpText())
            return 0
        case .auto("on"):
            errorOutput("\(tool) update: automatic updates are not available for the signed macOS app; installing needs an administrator password")
            return 1
        case .auto:
            output("automatic updates: off")
            return 0
        case .rollback:
            errorOutput("\(tool) update: rollback is not available for the signed macOS app; install an earlier package with \(installerName) --local")
            return 1
        default:
            break
        }
        guard let slug else {
            errorOutput("\(tool) update: this copy is a development build or part of an npm package; update the signed app or use the npm launcher")
            return 1
        }
        let result = check(slug: slug, current: current, stateURL: stateURL, fetch: fetch, now: now)
        if action == .refresh { return 0 }
        switch result {
        case let .failed(cause):
            errorOutput("\(tool) update: check failed: \(cause)")
            return 1
        case .current:
            output("\(tool) \(current) is current")
            return 0
        case let .available(version, notes):
            switch action {
            case .check:
                output("\(tool) \(version) available (you have \(current))")
                return 10
            case .skip:
                var state = UpdateState.read(stateURL)
                state.skippedVersion = version
                state.write(stateURL)
                output("Skipped \(version). A newer release will notify again.")
                return 0
            default:
                output("\(tool) \(current) → \(version)")
                if !notes.isEmpty { output(notes) }
                if interactive, !["", "y", "yes"].contains(ask("Install \(version) now? [Y/n] ")) { return 0 }
                do {
                    try install(version: version, slug: slug, fetch: fetch, runInstaller: runInstaller)
                } catch {
                    var state = UpdateState.read(stateURL)
                    state.lastError = "install of \(version) failed: \(describe(error))"
                    state.write(stateURL)
                    errorOutput("\(tool) update: install failed: \(describe(error))")
                    return 1
                }
                output("Installed \(version). It applies the next time UltraTerm Computer Use starts.")
                return 0
            }
        }
    }

    /// Never after MCP (its stdout is the protocol) or the commands no person is waiting on.
    public static func notifies(after command: UltraTermComputerUseCLICommand) -> Bool {
        switch command {
        case .mcp, .update, .turnEnded, .launchOnboarding: return false
        default: return true
        }
    }

    /// Called after a successful command. Never waits on the network: a due check starts a detached
    /// `update --refresh` process, and the notice uses what the last check recorded.
    public static func afterCommand(
        _ command: UltraTermComputerUseCLICommand,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        interactive: Bool = isatty(STDOUT_FILENO) != 0 && isatty(STDERR_FILENO) != 0,
        slug: String? = releaseSlug(),
        current: String = resolvedUltraTermComputerUseVersion(),
        startRefresh: () -> Void = { spawnDetached(Bundle.main.executablePath ?? CommandLine.arguments[0], ["update", "--refresh"]) },
        errorOutput: (String) -> Void = { FileHandle.standardError.write(Data("\($0)\n".utf8)) },
        now: Date = Date()
    ) {
        guard notifies(after: command), slug != nil, !arguments.contains("--json"),
              checksAllowed(environment: environment, interactive: interactive) else { return }
        let stateURL = stateURL(environment: environment)
        var state = UpdateState.read(stateURL)
        if checkDue(state, now: now) {
            // Claim today's check first, so concurrent commands do not start more than one.
            state.lastCheckAt = formatDate(now)
            state.write(stateURL)
            startRefresh()
        }
        guard noticeDue(state, current: current, now: now), let latest = state.latestVersion else { return }
        errorOutput(noticeText(current: current, latest: latest, environment: environment))
        state.lastShownVersion = latest
        state.lastShownAt = formatDate(now)
        state.write(stateURL)
    }

    // MARK: Helpers

    struct UpdateFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? URLError, error.code == .timedOut { return "timed out" }
        return error.localizedDescription
    }

    private final class Box: @unchecked Sendable { var result: Result<Data, Error> = .failure(URLError(.unknown)) }

    /// An ephemeral session: no cookies, no URL cache files, one total time limit.
    public static func get(_ url: URL, timeout: TimeInterval) throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            if let error {
                box.result = .failure(error)
            } else if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
                box.result = .failure(UpdateFailure("HTTP \(status)"))
            } else {
                box.result = .success(data ?? Data())
            }
            done.signal()
        }.resume()
        done.wait()
        return try box.result.get()
    }

    public static func runScript(_ file: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [file.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateFailure("the installer exited with \(process.terminationStatus)") }
    }

    public static func askLine(_ question: String) -> String {
        print(question, terminator: "")
        fflush(stdout)
        return (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Starts a process in its own session with no terminal I/O, so Ctrl-C in the shell never reaches it.
    public static func spawnDetached(_ path: String, _ arguments: [String]) {
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        posix_spawnattr_init(&attributes)
        posix_spawn_file_actions_init(&actions)
        defer {
            posix_spawnattr_destroy(&attributes)
            posix_spawn_file_actions_destroy(&actions)
        }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        for descriptor: Int32 in 0...2 {
            posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == 0 ? O_RDONLY : O_WRONLY, 0)
        }
        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid = pid_t()
        _ = posix_spawn(&pid, path, &actions, &attributes, argv, environ)
    }

    static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Accepts the launcher's `toISOString()` form (fractional seconds) and the plain form.
    static func parseDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// The one small owner-only state file, shared with the npm launcher's copy of the same keys.
public struct UpdateState: Codable, Equatable, Sendable {
    public var lastCheckAt: String?
    public var latestVersion: String?
    public var lastError: String?
    public var skippedVersion: String?
    public var lastShownVersion: String?
    public var lastShownAt: String?
    public var autoInstall = false
    public var autoAsked = false
    public var autoFailedVersion: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? { (try? values.decodeIfPresent(String.self, forKey: key)) ?? nil }
        func flag(_ key: CodingKeys) -> Bool { (try? values.decodeIfPresent(Bool.self, forKey: key)) ?? false }
        lastCheckAt = text(.lastCheckAt)
        latestVersion = text(.latestVersion)
        lastError = text(.lastError)
        skippedVersion = text(.skippedVersion)
        lastShownVersion = text(.lastShownVersion)
        lastShownAt = text(.lastShownAt)
        autoInstall = flag(.autoInstall)
        autoAsked = flag(.autoAsked)
        autoFailedVersion = text(.autoFailedVersion)
    }

    public static func read(_ url: URL) -> UpdateState {
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(UpdateState.self, from: data) else {
            return UpdateState()
        }
        return state
    }

    /// Atomic: a 0600 temp file in the same folder, renamed over the old one.
    public func write(_ url: URL) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(self) else { return }
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if Darwin.rename(temporary.path, url.path) != 0 { try? FileManager.default.removeItem(at: temporary) }
    }
}

public enum UpdateCommandAction: Equatable, Sendable {
    case install
    case check
    case skip
    case auto(String)
    case rollback
    /// Internal: the detached background check started by `afterCommand`.
    case refresh
    case help
}

public func parseUpdateCommand(_ arguments: [String]) throws -> UpdateCommandAction {
    switch arguments {
    case []: return .install
    case ["--check"]: return .check
    case ["--skip"]: return .skip
    case ["--rollback"]: return .rollback
    case ["--refresh"]: return .refresh
    case ["-h"], ["--help"]: return .help
    case ["--auto", "on"], ["--auto", "off"], ["--auto", "status"]: return .auto(arguments[1])
    default:
        throw UltraTermComputerUseCLIError(message: "update takes one of --check, --skip, --auto on|off|status, --rollback", helpCommand: "update")
    }
}

public func updateHelpText() -> String {
    """
    Usage:
      ultraterm-computer-use update             Show the newer release and install it after verification.
      ultraterm-computer-use update --check     Report only: exit 0 current, 10 update available, 1 check failed.
      ultraterm-computer-use update --skip      Hide this version's notice until a newer one appears.
      ultraterm-computer-use update --auto status
                                                Automatic installs are off: the package needs an administrator password.

    Checks are anonymous and at most daily. ULTRATERM_COMPUTER_USE_NO_UPDATE_CHECK=1, or
    "updates": {"check": false} in the config file, turns them off. See docs/updates.md.
    """
}
