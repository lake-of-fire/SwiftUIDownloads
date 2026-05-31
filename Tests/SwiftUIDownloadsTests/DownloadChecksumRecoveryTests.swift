import CryptoKit
import XCTest
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

    func execute(download: Downloadable, session _: URLSession) async throws {
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
    }

    func recordedAttemptCount() -> Int {
        attemptCount
    }
}

final class DownloadChecksumRecoveryTests: XCTestCase {
    func testRepairVerifiedLocalDestinationChecksumMarkerWritesMarkerForReadableFile() async throws {
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

        download.repairVerifiedLocalDestinationChecksumMarkerIfNeeded()

        let deadline = Date().addingTimeInterval(2)
        while !download.hasVerifiedLocalDestinationChecksumMarker() && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertTrue(download.hasVerifiedLocalDestinationChecksumMarker())
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

        await controller.finishDownload(download)
        let isComplete = try await download.awaitCompletionOrFailure()

        XCTAssertTrue(isComplete)
        XCTAssertEqual(try Data(contentsOf: destinationURL), expectedPayload)
        XCTAssertTrue(download.hasVerifiedLocalDestinationChecksumMarker())
        let attemptCount = await attemptExecutor.recordedAttemptCount()
        XCTAssertEqual(attemptCount, 1)
    }
}
