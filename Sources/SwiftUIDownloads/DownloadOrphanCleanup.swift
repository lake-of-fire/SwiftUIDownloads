import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A synchronous sweep of explicitly supplied download-owned directories.
/// The controller captures live protection before entering this operation and
/// does not suspend until it returns. This is not a cross-process transaction.
enum DownloadOrphanCleanup {
    private enum Pending {
        case visit(URL, isRoot: Bool)
        case prune(URL)
    }

    static func removeOrphans(
        in roots: [URL],
        preservingFiles: Set<URL>,
        preservingDirectories: Set<URL>,
        readDirectory: (URL) throws -> [URL] = {
            try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        }
    ) throws {
        try Task.checkCancellation()
        let protectedPaths = protectionPaths(preservingFiles.union(preservingDirectories))
        var visitedRoots = Set<URL>()

        for requestedRoot in roots {
            guard requestedRoot.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
            let root = requestedRoot.absoluteURL.standardizedFileURL.resolvingSymlinksInPath()
            // A download cleanup location must never mean the entire filesystem.
            guard root.pathComponents.count > 1 else { throw CocoaError(.fileReadInvalidFileName) }
            guard visitedRoots.insert(root).inserted else { continue }
            var pending: [Pending] = [.visit(root, isRoot: true)]

            while let action = pending.popLast() {
                try Task.checkCancellation()
                switch action {
                case .prune(let directory):
                    let entry = DownloadStagingPaths.directoryEntryURL(directory)
                    guard contains(entry, in: root) else { continue }
                    try removeEmptyDirectory(entry)
                case .visit(let url, let isRoot):
                    let entry = DownloadStagingPaths.directoryEntryURL(url)
                    // A parent replaced by an outward link during the sweep is
                    // not authority to remove files under that link's target.
                    guard contains(entry, in: root) else { continue }
                    if protectedPaths.contains(where: { contains(entry, in: $0) })
                        || isRealmSidecar(entry) {
                        continue
                    }
                    let attributes: [FileAttributeKey: Any]
                    do {
                        attributes = try FileManager.default.attributesOfItem(atPath: entry.path)
                    } catch {
                        if DownloadStagingPaths.isMissingFile(error) { continue }
                        throw error
                    }
                    let kind = attributes[.type] as? FileAttributeType
                    if isRoot, kind != .typeDirectory {
                        throw CocoaError(.fileReadInvalidFileName)
                    }
                    switch kind {
                    case .typeDirectory:
                        let children: [URL]
                        do {
                            children = try readDirectory(entry)
                        } catch {
                            if DownloadStagingPaths.isMissingFile(error) { continue }
                            throw error
                        }
                        if !isRoot { pending.append(.prune(entry)) }
                        pending.append(contentsOf: children.map { .visit($0, isRoot: false) })
                    case .typeRegular, .typeSymbolicLink:
                        try Task.checkCancellation()
                        // Do not follow links or recursively remove a directory
                        // which replaced a previously inspected file.
                        if unlink(entry.path) != 0 {
                            let code = errno
                            if code != ENOENT {
                                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                            }
                        }
                    default:
                        // Sockets, FIFOs and devices are not download artifacts.
                        continue
                    }
                }
            }
        }
    }

    private static func protectionPaths(_ urls: Set<URL>) -> Set<URL> {
        var paths = Set<URL>()
        for url in urls where url.isFileURL {
            // Entry identity protects a link itself. Target identity is used
            // only for retention: a kept link must not be left dangling when
            // its payload is also encountered through its physical path.
            paths.insert(DownloadStagingPaths.directoryEntryURL(url))
            paths.insert(DownloadStagingPaths.directoryEntryURL(url.resolvingSymlinksInPath()))
            // A selected path can contain an alias which is itself inside a
            // cleanup root. Keep that entry too, not just the physical payload.
            var parent = url.absoluteURL.standardizedFileURL.deletingLastPathComponent()
            while parent.pathComponents.count > 1 {
                let entry = DownloadStagingPaths.directoryEntryURL(parent)
                let kind = try? FileManager.default.attributesOfItem(atPath: entry.path)[.type]
                    as? FileAttributeType
                if kind == .typeSymbolicLink { paths.insert(entry) }
                parent.deleteLastPathComponent()
            }
        }
        return paths
    }

    private static func contains(_ candidate: URL, in root: URL) -> Bool {
        let prefix = root.pathComponents
        return candidate.pathComponents.starts(with: prefix)
    }

    private static func isRealmSidecar(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasSuffix(".realm.lock")
            || name.hasSuffix(".realm.note")
            || url.pathComponents.contains(where: { $0.hasSuffix(".realm.management") })
    }

    private static func removeEmptyDirectory(_ url: URL) throws {
        // Never infer recursive deletion authority from an earlier inventory.
        // New/unreadable/skipped children must keep their parent alive.
        if rmdir(url.path) != 0 {
            let code = errno
            guard code != ENOENT, code != ENOTEMPTY, code != EEXIST,
                  code != ENOTDIR else { return }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
