import XCTest
@testable import UltraTermComputerUseKit

/// Visual cursor trigger policy and timing bounds. All policy entry points are
/// exercised with a nil target, which is the headless no-op path: no overlay
/// window is created, no UI is touched.
final class CursorPolicyContractTests: XCTestCase {
    // MARK: Move duration environment configuration

    func testMoveDurationDefaultsWhenUnsetOrInvalid() {
        XCTAssertEqual(visualCursorMoveDuration(environment: [:]), defaultVisualCursorMoveDuration)
        XCTAssertEqual(visualCursorMoveDuration(environment: [visualCursorMoveDurationEnvironmentKey: ""]), defaultVisualCursorMoveDuration)
        XCTAssertEqual(visualCursorMoveDuration(environment: [visualCursorMoveDurationEnvironmentKey: "   "]), defaultVisualCursorMoveDuration)
        XCTAssertEqual(visualCursorMoveDuration(environment: [visualCursorMoveDurationEnvironmentKey: "fast"]), defaultVisualCursorMoveDuration)
        XCTAssertEqual(visualCursorMoveDuration(environment: [visualCursorMoveDurationEnvironmentKey: "nan"]), defaultVisualCursorMoveDuration)
        XCTAssertEqual(visualCursorMoveDuration(environment: [visualCursorMoveDurationEnvironmentKey: "inf"]), defaultVisualCursorMoveDuration)
    }

    func testMoveDurationParsesExplicitSeconds() {
        XCTAssertEqual(visualCursorMoveDuration(environment: [visualCursorMoveDurationEnvironmentKey: "0.5"]), 0.5)
        XCTAssertEqual(visualCursorMoveDuration(environment: [visualCursorMoveDurationEnvironmentKey: " 0.25 "]), 0.25)
    }

    func testMoveDurationIsClampedToTimingBounds() {
        XCTAssertEqual(defaultVisualCursorMoveDuration, 0.18)
        XCTAssertEqual(maximumVisualCursorMoveDuration, 2.0)

        XCTAssertEqual(visualCursorMoveDuration(environment: [visualCursorMoveDurationEnvironmentKey: "10"]), 2.0)
        XCTAssertEqual(visualCursorMoveDuration(environment: [visualCursorMoveDurationEnvironmentKey: "-1"]), 0)
        XCTAssertEqual(visualCursorMoveDuration(environment: [visualCursorMoveDurationEnvironmentKey: "0"]), 0)
    }

    // MARK: Idle cadence

    // The idle sway runs at 20 Hz with a fixed phase step (3 phase units per second).
    func testIdleUpdateIntervalStaysAtOrBelow20Hz() {
        XCTAssertEqual(visualCursorIdleUpdateInterval, 1.0 / 20.0)
    }

    func testIdlePhaseRatePreservesLegacyVisualSpeed() {
        // 0.05 per tick at 60 Hz = 3.0 per second.
        XCTAssertEqual(Double(visualCursorIdlePhaseStep) / visualCursorIdleUpdateInterval, 3.0, accuracy: 0.0001)
    }

    // MARK: Observation write dedup

    private func signature(
        phase: String = "idle",
        tip: VisualCursorObservationPoint? = nil,
        resting: VisualCursorObservationPoint? = nil,
        rotation: Double? = nil
    ) -> VisualCursorObservationSignature {
        VisualCursorObservationSignature(
            phase: phase,
            tipPosition: tip,
            restingTipPosition: resting,
            rotation: rotation
        )
    }

    func testObservationWrittenWhenNoPreviousSignature() {
        XCTAssertTrue(shouldWriteVisualCursorObservation(last: nil, next: signature()))
    }

    func testObservationSkippedWhenSignatureUnchanged() {
        let last = signature(phase: "moving", tip: VisualCursorObservationPoint(point: CGPoint(x: 1, y: 2)))
        let next = signature(phase: "moving", tip: VisualCursorObservationPoint(point: CGPoint(x: 1, y: 2)))

        XCTAssertFalse(shouldWriteVisualCursorObservation(last: last, next: next))
    }

    func testObservationWrittenOnAnyTrackedFieldChange() {
        let base = signature(tip: VisualCursorObservationPoint(point: CGPoint(x: 1, y: 2)), rotation: 0.5)

        XCTAssertTrue(shouldWriteVisualCursorObservation(last: base, next: signature(phase: "moving", tip: VisualCursorObservationPoint(point: CGPoint(x: 1, y: 2)), rotation: 0.5)))
        XCTAssertTrue(shouldWriteVisualCursorObservation(last: base, next: signature(tip: VisualCursorObservationPoint(point: CGPoint(x: 2, y: 2)), rotation: 0.5)))
        XCTAssertTrue(shouldWriteVisualCursorObservation(last: base, next: signature(tip: VisualCursorObservationPoint(point: CGPoint(x: 1, y: 2)), rotation: 0.6)))
        XCTAssertTrue(shouldWriteVisualCursorObservation(last: base, next: signature(tip: nil, rotation: 0.5)))
    }

    func testObservationSignatureExcludesTimestamp() {
        // Two snapshots taken at different times with identical visible state
        // produce equal signatures, so unchanged frames are never rewritten.
        let early = VisualCursorObservationSnapshot(
            phase: "idle",
            tipPosition: CGPoint(x: 3, y: 4),
            restingTipPosition: CGPoint(x: 3, y: 4),
            rotation: 0.1,
            timestamp: 1_000
        )
        let late = VisualCursorObservationSnapshot(
            phase: "idle",
            tipPosition: CGPoint(x: 3, y: 4),
            restingTipPosition: CGPoint(x: 3, y: 4),
            rotation: 0.1,
            timestamp: 2_000
        )

        func signature(of snapshot: VisualCursorObservationSnapshot) -> VisualCursorObservationSignature {
            VisualCursorObservationSignature(
                phase: snapshot.phase,
                tipPosition: snapshot.tipPosition,
                restingTipPosition: snapshot.restingTipPosition,
                rotation: snapshot.rotation
            )
        }

        XCTAssertNotEqual(early.timestamp, late.timestamp)
        XCTAssertFalse(shouldWriteVisualCursorObservation(last: signature(of: early), next: signature(of: late)))
    }

    // MARK: Completion routing

    func testVisualCursorCompletionEquality() {
        XCTAssertEqual(VisualCursorCompletion.settle, .settle)
        XCTAssertEqual(VisualCursorCompletion.pulse(clickCount: 1, mouseButton: .left), .pulse(clickCount: 1, mouseButton: .left))
        XCTAssertNotEqual(VisualCursorCompletion.pulse(clickCount: 1, mouseButton: .left), .pulse(clickCount: 2, mouseButton: .left))
        XCTAssertNotEqual(VisualCursorCompletion.pulse(clickCount: 1, mouseButton: .left), .pulse(clickCount: 1, mouseButton: .right))
        XCTAssertNotEqual(VisualCursorCompletion.pulse(clickCount: 1, mouseButton: .left), .settle)
    }

    func testTriggerPolicyRunReturnsActionValueWithNilTarget() throws {
        let value = try VisualCursorTriggerPolicy.run(target: nil, completion: .settle) {
            42
        }

        XCTAssertEqual(value, 42)
    }

    func testTriggerPolicyRunRethrowsActionErrorWithNilTarget() {
        struct Boom: Error, Equatable {}

        XCTAssertThrowsError(
            try VisualCursorTriggerPolicy.run(target: nil, completion: .pulse(clickCount: 1, mouseButton: .left)) {
                throw Boom()
            }
        ) { error in
            XCTAssertEqual(error as? Boom, Boom())
        }
    }

    func testTriggerPolicyBeginFinishAreNoOpsWithNilTarget() {
        // Exercises the headless contract directly: nothing is presented and
        // nothing crashes when no visual target exists.
        VisualCursorTriggerPolicy.begin(nil)
        VisualCursorTriggerPolicy.finish(nil, completion: .settle)
        VisualCursorTriggerPolicy.finish(nil, completion: .pulse(clickCount: 2, mouseButton: .left))
    }
}
