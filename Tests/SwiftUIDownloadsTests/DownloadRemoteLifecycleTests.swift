import XCTest
@testable import SwiftUIDownloads

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

private actor SuccessfulRemoteAttemptExecutor {
    private let etag: String?
    private let lastModified: Date?

    init(etag: String? = nil, lastModified: Date? = nil) {
        self.etag = etag
        self.lastModified = lastModified
    }

    func execute(
        download: Downloadable,
        session _: URLSession
    ) async throws -> DownloadTransferResult {
        try Data("replacement-payload".utf8).write(
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
}

final class DownloadRemoteLifecycleTests: XCTestCase {
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
}
