import Compression
import XCTest
@testable import SwiftUIDownloads

final class DataCompressionTests: XCTestCase {
    func testRoundTripPreservesData() throws {
        let source = Data("reader-compression-contract".utf8)

        let compressed = try source.compressed(using: COMPRESSION_LZFSE, pageSize: 8)

        XCTAssertEqual(
            try compressed.decompressed(from: COMPRESSION_LZFSE, pageSize: 7),
            source
        )
    }

    func testCompressionRejectsNonpositivePageSizes() {
        let source = Data("content".utf8)

        for pageSize in [0, -1] {
            XCTAssertThrowsError(try source.compressed(pageSize: pageSize)) { error in
                XCTAssertEqual(error as? DataCompressionError, .invalidPageSize(pageSize))
            }
        }
    }

    func testDecompressionRejectsNonpositivePageSizes() {
        let source = Data("content".utf8)

        for pageSize in [0, -1] {
            XCTAssertThrowsError(try source.decompressed(pageSize: pageSize)) { error in
                XCTAssertEqual(error as? DataCompressionError, .invalidPageSize(pageSize))
            }
        }
    }

    func testCompressionRejectsUnsupportedAlgorithm() {
        let unsupported = compression_algorithm(rawValue: UInt32.max)

        XCTAssertThrowsError(try Data().compressed(using: unsupported)) { error in
            XCTAssertEqual(error as? DataCompressionError, .unsupportedAlgorithm(unsupported))
        }
    }

    func testDecompressionRejectsUnsupportedAlgorithm() {
        let unsupported = compression_algorithm(rawValue: UInt32.max)

        XCTAssertThrowsError(try Data().decompressed(from: unsupported)) { error in
            XCTAssertEqual(error as? DataCompressionError, .unsupportedAlgorithm(unsupported))
        }
    }
}
