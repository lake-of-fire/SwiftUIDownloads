import Foundation
import SwiftUI
import Combine
import Compression
import BackgroundAssets
import Brotli

@globalActor
public actor DownloadActor {
    public static var shared = DownloadActor()
}

fileprivate func errorDescription(from error: Error) -> String {
    let nsError = error as NSError
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

public class Downloadable: ObservableObject, Identifiable, Hashable, Sendable {
    public static var groupIdentifier: String? = nil
    
    public let url: URL
    let mirrorURL: URL?
    public let name: String
    public let localDestination: URL
    /// If the file is compressed, this is the post-decompression checksum.
    public let localDestinationChecksum: String?
    var isFromBackgroundAssetsDownloader: Bool? = nil
    
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
        switch downloadProgress {
        case .completed(_, _, let error):
            if let error = error {
                print(error)
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
        get {
            return UserDefaults.standard.object(forKey: "fileLastDownloadedETag:\(url.absoluteString)") as? String
        }
        set {
            if let newValue = newValue {
                UserDefaults.standard.set(newValue, forKey: "fileLastDownloadedETag:\(url.absoluteString)")
            } else {
                UserDefaults.standard.removeObject(forKey: "fileLastDownloadedETag:\(url.absoluteString)")
            }
        }
    }
    
    @MainActor
    public var lastCheckedETagAt: Date? {
        get {
            return UserDefaults.standard.object(forKey: "fileLastCheckedETagAt:\(url.absoluteString)") as? Date
        }
        set {
            if let newValue = newValue {
                UserDefaults.standard.set(newValue, forKey: "fileLastCheckedETagAt:\(url.absoluteString)")
            } else {
                UserDefaults.standard.removeObject(forKey: "fileLastCheckedETagAt:\(url.absoluteString)")
            }
        }
    }
    
    @MainActor
    public var lastDownloaded: Date? {
        get {
            return UserDefaults.standard.object(forKey: "fileLastDownloadedDate:\(url.absoluteString)") as? Date
        }
        set {
            if let newValue = newValue {
                UserDefaults.standard.set(newValue, forKey: "fileLastDownloadedDate:\(url.absoluteString)")
            } else {
                UserDefaults.standard.removeObject(forKey: "fileLastDownloadedDate:\(url.absoluteString)")
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
        isFromBackgroundAssetsDownloader: Bool? = nil
    ) {
        self.url = url
        self.mirrorURL = mirrorURL
        self.name = name
        self.localDestination = localDestination
        self.localDestinationChecksum = localDestinationChecksum
        self.isFromBackgroundAssetsDownloader = isFromBackgroundAssetsDownloader
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
    
    public var stringContent: String? {
        return try? String(contentsOf: localDestination)
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
        
        return try await withCheckedThrowingContinuation { continuation in
            var cancellable: AnyCancellable?
            cancellable = $isFailed.combineLatest($isFinishedProcessing)
                .filter { $0 || $1 }
                .sink { isFailed, isFinishedProcessing in
                    if isFailed {
//                        continuation.resume(throwing: NSError(domain: "DownloadError", code: 1, userInfo: nil)) // Replace with a specific error if available
                        continuation.resume(returning: false)
                    } else if isFinishedProcessing {
                        continuation.resume(returning: true)
                    } else {
                        continuation.resume(returning: false)
                    }
                    cancellable?.cancel() // Clean up after finishing
                }
        }
    }
    
    @DownloadActor
    public func existsLocally() async -> Bool {
        return await FileManager.default.fileExists(atPath: localDestination.path) || FileManager.default.fileExists(atPath: compressedFileURL.path)
    }
    
    @DownloadActor
    public func fetchRemoteFileSize() async throws {
        if await !existsLocally() {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 6)
            request.httpMethod = "HEAD"
            do {
                let fileSize = try await UInt64(URLSession.shared.data(for: request).1.expectedContentLength)
                try await { @MainActor in
                    self.fileSize = fileSize
                }()
            } catch {
                print("Failed to fetch remote file size for url \(url.absoluteString): \(error)")
                throw(error)
            }
        }
    }
    
    @DownloadActor
    func download() async -> URLResourceDownloadTask {
        let destination = url.pathExtension == "br" ? compressedFileURL : localDestination
        let task = URLResourceDownloadTask(session: URLSession.shared, url: url, destination: destination)
        
        task.publisher.receive(on: DispatchQueue.main).sink(receiveCompletion: { [weak self] completion in
            Task { @MainActor [weak self] in
                switch completion {
                case .failure(let error):
                    debugPrint("Download failed", error)
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
        print("Downloading \(url) to \(destination)")
        
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
            if let fileSize = fileAttributes[FileAttributeKey.size]  {
                return (fileSize as! NSNumber).uint64Value
            } else {
                print("Failed to get a size attribute from path: \(localDestination)")
            }
        } catch {
            print("Failed to get file attributes for local path: \(localDestination) with error: \(error)")
        }
        return 0
    }
    
    @DownloadActor
    func decompressIfNeeded() async throws {
        if FileManager.default.fileExists(atPath: compressedFileURL.path) {
            print("Attempting decompression for \(compressedFileURL)")
            let data = try Data(contentsOf: compressedFileURL)
            // TODO: When dropping iOS 15, switch to native Apple Brotli
            //            let decompressed = try data.decompressed(from: COMPRESSION_BROTLI)
            
            if data.isEmpty {
                print("Data is empty for \(compressedFileURL)")
                do {
                    try FileManager.default.removeItem(at: compressedFileURL)
                } catch {
                    print("Error removing compressedFileURL \(compressedFileURL) \(error.localizedDescription)")
                }
                return
            }
            
            let nsData = NSData(data: data)
            if #available(iOS 16.1, macOS 13.1, *) {
                let decompressed = try data.decompressed(from: COMPRESSION_BROTLI)
                try decompressed.write(to: localDestination, options: .atomic)
            } else {
                guard let decompressed = nsData.brotliDecompressed() else {
                    print("Error decompressing \(compressedFileURL.path)")
                    return
                }
                try decompressed.write(to: localDestination, options: .atomic)
            }
            
            print("Decompressed \(compressedFileURL)")
            let sizeToSet = sizeForLocalFile()
            await { @MainActor [weak self] in
                self?.fileSize = sizeToSet
            }()
            
            do {
                try FileManager.default.removeItem(at: compressedFileURL)
            } catch {
                print("Error removing compressedFileURL \(compressedFileURL) \(error.localizedDescription)")
            }
//        } else {
//            print("No file exists to decompress at \(compressedFileURL)")
        }
    }
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
        localDestinationChecksum: String? = nil
    ) {
//        let filename = filename ?? url.lastPathComponent.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? url.lastPathComponent
        let filename = filename ?? url.lastPathComponent
        // TODO: macos 13+:   Downloadable(url: URL(string: "https://manabi.io/static/dictionaries/furigana.realm.br")!, mirrorURL: nil, name: "Furigana Data", localDestination: folderURL.appending(component: "furigana.realm")),
        self.init(
            url: url,
            mirrorURL: url,
            name: name,
            localDestination: destination.directoryURL.appendingPathComponent(filename),
            localDestinationChecksum: localDestinationChecksum
        )
    }
    
    #warning("Deprecated; remove in favor of above w/ DownloadDirectory")
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

public class DownloadController: NSObject, ObservableObject {
    public static var shared: DownloadController = {
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
    
    private var observation: NSKeyValueObservation?
    private var cancellables = Set<AnyCancellable>()
    
    public override init() {
        super.init()
        
        $activeDownloads
            .removeDuplicates()
//            .print("#")
            .combineLatest($failedDownloads.removeDuplicates())
            .receive(on: DispatchQueue.main)
            .sink { @MainActor [weak self] (active, failed) in
//                debugPrint("# update isPending...", active.isEmpty, failed.isEmpty)
                self?.isPending = !(active.isEmpty && failed.isEmpty)
            }
            .store(in: &cancellables)
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
                    print("DownloadController: deleting orphan \(fileURL)")
                    try FileManager.default.removeItem(at: fileURL)
                }
            }
        }
        
        for orphanDir in potentialOrphanDirs {
            if !seenSavedFiles.contains(where: { $0.path.hasPrefix(orphanDir.path) }) {
                print("DownloadController: deleting orphan directory \(orphanDir)")
                try FileManager.default.removeItem(at: orphanDir)
            }
        }
    }
    
    @DownloadActor
    func delete(download: Downloadable) async throws -> Downloadable {
        await cancelInProgressDownloads(matchingDownloadURL: download.url)
        try FileManager.default.removeItem(at: download.localDestination)
        try await { @MainActor in
            assuredDownloads = assuredDownloads.filter { $0.url != download.url }
            finishedDownloads = finishedDownloads.filter { $0.url != download.url }
            failedDownloads = failedDownloads.filter { $0.url != download.url }
            activeDownloads = activeDownloads.filter { $0.url != download.url }
            download.isActive = false
            download.isFinishedProcessing = false
            download.isFinishedDownloading = false
            download.isFailed = false
            download.downloadProgress = .uninitiated
        }()
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
    @MainActor
    public func ensureDownloaded(download: Downloadable, deletingOrphansIn: [DownloadDirectory] = [], excludingFromDeletion: Set<Downloadable> = Set()) async {
        if assuredDownloads.contains(where: { $0.url == download.url }) && !failedDownloads.contains(where: { $0.url == download.url }) {
            return
        }
        assuredDownloads.insert(download)
        do {
            try await deleteOrphanFiles(in: deletingOrphansIn, excluding: excludingFromDeletion)
        } catch {
            print("ERROR Failed to delete orphan files. \(error)")
        }
        
        if await download.existsLocally() {
            await finishDownload(download)
            if download.lastCheckedETagAt == nil || (download.lastCheckedETagAt ?? Date()).distance(to: Date()) > TimeInterval(60) {//} TimeInterval(60 * 60 * 2) {
                await checkFileModifiedAt(download: download) { [weak self] modified, _, etag in
                    Task { @MainActor [weak self] in
                        download.lastCheckedETagAt = Date()
                        if modified {
                            await self?.download(download, etag: etag)
                        }
                    }
                }
            }
        } else {
            async let task = { @DownloadActor [weak self] in
                await self?.download(download)
            }()
            try? await task
        }
        //        }
    }
    
    @DownloadActor
    public func download(_ download: Downloadable, etag: String? = nil) async {
        download.$isActive.removeDuplicates().receive(on: DispatchQueue.main).sink { @MainActor [weak self] isActive in
            if isActive {
                self?.activeDownloads.insert(download)
            } else {
                self?.activeDownloads.remove(download)
            }
        }.store(in: &cancellables)
        download.$isFailed.removeDuplicates().receive(on: DispatchQueue.main).sink { @MainActor [weak self] isFailed in
            if isFailed {
                self?.finishedDownloads.remove(download)
                self?.failedDownloads.insert(download)
                self?.activeDownloads.remove(download)
            } else {
                self?.failedDownloads.remove(download)
            }
        }.store(in: &cancellables)
        download.$isFinishedDownloading.removeDuplicates().receive(on: DispatchQueue.main).sink { @MainActor [weak self, weak download] isFinishedDownloading in
            if isFinishedDownloading {
                if let download = download {
                    self?.failedDownloads.remove(download)
                    self?.finishedDownloads.insert(download)
                    self?.activeDownloads.remove(download)
                }
                if !(download?.isFromBackgroundAssetsDownloader ?? true) {
                    Task { @MainActor [weak self] in
                        try? await self?.cancelInProgressDownloads(inDownloadExtension: true)
                    }
                }
                if let download = download {
                    Task.detached(priority: .utility) { [weak self] in
                        await self?.finishDownload(download, etag: etag)
                    }
                }
            } else if let download = download {
                self?.finishedDownloads.remove(download)
            }
        }.store(in: &cancellables)
        
        try await {
            let allTasks = await URLSession.shared.allTasks
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
            // Wait for DL to finish or error.
            let task = await download.download()
            // TODO: Does this immediately deinit?
            _ = try? await task.publisher.values.first(where: { progress in
                switch progress {
                case .completed(_, _, _): return true
                default: return false
                }
            })
        }()
    }
    
    @MainActor
    public func cancelInProgressDownloads(matchingDownloadURL downloadURL: URL? = nil) async {
        let allTasks = await URLSession.shared.allTasks
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
                    try FileManager.default.removeItem(at: destination)
                } catch {
                    print("ERROR deleting \(destination.absoluteString): \(error)")
                }
            }
        }
    }
    
    @MainActor
    func cancelInProgressDownloads(inApp: Bool = false, inDownloadExtension: Bool = false) async throws {
        if inApp {
            let allTasks = await URLSession.shared.allTasks
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
            try await Task.detached(priority: .utility) {
                try await download.decompressIfNeeded()
            }.value
         
            // Confirm non-empty
            let resourceValues = try download.localDestination.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = resourceValues.fileSize, fileSize > 0 else {
                async let task = { @MainActor [weak self] in
                    self?.activeDownloads.remove(download)
                    self?.finishedDownloads.remove(download)
                    self?.failedDownloads.insert(download)
                }()
                try await task
                return
            }
//              print("File size = " + ByteCountFormatter().string(fromByteCount: Int64(fileSize)))
            
            async let task = { @MainActor [weak self] in
                download.lastDownloadedETag = etag ?? download.lastDownloadedETag
                self?.failedDownloads.remove(download)
                self?.activeDownloads.remove(download)
                self?.finishedDownloads.insert(download)
                if !download.isFinishedDownloading {
                    print("Download \(download.url) finished downloading to \(download.localDestination)")
                }
                download.isFailed = false
                download.isActive = false
                download.isFinishedDownloading = true
                download.isFinishedProcessing = true
            }()
            try await task
        } catch {
            async let task = { @MainActor [weak self] in
                self?.failedDownloads.insert(download)
                self?.activeDownloads.remove(download)
                self?.finishedDownloads.remove(download)
                try? FileManager.default.removeItem(at: download.compressedFileURL)
                try? FileManager.default.removeItem(at: download.localDestination)
            }()
            try await task
        }
    }
    
    /// Checks if file at given URL is modified.
    /// Using "Last-Modified" header value to compare it with given date.
    @DownloadActor
    public func checkFileModifiedAt(download: Downloadable, completion: @escaping (Bool, Date?, String?) -> Void) {
        var request = URLRequest(url: download.url)
        request.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: request, completionHandler: { (_, response, error) in
            guard let httpURLResponse = response as? HTTPURLResponse,
                  httpURLResponse.statusCode == 200,
                  error == nil else {
                completion(false, nil, nil)
                return
            }
            
            if let modifiedDateString = httpURLResponse.allHeaderFields["Last-Modified"] as? String {
                let dateFormatter = DateFormatter()
                dateFormatter.locale = Locale(identifier: "en_US_POSIX")
                dateFormatter.dateStyle = .medium
                dateFormatter.timeStyle = .long
                dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                guard let modifiedDate = dateFormatter.date(from: modifiedDateString) else {
                    completion(false, nil, httpURLResponse.allHeaderFields["Etag"] as? String)
                    return
                }
                
                if modifiedDate > (download.lastDownloaded ?? Date(timeIntervalSince1970: 0)) {
                    completion(true, modifiedDate, httpURLResponse.allHeaderFields["Etag"] as? String)
                    return
                }
            }
            
            if let etag = httpURLResponse.allHeaderFields["Etag"] as? String, etag != download.lastDownloadedETag {
                completion(true, nil, httpURLResponse.allHeaderFields["Etag"] as? String)
                return
            }
            
            completion(false, nil, httpURLResponse.allHeaderFields["Etag"] as? String)
        }).resume()
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
