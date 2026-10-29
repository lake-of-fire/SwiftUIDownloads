import CryptoKit
import XCTest
import SwiftUtilities
@testable import SwiftUIDownloads

private final class InvalidMetadataHEADURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let kind = request.url!.lastPathComponent
        var headers = ["Content-Length": "123", "ETag": "untrusted-fragment",
                       "Last-Modified": "Wed, 01 Jan 2031 00:00:00 GMT"]
        if kind == "range" { headers["Content-Range"] = "bytes 0-122/1000" }
        if kind == "multipart" { headers["Content-Type"] = "multipart/byteranges; boundary=part" }
        let response = HTTPURLResponse(url: request.url!, statusCode: Int(kind) ?? 200,
            httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class UnavailableHEADURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 503,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class HangingDownloadURLProtocol: URLProtocol {
    nonisolated(unsafe) static var didStart: (() -> Void)?
    nonisolated(unsafe) static var didStop: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.didStart?()
    }

    override func stopLoading() {
        Self.didStop?()
    }
}

private final class ModifiedHEADURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "ETag": "new-etag",
                "Last-Modified": "Wed, 01 Jan 2031 00:00:00 GMT",
            ]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class UnknownLengthHEADURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Transfer-Encoding": "chunked"]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ETagOnlyHEADURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["ETag": "remote-b"]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class LastModifiedOnlyHEADURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Last-Modified": "Wed, 01 Jan 2031 00:00:00 GMT",
            ]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class SuccessfulGETURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "ETag": "get-response-etag",
                "Last-Modified": "Wed, 01 Jan 2031 00:00:00 GMT",
            ]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(
            self,
            didLoad: Data("get-response-payload".utf8)
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor EmptyCompressedRemoteAttemptExecutor {
    private var invocationCount = 0

    func execute(
        download: Downloadable,
        session _: URLSession
    ) async throws -> DownloadTransferResult {
        invocationCount += 1
        try Data().write(to: download.compressedFileURL, options: .atomic)
        await MainActor.run {
            download.downloadProgress = .completed(
                destinationLocation: download.compressedFileURL,
                etag: "new-etag",
                error: nil
            )
            download.isActive = false
            download.isFailed = false
            download.isFinishedDownloading = true
        }
        return DownloadTransferResult(
            destinationLocation: download.compressedFileURL,
            etag: "new-etag",
            lastModified: nil
        )
    }

    func count() -> Int { invocationCount }
}

private actor SuspendedTransferAttemptExecutor {
    private var count = 0
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    let started: XCTestExpectation
    let restarted: XCTestExpectation

    init(started: XCTestExpectation, restarted: XCTestExpectation) {
        self.started = started
        self.restarted = restarted
    }

    func execute(download: Downloadable) async throws -> DownloadTransferResult {
        count += 1
        if count == 1 {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
                started.fulfill()
            }
            try Task.checkCancellation()
        }
        restarted.fulfill()
        try Data("foreground-retry".utf8).write(to: download.localDestination)
        return DownloadTransferResult(destinationLocation: download.localDestination, etag: nil, lastModified: nil)
    }

    func releaseCanceledTransfer() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func attemptCount() -> Int { count }
}

private actor InterruptedThenSuccessfulAttemptExecutor {
    private var count = 0

    func execute(download: Downloadable) throws -> DownloadTransferResult {
        count += 1
        if count == 1 { throw CancellationError() }
        try Data("recovered-download".utf8).write(to: download.localDestination)
        return DownloadTransferResult(destinationLocation: download.localDestination, etag: nil, lastModified: nil)
    }
}

private actor SuccessfulRemoteAttemptExecutor {
    private let etag: String?
    private let lastModified: Date?
    private let payload: Data
    private var invocationCount = 0

    init(
        etag: String? = nil,
        lastModified: Date? = nil,
        payload: Data = Data("replacement-payload".utf8)
    ) {
        self.etag = etag
        self.lastModified = lastModified
        self.payload = payload
    }

    func execute(
        download: Downloadable,
        session _: URLSession
    ) async throws -> DownloadTransferResult {
        invocationCount += 1
        try payload.write(
            to: download.localDestination,
            options: .atomic
        )
        await MainActor.run {
            download.downloadProgress = .completed(
                destinationLocation: download.localDestination,
                etag: etag,
                error: nil
            )
            download.isActive = false
            download.isFailed = false
            download.isFinishedDownloading = true
        }
        return DownloadTransferResult(
            destinationLocation: download.localDestination,
            etag: etag,
            lastModified: lastModified
        )
    }

    func count() -> Int { invocationCount }
}

private enum ValidatorMetadataStoreError: Error {
    case injectedLoadFailure
}

private final class ValidatorMetadataBacking: @unchecked Sendable {
    private let lock = NSLock()
    private var metadata: DownloadMetadata
    private var remainingLoadFailures: Int

    init(
        metadata: DownloadMetadata = DownloadMetadata(),
        loadFailureCount: Int
    ) {
        self.metadata = metadata
        remainingLoadFailures = loadFailureCount
    }

    func load() throws -> DownloadMetadata {
        lock.lock()
        defer { lock.unlock() }
        if remainingLoadFailures > 0 {
            remainingLoadFailures -= 1
            throw ValidatorMetadataStoreError.injectedLoadFailure
        }
        return metadata
    }

    func update(_ body: (inout DownloadMetadata) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&metadata)
    }
}

private struct ValidatorMetadataStore: DownloadableMetadataStore {
    let metadataCacheNamespace: String
    let backing: ValidatorMetadataBacking

    init(backing: ValidatorMetadataBacking) {
        self.backing = backing
        metadataCacheNamespace = "validator-metadata-\(UUID().uuidString)"
    }

    func loadMetadata(for _: URL) throws -> DownloadMetadata {
        try backing.load()
    }

    func saveMetadata(
        _ metadata: DownloadMetadata,
        fields: DownloadMetadataFields,
        for _: URL
    ) {
        backing.update { storedMetadata in
            if fields.contains(.lastDownloadedETag) {
                storedMetadata.lastDownloadedETag = metadata.lastDownloadedETag
            }
            if fields.contains(.lastCheckedETagAt) {
                storedMetadata.lastCheckedETagAt = metadata.lastCheckedETagAt
            }
            if fields.contains(.lastDownloadedAt) {
                storedMetadata.lastDownloadedAt = metadata.lastDownloadedAt
            }
            if fields.contains(.lastModifiedAt) {
                storedMetadata.lastModifiedAt = metadata.lastModifiedAt
            }
        }
    }

    func lastDownloadedETag(for _: URL) -> String? {
        try? backing.load().lastDownloadedETag
    }

    func setLastDownloadedETag(_ etag: String?, for _: URL) {
        backing.update { $0.lastDownloadedETag = etag }
    }

    func lastCheckedETagAt(for _: URL) -> Date? {
        try? backing.load().lastCheckedETagAt
    }

    func setLastCheckedETagAt(_ date: Date?, for _: URL) {
        backing.update { $0.lastCheckedETagAt = date }
    }

    func lastDownloaded(for _: URL) -> Date? {
        try? backing.load().lastDownloadedAt
    }

    func setLastDownloaded(_ date: Date?, for _: URL) {
        backing.update { $0.lastDownloadedAt = date }
    }

    func lastModifiedAt(for _: URL) -> Date? {
        try? backing.load().lastModifiedAt
    }

    func setLastModifiedAt(_ date: Date?, for _: URL) {
        backing.update { $0.lastModifiedAt = date }
    }
}

final class DownloadRemoteLifecycleTests: XCTestCase {

    @MainActor
    func testAssuredDownloadRechecksExpiredOrMissingRemoteCheck() async throws {
        let previousChecks: [Date?] = [Date(timeIntervalSinceNow: -3 * 60 * 60), nil]
        for previousCheck in previousChecks {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("assured-update-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let destination = directory.appendingPathComponent("payload.bin")
            let installed = Data("installed-a".utf8)
            let replacement = Data("remote-b".utf8)
            try installed.write(to: destination)
            let download = Downloadable(
                url: URL(string: "https://assured-update.test/payload.bin")!,
                name: "Assured update", localDestination: destination,
                metadataStore: ValidatorMetadataStore(backing: ValidatorMetadataBacking(loadFailureCount: 0))
            )
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ETagOnlyHEADURLProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let attempts = SuccessfulRemoteAttemptExecutor(etag: "remote-b", payload: replacement)
            let controller = DownloadController(session: session, attemptExecutor: { download, session in
                try await attempts.execute(download: download, session: session)
            })

            await controller.finishDownload(download, etag: "installed-a")
            download.lastCheckedETagAt = Date()
            await controller.ensureDownloaded(download: download)
            XCTAssertTrue(controller.assuredDownloads.contains(download))
            XCTAssertEqual(try Data(contentsOf: destination), installed)
            let recentCheckCount = await attempts.count()
            XCTAssertEqual(recentCheckCount, 0, "A recent check must retain the installed artifact")

            download.lastCheckedETagAt = previousCheck
            download.shouldCheckForUpdates = false
            await controller.ensureDownloaded(download: download)
            let disabledCheckCount = await attempts.count()
            XCTAssertEqual(disabledCheckCount, 0, "Disabled update checks must remain disabled")

            download.shouldCheckForUpdates = true
            await controller.ensureDownloaded(download: download)
            let updateCount = await attempts.count()
            XCTAssertEqual(updateCount, 1, "Prior assurance must not suppress a due update check")
            XCTAssertEqual(try Data(contentsOf: destination), replacement)
            XCTAssertEqual(download.lastDownloadedETag, "remote-b")
            XCTAssertNotNil(download.lastCheckedETagAt)
            XCTAssertTrue(download.isFinishedProcessing)
        }
    }

    @MainActor
    func testStaleBackgroundDownloadNotificationLeavesAdmissionOpen() async {
        let controller = DownloadController()
        await controller.handleAppLifecycleNotification(.background) { false }
        let suspended = await controller.backgroundWorkIsSuspended
        XCTAssertFalse(suspended)
    }

    @MainActor
    func testOlderDownloadPauseCannotOverrideNewerActivation() async throws {
        let controller = DownloadController()
        let source = AppLifecycleNotificationSource()
        let pause = try XCTUnwrap(source.notification(for: .background) { true })
        let activation = try XCTUnwrap(source.notification(for: .active) { true })
        await controller.applyAppLifecycleNotification(activation)
        await controller.applyAppLifecycleNotification(pause)
        let suspended = await controller.backgroundWorkIsSuspended
        XCTAssertFalse(suspended)
    }

    @MainActor
    func testOlderDownloadActivationCannotReopenNewerPause() async throws {
        let controller = DownloadController()
        let source = AppLifecycleNotificationSource()
        let activation = try XCTUnwrap(source.notification(for: .active) { true })
        let pause = try XCTUnwrap(source.notification(for: .background) { true })
        await controller.applyAppLifecycleNotification(pause)
        await controller.applyAppLifecycleNotification(activation)
        let suspended = await controller.backgroundWorkIsSuspended
        XCTAssertTrue(suspended)
    }

    @MainActor
    func testDownloadLifecycleRechecksStateAfterActorHop() async {
        let controller = DownloadController()
        var checks = 0
        await controller.handleAppLifecycleNotification(.background) {
            checks += 1
            return checks == 1
        }
        let suspended = await controller.backgroundWorkIsSuspended
        XCTAssertFalse(suspended, "A background result that became stale during delivery cannot close admission")
    }

    @MainActor
    func testCancelledDownloadNotificationCannotPauseWork() async {
        let controller = DownloadController()
        let notification = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await controller.handleAppLifecycleNotification(.background) { true }
        }
        await notification.value
        let suspended = await controller.backgroundWorkIsSuspended
        XCTAssertFalse(suspended)
    }

    @MainActor
    func testCurrentDownloadNotificationsPauseThenReopenAdmission() async {
        let controller = DownloadController()
        await controller.handleAppLifecycleNotification(.background) { true }
        let paused = await controller.backgroundWorkIsSuspended
        XCTAssertTrue(paused)
        await controller.handleAppLifecycleNotification(.active) { true }
        let resumed = await controller.backgroundWorkIsSuspended
        XCTAssertFalse(resumed)
    }

    @MainActor
    func testDownloadNotificationsRecoverInterruptedTransferAndRejectOldPause() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = expectation(description: "transfer held during cancellation cleanup")
        let restarted = expectation(description: "transfer restarted after current activation")
        let executor = SuspendedTransferAttemptExecutor(started: started, restarted: restarted)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(session: session, attemptExecutor: { download, _ in
            try await executor.execute(download: download)
        })
        let download = Downloadable(
            url: URL(string: "https://notification-recovery.test/payload.bin")!,
            name: "Notification recovery",
            localDestination: directory.appendingPathComponent("payload.bin")
        )
        let original = Task { await controller.download(download) }
        await fulfillment(of: [started], timeout: 3)
        let source = AppLifecycleNotificationSource()
        let pause = try XCTUnwrap(source.notification(for: .background) { true })
        await controller.applyAppLifecycleNotification(pause)
        let activation = try XCTUnwrap(source.notification(for: .active) { true })
        let foreground = Task {
            await controller.applyAppLifecycleNotification(activation)
        }
        await executor.releaseCanceledTransfer()
        await original.value
        await foreground.value
        await fulfillment(of: [restarted], timeout: 3)
        await controller.applyAppLifecycleNotification(pause)

        let suspended = await controller.backgroundWorkIsSuspended
        let attempts = await executor.attemptCount()
        let state = await MainActor.run { (download.isFinishedProcessing, download.isFailed) }
        XCTAssertFalse(suspended)
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(state.0)
        XCTAssertFalse(state.1)
        XCTAssertEqual(try Data(contentsOf: download.localDestination), Data("foreground-retry".utf8))
    }

    @MainActor
    func testSupersededDownloadPausePreservesInFlightTransfer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = expectation(description: "original transfer started")
        let completed = expectation(description: "original transfer completed")
        let executor = SuspendedTransferAttemptExecutor(started: started, restarted: completed)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(session: session, attemptExecutor: { download, _ in
            try await executor.execute(download: download)
        })
        let download = Downloadable(
            url: URL(string: "https://notification-recovery.test/payload.bin")!,
            name: "Obsolete pause",
            localDestination: directory.appendingPathComponent("payload.bin")
        )
        let original = Task { await controller.download(download) }
        await fulfillment(of: [started], timeout: 3)
        let source = AppLifecycleNotificationSource()
        let pause = try XCTUnwrap(source.notification(for: .background) { true })
        let activation = try XCTUnwrap(source.notification(for: .active) { true })
        // Foreground was published before the component received background.
        // That obsolete delivery must not interrupt an otherwise valid transfer.
        await controller.applyAppLifecycleNotification(pause)
        let suspended = await controller.backgroundWorkIsSuspended
        XCTAssertFalse(suspended)
        let foreground = Task {
            await controller.applyAppLifecycleNotification(activation)
        }
        await executor.releaseCanceledTransfer()
        await original.value
        await foreground.value
        await fulfillment(of: [completed], timeout: 3)

        let attempts = await executor.attemptCount()
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(download.isFinishedProcessing)
        XCTAssertFalse(download.isFailed)
        XCTAssertEqual(try Data(contentsOf: download.localDestination), Data("foreground-retry".utf8))
    }

    func testPinnedArtifactSurvivesMissingOrChangedHTTPValidatorWithoutReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinned-artifact-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data("verified-dictionary".utf8)
        let checksum = Insecure.SHA1.hash(data: payload).map { String(format: "%02x", $0) }.joined()

        let installedETags: [String?] = [nil, "obsolete-validator"]
        for hasMarker in [false, true] {
            for installedETag in installedETags {
                let destination = directory.appendingPathComponent(UUID().uuidString + ".realm")
                try payload.write(to: destination)
                let initialAttributes = try FileManager.default.attributesOfItem(atPath: destination.path)
                let download = Downloadable(
                    url: URL(string: "https://pinned-artifact.test/\(UUID()).realm")!,
                    name: "Pinned dictionary", localDestination: destination,
                    localDestinationChecksum: checksum,
                    metadataStore: ValidatorMetadataStore(backing: ValidatorMetadataBacking(
                        metadata: DownloadMetadata(lastDownloadedETag: installedETag), loadFailureCount: 0
                    ))
                )
                if hasMarker { try download.ensureVerifiedLocalDestinationChecksum() }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [ETagOnlyHEADURLProtocol.self]
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }
                let attempts = SuccessfulRemoteAttemptExecutor(etag: "remote-b", payload: payload)
                let controller = DownloadController(session: session, attemptExecutor: { download, session in
                    try await attempts.execute(download: download, session: session)
                })

                await controller.ensureDownloaded(download: download)

                let count = await attempts.count()
                XCTAssertEqual(count, 0, "Verified pinned bytes must survive HTTP validator drift")
                XCTAssertTrue(download.hasVerifiedLocalDestinationChecksumMarker())
                XCTAssertEqual(try Data(contentsOf: destination), payload)
                let finalAttributes = try FileManager.default.attributesOfItem(atPath: destination.path)
                XCTAssertEqual(finalAttributes[.systemFileNumber] as? NSNumber,
                               initialAttributes[.systemFileNumber] as? NSNumber)
                let state = await MainActor.run {
                    (download.isFinishedProcessing, download.lastDownloadedETag, download.lastCheckedETagAt)
                }
                XCTAssertTrue(state.0)
                XCTAssertEqual(state.1, installedETag)
                XCTAssertNil(state.2, "A skipped remote check must not manufacture HTTP metadata")
            }
        }
    }

    func testPinnedArtifactStillRepairsCorruptionBeforeSkippingRemoteCheck() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinned-repair-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data("verified-dictionary".utf8)
        let checksum = Insecure.SHA1.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let destination = directory.appendingPathComponent("dictionary.realm")
        try Data("corrupt-dictionary".utf8).write(to: destination)
        let download = Downloadable(
            url: URL(string: "https://pinned-repair.test/\(UUID()).realm")!,
            name: "Pinned repair", localDestination: destination,
            localDestinationChecksum: checksum,
            metadataStore: ValidatorMetadataStore(backing: ValidatorMetadataBacking(loadFailureCount: 0))
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ETagOnlyHEADURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let attempts = SuccessfulRemoteAttemptExecutor(etag: "repaired", payload: payload)
        let controller = DownloadController(session: session, attemptExecutor: { download, session in
            try await attempts.execute(download: download, session: session)
        })

        await controller.ensureDownloaded(download: download)

        let count = await attempts.count()
        XCTAssertEqual(count, 1, "Repair must still replace corrupt pinned bytes exactly once")
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertTrue(download.hasVerifiedLocalDestinationChecksumMarker())
    }

    func testInvalidHEADResponseCannotPublishFileSizeOrUpdateValidators() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InvalidMetadataHEADURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(session: session)

        for kind in ["404", "503", "206", "range", "multipart"] {
            let download = Downloadable(
                url: URL(string: "https://metadata-head.test/\(UUID())/\(kind)")!,
                name: "Invalid metadata response",
                localDestination: FileManager.default.temporaryDirectory
                    .appendingPathComponent("missing-\(UUID())")
            )
            await MainActor.run { download.fileSize = 456 }
            do {
                try await download.fetchRemoteFileSize(session: session)
                XCTFail("Accepted invalid HEAD response: \(kind)")
            } catch {
                XCTAssertTrue(error is URLResourceDownloadHTTPError || error is DownloadResponseAdmissionError,
                    "Unexpected failure for \(kind): \(error)")
            }
            let fileSize = await MainActor.run { download.fileSize }
            XCTAssertEqual(fileSize, 456, "Invalid HEAD must preserve existing size for \(kind)")
            let result = await controller.checkRemoteModification(for: download)
            guard case .unavailable = result else {
                XCTFail("Invalid HEAD validators admitted for \(kind)")
                continue
            }
        }
    }

    func testRemoteFileSizeLeavesUnknownContentLengthUnset() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnknownLengthHEADURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let download = Downloadable(
            url: URL(string: "https://content-length.test/payload")!,
            name: "Unknown length",
            localDestination: FileManager.default.temporaryDirectory
                .appendingPathComponent("missing-\(UUID().uuidString)")
        )

        try await download.fetchRemoteFileSize(session: session)

        let fileSize = await MainActor.run { download.fileSize }
        XCTAssertNil(fileSize)
    }

    func testRemoteFileSizePublishesSuccessfulWholeResponseLength() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InvalidMetadataHEADURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let download = Downloadable(
            url: URL(string: "https://metadata-head.test/200")!,
            name: "Known length",
            localDestination: FileManager.default.temporaryDirectory
                .appendingPathComponent("missing-\(UUID())")
        )
        try await download.fetchRemoteFileSize(session: session)
        let fileSize = await MainActor.run { download.fileSize }
        XCTAssertEqual(fileSize, 123)
    }

    func testDownloadableIdentityUsesStandardizedSourceAndDestination() {
        let sourceURL = URL(string: "https://identity.test/catalog/../dictionary.zip")!
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("identity", isDirectory: true)
            .appendingPathComponent("../dictionary.zip")
        let renamed = Downloadable(
            url: sourceURL.standardized,
            name: "Renamed dictionary",
            localDestination: destination.standardizedFileURL
        )
        let original = Downloadable(
            url: sourceURL,
            name: "Original dictionary",
            localDestination: destination
        )
        let otherDestination = Downloadable(
            url: sourceURL,
            name: "Original dictionary",
            localDestination: destination.appendingPathExtension("other")
        )

        XCTAssertEqual(original.id, renamed.id)
        XCTAssertEqual(Set([original, renamed]).count, 1)
        XCTAssertNotEqual(original.id, otherDestination.id)
        XCTAssertEqual(Set([original, otherDestination]).count, 2)
        XCTAssertEqual(
            DownloadOperationKey(taskDescription: original.id.taskDescription),
            original.id
        )
    }

    @MainActor
    func testDownloadIdentityRemainsStableAcrossFileAndPublishedStateChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("dictionary.zip")
        let source = URL(string: "https://identity.test/dictionary.zip")!
        let download = Downloadable(url: source, name: "Dictionary", localDestination: destination)
        let equivalent = Downloadable(url: source, name: "Renamed", localDestination: destination)
        let key = download.id
        var retained = Set([download])
        try Data("installed payload".utf8).write(to: destination)
        download.isActive = true
        download.isFinishedDownloading = true
        download.isFinishedProcessing = true
        download.fileSize = 17
        XCTAssertEqual(download.id, key)
        XCTAssertTrue(retained.contains(equivalent))
        retained.formUnion([equivalent, download])
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained.remove(equivalent), download)
    }

    func testExecutionConfigurationNormalizesEquivalentInputs() {
        let sourceURL = URL(string: "https://identity.test/dictionary.zip")!
        let destination = URL(fileURLWithPath: "/tmp/configuration/dictionary.zip")
        let first = Downloadable(
            url: sourceURL,
            mirrorURL: URL(string: "https://mirror.test/catalog/../dictionary.zip")!,
            name: "First",
            localDestination: destination,
            localDestinationChecksum: " ABCD ",
            preservedLocalArtifactDirectories: [
                URL(fileURLWithPath: "/tmp/generated/one/../two"),
                URL(fileURLWithPath: "/tmp/generated/three")
            ],
            metadataStore: UserDefaultsDownloadableMetadataStore(
                metadataCacheNamespace: "shared-namespace"
            )
        )
        let second = Downloadable(
            url: sourceURL,
            mirrorURL: URL(string: "https://mirror.test/dictionary.zip")!,
            name: "Second",
            localDestination: destination,
            localDestinationChecksum: "abcd",
            preservedLocalArtifactDirectories: [
                URL(fileURLWithPath: "/tmp/generated/three"),
                URL(fileURLWithPath: "/tmp/generated/two")
            ],
            metadataStore: UserDefaultsDownloadableMetadataStore(
                metadataCacheNamespace: "shared-namespace"
            )
        )

        XCTAssertEqual(first.executionConfigurationSignature, second.executionConfigurationSignature)
    }

    @MainActor
    func testExactDescriptorCancellationLeavesSameSourceOtherDestinationRunning() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingDownloadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(session: session)
        let started = expectation(description: "Both destination variants started")
        started.expectedFulfillmentCount = 2
        HangingDownloadURLProtocol.didStart = { started.fulfill() }
        defer { HangingDownloadURLProtocol.didStart = nil }
        let sourceURL = URL(string: "https://cancellation.test/shared-source")!
        let firstDownload = Downloadable(
            url: sourceURL,
            name: "First",
            localDestination: URL(fileURLWithPath: "/tmp/first/shared-source")
        )
        let secondDownload = Downloadable(
            url: sourceURL,
            name: "Second",
            localDestination: URL(fileURLWithPath: "/tmp/second/shared-source")
        )
        let firstTask = session.dataTask(with: sourceURL)
        let secondTask = session.dataTask(with: sourceURL)
        firstTask.taskDescription = firstDownload.id.taskDescription
        secondTask.taskDescription = secondDownload.id.taskDescription
        firstTask.resume()
        secondTask.resume()
        await fulfillment(of: [started], timeout: 2)

        await controller.cancelInProgressDownload(firstDownload)

        XCTAssertNotEqual(firstTask.state, .running)
        XCTAssertEqual(secondTask.state, .running)
        await controller.cancelAllInProgressDownloads()
    }

    @MainActor
    func testFilteredCancellationLeavesOtherSessionTransfersRunning() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingDownloadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(session: session)
        let started = expectation(description: "Both transfers started")
        started.expectedFulfillmentCount = 2
        HangingDownloadURLProtocol.didStart = { started.fulfill() }
        defer { HangingDownloadURLProtocol.didStart = nil }
        let firstURL = URL(string: "https://cancellation.test/first")!
        let secondURL = URL(string: "https://cancellation.test/second")!
        let first = session.dataTask(with: firstURL)
        let second = session.dataTask(with: secondURL)
        first.taskDescription = firstURL.absoluteString
        second.taskDescription = secondURL.absoluteString
        first.resume()
        second.resume()
        await fulfillment(of: [started], timeout: 2)

        await controller.cancelInProgressDownloads(matchingSourceURL: firstURL)
        XCTAssertNotEqual(first.state, .running)
        XCTAssertEqual(second.state, .running)
        await controller.cancelAllInProgressDownloads()
        XCTAssertNotEqual(second.state, .running)
    }

    func testMissingInstalledETagRequiresGETBeforePublishingRemoteETag() async throws {
        try await assertMissingInstalledETagRequiresGET(loadFailureCount: 0)
    }

    func testMetadataLoadFailureRequiresGETBeforePublishingRemoteETag() async throws {
        try await assertMissingInstalledETagRequiresGET(loadFailureCount: 1)
    }

    func testKnownEqualETagWithoutInstalledReceiptForcesGET() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-known-validator-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let localA = Data("installed-a".utf8)
        let destination = temporaryDirectory.appendingPathComponent("payload.bin")
        try localA.write(to: destination)
        let metadataBacking = ValidatorMetadataBacking(
            metadata: DownloadMetadata(lastDownloadedETag: "remote-b"),
            loadFailureCount: 0
        )
        let download = Downloadable(
            url: URL(string: "https://swiftui-downloads-known-validator.test/payload.bin")!,
            name: "Known Installed Validator",
            localDestination: destination,
            metadataStore: ValidatorMetadataStore(backing: metadataBacking)
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ETagOnlyHEADURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let attemptExecutor = SuccessfulRemoteAttemptExecutor(
            etag: "unexpected-replacement"
        )
        let controller = DownloadController(
            session: session,
            attemptExecutor: { download, session in
                try await attemptExecutor.execute(download: download, session: session)
            }
        )

        await controller.ensureDownloaded(download: download)

        let replacementCount = await attemptExecutor.count()
        XCTAssertEqual(replacementCount, 1)
        XCTAssertEqual(
            try Data(contentsOf: destination),
            Data("replacement-payload".utf8)
        )
        let installedETag = await MainActor.run { download.lastDownloadedETag }
        XCTAssertEqual(installedETag, "unexpected-replacement")
    }

    func testKnownEqualETagWithMatchingInstalledReceiptSkipsGET() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-known-receipt-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let localA = Data("installed-a".utf8)
        let destination = temporaryDirectory.appendingPathComponent("payload.bin")
        try localA.write(to: destination)
        let metadataBacking = ValidatorMetadataBacking(loadFailureCount: 0)
        let url = URL(
            string: "https://swiftui-downloads-known-receipt.test/payload.bin"
        )!
        let metadataStore = ValidatorMetadataStore(backing: metadataBacking)
        let download = Downloadable(
            url: url,
            name: "Known Installed Receipt",
            localDestination: destination,
            metadataStore: metadataStore
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ETagOnlyHEADURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let attemptExecutor = SuccessfulRemoteAttemptExecutor(
            etag: "unexpected-replacement"
        )
        let controller = DownloadController(
            session: session,
            attemptExecutor: { download, session in
                try await attemptExecutor.execute(download: download, session: session)
            }
        )

        await controller.finishDownload(download, etag: "remote-b")
        XCTAssertNotNil(
            try metadataStore.installedArtifactReceipt(
                sourceURL: url,
                destinationURL: destination
            )
        )

        await controller.ensureDownloaded(download: download)

        let replacementCount = await attemptExecutor.count()
        XCTAssertEqual(replacementCount, 0)
        XCTAssertEqual(try Data(contentsOf: destination), localA)
        let installedETag = await MainActor.run { download.lastDownloadedETag }
        XCTAssertEqual(installedETag, "remote-b")    }

    func testForeignReplacementInvalidatesReceiptAndForcesGET() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-foreign-replacement-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let destination = temporaryDirectory.appendingPathComponent("payload.bin")
        try Data("installed-a".utf8).write(to: destination)
        let metadataBacking = ValidatorMetadataBacking(loadFailureCount: 0)
        let url = URL(
            string: "https://swiftui-downloads-foreign-replacement.test/payload.bin"
        )!
        let metadataStore = ValidatorMetadataStore(backing: metadataBacking)
        let originalDownload = Downloadable(
            url: url,
            name: "Original artifact",
            localDestination: destination,
            metadataStore: metadataStore
        )
        let setupSession = URLSession(configuration: .ephemeral)
        let setupController = DownloadController(session: setupSession)
        await setupController.finishDownload(originalDownload, etag: "remote-b")
        setupSession.invalidateAndCancel()

        try Data("foreign occupant".utf8).write(to: destination, options: .atomic)

        let replacementDownload = Downloadable(
            url: url,
            name: "Replacement artifact",
            localDestination: destination,
            metadataStore: metadataStore
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ETagOnlyHEADURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let remoteB = Data("remote-b".utf8)
        let attemptExecutor = SuccessfulRemoteAttemptExecutor(
            etag: "remote-b",
            payload: remoteB
        )
        let controller = DownloadController(
            session: session,
            attemptExecutor: { download, session in
                try await attemptExecutor.execute(download: download, session: session)
            }
        )

        await controller.ensureDownloaded(download: replacementDownload)

        let replacementCount = await attemptExecutor.count()
        XCTAssertEqual(replacementCount, 1)
        XCTAssertEqual(try Data(contentsOf: destination), remoteB)
        XCTAssertNotNil(
            try metadataStore.installedArtifactReceipt(
                sourceURL: url,
                destinationURL: destination
            )
        )
    }

    func testReceiptForSameSourceDoesNotAuthorizeDifferentDestination() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-destination-receipt-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let url = URL(
            string: "https://swiftui-downloads-destination-receipt.test/payload.bin"
        )!
        let firstDestination = temporaryDirectory.appendingPathComponent("first.bin")
        let secondDestination = temporaryDirectory.appendingPathComponent("second.bin")
        let installedBytes = Data("installed-a".utf8)
        try installedBytes.write(to: firstDestination)
        try installedBytes.write(to: secondDestination)
        let metadataStore = ValidatorMetadataStore(
            backing: ValidatorMetadataBacking(loadFailureCount: 0)
        )
        let firstDownload = Downloadable(
            url: url,
            name: "First destination",
            localDestination: firstDestination,
            metadataStore: metadataStore
        )
        let setupSession = URLSession(configuration: .ephemeral)
        let setupController = DownloadController(session: setupSession)
        await setupController.finishDownload(firstDownload, etag: "remote-b")
        setupSession.invalidateAndCancel()

        let secondDownload = Downloadable(
            url: url,
            name: "Second destination",
            localDestination: secondDestination,
            metadataStore: metadataStore
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ETagOnlyHEADURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let remoteB = Data("remote-b".utf8)
        let attemptExecutor = SuccessfulRemoteAttemptExecutor(
            etag: "remote-b",
            payload: remoteB
        )
        let controller = DownloadController(
            session: session,
            attemptExecutor: { download, session in
                try await attemptExecutor.execute(download: download, session: session)
            }
        )

        await controller.ensureDownloaded(download: secondDownload)

        let replacementCount = await attemptExecutor.count()
        XCTAssertEqual(replacementCount, 1)
        XCTAssertEqual(try Data(contentsOf: secondDestination), remoteB)
        XCTAssertEqual(try Data(contentsOf: firstDestination), installedBytes)
    }

    func testProductionGETHandsResponseValidatorsToInstalledArtifact()
    async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-production-get-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let destination = tempDirectory.appendingPathComponent("payload.bin")
        let download = Downloadable(
            url: URL(string: "https://swiftui-downloads-get.test/payload.bin")!,
            name: "Production GET Validators",
            localDestination: destination
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SuccessfulGETURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(session: session)

        await controller.download(download)

        let didComplete = try await download.awaitCompletionOrFailure()
        XCTAssertTrue(didComplete)
        XCTAssertEqual(
            try Data(contentsOf: destination),
            Data("get-response-payload".utf8)
        )
        let validators = await MainActor.run {
            (download.lastDownloadedETag, download.lastModifiedAt)
        }
        XCTAssertEqual(validators.0, "get-response-etag")
        XCTAssertEqual(
            validators.1,
            Date(timeIntervalSince1970: 1_924_992_000)
        )
        let receipt = try XCTUnwrap(
            download.metadataStore.installedArtifactReceipt(
                sourceURL: download.url,
                destinationURL: destination
            )
        )
        XCTAssertEqual(receipt.requestedSourceURL, download.url)
        XCTAssertEqual(receipt.finalResponseURL, download.url)
        XCTAssertEqual(receipt.destinationURL, destination.standardizedFileURL)
        XCTAssertEqual(
            receipt.byteCount,
            UInt64(Data("get-response-payload".utf8).count)
        )
        XCTAssertTrue(download.isReadyForImmediateLocalRead())
    }

    func testSuccessfulLastModifiedReplacementAdvancesInstalledBaseline()
    async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-modified-success-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let destination = tempDirectory.appendingPathComponent("payload.bin")
        try Data("installed-payload".utf8).write(to: destination)
        let download = Downloadable(
            url: URL(
                string: "https://swiftui-downloads-modified-success.test/payload.bin"
            )!,
            name: "Successful Modified Replacement",
            localDestination: destination
        )
        await download.waitForDownloadMetadata()
        await MainActor.run {
            download.lastDownloaded = Date(timeIntervalSince1970: 100)
            download.lastModifiedAt = Date(timeIntervalSince1970: 90)
            download.lastCheckedETagAt = nil
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LastModifiedOnlyHEADURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let attemptExecutor = SuccessfulRemoteAttemptExecutor(
            lastModified: Date(timeIntervalSince1970: 1_924_992_000)
        )
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
        let didComplete = try await download.awaitCompletionOrFailure()
        XCTAssertTrue(didComplete)
        let installedRemoteModifiedAt = await MainActor.run {
            download.lastModifiedAt
        }
        XCTAssertEqual(
            installedRemoteModifiedAt,
            Date(timeIntervalSince1970: 1_924_992_000)
        )
        XCTAssertEqual(
            try Data(contentsOf: destination),
            Data("replacement-payload".utf8)
        )

        let nextCheck = await controller.checkRemoteModification(for: download)
        guard case let .available(modified, _, _) = nextCheck else {
            return XCTFail("Expected a successful Last-Modified check")
        }
        XCTAssertFalse(modified)
    }

    func testFailedModifiedReplacementDoesNotAdvanceInstalledValidators()
    async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-modified-failure-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let destination = tempDirectory.appendingPathComponent("payload.bin")
        try Data("installed-payload".utf8).write(to: destination)
        let download = Downloadable(
            url: URL(
                string: "https://swiftui-downloads-modified.test/payload.bin.br"
            )!,
            name: "Failed Modified Replacement",
            localDestination: destination
        )
        await download.waitForDownloadMetadata()
        let installedAt = Date(timeIntervalSince1970: 100)
        let installedModifiedAt = Date(timeIntervalSince1970: 90)
        await MainActor.run {
            download.lastDownloaded = installedAt
            download.lastModifiedAt = installedModifiedAt
            download.lastDownloadedETag = "installed-etag"
            download.lastCheckedETagAt = nil
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModifiedHEADURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let attemptExecutor = EmptyCompressedRemoteAttemptExecutor()
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
        let completed = try await download.awaitCompletionOrFailure()
        XCTAssertFalse(completed)

        let state = await MainActor.run {
            (
                download.lastDownloaded,
                download.lastModifiedAt,
                download.lastDownloadedETag
            )
        }
        XCTAssertEqual(state.0, installedAt)
        XCTAssertEqual(state.1, installedModifiedAt)
        XCTAssertEqual(state.2, "installed-etag")
        let failedCheckTimestamp = await MainActor.run {
            download.lastCheckedETagAt
        }
        XCTAssertNil(
            failedCheckTimestamp,
            "A failed replacement must remain immediately retry-eligible"
        )
        XCTAssertEqual(
            try Data(contentsOf: destination),
            Data("installed-payload".utf8)
        )

        await controller.ensureDownloaded(download: download)
        let retryAttemptCount = await attemptExecutor.count()
        let retryCheckTimestamp = await MainActor.run {
            download.lastCheckedETagAt
        }
        XCTAssertEqual(retryAttemptCount, 2)
        XCTAssertNil(retryCheckTimestamp)
    }

    func testInstalledValidatorsComeFromGETWhenHEADDiffers() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-get-validators-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let destination = tempDirectory.appendingPathComponent("payload.bin")
        try Data("installed-payload".utf8).write(to: destination)
        let download = Downloadable(
            url: URL(string: "https://swiftui-downloads-get-validators.test/payload.bin")!,
            name: "GET Validators",
            localDestination: destination
        )
        await download.waitForDownloadMetadata()
        await MainActor.run {
            download.lastDownloaded = Date(timeIntervalSince1970: 100)
            download.lastDownloadedETag = "installed-etag"
            download.lastCheckedETagAt = nil
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModifiedHEADURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let getModifiedAt = Date(timeIntervalSince1970: 1_925_078_400)
        let attemptExecutor = SuccessfulRemoteAttemptExecutor(
            etag: "get-etag",
            lastModified: getModifiedAt
        )
        let controller = DownloadController(
            session: session,
            attemptExecutor: { download, session in
                try await attemptExecutor.execute(download: download, session: session)
            }
        )

        await controller.ensureDownloaded(download: download)

        let validators = await MainActor.run {
            (download.lastDownloadedETag, download.lastModifiedAt)
        }
        XCTAssertEqual(validators.0, "get-etag")
        XCTAssertEqual(validators.1, getModifiedAt)
    }

    func testSuccessfulGETWithoutETagClearsInstalledETag() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-absent-get-etag-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let destination = tempDirectory.appendingPathComponent("payload.bin")
        let download = Downloadable(
            url: URL(string: "https://swiftui-downloads-absent-get-etag.test/payload.bin")!,
            name: "Absent GET ETag",
            localDestination: destination
        )
        await download.waitForDownloadMetadata()
        await MainActor.run {
            download.lastDownloadedETag = "stale-etag"
            download.lastModifiedAt = Date(timeIntervalSince1970: 90)
        }

        let attemptExecutor = SuccessfulRemoteAttemptExecutor()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(
            session: session,
            attemptExecutor: { download, session in
                try await attemptExecutor.execute(download: download, session: session)
            }
        )

        await controller.download(download)

        let validators = await MainActor.run {
            (download.lastDownloadedETag, download.lastModifiedAt)
        }
        XCTAssertNil(validators.0)
        XCTAssertNil(validators.1)
    }

    func testUnavailableHEADDoesNotAdvanceSuccessfulCheckTimestamp() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-head-unavailable-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let destination = tempDirectory.appendingPathComponent("payload.bin")
        try Data("existing".utf8).write(to: destination)
        let download = Downloadable(
            url: URL(string: "https://swiftui-downloads-head.test/payload.bin")!,
            name: "Unavailable HEAD",
            localDestination: destination
        )
        let previousCheck = Date(timeIntervalSince1970: 123)
        await download.waitForDownloadMetadata()
        await MainActor.run {
            download.lastCheckedETagAt = previousCheck
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnavailableHEADURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(session: session)

        let result = await controller.checkRemoteModification(for: download)
        if case .unavailable = result {
            // Expected.
        } else {
            XCTFail("A non-success HEAD response must be unavailable")
        }
        await controller.ensureDownloaded(download: download)

        let recordedCheck = await MainActor.run { download.lastCheckedETagAt }
        XCTAssertEqual(recordedCheck, previousCheck)
    }

    func testRequestsArrivingAfterBackgroundDrainWaitForActivation() async throws {
        for request in ["download", "finish", "checksumRecovery", "ensure"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let executor = SuccessfulRemoteAttemptExecutor()
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let controller = DownloadController(session: session, attemptExecutor: { download, session in
                try await executor.execute(download: download, session: session)
            })
            let destination = directory.appendingPathComponent("payload.bin")
            let download = Downloadable(
                url: URL(string: "https://late-background.test/\(request)/payload.bin")!,
                name: request,
                localDestination: destination
            )
            await download.waitForDownloadMetadata()
            let installedPayload = Data("preserved-installed-artifact".utf8)
            if request == "finish" || request == "checksumRecovery" {
                try installedPayload.write(to: destination)
            }
            await controller.cancelAndDrainForBackgrounding()
            switch request {
            case "download": await controller.download(download)
            case "finish": await controller.finishDownload(download)
            case "checksumRecovery": await controller.recoverLocalChecksumFailure(for: download)
            default: await controller.ensureDownloaded(download: download)
            }

            let pausedAttempts = await executor.count()
            XCTAssertEqual(pausedAttempts, 0, request)
            let pausedState = await MainActor.run { (download.isFinishedProcessing, download.isFailed) }
            XCTAssertFalse(pausedState.0, request)
            XCTAssertFalse(pausedState.1, request)
            if FileManager.default.fileExists(atPath: destination.path) {
                XCTAssertEqual(try Data(contentsOf: destination), installedPayload, request)
            }
            await controller.resumeAfterBackgroundDrain(shouldResume: { false })
            let inactiveAttempts = await executor.count()
            XCTAssertEqual(inactiveAttempts, 0, "Rejected activation must keep \(request) deferred")
            await controller.resumeAfterBackgroundDrain(shouldResume: { true })
            let recovered = await MainActor.run { (download.isFinishedProcessing, download.isFailed) }
            XCTAssertTrue(recovered.0, request)
            XCTAssertFalse(recovered.1, request)
            if request == "checksumRecovery" {
                XCTAssertEqual(try Data(contentsOf: destination), Data("replacement-payload".utf8))
            }
        }
    }

    func testExplicitCancellationRemovesDeferredChecksumRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = SuccessfulRemoteAttemptExecutor()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(session: session, attemptExecutor: { download, session in
            try await executor.execute(download: download, session: session)
        })
        let download = Downloadable(
            url: URL(string: "https://cancel-deferred-checksum.test/payload.bin")!,
            name: "Canceled deferred recovery",
            localDestination: directory.appendingPathComponent("payload.bin")
        )
        let installed = Data("preserve-until-explicit-retry".utf8)
        try installed.write(to: download.localDestination)
        await controller.cancelAndDrainForBackgrounding()
        await controller.recoverLocalChecksumFailure(for: download)
        await controller.cancelInProgressDownload(download)
        await controller.resumeAfterBackgroundDrain(shouldResume: { true })

        let attempts = await executor.count()
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(try Data(contentsOf: download.localDestination), installed)
    }

    func testCancelingChecksumRecoveryCallerCancelsOwnedProducer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = expectation(description: "checksum recovery transfer started")
        let completedTransfer = expectation(description: "canceled transfer must not publish")
        completedTransfer.isInverted = true
        let executor = SuspendedTransferAttemptExecutor(started: started, restarted: completedTransfer)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(session: session, attemptExecutor: { download, _ in
            try await executor.execute(download: download)
        })
        let download = Downloadable(
            url: URL(string: "https://checksum-caller-cancellation.test/payload.bin")!,
            name: "Checksum cancellation",
            localDestination: directory.appendingPathComponent("payload.bin")
        )
        let recovery = Task { await controller.recoverLocalChecksumFailure(for: download) }
        await fulfillment(of: [started], timeout: 3)
        recovery.cancel()
        await executor.releaseCanceledTransfer()
        await recovery.value

        let state = await MainActor.run { (download.isFinishedProcessing, download.isFinishedDownloading) }
        XCTAssertFalse(state.0)
        XCTAssertFalse(state.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.localDestination.path))
        await fulfillment(of: [completedTransfer], timeout: 0.01)
    }

    func testSuspensionDrainWaitsForCanceledTransferCleanup() async throws {
        let started = expectation(description: "producer is held")
        let restarted = expectation(description: "no replacement producer during suspension")
        restarted.isInverted = true
        let executor = SuspendedTransferAttemptExecutor(started: started, restarted: restarted)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(session: session, attemptExecutor: { download, _ in
            try await executor.execute(download: download)
        })
        let download = Downloadable(
            url: URL(string: "https://suspension-drain.test/payload.bin")!,
            name: "Suspension drain",
            localDestination: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let producer = Task { await controller.ensureDownloaded(download: download) }
        await fulfillment(of: [started], timeout: 3)
        let drained = expectation(description: "all producer cleanup settled")
        let drain = Task {
            await controller.cancelAndDrainForBackgrounding()
            drained.fulfill()
        }
        // The executor cannot finish until explicitly released. Even a task
        // cancellation must not be mistaken for producer settlement.
        let premature = await XCTWaiter.fulfillment(of: [drained], timeout: 0.05)
        XCTAssertEqual(premature, .timedOut)
        await executor.releaseCanceledTransfer()
        await producer.value
        await drain.value
        await controller.resumeAfterBackgroundDrain(shouldResume: { false })
        let count = await executor.attemptCount()
        XCTAssertEqual(count, 1)
        let failed = await MainActor.run { download.isFailed }
        XCTAssertFalse(failed)
        await fulfillment(of: [restarted], timeout: 0.01)
    }

    func testForegroundRecoveryWaitsForCanceledProducerThenRestarts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = expectation(description: "transfer held during cancellation cleanup")
        let restarted = expectation(description: "replacement transfer")
        restarted.assertForOverFulfill = true
        let executor = SuspendedTransferAttemptExecutor(started: started, restarted: restarted)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(session: session, attemptExecutor: { download, _ in
            try await executor.execute(download: download)
        })
        let download = Downloadable(
            url: URL(string: "https://foreground-race.test/payload.bin")!,
            name: "Foreground overlap",
            localDestination: directory.appendingPathComponent("payload.bin")
        )
        let original = Task { await controller.ensureDownloaded(download: download) }
        await fulfillment(of: [started], timeout: 3)
        await controller.cancelLongRunningWorkForBackgrounding()
        let foreground = Task { await controller.resumeRecoverableDownloadsAfterForegrounding() }
        let duplicateForeground = Task { await controller.resumeRecoverableDownloadsAfterForegrounding() }
        // Give both notifications the canceled owner while its cleanup is held.
        await Task.yield()
        await executor.releaseCanceledTransfer()
        await original.value
        await foreground.value
        await duplicateForeground.value
        await fulfillment(of: [restarted], timeout: 3)
        let count = await executor.attemptCount()
        XCTAssertEqual(count, 2, "Exactly one replacement producer must run")
        let state = await MainActor.run { (download.isFinishedProcessing, download.isFailed) }
        XCTAssertTrue(state.0)
        XCTAssertFalse(state.1)
        XCTAssertEqual(try Data(contentsOf: download.localDestination), Data("foreground-retry".utf8))
    }

    @MainActor
    private final class RecoveryActivationState {
        var isActive = true
        var observedActivation = false
    }

    func testForegroundRecoveryRechecksActivationAfterProducerCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = expectation(description: "transfer held during cancellation cleanup")
        let restarted = expectation(description: "replacement transfer after real activation")
        let executor = SuspendedTransferAttemptExecutor(started: started, restarted: restarted)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(session: session, attemptExecutor: { download, _ in
            try await executor.execute(download: download)
        })
        let download = Downloadable(
            url: URL(string: "https://stale-activation.test/payload.bin")!,
            name: "Stale activation",
            localDestination: directory.appendingPathComponent("payload.bin")
        )
        let original = Task { await controller.download(download) }
        await fulfillment(of: [started], timeout: 3)
        await controller.cancelLongRunningWorkForBackgrounding()
        let activation = await RecoveryActivationState()
        let admitted = expectation(description: "foreground request admitted")
        let foreground = Task {
            await controller.resumeAfterBackgroundDrain(shouldResume: {
                if !activation.observedActivation {
                    activation.observedActivation = true
                    admitted.fulfill()
                }
                return activation.isActive
            })
        }
        await fulfillment(of: [admitted], timeout: 3)
        // The original producer still owns cleanup. Deactivate before releasing
        // it, without delivering another cancellation generation to the actor.
        await MainActor.run { activation.isActive = false }
        await executor.releaseCanceledTransfer()
        await original.value
        await foreground.value
        let staleCount = await executor.attemptCount()
        XCTAssertEqual(staleCount, 1, "A stale activation must not start another transfer")

        // The stale request must leave direct, non-assured work recoverable.
        await MainActor.run { activation.isActive = true }
        await controller.resumeAfterBackgroundDrain(shouldResume: { activation.isActive })
        await fulfillment(of: [restarted], timeout: 3)
        let recoveredCount = await executor.attemptCount()
        XCTAssertEqual(recoveredCount, 2)
        XCTAssertEqual(try Data(contentsOf: download.localDestination), Data("foreground-retry".utf8))
    }

    func testInterruptedDownloadCanRecoverWithoutBackgrounding() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let download = Downloadable(
            url: URL(string: "https://interrupted.test/payload.bin")!,
            name: "Interrupted transfer",
            localDestination: directory.appendingPathComponent("payload.bin")
        )
        let executor = InterruptedThenSuccessfulAttemptExecutor()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(session: session, attemptExecutor: { download, _ in
            try await executor.execute(download: download)
        })
        await controller.ensureDownloaded(download: download)
        let interrupted = await MainActor.run { (download.isFailed, download.failureMessage) }
        XCTAssertTrue(interrupted.0)
        XCTAssertEqual(interrupted.1, "Download interrupted. Please retry.")
        // Activation retries an assured failure without a Retry tap or a
        // preceding background transition.
        await controller.resumeAfterBackgroundDrain(shouldResume: { true })
        let recovered = await MainActor.run { (download.isFailed, download.isFinishedProcessing, download.failureMessage) }
        XCTAssertFalse(recovered.0)
        XCTAssertTrue(recovered.1)
        XCTAssertNil(recovered.2)
        XCTAssertEqual(try Data(contentsOf: download.localDestination), Data("recovered-download".utf8))
    }

    func testBackgroundCancellationDoesNotPublishFailureAndResumesTransfer() async throws {
        try await exerciseBackgroundCancellation(assureDownload: true)
    }

    func testBackgroundCancellationResumesDirectDownloadOutsideAssuranceList() async throws {
        try await exerciseBackgroundCancellation(assureDownload: false)
    }

    private func exerciseBackgroundCancellation(assureDownload: Bool) async throws {
        let started = expectation(description: "initial transfer started")
        let resumed = expectation(description: "foreground transfer restarted")
        HangingDownloadURLProtocol.didStart = { started.fulfill() }
        defer {
            HangingDownloadURLProtocol.didStart = nil
            HangingDownloadURLProtocol.didStop = nil
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-download-\(UUID().uuidString)")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingDownloadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(session: session)
        let download = Downloadable(
            url: URL(string: "https://background.test/payload.bin")!,
            name: "Background recovery",
            localDestination: directory.appendingPathComponent("payload.bin")
        )
        let operation = Task {
            if assureDownload {
                await controller.ensureDownloaded(download: download)
            } else {
                await controller.download(download)
            }
        }
        await fulfillment(of: [started], timeout: 3)
        await controller.cancelLongRunningWorkForBackgrounding()
        await operation.value
        let paused = await MainActor.run { (download.isFailed, download.failureMessage) }
        XCTAssertFalse(paused.0, "Background suspension is not a failed download")
        XCTAssertNil(paused.1, "Do not show CancellationError for app backgrounding")
        HangingDownloadURLProtocol.didStart = { resumed.fulfill() }
        let foreground = Task { await controller.resumeRecoverableDownloadsAfterForegrounding() }
        await fulfillment(of: [resumed], timeout: 3)
        await controller.cancelAllInProgressDownloads()
        await foreground.value
    }

    func testCancellingControllerTaskCancelsUnderlyingURLSessionTask() async throws {
        let started = expectation(description: "request started")
        let stopped = expectation(description: "request cancelled")
        HangingDownloadURLProtocol.didStart = { started.fulfill() }
        HangingDownloadURLProtocol.didStop = { stopped.fulfill() }
        defer {
            HangingDownloadURLProtocol.didStart = nil
            HangingDownloadURLProtocol.didStop = nil
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-parent-cancel-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingDownloadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(session: session)
        let download = Downloadable(
            url: URL(string: "https://swiftui-downloads-cancel.test/payload.bin")!,
            name: "Parent Cancellation",
            localDestination: tempDirectory.appendingPathComponent("payload.bin")
        )

        let operation = Task {
            await controller.download(download)
        }
        await fulfillment(of: [started], timeout: 2)
        operation.cancel()
        await operation.value
        await fulfillment(of: [stopped], timeout: 2)

        let state = await MainActor.run {
            (download.isFailed, download.isFinishedDownloading)
        }
        XCTAssertTrue(state.0)
        XCTAssertFalse(state.1)
    }

    func testInvalidateLocalArtifactsCancelsAndFencesOwnedTransfer() async throws {
        let started = expectation(description: "request started")
        let stopped = expectation(description: "request cancelled")
        HangingDownloadURLProtocol.didStart = { started.fulfill() }
        HangingDownloadURLProtocol.didStop = { stopped.fulfill() }
        defer {
            HangingDownloadURLProtocol.didStart = nil
            HangingDownloadURLProtocol.didStop = nil
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-invalidate-owned-transfer-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingDownloadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(session: session)
        let download = Downloadable(
            url: URL(string: "https://swiftui-downloads-invalidate.test/payload.bin")!,
            name: "Invalidate Owned Transfer",
            localDestination: tempDirectory.appendingPathComponent("payload.bin")
        )

        let operation = Task {
            await controller.download(download)
        }
        await fulfillment(of: [started], timeout: 2)

        try await controller.invalidateLocalArtifacts(for: download)
        await operation.value
        await fulfillment(of: [stopped], timeout: 2)

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
            // The cancelled attempt did not republish terminal failure state.
        } else {
            XCTFail("An invalidated transfer must remain uninitiated")
        }
    }

    private func assertMissingInstalledETagRequiresGET(
        loadFailureCount: Int
    ) async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-validator-authority-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let localA = Data("installed-a".utf8)
        let remoteB = Data("remote-b".utf8)
        let destination = temporaryDirectory.appendingPathComponent("payload.bin")
        try localA.write(to: destination)
        let url = URL(string: "https://swiftui-downloads-validator.test/payload.bin")!
        let metadataBacking = ValidatorMetadataBacking(
            loadFailureCount: loadFailureCount
        )
        let download = Downloadable(
            url: url,
            name: "Unknown Installed Validator",
            localDestination: destination,
            metadataStore: ValidatorMetadataStore(backing: metadataBacking)
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ETagOnlyHEADURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let attemptExecutor = SuccessfulRemoteAttemptExecutor(
            etag: "remote-b",
            payload: remoteB
        )
        let controller = DownloadController(
            session: session,
            attemptExecutor: { download, session in
                try await attemptExecutor.execute(download: download, session: session)
            }
        )

        await controller.ensureDownloaded(download: download)
        try await download.waitForDownloadMetadataPersistence()

        let replacementCount = await attemptExecutor.count()
        XCTAssertEqual(replacementCount, 1)
        XCTAssertEqual(try Data(contentsOf: destination), remoteB)

        let freshDownload = Downloadable(
            url: url,
            name: "Fresh Validator Reader",
            localDestination: destination,
            metadataStore: ValidatorMetadataStore(backing: metadataBacking)
        )
        await freshDownload.waitForDownloadMetadata()
        let freshInstalledETag = await MainActor.run {
            freshDownload.lastDownloadedETag
        }
        XCTAssertEqual(freshInstalledETag, "remote-b")

        let knownEqualResult = await controller.checkRemoteModification(
            for: freshDownload
        )
        guard case let .available(modified, _, etag) = knownEqualResult else {
            return XCTFail("Expected the known validator check to be available")
        }
        XCTAssertFalse(modified)
        XCTAssertEqual(etag, "remote-b")
        let countAfterKnownEqualCheck = await attemptExecutor.count()
        XCTAssertEqual(countAfterKnownEqualCheck, 1)
    }

    func testUpdatingOneDestinationDoesNotHideUpdateFromSameSourceOtherDestination()
    async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-downloads-validator-destination-scope-" + UUID().uuidString,
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "validator-destination-scope-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let source = try XCTUnwrap(
            URL(string: "https://swiftui-downloads-validator-scope.test/payload.bin")
        )
        let destinationA = root.appendingPathComponent("a.bin")
        let destinationB = root.appendingPathComponent("b.bin")
        try Data("installed-a".utf8).write(to: destinationA)
        try Data("installed-b-old".utf8).write(to: destinationB)

        let store = UserDefaultsDownloadableMetadataStore(
            userDefaults: defaults,
            metadataCacheNamespace: "shared-operation-store"
        )
        let first = Downloadable(
            url: source,
            name: "First destination",
            localDestination: destinationA,
            metadataStore: store
        )
        let second = Downloadable(
            url: source,
            name: "Second destination",
            localDestination: destinationB,
            metadataStore: store
        )
        let setupSession = URLSession(configuration: .ephemeral)
        let setupController = DownloadController(session: setupSession)
        await setupController.finishDownload(first, etag: "remote-a")
        await setupController.finishDownload(second, etag: "remote-old")
        // Replace A through a real transfer; finishing an already completed
        // installed artifact is deliberately a no-op.
        let remoteB = Data("remote-b".utf8)
        let firstUpdate = SuccessfulRemoteAttemptExecutor(
            etag: "remote-b",
            payload: remoteB
        )
        let updateController = DownloadController(
            session: setupSession,
            attemptExecutor: { download, session in
                try await firstUpdate.execute(download: download, session: session)
            }
        )
        await updateController.download(first)
        try await first.waitForDownloadMetadataPersistence()
        try await second.waitForDownloadMetadataPersistence()
        setupSession.invalidateAndCancel()

        let validators = await MainActor.run {
            (first.lastDownloadedETag, second.lastDownloadedETag)
        }
        XCTAssertEqual(validators.0, "remote-b")
        XCTAssertEqual(validators.1, "remote-old")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ETagOnlyHEADURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let attemptExecutor = SuccessfulRemoteAttemptExecutor(
            etag: "remote-b",
            payload: remoteB
        )
        let controller = DownloadController(
            session: session,
            attemptExecutor: { download, session in
                try await attemptExecutor.execute(
                    download: download,
                    session: session
                )
            }
        )

        await controller.ensureDownloaded(download: second)

        let attemptCount = await attemptExecutor.count()
        XCTAssertEqual(attemptCount, 1)
        XCTAssertEqual(try Data(contentsOf: destinationB), remoteB)
        XCTAssertEqual(try Data(contentsOf: destinationA), remoteB)
        let secondETag = await MainActor.run { second.lastDownloadedETag }
        XCTAssertEqual(secondETag, "remote-b")
    }

}
