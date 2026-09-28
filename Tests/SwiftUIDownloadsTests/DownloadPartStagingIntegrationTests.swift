import Foundation
import XCTest
import Brotli
@testable import SwiftUIDownloads

/// Exercises production Downloadable/DownloadController wiring; requires the
/// Apple package graph. No network, app-group data, or production account is used.
@MainActor
final class DownloadPartStagingIntegrationTests: XCTestCase {
    private func fixture() throws -> (root: URL, store: UserDefaultsDownloadableMetadataStore) {
        let name = "DownloadPartStaging-" + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        return (root, UserDefaultsDownloadableMetadataStore(
            userDefaults: defaults, metadataCacheNamespace: name
        ))
    }

    func testDescriptorStagesArePartFilesScopedToSourceAndDestination() throws {
        let f = try fixture()
        let url = URL(string: "https://example.com/book.epub")!
        let destination = f.root.appendingPathComponent("book.epub")
        let first = Downloadable(url: url, name: "first", localDestination: destination, metadataStore: f.store)
        let renamed = Downloadable(url: url, name: "renamed", localDestination: destination, metadataStore: f.store)
        let otherSource = Downloadable(url: URL(string: "https://other.example/book.epub")!, name: "other", localDestination: destination, metadataStore: f.store)
        let otherDestination = Downloadable(url: url, name: "other", localDestination: f.root.appendingPathComponent("second.epub"), metadataStore: f.store)
        let operation = UUID()
        let stages = [first.uncompressedTransferStagingURL(operationID: operation),
                      first.compressedTransferStagingURL(operationID: operation),
                      first.decompressionStagingURL(operationID: operation)]
        XCTAssertEqual(Set(stages).count, 3)
        for stage in stages {
            XCTAssertEqual(stage.pathExtension, "part")
            XCTAssertTrue(DownloadStagingPaths.isDownloadArtifact(stage))
        }
        XCTAssertEqual(stages[0], renamed.uncompressedTransferStagingURL(operationID: operation))
        XCTAssertNotEqual(stages[0], otherSource.uncompressedTransferStagingURL(operationID: operation))
        XCTAssertNotEqual(stages[0], otherDestination.uncompressedTransferStagingURL(operationID: operation))
    }

    func testLocalTransferInstallsFullLengthFinalFilenameAndRemovesPart() async throws {
        let f = try fixture()
        let source = f.root.appendingPathComponent("input.txt")
        let bytes = Data("A completed download keeps the user's filename.".utf8)
        try bytes.write(to: source)
        let finalName = String(repeating: "a", count: 251) + ".txt"
        XCTAssertEqual(finalName.utf8.count, 255)
        let destination = f.root.appendingPathComponent(finalName)
        let download = Downloadable(url: source, name: "long filename", localDestination: destination, metadataStore: f.store)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let controller = DownloadController(session: session)
        await controller.download(download)
        XCTAssertFalse(download.isFailed, download.failureMessage ?? "")
        XCTAssertTrue(download.isFinishedProcessing)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(destination.lastPathComponent, finalName)
        let verified = await download.hasVerifiedInstalledArtifact()
        XCTAssertTrue(verified)
        let children = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil)
        XCTAssertFalse(children.contains(where: DownloadStagingPaths.isDownloadArtifact))
    }

    func testImporterSeesPartCandidateBeforePromotion() async throws {
        let f = try fixture()
        let source = f.root.appendingPathComponent("input.txt")
        let destination = f.root.appendingPathComponent("installed.txt")
        let bytes = Data("payload".utf8)
        try bytes.write(to: source)
        let download = ImportableDownloadable(
            url: source, name: "text", localDestination: destination,
            deleteAfterImport: false, metadataStore: f.store, isImported: { false },
            importHandler: { candidate, _ in
                XCTAssertEqual(candidate.pathExtension, "part")
                XCTAssertTrue(DownloadStagingPaths.isDownloadArtifact(candidate))
                XCTAssertEqual(try Data(contentsOf: candidate), bytes)
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            }
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        await DownloadController(session: session).download(download)
        XCTAssertFalse(download.isFailed, download.failureMessage ?? "")
        XCTAssertTrue(download.isFinishedProcessing)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testCompressedTransferAndExpansionBothUsePartUntilInstall() async throws {
        let f = try fixture()
        let source = f.root.appendingPathComponent("input.txt.br")
        let destination = f.root.appendingPathComponent("installed.txt")
        let payload = Data(repeating: 0x41, count: 1024)
        let compressed = try XCTUnwrap((payload as NSData).brotliCompressed())
        try compressed.write(to: source)
        let download = ImportableDownloadable(
            url: source, name: "compressed", localDestination: destination,
            deleteAfterImport: false, metadataStore: f.store, isImported: { false },
            importHandler: { candidate, _ in
                XCTAssertEqual(candidate.pathExtension, "part")
                XCTAssertTrue(candidate.lastPathComponent.contains(".expanded."))
                XCTAssertEqual(try Data(contentsOf: candidate), payload)
                let siblings = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil)
                let compressedStages = siblings.filter {
                    DownloadStagingPaths.isDownloadArtifact($0)
                        && $0.lastPathComponent.contains(".compressed.")
                }
                XCTAssertEqual(compressedStages.count, 1)
                XCTAssertEqual(compressedStages.first?.pathExtension, "part")
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            }
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        await DownloadController(session: session).download(download)
        XCTAssertFalse(download.isFailed, download.failureMessage ?? "")
        XCTAssertTrue(download.isFinishedProcessing)
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        let children = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil)
        XCTAssertFalse(children.contains(where: DownloadStagingPaths.isDownloadArtifact))
    }

    func testFailedImporterRetainsOldDestinationAndRemovesItsPart() async throws {
        let f = try fixture()
        let source = f.root.appendingPathComponent("input.txt")
        let destination = f.root.appendingPathComponent("installed.txt")
        let previous = Data("previous valid document".utf8)
        try Data("replacement".utf8).write(to: source)
        try previous.write(to: destination)
        let download = ImportableDownloadable(
            url: source, name: "text", localDestination: destination,
            deleteAfterImport: false, metadataStore: f.store, isImported: { false },
            importHandler: { candidate, _ in
                XCTAssertEqual(candidate.pathExtension, "part")
                throw CocoaError(.fileReadCorruptFile)
            }
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        await DownloadController(session: session).download(download)
        XCTAssertTrue(download.isFailed)
        XCTAssertEqual(try Data(contentsOf: destination), previous)
        let children = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil)
        XCTAssertFalse(children.contains(where: DownloadStagingPaths.isDownloadArtifact))
    }

    func testDeleteDoesNotTreatOrdinaryPrefixMatchesOrOtherOwnersAsTemporary() async throws {
        let f = try fixture()
        let source = URL(string: "https://example.com/book.epub")!
        let destination = f.root.appendingPathComponent("book.epub")
        let download = Downloadable(url: source, name: "book", localDestination: destination, metadataStore: f.store)
        let other = Downloadable(url: URL(string: "https://other.example/book.epub")!, name: "other", localDestination: destination, metadataStore: f.store)
        let keep = [
            f.root.appendingPathComponent("book.epub.downloading.notes.epub"),
            f.root.appendingPathComponent("book.epub.decompressing.notes.txt"),
            f.root.appendingPathComponent("book.epub.part"),
            other.uncompressedTransferStagingURL(operationID: UUID()),
        ]
        let remove = [
            destination,
            download.uncompressedTransferStagingURL(operationID: UUID()),
            download.compressedTransferStagingURL(operationID: UUID()),
            download.decompressionStagingURL(operationID: UUID()),
            f.root.appendingPathComponent("book.downloading.\(UUID()).epub"),
            f.root.appendingPathComponent("book.epub.decompressing.\(UUID())"),
        ]
        for url in keep + remove { try Data(url.lastPathComponent.utf8).write(to: url) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        _ = try await DownloadController(session: session).delete(download: download)
        for url in keep { XCTAssertEqual(try Data(contentsOf: url), Data(url.lastPathComponent.utf8)) }
        for url in remove { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent) }
    }
}
