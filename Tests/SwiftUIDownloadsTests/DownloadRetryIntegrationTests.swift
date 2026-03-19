import XCTest
@testable import SwiftUIDownloads

private actor RetryAttemptExecutorStub {
    private var attemptDates: [Date] = []
    private var remainingFailures: Int
    private let payload: Data
    private let retryAfterSeconds: Double

    init(failuresBeforeSuccess: Int, payload: Data, retryAfterSeconds: Double) {
        self.remainingFailures = failuresBeforeSuccess
        self.payload = payload
        self.retryAfterSeconds = retryAfterSeconds
    }

    func execute(download: Downloadable, session _: URLSession) async throws {
        attemptDates.append(Date())

        if remainingFailures > 0 {
            remainingFailures -= 1
            throw URLResourceDownloadHTTPError(
                statusCode: 503,
                url: download.url,
                retryAfterSeconds: retryAfterSeconds
            )
        }

        try FileManager.default.createDirectory(
            at: download.localDestination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: download.localDestination, options: .atomic)
        await MainActor.run {
            download.downloadProgress = .completed(
                destinationLocation: download.localDestination,
                etag: nil,
                error: nil
            )
            download.isActive = false
            download.isFailed = false
            download.isFinishedDownloading = true
        }
    }

    func recordedAttemptDates() -> [Date] {
        attemptDates
    }
}

final class DownloadRetryIntegrationTests: XCTestCase {
    func testDownloadRetriesAfterRetryAfterThenSucceeds() async throws {
        let url = URL(string: "https://swiftui-downloads-retry.test/\(UUID().uuidString).txt")!
        let payload = Data("retried-successfully".utf8)
        let attemptExecutor = RetryAttemptExecutorStub(
            failuresBeforeSuccess: 1,
            payload: payload,
            retryAfterSeconds: 0.25
        )
        let retryPolicy = DownloadRetryPolicy(
            maxAttempts: 2,
            initialDelaySeconds: 0.05,
            maxDelaySeconds: 1.0,
            jitterFraction: 0,
            maxServerRetryAfterSeconds: 1.0
        )

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-downloads-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let destinationURL = tempDirectory.appendingPathComponent("downloaded.txt")
        let metadataSuiteName = "swiftui-downloads-retry-\(UUID().uuidString)"
        guard let metadataDefaults = UserDefaults(suiteName: metadataSuiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite for metadata store.")
            return
        }
        defer {
            metadataDefaults.removePersistentDomain(forName: metadataSuiteName)
        }
        let download = Downloadable(
            url: url,
            name: "Retry Test",
            localDestination: destinationURL,
            metadataStore: UserDefaultsDownloadableMetadataStore(userDefaults: metadataDefaults)
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(
            session: session,
            attemptExecutor: { download, session in
                try await attemptExecutor.execute(download: download, session: session)
            },
            retryPolicyProvider: { retryPolicy }
        )

        let startedAt = Date()
        await controller.download(download)
        let isComplete = try await download.awaitCompletionOrFailure()
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertTrue(isComplete)
        XCTAssertEqual(try Data(contentsOf: destinationURL), payload)

        let requestDates = await attemptExecutor.recordedAttemptDates()
        XCTAssertEqual(requestDates.count, 2)
        if requestDates.count == 2 {
            let spacing = requestDates[1].timeIntervalSince(requestDates[0])
            XCTAssertGreaterThanOrEqual(spacing, 0.20)
        }
        XCTAssertGreaterThanOrEqual(elapsed, 0.20)
    }

    func testDownloadRetryExhaustionMarksFailure() async throws {
        let url = URL(string: "https://swiftui-downloads-retry.test/\(UUID().uuidString).txt")!
        let payload = Data("will-not-succeed".utf8)
        let attemptExecutor = RetryAttemptExecutorStub(
            failuresBeforeSuccess: 5,
            payload: payload,
            retryAfterSeconds: 0.05
        )
        let retryPolicy = DownloadRetryPolicy(
            maxAttempts: 2,
            initialDelaySeconds: 0.01,
            maxDelaySeconds: 0.5,
            jitterFraction: 0,
            maxServerRetryAfterSeconds: 1.0
        )

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-downloads-retry-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let destinationURL = tempDirectory.appendingPathComponent("downloaded.txt")
        let metadataSuiteName = "swiftui-downloads-retry-failure-\(UUID().uuidString)"
        guard let metadataDefaults = UserDefaults(suiteName: metadataSuiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite for metadata store.")
            return
        }
        defer {
            metadataDefaults.removePersistentDomain(forName: metadataSuiteName)
        }
        let download = Downloadable(
            url: url,
            name: "Retry Exhaustion Test",
            localDestination: destinationURL,
            metadataStore: UserDefaultsDownloadableMetadataStore(userDefaults: metadataDefaults)
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(
            session: session,
            attemptExecutor: { download, session in
                try await attemptExecutor.execute(download: download, session: session)
            },
            retryPolicyProvider: { retryPolicy }
        )

        await controller.download(download)
        let isComplete = try await download.awaitCompletionOrFailure()
        XCTAssertFalse(isComplete)
        let isFailed = await MainActor.run { download.isFailed }
        XCTAssertTrue(isFailed)

        let requestDates = await attemptExecutor.recordedAttemptDates()
        XCTAssertEqual(requestDates.count, 2)

        let failedContainsDownload = await MainActor.run {
            controller.failedDownloads.contains(where: { $0.url == url })
        }
        XCTAssertTrue(failedContainsDownload)
    }
}
