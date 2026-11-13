import Foundation

/// The runtime works in the background: by default it never activates an app, raises or
/// unminimizes a window, or unhides an app, because each of those takes the screen or the
/// keyboard away from the person using the computer. Set this to 1 to allow them.
public let foregroundActivationEnvironmentKey = "ULTRATERM_COMPUTER_USE_ALLOW_FOREGROUND"

func foregroundActivationAllowed(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    guard let rawValue = environment[foregroundActivationEnvironmentKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    else {
        return false
    }

    return ["1", "true", "yes", "on"].contains(rawValue)
}

/// A snapshot may only recover a missing window by activating the app when the caller asked
/// for that and the process allows foreground changes.
func effectiveSnapshotRecoveryPolicy(
    _ requested: SnapshotRecoveryPolicy,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> SnapshotRecoveryPolicy {
    requested == .allowActivation && foregroundActivationAllowed(environment: environment) ? .allowActivation : .readOnly
}

let computerUseBackgroundWindowUnavailableMessage =
    "The app has no window that can be read in the background (it is hidden, minimized, has no open window, "
    + "or did not answer in time). Nothing was changed. Call get_app_state again; if it keeps failing, set "
    + "\(foregroundActivationEnvironmentKey)=1 to let the runtime unhide, unminimize and raise it."

/// Background reads never activate the app to recover, so one accessibility call that times
/// out on a busy machine would otherwise be reported as "no window". Read again a few times
/// first: this only reads, and gives up after about 0.75 s.
let backgroundReadRetryDelays: [TimeInterval] = [0.1, 0.25, 0.4]

func retryingBackgroundRead<T>(
    delays: [TimeInterval] = backgroundReadRetryDelays,
    sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    _ read: () -> T?
) -> T? {
    if let value = read() { return value }
    for delay in delays {
        sleep(delay)
        if let value = read() { return value }
    }
    return nil
}

/// The message for a snapshot that found no usable window, by what the policy allowed.
func noWindowFoundMessage(for policy: SnapshotRecoveryPolicy) -> String {
    policy == .allowActivation ? computerUseNoWindowFoundMessage : computerUseBackgroundWindowUnavailableMessage
}

/// Accessibility actions whose whole effect is to bring a window in front of the person's work.
func secondaryActionTakesForeground(_ rawAction: String) -> Bool {
    rawAction.caseInsensitiveCompare("AXRaise") == .orderedSame
}

/// Refuses a foreground action before it is sent unless the process allows foreground changes.
func requireForegroundAllowed(
    forSecondaryAction rawAction: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws {
    guard secondaryActionTakesForeground(rawAction), !foregroundActivationAllowed(environment: environment) else {
        return
    }
    throw ComputerUseError.message(
        "The Raise action brings a window in front of what the person is doing, so it is off by default. "
        + "Nothing was sent. Set \(foregroundActivationEnvironmentKey)=1 to allow it."
    )
}

/// A new opaque identifier for one captured state of an app.
func makeSnapshotStateID() -> String {
    var bytes = [UInt8](repeating: 0, count: 6)
    for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
    return bytes.map { String(format: "%02x", $0) }.joined()
}

public let stateIDArgumentDescription =
    "state_id from the latest get_app_state or action result for this app. When given, the action is refused with stale_state before anything is sent if the app's state has been captured again since."
