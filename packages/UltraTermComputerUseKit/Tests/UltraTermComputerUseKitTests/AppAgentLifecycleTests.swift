import Darwin
import Foundation
import XCTest
@testable import UltraTermComputerUseKit

final class AppAgentLifecycleTests: XCTestCase {
    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-agent-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testPidRecordRoundTripsAndRejectsGarbage() {
        let record = AppAgentPidRecord(pid: 4242, startTime: 1_790_000_000.25)
        XCTAssertEqual(AppAgentPidRecord.parse(record.encoded), record)
        XCTAssertNil(AppAgentPidRecord.parse(""))
        XCTAssertNil(AppAgentPidRecord.parse("1 1790000000"), "pid 1 (launchd) is never an agent")
        XCTAssertNil(AppAgentPidRecord.parse("abc 1790000000"))
        XCTAssertNil(AppAgentPidRecord.parse("4242"))
        XCTAssertEqual(AppAgentPidRecord.path(forSocket: "/tmp/a.sock"), "/tmp/a.sock.pid")
    }

    func testOwnershipIsLostWhenTheSocketPathIsRemovedOrReplaced() throws {
        let directory = try scratchDirectory()
        let path = directory.appendingPathComponent("agent.sock").path
        FileManager.default.createFile(atPath: path, contents: Data())
        let bound = AppAgentFileIdentity.of(path: path)
        XCTAssertNotNil(bound)
        XCTAssertNil(appAgentLostOwnershipReason(boundIdentity: bound, currentIdentity: AppAgentFileIdentity.of(path: path)))

        // The $TMPDIR purge (or anyone) removes the path.
        unlink(path)
        XCTAssertEqual(
            appAgentLostOwnershipReason(boundIdentity: bound, currentIdentity: AppAgentFileIdentity.of(path: path)),
            "socket path was removed"
        )

        // A replacement agent binds a new file at the same path.
        FileManager.default.createFile(atPath: path, contents: Data("new".utf8))
        XCTAssertEqual(
            appAgentLostOwnershipReason(boundIdentity: bound, currentIdentity: AppAgentFileIdentity.of(path: path)),
            "socket path now belongs to another agent"
        )
        XCTAssertNil(appAgentLostOwnershipReason(boundIdentity: nil, currentIdentity: nil), "no identity, no verdict")
    }

    func testLiveOwnerRequiresTheSameExecutableSoARecycledPidIsNeverSignalled() throws {
        let directory = try scratchDirectory()
        let socket = directory.appendingPathComponent("agent.sock").path
        let me = AppAgentPidRecord(pid: getpid(), startTime: Date().timeIntervalSince1970)
        try Data(me.encoded.utf8).write(to: URL(fileURLWithPath: AppAgentPidRecord.path(forSocket: socket)))
        let myExecutable = try XCTUnwrap(AppAgentProcess.executablePath(getpid()))

        XCTAssertEqual(AppAgentProcess.liveOwner(socketPath: socket, executablePath: myExecutable), me)
        XCTAssertNil(AppAgentProcess.liveOwner(socketPath: socket, executablePath: "/Applications/Other.app/Contents/MacOS/Other"))
        XCTAssertNil(AppAgentProcess.liveOwner(socketPath: directory.appendingPathComponent("none.sock").path, executablePath: myExecutable))
    }

    func testRetireStopsAProcessThatIgnoresTheGracefulWindow() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        let pid = child.processIdentifier
        addTeardownBlock { if child.isRunning { child.terminate() } }

        XCTAssertTrue(AppAgentProcess.isAlive(pid))
        let outcome = AppAgentProcess.retire(pid, gracefulTimeout: 0.2, forcedTimeout: 2)
        child.waitUntilExit()
        XCTAssertEqual(outcome, "stopped with SIGTERM")
        XCTAssertFalse(child.isRunning)
    }

    func testTouchRefreshesAccessTimeSoTheTmpPurgeSkipsLiveFiles() throws {
        let directory = try scratchDirectory()
        let path = directory.appendingPathComponent("agent.sock.token").path
        FileManager.default.createFile(atPath: path, contents: Data("t".utf8))
        var old = [timeval(tv_sec: 1_000_000_000, tv_usec: 0), timeval(tv_sec: 1_000_000_000, tv_usec: 0)]
        XCTAssertEqual(utimes(path, &old), 0)

        touchAppAgentFiles([path])
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertGreaterThan(TimeInterval(info.st_atimespec.tv_sec), Date().timeIntervalSince1970 - 60)
    }
}

final class AppAgentSocketPathTests: XCTestCase {
    private let temporary = URL(fileURLWithPath: "/private/var/folders/x/T", isDirectory: true)

    func testProductionAndDevelopmentBuildsNeverShareASocket() {
        let production = appAgentSocketPath(temporaryDirectory: temporary, bundleIdentifier: PermissionSupport.bundleIdentifier, environment: [:])
        let development = appAgentSocketPath(temporaryDirectory: temporary, bundleIdentifier: PermissionSupport.developmentBundleIdentifier, environment: [:])
        XCTAssertEqual(production, "/private/var/folders/x/T/ultraterm-computer-use-agent.sock")
        XCTAssertEqual(development, "/private/var/folders/x/T/ultraterm-computer-use-dev-agent.sock")
    }

    func testAbsoluteOverrideWinsAndRelativeOverrideIsIgnored() {
        XCTAssertEqual(
            appAgentSocketPath(temporaryDirectory: temporary, bundleIdentifier: nil, environment: [appAgentSocketEnvironmentKey: "/tmp/e2e/../e2e/agent.sock"]),
            "/tmp/e2e/agent.sock"
        )
        XCTAssertEqual(
            appAgentSocketPath(temporaryDirectory: temporary, bundleIdentifier: nil, environment: [appAgentSocketEnvironmentKey: "agent.sock"]),
            "/private/var/folders/x/T/ultraterm-computer-use-agent.sock"
        )
    }
}

final class AppAgentProcessIdentityTests: XCTestCase {
    func testKernelStartTimeIsTheRealLaunchNotTheFirstQuery() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        let launched = Date().timeIntervalSince1970
        try child.run()
        addTeardownBlock { if child.isRunning { child.terminate() } }
        Thread.sleep(forTimeInterval: 0.6)
        let started = try XCTUnwrap(AppAgentProcess.startTime(child.processIdentifier))
        XCTAssertEqual(started, launched, accuracy: 0.5)
        XCTAssertLessThan(started, Date().timeIntervalSince1970 - 0.4, "must not be the time of this query")
    }

    func testPeerPIDIdentifiesTheProcessAcrossAUnixSocket() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        XCTAssertEqual(AppAgentProcess.peerPID(ofSocket: fds[0]), getpid())
    }

    func testAnAgentStartedBeforeTheUpdateIsOutdated() {
        XCTAssertTrue(AppAgentProcess.predatesExecutable(startTime: 1_000, executableModified: 1_300))
        XCTAssertFalse(AppAgentProcess.predatesExecutable(startTime: 1_300, executableModified: 1_000))
        XCTAssertFalse(AppAgentProcess.predatesExecutable(startTime: 1_000, executableModified: 1_000.4), "clock slack")
    }
}
