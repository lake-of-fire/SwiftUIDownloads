import XCTest
@testable import SwiftUIDownloads

final class DownloadProgressMetricsTests: XCTestCase {
    func testUnknownNegativeProgressLengthRemainsUnknown() {
        XCTAssertNil(
            DownloadProgressMetrics.knownByteCount(
                totalUnitCount: -1,
                completedUnitCount: 0
            )
        )
        XCTAssertNil(
            DownloadProgressMetrics.knownByteCount(
                totalUnitCount: Int64.min,
                completedUnitCount: 123
            )
        )
    }

    func testClampedUnknownLengthRemainsUnknownAfterBytesArrive() {
        XCTAssertNil(
            DownloadProgressMetrics.knownByteCount(
                totalUnitCount: 0,
                completedUnitCount: 1
            )
        )
        XCTAssertNil(
            DownloadProgressMetrics.knownByteCount(
                totalUnitCount: 0,
                completedUnitCount: 1024
            )
        )
    }

    func testActualEmptyKnownLengthCanRemainZero() {
        XCTAssertEqual(
            DownloadProgressMetrics.knownByteCount(
                totalUnitCount: 0,
                completedUnitCount: 0
            ),
            0
        )
    }

    func testKnownProgressLengthsConvertExactly() {
        XCTAssertEqual(
            DownloadProgressMetrics.knownByteCount(
                totalUnitCount: 1,
                completedUnitCount: 0
            ),
            1
        )
        XCTAssertEqual(
            DownloadProgressMetrics.knownByteCount(
                totalUnitCount: 10,
                completedUnitCount: 4
            ),
            10
        )
        XCTAssertEqual(
            DownloadProgressMetrics.knownByteCount(
                totalUnitCount: Int64.max,
                completedUnitCount: Int64.max
            ),
            UInt64(Int64.max)
        )
    }
}
