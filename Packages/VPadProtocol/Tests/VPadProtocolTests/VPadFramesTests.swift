import XCTest
@testable import VPadProtocol

final class VPadFramesTests: XCTestCase {
    func testFrameRoundTrip() throws {
        let body = Data("payload".utf8)
        let encoded = VPadFrameCodec.encode(type: .ping, body: body)
        var decoder = VPadFrameDecoder()
        let payloads = try decoder.append(encoded)
        XCTAssertEqual(payloads.count, 1)
        let frame = try VPadFrameCodec.parse(payload: payloads[0])
        XCTAssertEqual(frame.type, .ping)
        XCTAssertEqual(frame.body, body)
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testDecoderHandlesPartialAndMultipleFrames() throws {
        let first = VPadFrameCodec.encode(type: .hello, body: Data(repeating: 7, count: 33))
        let second = VPadFrameCodec.encode(type: .ready)
        let combined = first + second

        var decoder = VPadFrameDecoder()
        XCTAssertTrue(try decoder.append(combined.prefix(2)).isEmpty)
        XCTAssertTrue(try decoder.append(combined[2..<10]).isEmpty)
        let payloads = try decoder.append(combined[10...])
        XCTAssertEqual(payloads.count, 2)
        XCTAssertEqual(try VPadFrameCodec.parse(payload: payloads[0]).type, .hello)
        XCTAssertEqual(try VPadFrameCodec.parse(payload: payloads[1]).type, .ready)
    }

    func testDecoderRejectsZeroAndOversizedLengths() {
        var zero = VPadFrameDecoder()
        XCTAssertThrowsError(try zero.append(Data([0, 0, 0, 0]))) { error in
            XCTAssertEqual(error as? VPadFrameError, .invalidLength(0))
        }

        var oversized = VPadFrameDecoder(maxPayloadLength: 16)
        XCTAssertThrowsError(try oversized.append(Data([0, 0, 0, 32]))) { error in
            XCTAssertEqual(error as? VPadFrameError, .invalidLength(32))
        }
    }

    func testParseRejectsUnknownType() {
        XCTAssertThrowsError(try VPadFrameCodec.parse(payload: Data([0xEE]))) { error in
            XCTAssertEqual(error as? VPadFrameError, .unknownType(0xEE))
        }
        XCTAssertThrowsError(try VPadFrameCodec.parse(payload: Data())) { error in
            XCTAssertEqual(error as? VPadFrameError, .malformed)
        }
    }

    func testFileHeaderRoundTrip() throws {
        let header = FileHeaderPayload(fileName: "clip.mov", fileSize: 500_000_000)
        let body = try XCTUnwrap(header.encoded())
        let decoded = try XCTUnwrap(FileHeaderPayload.decode(body))
        XCTAssertEqual(decoded, header)
    }

    func testFileHeaderRejectsInvalidNames() {
        XCTAssertNil(FileHeaderPayload(fileName: "", fileSize: 0).encoded())
        XCTAssertNil(FileHeaderPayload(
            fileName: String(repeating: "a", count: VPadConstants.maxFileNameBytes + 1),
            fileSize: 1
        ).encoded())
        XCTAssertNil(FileHeaderPayload.decode(Data([0, 0])))
    }

    func testFileChunkRoundTripAndLimits() throws {
        let chunk = FileChunkPayload(data: Data(repeating: 0xAB, count: 4096))
        let body = try XCTUnwrap(chunk.encoded())
        XCTAssertEqual(FileChunkPayload.decode(body), chunk)

        let tooLarge = FileChunkPayload(data: Data(repeating: 0, count: VPadConstants.fileChunkSize + 1))
        XCTAssertNil(tooLarge.encoded())
        XCTAssertNil(FileChunkPayload.decode(Data([0, 0, 0, 10, 1, 2])))
    }

    func testTrailerAndStatusRoundTrip() throws {
        let trailer = try XCTUnwrap(FileTrailerPayload.decode(Data(repeating: 0x11, count: 32)))
        XCTAssertEqual(try XCTUnwrap(trailer.encoded()).count, 32)
        XCTAssertNil(FileTrailerPayload.decode(Data(repeating: 0x11, count: 31)))

        let status = FileStatusPayload(status: .checksumMismatch)
        let body = status.encoded()
        XCTAssertEqual(FileStatusPayload.decode(body), status)
        XCTAssertNil(FileStatusPayload.decode(Data([9])))
    }

    func testFileNameSanitization() {
        XCTAssertEqual(VPadFileNameSanitizer.sanitize("notes.txt"), "notes.txt")
        XCTAssertEqual(VPadFileNameSanitizer.sanitize("folder/photo.jpg"), "photo.jpg")
        XCTAssertEqual(VPadFileNameSanitizer.sanitize("sub\\folder\\photo.jpg"), "photo.jpg")
        XCTAssertEqual(VPadFileNameSanitizer.sanitize("a:c.txt"), "a_c.txt")
        XCTAssertNil(VPadFileNameSanitizer.sanitize("../../etc/passwd"))
        XCTAssertNil(VPadFileNameSanitizer.sanitize("/etc/passwd"))
        XCTAssertNil(VPadFileNameSanitizer.sanitize("\\Windows\\System32"))
        XCTAssertNil(VPadFileNameSanitizer.sanitize("C:\\Windows\\System32"))
        XCTAssertNil(VPadFileNameSanitizer.sanitize("../photo.jpg"))
        XCTAssertNil(VPadFileNameSanitizer.sanitize("folder/../photo.jpg"))
        XCTAssertNil(VPadFileNameSanitizer.sanitize("photo\0.jpg"))
        XCTAssertNil(VPadFileNameSanitizer.sanitize("notes\r\n.txt"))
        XCTAssertNil(VPadFileNameSanitizer.sanitize(""))
        XCTAssertNil(VPadFileNameSanitizer.sanitize("."))
        XCTAssertNil(VPadFileNameSanitizer.sanitize(".."))
        XCTAssertNil(VPadFileNameSanitizer.sanitize(String(
            repeating: "x",
            count: VPadConstants.maxFileNameBytes + 1
        )))
    }
}
