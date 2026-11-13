import Foundation
import XCTest
@testable import UltraTermComputerUseKit

/// Still-image sideband contract: `image_path` content items, conditional
/// result metadata keys, and base64-to-disk externalization.
final class SidebandSchemaContractTests: XCTestCase {
    func testPNGImageFileItemMatchesSidebandSchema() {
        let item = ToolResultContentItem.pngImageFile(path: "/tmp/shot-0.png")
        let dictionary = item.dictionary

        XCTAssertEqual(dictionary["type"] as? String, "image_path")
        XCTAssertEqual(dictionary["mimeType"] as? String, "image/png")
        XCTAssertEqual(dictionary["path"] as? String, "/tmp/shot-0.png")
        XCTAssertNil(dictionary["data"], "sideband items must not inline base64 payloads")
    }

    func testPNGImageFileHonorsExplicitMimeType() {
        let item = ToolResultContentItem.pngImageFile(path: "/tmp/frame.jpg", mimeType: "image/jpeg")

        XCTAssertEqual(item.dictionary["type"] as? String, "image_path")
        XCTAssertEqual(item.dictionary["mimeType"] as? String, "image/jpeg")
    }

    func testResultDictionaryOmitsErrorAndStateIDWhenUnset() {
        let dictionary = ToolCallResult.text("ok").asDictionary

        XCTAssertEqual(dictionary["isError"] as? Bool, false)
        XCTAssertNotNil(dictionary["content"])
        XCTAssertNil(dictionary["error"])
        XCTAssertNil(dictionary["state_id"])
    }

    func testResultDictionaryIncludesErrorAndStateIDWhenSet() {
        let info = ComputerUseErrorInfo(code: "stale_state", phase: .execute, retryable: true, message: "old")
        let result = ToolCallResult(content: [.text("old")], isError: true, errorInfo: info, stateID: "1:2:abc")
        let dictionary = result.asDictionary

        XCTAssertEqual((dictionary["error"] as? [String: Any])?["code"] as? String, "stale_state")
        XCTAssertEqual(dictionary["state_id"] as? String, "1:2:abc")
    }

    func testExternalizeWritesExactPNGBytesToDisk() throws {
        let image = try ContractTestImages.solidCGImage(width: 16, height: 8)
        let pngData = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))

        try withContractTempDirectory { directory in
            let mediaDir = directory.appendingPathComponent("nested/media", isDirectory: true).path
            let result = ToolCallResult(content: [
                .text("state text"),
                .pngImage(pngData),
                .pngImageFile(path: "/already/external.png"),
            ])

            let externalized = try externalizeToolResultImages(result, mediaDir: mediaDir, stem: "shot")

            XCTAssertEqual(externalized.content.count, 3)

            let textItem = externalized.content[0].dictionary
            XCTAssertEqual(textItem["type"] as? String, "text")
            XCTAssertEqual(textItem["text"] as? String, "state text")

            let imageItem = externalized.content[1].dictionary
            XCTAssertEqual(imageItem["type"] as? String, "image_path")
            XCTAssertEqual(imageItem["mimeType"] as? String, "image/png")
            let writtenPath = try XCTUnwrap(imageItem["path"] as? String)
            XCTAssertEqual(URL(fileURLWithPath: writtenPath).lastPathComponent, "shot-1.png")
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: writtenPath)), pngData)

            let passthrough = externalized.content[2].dictionary
            XCTAssertEqual(passthrough["type"] as? String, "image_path")
            XCTAssertEqual(passthrough["path"] as? String, "/already/external.png")

            // The written payload is a decodable image of the same size.
            XCTAssertEqual(
                try ContractTestImages.encodedPixelSize(Data(contentsOf: URL(fileURLWithPath: writtenPath))),
                CGSize(width: 16, height: 8)
            )
        }
    }

    func testExternalizeNamesFilesByContentIndex() throws {
        let image = try ContractTestImages.solidCGImage(width: 4, height: 4)
        let pngData = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))

        try withContractTempDirectory { directory in
            let result = ToolCallResult(content: [.pngImage(pngData), .text("gap"), .pngImage(pngData)])
            let externalized = try externalizeToolResultImages(result, mediaDir: directory.path, stem: "cap")

            let first = externalized.content[0].dictionary["path"] as? String
            let second = externalized.content[2].dictionary["path"] as? String
            XCTAssertEqual(first.map { URL(fileURLWithPath: $0).lastPathComponent }, "cap-0.png")
            XCTAssertEqual(second.map { URL(fileURLWithPath: $0).lastPathComponent }, "cap-2.png")
        }
    }

    func testExternalizeSanitizesStemAndFallsBackToCapture() throws {
        let image = try ContractTestImages.solidCGImage(width: 4, height: 4)
        let pngData = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))

        try withContractTempDirectory { directory in
            let messy = try externalizeToolResultImages(
                ToolCallResult(content: [.pngImage(pngData)]),
                mediaDir: directory.path,
                stem: "My App!/v2"
            )
            let messyName = (messy.content[0].dictionary["path"] as? String)
                .map { URL(fileURLWithPath: $0).lastPathComponent }
            XCTAssertEqual(messyName, "My-App--v2-0.png")

            let empty = try externalizeToolResultImages(
                ToolCallResult(content: [.pngImage(pngData)]),
                mediaDir: directory.path,
                stem: ""
            )
            let emptyName = (empty.content[0].dictionary["path"] as? String)
                .map { URL(fileURLWithPath: $0).lastPathComponent }
            XCTAssertEqual(emptyName, "capture-0.png")
        }
    }

    func testExternalizeWithoutImagesReturnsResultUntouched() throws {
        try withContractTempDirectory { directory in
            let info = ComputerUseErrorInfo(code: "error", phase: .execute, retryable: false, message: "m")
            let result = ToolCallResult(
                content: [.text("only text"), .pngImageFile(path: "/x.png")],
                isError: true,
                errorInfo: info,
                stateID: "9:9:state"
            )

            let externalized = try externalizeToolResultImages(result, mediaDir: directory.path, stem: "shot")

            XCTAssertEqual(externalized.content.count, 2)
            XCTAssertTrue(externalized.isError)
            XCTAssertEqual(externalized.errorInfo, info)
            XCTAssertEqual(externalized.stateID, "9:9:state")
            XCTAssertEqual(externalized.content[1].dictionary["path"] as? String, "/x.png")
            let directoryContents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            XCTAssertTrue(
                directoryContents.isEmpty,
                "no files may be written when there is nothing to externalize"
            )
        }
    }

    func testExternalizePreservesResultMetadata() throws {
        let image = try ContractTestImages.solidCGImage(width: 4, height: 4)
        let pngData = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))

        try withContractTempDirectory { directory in
            let info = ComputerUseErrorInfo(code: "state_unavailable", phase: .execute, retryable: true, message: "m")
            let result = ToolCallResult(content: [.pngImage(pngData)], isError: false, errorInfo: info, stateID: "s")
            let externalized = try externalizeToolResultImages(result, mediaDir: directory.path, stem: "shot")

            XCTAssertEqual(externalized.errorInfo, info)
            XCTAssertEqual(externalized.stateID, "s")
            XCTAssertFalse(externalized.isError)
        }
    }
}
