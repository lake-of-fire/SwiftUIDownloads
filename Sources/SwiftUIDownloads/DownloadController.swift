import Foundation
import SwiftUI
import Combine
import BackgroundAssets
import CryptoKit
import SwiftUtilities
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

    DownloadController.localPreparationStageObserver?(.hashingInstalledArtifact)
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

/// Operation-local result of full SHA256 validation; never persisted or cached.
fileprivate struct VerifiedInstalledArtifactReceipt: Sendable {
    let receipt: InstalledArtifactReceipt

    init?(validating receipt: InstalledArtifactReceipt, for download: Downloadable) {
        guard download.installedArtifactMatches(receipt) else { return nil }
        self.receipt = receipt
    }

    func isCurrent(for download: Downloadable) -> Bool {
        guard !Task.isCancelled,
              let identity = download.installedArtifactIdentity(matching: receipt) else {
            return false
        }
        // Without an inode identity, retain the full validation fallback.
        guard identity.fileSystemNumber != nil,
              identity.fileSystemFileNumber != nil else {
            return download.installedArtifactMatches(receipt)
        }
        return true
    }
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

/// A disposable verification marker is not the payload. Failure to inspect
/// or retain it must fail admission without treating healthy bytes as corrupt.
private struct DownloadChecksumMarkerIOError: LocalizedError {
    let url: URL
    let underlyingError: Error

    var errorDescription: String? {
        "Unable to use checksum verification marker at \(url.path): \(underlyingError.localizedDescription)"
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
    if error is CancellationError {
        return "Download interrupted. Please retry."
    }
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

/// The canonical identity of one download operation.
///
/// Remote validators may be shared by source URL, but transfer ownership is
/// scoped to both the standardized source and installed destination.
public struct DownloadOperationKey: Hashable, Sendable {
    private static let taskDescriptionPrefix = "SwiftUIDownloads.DownloadOperationKey.v1."

    public let sourceURL: URL
    public let destinationURL: URL

    public init(sourceURL: URL, destinationURL: URL) {
        self.sourceURL = Self.standardizedSourceURL(sourceURL)
        self.destinationURL = destinationURL.absoluteURL.standardizedFileURL
    }

    static func standardizedSourceURL(_ sourceURL: URL) -> URL {
        sourceURL.isFileURL
            ? sourceURL.absoluteURL.standardizedFileURL
            : sourceURL.absoluteURL.standardized
    }

    /// A reversible representation used to associate URLSession tasks with
    /// their exact logical operation.
    public var taskDescription: String {
        let encodedSource = Data(sourceURL.absoluteString.utf8).base64EncodedString()
        let encodedDestination = Data(destinationURL.absoluteString.utf8).base64EncodedString()
        return Self.taskDescriptionPrefix + encodedSource + "." + encodedDestination
    }

    public init?(taskDescription: String) {
        guard taskDescription.hasPrefix(Self.taskDescriptionPrefix) else { return nil }
        let payload = taskDescription.dropFirst(Self.taskDescriptionPrefix.count)
        let components = payload.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2,
              let sourceData = Data(base64Encoded: String(components[0])),
              let destinationData = Data(base64Encoded: String(components[1])),
              let sourceString = String(data: sourceData, encoding: .utf8),
              let destinationString = String(data: destinationData, encoding: .utf8),
              let sourceURL = URL(string: sourceString),
              let destinationURL = URL(string: destinationString)
        else {
            return nil
        }
        self.init(sourceURL: sourceURL, destinationURL: destinationURL)
    }
}

public enum DownloadExecutionKind: Hashable, Sendable {
    case download
    case importable(
        deleteAfterImport: Bool,
        glossaryFTSEnabled: Bool,
        importOperationIdentifier: String?
    )
}

/// Immutable behavior that every descriptor sharing an operation key must
/// agree on. Display names are intentionally excluded so callers may rename a
/// download without creating a second operation.
public struct DownloadExecutionConfigurationSignature: Hashable, Sendable {
    public let mirrorURL: URL?
    public let localDestinationChecksum: String?
    public let preservedLocalArtifactDirectories: [URL]
    public let metadataCacheNamespace: String
    public let kind: DownloadExecutionKind
    public let allowsUITestArtifactReuse: Bool

    public init(
        mirrorURL: URL?,
        localDestinationChecksum: String?,
        preservedLocalArtifactDirectories: Set<URL>,
        metadataCacheNamespace: String,
        kind: DownloadExecutionKind,
        allowsUITestArtifactReuse: Bool = false
    ) {
        self.mirrorURL = mirrorURL.map(DownloadOperationKey.standardizedSourceURL)
        self.localDestinationChecksum = Self.normalizedOptionalString(
            localDestinationChecksum,
            lowercased: true
        )
        self.preservedLocalArtifactDirectories = Array(Set(
            preservedLocalArtifactDirectories.map {
                $0.absoluteURL.standardizedFileURL
            }
        )).sorted { $0.absoluteString < $1.absoluteString }
        self.metadataCacheNamespace = metadataCacheNamespace
        self.kind = kind
        self.allowsUITestArtifactReuse = allowsUITestArtifactReuse
    }

    static func normalizedOptionalString(
        _ value: String?,
        lowercased: Bool = false
    ) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            return nil
        }
        return lowercased ? normalized.lowercased() : normalized
    }
}

public struct DownloadOperationConfigurationConflictError: LocalizedError, Sendable {
    public let operationKey: DownloadOperationKey
    public let admittedConfiguration: DownloadExecutionConfigurationSignature
    public let proposedConfiguration: DownloadExecutionConfigurationSignature

    public init(
        operationKey: DownloadOperationKey,
        admittedConfiguration: DownloadExecutionConfigurationSignature,
        proposedConfiguration: DownloadExecutionConfigurationSignature
    ) {
        self.operationKey = operationKey
        self.admittedConfiguration = admittedConfiguration
        self.proposedConfiguration = proposedConfiguration
    }

    public var errorDescription: String? {
        "A download is already registered for this source and destination with incompatible settings."
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
    /// Only fixed-checksum dictionary payloads opt in. Writable databases,
    /// installed metadata and generated caches remain owned by each test run.
    public let allowsUITestArtifactReuse: Bool
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
    
    public let id: DownloadOperationKey

    public var executionConfigurationSignature: DownloadExecutionConfigurationSignature {
        DownloadExecutionConfigurationSignature(
            mirrorURL: mirrorURL,
            localDestinationChecksum: localDestinationChecksum,
            preservedLocalArtifactDirectories: preservedLocalArtifactDirectories,
            metadataCacheNamespace: metadataStore.metadataCacheNamespace,
            kind: .download,
            allowsUITestArtifactReuse: allowsUITestArtifactReuse
        )
    }

#if DEBUG
    private var shouldLogReaderOptimizationDiagnostics: Bool {
        let loweredName = name.lowercased()
        let loweredFilename = localDestination.lastPathComponent.lowercased()
        let loweredPath = localDestination.path.lowercased()
        return loweredName.contains("dictionary_index")
            || loweredName.contains("dictionary index")
            || loweredFilename.contains("lookup-cache")
            || loweredPath.contains("lookup-cache")
    }
#endif

    private func logReaderOptimizationDiagnostic(
        _ stage: String,
        _ details: [String: String] = [:]
    ) {
#if DEBUG
        // Exportable TestFlight milestones are owned by ReaderLoadTrace. Keep
        // these older console-only probes out of distribution builds.
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
#endif
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
    /// Installed bytes are revalidated if their file identity changes.
    public init(
        url: URL,
        mirrorURL: URL? = nil,
        name: String,
        localDestination: URL,
        localDestinationChecksum: String? = nil,
        preservedLocalArtifactDirectories: Set<URL> = [],
        isFromBackgroundAssetsDownloader: Bool? = nil,
        metadataStore: (any DownloadableMetadataStore)? = nil,
        allowsUITestArtifactReuse: Bool = false
    ) {
        self.id = DownloadOperationKey(sourceURL: url, destinationURL: localDestination)
        self.url = url
        self.mirrorURL = mirrorURL
        self.name = name
        self.localDestination = localDestination
        self.localDestinationChecksum = localDestinationChecksum
        self.allowsUITestArtifactReuse = allowsUITestArtifactReuse
        self.preservedLocalArtifactDirectories = Set(
            preservedLocalArtifactDirectories.map(\.standardizedFileURL)
        )
        self.isFromBackgroundAssetsDownloader = isFromBackgroundAssetsDownloader
        let resolvedMetadataStore = metadataStore ?? UserDefaultsDownloadableMetadataStore()
        self.metadataStore = resolvedMetadataStore
        self.downloadMetadataCache = DownloadMetadataCache.shared(
            store: resolvedMetadataStore,
            sourceURL: url,
            destinationURL: localDestination
        )
        let metadataObservationRelay = DownloadMetadataObservationRelay()
        metadataObservationRelay.owner = self
        self.downloadMetadataCache.startLoading(observationRelay: metadataObservationRelay)
    }
    
    public static func == (lhs: Downloadable, rhs: Downloadable) -> Bool {
        lhs.id == rhs.id
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

    func validInstalledArtifactReceipt() -> InstalledArtifactReceipt? {
        verifiedInstalledArtifactReceipt()?.receipt
    }

    /// Readiness comes from the current pinned checksum marker, not from the
    /// stored receipt's SHA256. The receipt only binds this prior installation
    /// to the same source, destination and file identity. Do not use this as a
    /// VerifiedInstalledArtifactReceipt or as byte proof for an unpinned file.
    fileprivate func retainedPinnedArtifactByteCount() -> UInt64? {
        guard let expectedChecksum = localDestinationChecksum?.lowercased(),
              let receipt = try? metadataStore.installedArtifactReceipt(
                sourceURL: url, destinationURL: localDestination
              ),
              let identity = installedArtifactIdentity(matching: receipt),
              let marker = try? loadChecksumVerificationMarker(),
              marker.expectedChecksum == expectedChecksum,
              checksumVerificationMarker(marker, matches: identity) else {
            return nil
        }
        return identity.fileSize
    }

    fileprivate func verifiedInstalledArtifactReceipt() -> VerifiedInstalledArtifactReceipt? {
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

        guard let verified = VerifiedInstalledArtifactReceipt(validating: receipt, for: self) else {
            if !Task.isCancelled {
                try? removeInstalledArtifactReceipt()
            }
            return nil
        }
        return verified
    }

    /// Binding and metadata checks only; this does not establish byte proof.
    fileprivate func installedArtifactIdentity(
        matching receipt: InstalledArtifactReceipt
    ) -> ChecksumVerificationFileIdentity? {
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
              installedArtifactReceipt(receipt, matches: initialIdentity) else {
            return nil
        }
        return initialIdentity
    }

    func installedArtifactMatches(_ receipt: InstalledArtifactReceipt) -> Bool {
        guard let initialIdentity = installedArtifactIdentity(matching: receipt),
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
        try makeInstalledArtifactReceipt(finalResponseURL: finalResponseURL, reusing: nil)
    }

    fileprivate func makeInstalledArtifactReceipt(
        finalResponseURL: URL?,
        reusing verifiedReceipt: VerifiedInstalledArtifactReceipt?
    ) throws -> InstalledArtifactReceipt {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: localDestination.path
        )
        guard let identity = checksumVerificationFileIdentity(from: attributes) else {
            throw DownloadableChecksumVerificationError.emptyFile(localDestination)
        }
        let digest: String
        if let verifiedReceipt, verifiedReceipt.isCurrent(for: self) {
            digest = verifiedReceipt.receipt.sha256Digest
        } else {
            digest = try sha256Checksum(for: localDestination)
        }
        try Task.checkCancellation()
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
        do {
            let data = try JSONEncoder().encode(marker)
            try data.write(to: checksumVerificationMarkerURL, options: .atomic)
        } catch {
            throw DownloadChecksumMarkerIOError(
                url: checksumVerificationMarkerURL,
                underlyingError: error
            )
        }
        let currentAttributes: [FileAttributeKey: Any]
        do {
            currentAttributes = try FileManager.default.attributesOfItem(
                atPath: localDestination.path
            )
        } catch {
            // A failed stat is not proof that the verified payload changed.
            try? FileManager.default.removeItem(at: checksumVerificationMarkerURL)
            throw DownloadLocalFileInspectionError(
                url: localDestination,
                underlyingError: error
            )
        }
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
        let data: Data
        do {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: checksumVerificationMarkerURL.path
            )
            // Non-file occupants cannot provide verification. Rehash bytes and
            // let atomic marker persistence fail safely if the path is blocked.
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                return nil
            }
            data = try Data(contentsOf: checksumVerificationMarkerURL)
        } catch {
            throw DownloadChecksumMarkerIOError(
                url: checksumVerificationMarkerURL,
                underlyingError: error
            )
        }
        // Truncated JSON and obsolete/malformed shapes are disposable cache
        // misses. Only a fresh checksum verification can replace their proof.
        return try? JSONDecoder().decode(ChecksumVerificationMarker.self, from: data)
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
        try await fetchRemoteFileSize(session: .shared)
    }

    @DownloadActor
    func fetchRemoteFileSize(session: URLSession) async throws {
        guard await !existsLocally() else { return }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 6
        )
        request.httpMethod = "HEAD"
        let response = try await session.data(for: request).1
        if let error = downloadResponseAdmissionError(response: response, requestedURL: url) {
            throw error
        }
        let expectedContentLength = response.expectedContentLength
        await MainActor.run {
            self.fileSize = expectedContentLength >= 0
                ? UInt64(expectedContentLength)
                : nil
        }
    }
    
    @DownloadActor
    func download(
        session: URLSession,
        destination: URL
    ) async -> URLResourceDownloadTask {
        let observationGeneration = beginDownloadObservation()
        let task = URLResourceDownloadTask(
            session: session,
            url: url,
            destination: destination,
            operationKey: id
        )
        
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
                    fileSize = DownloadProgressMetrics.knownByteCount(
                        totalUnitCount: progress.totalUnitCount,
                        completedUnitCount: progress.completedUnitCount
                    )
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
        stagingPaths.url(for: .transfer, operationID: operationID)
    }

    func compressedTransferStagingURL(operationID: UUID) -> URL {
        stagingPaths.url(for: .compressed, operationID: operationID)
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
            let temporaryOutputURL = decompressionStagingURL(operationID: operationID)
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
        do {
            if let isolatedURL = try isolatedUITestDirectoryURL(
                arguments: ProcessInfo.processInfo.arguments,
                environment: ProcessInfo.processInfo.environment,
                temporaryDirectory: FileManager.default.temporaryDirectory
            ) {
                return isolatedURL
            }
        } catch {
            // A malformed isolated launch must never fall through to the
            // developer's shared download data or a stale test override.
            preconditionFailure("Invalid isolated UI-test download identity: \(error)")
        }
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
#if DEBUG || MANABI_NATIVE_TEST_STORAGE
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
#if DEBUG || MANABI_NATIVE_TEST_STORAGE
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
    enum IsolatedUITestDirectoryError: Error {
        case invalidRunID
    }

    /// Resolve inside the launched app, whose sandbox temp directory differs
    /// from the XCTest runner's. Keep the existing Manabi isolated app-group
    /// layout without importing the application or creating any files here.
    func isolatedUITestDirectoryURL(
        arguments: [String],
        environment: [String: String],
        temporaryDirectory: URL
    ) throws -> URL? {
        guard arguments.contains("--ui-test-isolated-data-root") else { return nil }
        let parent: String?
        let child: String?
        let group: String?
        let defaultDirectory: String?
        switch self {
        case .documents(let parentDirectoryName, let subdirectoryName, let groupIdentifier):
            (parent, child, group) = (parentDirectoryName, subdirectoryName, groupIdentifier)
            defaultDirectory = "swiftui-downloads"
        case .appSupport(let parentDirectoryName, let subdirectoryName, let groupIdentifier):
            (parent, child, group) = (parentDirectoryName, subdirectoryName, groupIdentifier)
            defaultDirectory = nil
        }
        guard group != nil else { return nil }
        guard let runID = environment["MANABI_UI_TEST_DATA_ROOT_RUN_ID"],
              let parsed = UUID(uuidString: runID),
              parsed.uuidString.lowercased() == runID else {
            throw IsolatedUITestDirectoryError.invalidRunID
        }
        var url = temporaryDirectory
            .appendingPathComponent("ManabiReaderUITests", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
            .appendingPathComponent("app-group", isDirectory: true)
        if let directory = parent ?? defaultDirectory {
            url.appendPathComponent(directory, isDirectory: true)
        }
        if let child {
            url.appendPathComponent(child, isDirectory: true)
        }
        return url
    }

#endif

#if DEBUG || MANABI_NATIVE_TEST_STORAGE
    // The native measurement runner enables storage isolation without DEBUG,
    // preserving optimized production lookup paths. App/archive builds omit it.
    static func testAppGroupURL(
        groupIdentifier: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isRunningTests: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTest.XCTestCase") != nil
    ) -> URL? {
        guard groupIdentifier != nil else { return nil }
        if let testAppGroupPath = environment["MANABI_TEST_APP_GROUP_DIR"],
           !testAppGroupPath.isEmpty {
            return URL(fileURLWithPath: testAppGroupPath, isDirectory: true)
        }
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
        metadataStore: (any DownloadableMetadataStore)? = nil,
        allowsUITestArtifactReuse: Bool = false
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
            metadataStore: metadataStore,
            allowsUITestArtifactReuse: allowsUITestArtifactReuse
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

    public enum LocalPreparationOutcome: Sendable, Equatable {
        case available
        case unavailable
        /// A network-capable producer or background suspension owns admission.
        case busy
    }

    /// Scoped observation of startup preparation; never participates in admission.
    /// Fixed labels let an owning app time actor waits without exposing paths.
    public enum LocalPreparationStage: String, Sendable {
        case metadataRequested, metadataReady, processingRequested
        case stateRequested, stateRead, stateReady, verifiedArtifact
        case publicationRequested, publicationStarted, publicationApplied, publicationFinished, completed
        case hashingInstalledArtifact
    }

    @TaskLocal public static var localPreparationStageObserver:
        (@Sendable (LocalPreparationStage) -> Void)?

    private enum ProcessingScope: Sendable, Equatable {
        case ordinary
        case localOnly
    }
    
    typealias DownloadAttemptExecutor = @Sendable (
        _ download: Downloadable,
        _ session: URLSession
    ) async throws -> DownloadTransferResult
    private struct ProcessingTaskRecord {
        let id: UUID
        let task: Task<Void, Never>
        let completion: DownloadWorkCompletion
        var scope: ProcessingScope = .ordinary
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
    private enum DownloadAdmission {
        case owner(Downloadable)
        case compatibleReplay(owner: Downloadable)
        case rejected
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
    private var downloadStatusCancellables = [DownloadOperationKey: Set<AnyCancellable>]()
    private var processingTasks = [DownloadOperationKey: ProcessingTaskRecord]()
    private var checksumRecoveryTasks = [DownloadOperationKey: ProcessingTaskRecord]()
    private var downloadTasks = [DownloadOperationKey: ProcessingTaskRecord]()
    private var backgroundSuspendedDownloads = Set<DownloadOperationKey>()
    private var backgroundSuspendedChecksumRecoveries = Set<DownloadOperationKey>()
    private var backgroundSuspensionGeneration: UInt64 = 0
    @DownloadActor internal private(set) var backgroundWorkIsSuspended = false
    @MainActor private let lifecycleNotifications = AppLifecycleNotificationSource()
    @DownloadActor private var lifecycleNotificationAdmission = AppLifecycleNotificationAdmission()
    private var downloadAttemptIDs = [DownloadOperationKey: UUID]()
    private var activeTransferStagingURLs = Set<URL>()
    private var checksumRecoveriesReadyForProcessing = Set<DownloadOperationKey>()
    private var checksumRedownloadAttempted = Set<DownloadOperationKey>()
    private var completionMetadataRetryDownloadIDs = Set<DownloadOperationKey>()
    private var pendingInstalledArtifactReceipts = [
        DownloadOperationKey: PendingInstalledArtifactReceipt
    ]()
    private var admittedDownloads = [DownloadOperationKey: Downloadable]()
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
            .sink { [weak self] notification in
                guard let application = notification.object as? UIApplication else { return }
                Task { @MainActor [weak self] in
                    await self?.handleAppLifecycleNotification(.background) {
                        application.applicationState == .background
                    }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: UIApplication.willEnterForegroundNotification)
            .merge(with: NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification))
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.handleAppLifecycleNotification(.active) {
                        UIApplication.shared.applicationState == .active
                    }
                }
            }
            .store(in: &cancellables)
#endif
    }

    @MainActor
    internal func handleAppLifecycleNotification(
        _ phase: AppLifecycleNotification.Phase,
        isCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async {
        guard let notification = lifecycleNotifications.notification(
            for: phase,
            isCurrent: isCurrent
        ) else { return }
        await applyAppLifecycleNotification(notification)
    }

    @DownloadActor
    internal func applyAppLifecycleNotification(
        _ notification: AppLifecycleNotification
    ) async {
        guard await notification.isCurrent(),
              lifecycleNotificationAdmission.accept(notification) else { return }
        switch notification.phase {
        case .active:
            await resumeAfterBackgroundDrain(shouldResume: {
                notification.isCurrent()
            })
        case .background:
            await cancelLongRunningWorkForBackgrounding()
        }
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
             .cannotParseResponse,
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
        try Task.checkCancellation()
        guard !backgroundWorkIsSuspended else { throw CancellationError() }
        var retainedDownloads = await assuredDownloads.union(excluding)
        try Task.checkCancellation()
        guard !backgroundWorkIsSuspended else { throw CancellationError() }

        // Direct downloads and standalone processors need not be in the
        // assurance list. Capture actual owners after the last actor hop and
        // keep this snapshot through the synchronous sweep, including owners
        // which have been cancelled but have not finished unwinding.
        let liveKeys = Set(downloadTasks.keys)
            .union(processingTasks.keys)
            .union(checksumRecoveryTasks.keys)
        let liveDownloads = liveKeys.compactMap { admittedDownloads[$0] }
        retainedDownloads.formUnion(liveDownloads)
        var saveFiles = Set(retainedDownloads.map(\.localDestination))
            .union(retainedDownloads.map(\.compressedFileURL))
            .union(retainedDownloads.map(\.checksumVerificationMarkerURL))
            .union(activeTransferStagingURLs)
            .union(liveDownloads.map(\.url).filter(\.isFileURL))
        for download in retainedDownloads {
            if let processingTaskID = processingTasks[download.id]?.id {
                saveFiles.insert(download.decompressionStagingURL(operationID: processingTaskID))
            }
        }
        try DownloadOrphanCleanup.removeOrphans(
            in: locations.map(\.directoryURL),
            preservingFiles: saveFiles,
            preservingDirectories: Set(retainedDownloads.flatMap(\.preservedLocalArtifactDirectories))
        )

        for download in retainedDownloads
            where download.localDestinationChecksum == nil
                && !FileManager.default.fileExists(atPath: download.localDestination.path) {
            try Task.checkCancellation()
            try? download.removeInstalledArtifactReceipt()
        }
    }

    @DownloadActor
    func delete(download: Downloadable) async throws -> Downloadable {
        switch await admit(download) {
        case .owner:
            break
        case .compatibleReplay(let owner):
            _ = try await delete(download: owner)
            await mirrorTerminalState(from: owner, to: download)
            return download
        case .rejected:
            return download
        }
        // Fence any delegate/retry completion that arrives after deletion.
        downloadAttemptIDs[download.id] = nil
        completionMetadataRetryDownloadIDs.remove(download.id)
        pendingInstalledArtifactReceipts[
            download.id
        ] = nil
        download.invalidateDownloadObservation()
        let downloadRecord = downloadTasks[download.id]
        let processingRecord = processingTasks[download.id]
        let recoveryRecord = checksumRecoveryTasks[download.id]
        processingRecord?.task.cancel()
        recoveryRecord?.task.cancel()
        await cancelInProgressDownload(download)
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
            assuredDownloads = assuredDownloads.filter { $0.id != download.id }
            finishedDownloads = finishedDownloads.filter { $0.id != download.id }
            failedDownloads = failedDownloads.filter { $0.id != download.id }
            activeDownloads = activeDownloads.filter { $0.id != download.id }
            download.isActive = false
            download.isFinishedProcessing = false
            download.isFinishedDownloading = false
            download.isFailed = false
            download.downloadProgress = .uninitiated
        }
        if admittedDownloads[download.id] === download {
            admittedDownloads[download.id] = nil
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
    func isDownloaded(_ download: Downloadable) -> Bool {
        finishedDownloads.contains(download)
    }

    @MainActor
    func isDownloading(_ download: Downloadable) -> Bool {
        activeDownloads.contains(download)
    }

    @MainActor
    func isFailed(_ download: Downloadable) -> Bool {
        failedDownloads.contains(download)
    }

    @MainActor
    func downloadable(for operationKey: DownloadOperationKey) -> Downloadable? {
        finishedDownloads.first(where: { $0.id == operationKey })
            ?? activeDownloads.first(where: { $0.id == operationKey })
            ?? failedDownloads.first(where: { $0.id == operationKey })
            ?? assuredDownloads.first(where: { $0.id == operationKey })
    }

    /// Source-wide compatibility query. Prefer the descriptor/key overload
    /// when more than one destination may use the same source URL.
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
    /// Read-only admission of an already verified pinned file. This does not
    /// publish download UI state or establish remote assurance. The ordinary
    /// download owner still publishes completion and performs recovery.
    /// `.unavailable` selects normal local preparation, including imports and
    /// retained compressed inputs. Availability is a snapshot, not a lease.
    @DownloadActor
    public func verifiedLocalArtifactAvailability(
        download: Downloadable
    ) async throws -> LocalPreparationOutcome {
        try Task.checkCancellation()
        await download.waitForDownloadMetadata()
        try Task.checkCancellation()
        switch await admit(download) {
        case .owner:
            break
        case .compatibleReplay(let owner):
            return try await verifiedLocalArtifactAvailability(download: owner)
        case .rejected:
            return .unavailable
        }
        try Task.checkCancellation()
        guard !backgroundWorkIsSuspended,
              downloadTasks[download.id] == nil,
              checksumRecoveryTasks[download.id] == nil else { return .busy }
        if let processing = processingTasks[download.id] {
            // Preserve the normal local path's shared wait and cancellation.
            return processing.scope == .localOnly ? .unavailable : .busy
        }
        guard canPrepareNativePinnedArtifact(download),
              download.hasVerifiedLocalDestinationChecksumMarker() else {
            return .unavailable
        }
        // No suspension between producer exclusion and native identity proof.
        Self.localPreparationStageObserver?(.verifiedArtifact)
        Self.localPreparationStageObserver?(.completed)
        return .available
    }

    /// Eligibility only; callers must separately exclude producers and prove
    /// the current checksum marker before admitting bytes.
    @DownloadActor
    private func canPrepareNativePinnedArtifact(_ download: Downloadable) -> Bool {
        !(download is ImportableDownloadable)
            && download.localDestinationChecksum != nil
            && !completionMetadataRetryDownloadIDs.contains(download.id)
            && pendingInstalledArtifactReceipts[download.id] == nil
            && !FileManager.default.fileExists(atPath: download.compressedFileURL.path)
            && FileManager.default.fileExists(atPath: download.localDestination.path)
    }

    @DownloadActor
    private func admit(
        _ proposedDownload: Downloadable,
        registeringIfNeeded: Bool = true
    ) async -> DownloadAdmission {
        guard let admittedDownload = admittedDownloads[proposedDownload.id] else {
            if registeringIfNeeded {
                admittedDownloads[proposedDownload.id] = proposedDownload
            }
            return .owner(proposedDownload)
        }
        guard admittedDownload !== proposedDownload else {
            return .owner(admittedDownload)
        }
        guard admittedDownload.executionConfigurationSignature
                == proposedDownload.executionConfigurationSignature else {
            let error = DownloadOperationConfigurationConflictError(
                operationKey: proposedDownload.id,
                admittedConfiguration: admittedDownload.executionConfigurationSignature,
                proposedConfiguration: proposedDownload.executionConfigurationSignature
            )
            await markRejectedDownload(proposedDownload, error: error)
            return .rejected
        }
        return .compatibleReplay(owner: admittedDownload)
    }

    @DownloadActor
    private func markRejectedDownload(
        _ download: Downloadable,
        error: DownloadOperationConfigurationConflictError
    ) async {
        await MainActor.run {
            if let importable = download as? ImportableDownloadable {
                importable.lastImportError = error
                importable.importProgress = nil
                importable.importStatusText = "Download configuration conflict"
            }
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
    }

    @DownloadActor
    private func currentWork(for key: DownloadOperationKey) -> ProcessingTaskRecord? {
        // A transfer owns its finish phase; recovery likewise owns its processor.
        // Prefer the enclosing producer so a join includes its entire lifetime.
        downloadTasks[key] ?? checksumRecoveryTasks[key] ?? processingTasks[key]
    }

    @DownloadActor
    private func deferWorkIfBackgroundSuspended(
        _ download: Downloadable,
        checksumRecovery: Bool = false
    ) -> Bool {
        guard backgroundWorkIsSuspended else { return false }
        // Late requests are not part of the already-completed suspension drain.
        // Retain their identity for activation without starting another writer.
        backgroundSuspendedDownloads.insert(download.id)
        if checksumRecovery { backgroundSuspendedChecksumRecoveries.insert(download.id) }
        return true
    }

    @DownloadActor
    private func joinCurrentWorkIfNeeded(
        for key: DownloadOperationKey,
        continuingAfterLocalPreparation: Bool = false
    ) async -> Bool {
        while let work = currentWork(for: key) {
            guard await work.completion.wait(), !Task.isCancelled else { return true }
            // A local processor cannot discharge remote freshness or repair.
            // Recheck ownership after its completion before continuing assurance.
            if !continuingAfterLocalPreparation || work.scope == .ordinary { return true }
        }
        return false
    }

    @DownloadActor
    private func performCompatibleReplay(
        _ replay: Downloadable,
        owner: Downloadable,
        whenIdle: @escaping @DownloadActor @Sendable () async -> Void
    ) async {
        guard !Task.isCancelled else { return }
        let work = currentWork(for: owner.id)
        let observation = await DownloadReplayObservation(owner: owner, replay: replay)
        if let work {
            _ = await work.completion.wait()
        }
        if (work == nil || work?.scope == .localOnly),
           !Task.isCancelled, admittedDownloads[owner.id] === owner {
            // Registration is not readiness. Dispatch the requested action with
            // its original options, and let its normal admission recheck work
            // which may have arrived during the main-actor observation hop.
            await whenIdle()
        }
        await observation.stop(copyFinalState: !Task.isCancelled)
    }

    @DownloadActor
    private func mirrorTerminalState(
        from owner: Downloadable,
        to replay: Downloadable
    ) async {
        await DownloadReplayObservation.copyState(from: owner, to: replay)
    }

    @DownloadActor
    private func hasProcessableArtifactOrPendingReceipt(
        for download: Downloadable
    ) -> Bool {
        if download.hasProcessableLocalArtifact() {
            return true
        }
        guard let pendingReceipt = pendingInstalledArtifactReceipts[
            download.id
        ] else {
            return false
        }
        return download.installedArtifactMatches(pendingReceipt.receipt)
    }

    @DownloadActor
    private func clearDownloadStatusObservers(forDownloadID downloadID: DownloadOperationKey) {
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
        await ensureDownloaded(
            download: download,
            deletingOrphansIn: deletingOrphansIn,
            excludingFromDeletion: excludingFromDeletion,
            shouldCheckForUpdates: download.shouldCheckForUpdates
        )
    }

    /// Prepares retained bytes without remote checks, transfers, or checksum
    /// recovery. A canceled owner drains its processor before throwing; other
    /// local waiters own only their wait. This never establishes remote assurance.
    /// Missing or invalid retained bytes are unavailable; network-capable work
    /// returns busy without being joined. Retained pinned, non-importing files
    /// without compressed input or unsettled completion metadata are prepared
    /// from native checksum proof without publishing download UI state. Ordinary
    /// assurance publishes that state later. Availability is a snapshot, not a lease.
    @DownloadActor
    public func prepareAvailableLocalArtifact(
        download: Downloadable
    ) async throws -> LocalPreparationOutcome {
        try Task.checkCancellation()
        Self.localPreparationStageObserver?(.metadataRequested)
        await download.waitForDownloadMetadata()
        Self.localPreparationStageObserver?(.metadataReady)
        try Task.checkCancellation()
        switch await admit(download) {
        case .owner:
            break
        case .compatibleReplay(let owner):
            let preparesNativeArtifactOnly = canPrepareNativePinnedArtifact(owner)
            let outcome = try await prepareAvailableLocalArtifact(download: owner)
            try Task.checkCancellation()
            if preparesNativeArtifactOnly, outcome == .available {
                // Recursion suspended: native replay must recheck ownership and
                // proof too, without waiting for terminal UI state to mirror.
                guard !backgroundWorkIsSuspended,
                      downloadTasks[owner.id] == nil,
                      checksumRecoveryTasks[owner.id] == nil,
                      processingTasks[owner.id] == nil else { return .busy }
                return canPrepareNativePinnedArtifact(owner)
                    && owner.hasVerifiedLocalDestinationChecksumMarker()
                    ? .available : .unavailable
            }
            if outcome != .busy {
                await mirrorTerminalState(from: owner, to: download)
            }
            try Task.checkCancellation()
            return outcome
        case .rejected:
            return .unavailable
        }
        try Task.checkCancellation()
        guard !backgroundWorkIsSuspended,
              downloadTasks[download.id] == nil,
              checksumRecoveryTasks[download.id] == nil else { return .busy }
        let preparesNativeArtifactOnly = canPrepareNativePinnedArtifact(download)
        Self.localPreparationStageObserver?(.processingRequested)
        if let processing = processingTasks[download.id] {
            guard processing.scope == .localOnly else { return .busy }
            _ = await processing.completion.wait()
            try Task.checkCancellation()
        } else {
            await finishDownloadedFile(
                download,
                recordSuccessfulDownload: false,
                transferredFileURL: nil,
                scope: .localOnly,
                preparesNativeArtifactOnly: preparesNativeArtifactOnly
            )
            try Task.checkCancellation()
        }
        if preparesNativeArtifactOnly {
            // The registered processor has drained. Do not queue native
            // readiness behind cosmetic flags; recheck live producers and proof
            // without another suspension before returning the snapshot.
            guard !backgroundWorkIsSuspended,
                  downloadTasks[download.id] == nil,
                  checksumRecoveryTasks[download.id] == nil,
                  processingTasks[download.id] == nil else { return .busy }
            let outcome: LocalPreparationOutcome =
                canPrepareNativePinnedArtifact(download)
                && download.hasVerifiedLocalDestinationChecksumMarker()
                ? .available : .unavailable
            Self.localPreparationStageObserver?(.completed)
            return outcome
        }
        Self.localPreparationStageObserver?(.stateRequested)
        let finished = await MainActor.run {
            let finished = download.isFinishedProcessing && !download.isFailed
            Self.localPreparationStageObserver?(.stateRead)
            return finished
        }
        Self.localPreparationStageObserver?(.stateReady)
        let importable = download as? ImportableDownloadable
        let imported = await importable?.isImported() ?? true
        try Task.checkCancellation()
        // Recheck after suspension: a replacement producer may now own the path.
        guard !backgroundWorkIsSuspended,
              downloadTasks[download.id] == nil,
              checksumRecoveryTasks[download.id] == nil,
              processingTasks[download.id] == nil else { return .busy }
        let outcome: LocalPreparationOutcome = finished && imported
            && (download.hasAdmissibleInstalledArtifact() || importable?.deleteAfterImport == true)
            ? .available : .unavailable
        Self.localPreparationStageObserver?(.completed)
        return outcome
    }

    @MainActor
    private func ensureDownloaded(
        download: Downloadable,
        deletingOrphansIn: [DownloadDirectory],
        excludingFromDeletion: Set<Downloadable>,
        shouldCheckForUpdates: Bool
    ) async {
        guard !Task.isCancelled else { return }
        await download.waitForDownloadMetadata()
        guard !Task.isCancelled else { return }
        switch await admit(download) {
        case .owner:
            break
        case .compatibleReplay(let owner):
            await performCompatibleReplay(download, owner: owner) {
                await self.ensureDownloaded(
                    download: owner,
                    deletingOrphansIn: deletingOrphansIn,
                    excludingFromDeletion: excludingFromDeletion,
                    shouldCheckForUpdates: shouldCheckForUpdates
                )
            }
            return
        case .rejected:
            return
        }
        guard !(await deferWorkIfBackgroundSuspended(download)) else { return }
        if await joinCurrentWorkIfNeeded(
            for: download.id, continuingAfterLocalPreparation: true
        ) { return }
        guard !Task.isCancelled else { return }
        let updateCheckInterval = TimeInterval(60 * 60 * 2)
        let hasVerifiedPinnedArtifact = download.localDestinationChecksum != nil
            && download.hasVerifiedLocalDestinationChecksumMarker()
        let isUpdateCheckDue = shouldCheckForUpdates && !hasVerifiedPinnedArtifact && (
            download.lastCheckedETagAt == nil
                || (download.lastCheckedETagAt ?? Date()).distance(to: Date()) > updateCheckInterval
        )
        // Assurance establishes local readiness, not indefinite remote freshness.
        if !isUpdateCheckDue, assuredDownloads.contains(download) && !failedDownloads.contains(download) {
            let importable = download as? ImportableDownloadable
            let importIsComplete = await importable?.isImported() ?? true
            let importedWithoutRetainedSource = importIsComplete
                && importable?.deleteAfterImport == true
            // A prior assurance is not proof that installed bytes or derived
            // import state survived. Both must be ready for this fast path.
            if (download.isFinishedProcessing
                && importIsComplete
                && download.hasAdmissibleInstalledArtifact())
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
            // A checksum pins the accepted bytes, independently of HTTP
            // validators. Re-fetching an already verified pinned artifact
            // can only reinstall the same bytes (or fail verification), and
            // needlessly revokes dictionary readers through file replacement.
            // Validation/repair above still runs before taking this shortcut.
            let hasVerifiedPinnedArtifact = download.localDestinationChecksum != nil
                && download.hasVerifiedLocalDestinationChecksumMarker()
            if shouldCheckForUpdates,
               !hasVerifiedPinnedArtifact,
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
        guard !Task.isCancelled else { return }
        switch await admit(download) {
        case .owner:
            break
        case .compatibleReplay(let owner):
            await performCompatibleReplay(download, owner: owner) {
                await self.download(
                    owner,
                    etag: etag,
                    remoteModifiedAt: remoteModifiedAt,
                    updatesRemoteModifiedAt: updatesRemoteModifiedAt
                )
            }
            return
        case .rejected:
            return
        }
        if let existing = downloadTasks[download.id] {
            _ = await existing.completion.wait()
            return
        }
        guard !Task.isCancelled,
              !deferWorkIfBackgroundSuspended(download),
              downloadAttemptIDs[download.id] == nil else { return }
        let previousProcessingTask = processingTasks[download.id]?.task
        let previousRecoveryTask = checksumRecoveryTasks[download.id]?.task
        let downloadAttemptID = UUID()
        let completion = DownloadWorkCompletion()
        downloadAttemptIDs[download.id] = downloadAttemptID
        // URLSession has no task during retry backoff. Retain the logical
        // operation so scoped cancellation owns transfer, backoff and import.
        let task = Task { @DownloadActor [self] in
            defer {
                if downloadAttemptIDs[download.id] == downloadAttemptID {
                    downloadAttemptIDs[download.id] = nil
                }
                if downloadTasks[download.id]?.id == downloadAttemptID {
                    downloadTasks[download.id] = nil
                }
                completion.finish()
            }
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
        downloadTasks[download.id] = ProcessingTaskRecord(
            id: downloadAttemptID, task: task, completion: completion
        )

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

        // The logical attempt already owns this destination. A seed is only
        // installed when no prior destination exists; normal checksum/receipt
        // processing below still determines whether the download is ready.
        if let cache = download.uiTestArtifactCache,
           let checksum = download.localDestinationChecksum,
           !FileManager.default.fileExists(atPath: download.localDestination.path) {
            do {
                if try cache.restore(checksum: checksum, to: download.localDestination) {
                    return DownloadTransferResult(
                        destinationLocation: download.localDestination,
                        etag: nil, lastModified: nil, finalResponseURL: download.url
                    )
                }
            } catch {
                // A cache error is a miss, never proof of dictionary corruption.
                // Cancellation still belongs to the controller's attempt.
                guard !Task.isCancelled else { return nil }
            }
        }
        
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
        if allTasks.first(where: { $0.taskDescription == download.id.taskDescription }) != nil {
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
//                                        try await BADownloadManager.shared.startForegroundDownload(baDL)
//                                    }
//                                } else {
//                                    try await BADownloadManager.shared.startForegroundDownload(baDL)
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
            if terminalAttemptError is CancellationError
                || (terminalAttemptError as? URLError)?.code == .cancelled {
                await markDownloadCancelled(download, error: terminalAttemptError)
                return nil
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
    public func cancelInProgressDownload(_ download: Downloadable) async {
        switch await admit(download, registeringIfNeeded: false) {
        case .owner, .compatibleReplay:
            break
        case .rejected:
            return
        }
        let allTasks = await session.allTasks
        let matchingTasks = allTasks.filter {
            $0.taskDescription == download.id.taskDescription
        }
        for task in matchingTasks {
            task.cancel()
        }
        await cancelOwnedDownloadWork(matching: download.id)
    }

    /// Cancels every operation whose canonical source URL matches `sourceURL`,
    /// regardless of destination. Prefer exact descriptor cancellation.
    @MainActor
    public func cancelInProgressDownloads(matchingSourceURL sourceURL: URL) async {
        let standardizedSourceURL = DownloadOperationKey.standardizedSourceURL(sourceURL)
        let allTasks = await session.allTasks
        for task in allTasks where task.taskDescription == standardizedSourceURL.absoluteString
            || DownloadOperationKey(
                taskDescription: task.taskDescription ?? ""
            )?.sourceURL == standardizedSourceURL {
            task.cancel()
        }
        await cancelOwnedDownloadWork(matchingSourceURL: standardizedSourceURL)
    }

    @MainActor
    public func cancelAllInProgressDownloads() async {
        for task in await session.allTasks {
            task.cancel()
        }
        await cancelOwnedDownloadWork()
    }

    @DownloadActor
    private func cancelOwnedDownloadWork(
        matching operationKey: DownloadOperationKey? = nil,
        matchingSourceURL sourceURL: URL? = nil,
        preservingBackgroundSuspension: Bool = false
    ) async {
        let matches: (DownloadOperationKey) -> Bool = { key in
            (operationKey == nil || key == operationKey)
                && (sourceURL == nil || key.sourceURL == sourceURL)
        }
        let explicitlyCanceledSuspensions: Set<DownloadOperationKey> = preservingBackgroundSuspension
            ? [] : backgroundSuspendedDownloads.filter(matches)
        backgroundSuspendedDownloads.subtract(explicitlyCanceledSuspensions)
        backgroundSuspendedChecksumRecoveries.subtract(explicitlyCanceledSuspensions)
        let records = downloadTasks.filter { matches($0.key) }
            .map(\.value)
            + processingTasks.filter { matches($0.key) }.map(\.value)
            + checksumRecoveryTasks.filter { matches($0.key) }.map(\.value)
        records.forEach { $0.task.cancel() }
        for key in explicitlyCanceledSuspensions where currentWork(for: key) == nil {
            if let download = admittedDownloads[key] {
                await markDownloadCancelled(download)
            }
        }
        // Each owner removes only its candidates and publishes its terminal
        // cancellation. Ownership remains until it drains. Cancellation itself
        // must not await an importer that may have requested this cancellation.
        // Deletion separately awaits the owners before removing artifacts.
    }
    
    @MainActor
    func cancelInProgressDownloads(inApp: Bool = false, inDownloadExtension: Bool = false) async throws {
        if inApp {
            let allTasks = await session.allTasks
            let assuredDownloadIDs = Set(assuredDownloads.map(\.id))
            for task in allTasks.filter({ task in
                guard let taskDescription = task.taskDescription,
                      let key = DownloadOperationKey(taskDescription: taskDescription)
                else { return false }
                return assuredDownloadIDs.contains(key)
            }) {
                task.cancel()
            }
            await cancelOwnedDownloadWork()
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
        backgroundWorkIsSuspended = true
        backgroundSuspensionGeneration &+= 1
        backgroundSuspendedDownloads.formUnion(downloadTasks.keys)
        backgroundSuspendedDownloads.formUnion(processingTasks.keys)
        backgroundSuspendedDownloads.formUnion(checksumRecoveryTasks.keys)
        // Mark the reason before canceling. The owned task propagates cancellation
        // to URLSession, retry backoff and import without a main-actor race.
        await cancelOwnedDownloadWork(preservingBackgroundSuspension: true)
    }

    /// Cancellation alone can return while decompression, import, or metadata
    /// settlement still owns a shared-file lock. The app's suspension assertion
    /// covers this drain; the ordinary notification observer remains nonblocking.
    @DownloadActor
    public func reopenAdmissionAfterBackgroundDrain(
        shouldResume: @MainActor @Sendable () -> Bool
    ) async -> Bool {
        let generation = backgroundSuspensionGeneration
        guard await shouldResume(), generation == backgroundSuspensionGeneration,
              !Task.isCancelled else { return false }
        // The caller has already joined the suspension drain. Reopening local
        // admission must not wait for recoverable transfers or remote checks.
        backgroundWorkIsSuspended = false
        return true
    }

    @DownloadActor
    public func resumeAfterBackgroundDrain(
        shouldResume: @MainActor @Sendable () -> Bool
    ) async {
        let generation = backgroundSuspensionGeneration
        guard await shouldResume(), generation == backgroundSuspensionGeneration else { return }
        await resumeRecoverableDownloadsAfterForegrounding(shouldResume: shouldResume)
    }

    @DownloadActor
    public func cancelAndDrainForBackgrounding() async {
        await cancelLongRunningWorkForBackgrounding()
        let records = Array(downloadTasks.values)
            + Array(processingTasks.values)
            + Array(checksumRecoveryTasks.values)
        for record in records {
            // Producer settlement must not be replaced by a canceled waiter's
            // early return. The producer retains ownership through its cleanup.
            await record.task.value
        }
    }

    @DownloadActor
    func resumeRecoverableDownloadsAfterForegrounding(
        shouldResume: @MainActor @Sendable () -> Bool = { true }
    ) async {
        let generation = backgroundSuspensionGeneration
        guard await shouldResume(), generation == backgroundSuspensionGeneration,
              !Task.isCancelled else { return }
        backgroundWorkIsSuspended = false
        let suspendedDownloads = backgroundSuspendedDownloads.compactMap { admittedDownloads[$0] }
        let downloads = await MainActor.run { Array(assuredDownloads.union(suspendedDownloads)) }
        for download in downloads {
            guard await shouldResume(), generation == backgroundSuspensionGeneration,
                  !Task.isCancelled else { return }
            let wasBackgroundSuspended = backgroundSuspendedDownloads.contains(download.id)
            if wasBackgroundSuspended {
                // A join of the canceled producer is not a retry. Wait until its
                // cleanup has released ownership before inspecting recovery state.
                while let work = currentWork(for: download.id) {
                    guard await work.completion.wait() else { return }
                }
                guard await shouldResume(), generation == backgroundSuspensionGeneration,
                      !Task.isCancelled else { return }
            }
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

            guard await shouldResume(), generation == backgroundSuspensionGeneration,
                  !Task.isCancelled else { return }
            if wasBackgroundSuspended {
                // Keep the retry claim through every await above. A stale
                // activation must not consume the next activation's recovery.
                guard backgroundSuspendedDownloads.remove(download.id) != nil else { continue }
            }
            if backgroundSuspendedChecksumRecoveries.remove(download.id) != nil {
                await recoverLocalChecksumFailure(for: download)
                continue
            }
            if state.isFinishedProcessing {
                if completionMetadataRetryDownloadIDs.contains(download.id),
                   hasProcessableLocalArtifact || importedWithoutRetainedSource {
                    await finishDownload(
                        download,
                        recordSuccessfulDownload: false
                    )
                    continue
                }
                if (hasRecoverableFile
                    && download.hasAdmissibleInstalledArtifact())
                    || importedWithoutRetainedSource {
                    continue
                }
                if hasRecoverableFile {
                    await finishDownload(download)
                } else {
                    await self.download(download)
                }
                continue
            }

            guard wasBackgroundSuspended || hasRecoverableFile || state.isFailed || state.isActive || state.isFinishedDownloading else {
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
    private func clearProcessingTask(
        forDownloadID downloadID: DownloadOperationKey,
        processingTaskID: UUID
    ) {
        guard processingTasks[downloadID]?.id == processingTaskID else { return }
        processingTasks[downloadID] = nil
    }

    @DownloadActor
    private func clearChecksumRecoveryTask(
        forDownloadID downloadID: DownloadOperationKey,
        taskID: UUID
    ) {
        guard checksumRecoveryTasks[downloadID]?.id == taskID else { return }
        checksumRecoveryTasks[downloadID] = nil
        checksumRecoveriesReadyForProcessing.remove(downloadID)
        checksumRedownloadAttempted.remove(downloadID)
    }

    @DownloadActor
    private func markDownloadCancelled(_ download: Downloadable, error: Error = CancellationError()) async {
        let isBackgroundSuspension = backgroundSuspendedDownloads.contains(download.id)
        await MainActor.run { [weak self] in
            if let importable = download as? ImportableDownloadable {
                importable.lastImportError = nil
                importable.importProgress = nil
                importable.importStatusText = nil
            }
            self?.finishedDownloads.remove(download)
            if isBackgroundSuspension {
                self?.failedDownloads.remove(download)
                self?.activeDownloads.insert(download)
            } else {
                self?.failedDownloads.insert(download)
                self?.activeDownloads.remove(download)
            }
            download.isFailed = !isBackgroundSuspension
            download.isActive = isBackgroundSuspension
            download.isFinishedDownloading = false
            download.isFinishedProcessing = false
            download.downloadProgress = isBackgroundSuspension
                ? .uninitiated
                : .completed(destinationLocation: nil, etag: nil, error: error)
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
        preservingActiveTransfers: Bool = true,
        preservingCompressedInput: Bool = false
    ) throws {
        if includingDestination {
            try FileManager.default.removeItemIfPresent(
                at: download.localDestination
            )
            try FileManager.default.removeItemIfPresent(
                at: download.checksumVerificationMarkerURL
            )
            pendingInstalledArtifactReceipts[
                download.id
            ] = nil
            try download.removeInstalledArtifactReceipt()
        }
        if !preservingCompressedInput {
            try FileManager.default.removeItemIfPresent(
                at: download.compressedFileURL
            )
        }

        let removed = try download.stagingPaths.removeTemporaryArtifacts(
            preserving: preservingActiveTransfers ? activeTransferStagingURLs : []
        )
        activeTransferStagingURLs.subtract(removed)
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
        guard !Task.isCancelled else { return }
        switch await admit(download) {
        case .owner:
            break
        case .compatibleReplay(let owner):
            await performCompatibleReplay(download, owner: owner) {
                await self.finishDownload(
                    owner,
                    etag: etag,
                    remoteModifiedAt: remoteModifiedAt,
                    finalResponseURL: finalResponseURL,
                    updatesRemoteModifiedAt: updatesRemoteModifiedAt,
                    recordSuccessfulDownload: recordSuccessfulDownload
                )
            }
            return
        case .rejected:
            return
        }

        if await joinCurrentWorkIfNeeded(for: download.id) { return }
        guard !Task.isCancelled, !deferWorkIfBackgroundSuspended(download) else { return }
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
        expectedDownloadAttemptID: UUID? = nil,
        scope: ProcessingScope = .ordinary,
        preparesNativeArtifactOnly: Bool = false
    ) async {
        if scope == .localOnly {
            guard downloadTasks[download.id] == nil,
                  checksumRecoveryTasks[download.id] == nil,
                  processingTasks[download.id].map({ $0.scope == .localOnly }) ?? true else {
                return
            }
        }
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

        // Preserve ownership checks above before publishing cancellation: an
        // obsolete transfer must never reset a replacement producer's state.
        guard !Task.isCancelled, !deferWorkIfBackgroundSuspended(download) else {
            if let transferredFileURL,
               transferredFileURL != download.localDestination {
                activeTransferStagingURLs.remove(transferredFileURL)
                try? FileManager.default.removeItemIfPresent(at: transferredFileURL)
            }
            await markDownloadCancelled(download)
            return
        }
        let processingTaskID = UUID()
        let completion = DownloadWorkCompletion()
        let task = Task { @DownloadActor [weak self] in
            defer { completion.finish() }
            guard let self else { return }
            defer {
                self.clearProcessingTask(
                    forDownloadID: download.id, processingTaskID: processingTaskID
                )
            }
            await self.finishDownloadBody(
                download,
                etag: etag,
                remoteModifiedAt: remoteModifiedAt,
                finalResponseURL: finalResponseURL,
                updatesRemoteModifiedAt: updatesRemoteModifiedAt,
                recordSuccessfulDownload: recordSuccessfulDownload,
                transferredFileURL: transferredFileURL,
                processingTaskID: processingTaskID,
                scope: scope,
                preparesNativeArtifactOnly: preparesNativeArtifactOnly
            )
        }
        processingTasks[download.id] = ProcessingTaskRecord(
            id: processingTaskID, task: task, completion: completion, scope: scope
        )
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
        guard !Task.isCancelled else { return }
        switch await admit(download) {
        case .owner:
            break
        case .compatibleReplay(let owner):
            await performCompatibleReplay(download, owner: owner) {
                await self.recoverLocalChecksumFailure(
                    for: owner,
                    etag: etag,
                    remoteModifiedAt: remoteModifiedAt,
                    updatesRemoteModifiedAt: updatesRemoteModifiedAt
                )
            }
            return
        case .rejected:
            return
        }
        guard !deferWorkIfBackgroundSuspended(download, checksumRecovery: true) else { return }
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

        guard !Task.isCancelled,
              !deferWorkIfBackgroundSuspended(download, checksumRecovery: true) else { return }
        let taskID = UUID()
        let completion = DownloadWorkCompletion()
        let task = Task { @DownloadActor [weak self] in
            defer { completion.finish() }
            guard let self else { return }
            defer {
                clearChecksumRecoveryTask(forDownloadID: download.id, taskID: taskID)
            }
            guard !Task.isCancelled else {
                await markDownloadCancelled(download)
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
        }
        checksumRecoveryTasks[download.id] = ProcessingTaskRecord(
            id: taskID,
            task: task,
            completion: completion
        )
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
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
                download.id
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
        processingTaskID: UUID,
        scope: ProcessingScope = .ordinary,
        preparesNativeArtifactOnly: Bool = false
    ) async {
        await download.waitForDownloadMetadata()
        if scope == .localOnly {
            // Seed reuse is still validated by the normal checksum/receipt path.
            // Restore only while this registered processor owns the destination.
            if !download.hasProcessableLocalArtifact(),
               let cache = download.uiTestArtifactCache,
               let checksum = download.localDestinationChecksum {
                _ = try? cache.restore(checksum: checksum, to: download.localDestination)
            }
            guard !Task.isCancelled else { return }
            let importedWithoutSource = if let importable = download as? ImportableDownloadable,
                                           importable.deleteAfterImport {
                await importable.isImported()
            } else {
                false
            }
            let hasLocalArtifact = hasProcessableArtifactOrPendingReceipt(for: download)
            if importedWithoutSource, !hasLocalArtifact,
               !completionMetadataRetryDownloadIDs.contains(download.id) {
                await markDownloadAsProcessed(download)
                return
            }
            guard hasLocalArtifact || importedWithoutSource else { return }
        }
        if transferredFileURL != nil {
            // A transferred replacement owns a new completion result. Its
            // metadata supersedes any dirty completion values retained from
            // processing the previously installed artifact.
            completionMetadataRetryDownloadIDs.remove(download.id)
        } else if completionMetadataRetryDownloadIDs.contains(download.id) {
            do {
                try Task.checkCancellation()
                let receiptKey = download.id
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
                            download.id
                        ] = nil
                    }
                    await publishCompletionMetadataFailure(error, for: download)
                }
            }
            return
        }
        if scope == .ordinary,
           !recordSuccessfulDownload,
           transferredFileURL == nil,
           finalResponseURL == nil,
           canPrepareNativePinnedArtifact(download),
           let byteCount = download.retainedPinnedArtifactByteCount(),
           !Task.isCancelled,
           processingTasks[download.id]?.id == processingTaskID {
            // Local preparation admits these exact pinned bytes without UI
            // publication. Finish ordinary assurance without
            // hashing them again merely to validate the acquisition receipt.
            await publishSuccessfulCompletion(download, fileSize: byteCount)
            checksumRedownloadAttempted.remove(download.id)
            clearDownloadStatusObservers(forDownloadID: download.id)
            return
        }
        let usesNativePreparation = preparesNativeArtifactOnly
            && scope == .localOnly
            && !recordSuccessfulDownload
            && transferredFileURL == nil
            && canPrepareNativePinnedArtifact(download)
        let verifiedInstalledArtifactReceipt = transferredFileURL == nil
            && !usesNativePreparation
            ? download.verifiedInstalledArtifactReceipt()
            : nil
        let existingInstalledArtifactReceipt = verifiedInstalledArtifactReceipt?.receipt
        if !recordSuccessfulDownload,
           download.localDestinationChecksum == nil,
           let verifiedInstalledArtifactReceipt {
            let importIsComplete = if let importable = download as? ImportableDownloadable {
                await importable.isImported()
            } else {
                true
            }
            if importIsComplete,
               verifiedInstalledArtifactReceipt.isCurrent(for: download),
               !Task.isCancelled,
               processingTasks[download.id]?.id == processingTaskID {
                try? FileManager.default.removeItemIfPresent(
                    at: download.compressedFileURL
                )
                await MainActor.run {
                    download.fileSize = verifiedInstalledArtifactReceipt.receipt.byteCount
                }
                await publishSuccessfulCompletion(download)
                checksumRedownloadAttempted.remove(download.id)
                clearDownloadStatusObservers(forDownloadID: download.id)
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
        var preservesRetainedCompressedInput = false
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
            if compressedCandidateURL == download.compressedFileURL,
               !preservesRetainedCompressedInput {
                try? FileManager.default.removeItemIfPresent(
                    at: download.compressedFileURL
                )
            }
        }

        var finishStartedWithCompressedFile = false
        do {
            try Task.checkCancellation()
            if usesNativePreparation {
                // Keep verification under this processor's cancellation and
                // drain lifetime. It writes only current native checksum proof;
                // the ordinary assurance owner retains UI/receipt publication.
                let checksumTask = Task.detached(priority: .utility) {
                    try download.ensureVerifiedLocalDestinationChecksum()
                }
                try await withTaskCancellationHandler(operation: {
                    try await checksumTask.value
                }, onCancel: {
                    checksumTask.cancel()
                })
                try Task.checkCancellation()
                guard processingTasks[download.id]?.id == processingTaskID else {
                    throw CancellationError()
                }
                Self.localPreparationStageObserver?(.verifiedArtifact)
                try Task.checkCancellation()
                clearDownloadStatusObservers(forDownloadID: download.id)
                return
            }
            let canReuseInstalledArtifact: Bool
            if scope == .localOnly {
                // Retained pinned bytes can be admitted on their own identity.
                // Do not queue native verification behind a read of UI flags.
                canReuseInstalledArtifact = transferredFileURL == nil
                    && compressedCandidateURL == nil
                    && download.localDestinationChecksum != nil
                    && download.hasVerifiedLocalDestinationChecksumMarker()
            } else {
                let alreadyFinished = await MainActor.run {
                    download.isFinishedProcessing && !download.isFailed
                }
                canReuseInstalledArtifact = transferredFileURL == nil
                    && compressedCandidateURL == nil && alreadyFinished
            }
            if canReuseInstalledArtifact {
                let importable = download as? ImportableDownloadable
                let importIsComplete = await importable?.isImported() ?? true
                try Task.checkCancellation()
                guard processingTasks[download.id]?.id == processingTaskID else {
                    throw CancellationError()
                }
                let importedWithoutRetainedSource = importIsComplete
                    && importable?.deleteAfterImport == true
                if (importIsComplete && download.hasAdmissibleInstalledArtifact())
                    || importedWithoutRetainedSource {
                    if scope == .localOnly { Self.localPreparationStageObserver?(.verifiedArtifact) }
                    // Publication is idempotent and remains on the main actor;
                    // its UI state is not authority for the preceding native read.
                    await publishSuccessfulCompletion(download, onlyIfChanged: true)
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

            if let cache = download.uiTestArtifactCache,
               let checksum = download.localDestinationChecksum {
                // Seed bytes have their own verification and atomic publication.
                // Failure to cache cannot fail an otherwise verified download.
                try? cache.publish(checksum: checksum, from: processingFileURL)
                try Task.checkCancellation()
            }

            if let importable = download as? ImportableDownloadable {
                try Task.checkCancellation()
                let importObservationGeneration = importable.beginImportObservation()
                defer {
                    importable.endImportObservation(importObservationGeneration)
                }
                await { @MainActor in
                    importable.lastImportError = nil
                    importable.importProgress = 0
                    importable.importStatusText = "Importing…"
                }()
                let progressHandler: ImportableDownloadable.ImportProgressHandler = {
                    [weak importable] progress, status in
                    Task { @MainActor in
                        guard let importable,
                              importable.importObservationIsCurrent(
                                importObservationGeneration
                              ) else {
                            return
                        }
                        if let progress {
                            importable.importProgress = min(max(progress, 0), 1)
                        }
                        if let status {
                            importable.importStatusText = status
                        }
                    }
                }
                try await withTaskCancellationHandler(operation: {
                    try await importable.importHandler(
                        processingFileURL,
                        progressHandler
                    )
                }, onCancel: {
                    importable.endImportObservation(
                        importObservationGeneration
                    )
                })
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

            let receiptKey = download.id
            if let importable = download as? ImportableDownloadable,
               importable.deleteAfterImport {
                pendingInstalledArtifactReceipts[receiptKey] = nil
                try? download.removeInstalledArtifactReceipt()
            } else {
                let receipt = try download.makeInstalledArtifactReceipt(
                    finalResponseURL: finalResponseURL
                        ?? existingInstalledArtifactReceipt?.finalResponseURL,
                    // Importers may suspend or mutate input. Replacements and
                    // imports always earn new byte proof; only retained plain
                    // files may reuse this operation's validation after stat.
                    reusing: transferredFileURL == nil
                        && compressedCandidateURL == nil
                        && stagedUncompressedFileURL == nil
                        && !(download is ImportableDownloadable)
                        ? verifiedInstalledArtifactReceipt : nil
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
                download.id
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
            if scope == .ordinary,
               requiresCleanChecksumRedownload(error)
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
                preservesRetainedCompressedInput = scope == .localOnly
                    && compressedCandidateURL == download.compressedFileURL
                let preservesInstalledDestination =
                    stagedUncompressedFileURL != nil
                    || finishStartedWithCompressedFile
                // Native preparation only inspected retained input. Canceling
                // it must not delete those bytes or their receipt; ordinary
                // assurance owns any later corruption recovery.
                if processingTasks[download.id]?.id == processingTaskID,
                   !usesNativePreparation {
                    try? removeAllLocalArtifacts(
                        for: download,
                        includingDestination: !preservesInstalledDestination
                            && download.localDestinationChecksum != nil
                            && !download.hasVerifiedLocalDestinationChecksumMarker(),
                        preservingCompressedInput: preservesRetainedCompressedInput
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
                    || error is DownloadChecksumMarkerIOError
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
                if !preservesInstalledDestination,
                   !(error is DownloadChecksumMarkerIOError) {
                    try? FileManager.default.removeItem(
                        at: download.checksumVerificationMarkerURL
                    )
                }
            }
            if shouldDeleteLocal && !preservesInstalledDestination {
                pendingInstalledArtifactReceipts[
                    download.id
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
    private func publishSuccessfulCompletion(
        _ download: Downloadable, onlyIfChanged: Bool = false,
        fileSize: UInt64? = nil
    ) async {
        Self.localPreparationStageObserver?(.publicationRequested)
        await MainActor.run { [weak self] in
            Self.localPreparationStageObserver?(.publicationStarted)
            if let fileSize { download.fileSize = fileSize }
            if let self {
                if self.failedDownloads.contains(download) { self.failedDownloads.remove(download) }
                if self.activeDownloads.contains(download) { self.activeDownloads.remove(download) }
                if !onlyIfChanged || !self.finishedDownloads.contains(download) {
                    self.finishedDownloads.insert(download)
                }
            }
            if download.isFailed { download.isFailed = false }
            if download.isActive { download.isActive = false }
            // Actual processing must notify existing consumers even when
            // rebuilding derived state leaves these flags unchanged. Only
            // reuse of an already-verified artifact is an idempotent replay.
            if !onlyIfChanged || !download.isFinishedDownloading { download.isFinishedDownloading = true }
            if !onlyIfChanged || !download.isFinishedProcessing { download.isFinishedProcessing = true }
            // Every success clears prior terminal errors.
            let etag = download.lastDownloadedETag
            let hasCurrentCompletion: Bool
            if case let .completed(destination, previousETag, error) = download.downloadProgress {
                hasCurrentCompletion = destination == download.localDestination
                    && previousETag == etag && error == nil
            } else {
                hasCurrentCompletion = false
            }
            if !onlyIfChanged || !hasCurrentCompletion {
                download.downloadProgress = .completed(
                    destinationLocation: download.localDestination, etag: etag, error: nil
                )
            }
            if let importable = download as? ImportableDownloadable {
                if importable.lastImportError != nil { importable.lastImportError = nil }
                if importable.importProgress != nil { importable.importProgress = nil }
                if importable.importStatusText != nil { importable.importStatusText = nil }
            }
            Self.localPreparationStageObserver?(.publicationApplied)
        }
        Self.localPreparationStageObserver?(.publicationFinished)
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
                  httpURLResponse.statusCode == 200,
                  downloadResponseAdmissionError(response: response, requestedURL: download.url) == nil else {
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
