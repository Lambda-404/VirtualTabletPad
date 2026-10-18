import Foundation

// MARK: - Big-endian byte helpers

extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendUInt64BE(_ value: UInt64) {
        append(UInt8(truncatingIfNeeded: value >> 56))
        append(UInt8(truncatingIfNeeded: value >> 48))
        append(UInt8(truncatingIfNeeded: value >> 40))
        append(UInt8(truncatingIfNeeded: value >> 32))
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    func readUInt16BE(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return withUnsafeBytes { buffer in
            UInt16(bigEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        }
    }

    func readUInt32BE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return withUnsafeBytes { buffer in
            UInt32(bigEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    func readUInt64BE(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        return withUnsafeBytes { buffer in
            UInt64(bigEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        }
    }
}

// MARK: - Framing

public struct VPadFrame: Equatable, Sendable {
    public let type: FrameType
    public let body: Data

    public init(type: FrameType, body: Data = Data()) {
        self.type = type
        self.body = body
    }
}

public enum VPadFrameError: Error, Equatable {
    case invalidLength(Int)
    case unknownType(UInt8)
    case malformed
}

public enum VPadFrameCodec {
    public static func wrap(payload: Data) -> Data {
        var output = Data(capacity: 4 + payload.count)
        output.appendUInt32BE(UInt32(payload.count))
        output.append(payload)
        return output
    }

    public static func encode(type: FrameType, body: Data = Data()) -> Data {
        var payload = Data(capacity: 1 + body.count)
        payload.append(type.rawValue)
        payload.append(body)
        return wrap(payload: payload)
    }

    public static func parse(payload: Data) throws -> VPadFrame {
        guard let rawType = payload.first else {
            throw VPadFrameError.malformed
        }
        guard let type = FrameType(rawValue: rawType) else {
            throw VPadFrameError.unknownType(rawType)
        }
        return VPadFrame(type: type, body: Data(payload.dropFirst()))
    }
}

/// Incremental `[4-byte BE length][payload]` decoder. Yields raw payloads so
/// the TCP layer can decide whether to decrypt before calling `parse(payload:)`.
public struct VPadFrameDecoder: Sendable {
    public let maxPayloadLength: Int
    private var buffer = Data()

    public init(maxPayloadLength: Int = VPadConstants.maxFramePayload) {
        self.maxPayloadLength = maxPayloadLength
    }

    public var bufferedByteCount: Int { buffer.count }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var payloads: [Data] = []
        while buffer.count >= 4 {
            guard let rawLength = buffer.readUInt32BE(at: 0) else { break }
            let length = Int(rawLength)
            guard length > 0, length <= maxPayloadLength else {
                throw VPadFrameError.invalidLength(length)
            }
            guard buffer.count >= 4 + length else { break }
            let payload = buffer.subdata(in: 4..<(4 + length))
            // `Data.removeFirst` advances `startIndex`; rebuild the buffer so
            // subsequent absolute subdata ranges stay 0-based.
            buffer = Data(buffer.dropFirst(4 + length))
            payloads.append(payload)
        }
        return payloads
    }
}

// MARK: - File transfer payloads (§5)

public struct FileHeaderPayload: Equatable, Sendable {
    public let fileName: String
    public let fileSize: UInt64

    public init(fileName: String, fileSize: UInt64) {
        self.fileName = fileName
        self.fileSize = fileSize
    }

    public func encoded() -> Data? {
        guard let nameBytes = fileName.data(using: .utf8),
              !nameBytes.isEmpty,
              nameBytes.count <= VPadConstants.maxFileNameBytes,
              nameBytes.count <= 1_024 else {
            return nil
        }
        var data = Data(capacity: 2 + nameBytes.count + 8)
        data.appendUInt16BE(UInt16(nameBytes.count))
        data.append(nameBytes)
        data.appendUInt64BE(fileSize)
        return data
    }

    public static func decode(_ body: Data) -> FileHeaderPayload? {
        guard let nameLength = body.readUInt16BE(at: 0),
              nameLength > 0,
              nameLength <= 1_024,
              body.count == 2 + Int(nameLength) + 8,
              let fileSize = body.readUInt64BE(at: 2 + Int(nameLength)),
              let fileName = String(data: body.subdata(in: 2..<(2 + Int(nameLength))), encoding: .utf8) else {
            return nil
        }
        return FileHeaderPayload(fileName: fileName, fileSize: fileSize)
    }
}

public struct FileChunkPayload: Equatable, Sendable {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }

    public func encoded() -> Data? {
        guard data.count <= VPadConstants.fileChunkSize else { return nil }
        var output = Data(capacity: 4 + data.count)
        output.appendUInt32BE(UInt32(data.count))
        output.append(data)
        return output
    }

    public static func decode(_ body: Data) -> FileChunkPayload? {
        guard let length = body.readUInt32BE(at: 0) else { return nil }
        let chunkLength = Int(length)
        guard chunkLength <= VPadConstants.fileChunkSize,
              body.count == 4 + chunkLength else {
            return nil
        }
        return FileChunkPayload(data: body.subdata(in: 4..<(4 + chunkLength)))
    }
}

public struct FileTrailerPayload: Equatable, Sendable {
    public let sha256: Data

    public init(sha256: Data) {
        self.sha256 = sha256
    }

    public func encoded() -> Data? {
        sha256.count == 32 ? sha256 : nil
    }

    public static func decode(_ body: Data) -> FileTrailerPayload? {
        body.count == 32 ? FileTrailerPayload(sha256: body) : nil
    }
}

public struct FileStatusPayload: Equatable, Sendable {
    public let status: FileStatus

    public init(status: FileStatus) {
        self.status = status
    }

    public func encoded() -> Data {
        Data([status.rawValue])
    }

    public static func decode(_ body: Data) -> FileStatusPayload? {
        guard body.count == 1, let status = FileStatus(rawValue: body[body.startIndex]) else {
            return nil
        }
        return FileStatusPayload(status: status)
    }
}

// MARK: - File name sanitization

public enum VPadFileNameSanitizer {
    /// Strips path components and control characters. Returns nil when the
    /// remaining name is empty, a traversal sentinel, or too long.
    public static func sanitize(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        let normalized = raw.precomposedStringWithCanonicalMapping
        var candidate = (normalized as NSString).lastPathComponent
        let forbidden = CharacterSet(charactersIn: "/\\:\u{0000}").union(.controlCharacters)
        candidate = candidate
            .components(separatedBy: forbidden)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate != ".", candidate != ".." else {
            return nil
        }
        guard candidate.utf8.count <= VPadConstants.maxFileNameBytes else {
            return nil
        }
        return candidate
    }
}
