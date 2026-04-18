import Foundation
import SwiftUI
import Combine
import BackgroundAssets
import CryptoKit

private struct ChecksumVerificationMarker: Codable {
    let expectedChecksum: String
    let fileSize: UInt64
    let modificationTimeIntervalSince1970: TimeInterval
}

private func sha1Checksum(for fileURL: URL) throws -> String {
    let fileHandle = try FileHandle(forReadingFrom: fileURL)
    defer { try? fileHandle.close() }

    var hasher = Insecure.SHA1()
    while autoreleasepool(invoking: {
        let data = fileHandle.readData(ofLength: 64 * 1024)
        guard !data.isEmpty else { return false }
        hasher.update(data: data)
        return true
    }) {}

    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

// TODO: Extract download state transitions + import handling into a small processor/state machine once behavior stabilizes.

@globalActor
public actor DownloadActor {
    public static let shared = DownloadActor()
}

fileprivate func errorDescription(from error: Error) -> String {
    let nsError = error as NSError
    if let httpError = error as? URLResourceDownloadHTTPError {
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
        return "Unknown Error"
    }
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
    
    public let url: URL
    let mirrorURL: URL?
    public let name: String
    public let localDestination: URL
    /// If the file is compressed, this is the post-decompression checksum.
    public let localDestinationChecksum: String?
    var isFromBackgroundAssetsDownloader: Bool? = nil
    public let metadataStore: any DownloadableMetadataStore
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
    
    public var id: String {
        return url.absoluteString
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
        get { metadataStore.lastDownloadedETag(for: url) }
        set {
            let value = newValue
            Task { @DownloadActor in
                metadataStore.setLastDownloadedETag(value, for: url)
            }
        }
    }
    
    @MainActor
    public var lastCheckedETagAt: Date? {
        get { metadataStore.lastCheckedETagAt(for: url) }
        set {
            let value = newValue
            Task { @DownloadActor in
                metadataStore.setLastCheckedETagAt(value, for: url)
            }
        }
    }
    
    @MainActor
    public var lastDownloaded: Date? {
        get { metadataStore.lastDownloaded(for: url) }
        set {
            let value = newValue
            Task { @DownloadActor in
                metadataStore.setLastDownloaded(value, for: url)
            }
        }
    }

    @MainActor
    public var lastModifiedAt: Date? {
        get { metadataStore.lastModifiedAt(for: url) }
        set {
            let value = newValue
            Task { @DownloadActor in
                metadataStore.setLastModifiedAt(value, for: url)
            }
        }
    }
    
    /// localDestinationChecksum is currently NOT checked.
    // TODO: Verify localDestinationChecksum after download and decompress (was originally added for use in Cache)
    public init(
        url: URL,
        mirrorURL: URL? = nil,
        name: String,
        localDestination: URL,
        localDestinationChecksum: String? = nil,
        isFromBackgroundAssetsDownloader: Bool? = nil,
        metadataStore: (any DownloadableMetadataStore)? = nil
    ) {
        self.url = url
        self.mirrorURL = mirrorURL
        self.name = name
        self.localDestination = localDestination
        self.localDestinationChecksum = localDestinationChecksum
        self.isFromBackgroundAssetsDownloader = isFromBackgroundAssetsDownloader
        self.metadataStore = metadataStore ?? UserDefaultsDownloadableMetadataStore()
    }
    
    public static func == (lhs: Downloadable, rhs: Downloadable) -> Bool {
        return lhs.url == rhs.url && lhs.mirrorURL == rhs.mirrorURL && lhs.name == rhs.name && lhs.localDestination == rhs.localDestination && lhs.localDestinationChecksum == rhs.localDestinationChecksum
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
        let fileSize = (fileAttributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard fileSize > 0 else { return false }
        let modificationDate = (fileAttributes[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        guard let verification = try? loadChecksumVerificationMarker() else { return false }
        return verification.expectedChecksum == expectedChecksum
            && verification.fileSize == fileSize
            && verification.modificationTimeIntervalSince1970 == modificationDate.timeIntervalSince1970
    }

    public func isReadyForImmediateLocalRead() -> Bool {
        if localDestinationChecksum == nil {
            return FileManager.default.fileExists(atPath: localDestination.path)
        }
        return hasVerifiedLocalDestinationChecksumMarker()
    }

    public func ensureVerifiedLocalDestinationChecksum() throws {
        guard let expectedChecksum = localDestinationChecksum?.lowercased() else { return }
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: localDestination.path)
        let fileSize = (fileAttributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard fileSize > 0 else {
            throw NSError(
                domain: "Downloadable",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot verify empty file at \(localDestination.path)"]
            )
        }
        let modificationDate = (fileAttributes[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)

        if let verification = try loadChecksumVerificationMarker(),
           verification.expectedChecksum == expectedChecksum,
           verification.fileSize == fileSize,
           verification.modificationTimeIntervalSince1970 == modificationDate.timeIntervalSince1970 {
            return
        }

        let actualChecksum = try sha1Checksum(for: localDestination)
        guard actualChecksum == expectedChecksum else {
            try? FileManager.default.removeItem(at: checksumVerificationMarkerURL)
            throw NSError(
                domain: "Downloadable",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "SHA-1 mismatch. Expected \(expectedChecksum), got \(actualChecksum)"]
            )
        }

        let marker = ChecksumVerificationMarker(
            expectedChecksum: expectedChecksum,
            fileSize: fileSize,
            modificationTimeIntervalSince1970: modificationDate.timeIntervalSince1970
        )
        let data = try JSONEncoder().encode(marker)
        try data.write(to: checksumVerificationMarkerURL, options: .atomic)
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
            return isFinishedProcessing // Return `true` if finished, `false` if failed
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
            || FileManager.default.fileExists(atPath: compressedFileURL.path)
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
    func download(session: URLSession) async -> URLResourceDownloadTask {
        let destination = url.pathExtension == "br" ? compressedFileURL : localDestination
        let task = URLResourceDownloadTask(session: session, url: url, destination: destination)
        
        task.publisher.receive(on: DispatchQueue.main).sink(receiveCompletion: { [weak self] completion in
            Task { @MainActor [weak self] in
                switch completion {
                case .failure(let error):
                    self?.isFailed = true
                    self?.isFinishedDownloading = false
                    self?.isActive = false
                    self?.downloadProgress = .completed(destinationLocation: nil, etag: nil, error: error)
                case .finished:
                    self?.finishedDownloadingDuringCurrentLaunchAt = Date()
                    self?.lastDownloaded = Date()
                    self?.isFailed = false
                    self?.isActive = false
                    self?.isFinishedDownloading = true
                }
            }
        }, receiveValue: { [weak self] progress in
//            Task { @MainActor [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
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
                case .completed(_, _, _):
                    isActive = true
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
        
        task.resume()
        return task
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

    @DownloadActor
    func decompressIfNeeded() async throws {
        if FileManager.default.fileExists(atPath: compressedFileURL.path) {
            let compressedFileSize = (try? compressedFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if compressedFileSize == 0 {
                try? FileManager.default.removeItem(at: compressedFileURL)
                return
            }

            let temporaryOutputURL = localDestination.appendingPathExtension("decompressing")
            try? FileManager.default.removeItem(at: temporaryOutputURL)
            defer {
                try? FileManager.default.removeItem(at: temporaryOutputURL)
            }

            try decompressBrotliFile(at: compressedFileURL, to: temporaryOutputURL)

            if FileManager.default.fileExists(atPath: localDestination.path) {
                _ = try FileManager.default.replaceItemAt(localDestination, withItemAt: temporaryOutputURL)
            } else {
                try FileManager.default.moveItem(at: temporaryOutputURL, to: localDestination)
            }

            let sizeToSet = sizeForLocalFile()
            await { @MainActor [weak self] in
                self?.fileSize = sizeToSet
            }()

            try? FileManager.default.removeItem(at: compressedFileURL)
//        } else {
//            print("No file exists to decompress at \(compressedFileURL)")
        }
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
}

public extension Downloadable {
    convenience init(
        name: String,
        destination: DownloadDirectory,
        filename: String? = nil,
        url: URL,
        localDestinationChecksum: String? = nil,
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

public class DownloadController: NSObject, ObservableObject, @unchecked Sendable {
    typealias DownloadAttemptExecutor = @Sendable (_ download: Downloadable, _ session: URLSession) async throws -> Void

    public static let shared: DownloadController = {
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
        let downloads: [Downloadable] = Array(Set(activeDownloads).union(Set(failedDownloads)))
        return downloads.sorted(by: { $0.name > $1.name })
    }

    @MainActor
    public var unfinishedDownloadsIncludingImports: [Downloadable] {
        let importing = finishedDownloads.filter { !$0.isFinishedProcessing }
        let downloads = Set(activeDownloads)
            .union(Set(failedDownloads))
            .union(Set(importing))
        return Array(downloads).sorted(by: { $0.name > $1.name })
    }
    
    private var observation: NSKeyValueObservation?
    private var cancellables = Set<AnyCancellable>()
    private var downloadStatusCancellables = [String: Set<AnyCancellable>]()
    private let session: URLSession
    private let attemptExecutor: DownloadAttemptExecutor?
    private let retryPolicyProvider: @Sendable () -> DownloadRetryPolicy
    
    public override init() {
        self.session = .shared
        self.attemptExecutor = nil
        self.retryPolicyProvider = { .default }
        super.init()
        configureStateObservers()
    }

    public init(session: URLSession) {
        self.session = session
        self.attemptExecutor = nil
        self.retryPolicyProvider = { .default }
        super.init()
        configureStateObservers()
    }

    init(
        session: URLSession,
        attemptExecutor: DownloadAttemptExecutor?,
        retryPolicyProvider: @escaping @Sendable () -> DownloadRetryPolicy = { .default }
    ) {
        self.session = session
        self.attemptExecutor = attemptExecutor
        self.retryPolicyProvider = retryPolicyProvider
        super.init()
        configureStateObservers()
    }

    private func configureStateObservers() {
        $activeDownloads
            .removeDuplicates()
//            .print("#")
            .combineLatest($failedDownloads.removeDuplicates())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (active, failed) in
                Task { @MainActor [weak self] in
//                    debugPrint("# update isPending...", active.isEmpty, failed.isEmpty)
                    self?.isPending = !(active.isEmpty && failed.isEmpty)
                }
            }
            .store(in: &cancellables)
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
        
        let saveFiles = await Set<URL>(assuredDownloads.union(excluding).map { $0.localDestination })
            .union(Set(assuredDownloads.union(excluding).map { $0.compressedFileURL }))
        
        var potentialOrphanDirs = Set<URL>()
        var seenSavedFiles = Set<URL>()
        
        for location in locations {
            let dir = location.directoryURL
            let path = dir.path
            let enumerator = FileManager.default.enumerator(atPath: path)
            
            while let filename = enumerator?.nextObject() as? String {
                let fileURL = URL(fileURLWithPath: filename, relativeTo: dir).absoluteURL
                
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
    }
    
    @DownloadActor
    func delete(download: Downloadable) async throws -> Downloadable {
        await cancelInProgressDownloads(matchingDownloadURL: download.url)
        clearDownloadStatusObservers(forDownloadID: download.id)
        try FileManager.default.removeItemIfPresent(at: download.localDestination)
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
    private enum DownloadAttemptExecutionError: LocalizedError {
        case completedStateMissing(url: URL)

        var errorDescription: String? {
            switch self {
            case .completedStateMissing(let url):
                return "Download finished without a terminal state for \(url.absoluteString)"
            }
        }
    }

    @DownloadActor
    private func clearDownloadStatusObservers(forDownloadID downloadID: String) {
        guard let cancellables = downloadStatusCancellables.removeValue(forKey: downloadID) else {
            return
        }
        cancellables.forEach { $0.cancel() }
    }

    @DownloadActor
    private func resetDownloadStatusObservers(for download: Downloadable, etag: String?) {
        clearDownloadStatusObservers(forDownloadID: download.id)

        var perDownloadCancellables = Set<AnyCancellable>()
        download.$isActive.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] isActive in
            Task { @MainActor [weak self] in
                if isActive {
                    self?.activeDownloads.insert(download)
                } else {
                    self?.activeDownloads.remove(download)
                }
            }
        }.store(in: &perDownloadCancellables)
        download.$isFailed.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] isFailed in
            Task { @MainActor [weak self] in
                if isFailed {
                    self?.finishedDownloads.remove(download)
                    self?.failedDownloads.insert(download)
                    self?.activeDownloads.remove(download)
                } else {
                    self?.failedDownloads.remove(download)
                }
            }
        }.store(in: &perDownloadCancellables)
        download.$isFinishedDownloading.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self, weak download] isFinishedDownloading in
            Task { @MainActor [weak self, weak download] in
                if isFinishedDownloading {
                    if let download = download {
                        self?.failedDownloads.remove(download)
                        self?.finishedDownloads.insert(download)
                        self?.activeDownloads.remove(download)
                    }
                    if !(download?.isFromBackgroundAssetsDownloader ?? true) {
                        try? await self?.cancelInProgressDownloads(inDownloadExtension: true)
                    }
                    if let download = download {
                        Task.detached(priority: .utility) { [weak self] in
                            await self?.finishDownload(download, etag: etag)
                        }
                    }
                } else if let download = download {
                    self?.finishedDownloads.remove(download)
                }
            }
        }.store(in: &perDownloadCancellables)

        downloadStatusCancellables[download.id] = perDownloadCancellables
    }

    @DownloadActor
    private func runSingleDownloadAttempt(_ download: Downloadable) async throws {
        if let attemptExecutor {
            try await attemptExecutor(download, session)
            return
        }

        let task = await download.download(session: session)
        guard let completedState = try await task.publisher.values.first(where: { progress in
            if case .completed = progress {
                return true
            }
            return false
        }) else {
            throw DownloadAttemptExecutionError.completedStateMissing(url: download.url)
        }
        switch completedState {
        case .completed(_, _, let error):
            if let error {
                throw error
            }
        default:
            throw DownloadAttemptExecutionError.completedStateMissing(url: download.url)
        }
    }

    @MainActor
    public func ensureDownloaded(download: Downloadable, deletingOrphansIn: [DownloadDirectory] = [], excludingFromDeletion: Set<Downloadable> = Set()) async {
        if assuredDownloads.contains(where: { $0.url == download.url }) && !failedDownloads.contains(where: { $0.url == download.url }) {
            return
        }
        assuredDownloads.insert(download)
        do {
            try await deleteOrphanFiles(in: deletingOrphansIn, excluding: excludingFromDeletion)
        } catch { }
        
        let isImported = await (download as? ImportableDownloadable)?.isImported() ?? false
        let localExists = await download.existsLocally()
        if localExists || isImported {
            if isImported {
                await markDownloadAsProcessed(download)
            } else {
                await finishDownload(download)
            }
            let updateCheckInterval = TimeInterval(60 * 60 * 2)
            if download.shouldCheckForUpdates,
               download.lastCheckedETagAt == nil
                || (download.lastCheckedETagAt ?? Date()).distance(to: Date()) > updateCheckInterval {
                let (modified, modifiedAt, etag) = await checkFileModifiedAt(download: download)
                download.lastCheckedETagAt = Date()
                if let modifiedAt {
                    download.lastModifiedAt = modifiedAt
                }
                if modified {
                    await self.download(download, etag: etag)
                }
            }
        } else {
            await self.download(download)
        }
        //        }
    }
    
    @DownloadActor
    public func download(_ download: Downloadable, etag: String? = nil) async {
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
        resetDownloadStatusObservers(for: download, etag: etag)
        
        if download.url.isFileURL {
            await { @MainActor in
                download.isActive = true
                download.isFailed = false
            }()
            do {
                if download.url == download.localDestination {
                    guard FileManager.default.fileExists(atPath: download.localDestination.path) else {
                        throw NSError(domain: "DownloadController", code: 404, userInfo: [
                            NSLocalizedDescriptionKey: "Local file missing for import at \(download.localDestination.path)"
                        ])
                    }
                    await finishDownload(download, etag: etag)
                    return
                }
                try FileManager.default.createDirectory(
                    at: download.localDestination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: download.localDestination.path) {
                    try FileManager.default.removeItemIfPresent(at: download.localDestination)
                }
                try FileManager.default.copyItem(at: download.url, to: download.localDestination)
                await finishDownload(download, etag: etag)
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
            }
            return
        }

        let allTasks = await session.allTasks
        if allTasks.first(where: { $0.taskDescription == download.url.absoluteString }) != nil {
            // Task exists.
            return
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
        while true {
            if Task.isCancelled {
                terminalAttemptError = CancellationError()
                break
            }

            do {
                try await runSingleDownloadAttempt(download)
                break
            } catch {
                let shouldRetry = attempt < retryPolicy.maxAttempts && isRetryableDownloadError(error)
                guard shouldRetry else {
                    terminalAttemptError = error
                    break
                }

                let delaySeconds = retryPolicy.retryDelaySeconds(
                    forAttempt: attempt + 1,
                    error: error
                )
                let nanoseconds = UInt64(delaySeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)

                await { @MainActor in
                    download.isFailed = false
                    download.isActive = false
                    download.isFinishedDownloading = false
                    download.downloadProgress = .uninitiated
                }()
                attempt += 1
            }
        }

        if let terminalAttemptError {
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
        }
    }
    
    @MainActor
    public func cancelInProgressDownloads(matchingDownloadURL downloadURL: URL? = nil) async {
        let allTasks = await session.allTasks
        for (task, download) in allTasks.map({ task in
            let download = assuredDownloads.first(where: {
                if let downloadURL = downloadURL, $0.url != downloadURL {
                    return false
                }
                return $0.url.absoluteString == (task.taskDescription ?? "")
            })
            return (task, download)
        }) {
            task.cancel()
                if let destination = download?.localDestination {
                    do {
                        try FileManager.default.removeItemIfPresent(at: destination)
                    } catch { }
            }
        }
    }
    
    @MainActor
    func cancelInProgressDownloads(inApp: Bool = false, inDownloadExtension: Bool = false) async throws {
        if inApp {
            let allTasks = await session.allTasks
            for task in allTasks.filter({ task in assuredDownloads.contains(where: { $0.url.absoluteString == (task.taskDescription ?? "") }) }) {
                task.cancel()
            }
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
    public func finishDownload(_ download: Downloadable, etag: String? = nil) async {
        do {
            let alreadyFinished = await MainActor.run { download.isFinishedProcessing }
            if alreadyFinished {
                clearDownloadStatusObservers(forDownloadID: download.id)
                return
            }
            if let importable = download as? ImportableDownloadable,
               FileManager.default.fileExists(atPath: download.compressedFileURL.path) {
                await { @MainActor in
                    importable.importStatusText = "Expanding…"
                    if importable.importProgress == nil {
                        let downloadFraction = download.downloadProgress.fractionCompleted
                        importable.importProgress = min(downloadFraction, 0.999)
                    }
                }()
            }
            try await Task.detached(priority: .utility) {
                try await download.decompressIfNeeded()
            }.value
         
            // Confirm non-empty
            guard let resourceValues = try? download.localDestination.resourceValues(forKeys: [.fileSizeKey]),
                  let fileSize = resourceValues.fileSize, fileSize > 0 else {
                if let importable = download as? ImportableDownloadable,
                   await importable.isImported() {
                    await markDownloadAsProcessed(download)
                    clearDownloadStatusObservers(forDownloadID: download.id)
                    return
                }
                await MainActor.run { [weak self] in
                    self?.activeDownloads.remove(download)
                    self?.finishedDownloads.remove(download)
                    self?.failedDownloads.insert(download)
                }
                clearDownloadStatusObservers(forDownloadID: download.id)
                return
            }

            try download.ensureVerifiedLocalDestinationChecksum()
            
            if let importable = download as? ImportableDownloadable {
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
                try await importable.importHandler(download.localDestination, progressHandler)
                if importable.deleteAfterImport {
                    try? FileManager.default.removeItem(at: download.localDestination)
                }
            }
//              print("File size = " + ByteCountFormatter().string(fromByteCount: Int64(fileSize)))
            
            await MainActor.run { [weak self] in
                download.lastDownloadedETag = etag ?? download.lastDownloadedETag
                self?.failedDownloads.remove(download)
                self?.activeDownloads.remove(download)
                self?.finishedDownloads.insert(download)
                download.isFailed = false
                download.isActive = false
                download.isFinishedDownloading = true
                download.isFinishedProcessing = true
                if let importable = download as? ImportableDownloadable {
                    importable.importProgress = nil
                    importable.importStatusText = nil
                }
            }
            clearDownloadStatusObservers(forDownloadID: download.id)
        } catch {
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
                download.isFinishedProcessing = true
                let shouldDeleteLocal = (download as? ImportableDownloadable)?.deleteAfterImport ?? true
                try? FileManager.default.removeItem(at: download.compressedFileURL)
                if shouldDeleteLocal {
                    try? FileManager.default.removeItem(at: download.localDestination)
                }
            }
            clearDownloadStatusObservers(forDownloadID: download.id)
        }
    }

    @DownloadActor
    private func markDownloadAsProcessed(_ download: Downloadable) async {
        await { @MainActor [weak self] in
            download.isFailed = false
            download.isActive = false
            download.isFinishedDownloading = true
            download.isFinishedProcessing = true
            self?.failedDownloads.remove(download)
            self?.activeDownloads.remove(download)
            self?.finishedDownloads.insert(download)
        }()
    }
    
    /// Checks if file at given URL is modified.
    /// Using "Last-Modified" header value to compare it with given date.
    @DownloadActor
    public func checkFileModifiedAt(download: Downloadable) async -> (Bool, Date?, String?) {
        var request = URLRequest(url: download.url)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await session.data(for: request)
            guard let httpURLResponse = response as? HTTPURLResponse,
                  httpURLResponse.statusCode == 200 else {
                return (false, nil, nil)
            }

            let etag = httpURLResponse.allHeaderFields["Etag"] as? String
            let baseline = await MainActor.run {
                download.lastModifiedAt ?? download.lastDownloaded ?? Date(timeIntervalSince1970: 0)
            }
            let lastDownloadedETag = await MainActor.run {
                download.lastDownloadedETag
            }

            if let modifiedDateString = httpURLResponse.allHeaderFields["Last-Modified"] as? String {
                let dateFormatter = DateFormatter()
                dateFormatter.locale = Locale(identifier: "en_US_POSIX")
                dateFormatter.dateStyle = .medium
                dateFormatter.timeStyle = .long
                dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                if let modifiedDate = dateFormatter.date(from: modifiedDateString),
                   modifiedDate > baseline {
                    return (true, modifiedDate, etag)
                }
            }

            if let etag, etag != lastDownloadedETag {
                return (true, nil, etag)
            }

            return (false, nil, etag)
        } catch {
            return (false, nil, nil)
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
