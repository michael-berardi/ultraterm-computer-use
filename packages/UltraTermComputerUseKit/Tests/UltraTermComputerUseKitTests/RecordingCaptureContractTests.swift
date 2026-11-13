import AVFoundation
import XCTest
@testable import UltraTermComputerUseKit

/// Recording capture contract: configuration caps, bounded H.264 MP4 output,
/// duration-based stop, cooperative cancel, partial-output cleanup, and the
/// post-finalization retained-size hard cap (via an injected cap seam). All
/// frames are synthetic pixel buffers; the fake clock makes every stop
/// condition deterministic.
final class RecordingCaptureContractTests: XCTestCase {
    private func makeTarget() -> CaptureWindowTarget {
        CaptureWindowTarget(
            appName: "ContractApp",
            bundleIdentifier: "dev.test.contract",
            processIdentifier: 4_242,
            windowID: 77,
            windowTitle: "Contract",
            framePoints: CGRect(x: 0, y: 0, width: 320, height: 240),
            backingScaleFactor: 1
        )
    }

    private func makeConfiguration(
        output: URL,
        duration: TimeInterval = 0.5,
        fps: Int = 10,
        maxWidth: Int = 320,
        bitrate: Int = 1_000_000
    ) throws -> RecordingCaptureConfiguration {
        try RecordingCaptureConfiguration(
            outputURL: output,
            duration: duration,
            framesPerSecond: fps,
            maxWidth: maxWidth,
            bitrate: bitrate,
            includeCursor: false
        )
    }

    // MARK: Configuration

    func testConfigurationDefaultsMatchContract() {
        XCTAssertEqual(RecordingCaptureConfiguration.maximumDuration, 600)
        XCTAssertEqual(RecordingCaptureConfiguration.maximumFileBytes, 300 * 1024 * 1024)
        XCTAssertEqual(RecordingCaptureConfiguration.minimumBitrate, 100_000)
        XCTAssertEqual(RecordingCaptureConfiguration.maximumBitrate, 200_000_000)

        let options = RecordingCaptureOptions(outputPath: "/tmp/x.mp4")
        XCTAssertEqual(options.duration, 60)
        XCTAssertEqual(options.framesPerSecond, 15)
        XCTAssertEqual(options.maxWidth, 1920)
        XCTAssertEqual(options.bitrate, 4_000_000)
        XCTAssertFalse(options.includeCursor)
    }

    func testConfigurationRejectsOutOfRangeKnobs() {
        func make(duration: TimeInterval = 60, fps: Int = 15, maxWidth: Int = 1920, bitrate: Int = 4_000_000) throws {
            _ = try RecordingCaptureConfiguration(
                outputURL: URL(fileURLWithPath: "/tmp/x.mp4"),
                duration: duration,
                framesPerSecond: fps,
                maxWidth: maxWidth,
                bitrate: bitrate,
                includeCursor: false
            )
        }

        for duration in [0.0, -5, Double.nan, .infinity] {
            XCTAssertThrowsError(try make(duration: duration))
        }
        for fps in [0, 61] {
            XCTAssertThrowsError(try make(fps: fps))
        }
        for maxWidth in [63, 16_385] {
            XCTAssertThrowsError(try make(maxWidth: maxWidth))
        }
        for bitrate in [99_999, 200_000_001] {
            XCTAssertThrowsError(try make(bitrate: bitrate))
        }

        XCTAssertNoThrow(try make(fps: 1, maxWidth: 64, bitrate: 100_000))
        XCTAssertNoThrow(try make(fps: 60, maxWidth: 16_384, bitrate: 200_000_000))
    }

    func testEffectiveDurationClampsToContractCap() throws {
        let configuration = try makeConfiguration(output: URL(fileURLWithPath: "/tmp/x.mp4"), duration: 10_000)

        XCTAssertEqual(configuration.effectiveDuration, 600)
        XCTAssertEqual(configuration.duration, 10_000, "the requested value is preserved for reporting")
    }

    func testBitrateDerivedSizeCapDeadlineMath() throws {
        let configuration = try makeConfiguration(output: URL(fileURLWithPath: "/tmp/x.mp4"), bitrate: 4_000_000)
        let expected = floor(Double(300 * 1024 * 1024) * 8 / 4_000_000)

        XCTAssertEqual(configuration.bitrateDerivedSizeCapDeadline, expected)
        XCTAssertGreaterThan(configuration.bitrateDerivedSizeCapDeadline, 600,
                             "at contract bitrates the size cap can never beat the duration cap")
    }

    // MARK: Engine

    func testEngineRecordsBoundedMP4UntilDurationStop() async throws {
        try await withContractTempDirectory { directory in
            let output = directory.appendingPathComponent("capture.mp4")
            let clock = FakeCaptureClock()
            let source = FakeFrameSource()
            // Ten frames at 10 fps cadence across a 0.5 s run.
            source.onStart = {
                for index in 0..<10 {
                    source.emit(width: 320, height: 240, atSeconds: Double(index) * 0.1, seed: UInt8(index))
                }
            }

            let engine = RecordingCaptureEngine(
                target: makeTarget(),
                configuration: try makeConfiguration(output: output, duration: 0.5, fps: 10),
                frameSource: source,
                clock: clock
            )

            let summary = try engine.run()

            XCTAssertEqual(summary.status, .completed)
            XCTAssertEqual(summary.stopReason, .duration)
            XCTAssertEqual(summary.outputPath, output.path)
            XCTAssertEqual(summary.framesReceived, 10)
            XCTAssertGreaterThan(summary.framesEncoded, 0)
            XCTAssertEqual(
                summary.framesEncoded + summary.framesDropped,
                10,
                "every received frame is either encoded or counted as dropped (never queued)"
            )
            XCTAssertEqual(summary.width, 320)
            XCTAssertEqual(summary.height, 240)
            XCTAssertEqual(summary.durationCaptured, 0.5, accuracy: 0.001)
            XCTAssertNil(summary.error)
            XCTAssertGreaterThan(summary.fileBytes, 0)

            // The MP4 on disk is a real, probe-able movie with video content.
            let asset = AVAsset(url: output)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let firstVideoTrack = try XCTUnwrap(videoTracks.first)
            let naturalSize = try await firstVideoTrack.load(.naturalSize)
            XCTAssertEqual(videoTracks.count, 1, "exactly one video track; audio is never recorded")
            XCTAssertTrue(audioTracks.isEmpty)
            XCTAssertEqual(naturalSize.width, 320, accuracy: 1)
        }
    }

    func testEngineScalesOddSourceToEvenDimensions() throws {
        try withContractTempDirectory { directory in
            let output = directory.appendingPathComponent("capture.mp4")
            let source = FakeFrameSource()
            source.onStart = { source.emit(width: 321, height: 241, atSeconds: 0) }

            let engine = RecordingCaptureEngine(
                target: makeTarget(),
                configuration: try makeConfiguration(output: output, duration: 0.2, fps: 10, maxWidth: 320),
                frameSource: source,
                clock: FakeCaptureClock()
            )

            let summary = try engine.run()

            XCTAssertEqual(summary.status, .completed)
            XCTAssertEqual(summary.width, 320)
            XCTAssertEqual(summary.height, 240, "odd heights floor to even for H.264")
        }
    }

    func testEngineCancelKeepsFinalizedMP4() throws {
        try withContractTempDirectory { directory in
            let output = directory.appendingPathComponent("capture.mp4")
            let clock = FakeCaptureClock()
            let source = FakeFrameSource()
            source.onStart = { source.emit(width: 320, height: 240, atSeconds: 0) }

            let engine = RecordingCaptureEngine(
                target: makeTarget(),
                configuration: try makeConfiguration(output: output, duration: 60, fps: 10),
                frameSource: source,
                clock: clock
            )

            var cancelled = false
            clock.onAdvance = { _ in
                if !cancelled {
                    cancelled = true
                    engine.cancel()
                }
            }

            let summary = try engine.run()

            XCTAssertEqual(summary.status, .cancelled)
            XCTAssertEqual(summary.stopReason, .cancelled)
            XCTAssertEqual(summary.outputPath, output.path, "cancellation finalizes and keeps the MP4")
            XCTAssertGreaterThan(summary.fileBytes, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testEngineStartFailureRemovesPartialOutput() throws {
        try withContractTempDirectory { directory in
            let output = directory.appendingPathComponent("capture.mp4")
            // A stale file at the output path is replaced before the run; the
            // failed run must not leave anything behind.
            try Data("stale".utf8).write(to: output)

            let source = FakeFrameSource()
            source.startError = ContractCaptureError.syntheticStartFailure

            let engine = RecordingCaptureEngine(
                target: makeTarget(),
                configuration: try makeConfiguration(output: output, duration: 0.5),
                frameSource: source,
                clock: FakeCaptureClock()
            )

            let summary = try engine.run()

            XCTAssertEqual(summary.status, .failed)
            XCTAssertEqual(summary.stopReason, .error)
            XCTAssertEqual(summary.error, "syntheticStartFailure")
            XCTAssertNil(summary.outputPath)
            XCTAssertEqual(summary.fileBytes, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                           "a failed run must clean up the output path")
        }
    }

    func testEngineWithoutFramesFailsAndRemovesShellFile() throws {
        try withContractTempDirectory { directory in
            let output = directory.appendingPathComponent("capture.mp4")

            let engine = RecordingCaptureEngine(
                target: makeTarget(),
                configuration: try makeConfiguration(output: output, duration: 0.05, fps: 10),
                frameSource: FakeFrameSource(),
                clock: FakeCaptureClock()
            )

            let summary = try engine.run()

            XCTAssertEqual(summary.status, .failed)
            XCTAssertEqual(summary.stopReason, .duration)
            XCTAssertEqual(summary.error, "No frames captured; the output file was removed")
            XCTAssertNil(summary.outputPath)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                           "no shell MP4 may be left behind when zero frames were encoded")
        }
    }

    func testEngineMidStreamFailureRemovesPartialMP4() throws {
        try withContractTempDirectory { directory in
            let output = directory.appendingPathComponent("capture.mp4")
            let clock = FakeCaptureClock()
            let source = FakeFrameSource()
            source.onStart = { source.emit(width: 320, height: 240, atSeconds: 0) }

            var failed = false
            clock.onAdvance = { now in
                if now >= 0.1 && !failed {
                    failed = true
                    source.fail(ContractCaptureError.syntheticStreamFailure)
                }
            }

            let engine = RecordingCaptureEngine(
                target: makeTarget(),
                configuration: try makeConfiguration(output: output, duration: 60, fps: 10),
                frameSource: source,
                clock: clock
            )

            let summary = try engine.run()

            XCTAssertEqual(summary.status, .failed)
            XCTAssertEqual(summary.stopReason, .error)
            XCTAssertEqual(summary.error, "syntheticStreamFailure")
            XCTAssertNil(summary.outputPath)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                           "error finalization cancels the writer and deletes the partial MP4")
        }
    }

    func testEngineOverCapFinalizedOutputIsRemovedAndNotReportedCompleted() throws {
        try withContractTempDirectory { directory in
            let output = directory.appendingPathComponent("capture.mp4")
            let source = FakeFrameSource()
            source.onStart = { source.emit(width: 320, height: 240, atSeconds: 0) }

            // The injected cap seam stands in for the 300 MB contract cap: any
            // real finalized MP4 exceeds 1 byte, so the post-finalization
            // check is exercised without writing hundreds of megabytes.
            let engine = RecordingCaptureEngine(
                target: makeTarget(),
                configuration: try makeConfiguration(output: output, duration: 0.2, fps: 10),
                frameSource: source,
                clock: FakeCaptureClock(),
                maximumRetainedFileBytes: 1
            )

            let summary = try engine.run()

            XCTAssertEqual(summary.status, .failed,
                           "an over-cap finalized MP4 is never reported completed")
            XCTAssertEqual(summary.stopReason, .sizeCap)
            XCTAssertNil(summary.outputPath, "an over-cap finalized MP4 is never reported as retained output")
            XCTAssertEqual(summary.fileBytes, 0)
            let error = try XCTUnwrap(summary.error)
            XCTAssertTrue(error.hasPrefix("Finalized MP4 is "))
            XCTAssertTrue(error.hasSuffix("exceeding the 1-byte size cap; the output file was removed"),
                          "the size-cap outcome is explicit, got: \(error)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                           "the over-cap finalized MP4 must be removed")
        }
    }

    func testEngineInCapFinalizedOutputIsRetained() throws {
        try withContractTempDirectory { directory in
            let output = directory.appendingPathComponent("capture.mp4")
            let source = FakeFrameSource()
            source.onStart = { source.emit(width: 320, height: 240, atSeconds: 0) }

            let engine = RecordingCaptureEngine(
                target: makeTarget(),
                configuration: try makeConfiguration(output: output, duration: 0.2, fps: 10),
                frameSource: source,
                clock: FakeCaptureClock(),
                maximumRetainedFileBytes: RecordingCaptureConfiguration.maximumFileBytes
            )

            let summary = try engine.run()

            XCTAssertEqual(summary.status, .completed)
            XCTAssertEqual(summary.stopReason, .duration)
            XCTAssertEqual(summary.outputPath, output.path)
            XCTAssertGreaterThan(summary.fileBytes, 0)
            XCTAssertNil(summary.error)
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path),
                          "in-cap finalized output stays on disk")
            XCTAssertEqual(try Data(contentsOf: output).count, Int(summary.fileBytes))
        }
    }

    func testEngineOverCapFinalizedOutputIsRemovedEvenWhenCancelled() throws {
        try withContractTempDirectory { directory in
            let output = directory.appendingPathComponent("capture.mp4")
            let clock = FakeCaptureClock()
            let source = FakeFrameSource()
            source.onStart = { source.emit(width: 320, height: 240, atSeconds: 0) }

            let engine = RecordingCaptureEngine(
                target: makeTarget(),
                configuration: try makeConfiguration(output: output, duration: 60, fps: 10),
                frameSource: source,
                clock: clock,
                maximumRetainedFileBytes: 1
            )

            var cancelled = false
            clock.onAdvance = { _ in
                if !cancelled {
                    cancelled = true
                    engine.cancel()
                }
            }

            let summary = try engine.run()

            XCTAssertEqual(summary.status, .failed,
                           "the retained-bytes cap applies to cancelled runs too")
            XCTAssertEqual(summary.stopReason, .sizeCap)
            XCTAssertNil(summary.outputPath)
            XCTAssertEqual(summary.fileBytes, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                           "cancellation keeps the MP4 only while it is within the hard cap")
        }
    }

    func testEngineReplacesPreExistingOutputFile() throws {
        try withContractTempDirectory { directory in
            let output = directory.appendingPathComponent("capture.mp4")
            try Data(repeating: 0xAA, count: 4096).write(to: output)

            let source = FakeFrameSource()
            source.onStart = { source.emit(width: 320, height: 240, atSeconds: 0) }

            let engine = RecordingCaptureEngine(
                target: makeTarget(),
                configuration: try makeConfiguration(output: output, duration: 0.2, fps: 10),
                frameSource: source,
                clock: FakeCaptureClock()
            )

            let summary = try engine.run()

            XCTAssertEqual(summary.status, .completed)
            XCTAssertNotEqual(summary.fileBytes, 4096, "the stale file was replaced, not appended to")
            XCTAssertEqual(try Data(contentsOf: output).count, Int(summary.fileBytes))
        }
    }

    func testUnwritableOutputPathThrows() throws {
        let output = URL(fileURLWithPath: "/System/ultraterm-computer-use-contract-\(UUID().uuidString)/capture.mp4")
        let engine = RecordingCaptureEngine(
            target: makeTarget(),
            configuration: try makeConfiguration(output: output, duration: 0.1),
            frameSource: FakeFrameSource(),
            clock: FakeCaptureClock()
        )

        XCTAssertThrowsError(try engine.run()) { error in
            guard case CaptureCommandError.outputNotWritable = error else {
                return XCTFail("expected outputNotWritable, got \(error)")
            }
        }
    }

    func testSummaryTimestampsAreISO8601() throws {
        try withContractTempDirectory { directory in
            let output = directory.appendingPathComponent("capture.mp4")
            let source = FakeFrameSource()
            source.onStart = { source.emit(width: 320, height: 240, atSeconds: 0) }

            let engine = RecordingCaptureEngine(
                target: makeTarget(),
                configuration: try makeConfiguration(output: output, duration: 0.1, fps: 10),
                frameSource: source,
                clock: FakeCaptureClock()
            )

            let summary = try engine.run()

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            XCTAssertNotNil(summary.startedAt.flatMap { formatter.date(from: $0) })
            XCTAssertNotNil(summary.endedAt.flatMap { formatter.date(from: $0) })

            let json = try summary.jsonText()
            XCTAssertTrue(json.contains("\"stopReason\" : \"duration\""))
        }
    }
}
