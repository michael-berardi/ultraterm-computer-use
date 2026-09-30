import AppKit
import Darwin
import Foundation
import UltraTermComputerUseKit

private let appAgentCommand = "__ultraterm-computer-use-app-agent"
private let appAgentDisableEnvironmentKey = "ULTRATERM_COMPUTER_USE_DISABLE_APP_AGENT_PROXY"
// The kernel's start time, not first-use time: Swift globals initialize lazily,
// which made an agent launched before an update look newer than the update.
private let appAgentProcessStartDate = Date(
    timeIntervalSince1970: AppAgentProcess.startTime(getpid()) ?? Date().timeIntervalSince1970
)

enum MacOSAppAgentProxy {
    static func isAgentInvocation(arguments: [String]) -> Bool {
        arguments.first == appAgentCommand
    }

    @MainActor
    static func runAgent(arguments: [String]) throws {
        guard arguments.count == 2 else {
            throw UltraTermComputerUseCLIError(message: "\(appAgentCommand) requires a socket path")
        }

        try MacOSAppAgentRuntime.run(socketPath: arguments[1])
    }

    static func shouldProxy(command: UltraTermComputerUseCLICommand) -> Bool {
        shouldUseMacOSAppAgentProxy(
            command: command,
            proxyDisabled: proxyDisabled,
            appBundleAvailable: PermissionSupport.currentAppBundleURL() != nil,
            runningFromLaunchServicesAppInstance: isRunningFromLaunchServicesAppInstance
        )
    }

    @MainActor
    static func runProxy(command: UltraTermComputerUseCLICommand, arguments: [String]) throws -> Int32 {
        let socketPath = defaultSocketPath()
        let client = try connectOrLaunchAgent(socketPath: socketPath)

        switch command {
        case .mcp:
            try proxyMCP(client: client)
            return EXIT_SUCCESS
        default:
            let response = try sendCLIRequest(arguments: arguments, client: client)
            if !response.stdout.isEmpty {
                FileHandle.standardOutput.write(Data(response.stdout.utf8))
            }
            if !response.stderr.isEmpty {
                FileHandle.standardError.write(Data(response.stderr.utf8))
            }
            return response.exitCode
        }
    }

    private static var proxyDisabled: Bool {
        let value = ProcessInfo.processInfo.environment[appAgentDisableEnvironmentKey]?.lowercased()
        return value == "1" || value == "true" || value == "yes" || value == "on"
    }

    private static var isRunningFromUltraTermComputerUseAppBundle: Bool {
        Bundle.main.bundleURL.standardizedFileURL.pathExtension == "app"
            && PermissionSupport.isUltraTermComputerUseBundleIdentifier(Bundle.main.bundleIdentifier)
    }

    private static var isRunningFromLaunchServicesAppInstance: Bool {
        isRunningFromUltraTermComputerUseAppBundle && getppid() == 1
    }

    private static func defaultSocketPath() -> String {
        appAgentSocketPath(
            temporaryDirectory: FileManager.default.temporaryDirectory,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            environment: ProcessInfo.processInfo.environment
        )
    }

    @MainActor
    private static func connectOrLaunchAgent(socketPath: String) throws -> AppAgentSocketClient {
        guard let appURL = PermissionSupport.currentAppBundleURL() else {
            throw UltraTermComputerUseCLIError(message: "Unable to locate UltraTerm Computer Use.app for app-scoped macOS permissions.")
        }

        // Serialize probe/retire/unlink/launch/wait across every launcher, so two
        // concurrent invocations cannot both start an agent.
        return try withAgentStartupLock(socketPath: socketPath) {
            let executablePath = Bundle.main.executableURL?.standardizedFileURL.path ?? ""
            // A busy or slow agent is not a stale one: retry before replacing it.
            let retryDeadline = Date().addingTimeInterval(10)
            var outdated = false
            repeat {
                if let client = AppAgentSocketClient.connect(path: socketPath) {
                    client.setControlTimeout(seconds: 5)
                    switch try? client.isCurrentAgent(for: appURL) {
                    case true?:
                        client.setControlTimeout(seconds: 0)
                        return client
                    case false?:
                        outdated = true
                        _ = try? client.request(["kind": "terminate"])
                    case nil:
                        break
                    }
                }
                if outdated { break }
                // A missing socket file cannot come back: its owner is unreachable.
                if AppAgentFileIdentity.of(path: socketPath) == nil { break }
                if AppAgentProcess.liveOwner(socketPath: socketPath, executablePath: executablePath) == nil,
                   !AppAgentSocketClient.probe(path: socketPath) {
                    break
                }
                Thread.sleep(forTimeInterval: 0.25)
            } while Date() < retryDeadline

            // Never leave the previous agent running beside a new one.
            if let owner = AppAgentProcess.liveOwner(socketPath: socketPath, executablePath: executablePath),
               owner.pid != getpid() {
                let reason = outdated ? "outdated" : "unreachable for 10 s"
                let outcome = AppAgentProcess.retire(owner.pid)
                appAgentLog("launcher retired agent \(owner.pid) (\(reason)): \(outcome)")
                if AppAgentProcess.isAlive(owner.pid) {
                    throw UltraTermComputerUseCLIError(message: "UltraTerm Computer Use.app agent \(owner.pid) is \(reason) and did not exit; not starting a second agent.")
                }
            } else if AppAgentSocketClient.probe(path: socketPath), !outdated {
                throw UltraTermComputerUseCLIError(message: "An UltraTerm Computer Use.app agent owns \(socketPath) but is not answering; not starting a second agent.")
            }
            unlink(socketPath)
            return try launchAgent(appURL: appURL, socketPath: socketPath)
        }
    }

    @MainActor
    private static func launchAgent(appURL: URL, socketPath: String) throws -> AppAgentSocketClient {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = [appAgentCommand, socketPath]
        configuration.activates = false
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in }

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let client = AppAgentSocketClient.connect(path: socketPath) {
                return client
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        throw UltraTermComputerUseCLIError(message: "Timed out waiting for UltraTerm Computer Use.app agent to start.")
    }

    private static func withAgentStartupLock<T>(socketPath: String, _ body: () throws -> T) throws -> T {
        let lockPath = socketPath + ".startup.lock"
        let lockFD = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else {
            // The lock is a best-effort guard; never fail the command over it.
            return try body()
        }
        defer { close(lockFD) }
        // The agent never takes this lock, so waiting for it cannot deadlock.
        flock(lockFD, LOCK_EX)
        defer { flock(lockFD, LOCK_UN) }
        return try body()
    }

    private static func proxyMCP(client: AppAgentSocketClient) throws {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            let response = try client.request([
                "kind": "mcp",
                "line": line,
                "environment": proxiedEnvironment(),
            ])

            if let responseLine = response["response"] as? String {
                FileHandle.standardOutput.write(Data((responseLine + "\n").utf8))
            }
        }
    }

    private static func sendCLIRequest(arguments: [String], client: AppAgentSocketClient) throws -> CLIProxyResponse {
        let response = try client.request([
            "kind": "cli",
            "arguments": arguments,
            "environment": proxiedEnvironment(),
        ])

        return CLIProxyResponse(
            stdout: response["stdout"] as? String ?? "",
            stderr: response["stderr"] as? String ?? "",
            exitCode: Int32(response["exitCode"] as? Int ?? 1)
        )
    }

    private static func proxiedEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment.filter { key, _ in
            key.hasPrefix("ULTRATERM_COMPUTER_USE_")
        }
    }
}

private struct CLIProxyResponse {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

@MainActor
private final class MacOSAppAgentRuntime: NSObject, NSApplicationDelegate {
    private let socketPath: String
    private var listener: AppAgentSocketListener?
    private var turnEndedObserver: NSObjectProtocol?

    private init(socketPath: String) {
        self.socketPath = socketPath
    }

    static func run(socketPath: String) throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        let delegate = MacOSAppAgentRuntime(socketPath: socketPath)
        application.delegate = delegate
        application.run()
    }

    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SIGTERM (a launcher retiring this agent, or `kill`) cleans up like quit.
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler {
            appAgentLog("agent received SIGTERM")
            NSApp.terminate(nil)
        }
        termination.resume()
        terminationSignal = termination

        turnEndedObserver = DistributedNotificationCenter.default().addObserver(
            forName: ultraTermComputerUseTurnEndedNotificationName,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                resetUltraTermComputerUseVisualCursor()
            }
        }

        do {
            let listener = try AppAgentSocketListener(path: socketPath) { _ in
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            }
            self.listener = listener
            listener.start()
        } catch {
            writeAgentError(error)
            appAgentLog("agent failed to start: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))")
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let turnEndedObserver {
            DistributedNotificationCenter.default().removeObserver(turnEndedObserver)
        }
        listener?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func writeAgentError(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

private enum AppAgentConnections {
    private static let lock = NSLock()
    // Guarded by lock.
    nonisolated(unsafe) private static var active = 0

    static var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    static func started() { lock.lock(); active += 1; lock.unlock() }
    static func finished() { lock.lock(); active -= 1; lock.unlock() }
}

private final class AppAgentSocketListener: @unchecked Sendable {
    private let path: String
    private let pidPath: String
    private let socketFD: Int32
    private var boundSocketIdentity: AppAgentFileIdentity?
    private var running = true
    private var watchdog: DispatchSourceTimer?
    private let onLostOwnership: @Sendable (String) -> Void

    init(path: String, onLostOwnership: @escaping @Sendable (String) -> Void) throws {
        self.path = path
        self.pidPath = AppAgentPidRecord.path(forSocket: path)
        self.onLostOwnership = onLostOwnership
        // Never replace a socket a live agent still owns: that orphaned it.
        if AppAgentSocketClient.probe(path: path) {
            throw UltraTermComputerUseCLIError(message: "Another UltraTerm Computer Use.app agent already owns the socket at \(path)")
        }
        unlink(path)

        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        try withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            try pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { buffer in
                let bytes = Array(path.utf8)
                guard bytes.count < pathCapacity else {
                    throw UltraTermComputerUseCLIError(message: "Socket path is too long: \(path)")
                }
                for index in 0..<bytes.count {
                    buffer[index] = CChar(bitPattern: bytes[index])
                }
                buffer[bytes.count] = 0
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(socketFD)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        guard listen(socketFD, 16) == 0 else {
            close(socketFD)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        guard chmod(path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            close(socketFD)
            unlink(path)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        boundSocketIdentity = AppAgentFileIdentity.of(path: path)
        writePidRecord()
    }

    private var pidRecord: AppAgentPidRecord {
        AppAgentPidRecord(pid: getpid(), startTime: appAgentProcessStartDate.timeIntervalSince1970)
    }

    private func writePidRecord() {
        try? Data(pidRecord.encoded.utf8).write(to: URL(fileURLWithPath: pidPath), options: .atomic)
        chmod(pidPath, mode_t(S_IRUSR | S_IWUSR))
    }

    private var ownsSocketPath: Bool {
        appAgentLostOwnershipReason(
            boundIdentity: boundSocketIdentity,
            currentIdentity: AppAgentFileIdentity.of(path: path)
        ) == nil
    }

    /// Every 5 s: exit once this agent no longer owns its socket path (after
    /// its clients finish), restore a purged pid record, and refresh both files
    /// hourly so the ~3-day `$TMPDIR` purge never removes them.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        var ticks = 0
        var reportedWaiting = false
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            ticks += 1
            if let reason = appAgentLostOwnershipReason(
                boundIdentity: self.boundSocketIdentity,
                currentIdentity: AppAgentFileIdentity.of(path: self.path)
            ) {
                let clients = AppAgentConnections.count
                if clients == 0 {
                    appAgentLog("agent exiting: \(reason)")
                    self.onLostOwnership(reason)
                } else if !reportedWaiting {
                    reportedWaiting = true
                    appAgentLog("agent lost its socket (\(reason)); exiting after \(clients) client(s) finish")
                }
                return
            }
            if AppAgentPidRecord.read(socketPath: self.path) != self.pidRecord {
                self.writePidRecord()
            }
            if ticks % 720 == 0 {
                touchAppAgentFiles([self.path, self.pidPath])
            }
        }
        watchdog = timer
        timer.resume()
    }

    func start() {
        appAgentLog("agent listening on \(path)")
        startWatchdog()
        Thread.detachNewThread {
            self.acceptLoop()
        }
    }

    func stop() {
        running = false
        watchdog?.cancel()
        // Remove only what is still ours: a replacement agent may already have
        // bound the same path, and deleting it orphaned that agent.
        let owned = ownsSocketPath
        if AppAgentPidRecord.read(socketPath: path) == pidRecord {
            unlink(pidPath)
        }
        close(socketFD)
        if owned {
            unlink(path)
        }
    }

    private func acceptLoop() {
        while running {
            let clientFD = accept(socketFD, nil, nil)
            guard clientFD >= 0 else {
                if running {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                continue
            }

            AppAgentConnections.started()
            Thread.detachNewThread {
                AppAgentConnection(fileDescriptor: clientFD).run()
                AppAgentConnections.finished()
            }
        }
    }
}

private final class AppAgentConnection: @unchecked Sendable {
    private let fileDescriptor: Int32
    private let server = StdioMCPServer()

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    func run() {
        guard let file = fdopen(fileDescriptor, "r+") else {
            close(fileDescriptor)
            return
        }
        defer { fclose(file) }

        while let line = readAgentLine(file) {
            let response = handle(requestLine: line)
            writeAgentLine(response, to: file)
        }
    }

    private func handle(requestLine: String) -> [String: Any] {
        do {
            guard let request = try JSONSerialization.jsonObject(with: Data(requestLine.utf8)) as? [String: Any],
                  let kind = request["kind"] as? String
            else {
                return ["error": "Invalid app-agent request"]
            }

            switch kind {
            case "agentInfo":
                return [
                    "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
                    "bundleURL": Bundle.main.bundleURL.standardizedFileURL.path,
                    "executableURL": Bundle.main.executableURL?.standardizedFileURL.path ?? "",
                    "processStartTime": appAgentProcessStartDate.timeIntervalSince1970,
                ]
            case "terminate":
                Task { @MainActor in
                    NSApp.terminate(nil)
                }
                return ["ok": true]
            case "mcp":
                let line = request["line"] as? String ?? ""
                let environment = request["environment"] as? [String: String] ?? [:]
                let response = AppAgentEnvironment.withOverrides(environment) {
                    server.handle(line: line)
                }
                if let response {
                    return ["response": response]
                }
                return ["response": NSNull()]
            case "cli":
                let arguments = request["arguments"] as? [String] ?? []
                let environment = request["environment"] as? [String: String] ?? [:]
                let response = AppAgentEnvironment.withOverrides(environment) {
                    runCLI(arguments: arguments)
                }
                return [
                    "stdout": response.stdout,
                    "stderr": response.stderr,
                    "exitCode": Int(response.exitCode),
                ]
            default:
                return ["error": "Unknown app-agent request kind: \(kind)"]
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return ["error": message]
        }
    }

    private func runCLI(arguments: [String]) -> CLIProxyResponse {
        do {
            let command = try parseUltraTermComputerUseCLI(arguments: arguments)

            switch command {
            case .launchOnboarding:
                let permissions = PermissionDiagnostics.current()
                if !permissions.allGranted {
                    Task { @MainActor in
                        PermissionOnboardingApp.present()
                    }
                }
                return CLIProxyResponse(stdout: "", stderr: "", exitCode: EXIT_SUCCESS)

            case .doctor:
                let permissions = PermissionDiagnostics.current()
                if !permissions.missingPermissions.isEmpty {
                    Task { @MainActor in
                        PermissionOnboardingApp.present()
                    }
                }
                return CLIProxyResponse(stdout: permissions.summary + "\n", stderr: "", exitCode: EXIT_SUCCESS)

            case .listApps:
                let service = ComputerUseService()
                return CLIProxyResponse(stdout: (service.listApps().primaryText ?? "") + "\n", stderr: "", exitCode: EXIT_SUCCESS)

            case let .snapshot(app, textLimit, treeLimits):
                let service = ComputerUseService()
                let text = try service.getAppState(app: app, textLimit: textLimit, treeLimits: treeLimits).primaryText ?? ""
                return CLIProxyResponse(stdout: text + "\n", stderr: "", exitCode: EXIT_SUCCESS)

            case let .call(invocation):
                let output = try runUltraTermComputerUseCall(invocation)
                return CLIProxyResponse(
                    stdout: try output.jsonText() + "\n",
                    stderr: "",
                    exitCode: output.hasToolError ? EXIT_FAILURE : EXIT_SUCCESS
                )

            default:
                return CLIProxyResponse(stdout: "", stderr: "Unsupported proxied command.\n", exitCode: EXIT_FAILURE)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return CLIProxyResponse(stdout: "", stderr: message + "\n", exitCode: EXIT_FAILURE)
        }
    }
}

private enum AppAgentEnvironment {
    private static let lock = NSLock()

    static func withOverrides<T>(_ overrides: [String: String], _ body: () throws -> T) rethrows -> T {
        guard !overrides.isEmpty else {
            return try body()
        }

        lock.lock()
        defer { lock.unlock() }

        let previousValues = Dictionary(
            uniqueKeysWithValues: overrides.keys.map { key in
                (key, ProcessInfo.processInfo.environment[key])
            }
        )
        for (key, value) in overrides {
            setenv(key, value, 1)
        }

        defer {
            for (key, previousValue) in previousValues {
                if let previousValue {
                    setenv(key, previousValue, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        return try body()
    }
}

private final class AppAgentSocketClient: @unchecked Sendable {
    private let file: UnsafeMutablePointer<FILE>

    private init(file: UnsafeMutablePointer<FILE>) {
        self.file = file
    }

    deinit {
        fclose(file)
    }

    /// Bound control requests (agentInfo, terminate) so a wedged agent cannot
    /// hang the launcher; 0 restores blocking reads for MCP/CLI traffic.
    func setControlTimeout(seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fileno(file), SOL_SOCKET, SO_RCVTIMEO, &timeout, size)
        setsockopt(fileno(file), SOL_SOCKET, SO_SNDTIMEO, &timeout, size)
    }

    /// True when a live agent accepts connections at `path`.
    static func probe(path: String) -> Bool {
        connect(path: path) != nil
    }

    static func connect(path: String) -> AppAgentSocketClient? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return nil
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        let copied = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { buffer -> Bool in
                let bytes = Array(path.utf8)
                guard bytes.count < pathCapacity else {
                    return false
                }
                for index in 0..<bytes.count {
                    buffer[index] = CChar(bitPattern: bytes[index])
                }
                buffer[bytes.count] = 0
                return true
            }
        }

        guard copied else {
            close(fd)
            return nil
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, let file = fdopen(fd, "r+") else {
            close(fd)
            return nil
        }

        return AppAgentSocketClient(file: file)
    }

    func request(_ object: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        guard let line = String(data: data, encoding: .utf8) else {
            throw ComputerUseError.message("Failed to encode app-agent request.")
        }

        writeAgentLine(line, to: file)

        guard let responseLine = readAgentLine(file),
              let response = try JSONSerialization.jsonObject(with: Data(responseLine.utf8)) as? [String: Any]
        else {
            throw ComputerUseError.message("UltraTerm Computer Use.app agent closed the connection.")
        }

        if let error = response["error"] as? String {
            throw ComputerUseError.message(error)
        }

        return response
    }

    func isCurrentAgent(for appURL: URL) throws -> Bool {
        let response = try request(["kind": "agentInfo"])
        let expectedBundleURL = appURL.standardizedFileURL

        guard response["bundleURL"] as? String == expectedBundleURL.path else {
            return false
        }

        // Prefer the kernel's start time of the process actually on the other
        // end of this socket over the agent's own report.
        let peerStart = AppAgentProcess.peerPID(ofSocket: fileno(file)).flatMap(AppAgentProcess.startTime)
        guard let processStartTime = peerStart ?? response["processStartTime"] as? TimeInterval else {
            return false
        }

        guard let executableURL = executableURL(for: expectedBundleURL),
              let modifiedAt = try? executableURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else {
            return true
        }

        return !AppAgentProcess.predatesExecutable(
            startTime: processStartTime,
            executableModified: modifiedAt.timeIntervalSince1970
        )
    }

    private func executableURL(for appURL: URL) -> URL? {
        guard let bundle = Bundle(url: appURL),
              let executableName = bundle.object(forInfoDictionaryKey: kCFBundleExecutableKey as String) as? String,
              !executableName.isEmpty
        else {
            return nil
        }

        return appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(executableName)
            .standardizedFileURL
    }
}

private func readAgentLine(_ file: UnsafeMutablePointer<FILE>) -> String? {
    var bytes: [UInt8] = []

    while true {
        let character = fgetc(file)
        if character == EOF {
            return bytes.isEmpty ? nil : String(data: Data(bytes), encoding: .utf8)
        }
        if character == 10 {
            return String(data: Data(bytes), encoding: .utf8)
        }
        bytes.append(UInt8(character))
    }
}

private func writeAgentLine(_ object: [String: Any], to file: UnsafeMutablePointer<FILE>) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
       let line = String(data: data, encoding: .utf8)
    {
        writeAgentLine(line, to: file)
    }
}

private func writeAgentLine(_ line: String, to file: UnsafeMutablePointer<FILE>) {
    let output = line + "\n"
    _ = output.withCString { pointer in
        fputs(pointer, file)
    }
    fflush(file)
}
