import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import SwiftUIDownloads

private final class DirectoryListing {
    var afterListing: ((URL) throws -> Void)?

    func read(_ url: URL) throws -> [URL] {
        let result = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        try afterListing?(url)
        return result
    }
}

final class DownloadOrphanCleanupTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("orphan-cleanup-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @discardableResult
    private func write(_ name: String, in root: URL, text: String = "keep") throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func clean(_ root: URL, files: Set<URL> = [], directories: Set<URL> = [],
                       manager: DirectoryListing? = nil) throws {
        try DownloadOrphanCleanup.removeOrphans(in: [root], preservingFiles: files,
                                               preservingDirectories: directories, readDirectory: { url in
            if let manager { return try manager.read(url) }
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        })
    }

    private func assertKept(_ url: URL, text: String = "keep", file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Data(contentsOf: url), Data(text.utf8), file: file, line: line)
    }

    private func alias(to target: URL, in root: URL) throws -> URL {
        let url = root.appendingPathComponent("alias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        return url
    }

    func testPreservesPayloadCompressedFileAndMarkerWhileRemovingOrphans() throws {
        let root = try fixture()
        let files = try ["payload/book.epub", "payload/book.epub.br", "payload/book.epub.sha1verified.json"]
            .map { try write($0, in: root) }
        let orphan = try write("unused/nested/old.bin", in: root)
        try clean(root, files: Set(files))
        for url in files { try assertKept(url) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unused").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testPhysicalSweepHonorsFileProtectionThroughParentAlias() throws {
        let root = try fixture()
        let physical = root.appendingPathComponent("downloads", isDirectory: true)
        let kept = try write("book.epub", in: physical)
        let reference = try alias(to: physical, in: root).appendingPathComponent("book.epub")
        try clean(physical, files: [reference])
        try assertKept(kept)
    }

    func testAliasSweepHonorsPhysicalFileProtection() throws {
        let root = try fixture()
        let physical = root.appendingPathComponent("downloads", isDirectory: true)
        let kept = try write("book.epub", in: physical)
        let stale = try write("stale.bin", in: physical)
        try clean(alias(to: physical, in: root), files: [kept])
        try assertKept(kept)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testActivePartCandidatesAreProtectedAcrossAliasesInEveryPhase() throws {
        let root = try fixture()
        let physical = root.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
        let aliasRoot = try alias(to: physical, in: root)
        let paths = DownloadStagingPaths(destination: physical.appendingPathComponent("book.epub"),
                                         ownerID: String(repeating: "a", count: 64))
        let kept = DownloadStagingPaths.Phase.allCases.map { paths.url(for: $0, operationID: UUID()) }
        for url in kept { try Data("keep".utf8).write(to: url) }
        let stale = paths.url(for: .transfer, operationID: UUID())
        try Data("stale".utf8).write(to: stale)
        try clean(physical, files: Set(kept.map { aliasRoot.appendingPathComponent($0.lastPathComponent) }))
        for url in kept { try assertKept(url) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testPreservedGeneratedDirectoryIsOpaqueThroughAlias() throws {
        let root = try fixture()
        let physical = root.appendingPathComponent("downloads", isDirectory: true)
        let kept = try write("derived/parts/index.bin", in: physical)
        let stale = try write("obsolete.bin", in: physical)
        let reference = try alias(to: physical, in: root).appendingPathComponent("derived", isDirectory: true)
        try clean(physical, directories: [reference])
        try assertKept(kept)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testNestedCleanupRootsCannotReenterPreservedDirectory() throws {
        let root = try fixture()
        let kept = try write("derived/subtree/index.bin", in: root)
        let preserved = root.appendingPathComponent("derived", isDirectory: true)
        for roots in [[root, preserved, preserved.appendingPathComponent("subtree")], [preserved, root]] {
            try DownloadOrphanCleanup.removeOrphans(in: roots, preservingFiles: [], preservingDirectories: [preserved])
            try assertKept(kept)
        }
    }

    func testRetainedDirectoryEntryIsNotTraversedAsAnOrphanTree() throws {
        let root = try fixture()
        let kept = try write("payload.epub/OEBPS/chapter.xhtml", in: root)
        try clean(root, files: [root.appendingPathComponent("payload.epub")])
        try assertKept(kept)
    }

    func testRealmManagementTreeKeepsAncestorsWithoutRetainedRealmFile() throws {
        let root = try fixture()
        let kept = try write("unused/deep/store.realm.management/access.lock", in: root)
        let stale = try write("unused/deep/old.bin", in: root)
        try clean(root)
        try assertKept(kept)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testExplicitCleanupRootInsideRealmManagementRemainsProtected() throws {
        let root = try fixture()
        let kept = try write("store.realm.management/nested/access.lock", in: root)
        try clean(root.appendingPathComponent("store.realm.management/nested", isDirectory: true))
        try assertKept(kept)
    }

    func testRealmLockAndNoteSidecarsKeepTheirParent() throws {
        let root = try fixture()
        let kept = try ["cache/old.realm.lock", "cache/old.realm.note"].map { try write($0, in: root) }
        try clean(root)
        for url in kept { try assertKept(url) }
    }

    func testRetainedSiblingDoesNotKeepAnEmptyPrefixNamedDirectory() throws {
        let root = try fixture()
        let kept = try write("dictionary-new/file.bin", in: root)
        let empty = root.appendingPathComponent("dictionary", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try clean(root, files: [kept])
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path))
        try assertKept(kept)
    }

    func testUnprotectedDirectorySymlinkIsUnlinkedWithoutTraversingTarget() throws {
        let root = try fixture()
        let outside = try fixture()
        let sentinel = try write("nested/user-data.bin", in: outside)
        let link = try alias(to: outside, in: root)
        try clean(root)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        try assertKept(sentinel)
    }

    func testRetainedInRootSymlinkProtectsEntryAndPayload() throws {
        let root = try fixture()
        let payload = try write("physical/payload.bin", in: root)
        let link = root.appendingPathComponent("book.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: payload)
        try clean(root, files: [link])
        try assertKept(link)
        try assertKept(payload)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), payload.path)
    }

    func testDanglingUnprotectedSymlinkIsRemoved() throws {
        let root = try fixture()
        let link = root.appendingPathComponent("obsolete")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("absent"))
        try clean(root)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
    }

    func testProtectedDanglingSymlinkIsNotRemoved() throws {
        let root = try fixture()
        let link = root.appendingPathComponent("awaiting-payload")
        let target = root.appendingPathComponent("absent")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try clean(root, files: [link])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }

    func testSpecialFileKeepsItsParentWithoutBeingRemoved() throws {
        let root = try fixture()
        let directory = root.appendingPathComponent("ipc", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fifo = directory.appendingPathComponent("channel")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        try clean(root)
        var status = stat()
        XCTAssertEqual(lstat(fifo.path, &status), 0)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFIFO)
    }

    func testLateChildAfterDirectoryListingIsNotRecursivelyDeleted() throws {
        let root = try fixture()
        let stale = try write("orphan/old.bin", in: root)
        let directory = stale.deletingLastPathComponent()
        let late = directory.appendingPathComponent("arrived-after-listing.bin")
        let manager = DirectoryListing()
        manager.afterListing = { url in
            if url.path == directory.path { try Data("keep".utf8).write(to: late) }
        }
        try clean(root, manager: manager)
        try assertKept(late)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testAlreadyCancelledSweepDoesNotRemoveFiles() async throws {
        let root = try fixture()
        let kept = try write("orphan/file.bin", in: root)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try DownloadOrphanCleanup.removeOrphans(in: [root], preservingFiles: [], preservingDirectories: [])
        }
        do { try await task.value; XCTFail("Cancelled sweep succeeded") }
        catch is CancellationError {}
        try assertKept(kept)
    }

    func testCancellationDuringListingStopsBeforeNextMutation() async throws {
        let root = try fixture()
        let kept = try write("file.bin", in: root)
        let manager = DirectoryListing()
        manager.afterListing = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let task = Task {
            try DownloadOrphanCleanup.removeOrphans(in: [root], preservingFiles: [], preservingDirectories: [], readDirectory: manager.read)
        }
        do { try await task.value; XCTFail("Cancelled sweep succeeded") }
        catch is CancellationError {}
        try assertKept(kept)
    }

    func testListingErrorPropagatesWithoutRemovingUnreadChildren() throws {
        let root = try fixture()
        let kept = try write("file.bin", in: root)
        let manager = DirectoryListing()
        manager.afterListing = { _ in throw CocoaError(.fileReadNoPermission) }
        XCTAssertThrowsError(try clean(root, manager: manager))
        try assertKept(kept)
    }

    func testMissingRootIsANoOpWithoutCreatingAnything() throws {
        let root = try fixture().appendingPathComponent("not-created", isDirectory: true)
        try clean(root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testNonDirectoryAndNonFileRootsAreRejected() throws {
        let root = try fixture()
        let kept = try write("file.bin", in: root)
        XCTAssertThrowsError(try clean(kept))
        XCTAssertThrowsError(try clean(XCTUnwrap(URL(string: "https://example.com/downloads"))))
        XCTAssertThrowsError(try clean(URL(fileURLWithPath: "/", isDirectory: true)))
        try assertKept(kept)
    }

    func testRepeatedAndOverlappingRootsAreIdempotent() throws {
        let root = try fixture()
        let kept = try write("nested/keep.bin", in: root)
        let stale = try write("old/obsolete.bin", in: root)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        for _ in 0..<2 {
            try DownloadOrphanCleanup.removeOrphans(in: [root, nested, root], preservingFiles: [kept], preservingDirectories: [])
        }
        try assertKept(kept)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testJapaneseAndLiteralURLDelimitersRemainFilenameData() throws {
        let root = try fixture()
        let kept = try write("作者/日本語 #%2F?.epub", in: root)
        let stale = try write("作者/別の本.epub", in: root)
        try clean(root, files: [kept])
        try assertKept(kept)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testRetainedFileThroughInRootAliasKeepsTheAliasUsable() throws {
        let root = try fixture()
        let real = root.appendingPathComponent("physical", isDirectory: true)
        let kept = try write("book.epub", in: real)
        let stale = try write("stale.bin", in: real)
        let aliasRoot = try alias(to: real, in: root)
        let selected = aliasRoot.appendingPathComponent("book.epub")
        try clean(root, files: [selected])
        try assertKept(kept)
        try assertKept(selected)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: aliasRoot.path), real.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testPreservedSubtreeThroughInRootAliasKeepsItsAccessPath() throws {
        let root = try fixture()
        let real = root.appendingPathComponent("physical", isDirectory: true)
        let kept = try write("derived/index.bin", in: real)
        let stale = try write("obsolete.bin", in: real)
        let aliasRoot = try alias(to: real, in: root)
        let selected = aliasRoot.appendingPathComponent("derived", isDirectory: true)
        try clean(root, directories: [selected])
        try assertKept(kept)
        try assertKept(selected.appendingPathComponent("index.bin"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testNestedRootCannotReenterRetainedPackage() throws {
        let root = try fixture()
        let kept = try write("payload.epub/OEBPS/chapter.xhtml", in: root)
        let package = root.appendingPathComponent("payload.epub", isDirectory: true)
        try DownloadOrphanCleanup.removeOrphans(
            in: [root, package.appendingPathComponent("OEBPS", isDirectory: true)],
            preservingFiles: [package], preservingDirectories: []
        )
        try assertKept(kept)
    }

}
