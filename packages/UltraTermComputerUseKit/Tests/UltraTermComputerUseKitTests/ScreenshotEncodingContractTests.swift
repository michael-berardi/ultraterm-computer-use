import ImageIO
import XCTest
@testable import UltraTermComputerUseKit

/// Screen Recording gate for the `inspect` command. The screenshot encoder
/// (ImageCaptureConfig / encodeScreenshot) has its own tests, so only the
/// permission contract is covered here.
final class ScreenshotEncodingContractTests: XCTestCase {
    func testRequestedScreenshotRequiresScreenRecordingPermission() {
        let permissions = PermissionDiagnostics(
            accessibilityTrusted: true,
            screenCaptureGranted: false
        )

        XCTAssertThrowsError(
            try validateSnapshotPermissions(permissions, includeScreenshot: true)
        ) { error in
            guard case let ComputerUseError.permissionDenied(message) = error else {
                return XCTFail("expected permissionDenied, got \(error)")
            }
            XCTAssertTrue(message.contains("Screen Recording permission is required"))
        }
    }

    func testTextOnlySnapshotDoesNotRequireScreenRecordingPermission() {
        let permissions = PermissionDiagnostics(
            accessibilityTrusted: true,
            screenCaptureGranted: false
        )

        XCTAssertNoThrow(
            try validateSnapshotPermissions(permissions, includeScreenshot: false)
        )
    }
}
