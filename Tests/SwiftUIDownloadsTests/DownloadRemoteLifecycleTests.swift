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
}
