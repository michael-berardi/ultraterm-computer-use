import Foundation

public struct ToolResultContentItem: @unchecked Sendable {
    public let dictionary: [String: Any]

    public static func text(_ text: String) -> ToolResultContentItem {
        ToolResultContentItem(
            dictionary: [
                "type": "text",
                "text": text,
            ]
        )
    }

    static func screenshotImage(_ data: Data) -> ToolResultContentItem {
        ToolResultContentItem(dictionary: [
            "type": "image", "data": data.base64EncodedString(),
            "mimeType": data.starts(with: [0xff, 0xd8, 0xff]) ? "image/jpeg" : (data.count >= 12 && String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WEBP" ? "image/webp" : "image/png"),
        ])
    }

    public static func pngImage(_ data: Data) -> ToolResultContentItem {
        ToolResultContentItem(
            dictionary: [
                "type": "image",
                "data": data.base64EncodedString(),
                "mimeType": "image/png",
            ]
        )
    }

    /// Sideband reference to an image written to disk. Keeps base64 payloads
    /// out of stdout; consumers load the file at `path` instead.
    public static func pngImageFile(path: String, mimeType: String = "image/png") -> ToolResultContentItem {
        ToolResultContentItem(
            dictionary: [
                "type": "image_path",
                "mimeType": mimeType,
                "path": path,
            ]
        )
    }
}

public struct ToolCallResult: @unchecked Sendable {
    public let content: [ToolResultContentItem]
    public let isError: Bool
    public let errorInfo: ComputerUseErrorInfo?
    public let stateID: String?

    public init(
        content: [ToolResultContentItem],
        isError: Bool = false,
        errorInfo: ComputerUseErrorInfo? = nil,
        stateID: String? = nil
    ) {
        self.content = content
        self.isError = isError
        self.errorInfo = errorInfo
        self.stateID = stateID
    }

    public var primaryText: String? {
        content.first(where: { $0.dictionary["type"] as? String == "text" })?.dictionary["text"] as? String
    }

    /// Plain-text CLI output includes observation notes but never image bytes.
    public var textContent: String {
        content.compactMap { item in
            item.dictionary["type"] as? String == "text" ? item.dictionary["text"] as? String : nil
        }.joined(separator: "\n")
    }

    public var asDictionary: [String: Any] {
        var dictionary: [String: Any] = [
            "content": content.map(\.dictionary),
            "isError": isError,
        ]

        if let errorInfo {
            dictionary["error"] = errorInfo.asDictionary
        }
        if let stateID {
            dictionary["state_id"] = stateID
        }

        return dictionary
    }

    public static func text(_ text: String, isError: Bool = false) -> ToolCallResult {
        ToolCallResult(content: [.text(text)], isError: isError)
    }

    public static func text(_ text: String, errorInfo: ComputerUseErrorInfo) -> ToolCallResult {
        ToolCallResult(content: [.text(text)], isError: true, errorInfo: errorInfo)
    }
}

/// Write every base64 image item in `result` to `mediaDir` as
/// `<stem>-<index>.<png|jpg|webp>` (by MIME type) and replace it with an `image_path` sideband item.
///
/// Text and already-externalized items pass through untouched. The directory
/// is created when missing. `index` is the item's position in `content`.
public func externalizeToolResultImages(
    _ result: ToolCallResult,
    mediaDir: String,
    stem: String,
    fileManager: FileManager = .default
) throws -> ToolCallResult {
    let directoryURL = URL(fileURLWithPath: mediaDir, isDirectory: true)
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

    let sanitizedStem = stem
        .map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        .reduce(into: "", { $0.append($1) })
    let effectiveStem = sanitizedStem.isEmpty ? "capture" : sanitizedStem

    var items: [ToolResultContentItem] = []
    items.reserveCapacity(result.content.count)
    var wroteImage = false

    for (index, item) in result.content.enumerated() {
        guard
            item.dictionary["type"] as? String == "image",
            let base64 = item.dictionary["data"] as? String,
            let data = Data(base64Encoded: base64)
        else {
            items.append(item)
            continue
        }

        let mimeType = item.dictionary["mimeType"] as? String ?? "image/png"
        // Screenshots may be PNG, JPEG or WebP: the file extension follows the real format.
        let fileExtension = mimeType == "image/jpeg" ? "jpg" : (mimeType == "image/webp" ? "webp" : "png")
        let fileName = "\(effectiveStem)-\(index).\(fileExtension)"
        let fileURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        try data.write(to: fileURL, options: .atomic)
        items.append(.pngImageFile(path: fileURL.path, mimeType: mimeType))
        wroteImage = true
    }

    guard wroteImage else {
        return result
    }

    return ToolCallResult(
        content: items,
        isError: result.isError,
        errorInfo: result.errorInfo,
        stateID: result.stateID
    )
}
