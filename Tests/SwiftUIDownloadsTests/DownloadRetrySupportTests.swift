import XCTest
@testable import SwiftUIDownloads

final class DownloadRetrySupportTests: XCTestCase {
    func testPolicyBoundsInvalidConfigurationAndNanosecondConversion() {
        let invalidValues: [Double] = [.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -1, 0]
        for value in invalidValues {
            let policy = DownloadRetryPolicy(
                maxAttempts: .max, initialDelaySeconds: value, maxDelaySeconds: value,
                jitterFraction: value, maxServerRetryAfterSeconds: value
            )
            XCTAssertEqual(policy.maxAttempts, DownloadRetryPolicy.maximumAttempts)
            for attempt in [Int.min, 0, 1, 2, 100, Int.max] {
                for sample in [Double.nan, -.infinity, -1, 0, 0.5, 1, .infinity] {
                    let delay = policy.delayBeforeRetrySeconds(forAttempt: attempt, jitterUnitInterval: sample)
                    XCTAssertTrue(delay.isFinite)
                    XCTAssertGreaterThanOrEqual(delay, 0)
                    XCTAssertLessThanOrEqual(delay, DownloadRetryPolicy.maximumRetryDelaySeconds)
                }
                XCTAssertLessThanOrEqual(
                    policy.retryDelayNanoseconds(forAttempt: attempt, error: URLError(.timedOut)),
                    300_000_000_000
                )
            }
        }
    }

    func testPolicyNormalizesReversedBoundsAndPreservesJitterEndpoints() {
        let policy = DownloadRetryPolicy(
            maxAttempts: 0, initialDelaySeconds: 12, maxDelaySeconds: 2,
            jitterFraction: 1, maxServerRetryAfterSeconds: 20
        )
        XCTAssertEqual(policy.maxAttempts, 1)
        XCTAssertEqual(policy.maxDelaySeconds, 12)
        XCTAssertEqual(policy.delayBeforeRetrySeconds(forAttempt: .max, jitterUnitInterval: 0), 0)
        XCTAssertEqual(policy.delayBeforeRetrySeconds(forAttempt: .max, jitterUnitInterval: 1), 24)
        XCTAssertEqual(policy.delayBeforeRetrySeconds(forAttempt: .max, jitterUnitInterval: .nan), 12)
        let tiny = DownloadRetryPolicy(
            maxAttempts: 3, initialDelaySeconds: .leastNonzeroMagnitude, maxDelaySeconds: 60,
            jitterFraction: 0, maxServerRetryAfterSeconds: 120
        )
        XCTAssertEqual(tiny.delayBeforeRetrySeconds(forAttempt: .max), 60)
    }

    func testEnvironmentPolicyUsesFiniteDefaultsAndPracticalLimits() {
        let policy = DownloadRetryPolicy(environment: [
            "MANABI_DOWNLOAD_MAX_ATTEMPTS": String(Int.max),
            "MANABI_DOWNLOAD_INITIAL_RETRY_DELAY_SECONDS": "nan",
            "MANABI_DOWNLOAD_MAX_RETRY_DELAY_SECONDS": "inf",
            "MANABI_DOWNLOAD_RETRY_JITTER_FRACTION": "-inf",
            "MANABI_DOWNLOAD_MAX_SERVER_RETRY_AFTER_SECONDS": "1e300"
        ])
        XCTAssertEqual(policy.maxAttempts, 10)
        XCTAssertEqual(policy.initialDelaySeconds, 0.7)
        XCTAssertEqual(policy.maxDelaySeconds, 6)
        XCTAssertEqual(policy.jitterFraction, 0.35)
        XCTAssertEqual(policy.maxServerRetryAfterSeconds, 300)
        let error = URLResourceDownloadHTTPError(
            statusCode: 503, url: URL(string: "https://example.invalid")!, retryAfterSeconds: .infinity
        )
        XCTAssertNil(serverSuggestedRetryDelaySeconds(from: error))
    }

    func testParseRetryAfterSeconds_numericValue() {
        let parsed = parseRetryAfterSeconds("7")
        XCTAssertEqual(parsed, 7)
    }

    func testRetryAfterRejectsNonfiniteAndNegativeValues() {
        for header in ["nan", "inf", "-inf", "1e999", "-7"] {
            XCTAssertNil(parseRetryAfterSeconds(header), header)
        }
        for value in [Double.nan, .infinity, -.infinity, -1] {
            let error = URLResourceDownloadHTTPError(statusCode: 503, url: nil, retryAfterSeconds: value)
            XCTAssertNil(error.retryAfterSeconds)
            XCTAssertFalse(error.localizedDescription.contains("Retry-After"))
        }
    }

    func testOversizedRetryAfterCanBeReportedAndClamped() throws {
        let parsed = try XCTUnwrap(parseRetryAfterSeconds("99999999999999999999"))
        let policy = DownloadRetryPolicy(maxAttempts: 3, initialDelaySeconds: 1,
                                         maxDelaySeconds: 8, jitterFraction: 0,
                                         maxServerRetryAfterSeconds: 30)
        for url in [nil, URL(string: "https://example.com/archive")] {
            for value in [parsed, Double(Int.max), Double.greatestFiniteMagnitude] {
                let error = URLResourceDownloadHTTPError(statusCode: 503, url: url, retryAfterSeconds: value)
                XCTAssertTrue(error.localizedDescription.contains("Retry-After"))
                XCTAssertEqual(policy.retryDelaySeconds(forAttempt: 2, error: error), 30)
            }
        }
        let ordinary = URLResourceDownloadHTTPError(statusCode: 429, url: nil, retryAfterSeconds: 7)
        XCTAssertTrue(ordinary.localizedDescription.hasSuffix("Retry-After 7s"))
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
