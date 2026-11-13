import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

// MARK: - Shared status

/// Terminal status shared by preview and recording summaries.
public enum CaptureCommandStatus: String, Codable, Equatable, Sendable {
    case completed
    case cancelled
    case failed
}

/// Timestamps rendered in summaries and manifests.
enum CaptureTimestampFormatter {
    /// `ISO8601DateFormatter` is not `Sendable`, so it is constructed per call
    /// instead of being stored in shared static state; the format options are
    /// fixed, so output is identical across calls.
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

func captureSummaryJSONText<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    guard let text = String(data: data, encoding: .utf8) else {
        throw CaptureCommandError.captureFailed("Summary JSON encoding failed")
    }
    return text
}

// MARK: - CLI options

/// Parsed `preview` CLI options.
public struct PreviewCaptureOptions: Equatable, Sendable {
    public var outputDirectory: String
    public var duration: TimeInterval
    public var framesPerSecond: Int
    public var maxWidth: Int
    public var jpegQuality: Double
    public var includeCursor: Bool

    public init(
        outputDirectory: String,
        duration: TimeInterval = 30,
        framesPerSecond: Int = 8,
        maxWidth: Int = 960,
        jpegQuality: Double = 0.8,
        includeCursor: Bool = false
    ) {
        self.outputDirectory = outputDirectory
        self.duration = duration
        self.framesPerSecond = framesPerSecond
        self.maxWidth = maxWidth
        self.jpegQuality = jpegQuality
        self.includeCursor = includeCursor
    }
}

// MARK: - Engine configuration

/// Validated preview configuration consumed by `PreviewCaptureEngine`.
public struct PreviewCaptureConfiguration: Equatable, Sendable {
    public static let maximumDuration: TimeInterval = 3600
    public static let minimumMaxWidth = 64
    public static let maximumMaxWidth = 16_384

    public let outputDirectory: URL
    public let duration: TimeInterval
    public let framesPerSecond: Int
    public let maxWidth: Int
    public let jpegQuality: Double
    public let includeCursor: Bool

    public init(
        outputDirectory: URL,
        duration: TimeInterval,
        framesPerSecond: Int,
        maxWidth: Int,
        jpegQuality: Double,
        includeCursor: Bool
    ) throws {
        guard duration.isFinite, duration > 0, duration <= Self.maximumDuration else {
            throw CaptureCommandError.invalidConfiguration(
                "duration must be > 0 and <= \(Int(Self.maximumDuration)) seconds"
            )
        }
        guard (1...60).contains(framesPerSecond) else {
            throw CaptureCommandError.invalidConfiguration("fps must be between 1 and 60")
        }
        guard (Self.minimumMaxWidth...Self.maximumMaxWidth).contains(maxWidth) else {
            throw CaptureCommandError.invalidConfiguration(
                "max-width must be between \(Self.minimumMaxWidth) and \(Self.maximumMaxWidth)"
            )
        }
        guard jpegQuality.isFinite, (0.05...1).contains(jpegQuality) else {
            throw CaptureCommandError.invalidConfiguration("quality must be between 0.05 and 1")
        }

        self.outputDirectory = outputDirectory
        self.duration = duration
        self.framesPerSecond = framesPerSecond
        self.maxWidth = maxWidth
        self.jpegQuality = jpegQuality
        self.includeCursor = includeCursor
    }

    /// Minimum wall-clock spacing between two published frames.
    public var frameInterval: TimeInterval {
        1 / Double(framesPerSecond)
    }
}

// MARK: - Manifest

/// Status values written into `manifest.json`.
public enum PreviewManifestStatus: String, Codable, Equatable, Sendable {
    case capturing
    case completed
    case cancelled
    case failed
}

/// Atomic sidecar describing the current `latest.jpg`.
public struct PreviewManifest: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var app: String
    public var bundleIdentifier: String?
    public var processIdentifier: Int32
    public var windowID: UInt32
    public var latestFrame: String?
    public var width: Int
    public var height: Int
    public var framesPerSecond: Int
    public var includeCursor: Bool
    public var status: PreviewManifestStatus
    public var framesReceived: Int
    public var framesWritten: Int
    public var framesDropped: Int
    public var startedAt: String
    public var updatedAt: String
    public var endedAt: String?
    public var error: String?

    public init(
        app: String,
        bundleIdentifier: String?,
        processIdentifier: Int32,
        windowID: UInt32,
        latestFrame: String?,
        width: Int,
        height: Int,
        framesPerSecond: Int,
        includeCursor: Bool,
        status: PreviewManifestStatus,
        framesReceived: Int,
        framesWritten: Int,
        framesDropped: Int,
        startedAt: String,
        updatedAt: String,
        endedAt: String?,
        error: String?
    ) {
        self.app = app
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.windowID = windowID
        self.latestFrame = latestFrame
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.includeCursor = includeCursor
        self.status = status
        self.framesReceived = framesReceived
        self.framesWritten = framesWritten
        self.framesDropped = framesDropped
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.endedAt = endedAt
        self.error = error
    }
}

// MARK: - Summary

/// Machine-readable result of a `preview` run.
public struct PreviewCaptureSummary: Codable, Equatable, Sendable {
    public let status: CaptureCommandStatus
    public let app: String
    public let bundleIdentifier: String?
    public let processIdentifier: Int32
    public let windowID: Int64
    public let outputDirectory: String
    public let latestFramePath: String?
    public let manifestPath: String?
    public let framesPerSecond: Int
    public let durationRequested: Double
    public let durationCaptured: Double
    public let framesReceived: Int
    public let framesWritten: Int
    public let framesDropped: Int
    public let width: Int
    public let height: Int
    public let includeCursor: Bool
    public let startedAt: String?
    public let endedAt: String?
    public let error: String?

    public init(
        status: CaptureCommandStatus,
        app: String,
        bundleIdentifier: String?,
        processIdentifier: Int32,
        windowID: Int64,
        outputDirectory: String,
        latestFramePath: String?,
        manifestPath: String?,
        framesPerSecond: Int,
        durationRequested: Double,
        durationCaptured: Double,
        framesReceived: Int,
        framesWritten: Int,
        framesDropped: Int,
        width: Int,
        height: Int,
        includeCursor: Bool,
        startedAt: String?,
        endedAt: String?,
        error: String?
    ) {
        self.status = status
        self.app = app
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.windowID = windowID
        self.outputDirectory = outputDirectory
        self.latestFramePath = latestFramePath
        self.manifestPath = manifestPath
        self.framesPerSecond = framesPerSecond
        self.durationRequested = durationRequested
        self.durationCaptured = durationCaptured
        self.framesReceived = framesReceived
        self.framesWritten = framesWritten
        self.framesDropped = framesDropped
        self.width = width
        self.height = height
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

/// File-backed real-time preview. Consumes frames from a `ScreenStreamFrameSource`,
/// publishes at most `framesPerSecond` JPEGs, and atomically replaces
/// `latest.jpg` + `manifest.json`. The latest-frame mailbox holds exactly one
/// unclaimed frame (drop-oldest); at most two pixel buffers are retained by the
/// engine at any moment.
public final class PreviewCaptureEngine: @unchecked Sendable {
    public static let latestFrameFilename = "latest.jpg"
    public static let manifestFilename = "manifest.json"

    private let target: CaptureWindowTarget
    private let configuration: PreviewCaptureConfiguration
    private let frameSource: any ScreenStreamFrameSource
    private let clock: any CaptureClock
    private let fileManager: FileManager
    private let dateProvider: @Sendable () -> Date
    private let renderer = PixelBufferRenderer()
    private let mailbox = LatestFrameMailbox()

    private let stateLock = NSLock()
    private var framesReceived = 0
    private var framesWritten = 0
    private var encodeDrops = 0
    private var lastWrittenWidth = 0
    private var lastWrittenHeight = 0
    private var cancelRequested = false
    private var terminalFailure: String?

    public init(
        target: CaptureWindowTarget,
        configuration: PreviewCaptureConfiguration,
        frameSource: any ScreenStreamFrameSource,
        clock: any CaptureClock = SystemCaptureClock(),
        fileManager: FileManager = .default,
        dateProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.target = target
        self.configuration = configuration
        self.frameSource = frameSource
        self.clock = clock
        self.fileManager = fileManager
        self.dateProvider = dateProvider
    }

    /// Request cooperative cancellation; the run loop exits at the next tick and
    /// the summary reports `cancelled`.
    public func cancel() {
        stateLock.lock()
        cancelRequested = true
        stateLock.unlock()
    }

    public func run() throws -> PreviewCaptureSummary {
        let latestFrameURL = configuration.outputDirectory.appendingPathComponent(Self.latestFrameFilename)
        let manifestURL = configuration.outputDirectory.appendingPathComponent(Self.manifestFilename)

        do {
            try fileManager.createDirectory(at: configuration.outputDirectory, withIntermediateDirectories: true)
        } catch {
            throw CaptureCommandError.outputNotWritable(configuration.outputDirectory.path)
        }

        let startedAt = dateProvider()
        let startedMonotonic = clock.now()
        let endTime = startedMonotonic + configuration.duration

        frameSource.frameHandler = { [weak self] frame in
            guard let self else {
                return
            }
            stateLock.lock()
            framesReceived += 1
            let failed = terminalFailure != nil || cancelRequested
            stateLock.unlock()
            guard !failed else {
                return
            }
            mailbox.push(frame)
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

        var framesWereWritten = false
        do {
            try frameSource.start()
        } catch {
            frameSource.frameHandler = nil
            frameSource.failureHandler = nil
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            let endedAt = dateProvider()
            return makeSummary(
                status: .failed,
                latestFrameURL: nil,
                manifestURL: nil,
                startedAt: startedAt,
                endedAt: endedAt,
                durationCaptured: clock.now() - startedMonotonic,
                error: message
            )
        }

        var lastPublish = startedMonotonic - configuration.frameInterval

        while true {
            let now = clock.now()
            stateLock.lock()
            let stopped = cancelRequested || terminalFailure != nil
            stateLock.unlock()
            if stopped || now >= endTime {
                break
            }

            if now - lastPublish >= configuration.frameInterval, let frame = mailbox.take() {
                do {
                    if try publish(frame: frame, latestFrameURL: latestFrameURL, manifestURL: manifestURL, startedAt: startedAt) {
                        framesWereWritten = true
                    }
                    lastPublish = now
                    continue
                } catch {
                    stateLock.lock()
                    terminalFailure = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                    stateLock.unlock()
                    break
                }
            }

            let remaining = endTime - now
            clock.sleep(min(0.005, min(configuration.frameInterval, max(0, remaining))))
        }

        frameSource.stop()
        frameSource.frameHandler = nil
        frameSource.failureHandler = nil

        // Any frame still parked in the mailbox was received but never written.
        if mailbox.take() != nil {
            stateLock.lock()
            encodeDrops += 1
            stateLock.unlock()
        }

        stateLock.lock()
        let failure = terminalFailure
        let cancelled = cancelRequested && failure == nil
        stateLock.unlock()

        let status: CaptureCommandStatus = failure != nil ? .failed : (cancelled ? .cancelled : .completed)
        let endedAt = dateProvider()
        let durationCaptured = clock.now() - startedMonotonic

        if framesWereWritten {
            try? writeManifest(
                to: manifestURL,
                status: PreviewManifestStatus(rawValue: status.rawValue) ?? .failed,
                startedAt: startedAt,
                endedAt: endedAt,
                error: failure
            )
        }

        return makeSummary(
            status: status,
            latestFrameURL: framesWereWritten ? latestFrameURL : nil,
            manifestURL: framesWereWritten ? manifestURL : nil,
            startedAt: startedAt,
            endedAt: endedAt,
            durationCaptured: durationCaptured,
            error: failure
        )
    }

    // MARK: Publishing

    /// Returns true when a frame was encoded and published; encode failures
    /// count as drops and return false, while I/O failures throw.
    private func publish(frame: CapturedVideoFrame, latestFrameURL: URL, manifestURL: URL, startedAt: Date) throws -> Bool {
        let data: Data
        do {
            data = try renderer.jpegData(
                for: frame.pixelBuffer,
                maxWidth: configuration.maxWidth,
                quality: configuration.jpegQuality
            )
        } catch {
            stateLock.lock()
            encodeDrops += 1
            stateLock.unlock()
            return false
        }

        // Atomic replace: Data.write(.atomic) stages a temp file in the same
        // directory and renames it over the destination.
        try data.write(to: latestFrameURL, options: .atomic)

        let sourceWidth = CVPixelBufferGetWidth(frame.pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(frame.pixelBuffer)
        let scaled = CaptureGeometry.scaledDimensions(
            source: CGSize(width: sourceWidth, height: sourceHeight),
            maxWidth: configuration.maxWidth
        )

        stateLock.lock()
        framesWritten += 1
        lastWrittenWidth = Int(scaled.width)
        lastWrittenHeight = Int(scaled.height)
        stateLock.unlock()

        try writeManifest(to: manifestURL, status: .capturing, startedAt: startedAt, endedAt: nil, error: nil)
        return true
    }

    private func writeManifest(to url: URL, status: PreviewManifestStatus, startedAt: Date, endedAt: Date?, error: String?) throws {
        stateLock.lock()
        let manifest = PreviewManifest(
            app: target.appName,
            bundleIdentifier: target.bundleIdentifier,
            processIdentifier: target.processIdentifier,
            windowID: target.windowID,
            latestFrame: framesWritten > 0 ? Self.latestFrameFilename : nil,
            width: lastWrittenWidth,
            height: lastWrittenHeight,
            framesPerSecond: configuration.framesPerSecond,
            includeCursor: configuration.includeCursor,
            status: status,
            framesReceived: framesReceived,
            framesWritten: framesWritten,
            framesDropped: mailbox.droppedCount + encodeDrops,
            startedAt: CaptureTimestampFormatter.string(from: startedAt),
            updatedAt: CaptureTimestampFormatter.string(from: dateProvider()),
            endedAt: endedAt.map(CaptureTimestampFormatter.string(from:)),
            error: error
        )
        stateLock.unlock()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    private func makeSummary(
        status: CaptureCommandStatus,
        latestFrameURL: URL?,
        manifestURL: URL?,
        startedAt: Date,
        endedAt: Date,
        durationCaptured: Double,
        error: String?
    ) -> PreviewCaptureSummary {
        stateLock.lock()
        defer { stateLock.unlock() }
        return PreviewCaptureSummary(
            status: status,
            app: target.appName,
            bundleIdentifier: target.bundleIdentifier,
            processIdentifier: target.processIdentifier,
            windowID: Int64(target.windowID),
            outputDirectory: configuration.outputDirectory.path,
            latestFramePath: latestFrameURL?.path,
            manifestPath: manifestURL?.path,
            framesPerSecond: configuration.framesPerSecond,
            durationRequested: configuration.duration,
            durationCaptured: durationCaptured,
            framesReceived: framesReceived,
            framesWritten: framesWritten,
            framesDropped: mailbox.droppedCount + encodeDrops,
            width: lastWrittenWidth,
            height: lastWrittenHeight,
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
public enum PreviewCaptureCommand {
    public static func run(app query: String, options: PreviewCaptureOptions) throws -> PreviewCaptureSummary {
        let runningApp = try CaptureTargetResolver.resolveRunningApp(query: query)
        let target = try CaptureTargetResolver.resolveWindow(for: runningApp)
        let configuration = try PreviewCaptureConfiguration(
            outputDirectory: URL(fileURLWithPath: options.outputDirectory),
            duration: options.duration,
            framesPerSecond: options.framesPerSecond,
            maxWidth: options.maxWidth,
            jpegQuality: options.jpegQuality,
            includeCursor: options.includeCursor
        )
        let source = ScreenCaptureKitFrameSource(
            target: target,
            maxWidth: configuration.maxWidth,
            framesPerSecond: configuration.framesPerSecond,
            includeCursor: configuration.includeCursor
        )
        let engine = PreviewCaptureEngine(target: target, configuration: configuration, frameSource: source)

        let signalScope = CaptureSignalScope {
            engine.cancel()
        }
        defer {
            signalScope.close()
        }

        return try engine.run()
    }
}
