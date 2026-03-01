import XCTest
@testable import SwiftUIDownloads

final class DownloadRetrySupportTests: XCTestCase {
    func testParseRetryAfterSeconds_numericValue() {
        let parsed = parseRetryAfterSeconds("7")
        XCTAssertEqual(parsed, 7)
    }

    func testParseRetryAfterSeconds_httpDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let parsed = parseRetryAfterSeconds(
            "Tue, 14 Nov 2023 22:13:25 GMT",
            now: now
        )
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed ?? -1, 5, accuracy: 0.001)
    }

    func testRetryAfterSeconds_readsResponseHeader() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/archive")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "11"]
        )!

        XCTAssertEqual(retryAfterSeconds(from: response, now: now), 11)
    }

    func testRetryableDownloadError_httpRules() {
        let retryable = URLResourceDownloadHTTPError(
            statusCode: 503,
            url: URL(string: "https://example.com")!,
            retryAfterSeconds: 3
        )
        let notRetryable = URLResourceDownloadHTTPError(
            statusCode: 404,
            url: URL(string: "https://example.com")!
        )

        XCTAssertTrue(isRetryableDownloadError(retryable))
        XCTAssertFalse(isRetryableDownloadError(notRetryable))
    }

    func testRetryDelayPrefersServerRetryAfterWhenLarger() {
        let policy = DownloadRetryPolicy(
            maxAttempts: 3,
            initialDelaySeconds: 0.5,
            maxDelaySeconds: 4,
            jitterFraction: 0,
            maxServerRetryAfterSeconds: 30
        )
        let error = URLResourceDownloadHTTPError(
            statusCode: 429,
            url: URL(string: "https://example.com")!,
            retryAfterSeconds: 6
        )

        let delay = policy.retryDelaySeconds(forAttempt: 2, error: error)
        XCTAssertEqual(delay, 6, accuracy: 0.001)
    }

    func testRetryDelayClampsServerRetryAfterToPolicyLimit() {
        let policy = DownloadRetryPolicy(
            maxAttempts: 3,
            initialDelaySeconds: 1,
            maxDelaySeconds: 8,
            jitterFraction: 0,
            maxServerRetryAfterSeconds: 3
        )
        let error = URLResourceDownloadHTTPError(
            statusCode: 503,
            url: URL(string: "https://example.com")!,
            retryAfterSeconds: 20
        )

        let delay = policy.retryDelaySeconds(forAttempt: 2, error: error)
        XCTAssertEqual(delay, 3, accuracy: 0.001)
    }
}
