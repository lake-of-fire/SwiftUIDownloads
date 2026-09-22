import Foundation
import SwiftUI
import Combine
import BackgroundAssets
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

private struct ChecksumVerificationMarker: Codable {
    let schemaVersion: Int?
    let expectedChecksum: String
    let fileSize: UInt64
    let modificationTimeIntervalSince1970: TimeInterval
    let fileSystemNumber: UInt64?
    let fileSystemFileNumber: UInt64?
}

fileprivate struct ChecksumVerificationFileIdentity: Equatable, Sendable {
    let fileSize: UInt64
    let modificationTimeIntervalSince1970: TimeInterval
    let fileSystemNumber: UInt64?
    let fileSystemFileNumber: UInt64?
}

private let checksumVerificationMarkerSchemaVersion = 2

fileprivate func checksumVerificationFileIdentity(
    from fileAttributes: [FileAttributeKey: Any]
) -> ChecksumVerificationFileIdentity? {
    let fileSize = (fileAttributes[.size] as? NSNumber)?.uint64Value ?? 0
    guard fileSize > 0,
          let modificationDate = fileAttributes[.modificationDate] as? Date else {
        return nil
    }
    return ChecksumVerificationFileIdentity(
        fileSize: fileSize,
        modificationTimeIntervalSince1970: modificationDate.timeIntervalSince1970,
        fileSystemNumber: (fileAttributes[.systemNumber] as? NSNumber)?.uint64Value,
        fileSystemFileNumber: (fileAttributes[.systemFileNumber] as? NSNumber)?.uint64Value
    )
}

private func checksumVerificationMarker(
    _ marker: ChecksumVerificationMarker,
    matches identity: ChecksumVerificationFileIdentity
) -> Bool {
    // Version-one markers used a one-second modification-time tolerance. They
    // cannot distinguish rapid same-size replacements, so conservatively
    // rehash once and replace them with a version-two marker.
    guard marker.schemaVersion == checksumVerificationMarkerSchemaVersion,
          let markerSystemNumber = marker.fileSystemNumber,
          let markerSystemFileNumber = marker.fileSystemFileNumber,
          let identitySystemNumber = identity.fileSystemNumber,
          let identitySystemFileNumber = identity.fileSystemFileNumber else {
        return false
    }
    return marker.fileSize == identity.fileSize
        && marker.modificationTimeIntervalSince1970
            == identity.modificationTimeIntervalSince1970
        && markerSystemNumber == identitySystemNumber
        && markerSystemFileNumber == identitySystemFileNumber
}

private func sha1Checksum(for fileURL: URL) throws -> String {
    let fileHandle = try FileHandle(forReadingFrom: fileURL)
    defer { try? fileHandle.close() }

    var hasher = Insecure.SHA1()
    while autoreleasepool(invoking: {
        guard !Task.isCancelled else { return false }
        let data = fileHandle.readData(ofLength: 64 * 1024)
        guard !data.isEmpty else { return false }
        hasher.update(data: data)
        return true
    }) {}

    try Task.checkCancellation()
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func sha256Checksum(for fileURL: URL) throws -> String {
    let fileHandle = try FileHandle(forReadingFrom: fileURL)
    defer { try? fileHandle.close() }

    var hasher = SHA256()
    while autoreleasepool(invoking: {
        guard !Task.isCancelled else { return false }
        let data = fileHandle.readData(ofLength: 64 * 1024)
        guard !data.isEmpty else { return false }
        hasher.update(data: data)
        return true
    }) {}

    try Task.checkCancellation()
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func standardizedArtifactSourceURL(_ url: URL) -> URL {
    url.isFileURL ? url.standardizedFileURL : url.standardized
}

private func installedArtifactReceipt(
    _ receipt: InstalledArtifactReceipt,
    matches identity: ChecksumVerificationFileIdentity
) -> Bool {
    receipt.byteCount == identity.fileSize
        && receipt.modificationTimeIntervalSince1970
            == identity.modificationTimeIntervalSince1970
        && receipt.fileSystemNumber == identity.fileSystemNumber
        && receipt.fileSystemFileNumber == identity.fileSystemFileNumber
}

private enum InstalledArtifactReceiptValidationError: LocalizedError {
    case missingOrInvalid(URL)

    var errorDescription: String? {
        switch self {
        case .missingOrInvalid(let url):
            return "The installed download at \(url.path) has no valid acquisition receipt."
        }
    }
}

private struct InstalledArtifactReceiptPersistenceVerificationError: LocalizedError {
    let destination: URL

    var errorDescription: String? {
        "The installed-artifact receipt was not retained for \(destination.path)."
    }
}

public enum DownloadableChecksumVerificationError: LocalizedError, Equatable {
    case emptyFile(URL)
    case fileChangedDuringVerification(URL)
    case mismatch(expected: String, actual: String)

    public var requiresCleanRedownload: Bool {
        true
    }

    public var errorDescription: String? {
        switch self {
        case let .emptyFile(url):
            return "Cannot verify empty file at \(url.path)"
        case let .fileChangedDuringVerification(url):
            return "File changed while its checksum was being verified at \(url.path)"
        case let .mismatch(expected, actual):
            return "SHA-1 mismatch. Expected \(expected), got \(actual)"
        }
    }
}

private struct DownloadLocalFileInspectionError: LocalizedError {
    let url: URL
    let underlyingError: Error

    var errorDescription: String? {
        "Unable to inspect local file at \(url.path): \(underlyingError.localizedDescription)"
    }
}

private enum DownloadCompressedPayloadValidationError: LocalizedError {
    case emptyFile(URL)

    var errorDescription: String? {
        switch self {
        case let .emptyFile(url):
            return "The compressed download at \(url.path) is empty."
        }
    }
}

// TODO: Extract download state transitions + import handling into a small processor/state machine once behavior stabilizes.

@globalActor
public actor DownloadActor {
    public static let shared = DownloadActor()
}

fileprivate func errorDescription(from error: Error) -> String {
    let nsError = error as NSError
    if let checksumError = error as? DownloadableChecksumVerificationError {
        return checksumError.localizedDescription
    } else if let installError = error as? URLResourceDownloadInstallError {
        return installError.localizedDescription
    } else if let httpError = error as? URLResourceDownloadHTTPError {
        return httpError.localizedDescription
    }
    if let urlError = error as? URLError {
        switch urlError.code {
        case .unknown:
            return "Unknown Error"
        case .cancelled:
            return "Request Cancelled"
        case .badURL:
            return "Bad URL"
        case .timedOut:
            return "Request Timed Out"
        case .unsupportedURL:
            return "Unsupported URL"
        case .cannotFindHost:
            return "Cannot Find Host"
        case .cannotConnectToHost:
            return "Cannot Connect To Host"
        case .networkConnectionLost:
            return "Network Connection Lost"
        case .dnsLookupFailed:
            return "DNS Lookup Failed"
        case .httpTooManyRedirects:
            return "Too Many Redirects"
        case .resourceUnavailable:
            return "Resource Unavailable"
        case .notConnectedToInternet:
            return "Not Connected To Internet"
        case .redirectToNonExistentLocation:
            return "Redirect To Non-Existent Location"
        case .badServerResponse:
            return "Bad Server Response"
        case .userCancelledAuthentication:
            return "User Cancelled Authentication"
        case .userAuthenticationRequired:
            return "User Authentication Required"
        case .zeroByteResource:
            return "Zero Byte Resource"
        case .cannotDecodeRawData:
            return "Cannot Decode Raw Data"
        case .cannotDecodeContentData:
            return "Cannot Decode Content Data"
        case .cannotParseResponse:
            return "Cannot Parse Response"
        case .appTransportSecurityRequiresSecureConnection:
            return "App Transport Security Requires Secure Connection"
        case .fileDoesNotExist:
            return "File Does Not Exist"
        case .fileIsDirectory:
            return "File Is Directory"
        case .noPermissionsToReadFile:
            return "No Permissions To Read File"
        case .dataLengthExceedsMaximum:
            return "Data Length Exceeds Maximum"
        default:
            return urlError.localizedDescription
        }
    } else if let posixError = error as? POSIXError {
        switch posixError.code {
        case .ENOSPC: // No space on device
            return "No space left on device."
        default:
            return posixError.localizedDescription
        }
    } else if let httpResponse = nsError.userInfo[NSUnderlyingErrorKey] as? HTTPURLResponse {
        let statusCode = httpResponse.statusCode
        let statusCodeString = HTTPURLResponse.localizedString(forStatusCode: statusCode)
        let responseBody = nsError.userInfo[NSLocalizedDescriptionKey] as? String ?? ""
        return "HTTP Status Code: \(statusCode) - \(statusCodeString)\nResponse Body: \(responseBody)"
    } else {
        return nsError.localizedDescription
    }
}

fileprivate func requiresCleanChecksumRedownload(_ error: Error) -> Bool {
    (error as? DownloadableChecksumVerificationError)?
        .requiresCleanRedownload == true
}

fileprivate extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var addedDict = [Element: Bool]()

        return filter {
            addedDict.updateValue(true, forKey: $0) == nil
        }
    }

    mutating func removeDuplicates() {
        self = self.removingDuplicates()
    }
}

public class Downloadable: ObservableObject, Identifiable, Hashable, @unchecked Sendable {
    public static var groupIdentifier: String? = nil
    public let objectWillChange = ObservableObjectPublisher()
    
    public let url: URL
    let mirrorURL: URL?
    public let name: String
    public let localDestination: URL
    /// If the file is compressed, this is the post-decompression checksum.
    public let localDestinationChecksum: String?
    /// Generated artifacts which belong to this download but are not the
    /// downloaded payload itself. Orphan cleanup preserves these directories

    /// and their descendants when they are contained by its cleanup root.
    public let preservedLocalArtifactDirectories: Set<URL>
    var isFromBackgroundAssetsDownloader: Bool? = nil
    public let metadataStore: any DownloadableMetadataStore
    private let downloadMetadataCache: DownloadMetadataCache
    @MainActor public var shouldCheckForUpdates: Bool = true
    
    @MainActor
    @Published internal var downloadProgress: URLResourceDownloadTaskProgress = .uninitiated
    @MainActor
    @Published public var isFailed = false
    @MainActor
    @Published public var isActive = false
    @MainActor
    @Published public var isFinishedDownloading = false
    @MainActor
    @Published public var isFinishedProcessing = false
    @MainActor
    @Published public var fileSize: UInt64? = nil
    
    // Helpers to make sure we don't double-import the same thing multiple times
    public var finishedDownloadingDuringCurrentLaunchAt: Date?
    public var finishedLoadingDuringCurrentLaunchAt: Date?
    
    private var cancellables = Set<AnyCancellable>()
    private let downloadObservationLock = NSLock()
    private var downloadObservationGeneration = UUID()
    
    public var id: String {
        return url.absoluteString
    }

    private var shouldLogReaderOptimizationDiagnostics: Bool {
        let loweredName = name.lowercased()
        let loweredFilename = localDestination.lastPathComponent.lowercased()
        let loweredPath = localDestination.path.lowercased()
        return loweredName.contains("dictionary_index")
            || loweredName.contains("dictionary index")
            || loweredFilename.contains("lookup-cache")
            || loweredPath.contains("lookup-cache")
    }

    private func logReaderOptimizationDiagnostic(
        _ stage: String,
        _ details: [String: String] = [:]
    ) {
        guard shouldLogReaderOptimizationDiagnostics else { return }
        var segments: [String] = [
            "stage=\(stage)",
            "downloadName=\(name)",
            "filename=\(localDestination.lastPathComponent)"
        ]
        for key in details.keys.sorted() {
            if let value = details[key] {
                segments.append("\(key)=\(value)")
            }
        }
        debugPrint(segments.joined(separator: " "))
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    @MainActor
    public var failureMessage: String? {
        if let importable = self as? ImportableDownloadable,
           let importError = importable.lastImportError {
            return importError.localizedDescription
        }
        switch downloadProgress {
        case .completed(_, _, let error):
            if let error = error {
                return errorDescription(from: error)
            }
        default: break
        }
        return nil
    }

    @MainActor
    public var fractionCompleted: Double {
        return downloadProgress.fractionCompleted
    }
    
    @MainActor
    public var lastDownloadedETag: String? {
        get { downloadMetadataCache.currentMetadata().lastDownloadedETag }
        set {
            downloadMetadataCache.setLastDownloadedETag(newValue)
        }
    }
    
    @MainActor
    public var lastCheckedETagAt: Date? {
        get { downloadMetadataCache.currentMetadata().lastCheckedETagAt }
        set {
            downloadMetadataCache.setLastCheckedETagAt(newValue)
        }
    }
    
    @MainActor
    public var lastDownloaded: Date? {
        get { downloadMetadataCache.currentMetadata().lastDownloadedAt }
        set {
            downloadMetadataCache.setLastDownloadedAt(newValue)
        }
    }

    @MainActor
    public var lastModifiedAt: Date? {
        get { downloadMetadataCache.currentMetadata().lastModifiedAt }
        set {
            downloadMetadataCache.setLastModifiedAt(newValue)
        }
    }

    public func waitForDownloadMetadata() async {
        await downloadMetadataCache.waitForInitialLoad()
    }

    public var cachedDownloadMetadata: DownloadMetadata {
        downloadMetadataCache.currentMetadata()
    }

    public func waitForDownloadMetadataPersistence() async throws {
        try await downloadMetadataCache.waitForPendingSaves()
    }
    
    /// The checksum, when provided, describes the expanded file before import.
    public init(
        url: URL,
        mirrorURL: URL? = nil,
        name: String,
        localDestination: URL,
        localDestinationChecksum: String? = nil,
        preservedLocalArtifactDirectories: Set<URL> = [],
        isFromBackgroundAssetsDownloader: Bool? = nil,
        metadataStore: (any DownloadableMetadataStore)? = nil
    ) {
        self.url = url
        self.mirrorURL = mirrorURL
        self.name = name
        self.localDestination = localDestination
        self.localDestinationChecksum = localDestinationChecksum
        self.preservedLocalArtifactDirectories = Set(
            preservedLocalArtifactDirectories.map(\.standardizedFileURL)
        )
        self.isFromBackgroundAssetsDownloader = isFromBackgroundAssetsDownloader
        let resolvedMetadataStore = metadataStore ?? UserDefaultsDownloadableMetadataStore()
        self.metadataStore = resolvedMetadataStore
        self.downloadMetadataCache = DownloadMetadataCache.shared(store: resolvedMetadataStore, url: url)
        let metadataObservationRelay = DownloadMetadataObservationRelay()
        metadataObservationRelay.owner = self
        self.downloadMetadataCache.startLoading(observationRelay: metadataObservationRelay)
    }
    
    public static func == (lhs: Downloadable, rhs: Downloadable) -> Bool {
        return lhs.url == rhs.url
            && lhs.mirrorURL == rhs.mirrorURL
            && lhs.name == rhs.name
            && lhs.localDestination == rhs.localDestination
            && lhs.localDestinationChecksum == rhs.localDestinationChecksum
            && lhs.preservedLocalArtifactDirectories
                == rhs.preservedLocalArtifactDirectories
    }
    
    public var localDestinationFilename: String {
        return localDestination.lastPathComponent
    }
    
    public var compressedFileURL: URL {
        return localDestination.appendingPathExtension("br")
    }

    public var checksumVerificationMarkerURL: URL {
        return localDestination.appendingPathExtension("sha1verified.json")
    }
    
    public var stringContent: String? {
        return try? String(contentsOf: localDestination)
    }

    public func hasVerifiedLocalDestinationChecksumMarker() -> Bool {
        guard let expectedChecksum = localDestinationChecksum?.lowercased() else {
            return FileManager.default.fileExists(atPath: localDestination.path)
        }
        guard let fileAttributes = try? FileManager.default.attributesOfItem(atPath: localDestination.path) else {
            return false
        }
        guard let identity = checksumVerificationFileIdentity(from: fileAttributes) else {
            return false
        }
        guard let verification = try? loadChecksumVerificationMarker() else { return false }
        return verification.expectedChecksum == expectedChecksum
            && checksumVerificationMarker(verification, matches: identity)
    }

    public func hasReadableLocalDestination() -> Bool {
        guard let fileAttributes = try? FileManager.default.attributesOfItem(atPath: localDestination.path) else {
            return false
        }
        let fileSize = (fileAttributes[.size] as? NSNumber)?.uint64Value ?? 0
        return fileSize > 0
    }

    public func isReadyForImmediateLocalRead() -> Bool {
        if localDestinationChecksum == nil {
            return validInstalledArtifactReceipt() != nil
        }
        return hasVerifiedLocalDestinationChecksumMarker()
    }

    func hasAdmissibleInstalledArtifact() -> Bool {
        if localDestinationChecksum != nil {
            return hasVerifiedLocalDestinationChecksumMarker()
        }
        return validInstalledArtifactReceipt() != nil
    }

    func hasProcessableLocalArtifact() -> Bool {
        if FileManager.default.fileExists(atPath: localDestination.path) {
            return localDestinationChecksum != nil
                || validInstalledArtifactReceipt() != nil
        }
        return url.pathExtension == "br"
            && FileManager.default.fileExists(atPath: compressedFileURL.path)
    }

    var installedArtifactReceiptStorageKey: String {
        [
            standardizedArtifactSourceURL(url).absoluteString,
            localDestination.standardizedFileURL.absoluteString
        ].joined(separator: "\u{0}")
    }

    func validInstalledArtifactReceipt() -> InstalledArtifactReceipt? {
        let receipt: InstalledArtifactReceipt
        do {
            guard let storedReceipt = try metadataStore.installedArtifactReceipt(
                sourceURL: url,
                destinationURL: localDestination
            ) else {
                return nil
            }
            receipt = storedReceipt
        } catch {
            try? removeInstalledArtifactReceipt()
            return nil
        }

        guard installedArtifactMatches(receipt) else {
            if !Task.isCancelled {
                try? removeInstalledArtifactReceipt()
            }
            return nil
        }
        return receipt
    }

    func installedArtifactMatches(_ receipt: InstalledArtifactReceipt) -> Bool {
        let standardizedSourceURL = standardizedArtifactSourceURL(url)
        let standardizedDestinationURL = localDestination.standardizedFileURL
        guard receipt.schemaVersion == InstalledArtifactReceipt.currentSchemaVersion,
              receipt.requestedSourceURL == standardizedSourceURL,
              receipt.destinationURL == standardizedDestinationURL,
              let attributes = try? FileManager.default.attributesOfItem(
                atPath: localDestination.path
              ),
              let initialIdentity = checksumVerificationFileIdentity(
                from: attributes
              ),
              installedArtifactReceipt(receipt, matches: initialIdentity),
              let digest = try? sha256Checksum(for: localDestination),
              digest == receipt.sha256Digest,
              let currentAttributes = try? FileManager.default.attributesOfItem(
                atPath: localDestination.path
              ),
              checksumVerificationFileIdentity(from: currentAttributes)
                == initialIdentity else {
            return false
        }
        return true
    }

    func makeInstalledArtifactReceipt(
        finalResponseURL: URL?
    ) throws -> InstalledArtifactReceipt {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: localDestination.path
        )
        guard let identity = checksumVerificationFileIdentity(from: attributes) else {
            throw DownloadableChecksumVerificationError.emptyFile(localDestination)
        }
        let digest = try sha256Checksum(for: localDestination)
        try requireFileIdentity(identity, at: localDestination)
        return InstalledArtifactReceipt(
            requestedSourceURL: standardizedArtifactSourceURL(url),
            finalResponseURL: finalResponseURL.map(standardizedArtifactSourceURL),
            destinationURL: localDestination.standardizedFileURL,
            sha256Digest: digest,
            byteCount: identity.fileSize,
            modificationTimeIntervalSince1970: identity.modificationTimeIntervalSince1970,
            fileSystemNumber: identity.fileSystemNumber,
            fileSystemFileNumber: identity.fileSystemFileNumber
        )
    }

    func persistInstalledArtifactReceipt(
        _ receipt: InstalledArtifactReceipt
    ) throws {
        do {
            try metadataStore.saveInstalledArtifactReceipt(
                receipt,
                sourceURL: url,
                destinationURL: localDestination
            )
            guard try metadataStore.installedArtifactReceipt(
                sourceURL: url,
                destinationURL: localDestination
            ) == receipt else {
                throw InstalledArtifactReceiptPersistenceVerificationError(
                    destination: localDestination
                )
            }
        } catch {
            throw DownloadMetadataPersistenceError(error)
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: localDestination.path
        )
        guard let identity = checksumVerificationFileIdentity(from: attributes),
              installedArtifactReceipt(receipt, matches: identity) else {
            try? removeInstalledArtifactReceipt()
            throw DownloadableChecksumVerificationError
                .fileChangedDuringVerification(localDestination)
        }
    }

    func removeInstalledArtifactReceipt() throws {
        try metadataStore.removeInstalledArtifactReceipt(
            sourceURL: url,
            destinationURL: localDestination
        )
    }

    public func ensureVerifiedLocalDestinationChecksum() throws {
        guard let expectedChecksum = localDestinationChecksum?.lowercased() else { return }
        let startedAt = Date()
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: localDestination.path)
        guard let initialIdentity = checksumVerificationFileIdentity(from: fileAttributes) else {
            throw DownloadableChecksumVerificationError.emptyFile(
                localDestination
            )
        }

        if let verification = try loadChecksumVerificationMarker(),
           verification.expectedChecksum == expectedChecksum,
           checksumVerificationMarker(verification, matches: initialIdentity) {
            logReaderOptimizationDiagnostic(
                "download.checksum.markerHit",
                [
                    "elapsed": String(format: "%.3fs", Date().timeIntervalSince(startedAt)),
                    "fileSize": String(initialIdentity.fileSize)
                ]
            )
            return
        }

        logReaderOptimizationDiagnostic(
            "download.checksum.markerMiss",
            [
                "expectedChecksumPrefix": String(expectedChecksum.prefix(8)),
                "fileSize": String(initialIdentity.fileSize),
                "markerExists": String(FileManager.default.fileExists(atPath: checksumVerificationMarkerURL.path))
            ]
        )
        do {
            try verifyChecksum(
                of: localDestination,
                expectedChecksum: expectedChecksum
            )
        } catch {
            try? FileManager.default.removeItem(
                at: checksumVerificationMarkerURL
            )
            throw error
        }
        let verifiedAttributes = try FileManager.default.attributesOfItem(
            atPath: localDestination.path
        )
        guard checksumVerificationFileIdentity(from: verifiedAttributes)
                == initialIdentity else {
            try? FileManager.default.removeItem(at: checksumVerificationMarkerURL)
            throw DownloadableChecksumVerificationError
                .fileChangedDuringVerification(localDestination)
        }
        try recordVerifiedLocalDestinationChecksum(
            expectedChecksum: expectedChecksum,
            identity: initialIdentity
        )
    }

    fileprivate func ensureVerifiedChecksum(
        of candidateURL: URL
    ) throws -> ChecksumVerificationFileIdentity {
        let initialAttributes = try FileManager.default.attributesOfItem(
            atPath: candidateURL.path
        )
        guard let initialIdentity = checksumVerificationFileIdentity(
            from: initialAttributes
        ) else {
            throw DownloadableChecksumVerificationError.emptyFile(candidateURL)
        }
        if let expectedChecksum = localDestinationChecksum?.lowercased() {
            try verifyChecksum(
                of: candidateURL,
                expectedChecksum: expectedChecksum
            )
        }
        try requireFileIdentity(
            initialIdentity,
            at: candidateURL
        )
        return initialIdentity
    }

    fileprivate func requireFileIdentity(
        _ expectedIdentity: ChecksumVerificationFileIdentity,
        at fileURL: URL
    ) throws {
        guard let currentAttributes = try? FileManager.default
                .attributesOfItem(atPath: fileURL.path),
              checksumVerificationFileIdentity(from: currentAttributes)
                == expectedIdentity else {
            throw DownloadableChecksumVerificationError
                .fileChangedDuringVerification(fileURL)
        }
    }

    fileprivate func recordVerifiedLocalDestinationChecksum(
        identity: ChecksumVerificationFileIdentity,
        checkingCancellation: Bool = true
    ) throws {
        try requireFileIdentity(identity, at: localDestination)
        guard let expectedChecksum = localDestinationChecksum?.lowercased() else {
            return
        }
        try recordVerifiedLocalDestinationChecksum(
            expectedChecksum: expectedChecksum,
            identity: identity,
            checkingCancellation: checkingCancellation
        )
    }

    func recordVerifiedLocalDestinationChecksum(
        checkingCancellation: Bool = true
    ) throws {
        guard let expectedChecksum = localDestinationChecksum?.lowercased() else {
            return
        }
        try recordVerifiedLocalDestinationChecksum(
            expectedChecksum: expectedChecksum,
            checkingCancellation: checkingCancellation
        )
    }

    private func verifyChecksum(
        of fileURL: URL,
        expectedChecksum: String
    ) throws {
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )
        let fileSize = (fileAttributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard fileSize > 0 else {
            throw DownloadableChecksumVerificationError.emptyFile(fileURL)
        }
        let hashStartedAt = Date()
        let actualChecksum = try sha1Checksum(for: fileURL)
        logReaderOptimizationDiagnostic(
            "download.checksum.sha1Complete",
            [
                "elapsed": String(format: "%.3fs", Date().timeIntervalSince(hashStartedAt)),
                "matched": String(actualChecksum == expectedChecksum)
            ]
        )
        guard actualChecksum == expectedChecksum else {
            throw DownloadableChecksumVerificationError.mismatch(
                expected: expectedChecksum,
                actual: actualChecksum
            )
        }
    }

    private func recordVerifiedLocalDestinationChecksum(
        expectedChecksum: String,
        checkingCancellation: Bool = true
    ) throws {
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: localDestination.path
        )
        guard let identity = checksumVerificationFileIdentity(from: fileAttributes) else {
            throw DownloadableChecksumVerificationError.emptyFile(
                localDestination
            )
        }
        try recordVerifiedLocalDestinationChecksum(
            expectedChecksum: expectedChecksum,
            identity: identity,
            checkingCancellation: checkingCancellation
        )
    }

    private func recordVerifiedLocalDestinationChecksum(
        expectedChecksum: String,
        identity: ChecksumVerificationFileIdentity,
        checkingCancellation: Bool = true
    ) throws {
        let startedAt = Date()
        let marker = ChecksumVerificationMarker(
            schemaVersion: checksumVerificationMarkerSchemaVersion,
            expectedChecksum: expectedChecksum,
            fileSize: identity.fileSize,
            modificationTimeIntervalSince1970: identity.modificationTimeIntervalSince1970,
            fileSystemNumber: identity.fileSystemNumber,
            fileSystemFileNumber: identity.fileSystemFileNumber
        )
        if checkingCancellation {
            try Task.checkCancellation()
        }
        let data = try JSONEncoder().encode(marker)
        try data.write(to: checksumVerificationMarkerURL, options: .atomic)
        let currentAttributes = try FileManager.default.attributesOfItem(
            atPath: localDestination.path
        )
        guard checksumVerificationFileIdentity(from: currentAttributes) == identity else {
            try? FileManager.default.removeItem(at: checksumVerificationMarkerURL)
            throw DownloadableChecksumVerificationError
                .fileChangedDuringVerification(localDestination)
        }
        logReaderOptimizationDiagnostic(
            "download.checksum.markerWrite",
            [
                "elapsed": String(format: "%.3fs", Date().timeIntervalSince(startedAt)),
                "markerFilename": checksumVerificationMarkerURL.lastPathComponent
            ]
        )
    }

    private func loadChecksumVerificationMarker() throws -> ChecksumVerificationMarker? {
        guard FileManager.default.fileExists(atPath: checksumVerificationMarkerURL.path) else { return nil }
        let data = try Data(contentsOf: checksumVerificationMarkerURL)
        return try JSONDecoder().decode(ChecksumVerificationMarker.self, from: data)
    }
    
    @MainActor
    public var humanizedFileSize: String? {
        guard let fileSize else { return nil }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = Double(fileSize), unitIndex = 0
        while size > 1024 && unitIndex < units.count - 1 { size /= 1024; unitIndex += 1 }
        return unitIndex < 2 ? String(format: "%.0f \(units[unitIndex])", size) : String(format: "%.1f \(units[unitIndex])", size)
    }
    
    /// Returns whether it became downloaded.
    @MainActor
    public func awaitCompletionOrFailure() async throws -> Bool {
        guard !(isFinishedProcessing || isFailed) else {
            return isFinishedProcessing && !isFailed
        }

        while true {
            try Task.checkCancellation()
            if isFailed {
                return false
            }
            if isFinishedProcessing {
                return true
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    
    @DownloadActor
    public func existsLocally() async -> Bool {
        FileManager.default.fileExists(atPath: localDestination.path)
            || (url.pathExtension == "br" && FileManager.default.fileExists(atPath: compressedFileURL.path))
    }

    /// Validates an installed artifact away from the main actor. Callers that
    /// need to open a catalog download immediately must use this instead of
    /// treating path presence as proof that the bytes belong to the download.
    @DownloadActor
    public func hasVerifiedInstalledArtifact() -> Bool {
        isReadyForImmediateLocalRead()
    }
    
    @DownloadActor
    public func fetchRemoteFileSize() async throws {
        if await !existsLocally() {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 6)
            request.httpMethod = "HEAD"
            do {
                let fileSize = try await UInt64(URLSession.shared.data(for: request).1.expectedContentLength)
                await MainActor.run {
                    self.fileSize = fileSize
                }
            } catch {
                throw(error)
            }
        }
    }
    
    @DownloadActor
    func download(
        session: URLSession,
        destination: URL
    ) async -> URLResourceDownloadTask {
        let observationGeneration = beginDownloadObservation()
        let task = URLResourceDownloadTask(session: session, url: url, destination: destination)
        
        task.publisher.receive(on: DispatchQueue.main).sink(
            receiveCompletion: { _ in
                // DownloadController owns the attempt generation and publishes
                // terminal UI state only after its subscribe-before-resume
                // waiter has observed the unique terminal result. Publishing
                // here would let an obsolete delegate callback overwrite a
                // newer attempt or deletion.
            },
            receiveValue: { [weak self] progress in
//            Task { @MainActor [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.downloadObservationIsCurrent(
                        observationGeneration
                      ) else { return }
                downloadProgress = progress
                // CHATGPT: INSERT self?.fileSize = ((uint64 here...))
                switch progress {
                    //            case .completed(let destinationLocation, let etag, let urlError):
                    //                guard urlError == nil, let destinationLocation = destinationLocation else {
                    //                    isFailed = true
                    //                    isFinishedDownloading = false
                    //                    isActive = false
                    //                    return
                    //                }
                    //                finishedDownloadingDuringCurrentLaunchAt = Date()
                    //                lastDownloadedETag = etag
                    //                lastDownloaded = Date()
                    //                isFinishedDownloading = true
                    //                isActive = false
                    //                isFailed = false
                case .downloading(let progress):
                    fileSize = UInt64(progress.totalUnitCount)
                    if !progress.isFinished, !progress.isCancelled {
                        isFailed = false
                        isActive = true
                        isFinishedDownloading = false
                    }
                case .uninitiated:
                    isActive = true
                case .completed:
                    // Terminal state is generation-fenced by DownloadController.
                    break
                case .waitingForResponse:
                    isActive = true
                }
            }
//            }
        }).store(in: &cancellables)
        
        await { @MainActor in
            isFinishedDownloading = false
            isActive = true
            isFailed = false
        }()
        
        // The controller installs its terminal waiter before resuming this
        // task. A PassthroughSubject does not replay a fast completion.
        return task
    }

    func uncompressedTransferStagingURL(operationID: UUID) -> URL {
        let pathExtension = localDestination.pathExtension

        let baseName = localDestination.lastPathComponent
        let suffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        return localDestination.deletingLastPathComponent()
            .appendingPathComponent(
                "\(baseName).downloading.\(operationID.uuidString)\(suffix)"
            )
    }

    func compressedTransferStagingURL(operationID: UUID) -> URL {
        uncompressedTransferStagingURL(operationID: operationID)
            .appendingPathExtension("br")
    }

    private func beginDownloadObservation() -> UUID {
        downloadObservationLock.withLock {
            downloadObservationGeneration = UUID()
            return downloadObservationGeneration
        }
    }

    func invalidateDownloadObservation() {
        downloadObservationLock.withLock {
            downloadObservationGeneration = UUID()
        }
    }

    private func downloadObservationIsCurrent(_ generation: UUID) -> Bool {
        downloadObservationLock.withLock {
            downloadObservationGeneration == generation
        }
    }
    
    @DownloadActor
    func sizeForLocalFile() -> UInt64 {
        do {
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: localDestination.path)
            if let fileSize = fileAttributes[FileAttributeKey.size] as? NSNumber {
                return fileSize.uint64Value
            }
        } catch { }
        return 0
    }


    func decompressCandidate(
        at compressedCandidateURL: URL,
        operationID: UUID = UUID()
    ) throws -> URL {        if FileManager.default.fileExists(atPath: compressedCandidateURL.path) {
            let compressedFileSize: Int
            do {
                guard let fileSize = try compressedCandidateURL.resourceValues(
                    forKeys: [.fileSizeKey]
                ).fileSize else {
                    throw CocoaError(.fileReadUnknown)
                }
                compressedFileSize = fileSize
            } catch {
                throw DownloadLocalFileInspectionError(
                    url: compressedCandidateURL,
                    underlyingError: error
                )
            }
            if compressedFileSize == 0 {
                throw DownloadCompressedPayloadValidationError.emptyFile(
                    compressedCandidateURL
                )
            }

            // A unique output prevents a cancelled older processor from
            // deleting or replacing a newer attempt's staging file.
            let temporaryOutputURL = localDestination.appendingPathExtension(
                "decompressing.\(operationID.uuidString)"
            )
            try? FileManager.default.removeItem(at: temporaryOutputURL)
            do {
                try decompressBrotliFile(
                    at: compressedCandidateURL,
                    to: temporaryOutputURL
                )
                try Task.checkCancellation()
                return temporaryOutputURL
            } catch {
                try? FileManager.default.removeItem(at: temporaryOutputURL)
                throw error
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }
}

private func decompressBrotliFile(at sourceURL: URL, to destinationURL: URL) throws {
    try BrotliFileDecompressor.decompressFile(at: sourceURL, to: destinationURL)
}

public enum DownloadDirectory {
    // TODO: Cache destinations
    
    case documents(
        parentDirectoryName: String?,
        subdirectoryName: String? = nil,
        groupIdentifier: String?
    )
    
    case appSupport(
        parentDirectoryName: String?,
        subdirectoryName: String? = nil,
        groupIdentifier: String?
    )
    
    public var directoryURL: URL {
#if DEBUG
        if let configuredRoot = ProcessInfo.processInfo.environment["JVIDS_MANABI_DATA_ROOT"],
           !configuredRoot.isEmpty {
            var url = URL(fileURLWithPath: configuredRoot, isDirectory: true)
            switch self {
            case .documents(let parentDirectoryName, let subdirectoryName, _),
                 .appSupport(let parentDirectoryName, let subdirectoryName, _):
                if let parentDirectoryName {
                    url.appendPathComponent(parentDirectoryName, isDirectory: true)
                }
                if let subdirectoryName {
                    url.appendPathComponent(subdirectoryName, isDirectory: true)
                }
            }
            return url
        }
#endif
        switch self {
        case .documents(
            let parentDirectoryName,
            let subdirectoryName,
            let groupIdentifier
        ):
            var containerURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            if let groupIdentifier = groupIdentifier, let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) {
                containerURL = sharedContainerURL
            }
#if DEBUG
            if let testAppGroupURL = Self.testAppGroupURL(groupIdentifier: groupIdentifier) {
                containerURL = testAppGroupURL
            }
#endif
            var url = containerURL.appendingPathComponent("swiftui-downloads", isDirectory: true)
            
            if let parentDirectoryName {
                url = containerURL.appendingPathComponent(parentDirectoryName, isDirectory: true)
            }
            
            if let subdirectoryName {
                url = url.appendingPathComponent(subdirectoryName, isDirectory: true)
            }
            
            return url
            
        case .appSupport(let parentDirectoryName, let subdirectoryName, let groupIdentifier):
            var containerURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            if let groupIdentifier = groupIdentifier, let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) {
                containerURL = sharedContainerURL
            }
#if DEBUG
            if let testAppGroupURL = Self.testAppGroupURL(groupIdentifier: groupIdentifier) {
                containerURL = testAppGroupURL
            }
#endif
            var url = containerURL
            if let parentDirectoryName {
                url = url.appendingPathComponent(parentDirectoryName, isDirectory: true)
            }
            if let subdirectoryName {
                url = url.appendingPathComponent(subdirectoryName, isDirectory: true)
            }
            return url
        }
    }

#if DEBUG
    private static func testAppGroupURL(groupIdentifier: String?) -> URL? {
        guard groupIdentifier != nil else { return nil }
        if let testAppGroupPath = ProcessInfo.processInfo.environment["MANABI_TEST_APP_GROUP_DIR"],
           !testAppGroupPath.isEmpty {
            return URL(fileURLWithPath: testAppGroupPath, isDirectory: true)
        }
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTest.XCTestCase") != nil
        guard isRunningTests else { return nil }
        return URL(fileURLWithPath: "/tmp/manabi-reader-test-app-group", isDirectory: true)
    }
#endif
}

public extension Downloadable {
    convenience init(
        name: String,
        destination: DownloadDirectory,
        filename: String? = nil,
        url: URL,
        localDestinationChecksum: String? = nil,
        preservedLocalArtifactDirectories: Set<URL> = [],
        metadataStore: (any DownloadableMetadataStore)? = nil
    ) {
//        let filename = filename ?? url.lastPathComponent.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? url.lastPathComponent
        let filename = filename ?? url.lastPathComponent
        // TODO: macos 13+:   Downloadable(url: URL(string: "https://manabi.io/static/dictionaries/furigana.realm.br")!, mirrorURL: nil, name: "Furigana Data", localDestination: folderURL.appending(component: "furigana.realm")),
        self.init(
            url: url,
            mirrorURL: url,
            name: name,
            localDestination: destination.directoryURL.appendingPathComponent(filename),
            localDestinationChecksum: localDestinationChecksum,
            preservedLocalArtifactDirectories: preservedLocalArtifactDirectories,
            metadataStore: metadataStore
        )
    }
    
    // Deprecated; remove in favor of above with DownloadDirectory.
    convenience init?(name: String, groupIdentifier: String? = nil, parentDirectoryName: String, filename: String? = nil, downloadMirrors: [URL]) {
        guard let url = downloadMirrors.first else {
            return nil
        }
//        let filename = filename ?? url.lastPathComponent.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? url.lastPathComponent
        let filename = filename ?? url.lastPathComponent
        var containerURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        
        if let groupIdentifier = groupIdentifier ?? Self.groupIdentifier, let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) {
            containerURL = sharedContainerURL
        }

        guard let folderURL = containerURL?
            .appendingPathComponent(parentDirectoryName, isDirectory: true) else {
            return nil
        }
        // TODO: macos 13+:   Downloadable(url: URL(string: "https://manabi.io/static/dictionaries/furigana.realm.br")!, mirrorURL: nil, name: "Furigana Data", localDestination: folderURL.appending(component: "furigana.realm")),
        self.init(url: url, mirrorURL: downloadMirrors.dropFirst().first, name: name, localDestination: folderURL.appendingPathComponent(filename))
    }
}

@available(macOS 13.0, iOS 16.1, *)
public extension Downloadable {
    func backgroundAssetDownload(applicationGroupIdentifier: String? = nil) -> BAURLDownload? {
        guard let applicationGroupIdentifier = applicationGroupIdentifier ?? Self.groupIdentifier else { return nil }
        return BAURLDownload(identifier: localDestination.absoluteString, request: URLRequest(url: url), applicationGroupIdentifier: applicationGroupIdentifier, priority: .max)
    }
}

private enum DownloadAttemptExecutionError: LocalizedError {
    case completedStateMissing(url: URL)

    var errorDescription: String? {
        switch self {
        case .completedStateMissing(let url):
            return "Download finished without a terminal state for \(url.absoluteString)"
        }
    }
}

/// Internal handoff from the completed GET to its owning processing attempt.
/// Keeping this separate preserves the public progress enum's source shape.
struct DownloadTransferResult: Sendable {
    let destinationLocation: URL
    let etag: String?
    let lastModified: Date?
    let finalResponseURL: URL?

    init(
        destinationLocation: URL,
        etag: String?,
        lastModified: Date?,
        finalResponseURL: URL? = nil
    ) {
        self.destinationLocation = destinationLocation
        self.etag = etag
        self.lastModified = lastModified
        self.finalResponseURL = finalResponseURL
    }
}

private final class DownloadAttemptTerminalWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let lastModified: @Sendable () -> Date?
    private let finalResponseURL: @Sendable () -> URL?
    private var continuation: CheckedContinuation<DownloadTransferResult, Error>?
    private var cancellable: AnyCancellable?

    init(
        url: URL,
        lastModified: @escaping @Sendable () -> Date?,
        finalResponseURL: @escaping @Sendable () -> URL?,
        continuation: CheckedContinuation<DownloadTransferResult, Error>
    ) {
        self.url = url
        self.lastModified = lastModified
        self.finalResponseURL = finalResponseURL
        self.continuation = continuation
    }

    func subscribe(to publisher: AnyPublisher<URLResourceDownloadTaskProgress, Error>) {
        let cancellable = publisher.sink(
            receiveCompletion: { [self] completion in
                switch completion {
                case .failure(let error):
                    finish(.failure(error))
                case .finished:
                    finish(.failure(
                        DownloadAttemptExecutionError
                            .completedStateMissing(url: url)
                    ))
                }
            },
            receiveValue: { [self] progress in
                guard case let .completed(
                    destinationLocation,
                    etag,
                    error
                ) = progress else { return }
                if let error {
                    finish(.failure(error))
                } else if let destinationLocation {
                    finish(.success(DownloadTransferResult(
                        destinationLocation: destinationLocation,
                        etag: etag,
                        lastModified: lastModified(),
                        finalResponseURL: finalResponseURL()
                    )))
                } else {
                    finish(.failure(
                        DownloadAttemptExecutionError
                            .completedStateMissing(url: url)
                    ))
                }
            }
        )
        lock.lock()
        if continuation == nil {
            lock.unlock()
            cancellable.cancel()
            return
        }
        self.cancellable = cancellable
        lock.unlock()
    }

    private func finish(_ result: Result<DownloadTransferResult, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let cancellable = self.cancellable
        self.cancellable = nil
        lock.unlock()

        cancellable?.cancel()
        continuation.resume(with: result)
    }
}

public class DownloadController: NSObject, ObservableObject, @unchecked Sendable {
    public let objectWillChange = ObservableObjectPublisher()
    
    typealias DownloadAttemptExecutor = @Sendable (
        _ download: Downloadable,
        _ session: URLSession
    ) async throws -> DownloadTransferResult
    private struct ProcessingTaskRecord {
        let id: UUID
        let task: Task<Void, Never>
    }
    private struct SuccessfulDownloadMetadata: Sendable {
        let downloadedAt: Date
        let etag: String?
        let remoteModifiedAt: Date?
        let checkedAt: Date?
    }
    private struct PendingInstalledArtifactReceipt: Sendable {
        let receipt: InstalledArtifactReceipt
        let successfulDownloadMetadata: SuccessfulDownloadMetadata?
    }

    nonisolated(unsafe) public static var shared: DownloadController = {
        let controller = DownloadController()
//        if Bundle.main.object(forInfoDictionaryKey: "BAInitialDownloadRestrictions") != nil {
//            Task.detached(priority: .utility) { [weak controller] in
//                if #available(macOS 13.0, iOS 16.1, *) {
//                    BADownloadManager.shared.delegate = controller
//                } else { }
//            }
//        }
        return controller
    }()
    
    @MainActor
    @Published public var isPending = false
    @MainActor
    @Published public var assuredDownloads = Set<Downloadable>()
    @MainActor
    @Published public var activeDownloads = Set<Downloadable>()
    @MainActor
    @Published public var finishedDownloads = Set<Downloadable>()
    @MainActor
    @Published public var failedDownloads = Set<Downloadable>()

    @MainActor
    public var unfinishedDownloads: [Downloadable] {
        let active = activeDownloads.filter {
            $0.isActive
                && !$0.isFailed
                && !$0.isFinishedDownloading
                && !$0.isFinishedProcessing
        }
        let failed = failedDownloads.filter(\.isFailed)
        let downloads: [Downloadable] = Array(Set(active).union(Set(failed)))
        return downloads.sorted(by: { $0.name > $1.name })
    }

    @MainActor
    public var unfinishedDownloadsIncludingImports: [Downloadable] {
        let importing = finishedDownloads.filter { !$0.isFinishedProcessing }
        let active = activeDownloads.filter {
            $0.isActive
                && !$0.isFailed
                && !$0.isFinishedDownloading
                && !$0.isFinishedProcessing
        }
        let failed = failedDownloads.filter(\.isFailed)
        let downloads = Set(active)
            .union(Set(failed))
            .union(Set(importing))
        return Array(downloads).sorted(by: { $0.name > $1.name })
    }
    
    private var observation: NSKeyValueObservation?
    private var cancellables = Set<AnyCancellable>()
    private var downloadStatusCancellables = [String: Set<AnyCancellable>]()
    private var processingTasks = [String: ProcessingTaskRecord]()
    private var checksumRecoveryTasks = [String: ProcessingTaskRecord]()
    private var downloadTasks = [String: ProcessingTaskRecord]()
    private var downloadAttemptIDs = [String: UUID]()
    private var activeTransferStagingURLs = Set<URL>()
    private var checksumRecoveriesReadyForProcessing = Set<String>()
    private var checksumRedownloadAttempted = Set<String>()
    private var completionMetadataRetryDownloadIDs = Set<String>()
    private var pendingInstalledArtifactReceipts = [String: PendingInstalledArtifactReceipt]()
    private let session: URLSession
    private let attemptExecutor: DownloadAttemptExecutor?
    private let retryPolicyProvider: @Sendable () -> DownloadRetryPolicy
    private let retrySleeper: @Sendable (UInt64) async throws -> Void
    
    public override init() {
        self.session = .shared
        self.attemptExecutor = nil
        self.retryPolicyProvider = { .default }
        self.retrySleeper = { try await Task.sleep(nanoseconds: $0) }
        super.init()
        configureStateObservers()
        configureAppLifecycleObservers()
    }

    public init(session: URLSession) {
        self.session = session
        self.attemptExecutor = nil
        self.retryPolicyProvider = { .default }
        self.retrySleeper = { try await Task.sleep(nanoseconds: $0) }
        super.init()
        configureStateObservers()
        configureAppLifecycleObservers()
    }

    init(
        session: URLSession,
        attemptExecutor: DownloadAttemptExecutor?,
        retryPolicyProvider: @escaping @Sendable () -> DownloadRetryPolicy = { .default },
        retrySleeper: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        }
    ) {
        self.session = session
        self.attemptExecutor = attemptExecutor
        self.retryPolicyProvider = retryPolicyProvider
        self.retrySleeper = retrySleeper
        super.init()
        configureStateObservers()
        configureAppLifecycleObservers()
    }

    private func configureStateObservers() {
        $activeDownloads
            .removeDuplicates()
//            .print("#")
            .combineLatest($failedDownloads.removeDuplicates())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.refreshPublishedDownloadState()
                }
            }
            .store(in: &cancellables)
    }


    /// Re-derive aggregate publication from each child's current lifecycle
    /// state after publisher scheduling. Captured set values can be stale by
    /// the time this work reaches the main actor.
    @MainActor
    private func refreshPublishedDownloadState() {
        let currentActiveDownloads = Set(activeDownloads.filter {
            $0.isActive
                && !$0.isFailed
                && !$0.isFinishedDownloading
                && !$0.isFinishedProcessing

        })
        let currentFailedDownloads = Set(failedDownloads.filter(\.isFailed))
        let currentFinishedDownloads = Set(finishedDownloads.filter {
            $0.isFinishedDownloading && !$0.isFailed
        })
        if activeDownloads != currentActiveDownloads {
            activeDownloads = currentActiveDownloads
        }
        if failedDownloads != currentFailedDownloads {
            failedDownloads = currentFailedDownloads
        }
        if finishedDownloads != currentFinishedDownloads {
            finishedDownloads = currentFinishedDownloads
        }
        let pending = !currentActiveDownloads.isEmpty || !currentFailedDownloads.isEmpty
        if isPending != pending {
            isPending = pending
        } else {
            objectWillChange.send()
        }
    }

    private func configureAppLifecycleObservers() {
#if canImport(UIKit)
        NotificationCenter.default
            .publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @DownloadActor [weak self] in
                    await self?.cancelLongRunningWorkForBackgrounding()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: UIApplication.willEnterForegroundNotification)
            .merge(with: NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification))
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @DownloadActor [weak self] in
                    await self?.resumeRecoverableDownloadsAfterForegrounding()
                }
            }
            .store(in: &cancellables)
#endif
    }
}

struct DownloadRetryPolicy: Sendable {
    let maxAttempts: Int
    let initialDelaySeconds: Double
    let maxDelaySeconds: Double
    let jitterFraction: Double
    let maxServerRetryAfterSeconds: Double

    static var `default`: DownloadRetryPolicy {
        let env = ProcessInfo.processInfo.environment
        let attempts = max(1, Int(env["MANABI_DOWNLOAD_MAX_ATTEMPTS"] ?? "") ?? 3)
        let initialDelay = max(0.05, Double(env["MANABI_DOWNLOAD_INITIAL_RETRY_DELAY_SECONDS"] ?? "") ?? 0.7)
        let maxDelay = max(initialDelay, Double(env["MANABI_DOWNLOAD_MAX_RETRY_DELAY_SECONDS"] ?? "") ?? 6.0)
        let jitter = min(max(Double(env["MANABI_DOWNLOAD_RETRY_JITTER_FRACTION"] ?? "") ?? 0.35, 0), 1)
        let maxRetryAfter = max(
            maxDelay,
            Double(env["MANABI_DOWNLOAD_MAX_SERVER_RETRY_AFTER_SECONDS"] ?? "") ?? 120.0
        )
        return DownloadRetryPolicy(
            maxAttempts: attempts,
            initialDelaySeconds: initialDelay,
            maxDelaySeconds: maxDelay,
            jitterFraction: jitter,
            maxServerRetryAfterSeconds: maxRetryAfter
        )
    }

    func delayBeforeRetrySeconds(forAttempt attempt: Int) -> Double {
        guard attempt > 1 else { return 0 }
        let exponent = Double(max(0, attempt - 2))
        let baseDelay = min(maxDelaySeconds, initialDelaySeconds * pow(2.0, exponent))
        let jitterMagnitude = baseDelay * jitterFraction
        let lower = max(0, baseDelay - jitterMagnitude)
        let upper = baseDelay + jitterMagnitude
        return Double.random(in: lower...upper)
    }

    func retryDelaySeconds(forAttempt attempt: Int, error: Error) -> Double {
        let localDelay = delayBeforeRetrySeconds(forAttempt: attempt)
        let serverDelay = serverSuggestedRetryDelaySeconds(from: error)
            .map { min($0, maxServerRetryAfterSeconds) }
        return max(localDelay, serverDelay ?? 0)
    }
}

func serverSuggestedRetryDelaySeconds(from error: Error) -> Double? {
    guard let httpError = error as? URLResourceDownloadHTTPError,
          httpError.statusCode == 429 || httpError.statusCode == 503 else {
        return nil
    }
    guard let retryAfterSeconds = httpError.retryAfterSeconds, retryAfterSeconds > 0 else {
        return nil
    }
    return retryAfterSeconds
}

func isRetryableDownloadError(_ error: Error) -> Bool {
    if let urlError = error as? URLError {
        switch urlError.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .resourceUnavailable,
             .notConnectedToInternet,
             .dataNotAllowed,
             .internationalRoamingOff,
             .callIsActive:
            return true
        default:
            return false
        }
    }

    if let posixError = error as? POSIXError {
        switch posixError.code {
        case .ENETDOWN,
             .ENETUNREACH,
             .ENETRESET,
             .ECONNABORTED,
             .ECONNRESET,
             .ECONNREFUSED,
             .ETIMEDOUT,
             .EHOSTUNREACH:
            return true
        default:
            return false
        }
    }

    if let httpError = error as? URLResourceDownloadHTTPError {
        return httpError.statusCode == 429 || (500...599).contains(httpError.statusCode)
    }

    return false
}

private extension FileManager {
    func removeItemIfPresent(at url: URL) throws {
        do {
            try removeItem(at: url)
        } catch let error as NSError {
            let isMissingFile = error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError
            let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
            let isMissingUnderlyingPOSIX = underlying?.domain == NSPOSIXErrorDomain
                && underlying?.code == Int(ENOENT)
            if isMissingFile || isMissingUnderlyingPOSIX {
                return
            }
            throw error
        }
    }
}

public extension DownloadController {
    @MainActor
    var failureMessages: [String]? {
        return failedDownloads.isEmpty ? nil : Array(failedDownloads).sorted(using: [KeyPathComparator(\.url.absoluteString)]).compactMap { $0.failureMessage }.removingDuplicates()
    }
    
    @DownloadActor
    func ensureDownloaded(_ downloads: Set<Downloadable>, deletingOrphansIn: [DownloadDirectory] = []) async {
        for download in downloads {
            await ensureDownloaded(download: download, deletingOrphansIn: deletingOrphansIn, excludingFromDeletion: downloads)
        }
    }

    @DownloadActor
    func ensureDownloaded(
        _ downloads: [Downloadable],
        deletingOrphansIn: [DownloadDirectory] = []
    ) async {
        let downloadSet = Set(downloads)
        for download in downloads {
            await ensureDownloaded(
                download: download,
                deletingOrphansIn: deletingOrphansIn,
                excludingFromDeletion: downloadSet
            )
            if download is ImportableDownloadable {
                _ = try? await download.awaitCompletionOrFailure()
            }
        }
    }
    
    @DownloadActor
    func deleteOrphanFiles(in locations: [DownloadDirectory], excluding: Set<Downloadable> = Set()) async throws {
        guard !locations.isEmpty else { return }
        
        let retainedDownloads = await assuredDownloads.union(excluding)
        var saveFiles = Set(retainedDownloads.map(\.localDestination))
            .union(Set(retainedDownloads.map(\.compressedFileURL)))
            .union(Set(retainedDownloads.map(\.checksumVerificationMarkerURL)))
            .union(activeTransferStagingURLs)
        for download in retainedDownloads {
            if let processingTaskID = processingTasks[download.id]?.id {
                saveFiles.insert(
                    download.localDestination.appendingPathExtension(
                        "decompressing.\(processingTaskID.uuidString)"
                    )
                )
            }
        }
        
        var potentialOrphanDirs = Set<URL>()
        var seenSavedFiles = Set<URL>()
        
        for location in locations {
            let dir = location.directoryURL
            let preservedDirectories = preservedArtifactDirectories(
                from: retainedDownloads,
                containedBy: dir
            )
            let path = dir.path
            let enumerator = FileManager.default.enumerator(atPath: path)
            
            while let filename = enumerator?.nextObject() as? String {
                let fileURL = URL(fileURLWithPath: filename, relativeTo: dir).absoluteURL

                if preservedDirectories.contains(fileURL.standardizedFileURL) {
                    seenSavedFiles.insert(fileURL)
                    enumerator?.skipDescendants()
                    continue
                }
                
                var shouldSkip = false
                var currentPath = fileURL
                while currentPath.path != dir.path {
                    if currentPath.lastPathComponent.hasSuffix(".realm.management") {
                        shouldSkip = true
                        break
                    }
                    currentPath.deleteLastPathComponent()
                }
                if shouldSkip { continue }
                
                if saveFiles.contains(fileURL) || fileURL.lastPathComponent.hasSuffix(".realm.lock") || fileURL.lastPathComponent.hasSuffix(".realm.management") || fileURL.lastPathComponent.hasSuffix(".realm.note") {
                    seenSavedFiles.insert(fileURL)
                    continue
                }
                
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    potentialOrphanDirs.insert(fileURL)
                } else {
                    try FileManager.default.removeItemIfPresent(at: fileURL)
                }
            }
        }
        
        for orphanDir in potentialOrphanDirs {
            if !seenSavedFiles.contains(where: { $0.path.hasPrefix(orphanDir.path) }) {
                try FileManager.default.removeItemIfPresent(at: orphanDir)
            }
        }

        for download in retainedDownloads
            where download.localDestinationChecksum == nil
                && !FileManager.default.fileExists(
                    atPath: download.localDestination.path
                ) {
            try? download.removeInstalledArtifactReceipt()
        }
    }

    private func preservedArtifactDirectories(
        from downloads: Set<Downloadable>,
        containedBy cleanupRoot: URL
    ) -> Set<URL> {
        let resolvedRoot = cleanupRoot.resolvingSymlinksInPath().standardizedFileURL
        return Set(downloads.flatMap(\.preservedLocalArtifactDirectories).compactMap {
            let declaredDirectory = $0.standardizedFileURL
            let resolvedDirectory = declaredDirectory.resolvingSymlinksInPath().standardizedFileURL
            guard resolvedDirectory != resolvedRoot,
                  resolvedDirectory.path.hasPrefix(resolvedRoot.path + "/")
            else {
                return nil
            }
            return declaredDirectory
        })
    }
    
    @DownloadActor
    func delete(download: Downloadable) async throws -> Downloadable {
        // Fence any delegate/retry completion that arrives after deletion.
        downloadAttemptIDs[download.id] = nil
        completionMetadataRetryDownloadIDs.remove(download.id)
        pendingInstalledArtifactReceipts[
            download.installedArtifactReceiptStorageKey
        ] = nil
        download.invalidateDownloadObservation()
        let downloadRecord = downloadTasks[download.id]
        let processingRecord = processingTasks[download.id]
        let recoveryRecord = checksumRecoveryTasks[download.id]
        processingRecord?.task.cancel()
        recoveryRecord?.task.cancel()
        await cancelInProgressDownloads(matchingDownloadURL: download.url)
        await downloadRecord?.task.value
        await processingRecord?.task.value
        await recoveryRecord?.task.value

        // Do not let cleanup from this deletion race a newer processor that
        // has taken ownership of the same logical download.
        let hasNewerDownloadTask = downloadTasks[download.id].map {
            $0.id != downloadRecord?.id
        } ?? false
        let hasNewerProcessingTask = processingTasks[download.id].map {
            $0.id != processingRecord?.id
        } ?? false
        let hasNewerRecoveryTask = checksumRecoveryTasks[download.id].map {
            $0.id != recoveryRecord?.id
        } ?? false
        if hasNewerDownloadTask || hasNewerProcessingTask || hasNewerRecoveryTask {
            return try await delete(download: download)
        }

        completionMetadataRetryDownloadIDs.remove(download.id)
        clearDownloadStatusObservers(forDownloadID: download.id)
        try removeAllLocalArtifacts(
            for: download,
            includingDestination: true,
            preservingActiveTransfers: false
        )
        await MainActor.run {
            assuredDownloads = assuredDownloads.filter { $0.url != download.url }
            finishedDownloads = finishedDownloads.filter { $0.url != download.url }
            failedDownloads = failedDownloads.filter { $0.url != download.url }
            activeDownloads = activeDownloads.filter { $0.url != download.url }
            download.isActive = false
            download.isFinishedProcessing = false
            download.isFinishedDownloading = false
            download.isFailed = false
            download.downloadProgress = .uninitiated
        }
        return download
    }

    /// Invalidates every local artifact and lifecycle flag for a download so
    /// a caller that rejected the installed bytes can request one clean,
    /// independently transferred replacement.
    @DownloadActor
    func invalidateLocalArtifacts(
        for download: Downloadable
    ) async throws {
        _ = try await delete(download: download)
    }
    
    @MainActor
    func isDownloaded(url: URL) -> Bool {
        return finishedDownloads.map { $0.url }.contains(url)
    }
    
    @MainActor
    func isDownloading(url: URL) -> Bool {
        return activeDownloads.map { $0.url }.contains(url)
    }
    
    @MainActor
    func isFailed(url: URL) -> Bool {
        return failedDownloads.map { $0.url }.contains(url)
    }
    
    @MainActor
    func downloadable(forURL url: URL) -> Downloadable? {
        return finishedDownloads.first(where: { $0.url == url }) ?? activeDownloads.first(where: { $0.url == url }) ?? failedDownloads.first(where: { $0.url == url }) ?? assuredDownloads.first(where: { $0.url == url })
    }
}

extension DownloadController {
    @DownloadActor
    private func hasProcessableArtifactOrPendingReceipt(
        for download: Downloadable
    ) -> Bool {
        if download.hasProcessableLocalArtifact() {
            return true
        }
        guard let pendingReceipt = pendingInstalledArtifactReceipts[
            download.installedArtifactReceiptStorageKey
        ] else {
            return false
        }
        return download.installedArtifactMatches(pendingReceipt.receipt)
    }

    @DownloadActor
    private func clearDownloadStatusObservers(forDownloadID downloadID: String) {
        guard let cancellables = downloadStatusCancellables.removeValue(forKey: downloadID) else {
            return
        }
        cancellables.forEach { $0.cancel() }
    }

    @DownloadActor
    private func resetDownloadStatusObservers(for download: Downloadable) {
        clearDownloadStatusObservers(forDownloadID: download.id)

        var perDownloadCancellables = Set<AnyCancellable>()
        download.$isActive.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                if download.isActive
                    && !download.isFailed
                    && !download.isFinishedDownloading
                    && !download.isFinishedProcessing {
                    self?.activeDownloads.insert(download)
                } else {
                    self?.activeDownloads.remove(download)
                }
            }
        }.store(in: &perDownloadCancellables)
        download.$isFailed.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                if download.isFailed {
                    self?.finishedDownloads.remove(download)
                    self?.failedDownloads.insert(download)
                    self?.activeDownloads.remove(download)
                } else {
                    self?.failedDownloads.remove(download)
                }
            }
        }.store(in: &perDownloadCancellables)
        download.$isFinishedDownloading.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self, weak download] _ in
            Task { @MainActor [weak self, weak download] in
                guard let download else { return }

                if download.isFinishedDownloading && !download.isFailed {                    self?.failedDownloads.remove(download)
                    self?.finishedDownloads.insert(download)
                    self?.activeDownloads.remove(download)
                    if !(download.isFromBackgroundAssetsDownloader ?? true) {
                        try? await self?.cancelInProgressDownloads(
                            inDownloadExtension: true
                        )
                    }
                } else {
                    self?.finishedDownloads.remove(download)
                }
            }
        }.store(in: &perDownloadCancellables)
        download.$isFinishedProcessing.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPublishedDownloadState()
            }
        }.store(in: &perDownloadCancellables)

        downloadStatusCancellables[download.id] = perDownloadCancellables
    }

    @DownloadActor
    private func runSingleDownloadAttempt(
        _ download: Downloadable
    ) async throws -> DownloadTransferResult {
        if let attemptExecutor {
            return try await attemptExecutor(download, session)
        }


        // Keep transferred bytes out of the installed location until the        // processing owner has checked size/checksum and completed import.
        let transferDestination = download.url.pathExtension == "br"
            ? download.compressedTransferStagingURL(operationID: UUID())
            : download.uncompressedTransferStagingURL(operationID: UUID())
        activeTransferStagingURLs.insert(transferDestination)
        try? FileManager.default.removeItemIfPresent(at: transferDestination)
        let task = await download.download(
            session: session,
            destination: transferDestination
        )
        do {
            return try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    let waiter = DownloadAttemptTerminalWaiter(
                        url: download.url,
                        lastModified: { task.responseLastModified },
                        finalResponseURL: { task.finalResponseURL },
                        continuation: continuation
                    )
                    waiter.subscribe(to: task.publisher)
                    task.resume()
                    if Task.isCancelled {
                        task.cancel()
                    }
                }
            }, onCancel: {
                task.cancel()
            })
        } catch {
            activeTransferStagingURLs.remove(transferDestination)
            try? FileManager.default.removeItemIfPresent(at: transferDestination)
            throw error
        }
    }

    @MainActor
    public func ensureDownloaded(download: Downloadable, deletingOrphansIn: [DownloadDirectory] = [], excludingFromDeletion: Set<Downloadable> = Set()) async {
        await download.waitForDownloadMetadata()
        if assuredDownloads.contains(where: { $0.url == download.url }) && !failedDownloads.contains(where: { $0.url == download.url }) {
            let isImported = await (download as? ImportableDownloadable)?.isImported() ?? false
            let importedWithoutRetainedSource = isImported
                && (download as? ImportableDownloadable)?.deleteAfterImport == true
            if download.hasAdmissibleInstalledArtifact()
                || importedWithoutRetainedSource {
                return
            }
        }
        assuredDownloads.insert(download)
        do {
            try await deleteOrphanFiles(in: deletingOrphansIn, excluding: excludingFromDeletion)
        } catch { }
        
        let isImported = await (download as? ImportableDownloadable)?.isImported() ?? false
        let importedWithoutRetainedSource = isImported
            && (download as? ImportableDownloadable)?.deleteAfterImport == true
        let hasProcessableLocalArtifact = await hasProcessableArtifactOrPendingReceipt(
            for: download
        )
            if hasProcessableLocalArtifact || importedWithoutRetainedSource {
                if importedWithoutRetainedSource {
                    await markDownloadAsProcessed(download)
                } else {
                    // Validate/process an already-installed artifact before
                    // checking the remote version, but keep its validators
                    // anchored to the version that is actually installed.
                    await finishDownload(
                        download,
                        recordSuccessfulDownload: false
                    )
                }
            let updateCheckInterval = TimeInterval(60 * 60 * 2)
            if download.shouldCheckForUpdates,
               download.lastCheckedETagAt == nil
                || (download.lastCheckedETagAt ?? Date()).distance(to: Date()) > updateCheckInterval {
                switch await checkRemoteModification(for: download) {
                case let .available(modified, modifiedAt, etag):
                    if !modified {
                        download.lastCheckedETagAt = Date()
                        // These values describe the installed artifact only
                        // when the server says that artifact is still current.
                        // For an update, finishDownloadBody records success;
                        // persisting the remote validators before replacement
                        // succeeds would suppress retry after a failed update.
                        if let modifiedAt {
                            download.lastModifiedAt = modifiedAt
                        }
                        if let etag {
                            download.lastDownloadedETag = etag
                        }
                    }
                    if modified {
                    await self.download(
                        download,
                        updatesRemoteModifiedAt: true
                    )
                    }
                case .unavailable:
                    break
                }
            }
        } else {
            await self.download(download)
        }
        //        }
    }
    
    @DownloadActor
    public func download(
        _ download: Downloadable,
        etag: String? = nil,
        remoteModifiedAt: Date? = nil,
        updatesRemoteModifiedAt: Bool = false
    ) async {
        guard !Task.isCancelled,
              downloadAttemptIDs[download.id] == nil,
              downloadTasks[download.id] == nil else { return }
        let previousProcessingTask = processingTasks[download.id]?.task
        let previousRecoveryTask = checksumRecoveryTasks[download.id]?.task
        let downloadAttemptID = UUID()
        downloadAttemptIDs[download.id] = downloadAttemptID
        // URLSession has no task during retry backoff. Retain the logical
        // operation so scoped cancellation owns transfer, backoff and import.
        let task = Task { @DownloadActor [self] in
            // Reserve this operation before waiting so standalone finish cannot
            // start processing the old destination during the replacement GET.
            await previousRecoveryTask?.value
            await previousProcessingTask?.value
            guard !Task.isCancelled,
                  downloadAttemptIDs[download.id] == downloadAttemptID else { return }
            if let transferResult = await performDownload(
                download,
                etag: etag,
                remoteModifiedAt: remoteModifiedAt,
                downloadAttemptID: downloadAttemptID
            ) {
                await finishDownloadedFile(
                    download,
                    etag: transferResult.etag,
                    remoteModifiedAt: transferResult.lastModified,
                    finalResponseURL: transferResult.finalResponseURL,
                    updatesRemoteModifiedAt: updatesRemoteModifiedAt,
                    transferredFileURL: transferResult.destinationLocation,
                    expectedDownloadAttemptID: downloadAttemptID
                )
            }
        }
        downloadTasks[download.id] = ProcessingTaskRecord(id: downloadAttemptID, task: task)
        defer {
            if downloadAttemptIDs[download.id] == downloadAttemptID {
                downloadAttemptIDs[download.id] = nil
            }
            if downloadTasks[download.id]?.id == downloadAttemptID {
                downloadTasks[download.id] = nil
            }
        }

        await withTaskCancellationHandler(operation: {
            await task.value
        }, onCancel: {
            task.cancel()
        })    }

    @DownloadActor
    private func performDownload(
        _ download: Downloadable,
        etag: String?,
        remoteModifiedAt: Date?,
        downloadAttemptID: UUID
    ) async -> DownloadTransferResult? {
        await { @MainActor in
            // Allow a fresh import attempt after a previous failure.
            download.isFinishedProcessing = false
            download.isFinishedDownloading = false
            download.isFailed = false
        }()
        if let importable = download as? ImportableDownloadable {
            await { @MainActor in
                importable.lastImportError = nil
                importable.importStatusText = nil
            }()
        }
        resetDownloadStatusObservers(for: download)
        
        if download.url.isFileURL {
            await { @MainActor in
                download.isActive = true
                download.isFailed = false
            }()
            do {
                try Task.checkCancellation()
                guard downloadAttemptIDs[download.id] == downloadAttemptID else {
                    throw CancellationError()
                }
                if download.url == download.localDestination {
                    guard FileManager.default.fileExists(atPath: download.localDestination.path) else {
                        throw NSError(domain: "DownloadController", code: 404, userInfo: [
                            NSLocalizedDescriptionKey: "Local file missing for import at \(download.localDestination.path)"
                        ])
                    }
                    return DownloadTransferResult(
                        destinationLocation: download.localDestination,
                        etag: etag,
                        lastModified: remoteModifiedAt,
                        finalResponseURL: download.url
                    )
                }
                try FileManager.default.createDirectory(
                    at: download.localDestination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let transferDestination = download.url.pathExtension == "br"
                    ? download.compressedTransferStagingURL(operationID: UUID())
                    : download.uncompressedTransferStagingURL(operationID: UUID())
                activeTransferStagingURLs.insert(transferDestination)
                try FileManager.default.removeItemIfPresent(at: transferDestination)
                do {
                    try FileManager.default.copyItem(
                        at: download.url,
                        to: transferDestination
                    )
                } catch {
                    activeTransferStagingURLs.remove(transferDestination)
                    try? FileManager.default.removeItemIfPresent(
                        at: transferDestination
                    )
                    throw error
                }
                return DownloadTransferResult(
                    destinationLocation: transferDestination,
                    etag: etag,
                    lastModified: remoteModifiedAt,
                    finalResponseURL: download.url
                )
            } catch {
                await MainActor.run { [weak self] in
                    self?.finishedDownloads.remove(download)
                    self?.failedDownloads.insert(download)
                    self?.activeDownloads.remove(download)
                    download.isFailed = true
                    download.isActive = false
                    download.isFinishedDownloading = false
                    download.isFinishedProcessing = false
                    download.downloadProgress = .completed(
                        destinationLocation: nil,
                        etag: nil,
                        error: error
                    )
                }
                clearDownloadStatusObservers(forDownloadID: download.id)
                return nil
            }
        }

        let allTasks = await session.allTasks
        if allTasks.first(where: { $0.taskDescription == download.url.absoluteString }) != nil {
            // Task exists.
            return nil
        }
            
//            if Bundle.main.object(forInfoDictionaryKey: "BAInitialDownloadRestrictions") != nil {
//                if #available(macOS 13, iOS 16.1, *) {
//                    Task.detached(priority: .utility) {
//                        do {
//                            if let baDL = download.backgroundAssetDownload(applicationGroupIdentifier: ""), try await BADownloadManager.shared.currentDownloads.contains(baDL) {
//                                if #available(iOS 16.4, macOS 13.3, *) {
//                                    if !baDL.isEssential {
//                                        try BADownloadManager.shared.startForegroundDownload(baDL)
//                                    }
//                                } else {
//                                    try BADownloadManager.shared.startForegroundDownload(baDL)
//                                }
//                                return
//                            }
//                        } catch {
//                            print("Unable to download background asset...")
//                        }
//                    }
//                } else { }
//            }
            
        download.isFromBackgroundAssetsDownloader = false
        let retryPolicy = retryPolicyProvider()
        var attempt = 1
        var terminalAttemptError: Error?
        var transferResult: DownloadTransferResult?
        while true {
            if Task.isCancelled || downloadAttemptIDs[download.id] != downloadAttemptID {
                terminalAttemptError = CancellationError()
                break
            }

            do {
                transferResult = try await runSingleDownloadAttempt(download)
                break
            } catch {
                let shouldRetry = !Task.isCancelled
                    && downloadAttemptIDs[download.id] == downloadAttemptID
                    && attempt < retryPolicy.maxAttempts
                    && isRetryableDownloadError(error)
                guard shouldRetry else {
                    terminalAttemptError = error
                    break
                }

                download.invalidateDownloadObservation()

                let delaySeconds = retryPolicy.retryDelaySeconds(
                    forAttempt: attempt + 1,
                    error: error
                )
                let nanoseconds = UInt64(delaySeconds * 1_000_000_000)
                do {
                    try await retrySleeper(nanoseconds)
                    try Task.checkCancellation()
                } catch {
                    terminalAttemptError = CancellationError()
                    break
                }
                guard downloadAttemptIDs[download.id] == downloadAttemptID else {
                    terminalAttemptError = CancellationError()
                    break
                }

                await { @MainActor in
                    download.isFailed = false
                    download.isActive = false
                    download.isFinishedDownloading = false
                    download.downloadProgress = .uninitiated
                }()
                attempt += 1
            }
        }

        guard downloadAttemptIDs[download.id] == downloadAttemptID else {
            if let transferResult,
               transferResult.destinationLocation != download.localDestination {
                activeTransferStagingURLs.remove(
                    transferResult.destinationLocation
                )
                try? FileManager.default.removeItemIfPresent(
                    at: transferResult.destinationLocation
                )
            }
            return nil
        }
        download.invalidateDownloadObservation()

        if let terminalAttemptError {
            if terminalAttemptError is CancellationError
                || (terminalAttemptError as? URLError)?.code == .cancelled {
                try? removeAllLocalArtifacts(
                    for: download,
                    includingDestination: false
                )
            }
            await MainActor.run { [weak self] in
                self?.finishedDownloads.remove(download)
                self?.failedDownloads.insert(download)
                self?.activeDownloads.remove(download)
                download.isFailed = true
                download.isActive = false
                download.isFinishedDownloading = false
                download.isFinishedProcessing = false
                download.downloadProgress = .completed(
                    destinationLocation: nil,
                    etag: nil,
                    error: terminalAttemptError
                )
            }
            clearDownloadStatusObservers(forDownloadID: download.id)
            return nil
        } else {
            // Keep transfer completion internal until validation/import and
            // installation finish. Publishing an intermediate success would
            // require an actor hop after the ownership check, allowing delete
            // to invalidate the attempt before stale UI state is written.
            return transferResult
        }
    }
    
    @MainActor
    public func cancelInProgressDownloads(matchingDownloadURL downloadURL: URL? = nil) async {
        let allTasks = await session.allTasks
        let matchingTasks = allTasks.filter { task in
            guard let downloadURL else { return true }
            return task.taskDescription == downloadURL.absoluteString
        }
        for task in matchingTasks {
            task.cancel()
        }
        await cancelOwnedDownloadWork(matchingDownloadURL: downloadURL)
    }

    @DownloadActor
    private func cancelOwnedDownloadWork(matchingDownloadURL downloadURL: URL?) {
        let matchingID = downloadURL?.absoluteString
        let records = downloadTasks.filter { matchingID == nil || $0.key == matchingID }
            .map(\.value)
            + processingTasks.filter { matchingID == nil || $0.key == matchingID }.map(\.value)
            + checksumRecoveryTasks.filter { matchingID == nil || $0.key == matchingID }.map(\.value)
        records.forEach { $0.task.cancel() }
        // Each owner removes only its candidates and publishes its terminal
        // cancellation. Ownership remains until it drains. Cancellation itself
        // must not await an importer that may have requested this cancellation.
        // Deletion separately awaits the owners before removing artifacts.
    }
    
    @MainActor
    func cancelInProgressDownloads(inApp: Bool = false, inDownloadExtension: Bool = false) async throws {
        if inApp {
            let allTasks = await session.allTasks
            for task in allTasks.filter({ task in assuredDownloads.contains(where: { $0.url.absoluteString == (task.taskDescription ?? "") }) }) {
                task.cancel()
            }
            await cancelOwnedDownloadWork(matchingDownloadURL: nil)
        }
        if inDownloadExtension {
            if Bundle.main.object(forInfoDictionaryKey: "BAInitialDownloadRestrictions") != nil {
                if #available(iOS 16.1, macOS 13, *) {
                    for download in try await BADownloadManager.shared.currentDownloads {
                        try BADownloadManager.shared.cancel(download)
                    }
                }
            }
        }
    }

    @DownloadActor
    func cancelLongRunningWorkForBackgrounding() async {
        try? await cancelInProgressDownloads(inApp: true)
    }

    @DownloadActor
    func resumeRecoverableDownloadsAfterForegrounding() async {
        let downloads = await MainActor.run { Array(assuredDownloads) }
        for download in downloads {
            let state = await MainActor.run {
                (
                    isFailed: download.isFailed,
                    isActive: download.isActive,
                    isFinishedDownloading: download.isFinishedDownloading,
                    isFinishedProcessing: download.isFinishedProcessing
                )
            }
            let hasRecoverableFile = await download.existsLocally()
            let hasProcessableLocalArtifact = await hasProcessableArtifactOrPendingReceipt(
                for: download
            )
            let isImported = await (download as? ImportableDownloadable)?.isImported() ?? false
            let importedWithoutRetainedSource = isImported
                && (download as? ImportableDownloadable)?.deleteAfterImport == true

            if state.isFinishedProcessing {
                if completionMetadataRetryDownloadIDs.contains(download.id),
                   hasProcessableLocalArtifact || importedWithoutRetainedSource {
                    await finishDownload(
                        download,
                        recordSuccessfulDownload: false
                    )
                    continue
                }
                if hasProcessableLocalArtifact || importedWithoutRetainedSource {
                    continue
                }
                await self.download(download)
                continue
            }

            guard hasRecoverableFile || state.isFailed || state.isActive || state.isFinishedDownloading else {
                continue
            }

            if hasProcessableLocalArtifact {
                await finishDownload(
                    download,
                    recordSuccessfulDownload: false
                )
            } else {
                await self.download(download)
            }
        }
    }

    @DownloadActor
    private func clearProcessingTask(forDownloadID downloadID: String, processingTaskID: UUID) {
        guard processingTasks[downloadID]?.id == processingTaskID else { return }
        processingTasks[downloadID] = nil
    }

    @DownloadActor
    private func clearChecksumRecoveryTask(
        forDownloadID downloadID: String,
        taskID: UUID
    ) {
        guard checksumRecoveryTasks[downloadID]?.id == taskID else { return }
        checksumRecoveryTasks[downloadID] = nil
        checksumRecoveriesReadyForProcessing.remove(downloadID)
        checksumRedownloadAttempted.remove(downloadID)
    }

    @DownloadActor
    private func markDownloadCancelled(_ download: Downloadable, error: Error = CancellationError()) async {
        await MainActor.run { [weak self] in
            if let importable = download as? ImportableDownloadable {
                importable.lastImportError = nil
                importable.importProgress = nil
                importable.importStatusText = nil
            }
            self?.failedDownloads.insert(download)
            self?.activeDownloads.remove(download)
            self?.finishedDownloads.remove(download)
            download.isFailed = true
            download.isActive = false
            download.isFinishedDownloading = false
            download.isFinishedProcessing = false
            download.downloadProgress = .completed(destinationLocation: nil, etag: nil, error: error)
        }
        clearDownloadStatusObservers(forDownloadID: download.id)
    }

    @DownloadActor
    private func discardTransferredCandidate(_ transferResult: DownloadTransferResult?, for download: Downloadable) {
        guard let candidateURL = transferResult?.destinationLocation,
              candidateURL != download.localDestination else { return }
        activeTransferStagingURLs.remove(candidateURL)
        try? FileManager.default.removeItemIfPresent(at: candidateURL)
    }

    @DownloadActor
    private func removeAllLocalArtifacts(
        for download: Downloadable,
        includingDestination: Bool,
        preservingActiveTransfers: Bool = true
    ) throws {
        if includingDestination {
            try FileManager.default.removeItemIfPresent(
                at: download.localDestination
            )
            try FileManager.default.removeItemIfPresent(
                at: download.checksumVerificationMarkerURL
            )
            pendingInstalledArtifactReceipts[
                download.installedArtifactReceiptStorageKey
            ] = nil
            try download.removeInstalledArtifactReceipt()
        }
        try FileManager.default.removeItemIfPresent(
            at: download.compressedFileURL
        )

        let directory = download.localDestination.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        let stagingPrefix = download.localDestination.lastPathComponent
            + ".decompressing."
        let transferStagingPrefix = download.localDestination
            .lastPathComponent + ".downloading."
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for child in children
            where child.lastPathComponent.hasPrefix(stagingPrefix)
                || child.lastPathComponent.hasPrefix(transferStagingPrefix) {
            // A cancelled older processor must not remove a candidate owned
            // by a newer transfer admitted while cancellation was unwinding.
            guard !preservingActiveTransfers
                    || !activeTransferStagingURLs.contains(child) else {
                continue
            }
            if !preservingActiveTransfers {
                activeTransferStagingURLs.remove(child)
            }
            try FileManager.default.removeItemIfPresent(at: child)
        }
    }
    
    @DownloadActor
    public func finishDownload(
        _ download: Downloadable,
        etag: String? = nil,
        remoteModifiedAt: Date? = nil,
        finalResponseURL: URL? = nil,
        updatesRemoteModifiedAt: Bool = false,
        recordSuccessfulDownload: Bool = true
    ) async {

        if let currentDownload = downloadTasks[download.id]?.task {
            await currentDownload.value
            return
        }
        await finishDownloadedFile(
            download,
            etag: etag,
            remoteModifiedAt: remoteModifiedAt,
            finalResponseURL: finalResponseURL,
            updatesRemoteModifiedAt: updatesRemoteModifiedAt,
            recordSuccessfulDownload: recordSuccessfulDownload,
            transferredFileURL: nil
        )
    }

    @DownloadActor
    private func finishDownloadedFile(
        _ download: Downloadable,
        etag: String? = nil,
        remoteModifiedAt: Date? = nil,
        finalResponseURL: URL? = nil,
        updatesRemoteModifiedAt: Bool = false,
        recordSuccessfulDownload: Bool = true,
        transferredFileURL: URL?,
        expectedDownloadAttemptID: UUID? = nil
    ) async {
        if let expectedDownloadAttemptID,
           downloadAttemptIDs[download.id] != expectedDownloadAttemptID {
            if let transferredFileURL,
               transferredFileURL != download.localDestination {
                activeTransferStagingURLs.remove(transferredFileURL)
                try? FileManager.default.removeItemIfPresent(
                    at: transferredFileURL
                )
            }
            return
        }
        if checksumRecoveryTasks[download.id] != nil,
           !checksumRecoveriesReadyForProcessing.contains(download.id) {
            if let transferredFileURL,
               transferredFileURL != download.localDestination {
                activeTransferStagingURLs.remove(transferredFileURL)
                try? FileManager.default.removeItemIfPresent(
                    at: transferredFileURL
                )
            }
            return
        }
        if let existingTask = processingTasks[download.id]?.task {
            await existingTask.value
            if let transferredFileURL,
               transferredFileURL != download.localDestination {
                activeTransferStagingURLs.remove(transferredFileURL)
                try? FileManager.default.removeItemIfPresent(
                    at: transferredFileURL
                )
            }
            return
        }

        let processingTaskID = UUID()
        let task = Task { @DownloadActor [weak self] in
            guard let self else { return }
            await self.finishDownloadBody(
                download,
                etag: etag,
                remoteModifiedAt: remoteModifiedAt,
                finalResponseURL: finalResponseURL,
                updatesRemoteModifiedAt: updatesRemoteModifiedAt,
                recordSuccessfulDownload: recordSuccessfulDownload,
                transferredFileURL: transferredFileURL,
                processingTaskID: processingTaskID
            )
        }
        processingTasks[download.id] = ProcessingTaskRecord(id: processingTaskID, task: task)
        await withTaskCancellationHandler(operation: {
            await task.value
        }, onCancel: {
            task.cancel()
        })
    }

    /// Discards a locally corrupt uncompressed payload and enters the normal
    /// download/retry pipeline. If normal finish processing is already active,
    /// that task owns the same recovery transition.
    @DownloadActor
    public func recoverLocalChecksumFailure(
        for download: Downloadable,
        etag: String? = nil,
        remoteModifiedAt: Date? = nil,
        updatesRemoteModifiedAt: Bool = false
    ) async {
        if let currentDownload = downloadTasks[download.id]?.task {
            // The in-flight replacement owns checksum validation and recovery.
            await currentDownload.value
            return
        }
        if let existingRecovery = checksumRecoveryTasks[download.id]?.task {
            await existingRecovery.value
            return
        }
        if let existingTask = processingTasks[download.id]?.task {
            await existingTask.value
            if download.hasVerifiedLocalDestinationChecksumMarker() {
                return
            }
            let replacementState = await MainActor.run {
                (
                    isActive: download.isActive,
                    isFinishedDownloading: download.isFinishedDownloading
                )
            }
            if replacementState.isActive {
                return
            }
            if replacementState.isFinishedDownloading {
                await finishDownload(
                    download,
                    etag: etag,
                    remoteModifiedAt: remoteModifiedAt,
                    updatesRemoteModifiedAt: updatesRemoteModifiedAt
                )
                if download.hasVerifiedLocalDestinationChecksumMarker() {
                    return
                }
            }
        }
        if let currentDownload = downloadTasks[download.id]?.task {
            await currentDownload.value
            return
        }
        if let existingRecovery = checksumRecoveryTasks[download.id]?.task {
            await existingRecovery.value
            return
        }

        let taskID = UUID()
        let task = Task { @DownloadActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else {
                await markDownloadCancelled(download)
                clearChecksumRecoveryTask(
                    forDownloadID: download.id,
                    taskID: taskID
                )
                return
            }
            let transferResult = await retryDownloadAfterChecksumFailure(
                download,
                etag: etag,
                remoteModifiedAt: remoteModifiedAt,
                updatesRemoteModifiedAt: updatesRemoteModifiedAt
            )
            guard !Task.isCancelled else {
                discardTransferredCandidate(transferResult, for: download)
                await markDownloadCancelled(download)
                clearChecksumRecoveryTask(
                    forDownloadID: download.id,
                    taskID: taskID
                )
                return
            }
            if let transferResult {
                checksumRecoveriesReadyForProcessing.insert(download.id)
                await finishDownloadedFile(
                    download,
                    etag: transferResult.etag,
                    remoteModifiedAt: transferResult.lastModified,
                    finalResponseURL: transferResult.finalResponseURL,
                    updatesRemoteModifiedAt: updatesRemoteModifiedAt,
                    transferredFileURL: transferResult.destinationLocation
                )
            }
            _ = try? await download.awaitCompletionOrFailure()
            clearChecksumRecoveryTask(
                forDownloadID: download.id,
                taskID: taskID
            )
        }
        checksumRecoveryTasks[download.id] = ProcessingTaskRecord(
            id: taskID,
            task: task
        )
        await task.value
    }

    @DownloadActor
    private func retryDownloadAfterChecksumFailure(
        _ download: Downloadable,
        etag: String?,
        remoteModifiedAt: Date? = nil,
        updatesRemoteModifiedAt: Bool = false,
        preserveInstalledDestination: Bool = false
    ) async -> DownloadTransferResult? {
        checksumRedownloadAttempted.insert(download.id)
        await MainActor.run { [weak self] in
            if let importable = download as? ImportableDownloadable {
                importable.lastImportError = nil
                importable.importStatusText = "Retrying download…"
            }
            self?.failedDownloads.remove(download)
            self?.activeDownloads.remove(download)
            self?.finishedDownloads.remove(download)
            download.isFailed = false
            download.isActive = false
            download.isFinishedDownloading = false
            download.isFinishedProcessing = false
        }
        guard !Task.isCancelled else { return nil }
        if !preserveInstalledDestination {
            try? FileManager.default.removeItemIfPresent(
                at: download.localDestination
            )
            pendingInstalledArtifactReceipts[
                download.installedArtifactReceiptStorageKey
            ] = nil
            try? download.removeInstalledArtifactReceipt()
        }
        try? FileManager.default.removeItemIfPresent(
            at: download.compressedFileURL
        )
        if !preserveInstalledDestination {
            try? FileManager.default.removeItemIfPresent(
                at: download.checksumVerificationMarkerURL
            )
        }
        clearDownloadStatusObservers(forDownloadID: download.id)
        guard !Task.isCancelled else { return nil }
        if let owningAttemptID = downloadAttemptIDs[download.id] {
            return await performDownload(
                download,
                etag: etag,
                remoteModifiedAt: remoteModifiedAt,
                downloadAttemptID: owningAttemptID
            )
        }

        let recoveryAttemptID = UUID()
        downloadAttemptIDs[download.id] = recoveryAttemptID
        defer {
            if downloadAttemptIDs[download.id] == recoveryAttemptID {
                downloadAttemptIDs[download.id] = nil
            }
        }
        return await performDownload(
            download,
            etag: etag,
            remoteModifiedAt: remoteModifiedAt,
            downloadAttemptID: recoveryAttemptID
        )
    }

    @DownloadActor
    private func finishDownloadBody(
        _ download: Downloadable,
        etag: String? = nil,
        remoteModifiedAt: Date? = nil,
        finalResponseURL: URL? = nil,
        updatesRemoteModifiedAt: Bool = false,
        recordSuccessfulDownload: Bool,
        transferredFileURL: URL? = nil,
        processingTaskID: UUID
    ) async {
        await download.waitForDownloadMetadata()
        if transferredFileURL != nil {
            // A transferred replacement owns a new completion result. Its
            // metadata supersedes any dirty completion values retained from
            // processing the previously installed artifact.
            completionMetadataRetryDownloadIDs.remove(download.id)
        } else if completionMetadataRetryDownloadIDs.contains(download.id) {
            do {
                try Task.checkCancellation()
                let receiptKey = download.installedArtifactReceiptStorageKey
                let importDeletedSource = if let importable = download as? ImportableDownloadable,
                                             importable.deleteAfterImport {
                    await importable.isImported()
                } else {
                    false
                }
                if !importDeletedSource {
                    if let pendingReceipt = pendingInstalledArtifactReceipts[receiptKey] {
                        guard download.installedArtifactMatches(pendingReceipt.receipt) else {
                            throw InstalledArtifactReceiptValidationError
                                .missingOrInvalid(download.localDestination)
                        }
                        try download.persistInstalledArtifactReceipt(
                            pendingReceipt.receipt
                        )
                    } else if download.validInstalledArtifactReceipt() == nil {
                        throw InstalledArtifactReceiptValidationError
                            .missingOrInvalid(download.localDestination)
                    }
                }
                let metadata = download.cachedDownloadMetadata
                let successfulMetadata = pendingInstalledArtifactReceipts[
                    receiptKey
                ]?.successfulDownloadMetadata
                await MainActor.run {
                    if let successfulMetadata {
                        download.lastDownloadedETag = successfulMetadata.etag
                        download.lastDownloaded = successfulMetadata.downloadedAt
                        download.lastModifiedAt = successfulMetadata.remoteModifiedAt
                        if let checkedAt = successfulMetadata.checkedAt {
                            download.lastCheckedETagAt = checkedAt
                        }
                    } else {
                        // Identical assignments deliberately ask the cache to
                        // retry all dirty fields after its prior save failure.
                        download.lastDownloadedETag = metadata.lastDownloadedETag
                        download.lastCheckedETagAt = metadata.lastCheckedETagAt
                        download.lastDownloaded = metadata.lastDownloadedAt
                        download.lastModifiedAt = metadata.lastModifiedAt
                    }
                }
                try await download.waitForDownloadMetadataPersistence()
                try Task.checkCancellation()
                guard processingTasks[download.id]?.id == processingTaskID else {
                    throw CancellationError()
                }
                completionMetadataRetryDownloadIDs.remove(download.id)
                pendingInstalledArtifactReceipts[receiptKey] = nil
                await publishSuccessfulCompletion(download)
                checksumRedownloadAttempted.remove(download.id)
                clearDownloadStatusObservers(forDownloadID: download.id)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    await markDownloadCancelled(download, error: error)
                } else {
                    if !(error is DownloadMetadataPersistenceError) {
                        completionMetadataRetryDownloadIDs.remove(download.id)
                        pendingInstalledArtifactReceipts[
                            download.installedArtifactReceiptStorageKey
                        ] = nil
                    }
                    await publishCompletionMetadataFailure(error, for: download)
                }
            }
            clearProcessingTask(forDownloadID: download.id, processingTaskID: processingTaskID)
            return
        }
        let existingInstalledArtifactReceipt = transferredFileURL == nil
            ? download.validInstalledArtifactReceipt()
            : nil
        if !recordSuccessfulDownload,
           download.localDestinationChecksum == nil,
           let existingInstalledArtifactReceipt {
            let importIsComplete = if let importable = download as? ImportableDownloadable {
                await importable.isImported()
            } else {
                true
            }
            if importIsComplete,
               download.installedArtifactMatches(
                existingInstalledArtifactReceipt
               ),
               !Task.isCancelled,
               processingTasks[download.id]?.id == processingTaskID {
                try? FileManager.default.removeItemIfPresent(
                    at: download.compressedFileURL
                )
                await MainActor.run {
                    download.fileSize = existingInstalledArtifactReceipt.byteCount
                }
                await publishSuccessfulCompletion(download)
                checksumRedownloadAttempted.remove(download.id)
                clearDownloadStatusObservers(forDownloadID: download.id)
                clearProcessingTask(
                    forDownloadID: download.id,
                    processingTaskID: processingTaskID
                )
                return
            }
            // A completed installed receipt supersedes any leftover transfer
            // archive, but the importer must rerun if its derived state is gone.
            try? FileManager.default.removeItemIfPresent(
                at: download.compressedFileURL
            )
        }
        let transferredCompressedFileURL = transferredFileURL.flatMap { url in
            download.url.pathExtension == "br"
                && url != download.localDestination ? url : nil
        }
        let compressedCandidateURL: URL?
        if download.url.pathExtension == "br" {
            compressedCandidateURL = transferredCompressedFileURL
                ?? (FileManager.default.fileExists(
                    atPath: download.compressedFileURL.path
                ) ? download.compressedFileURL : nil)
        } else {
            // An uncompressed transfer must never be shadowed by a stale
            // compressed cache left by an earlier archive version.
            compressedCandidateURL = nil
            try? FileManager.default.removeItemIfPresent(
                at: download.compressedFileURL
            )
        }
        var stagedUncompressedFileURL = transferredFileURL.flatMap { url in
            url != download.localDestination && url != compressedCandidateURL
                ? url : nil
        }
        let attemptOwnedTransferredFileURL = transferredFileURL.flatMap { url in
            url != download.localDestination ? url : nil
        }
        if let attemptOwnedTransferredFileURL {
            activeTransferStagingURLs.insert(attemptOwnedTransferredFileURL)
        }
        defer {
            if let attemptOwnedTransferredFileURL {
                activeTransferStagingURLs.remove(attemptOwnedTransferredFileURL)
                try? FileManager.default.removeItemIfPresent(
                    at: attemptOwnedTransferredFileURL
                )
            }
            if let stagedUncompressedFileURL {
                try? FileManager.default.removeItemIfPresent(
                    at: stagedUncompressedFileURL
                )
            }
            if compressedCandidateURL == download.compressedFileURL {
                try? FileManager.default.removeItemIfPresent(
                    at: download.compressedFileURL
                )
            }
            clearProcessingTask(forDownloadID: download.id, processingTaskID: processingTaskID)
        }

        var finishStartedWithCompressedFile = false
        do {
            try Task.checkCancellation()
            let alreadyFinished = await MainActor.run { download.isFinishedProcessing }
            if alreadyFinished, transferredFileURL == nil, compressedCandidateURL == nil {
                let isImported = await (download as? ImportableDownloadable)?
                    .isImported() ?? false
                let importedWithoutRetainedSource = isImported
                    && (download as? ImportableDownloadable)?
                        .deleteAfterImport == true
                if download.hasAdmissibleInstalledArtifact()
                    || importedWithoutRetainedSource {
                    clearDownloadStatusObservers(forDownloadID: download.id)
                    return
                }
            }
            finishStartedWithCompressedFile = compressedCandidateURL != nil
            if transferredFileURL == nil,
               compressedCandidateURL == nil,
               !recordSuccessfulDownload,
               download.localDestinationChecksum == nil,
               download.validInstalledArtifactReceipt() == nil {
                throw InstalledArtifactReceiptValidationError
                    .missingOrInvalid(download.localDestination)
            }
            if let importable = download as? ImportableDownloadable,
               compressedCandidateURL != nil {
                await { @MainActor in
                    importable.importStatusText = "Expanding…"
                    if importable.importProgress == nil {
                        let downloadFraction = download.downloadProgress.fractionCompleted
                        importable.importProgress = min(downloadFraction, 0.999)
                    }
                }()
            }
            if let compressedCandidateURL {
                let decompressTask = Task.detached(priority: .utility) {

                    try download.decompressCandidate(                        at: compressedCandidateURL,
                        operationID: processingTaskID
                    )
                }
                stagedUncompressedFileURL = try await withTaskCancellationHandler(
                    operation: {
                        try await decompressTask.value
                    },
                    onCancel: {
                        decompressTask.cancel()
                    }
                )
                try Task.checkCancellation()
            }

            // Confirm non-empty. Filesystem/stat failures remain ordinary
            // processing errors; only a successfully observed zero-byte file
            // is classified as deterministic local corruption.
            let processingFileURL = stagedUncompressedFileURL
                ?? download.localDestination
            let resourceValues: URLResourceValues
            do {
                resourceValues = try processingFileURL.resourceValues(
                    forKeys: [.fileSizeKey]
                )
            } catch {
                throw DownloadLocalFileInspectionError(
                    url: processingFileURL,
                    underlyingError: error
                )
            }
            guard let fileSize = resourceValues.fileSize, fileSize > 0 else {
                if stagedUncompressedFileURL == nil,
                   compressedCandidateURL == nil,
                   let importable = download as? ImportableDownloadable,
                   await importable.isImported() {
                    await markDownloadAsProcessed(download)
                    clearDownloadStatusObservers(forDownloadID: download.id)
                    return
                }
                throw DownloadableChecksumVerificationError.emptyFile(
                    processingFileURL
                )
            }

            try Task.checkCancellation()
            let verifiesStagedCandidate = stagedUncompressedFileURL != nil
            let checksumTask = Task.detached(priority: .utility) {
                () throws -> ChecksumVerificationFileIdentity? in
                if verifiesStagedCandidate {
                    return try download.ensureVerifiedChecksum(
                        of: processingFileURL
                    )
                } else {
                    try download.ensureVerifiedLocalDestinationChecksum()
                    return nil
                }
            }
            let verifiedStagedIdentity = try await withTaskCancellationHandler(operation: {
                try await checksumTask.value
            }, onCancel: {
                checksumTask.cancel()
            })
            try Task.checkCancellation()

            if let importable = download as? ImportableDownloadable {
                try Task.checkCancellation()
                await { @MainActor in
                    importable.lastImportError = nil
                    importable.importProgress = 0
                    importable.importStatusText = "Importing…"
                }()
                let progressHandler: ImportableDownloadable.ImportProgressHandler = { [weak importable] progress, status in
                    Task { @MainActor in
                        guard let importable else { return }
                        if let progress {
                            importable.importProgress = min(max(progress, 0), 1)
                        }
                        if let status {
                            importable.importStatusText = status
                        }
                    }
                }
                try await importable.importHandler(processingFileURL, progressHandler)
                try Task.checkCancellation()
            }

            if let stagedUncompressedFileURL {
                try Task.checkCancellation()
                guard processingTasks[download.id]?.id == processingTaskID else {
                    throw CancellationError()
                }
                guard let verifiedStagedIdentity else {
                    throw DownloadableChecksumVerificationError
                        .fileChangedDuringVerification(
                            stagedUncompressedFileURL
                        )
                }
                // The importer receives the candidate URL and may suspend or
                // mutate it. Revalidate the exact file which was hashed as the
                // final synchronous step before installing it.
                try download.requireFileIdentity(
                    verifiedStagedIdentity,
                    at: stagedUncompressedFileURL
                )
                // This synchronous block is the install linearization point.
                // No suspension occurs between the last ownership check and
                // replacement of the previously usable artifact.
                if let importable = download as? ImportableDownloadable,
                   importable.deleteAfterImport {
                    try? FileManager.default.removeItemIfPresent(
                        at: download.localDestination
                    )
                    try? FileManager.default.removeItemIfPresent(
                        at: download.checksumVerificationMarkerURL
                    )
                } else {
                    do {
                        try FileManager.default.createDirectory(
                            at: download.localDestination
                                .deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        if FileManager.default.fileExists(
                            atPath: download.localDestination.path
                        ) {
                            _ = try FileManager.default.replaceItemAt(
                                download.localDestination,
                                withItemAt: stagedUncompressedFileURL,
                                backupItemName: nil,
                                options: .usingNewMetadataOnly
                            )
                        } else {
                            try FileManager.default.moveItem(
                                at: stagedUncompressedFileURL,
                                to: download.localDestination
                            )
                        }
                    } catch {
                        throw URLResourceDownloadInstallError
                            .destinationInstallFailed(
                                destination: download.localDestination,
                                underlyingError: error
                            )
                    }
                    try? FileManager.default.removeItemIfPresent(
                        at: download.checksumVerificationMarkerURL
                    )
                    // Atomic replacement must install the exact inode and
                    // metadata which passed checksum verification. Do not
                    // mint a marker for whatever happens to occupy the path.
                    try download.recordVerifiedLocalDestinationChecksum(
                        identity: verifiedStagedIdentity,
                        checkingCancellation: false
                    )
                }
            } else if let importable = download as? ImportableDownloadable,
                      importable.deleteAfterImport {
                try? FileManager.default.removeItem(at: download.localDestination)
            }

            let receiptKey = download.installedArtifactReceiptStorageKey
            if let importable = download as? ImportableDownloadable,
               importable.deleteAfterImport {
                pendingInstalledArtifactReceipts[receiptKey] = nil
                try? download.removeInstalledArtifactReceipt()
            } else {
                let receipt = try download.makeInstalledArtifactReceipt(
                    finalResponseURL: finalResponseURL
                        ?? existingInstalledArtifactReceipt?.finalResponseURL
                )
                let successfulMetadata = recordSuccessfulDownload
                    ? SuccessfulDownloadMetadata(
                        downloadedAt: Date(),
                        etag: etag,
                        remoteModifiedAt: remoteModifiedAt,
                        checkedAt: updatesRemoteModifiedAt ? Date() : nil
                    )
                    : nil
                pendingInstalledArtifactReceipts[receiptKey] =
                    PendingInstalledArtifactReceipt(
                        receipt: receipt,
                        successfulDownloadMetadata: successfulMetadata
                    )
                try download.persistInstalledArtifactReceipt(receipt)
            }
//              print("File size = " + ByteCountFormatter().string(fromByteCount: Int64(fileSize)))
            let successfulMetadata = pendingInstalledArtifactReceipts[
                receiptKey
            ]?.successfulDownloadMetadata
            await MainActor.run {
                download.fileSize = UInt64(fileSize)

                // This timestamp is queued as the baseline for Last-Modified                // comparisons, so advance it only after the downloaded bytes
                // have decompressed, verified, and imported successfully. A
                // failed replacement may deliberately preserve the prior
                // usable destination and must not make that older artifact
                // look like the just-downloaded remote version after relaunch.
                if recordSuccessfulDownload {
                    download.lastDownloaded = successfulMetadata?.downloadedAt
                        ?? Date()
                    // Validators describe the installed GET bytes. Assigning
                    // nil is intentional: a successful response that omits a
                    // validator invalidates the older artifact's value.
                    download.lastDownloadedETag = successfulMetadata?.etag
                        ?? etag
                    // This server validator describes the replacement bytes,
                    // so publish it only after expansion, verification, and
                    // import have all succeeded. Clearing a stale prior value
                    // when the successful response omitted Last-Modified makes
                    // later checks fall back to the install timestamp.
                    download.lastModifiedAt = successfulMetadata?
                        .remoteModifiedAt ?? remoteModifiedAt
                    if let checkedAt = successfulMetadata?.checkedAt {
                        download.lastCheckedETagAt = checkedAt
                    } else if updatesRemoteModifiedAt {
                        download.lastCheckedETagAt = Date()
                    }
                }
            }
            if recordSuccessfulDownload {
                try await download.waitForDownloadMetadataPersistence()
                try Task.checkCancellation()
                guard processingTasks[download.id]?.id == processingTaskID else {
                    throw CancellationError()
                }
            }
            completionMetadataRetryDownloadIDs.remove(download.id)
            pendingInstalledArtifactReceipts[
                download.installedArtifactReceiptStorageKey
            ] = nil
            await publishSuccessfulCompletion(download)
            checksumRedownloadAttempted.remove(download.id)
            clearDownloadStatusObservers(forDownloadID: download.id)
        } catch {
            if error is DownloadMetadataPersistenceError {
                completionMetadataRetryDownloadIDs.insert(download.id)
                if Task.isCancelled
                    || processingTasks[download.id]?.id != processingTaskID {
                    await markDownloadCancelled(download)
                } else {
                    await publishCompletionMetadataFailure(error, for: download)
                }
                return
            }
            if requiresCleanChecksumRedownload(error)
                && download.localDestinationChecksum != nil
                && (!finishStartedWithCompressedFile
                    || transferredCompressedFileURL != nil)
                && !checksumRedownloadAttempted.contains(download.id) {
                let transferResult = await retryDownloadAfterChecksumFailure(
                    download,
                    etag: etag,
                    remoteModifiedAt: remoteModifiedAt,
                    updatesRemoteModifiedAt: updatesRemoteModifiedAt,
                    preserveInstalledDestination: stagedUncompressedFileURL != nil
                )
                if !Task.isCancelled, let transferResult {
                    // This processor owns the checksum-recovery attempt from
                    // validation through replacement processing. Re-entering
                    // finishDownload here would await this same task.
                    await finishDownloadBody(
                        download,
                        etag: transferResult.etag,
                        remoteModifiedAt: transferResult.lastModified,
                        finalResponseURL: transferResult.finalResponseURL,
                        updatesRemoteModifiedAt: updatesRemoteModifiedAt,
                        recordSuccessfulDownload: true,
                        transferredFileURL: transferResult.destinationLocation,
                        processingTaskID: processingTaskID
                    )
                } else {
                    discardTransferredCandidate(transferResult, for: download)
                    checksumRedownloadAttempted.remove(download.id)
                    if Task.isCancelled {
                        await markDownloadCancelled(download)
                    }
                }
                return
            }
            checksumRedownloadAttempted.remove(download.id)
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                let preservesInstalledDestination =
                    stagedUncompressedFileURL != nil
                    || finishStartedWithCompressedFile
                if processingTasks[download.id]?.id == processingTaskID {
                    try? removeAllLocalArtifacts(
                        for: download,
                        includingDestination: !preservesInstalledDestination
                            && download.localDestinationChecksum != nil
                            && !download.hasVerifiedLocalDestinationChecksumMarker()
                    )
                }

                await markDownloadCancelled(download, error: error)
                return
            }
            let preservesInstalledDestination =
                stagedUncompressedFileURL != nil
                || finishStartedWithCompressedFile
            let shouldDeleteLocal = (
                error is DownloadLocalFileInspectionError
                    || error is DownloadCompressedPayloadValidationError
            )
                ? false
                : (download as? ImportableDownloadable)?.deleteAfterImport
                    ?? true
            await MainActor.run { [weak self] in
                if let importable = download as? ImportableDownloadable {
                    importable.lastImportError = error
                    importable.importStatusText = "Import failed"
                }
                self?.failedDownloads.insert(download)
                self?.activeDownloads.remove(download)
                self?.finishedDownloads.remove(download)
                download.isFailed = true
                download.isActive = false
                download.isFinishedDownloading = false
                download.isFinishedProcessing = true
                try? FileManager.default.removeItem(at: download.compressedFileURL)
                if shouldDeleteLocal && !preservesInstalledDestination {
                    try? FileManager.default.removeItem(at: download.localDestination)
                }
                if !preservesInstalledDestination {
                    try? FileManager.default.removeItem(
                        at: download.checksumVerificationMarkerURL
                    )
                }
            }
            if shouldDeleteLocal && !preservesInstalledDestination {
                pendingInstalledArtifactReceipts[
                    download.installedArtifactReceiptStorageKey
                ] = nil
                try? download.removeInstalledArtifactReceipt()
            }
            clearDownloadStatusObservers(forDownloadID: download.id)
        }
    }

    @DownloadActor
    private func markDownloadAsProcessed(_ download: Downloadable) async {
        if completionMetadataRetryDownloadIDs.contains(download.id) {
            await finishDownload(download, recordSuccessfulDownload: false)
            return
        }
        await { @MainActor [weak self] in
            download.isFailed = false
            download.isActive = false
            download.isFinishedDownloading = true
            download.isFinishedProcessing = true
            self?.failedDownloads.remove(download)
            self?.activeDownloads.remove(download)
            self?.finishedDownloads.insert(download)
            self?.refreshPublishedDownloadState()
        }()
    }

    @DownloadActor
    private func publishSuccessfulCompletion(_ download: Downloadable) async {
        await MainActor.run { [weak self] in
            self?.failedDownloads.remove(download)
            self?.activeDownloads.remove(download)
            self?.finishedDownloads.insert(download)
            download.isFailed = false
            download.isActive = false
            download.isFinishedDownloading = true
            download.isFinishedProcessing = true
            if case let .completed(destinationLocation, etag, error) = download.downloadProgress,
               error is DownloadMetadataPersistenceError {
                download.downloadProgress = .completed(
                    destinationLocation: destinationLocation,
                    etag: etag,
                    error: nil
                )
            }
            if let importable = download as? ImportableDownloadable {
                importable.lastImportError = nil
                importable.importProgress = nil
                importable.importStatusText = nil
            }
        }
    }

    @DownloadActor
    private func publishCompletionMetadataFailure(
        _ error: Error,
        for download: Downloadable
    ) async {
        await MainActor.run { [weak self] in
            if let importable = download as? ImportableDownloadable {
                importable.lastImportError = error
                importable.importProgress = nil
                importable.importStatusText = "Saving download metadata failed"
            }
            self?.failedDownloads.insert(download)
            self?.activeDownloads.remove(download)
            self?.finishedDownloads.remove(download)
            download.isFailed = true
            download.isActive = false
            download.isFinishedDownloading = false
            download.isFinishedProcessing = true
            download.downloadProgress = .completed(
                destinationLocation: download.localDestination,
                etag: download.lastDownloadedETag,
                error: error
            )
        }
        clearDownloadStatusObservers(forDownloadID: download.id)
    }
    
    enum RemoteModificationCheckResult {
        case available(modified: Bool, modifiedAt: Date?, etag: String?)
        case unavailable
    }

    /// Checks if file at given URL is modified.
    /// Using "Last-Modified" header value to compare it with given date.
    @DownloadActor
    public func checkFileModifiedAt(download: Downloadable) async -> (Bool, Date?, String?) {
        switch await checkRemoteModification(for: download) {
        case let .available(modified, modifiedAt, etag):
            return (modified, modifiedAt, etag)
        case .unavailable:
            return (false, nil, nil)
        }
    }

    @DownloadActor
    func checkRemoteModification(
        for download: Downloadable
    ) async -> RemoteModificationCheckResult {
        await download.waitForDownloadMetadata()
        var request = URLRequest(url: download.url)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await session.data(for: request)
            guard let httpURLResponse = response as? HTTPURLResponse,
                  httpURLResponse.statusCode == 200 else {
                return .unavailable
            }

            let etag = httpURLResponse.value(forHTTPHeaderField: "ETag")
            let remoteModifiedAt = httpURLResponse
                .value(forHTTPHeaderField: "Last-Modified")
                .flatMap(parseHTTPDate)
            let localModificationDate = (try? download.localDestination.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? nil
            let metadataBaseline = await MainActor.run {
                download.lastModifiedAt ?? download.lastDownloaded
            }
            let baseline = metadataBaseline ?? localModificationDate ?? Date(timeIntervalSince1970: 0)
            let lastDownloadedETag = await MainActor.run {
                download.lastDownloadedETag
            }

            if let remoteModifiedAt, remoteModifiedAt > baseline {
                return .available(
                    modified: true,
                    modifiedAt: remoteModifiedAt,
                    etag: etag
                )
            }

            if let etag {
                // A remote validator can establish equality only when the
                // installed artifact has a validator to compare with it.
                // Otherwise treating the response as unchanged would attach
                // the remote identity to unverified local bytes.
                guard let lastDownloadedETag else {
                    return .available(
                        modified: true,
                        modifiedAt: nil,
                        etag: etag
                    )
                }
                if etag != lastDownloadedETag {
                    return .available(
                        modified: true,
                        modifiedAt: nil,
                        etag: etag
                    )
                }
            }

            return .available(
                modified: false,
                modifiedAt: remoteModifiedAt,
                etag: etag
            )
        } catch {
            return .unavailable
        }
    }
}

//@available(macOS 13.0, iOS 16.1, *)
//extension DownloadController: BADownloadManagerDelegate {
//    @MainActor
//    public func download(_ download: BADownload, didWriteBytes bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite totalExpectedBytes: Int64) {
//        Task { @MainActor in
//            guard let downloadable = assuredDownloads.downloadable(forDownload: download) else { return }
//            let progress = Progress(totalUnitCount: totalExpectedBytes)
//            progress.completedUnitCount = totalBytesWritten
//            downloadable.downloadProgress = .downloading(progress: progress)
//            downloadable.isFromBackgroundAssetsDownloader = true
//            finishedDownloads.remove(downloadable)
//            failedDownloads.remove(downloadable)
//            activeDownloads.insert(downloadable)
//            do {
//                try await cancelInProgressDownloads(inApp: true)
//            } catch {
//            }
//        }
//    }
//    
//    @MainActor
//    public func downloadDidBegin(_ download: BADownload) {
//        Task { @MainActor in
//            guard let downloadable = assuredDownloads.downloadable(forDownload: download) else { return }
//            downloadable.downloadProgress = .downloading(progress: Progress())
//            downloadable.isFromBackgroundAssetsDownloader = true
//            finishedDownloads.remove(downloadable)
//            failedDownloads.remove(downloadable)
//            activeDownloads.insert(downloadable)
//        }
//    }
//    
//    @MainActor
//    public func download(_ download: BADownload, finishedWithFileURL fileURL: URL) {
//        Task { @MainActor in
//            BADownloadManager.shared.withExclusiveControl { [weak self] acquiredLock, error in
//                guard acquiredLock, error == nil else { return }
//                if let downloadable = self?.assuredDownloads.downloadable(forDownload: download) {
//                    downloadable.isFromBackgroundAssetsDownloader = true
//                    let destination = downloadable.url.pathExtension == "br" ? downloadable.compressedFileURL : downloadable.localDestination
//                    do {
//                        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
//                        try FileManager.default.moveItem(at: fileURL, to: destination)
//                    } catch { }
//                    Task.detached(priority: .utility) { [weak self] in
//                        await self?.finishDownload(downloadable)
//                        Task { @MainActor [weak self] in
//                            downloadable.finishedDownloadingDuringCurrentLaunchAt = Date()
//                            try await self?.cancelInProgressDownloads(inApp: true)
//                        }
//                    }
//                }
//            }
//        }
//    }
//    
//    @DownloadActor
//    public func download(_ download: BADownload, failedWithError error: Error) {
//        if let downloadable = assuredDownloads.downloadable(forDownload: download) {
//            Task { @MainActor in
//                downloadable.downloadProgress = .completed(destinationLocation: nil, etag: nil, error: error)
//                finishedDownloads.remove(downloadable)
//                activeDownloads.remove(downloadable)
//                failedDownloads.insert(downloadable)
//            }
//        }
//        if Bundle.main.object(forInfoDictionaryKey: "BAInitialDownloadRestrictions") != nil {
//            Task { @MainActor in
//                do {
//                    if #available(iOS 16.4, macOS 13.3, *) {
//                        if !download.isEssential {
//                            try BADownloadManager.shared.startForegroundDownload(download)
//                        }
//                    } else {
//                        try BADownloadManager.shared.startForegroundDownload(download)
//                    }
//                } catch { }
//            }
//        }
//    }
//}
//
//@available(macOS 13.0, iOS 16.1, *)
//public extension Set<Downloadable> {
//    func downloadable(forDownload download: BADownload) -> Downloadable? {
//        for downloadable in DownloadController.shared.assuredDownloads {
//            if downloadable.localDestination.absoluteString == download.identifier {
//                return downloadable
//            }
//        }
//        return nil
//    }
//}
