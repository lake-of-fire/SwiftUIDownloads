import CryptoKit
import XCTest
import Brotli
@testable import SwiftUIDownloads

private func sha1Hex(_ data: Data) -> String {
    Insecure.SHA1.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
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
        try FileManager.default.createDirectory(
            at: download.compressedFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: download.compressedFileURL, options: .atomic)
        await MainActor.run {
            download.downloadProgress = .completed(
                destinationLocation: download.compressedFileURL,
                etag: "empty-update",
                error: nil
            )
            download.isActive = false
            download.isFailed = false
            download.isFinishedDownloading = true
        }
        return DownloadTransferResult(
            destinationLocation: download.compressedFileURL,
            etag: "empty-update",
            lastModified: nil
        )
    }
}

private actor AsyncCompletionFlag {
    private var completed = false

    func markCompleted() { completed = true }
    func value() -> Bool { completed }
}

final class DownloadChecksumRecoveryTests: XCTestCase {
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
