import Darwin
import Foundation

/// Lifecycle helpers for the single app-scoped automation agent.
///
/// The agent listens on a Unix socket in `$TMPDIR`. Two things used to leave
/// agents running forever with nobody able to reach them:
/// - macOS purges `$TMPDIR` files that have not been accessed for about three
///   days, so the socket (or its token) vanished under a live agent and the
///   next launcher started a second agent beside it;
/// - the launcher unlinked the socket and launched a replacement whenever a
///   connect or version check failed, without making sure the old agent had
///   exited.
/// The pid record lets a launcher find and retire the real owner first, and
/// the socket identity lets an agent notice it no longer owns its path.

/// `<socket>.pid`: the owning agent's pid and start time, one line.
public struct AppAgentPidRecord: Equatable, Sendable {
    public let pid: Int32
    public let startTime: TimeInterval

    public init(pid: Int32, startTime: TimeInterval) {
        self.pid = pid
        self.startTime = startTime
    }

    public static func path(forSocket socketPath: String) -> String {
        socketPath + ".pid"
    }

    public var encoded: String {
        "\(pid) \(startTime)\n"
    }

    public static func parse(_ text: String) -> AppAgentPidRecord? {
        let fields = text.split(whereSeparator: \.isWhitespace)
        guard fields.count == 2,
              let pid = Int32(fields[0]), pid > 1,
              let startTime = TimeInterval(fields[1]), startTime > 0
        else {
            return nil
        }
        return AppAgentPidRecord(pid: pid, startTime: startTime)
    }

    public static func read(socketPath: String) -> AppAgentPidRecord? {
        guard let text = try? String(contentsOfFile: path(forSocket: socketPath), encoding: .utf8) else {
            return nil
        }
        return parse(text)
    }
}

/// Device and inode of a filesystem entry, compared with `lstat`.
public struct AppAgentFileIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }

    public static func of(path: String) -> AppAgentFileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return nil
        }
        return AppAgentFileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }
}

/// Why a running agent should stop serving, or `nil` while it still owns its path.
public func appAgentLostOwnershipReason(
    boundIdentity: AppAgentFileIdentity?,
    currentIdentity: AppAgentFileIdentity?
) -> String? {
    guard let boundIdentity else {
        return nil
    }
    guard let currentIdentity else {
        return "socket path was removed"
    }
    return currentIdentity == boundIdentity ? nil : "socket path now belongs to another agent"
}

public enum AppAgentProcess {
    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 1 else {
            return false
        }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// When the kernel started `pid`. Never trust a process's own claim: a
    /// lazily initialized start date reported the first-request time instead,
    /// so an agent launched before an update looked newer than the update.
    public static func startTime(_ pid: Int32) -> TimeInterval? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        let started = info.kp_proc.p_un.__p_starttime
        return TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000
    }

    /// The pid on the other end of a connected Unix socket.
    public static func peerPID(ofSocket fd: Int32) -> Int32? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 1 else {
            return nil
        }
        return pid
    }

    /// True when a process started before its executable file was last
    /// replaced, i.e. it still runs an outdated build.
    public static func predatesExecutable(startTime: TimeInterval, executableModified: TimeInterval) -> Bool {
        startTime + 0.5 < executableModified
    }

    /// The executable of a live process, or `nil` when it cannot be read.
    public static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return nil
        }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).standardizedFileURL.path
    }

    /// The recorded owner, only when that pid is alive AND runs this app's
    /// executable, so a recycled pid can never be signalled by mistake.
    public static func liveOwner(socketPath: String, executablePath: String) -> AppAgentPidRecord? {
        guard let record = AppAgentPidRecord.read(socketPath: socketPath),
              isAlive(record.pid),
              let running = self.executablePath(record.pid),
              running == URL(fileURLWithPath: executablePath).standardizedFileURL.path
        else {
            return nil
        }
        return record
    }

    /// Wait for `pid` to exit; SIGTERM after `gracefulTimeout`, SIGKILL after
    /// `forcedTimeout` more. Returns a description of how it ended.
    @discardableResult
    public static func retire(
        _ pid: Int32,
        gracefulTimeout: TimeInterval = 3,
        forcedTimeout: TimeInterval = 3
    ) -> String {
        if waitForExit(pid, timeout: gracefulTimeout) {
            return "exited"
        }
        kill(pid, SIGTERM)
        if waitForExit(pid, timeout: forcedTimeout) {
            return "stopped with SIGTERM"
        }
        kill(pid, SIGKILL)
        return waitForExit(pid, timeout: 1) ? "stopped with SIGKILL" : "did not exit"
    }

    public static func waitForExit(_ pid: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isAlive(pid) {
            if Date() >= deadline {
                return false
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return true
    }
}

/// Refresh access and modification times so the periodic `$TMPDIR` purge
/// never removes a live agent's socket, token or pid file.
public func touchAppAgentFiles(_ paths: [String]) {
    for path in paths {
        utimes(path, nil)
    }
}

/// Append one timestamped line to `~/Library/Logs/UltraTerm Computer Use/app-agent.log`.
/// The agent is launched through Launch Services, so its stderr goes nowhere;
/// every lifecycle decision (retire, self-exit, recovery) is written here.
public func appAgentLog(_ message: String) {
    let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/UltraTerm Computer Use", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("app-agent.log")
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] pid \(getpid()): \(message)\n"
    if let handle = try? FileHandle(forWritingTo: file) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    } else {
        try? Data(line.utf8).write(to: file)
    }
}

/// Explicit agent socket for tests and side-by-side builds (absolute path).
public let appAgentSocketEnvironmentKey = "ULTRATERM_COMPUTER_USE_AGENT_SOCKET"

/// The agent socket for this build. A development build gets its own socket:
/// sharing the production path let a dev build treat the installed agent as
/// outdated and replace it. `TMPDIR` does not isolate a build, because
/// Foundation's temporary directory ignores it on macOS.
public func appAgentSocketPath(
    temporaryDirectory: URL,
    bundleIdentifier: String?,
    environment: [String: String]
) -> String {
    if let override = environment[appAgentSocketEnvironmentKey], override.hasPrefix("/") {
        return URL(fileURLWithPath: override).standardizedFileURL.path
    }
    let name = bundleIdentifier == PermissionSupport.developmentBundleIdentifier
        ? "ultraterm-computer-use-dev-agent.sock"
        : "ultraterm-computer-use-agent.sock"
    return temporaryDirectory.appendingPathComponent(name).standardizedFileURL.path
}
