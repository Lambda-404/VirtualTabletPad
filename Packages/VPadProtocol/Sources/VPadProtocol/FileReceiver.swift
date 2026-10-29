import CryptoKit
import Foundation
import os

public enum FileReceiverOutcome: Equatable, Sendable {
    case none
    case status(FileStatus, fileName: String?)
    case protocolError(ProtocolErrorCode)
}

/// Receives one file at a time from the TCP control connection and streams it
/// to disk in a dedicated directory, verifying SHA-256 and enforcing size & name sanitization.
public final class FileReceiver: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.vpad.FileReceiver", category: "files")

    private struct Transfer {
        let url: URL
        let handle: FileHandle
        let expectedSize: UInt64
        let displayName: String
        var bytesWritten: UInt64
        var hasher: SHA256
    }

    public let uploadsDirectory: URL
    public let maxFileSize: UInt64
    public var confirmationHandler: (@Sendable (_ fileName: String, _ fileSize: UInt64) -> Bool)?
    private var transfer: Transfer?

    public init(
        uploadsDirectory: URL = FileReceiver.defaultUploadsDirectory(),
        maxFileSize: UInt64 = VPadConstants.maxFileSize,
        confirmationHandler: (@Sendable (String, UInt64) -> Bool)? = nil
    ) {
        self.uploadsDirectory = uploadsDirectory.standardizedFileURL
        self.maxFileSize = maxFileSize
        self.confirmationHandler = confirmationHandler
    }

    public static func defaultUploadsDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["VPAD_UPLOADS_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #if os(macOS)
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads", isDirectory: true)
        return downloads.appendingPathComponent(VPadConstants.uploadsFolderName, isDirectory: true)
        #else
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return docs.appendingPathComponent(VPadConstants.uploadsFolderName, isDirectory: true)
        #endif
    }

    public func handle(_ frame: VPadFrame) -> FileReceiverOutcome {
        switch frame.type {
        case .fileHeader:
            return handleHeader(frame.body)
        case .fileChunk:
            return handleChunk(frame.body)
        case .fileTrailer:
            return handleTrailer(frame.body)
        case .fileAbort:
            return handleAbort()
        default:
            return .none
        }
    }

    /// Call on disconnect, session replacement or app shutdown.
    public func abort() {
        finishTransfer(deleteFile: true)
    }

    // MARK: - Frame handling

    private func handleHeader(_ body: Data) -> FileReceiverOutcome {
        guard transfer == nil else {
            Self.log.error("received file header while a transfer is active")
            return .protocolError(.malformedFrame)
        }
        guard let header = FileHeaderPayload.decode(body),
              header.fileSize <= maxFileSize,
              header.fileSize > 0,
              let sanitized = VPadFileNameSanitizer.sanitize(header.fileName) else {
            Self.log.error("invalid file header: size exceeded or invalid name")
            return .protocolError(.malformedFrame)
        }

        if let handler = confirmationHandler {
            guard handler(sanitized, header.fileSize) else {
                Self.log.info("transfer rejected by user confirmation for \(sanitized, privacy: .private)")
                return .status(.cancelled, fileName: sanitized)
            }
        }

        do {
            try FileManager.default.createDirectory(
                at: uploadsDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            Self.log.error("cannot create uploads directory: \(error.localizedDescription, privacy: .public)")
            return .status(.diskError, fileName: sanitized)
        }

        let destination = uniqueDestination(for: sanitized)
        let directoryPrefix = uploadsDirectory.path.hasSuffix("/")
            ? uploadsDirectory.path
            : uploadsDirectory.path + "/"
        guard destination.standardizedFileURL.path.hasPrefix(directoryPrefix) else {
            Self.log.error("file destination escaped uploads directory")
            return .protocolError(.malformedFrame)
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            Self.log.error("cannot create upload file")
            return .status(.diskError, fileName: sanitized)
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            Self.log.error("cannot open upload for writing: \(error.localizedDescription, privacy: .public)")
            return .status(.diskError, fileName: sanitized)
        }

        transfer = Transfer(
            url: destination,
            handle: handle,
            expectedSize: header.fileSize,
            displayName: sanitized,
            bytesWritten: 0,
            hasher: SHA256()
        )
        Self.log.info(
            "receiving \(sanitized, privacy: .private) (\(header.fileSize, privacy: .public) bytes)"
        )
        return .none
    }

    private func handleChunk(_ body: Data) -> FileReceiverOutcome {
        guard var current = transfer else {
            Self.log.error("received file chunk without a header")
            return .protocolError(.malformedFrame)
        }
        guard let chunk = FileChunkPayload.decode(body),
              current.bytesWritten <= current.expectedSize,
              UInt64(chunk.data.count) <= current.expectedSize - current.bytesWritten else {
            Self.log.error("invalid or oversized file chunk")
            finishTransfer(deleteFile: true)
            return .protocolError(.malformedFrame)
        }

        do {
            try current.handle.write(contentsOf: chunk.data)
        } catch {
            Self.log.error("file write failed: \(error.localizedDescription, privacy: .public)")
            finishTransfer(deleteFile: true)
            return .status(.diskError, fileName: current.displayName)
        }

        current.bytesWritten += UInt64(chunk.data.count)
        current.hasher.update(data: chunk.data)
        transfer = current
        return .none
    }

    private func handleTrailer(_ body: Data) -> FileReceiverOutcome {
        guard let current = transfer else {
            Self.log.error("received file trailer without a header")
            return .protocolError(.malformedFrame)
        }
        guard let trailer = FileTrailerPayload.decode(body),
              current.bytesWritten == current.expectedSize else {
            Self.log.error("file trailer is malformed or file is incomplete")
            finishTransfer(deleteFile: true)
            return .protocolError(.malformedFrame)
        }

        let digest = Data(current.hasher.finalize())
        try? current.handle.close()
        transfer = nil

        guard digest == trailer.sha256 else {
            Self.log.error("checksum mismatch for \(current.displayName, privacy: .private)")
            try? FileManager.default.removeItem(at: current.url)
            return .status(.checksumMismatch, fileName: current.displayName)
        }

        Self.log.info(
            "saved \(current.displayName, privacy: .private) (\(current.bytesWritten, privacy: .public) bytes)"
        )
        return .status(.success, fileName: current.displayName)
    }

    private func handleAbort() -> FileReceiverOutcome {
        guard let current = transfer else { return .none }
        finishTransfer(deleteFile: true)
        Self.log.info("file transfer cancelled for \(current.displayName, privacy: .private)")
        return .status(.cancelled, fileName: current.displayName)
    }

    // MARK: - Helpers

    private func uniqueDestination(for sanitized: String) -> URL {
        var candidate = uploadsDirectory.appendingPathComponent(sanitized, isDirectory: false)
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            return candidate
        }
        for _ in 0..<8 {
            candidate = uploadsDirectory.appendingPathComponent(
                UUID().uuidString + "-" + sanitized,
                isDirectory: false
            )
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return uploadsDirectory.appendingPathComponent(
            "\(Int(Date().timeIntervalSince1970))-\(sanitized)",
            isDirectory: false
        )
    }

    private func finishTransfer(deleteFile: Bool) {
        guard let current = transfer else { return }
        transfer = nil
        try? current.handle.close()
        if deleteFile {
            try? FileManager.default.removeItem(at: current.url)
        }
    }
}
