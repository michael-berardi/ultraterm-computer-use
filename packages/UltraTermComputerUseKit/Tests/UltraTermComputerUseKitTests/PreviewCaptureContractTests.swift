import XCTest
@testable import UltraTermComputerUseKit

/// Preview capture contract: configuration validation, publish throttling,
/// drop-oldest frame policy, and atomic latest.jpg + manifest.json updates.
/// Engines run on synthetic frames with a fake clock — no ScreenCaptureKit,
/// no apps, no real time.
final class PreviewCaptureContractTests: XCTestCase {
    private func makeTarget() -> CaptureWindowTarget {
        CaptureWindowTarget(
            appName: "ContractApp",
            bundleIdentifier: "dev.test.contract",
            processIdentifier: 4_242,
            windowID: 77,
            windowTitle: "Contract",
            framePoints: CGRect(x: 0, y: 0, width: 640, height: 480),
            backingScaleFactor: 1
        )
    }

    private func makeConfiguration(
        directory: URL,
        duration: TimeInterval = 0.5,
        fps: Int = 4,
        maxWidth: Int = 320,
        quality: Double = 0.8
    ) throws -> PreviewCaptureConfiguration {
        try PreviewCaptureConfiguration(
            outputDirectory: directory,
            duration: duration,
            framesPerSecond: fps,
            maxWidth: maxWidth,
            jpegQuality: quality,
            includeCursor: false
        )
    }

    // MARK: Configuration validation

    func testConfigurationRejectsInvalidDurations() {
        for duration in [0.0, -1, 3601, .nan, .infinity] {
            XCTAssertThrowsError(try PreviewCaptureConfiguration(
                outputDirectory: URL(fileURLWithPath: "/tmp/x"),
                duration: duration,
                framesPerSecond: 8,
                maxWidth: 960,
                jpegQuality: 0.8,
                includeCursor: false
            )) { error in
                guard case CaptureCommandError.invalidConfiguration = error else {
                    return XCTFail("expected invalidConfiguration for duration \(duration), got \(error)")
                }
            }
        }
    }

    func testConfigurationRejectsOutOfRangeKnobs() {
        func make(fps: Int = 8, maxWidth: Int = 960, quality: Double = 0.8) throws {
            _ = try PreviewCaptureConfiguration(
                outputDirectory: URL(fileURLWithPath: "/tmp/x"),
                duration: 30,
                framesPerSecond: fps,
                maxWidth: maxWidth,
                jpegQuality: quality,
                includeCursor: false
            )
        }

        for fps in [0, 61, -2] {
            XCTAssertThrowsError(try make(fps: fps))
        }
        for maxWidth in [63, 16_385] {
            XCTAssertThrowsError(try make(maxWidth: maxWidth))
        }
        for quality in [0.04, 1.01, -0.5, Double.nan] {
            XCTAssertThrowsError(try make(quality: quality))
        }

        XCTAssertNoThrow(try make(fps: 1, maxWidth: 64, quality: 0.05))
        XCTAssertNoThrow(try make(fps: 60, maxWidth: 16_384, quality: 1))
    }

    func testConfigurationFrameIntervalIsReciprocalOfFPS() throws {
        let configuration = try makeConfiguration(directory: URL(fileURLWithPath: "/tmp/x"), fps: 4)
        XCTAssertEqual(configuration.frameInterval, 0.25)
        XCTAssertEqual(PreviewCaptureConfiguration.maximumDuration, 3600)
    }

    func testPreviewOptionsDefaultsMatchContract() {
        let options = PreviewCaptureOptions(outputDirectory: "/tmp/x")

        XCTAssertEqual(options.duration, 30)
        XCTAssertEqual(options.framesPerSecond, 8)
        XCTAssertEqual(options.maxWidth, 960)
        XCTAssertEqual(options.jpegQuality, 0.8)
        XCTAssertFalse(options.includeCursor)
    }

    // MARK: Engine: publish + atomic outputs

    func testEnginePublishesLatestFrameAndManifestAtomically() throws {
        try withContractTempDirectory { directory in
            let clock = FakeCaptureClock()
            let source = FakeFrameSource()
            source.onStart = { source.emit(width: 640, height: 480, atSeconds: 0) }

            let engine = PreviewCaptureEngine(
                target: makeTarget(),
                configuration: try makeConfiguration(directory: directory, duration: 0.5, fps: 4, maxWidth: 320),
                frameSource: source,
                clock: clock
            )

            let summary = try engine.run()

            XCTAssertEqual(summary.status, .completed)
            XCTAssertEqual(summary.framesReceived, 1)
            XCTAssertEqual(summary.framesWritten, 1)
            XCTAssertEqual(summary.framesDropped, 0)
            XCTAssertEqual(summary.durationRequested, 0.5)
            XCTAssertEqual(summary.durationCaptured, 0.5, accuracy: 0.001)
            XCTAssertEqual(source.startCount, 1)
            XCTAssertEqual(source.stopCount, 1)

            let latestURL = directory.appendingPathComponent("latest.jpg")
            let manifestURL = directory.appendingPathComponent("manifest.json")
            XCTAssertEqual(summary.latestFramePath, latestURL.path)
            XCTAssertEqual(summary.manifestPath, manifestURL.path)

            // latest.jpg is a decodable JPEG scaled to the configured width.
            let jpegData = try Data(contentsOf: latestURL)
            let pixelSize = try ContractTestImages.encodedPixelSize(jpegData)
            XCTAssertLessThanOrEqual(pixelSize.width, 320)
            XCTAssertEqual(pixelSize.width.truncatingRemainder(dividingBy: 2), 0)
            XCTAssertEqual(Int(pixelSize.width), summary.width)
            XCTAssertEqual(Int(pixelSize.height), summary.height)

            // manifest.json describes the current latest.jpg.
            let manifest = try JSONDecoder().decode(PreviewManifest.self, from: Data(contentsOf: manifestURL))
            XCTAssertEqual(manifest.version, 1)
            XCTAssertEqual(manifest.app, "ContractApp")
            XCTAssertEqual(manifest.bundleIdentifier, "dev.test.contract")
            XCTAssertEqual(manifest.processIdentifier, 4_242)
            XCTAssertEqual(manifest.windowID, 77)
            XCTAssertEqual(manifest.latestFrame, "latest.jpg")
            XCTAssertEqual(manifest.status, .completed)
            XCTAssertEqual(manifest.framesReceived, 1)
            XCTAssertEqual(manifest.framesWritten, 1)
            XCTAssertEqual(manifest.framesDropped, 0)
            XCTAssertEqual(manifest.framesPerSecond, 4)
            XCTAssertFalse(manifest.includeCursor)
            XCTAssertNotNil(manifest.endedAt)
            XCTAssertNil(manifest.error)
        }
    }

    func testEngineThrottlesPublishesAndDropsOldestFrames() throws {
        try withContractTempDirectory { directory in
            let clock = FakeCaptureClock()
            let source = FakeFrameSource()
            // Three frames queued before the first tick: only the newest may
            // be published, and the two displaced frames count as drops.
            source.onStart = {
                source.emit(width: 320, height: 240, atSeconds: 0, seed: 1)
                source.emit(width: 320, height: 240, atSeconds: 0, seed: 2)
                source.emit(width: 320, height: 240, atSeconds: 0, seed: 3)
            }
            // One fresh frame each time the throttle window opens.
            var emitted = Set<Int>()
            clock.onAdvance = { now in
                for tick in [0.25, 0.5] where now >= tick && !emitted.contains(Int(tick * 100)) {
                    emitted.insert(Int(tick * 100))
                    source.emit(width: 320, height: 240, atSeconds: tick, seed: 10)
                }
            }

            let engine = PreviewCaptureEngine(
                target: makeTarget(),
                configuration: try makeConfiguration(directory: directory, duration: 0.75, fps: 4, maxWidth: 320),
                frameSource: source,
                clock: clock
            )

            let summary = try engine.run()

            XCTAssertEqual(summary.status, .completed)
            XCTAssertEqual(summary.framesReceived, 5)
            XCTAssertEqual(summary.framesWritten, 3, "one publish per 0.25 s throttle window")
            XCTAssertEqual(summary.framesDropped, 2, "the two displaced queued frames are dropped oldest-first")

            let manifest = try JSONDecoder().decode(
                PreviewManifest.self,
                from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
            )
            XCTAssertEqual(manifest.framesWritten, 3)
            XCTAssertEqual(manifest.framesDropped, 2)
        }
    }

    func testEngineWithoutFramesWritesNothing() throws {
        try withContractTempDirectory { directory in
            let engine = PreviewCaptureEngine(
                target: makeTarget(),
                configuration: try makeConfiguration(directory: directory, duration: 0.02, fps: 8),
                frameSource: FakeFrameSource(),
                clock: FakeCaptureClock()
            )

            let summary = try engine.run()

            XCTAssertEqual(summary.status, .completed)
            XCTAssertEqual(summary.framesWritten, 0)
            XCTAssertNil(summary.latestFramePath)
            XCTAssertNil(summary.manifestPath)
            XCTAssertNil(summary.error)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("latest.jpg").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path))
        }
    }

    func testEngineReportsStartFailureWithoutTouchingOutputs() throws {
        try withContractTempDirectory { directory in
            let source = FakeFrameSource()
            source.startError = ContractCaptureError.syntheticStartFailure

            let engine = PreviewCaptureEngine(
                target: makeTarget(),
                configuration: try makeConfiguration(directory: directory, duration: 0.5),
                frameSource: source,
                clock: FakeCaptureClock()
            )

            let summary = try engine.run()

            XCTAssertEqual(summary.status, .failed)
            XCTAssertEqual(summary.error, "syntheticStartFailure")
            XCTAssertNil(summary.latestFramePath)
            XCTAssertNil(summary.manifestPath)
            XCTAssertEqual(source.stopCount, 0, "a source that never started is never stopped")
        }
    }

    func testEngineReportsMidStreamFailure() throws {
        try withContractTempDirectory { directory in
            let clock = FakeCaptureClock()
            let source = FakeFrameSource()
            source.onStart = { source.emit(width: 320, height: 240, atSeconds: 0) }
            var failed = false
            clock.onAdvance = { now in
                if now >= 0.2 && !failed {
                    failed = true
                    source.fail(ContractCaptureError.syntheticStreamFailure)
                }
            }

            let engine = PreviewCaptureEngine(
                target: makeTarget(),
                configuration: try makeConfiguration(directory: directory, duration: 1, fps: 4),
                frameSource: source,
                clock: clock
            )

            let summary = try engine.run()

            XCTAssertEqual(summary.status, .failed)
            XCTAssertEqual(summary.error, "syntheticStreamFailure")
            XCTAssertEqual(source.stopCount, 1)

            // A frame was published before the failure: the manifest records
            // the terminal failed status for consumers watching the directory.
            let manifest = try JSONDecoder().decode(
                PreviewManifest.self,
                from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
            )
            XCTAssertEqual(manifest.status, .failed)
            XCTAssertEqual(manifest.error, "syntheticStreamFailure")
        }
    }

    func testEngineCancellationEndsRunCooperatively() throws {
        try withContractTempDirectory { directory in
            let clock = FakeCaptureClock()
            let source = FakeFrameSource()
            source.onStart = { source.emit(width: 320, height: 240, atSeconds: 0) }

            let engine = PreviewCaptureEngine(
                target: makeTarget(),
                configuration: try makeConfiguration(directory: directory, duration: 60, fps: 4),
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
            XCTAssertNil(summary.error)
            XCTAssertLessThan(summary.durationCaptured, 60)
        }
    }

    func testSummarySerializesToSortedJSON() throws {
        try withContractTempDirectory { directory in
            let source = FakeFrameSource()
            source.onStart = { source.emit(width: 320, height: 240, atSeconds: 0) }

            let engine = PreviewCaptureEngine(
                target: makeTarget(),
                configuration: try makeConfiguration(directory: directory, duration: 0.05),
                frameSource: source,
                clock: FakeCaptureClock()
            )

            let summary = try engine.run()
            let json = try summary.jsonText()

            XCTAssertTrue(json.contains("\"status\" : \"completed\""))
            XCTAssertNotNil(json.range(of: "\"app\""))
        }
    }
}
