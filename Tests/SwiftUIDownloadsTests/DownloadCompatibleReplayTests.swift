import Combine
import Foundation
import XCTest
import CryptoKit
@testable import SwiftUIDownloads

private actor ReplayGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor ReplayCounter {
    private(set) var count = 0
    func next() -> Int { count += 1; return count }
}

/// Native controller/Combine tests. The portable runner does NOT execute these.
final class DownloadCompatibleReplayTests: XCTestCase, @unchecked Sendable {
    @MainActor
    private struct Fixture {
        let root: URL
        let source: URL
        let store: UserDefaultsDownloadableMetadataStore
        let session: URLSession
        var destination: URL { root.appendingPathComponent("日本語.txt") }

        func descriptor(_ name: String, checksum: String? = nil) -> Downloadable {
            let value = Downloadable(url: source, name: name, localDestination: destination,
                                     localDestinationChecksum: checksum, metadataStore: store)
            value.shouldCheckForUpdates = false
            return value
        }

        func controller(
            _ execute: @escaping DownloadController.DownloadAttemptExecutor
        ) -> DownloadController {
            DownloadController(session: session, attemptExecutor: execute, retryPolicyProvider: {
                DownloadRetryPolicy(maxAttempts: 1, initialDelaySeconds: 0, maxDelaySeconds: 0,
                                    jitterFraction: 0, maxServerRetryAfterSeconds: 0)
            })
        }
    }

    @MainActor
    private func fixture() throws -> Fixture {
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "DownloadCompatibleReplayTests.\(id)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let session = URLSession(configuration: .ephemeral)
        addTeardownBlock {
            session.invalidateAndCancel()
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(root: root, source: URL(string: "https://replay.invalid/\(id)/book.txt")!,
                       store: UserDefaultsDownloadableMetadataStore(userDefaults: defaults,
                                                                    metadataCacheNamespace: suite),
                       session: session)
    }

    private static func transfer(_ download: Downloadable, text: String) throws -> DownloadTransferResult {
        let candidate = download.uncompressedTransferStagingURL(operationID: UUID())
        try Data(text.utf8).write(to: candidate)
        return DownloadTransferResult(destinationLocation: candidate, etag: "etag-\(text)", lastModified: nil)
    }

    @MainActor
    private func runToCompletion(_ operation: @escaping @Sendable () async -> Void,
                                 file: StaticString = #filePath, line: UInt = #line) async {
        let returned = expectation(description: "requested controller action returned")
        let task = Task { await operation(); returned.fulfill() }
        let outcome = await XCTWaiter.fulfillment(of: [returned], timeout: 3)
        if outcome != .completed { task.cancel() }
        await task.value
        XCTAssertEqual(outcome, .completed, file: file, line: line)
    }

    @MainActor
    func testRecreatedDescriptorRetriesAFailedOwner() async throws {
        let f = try fixture()
        let count = ReplayCounter()
        let controller = f.controller { download, _ in
            if await count.next() == 1 { throw URLError(.badURL) }
            return try Self.transfer(download, text: "retried")
        }
        let owner = f.descriptor("owner")
        await controller.download(owner)
        XCTAssertTrue(owner.isFailed)
        let replay = f.descriptor("recreated")
        await runToCompletion { await controller.download(replay) }
        let attempts = await count.count
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(owner.isFailed)
        XCTAssertFalse(replay.isFailed)
        XCTAssertTrue(replay.isFinishedProcessing)
        XCTAssertNil(replay.failureMessage)
        XCTAssertEqual(try Data(contentsOf: f.destination), Data("retried".utf8))
    }

    @MainActor
    func testExplicitIdleReplayDownloadDoesNotBecomeAnExistenceCheck() async throws {
        let f = try fixture()
        let count = ReplayCounter()
        let controller = f.controller { download, _ in
            try Self.transfer(download, text: "version-\(await count.next())")
        }
        await controller.download(f.descriptor("owner"))
        let replay = f.descriptor("replacement requested")
        await runToCompletion { await controller.download(replay) }
        let attempts = await count.count
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(replay.isFinishedProcessing)
        XCTAssertEqual(try Data(contentsOf: f.destination), Data("version-2".utf8))
    }

    @MainActor
    func testRecreatedAssuranceRevalidatesDeletedInstalledBytes() async throws {
        let f = try fixture()
        let count = ReplayCounter()
        let controller = f.controller { download, _ in
            _ = await count.next()
            return try Self.transfer(download, text: "restored")
        }
        let owner = f.descriptor("owner")
        await controller.ensureDownloaded(download: owner)
        try FileManager.default.removeItem(at: f.destination)
        let replay = f.descriptor("recreated")
        await runToCompletion { await controller.ensureDownloaded(download: replay) }
        let attempts = await count.count
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(replay.isFinishedProcessing)
        XCTAssertTrue(replay.isReadyForImmediateLocalRead())
        XCTAssertEqual(try Data(contentsOf: f.destination), Data("restored".utf8))
    }

    @MainActor
    func testRecreatedAssuranceRevalidatesReplacedInstalledBytes() async throws {
        let f = try fixture()
        let count = ReplayCounter()
        let controller = f.controller { download, _ in
            _ = await count.next()
            return try Self.transfer(download, text: "authentic")
        }
        let owner = f.descriptor("owner")
        await controller.ensureDownloaded(download: owner)
        try Data("different".utf8).write(to: f.destination, options: .atomic)
        let replay = f.descriptor("recreated")
        await runToCompletion { await controller.ensureDownloaded(download: replay) }
        let attempts = await count.count
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(replay.isReadyForImmediateLocalRead())
        XCTAssertEqual(try Data(contentsOf: f.destination), Data("authentic".utf8))
    }

    @MainActor
    func testCancellingUnregisteredDescriptorDoesNotPoisonLaterAdmission() async throws {
        let f = try fixture()
        let count = ReplayCounter()
        let controller = f.controller { download, _ in
            _ = await count.next()
            return try Self.transfer(download, text: "first acquisition")
        }
        await controller.cancelInProgressDownload(f.descriptor("never started"))
        let replay = f.descriptor("actual request")
        await runToCompletion { await controller.download(replay) }
        let attempts = await count.count
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(replay.isFinishedProcessing)
        XCTAssertFalse(replay.isFailed)
    }

    @MainActor
    func testCancellationOnlyDoesNotReserveAnIncompatibleConfiguration() async throws {
        let f = try fixture()
        let controller = f.controller { download, _ in try Self.transfer(download, text: "first") }
        await controller.cancelInProgressDownload(f.descriptor("not registered", checksum: "unused"))
        let replay = f.descriptor("different configuration is allowed")
        await runToCompletion { await controller.download(replay) }
        XCTAssertFalse(replay.isFailed)
        XCTAssertTrue(replay.isFinishedProcessing)
    }

    @MainActor
    func testAlreadyCancelledDownloadDoesNotLeaveAnIdleRegistration() async throws {
        let f = try fixture()
        let controller = f.controller { download, _ in try Self.transfer(download, text: "first") }
        let cancelled = f.descriptor("cancelled before entry", checksum: "unused")
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            await controller.download(cancelled)
        }
        task.cancel()
        await task.value
        let replay = f.descriptor("first actual request")
        await runToCompletion { await controller.download(replay) }
        XCTAssertFalse(replay.isFailed)
        XCTAssertTrue(replay.isFinishedProcessing)
    }

    @MainActor
    func testReplayJoinsActualProducerDespiteStaleTerminalFlags() async throws {
        let f = try fixture()
        let gate = ReplayGate()
        let count = ReplayCounter()
        let entered = expectation(description: "transfer entered")
        let controller = f.controller { download, _ in
            _ = await count.next()
            entered.fulfill()
            await gate.wait()
            return try Self.transfer(download, text: "held")
        }
        let owner = f.descriptor("owner")
        let operation = Task { await controller.download(owner) }
        await fulfillment(of: [entered], timeout: 2)
        // UI flags are explicitly not the producer-lifetime authority.
        owner.isFinishedProcessing = true
        let replay = f.descriptor("joiner")
        let returned = expectation(description: "replay must not return from stale flag")
        returned.isInverted = true
        let joining = Task { await controller.download(replay); returned.fulfill() }
        await fulfillment(of: [returned], timeout: 0.1)
        await gate.open()
        await operation.value
        await joining.value
        let attempts = await count.count
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(replay.isFinishedProcessing)
        XCTAssertFalse(replay.isFailed)
    }

    @MainActor
    func testCancelledReplayReturnsWithoutCancellingHeldOwner() async throws {
        let f = try fixture()
        let gate = ReplayGate()
        let entered = expectation(description: "owner transfer entered")
        let observed = expectation(description: "replay observation began")
        let owner = f.descriptor("owner")
        let replay = f.descriptor("joiner")
        let controller = f.controller { download, _ in
            await MainActor.run { download.isActive = true }
            entered.fulfill()
            await gate.wait()
            XCTAssertFalse(Task.isCancelled)
            return try Self.transfer(download, text: "owner survives")
        }
        let operation = Task { await controller.download(owner) }
        await fulfillment(of: [entered], timeout: 2)
        let observation = replay.$isActive.filter { $0 }.first().sink { _ in observed.fulfill() }
        let returned = expectation(description: "cancelled replay returned before owner release")
        let joining = Task { await controller.download(replay); returned.fulfill() }
        await fulfillment(of: [observed], timeout: 2)
        joining.cancel()
        let outcome = await XCTWaiter.fulfillment(of: [returned], timeout: 2)
        await gate.open()
        await joining.value
        await operation.value
        observation.cancel()
        XCTAssertEqual(outcome, .completed)
        XCTAssertTrue(owner.isFinishedProcessing)
        XCTAssertFalse(owner.isFailed)
        XCTAssertEqual(try Data(contentsOf: f.destination), Data("owner survives".utf8))
    }

    @MainActor
    func testReplayWaitsForImportAndMirrorsItsProgress() async throws {
        let f = try fixture()
        let gate = ReplayGate()
        let entered = expectation(description: "import entered")
        let observed = expectation(description: "replay shows current import progress")
        let count = ReplayCounter()
        let handler: ImportableDownloadable.ImportHandler = { _, progress in
            _ = await count.next()
            progress(0.4, "Building index")
            entered.fulfill()
            await gate.wait()
        }
        func descriptor(_ name: String) -> ImportableDownloadable {
            ImportableDownloadable(url: f.source, name: name, localDestination: f.destination,
                                   deleteAfterImport: false, metadataStore: f.store,
                                   isImported: { false }, importHandler: handler)
        }
        let owner = descriptor("owner")
        let replay = descriptor("joiner")
        let controller = f.controller { download, _ in try Self.transfer(download, text: "import") }
        let operation = Task { await controller.download(owner) }
        await fulfillment(of: [entered], timeout: 2)
        let observation = replay.$importProgress.compactMap { $0 }.filter { $0 == 0.4 }
            .first().sink { _ in observed.fulfill() }
        let returned = expectation(description: "replay must wait for import to finish")
        returned.isInverted = true
        let joining = Task { await controller.download(replay); returned.fulfill() }
        await fulfillment(of: [observed], timeout: 2)
        await fulfillment(of: [returned], timeout: 0.05)
        await gate.open()
        await operation.value
        await joining.value
        observation.cancel()
        let imports = await count.count
        XCTAssertEqual(imports, 1)
        XCTAssertTrue(replay.isFinishedProcessing)
        XCTAssertNil(replay.importProgress)
        XCTAssertNil(replay.importStatusText)
    }

    @MainActor
    func testCompatibleStandaloneFinishRetainsItsArgumentsAndDoesNotDownload() async throws {
        let f = try fixture()
        let controller = f.controller { _, _ in
            XCTFail("Standalone finish must not turn into a GET")
            throw URLError(.badURL)
        }
        let owner = f.descriptor("owner")
        await controller.finishDownload(owner) // Missing file establishes a failed owner.
        try Data("locally supplied".utf8).write(to: f.destination)
        let replay = f.descriptor("recreated")
        let date = Date(timeIntervalSince1970: 1234)
        let finalURL = URL(string: "https://cdn.invalid/final.txt")!
        await runToCompletion {
            await controller.finishDownload(replay, etag: "local-etag", remoteModifiedAt: date,
                                            finalResponseURL: finalURL, updatesRemoteModifiedAt: true)
        }
        XCTAssertTrue(replay.isFinishedProcessing)
        XCTAssertFalse(replay.isFailed)
        XCTAssertNil(replay.failureMessage)
        XCTAssertEqual(replay.lastDownloadedETag, "local-etag")
        XCTAssertEqual(replay.lastModifiedAt, date)
        XCTAssertNotNil(replay.lastCheckedETagAt)
        XCTAssertEqual(replay.validInstalledArtifactReceipt()?.finalResponseURL, finalURL)
    }

    @MainActor
    func testCompatibleFinishCannotForgetRecordSuccessfulDownloadFalse() async throws {
        let f = try fixture()
        let controller = f.controller { _, _ in throw URLError(.badURL) }
        let owner = f.descriptor("owner")
        await controller.download(owner)
        try Data("unreceipted".utf8).write(to: f.destination)
        let replay = f.descriptor("recreated")
        await runToCompletion {
            await controller.finishDownload(replay, recordSuccessfulDownload: false)
        }
        XCTAssertTrue(replay.isFailed)
        XCTAssertNil(replay.validInstalledArtifactReceipt())
        XCTAssertNil(replay.lastDownloaded)
    }

    @MainActor
    func testCompatibleChecksumRecoveryRunsInsteadOfCopyingOldFailure() async throws {
        let f = try fixture()
        let payload = "verified recovery"
        let checksum = Insecure.SHA1.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
        let count = ReplayCounter()
        let controller = f.controller { download, _ in
            if await count.next() == 1 { throw URLError(.badURL) }
            return try Self.transfer(download, text: payload)
        }
        let owner = f.descriptor("owner", checksum: checksum)
        await controller.download(owner)
        try Data("corrupt".utf8).write(to: f.destination)
        let replay = f.descriptor("recreated", checksum: checksum)
        await runToCompletion { await controller.recoverLocalChecksumFailure(for: replay) }
        let attempts = await count.count
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(replay.isFailed)
        XCTAssertTrue(replay.hasVerifiedLocalDestinationChecksumMarker())
    }

    @MainActor
    func testConcurrentCompatibleAssurancesUseOneTransfer() async throws {
        let f = try fixture()
        let count = ReplayCounter()
        let controller = f.controller { download, _ in
            _ = await count.next()
            return try Self.transfer(download, text: "shared")
        }
        let descriptors = (0..<30).map { f.descriptor("caller-\($0)") }
        await runToCompletion {
            await withTaskGroup(of: Void.self) { group in
                for descriptor in descriptors {
                    group.addTask { await controller.ensureDownloaded(download: descriptor) }
                }
            }
        }
        let attempts = await count.count
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(descriptors.allSatisfy { $0.isFinishedProcessing && !$0.isFailed })
    }

    @MainActor
    func testAssuranceRebuildsMissingDerivedImportWithoutAnotherTransfer() async throws {
        let f = try fixture()
        let derived = f.root.appendingPathComponent("derived-index")
        let transfers = ReplayCounter()
        let imports = ReplayCounter()
        let handler: ImportableDownloadable.ImportHandler = { _, _ in
            _ = await imports.next()
            try Data("index".utf8).write(to: derived)
        }
        func descriptor(_ name: String) -> ImportableDownloadable {
            let result = ImportableDownloadable(
                url: f.source, name: name, localDestination: f.destination,
                deleteAfterImport: false, metadataStore: f.store,
                isImported: { FileManager.default.fileExists(atPath: derived.path) },
                importHandler: handler
            )
            result.shouldCheckForUpdates = false
            return result
        }
        let controller = f.controller { download, _ in
            _ = await transfers.next()
            return try Self.transfer(download, text: "retained source")
        }
        let owner = descriptor("owner")
        await controller.ensureDownloaded(download: owner)
        XCTAssertTrue(owner.isFinishedProcessing)
        try FileManager.default.removeItem(at: derived)
        let replay = descriptor("recreated")
        await runToCompletion { await controller.ensureDownloaded(download: replay) }
        let transferCount = await transfers.count
        let importCount = await imports.count
        XCTAssertEqual(transferCount, 1)
        XCTAssertEqual(importCount, 2)
        XCTAssertFalse(replay.isFailed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: derived.path))
    }

    @MainActor
    func testStoppedReplayObservationCannotApplyQueuedOwnerUpdates() async throws {
        let f = try fixture()
        let owner = f.descriptor("owner")
        let replay = f.descriptor("replay")
        let observation = DownloadReplayObservation(owner: owner, replay: replay)
        owner.isActive = true // Queues a main-actor publication.
        observation.stop(copyFinalState: false)
        replay.isActive = false
        // Enqueue after the observer callback's task without relying on sleeps.
        await Task { @MainActor in }.value
        XCTAssertFalse(replay.isActive)
        owner.isFailed = true
        await Task { @MainActor in }.value
        XCTAssertFalse(replay.isFailed)
    }
}
