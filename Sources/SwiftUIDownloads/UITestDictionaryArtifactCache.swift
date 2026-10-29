import Foundation
import CryptoKit
import Darwin

/// A byte-verified seed store for isolated UI tests. Destinations are independent
/// APFS clones, never symlinks or hard links into a mutable download directory.
/// Deleting or repairing one run cannot change another run or the seed bytes.
public struct UITestDictionaryArtifactCache: Sendable {
    public let directory: URL
    private let maximumBytes: UInt64

    public init(directory: URL, maximumBytes: UInt64 = 1_024 * 1_024 * 1_024) {
        self.directory = directory
        self.maximumBytes = maximumBytes
    }

    static func isolatedCache(
        enabled: Bool, arguments: [String], environment: [String: String],
        temporaryDirectory: URL, destination: URL
    ) -> Self? {
#if DEBUG
        guard enabled, arguments.contains("--ui-test-isolated-data-root"),
              !arguments.contains("--cloudkit-e2e"),
              let runID = environment["MANABI_UI_TEST_DATA_ROOT_RUN_ID"],
              UUID(uuidString: runID)?.uuidString.lowercased() == runID else { return nil }
        let temporary = temporaryDirectory.resolvingSymlinksInPath()
        let isolated = temporary.appendingPathComponent("ManabiReaderUITests")
            .appendingPathComponent(runID).appendingPathComponent("app-group")
        let canonicalDestination = destination.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalDestination.path.hasPrefix(isolated.path + "/") else { return nil }
        return Self(directory: temporary.appendingPathComponent("ManabiReaderUITestAssets-v1"))
#else
        return nil
#endif
    }

    /// Restores only an absent destination. Validation and cloning happen under
    /// the same process lock so pruning/publication cannot replace the seed.
    public func restore(checksum: String, to destination: URL) throws -> Bool {
        try withLock {
            let seed = try seedURL(checksum)
            guard FileManager.default.fileExists(atPath: seed.path) else { return false }
            try requireRegularFile(seed)
            guard try Self.sha1(seed) == checksum.lowercased() else {
                // Eviction never touches already-materialized run files.
                try FileManager.default.removeItem(at: seed)
                return false
            }
            try requireDirectPath(destination)
            guard !FileManager.default.fileExists(atPath: destination.path) else { return false }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let staged = destination.deletingLastPathComponent()
                .appendingPathComponent(".ui-test-seed-\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: staged) }
            try Self.cloneOrCopy(from: seed, to: staged)
            // The local copy is writable; the seed remains read-only. APFS
            // separates subsequent writes while retaining unchanged extents.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: staged, to: destination)
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: seed.path)
            try prune(preserving: seed)
            return true
        }
    }

    /// Takes an independent clone, verifies its bytes, then atomically publishes
    /// it. A checksum failure leaves the previously usable generation intact.
    public func publish(checksum: String, from source: URL) throws {
        try withLock {
            let seed = try seedURL(checksum)
            try requireRegularFile(source)
            if FileManager.default.fileExists(atPath: seed.path) {
                try requireRegularFile(seed)
                if try Self.sha1(seed) == checksum.lowercased() {
                    try prune(preserving: seed)
                    return
                }
            }
            let staged = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: staged) }
            try Self.cloneOrCopy(from: source, to: staged)
            let size = try staged.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, UInt64(size) <= maximumBytes else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            guard try Self.sha1(staged) == checksum.lowercased() else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: staged.path)
            try Task.checkCancellation()
            // rename is atomic and leaves open/private clones unaffected.
            guard rename(staged.path, seed.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            try prune(preserving: seed)
        }
    }

    @discardableResult
    public static func cloneOrCopy(from source: URL, to destination: URL) throws -> Bool {
        if clonefile(source.path, destination.path, 0) == 0 { return true }
        // Correctness and isolation also hold on a filesystem without cloning;
        // it simply cannot provide the APFS storage savings.
        try FileManager.default.copyItem(at: source, to: destination)
        return false
    }

    private func seedURL(_ checksum: String) throws -> URL {
        let digest = checksum.lowercased()
        guard digest.count == 40, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return directory.appendingPathComponent(digest + ".asset")
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try requireDirectPath(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appendingPathComponent(".lock").path,
                              O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }
        try Task.checkCancellation()
        return try body()
    }

    private func requireDirectPath(_ url: URL) throws {
        var component = url
        while component.path != "/" {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: component.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                // Foundation intentionally preserves Darwin's system aliases
                // even in resolvingSymlinksInPath(). Accept only their exact
                // system-owned targets; links beneath them remain forbidden.
                let systemAliases = ["/var": "private/var", "/tmp": "private/tmp", "/etc": "private/etc"]
                guard let expected = systemAliases[component.path],
                      try FileManager.default.destinationOfSymbolicLink(atPath: component.path) == expected else {
                    throw CocoaError(.fileWriteNoPermission)
                }
            }
            component.deleteLastPathComponent()
        }
        guard url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private func requireRegularFile(_ url: URL) throws {
        try requireDirectPath(url)
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private static func sha1(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 256 * 1024), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func prune(preserving seed: URL) throws {
        let manager = FileManager.default
        let files = try manager.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        let candidates = files.filter { file in
            let name = file.deletingPathExtension().lastPathComponent
            return file.pathExtension == "asset" && (try? seedURL(name))?.standardizedFileURL.path == file.standardizedFileURL.path
                && (try? requireRegularFile(file)) != nil
        }
        let entries = try candidates.map { file -> (URL, UInt64, Date) in
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (file, UInt64(max(0, values.fileSize ?? 0)), values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var bytes = entries.reduce(UInt64(0)) { $0 + $1.1 }
        for (file, size, accessed) in entries where file.standardizedFileURL.path != seed.standardizedFileURL.path {
            if bytes > maximumBytes || Date().timeIntervalSince(accessed) > 7 * 24 * 60 * 60 {
                try manager.removeItem(at: file)
                bytes -= size
            }
        }
        // Reap only our own crashed publication staging files after a day.
        for file in files where file.pathExtension == "tmp" {
            let name = file.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("."), UUID(uuidString: String(name.dropFirst())) != nil,
                  (try? requireRegularFile(file)) != nil,
                  let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  Date().timeIntervalSince(modified) > 24 * 60 * 60 else { continue }
            try? manager.removeItem(at: file)
        }
    }
}
