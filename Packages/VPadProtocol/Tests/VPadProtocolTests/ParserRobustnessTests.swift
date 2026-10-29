import Foundation
import XCTest
@testable import VPadProtocol

/// Deterministic, reproducible LCG pseudo-random number generator for fuzz tests.
private struct SeededPRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64 = 0x12345678_9ABCDEF0) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        // 64-bit LCG constants (Knuth)
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    mutating func randomBytes(count: Int) -> Data {
        var data = Data(count: count)
        for i in 0..<count {
            data[i] = UInt8(next() & 0xFF)
        }
        return data
    }
}

final class ParserRobustnessTests: XCTestCase {
    // MARK: - Packet decoder tests

    func testPacketFromDataWrongLengths() {
        let invalidLengths = [0, 1, 10, 27, 29, 32, 56, 100]
        for len in invalidLengths {
            let data = Data(repeating: 0x42, count: len)
            XCTAssertNil(VPadPacket.fromData(data), "Expected nil for length \(len)")
        }
    }

    func testPacketFromDataRandomBytesNeverCrashes() {
        var prng = SeededPRNG(seed: 0xCAFE_BABE_0000_0001)
        for _ in 0..<1_000 {
            let bytes = prng.randomBytes(count: 28)
            let packet = VPadPacket.fromData(bytes)
            XCTAssertNotNil(packet)
            if let packet {
                let serialized = packet.toData()
                XCTAssertEqual(serialized.count, 28)
            }
        }
    }

    // MARK: - TCP Frame & Decoder tests

    func testFrameCodecParseMalformed() {
        // Empty payload
        XCTAssertThrowsError(try VPadFrameCodec.parse(payload: Data())) { error in
            XCTAssertEqual(error as? VPadFrameError, .malformed)
        }

        // Unknown frame type IDs
        let unknownTypes: [UInt8] = [0x00, 0x0A, 0x15, 0x2F, 0x35, 0xFE, 0xFF]
        for type in unknownTypes {
            let payload = Data([type, 1, 2, 3])
            XCTAssertThrowsError(try VPadFrameCodec.parse(payload: payload)) { error in
                XCTAssertEqual(error as? VPadFrameError, .unknownType(type))
            }
        }
    }

    func testFrameDecoderLengthBoundsAndTruncation() throws {
        var decoder = VPadFrameDecoder(maxPayloadLength: 1024)

        // Length 0 is forbidden
        XCTAssertThrowsError(try decoder.append(Data([0, 0, 0, 0]))) { error in
            XCTAssertEqual(error as? VPadFrameError, .invalidLength(0))
        }
        decoder.reset()

        // Length > maxPayloadLength is forbidden
        var bigLength = Data()
        bigLength.appendUInt32BE(1025)
        XCTAssertThrowsError(try decoder.append(bigLength)) { error in
            XCTAssertEqual(error as? VPadFrameError, .invalidLength(1025))
        }
        decoder.reset()

        // Truncated frames: length says 10 bytes, but only 9 bytes follow
        decoder.reset()
        var truncated = Data()
        truncated.appendUInt32BE(10)
        truncated.append(Data(repeating: 0xAA, count: 9))
        let payloads = try decoder.append(truncated)
        XCTAssertTrue(payloads.isEmpty)
        XCTAssertEqual(decoder.bufferedByteCount, 13)

        // Complete the frame
        let completed = try decoder.append(Data([0xBB]))
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed[0].count, 10)
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    // MARK: - Handshake payload tests

    func testClientHelloPayloadDecoderRobustness() {
        // Truncated lengths throw invalidLength
        for len in 0..<ClientHelloPayload.expectedLength {
            let truncated = Data(repeating: 0x01, count: len)
            XCTAssertThrowsError(try ClientHelloPayload.decode(truncated)) { error in
                XCTAssertEqual(error as? HandshakeError, .invalidLength)
            }
        }

        // Random data with wrong version throws invalidVersion
        var prng = SeededPRNG(seed: 0x1122_3344_5566_7788)
        for _ in 0..<100 {
            var data = prng.randomBytes(count: 140)
            data[0] = 99 // Wrong version
            XCTAssertThrowsError(try ClientHelloPayload.decode(data)) { error in
                XCTAssertEqual(error as? HandshakeError, .invalidVersion)
            }
        }

        // Valid version with random payload decodes without throwing
        for _ in 0..<100 {
            let count = Int.random(in: 129...200)
            var data = prng.randomBytes(count: count)
            data[0] = VPadConstants.protocolVersionV2
            XCTAssertNoThrow(try ClientHelloPayload.decode(data))
        }
    }

    func testServerHelloAckPayloadDecoderRobustness() {
        // Truncated lengths throw invalidLength
        for len in 0..<ServerHelloAckPayload.expectedLength {
            let truncated = Data(repeating: 0x02, count: len)
            XCTAssertThrowsError(try ServerHelloAckPayload.decode(truncated)) { error in
                XCTAssertEqual(error as? HandshakeError, .invalidLength)
            }
        }

        // Random data with wrong version throws invalidVersion
        var prng = SeededPRNG(seed: 0x8877_6655_4433_2211)
        for _ in 0..<100 {
            var data = prng.randomBytes(count: ServerHelloAckPayload.expectedLength)
            data[0] = 77 // Wrong version
            XCTAssertThrowsError(try ServerHelloAckPayload.decode(data)) { error in
                XCTAssertEqual(error as? HandshakeError, .invalidVersion)
            }
        }

        // Valid version with random payload decodes without throwing
        for _ in 0..<100 {
            var data = prng.randomBytes(count: ServerHelloAckPayload.expectedLength)
            data[0] = VPadConstants.protocolVersionV2
            XCTAssertNoThrow(try ServerHelloAckPayload.decode(data))
        }
    }

    // MARK: - File payloads robustness

    func testFilePayloadsDecoderRobustness() {
        // FileHeaderPayload: wrong length, invalid name length
        XCTAssertNil(FileHeaderPayload.decode(Data()))
        XCTAssertNil(FileHeaderPayload.decode(Data([0, 5, 1, 2, 3]))) // incomplete
        XCTAssertNil(FileHeaderPayload.decode(Data(repeating: 0, count: 10))) // nameLength = 0

        // FileChunkPayload: length mismatch or oversized
        XCTAssertNil(FileChunkPayload.decode(Data()))
        XCTAssertNil(FileChunkPayload.decode(Data([0, 0, 0, 10, 1, 2]))) // claims 10B, only 2B provided

        // FileTrailerPayload: must be exactly 32 bytes
        XCTAssertNil(FileTrailerPayload.decode(Data(repeating: 0, count: 31)))
        XCTAssertNil(FileTrailerPayload.decode(Data(repeating: 0, count: 33)))
        XCTAssertNotNil(FileTrailerPayload.decode(Data(repeating: 0, count: 32)))

        // FileStatusPayload: must be exactly 1 byte with valid raw value
        XCTAssertNil(FileStatusPayload.decode(Data()))
        XCTAssertNil(FileStatusPayload.decode(Data([0, 1])))
        XCTAssertNil(FileStatusPayload.decode(Data([0x7F])))
    }

    // MARK: - Comprehensive Seeded Fuzzing Loop

    func testSeededFuzzingLoopNeverCrashes() {
        var prng = SeededPRNG(seed: 0x5EED_F00D_BAAD_F00D)
        var frameDecoder = VPadFrameDecoder(maxPayloadLength: 1024)

        for iteration in 0..<2_000 {
            let length = Int(prng.next() % 512)
            let randomData = prng.randomBytes(count: length)

            // 1. Packet parser
            _ = VPadPacket.fromData(randomData)

            // 2. Frame parser
            _ = try? VPadFrameCodec.parse(payload: randomData)

            // 3. Streaming Frame Decoder
            do {
                _ = try frameDecoder.append(randomData)
            } catch {
                frameDecoder.reset()
            }

            // 4. Handshake decoders
            _ = try? ClientHelloPayload.decode(randomData)
            _ = try? ServerHelloAckPayload.decode(randomData)

            // 5. File payload decoders
            _ = FileHeaderPayload.decode(randomData)
            _ = FileChunkPayload.decode(randomData)
            _ = FileTrailerPayload.decode(randomData)
            _ = FileStatusPayload.decode(randomData)

            // 6. Sanitizer with pseudo-random strings
            if let string = String(data: randomData, encoding: .utf8) {
                _ = VPadFileNameSanitizer.sanitize(string)
                _ = PairingPayloadV2.decode(from: string)
            }

            if iteration % 500 == 0 {
                frameDecoder.reset()
            }
        }
    }
}
