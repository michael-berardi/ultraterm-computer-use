import XCTest
@testable import UltraTermComputerUseKit

/// Screenshot-pixel to window-point coordinate conversion, including the 2x
/// Retina case. Pure math over explicit sizes; no displays are queried.
final class CoordinateConversionContractTests: XCTestCase {
    func testRetina2xScaleIsDerivedFromPixelSizeAgainstWindowBounds() {
        let scale = screenshotPixelScale(
            screenshotPixelSize: CGSize(width: 2560, height: 1440),
            windowBounds: CGRect(x: 100, y: 200, width: 1280, height: 720)
        )

        XCTAssertEqual(scale, CGSize(width: 2, height: 2))
    }

    func testRetina2xPixelPointConvertsToWindowPointByHalving() {
        let point = screenshotPixelToWindowPoint(
            CGPoint(x: 512, y: 288),
            screenshotPixelSize: CGSize(width: 2560, height: 1440),
            windowBounds: CGRect(x: 0, y: 0, width: 1280, height: 720)
        )

        XCTAssertEqual(point, CGPoint(x: 256, y: 144))
    }

    func testNonUniformScaleConvertsEachAxisIndependently() {
        let point = screenshotPixelToWindowPoint(
            CGPoint(x: 400, y: 300),
            screenshotPixelSize: CGSize(width: 2000, height: 1500),
            windowBounds: CGRect(x: 0, y: 0, width: 1000, height: 1000)
        )

        XCTAssertEqual(point, CGPoint(x: 200, y: 200))
    }

    func testUnscaledCaptureIsIdentity() {
        let point = screenshotPixelToWindowPoint(
            CGPoint(x: 123, y: 456),
            screenshotPixelSize: CGSize(width: 800, height: 600),
            windowBounds: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        XCTAssertEqual(point, CGPoint(x: 123, y: 456))
    }

    func testMissingOrDegenerateInputsFallBackToIdentity() {
        let point = CGPoint(x: 42, y: 24)

        XCTAssertEqual(
            screenshotPixelToWindowPoint(point, screenshotPixelSize: nil, windowBounds: CGRect(x: 0, y: 0, width: 100, height: 100)),
            point
        )
        XCTAssertEqual(
            screenshotPixelToWindowPoint(point, screenshotPixelSize: CGSize(width: 100, height: 100), windowBounds: nil),
            point
        )
        XCTAssertEqual(
            screenshotPixelToWindowPoint(point, screenshotPixelSize: CGSize(width: 200, height: 200), windowBounds: .zero),
            point
        )
        XCTAssertEqual(
            screenshotPixelToWindowPoint(point, screenshotPixelSize: .zero, windowBounds: CGRect(x: 0, y: 0, width: 100, height: 100)),
            point
        )
    }
}
