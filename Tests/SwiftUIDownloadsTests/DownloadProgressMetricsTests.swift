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

    func testIndeterminateStatusTextOmitsUnknownTotal() {
        let progress = Progress(totalUnitCount: -1)
        progress.completedUnitCount = 1_500_000

        let text = DownloadProgressMetrics.statusText(for: progress)

        XCTAssertTrue(text.contains("1.5MB downloaded"))
        XCTAssertFalse(text.contains(" of "))
        XCTAssertFalse(text.contains("-"))
    }

    func testKnownStatusTextIncludesTotal() {
        let progress = Progress(totalUnitCount: 4_000_000)
        progress.completedUnitCount = 1_500_000

        XCTAssertTrue(
            DownloadProgressMetrics.statusText(for: progress)
                .contains("1.5MB of 4.0MB")
        )
    }

}
