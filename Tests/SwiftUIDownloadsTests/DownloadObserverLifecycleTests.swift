import XCTest
@testable import SwiftUIDownloads

private struct AsyncWaitTimeoutError: Error {}

private actor ImportInvocationCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private actor SuccessfulAttemptExecutorStub {
    private let payload: Data

    init(payload: Data) {
        self.payload = payload
    }

    func execute(download: Downloadable, session _: URLSession) async throws {
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
}

final class DownloadObserverLifecycleTests: XCTestCase {
    private func awaitCompletionOrFailureWithTimeout(
        _ download: Downloadable,
        timeoutSeconds: Double = 1
    ) async throws -> Bool {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await download.awaitCompletionOrFailure()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw AsyncWaitTimeoutError()
            }
            guard let firstCompleted = try await group.next() else {
                throw AsyncWaitTimeoutError()
            }
            group.cancelAll()
            return firstCompleted
        }
    }

    func testRepeatedDownloadCallsDoNotDuplicateImportHandling() async throws {
        let downloadURL = URL(string: "https://swiftui-downloads-observer.test/\(UUID().uuidString).txt")!
        let payload = Data("observer-lifecycle".utf8)
        let counter = ImportInvocationCounter()
        let attemptExecutor = SuccessfulAttemptExecutorStub(payload: payload)
        let retryPolicy = DownloadRetryPolicy(
            maxAttempts: 1,
            initialDelaySeconds: 0.05,
            maxDelaySeconds: 0.05,
            jitterFraction: 0,
            maxServerRetryAfterSeconds: 1.0
        )

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-downloads-observer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let destinationURL = tempDirectory.appendingPathComponent("importable.txt")
        let metadataSuiteName = "swiftui-downloads-observer-\(UUID().uuidString)"
        guard let metadataDefaults = UserDefaults(suiteName: metadataSuiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite for metadata store.")
            return
        }
        defer {
            metadataDefaults.removePersistentDomain(forName: metadataSuiteName)
        }

        let download = ImportableDownloadable(
            url: downloadURL,
            name: "Observer Lifecycle",
            localDestination: destinationURL,
            deleteAfterImport: false,
            metadataStore: UserDefaultsDownloadableMetadataStore(userDefaults: metadataDefaults),
            isImported: { false },
            importHandler: { localURL, progressHandler in
                progressHandler(0.5, "Importing…")
                _ = try Data(contentsOf: localURL)
                await counter.increment()
                progressHandler(1, "Imported")
            }
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

        for expectedCount in 1...3 {
            await controller.download(download)
            let isComplete = try await download.awaitCompletionOrFailure()
            XCTAssertTrue(isComplete)
            let importCount = await counter.value()
            XCTAssertEqual(importCount, expectedCount)
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        let finalImportCount = await counter.value()
        XCTAssertEqual(finalImportCount, 3)
    }

    func testLocalFileMissingFailureUpdatesFailedSetAndAllowsRetryWithoutHanging() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-downloads-local-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let missingLocalURL = tempDirectory.appendingPathComponent("missing-local.txt")
        let metadataSuiteName = "swiftui-downloads-local-missing-\(UUID().uuidString)"
        guard let metadataDefaults = UserDefaults(suiteName: metadataSuiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite for metadata store.")
            return
        }
        defer {
            metadataDefaults.removePersistentDomain(forName: metadataSuiteName)
        }

        let download = Downloadable(
            url: missingLocalURL,
            name: "Missing Local File",
            localDestination: missingLocalURL,
            metadataStore: UserDefaultsDownloadableMetadataStore(userDefaults: metadataDefaults)
        )
        let controller = DownloadController()

        for _ in 1...2 {
            await controller.download(download)
            let didComplete = try await awaitCompletionOrFailureWithTimeout(download)
            XCTAssertFalse(didComplete)
            let failedContainsDownload = await MainActor.run {
                controller.failedDownloads.contains(where: { $0.url == missingLocalURL })
            }
            XCTAssertTrue(failedContainsDownload)
        }
    }
}
