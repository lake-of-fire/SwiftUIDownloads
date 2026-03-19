import XCTest
import Brotli
@testable import SwiftUIDownloads

final class BrotliFileDecompressorTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-downloads-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL, FileManager.default.fileExists(atPath: temporaryDirectoryURL.path) {
            try FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
    }

    func testDecompressFile_streamedBrotliRoundTrip() throws {
        let sourcePayload = Data(repeating: 0xAB, count: 512 * 1024)
        guard let compressedPayload = (sourcePayload as NSData).brotliCompressed() else {
            XCTFail("Expected test payload to be compressible")
            return
        }

        let compressedURL = temporaryDirectoryURL.appendingPathComponent("payload.br")
        let decompressedURL = temporaryDirectoryURL.appendingPathComponent("payload.bin")
        try compressedPayload.write(to: compressedURL, options: .atomic)

        try BrotliFileDecompressor.decompressFile(at: compressedURL, to: decompressedURL)

        let result = try Data(contentsOf: decompressedURL)
        XCTAssertEqual(result, sourcePayload)
    }

    func testDecompressFile_invalidDataThrows() throws {
        let compressedURL = temporaryDirectoryURL.appendingPathComponent("invalid.br")
        let decompressedURL = temporaryDirectoryURL.appendingPathComponent("output.bin")
        try Data("not brotli".utf8).write(to: compressedURL, options: .atomic)

        XCTAssertThrowsError(
            try BrotliFileDecompressor.decompressFile(at: compressedURL, to: decompressedURL)
        )
    }
}
