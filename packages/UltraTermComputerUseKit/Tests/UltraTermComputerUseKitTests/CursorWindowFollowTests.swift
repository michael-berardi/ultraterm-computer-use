import AppKit
import XCTest
@testable import UltraTermComputerUseKit

final class CursorWindowFollowTests: XCTestCase {
    @MainActor
    private final class Counter: NSObject {
        var count = 0
        @objc func increment() { count += 1 }
    }
    private final class Frame: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CGRect
        init(_ value: CGRect) { stored = value }
        var value: CGRect {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); defer { lock.unlock() }; stored = newValue }
        }
    }
    @MainActor
    private func withOverlay(_ body: (URL, CGRect) throws -> Void) throws {
        guard let screen = currentVisualCursorScreenMappings().first?.screenStateFrame else {
            throw XCTSkip("A WindowServer display is required for overlay rendering")
        }
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ocu-cursor-follow-\(UUID().uuidString).json")
        let previous = ProcessInfo.processInfo.environment
        setenv("ULTRATERM_COMPUTER_USE_VISUAL_CURSOR", "1", 1)
        setenv("ULTRATERM_COMPUTER_USE_VISUAL_CURSOR_OBSERVATION_FILE", file.path, 1)
        setenv("ULTRATERM_COMPUTER_USE_ACTION_READ_BACK", "0", 1)
        SoftwareCursorOverlay.moveCursor(to: defaultVisualCursorInitialTipPosition(), in: nil)
        SoftwareCursorOverlay.reset()
        defer {
            SoftwareCursorOverlay.reset()
            CursorWindowFrameTracker.installFrameOverrideForTesting(nil)
            CursorWindowFrameTracker.forgetAll()
            for key in ["ULTRATERM_COMPUTER_USE_VISUAL_CURSOR", "ULTRATERM_COMPUTER_USE_VISUAL_CURSOR_OBSERVATION_FILE", "ULTRATERM_COMPUTER_USE_ACTION_READ_BACK"] {
                if let value = previous[key] { setenv(key, value, 1) } else { unsetenv(key) }
            }
            try? FileManager.default.removeItem(at: file)
        }
        try body(file, CGRect(x: screen.minX + 100, y: screen.minY + 100, width: 200, height: 160))
    }

    private func anchor(_ frame: CGRect) -> CursorRestingAnchor {
        .init(windowID: 4242, layer: 0, windowLocalPoint: CGPoint(x: 40, y: 50), windowBounds: frame)
    }

    @MainActor
    private func point(_ frame: CGRect) -> CGPoint {
        screenStatePointToAppKitGlobalPoint(fromScreenStatePoint: CGPoint(x: frame.minX + 40, y: frame.minY + 50))
    }

    @MainActor
    private func assertPosition(_ file: URL, frame: CGRect, file testFile: StaticString = #filePath, line: UInt = #line) throws {
        let state = try JSONDecoder().decode(VisualCursorObservationSnapshot.self, from: Data(contentsOf: file))
        let expected = point(frame)
        XCTAssertEqual(try XCTUnwrap(state.restingTipPosition).x, expected.x, accuracy: 1, file: testFile, line: line)
        XCTAssertEqual(try XCTUnwrap(state.restingTipPosition).y, expected.y, accuracy: 1, file: testFile, line: line)
        XCTAssertEqual(try XCTUnwrap(state.tipPosition).x, expected.x, accuracy: 1, file: testFile, line: line)
        XCTAssertEqual(try XCTUnwrap(state.tipPosition).y, expected.y, accuracy: 1, file: testFile, line: line)
    }

    /// Waits, bounded, for the idle animation to publish `frame`'s point, then
    /// asserts it. Only the overlay's idle timer can update the observation
    /// here, so a fixed sleep would test timer slack instead of following.
    @MainActor
    private func awaitPosition(_ file: URL, frame: CGRect, file testFile: StaticString = #filePath, line: UInt = #line) throws {
        let expected = point(frame)
        func matches(_ point: VisualCursorObservationPoint?) -> Bool {
            guard let point else { return false }
            return abs(point.x - expected.x) <= 1 && abs(point.y - expected.y) <= 1
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let state = try? JSONDecoder().decode(VisualCursorObservationSnapshot.self, from: Data(contentsOf: file)),
               matches(state.restingTipPosition), matches(state.tipPosition) {
                break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        try assertPosition(file, frame: frame, file: testFile, line: line)
    }

    /// Runs `body` once, inside the first overlay frame pump at least `delay`
    /// seconds from now. Invalidate the result once the overlay call returns.
    ///
    /// A wall-clock `Timer` cannot reliably land inside a 0.18 s travel: when
    /// the runner inherits utility QoS (as under a headless agent), the kernel
    /// coalesces timers. Measured there: an 8 ms sleep took 39-71 ms, each
    /// 1/120 s pump about 57 ms, and a 0.08 s timer fired at 0.23 s, after the
    /// travel had ended. The overlay pumps the main run loop in default mode
    /// once per frame, so an entry observer fires within that pump regardless.
    @MainActor
    private func onOverlayFrame(after delay: TimeInterval = 0, _ body: @escaping @MainActor () -> Void) -> CFRunLoopObserver {
        let start = ProcessInfo.processInfo.systemUptime
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.entry.rawValue, true, 0) { observer, _ in
            guard ProcessInfo.processInfo.systemUptime - start >= delay else { return }
            CFRunLoopObserverInvalidate(observer)
            MainActor.assumeIsolated { body() }
        }!
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .defaultMode)
        return observer
    }

    @MainActor
    func testIdleFollowsRepeatedMovesAndReturnToOriginalFrame() throws {
        try withOverlay { file, original in
            let live = Frame(original)
            CursorWindowFrameTracker.installFrameOverrideForTesting { _ in live.value }
            SoftwareCursorOverlay.settle(at: point(original), in: nil, anchor: anchor(original))
            for frame in [original.offsetBy(dx: 240, dy: 80), original.offsetBy(dx: 80, dy: 160), original] {
                live.value = frame
                try awaitPosition(file, frame: frame)
            }
        }
    }

    @MainActor
    func testClickPulseTracksMovesDuringBothClicks() throws {
        try withOverlay { file, original in
            let live = Frame(original)
            CursorWindowFrameTracker.installFrameOverrideForTesting { _ in live.value }
            SoftwareCursorOverlay.settle(at: point(original), in: nil, anchor: anchor(original))
            // First click spans 0-0.16 s, the second starts after a 0.05 s pause.
            let first = onOverlayFrame { live.value = original.offsetBy(dx: 180, dy: 40) }
            let second = onOverlayFrame(after: 0.24) { live.value = original.offsetBy(dx: 260, dy: 100) }
            SoftwareCursorOverlay.pulseClick(at: point(original), clickCount: 2, mouseButton: .left, in: nil, anchor: anchor(original))
            XCTAssertFalse(CFRunLoopObserverIsValid(first), "No pulse frame ran during the first click")
            XCTAssertFalse(CFRunLoopObserverIsValid(second), "No pulse frame ran during the second click")
            CFRunLoopObserverInvalidate(first)
            CFRunLoopObserverInvalidate(second)
            try assertPosition(file, frame: original.offsetBy(dx: 260, dy: 100))
        }
    }

    @MainActor
    func testTravelAbortActuallyPlacesVisibleTipAtMovedWindow() throws {
        try withOverlay { file, original in
            let live = Frame(original)
            CursorWindowFrameTracker.installFrameOverrideForTesting { _ in live.value }
            let move = onOverlayFrame { live.value = original.offsetBy(dx: 240, dy: 100) }
            SoftwareCursorOverlay.moveCursor(to: point(original), in: nil, anchor: anchor(original))
            XCTAssertFalse(CFRunLoopObserverIsValid(move), "The travel never pumped a frame")
            CFRunLoopObserverInvalidate(move)
            try assertPosition(file, frame: original.offsetBy(dx: 240, dy: 100))
            // The next pipeline stage must not restore the snapshot's old point.
            SoftwareCursorOverlay.settle(at: point(original), in: nil, anchor: anchor(original))
            try assertPosition(file, frame: live.value)
        }
    }

    @MainActor
    func testUnanchoredTargetDoesNotKeepPreviousWindowTracking() throws {
        try withOverlay { file, original in
            let live = Frame(original)
            CursorWindowFrameTracker.installFrameOverrideForTesting { _ in live.value }
            SoftwareCursorOverlay.settle(at: point(original), in: nil, anchor: anchor(original))
            SoftwareCursorOverlay.settle(at: point(original), in: nil)
            live.value = original.offsetBy(dx: 240, dy: 100)
            // Several idle ticks, even with coalesced timers (see onOverlayFrame).
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            try assertPosition(file, frame: original)
        }
    }

    @MainActor
    func testResetAfterPulseDoesNotLeaveAnIdleTimerRepainting() throws {
        try withOverlay { file, original in
            CursorWindowFrameTracker.installFrameOverrideForTesting { _ in original }
            SoftwareCursorOverlay.settle(at: point(original), in: nil, anchor: anchor(original))
            SoftwareCursorOverlay.pulseClick(at: point(original), clickCount: 1, mouseButton: .left, in: nil, anchor: anchor(original))
            SoftwareCursorOverlay.reset()
            // Several idle ticks, even with coalesced timers (see onOverlayFrame).
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let state = try JSONDecoder().decode(VisualCursorObservationSnapshot.self, from: Data(contentsOf: file))
            XCTAssertEqual(state.phase, "hidden")
            XCTAssertNil(state.tipPosition)
            XCTAssertNil(state.restingTipPosition)
        }
    }

    @MainActor
    func testWindowAlreadyMovedBeforeTravelDoesNotAbortAgainstOriginalSnapshot() throws {
        try withOverlay { _, original in
            let moved = original.offsetBy(dx: 240, dy: 100)
            CursorWindowFrameTracker.installFrameOverrideForTesting { _ in moved }
            let start = ProcessInfo.processInfo.systemUptime
            SoftwareCursorOverlay.moveCursor(to: point(original), in: nil, anchor: anchor(original))
            // An aborted move returns at once; a full one takes the configured move duration.
            XCTAssertGreaterThan(ProcessInfo.processInfo.systemUptime - start, defaultVisualCursorMoveDuration * 0.9)
        }
    }

    @MainActor
    func testServiceClickRegistersLiveWindowAndFeedbackMatchesMovedButton() throws {
        do { try requireUsableComputerUseSession() }
        catch { throw XCTSkip("Service integration requires an unlocked session and a trusted test host: \(error)") }
        try withOverlay { file, original in
            let counter = Counter()
            let window = NSWindow(contentRect: original, styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "OCU service click fixture"
            window.isReleasedWhenClosed = false
            let button = NSButton(title: "OCU follow click", target: counter, action: #selector(Counter.increment))
            button.frame = CGRect(x: 20, y: 20, width: 140, height: 32)
            window.contentView?.addSubview(button)
            NSApplication.shared.finishLaunching()
            window.orderFront(nil)
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            guard AXIsProcessTrusted(), let app = AppDiscovery.runningApps().first(where: { $0.pid == getpid() }) else {
                throw XCTSkip("Live AX test application is unavailable")
            }
            let service = ComputerUseService()
            let result = try service.query(app: app.bundleIdentifier ?? app.name, text: button.title, role: "button",
                                           exact: true, windowID: CGWindowID(window.windowNumber))
            let matches = try XCTUnwrap(result["matches"] as? [[String: Any]])
            XCTAssertEqual(matches.count, 1)
            let index = try XCTUnwrap(matches.first?["index"] as? Int)
            let move = onOverlayFrame(after: 0.08) {
                window.setFrameOrigin(CGPoint(x: original.minX + 240, y: original.minY + 80))
            }
            defer { CFRunLoopObserverInvalidate(move) }
            _ = try service.click(app: app.bundleIdentifier ?? app.name, elementIndex: String(index),
                                  x: nil, y: nil, clickCount: 1, mouseButton: "left", clickMethod: .accessibility)
            XCTAssertFalse(CFRunLoopObserverIsValid(move), "The window must move while the click is still animating")
            XCTAssertEqual(counter.count, 1, "The real AX button action must still execute exactly once")
            let state = try JSONDecoder().decode(VisualCursorObservationSnapshot.self, from: Data(contentsOf: file))
            let expected = window.convertPoint(toScreen: CGPoint(x: button.frame.midX, y: button.frame.midY))
            XCTAssertEqual(try XCTUnwrap(state.tipPosition).x, expected.x, accuracy: 1)
            XCTAssertEqual(try XCTUnwrap(state.tipPosition).y, expected.y, accuracy: 1)
            XCTAssertEqual(try XCTUnwrap(state.restingTipPosition).x, expected.x, accuracy: 1)
            XCTAssertEqual(try XCTUnwrap(state.restingTipPosition).y, expected.y, accuracy: 1)
        }
    }

    @MainActor
    func testRealAccessibilityWindowFollowsTravelPulseAndIdleAcrossDisplays() throws {
        try withOverlay { file, original in
            let window = NSWindow(contentRect: original, styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "OCU cursor follow fixture \(UUID().uuidString)"
            window.isReleasedWhenClosed = false
            NSApplication.shared.finishLaunching()
            window.orderFront(nil)
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let application = AXUIElementCreateApplication(getpid())
            var raw: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &raw)
            guard status == .success,
                  let windows = raw as? [AXUIElement],
                  let element = windows.first(where: { element in
                      var title: CFTypeRef?
                      return AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success &&
                          title as? String == window.title
                  })
            else { throw XCTSkip("Live self-AX window access unavailable (AX status \(status.rawValue), trusted \(AXIsProcessTrusted()))") }
            let id = CGWindowID(window.windowNumber)
            CursorWindowFrameTracker.register(windowID: id, element: element)
            func awaitFrame(_ predicate: (CGRect) -> Bool) throws -> CGRect {
                let deadline = Date().addingTimeInterval(1)
                while Date() < deadline {
                    if let frame = CursorWindowFrameTracker.liveFrame(for: id), predicate(frame) { return frame }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                }
                XCTFail("Real AX frame was not observed before deadline")
                throw NSError(domain: "CursorFollowTests", code: 1)
            }
            let initial = try awaitFrame { _ in true }
            let targetAnchor = CursorRestingAnchor(windowID: id, layer: 0, windowLocalPoint: CGPoint(x: 40, y: 50), windowBounds: initial)
            // Move the real window from inside the travel's own frame pump (see
            // onOverlayFrame). The longest allowed travel leaves room for the
            // real AX read however coarse the runner's timers are; returning
            // well before it proves the travel was aborted by the live frame
            // rather than run to the snapshot point.
            let previousMoveDuration = ProcessInfo.processInfo.environment[visualCursorMoveDurationEnvironmentKey]
            setenv(visualCursorMoveDurationEnvironmentKey, String(maximumVisualCursorMoveDuration), 1)
            defer {
                if let previousMoveDuration { setenv(visualCursorMoveDurationEnvironmentKey, previousMoveDuration, 1) }
                else { unsetenv(visualCursorMoveDurationEnvironmentKey) }
            }
            let move = onOverlayFrame {
                window.setFrameOrigin(CGPoint(x: original.minX + 200, y: original.minY + 40))
            }
            let travelStart = ProcessInfo.processInfo.systemUptime
            SoftwareCursorOverlay.moveCursor(to: point(initial), in: nil, anchor: targetAnchor)
            let travelTime = ProcessInfo.processInfo.systemUptime - travelStart
            XCTAssertFalse(CFRunLoopObserverIsValid(move), "The travel never pumped a frame")
            CFRunLoopObserverInvalidate(move)
            XCTAssertLessThan(travelTime, maximumVisualCursorMoveDuration / 2,
                              "Travel ran on instead of aborting at the window's real AX frame")
            let afterTravel = try awaitFrame { abs($0.minX - (initial.minX + 200)) < 1 }
            try assertPosition(file, frame: afterTravel)
            SoftwareCursorOverlay.settle(at: point(initial), in: nil, anchor: targetAnchor)
            try assertPosition(file, frame: afterTravel)
            let duringPulse = onOverlayFrame {
                window.setFrameOrigin(CGPoint(x: original.minX + 260, y: original.minY + 100))
            }
            SoftwareCursorOverlay.pulseClick(at: point(initial), clickCount: 2, mouseButton: .left, in: nil, anchor: targetAnchor)
            XCTAssertFalse(CFRunLoopObserverIsValid(duringPulse), "The pulse never pumped a frame")
            CFRunLoopObserverInvalidate(duringPulse)
            let afterPulse = try awaitFrame { abs($0.minX - (initial.minX + 260)) < 1 }
            try assertPosition(file, frame: afterPulse)
            for offset in [CGPoint(x: 220, y: 60), CGPoint(x: 100, y: 140), .zero] {
                window.setFrameOrigin(CGPoint(x: original.minX + offset.x, y: original.minY + offset.y))
                let moved = try awaitFrame { abs($0.minX - (initial.minX + offset.x)) < 1 }
                try awaitPosition(file, frame: moved)
            }
            for mapping in currentVisualCursorScreenMappings() {
                window.setFrameOrigin(CGPoint(x: mapping.appKitFrame.minX + 120, y: mapping.appKitFrame.minY + 120))
                let moved = try awaitFrame { abs($0.minX - (mapping.screenStateFrame.minX + 120)) < 1 }
                try awaitPosition(file, frame: moved)
            }
            print("Live AX cursor following verified on \(currentVisualCursorScreenMappings().count) display(s).")
        }
    }
}
