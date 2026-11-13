import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
// `SCStream`, `SCShareableContent`, and the stream delegate protocols carry no
// `Sendable` annotations. Their use here is confined to the synchronous bridge
// and one serial sample queue, so a narrowly scoped preconcurrency import is
// justified instead of disabling concurrency checking file-wide.
@preconcurrency import ScreenCaptureKit

// MARK: - Errors

public enum CaptureCommandError: Error, LocalizedError, Equatable {
    case appNotRunning(String)
    case noCapturableWindow(String)
    case screenRecordingPermissionDenied
    case invalidConfiguration(String)
    case outputNotWritable(String)
    case captureFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .appNotRunning(query):
            return "No running application matches '\(query)'. preview/record never launch apps; start the app first and retry."
        case let .noCapturableWindow(app):
            return "Application '\(app)' has no on-screen capturable window."
        case .screenRecordingPermissionDenied:
            return "Screen Recording permission is not granted to this process. Run `ultraterm-computer-use doctor` and grant permission before capturing."
        case let .invalidConfiguration(message):
            return "Invalid capture configuration: \(message)"
        case let .outputNotWritable(path):
            return "Output location is not writable: \(path)"
        case let .captureFailed(message):
            return "Capture failed: \(message)"
        }
    }
}

// MARK: - Clock seam

/// Monotonic clock used by capture engines so tests can advance time deterministically.
public protocol CaptureClock: Sendable {
    /// Monotonic seconds; must never move backwards.
    func now() -> TimeInterval
    /// Sleep for up to `interval` seconds. Implementations may return early.
    func sleep(_ interval: TimeInterval)
}

public struct SystemCaptureClock: CaptureClock {
    public init() {}

    public func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    public func sleep(_ interval: TimeInterval) {
        guard interval > 0 else {
            return
        }
        Thread.sleep(forTimeInterval: interval)
    }
}

// MARK: - Frames

/// A single captured video frame in pixel form. `@unchecked Sendable` because
/// `CVPixelBuffer` is a CoreFoundation type; ownership is transferred, never shared
/// mutably.
public struct CapturedVideoFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let presentationTimestamp: CMTime

    public init(pixelBuffer: CVPixelBuffer, presentationTimestamp: CMTime) {
        self.pixelBuffer = pixelBuffer
        self.presentationTimestamp = presentationTimestamp
    }
}

/// Source of captured frames. The production implementation wraps `SCStream`;
/// tests inject synthetic pixel-buffer producers. Implementations must invoke
/// handlers from a single serial context.
public protocol ScreenStreamFrameSource: AnyObject, Sendable {
    var frameHandler: (@Sendable (CapturedVideoFrame) -> Void)? { get set }
    var failureHandler: (@Sendable (any Error) -> Void)? { get set }

    func start() throws
    func stop()
}

// MARK: - Target resolution

/// A resolved, already-running capture target. Resolution never launches,
/// activates, or unhides the application.
public struct CaptureWindowTarget: Equatable, Sendable {
    public let appName: String
    public let bundleIdentifier: String?
    public let processIdentifier: pid_t
    public let windowID: CGWindowID
    public let windowTitle: String?
    public let framePoints: CGRect
    public let backingScaleFactor: CGFloat

    public init(
        appName: String,
        bundleIdentifier: String?,
        processIdentifier: pid_t,
        windowID: CGWindowID,
        windowTitle: String?,
        framePoints: CGRect,
        backingScaleFactor: CGFloat
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.windowID = windowID
        self.windowTitle = windowTitle
        self.framePoints = framePoints
        self.backingScaleFactor = backingScaleFactor
    }

    /// Native pixel size of the window backing store.
    public var nativePixelSize: CGSize {
        CGSize(
            width: max(1, (framePoints.width * backingScaleFactor).rounded()),
            height: max(1, (framePoints.height * backingScaleFactor).rounded())
        )
    }
}

public enum CaptureTargetResolver {
    /// Resolve an exact running app by bundle identifier, localized name, or
    /// executable name. Never launches or activates anything.
    public static func resolveRunningApp(query: String) throws -> RunningAppDescriptor {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw CaptureCommandError.appNotRunning(query)
        }

        let running = AppDiscovery.runningApps().filter { descriptor in
            !AppSafetyPolicy.isBlocked(bundleIdentifier: descriptor.bundleIdentifier)
        }

        if normalized.contains("."),
           let match = running.first(where: {
               $0.bundleIdentifier?.caseInsensitiveCompare(normalized) == .orderedSame
           })
        {
            return match
        }

        if let match = running.first(where: {
            $0.name.caseInsensitiveCompare(normalized) == .orderedSame
                || $0.runningApplication.executableURL?
                .deletingPathExtension().lastPathComponent
                .caseInsensitiveCompare(normalized) == .orderedSame
        }) {
            return match
        }

        throw CaptureCommandError.appNotRunning(normalized)
    }

    /// Pick the best on-screen window for a running app without activating it.
    /// Prefers titled, larger, layer-0 windows; ties break on window ID so the
    /// choice is deterministic.
    public static func resolveWindow(for app: RunningAppDescriptor) throws -> CaptureWindowTarget {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureCommandError.screenRecordingPermissionDenied
        }

        // Capture only Sendable values in the async bridge closure; the
        // descriptor retains an NSRunningApplication.
        let pid = app.pid
        let name = app.name
        let bundleIdentifier = app.bundleIdentifier

        return try BlockingAsyncBridge.run(timeout: 15) {
            try await resolveWindowAsync(pid: pid, appName: name, bundleIdentifier: bundleIdentifier)
        }
    }

    private static func resolveWindowAsync(pid: pid_t, appName: String, bundleIdentifier: String?) async throws -> CaptureWindowTarget {
        let content = try await SCShareableContent.current
        let candidates = content.windows.filter { window in
            window.owningApplication?.processID == pid
                && window.windowLayer == 0
                && window.isOnScreen
                && window.frame.width >= 64
                && window.frame.height >= 64
        }

        guard let best = candidates.max(by: { lhs, rhs in
            let lhsTitled = lhs.title?.isEmpty == false
            let rhsTitled = rhs.title?.isEmpty == false
            if lhsTitled != rhsTitled {
                return !lhsTitled
            }
            let lhsArea = lhs.frame.width * lhs.frame.height
            let rhsArea = rhs.frame.width * rhs.frame.height
            if lhsArea != rhsArea {
                return lhsArea < rhsArea
            }
            return lhs.windowID > rhs.windowID
        }) else {
            throw CaptureCommandError.noCapturableWindow(appName)
        }

        return CaptureWindowTarget(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            processIdentifier: pid,
            windowID: best.windowID,
            windowTitle: best.title,
            framePoints: best.frame,
            backingScaleFactor: backingScaleFactor(for: best.frame)
        )
    }

    private static func backingScaleFactor(for framePoints: CGRect) -> CGFloat {
        NSScreen.screens.first(where: { $0.frame.intersects(framePoints) })?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
    }
}

// MARK: - Geometry

/// Even-dimension scaling math shared by preview and recording.
enum CaptureGeometry {
    static let minimumDimension = 2

    /// Scale `source` so its width does not exceed `maxWidth`, preserving aspect
    /// ratio and rounding both dimensions down to even values (H.264 requirement).
    static func scaledDimensions(source: CGSize, maxWidth: Int) -> CGSize {
        let sourceWidth = max(1, Int(source.width.rounded()))
        let sourceHeight = max(1, Int(source.height.rounded()))
        let clampedMaxWidth = max(minimumDimension, maxWidth)

        var width = sourceWidth
        var height = sourceHeight
        if width > clampedMaxWidth {
            let scale = Double(clampedMaxWidth) / Double(width)
            width = clampedMaxWidth
            height = max(1, Int((Double(sourceHeight) * scale).rounded()))
        }

        return CGSize(width: evenDimension(width), height: evenDimension(height))
    }

    static func evenDimension(_ value: Int) -> Int {
        max(minimumDimension, value & ~1)
    }
}

// MARK: - Pixel rendering

/// Bounded CVPixelBuffer rendering: scales via Core Image, encodes JPEG, or
/// renders into an `AVAssetWriterInputPixelBufferAdaptor` pool buffer. Buffers
/// are processed one at a time and never retained.
final class PixelBufferRenderer: @unchecked Sendable {
    private let context: CIContext
    private let colorSpace: CGColorSpace

    init(context: CIContext = CIContext(options: [.cacheIntermediates: false])) {
        self.context = context
        self.colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// JPEG bytes for `pixelBuffer`, downscaled so width ≤ `maxWidth`.
    func jpegData(for pixelBuffer: CVPixelBuffer, maxWidth: Int, quality: Double) throws -> Data {
        let sourceSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let targetSize = CaptureGeometry.scaledDimensions(source: sourceSize, maxWidth: maxWidth)
        let image = scaledImage(from: pixelBuffer, sourceSize: sourceSize, targetSize: targetSize)

        guard let data = context.jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            options: [.init(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
        ) else {
            throw CaptureCommandError.captureFailed("JPEG encoding failed")
        }

        return data
    }

    /// Render `pixelBuffer` into `destination` and return it, or nil when the
    /// pool cannot provide a buffer right now.
    func renderedBuffer(
        _ pixelBuffer: CVPixelBuffer,
        into adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool,
              let destination = createPixelBuffer(from: pool)
        else {
            return nil
        }

        let targetSize = CGSize(
            width: CVPixelBufferGetWidth(destination),
            height: CVPixelBufferGetHeight(destination)
        )
        let sourceSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let image = scaledImage(from: pixelBuffer, sourceSize: sourceSize, targetSize: targetSize)

        context.render(
            image,
            to: destination,
            bounds: CGRect(origin: .zero, size: targetSize),
            colorSpace: colorSpace
        )
        return destination
    }

    private func scaledImage(from pixelBuffer: CVPixelBuffer, sourceSize: CGSize, targetSize: CGSize) -> CIImage {
        let base = CIImage(cvPixelBuffer: pixelBuffer)
        let sourceWidth = max(1, Int(sourceSize.width.rounded()))
        let targetWidth = max(1, Int(targetSize.width.rounded()))
        guard sourceWidth != targetWidth
            || max(1, Int(sourceSize.height.rounded())) != max(1, Int(targetSize.height.rounded()))
        else {
            return base
        }

        let scale = targetSize.width / sourceSize.width
        return base.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale,
            kCIInputAspectRatioKey: 1.0,
        ])
    }

    private func createPixelBuffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard status == kCVReturnSuccess else {
            return nil
        }
        return buffer
    }
}

// MARK: - Timestamps

/// Rebases source timestamps to zero and guarantees strictly increasing output
/// timestamps even when the source delivers non-monotonic or invalid values.
struct MonotonicTimestampNormalizer {
    private var firstSourceSeconds: Double?
    private var lastEmittedSeconds: Double?
    let minimumDeltaSeconds: Double
    let timescale: CMTimeScale

    init(minimumDeltaSeconds: Double, timescale: CMTimeScale = 90_000) {
        self.minimumDeltaSeconds = minimumDeltaSeconds
        self.timescale = timescale
    }

    mutating func normalize(sourceTimestamp: CMTime) -> CMTime {
        let sourceSeconds = sourceTimestamp.isNumeric ? sourceTimestamp.seconds : nil

        let candidate: Double
        if let first = firstSourceSeconds {
            let rebased = (sourceSeconds ?? (lastEmittedSeconds ?? 0) + minimumDeltaSeconds) - first
            candidate = max(0, rebased)
        } else {
            firstSourceSeconds = sourceSeconds ?? 0
            candidate = 0
        }

        var emitted = candidate
        if let last = lastEmittedSeconds, emitted <= last {
            emitted = last + minimumDeltaSeconds
        }
        lastEmittedSeconds = emitted

        return CMTime(seconds: emitted, preferredTimescale: timescale)
    }
}

// MARK: - Latest-frame mailbox

/// Depth-1, drop-oldest frame slot. A producer replacing an unclaimed frame
/// counts one drop. Retains at most one pixel buffer.
final class LatestFrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var slot: CapturedVideoFrame?
    private var dropped = 0

    var droppedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return slot == nil ? 0 : 1
    }

    func push(_ frame: CapturedVideoFrame) {
        lock.lock()
        if slot != nil {
            dropped += 1
        }
        slot = frame
        lock.unlock()
    }

    func take() -> CapturedVideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        let frame = slot
        slot = nil
        return frame
    }
}

// MARK: - ScreenCaptureKit frame source

/// Production `ScreenStreamFrameSource` backed by `SCStream`. Captures a single
/// desktop-independent window with a bounded sample queue and audio disabled.
public final class ScreenCaptureKitFrameSource: NSObject, ScreenStreamFrameSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public let target: CaptureWindowTarget
    public let framesPerSecond: Int
    public let includeCursor: Bool
    /// Pixel dimensions the stream is configured to deliver.
    public let outputPixelSize: CGSize

    public var frameHandler: (@Sendable (CapturedVideoFrame) -> Void)?
    public var failureHandler: (@Sendable (any Error) -> Void)?

    private let sampleQueue = DispatchQueue(label: "ultraterm-computer-use.stream.samples", qos: .userInitiated)
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var failureReported = false

    public init(target: CaptureWindowTarget, maxWidth: Int, framesPerSecond: Int, includeCursor: Bool) {
        self.target = target
        self.framesPerSecond = framesPerSecond
        self.includeCursor = includeCursor
        self.outputPixelSize = CaptureGeometry.scaledDimensions(
            source: target.nativePixelSize,
            maxWidth: maxWidth
        )
        super.init()
    }

    public func start() throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureCommandError.screenRecordingPermissionDenied
        }

        let startedStream: SCStream = try BlockingAsyncBridge.run(timeout: 15) {
            let content = try await SCShareableContent.current
            guard let window = content.windows.first(where: { $0.windowID == self.target.windowID }) else {
                throw CaptureCommandError.noCapturableWindow(self.target.appName)
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int(self.outputPixelSize.width))
            configuration.height = max(1, Int(self.outputPixelSize.height))
            configuration.minimumFrameInterval = CMTime(
                value: 1,
                timescale: CMTimeScale(max(1, self.framesPerSecond))
            )
            configuration.queueDepth = 3
            configuration.showsCursor = self.includeCursor
            configuration.scalesToFit = true
            configuration.ignoreShadowsSingleWindow = true
            configuration.capturesAudio = false
            configuration.pixelFormat = kCVPixelFormatType_32BGRA

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.sampleQueue)
            try await stream.startCapture()
            return stream
        }

        stateLock.lock()
        stream = startedStream
        failureReported = false
        stateLock.unlock()
    }

    public func stop() {
        stateLock.lock()
        let activeStream = stream
        stream = nil
        stateLock.unlock()

        guard let activeStream else {
            return
        }

        do {
            try BlockingAsyncBridge.run(timeout: 10) {
                try activeStream.removeStreamOutput(self, type: .screen)
                try await activeStream.stopCapture()
            }
        } catch {
            // Teardown must never throw; the surface is gone or the stream already stopped.
        }
    }

    // MARK: SCStreamOutput

    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            return
        }

        frameHandler?(CapturedVideoFrame(
            pixelBuffer: pixelBuffer,
            presentationTimestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        ))
    }

    // MARK: SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        stateLock.lock()
        let alreadyReported = failureReported
        failureReported = true
        stateLock.unlock()

        guard !alreadyReported else {
            return
        }
        failureHandler?(error)
    }
}

// MARK: - Cancellation signal scope

/// Installs SIGINT/SIGTERM dispatch sources that cancel the supplied engine and
/// restores default handling when the scope closes. Lives for one command run.
final class CaptureSignalScope: @unchecked Sendable {
    private let sources: [DispatchSourceSignal]

    init(onSignal: @escaping @Sendable () -> Void) {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        var installed: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            source.setEventHandler(handler: onSignal)
            source.resume()
            installed.append(source)
        }
        sources = installed
    }

    func close() {
        for source in sources {
            source.cancel()
        }
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }
}
