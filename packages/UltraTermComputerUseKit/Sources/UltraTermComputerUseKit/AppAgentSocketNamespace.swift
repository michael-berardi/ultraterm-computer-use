import CryptoKit
import Foundation

public let ultraTermComputerUseAppAgentSocketNamespaceEnvironmentKey = "ULTRATERM_COMPUTER_USE_AGENT_SOCKET_NAMESPACE"

public func ultraTermComputerUseAppAgentSocketFileName(namespace: String?) -> String {
    guard let namespace = namespace?.trimmingCharacters(in: .whitespacesAndNewlines), !namespace.isEmpty else {
        return "ultraterm-computer-use-agent.sock"
    }

    let digest = SHA256.hash(data: Data(namespace.utf8))
    let identifier = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    return "ultraterm-computer-use-agent-\(identifier).sock"
}
