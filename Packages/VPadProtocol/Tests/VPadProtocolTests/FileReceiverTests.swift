import CryptoKit
import Foundation
import XCTest
@testable import VPadProtocol

final class FileReceiverTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VPadTestUploads-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testPathTraversalNamesRejected() throws {
        let receiver = FileReceiver(uploadsDirectory: tempDirectory)
        let maliciousNames = [
            "../../etc/passwd",
            "../escape.txt",
            "/etc/passwd",
            "\\Windows\\System32\\cmd.exe",
            "C:\\boot.ini",
            "photo\0.jpg",
            "notes\r\n.txt"
        ]

        for name in maliciousNames {
            let header = FileHeaderPayload(fileName: name, fileSize: 100)
            guard let encoded = header.encoded() else {
                // If encoding correctly rejects the invalid name, this is safe.
                continue
            }
            let frame = VPadFrame(type: .fileHeader, body: encoded)
            let outcome = receiver.handle(frame)
            XCTAssertEqual(
                outcome,
                .protocolError(.malformedFrame),
                "Expected rejection for traversal name: \(name)"
            )
        }

        // Verify no directory or files were created
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.path))
    }

    func testOversizeFileRejectedAtHeader() throws {
        let maxAllowed: UInt64 = 1_000
        let receiver = FileReceiver(uploadsDirectory: tempDirectory, maxFileSize: maxAllowed)

        let header = FileHeaderPayload(fileName: "toolarge.bin", fileSize: maxAllowed + 1)
        let encoded = try XCTUnwrap(header.encoded())
        let frame = VPadFrame(type: .fileHeader, body: encoded)
        let outcome = receiver.handle(frame)

        XCTAssertEqual(outcome, .protocolError(.malformedFrame))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.path))
    }

    func testOversizeChunkRejectedAndDeletesFile() throws {
        let receiver = FileReceiver(uploadsDirectory: tempDirectory)

        let header = FileHeaderPayload(fileName: "chunktest.bin", fileSize: 50)
        let headerFrame = VPadFrame(type: .fileHeader, body: try XCTUnwrap(header.encoded()))
        XCTAssertEqual(receiver.handle(headerFrame), .none)

        // Send a chunk larger than the expected 50 bytes
        let oversizedChunk = FileChunkPayload(data: Data(repeating: 0x41, count: 51))
        let chunkFrame = VPadFrame(type: .fileChunk, body: try XCTUnwrap(oversizedChunk.encoded()))
        let outcome = receiver.handle(chunkFrame)

        XCTAssertEqual(outcome, .protocolError(.malformedFrame))

        // Ensure temporary file was cleaned up
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)) ?? []
        XCTAssertTrue(contents.isEmpty, "Oversized chunk should clean up partial file")
    }

    func testHashMismatchRejectsAndDeletesFile() throws {
        let receiver = FileReceiver(uploadsDirectory: tempDirectory)
        let testData = Data([0xDE, 0xAD, 0xBE, 0xEF])

        let header = FileHeaderPayload(fileName: "corrupt.bin", fileSize: UInt64(testData.count))
        XCTAssertEqual(receiver.handle(VPadFrame(type: .fileHeader, body: try XCTUnwrap(header.encoded()))), .none)

        let chunk = FileChunkPayload(data: testData)
        XCTAssertEqual(receiver.handle(VPadFrame(type: .fileChunk, body: try XCTUnwrap(chunk.encoded()))), .none)

        // Send bogus SHA256 trailer
        let bogusSHA = Data(repeating: 0xEE, count: 32)
        let trailer = FileTrailerPayload(sha256: bogusSHA)
        let trailerFrame = VPadFrame(type: .fileTrailer, body: try XCTUnwrap(trailer.encoded()))
        let outcome = receiver.handle(trailerFrame)

        XCTAssertEqual(outcome, .status(.checksumMismatch, fileName: "corrupt.bin"))

        // Ensure file was deleted after checksum mismatch
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)) ?? []
        XCTAssertTrue(contents.isEmpty, "Checksum mismatch should remove the file from disk")
    }

    func testUserConfirmationRejectionCancelsTransfer() throws {
        let receiver = FileReceiver(
            uploadsDirectory: tempDirectory,
            confirmationHandler: { _, _ in false } // User declines
        )

        let header = FileHeaderPayload(fileName: "declined.pdf", fileSize: 1024)
        let frame = VPadFrame(type: .fileHeader, body: try XCTUnwrap(header.encoded()))
        let outcome = receiver.handle(frame)

        XCTAssertEqual(outcome, .status(.cancelled, fileName: "declined.pdf"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory.path))
    }

    func testValidTransferWritesToDedicatedFolderAndVerifiesSHA256() throws {
        let receiver = FileReceiver(
            uploadsDirectory: tempDirectory,
            confirmationHandler: { _, _ in true } // User approves
        )
        let payload = Data((0..<4096).map { UInt8($0 % 256) })
        let expectedDigest = Data(SHA256.hash(data: payload))

        let header = FileHeaderPayload(fileName: "valid.dat", fileSize: UInt64(payload.count))
        XCTAssertEqual(receiver.handle(VPadFrame(type: .fileHeader, body: try XCTUnwrap(header.encoded()))), .none)

        let chunk = FileChunkPayload(data: payload)
        XCTAssertEqual(receiver.handle(VPadFrame(type: .fileChunk, body: try XCTUnwrap(chunk.encoded()))), .none)

        let trailer = FileTrailerPayload(sha256: expectedDigest)
        let trailerFrame = VPadFrame(type: .fileTrailer, body: try XCTUnwrap(trailer.encoded()))
        let outcome = receiver.handle(trailerFrame)

        XCTAssertEqual(outcome, .status(.success, fileName: "valid.dat"))

        // Verify written file
        let savedPath = tempDirectory.appendingPathComponent("valid.dat").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedPath))
        let writtenData = try Data(contentsOf: URL(fileURLWithPath: savedPath))
        XCTAssertEqual(writtenData, payload)
    }

    func testFileAbortCancelsAndCleansUp() throws {
        let receiver = FileReceiver(uploadsDirectory: tempDirectory)
        let testData = Data([1, 2, 3, 4, 5])

        let header = FileHeaderPayload(fileName: "aborted.dat", fileSize: 10)
        XCTAssertEqual(receiver.handle(VPadFrame(type: .fileHeader, body: try XCTUnwrap(header.encoded()))), .none)

        let chunk = FileChunkPayload(data: testData)
        XCTAssertEqual(receiver.handle(VPadFrame(type: .fileChunk, body: try XCTUnwrap(chunk.encoded()))), .none)

        let abortFrame = VPadFrame(type: .fileAbort)
        let outcome = receiver.handle(abortFrame)

        XCTAssertEqual(outcome, .status(.cancelled, fileName: "aborted.dat"))

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)) ?? []
        XCTAssertTrue(contents.isEmpty, "Aborting transfer must remove partial file")
    }
}
