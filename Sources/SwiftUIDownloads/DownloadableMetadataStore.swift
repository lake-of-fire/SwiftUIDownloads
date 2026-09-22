import Foundation
import CryptoKit

public struct InstalledArtifactReceipt: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let requestedSourceURL: URL
    public let finalResponseURL: URL?
    public let destinationURL: URL
    public let sha256Digest: String
    public let byteCount: UInt64
    public let modificationTimeIntervalSince1970: TimeInterval
    public let fileSystemNumber: UInt64?
    public let fileSystemFileNumber: UInt64?

    public init(
        schemaVersion: Int = InstalledArtifactReceipt.currentSchemaVersion,
        requestedSourceURL: URL,
        finalResponseURL: URL? = nil,
        destinationURL: URL,
        sha256Digest: String,
        byteCount: UInt64,
        modificationTimeIntervalSince1970: TimeInterval,
        fileSystemNumber: UInt64?,
        fileSystemFileNumber: UInt64?
    ) {
        self.schemaVersion = schemaVersion
        self.requestedSourceURL = requestedSourceURL
        self.finalResponseURL = finalResponseURL
        self.destinationURL = destinationURL
        self.sha256Digest = sha256Digest
        self.byteCount = byteCount
        self.modificationTimeIntervalSince1970 = modificationTimeIntervalSince1970
        self.fileSystemNumber = fileSystemNumber
        self.fileSystemFileNumber = fileSystemFileNumber
    }
}

private func standardizedReceiptSourceURL(_ url: URL) -> URL {
    url.isFileURL ? url.standardizedFileURL : url.standardized
}

private func installedArtifactReceiptKey(sourceURL: URL, destinationURL: URL) -> String {
    let identity = [
        standardizedReceiptSourceURL(sourceURL).absoluteString,
        destinationURL.standardizedFileURL.absoluteString
    ].joined(separator: "\u{0}")
    let digest = SHA256.hash(data: Data(identity.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    return "installedArtifactReceipt:v1:\(digest)"
}

public struct DownloadMetadata: Equatable, Sendable {
    public var lastDownloadedETag: String?
    public var lastCheckedETagAt: Date?
    public var lastDownloadedAt: Date?
    public var lastModifiedAt: Date?

    public init(
        lastDownloadedETag: String? = nil,
        lastCheckedETagAt: Date? = nil,
        lastDownloadedAt: Date? = nil,
        lastModifiedAt: Date? = nil
    ) {
        self.lastDownloadedETag = lastDownloadedETag
        self.lastCheckedETagAt = lastCheckedETagAt
        self.lastDownloadedAt = lastDownloadedAt
        self.lastModifiedAt = lastModifiedAt
    }
}

public struct DownloadMetadataFields: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let lastDownloadedETag = Self(rawValue: 1 << 0)
    public static let lastCheckedETagAt = Self(rawValue: 1 << 1)
    public static let lastDownloadedAt = Self(rawValue: 1 << 2)
    public static let lastModifiedAt = Self(rawValue: 1 << 3)
    public static let all: Self = [
        .lastDownloadedETag,
        .lastCheckedETagAt,
        .lastDownloadedAt,
        .lastModifiedAt
    ]
}

public protocol DownloadableMetadataStore: Sendable {
    /// Identifies metadata storage that must share one in-memory cache.
    /// Include any store-specific partition, such as a dictionary identifier.
    var metadataCacheNamespace: String { get }
    func lastDownloadedETag(for url: URL) -> String?
    func setLastDownloadedETag(_ etag: String?, for url: URL)
    func lastCheckedETagAt(for url: URL) -> Date?
    func setLastCheckedETagAt(_ date: Date?, for url: URL)
    func lastDownloaded(for url: URL) -> Date?
    func setLastDownloaded(_ date: Date?, for url: URL)
    func lastModifiedAt(for url: URL) -> Date?
    func setLastModifiedAt(_ date: Date?, for url: URL)
    func loadMetadata(for url: URL) throws -> DownloadMetadata
    func saveMetadata(_ metadata: DownloadMetadata, fields: DownloadMetadataFields, for url: URL) throws
    func installedArtifactReceipt(
        sourceURL: URL,
        destinationURL: URL
    ) throws -> InstalledArtifactReceipt?
    func saveInstalledArtifactReceipt(
        _ receipt: InstalledArtifactReceipt,
        sourceURL: URL,
        destinationURL: URL
    ) throws
    func removeInstalledArtifactReceipt(
        sourceURL: URL,
        destinationURL: URL
    ) throws
}

public extension DownloadableMetadataStore {
    func loadMetadata(for url: URL) throws -> DownloadMetadata {
        DownloadMetadata(
            lastDownloadedETag: lastDownloadedETag(for: url),
            lastCheckedETagAt: lastCheckedETagAt(for: url),
            lastDownloadedAt: lastDownloaded(for: url),
            lastModifiedAt: lastModifiedAt(for: url)
        )
    }

    func saveMetadata(
        _ metadata: DownloadMetadata,
        fields: DownloadMetadataFields,
        for url: URL
    ) throws {
        if fields.contains(.lastDownloadedETag) {
            setLastDownloadedETag(metadata.lastDownloadedETag, for: url)
        }
        if fields.contains(.lastCheckedETagAt) {
            setLastCheckedETagAt(metadata.lastCheckedETagAt, for: url)
        }
        if fields.contains(.lastDownloadedAt) {
            setLastDownloaded(metadata.lastDownloadedAt, for: url)
        }
        if fields.contains(.lastModifiedAt) {
            setLastModifiedAt(metadata.lastModifiedAt, for: url)
        }
    }

    func installedArtifactReceipt(
        sourceURL: URL,
        destinationURL: URL
    ) throws -> InstalledArtifactReceipt? {
        guard let data = UserDefaults.standard.data(
            forKey: installedArtifactReceiptKey(
                sourceURL: sourceURL,
                destinationURL: destinationURL
            )
        ) else {
            return nil
        }
        return try JSONDecoder().decode(InstalledArtifactReceipt.self, from: data)
    }

    func saveInstalledArtifactReceipt(
        _ receipt: InstalledArtifactReceipt,
        sourceURL: URL,
        destinationURL: URL
    ) throws {
        let data = try JSONEncoder().encode(receipt)
        UserDefaults.standard.set(
            data,
            forKey: installedArtifactReceiptKey(
                sourceURL: sourceURL,
                destinationURL: destinationURL
            )
        )
    }

    func removeInstalledArtifactReceipt(
        sourceURL: URL,
        destinationURL: URL
    ) throws {
        UserDefaults.standard.removeObject(
            forKey: installedArtifactReceiptKey(
                sourceURL: sourceURL,
                destinationURL: destinationURL
            )
        )
    }
}

public struct UserDefaultsDownloadableMetadataStore: DownloadableMetadataStore, @unchecked Sendable {
    private let userDefaults: UserDefaults
    public let metadataCacheNamespace: String
    
    public init(
        userDefaults: UserDefaults = .standard,
        metadataCacheNamespace: String? = nil
    ) {
        self.userDefaults = userDefaults
        self.metadataCacheNamespace = metadataCacheNamespace
            ?? "UserDefaultsDownloadMetadata:\(ObjectIdentifier(userDefaults))"
    }

    public func loadMetadata(for url: URL) -> DownloadMetadata {
        let urlString = url.absoluteString
        return DownloadMetadata(
            lastDownloadedETag: userDefaults.object(forKey: "fileLastDownloadedETag:\(urlString)") as? String,
            lastCheckedETagAt: userDefaults.object(forKey: "fileLastCheckedETagAt:\(urlString)") as? Date,
            lastDownloadedAt: userDefaults.object(forKey: "fileLastDownloadedDate:\(urlString)") as? Date,
            lastModifiedAt: userDefaults.object(forKey: "fileLastModifiedDate:\(urlString)") as? Date
        )
    }

    public func lastDownloadedETag(for url: URL) -> String? {
        userDefaults.object(forKey: "fileLastDownloadedETag:\(url.absoluteString)") as? String
    }
    
    public func setLastDownloadedETag(_ etag: String?, for url: URL) {
        let key = "fileLastDownloadedETag:\(url.absoluteString)"
        if let etag {
            userDefaults.set(etag, forKey: key)
        } else {
            userDefaults.removeObject(forKey: key)
        }
    }
    
    public func lastCheckedETagAt(for url: URL) -> Date? {
        userDefaults.object(forKey: "fileLastCheckedETagAt:\(url.absoluteString)") as? Date
    }
    
    public func setLastCheckedETagAt(_ date: Date?, for url: URL) {
        let key = "fileLastCheckedETagAt:\(url.absoluteString)"
        if let date {
            userDefaults.set(date, forKey: key)
        } else {
            userDefaults.removeObject(forKey: key)
        }
    }
    
    public func lastDownloaded(for url: URL) -> Date? {
        userDefaults.object(forKey: "fileLastDownloadedDate:\(url.absoluteString)") as? Date
    }
    
    public func setLastDownloaded(_ date: Date?, for url: URL) {
        let key = "fileLastDownloadedDate:\(url.absoluteString)"
        if let date {
            userDefaults.set(date, forKey: key)
        } else {
            userDefaults.removeObject(forKey: key)
        }
    }
    
    public func lastModifiedAt(for url: URL) -> Date? {
        userDefaults.object(forKey: "fileLastModifiedDate:\(url.absoluteString)") as? Date
    }
    
    public func setLastModifiedAt(_ date: Date?, for url: URL) {
        let key = "fileLastModifiedDate:\(url.absoluteString)"
        if let date {
            userDefaults.set(date, forKey: key)
        } else {
            userDefaults.removeObject(forKey: key)
        }
    }

    public func installedArtifactReceipt(
        sourceURL: URL,
        destinationURL: URL
    ) throws -> InstalledArtifactReceipt? {
        guard let data = userDefaults.data(
            forKey: installedArtifactReceiptKey(
                sourceURL: sourceURL,
                destinationURL: destinationURL
            )
        ) else {
            return nil
        }
        return try JSONDecoder().decode(InstalledArtifactReceipt.self, from: data)
    }

    public func saveInstalledArtifactReceipt(
        _ receipt: InstalledArtifactReceipt,
        sourceURL: URL,
        destinationURL: URL
    ) throws {
        let data = try JSONEncoder().encode(receipt)
        userDefaults.set(
            data,
            forKey: installedArtifactReceiptKey(
                sourceURL: sourceURL,
                destinationURL: destinationURL
            )
        )
    }

    public func removeInstalledArtifactReceipt(
        sourceURL: URL,
        destinationURL: URL
    ) throws {
        userDefaults.removeObject(
            forKey: installedArtifactReceiptKey(
                sourceURL: sourceURL,
                destinationURL: destinationURL
            )
        )
    }
}
