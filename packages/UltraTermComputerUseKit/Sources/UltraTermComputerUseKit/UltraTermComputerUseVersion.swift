import Foundation

public let ultraTermComputerUseVersion = "0.5.0"

public func resolvedUltraTermComputerUseVersion(bundle: Bundle = .main) -> String {
    if let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
       !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return version
    }

    return ultraTermComputerUseVersion
}
