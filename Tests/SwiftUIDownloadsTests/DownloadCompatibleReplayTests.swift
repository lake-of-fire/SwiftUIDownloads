import Combine
import Foundation
import XCTest
import CryptoKit
import Brotli
@testable import SwiftUIDownloads

private final class LocalPreparationRequestCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [URL: Int] = [:]
    private var methodCounts: [URL: [String: Int]] = [:]
    private var responses: [URL: (payload: Data, etag: String)] = [:]

    func record(_ url: URL, method: String) {
        lock.lock()
        defer { lock.unlock() }
        counts[url, default: 0] += 1
        methodCounts[url, default: [:]][method, default: 0] += 1
    }

    func count(_ url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[url, default: 0]
    }

    func count(_ url: URL, method: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return methodCounts[url]?[method] ?? 0
    }

    func respond(to url: URL, payload: Data, etag: String) {
        lock.lock()
        defer { lock.unlock() }
        responses[url] = (payload, etag)
    }

    func response(for url: URL) -> (payload: Data, etag: String)? {
        lock.lock()
        defer { lock.unlock() }
        return responses[url]
    }
}

private final class LocalPreparationURLProtocol: URLProtocol {
    static let requests = LocalPreparationRequestCounts()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let method = request.httpMethod ?? "GET"
        Self.requests.record(url, method: method)
        guard let result = Self.requests.response(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["ETag": result.etag, "Content-Length": String(result.payload.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if method != "HEAD" { client?.urlProtocol(self, didLoad: result.payload) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class LocalPreparationStageCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [DownloadController.LocalPreparationStage] = []

    func append(_ stage: DownloadController.LocalPreparationStage) {
        lock.lock()
        defer { lock.unlock() }
        stages.append(stage)
    }

    func snapshot() -> [DownloadController.LocalPreparationStage] {
        lock.lock()
        defer { lock.unlock() }
        return stages
    }
}

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

private actor ReplayImportState {
    private(set) var isImported = false
    func setImported(_ value: Bool) { isImported = value }
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
    private func fixture(observeLocalRequests: Bool = false) throws -> Fixture {
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "DownloadCompatibleReplayTests.\(id)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let configuration = URLSessionConfiguration.ephemeral
        if observeLocalRequests { configuration.protocolClasses = [LocalPreparationURLProtocol.self] }
        let session = URLSession(configuration: configuration)
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

    private static func checksum(_ payload: Data) -> String {
        Insecure.SHA1.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    func testVerifiedNativeAdmissionLeavesPublicationToOrdinaryOwner() async throws {
        let f = try fixture(observeLocalRequests: true)
        let payload = Data("verified native dictionary".utf8)
        try payload.write(to: f.destination)
        let download = f.descriptor("native", checksum: Self.checksum(payload))
        try download.ensureVerifiedLocalDestinationChecksum()
        let controller = f.controller { _, _ in
            XCTFail("Verified native admission must remain offline")
            throw URLError(.notConnectedToInternet)
        }
        let capture = LocalPreparationStageCapture()
        let outcome = try await DownloadController.$localPreparationStageObserver.withValue({
            capture.append($0)
        }) {
            try await controller.verifiedLocalArtifactAvailability(download: download)
        }
        XCTAssertEqual(outcome, .available)
        XCTAssertEqual(capture.snapshot(), [.verifiedArtifact, .completed])
        XCTAssertFalse(download.isFinishedProcessing)
        XCTAssertFalse(download.isFinishedDownloading)
        XCTAssertTrue(controller.finishedDownloads.isEmpty)
        XCTAssertTrue(controller.assuredDownloads.isEmpty)
        // Compatible descriptors share native proof without mirroring UI flags.
        let replay = f.descriptor("replay", checksum: Self.checksum(payload))
        let replayOutcome = try await controller.verifiedLocalArtifactAvailability(download: replay)
        XCTAssertEqual(replayOutcome, .available)
        XCTAssertFalse(replay.isFinishedProcessing)
        await controller.ensureDownloaded(download: download)
        XCTAssertTrue(download.isFinishedProcessing)
        XCTAssertTrue(download.isFinishedDownloading)
        XCTAssertTrue(controller.finishedDownloads.contains(download))
        XCTAssertEqual(try Data(contentsOf: f.destination), payload)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0)
    }

    @MainActor
    func testVerifiedNativeAdmissionRequiresCurrentPinnedIdentity() async throws {
        let f = try fixture(observeLocalRequests: true)
        let payload = Data("pinned dictionary".utf8)
        try payload.write(to: f.destination)
        let download = f.descriptor("native", checksum: Self.checksum(payload))
        let controller = f.controller { _, _ in throw URLError(.notConnectedToInternet) }
        let unverified = try await controller.verifiedLocalArtifactAvailability(download: download)
        XCTAssertEqual(unverified, .unavailable)
        XCTAssertFalse(download.hasVerifiedLocalDestinationChecksumMarker())
        try download.ensureVerifiedLocalDestinationChecksum()
        let available = try await controller.verifiedLocalArtifactAvailability(download: download)
        XCTAssertEqual(available, .available)
        // Atomic replacement invalidates proof even when bytes and length match.
        try payload.write(to: f.destination, options: .atomic)
        let replaced = try await controller.verifiedLocalArtifactAvailability(download: download)
        XCTAssertEqual(replaced, .unavailable)
        XCTAssertFalse(download.isFailed)
        XCTAssertFalse(download.isFinishedProcessing)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0)
    }

    @MainActor
    func testVerifiedNativeAdmissionDefersCompressedInputAndImports() async throws {
        let f = try fixture(observeLocalRequests: true)
        let payload = Data("pinned input".utf8)
        try payload.write(to: f.destination)
        let download = f.descriptor("native", checksum: Self.checksum(payload))
        try download.ensureVerifiedLocalDestinationChecksum()
        try Data("pending compressed input".utf8).write(to: download.compressedFileURL)
        let controller = f.controller { _, _ in throw URLError(.notConnectedToInternet) }
        let compressed = try await controller.verifiedLocalArtifactAvailability(download: download)
        XCTAssertEqual(compressed, .unavailable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: download.compressedFileURL.path))
        try FileManager.default.moveItem(
            at: download.compressedFileURL, to: f.root.appendingPathComponent("retained-input")
        )
        let imports = ReplayCounter()
        let importable = ImportableDownloadable(
            url: f.source.appendingPathComponent("import"), name: "import", localDestination: f.destination,
            localDestinationChecksum: Self.checksum(payload), deleteAfterImport: false,
            metadataStore: f.store,
            isImported: { _ = await imports.next(); return true },
            importHandler: { _, _ in XCTFail("Admission must not start an importer") }
        )
        let importOutcome = try await controller.verifiedLocalArtifactAvailability(download: importable)
        XCTAssertEqual(importOutcome, .unavailable)
        let importChecks = await imports.count
        XCTAssertEqual(importChecks, 0)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0)
    }

    @MainActor
    func testVerifiedNativeAdmissionPreservesBackgroundAndCancellationBoundaries() async throws {
        let f = try fixture(observeLocalRequests: true)
        let payload = Data("verified dictionary".utf8)
        try payload.write(to: f.destination)
        let download = f.descriptor("native", checksum: Self.checksum(payload))
        try download.ensureVerifiedLocalDestinationChecksum()
        let controller = f.controller { _, _ in throw URLError(.notConnectedToInternet) }
        await controller.cancelAndDrainForBackgrounding()
        let suspended = try await controller.verifiedLocalArtifactAvailability(download: download)
        XCTAssertEqual(suspended, .busy)
        let reopened = await controller.reopenAdmissionAfterBackgroundDrain(shouldResume: { true })
        XCTAssertTrue(reopened)
        let available = try await controller.verifiedLocalArtifactAvailability(download: download)
        XCTAssertEqual(available, .available)
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await controller.verifiedLocalArtifactAvailability(download: download)
        }
        do {
            _ = try await canceled.value
            XCTFail("Canceled native admission must throw")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(download.isFinishedProcessing)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0)
    }

    @MainActor
    func testLocalPreparationObservationIsScopedAndPreservesVerifiedOfflineReadiness() async throws {
        let f = try fixture(observeLocalRequests: true)
        let payload = Data("verified local dictionary".utf8)
        try payload.write(to: f.destination)
        let download = f.descriptor("local", checksum: Self.checksum(payload))
        try download.ensureVerifiedLocalDestinationChecksum()
        let controller = f.controller { _, _ in
            XCTFail("Observing local preparation must not acquire remote bytes")
            throw URLError(.notConnectedToInternet)
        }
        let capture = LocalPreparationStageCapture()
        let outcome = try await DownloadController.$localPreparationStageObserver.withValue({
            capture.append($0)
        }) {
            try await controller.prepareAvailableLocalArtifact(download: download)
        }
        XCTAssertEqual(outcome, .available)
        XCTAssertTrue(download.isReadyForImmediateLocalRead())
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0)
        XCTAssertNil(DownloadController.localPreparationStageObserver)
        let stages = capture.snapshot()
        let expectedOrder: [(DownloadController.LocalPreparationStage, DownloadController.LocalPreparationStage)] = [
            (.metadataRequested, .metadataReady),
            (.metadataReady, .processingRequested),
            (.processingRequested, .verifiedArtifact),
            (.verifiedArtifact, .completed),
        ]
        XCTAssertFalse(stages.contains(.publicationRequested))
        XCTAssertFalse(stages.contains(.stateRequested))
        XCTAssertFalse(download.isFinishedProcessing)
        for (before, after) in expectedOrder {
            XCTAssertLessThan(try XCTUnwrap(stages.firstIndex(of: before)),
                              try XCTUnwrap(stages.firstIndex(of: after)))
        }
    }

    @MainActor
    func testRepeatedVerifiedLocalPreparationDoesNotRepublishUnchangedStatus() async throws {
        let f = try fixture(observeLocalRequests: true)
        let payload = Data("retained pinned dictionary".utf8)
        try payload.write(to: f.destination)
        let download = f.descriptor("local", checksum: Self.checksum(payload))
        try download.ensureVerifiedLocalDestinationChecksum()
        let controller = f.controller { _, _ in
            XCTFail("Repeated local preparation must stay offline")
            throw URLError(.notConnectedToInternet)
        }
        let first = try await controller.prepareAvailableLocalArtifact(download: download)
        XCTAssertEqual(first, .available)
        var publications = 0
        let observations = [
            download.$isFailed.dropFirst().sink { _ in publications += 1 },
            download.$isActive.dropFirst().sink { _ in publications += 1 },
            download.$isFinishedDownloading.dropFirst().sink { _ in publications += 1 },
            download.$isFinishedProcessing.dropFirst().sink { _ in publications += 1 },
            download.$downloadProgress.dropFirst().sink { _ in publications += 1 },
            controller.$failedDownloads.dropFirst().sink { _ in publications += 1 },
            controller.$activeDownloads.dropFirst().sink { _ in publications += 1 },
            controller.$finishedDownloads.dropFirst().sink { _ in publications += 1 },
        ]
        defer { observations.forEach { $0.cancel() } }
        let repeated = try await controller.prepareAvailableLocalArtifact(download: download)
        XCTAssertEqual(repeated, .available)
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0)
        XCTAssertFalse(controller.assuredDownloads.contains(download))
    }

    @MainActor
    func testVerifiedLocalPreparationDefersClearingStaleFailureToOrdinaryAssurance() async throws {
        let f = try fixture(observeLocalRequests: true)
        let payload = Data("healthy installed dictionary".utf8)
        try payload.write(to: f.destination)
        let download = f.descriptor("local", checksum: Self.checksum(payload))
        try download.ensureVerifiedLocalDestinationChecksum()
        download.isFailed = true
        download.downloadProgress = .completed(
            destinationLocation: nil, etag: nil, error: URLError(.cannotOpenFile)
        )
        let controller = f.controller { _, _ in
            XCTFail("Recovering a verified local file must not request the network")
            throw URLError(.notConnectedToInternet)
        }
        controller.failedDownloads.insert(download)
        let outcome = try await controller.prepareAvailableLocalArtifact(download: download)
        XCTAssertEqual(outcome, .available)
        XCTAssertTrue(download.isFailed, "UI errors do not defeat current native proof")
        XCTAssertTrue(controller.failedDownloads.contains(download))
        XCTAssertFalse(controller.finishedDownloads.contains(download))
        await controller.ensureDownloaded(download: download)
        XCTAssertFalse(download.isFailed)
        XCTAssertFalse(controller.failedDownloads.contains(download))
        XCTAssertTrue(controller.finishedDownloads.contains(download))
        guard case let .completed(destination, _, error) = download.downloadProgress else {
            return XCTFail("Expected successful local completion")
        }
        XCTAssertEqual(destination, f.destination)
        XCTAssertNil(error)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0)
    }

    @MainActor
    func testForegroundAdmissionReopensLocalPreparationWithoutStartingRemoteRecovery() async throws {
        let f = try fixture(observeLocalRequests: true)
        let payload = Data("retained dictionary".utf8)
        try payload.write(to: f.destination)
        let download = f.descriptor("local", checksum: Self.checksum(payload))
        let transfers = ReplayCounter()
        let controller = f.controller { candidate, _ in
            _ = await transfers.next()
            return try Self.transfer(candidate, text: "unexpected")
        }
        await controller.cancelAndDrainForBackgrounding()
        let rejected = await controller.reopenAdmissionAfterBackgroundDrain(shouldResume: { false })
        XCTAssertFalse(rejected)
        let suspended = try await controller.prepareAvailableLocalArtifact(download: download)
        XCTAssertEqual(suspended, .busy)
        let reopened = await controller.reopenAdmissionAfterBackgroundDrain(shouldResume: { true })
        XCTAssertTrue(reopened)
        let available = try await controller.prepareAvailableLocalArtifact(download: download)
        XCTAssertEqual(available, .available)
        let transferCount = await transfers.count
        XCTAssertEqual(transferCount, 0)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0)
        await controller.cancelAndDrainForBackgrounding()
        let pausedAgain = try await controller.prepareAvailableLocalArtifact(download: download)
        XCTAssertEqual(pausedAgain, .busy)
    }

    @MainActor
    func testLocalPreparationLeavesVerifiedPinnedUIStateForOrdinaryAssurance() async throws {
        let f = try fixture(observeLocalRequests: true)
        let payload = Data("already verified dictionary".utf8)
        try payload.write(to: f.destination)
        let download = f.descriptor("verified", checksum: Self.checksum(payload))
        try download.ensureVerifiedLocalDestinationChecksum()
        XCTAssertFalse(download.isFinishedProcessing)
        let transfers = ReplayCounter()
        let controller = f.controller { candidate, _ in
            _ = await transfers.next()
            return try Self.transfer(candidate, text: "unexpected")
        }
        let outcome = try await controller.prepareAvailableLocalArtifact(download: download)
        XCTAssertEqual(outcome, .available)
        XCTAssertFalse(download.isFinishedProcessing)
        XCTAssertFalse(download.isFinishedDownloading)
        XCTAssertFalse(controller.assuredDownloads.contains(download))
        await controller.ensureDownloaded(download: download)
        XCTAssertTrue(download.isFinishedProcessing)
        XCTAssertTrue(download.isFinishedDownloading)
        XCTAssertNil(download.lastDownloaded)
        XCTAssertEqual(try Data(contentsOf: f.destination), payload)
        let count = await transfers.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0)
    }

    @MainActor
    func testLocalPreparationRejectsChangedPreviouslyVerifiedPinnedArtifact() async throws {
        let f = try fixture(observeLocalRequests: true)
        let payload = Data("verified dictionary".utf8)
        try payload.write(to: f.destination)
        let download = f.descriptor("changed", checksum: Self.checksum(payload))
        try download.ensureVerifiedLocalDestinationChecksum()
        try Data("modified dictionary".utf8).write(to: f.destination, options: .atomic)
        XCTAssertFalse(download.hasVerifiedLocalDestinationChecksumMarker())
        let transfers = ReplayCounter()
        let controller = f.controller { candidate, _ in
            _ = await transfers.next()
            return try Self.transfer(candidate, text: "unexpected")
        }
        let outcome = try await controller.prepareAvailableLocalArtifact(download: download)
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertTrue(download.isFailed)
        XCTAssertFalse(download.isReadyForImmediateLocalRead())
        let count = await transfers.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0)
    }

    @MainActor
    func testLocalPreparationVerifiedPinnedArtifactStillRebuildsMissingImport() async throws {
        let f = try fixture(observeLocalRequests: true)
        let payload = Data("verified import source".utf8)
        try payload.write(to: f.destination)
        let imports = ReplayCounter()
        let state = ReplayImportState()
        let download = ImportableDownloadable(
            url: f.source, name: "missing derived state", localDestination: f.destination,
            localDestinationChecksum: Self.checksum(payload), deleteAfterImport: false,
            importOperationIdentifier: "verified-local-import", metadataStore: f.store,
            isImported: { await state.isImported },
            importHandler: { _, _ in
                _ = await imports.next()
                await state.setImported(true)
            }
        )
        try download.ensureVerifiedLocalDestinationChecksum()
        let controller = f.controller { candidate, _ in
            XCTFail("Local import must not acquire remote bytes")
            return try Self.transfer(candidate, text: "unexpected")
        }
        let outcome = try await controller.prepareAvailableLocalArtifact(download: download)
        XCTAssertEqual(outcome, .available)
        let count = await imports.count
        XCTAssertEqual(count, 1)
        XCTAssertTrue(download.isFinishedProcessing)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0)
    }

    @MainActor
    func testLocalPreparationValidatesPinnedDestinationWithoutRemoteAssurance() async throws {
        let f = try fixture(observeLocalRequests: true)
        let payload = Data("retained dictionary".utf8)
        try payload.write(to: f.destination)
        let download = f.descriptor("local", checksum: Self.checksum(payload))
        download.shouldCheckForUpdates = true
        let transfers = ReplayCounter()
        let controller = f.controller { download, _ in
            _ = await transfers.next()
            return try Self.transfer(download, text: "unexpected")
        }

        let capture = LocalPreparationStageCapture()
        let outcome = try await DownloadController.$localPreparationStageObserver.withValue({
            capture.append($0)
        }) {
            try await controller.prepareAvailableLocalArtifact(download: download)
        }

        XCTAssertEqual(outcome, .available)
        XCTAssertFalse(download.isFinishedProcessing)
        XCTAssertFalse(download.isFinishedDownloading)
        XCTAssertTrue(controller.finishedDownloads.isEmpty)
        XCTAssertFalse(capture.snapshot().contains(.publicationRequested))
        XCTAssertFalse(capture.snapshot().contains(.stateRequested))
        XCTAssertTrue(download.hasVerifiedLocalDestinationChecksumMarker())
        XCTAssertEqual(try Data(contentsOf: f.destination), payload)
        XCTAssertFalse(controller.assuredDownloads.contains(download))
        XCTAssertNil(download.lastDownloaded)
        XCTAssertNil(download.lastCheckedETagAt)
        let replay = f.descriptor("compatible local", checksum: Self.checksum(payload))
        let replayOutcome = try await controller.prepareAvailableLocalArtifact(download: replay)
        XCTAssertEqual(replayOutcome, .available)
        XCTAssertFalse(replay.isFinishedProcessing)
        XCTAssertFalse(replay.isFinishedDownloading)
        await controller.ensureDownloaded(download: replay)
        XCTAssertTrue(download.isFinishedProcessing)
        XCTAssertTrue(replay.isFinishedProcessing)
        XCTAssertTrue(replay.isFinishedDownloading)
        XCTAssertEqual(replay.fileSize, UInt64(payload.count))
        XCTAssertNil(download.lastDownloaded)
        XCTAssertNil(download.lastCheckedETagAt)
        XCTAssertNil(download.lastDownloadedETag)
        let transferCount = await transfers.count
        XCTAssertEqual(transferCount, 0)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0)
    }

    @MainActor
    func testConcurrentCompatibleFreshNativePreparationsLeaveUICompletionToAssurance() async throws {
        let f = try fixture(observeLocalRequests: true)
        let payload = Data(repeating: 0x61, count: 1024 * 1024)
        try payload.write(to: f.destination)
        let owner = f.descriptor("fresh owner", checksum: Self.checksum(payload))
        let replay = f.descriptor("fresh replay", checksum: Self.checksum(payload))
        let controller = f.controller { _, _ in
            XCTFail("Concurrent native preparation must remain offline")
            throw URLError(.notConnectedToInternet)
        }
        async let ownerOutcome = controller.prepareAvailableLocalArtifact(download: owner)
        async let replayOutcome = controller.prepareAvailableLocalArtifact(download: replay)
        let outcomes = try await [ownerOutcome, replayOutcome]
        XCTAssertEqual(outcomes, [.available, .available])
        XCTAssertTrue(owner.hasVerifiedLocalDestinationChecksumMarker())
        XCTAssertFalse(owner.isFinishedProcessing)
        XCTAssertFalse(replay.isFinishedProcessing)
        XCTAssertTrue(controller.finishedDownloads.isEmpty)
        await controller.ensureDownloaded(download: replay)
        XCTAssertTrue(replay.isFinishedProcessing)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0)
    }

    @MainActor
    func testFreshNativePreparationRechecksAtomicReplacementAfterVerification() async throws {
        let f = try fixture(observeLocalRequests: true)
        let payload = Data("fresh pinned dictionary".utf8)
        try payload.write(to: f.destination)
        let download = f.descriptor("native replacement", checksum: Self.checksum(payload))
        let controller = f.controller { _, _ in
            XCTFail("Native preparation must remain offline")
            throw URLError(.notConnectedToInternet)
        }
        let destination = f.destination
        let outcome = try await DownloadController.$localPreparationStageObserver.withValue({ stage in
            if stage == .verifiedArtifact {
                // Identical bytes on a new inode still invalidate the marker.
                do { try payload.write(to: destination, options: .atomic) }
                catch { XCTFail("Could not replace verified fixture: \(error)") }
            }
        }) {
            try await controller.prepareAvailableLocalArtifact(download: download)
        }
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertFalse(download.hasVerifiedLocalDestinationChecksumMarker())
        XCTAssertFalse(download.isFinishedProcessing)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0)
    }

    @MainActor
    func testFreshNativePreparationCancellationAtAdmissionLeavesRetryAvailable() async throws {
        let f = try fixture(observeLocalRequests: true)
        let payload = Data("cancelable native dictionary".utf8)
        try payload.write(to: f.destination)
        let download = f.descriptor("native cancellation", checksum: Self.checksum(payload))
        let controller = f.controller { _, _ in
            XCTFail("Local preparation and retry must remain offline")
            throw URLError(.notConnectedToInternet)
        }
        let canceled = Task {
            try await DownloadController.$localPreparationStageObserver.withValue({ stage in
                if stage == .processingRequested {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }) {
                try await controller.prepareAvailableLocalArtifact(download: download)
            }
        }
        do {
            _ = try await canceled.value
            XCTFail("Canceled native owner must throw")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(download.hasVerifiedLocalDestinationChecksumMarker())
        XCTAssertFalse(download.isFinishedProcessing)
        let retried = try await controller.prepareAvailableLocalArtifact(download: download)
        XCTAssertEqual(retried, .available)
        XCTAssertTrue(download.hasVerifiedLocalDestinationChecksumMarker())
        XCTAssertFalse(download.isFinishedProcessing)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0)
    }

    @MainActor
    func testCanceledNativeProcessorPreservesRetainedBytesWithoutProof() async throws {
        let f = try fixture(observeLocalRequests: true)
        let payload = Data("retained native input survives cancellation".utf8)
        try payload.write(to: f.destination)
        let download = f.descriptor("canceled native processor", checksum: Self.checksum(payload))
        let controller = f.controller { _, _ in
            XCTFail("Canceling local verification cannot require a remote replacement")
            throw URLError(.notConnectedToInternet)
        }
        let markerURL = download.checksumVerificationMarkerURL
        let outcome = try await DownloadController.$localPreparationStageObserver.withValue({ stage in
            if stage == .verifiedArtifact {
                // Exercise cancellation cleanup without reusable proof. This
                // is a deterministic completion-boundary test, not mid-hash QA.
                do { try FileManager.default.removeItem(at: markerURL) }
                catch { XCTFail("Could not invalidate fixture proof: \(error)") }
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }) {
            try await controller.prepareAvailableLocalArtifact(download: download)
        }
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(try Data(contentsOf: f.destination), payload)
        XCTAssertFalse(download.hasVerifiedLocalDestinationChecksumMarker())
        let retried = try await controller.prepareAvailableLocalArtifact(download: download)
        XCTAssertEqual(retried, .available)
        XCTAssertTrue(download.hasVerifiedLocalDestinationChecksumMarker())
        XCTAssertEqual(try Data(contentsOf: f.destination), payload)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0)
    }

    @MainActor
    func testNativePreparationRehashesCorruptMarkerAndOrdinaryAssuranceStaysOffline() async throws {
        let f = try fixture(observeLocalRequests: true)
        let payload = Data("healthy retained bytes with a truncated marker".utf8)
        try payload.write(to: f.destination)
        let download = f.descriptor("corrupt marker", checksum: Self.checksum(payload))
        try Data("{\"schemaVersion\":".utf8).write(to: download.checksumVerificationMarkerURL)
        let controller = f.controller { _, _ in
            XCTFail("Marker repair must not acquire remote bytes")
            throw URLError(.notConnectedToInternet)
        }
        let before = try await controller.verifiedLocalArtifactAvailability(download: download)
        XCTAssertEqual(before, .unavailable)
        let outcome = try await controller.prepareAvailableLocalArtifact(download: download)
        XCTAssertEqual(outcome, .available)
        XCTAssertTrue(download.hasVerifiedLocalDestinationChecksumMarker())
        XCTAssertEqual(try Data(contentsOf: f.destination), payload)
        XCTAssertFalse(download.isFinishedProcessing)
        XCTAssertFalse(download.isFinishedDownloading)
        await controller.ensureDownloaded(download: download)
        XCTAssertTrue(download.isFinishedProcessing)
        XCTAssertFalse(download.isFailed)
        XCTAssertNil(download.lastDownloaded)
        XCTAssertNil(download.lastCheckedETagAt)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0)
    }

    @MainActor
    func testNativePreparationMarkerWriteFailurePreservesPayloadForOfflineRetry() async throws {
        let f = try fixture(observeLocalRequests: true)
        let payload = Data("healthy retained bytes with blocked marker persistence".utf8)
        try payload.write(to: f.destination)
        let download = f.descriptor("blocked marker", checksum: Self.checksum(payload))
        // A directory deterministically prevents the atomic marker file write.
        // Retain its contents to verify error cleanup does not remove occupants.
        try FileManager.default.createDirectory(
            at: download.checksumVerificationMarkerURL, withIntermediateDirectories: false
        )
        let blocker = download.checksumVerificationMarkerURL.appendingPathComponent("retained-blocker")
        let blockerBytes = Data("retain me".utf8)
        try blockerBytes.write(to: blocker)
        let controller = f.controller { _, _ in
            XCTFail("Marker I/O failure and retry must stay offline")
            throw URLError(.notConnectedToInternet)
        }
        let outcome = try await controller.prepareAvailableLocalArtifact(download: download)
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertTrue(download.isFailed)
        XCTAssertFalse(download.isFinishedDownloading)
        XCTAssertFalse(download.hasVerifiedLocalDestinationChecksumMarker())
        XCTAssertEqual(try Data(contentsOf: f.destination), payload)
        XCTAssertEqual(try Data(contentsOf: blocker), blockerBytes)
        let failedProof = try await controller.verifiedLocalArtifactAvailability(download: download)
        XCTAssertEqual(failedProof, .unavailable)

        try FileManager.default.moveItem(
            at: download.checksumVerificationMarkerURL,
            to: f.root.appendingPathComponent("preserved-marker-blocker")
        )
        let retried = try await controller.prepareAvailableLocalArtifact(download: download)
        XCTAssertEqual(retried, .available)
        XCTAssertTrue(download.hasVerifiedLocalDestinationChecksumMarker())
        XCTAssertEqual(try Data(contentsOf: f.destination), payload)
        XCTAssertTrue(download.isFailed, "Native readiness leaves stale UI failure to assurance")
        await controller.ensureDownloaded(download: download)
        XCTAssertFalse(download.isFailed)
        XCTAssertTrue(download.isFinishedDownloading)
        XCTAssertNil(download.lastDownloaded)
        XCTAssertNil(download.lastCheckedETagAt)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0)
    }

    @MainActor
    func testCorruptMarkerDoesNotAdmitMismatchedPinnedBytes() async throws {
        let f = try fixture(observeLocalRequests: true)
        let payload = Data("expected pinned bytes".utf8)
        try Data("different retained bytes".utf8).write(to: f.destination)
        let download = f.descriptor("corrupt marker mismatch", checksum: Self.checksum(payload))
        try Data("not JSON".utf8).write(to: download.checksumVerificationMarkerURL)
        let controller = f.controller { _, _ in
            XCTFail("A bad checksum must not trigger local-only network recovery")
            throw URLError(.notConnectedToInternet)
        }
        let outcome = try await controller.prepareAvailableLocalArtifact(download: download)
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertTrue(download.isFailed)
        XCTAssertFalse(download.hasVerifiedLocalDestinationChecksumMarker())
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.path))
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0)
    }

    @MainActor
    func testFreshNativePreparationRejectsEmptyPinnedFile() async throws {
        let f = try fixture(observeLocalRequests: true)
        try Data().write(to: f.destination)
        let download = f.descriptor("empty native", checksum: Self.checksum(Data()))
        let controller = f.controller { _, _ in
            XCTFail("Invalid native preparation cannot recover remotely")
            throw URLError(.notConnectedToInternet)
        }
        let outcome = try await controller.prepareAvailableLocalArtifact(download: download)
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertFalse(download.hasVerifiedLocalDestinationChecksumMarker())
        XCTAssertTrue(download.isFailed)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0)
    }

    @MainActor
    func testLocalPreparationExpandsRetainedCompressedArtifact() async throws {
        let f = try fixture(observeLocalRequests: true)
        let payload = Data("retained compressed dictionary".utf8)
        let compressed = try XCTUnwrap((payload as NSData).brotliCompressed())
        let download = Downloadable(
            url: f.source.appendingPathExtension("br"), name: "compressed local",
            localDestination: f.destination, localDestinationChecksum: Self.checksum(payload),
            metadataStore: f.store
        )
        try compressed.write(to: download.compressedFileURL)
        let transfers = ReplayCounter()
        let controller = f.controller { download, _ in
            _ = await transfers.next()
            return try Self.transfer(download, text: "unexpected")
        }

        let outcome = try await controller.prepareAvailableLocalArtifact(download: download)

        XCTAssertEqual(outcome, .available)
        XCTAssertEqual(try Data(contentsOf: f.destination), payload)
        XCTAssertTrue(download.isReadyForImmediateLocalRead())
        XCTAssertTrue(download.isFinishedProcessing, "Compressed processing retains ordinary publication")
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.compressedFileURL.path))
        let transferCount = await transfers.count
        XCTAssertEqual(transferCount, 0)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(download.url), 0)
    }

    @MainActor
    func testLocalPreparationReusesInstalledReceiptWithoutRemoteCheck() async throws {
        let f = try fixture(observeLocalRequests: true)
        let transfers = ReplayCounter()
        let controller = f.controller { download, _ in
            _ = await transfers.next()
            return try Self.transfer(download, text: "receipt authenticated")
        }
        let owner = f.descriptor("installed")
        await controller.download(owner)
        let replay = f.descriptor("local replay")
        replay.shouldCheckForUpdates = true
        let downloadedAt = owner.lastDownloaded

        let outcome = try await controller.prepareAvailableLocalArtifact(download: replay)

        XCTAssertEqual(outcome, .available)
        XCTAssertTrue(replay.isReadyForImmediateLocalRead())
        XCTAssertTrue(replay.isFinishedProcessing)
        XCTAssertEqual(owner.lastDownloaded, downloadedAt)
        XCTAssertNil(owner.lastCheckedETagAt)
        let count = await transfers.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0)
    }

    @MainActor
    func testLocalPreparationRejectsUnreceiptedUnpinnedDestination() async throws {
        let f = try fixture(observeLocalRequests: true)
        try Data("unverified bytes".utf8).write(to: f.destination)
        let controller = f.controller { _, _ in
            XCTFail("Local preparation cannot acquire remote bytes")
            throw URLError(.notConnectedToInternet)
        }
        let download = f.descriptor("unverified")

        let outcome = try await controller.prepareAvailableLocalArtifact(download: download)

        XCTAssertEqual(outcome, .unavailable)
        XCTAssertFalse(download.isReadyForImmediateLocalRead())
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0)
    }

    @MainActor
    func testAbsentLocalPreparationDoesNotRequestHTTPOrSuppressLaterDownload() async throws {
        let f = try fixture(observeLocalRequests: true)
        let download = f.descriptor("absent")
        download.shouldCheckForUpdates = true
        let transfers = ReplayCounter()
        let controller = f.controller { download, _ in
            _ = await transfers.next()
            return try Self.transfer(download, text: "subsequently downloaded")
        }

        let outcome = try await controller.prepareAvailableLocalArtifact(download: download)

        XCTAssertEqual(outcome, .unavailable)
        XCTAssertFalse(download.isFinishedProcessing)
        XCTAssertFalse(controller.assuredDownloads.contains(download))
        let before = await transfers.count
        XCTAssertEqual(before, 0)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0)

        await controller.ensureDownloaded(download: download)
        let after = await transfers.count
        XCTAssertEqual(after, 1)
        XCTAssertTrue(download.isReadyForImmediateLocalRead())
    }

    @MainActor
    func testCorruptPinnedLocalPreparationNeverRecoversRemotelyAndNormalRecoveryStillWorks() async throws {
        let f = try fixture(observeLocalRequests: true)
        let payload = Data("repaired".utf8)
        try Data("corrupt".utf8).write(to: f.destination)
        let download = f.descriptor("corrupt", checksum: Self.checksum(payload))
        download.shouldCheckForUpdates = true
        let transfers = ReplayCounter()
        let controller = f.controller { download, _ in
            _ = await transfers.next()
            return try Self.transfer(download, text: "repaired")
        }

        let outcome = try await controller.prepareAvailableLocalArtifact(download: download)

        XCTAssertEqual(outcome, .unavailable)
        XCTAssertFalse(download.isReadyForImmediateLocalRead())
        XCTAssertFalse(controller.assuredDownloads.contains(download))
        let before = await transfers.count
        XCTAssertEqual(before, 0)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0)

        await controller.ensureDownloaded(download: download)
        let after = await transfers.count
        XCTAssertEqual(after, 1)
        XCTAssertFalse(download.isFailed)
        XCTAssertTrue(download.isReadyForImmediateLocalRead())
        XCTAssertEqual(try Data(contentsOf: f.destination), payload)
    }

    @MainActor
    func testLocalPreparationDoesNotJoinExistingTransferIncludingCompatibleReplay() async throws {
        let f = try fixture(observeLocalRequests: true)
        let gate = ReplayGate()
        let entered = expectation(description: "remote transfer entered")
        let controller = f.controller { download, _ in
            entered.fulfill()
            await gate.wait()
            return try Self.transfer(download, text: "remote result")
        }
        let owner = f.descriptor("owner")
        let remote = Task { await controller.download(owner) }
        await fulfillment(of: [entered], timeout: 2)
        let returned = expectation(description: "local requests do not await remote gate")
        let local = Task {
            let native = try await controller.verifiedLocalArtifactAvailability(download: owner)
            let nativeReplay = try await controller.verifiedLocalArtifactAvailability(download: f.descriptor("native replay"))
            XCTAssertEqual(native, .busy)
            XCTAssertEqual(nativeReplay, .busy)
            let direct = try await controller.prepareAvailableLocalArtifact(download: owner)
            let replay = try await controller.prepareAvailableLocalArtifact(download: f.descriptor("replay"))
            XCTAssertEqual(direct, .busy)
            XCTAssertEqual(replay, .busy)
            returned.fulfill()
        }
        let status = await XCTWaiter.fulfillment(of: [returned], timeout: 2)
        // Always release the producer, including when the local request regresses.
        await gate.open()
        await remote.value
        try await local.value
        XCTAssertEqual(status, .completed)
        XCTAssertTrue(owner.isReadyForImmediateLocalRead())
    }

    @MainActor
    func testLocalPreparationCancellationDrainsImporterAndAllowsRetry() async throws {
        let f = try fixture(observeLocalRequests: true)
        let payload = Data("local import".utf8)
        try payload.write(to: f.destination)
        let gate = ReplayGate()
        let imported = ReplayCounter()
        let entered = expectation(description: "local importer entered")
        entered.assertForOverFulfill = false
        let download = ImportableDownloadable(
            url: f.source, name: "local import", localDestination: f.destination,
            localDestinationChecksum: Self.checksum(payload), deleteAfterImport: false,
            metadataStore: f.store,
            isImported: { await imported.count > 0 },
            importHandler: { _, _ in
                entered.fulfill()
                await gate.wait()
                try Task.checkCancellation()
                _ = await imported.next()
            }
        )
        let controller = f.controller { _, _ in throw URLError(.notConnectedToInternet) }
        let returned = expectation(description: "canceled owner waits for importer cleanup")
        returned.isInverted = true
        let local = Task {
            defer { returned.fulfill() }
            return try await controller.prepareAvailableLocalArtifact(download: download)
        }
        await fulfillment(of: [entered], timeout: 2)
        local.cancel()
        await fulfillment(of: [returned], timeout: 0.1)
        await gate.open()
        do {
            _ = try await local.value
            XCTFail("Canceled local preparation must throw")
        } catch { XCTAssertTrue(error is CancellationError) }

        let retry = try await controller.prepareAvailableLocalArtifact(download: download)
        XCTAssertEqual(retry, .available)
        XCTAssertFalse(download.isFailed)
        XCTAssertTrue(download.isReadyForImmediateLocalRead())
        let completedImports = await imported.count
        XCTAssertEqual(completedImports, 1)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0)
    }

    @MainActor
    func testLocalPreparationSharesProcessorAndCanceledWaiterDoesNotCancelOwner() async throws {
        let f = try fixture(observeLocalRequests: true)
        let payload = Data("shared local import".utf8)
        try payload.write(to: f.destination)
        let gate = ReplayGate()
        let imports = ReplayCounter()
        let completed = ReplayCounter()
        let entered = expectation(description: "shared importer entered")
        entered.assertForOverFulfill = false
        let handler: ImportableDownloadable.ImportHandler = { _, _ in
            _ = await imports.next()
            entered.fulfill()
            await gate.wait()
            try Task.checkCancellation()
            _ = await completed.next()
        }
        func descriptor(_ name: String) -> ImportableDownloadable {
            ImportableDownloadable(
                url: f.source, name: name, localDestination: f.destination,
                localDestinationChecksum: Self.checksum(payload), deleteAfterImport: false,
                metadataStore: f.store,
                isImported: { await completed.count > 0 }, importHandler: handler
            )
        }
        let download = descriptor("owner")
        let replay = descriptor("local waiter")
        let controller = f.controller { _, _ in throw URLError(.notConnectedToInternet) }
        let owner = Task { try await controller.prepareAvailableLocalArtifact(download: download) }
        await fulfillment(of: [entered], timeout: 2)
        let nativeWhileProcessing = try await controller.verifiedLocalArtifactAvailability(download: replay)
        XCTAssertEqual(nativeWhileProcessing, .unavailable)
        let returned = expectation(description: "local waiter waits for shared processor")
        returned.isInverted = true
        let canceled = expectation(description: "local waiter cancellation returns independently")
        let waiter = Task {
            defer { returned.fulfill(); canceled.fulfill() }
            return try await controller.prepareAvailableLocalArtifact(download: replay)
        }
        await fulfillment(of: [returned], timeout: 0.1)
        waiter.cancel()
        let cancellationStatus = await XCTWaiter.fulfillment(of: [canceled], timeout: 2)
        await gate.open()
        do {
            _ = try await waiter.value
            XCTFail("Canceled waiter must throw")
        } catch { XCTAssertTrue(error is CancellationError) }
        let outcome = try await owner.value

        XCTAssertEqual(cancellationStatus, .completed)
        XCTAssertEqual(outcome, .available)
        let count = await imports.count
        XCTAssertEqual(count, 1)
        XCTAssertFalse(download.isFailed)
        let replayOutcome = try await controller.prepareAvailableLocalArtifact(download: replay)
        XCTAssertEqual(replayOutcome, .available)
        XCTAssertTrue(replay.isFinishedProcessing)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0)
    }

    @MainActor
    private func assertOrdinaryAssuranceContinuesAfterLocalPreparation(
        usesReplay: Bool, localImportFails: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let f = try fixture(observeLocalRequests: true)
        let payload = Data("handoff dictionary".utf8)
        LocalPreparationURLProtocol.requests.respond(to: f.source, payload: payload, etag: "installed")
        let gate = ReplayGate()
        let imports = ReplayCounter()
        let failures = ReplayCounter()
        let state = ReplayImportState()
        let entered = expectation(description: "local importer owns destination")
        let handler: ImportableDownloadable.ImportHandler = { candidate, _ in
            let attempt = await imports.next()
            if attempt == (localImportFails ? 1 : 2) {
                entered.fulfill()
                await gate.wait()
                if localImportFails {
                    // Importers may mutate their input. Leave invalid pinned
                    // bytes so ordinary assurance must acquire a replacement.
                    try Data("invalidated by failed importer".utf8).write(to: candidate, options: .atomic)
                    _ = await failures.next()
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
            await state.setImported(true)
        }
        func descriptor(_ name: String) -> ImportableDownloadable {
            let download = ImportableDownloadable(
                url: f.source, name: name, localDestination: f.destination,
                localDestinationChecksum: localImportFails ? Self.checksum(payload) : nil,
                deleteAfterImport: false, importOperationIdentifier: "local-assurance-handoff",
                metadataStore: f.store,
                isImported: { await state.isImported }, importHandler: handler
            )
            download.shouldCheckForUpdates = true
            return download
        }
        let owner = descriptor("local owner")
        let controller = DownloadController(session: f.session)
        if localImportFails {
            try payload.write(to: f.destination)
        } else {
            // Establish an authentic unpinned receipt through the actual GET path,
            // then require a derived import and an overdue remote freshness check.
            await controller.download(owner)
            XCTAssertTrue(owner.isReadyForImmediateLocalRead(), file: file, line: line)
            owner.lastCheckedETagAt = Date(timeIntervalSinceNow: -3 * 60 * 60)
            await state.setImported(false)
        }
        let local = Task { try await controller.prepareAvailableLocalArtifact(download: owner) }
        await fulfillment(of: [entered], timeout: 2)
        let ordinaryDescriptor = usesReplay ? descriptor("ordinary replay") : owner
        let returned = expectation(description: "ordinary assurance waits for local producer")
        returned.isInverted = true
        let ordinary = Task {
            await controller.ensureDownloaded(download: ordinaryDescriptor)
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 0.1)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source, method: "HEAD"), 0,
                       file: file, line: line)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source, method: "GET"),
                       localImportFails ? 0 : 1, file: file, line: line)
        await gate.open()
        _ = try await local.value
        await ordinary.value

        let failureCount = await failures.count
        XCTAssertEqual(failureCount, localImportFails ? 1 : 0, file: file, line: line)
        let importCount = await imports.count
        XCTAssertEqual(importCount, 2, file: file, line: line)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source, method: "GET"), 1,
                       file: file, line: line)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source, method: "HEAD"),
                       localImportFails ? 0 : 1, file: file, line: line)
        XCTAssertTrue(ordinaryDescriptor.isFinishedProcessing, file: file, line: line)
        XCTAssertFalse(ordinaryDescriptor.isFailed, file: file, line: line)
        XCTAssertTrue(ordinaryDescriptor.isReadyForImmediateLocalRead(), file: file, line: line)
        if !localImportFails {
            XCTAssertGreaterThan(try XCTUnwrap(owner.lastCheckedETagAt),
                                 Date(timeIntervalSinceNow: -60), file: file, line: line)
        }
    }

    @MainActor
    func testOrdinaryOwnerAssuranceChecksOverdueUpdateAfterJoiningLocalPreparation() async throws {
        try await assertOrdinaryAssuranceContinuesAfterLocalPreparation(usesReplay: false, localImportFails: false)
    }

    @MainActor
    func testOrdinaryReplayAssuranceChecksOverdueUpdateAfterJoiningLocalPreparation() async throws {
        try await assertOrdinaryAssuranceContinuesAfterLocalPreparation(usesReplay: true, localImportFails: false)
    }

    @MainActor
    func testOrdinaryOwnerAssuranceAcquiresAfterJoiningFailedLocalPreparation() async throws {
        try await assertOrdinaryAssuranceContinuesAfterLocalPreparation(usesReplay: false, localImportFails: true)
    }

    @MainActor
    func testOrdinaryReplayAssuranceAcquiresAfterJoiningFailedLocalPreparation() async throws {
        try await assertOrdinaryAssuranceContinuesAfterLocalPreparation(usesReplay: true, localImportFails: true)
    }

    @MainActor
    func testCanceledLocalCompressedImportRetainsOriginalInputForOfflineRetry() async throws {
        let f = try fixture(observeLocalRequests: true)
        let payload = Data("retained offline compressed dictionary".utf8)
        let compressed = try XCTUnwrap((payload as NSData).brotliCompressed())
        let gate = ReplayGate()
        let imported = ReplayImportState()
        let entered = expectation(description: "compressed local import holds staged bytes")
        entered.assertForOverFulfill = false
        let download = ImportableDownloadable(
            url: f.source.appendingPathExtension("br"), name: "offline compressed import",
            localDestination: f.destination, localDestinationChecksum: Self.checksum(payload),
            deleteAfterImport: false, metadataStore: f.store,
            isImported: { await imported.isImported },
            importHandler: { candidate, _ in
                XCTAssertEqual(try Data(contentsOf: candidate), payload)
                entered.fulfill()
                await gate.wait()
                try Task.checkCancellation()
                await imported.setImported(true)
            }
        )
        try compressed.write(to: download.compressedFileURL)
        let controller = DownloadController(session: f.session)
        let local = Task { try await controller.prepareAvailableLocalArtifact(download: download) }
        await fulfillment(of: [entered], timeout: 2)
        local.cancel()
        await gate.open()
        do {
            _ = try await local.value
            XCTFail("Canceled local processor must drain and throw")
        } catch { XCTAssertTrue(error is CancellationError) }

        XCTAssertEqual(try Data(contentsOf: download.compressedFileURL), compressed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.path))
        let stagedAfterCancellation = try FileManager.default.contentsOfDirectory(
            at: f.root, includingPropertiesForKeys: nil
        )
        XCTAssertEqual(Set(stagedAfterCancellation.map { $0.resolvingSymlinksInPath() }),
                       Set([download.compressedFileURL.resolvingSymlinksInPath()]),
                       "Only the retained input survives; attempt-owned staging is removed")
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(download.url), 0)

        let outcome = try await controller.prepareAvailableLocalArtifact(download: download)

        XCTAssertEqual(outcome, .available)
        XCTAssertEqual(try Data(contentsOf: f.destination), payload)
        XCTAssertTrue(download.isReadyForImmediateLocalRead())
        XCTAssertTrue(download.isFinishedProcessing, "Compressed processing retains ordinary publication")
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.compressedFileURL.path))
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(download.url), 0)
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
    func testOrdinaryStartupAssuranceReusesVerifiedPinnedReceiptOffline() async throws {
        let f = try fixture(observeLocalRequests: true)
        let payload = Data("retained startup dictionary".utf8)
        try payload.write(to: f.destination)
        let checksum = Self.checksum(payload)
        let installed = f.descriptor("installed dictionary", checksum: checksum)
        let seed = f.controller { _, _ in throw URLError(.badURL) }
        await seed.finishDownload(
            installed, etag: "retained-etag",
            remoteModifiedAt: Date(timeIntervalSince1970: 1234),
            finalResponseURL: f.source, updatesRemoteModifiedAt: true
        )
        let original = try XCTUnwrap(f.store.installedArtifactReceipt(
            sourceURL: f.source, destinationURL: f.destination
        ))
        let downloadedAt = installed.lastDownloaded
        let modifiedAt = installed.lastModifiedAt
        let checkedAt = installed.lastCheckedETagAt
        // A new process's descriptor starts without completion UI state, while
        // its retained bytes, verification marker and receipt remain on disk.
        let restored = f.descriptor("restored dictionary", checksum: checksum)
        XCTAssertFalse(restored.isFinishedProcessing)
        let controller = f.controller { _, _ in
            XCTFail("Retained startup assurance must stay offline")
            throw URLError(.notConnectedToInternet)
        }
        let capture = LocalPreparationStageCapture()
        await DownloadController.$localPreparationStageObserver.withValue({ capture.append($0) }) {
            await controller.ensureDownloaded(download: restored)
        }
        XCTAssertEqual(capture.snapshot().filter { $0 == .hashingInstalledArtifact }.count, 0)
        XCTAssertFalse(restored.isFailed)
        XCTAssertTrue(restored.isFinishedDownloading)
        XCTAssertTrue(restored.isFinishedProcessing)
        XCTAssertTrue(controller.finishedDownloads.contains(restored))
        XCTAssertEqual(restored.fileSize, UInt64(payload.count))
        XCTAssertEqual(restored.lastDownloaded, downloadedAt)
        XCTAssertEqual(restored.lastDownloadedETag, "retained-etag")
        XCTAssertEqual(restored.lastModifiedAt, modifiedAt)
        XCTAssertEqual(restored.lastCheckedETagAt, checkedAt)
        guard case let .completed(destination, etag, error) = restored.downloadProgress else {
            return XCTFail("Initial ordinary assurance must publish completion")
        }
        XCTAssertEqual(destination, f.destination)
        XCTAssertEqual(etag, "retained-etag")
        XCTAssertNil(error)
        XCTAssertEqual(try f.store.installedArtifactReceipt(
            sourceURL: f.source, destinationURL: f.destination
        ), original)
        XCTAssertEqual(try Data(contentsOf: f.destination), payload)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0)
    }

    @MainActor
    func testRetainedPinnedFinishPreservesExplicitResponseURLUpdate() async throws {
        let f = try fixture(observeLocalRequests: true)
        let payload = Data("retained pinned bytes with updated response metadata".utf8)
        try payload.write(to: f.destination)
        let checksum = Self.checksum(payload)
        let installed = f.descriptor("installed", checksum: checksum)
        await f.controller { _, _ in throw URLError(.badURL) }
            .finishDownload(installed, finalResponseURL: f.source)
        let installedAt = installed.lastDownloaded
        let restored = f.descriptor("restored", checksum: checksum)
        let responseURL = URL(string: "https://cdn.invalid/retained-dictionary")!
        let controller = f.controller { _, _ in
            XCTFail("Updating retained receipt metadata must stay offline")
            throw URLError(.notConnectedToInternet)
        }
        await controller.finishDownload(
            restored, finalResponseURL: responseURL,
            recordSuccessfulDownload: false
        )
        let receipt = try XCTUnwrap(f.store.installedArtifactReceipt(
            sourceURL: f.source, destinationURL: f.destination
        ))
        XCTAssertEqual(receipt.finalResponseURL, responseURL)
        XCTAssertEqual(restored.lastDownloaded, installedAt)
        XCTAssertTrue(restored.isFinishedProcessing)
        XCTAssertFalse(restored.isFailed)
        XCTAssertEqual(try Data(contentsOf: f.destination), payload)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0)
    }

    @MainActor
    func testOrdinaryStartupAssuranceRequiresPinnedMarkerAndBoundReceipt() async throws {
        for invalidation in ["missing-marker", "corrupt-marker", "missing-receipt", "unbound-receipt", "replacement"] {
            let f = try fixture(observeLocalRequests: true)
            let payload = Data("retained dictionary requiring full preparation".utf8)
            try payload.write(to: f.destination)
            let checksum = Self.checksum(payload)
            let installed = f.descriptor("installed", checksum: checksum)
            await f.controller { _, _ in throw URLError(.badURL) }.finishDownload(installed)
            let original = try XCTUnwrap(f.store.installedArtifactReceipt(
                sourceURL: f.source, destinationURL: f.destination
            ))
            switch invalidation {
            case "missing-marker":
                try FileManager.default.removeItem(at: installed.checksumVerificationMarkerURL)
            case "corrupt-marker":
                try Data("invalid marker".utf8).write(to: installed.checksumVerificationMarkerURL)
            case "missing-receipt":
                try installed.removeInstalledArtifactReceipt()
            case "unbound-receipt":
                let unbound = InstalledArtifactReceipt(
                    requestedSourceURL: URL(string: "https://other.invalid/dictionary")!,
                    finalResponseURL: original.finalResponseURL,
                    destinationURL: original.destinationURL,
                    sha256Digest: original.sha256Digest, byteCount: original.byteCount,
                    modificationTimeIntervalSince1970: original.modificationTimeIntervalSince1970,
                    fileSystemNumber: original.fileSystemNumber,
                    fileSystemFileNumber: original.fileSystemFileNumber
                )
                try installed.persistInstalledArtifactReceipt(unbound)
            default:
                try payload.write(to: f.destination, options: .atomic)
            }
            let restored = f.descriptor("restored", checksum: checksum)
            let controller = f.controller { _, _ in
                XCTFail("Valid retained pinned bytes must stay offline: \(invalidation)")
                throw URLError(.notConnectedToInternet)
            }
            let capture = LocalPreparationStageCapture()
            await DownloadController.$localPreparationStageObserver.withValue({ capture.append($0) }) {
                await controller.ensureDownloaded(download: restored)
            }
            XCTAssertEqual(capture.snapshot().filter { $0 == .hashingInstalledArtifact }.count, 1, invalidation)
            XCTAssertFalse(restored.isFailed, invalidation)
            XCTAssertTrue(restored.isFinishedProcessing, invalidation)
            XCTAssertTrue(restored.hasVerifiedLocalDestinationChecksumMarker(), invalidation)
            XCTAssertNotNil(restored.validInstalledArtifactReceipt(), invalidation)
            XCTAssertEqual(try Data(contentsOf: f.destination), payload, invalidation)
            XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0, invalidation)
        }
    }

    @MainActor
    func testOrdinaryStartupAssuranceRejectsReplacedPinnedBytes() async throws {
        let f = try fixture(observeLocalRequests: true)
        let payload = Data("original pinned dictionary".utf8)
        try payload.write(to: f.destination)
        let checksum = Self.checksum(payload)
        let installed = f.descriptor("installed", checksum: checksum)
        await f.controller { _, _ in throw URLError(.badURL) }.finishDownload(installed)
        let originalDate = installed.lastDownloaded
        try Data("replaced corrupt dictionary".utf8).write(to: f.destination, options: .atomic)
        let restored = f.descriptor("restored", checksum: checksum)
        XCTAssertFalse(restored.hasVerifiedLocalDestinationChecksumMarker())
        let transfers = ReplayCounter()
        let controller = f.controller { _, _ in
            _ = await transfers.next()
            throw URLError(.notConnectedToInternet)
        }
        await controller.ensureDownloaded(download: restored)
        XCTAssertTrue(restored.isFailed)
        XCTAssertFalse(restored.isFinishedDownloading)
        XCTAssertFalse(controller.finishedDownloads.contains(restored))
        XCTAssertEqual(restored.lastDownloaded, originalDate)
        let attempts = await transfers.count
        XCTAssertEqual(attempts, 1, "Changed bytes must enter ordinary checksum recovery")
    }

    @MainActor
    func testOrdinaryStartupAssuranceStillHashesUnpinnedReceipt() async throws {
        let f = try fixture(observeLocalRequests: true)
        let payload = Data("unpinned retained dictionary".utf8)
        try payload.write(to: f.destination)
        await f.controller { _, _ in throw URLError(.badURL) }
            .finishDownload(f.descriptor("installed"))
        let original = try XCTUnwrap(f.store.installedArtifactReceipt(
            sourceURL: f.source, destinationURL: f.destination
        ))
        let restored = f.descriptor("restored")
        let controller = f.controller { _, _ in
            XCTFail("Valid unpinned receipt must stay offline")
            throw URLError(.notConnectedToInternet)
        }
        let capture = LocalPreparationStageCapture()
        await DownloadController.$localPreparationStageObserver.withValue({ capture.append($0) }) {
            await controller.ensureDownloaded(download: restored)
        }
        XCTAssertGreaterThan(capture.snapshot().filter { $0 == .hashingInstalledArtifact }.count, 0)
        XCTAssertFalse(restored.isFailed)
        XCTAssertTrue(restored.isFinishedProcessing)
        XCTAssertEqual(try f.store.installedArtifactReceipt(
            sourceURL: f.source, destinationURL: f.destination
        ), original)
        XCTAssertEqual(LocalPreparationURLProtocol.requests.count(f.source), 0)
    }

    @MainActor
    func testPinnedMarkerDoesNotCertifyStoredReceiptDigest() async throws {
        let f = try fixture()
        let payload = Data("independently pinned bytes".utf8)
        try payload.write(to: f.destination)
        let download = f.descriptor("pinned", checksum: Self.checksum(payload))
        try download.ensureVerifiedLocalDestinationChecksum()
        let receipt = try download.makeInstalledArtifactReceipt(finalResponseURL: f.source)
        let forged = InstalledArtifactReceipt(
            requestedSourceURL: receipt.requestedSourceURL, finalResponseURL: receipt.finalResponseURL,
            destinationURL: receipt.destinationURL, sha256Digest: String(repeating: "0", count: 64),
            byteCount: receipt.byteCount, modificationTimeIntervalSince1970: receipt.modificationTimeIntervalSince1970,
            fileSystemNumber: receipt.fileSystemNumber, fileSystemFileNumber: receipt.fileSystemFileNumber
        )
        try download.persistInstalledArtifactReceipt(forged)
        XCTAssertTrue(download.hasVerifiedLocalDestinationChecksumMarker())
        XCTAssertFalse(download.installedArtifactMatches(forged))
        XCTAssertNil(download.validInstalledArtifactReceipt(),
                     "Pinned readiness must not weaken the full SHA256 receipt-validation API")
    }

    @MainActor
    func testFinishReusesVerifiedReceiptForUnchangedPlainFile() async throws {
        let originalURL = URL(string: "https://cdn.invalid/original.txt")!
        let updatedURL = URL(string: "https://cdn.invalid/updated.txt")!
        for finalURL in [nil, updatedURL] as [URL?] {
            let f = try fixture()
            let payload = Data("retained plain file".utf8)
            try payload.write(to: f.destination)
            let seedController = f.controller { _, _ in throw URLError(.badURL) }
            await seedController.finishDownload(f.descriptor("seed"), finalResponseURL: originalURL)
            let original = try XCTUnwrap(f.store.installedArtifactReceipt(
                sourceURL: f.source, destinationURL: f.destination
            ))
            let download = f.descriptor("retained")
            let controller = f.controller { _, _ in
                XCTFail("Finishing retained bytes must not acquire a replacement")
                throw URLError(.badURL)
            }
            let capture = LocalPreparationStageCapture()
            await DownloadController.$localPreparationStageObserver.withValue({ capture.append($0) }) {
                await controller.finishDownload(download, etag: "retained", finalResponseURL: finalURL)
            }

            XCTAssertEqual(capture.snapshot().filter { $0 == .hashingInstalledArtifact }.count, 1,
                           "Validate stored proof fully once, then reuse it within this finish")
            XCTAssertFalse(download.isFailed)
            XCTAssertTrue(download.isFinishedProcessing)
            XCTAssertEqual(download.lastDownloadedETag, "retained")
            let receipt = try XCTUnwrap(f.store.installedArtifactReceipt(
                sourceURL: f.source, destinationURL: f.destination
            ))
            XCTAssertEqual(receipt.schemaVersion, original.schemaVersion)
            XCTAssertEqual(receipt.sha256Digest, original.sha256Digest)
            XCTAssertEqual(receipt.byteCount, original.byteCount)
            XCTAssertEqual(receipt.modificationTimeIntervalSince1970, original.modificationTimeIntervalSince1970)
            XCTAssertEqual(receipt.fileSystemFileNumber, original.fileSystemFileNumber)
            XCTAssertEqual(receipt.fileSystemNumber, original.fileSystemNumber)
            XCTAssertEqual(receipt.requestedSourceURL, original.requestedSourceURL)
            XCTAssertEqual(receipt.destinationURL, original.destinationURL)
            XCTAssertEqual(receipt.finalResponseURL, finalURL ?? originalURL)
            XCTAssertEqual(try Data(contentsOf: f.destination), payload)
        }
    }

    @MainActor
    func testFinishReusesVerifiedReceiptWithoutRecordingAnotherDownload() async throws {
        let f = try fixture()
        try Data("already installed".utf8).write(to: f.destination)
        let download = f.descriptor("installed")
        let controller = f.controller { _, _ in throw URLError(.badURL) }
        await controller.finishDownload(download, finalResponseURL: f.source)
        let original = try XCTUnwrap(f.store.installedArtifactReceipt(
            sourceURL: f.source, destinationURL: f.destination
        ))
        let downloadedAt = download.lastDownloaded
        let capture = LocalPreparationStageCapture()
        await DownloadController.$localPreparationStageObserver.withValue({ capture.append($0) }) {
            await controller.finishDownload(download, recordSuccessfulDownload: false)
        }
        XCTAssertEqual(capture.snapshot().filter { $0 == .hashingInstalledArtifact }.count, 1)
        XCTAssertFalse(download.isFailed)
        XCTAssertTrue(download.isFinishedProcessing)
        XCTAssertEqual(download.lastDownloaded, downloadedAt)
        XCTAssertEqual(try f.store.installedArtifactReceipt(
            sourceURL: f.source, destinationURL: f.destination
        ), original)
    }

    @MainActor
    func testFinishRejectsReceiptReplacedDuringSuspendedImportCheck() async throws {
        let f = try fixture()
        let originalPayload = Data("original contents".utf8)
        let replacement = Data("replaced contents".utf8)
        try originalPayload.write(to: f.destination)
        let seedController = f.controller { _, _ in throw URLError(.badURL) }
        await seedController.finishDownload(f.descriptor("seed"))
        let original = try XCTUnwrap(f.store.installedArtifactReceipt(
            sourceURL: f.source, destinationURL: f.destination
        ))
        let gate = ReplayGate()
        let entered = expectation(description: "receipt validated before import-state suspension")
        let destination = f.destination
        let download = ImportableDownloadable(
            url: f.source, name: "suspended check", localDestination: destination,
            deleteAfterImport: false, metadataStore: f.store,
            isImported: {
                entered.fulfill()
                await gate.wait()
                do {
                    try replacement.write(to: destination, options: .atomic)
                    // Preserve length and mtime: the replacement inode must
                    // invalidate the operation's previously verified facts.
                    try FileManager.default.setAttributes([
                        .modificationDate: Date(timeIntervalSince1970: original.modificationTimeIntervalSince1970)
                    ], ofItemAtPath: destination.path)
                } catch { XCTFail("Could not replace retained input: \(error)") }
                return true
            },
            importHandler: { _, _ in XCTFail("A replaced receipt cannot admit an import") }
        )
        let controller = f.controller { _, _ in throw URLError(.badURL) }
        let capture = LocalPreparationStageCapture()
        let finish = Task {
            await DownloadController.$localPreparationStageObserver.withValue({ capture.append($0) }) {
                await controller.finishDownload(download, recordSuccessfulDownload: false)
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(capture.snapshot().filter { $0 == .hashingInstalledArtifact }.count, 1)
        await gate.open()
        await finish.value
        XCTAssertTrue(download.isFailed)
        XCTAssertFalse(controller.finishedDownloads.contains(download))
        XCTAssertEqual(try Data(contentsOf: destination), replacement)
        XCTAssertNil(try f.store.installedArtifactReceipt(sourceURL: f.source, destinationURL: destination))
        XCTAssertFalse(download.isReadyForImmediateLocalRead())
    }

    @MainActor
    private func assertFinishRehashesAfterSuspendedImporter(replacingSource: Bool) async throws {
        let f = try fixture()
        let payload = Data("original contents".utf8)
        let replacement = Data("replaced contents".utf8)
        let originalURL = URL(string: "https://cdn.invalid/import-source.txt")!
        try payload.write(to: f.destination)
        let seedController = f.controller { _, _ in throw URLError(.badURL) }
        await seedController.finishDownload(f.descriptor("seed"), finalResponseURL: originalURL)
        let original = try XCTUnwrap(f.store.installedArtifactReceipt(
            sourceURL: f.source, destinationURL: f.destination
        ))
        let gate = ReplayGate()
        let entered = expectation(description: "importer suspended after initial byte validation")
        let imported = ReplayImportState()
        let download = ImportableDownloadable(
            url: f.source, name: "suspended importer", localDestination: f.destination,
            deleteAfterImport: false, metadataStore: f.store,
            isImported: { await imported.isImported },
            importHandler: { input, _ in
                entered.fulfill()
                await gate.wait()
                if replacingSource {
                    try replacement.write(to: input, options: .atomic)
                    try FileManager.default.setAttributes([
                        .modificationDate: Date(timeIntervalSince1970: original.modificationTimeIntervalSince1970)
                    ], ofItemAtPath: input.path)
                }
                await imported.setImported(true)
            }
        )
        let controller = f.controller { _, _ in throw URLError(.badURL) }
        let capture = LocalPreparationStageCapture()
        let finish = Task {
            await DownloadController.$localPreparationStageObserver.withValue({ capture.append($0) }) {
                await controller.finishDownload(download)
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(capture.snapshot().filter { $0 == .hashingInstalledArtifact }.count, 1)
        await gate.open()
        await finish.value
        XCTAssertEqual(capture.snapshot().filter { $0 == .hashingInstalledArtifact }.count, 2,
                       "An importer must earn fresh byte proof even when its input is unchanged")
        XCTAssertFalse(download.isFailed)
        XCTAssertTrue(download.isFinishedProcessing)
        let receipt = try XCTUnwrap(f.store.installedArtifactReceipt(
            sourceURL: f.source, destinationURL: f.destination
        ))
        let expectedPayload = replacingSource ? replacement : payload
        let expectedDigest = SHA256.hash(data: expectedPayload).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(receipt.sha256Digest, expectedDigest)
        XCTAssertEqual(receipt.finalResponseURL, originalURL)
        XCTAssertEqual(try Data(contentsOf: f.destination), expectedPayload)
        XCTAssertTrue(download.isReadyForImmediateLocalRead())
        if replacingSource {
            XCTAssertNotEqual(receipt.fileSystemFileNumber, original.fileSystemFileNumber)
            XCTAssertFalse(download.installedArtifactMatches(original))
        } else {
            XCTAssertEqual(receipt, original)
        }
    }

    @MainActor
    func testFinishRehashesUnchangedInputAfterSuspendedImporter() async throws {
        try await assertFinishRehashesAfterSuspendedImporter(replacingSource: false)
    }

    @MainActor
    func testFinishRehashesReplacementAfterSuspendedImporter() async throws {
        try await assertFinishRehashesAfterSuspendedImporter(replacingSource: true)
    }

    @MainActor
    func testStoredReceiptAlwaysRequiresFullSHA256Validation() async throws {
        let f = try fixture()
        try Data("untrusted stored proof".utf8).write(to: f.destination)
        let download = f.descriptor("untrusted")
        let receipt = try download.makeInstalledArtifactReceipt(finalResponseURL: f.source)
        let forged = InstalledArtifactReceipt(
            requestedSourceURL: receipt.requestedSourceURL, finalResponseURL: receipt.finalResponseURL,
            destinationURL: receipt.destinationURL, sha256Digest: String(repeating: "0", count: 64),
            byteCount: receipt.byteCount, modificationTimeIntervalSince1970: receipt.modificationTimeIntervalSince1970,
            fileSystemNumber: receipt.fileSystemNumber, fileSystemFileNumber: receipt.fileSystemFileNumber
        )
        // Every non-byte identity field matches the current file.
        try download.persistInstalledArtifactReceipt(forged)
        XCTAssertFalse(download.installedArtifactMatches(forged))
        XCTAssertNil(download.validInstalledArtifactReceipt())
        try download.persistInstalledArtifactReceipt(forged)
        let controller = f.controller { _, _ in throw URLError(.badURL) }
        let capture = LocalPreparationStageCapture()
        await DownloadController.$localPreparationStageObserver.withValue({ capture.append($0) }) {
            await controller.finishDownload(download, recordSuccessfulDownload: false)
        }
        XCTAssertEqual(capture.snapshot().filter { $0 == .hashingInstalledArtifact }.count, 1)
        XCTAssertTrue(download.isFailed)
        XCTAssertNil(try f.store.installedArtifactReceipt(sourceURL: f.source, destinationURL: f.destination))
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
        var completedStatuses = 0
        var completedProgress = 0
        var completedSets = 0
        let completionObservation = controller.$finishedDownloads.dropFirst()
            .filter { $0.contains(owner) }.sink { _ in completedSets += 1 }
        let statusObservation = owner.$isFinishedProcessing.dropFirst()
            .filter { $0 }.sink { _ in completedStatuses += 1 }
        let progressObservation = owner.$downloadProgress.dropFirst().sink { progress in
            if case .completed = progress { completedProgress += 1 }
        }
        defer {
            completionObservation.cancel()
            statusObservation.cancel()
            progressObservation.cancel()
        }
        try FileManager.default.removeItem(at: derived)
        let replay = descriptor("recreated")
        await runToCompletion { await controller.ensureDownloaded(download: replay) }
        let transferCount = await transfers.count
        let importCount = await imports.count
        XCTAssertEqual(transferCount, 1)
        XCTAssertEqual(importCount, 2)
        XCTAssertGreaterThan(completedSets, 0,
                             "Rebuilt content must reach controller completion consumers")
        XCTAssertGreaterThan(completedStatuses, 0,
                             "Rebuilt derived content must notify existing status consumers")
        XCTAssertGreaterThan(completedProgress, 0,
                             "Actual processing must retain completion progress publication")
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
