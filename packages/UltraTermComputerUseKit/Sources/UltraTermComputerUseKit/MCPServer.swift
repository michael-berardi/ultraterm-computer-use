import Foundation

/// Buffered newline-delimited framing over a stream socket file descriptor.
/// Replaces byte-at-a-time `fgetc` reads with chunked `read(2)` calls while
/// remaining fully compatible with newline-delimited JSON-RPC: one JSON payload
/// per line, `\n` terminated, partial trailing line delivered at EOF.
///
/// The channel takes ownership of the file descriptor and closes it on deinit.
/// It is not internally synchronized; use one channel per thread/connection.
public final class LineDelimitedSocketChannel {
    public let fileDescriptor: Int32
    private let readChunkSize: Int
    private let maxBufferedBytes: Int
    private var pending = Data()

    public init(
        fileDescriptor: Int32,
        readChunkSize: Int = 64 * 1024,
        maxBufferedBytes: Int = 64 * 1024 * 1024
    ) {
        self.fileDescriptor = fileDescriptor
        self.readChunkSize = max(readChunkSize, 1)
        self.maxBufferedBytes = max(maxBufferedBytes, 1)
    }

    deinit {
        close(fileDescriptor)
    }

    /// Returns the next complete line without the trailing newline, the final
    /// partial line when the peer closes mid-line, or `nil` once the stream is
    /// exhausted (also on read errors, invalid UTF-8, or when a single line
    /// grows past `maxBufferedBytes` — callers should drop such a connection).
    public func readLine() -> String? {
        while true {
            if let newlineIndex = pending.firstIndex(of: 0x0A) {
                let lineData = pending.subdata(in: pending.startIndex..<newlineIndex)
                pending.removeSubrange(pending.startIndex...newlineIndex)
                return String(data: lineData, encoding: .utf8)
            }

            var chunk = [UInt8](repeating: 0, count: readChunkSize)
            let bytesRead = chunk.withUnsafeMutableBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else {
                    return -1
                }
                return read(fileDescriptor, baseAddress, readChunkSize)
            }

            if bytesRead > 0 {
                pending.append(contentsOf: chunk[0..<bytesRead])
                if pending.count > maxBufferedBytes {
                    // A peer streaming without newlines would grow this buffer
                    // without bound; treat it as a fatal framing error.
                    return nil
                }
                continue
            }

            if bytesRead < 0, errno == EINTR {
                continue
            }

            // EOF (0) or hard read error: flush any buffered partial line.
            guard !pending.isEmpty else {
                return nil
            }
            let lineData = pending
            pending.removeAll()
            return String(data: lineData, encoding: .utf8)
        }
    }

    public func writeLine(_ line: String) {
        writeAll(Array(line.utf8) + [0x0A])
    }

    /// Best-effort JSON line write; encoding failures are dropped, matching the
    /// previous stdio helper semantics.
    public func writeJSONLine(_ object: [String: Any]) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
            let line = String(data: data, encoding: .utf8)
        else {
            return
        }

        writeLine(line)
    }

    private func writeAll(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }

            var offset = 0
            while offset < bytes.count {
                let written = write(fileDescriptor, baseAddress + offset, bytes.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR {
                    continue
                }
                // Broken pipe or hard error: nothing more can be sent.
                break
            }
        }
    }
}

let computerUseServerInstructions = """
Computer Use tools let you interact with macOS apps by performing UI actions.

Some apps might have a separate dedicated plugin or skill. You may want to use that plugin or skill instead of Computer Use when it seems like a good fit for the task. While the separate plugin or skill may not expose every feature in the app, if the plugin can perform the task with its available features, prefer it. If the needed capability is not exposed there, use Computer Use may be appropriate for the missing interaction.

Begin by calling `get_app_state` every turn you want to use Computer Use to get the latest state before acting. Some hosts stop the session after each assistant turn, so this step is required before interacting with apps in a new assistant turn.

Every state and action result carries a `state_id`. Pass it to the next action: if the app's state was captured again in between, the action is refused with `stale_state` before anything is sent, and you refresh and retry.

The available tools are list_apps, get_app_state, click, perform_secondary_action, scroll, drag, type_text, press_key, set_value, select_text, and query. If any of these are not available in your environment, use tool_search to surface one before calling any Computer Use action tools.

Computer Use works in the background: it does not activate apps, raise or unminimize windows, or move the real pointer, so the user keeps working while you use an app. An app that is hidden or minimized is reported as unavailable instead of being brought forward; tell the user, or ask them to set ULTRATERM_COMPUTER_USE_ALLOW_FOREGROUND=1 if the task needs it. Avoid anything else that would disrupt the user's session, such as overwriting their clipboard, unless they asked for it.

After each action, use the action result or fetch the latest state to verify the UI changed as expected.
Prefer element-targeted interactions over coordinate clicks when an index for the targeted element is available. Note that element indices are the sequential integers from the app state's accessibility tree.
Avoid falling back to AppleScript during a computer use session. Prefer Computer Use tools as much as possible to complete tasks.
Ask the user before taking destructive or externally visible actions such as sending, deleting, or purchasing. If helpful, you can ask follow-up questions before taking action to make sure you’re understanding the user’s request correctly.
"""

public final class StdioMCPServer {
    private let service: ComputerUseService
    private let dispatcher: ComputerUseToolDispatcher
    private let backgroundStateReset: () -> Void

    public init(
        service: ComputerUseService = ComputerUseService(),
        backgroundStateReset: @escaping () -> Void = resetUltraTermComputerUseBackgroundWindowState
    ) {
        self.service = service
        self.dispatcher = ComputerUseToolDispatcher(service: service)
        self.backgroundStateReset = backgroundStateReset
    }

    public func run() throws {
        defer { endSession() }
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            // This thread's autorelease pool never drains on its own: each response's encoded
            // bytes (a screenshot's base64 among them) stayed alive for the whole session.
            autoreleasepool {
                if let response = handle(line: line) {
                    FileHandle.standardOutput.write((response + "\n").data(using: .utf8)!)
                }
            }
        }
    }

    public func handle(line: String) -> String? {
        do {
            guard let payload = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                return try encodeJSONRPCError(id: nil, code: -32700, message: "Invalid JSON-RPC payload")
            }

            let method = payload["method"] as? String
            let id = payload["id"]
            let params = payload["params"] as? [String: Any] ?? [:]

            switch method {
            case "initialize":
                return try encodeJSONRPCResult(
                    id: id,
                    result: [
                        "protocolVersion": "2025-03-26",
                        "serverInfo": [
                            "name": "ultraterm-computer-use",
                            "version": ultraTermComputerUseVersion,
                        ],
                        "capabilities": [
                            "tools": [
                                "listChanged": false,
                            ],
                        ],
                        "instructions": computerUseServerInstructions,
                    ]
                )
            case "notifications/initialized":
                return nil
            case "notifications/turn-ended":
                endSession()
                return nil
            case "ping":
                return try encodeJSONRPCResult(id: id, result: [:])
            case "tools/list":
                return try encodeJSONRPCResult(
                    id: id,
                    result: [
                        "tools": ToolDefinitions.all.map(\.asDictionary),
                    ]
                )
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                let result = dispatcher.callToolAsResult(name: name, arguments: arguments)
                return try encodeJSONRPCResult(
                    id: id,
                    result: result.asDictionary
                )
            default:
                if method == nil {
                    return nil
                }

                return try encodeJSONRPCError(id: id, code: -32601, message: "Method not found: \(method ?? "")")
            }
        } catch let error as ComputerUseError {
            let payload = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            let id = payload?["id"]
            let result = ToolCallResult.text(error.errorDescription ?? String(describing: error), isError: error.toolResultIsError)
            return try? encodeJSONRPCResult(id: id, result: result.asDictionary)
        } catch {
            if (try? JSONSerialization.jsonObject(with: Data(line.utf8))) == nil {
                return try? encodeJSONRPCError(id: nil, code: -32700, message: "Invalid JSON-RPC payload")
            }
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            let payload = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            let id = payload?["id"]
            return try? encodeJSONRPCResult(
                id: id,
                result: [
                    "content": [
                        [
                            "type": "text",
                            "text": message,
                        ],
                    ],
                    "isError": true,
                ]
            )
        }
    }

    /// Release state that is scoped to one MCP client session. App-hosted MCP
    /// connections call this explicitly because they use `handle(line:)`
    /// instead of the stdio `run()` loop.
    public func endSession() {
        service.clearQueryIndexes()
        VisualCursorSupport.performOnMain {
            SoftwareCursorOverlay.reset()
        }
        backgroundStateReset()
    }

    private func encodeJSONRPCResult(id: Any?, result: [String: Any]) throws -> String {
        try encode([
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "result": result,
        ])
    }

    private func encodeJSONRPCError(id: Any?, code: Int, message: String) throws -> String {
        try encode([
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": [
                "code": code,
                "message": message,
            ],
        ])
    }

    private func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        guard let text = String(data: data, encoding: .utf8) else {
            throw ComputerUseError.message("Failed to encode JSON-RPC response.")
        }

        return text
    }
}
