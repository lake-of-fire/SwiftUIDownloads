import Foundation

/// One contract for temporary payload names, library filtering, and cleanup.
/// A `.part` suffix is not proof of ownership; cleanup also requires the exact
/// operation namespace (or a recognized legacy name for this destination).
public struct DownloadStagingPaths: Sendable {
    enum Phase: String, CaseIterable, Sendable {
        case transfer
        case compressed
        case expanded
    }

    private static let prefix = "swiftui-download-v1"
    let destination: URL
    let ownerID: String

    // The Downloadable adapter supplies SHA-256 of its canonical operation key.
    // Keeping hashing separate lets the complete path/cleanup contract run on
    // Foundation-only hosts without substituting a crypto implementation.
    init(destination: URL, ownerID: String) {
        precondition(Self.isOwnerID(ownerID))
        self.destination = destination.absoluteURL.standardizedFileURL
        self.ownerID = ownerID
    }

    func url(for phase: Phase, operationID: UUID) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(
            ".\(Self.prefix).\(ownerID).\(phase.rawValue).\(operationID.uuidString).part"
        )
    }

    /// Includes historical names only for compatibility with existing files.
    /// Generic `.part` files and ordinary names containing "downloading" are
    /// deliberately not treated as files this framework owns.
    public static func isDownloadArtifact(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasSuffix(".sha1verified.json")
            || modernOwnerID(name) != nil || legacyArtifact(name) != nil
    }

    func ownsTemporaryArtifact(_ url: URL) -> Bool {
        let url = url.absoluteURL.standardizedFileURL
        guard url.deletingLastPathComponent() == destination.deletingLastPathComponent(),
              url != destination else { return false }
        if let owner = Self.modernOwnerID(url.lastPathComponent) {
            return owner == ownerID
        }
        guard let legacy = Self.legacyArtifact(url.lastPathComponent) else { return false }
        let filename = destination.lastPathComponent
        if legacy.marker == "decompressing" {
            return legacy.prefix == filename && legacy.suffix.isEmpty
        }
        let ext = destination.pathExtension
        let suffix = ext.isEmpty ? [] : [ext]
        guard legacy.suffix == suffix || legacy.suffix == suffix + ["br"] else {
            return false
        }
        // Released versions used both the complete filename and its stem.
        return legacy.prefix == filename
            || legacy.prefix == destination.deletingPathExtension().lastPathComponent
    }

    /// Synchronous so the DownloadActor's active-file snapshot stays current.
    /// Cancellation cleanup intentionally still works in a cancelled task.
    @discardableResult
    func removeTemporaryArtifacts(preserving protectedURLs: Set<URL>) throws -> [URL] {
        let protectedURLs = Set(protectedURLs.map { $0.absoluteURL.standardizedFileURL })
        let directory = destination.deletingLastPathComponent()
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )
        } catch {
            if Self.isMissingFile(error) { return [] }
            throw error
        }
        var removed: [URL] = []
        for child in children where ownsTemporaryArtifact(child)
            && !protectedURLs.contains(child.absoluteURL.standardizedFileURL) {
            do {
                try FileManager.default.removeItem(at: child)
                removed.append(directory.appendingPathComponent(child.lastPathComponent))
            } catch {
                if Self.isMissingFile(error) { continue }
                throw error
            }
        }
        return removed
    }

    private static func modernOwnerID(_ name: String) -> String? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 6, parts[0].isEmpty, parts[1] == Substring(prefix),
              isOwnerID(String(parts[2])), Phase(rawValue: String(parts[3])) != nil,
              isOperationID(parts[4]), parts[5] == "part" else { return nil }
        return String(parts[2])
    }

    private struct LegacyArtifact {
        let prefix: String
        let marker: String
        let suffix: [String]
    }

    private static func legacyArtifact(_ name: String) -> LegacyArtifact? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        for index in parts.indices where index > 0 && index + 1 < parts.count {
            let marker = parts[index]
            guard marker == "downloading" || marker == "decompressing",
                  isOperationID(parts[index + 1]) else { continue }
            let prefix = parts[..<index].joined(separator: ".")
            let suffix = parts.dropFirst(index + 2).map(String.init)
            guard !prefix.isEmpty, suffix.allSatisfy({ !$0.isEmpty }) else { continue }
            if (marker == "downloading" && (suffix.count <= 1
                || (suffix.count == 2 && suffix.last == "br")))
                || (marker == "decompressing" && suffix.isEmpty) {
                return LegacyArtifact(prefix: prefix, marker: String(marker), suffix: suffix)
            }
        }
        return nil
    }

    private static func isOwnerID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func isOperationID(_ value: Substring) -> Bool {
        guard value.utf8.count == 36, let uuid = UUID(uuidString: String(value)) else {
            return false
        }
        return uuid.uuidString.lowercased() == value.lowercased()
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError))
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }
}
