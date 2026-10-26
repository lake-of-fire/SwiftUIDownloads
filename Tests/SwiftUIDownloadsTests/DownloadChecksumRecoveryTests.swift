import CryptoKit
import Combine
import XCTest
import Brotli
@testable import SwiftUIDownloads

private func sha1Hex(_ data: Data) -> String {
    Insecure.SHA1.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
}

private final class CorruptUncompressedUpdateURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["ETag": "corrupt-update"]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Data("corrupt-update".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private enum TestImportError: Error {
    case rejectedCandidate
}

private final class RetryOwnershipRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [URL: Int] = [:]

    func record(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        counts[url, default: 0] += 1
    }

    func count(for url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[url, default: 0]
    }

    func remove(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        counts[url] = nil
    }
}

private final class RetryOwnershipURLProtocol: URLProtocol {
    static let requests = RetryOwnershipRequests()
    static let payload = Data("valid-independent-replacement".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.requests.record(url)
        let response = HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: nil, headerFields: ["ETag": "must-not-be-downloaded"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
private final class RetryReplacementWitness {
    weak var download: ImportableDownloadable?
    private(set) var receipt: InstalledArtifactReceipt?
    private(set) var marker: Data?
    private(set) var replacements = 0

    func install() {
        guard replacements == 0, let download else { return }
        do {
            try RetryOwnershipURLProtocol.payload.write(to: download.localDestination, options: .atomic)
            try download.ensureVerifiedLocalDestinationChecksum()
            let receipt = try download.makeInstalledArtifactReceipt(finalResponseURL: download.url)
            try download.persistInstalledArtifactReceipt(receipt)
            self.receipt = receipt
            marker = try Data(contentsOf: download.checksumVerificationMarkerURL)
            replacements += 1
        } catch {
            XCTFail("Unable to install independent replacement in actual callback: \(error)")
        }
    }
}

private actor RetainedImportGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor ChecksumRecoveryAttemptExecutor {
    private(set) var attemptCount = 0
    private let payload: Data

    init(payload: Data) {
        self.payload = payload
    }

    func execute(
        download: Downloadable,
        session _: URLSession
    ) async throws -> DownloadTransferResult {
        attemptCount += 1
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

    func recordedAttemptCount() -> Int {
        attemptCount
    }
}

private actor EmptyCompressedAttemptExecutor {
    func execute(
        download: Downloadable,
        session _: URLSession
    ) async throws -> DownloadTransferResult {
        let candidateURL = download.compressedTransferStagingURL(
            operationID: UUID()
        )
        try FileManager.default.createDirectory(
            at: candidateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: candidateURL, options: .atomic)
        await MainActor.run {
            download.downloadProgress = .completed(
                destinationLocation: candidateURL,
                etag: "empty-update",
                error: nil
            )
            download.isActive = false
            download.isFailed = false
            download.isFinishedDownloading = true
        }
        return DownloadTransferResult(
            destinationLocation: candidateURL,
            etag: "empty-update",
            lastModified: nil
        )
    }
}

private actor CompressedAttemptExecutor {
    private let compressedPayload: Data

    init(payload: Data) throws {
        guard let compressed = (payload as NSData).brotliCompressed() else {
            throw CocoaError(.fileWriteUnknown)
        }
        compressedPayload = compressed
    }

    func execute(
        download: Downloadable,
        session _: URLSession
    ) async throws -> DownloadTransferResult {
        let candidateURL = download.compressedTransferStagingURL(
            operationID: UUID()
        )
        try FileManager.default.createDirectory(
            at: candidateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try compressedPayload.write(to: candidateURL, options: .atomic)
        return DownloadTransferResult(
            destinationLocation: candidateURL,
            etag: "compressed-candidate",
            lastModified: Date(timeIntervalSince1970: 456)
        )
    }
}

private actor StagedUncompressedAttemptExecutor {
    private(set) var attemptCount = 0
    private let payload: Data

    init(payload: Data) {
        self.payload = payload
    }

    func execute(
        download: Downloadable,
        session _: URLSession
    ) async throws -> DownloadTransferResult {
        attemptCount += 1
        let candidateURL = download.uncompressedTransferStagingURL(
            operationID: UUID()
        )
        try FileManager.default.createDirectory(
            at: candidateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: candidateURL, options: .atomic)
        return DownloadTransferResult(
            destinationLocation: candidateURL,
            etag: "staged-candidate-\(attemptCount)",
            lastModified: nil
        )
    }

    func recordedAttemptCount() -> Int { attemptCount }
}

private actor SequencedCompressedAttemptExecutor {
    private(set) var attemptCount = 0
    private let compressedPayloads: [Data]

    private let cancelAfterAttempt: Int?

    init(payloads: [Data], cancelAfterAttempt: Int? = nil) throws {
        self.cancelAfterAttempt = cancelAfterAttempt
        compressedPayloads = try payloads.map { payload in
            guard let compressed = (payload as NSData).brotliCompressed() else {
                throw CocoaError(.fileWriteUnknown)
            }
            return compressed
        }
    }

    func execute(
        download: Downloadable,
        session _: URLSession
    ) async throws -> DownloadTransferResult {
        let index = min(attemptCount, compressedPayloads.count - 1)
        attemptCount += 1
        let candidateURL = download.compressedTransferStagingURL(
            operationID: UUID()
        )
        try FileManager.default.createDirectory(
            at: candidateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try compressedPayloads[index].write(
            to: candidateURL,
            options: .atomic
        )

        if attemptCount == cancelAfterAttempt {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return DownloadTransferResult(
            destinationLocation: candidateURL,
            etag: "compressed-candidate-\(attemptCount)",
            lastModified: nil
        )
    }

    func recordedAttemptCount() -> Int { attemptCount }
}

private actor AsyncCompletionFlag {
    private var completed = false

    func markCompleted() { completed = true }
    func value() -> Bool { completed }
}

final class DownloadChecksumRecoveryTests: XCTestCase {
    @MainActor
    func testFinishChecksumRetryRejectsStatusObserverReplacementAndSettles() async throws {
        try await exerciseChecksumRetryStatusReplacement(directRecovery: false)
    }

    @MainActor
    func testDirectChecksumRecoveryRejectsStatusObserverReplacementAndSettles() async throws {
        try await exerciseChecksumRetryStatusReplacement(directRecovery: true)
    }

    @MainActor
    func testEmptySourceImportedCallbackCannotTransferOwnershipToReplacement() async throws {
        for importedResult in [false, true] {
            try await exerciseChecksumRetryStatusReplacement(
                directRecovery: false, emptySourceImportedResult: importedResult)
        }
    }

    @MainActor
    func testUnchangedEmptyAndMissingSourcesStillPermitCleanRecovery() async throws {
        for mode in ["finish-empty", "direct-empty", "direct-missing", "finish-imported-empty"] {
            let alreadyImported = mode == "finish-imported-empty"
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("unchanged-recovery-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let suite = "unchanged-recovery-metadata-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = UserDefaultsDownloadableMetadataStore(userDefaults: defaults)
            let source = URL(string: "https://retry-ownership.test/\(UUID().uuidString)/payload.bin")!
            defer { RetryOwnershipURLProtocol.requests.remove(source) }
            let destination = directory.appendingPathComponent("payload.bin")
            if mode != "direct-missing" { try Data().write(to: destination, options: .atomic) }
            let imported = AsyncCompletionFlag()
            let download = ImportableDownloadable(
                url: source, name: "Unchanged Recovery", localDestination: destination,
                localDestinationChecksum: sha1Hex(RetryOwnershipURLProtocol.payload),
                deleteAfterImport: false, metadataStore: store, isImported: { alreadyImported }, importHandler: { file, _ in
                    XCTAssertEqual(try Data(contentsOf: file), RetryOwnershipURLProtocol.payload)
                    await imported.markCompleted()
                })
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [RetryOwnershipURLProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let controller = DownloadController(session: session)
            let exited = expectation(description: "Unchanged recovery settles: " + mode)
            let operation = Task {
                defer { exited.fulfill() }
                if mode.hasPrefix("finish-") {
                    await controller.finishDownload(download)
                } else {
                    await controller.recoverLocalChecksumFailure(for: download)
                }
            }
            let result = await XCTWaiter.fulfillment(of: [exited], timeout: 5)
            XCTAssertEqual(result, .completed, mode)
            if result != .completed {
                operation.cancel()
                await controller.cancelInProgressDownload(download)
                session.invalidateAndCancel()
            }
            await operation.value
            XCTAssertEqual(RetryOwnershipURLProtocol.requests.count(for: source), alreadyImported ? 0 : 1, mode)
            let importerRan = await imported.value()
            XCTAssertEqual(importerRan, !alreadyImported, mode)
            XCTAssertEqual(try Data(contentsOf: destination), alreadyImported ? Data() : RetryOwnershipURLProtocol.payload)
            if !alreadyImported {
                XCTAssertTrue(download.hasVerifiedLocalDestinationChecksumMarker(), mode)
            }
            XCTAssertTrue(download.isFinishedProcessing, mode)
            XCTAssertTrue(download.isFinishedDownloading, mode)
            XCTAssertFalse(download.isFailed, mode)
        }
    }

    @MainActor
    private func exerciseChecksumRetryStatusReplacement(
        directRecovery: Bool, emptySourceImportedResult: Bool? = nil
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("retry-status-ownership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "retry-status-metadata-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsDownloadableMetadataStore(userDefaults: defaults)
        let source = URL(string: "https://retry-ownership.test/\(UUID().uuidString)/payload.bin")!
        defer { RetryOwnershipURLProtocol.requests.remove(source) }
        let destination = directory.appendingPathComponent("payload.bin")
        try (emptySourceImportedResult == nil ? Data("corrupt-original-source".utf8) : Data())
            .write(to: destination, options: .atomic)
        let imported = AsyncCompletionFlag()
        let witness = RetryReplacementWitness()
        let download = ImportableDownloadable(
            url: source, name: "Retry Ownership", localDestination: destination,
            localDestinationChecksum: sha1Hex(RetryOwnershipURLProtocol.payload),
            deleteAfterImport: true, metadataStore: store,
            isImported: {
                guard let emptySourceImportedResult else { return false }
                await witness.install()
                return emptySourceImportedResult
            }, importHandler: { _, _ in await imported.markCompleted() })
        witness.download = download
        await download.waitForDownloadMetadata()
        let baselineDate = Date(timeIntervalSince1970: 123)
        download.lastDownloaded = baselineDate
        download.lastDownloadedETag = "original-etag"
        try await download.waitForDownloadMetadataPersistence()

        let subscription = download.$importStatusText.sink { status in
            guard emptySourceImportedResult == nil, status == "Retrying download…" else { return }
            witness.install()
        }
        defer { subscription.cancel() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RetryOwnershipURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(session: session)
        let exited = expectation(description: "Checksum recovery settles after lost ownership")
        let operation = Task {
            defer { exited.fulfill() }
            if directRecovery {
                await controller.recoverLocalChecksumFailure(for: download)
            } else {
                await controller.finishDownload(download)
            }
        }
        // No throwing setup remains while the operation owns fixture resources.
        let result = await XCTWaiter.fulfillment(of: [exited], timeout: 5)
        XCTAssertEqual(result, .completed)
        if result != .completed {
            operation.cancel()
            await controller.cancelInProgressDownload(download)
            session.invalidateAndCancel()
        }
        await operation.value

        XCTAssertEqual(witness.replacements, 1, "The actual status/imported-state callback must exercise replacement")
        XCTAssertEqual(RetryOwnershipURLProtocol.requests.count(for: source), 0)
        let importerRan = await imported.value()
        XCTAssertFalse(importerRan)
        XCTAssertEqual(try Data(contentsOf: destination), RetryOwnershipURLProtocol.payload)
        XCTAssertNotNil(witness.marker)
        XCTAssertEqual(try Data(contentsOf: download.checksumVerificationMarkerURL), witness.marker)
        XCTAssertNotNil(witness.receipt)
        XCTAssertEqual(try store.installedArtifactReceipt(sourceURL: source, destinationURL: destination),
            witness.receipt)
        XCTAssertTrue(download.hasVerifiedLocalDestinationChecksumMarker())
        XCTAssertTrue(download.isFailed)
        XCTAssertFalse(download.isActive)
        XCTAssertFalse(download.isFinishedDownloading)
        XCTAssertTrue(download.isFinishedProcessing)
        XCTAssertFalse(controller.finishedDownloads.contains(download))
        XCTAssertEqual(download.lastDownloaded, baselineDate)
        XCTAssertEqual(download.lastDownloadedETag, "original-etag")
        let persisted = store.loadMetadata(sourceURL: source, destinationURL: destination)
        XCTAssertEqual(persisted.lastDownloadedAt, baselineDate)
        XCTAssertEqual(persisted.lastDownloadedETag, "original-etag")
        guard let error = download.lastImportError as? DownloadableChecksumVerificationError,
              case .fileChangedDuringVerification = error else {
            return XCTFail("Expected terminal ownership rejection, got \(String(describing: download.lastImportError))")
        }
        if download.isFailed || download.isFinishedProcessing {
            let succeeded = try await download.awaitCompletionOrFailure()
            XCTAssertFalse(succeeded)
        }
    }

    @MainActor
    func testImportStatusReplacementIsRejectedBeforeImporterDispatch() async throws {
        for checksum in [false, true] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("import-status-replacement-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let original = Data("verified-local-source".utf8)
            let replacement = Data("status-observer-replacement".utf8)
            let destination = directory.appendingPathComponent("payload.bin")
            try original.write(to: destination, options: .atomic)
            let imported = AsyncCompletionFlag()
            let download = ImportableDownloadable(
                url: destination, name: "Status Replacement", localDestination: destination,
                localDestinationChecksum: checksum ? sha1Hex(original) : nil,
                deleteAfterImport: true, isImported: { false },
                importHandler: { _, _ in await imported.markCompleted() })
            var replaced = false
            let subscription = download.$importStatusText.sink { status in
                guard status == "Importing…", !replaced else { return }
                do {
                    try replacement.write(to: destination, options: .atomic)
                    replaced = true
                } catch { XCTFail("Unable to replace source during actual status publication: \(error)") }
            }
            defer { subscription.cancel() }
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let controller = DownloadController(session: session)
            await controller.download(download)
            let importerRan = await imported.value()
            XCTAssertTrue(replaced, "The real Importing status observer must exercise the actor hop")
            XCTAssertFalse(importerRan, "A source replaced before dispatch has no import admission")
            XCTAssertTrue(download.isFailed)
            XCTAssertFalse(download.isFinishedDownloading)
            XCTAssertEqual(try Data(contentsOf: destination), replacement)
        }
    }

    func testRetainedImportCannotCertifyReplacementWithoutChecksum() async throws {
        try await exerciseRetainedImportReplacement(checksum: false, deleteAfterImport: false)
    }

    func testRetainedImportCannotCertifyReplacementWithChecksum() async throws {
        try await exerciseRetainedImportReplacement(checksum: true, deleteAfterImport: false)
    }

    func testRetainedImportCannotDeleteReplacement() async throws {
        for checksum in [false, true] {
            try await exerciseRetainedImportReplacement(checksum: checksum, deleteAfterImport: true)
        }
    }

    func testFailedRetainedImportPreservesReplacement() async throws {
        for deleteAfterImport in [false, true] {
            try await exerciseRetainedImportReplacement(checksum: false,
                deleteAfterImport: deleteAfterImport, outcome: .failure)
        }
    }

    func testCancelledRetainedImportPreservesReplacement() async throws {
        for deleteAfterImport in [false, true] {
            try await exerciseRetainedImportReplacement(checksum: false,
                deleteAfterImport: deleteAfterImport, outcome: .cancellation)
        }
    }

    func testUnchangedRetainedImportStillFinishesAndAppliesSourceRetention() async throws {
        for checksum in [false, true] {
            for deleteAfterImport in [false, true] {
                try await exerciseRetainedImportReplacement(checksum: checksum,
                    deleteAfterImport: deleteAfterImport, replacesSource: false)
            }
        }
    }

    private enum RetainedImportOutcome: Sendable { case success, failure, cancellation }

    private func exerciseRetainedImportReplacement(
        checksum: Bool, deleteAfterImport: Bool,
        outcome: RetainedImportOutcome = .success, replacesSource: Bool = true
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("retained-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "retained-import-metadata-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsDownloadableMetadataStore(userDefaults: defaults)
        let original = Data("original-local-import".utf8)
        let replacement = Data("replacement-local-source".utf8)
        let destination = directory.appendingPathComponent("payload.bin")
        try original.write(to: destination, options: .atomic)
        let importStarted = expectation(description: "Actual importer read the retained source")
        let gate = RetainedImportGate()
        let download = ImportableDownloadable(
            url: destination, name: "Retained Source", localDestination: destination,
            localDestinationChecksum: checksum ? sha1Hex(original) : nil,
            deleteAfterImport: deleteAfterImport, metadataStore: store,
            isImported: { false }, importHandler: { source, _ in
                XCTAssertEqual(try Data(contentsOf: source), original)
                importStarted.fulfill()
                await gate.wait()
                if case .failure = outcome { throw TestImportError.rejectedCandidate }
            })
        await download.waitForDownloadMetadata()
        let originalDownloadedAt = Date(timeIntervalSince1970: 123)
        await MainActor.run {
            download.lastDownloaded = originalDownloadedAt
            download.lastDownloadedETag = "original-etag"
        }
        try await download.waitForDownloadMetadataPersistence()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(session: session)
        // Source == destination exercises the production local transfer and
        // unstaged finish path; no transfer or processor is substituted.
        let task = Task { await controller.download(download, etag: "replacement-etag") }
        addTeardownBlock {
            task.cancel()
            await gate.release()
            await task.value
        }
        await fulfillment(of: [importStarted], timeout: 5)
        if replacesSource {
            do {
                try replacement.write(to: destination, options: .atomic)
            } catch {
                task.cancel()
                await gate.release()
                await task.value
                throw error
            }
        }
        if case .cancellation = outcome {
            await controller.cancelInProgressDownload(download)
        }
        await gate.release()
        await task.value
        let state = await MainActor.run {
            (download.isFailed, download.isFinishedDownloading,
             download.isFinishedProcessing, download.lastDownloaded,
             download.lastDownloadedETag, download.lastImportError)
        }
        if replacesSource {
            XCTAssertEqual(try Data(contentsOf: destination), replacement,
                "A processing result cannot delete or redownload another file's replacement")
            XCTAssertTrue(state.0)
            XCTAssertFalse(state.1)
            XCTAssertEqual(state.3, originalDownloadedAt)
            XCTAssertEqual(state.4, "original-etag")
            XCTAssertNil(try store.installedArtifactReceipt(sourceURL: destination,
                destinationURL: destination), "Unimported replacement bytes must not acquire a success receipt")
            if case .success = outcome {
                guard let error = state.5 as? DownloadableChecksumVerificationError,
                      case .fileChangedDuringVerification = error else {
                    return XCTFail("Expected original-file ownership rejection, got \(String(describing: state.5))")
                }
            }
        } else {
            XCTAssertFalse(state.0)
            XCTAssertTrue(state.1)
            XCTAssertTrue(state.2)
            XCTAssertEqual(state.4, "replacement-etag")
            XCTAssertEqual(FileManager.default.fileExists(atPath: destination.path), !deleteAfterImport)
            if !deleteAfterImport {
                XCTAssertEqual(try Data(contentsOf: destination), original)
                XCTAssertNotNil(try store.installedArtifactReceipt(sourceURL: destination,
                    destinationURL: destination))
            }
        }
    }


    func testEmptyCompressedReplacementCannotInheritPriorImportSuccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "download-empty-replacement-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("payload.bin")
        let priorPayload = Data("already-imported-version".utf8)
        try priorPayload.write(to: destination)
        let importCalled = AsyncCompletionFlag()
        let download = ImportableDownloadable(
            url: URL(string: "https://download-empty.test/\(UUID().uuidString).br")!,
            name: "Empty replacement",
            localDestination: destination,
            deleteAfterImport: false,
            isImported: { true },
            importHandler: { _, _ in await importCalled.markCompleted() }
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(session: session, attemptExecutor: { download, _ in
            let candidate = download.compressedTransferStagingURL(operationID: UUID())
            // A complete Brotli stream encoding an empty body, not a truncated file.
            try Data([0x3b]).write(to: candidate)
            return DownloadTransferResult(destinationLocation: candidate, etag: "empty", lastModified: nil)
        })

        await controller.download(download)

        let state = await MainActor.run {
            (download.isFailed, download.isFinishedDownloading, download.lastImportError)
        }
        XCTAssertTrue(state.0)
        XCTAssertFalse(state.1)
        guard let error = state.2 as? DownloadableChecksumVerificationError,
              case let .emptyFile(candidate) = error else {
            XCTFail("Expected empty expanded candidate rejection, got \(String(describing: state.2))")
            return
        }
        XCTAssertNotEqual(candidate, destination)
        XCTAssertEqual(candidate.deletingLastPathComponent(), directory)
        XCTAssertEqual(try Data(contentsOf: destination), priorPayload)
        let didImport = await importCalled.value()
        XCTAssertFalse(didImport)
    }
    func testCorruptUncompressedUpdatePreservesInstalledDestination()
    async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-staged-checksum-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let installedPayload = Data("previous-valid-payload".utf8)
        let destination = tempDirectory.appendingPathComponent("payload.bin")
        try installedPayload.write(to: destination, options: .atomic)
        let download = Downloadable(
            url: URL(
                string: "https://swiftui-downloads-staged.test/payload.bin"
            )!,
            name: "Staged Checksum Update",
            localDestination: destination,
            localDestinationChecksum: sha1Hex(installedPayload)
        )
        try download.ensureVerifiedLocalDestinationChecksum()
        XCTAssertTrue(download.hasVerifiedLocalDestinationChecksumMarker())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            CorruptUncompressedUpdateURLProtocol.self
        ]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(session: session)

        await controller.download(download)

        let completed = try await download.awaitCompletionOrFailure()
        XCTAssertFalse(completed)
        XCTAssertEqual(try Data(contentsOf: destination), installedPayload)
        XCTAssertTrue(
            download.hasVerifiedLocalDestinationChecksumMarker(),
            "A rejected candidate must not invalidate the installed baseline"
        )
        let remainingFiles = try FileManager.default.contentsOfDirectory(
            at: tempDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(remainingFiles.contains { url in

            url.lastPathComponent.contains(".downloading.")        })
    }

    func testRejectedUncompressedImportPreservesInstalledDestination()
    async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-staged-import-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let installedPayload = Data("previous-importable-payload".utf8)
        let destination = tempDirectory.appendingPathComponent("payload.bin")
        try installedPayload.write(to: destination, options: .atomic)
        let download = ImportableDownloadable(
            url: URL(
                string: "https://swiftui-downloads-staged.test/import.bin"
            )!,
            name: "Staged Import Update",
            localDestination: destination,
            deleteAfterImport: false,
            isImported: { false },
            importHandler: { candidateURL, _ in
                XCTAssertEqual(
                    try Data(contentsOf: candidateURL),
                    Data("corrupt-update".utf8)
                )
                XCTAssertEqual(
                    try Data(contentsOf: destination),
                    installedPayload,
                    "The installed file must remain readable during import"
                )
                throw TestImportError.rejectedCandidate
            }
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            CorruptUncompressedUpdateURLProtocol.self
        ]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(session: session)

        await controller.download(download)

        let completed = try await download.awaitCompletionOrFailure()
        XCTAssertFalse(completed)
        XCTAssertEqual(try Data(contentsOf: destination), installedPayload)
        let importError = await MainActor.run { download.lastImportError }
        guard let importError else {
            return XCTFail("Expected the rejected candidate error")
        }
        XCTAssertTrue(importError is TestImportError)
    }

    func testImportMutationAfterChecksumVerificationIsRejectedBeforeInstall()
    async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-import-mutation-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let installedPayload = Data("previous-verified-install".utf8)
        let candidatePayload = Data("checksum-authorized-candidate".utf8)
        let mutatedPayload = Data(
            repeating: 0x5A,
            count: candidatePayload.count
        )
        let destination = tempDirectory.appendingPathComponent("payload.bin")
        try installedPayload.write(to: destination, options: .atomic)
        let executor = StagedUncompressedAttemptExecutor(
            payload: candidatePayload
        )
        let download = ImportableDownloadable(
            url: URL(
                string: "https://swiftui-downloads-staged.test/mutated.bin"
            )!,
            name: "Mutated Staged Import",
            localDestination: destination,
            localDestinationChecksum: sha1Hex(candidatePayload),
            deleteAfterImport: false,
            isImported: { false },
            importHandler: { candidateURL, _ in
                try mutatedPayload.write(to: candidateURL, options: .atomic)
            }
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(
            session: session,
            attemptExecutor: { download, session in
                try await executor.execute(
                    download: download,
                    session: session
                )
            }
        )

        await controller.download(download)

        let completed = try await download.awaitCompletionOrFailure()
        let attemptCount = await executor.recordedAttemptCount()
        XCTAssertFalse(completed)
        XCTAssertEqual(try Data(contentsOf: destination), installedPayload)
        XCTAssertFalse(download.hasVerifiedLocalDestinationChecksumMarker())
        XCTAssertEqual(attemptCount, 2)
        let importError = await MainActor.run { download.lastImportError }
        guard let checksumError = importError
                as? DownloadableChecksumVerificationError,
              case .fileChangedDuringVerification = checksumError else {
            return XCTFail(
                "Expected staged-file mutation error, got "
                    + String(describing: importError)
            )
        }
    }

    func testCompressedChecksumFailurePerformsOneCleanAttemptAndInstallsIt()
    async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-compressed-recovery-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let installedPayload = Data("previous-compressed-install".utf8)
        let rejectedPayload = Data("rejected-compressed-update".utf8)
        let acceptedPayload = Data("accepted-compressed-update".utf8)
        let destination = tempDirectory.appendingPathComponent("payload.bin")
        try installedPayload.write(to: destination, options: .atomic)
        let executor = try SequencedCompressedAttemptExecutor(
            payloads: [rejectedPayload, acceptedPayload]
        )
        let download = Downloadable(
            url: URL(
                string: "https://swiftui-downloads-staged.test/recovery.bin.br"
            )!,
            name: "Compressed Checksum Recovery",
            localDestination: destination,
            localDestinationChecksum: sha1Hex(acceptedPayload)
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(
            session: session,
            attemptExecutor: { download, session in
                try await executor.execute(
                    download: download,
                    session: session
                )
            }
        )

        await controller.download(download)

        let completed = try await download.awaitCompletionOrFailure()
        let attemptCount = await executor.recordedAttemptCount()
        XCTAssertTrue(completed)
        XCTAssertEqual(attemptCount, 2)
        XCTAssertEqual(try Data(contentsOf: destination), acceptedPayload)
        XCTAssertTrue(download.hasVerifiedLocalDestinationChecksumMarker())
        let remainingFiles = try FileManager.default.contentsOfDirectory(
            at: tempDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(remainingFiles.contains { url in
            url.lastPathComponent.contains(".downloading.")
                || url.lastPathComponent.contains(".decompressing.")
        })
    }

    func testValidBrotliCandidateWithWrongChecksumPreservesInstalledDestination()
    async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-compressed-checksum-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let installedPayload = Data("previous-compressed-baseline".utf8)
        let candidatePayload = Data("valid-brotli-wrong-checksum".utf8)
        let destination = tempDirectory.appendingPathComponent("payload.bin")
        try installedPayload.write(to: destination, options: .atomic)
        let download = Downloadable(
            url: URL(string: "https://swiftui-downloads-staged.test/payload.bin.br")!,
            name: "Compressed Checksum Update",
            localDestination: destination,
            localDestinationChecksum: sha1Hex(installedPayload)
        )
        try download.ensureVerifiedLocalDestinationChecksum()
        let executor = try CompressedAttemptExecutor(payload: candidatePayload)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(
            session: session,
            attemptExecutor: { download, session in
                try await executor.execute(download: download, session: session)
            }
        )

        await controller.download(download)

        let completed = try await download.awaitCompletionOrFailure()
        XCTAssertFalse(completed)
        XCTAssertEqual(try Data(contentsOf: destination), installedPayload)
        XCTAssertTrue(download.hasVerifiedLocalDestinationChecksumMarker())
        let remainingFiles = try FileManager.default.contentsOfDirectory(
            at: tempDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(remainingFiles.contains { url in
            url.lastPathComponent.contains(".downloading.")
                || url.lastPathComponent.contains(".decompressing.")
        })
    }


    func testCancellationAfterCleanCompressedRetryReturnsDiscardsCandidateAndPublishesFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-retry-return-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data("previous-valid-install".utf8)
        let destination = directory.appendingPathComponent("payload.bin")
        try payload.write(to: destination, options: .atomic)
        let download = Downloadable(
            url: URL(string: "https://download-retry-return.test/\(UUID().uuidString).br")!,
            name: "Cancelled clean retry",
            localDestination: destination,
            localDestinationChecksum: sha1Hex(payload)
        )
        try download.ensureVerifiedLocalDestinationChecksum()
        let executor = try SequencedCompressedAttemptExecutor(
            payloads: [Data("wrong-checksum".utf8), payload],
            cancelAfterAttempt: 2
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(
            session: session,
            attemptExecutor: { download, session in
                try await executor.execute(download: download, session: session)
            }
        )

        await controller.download(download)

        let attempts = await executor.recordedAttemptCount()
        XCTAssertEqual(attempts, 2)
        let state = await MainActor.run {
            (download.isFailed, download.isFinishedProcessing, controller.failedDownloads.contains(download))
        }
        XCTAssertTrue(state.0)
        XCTAssertFalse(state.1)
        XCTAssertTrue(state.2)
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertTrue(download.hasVerifiedLocalDestinationChecksumMarker())
        let remainingFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertFalse(remainingFiles.contains {
            $0.lastPathComponent.contains(".downloading.") || $0.lastPathComponent.contains(".decompressing.")
        })
    }
    func testRejectedCompressedImportPreservesInstalledDestination()
    async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-compressed-import-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let installedPayload = Data("previous-compressed-import".utf8)
        let candidatePayload = Data("rejected-compressed-import".utf8)
        let destination = tempDirectory.appendingPathComponent("payload.bin")
        try installedPayload.write(to: destination, options: .atomic)
        let download = ImportableDownloadable(
            url: URL(string: "https://swiftui-downloads-staged.test/import.bin.br")!,
            name: "Compressed Import Update",
            localDestination: destination,
            deleteAfterImport: false,
            isImported: { false },
            importHandler: { candidateURL, _ in
                XCTAssertEqual(try Data(contentsOf: candidateURL), candidatePayload)
                XCTAssertEqual(try Data(contentsOf: destination), installedPayload)
                throw TestImportError.rejectedCandidate
            }
        )
        let executor = try CompressedAttemptExecutor(payload: candidatePayload)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(
            session: session,
            attemptExecutor: { download, session in
                try await executor.execute(download: download, session: session)
            }
        )

        await controller.download(download)

        let completed = try await download.awaitCompletionOrFailure()
        XCTAssertFalse(completed)
        XCTAssertEqual(try Data(contentsOf: destination), installedPayload)
        let importError = await MainActor.run { download.lastImportError }
        XCTAssertTrue(importError is TestImportError)
    }

    func testCancellingCompressedImportPreservesInstalledBytesAndMetadata()
    async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-compressed-cancellation-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let installedPayload = Data("previous-cancelled-import".utf8)
        let destination = tempDirectory.appendingPathComponent("payload.bin")
        try installedPayload.write(to: destination, options: .atomic)
        let importStarted = expectation(description: "compressed import started")
        let download = ImportableDownloadable(
            url: URL(string: "https://swiftui-downloads-staged.test/cancel.bin.br")!,
            name: "Cancelled Compressed Import",
            localDestination: destination,
            localDestinationChecksum: sha1Hex(installedPayload),
            deleteAfterImport: false,
            isImported: { false },
            importHandler: { _, _ in
                importStarted.fulfill()
                try await Task.sleep(nanoseconds: 30_000_000_000)
            }
        )
        try download.ensureVerifiedLocalDestinationChecksum()
        await download.waitForDownloadMetadata()
        let priorDownloadedAt = Date(timeIntervalSince1970: 123)
        let priorModifiedAt = Date(timeIntervalSince1970: 234)
        await MainActor.run {
            download.lastDownloaded = priorDownloadedAt
            download.lastDownloadedETag = "prior-etag"
            download.lastModifiedAt = priorModifiedAt
        }
        let executor = try CompressedAttemptExecutor(
            payload: installedPayload
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(
            session: session,
            attemptExecutor: { download, session in
                try await executor.execute(download: download, session: session)
            }
        )

        let task = Task { await controller.download(download) }
        await fulfillment(of: [importStarted], timeout: 5)
        await controller.cancelLongRunningWorkForBackgrounding()
        await task.value

        XCTAssertEqual(try Data(contentsOf: destination), installedPayload)
        XCTAssertTrue(download.hasVerifiedLocalDestinationChecksumMarker())
        let metadata = await MainActor.run {
            (
                download.lastDownloaded,
                download.lastDownloadedETag,
                download.lastModifiedAt
            )
        }
        XCTAssertEqual(metadata.0, priorDownloadedAt)
        XCTAssertEqual(metadata.1, "prior-etag")
        XCTAssertEqual(metadata.2, priorModifiedAt)
        let remainingFiles = try FileManager.default.contentsOfDirectory(
            at: tempDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(remainingFiles.contains { url in
            url.lastPathComponent.contains(".downloading.")
                || url.lastPathComponent.contains(".decompressing.")
        })
    }

    func testZeroByteCompressedPayloadFailsInsteadOfAcceptingOldDestination() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-zero-compressed-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let destination = tempDirectory.appendingPathComponent("payload.bin")
        try Data("old-destination".utf8).write(to: destination)
        let download = Downloadable(
            url: URL(string: "https://swiftui-downloads-zero.test/payload.bin.br")!,
            name: "Zero Compressed Payload",
            localDestination: destination
        )
        try Data().write(to: download.compressedFileURL)

        let controller = DownloadController()
        await controller.finishDownload(download)

        let state = await MainActor.run {
            (
                download.isFailed,
                download.isFinishedDownloading,
                download.isFinishedProcessing
            )
        }
        XCTAssertTrue(state.0)
        XCTAssertFalse(state.1)
        XCTAssertTrue(state.2)
        XCTAssertEqual(
            try Data(contentsOf: destination),
            Data("old-destination".utf8),
            "A failed compressed update must preserve the previously usable file"
        )
    }

    func testFailedCompressedReplacementPreservesSuccessfulDownloadBaseline()
    async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-failed-baseline-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let destination = tempDirectory.appendingPathComponent("payload.bin")
        try Data("previous-valid-payload".utf8).write(to: destination)
        let download = Downloadable(
            url: URL(
                string: "https://swiftui-downloads-zero.test/\(UUID().uuidString).bin.br"
            )!,
            name: "Failed Replacement Baseline",
            localDestination: destination
        )
        await download.waitForDownloadMetadata()
        let previousSuccessfulDownload = Date(timeIntervalSince1970: 123)
        await MainActor.run {
            download.lastDownloaded = previousSuccessfulDownload
        }

        let attemptExecutor = EmptyCompressedAttemptExecutor()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(
            session: session,
            attemptExecutor: { download, session in
                try await attemptExecutor.execute(
                    download: download,
                    session: session
                )
            }
        )

        await controller.download(download)
        let completed = try await download.awaitCompletionOrFailure()
        XCTAssertFalse(completed)

        let state = await MainActor.run {
            (download.lastDownloaded, download.lastDownloadedETag)
        }
        XCTAssertEqual(state.0, previousSuccessfulDownload)
        XCTAssertNil(state.1)
        XCTAssertEqual(
            try Data(contentsOf: destination),
            Data("previous-valid-payload".utf8)
        )
    }

    func testInvalidateLocalArtifactsRemovesEveryArtifactAndResetsLifecycleState() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-delete-artifacts-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let destination = tempDirectory.appendingPathComponent("payload.bin")
        let download = Downloadable(
            url: URL(string: "https://swiftui-downloads-delete.test/payload.bin.br")!,
            name: "Delete Artifacts",
            localDestination: destination,
            localDestinationChecksum: sha1Hex(Data("payload".utf8))
        )
        let firstStaging = destination.appendingPathExtension(
            "decompressing.\(UUID().uuidString)"
        )
        let secondStaging = destination.appendingPathExtension(
            "decompressing.\(UUID().uuidString)"
        )
        for url in [
            destination,
            download.compressedFileURL,
            download.checksumVerificationMarkerURL,
            firstStaging,
            secondStaging,
        ] {
            try Data("artifact".utf8).write(to: url)
        }

        let controller = DownloadController()
        await MainActor.run {
            controller.assuredDownloads.insert(download)
            controller.activeDownloads.insert(download)
            controller.finishedDownloads.insert(download)
            controller.failedDownloads.insert(download)
            download.isActive = true
            download.isFinishedDownloading = true
            download.isFinishedProcessing = true
            download.isFailed = true
            download.downloadProgress = .completed(
                destinationLocation: destination,
                etag: "installed-etag",
                error: nil
            )
        }

        try await controller.invalidateLocalArtifacts(for: download)

        for url in [
            destination,
            download.compressedFileURL,
            download.checksumVerificationMarkerURL,
            firstStaging,
            secondStaging,
        ] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        let state = await MainActor.run {
            (
                controller.assuredDownloads.contains(download),
                controller.activeDownloads.contains(download),
                controller.finishedDownloads.contains(download),
                controller.failedDownloads.contains(download),
                download.isActive,
                download.isFinishedDownloading,
                download.isFinishedProcessing,
                download.isFailed,
                download.downloadProgress
            )
        }
        XCTAssertFalse(state.0)
        XCTAssertFalse(state.1)
        XCTAssertFalse(state.2)
        XCTAssertFalse(state.3)
        XCTAssertFalse(state.4)
        XCTAssertFalse(state.5)
        XCTAssertFalse(state.6)
        XCTAssertFalse(state.7)
        if case .uninitiated = state.8 {
            // Expected clean lifecycle state.
        } else {
            XCTFail("Invalidation must reset download progress")
        }
    }

    func testVerifyingReadableFileWritesChecksumMarker() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-downloads-checksum-repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let payload = Data("verified-local-file".utf8)
        let destinationURL = tempDirectory.appendingPathComponent("payload.bin")
        try payload.write(to: destinationURL, options: .atomic)

        let download = Downloadable(
            url: URL(string: "https://swiftui-downloads-checksum.test/payload.bin")!,
            name: "Checksum Repair",
            localDestination: destinationURL,
            localDestinationChecksum: sha1Hex(payload)
        )

        XCTAssertFalse(download.hasVerifiedLocalDestinationChecksumMarker())
        XCTAssertTrue(download.hasReadableLocalDestination())

        try download.ensureVerifiedLocalDestinationChecksum()

        XCTAssertTrue(download.hasVerifiedLocalDestinationChecksumMarker())
    }

    func testRapidSameSizeReplacementCannotReuseChecksumMarker() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-checksum-identity-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let verifiedPayload = Data("verified-local-file".utf8)
        let replacementPayload = Data("tampered-local-file".utf8)
        XCTAssertEqual(verifiedPayload.count, replacementPayload.count)

        let destinationURL = tempDirectory.appendingPathComponent("payload.bin")
        try verifiedPayload.write(to: destinationURL, options: .atomic)
        let download = Downloadable(
            url: URL(string: "https://swiftui-downloads-checksum.test/identity.bin")!,
            name: "Checksum Marker Identity",
            localDestination: destinationURL,
            localDestinationChecksum: sha1Hex(verifiedPayload)
        )
        try download.ensureVerifiedLocalDestinationChecksum()
        XCTAssertTrue(download.hasVerifiedLocalDestinationChecksumMarker())

        let originalAttributes = try FileManager.default.attributesOfItem(
            atPath: destinationURL.path
        )
        let originalModificationDate = try XCTUnwrap(
            originalAttributes[.modificationDate] as? Date
        )
        try replacementPayload.write(to: destinationURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: originalModificationDate.addingTimeInterval(0.5)],
            ofItemAtPath: destinationURL.path
        )

        let replacementAttributes = try FileManager.default.attributesOfItem(
            atPath: destinationURL.path
        )
        let replacementModificationDate = try XCTUnwrap(
            replacementAttributes[.modificationDate] as? Date
        )
        XCTAssertEqual(
            (replacementAttributes[.size] as? NSNumber)?.uint64Value,
            UInt64(verifiedPayload.count)
        )
        XCTAssertLessThan(
            abs(
                replacementModificationDate.timeIntervalSince1970
                    - originalModificationDate.timeIntervalSince1970
            ),
            1,
            "The replacement must exercise the former one-second tolerance"
        )

        XCTAssertFalse(download.hasVerifiedLocalDestinationChecksumMarker())
        XCTAssertThrowsError(
            try download.ensureVerifiedLocalDestinationChecksum()
        ) { error in
            guard case DownloadableChecksumVerificationError.mismatch = error else {
                return XCTFail("Expected checksum mismatch, got \(error)")
            }
        }
        XCTAssertFalse(download.hasVerifiedLocalDestinationChecksumMarker())
    }

    func testLegacyChecksumMarkerIsReverifiedAndUpgraded() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-legacy-checksum-marker-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let payload = Data("legacy-marker-payload".utf8)
        let destinationURL = tempDirectory.appendingPathComponent("payload.bin")
        try payload.write(to: destinationURL, options: .atomic)
        let download = Downloadable(
            url: URL(string: "https://swiftui-downloads-checksum.test/legacy.bin")!,
            name: "Legacy Checksum Marker",
            localDestination: destinationURL,
            localDestinationChecksum: sha1Hex(payload)
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: destinationURL.path
        )
        let modificationDate = try XCTUnwrap(
            attributes[.modificationDate] as? Date
        )
        let legacyMarker: [String: Any] = [
            "expectedChecksum": sha1Hex(payload),
            "fileSize": payload.count,
            "modificationTimeIntervalSince1970": modificationDate
                .timeIntervalSince1970,
        ]
        let legacyMarkerData = try JSONSerialization.data(
            withJSONObject: legacyMarker
        )
        try legacyMarkerData.write(
            to: download.checksumVerificationMarkerURL,
            options: .atomic
        )

        XCTAssertFalse(download.hasVerifiedLocalDestinationChecksumMarker())
        try download.ensureVerifiedLocalDestinationChecksum()
        XCTAssertTrue(download.hasVerifiedLocalDestinationChecksumMarker())
    }


    func testSameSizeReplacementWithIdenticalModificationTimeCannotReuseChecksumMarker() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-marker-inode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("payload.bin")
        let payload = Data("verified".utf8)
        try payload.write(to: destination, options: .atomic)
        let fixedModificationDate = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedModificationDate],
            ofItemAtPath: destination.path
        )
        let download = Downloadable(
            url: URL(string: "https://download-marker.test/\(UUID().uuidString)")!,
            name: "Exact marker identity",
            localDestination: destination,
            localDestinationChecksum: sha1Hex(payload)
        )
        try download.ensureVerifiedLocalDestinationChecksum()
        let original = try FileManager.default.attributesOfItem(atPath: destination.path)
        let modificationDate = try XCTUnwrap(original[.modificationDate] as? Date)
        try Data("replaced".utf8).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: destination.path)
        let replacement = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual(replacement[.size] as? NSNumber, original[.size] as? NSNumber)
        XCTAssertEqual(replacement[.modificationDate] as? Date, modificationDate)
        XCTAssertNotEqual(replacement[.systemFileNumber] as? NSNumber, original[.systemFileNumber] as? NSNumber)

        XCTAssertFalse(download.hasVerifiedLocalDestinationChecksumMarker())
        XCTAssertThrowsError(try download.ensureVerifiedLocalDestinationChecksum())
    }
    func testEmptyLocalFileRequiresCleanRedownload() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-empty-checksum-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let destinationURL = tempDirectory.appendingPathComponent("payload.bin")
        try Data().write(to: destinationURL, options: .atomic)
        let download = Downloadable(
            url: URL(string: "https://swiftui-downloads-checksum.test/empty.bin")!,
            name: "Empty Checksum Payload",
            localDestination: destinationURL,
            localDestinationChecksum: sha1Hex(Data("expected".utf8))
        )

        XCTAssertThrowsError(
            try download.ensureVerifiedLocalDestinationChecksum()
        ) { error in
            XCTAssertTrue(
                (error as? DownloadableChecksumVerificationError)?
                    .requiresCleanRedownload == true
            )
        }
    }

    func testOrphanCleanupKeepsChecksumMarkerForAssuredDownload() async throws {
        let parentName = "swiftui-downloads-orphan-marker-\(UUID().uuidString)"
        let directory = DownloadDirectory.appSupport(
            parentDirectoryName: parentName,
            groupIdentifier: nil
        )
        let directoryURL = directory.directoryURL
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let payload = Data("kept-marker".utf8)
        let destinationURL = directoryURL.appendingPathComponent("payload.bin")
        try payload.write(to: destinationURL, options: .atomic)
        let orphanURL = directoryURL.appendingPathComponent("orphan.tmp")
        try Data("orphan".utf8).write(to: orphanURL, options: .atomic)

        let download = Downloadable(
            url: URL(string: "https://swiftui-downloads-checksum.test/kept-marker.bin")!,
            name: "Kept Marker",
            localDestination: destinationURL,
            localDestinationChecksum: sha1Hex(payload)
        )
        try download.ensureVerifiedLocalDestinationChecksum()

        let abandonedTransferURL = download.compressedTransferStagingURL(operationID: UUID())
        let abandonedExpansionURL = destinationURL.appendingPathExtension("decompressing.\(UUID().uuidString)")
        try Data("abandoned transfer".utf8).write(to: abandonedTransferURL)
        try Data("abandoned expansion".utf8).write(to: abandonedExpansionURL)
        // Reconstruct both owners as a later launch would, retaining only the
        // installed artifact and its on-disk verification marker.
        let reopenedDownload = Downloadable(
            url: download.url,
            name: download.name,
            localDestination: destinationURL,
            localDestinationChecksum: sha1Hex(payload)
        )
        let controller = DownloadController()
        await MainActor.run { () -> Void in
            controller.assuredDownloads.insert(reopenedDownload)
        }

        try await controller.deleteOrphanFiles(in: [directory])

        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: download.checksumVerificationMarkerURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandonedTransferURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandonedExpansionURL.path))
        XCTAssertTrue(reopenedDownload.hasVerifiedLocalDestinationChecksumMarker())
    }


    func testOrphanCleanupPreservesDeclaredGeneratedDirectoryAndDescendants() async throws {
        let parentName = "swiftui-downloads-generated-artifacts-\(UUID().uuidString)"
        let directory = DownloadDirectory.appSupport(
            parentDirectoryName: parentName,
            groupIdentifier: nil
        )
        let directoryURL = directory.directoryURL

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let destinationURL = directoryURL.appendingPathComponent("payload.bin")
        let generatedDirectoryURL = directoryURL.appendingPathComponent(
            ".runtime-snapshots",
            isDirectory: true
        )

        let generatedArtifactURL = generatedDirectoryURL.appendingPathComponent("payload.snapshot")
        let orphanURL = directoryURL.appendingPathComponent("orphan.tmp")
        try Data("payload".utf8).write(to: destinationURL, options: .atomic)
        try FileManager.default.createDirectory(at: generatedDirectoryURL, withIntermediateDirectories: true)
        try Data("snapshot".utf8).write(to: generatedArtifactURL, options: .atomic)
        try Data("orphan".utf8).write(to: orphanURL, options: .atomic)

        let declaredPathAlias = generatedDirectoryURL
            .deletingLastPathComponent()
            .appendingPathComponent(".runtime-snapshots/../.runtime-snapshots")
        let download = Downloadable(
            url: URL(string: "https://swiftui-downloads.test/generated.bin")!,
            name: "Generated Artifacts",
            localDestination: destinationURL,

            preservedLocalArtifactDirectories: [declaredPathAlias]
        )
        let controller = DownloadController()
        _ = await MainActor.run { controller.assuredDownloads.insert(download) }

        try await controller.deleteOrphanFiles(in: [directory])

        XCTAssertTrue(FileManager.default.fileExists(atPath: generatedArtifactURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
    }

    func testOrphanCleanupDoesNotTrustGeneratedDirectorySymlinkOutsideCleanupRoot() async throws {
        let directory = DownloadDirectory.appSupport(
            parentDirectoryName: "swiftui-downloads-symlink-root-\(UUID().uuidString)",
            groupIdentifier: nil
        )
        let rootURL = directory.directoryURL
        let outsideURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swiftui-downloads-symlink-outside-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: outsideURL)
        }

        let outsideArtifactURL = outsideURL.appendingPathComponent("must-not-be-owned.snapshot")
        try Data("outside".utf8).write(to: outsideArtifactURL, options: .atomic)
        let escapingLinkURL = rootURL.appendingPathComponent("escaping-generated", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: escapingLinkURL,
            withDestinationURL: outsideURL
        )
        let destinationURL = rootURL.appendingPathComponent("payload.bin")
        try Data("payload".utf8).write(to: destinationURL, options: .atomic)
        let download = Downloadable(
            url: URL(string: "https://swiftui-downloads.test/symlink.bin")!,
            name: "Escaping Generated Artifacts",
            localDestination: destinationURL,
            preservedLocalArtifactDirectories: [escapingLinkURL]
        )
        let controller = DownloadController()
        _ = await MainActor.run { controller.assuredDownloads.insert(download) }

        try await controller.deleteOrphanFiles(in: [directory])

        XCTAssertFalse(FileManager.default.fileExists(atPath: escapingLinkURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideArtifactURL.path))
    }
    func testChecksumMismatchWithoutCompressedFileRetriesCleanDownload() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-downloads-checksum-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let expectedPayload = Data("expected-payload".utf8)
        let stalePayload = Data("stale-payload".utf8)
        let destinationURL = tempDirectory.appendingPathComponent("payload.bin")
        try stalePayload.write(to: destinationURL, options: .atomic)

        let download = Downloadable(
            url: URL(string: "https://swiftui-downloads-checksum.test/retry.bin")!,
            name: "Checksum Retry",
            localDestination: destinationURL,
            localDestinationChecksum: sha1Hex(expectedPayload)
        )
        let attemptExecutor = ChecksumRecoveryAttemptExecutor(payload: expectedPayload)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(
            session: session,
            attemptExecutor: { download, session in
                try await attemptExecutor.execute(download: download, session: session)
            }
        )

        let recoveryCompleted = expectation(
            description: "checksum replacement finishes without re-entering its processor"
        )
        let completionFlag = AsyncCompletionFlag()
        Task {
            await controller.finishDownload(download)
            await completionFlag.markCompleted()
            recoveryCompleted.fulfill()
        }
        await fulfillment(of: [recoveryCompleted], timeout: 5)
        guard await completionFlag.value() else {
            return
        }
        let isComplete = try await download.awaitCompletionOrFailure()

        XCTAssertTrue(isComplete)
        XCTAssertEqual(try Data(contentsOf: destinationURL), expectedPayload)
        XCTAssertTrue(download.hasVerifiedLocalDestinationChecksumMarker())
        let attemptCount = await attemptExecutor.recordedAttemptCount()
        XCTAssertEqual(attemptCount, 1)
    }

    func testUncompressedUpdateIgnoresStaleCompressedCache() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-uncompressed-stale-cache-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let expectedPayload = Data("new-uncompressed-payload".utf8)
        let staleCompressedPayload = Data("old-compressed-payload".utf8)
        guard let staleCompressedBytes =
                (staleCompressedPayload as NSData).brotliCompressed() else {
            XCTFail("Expected stale test payload to be compressible")
            return
        }

        let destinationURL = tempDirectory.appendingPathComponent("payload.json")
        let download = Downloadable(
            url: URL(string: "https://swiftui-downloads-staged.test/uncompressed.json")!,
            name: "Uncompressed stale-cache update",
            localDestination: destinationURL
        )
        try FileManager.default.createDirectory(
            at: download.compressedFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try staleCompressedBytes.write(
            to: download.compressedFileURL,
            options: .atomic
        )

        let attemptExecutor = StagedUncompressedAttemptExecutor(
            payload: expectedPayload
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(
            session: session,
            attemptExecutor: { download, session in
                try await attemptExecutor.execute(
                    download: download,
                    session: session
                )
            }
        )


        let hasLocalArtifact = await download.existsLocally()
        XCTAssertFalse(hasLocalArtifact, "A stale .br cannot authorize local processing of an uncompressed download")
        await controller.ensureDownloaded([download])
        let isComplete = try await download.awaitCompletionOrFailure()
        XCTAssertTrue(isComplete)
        XCTAssertEqual(try Data(contentsOf: destinationURL), expectedPayload)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: download.compressedFileURL.path)
        )
        let attemptCount = await attemptExecutor.recordedAttemptCount()
        XCTAssertEqual(attemptCount, 1)
    }

    func testDirectChecksumFailureCanRequestCleanRecovery() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-direct-checksum-recovery-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let expectedPayload = Data("expected-direct-payload".utf8)
        let destinationURL = tempDirectory.appendingPathComponent("payload.bin")
        try Data("corrupt-direct-payload".utf8).write(
            to: destinationURL,
            options: .atomic
        )
        let download = Downloadable(
            url: URL(string: "https://swiftui-downloads-checksum.test/direct.bin")!,
            name: "Direct Checksum Recovery",
            localDestination: destinationURL,
            localDestinationChecksum: sha1Hex(expectedPayload)
        )
        let attemptExecutor = ChecksumRecoveryAttemptExecutor(
            payload: expectedPayload
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(
            session: session,
            attemptExecutor: { download, session in
                try await attemptExecutor.execute(
                    download: download,
                    session: session
                )
            }
        )

        XCTAssertThrowsError(
            try download.ensureVerifiedLocalDestinationChecksum()
        ) { error in
            XCTAssertTrue(
                (error as? DownloadableChecksumVerificationError)?
                    .requiresCleanRedownload == true
            )
        }

        await controller.recoverLocalChecksumFailure(for: download)
        let isComplete = try await download.awaitCompletionOrFailure()
        let attemptCount = await attemptExecutor.recordedAttemptCount()
        XCTAssertTrue(isComplete)
        XCTAssertEqual(try Data(contentsOf: destinationURL), expectedPayload)
        XCTAssertTrue(download.hasVerifiedLocalDestinationChecksumMarker())
        XCTAssertEqual(attemptCount, 1)
    }

    func testAlreadyAssuredJMDictStyleArtifactRecoversExternalReplacement() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-assured-checksum-recovery-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let expectedPayload = Data("valid-jmdict-artifact".utf8)
        let destinationURL = tempDirectory.appendingPathComponent("jmdict.realm")
        let download = Downloadable(
            url: URL(string: "https://swiftui-downloads-checksum.test/jmdict.realm")!,
            name: "Japanese-English Dictionary (JMDict)",
            localDestination: destinationURL,
            localDestinationChecksum: sha1Hex(expectedPayload)
        )
        await MainActor.run { download.shouldCheckForUpdates = false }
        let attemptExecutor = ChecksumRecoveryAttemptExecutor(
            payload: expectedPayload
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(
            session: session,
            attemptExecutor: { download, session in
                try await attemptExecutor.execute(
                    download: download,
                    session: session
                )
            }
        )

        await controller.ensureDownloaded(download: download)
        XCTAssertTrue(download.hasVerifiedLocalDestinationChecksumMarker())
        let firstAttemptCount = await attemptExecutor.recordedAttemptCount()
        XCTAssertEqual(firstAttemptCount, 1)

        // Another process, interrupted installer, or damaged cache can replace
        // a previously assured file without changing this controller's flags.
        try Data("partial-jmdict-artifact".utf8).write(
            to: destinationURL,
            options: .atomic
        )
        XCTAssertFalse(download.hasVerifiedLocalDestinationChecksumMarker())

        await controller.ensureDownloaded(download: download)
        let recoveredAttemptCount = await attemptExecutor.recordedAttemptCount()
        XCTAssertEqual(recoveredAttemptCount, 2)
        XCTAssertEqual(try Data(contentsOf: destinationURL), expectedPayload)
        XCTAssertTrue(download.hasVerifiedLocalDestinationChecksumMarker())
        let state = await MainActor.run {
            (download.isFinishedProcessing, download.isFailed,
             controller.finishedDownloads.contains(download))
        }
        XCTAssertTrue(state.0)
        XCTAssertFalse(state.1)
        XCTAssertTrue(state.2)

        // Foreground recovery must not trust the same stale finished flag.
        try Data("another-partial-artifact".utf8).write(
            to: destinationURL,
            options: .atomic
        )
        await controller.resumeRecoverableDownloadsAfterForegrounding()
        let foregroundAttemptCount = await attemptExecutor.recordedAttemptCount()
        XCTAssertEqual(foregroundAttemptCount, 3)
        XCTAssertEqual(try Data(contentsOf: destinationURL), expectedPayload)
        XCTAssertTrue(download.hasVerifiedLocalDestinationChecksumMarker())
    }

    func testImportedButRetainedSourceStillRevalidatesAssuredInstall() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swiftui-downloads-retained-import-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let expectedPayload = Data("valid-retained-dictionary".utf8)
        let destination = directory.appendingPathComponent("dictionary.realm")
        let download = ImportableDownloadable(
            url: URL(string: "https://swiftui-downloads-checksum.test/retained.realm")!,
            name: "Retained dictionary",
            localDestination: destination,
            localDestinationChecksum: sha1Hex(expectedPayload),
            deleteAfterImport: false,
            isImported: { true },
            importHandler: { _, _ in }
        )
        await MainActor.run { download.shouldCheckForUpdates = false }
        let attempts = ChecksumRecoveryAttemptExecutor(payload: expectedPayload)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(session: session, attemptExecutor: { download, session in
            try await attempts.execute(download: download, session: session)
        })

        await controller.ensureDownloaded(download: download)
        let firstAttemptCount = await attempts.recordedAttemptCount()
        XCTAssertEqual(firstAttemptCount, 1)
        XCTAssertTrue(download.hasVerifiedLocalDestinationChecksumMarker())

        try Data("damaged-retained-dictionary".utf8).write(to: destination, options: .atomic)
        XCTAssertFalse(download.hasVerifiedLocalDestinationChecksumMarker())
        await controller.ensureDownloaded(download: download)

        let recoveredAttemptCount = await attempts.recordedAttemptCount()
        XCTAssertEqual(recoveredAttemptCount, 2)
        XCTAssertEqual(try Data(contentsOf: destination), expectedPayload)
        XCTAssertTrue(download.hasVerifiedLocalDestinationChecksumMarker())
    }

    func testConcurrentFinishAndDirectRecoveryUseOneDownloadAttempt() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-concurrent-checksum-recovery-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let expectedPayload = Data("expected-concurrent-payload".utf8)
        let destinationURL = tempDirectory.appendingPathComponent("payload.bin")
        try Data("corrupt-concurrent-payload".utf8).write(
            to: destinationURL,
            options: .atomic
        )
        let download = Downloadable(
            url: URL(string: "https://swiftui-downloads-checksum.test/concurrent.bin")!,
            name: "Concurrent Checksum Recovery",
            localDestination: destinationURL,
            localDestinationChecksum: sha1Hex(expectedPayload)
        )
        let attemptExecutor = ChecksumRecoveryAttemptExecutor(
            payload: expectedPayload
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(
            session: session,
            attemptExecutor: { download, session in
                try await attemptExecutor.execute(
                    download: download,
                    session: session
                )
            }
        )

        async let finish: Void = controller.finishDownload(download)
        async let first: Void = controller.recoverLocalChecksumFailure(
            for: download
        )
        async let second: Void = controller.recoverLocalChecksumFailure(
            for: download
        )
        _ = await (finish, first, second)

        let isComplete = try await download.awaitCompletionOrFailure()
        let attemptCount = await attemptExecutor.recordedAttemptCount()
        XCTAssertTrue(isComplete)
        XCTAssertEqual(try Data(contentsOf: destinationURL), expectedPayload)
        XCTAssertTrue(download.hasVerifiedLocalDestinationChecksumMarker())
        XCTAssertEqual(attemptCount, 1)
    }

    func testForegroundRecoveryProcessesPreservedCompressedFile() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-downloads-foreground-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let payload = Data("recoverable-compressed-payload".utf8)
        guard let compressedPayload = (payload as NSData).brotliCompressed() else {
            XCTFail("Expected test payload to be compressible")
            return
        }

        let destinationURL = tempDirectory.appendingPathComponent("payload.bin")
        let download = Downloadable(
            url: URL(string: "https://swiftui-downloads-checksum.test/recoverable-payload.bin.br")!,
            name: "Foreground Recovery",
            localDestination: destinationURL,
            localDestinationChecksum: sha1Hex(payload)
        )
        try compressedPayload.write(to: download.compressedFileURL, options: .atomic)

        let controller = DownloadController()
        await MainActor.run {
            controller.assuredDownloads.insert(download)
            controller.failedDownloads.insert(download)
            download.isFailed = true
            download.isFinishedDownloading = false
            download.isFinishedProcessing = false
        }

        await controller.resumeRecoverableDownloadsAfterForegrounding()

        XCTAssertEqual(try Data(contentsOf: destinationURL), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.compressedFileURL.path))
        let isComplete = await MainActor.run { download.isFinishedProcessing && !download.isFailed }
        XCTAssertTrue(isComplete)
        XCTAssertTrue(download.hasVerifiedLocalDestinationChecksumMarker())
    }
}
