import Darwin
import XCTest
@testable import UltraTermComputerUseKit

/// Buffered newline framing contract for the MCP/agent transport. Each test
/// runs over a local socketpair — no server, no proxy, no desktop.
final class TransportFramingContractTests: XCTestCase {
    private func withChannelPair<T>(
        readChunkSize: Int = 64 * 1024,
        maxBufferedBytes: Int = 64 * 1024 * 1024,
        _ body: (LineDelimitedSocketChannel, Int32) throws -> T
    ) throws -> T {
        let (channelFD, peerFD) = try makeContractSocketPair()
        let channel = LineDelimitedSocketChannel(
            fileDescriptor: channelFD,
            readChunkSize: readChunkSize,
            maxBufferedBytes: maxBufferedBytes
        )
        defer { close(peerFD) }
        return try body(channel, peerFD)
    }

    private func writeString(_ string: String, to fd: Int32) {
        string.withCString { pointer in
            _ = write(fd, pointer, strlen(pointer))
        }
    }

    private func readString(upTo count: Int, from fd: Int32) -> String {
        var buffer = [UInt8](repeating: 0, count: count)
        let readCount = buffer.withUnsafeMutableBytes { pointer -> Int in
            guard let baseAddress = pointer.baseAddress else {
                return 0
            }
            return read(fd, baseAddress, count)
        }
        return String(decoding: buffer[0..<max(0, readCount)], as: UTF8.self)
    }

    func testWriteLineAppendsNewline() throws {
        try withChannelPair { channel, peer in
            channel.writeLine("{\"jsonrpc\":\"2.0\"}")
            XCTAssertEqual(readString(upTo: 64, from: peer), "{\"jsonrpc\":\"2.0\"}\n")
        }
    }

    func testWriteJSONLineEmitsParseableJSONLine() throws {
        try withChannelPair { channel, peer in
            channel.writeJSONLine(["id": 1, "result": ["ok": true]])
            let line = readString(upTo: 256, from: peer)

            XCTAssertTrue(line.hasSuffix("\n"))
            let payload = try JSONSerialization.jsonObject(with: Data(line.dropLast().utf8)) as? [String: Any]
            XCTAssertEqual(payload?["id"] as? Int, 1)
        }
    }

    func testReadLineSplitsMultipleLinesFromOneChunk() throws {
        try withChannelPair { channel, peer in
            writeString("one\ntwo\nthree\n", to: peer)

            XCTAssertEqual(channel.readLine(), "one")
            XCTAssertEqual(channel.readLine(), "two")
            XCTAssertEqual(channel.readLine(), "three")
        }
    }

    func testReadLineHandlesBlankLines() throws {
        try withChannelPair { channel, peer in
            writeString("first\n\nsecond\n", to: peer)

            XCTAssertEqual(channel.readLine(), "first")
            XCTAssertEqual(channel.readLine(), "")
            XCTAssertEqual(channel.readLine(), "second")
        }
    }

    func testReadLineAssemblesLinesAcrossTinyChunks() throws {
        try withChannelPair(readChunkSize: 4) { channel, peer in
            let payload = String(repeating: "x", count: 1_000)
            writeString(payload + "\n", to: peer)

            XCTAssertEqual(channel.readLine(), payload)
        }
    }

    func testReadLineDeliversPartialLineAtEOFThenNil() throws {
        try withChannelPair { channel, peer in
            writeString("trailing-without-newline", to: peer)
            shutdown(peer, SHUT_WR)

            XCTAssertEqual(channel.readLine(), "trailing-without-newline")
            XCTAssertNil(channel.readLine())
        }
    }

    func testReadLineReturnsNilImmediatelyAtEOF() throws {
        try withChannelPair { channel, peer in
            shutdown(peer, SHUT_WR)

            XCTAssertNil(channel.readLine())
        }
    }

    func testReadLineDropsOversizedLineWithoutBound() throws {
        try withChannelPair(readChunkSize: 8, maxBufferedBytes: 64) { channel, peer in
            // 1 KB with no newline: the buffer must not grow unbounded.
            writeString(String(repeating: "y", count: 1_024), to: peer)
            shutdown(peer, SHUT_WR)

            XCTAssertNil(channel.readLine(), "a line exceeding maxBufferedBytes must drop the connection")
        }
    }

    func testReadLineReturnsNilForInvalidUTF8() throws {
        try withChannelPair { channel, peer in
            let bytes: [UInt8] = [0xFF, 0xFE, 0x0A]
            _ = bytes.withUnsafeBytes { pointer -> Int in
                guard let baseAddress = pointer.baseAddress else {
                    return 0
                }
                return write(peer, baseAddress, bytes.count)
            }

            XCTAssertNil(channel.readLine())
        }
    }

    func testRoundTripPreservesJSONRPCPayloads() throws {
        try withChannelPair { channel, peer in
            let requests = [
                #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#,
                #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_apps","arguments":{}}}"#,
            ]
            for request in requests {
                writeString(request + "\n", to: peer)
            }

            for request in requests {
                let line = try XCTUnwrap(channel.readLine())
                let parsed = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                let expected = try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any]
                XCTAssertEqual(parsed?["id"] as? Int, expected?["id"] as? Int)
                XCTAssertEqual(parsed?["method"] as? String, expected?["method"] as? String)
            }
        }
    }

    func testChannelClosesOwnedDescriptorOnDeinit() throws {
        let (channelFD, peerFD) = try makeContractSocketPair()
        do {
            _ = LineDelimitedSocketChannel(fileDescriptor: channelFD)
        }
        // The channel is gone; the peer observes EOF.
        XCTAssertEqual(readString(upTo: 8, from: peerFD), "")
        close(peerFD)
    }
}
