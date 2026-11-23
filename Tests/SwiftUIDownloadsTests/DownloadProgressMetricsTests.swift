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

    func testZeroTotalIsUnknownWhenBytesHaveArrived() {
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

    func testUnknownNetworkProgressStaysIndeterminateAfterBytesArrive() {
        let progress = downloadTransferProgress(expectedByteCount: -1, receivedByteCount: 1_500_000)
        progress.throughput = 500_000

        XCTAssertNil(DownloadProgressMetrics.determinateFraction(for: progress))
        XCTAssertEqual(
            DownloadProgressMetrics.statusText(for: progress),
            "1.5MB downloaded at 0.5MB/s"
        )
    }

    func testKnownStatusTextIncludesTotal() {
        let progress = downloadTransferProgress(
            expectedByteCount: 4_000_000, receivedByteCount: 1_500_000
        )

        XCTAssertEqual(DownloadProgressMetrics.determinateFraction(for: progress), 0.375)
        XCTAssertEqual(
            DownloadProgressMetrics.statusText(for: progress),
            "1.5MB of 4.0MB"
        )
    }

    func testZeroTotalWithTransferredBytesStaysIndeterminate() {
        let progress = downloadTransferProgress(expectedByteCount: 0, receivedByteCount: 1_500_000)

        XCTAssertNil(DownloadProgressMetrics.determinateFraction(for: progress))
        XCTAssertEqual(DownloadProgressMetrics.statusText(for: progress), "1.5MB downloaded")
    }

    func testActualEmptyTransferKeepsKnownProgressAndStatus() {
        let progress = downloadTransferProgress(expectedByteCount: 0, receivedByteCount: 0)

        XCTAssertNotNil(DownloadProgressMetrics.determinateFraction(for: progress))
        XCTAssertEqual(DownloadProgressMetrics.statusText(for: progress), "0.0MB of 0.0MB")
    }

    func testCompactTransferStaysIndeterminateUntilTheTotalIsKnown() {
        let unknown = downloadTransferProgress(expectedByteCount: -1, receivedByteCount: 1_500_000)
        let known = downloadTransferProgress(expectedByteCount: 4_000_000, receivedByteCount: 1_500_000)

        XCTAssertNil(DownloadProgressMetrics.determinateFraction(for: .uninitiated))
        XCTAssertNil(DownloadProgressMetrics.determinateFraction(for: .waitingForResponse))
        XCTAssertNil(DownloadProgressMetrics.determinateFraction(for: .downloading(progress: unknown)))
        XCTAssertEqual(
            DownloadProgressMetrics.determinateFraction(for: .downloading(progress: known)),
            0.375
        )
    }

    func testCompactTerminalTransferKeepsExistingFractions() {
        let destination = URL(fileURLWithPath: "/downloaded.epub")
        let success = URLResourceDownloadTaskProgress.completed(
            destinationLocation: destination, etag: nil, error: nil
        )
        let failure = URLResourceDownloadTaskProgress.completed(
            destinationLocation: nil, etag: nil, error: URLError(.cancelled)
        )

        XCTAssertEqual(DownloadProgressMetrics.determinateFraction(for: success), 1)
        XCTAssertEqual(DownloadProgressMetrics.determinateFraction(for: failure), 0)
    }

}
