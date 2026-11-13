import AppKit
import CoreMedia
import CoreVideo
import Darwin
import ImageIO
import XCTest
@testable import UltraTermComputerUseKit

// Shared, deterministic fixtures for the contract test suites. Everything here
// is synthetic: pixel buffers are generated in memory, clocks are advanced by
// hand, and frame sources are fed from test code. Nothing touches TCC, real
// applications, the desktop, or the user's UI.

enum ContractTestImages {
    /// Deterministic per-pixel noise (incompressible) in premultiplied-last RGBA.
    static func noisyCGImage(width: Int, height: Int) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let pixel = index / 4
            let x = pixel % width
            let y = pixel / width
            pixels[index] = UInt8((x * 37 + y * 17) & 0xFF)
            pixels[index + 1] = UInt8((x * 11 + y * 43) & 0xFF)
            pixels[index + 2] = UInt8((x * 71 + y * 5 + (x * y)) & 0xFF)
            pixels[index + 3] = 255
        }
        return try cgImage(width: width, height: height, pixels: pixels)
    }

    /// Uniform color image (highly compressible).
    static func solidCGImage(width: Int, height: Int) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = 80
            pixels[index + 1] = 140
            pixels[index + 2] = 220
            pixels[index + 3] = 255
        }
        return try cgImage(width: width, height: height, pixels: pixels)
    }

    private static func cgImage(width: Int, height: Int, pixels: [UInt8]) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    /// Pixel dimensions recorded in an encoded PNG/JPEG payload.
    static func encodedPixelSize(_ data: Data) throws -> CGSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        return CGSize(width: width, height: height)
    }

    /// 32BGRA pixel buffer filled with a deterministic gradient.
    static func pixelBuffer(width: Int, height: Int, seed: UInt8 = 0) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let baseAddress = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let offset = x * 4
                row[offset] = UInt8((x &+ Int(seed)) & 0xFF)
                row[offset + 1] = UInt8((y &+ Int(seed)) & 0xFF)
                row[offset + 2] = UInt8(((x + y) &+ Int(seed)) & 0xFF)
                row[offset + 3] = 255
            }
        }
        return pixelBuffer
    }
}

/// Runs `body` inside a unique temporary directory and always removes it.
func withContractTempDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ultraterm-computer-use-contract-\(UUID().uuidString)", isDirectory: true)
    // The directory must exist before `body` runs: tests that stage files
    // (e.g. a stale output) before the capture engine creates its parent
    // directory would otherwise fail with NSFileNoSuchFileError.
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        // `try?` keeps cleanup idempotent even if the body already removed it.
        try? FileManager.default.removeItem(at: directory)
    }
    return try body(directory)
}

/// Async counterpart for contracts that use modern AVFoundation loading APIs.
func withContractTempDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ultraterm-computer-use-contract-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}

/// Deterministic monotonic clock. `sleep` advances time instantly and then
/// runs scheduled work, so engines observe frames arriving "over time" without
/// any real waiting.
final class FakeCaptureClock: CaptureClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 0
    /// Invoked after every time advance, on the caller's thread.
    var onAdvance: ((TimeInterval) -> Void)?

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func sleep(_ interval: TimeInterval) {
        guard interval > 0 else {
            return
        }
        advance(by: interval)
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        current += interval
        let now = current
        lock.unlock()
        onAdvance?(now)
    }
}

/// Synthetic frame source. Frames are only delivered when the test explicitly
/// emits them, keeping every capture engine run deterministic.
final class FakeFrameSource: ScreenStreamFrameSource, @unchecked Sendable {
    var frameHandler: (@Sendable (CapturedVideoFrame) -> Void)?
    var failureHandler: (@Sendable (any Error) -> Void)?

    private let lock = NSLock()
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var startError: Error?
    /// Invoked at the end of a successful `start()`, after handlers are set.
    var onStart: (() -> Void)?

    func start() throws {
        lock.lock()
        startCount += 1
        let error = startError
        lock.unlock()
        if let error {
            throw error
        }
        onStart?()
    }

    func stop() {
        lock.lock()
        stopCount += 1
        lock.unlock()
    }

    func emit(width: Int, height: Int, atSeconds seconds: Double, seed: UInt8 = 0) {
        do {
            let buffer = try ContractTestImages.pixelBuffer(width: width, height: height, seed: seed)
            let timestamp = CMTime(seconds: seconds, preferredTimescale: 90_000)
            frameHandler?(CapturedVideoFrame(pixelBuffer: buffer, presentationTimestamp: timestamp))
        } catch {
            XCTFail("failed to build synthetic frame: \(error)")
        }
    }

    func fail(_ error: Error) {
        failureHandler?(error)
    }
}

enum ContractCaptureError: Error, Equatable {
    case syntheticStartFailure
    case syntheticStreamFailure
}

/// Builds an `AppSnapshot` without any running app, accessibility, or screen
/// capture. `NSRunningApplication.current` stands in as the application object;
/// the descriptor pid is synthetic so cache validation stays under test control.
func makeContractSnapshot(
    pid: pid_t = 4_242,
    windowID: CGWindowID? = 77,
    stateID: String = "4242:77:test-state",
    bundleIdentifier: String? = "dev.test.contract",
    appName: String = "ContractApp"
) -> AppSnapshot {
    AppSnapshot(
        app: RunningAppDescriptor(
            name: appName,
            bundleIdentifier: bundleIdentifier,
            pid: pid,
            runningApplication: NSRunningApplication.current
        ),
        windowTitle: "Contract Window",
        windowBounds: CGRect(x: 0, y: 0, width: 800, height: 600),
        targetWindowID: windowID,
        targetWindowLayer: 0,
        screenshotData: nil,
        mode: .accessibility,
        treeLines: [],
        focusedSummary: nil,
        focusedElement: nil,
        selectedText: nil,
        windowElement: nil,
        elements: [:],
        stateID: stateID
    )
}

/// Connected socket pair for transport framing tests. The channel owns one
/// end; the test drives the other.
func makeContractSocketPair() throws -> (channel: Int32, peer: Int32) {
    var sockets: [Int32] = [0, 0]
    let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets)
    XCTAssertEqual(result, 0)
    guard result == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return (sockets[0], sockets[1])
}

/// Mutable wall clock for TTL tests.
final class MutableDateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) {
        current = start
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }
}
