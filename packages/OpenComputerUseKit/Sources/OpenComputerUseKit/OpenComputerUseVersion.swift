import Foundation

public let openComputerUseVersion = "0.1.39"

public func resolvedOpenComputerUseVersion(bundle: Bundle = .main) -> String {
    if let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
       !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return version
    }

    return openComputerUseVersion
}
