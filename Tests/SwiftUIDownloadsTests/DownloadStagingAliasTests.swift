import Foundation
import XCTest
@testable import SwiftUIDownloads

final class DownloadStagingAliasTests: XCTestCase {
    private let owner = String(repeating: "a", count: 64)

    private func fixture() throws -> (root: URL, physical: URL, alias: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("staging-alias-\(UUID().uuidString)", isDirectory: true)
        let physical = root.appendingPathComponent("physical", isDirectory: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, physical, alias)
    }

    private func paths(at root: URL) -> DownloadStagingPaths {
        DownloadStagingPaths(destination: root.appendingPathComponent("book.epub"), ownerID: owner)
    }

    func testPhysicalCleanupPreservesCandidateProtectedThroughParentAlias() throws {
        let f = try fixture()
        let paths = paths(at: f.physical)
        for phase in DownloadStagingPaths.Phase.allCases {
            let candidate = paths.url(for: phase, operationID: UUID())
            let payload = Data(phase.rawValue.utf8)
            try payload.write(to: candidate)
            let protected = f.alias.appendingPathComponent(candidate.lastPathComponent)
            XCTAssertTrue(try paths.removeTemporaryArtifacts(preserving: [protected]).isEmpty)
            XCTAssertEqual(try Data(contentsOf: candidate), payload)
            try FileManager.default.removeItem(at: candidate)
        }
    }

    func testAliasCleanupPreservesCandidateProtectedThroughPhysicalParent() throws {
        let f = try fixture()
        let paths = paths(at: f.alias)
        let candidate = paths.url(for: .transfer, operationID: UUID())
        try Data("active".utf8).write(to: candidate)
        let protected = f.physical.appendingPathComponent(candidate.lastPathComponent)
        XCTAssertTrue(try paths.removeTemporaryArtifacts(preserving: [protected]).isEmpty)
        XCTAssertEqual(try Data(contentsOf: candidate), Data("active".utf8))
    }

    func testAliasSpellingDoesNotPreventCleaningAnOwnedSibling() throws {
        let f = try fixture()
        let paths = paths(at: f.alias)
        let candidate = paths.url(for: .expanded, operationID: UUID())
        try Data("stale".utf8).write(to: candidate)
        let physicalCandidate = f.physical.appendingPathComponent(candidate.lastPathComponent)
        XCTAssertTrue(paths.ownsTemporaryArtifact(physicalCandidate))
        XCTAssertEqual(try paths.removeTemporaryArtifacts(preserving: []), [candidate])
        XCTAssertFalse(FileManager.default.fileExists(atPath: physicalCandidate.path))
    }

    func testUnrelatedSameBasenameCannotProtectAnOwnedCandidate() throws {
        let f = try fixture()
        let paths = paths(at: f.physical)
        let candidate = paths.url(for: .compressed, operationID: UUID())
        let outside = f.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let unrelated = outside.appendingPathComponent(candidate.lastPathComponent)
        try Data("stale".utf8).write(to: candidate)
        try Data("unrelated".utf8).write(to: unrelated)
        XCTAssertFalse(paths.ownsTemporaryArtifact(unrelated))
        XCTAssertEqual(try paths.removeTemporaryArtifacts(preserving: [unrelated]), [candidate])
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("unrelated".utf8))
    }

    func testOwnedSymlinkLeafIsUnlinkedWithoutFollowingItsTarget() throws {
        let f = try fixture()
        let paths = paths(at: f.physical)
        let target = f.root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let sentinel = target.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        let candidate = paths.url(for: .expanded, operationID: UUID())
        try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: target)
        XCTAssertEqual(try paths.removeTemporaryArtifacts(preserving: [target]), [candidate])
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: candidate.path))
    }

    func testProtectedSymlinkLeafThroughAliasIsNotUnlinked() throws {
        let f = try fixture()
        let paths = paths(at: f.physical)
        let target = f.root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: target)
        let candidate = paths.url(for: .transfer, operationID: UUID())
        try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: target)
        let protected = f.alias.appendingPathComponent(candidate.lastPathComponent)
        XCTAssertTrue(try paths.removeTemporaryArtifacts(preserving: [protected]).isEmpty)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: candidate.path), target.path)
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
    }

    func testPartNamedDirectoryIsNeverRecursivelyDeleted() throws {
        let f = try fixture()
        let paths = paths(at: f.physical)
        let directory = paths.url(for: .transfer, operationID: UUID())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sentinel = directory.appendingPathComponent("keep.txt")
        try Data("not a transfer".utf8).write(to: sentinel)
        XCTAssertTrue(try paths.removeTemporaryArtifacts(preserving: []).isEmpty)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("not a transfer".utf8))
    }

    func testLegacyNamedDirectoryIsNeverRecursivelyDeleted() throws {
        let f = try fixture()
        let paths = paths(at: f.physical)
        let directory = f.physical.appendingPathComponent("book.epub.decompressing.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sentinel = directory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        XCTAssertTrue(try paths.removeTemporaryArtifacts(preserving: []).isEmpty)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }

    func testDanglingOwnedSymlinkCanBeRemovedThroughParentAlias() throws {
        let f = try fixture()
        let paths = paths(at: f.alias)
        let candidate = paths.url(for: .transfer, operationID: UUID())
        let missing = f.root.appendingPathComponent("missing")
        try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: missing)
        XCTAssertEqual(try paths.removeTemporaryArtifacts(preserving: []), [candidate])
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: candidate.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
}
