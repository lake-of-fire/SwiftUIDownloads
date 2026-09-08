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

    func execute(
        download: Downloadable,
        session _: URLSession
    ) async throws -> DownloadTransferResult {
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
        return DownloadTransferResult(
            destinationLocation: download.localDestination,
            etag: nil,
            lastModified: nil
        )
    }

    func recordedAttemptDates() -> [Date] {
        attemptDates
    }
}

private actor DownloadAttemptReleaseGate {
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { self.continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

final class DownloadRetryIntegrationTests: XCTestCase {
    func testReplacementWaitsForStandaloneImportAndInstallsItsOwnCandidate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "download-processing-replacement-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("payload.bin")
        let oldPayload = Data("old-import".utf8)
        let newPayload = Data("new-import".utf8)
        try oldPayload.write(to: destination)
        let gate = DownloadAttemptReleaseGate()
        let oldImportStarted = expectation(description: "standalone import started")
        let replacementRequested = expectation(description: "replacement requested while importing")
        let newImportFinished = expectation(description: "replacement candidate imported")
        let download = ImportableDownloadable(
            url: URL(string: "https://download-processing.test/\(UUID().uuidString)")!,
            name: "Replacement",
            localDestination: destination,
            deleteAfterImport: false,
            isImported: { false },
            importHandler: { candidate, _ in
                let payload = try Data(contentsOf: candidate)
                if payload == oldPayload {
                    oldImportStarted.fulfill()
                    await gate.wait()
                } else {
                    XCTAssertEqual(payload, newPayload)
                    newImportFinished.fulfill()
                }
            }
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(session: session, attemptExecutor: { download, _ in
            let candidate = download.uncompressedTransferStagingURL(operationID: UUID())
            try newPayload.write(to: candidate)
            return DownloadTransferResult(destinationLocation: candidate, etag: "new", lastModified: nil)
        })
        let oldOperation = Task { await controller.finishDownload(download) }
        await fulfillment(of: [oldImportStarted], timeout: 2)
        let replacement = Task { @DownloadActor in
            replacementRequested.fulfill()
            await controller.download(download)
        }
        await fulfillment(of: [replacementRequested], timeout: 2)
        await gate.release()
        await oldOperation.value
        await replacement.value
        await fulfillment(of: [newImportFinished], timeout: 2)
        XCTAssertEqual(try Data(contentsOf: destination), newPayload)
        let etag = await MainActor.run { download.lastDownloadedETag }
        XCTAssertEqual(etag, "new")
    }

    func testDeletingOneExtensionPreservesAnotherDestinationsStagingFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "download-staging-ownership-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let selected = Downloadable(
            url: URL(string: "https://download-staging.test/selected")!, name: "Selected",
            localDestination: directory.appendingPathComponent("payload.bin")
        )
        let retained = Downloadable(
            url: URL(string: "https://download-staging.test/retained")!, name: "Retained",
            localDestination: directory.appendingPathComponent("payload.json")
        )
        let selectedCandidate = selected.uncompressedTransferStagingURL(operationID: UUID())
        let retainedCandidate = retained.uncompressedTransferStagingURL(operationID: UUID())
        let retainedCompressedCandidate = retained.compressedTransferStagingURL(operationID: UUID())
        let payload = Data("retained-candidate".utf8)
        try payload.write(to: selectedCandidate)
        try payload.write(to: retainedCandidate)
        try payload.write(to: retainedCompressedCandidate)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(session: session)

        _ = try await controller.delete(download: selected)

        XCTAssertFalse(FileManager.default.fileExists(atPath: selectedCandidate.path))
        XCTAssertEqual(try Data(contentsOf: retainedCandidate), payload)
        XCTAssertEqual(try Data(contentsOf: retainedCompressedCandidate), payload)
    }

    func testScopedBackoffCancellationPreservesAnotherLogicalDownload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "download-concurrent-cancel-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cancelledDownload = Downloadable(
            url: URL(string: "https://download-concurrent.test/\(UUID().uuidString)/cancelled")!,
            name: "Cancelled download",
            localDestination: directory.appendingPathComponent("cancelled.bin")
        )
        let retainedDownload = Downloadable(
            url: URL(string: "https://download-concurrent.test/\(UUID().uuidString)/retained")!,
            name: "Retained download",
            localDestination: directory.appendingPathComponent("retained.bin")
        )
        let retainedPayload = Data("unrelated-download".utf8)
        let cancelledExecutor = RetryAttemptExecutorStub(
            failuresBeforeSuccess: 1, payload: Data("must-not-install".utf8), retryAfterSeconds: 0
        )
        let retainedGate = DownloadAttemptReleaseGate()
        let enteredBackoff = expectation(description: "selected download entered backoff")
        let retainedStarted = expectation(description: "unrelated logical download started")
        let cancelledCompleted = expectation(description: "selected logical download drained")
        let retainedCompleted = expectation(description: "unrelated logical download drained")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(
            session: session,
            attemptExecutor: { download, session in
                if download.url == cancelledDownload.url {
                    return try await cancelledExecutor.execute(download: download, session: session)
                }
                retainedStarted.fulfill()
                await retainedGate.wait()
                try Task.checkCancellation()
                let candidate = download.localDestination.appendingPathExtension("downloading.test")
                try retainedPayload.write(to: candidate)
                return DownloadTransferResult(destinationLocation: candidate, etag: nil, lastModified: nil)
            },
            retrySleeper: { _ in
                enteredBackoff.fulfill()
                try await Task.sleep(nanoseconds: 30_000_000_000)
            }
        )
        let cancelledOperation = Task {
            await controller.download(cancelledDownload)
            cancelledCompleted.fulfill()
        }
        let retainedOperation = Task {
            await controller.download(retainedDownload)
            retainedCompleted.fulfill()
        }

        await fulfillment(of: [enteredBackoff, retainedStarted], timeout: 2)
        await controller.cancelInProgressDownloads(matchingDownloadURL: cancelledDownload.url)
        await retainedGate.release()
        await fulfillment(of: [cancelledCompleted, retainedCompleted], timeout: 2)
        cancelledOperation.cancel()
        retainedOperation.cancel()
        await cancelledOperation.value
        await retainedOperation.value

        let cancelledAttempts = await cancelledExecutor.recordedAttemptDates()
        XCTAssertEqual(cancelledAttempts.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledDownload.localDestination.path))
        XCTAssertEqual(try Data(contentsOf: retainedDownload.localDestination), retainedPayload)
        let state = await MainActor.run {
            (cancelledDownload.isFailed, retainedDownload.isFailed, retainedDownload.isFinishedProcessing)
        }
        XCTAssertTrue(state.0)
        XCTAssertFalse(state.1)
        XCTAssertTrue(state.2)
    }

    func testScopedCancellationDuringRetryBackoffStopsLogicalOperationAndAllowsFreshDownload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-backoff-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("payload.bin")
        let installedPayload = Data("previous-install".utf8)
        let replacementPayload = Data("replacement-install".utf8)
        try installedPayload.write(to: destination)
        let download = Downloadable(
            url: URL(string: "https://download-backoff-cancel.test/\(UUID().uuidString)")!,
            name: "Cancelled backoff",
            localDestination: destination
        )
        await download.waitForDownloadMetadata()
        let priorDownloadedAt = Date(timeIntervalSince1970: 123)
        await MainActor.run {
            download.lastDownloaded = priorDownloadedAt
            download.lastDownloadedETag = "prior-etag"
        }
        try await download.waitForDownloadMetadataPersistence()
        let executor = RetryAttemptExecutorStub(
            failuresBeforeSuccess: 1,
            payload: replacementPayload,
            retryAfterSeconds: 0
        )
        let enteredBackoff = expectation(description: "retry entered backoff without a URLSession task")
        let completed = expectation(description: "cancelled logical operation drained")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(
            session: session,
            attemptExecutor: { download, session in
                try await executor.execute(download: download, session: session)
            },
            retrySleeper: { _ in
                enteredBackoff.fulfill()
                try await Task.sleep(nanoseconds: 30_000_000_000)
            }
        )
        let operation = Task {
            await controller.download(download)
            completed.fulfill()
        }
        await fulfillment(of: [enteredBackoff], timeout: 2)
        let sessionTasks = await session.allTasks
        XCTAssertTrue(sessionTasks.isEmpty)
        let cancellation = Task {
            await controller.cancelInProgressDownloads(matchingDownloadURL: download.url)
        }
        await fulfillment(of: [completed], timeout: 2)
        // Ensure a failed assertion cannot leave the long backoff running.
        operation.cancel()
        await operation.value
        await cancellation.value

        let cancelledAttemptDates = await executor.recordedAttemptDates()
        XCTAssertEqual(cancelledAttemptDates.count, 1)
        XCTAssertEqual(try Data(contentsOf: destination), installedPayload)
        let cancelledState = await MainActor.run {
            (download.isFailed, download.isFinishedDownloading, download.lastDownloaded, download.lastDownloadedETag)
        }
        XCTAssertTrue(cancelledState.0)
        XCTAssertFalse(cancelledState.1)
        XCTAssertEqual(cancelledState.2, priorDownloadedAt)
        XCTAssertEqual(cancelledState.3, "prior-etag")

        await controller.download(download)
        let finished = try await download.awaitCompletionOrFailure()
        XCTAssertTrue(finished)
        XCTAssertEqual(try Data(contentsOf: destination), replacementPayload)
        let finalAttemptDates = await executor.recordedAttemptDates()
        XCTAssertEqual(finalAttemptDates.count, 2)
    }

    func testScopedCancellationDoesNotCancelAnotherSessionTask() async {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let selectedURL = URL(string: "https://download-scope.test/selected")!
        let otherURL = URL(string: "https://download-scope.test/other")!
        let selectedTask = session.dataTask(with: selectedURL)
        selectedTask.taskDescription = selectedURL.absoluteString
        let otherTask = session.dataTask(with: otherURL)
        otherTask.taskDescription = otherURL.absoluteString
        let controller = DownloadController(session: session)

        await controller.cancelInProgressDownloads(matchingDownloadURL: selectedURL)

        XCTAssertNotEqual(selectedTask.state, .suspended)
        XCTAssertEqual(otherTask.state, .suspended)
    }

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
        let terminalState = await MainActor.run {
            (
                download.isFailed,
                download.isFinishedDownloading,
                controller.failedDownloads.contains(download),
                controller.finishedDownloads.contains(download)
            )
        }
        XCTAssertTrue(terminalState.0)
        XCTAssertFalse(terminalState.1)
        XCTAssertTrue(terminalState.2)
        XCTAssertFalse(terminalState.3)

        let requestDates = await attemptExecutor.recordedAttemptDates()
        XCTAssertEqual(requestDates.count, 2)

        let failedContainsDownload = await MainActor.run {
            controller.failedDownloads.contains(where: { $0.url == url })
        }
        XCTAssertTrue(failedContainsDownload)
    }
}
