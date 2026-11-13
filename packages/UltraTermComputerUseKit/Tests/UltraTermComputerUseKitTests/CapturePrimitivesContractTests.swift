import CoreMedia
import XCTest
@testable import UltraTermComputerUseKit

/// Pure capture primitives shared by preview and recording: even-dimension
/// geometry, the depth-1 drop-oldest mailbox, monotonic timestamp
/// normalization, and media error text.
final class CapturePrimitivesContractTests: XCTestCase {
    // MARK: CaptureGeometry

    func testScaledDimensionsKeepsSmallSourcesButForcesEven() {
        XCTAssertEqual(
            CaptureGeometry.scaledDimensions(source: CGSize(width: 640, height: 480), maxWidth: 960),
            CGSize(width: 640, height: 480)
        )
        XCTAssertEqual(
            CaptureGeometry.scaledDimensions(source: CGSize(width: 999, height: 501), maxWidth: 1024),
            CGSize(width: 998, height: 500)
        )
    }

    func testScaledDimensionsCapsWidthAndPreservesAspect() {
        XCTAssertEqual(
            CaptureGeometry.scaledDimensions(source: CGSize(width: 1000, height: 500), maxWidth: 500),
            CGSize(width: 500, height: 250)
        )
        // 333 -> 332 after even flooring; 500 * 0.333 = 166.5 -> 167 -> 166.
        XCTAssertEqual(
            CaptureGeometry.scaledDimensions(source: CGSize(width: 1000, height: 500), maxWidth: 333),
            CGSize(width: 332, height: 166)
        )
    }

    func testScaledDimensionsNeverDropsBelowTwo() {
        XCTAssertEqual(
            CaptureGeometry.scaledDimensions(source: CGSize(width: 4, height: 4), maxWidth: 1),
            CGSize(width: 2, height: 2)
        )
        XCTAssertEqual(
            CaptureGeometry.scaledDimensions(source: CGSize(width: 16_384, height: 2), maxWidth: 16_384),
            CGSize(width: 16_384, height: 2)
        )
    }

    func testEvenDimensionFloorsToEvenWithFloorOfTwo() {
        XCTAssertEqual(CaptureGeometry.evenDimension(0), 2)
        XCTAssertEqual(CaptureGeometry.evenDimension(1), 2)
        XCTAssertEqual(CaptureGeometry.evenDimension(2), 2)
        XCTAssertEqual(CaptureGeometry.evenDimension(3), 2)
        XCTAssertEqual(CaptureGeometry.evenDimension(4), 4)
        XCTAssertEqual(CaptureGeometry.evenDimension(101), 100)
    }

    // MARK: CaptureWindowTarget

    func testNativePixelSizeAppliesBackingScaleFactor() {
        let target = CaptureWindowTarget(
            appName: "ContractApp",
            bundleIdentifier: "dev.test.contract",
            processIdentifier: 4_242,
            windowID: 77,
            windowTitle: "Contract",
            framePoints: CGRect(x: 0, y: 0, width: 640, height: 480),
            backingScaleFactor: 2
        )

        XCTAssertEqual(target.nativePixelSize, CGSize(width: 1280, height: 960))

        let tiny = CaptureWindowTarget(
            appName: "ContractApp",
            bundleIdentifier: nil,
            processIdentifier: 1,
            windowID: 2,
            windowTitle: nil,
            framePoints: .zero,
            backingScaleFactor: 1
        )
        XCTAssertEqual(tiny.nativePixelSize, CGSize(width: 1, height: 1))
    }

    // MARK: LatestFrameMailbox

    private func frame(width: Int = 8, seconds: Double = 0) throws -> CapturedVideoFrame {
        CapturedVideoFrame(
            pixelBuffer: try ContractTestImages.pixelBuffer(width: width, height: 8),
            presentationTimestamp: CMTime(seconds: seconds, preferredTimescale: 90_000)
        )
    }

    func testMailboxHoldsExactlyOneFrameAndDropsOldest() throws {
        let mailbox = LatestFrameMailbox()
        XCTAssertEqual(mailbox.pendingCount, 0)
        XCTAssertEqual(mailbox.droppedCount, 0)

        try mailbox.push(frame(seconds: 1))
        XCTAssertEqual(mailbox.pendingCount, 1)
        XCTAssertEqual(mailbox.droppedCount, 0)

        try mailbox.push(frame(seconds: 2))
        try mailbox.push(frame(seconds: 3))
        XCTAssertEqual(mailbox.pendingCount, 1, "depth is exactly 1")
        XCTAssertEqual(mailbox.droppedCount, 2, "each unclaimed replacement counts one drop")

        let taken = mailbox.take()
        XCTAssertEqual(taken?.presentationTimestamp.seconds, 3, "the newest frame wins")
        XCTAssertEqual(mailbox.pendingCount, 0)
        XCTAssertNil(mailbox.take())
        XCTAssertEqual(mailbox.droppedCount, 2)
    }

    // MARK: MonotonicTimestampNormalizer

    func testNormalizerRebasesFirstFrameToZero() {
        var normalizer = MonotonicTimestampNormalizer(minimumDeltaSeconds: 0.04)
        let first = normalizer.normalize(sourceTimestamp: CMTime(seconds: 120, preferredTimescale: 90_000))

        XCTAssertEqual(first.seconds, 0)
        XCTAssertEqual(first.timescale, 90_000)
    }

    func testNormalizerPreservesSourceDeltas() {
        var normalizer = MonotonicTimestampNormalizer(minimumDeltaSeconds: 0.04)
        _ = normalizer.normalize(sourceTimestamp: CMTime(seconds: 10, preferredTimescale: 90_000))
        let second = normalizer.normalize(sourceTimestamp: CMTime(seconds: 10.5, preferredTimescale: 90_000))

        XCTAssertEqual(second.seconds, 0.5, accuracy: 0.000_1)
    }

    func testNormalizerForwardsNonMonotonicSourcesByMinimumDelta() {
        var normalizer = MonotonicTimestampNormalizer(minimumDeltaSeconds: 0.04)
        _ = normalizer.normalize(sourceTimestamp: CMTime(seconds: 10, preferredTimescale: 90_000))
        let repeated = normalizer.normalize(sourceTimestamp: CMTime(seconds: 10, preferredTimescale: 90_000))
        let backwards = normalizer.normalize(sourceTimestamp: CMTime(seconds: 5, preferredTimescale: 90_000))

        XCTAssertEqual(repeated.seconds, 0.04, accuracy: 0.000_1)
        XCTAssertEqual(backwards.seconds, 0.08, accuracy: 0.000_1)
    }

    func testNormalizerHandlesInvalidTimestamps() {
        var normalizer = MonotonicTimestampNormalizer(minimumDeltaSeconds: 0.04)
        let first = normalizer.normalize(sourceTimestamp: .invalid)
        let second = normalizer.normalize(sourceTimestamp: .invalid)

        XCTAssertEqual(first.seconds, 0)
        XCTAssertEqual(second.seconds, 0.04, accuracy: 0.000_1)
    }

    // MARK: Timestamps and errors

    func testCaptureTimestampFormatterEmitsISO8601WithFractionalSeconds() {
        let text = CaptureTimestampFormatter.string(from: Date(timeIntervalSince1970: 1_700_000_000.25))

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertNotNil(formatter.date(from: text), "\(text) must round-trip as fractional ISO8601")
        XCTAssertTrue(text.contains("."), "fractional seconds keep sub-second ordering visible")
    }

    func testCaptureCommandErrorDescriptionsAreStable() {
        XCTAssertEqual(
            CaptureCommandError.appNotRunning("Foo").errorDescription,
            "No running application matches 'Foo'. preview/record never launch apps; start the app first and retry."
        )
        XCTAssertEqual(
            CaptureCommandError.noCapturableWindow("Foo").errorDescription,
            "Application 'Foo' has no on-screen capturable window."
        )
        XCTAssertEqual(
            CaptureCommandError.screenRecordingPermissionDenied.errorDescription,
            "Screen Recording permission is not granted to this process. Run `ultraterm-computer-use doctor` and grant permission before capturing."
        )
        XCTAssertEqual(
            CaptureCommandError.invalidConfiguration("bad").errorDescription,
            "Invalid capture configuration: bad"
        )
        XCTAssertEqual(
            CaptureCommandError.outputNotWritable("/x").errorDescription,
            "Output location is not writable: /x"
        )
        XCTAssertEqual(
            CaptureCommandError.captureFailed("boom").errorDescription,
            "Capture failed: boom"
        )
    }

    func testStopReasonAndStatusRawValuesAreStable() {
        XCTAssertEqual(RecordingStopReason.duration.rawValue, "duration")
        XCTAssertEqual(RecordingStopReason.sizeCap.rawValue, "size-cap")
        XCTAssertEqual(RecordingStopReason.cancelled.rawValue, "cancelled")
        XCTAssertEqual(RecordingStopReason.error.rawValue, "error")

        XCTAssertEqual(CaptureCommandStatus.completed.rawValue, "completed")
        XCTAssertEqual(CaptureCommandStatus.cancelled.rawValue, "cancelled")
        XCTAssertEqual(CaptureCommandStatus.failed.rawValue, "failed")

        XCTAssertEqual(PreviewManifestStatus.capturing.rawValue, "capturing")
        XCTAssertEqual(PreviewManifestStatus.completed.rawValue, "completed")
    }
}
