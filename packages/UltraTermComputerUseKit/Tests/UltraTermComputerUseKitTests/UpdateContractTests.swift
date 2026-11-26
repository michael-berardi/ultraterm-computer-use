import CommonCrypto
import Foundation
import XCTest
@testable import UltraTermComputerUseKit

/// Update contract v1 for the signed macOS app. The release API and the installer are injected;
/// no test uses the network.
final class UpdateContractTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("utcu-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private var environment: [String: String] { ["HOME": home.path] }
    private var stateURL: URL { UpdateSupport.stateURL(environment: environment) }

    private func release(_ tag: String, body: String = "", prerelease: Bool = false) -> Data {
        try! JSONSerialization.data(withJSONObject: ["tag_name": tag, "body": body, "draft": false, "prerelease": prerelease])
    }

    private func sha256(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func testVersionComparison() {
        XCTAssertTrue(UpdateSupport.isNewer("0.12.0", than: "0.11.0"))
        XCTAssertTrue(UpdateSupport.isNewer("v1.0.0", than: "0.99.99"))
        XCTAssertTrue(UpdateSupport.isNewer("0.11.10", than: "0.11.9"))
        XCTAssertFalse(UpdateSupport.isNewer("0.11.0", than: "0.11.0"), "equal")
        XCTAssertFalse(UpdateSupport.isNewer("0.10.9", than: "0.11.0"), "older")
        for bad in ["0.12.0-beta.1", "0.12.0+build", "latest", "", "1.2", "99999999999999999999.0.0"] {
            XCTAssertFalse(UpdateSupport.isNewer(bad, than: "0.11.0"), bad)
        }
    }

    func testOnlyReleaseAppBundlesCheck() {
        XCTAssertEqual(UpdateSupport.releaseSlug(bundlePath: "/Applications/UltraTerm Computer Use.app", infoValue: "owner/repo"), "owner/repo")
        XCTAssertNil(UpdateSupport.releaseSlug(bundlePath: "/Applications/UltraTerm Computer Use.app", infoValue: ""), "development build")
        XCTAssertNil(UpdateSupport.releaseSlug(bundlePath: "/Applications/UltraTerm Computer Use.app", infoValue: "your-org/ultraterm-computer-use"))
        XCTAssertNil(UpdateSupport.releaseSlug(bundlePath: "/x/node_modules/ultraterm-computer-use/dist/UltraTerm Computer Use.app", infoValue: "owner/repo"), "the npm launcher owns this copy")
        XCTAssertNil(UpdateSupport.releaseSlug(bundlePath: "/repo/.build/debug", infoValue: "owner/repo"), "not an app bundle")
    }

    func testSilentOutsideATerminalInCIAgentsAndWhenOptedOut() throws {
        XCTAssertTrue(UpdateSupport.checksAllowed(environment: environment, interactive: true))
        XCTAssertFalse(UpdateSupport.checksAllowed(environment: environment, interactive: false))
        for (key, value) in [("CI", "true"), ("ULTRATERM_COMPUTER_USE_NO_UPDATE_CHECK", "1"), ("CLAUDECODE", "1"), ("CODEX_SANDBOX", "seatbelt")] {
            XCTAssertFalse(UpdateSupport.checksAllowed(environment: environment.merging([key: value]) { $1 }, interactive: true), key)
        }
        let config = home.appendingPathComponent(".config/ultraterm-computer-use/config.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"updates":{"check":false}}"#.utf8).write(to: config)
        XCTAssertFalse(UpdateSupport.checksAllowed(environment: environment, interactive: true), "config switch")
    }

    func testCheckRecordsResultAndFailureCause() {
        var requested: [URL] = []
        let result = UpdateSupport.check(slug: "owner/repo", current: "0.11.0", stateURL: stateURL, fetch: { url, timeout in
            requested.append(url)
            XCTAssertLessThanOrEqual(timeout, 4)
            return self.release("v0.12.0", body: "One.\n\nTwo.")
        })
        XCTAssertEqual(result, .available(version: "0.12.0", notes: "One.\nTwo."))
        XCTAssertEqual(requested.map(\.absoluteString), ["https://api.github.com/repos/owner/repo/releases/latest"])
        XCTAssertEqual(UpdateState.read(stateURL).latestVersion, "0.12.0")
        let attributes = try? FileManager.default.attributesOfItem(atPath: stateURL.path)
        XCTAssertEqual((attributes?[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stateURL.deletingLastPathComponent().path), ["update-state.json"], "one cache file, no temp files")

        XCTAssertEqual(UpdateSupport.check(slug: "owner/repo", current: "0.11.0", stateURL: stateURL, fetch: { _, _ in self.release("v0.13.0-rc.1", prerelease: true) }), .current)
        let failed = UpdateSupport.check(slug: "owner/repo", current: "0.11.0", stateURL: stateURL, fetch: { _, _ in throw URLError(.timedOut) })
        XCTAssertEqual(failed, .failed(cause: "timed out"))
        XCTAssertEqual(UpdateState.read(stateURL).lastError, "check failed: timed out")
    }

    func testCheckIntervalNoticeFrequencyAndSkip() {
        let now = Date()
        var state = UpdateState()
        XCTAssertTrue(UpdateSupport.checkDue(state, now: now))
        state.lastCheckAt = UpdateSupport.formatDate(now.addingTimeInterval(-3600))
        XCTAssertFalse(UpdateSupport.checkDue(state, now: now))
        state.lastCheckAt = "2026-11-25T21:16:11.764Z"
        XCTAssertTrue(UpdateSupport.checkDue(state, now: UpdateSupport.parseDate("2026-11-26T21:16:12Z")!), "the launcher's date form parses")

        state.latestVersion = "0.12.0"
        XCTAssertTrue(UpdateSupport.noticeDue(state, current: "0.11.0", now: now))
        XCTAssertFalse(UpdateSupport.noticeDue(state, current: "0.12.0", now: now))
        state.lastShownVersion = "0.12.0"
        state.lastShownAt = UpdateSupport.formatDate(now.addingTimeInterval(-60))
        XCTAssertFalse(UpdateSupport.noticeDue(state, current: "0.11.0", now: now), "once per 24 h per version")
        XCTAssertTrue(UpdateSupport.noticeDue(state, current: "0.11.0", now: now.addingTimeInterval(UpdateSupport.checkInterval)))
        state.skippedVersion = "0.12.0"
        XCTAssertFalse(UpdateSupport.noticeDue(state, current: "0.11.0", now: now.addingTimeInterval(2 * UpdateSupport.checkInterval)))
        state.latestVersion = "0.12.1"
        XCTAssertTrue(UpdateSupport.noticeDue(state, current: "0.11.0", now: now), "a newer release notifies again")
    }

    func testNoticeAfterCommandUsesTheCacheAndStartsOneBackgroundCheck() {
        var refreshes = 0
        var printed: [String] = []
        func run(_ arguments: [String] = ["list_apps"], command: UltraTermComputerUseCLICommand = .listApps, interactive: Bool = true) {
            UpdateSupport.afterCommand(command, arguments: arguments, environment: environment.merging(["NO_COLOR": "1"]) { $1 }, interactive: interactive,
                                       slug: "owner/repo", current: "0.11.0", startRefresh: { refreshes += 1 }, errorOutput: { printed.append($0) })
        }
        run()
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(printed, [], "nothing is known yet")
        run()
        XCTAssertEqual(refreshes, 1, "today's check is already claimed")

        var state = UpdateState.read(stateURL)
        state.latestVersion = "0.12.0"
        state.write(stateURL)
        run(["list_apps", "--json"])
        run(interactive: false)
        run(["mcp"], command: .mcp)
        XCTAssertEqual(printed, [], "never with --json, outside a terminal or after MCP")
        run()
        XCTAssertEqual(printed, ["ultraterm-computer-use 0.12.0 available (you have 0.11.0) · run: ultraterm-computer-use update\nskip: ultraterm-computer-use update --skip"])
        run()
        XCTAssertEqual(printed.count, 1, "shown once per day")
    }

    func testUpdateCommandExitCodesAndSkip() {
        var lines: [String] = []
        func update(_ action: UpdateCommandAction, tag: String = "v0.12.0", slug: String? = "owner/repo") -> Int32 {
            UpdateSupport.run(action, environment: environment, slug: slug, current: "0.11.0", interactive: false,
                              fetch: { _, _ in self.release(tag) }, runInstaller: { _ in XCTFail("no install") },
                              output: { lines.append($0) }, errorOutput: { lines.append($0) })
        }
        XCTAssertEqual(update(.check), 10)
        XCTAssertEqual(update(.check, tag: "v0.11.0"), 0)
        XCTAssertEqual(UpdateSupport.run(.check, environment: environment, slug: "owner/repo", current: "0.11.0", interactive: false,
                                         fetch: { _, _ in throw URLError(.notConnectedToInternet) }, output: { lines.append($0) }, errorOutput: { lines.append($0) }), 1)
        XCTAssertTrue(lines.last!.hasPrefix("ultraterm-computer-use update: check failed: "), lines.last!)
        XCTAssertEqual(update(.skip), 0)
        XCTAssertEqual(UpdateState.read(stateURL).skippedVersion, "0.12.0")
        XCTAssertEqual(update(.auto("status")), 0)
        XCTAssertEqual(lines.last, "automatic updates: off")
        XCTAssertEqual(update(.auto("on")), 1, "needs an administrator password, so not offered")
        XCTAssertEqual(update(.rollback), 1)
        XCTAssertEqual(update(.check, slug: nil), 1, "development and npm copies do not update themselves")
        XCTAssertEqual(try parseUpdateCommand(["--auto", "on"]), .auto("on"))
        XCTAssertThrowsError(try parseUpdateCommand(["--auto", "maybe"]))
        XCTAssertThrowsError(try parseUpdateCommand(["--check", "--skip"]))
    }

    func testInstallVerifiesTheInstallerBeforeRunningItAndCleansUp() throws {
        let script = Data("#!/bin/bash\necho installing\n".utf8)
        let goodSums = "\(sha256(script))  install-ultraterm-computer-use.sh\n"
        var ran: [URL] = []
        var fetched: [String] = []
        let fetch: (String) -> (URL, TimeInterval) throws -> Data = { sums in
            { url, _ in
                fetched.append(url.absoluteString)
                return url.lastPathComponent == "SHA256SUMS" ? Data(sums.utf8) : script
            }
        }
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))

        try UpdateSupport.install(version: "0.12.0", slug: "owner/repo", fetch: fetch(goodSums), runInstaller: { file in
            XCTAssertEqual(try Data(contentsOf: file), script)
            ran.append(file)
        })
        XCTAssertEqual(ran.count, 1)
        XCTAssertEqual(fetched, [
            "https://github.com/owner/repo/releases/download/v0.12.0/SHA256SUMS",
            "https://github.com/owner/repo/releases/download/v0.12.0/install-ultraterm-computer-use.sh",
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: ran[0].deletingLastPathComponent().path), "temp folder removed after success")

        let badSums = "\(String(repeating: "0", count: 64))  install-ultraterm-computer-use.sh\n"
        XCTAssertThrowsError(try UpdateSupport.install(version: "0.12.0", slug: "owner/repo", fetch: fetch(badSums), runInstaller: { _ in XCTFail("must not run") })) {
            XCTAssertEqual($0.localizedDescription, "checksum mismatch for install-ultraterm-computer-use.sh; nothing was installed")
        }
        XCTAssertThrowsError(try UpdateSupport.install(version: "0.12.0", slug: "owner/repo", fetch: fetch(""), runInstaller: { _ in XCTFail("must not run") }))
        XCTAssertThrowsError(try UpdateSupport.install(version: "0.12.0", slug: "owner/repo", fetch: fetch(goodSums), runInstaller: { _ in throw URLError(.cancelled) }))
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))
        XCTAssertEqual(after.subtracting(before).filter { $0.hasPrefix("ultraterm-computer-use-update-") }, [], "temp folders removed after failures")
    }

    func testHelpAndParsing() throws {
        XCTAssertTrue(ultraTermComputerUseHelpText(command: "update").contains("update --check"))
        XCTAssertEqual(try parseUltraTermComputerUseCLI(arguments: ["update", "--check"]), .update(.check))
        XCTAssertFalse(UpdateSupport.notifies(after: .mcp))
        XCTAssertFalse(UpdateSupport.notifies(after: .update(.install)))
        XCTAssertTrue(UpdateSupport.notifies(after: .listApps))
    }
}
