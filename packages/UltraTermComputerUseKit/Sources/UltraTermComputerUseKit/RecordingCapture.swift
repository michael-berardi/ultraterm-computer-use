// `AVAssetWriter` has no `Sendable` annotation, but the `finishWriting`
// completion is `@Sendable`; the writer is otherwise confined to the
// lock-guarded engine and capture callback, so a narrowly scoped
// preconcurrency import covers that one crossing.
@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

// MARK: - CLI options

/// Parsed `record` CLI options.
public struct RecordingCaptureOptions: Equatable, Sendable {
    public var outputPath: String
    public var duration: TimeInterval
    public var framesPerSecond: Int
    public var maxWidth: Int
    public var bitrate: Int
    public var includeCursor: Bool

    public init(
        outputPath: String,
        duration: TimeInterval = 60,
        framesPerSecond: Int = 15,
        maxWidth: Int = 1920,
        bitrate: Int = 4_000_000,
        includeCursor: Bool = false
    ) {
        self.outputPath = outputPath
        self.duration = duration
        self.framesPerSecond = framesPerSecond
        self.maxWidth = maxWidth
        self.bitrate = bitrate
        self.includeCursor = includeCursor
    }
}

// MARK: - Configuration

/// Why a recording stopped.
public enum RecordingStopReason: String, Codable, Equatable, Sendable {
    case duration
    case sizeCap = "size-cap"
    case cancelled
    case error
}

/// Validated recording configuration consumed by `RecordingCaptureEngine`.
public struct RecordingCaptureConfiguration: Equatable, Sendable {
    /// Hard cap on session length, per product contract.
    public static let maximumDuration: TimeInterval = 600
    /// Hard cap on output file size, per product contract.
    public static let maximumFileBytes: Int64 = 300 * 1024 * 1024
    public static let minimumMaxWidth = 64
    public static let maximumMaxWidth = 16_384
    public static let minimumBitrate = 100_000
    public static let maximumBitrate = 200_000_000

    public let outputURL: URL
    public let duration: TimeInterval
    public let framesPerSecond: Int
    public let maxWidth: Int
    public let bitrate: Int
    public let includeCursor: Bool

    public init(
        outputURL: URL,
        duration: TimeInterval,
        framesPerSecond: Int,
        maxWidth: Int,
        bitrate: Int,
        includeCursor: Bool
    ) throws {
        guard duration.isFinite, duration > 0 else {
            throw CaptureCommandError.invalidConfiguration("duration must be > 0 seconds")
        }
        guard (1...60).contains(framesPerSecond) else {
            throw CaptureCommandError.invalidConfiguration("fps must be between 1 and 60")
        }
        guard (Self.minimumMaxWidth...Self.maximumMaxWidth).contains(maxWidth) else {
            throw CaptureCommandError.invalidConfiguration(
                "max-width must be between \(Self.minimumMaxWidth) and \(Self.maximumMaxWidth)"
            )
        }
        guard (Self.minimumBitrate...Self.maximumBitrate).contains(bitrate) else {
            throw CaptureCommandError.invalidConfiguration(
                "bitrate must be between \(Self.minimumBitrate) and \(Self.maximumBitrate) bits per second"
            )
        }

        self.outputURL = outputURL
        self.duration = duration
        self.framesPerSecond = framesPerSecond
        self.maxWidth = maxWidth
        self.bitrate = bitrate
        self.includeCursor = includeCursor
    }

    /// Requested duration clamped to the 600 s contract cap.
    public var effectiveDuration: TimeInterval {
        min(duration, Self.maximumDuration)
    }

    public var frameInterval: TimeInterval {
        1 / Double(framesPerSecond)
    }

    /// Seconds after which the requested average bitrate alone would exceed the
    /// size cap. Acts as a secondary bound next to on-disk size polling.
    public var bitrateDerivedSizeCapDeadline: TimeInterval {
        let bits = Double(Self.maximumFileBytes) * 8
        return max(1, (bits / Double(bitrate)).rounded(.down))
    }
}

// MARK: - Summary

/// Machine-readable result of a `record` run.
public struct RecordingCaptureSummary: Codable, Equatable, Sendable {
    public let status: CaptureCommandStatus
    public let stopReason: RecordingStopReason?
    public let app: String
    public let bundleIdentifier: String?
    public let processIdentifier: Int32
    public let windowID: Int64
    public let outputPath: String?
    public let framesPerSecond: Int
    public let bitrate: Int
    public let durationRequested: Double
    public let durationCaptured: Double
    public let framesReceived: Int
    public let framesEncoded: Int
    public let framesDropped: Int
    public let width: Int
    public let height: Int
    public let fileBytes: Int64
    public let includeCursor: Bool
    public let startedAt: String?
    public let endedAt: String?
    public let error: String?

    public init(
        status: CaptureCommandStatus,
        stopReason: RecordingStopReason?,
        app: String,
        bundleIdentifier: String?,
        processIdentifier: Int32,
        windowID: Int64,
        outputPath: String?,
        framesPerSecond: Int,
        bitrate: Int,
        durationRequested: Double,
        durationCaptured: Double,
        framesReceived: Int,
        framesEncoded: Int,
        framesDropped: Int,
        width: Int,
        height: Int,
        fileBytes: Int64,
        includeCursor: Bool,
        startedAt: String?,
        endedAt: String?,
        error: String?
    ) {
        self.status = status
        self.stopReason = stopReason
        self.app = app
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.windowID = windowID
        self.outputPath = outputPath
        self.framesPerSecond = framesPerSecond
        self.bitrate = bitrate
        self.durationRequested = durationRequested
        self.durationCaptured = durationCaptured
        self.framesReceived = framesReceived
        self.framesEncoded = framesEncoded
        self.framesDropped = framesDropped
        self.width = width
        self.height = height
        self.fileBytes = fileBytes
        self.includeCursor = includeCursor
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.error = error
    }

    public func jsonText() throws -> String {
        try captureSummaryJSONText(self)
    }
}

// MARK: - Engine

/// Bounded H.264 MP4 recorder. Frames are appended straight from the capture
/// callback; when the encoder falls behind (`isReadyForMoreMediaData == false`
/// or an exhausted adaptor pool) frames are dropped and counted, never queued,
/// so memory stays bounded by the SCStream sample queue plus one in-flight
/// buffer. Audio is never captured. On error the partial MP4 is deleted; on
/// cancellation the MP4 is finalized and kept with status `cancelled`. The
/// hard size cap is also enforced after finalization: a finalized MP4 larger
/// than `maximumRetainedFileBytes` is deleted and reported as a failed
/// size-cap outcome, never retained or reported completed.
public final class RecordingCaptureEngine: @unchecked Sendable {
    private let target: CaptureWindowTarget
    private let configuration: RecordingCaptureConfiguration
    private let frameSource: any ScreenStreamFrameSource
    private let clock: any CaptureClock
    private let fileManager: FileManager
    private let dateProvider: @Sendable () -> Date
    private let maximumRetainedFileBytes: Int64
    private let renderer = PixelBufferRenderer()

    private let stateLock = NSLock()
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false
    private lazy var normalizer = MonotonicTimestampNormalizer(
        minimumDeltaSeconds: configuration.frameInterval
    )
    private var framesReceived = 0
    private var framesEncoded = 0
    private var framesDropped = 0
    private var outputWidth = 0
    private var outputHeight = 0
    private var cancelRequested = false
    private var terminalFailure: String?

    public init(
        target: CaptureWindowTarget,
        configuration: RecordingCaptureConfiguration,
        frameSource: any ScreenStreamFrameSource,
        clock: any CaptureClock = SystemCaptureClock(),
        fileManager: FileManager = .default,
        dateProvider: @escaping @Sendable () -> Date = Date.init,
        maximumRetainedFileBytes: Int64 = RecordingCaptureConfiguration.maximumFileBytes
    ) {
        self.target = target
        self.configuration = configuration
        self.frameSource = frameSource
        self.clock = clock
        self.fileManager = fileManager
        self.dateProvider = dateProvider
        self.maximumRetainedFileBytes = maximumRetainedFileBytes
    }

    /// Request cooperative cancellation. The MP4 is finalized and kept.
    public func cancel() {
        stateLock.lock()
        cancelRequested = true
        stateLock.unlock()
    }

    public func run() throws -> RecordingCaptureSummary {
        let outputURL = configuration.outputURL
        let parentDirectory = outputURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        } catch {
            throw CaptureCommandError.outputNotWritable(parentDirectory.path)
        }
        if fileManager.fileExists(atPath: outputURL.path) {
            do {
                try fileManager.removeItem(at: outputURL)
            } catch {
                throw CaptureCommandError.outputNotWritable(outputURL.path)
            }
        }

        let startedAt = dateProvider()
        let startedMonotonic = clock.now()
        let endTime = startedMonotonic + configuration.effectiveDuration
        // The size cap is a secondary bound: it may only win when its own
        // threshold is reached, i.e. the bitrate-derived deadline itself.
        // Clamping it to the duration would make size-cap win every tie at
        // the duration tick even when the cap was never approached.
        let sizeCapTime = startedMonotonic + configuration.bitrateDerivedSizeCapDeadline

        frameSource.frameHandler = { [weak self] frame in
            self?.append(frame: frame)
        }
        frameSource.failureHandler = { [weak self] error in
            guard let self else {
                return
            }
            stateLock.lock()
            if terminalFailure == nil {
                terminalFailure = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
            cancelRequested = true
            stateLock.unlock()
        }

        do {
            try frameSource.start()
        } catch {
            frameSource.frameHandler = nil
            frameSource.failureHandler = nil
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            removePartialOutput()
            return makeSummary(
                status: .failed,
                stopReason: .error,
                outputURL: nil,
                startedAt: startedAt,
                endedAt: dateProvider(),
                durationCaptured: clock.now() - startedMonotonic,
                fileBytes: 0,
                error: message
            )
        }

        var stopReason = RecordingStopReason.duration
        var nextSizePoll = startedMonotonic + 1

        while true {
            let now = clock.now()
            stateLock.lock()
            let failed = terminalFailure != nil
            let cancelled = cancelRequested
            stateLock.unlock()

            if failed {
                stopReason = .error
                break
            }
            if cancelled {
                stopReason = .cancelled
                break
            }
            if now >= sizeCapTime {
                stopReason = .sizeCap
                break
            }
            if now >= endTime {
                stopReason = .duration
                break
            }
            if now >= nextSizePoll {
                if onDiskFileSize() >= RecordingCaptureConfiguration.maximumFileBytes {
                    stopReason = .sizeCap
                    break
                }
                nextSizePoll = now + 1
            }

            clock.sleep(min(0.05, max(0, endTime - now)))
        }

        frameSource.stop()
        frameSource.frameHandler = nil
        frameSource.failureHandler = nil

        return finalize(
            stopReason: stopReason,
            outputURL: outputURL,
            startedAt: startedAt,
            startedMonotonic: startedMonotonic
        )
    }

    // MARK: Writer lifecycle

    private func append(frame: CapturedVideoFrame) {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard terminalFailure == nil, !cancelRequested else {
            return
        }

        framesReceived += 1

        do {
            if writer == nil {
                try createWriter(for: frame)
            }

            guard let writer, let writerInput, let adaptor else {
                return
            }

            guard writer.status == .writing else {
                if writer.status == .failed {
                    terminalFailure = writer.error?.localizedDescription ?? "AVAssetWriter failed"
                }
                return
            }

            guard writerInput.isReadyForMoreMediaData else {
                framesDropped += 1
                return
            }

            let pts = normalizer.normalize(sourceTimestamp: frame.presentationTimestamp)
            if !sessionStarted {
                writer.startSession(atSourceTime: .zero)
                sessionStarted = true
            }

            guard let buffer = renderer.renderedBuffer(frame.pixelBuffer, into: adaptor) else {
                framesDropped += 1
                return
            }

            if adaptor.append(buffer, withPresentationTime: pts) {
                framesEncoded += 1
            } else {
                framesDropped += 1
                if writer.status == .failed {
                    terminalFailure = writer.error?.localizedDescription ?? "AVAssetWriter append failed"
                }
            }
        } catch {
            terminalFailure = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    /// Must be called with `stateLock` held.
    private func createWriter(for frame: CapturedVideoFrame) throws {
        let scaled = CaptureGeometry.scaledDimensions(
            source: CGSize(
                width: CVPixelBufferGetWidth(frame.pixelBuffer),
                height: CVPixelBufferGetHeight(frame.pixelBuffer)
            ),
            maxWidth: configuration.maxWidth
        )
        outputWidth = Int(scaled.width)
        outputHeight = Int(scaled.height)

        let newWriter: AVAssetWriter
        do {
            newWriter = try AVAssetWriter(outputURL: configuration.outputURL, fileType: .mp4)
        } catch {
            throw CaptureCommandError.outputNotWritable(configuration.outputURL.path)
        }
        newWriter.shouldOptimizeForNetworkUse = false

        let compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: configuration.bitrate,
            AVVideoExpectedSourceFrameRateKey: configuration.framesPerSecond,
            AVVideoMaxKeyFrameIntervalKey: configuration.framesPerSecond * 2,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
            AVVideoCompressionPropertiesKey: compressionProperties,
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outputWidth,
                kCVPixelBufferHeightKey as String: outputHeight,
            ]
        )

        guard newWriter.canAdd(input) else {
            throw CaptureCommandError.captureFailed("AVAssetWriter rejected the H.264 video input")
        }
        newWriter.add(input)

        guard newWriter.startWriting() else {
            throw CaptureCommandError.captureFailed(
                newWriter.error?.localizedDescription ?? "AVAssetWriter failed to start"
            )
        }

        writer = newWriter
        writerInput = input
        self.adaptor = adaptor
    }

    private func finalize(
        stopReason: RecordingStopReason,
        outputURL: URL,
        startedAt: Date,
        startedMonotonic: TimeInterval
    ) -> RecordingCaptureSummary {
        stateLock.lock()
        let activeWriter = writer
        let activeInput = writerInput
        let encodedFrames = framesEncoded
        let failure = terminalFailure
        writer = nil
        writerInput = nil
        adaptor = nil
        stateLock.unlock()

        let endedAt = dateProvider()
        let durationCaptured = clock.now() - startedMonotonic

        guard let activeWriter, encodedFrames > 0 else {
            // No frames ever reached the encoder: never leave a shell MP4 behind.
            removePartialOutput()
            let noFrames = stopReason == .cancelled
            return makeSummary(
                status: noFrames ? .cancelled : .failed,
                stopReason: stopReason,
                outputURL: nil,
                startedAt: startedAt,
                endedAt: endedAt,
                durationCaptured: durationCaptured,
                fileBytes: 0,
                error: failure ?? (noFrames ? nil : "No frames captured; the output file was removed")
            )
        }

        if stopReason == .error {
            activeWriter.cancelWriting()
            removePartialOutput()
            return makeSummary(
                status: .failed,
                stopReason: .error,
                outputURL: nil,
                startedAt: startedAt,
                endedAt: endedAt,
                durationCaptured: durationCaptured,
                fileBytes: 0,
                error: failure ?? "Capture failed; the partial output was removed"
            )
        }

        activeInput?.markAsFinished()
        var finishError: String?
        let finishBox = FinishWritingBox()
        let writerBox = FinishWriterBox(activeWriter)
        let finishSemaphore = DispatchSemaphore(value: 0)
        activeWriter.finishWriting {
            finishBox.error = writerBox.writer.error
            finishSemaphore.signal()
        }
        if finishSemaphore.wait(timeout: .now() + 30) == .timedOut {
            finishError = "Timed out finalizing MP4"
        } else if let writerError = finishBox.error {
            finishError = (writerError as? LocalizedError)?.errorDescription ?? String(describing: writerError)
        }

        if let finishError {
            removePartialOutput()
            return makeSummary(
                status: .failed,
                stopReason: .error,
                outputURL: nil,
                startedAt: startedAt,
                endedAt: endedAt,
                durationCaptured: durationCaptured,
                fileBytes: 0,
                error: finishError
            )
        }

        let fileBytes = onDiskFileSize()
        // The in-loop size poll and the bitrate-derived deadline are best
        // effort: encoding overshoot and `finishWriting` trailer growth can
        // still push the finalized MP4 past the hard cap. The cap is a
        // retained-bytes contract, so an over-cap file is removed and
        // reported as an explicit failed size-cap outcome regardless of why
        // the run stopped — it is never kept or reported completed.
        if fileBytes > maximumRetainedFileBytes {
            removePartialOutput()
            return makeSummary(
                status: .failed,
                stopReason: .sizeCap,
                outputURL: nil,
                startedAt: startedAt,
                endedAt: endedAt,
                durationCaptured: durationCaptured,
                fileBytes: 0,
                error: "Finalized MP4 is \(fileBytes) bytes, exceeding the "
                    + "\(maximumRetainedFileBytes)-byte size cap; the output file was removed"
            )
        }
        return makeSummary(
            status: stopReason == .cancelled ? .cancelled : .completed,
            stopReason: stopReason,
            outputURL: outputURL,
            startedAt: startedAt,
            endedAt: endedAt,
            durationCaptured: durationCaptured,
            fileBytes: fileBytes,
            error: failure
        )
    }

    // MARK: Helpers

    private func onDiskFileSize() -> Int64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: configuration.outputURL.path),
              let size = attributes[.size] as? NSNumber
        else {
            return 0
        }
        return size.int64Value
    }

    private func removePartialOutput() {
        try? fileManager.removeItem(at: configuration.outputURL)
    }

    /// Box crossing the `finishWriting` completion boundary.
    private final class FinishWritingBox: @unchecked Sendable {
        var error: (any Error)?
    }

    /// `AVAssetWriter` is not `Sendable`, but `finishWriting`'s completion is
    /// `@Sendable`. The writer is otherwise confined to the lock-guarded
    /// engine and is only read (never mutated) inside the completion, so a
    /// narrowly scoped unchecked-Sendable box is the sound crossing here.
    private final class FinishWriterBox: @unchecked Sendable {
        let writer: AVAssetWriter

        init(_ writer: AVAssetWriter) {
            self.writer = writer
        }
    }

    private func makeSummary(
        status: CaptureCommandStatus,
        stopReason: RecordingStopReason?,
        outputURL: URL?,
        startedAt: Date,
        endedAt: Date,
        durationCaptured: Double,
        fileBytes: Int64,
        error: String?
    ) -> RecordingCaptureSummary {
        stateLock.lock()
        defer { stateLock.unlock() }
        return RecordingCaptureSummary(
            status: status,
            stopReason: stopReason,
            app: target.appName,
            bundleIdentifier: target.bundleIdentifier,
            processIdentifier: target.processIdentifier,
            windowID: Int64(target.windowID),
            outputPath: outputURL?.path,
            framesPerSecond: configuration.framesPerSecond,
            bitrate: configuration.bitrate,
            durationRequested: configuration.duration,
            durationCaptured: durationCaptured,
            framesReceived: framesReceived,
            framesEncoded: framesEncoded,
            framesDropped: framesDropped,
            width: outputWidth,
            height: outputHeight,
            fileBytes: fileBytes,
            includeCursor: configuration.includeCursor,
            startedAt: CaptureTimestampFormatter.string(from: startedAt),
            endedAt: CaptureTimestampFormatter.string(from: endedAt),
            error: error
        )
    }
}

// MARK: - Command

/// CLI-facing runner: resolves an already-running target (never launches or
/// activates), builds the ScreenCaptureKit source, and runs the engine with
/// SIGINT/SIGTERM mapped to cooperative cancellation.
public enum RecordingCaptureCommand {
    public static func run(app query: String, options: RecordingCaptureOptions) throws -> RecordingCaptureSummary {
        let runningApp = try CaptureTargetResolver.resolveRunningApp(query: query)
        let target = try CaptureTargetResolver.resolveWindow(for: runningApp)
        let configuration = try RecordingCaptureConfiguration(
            outputURL: URL(fileURLWithPath: options.outputPath),
            duration: options.duration,
            framesPerSecond: options.framesPerSecond,
            maxWidth: options.maxWidth,
            bitrate: options.bitrate,
            includeCursor: options.includeCursor
        )
        let source = ScreenCaptureKitFrameSource(
            target: target,
            maxWidth: configuration.maxWidth,
            framesPerSecond: configuration.framesPerSecond,
            includeCursor: configuration.includeCursor
        )
        let engine = RecordingCaptureEngine(target: target, configuration: configuration, frameSource: source)

        let signalScope = CaptureSignalScope {
            engine.cancel()
        }
        defer {
            signalScope.close()
        }

        return try engine.run()
    }
}
