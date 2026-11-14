import Darwin
import XCTest
@testable import UltraTermComputerUseKit

/// Regression tests for the 0.10.2 review fixes: media directory handling, path resolution,
/// the bounded wait for the app agent and the private agent socket. No desktop is touched.
final class CLICallReviewFixTests: XCTestCase {
    private func unusableDirectory(in root: URL) throws -> String {
        // A regular file in the way: creating a folder below it fails on any account.
        let file = root.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: file)
        return file.appendingPathComponent("shots").path
    }

    func testUnusableMediaDirIsAUsageErrorBeforeAnyCallRuns() throws {
        try withContractTempDirectory { root in
            let mediaDir = try unusableDirectory(in: root)
            let options = UltraTermComputerUseCallOptions(mediaDir: mediaDir)
            for invocation in [
                UltraTermComputerUseCallInvocation.single(
                    toolName: "list_apps", argumentsJSON: nil, argumentsFile: nil, options: options),
                .sequence(callsJSON: #"[{"tool":"list_apps","args":{}}]"#, callsFile: nil, interCallDelay: 0, options: options),
            ] {
                let output = try runUltraTermComputerUseCall(invocation)
                XCTAssertTrue(output.hasToolError)
                XCTAssertTrue(output.steps.isEmpty, "no call may run when the media folder is unusable")
                XCTAssertEqual(output.errorInfo?.code, "usage")
                XCTAssertEqual(output.errorInfo?.phase, .preflight)
                XCTAssertTrue(output.errorInfo?.message.contains("--media-dir") == true)
                let response = try ultraTermComputerUseCallResponse(for: output, options: options)
                XCTAssertEqual(response.exitCode, 2)
                XCTAssertTrue(response.stderr.contains("No call was run."), response.stderr)
            }
        }
    }

    func testFailedImageWriteKeepsTheResultAndItsStateID() throws {
        let image = try ContractTestImages.solidCGImage(width: 4, height: 4)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try withContractTempDirectory { root in
            let result = ToolCallResult(content: [.text("clicked"), .pngImage(png)], stateID: "1:2:new")
            let kept = externalizedCallResult(
                result, tool: "click", arguments: ["app": "A"], index: 0,
                options: UltraTermComputerUseCallOptions(mediaDir: try unusableDirectory(in: root))
            )
            XCTAssertFalse(kept.isError)
            XCTAssertEqual(kept.stateID, "1:2:new")
            XCTAssertTrue(kept.textContent.contains("clicked"))
            XCTAssertTrue(kept.textContent.contains("image not saved:"), kept.textContent)
        }
    }

    func testPathValuesAreFoundByParsingNotByWalkingOptionNames() {
        // A tool flag's value that looks like an option is that flag's value, not an option.
        XCTAssertEqual(
            resolvingUltraTermComputerUseCallFilePaths(
                ["call", "type_text", "--app", "Terminal", "--text", "--calls", "--media-dir", "shots"],
                currentDirectory: "/work"
            ),
            ["call", "type_text", "--app", "Terminal", "--text", "--calls", "--media-dir", "/work/shots"]
        )
        // Typed text that is literally `--media-dir` must not be rewritten into a path.
        XCTAssertEqual(
            resolvingUltraTermComputerUseCallFilePaths(
                ["call", "type_text", "--app", "Terminal", "--text", "--media-dir", "--media-dir", "shots"],
                currentDirectory: "/work"
            ),
            ["call", "type_text", "--app", "Terminal", "--text", "--media-dir", "--media-dir", "/work/shots"]
        )
        // An absolute path stays; a call that does not parse is passed on unchanged.
        XCTAssertEqual(
            resolvingUltraTermComputerUseCallFilePaths(["call", "list_apps", "--media-dir", "/tmp/m"], currentDirectory: "/work"),
            ["call", "list_apps", "--media-dir", "/tmp/m"]
        )
    }

    func testAgentReplyTimeoutIsTheLimitPlusSleepPauses() {
        XCTAssertEqual(ultraTermComputerUseAgentReplyTimeout(arguments: ["call", "list_apps"]), 120)
        XCTAssertEqual(ultraTermComputerUseAgentReplyTimeout(arguments: ["list-apps"]), 120)
        let three = #"[{"tool":"list_apps"},{"tool":"list_apps"},{"tool":"list_apps"}]"#
        XCTAssertEqual(
            ultraTermComputerUseAgentReplyTimeout(arguments: ["call", "--calls", three, "--sleep", "5"]),
            3 * 120 + 2 * 5
        )
    }

    func testReceiveTimeoutIsReportedAsATimeoutNotAClosedConnection() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[1]) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fds[0], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let channel = LineDelimitedSocketChannel(fileDescriptor: fds[0])
        XCTAssertNil(channel.readLine())
        XCTAssertTrue(channel.lastReadTimedOut)
        close(fds[1]); fds[1] = -1
        XCTAssertNil(channel.readLine())
        XCTAssertFalse(channel.lastReadTimedOut, "a closed peer is not a timeout")
    }

    func testAgentSocketIsOwnerOnlyFromTheMomentItExists() throws {
        let path = "/tmp/ocu-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(path) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            let bytes = Array(path.utf8)
            precondition(bytes.count < capacity)
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let previous = umask(0)  // the worst caller: nothing masked
        defer { umask(previous) }
        XCTAssertEqual(appAgentBindPrivateSocket(fd: fd, address: address), 0)
        var info = stat()
        XCTAssertEqual(stat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600, "bind itself must create the socket owner-only")
        XCTAssertEqual(umask(0), 0, "the caller's umask is restored")
    }

    func testPeerCheckAcceptsTheCurrentUserOnly() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        XCTAssertTrue(appAgentPeerIsCurrentUser(fd: fds[0]))
        XCTAssertFalse(appAgentPeerIsCurrentUser(fd: -1))
    }
}
