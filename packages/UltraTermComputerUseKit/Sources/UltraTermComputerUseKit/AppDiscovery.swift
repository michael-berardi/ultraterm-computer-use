import AppKit
import CoreServices
import Foundation

public struct RunningAppDescriptor {
    public let name: String
    public let bundleIdentifier: String?
    public let pid: pid_t
    public let runningApplication: NSRunningApplication
}

/// A parsed app target query. Accepts `pid:<pid>`, a bare pid, a bundle
/// identifier (contains `.`), or an exact app name.
public enum AppTargetQuery: Equatable {
    case pid(pid_t)
    case bundleIdentifier(String)
    case name(String)

    public static func parse(_ raw: String) -> AppTargetQuery {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        let pidPrefix = "pid:"
        if trimmed.lowercased().hasPrefix(pidPrefix) {
            let remainder = trimmed.dropFirst(pidPrefix.count)
            if let pid = pid_t(remainder) {
                return .pid(pid)
            }
        }

        if let pid = pid_t(trimmed), String(pid) == trimmed {
            return .pid(pid)
        }

        if trimmed.contains(".") {
            return .bundleIdentifier(trimmed)
        }

        return .name(trimmed)
    }
}

struct ListedAppDescriptor {
    let name: String
    let bundleIdentifier: String
    let isRunning: Bool
    let isFrontmost: Bool
    let lastUsed: Date?
    let uses: Int?

    var renderedLine: String {
        var markers: [String] = []
        if isFrontmost {
            markers.append("frontmost")
        }
        if isRunning {
            markers.append("running")
        }
        if let lastUsed {
            markers.append("last-used=\(AppDiscovery.usageDateFormatter.string(from: lastUsed))")
        }
        if let uses {
            markers.append("uses=\(uses)")
        }

        return "\(name) — \(bundleIdentifier) [\(markers.joined(separator: ", "))]"
    }
}

private struct SpotlightAppRecord {
    let name: String
    let bundleIdentifier: String
    let lastUsed: Date?
    let uses: Int?
}

private struct ResolvedAppInfo {
    let bundleIdentifier: String
    let name: String
}

enum AppDiscovery {
    private static let listAppsQuery = #"kMDItemContentType == "com.apple.application-bundle" && kMDItemFSName == "*.app""#
    private static let lastUsedDateRankingAttribute = "kMDItemLastUsedDate_Ranking"
    private static let useCountAttribute = "kMDItemUseCount"
    private static let maxRecentNonRunningApps = 10
    private static let fixtureListBundleIdentifier = "dev.opencodex.opencomputeruse.fixture"
    private static let standardApplicationSearchRoots: [URL] = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
    ]

    static let usageDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func listCatalog() -> [ListedAppDescriptor] {
        let running = userFacingRunningApps()
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased()
        let runningByBundle = running.reduce(into: [String: RunningAppDescriptor]()) { result, descriptor in
            guard let bundleIdentifier = listedBundleIdentifier(for: descriptor) else {
                return
            }

            let key = bundleIdentifier.lowercased()
            if result[key] == nil {
                result[key] = descriptor
            }
        }

        var entriesByBundle: [String: ListedAppDescriptor] = [:]

        for record in SpotlightAppIndex.recentApps(cutoffDate: recentUsageCutoff()) {
            guard !AppSafetyPolicy.isBlocked(bundleIdentifier: record.bundleIdentifier) else {
                continue
            }

            let key = record.bundleIdentifier.lowercased()
            let runningDescriptor = runningByBundle[key]
            entriesByBundle[key] = ListedAppDescriptor(
                name: runningDescriptor?.name ?? record.name,
                bundleIdentifier: record.bundleIdentifier,
                isRunning: runningDescriptor != nil,
                isFrontmost: key == frontmostBundleIdentifier,
                lastUsed: record.lastUsed,
                uses: record.uses
            )
        }

        for descriptor in running {
            guard let bundleIdentifier = listedBundleIdentifier(for: descriptor),
                  !AppSafetyPolicy.isBlocked(bundleIdentifier: bundleIdentifier) else {
                continue
            }

            let key = bundleIdentifier.lowercased()
            let existing = entriesByBundle[key]
            entriesByBundle[key] = ListedAppDescriptor(
                name: descriptor.name,
                bundleIdentifier: bundleIdentifier,
                isRunning: true,
                isFrontmost: key == frontmostBundleIdentifier,
                lastUsed: existing?.lastUsed,
                uses: existing?.uses
            )
        }

        let sorted = entriesByBundle.values.sorted(by: compareListedApps)
        let runningEntries = sorted.filter(\.isRunning)
        let recentEntries = sorted.filter { !$0.isRunning }.prefix(maxRecentNonRunningApps)
        return runningEntries + recentEntries
    }

    static func runningApps() -> [RunningAppDescriptor] {
        NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated }
            .sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive {
                    return lhs.isActive && !rhs.isActive
                }

                return appName(lhs).localizedCaseInsensitiveCompare(appName(rhs)) == .orderedAscending
            }
            .map { app in
                RunningAppDescriptor(
                    name: appName(app),
                    bundleIdentifier: app.bundleIdentifier,
                    pid: app.processIdentifier,
                    runningApplication: app
                )
            }
    }

    /// Resolve a target strictly among running apps. Never launches, never
    /// activates. `pid:<pid>` and bare pids address one process exactly; names and
    /// bundle identifiers use the ranked resolution below. Retries a bounded number
    /// of times when a scan transiently finds no match.
    static func resolveRunning(
        _ query: String,
        applications: [RunningAppDescriptor]? = nil,
        maxAttempts: Int = 1,
        retryDelay: TimeInterval = 0.25
    ) throws -> RunningAppDescriptor {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bundleIdentifier = blockedBundleIdentifier(forQuery: query) {
            throw AppSafetyPolicy.permissionDenied(bundleIdentifier: bundleIdentifier)
        }

        var attempt = 0
        while true {
            let running = applications ?? runningApps()
            if case .pid = AppTargetQuery.parse(query) {
                if let unique = try safetyCheckedUniqueMatch(in: runningMatches(in: running, for: query), for: query) {
                    return unique
                }
            } else if let app = resolvedRunningApp(in: running, matching: query) {
                return app
            }

            attempt += 1
            if applications != nil || attempt >= max(1, maxAttempts) {
                throw ComputerUseError.appNotFound(query)
            }

            Thread.sleep(forTimeInterval: retryDelay)
        }
    }

    /// All running apps matching the query: exact pid, exact bundle
    /// identifier, or exact (case-insensitive) app/executable name.
    static func runningMatches(for query: String) -> [RunningAppDescriptor] {
        runningMatches(in: runningApps(), for: query)
    }

    static func runningMatches(in descriptors: [RunningAppDescriptor], for query: String) -> [RunningAppDescriptor] {
        switch AppTargetQuery.parse(query) {
        case .pid(let pid):
            return descriptors.filter { $0.pid == pid }
        case .bundleIdentifier(let bundleIdentifier):
            return descriptors.filter {
                $0.bundleIdentifier?.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
            }
        case .name(let name):
            return descriptors.filter { descriptor in
                guard !AppSafetyPolicy.isBlocked(bundleIdentifier: descriptor.bundleIdentifier) else {
                    return false
                }

                return descriptor.name.caseInsensitiveCompare(name) == .orderedSame
                    || descriptor.runningApplication.executableURL?.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
            }
        }
    }

    /// Returns the single match, nil when there are none, and throws
    /// `.ambiguousApp` with candidate descriptions when several distinct
    /// processes match.
    static func uniqueMatch(
        in matches: [RunningAppDescriptor],
        for query: String
    ) throws -> RunningAppDescriptor? {
        guard let first = matches.first else {
            return nil
        }

        let distinctPIDs = Set(matches.map(\.pid))
        guard distinctPIDs.count > 1 else {
            return first
        }

        throw ComputerUseError.ambiguousApp(query, candidates: matches.map(candidateDescription(for:)))
    }

    /// Single-match resolution with the safety policy applied to the result.
    /// A blocked app is rejected with permission-denied no matter how the
    /// query addressed it (pid, bundle identifier, or name), so a blocked
    /// target can never be reached through any query kind.
    static func safetyCheckedUniqueMatch(
        in matches: [RunningAppDescriptor],
        for query: String
    ) throws -> RunningAppDescriptor? {
        guard let unique = try uniqueMatch(in: matches, for: query) else {
            return nil
        }

        if let bundleIdentifier = unique.bundleIdentifier,
           AppSafetyPolicy.isBlocked(bundleIdentifier: bundleIdentifier) {
            throw AppSafetyPolicy.permissionDenied(bundleIdentifier: bundleIdentifier)
        }

        return unique
    }

    private static func candidateDescription(for descriptor: RunningAppDescriptor) -> String {
        let bundleIdentifier = descriptor.bundleIdentifier ?? "unknown-bundle"
        return "\(descriptor.name) — \(bundleIdentifier) (pid \(descriptor.pid))"
    }

    static func resolve(_ query: String) throws -> RunningAppDescriptor {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let running = runningApps()

        if let bundleIdentifier = blockedBundleIdentifier(forQuery: normalizedQuery) {
            throw AppSafetyPolicy.permissionDenied(bundleIdentifier: bundleIdentifier)
        }

        // A pid addresses one live process: never fall through to launching.
        if case .pid = AppTargetQuery.parse(normalizedQuery) {
            return try resolveRunning(normalizedQuery, applications: running)
        }

        if let match = resolvedRunningApp(in: running, matching: normalizedQuery) {
            return match
        }

        try launchIfPossible(normalizedQuery)

        for _ in 0..<20 {
            if let launched = resolvedRunningApp(in: runningApps(), matching: normalizedQuery) {
                return launched
            }

            Thread.sleep(forTimeInterval: 0.25)
        }

        throw ComputerUseError.appNotFound(normalizedQuery)
    }

    struct ResolutionCandidate {
        let name: String
        let executableName: String?
        let isRegularApp: Bool
    }

    private static func resolvedRunningApp(in descriptors: [RunningAppDescriptor], matching query: String) -> RunningAppDescriptor? {
        if isBundleIdentifierQuery(query) {
            return descriptors.first(where: { descriptor in
                descriptor.bundleIdentifier?.caseInsensitiveCompare(query) == .orderedSame
            })
        }

        let allowed = descriptors.filter { descriptor in
            !AppSafetyPolicy.isBlocked(bundleIdentifier: descriptor.bundleIdentifier)
        }
        let candidates = allowed.map { descriptor in
            ResolutionCandidate(
                name: descriptor.name,
                executableName: descriptor.runningApplication.executableURL?.deletingPathExtension().lastPathComponent,
                isRegularApp: descriptor.runningApplication.activationPolicy == .regular
            )
        }

        guard let index = bestResolutionIndex(of: candidates, matching: query) else {
            return nil
        }

        return allowed[index]
    }

    static func bestResolutionIndex(of candidates: [ResolutionCandidate], matching query: String) -> Int? {
        var best: (rank: Int, index: Int)?

        for (index, candidate) in candidates.enumerated() {
            let rank: Int?
            if candidate.isRegularApp, candidate.name.caseInsensitiveCompare(query) == .orderedSame {
                rank = 0
            } else if candidate.isRegularApp, candidate.executableName?.caseInsensitiveCompare(query) == .orderedSame {
                rank = 1
            } else if candidate.name.caseInsensitiveCompare(query) == .orderedSame {
                rank = 2
            } else if candidate.executableName?.caseInsensitiveCompare(query) == .orderedSame {
                rank = 3
            } else {
                rank = nil
            }

            guard let rank else {
                continue
            }

            if let current = best, rank >= current.rank {
                continue
            }

            best = (rank, index)
            if rank == 0 {
                break
            }
        }

        return best?.index
    }

    private static func userFacingRunningApps() -> [RunningAppDescriptor] {
        var seen: Set<String> = []
        var descriptors: [RunningAppDescriptor] = []

        for descriptor in runningApps() {
            guard isUserFacingListApp(descriptor.runningApplication) else {
                continue
            }

            guard let bundleIdentifier = listedBundleIdentifier(for: descriptor) else {
                continue
            }

            let key = bundleIdentifier.lowercased()
            guard seen.insert(key).inserted else {
                continue
            }

            descriptors.append(descriptor)
        }

        return descriptors
    }

    private static func listedBundleIdentifier(for descriptor: RunningAppDescriptor) -> String? {
        if let bundleIdentifier = descriptor.bundleIdentifier, !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        guard descriptor.name == FixtureBridge.appName else {
            return nil
        }

        return fixtureListBundleIdentifier
    }

    /// Machine-readable payload for the `targets` CLI command.
    static func targetsPayload(runningOnly: Bool) -> [[String: Any]] {
        if runningOnly {
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            return runningTargetsPayload(from: runningApps(), frontmostPID: frontmostPID)
        }

        return listCatalog().map { descriptor in
            var entry: [String: Any] = [
                "name": descriptor.name,
                "bundle_id": descriptor.bundleIdentifier,
                "running": descriptor.isRunning,
                "frontmost": descriptor.isFrontmost,
            ]
            if let lastUsed = descriptor.lastUsed {
                entry["last_used"] = usageDateFormatter.string(from: lastUsed)
            }
            if let uses = descriptor.uses {
                entry["uses"] = uses
            }
            return entry
        }
    }

    /// Running-only target entries with safety-blocked apps removed:
    /// discovery payloads never expose blocked apps or their PIDs.
    static func runningTargetsPayload(
        from descriptors: [RunningAppDescriptor],
        frontmostPID: pid_t?
    ) -> [[String: Any]] {
        descriptors
            .filter { !AppSafetyPolicy.isBlocked(bundleIdentifier: $0.bundleIdentifier) }
            .map { descriptor in
                var entry: [String: Any] = [
                    "name": descriptor.name,
                    "pid": Int(descriptor.pid),
                    "running": true,
                    "frontmost": descriptor.pid == frontmostPID,
                ]
                if let bundleIdentifier = descriptor.bundleIdentifier {
                    entry["bundle_id"] = bundleIdentifier
                }
                return entry
            }
    }

    static func compareListedApps(_ lhs: ListedAppDescriptor, _ rhs: ListedAppDescriptor) -> Bool {
        if lhs.isFrontmost != rhs.isFrontmost {
            return lhs.isFrontmost && !rhs.isFrontmost
        }

        if lhs.isRunning != rhs.isRunning {
            return lhs.isRunning && !rhs.isRunning
        }

        let lhsHasUsage = lhs.lastUsed != nil
        let rhsHasUsage = rhs.lastUsed != nil
        if lhsHasUsage != rhsHasUsage {
            return lhsHasUsage && !rhsHasUsage
        }

        let calendar = Calendar(identifier: .gregorian)
        if let lhsLast = lhs.lastUsed, let rhsLast = rhs.lastUsed {
            let lhsDay = calendar.startOfDay(for: lhsLast)
            let rhsDay = calendar.startOfDay(for: rhsLast)
            if lhsDay != rhsDay {
                return lhsDay > rhsDay
            }
        }

        if let lhsUses = lhs.uses, let rhsUses = rhs.uses, lhsUses != rhsUses {
            return lhsUses > rhsUses
        }

        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static func launchIfPossible(_ query: String) throws {
        if isBundleIdentifierQuery(query) {
            guard !AppSafetyPolicy.isBlocked(bundleIdentifier: query) else {
                return
            }

            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query) {
                try openApplication(at: appURL)
            }
            return
        }

        guard let appURL = applicationURL(named: query) else {
            return
        }

        if AppSafetyPolicy.isBlocked(bundleIdentifier: Bundle(url: appURL)?.bundleIdentifier) {
            return
        }

        try openApplication(at: appURL)
    }

    private static func applicationURL(named query: String) -> URL? {
        let targetName = stripAppSuffix(from: query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetName.isEmpty else {
            return nil
        }

        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isApplicationKey, .isDirectoryKey, .nameKey]
        var visitedPaths: Set<String> = []

        for root in standardApplicationSearchRoots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let candidateURL as URL in enumerator {
                guard candidateURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
                    continue
                }

                let normalizedPath = candidateURL.standardizedFileURL.path.lowercased()
                guard visitedPaths.insert(normalizedPath).inserted else {
                    continue
                }

                let candidateName = stripAppSuffix(from: candidateURL.lastPathComponent)
                if candidateName.caseInsensitiveCompare(targetName) == .orderedSame {
                    return candidateURL
                }
            }
        }

        return nil
    }

    private static func openApplication(at appURL: URL) throws {
        let configuration = NSWorkspace.OpenConfiguration()
        // A launch must not take the keyboard from the app the person is using.
        configuration.activates = foregroundActivationAllowed()
        let semaphore = DispatchSemaphore(value: 0)
        let errorBox = LaunchErrorBox()

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            errorBox.error = error
            semaphore.signal()
        }

        waitForSignal(semaphore)

        if let launchError = errorBox.error {
            throw launchError
        }
    }

    private static func waitForSignal(_ semaphore: DispatchSemaphore) {
        if Thread.isMainThread {
            while semaphore.wait(timeout: .now()) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            }
            return
        }

        semaphore.wait()
    }

    private final class LaunchErrorBox: @unchecked Sendable {
        var error: Error?
    }

    private static func recentUsageCutoff(referenceDate: Date = Date()) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        let startOfToday = calendar.startOfDay(for: referenceDate)
        return calendar.date(byAdding: .day, value: -13, to: startOfToday) ?? startOfToday
    }

    private static func blockedBundleIdentifier(forQuery query: String) -> String? {
        guard isBundleIdentifierQuery(query), AppSafetyPolicy.isBlocked(bundleIdentifier: query) else {
            return nil
        }

        return query
    }

    private static func isBundleIdentifierQuery(_ query: String) -> Bool {
        query.contains(".")
    }

    private static func isUserFacingListApp(_ app: NSRunningApplication) -> Bool {
        if appName(app) == FixtureBridge.appName {
            return true
        }

        return app.activationPolicy == .regular
    }

    private static func bundleDisplayName(_ bundle: Bundle?) -> String? {
        guard let bundle else {
            return nil
        }

        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let bundleName = bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String
        return displayName ?? bundleName
    }

    private static func stripAppSuffix(from value: String) -> String {
        value.hasSuffix(".app") ? String(value.dropLast(4)) : value
    }

    static func appName(_ app: NSRunningApplication) -> String {
        app.localizedName
            ?? bundleDisplayName(Bundle(url: app.bundleURL ?? URL(fileURLWithPath: "/")))
            ?? app.bundleURL?.deletingPathExtension().lastPathComponent
            ?? app.executableURL?.lastPathComponent
            ?? "pid-\(app.processIdentifier)"
    }

    private enum SpotlightAppIndex {
        static func recentApps(cutoffDate: Date) -> [SpotlightAppRecord] {
            let sortingAttributes = [
                lastUsedDateRankingAttribute as CFString,
                useCountAttribute as CFString,
            ] as CFArray

            guard let query = MDQueryCreate(
                kCFAllocatorDefault,
                listAppsQuery as CFString,
                nil,
                sortingAttributes
            ) else {
                return []
            }

            MDQuerySetSearchScope(query, standardSearchScopes() as CFArray, 0)
            MDQuerySetSortOptionFlagsForAttribute(query, lastUsedDateRankingAttribute as CFString, kMDQueryReverseSortOrderFlag.rawValue)
            MDQuerySetSortOptionFlagsForAttribute(query, useCountAttribute as CFString, kMDQueryReverseSortOrderFlag.rawValue)

            guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else {
                return []
            }

            var seen: Set<String> = []
            var records: [SpotlightAppRecord] = []

            for index in 0..<MDQueryGetResultCount(query) {
                guard let rawResult = MDQueryGetResultAtIndex(query, index) else {
                    continue
                }

                let item = unsafeBitCast(rawResult, to: MDItem.self)
                guard
                    let bundleIdentifier = stringAttribute(kMDItemCFBundleIdentifier, item: item),
                    !bundleIdentifier.isEmpty
                else {
                    continue
                }

                let key = bundleIdentifier.lowercased()
                guard seen.insert(key).inserted else {
                    continue
                }

                guard let path = stringAttribute(kMDItemPath, item: item) else {
                    continue
                }

                let appURL = URL(fileURLWithPath: path)
                let bundle = Bundle(url: appURL)
                if bundle?.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool == true {
                    continue
                }
                if bundle?.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true {
                    continue
                }

                let lastUsed = dateAttribute(lastUsedDateRankingAttribute as CFString, item: item)
                    ?? dateAttribute(kMDItemLastUsedDate, item: item)
                guard let lastUsed, lastUsed >= cutoffDate else {
                    continue
                }

                let uses = numberAttribute(useCountAttribute as CFString, item: item)?.intValue
                let displayName = bundleDisplayName(bundle)
                    ?? stringAttribute(kMDItemDisplayName, item: item).map(stripAppSuffix(from:))
                    ?? stripAppSuffix(from: appURL.lastPathComponent)

                records.append(
                    SpotlightAppRecord(
                        name: displayName,
                        bundleIdentifier: bundleIdentifier,
                        lastUsed: lastUsed,
                        uses: uses
                    )
                )
            }

            return records
        }

        private static func standardSearchScopes() -> [CFString] {
            var scopes: [String] = [
                "/Applications",
                "/System/Applications",
                "/System/Library/CoreServices",
            ]

            let homeApplications = NSString(string: "~/Applications").expandingTildeInPath
            if FileManager.default.fileExists(atPath: homeApplications) {
                scopes.append(homeApplications)
            }

            return scopes as [CFString]
        }

        private static func stringAttribute(_ name: CFString, item: MDItem) -> String? {
            MDItemCopyAttribute(item, name) as? String
        }

        private static func numberAttribute(_ name: CFString, item: MDItem) -> NSNumber? {
            MDItemCopyAttribute(item, name) as? NSNumber
        }

        private static func dateAttribute(_ name: CFString, item: MDItem) -> Date? {
            MDItemCopyAttribute(item, name) as? Date
        }
    }
}

/// JSON payload for the `targets` CLI command.
public func ultraTermComputerUseTargetsPayload(runningOnly: Bool) -> [[String: Any]] {
    AppDiscovery.targetsPayload(runningOnly: runningOnly)
}

/// Human-readable listing for the `targets` CLI command.
public func ultraTermComputerUseTargetsText(runningOnly: Bool) -> String {
    let catalog = AppDiscovery.listCatalog()
    let entries = runningOnly ? catalog.filter(\.isRunning) : catalog
    return entries.map(\.renderedLine).joined(separator: "\n")
}

enum AppSafetyPolicy {
    /// Entries are normalized lowercase; matching is case-insensitive.
    private static let blockedBundleIdentifiers: Set<String> = [
        "com.1password.1password",
        "com.1password.safari",
        "com.apple.keychainaccess",
        "com.apple.passwordmanagerbrowserextensionhelper",
        "com.apple.passwords",
        "com.apple.passwords.menubarextra",
        "com.bitwarden.desktop",
        "com.dashlane.dashlanephonefinal",
        "com.lastpass.lastpass",
        "com.nordsec.nordpass",
        "me.proton.pass.electron",
        "me.proton.pass.catalyst",
    ]

    static func isBlocked(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else {
            return false
        }

        let normalized = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return blockedBundleIdentifiers.contains(normalized)
    }

    static func permissionDenied(bundleIdentifier: String) -> ComputerUseError {
        .permissionDenied("Computer Use is not allowed to use the app '\(bundleIdentifier)' for safety reasons.")
    }
}
