import Foundation
import XCTest
import Brotli
@testable import SwiftUIDownloads

private actor OrphanImportGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var input: URL?

    func record(_ url: URL) { input = url }
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// Native controller coverage; not included in the Foundation-only runner.
@MainActor
final class DownloadOrphanControllerTests: XCTestCase {
    private func fixture() throws -> (
        location: DownloadDirectory, root: URL, controller: DownloadController,
        store: UserDefaultsDownloadableMetadataStore
    ) {
        let name = "SwiftUIDownloads-OrphanTests-\(UUID().uuidString)"
        let location = DownloadDirectory.documents(parentDirectoryName: name, groupIdentifier: nil)
        let root = location.directoryURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let session = URLSession(configuration: .ephemeral)
        addTeardownBlock {
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        return (location, root, DownloadController(session: session),
                UserDefaultsDownloadableMetadataStore(userDefaults: defaults, metadataCacheNamespace: name))
    }

    @discardableResult
    private func write(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: url)
        return url
    }

    func testExcludedDescriptorThroughAliasRetainsInstalledBytesAndGeneratedTree() async throws {
        let fixture = try fixture()
        let payload = try write("physical/book.txt", in: fixture.root)
        let generated = try write("physical/generated/index.bin", in: fixture.root)
        let stale = try write("physical/stale.bin", in: fixture.root)
        let alias = fixture.root.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: payload.deletingLastPathComponent())
        let download = Downloadable(
            url: try XCTUnwrap(URL(string: "https://orphan.test/book.txt")), name: "Book",
            localDestination: alias.appendingPathComponent("book.txt"),
            preservedLocalArtifactDirectories: [alias.appendingPathComponent("generated", isDirectory: true)],
            metadataStore: fixture.store
        )
        try await fixture.controller.deleteOrphanFiles(in: [fixture.location], excluding: [download])
        XCTAssertEqual(try Data(contentsOf: download.localDestination), Data("payload".utf8))
        XCTAssertEqual(try Data(contentsOf: generated), Data("payload".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testStandaloneProcessorProtectsSourceAndGeneratedArtifactsWithoutAssurance() async throws {
        try await exerciseStandaloneProcessor(cancelOwner: false)
    }

    func testCancelledProcessorRemainsProtectedUntilItsImporterUnwinds() async throws {
        try await exerciseStandaloneProcessor(cancelOwner: true)
    }

    private func exerciseStandaloneProcessor(cancelOwner: Bool) async throws {
        let fixture = try fixture()
        let payload = try write("book.txt", in: fixture.root)
        let generated = try write("generated/index.bin", in: fixture.root)
        let stale = try write("obsolete.bin", in: fixture.root)
        let gate = OrphanImportGate()
        let entered = expectation(description: "Standalone importer entered")
        let finished = expectation(description: "Standalone processor finished")
        let download = ImportableDownloadable(
            url: try XCTUnwrap(URL(string: "https://orphan.test/book.txt")), name: "Book",
            localDestination: payload,
            preservedLocalArtifactDirectories: [generated.deletingLastPathComponent()],
            deleteAfterImport: false, metadataStore: fixture.store, isImported: { false },
            importHandler: { input, _ in
                await gate.record(input)
                entered.fulfill()
                await gate.wait()
                XCTAssertEqual(try Data(contentsOf: input), Data("payload".utf8))
            }
        )
        let task = Task { await fixture.controller.finishDownload(download); finished.fulfill() }
        addTeardownBlock { task.cancel(); await gate.open() }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(fixture.controller.assuredDownloads.isEmpty)
        if cancelOwner { task.cancel() }
        do {
            try await fixture.controller.deleteOrphanFiles(in: [fixture.location])
        } catch { XCTFail("Orphan cleanup failed: \(error)") }
        XCTAssertEqual(try Data(contentsOf: payload), Data("payload".utf8))
        XCTAssertEqual(try Data(contentsOf: generated), Data("payload".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        await gate.open()
        await fulfillment(of: [finished], timeout: 5)
        if cancelOwner {
            XCTAssertTrue(download.isFailed)
        } else {
            XCTAssertTrue(download.isFinishedProcessing)
            XCTAssertFalse(download.isFailed)
        }
    }

    func testDirectLocalDownloadProtectsCandidateAndInputWithoutAssurance() async throws {
        let fixture = try fixture()
        let source = try write("source.txt", in: fixture.root)
        let destination = fixture.root.appendingPathComponent("installed.txt")
        let gate = OrphanImportGate()
        let entered = expectation(description: "Direct download importer entered")
        let finished = expectation(description: "Direct download finished")
        let download = ImportableDownloadable(
            url: source, name: "Direct", localDestination: destination,
            deleteAfterImport: false, metadataStore: fixture.store, isImported: { false },
            importHandler: { input, _ in
                await gate.record(input)
                entered.fulfill()
                await gate.wait()
                XCTAssertEqual(try Data(contentsOf: input), Data("payload".utf8))
            }
        )
        let task = Task { await fixture.controller.download(download); finished.fulfill() }
        addTeardownBlock { task.cancel(); await gate.open() }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(fixture.controller.assuredDownloads.isEmpty)
        let candidate = await gate.input
        XCTAssertEqual(candidate?.pathExtension, "part")
        do {
            try await fixture.controller.deleteOrphanFiles(in: [fixture.location])
        } catch { XCTFail("Orphan cleanup failed: \(error)") }
        XCTAssertEqual(try Data(contentsOf: source), Data("payload".utf8))
        if let candidate { XCTAssertEqual(try Data(contentsOf: candidate), Data("payload".utf8)) }
        await gate.open()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertFalse(download.isFailed)
        XCTAssertTrue(download.isFinishedProcessing)
        XCTAssertEqual(try Data(contentsOf: destination), Data("payload".utf8))
    }

    func testStandaloneBrotliProcessorProtectsExpandedCandidateWithoutAssurance() async throws {
        let fixture = try fixture()
        let destination = fixture.root.appendingPathComponent("expanded.txt")
        let compressed = try XCTUnwrap((Data("payload".utf8) as NSData).brotliCompressed())
        let gate = OrphanImportGate()
        let entered = expectation(description: "Expanded importer entered")
        let finished = expectation(description: "Expanded processor finished")
        let download = ImportableDownloadable(
            url: try XCTUnwrap(URL(string: "https://orphan.test/book.txt.br")), name: "Brotli",
            localDestination: destination, deleteAfterImport: false,
            metadataStore: fixture.store, isImported: { false },
            importHandler: { input, _ in
                await gate.record(input)
                entered.fulfill()
                await gate.wait()
                XCTAssertEqual(try Data(contentsOf: input), Data("payload".utf8))
            }
        )
        try compressed.write(to: download.compressedFileURL)
        let task = Task { await fixture.controller.finishDownload(download); finished.fulfill() }
        addTeardownBlock { task.cancel(); await gate.open() }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(fixture.controller.assuredDownloads.isEmpty)
        let candidate = await gate.input
        XCTAssertEqual(candidate?.pathExtension, "part")
        do {
            try await fixture.controller.deleteOrphanFiles(in: [fixture.location])
        } catch { XCTFail("Orphan cleanup failed: \(error)") }
        if let candidate { XCTAssertEqual(try Data(contentsOf: candidate), Data("payload".utf8)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: download.compressedFileURL.path))
        await gate.open()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertFalse(download.isFailed)
        XCTAssertTrue(download.isFinishedProcessing)
        XCTAssertEqual(try Data(contentsOf: destination), Data("payload".utf8))
    }

    func testCancelledPublicSweepPreservesFiles() async throws {
        let fixture = try fixture()
        let payload = try write("unused.bin", in: fixture.root)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await fixture.controller.deleteOrphanFiles(in: [fixture.location])
        }
        do { try await task.value; XCTFail("Cancelled sweep succeeded") }
        catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: payload), Data("payload".utf8))
    }

    func testPublicSweepPreservesRealmManagementThroughParentPruning() async throws {
        let fixture = try fixture()
        let payload = try write("unused/nested/store.realm.management/access.lock", in: fixture.root)
        let stale = try write("unused/old.bin", in: fixture.root)
        try await fixture.controller.deleteOrphanFiles(in: [fixture.location])
        XCTAssertEqual(try Data(contentsOf: payload), Data("payload".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }
}
