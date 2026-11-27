import XCTest
@testable import SwiftUIDownloads

final class DownloadProgressMetricsTests: XCTestCase {
    func testUnknownAndClampedZeroTotalsRemainIndeterminateAfterBytesArrive() {
        for total in [-1, 0] {
            let progress = Progress(totalUnitCount: total)
            progress.completedUnitCount = 1_500_000

            XCTAssertNil(DownloadProgressMetrics.knownByteCount(
                totalUnitCount: total,
                completedUnitCount: progress.completedUnitCount
            ))
            XCTAssertNil(DownloadProgressMetrics.determinateFraction(for: progress))
            XCTAssertEqual(DownloadProgressMetrics.statusText(for: progress), "1.5MB downloaded")
        }
    }

    func testKnownAndActuallyEmptyTransfersRemainDeterminate() {
        let known = Progress(totalUnitCount: 4_000_000)
        known.completedUnitCount = 1_500_000
        XCTAssertEqual(DownloadProgressMetrics.determinateFraction(for: known), 0.375)
        XCTAssertEqual(DownloadProgressMetrics.statusText(for: known), "1.5MB of 4.0MB")

        let empty = Progress(totalUnitCount: 0)
        XCTAssertNotNil(DownloadProgressMetrics.determinateFraction(for: empty))
        XCTAssertEqual(DownloadProgressMetrics.statusText(for: empty), "0.0MB of 0.0MB")
    }

    func testCompactControlUsesIndeterminateStateUntilTransferSizeIsKnown() {
        let unknown = Progress(totalUnitCount: 0)
        unknown.completedUnitCount = 1
        let known = Progress(totalUnitCount: 10)
        known.completedUnitCount = 4

        XCTAssertNil(DownloadProgressMetrics.determinateFraction(for: .uninitiated))
        XCTAssertNil(DownloadProgressMetrics.determinateFraction(for: .waitingForResponse))
        XCTAssertNil(DownloadProgressMetrics.determinateFraction(for: .downloading(progress: unknown)))
        XCTAssertEqual(DownloadProgressMetrics.determinateFraction(for: .downloading(progress: known)), 0.4)
    }
}
