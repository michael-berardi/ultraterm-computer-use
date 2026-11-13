import XCTest
@testable import UltraTermComputerUseKit

/// App target discovery contract: query parsing, running-only resolution
/// (never launches/activates), and ambiguity detection. Fabricated descriptors
/// use `NSRunningApplication.current` as the application object with synthetic
/// identity fields; resolution tests only use the test process itself or
/// guaranteed-absent names.
final class DiscoveryContractTests: XCTestCase {
    private func descriptor(name: String, bundle: String?, pid: pid_t) -> RunningAppDescriptor {
        RunningAppDescriptor(
            name: name,
            bundleIdentifier: bundle,
            pid: pid,
            runningApplication: NSRunningApplication.current
        )
    }

    // MARK: AppTargetQuery.parse

    func testQueryParsesExplicitPIDPrefix() {
        XCTAssertEqual(AppTargetQuery.parse("pid:123"), .pid(123))
        XCTAssertEqual(AppTargetQuery.parse("PID:123"), .pid(123))
        XCTAssertEqual(AppTargetQuery.parse("  pid:42  "), .pid(42))
    }

    func testQueryParsesBareDigitsAsPID() {
        XCTAssertEqual(AppTargetQuery.parse("123"), .pid(123))
        XCTAssertEqual(AppTargetQuery.parse("0"), .pid(0))
    }

    func testQueryParsesBundleIdentifierWhenContainingDot() {
        XCTAssertEqual(AppTargetQuery.parse("com.apple.TextEdit"), .bundleIdentifier("com.apple.TextEdit"))
        XCTAssertEqual(AppTargetQuery.parse("pid:abc.def"), .bundleIdentifier("pid:abc.def"))
    }

    func testQueryParsesAnythingElseAsName() {
        XCTAssertEqual(AppTargetQuery.parse("TextEdit"), .name("TextEdit"))
        XCTAssertEqual(AppTargetQuery.parse("pid:abc"), .name("pid:abc"))
        XCTAssertEqual(AppTargetQuery.parse(""), .name(""))
        XCTAssertEqual(AppTargetQuery.parse("0123"), .name("0123"), "non-canonical digits are not a pid")
    }

    // MARK: runningMatches / uniqueMatch (internal seam)

    func testRunningMatchesFiltersByQueryKind() {
        let apps = [
            descriptor(name: "Alpha", bundle: "dev.test.alpha", pid: 10),
            descriptor(name: "Beta", bundle: "dev.test.beta", pid: 20),
        ]

        XCTAssertEqual(AppDiscovery.runningMatches(in: apps, for: "pid:20").map(\.pid), [20])
        XCTAssertEqual(AppDiscovery.runningMatches(in: apps, for: "20").map(\.pid), [20])
        XCTAssertEqual(AppDiscovery.runningMatches(in: apps, for: "DEV.TEST.ALPHA").map(\.pid), [10])
        XCTAssertEqual(AppDiscovery.runningMatches(in: apps, for: "alpha").map(\.pid), [10])
        XCTAssertTrue(AppDiscovery.runningMatches(in: apps, for: "gamma").isEmpty)
        XCTAssertTrue(AppDiscovery.runningMatches(in: apps, for: "pid:99").isEmpty)
    }

    func testRunningMatchesExcludesSafetyBlockedAppsFromNameMatches() {
        let apps = [descriptor(name: "1Password", bundle: "com.1password.1password", pid: 10)]

        XCTAssertTrue(AppDiscovery.runningMatches(in: apps, for: "1password").isEmpty)
        // Bundle-identifier queries are resolved before the safety gate so the
        // resolver can report permissionDenied instead of a bare not-found.
        XCTAssertEqual(AppDiscovery.runningMatches(in: apps, for: "com.1password.1password").map(\.pid), [10])
    }

    func testUniqueMatchReturnsSingleMatch() throws {
        let apps = [descriptor(name: "Alpha", bundle: "dev.test.alpha", pid: 10)]
        let match = try AppDiscovery.uniqueMatch(in: apps, for: "alpha")

        XCTAssertEqual(match?.pid, 10)
    }

    func testUniqueMatchReturnsNilForNoMatches() throws {
        XCTAssertNil(try AppDiscovery.uniqueMatch(in: [], for: "alpha"))
    }

    func testUniqueMatchCollapsesSamePIDDuplicates() throws {
        let same = descriptor(name: "Alpha", bundle: "dev.test.alpha", pid: 10)
        let match = try AppDiscovery.uniqueMatch(in: [same, same], for: "alpha")

        XCTAssertEqual(match?.pid, 10)
    }

    func testUniqueMatchThrowsAmbiguousAppForDistinctPIDs() {
        let apps = [
            descriptor(name: "Alpha", bundle: "dev.test.alpha", pid: 10),
            descriptor(name: "Alpha", bundle: "dev.test.alpha", pid: 20),
        ]

        XCTAssertThrowsError(try AppDiscovery.uniqueMatch(in: apps, for: "alpha")) { error in
            guard case let ComputerUseError.ambiguousApp(query, candidates) = error else {
                return XCTFail("expected ambiguousApp, got \(error)")
            }
            XCTAssertEqual(query, "alpha")
            XCTAssertEqual(candidates, [
                "Alpha — dev.test.alpha (pid 10)",
                "Alpha — dev.test.alpha (pid 20)",
            ])
        }
    }

    // MARK: Running-only resolution against the live workspace

    func testResolveRunningDoesNotTreatNonAppProcessAsTarget() {
        XCTAssertThrowsError(
            try AppDiscovery.resolveRunning("pid:1", maxAttempts: 1, retryDelay: 0)  // launchd: a process that is never a workspace app (the test host itself can be registered once AppKit loads)
        ) { error in
            guard case ComputerUseError.appNotFound = error else {
                return XCTFail("expected appNotFound for a non-app process, got \(error)")
            }
        }
    }

    func testResolveRunningFailsFastForAbsentApp() {
        // maxAttempts 1 + zero delay: resolution is bounded and never launches.
        XCTAssertThrowsError(
            try AppDiscovery.resolveRunning("no-such-app-contract-xyz", maxAttempts: 1, retryDelay: 0)
        ) { error in
            guard case let ComputerUseError.appNotFound(query) = error else {
                return XCTFail("expected appNotFound, got \(error)")
            }
            XCTAssertEqual(query, "no-such-app-contract-xyz")
        }
    }

    func testResolveRunningFailsFastForAbsentBundleIdentifier() {
        XCTAssertThrowsError(
            try AppDiscovery.resolveRunning("dev.test.no-such-bundle-xyz", maxAttempts: 1, retryDelay: 0)
        ) { error in
            guard case ComputerUseError.appNotFound = error else {
                return XCTFail("expected appNotFound, got \(error)")
            }
        }
    }

    func testResolveRunningRejectsSafetyBlockedBundle() {
        XCTAssertThrowsError(
            try AppDiscovery.resolveRunning("com.1password.1password", maxAttempts: 1, retryDelay: 0)
        ) { error in
            guard case ComputerUseError.permissionDenied = error else {
                return XCTFail("expected permissionDenied, got \(error)")
            }
        }
    }

    // MARK: Safety gate after resolution

    func testResolveRunningRejectsCaseVariantBlockedBundle() {
        XCTAssertThrowsError(
            try AppDiscovery.resolveRunning("COM.1PASSWORD.1PASSWORD", maxAttempts: 1, retryDelay: 0)
        ) { error in
            guard case ComputerUseError.permissionDenied = error else {
                return XCTFail("expected permissionDenied, got \(error)")
            }
        }
    }

    func testSafetyCheckedResolutionRejectsBlockedAppReachedByPID() {
        let blocked = descriptor(name: "1Password", bundle: "com.1password.1password", pid: 10)
        let matches = AppDiscovery.runningMatches(in: [blocked], for: "pid:10")

        // The raw match seam still surfaces the descriptor so the gate can
        // deny it explicitly instead of reporting a bare not-found.
        XCTAssertEqual(matches.map(\.pid), [10])
        XCTAssertThrowsError(
            try AppDiscovery.safetyCheckedUniqueMatch(in: matches, for: "pid:10")
        ) { error in
            guard case ComputerUseError.permissionDenied = error else {
                return XCTFail("expected permissionDenied, got \(error)")
            }
        }
    }

    func testSafetyCheckedResolutionRejectsCaseVariantBlockedBundleMatch() {
        let blocked = descriptor(name: "1Password", bundle: "com.1password.1password", pid: 10)
        let matches = AppDiscovery.runningMatches(in: [blocked], for: "COM.1PASSWORD.1PASSWORD")

        XCTAssertEqual(matches.map(\.pid), [10])
        XCTAssertThrowsError(
            try AppDiscovery.safetyCheckedUniqueMatch(in: matches, for: "COM.1PASSWORD.1PASSWORD")
        ) { error in
            guard case ComputerUseError.permissionDenied = error else {
                return XCTFail("expected permissionDenied, got \(error)")
            }
        }
    }

    func testSafetyCheckedResolutionPassesUnblockedMatchThrough() throws {
        let app = descriptor(name: "Alpha", bundle: "dev.test.alpha", pid: 10)

        let match = try AppDiscovery.safetyCheckedUniqueMatch(in: [app], for: "alpha")

        XCTAssertEqual(match?.pid, 10)
    }

    func testSafetyCheckedResolutionReturnsNilForNoMatches() throws {
        XCTAssertNil(try AppDiscovery.safetyCheckedUniqueMatch(in: [], for: "pid:10"))
    }

    // MARK: inspect / targets payload

    func testInspectAppStateNeverLaunchesForAbsentApp() {
        // inspect resolves running apps only: an absent target fails bounded
        // (resolveRunning's two quick scans) instead of resolve()'s launch +
        // 5-second poll. Assert the whole call stays well under that budget.
        let service = ComputerUseService()
        let started = Date()

        XCTAssertThrowsError(try service.inspectAppState(app: "no-such-app-contract-xyz")) { error in
            guard case ComputerUseError.appNotFound = error else {
                return XCTFail("expected appNotFound, got \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4,
                          "inspect must not launch or poll-wait for missing apps")
    }

    func testTargetsPayloadRunningOnlyEntriesCarryContractKeys() {
        let payload = AppDiscovery.targetsPayload(runningOnly: true)

        XCTAssertFalse(payload.isEmpty, "the test process itself is a running app")
        for entry in payload {
            XCTAssertNotNil(entry["name"] as? String)
            XCTAssertNotNil(entry["pid"] as? Int)
            XCTAssertEqual(entry["running"] as? Bool, true)
            XCTAssertNotNil(entry["frontmost"] as? Bool)
        }
    }

    func testRunningTargetsPayloadExcludesBlockedAppsAndTheirPIDs() {
        let allowed = descriptor(name: "Alpha", bundle: "dev.test.alpha", pid: 10)
        let blocked = descriptor(name: "1Password", bundle: "com.1password.1password", pid: 20)
        let caseVariantBlocked = descriptor(name: "Bitwarden", bundle: "COM.BITWARDEN.DESKTOP", pid: 30)

        let payload = AppDiscovery.runningTargetsPayload(
            from: [allowed, blocked, caseVariantBlocked],
            frontmostPID: 10
        )

        XCTAssertEqual(payload.count, 1)
        XCTAssertEqual(payload.first?["pid"] as? Int, 10)
        XCTAssertEqual(payload.first?["bundle_id"] as? String, "dev.test.alpha")
        XCTAssertEqual(payload.first?["frontmost"] as? Bool, true)

        let pids = payload.compactMap { $0["pid"] as? Int }
        XCTAssertFalse(pids.contains(20), "blocked app pid must never appear in discovery payloads")
        XCTAssertFalse(pids.contains(30), "case-variant blocked bundle ids must be filtered too")
    }
}
