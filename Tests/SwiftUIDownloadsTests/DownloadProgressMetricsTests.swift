import XCTest
@testable import SwiftUIDownloads

final class DownloadProgressMetricsTests: XCTestCase {
    func testUnknownProgressLengthRemainsUnknown() {
        XCTAssertNil(
            DownloadProgressMetrics.knownByteCount(totalUnitCount: -1)
        )
    }

    func testOtherNegativeProgressLengthsRemainUnknown() {
        XCTAssertNil(
            DownloadProgressMetrics.knownByteCount(totalUnitCount: Int64.min)
        )
        XCTAssertNil(
            DownloadProgressMetrics.knownByteCount(totalUnitCount: -2)
        )
    }

    func testKnownProgressLengthsConvertExactly() {
        XCTAssertEqual(
            DownloadProgressMetrics.knownByteCount(totalUnitCount: 0),
            0
        )
        XCTAssertEqual(
            DownloadProgressMetrics.knownByteCount(totalUnitCount: 1),
            1
        )
        XCTAssertEqual(
            DownloadProgressMetrics.knownByteCount(totalUnitCount: Int64.max),
            UInt64(Int64.max)
        )
    }
}
