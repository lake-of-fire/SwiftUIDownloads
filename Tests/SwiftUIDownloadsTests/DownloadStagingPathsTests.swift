import Foundation
import XCTest
@testable import SwiftUIDownloads

final class DownloadStagingPathsTests: XCTestCase {
    private let owner = String(repeating: "a", count: 64)
    private let otherOwner = String(repeating: "b", count: 64)
    private let operation = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!

    private func paths(_ name: String = "book.epub", root: URL = URL(fileURLWithPath: "/library")) -> DownloadStagingPaths {
        DownloadStagingPaths(destination: root.appendingPathComponent(name), ownerID: owner)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-staging-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testEveryStageIsHiddenAndEndsInPart() {
        let paths = paths()
        for phase in DownloadStagingPaths.Phase.allCases {
            let url = paths.url(for: phase, operationID: operation)
            XCTAssertEqual(url.pathExtension, "part")
            XCTAssertTrue(url.lastPathComponent.hasPrefix("."))
            XCTAssertEqual(url.deletingLastPathComponent(), paths.destination.deletingLastPathComponent())
            XCTAssertNotEqual(url, paths.destination)
            XCTAssertTrue(DownloadStagingPaths.isDownloadArtifact(url))
            XCTAssertTrue(paths.ownsTemporaryArtifact(url))
        }
    }

    func testPhaseAndAttemptPathsAreIndependent() {
        let paths = paths()
        let urls = DownloadStagingPaths.Phase.allCases.map { paths.url(for: $0, operationID: operation) }
        XCTAssertEqual(Set(urls).count, 3)
        XCTAssertNotEqual(urls[0], paths.url(for: .transfer, operationID: UUID()))
        XCTAssertEqual(urls[0], paths.url(for: .transfer, operationID: operation))
    }

    func testDifferentOperationNamespacesCannotOwnEachOthersFiles() {
        let first = paths()
        let second = DownloadStagingPaths(destination: first.destination, ownerID: otherOwner)
        for phase in DownloadStagingPaths.Phase.allCases {
            let url = second.url(for: phase, operationID: operation)
            XCTAssertFalse(first.ownsTemporaryArtifact(url))
            XCTAssertNotEqual(url, first.url(for: phase, operationID: operation))
        }
    }

    func testSameNamespaceInAnotherDirectoryIsNotOwned() {
        let first = paths()
        let second = paths(root: URL(fileURLWithPath: "/other-library"))
        XCTAssertFalse(first.ownsTemporaryArtifact(second.url(for: .transfer, operationID: operation)))
    }

    func testFullLengthFilenameDoesNotLengthenTemporaryName() throws {
        let root = try temporaryRoot()
        let name = String(repeating: "a", count: 250) + ".epub"
        XCTAssertEqual(name.utf8.count, 255)
        let paths = paths(name, root: root)
        try Data("old installed bytes".utf8).write(to: paths.destination)
        for phase in DownloadStagingPaths.Phase.allCases {
            let url = paths.url(for: phase, operationID: operation)
            XCTAssertLessThan(url.lastPathComponent.utf8.count, 180)
            try Data(phase.rawValue.utf8).write(to: url)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), phase.rawValue)
        }
        XCTAssertEqual(try String(contentsOf: paths.destination, encoding: .utf8), "old installed bytes")
    }

    func testJapaneseAndReservedCharactersDoNotAppearInTemporaryName() {
        let paths = paths("長い名前 #%?.epub")
        let name = paths.url(for: .transfer, operationID: operation).lastPathComponent
        XCTAssertTrue(name.utf8.allSatisfy { $0 < 128 })
        XCTAssertFalse(name.contains("%"))
        XCTAssertFalse(name.contains("?"))
        XCTAssertTrue(paths.ownsTemporaryArtifact(paths.url(for: .expanded, operationID: operation)))
    }

    func testMalformedModernNamesAreNeitherArtifactsNorOwned() {
        let paths = paths()
        let good = paths.url(for: .transfer, operationID: operation).lastPathComponent
        let bad = [
            good + ".epub",
            good.replacingOccurrences(of: ".part", with: ".part.br"),
            good.replacingOccurrences(of: ".transfer.", with: ".unknown."),
            good.replacingOccurrences(of: owner, with: String(repeating: "g", count: 64)),
            good.replacingOccurrences(of: owner, with: String(owner.dropLast())),
            good.replacingOccurrences(of: operation.uuidString, with: "not-a-uuid"),
            String(good.dropFirst()),
        ]
        for name in bad {
            let url = paths.destination.deletingLastPathComponent().appendingPathComponent(name)
            XCTAssertFalse(DownloadStagingPaths.isDownloadArtifact(url), name)
            XCTAssertFalse(paths.ownsTemporaryArtifact(url), name)
        }
    }

    func testLegacyTransfersAreRecognizedForBothReleasedBasenameForms() {
        let paths = paths()
        for name in [
            "book.downloading.\(operation).epub",
            "book.downloading.\(operation).epub.br",
            "book.epub.downloading.\(operation).epub",
            "book.epub.downloading.\(operation).epub.br",
            "book.epub.decompressing.\(operation)",
        ] {
            let url = paths.destination.deletingLastPathComponent().appendingPathComponent(name)
            XCTAssertTrue(DownloadStagingPaths.isDownloadArtifact(url), name)
            XCTAssertTrue(paths.ownsTemporaryArtifact(url), name)
        }
    }

    func testLegacyExtensionlessTransfersAreRecognized() {
        let paths = paths("book")
        for suffix in ["", ".br"] {
            let url = paths.destination.deletingLastPathComponent()
                .appendingPathComponent("book.downloading.\(operation)" + suffix)
            XCTAssertTrue(DownloadStagingPaths.isDownloadArtifact(url))
            XCTAssertTrue(paths.ownsTemporaryArtifact(url))
        }
    }

    func testLegacyArtifactsBelongToTheirExactDestinationNotSimilarFiles() {
        let paths = paths()
        let root = paths.destination.deletingLastPathComponent()
        for name in [
            "book.downloading.\(operation).zip",
            "book.epub.extra.downloading.\(operation).epub",
            "book.zip.decompressing.\(operation)",
            "book.epub.downloading.\(operation).zip",
        ] {
            let url = root.appendingPathComponent(name)
            XCTAssertTrue(DownloadStagingPaths.isDownloadArtifact(url), name)
            XCTAssertFalse(paths.ownsTemporaryArtifact(url), name)
        }
    }

    func testOrdinaryPrefixMatchesAreNotArtifacts() {
        let paths = paths()
        for name in [
            "book.epub.downloading.notes.epub",
            "book.epub.decompressing.notes.txt",
            "book.epub.part", "unfinished.part",
            "book.epub.downloading.\(operation).extra.epub",
            "book.epub.downloading.\(operation).",
            "book.epub.decompressing.\(operation).notes",
            ".downloading.\(operation)",
        ] {
            let url = paths.destination.deletingLastPathComponent().appendingPathComponent(name)
            XCTAssertFalse(DownloadStagingPaths.isDownloadArtifact(url), name)
            XCTAssertFalse(paths.ownsTemporaryArtifact(url), name)
        }
    }

    func testChecksumMarkerIsFilteredButNotTreatedAsTemporaryPayload() {
        let paths = paths()
        let marker = paths.destination.appendingPathExtension("sha1verified.json")
        XCTAssertTrue(DownloadStagingPaths.isDownloadArtifact(marker))
        XCTAssertFalse(paths.ownsTemporaryArtifact(marker))
        XCTAssertFalse(paths.ownsTemporaryArtifact(paths.destination))
    }

    func testCleanupPreservesActiveCandidatesOtherOperationsAndOrdinaryFiles() throws {
        let root = try temporaryRoot()
        let paths = paths(root: root)
        let other = DownloadStagingPaths(destination: paths.destination, ownerID: otherOwner)
        let retained = [
            paths.destination,
            paths.url(for: .transfer, operationID: operation),
            other.url(for: .expanded, operationID: operation),
            root.appendingPathComponent("book.epub.downloading.notes.epub"),
            root.appendingPathComponent("book.epub.decompressing.notes.txt"),
            root.appendingPathComponent("unfinished.part"),
        ]
        let removed = [
            paths.url(for: .expanded, operationID: operation),
            root.appendingPathComponent("book.downloading.\(operation).epub"),
            root.appendingPathComponent("book.epub.decompressing.\(operation)"),
        ]
        for url in retained + removed { try Data(url.lastPathComponent.utf8).write(to: url) }
        XCTAssertEqual(Set(try paths.removeTemporaryArtifacts(preserving: [retained[1]])), Set(removed))
        for url in retained {
            XCTAssertEqual(try Data(contentsOf: url), Data(url.lastPathComponent.utf8))
        }
        for url in removed { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
    }

    func testCleanupUsesNormalizedProtectionPaths() throws {
        let root = try temporaryRoot()
        let paths = paths(root: root)
        let candidate = paths.url(for: .compressed, operationID: operation)
        try Data([1, 2, 3]).write(to: candidate)
        let equivalent = root.appendingPathComponent("sub/../" + candidate.lastPathComponent)
        XCTAssertTrue(try paths.removeTemporaryArtifacts(preserving: [equivalent]).isEmpty)
        XCTAssertEqual(try Data(contentsOf: candidate), Data([1, 2, 3]))
    }

    func testCleanupOnlyUnlinksAnOwnedSymlink() throws {
        let root = try temporaryRoot()
        let paths = paths(root: root)
        let target = root.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: target)
        let link = paths.url(for: .transfer, operationID: operation)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(try paths.removeTemporaryArtifacts(preserving: []), [link])
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
    }

    func testCleanupOfMissingDirectoryIsANoOp() throws {
        let root = try temporaryRoot().appendingPathComponent("absent")
        XCTAssertTrue(try paths(root: root).removeTemporaryArtifacts(preserving: []).isEmpty)
    }

    func testCleanupIsIdempotent() throws {
        let root = try temporaryRoot()
        let paths = paths(root: root)
        let candidate = paths.url(for: .expanded, operationID: operation)
        try Data([4]).write(to: candidate)
        XCTAssertEqual(try paths.removeTemporaryArtifacts(preserving: []), [candidate])
        XCTAssertTrue(try paths.removeTemporaryArtifacts(preserving: []).isEmpty)
    }

    func testPromotionPreservesFinalFilenameAndBytes() throws {
        let root = try temporaryRoot()
        let paths = paths("日本語 #%?.epub", root: root)
        let candidate = paths.url(for: .transfer, operationID: operation)
        let data = Data("verified payload".utf8)
        try data.write(to: candidate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.destination.path))
        try FileManager.default.moveItem(at: candidate, to: paths.destination)
        XCTAssertEqual(try Data(contentsOf: paths.destination), data)
        XCTAssertEqual(paths.destination.lastPathComponent, "日本語 #%?.epub")
        XCTAssertFalse(DownloadStagingPaths.isDownloadArtifact(paths.destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
    }
}
