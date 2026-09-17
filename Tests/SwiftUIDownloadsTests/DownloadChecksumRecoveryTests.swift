import CryptoKit
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

    init(payloads: [Data]) throws {
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
            url.lastPathComponent.hasPrefix("payload.downloading.")
        })
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

        let controller = DownloadController()
        await MainActor.run { () -> Void in
            controller.assuredDownloads.insert(download)
        }

        try await controller.deleteOrphanFiles(in: [directory])

        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: download.checksumVerificationMarkerURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
    }

    func testOrphanCleanupPreservesGeneratedArtifactDirectoryAndDescendants() async throws {
        let parentName = "swiftui-downloads-generated-artifacts-\(UUID().uuidString)"
        let directory = DownloadDirectory.appSupport(
            parentDirectoryName: parentName,
            groupIdentifier: nil
        )
        let directoryURL = directory.directoryURL
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let destinationURL = directoryURL.appendingPathComponent("payload.bin")
        try Data("payload".utf8).write(to: destinationURL, options: .atomic)
        let generatedDirectoryURL = directoryURL.appendingPathComponent(
            ".runtime-snapshots",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: generatedDirectoryURL,
            withIntermediateDirectories: true
        )
        let generatedArtifactURL = generatedDirectoryURL
            .appendingPathComponent("payload.snapshot")
        try Data("snapshot".utf8).write(
            to: generatedArtifactURL,
            options: .atomic
        )
        let orphanURL = directoryURL.appendingPathComponent("orphan.tmp")
        try Data("orphan".utf8).write(to: orphanURL, options: .atomic)

        let download = Downloadable(
            url: URL(string: "https://swiftui-downloads.test/generated.bin")!,
            name: "Generated Artifacts",
            localDestination: destinationURL,
            preservedLocalArtifactDirectories: [generatedDirectoryURL]
        )
        let controller = DownloadController()
        await MainActor.run { () -> Void in
            controller.assuredDownloads.insert(download)
        }

        try await controller.deleteOrphanFiles(in: [directory])

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: generatedArtifactURL.path)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
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

        await controller.download(download)

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
