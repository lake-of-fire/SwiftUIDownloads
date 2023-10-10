import Foundation
import SwiftUI
import Combine
import Compression
import BackgroundAssets
import Brotli

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

public class Downloadable: ObservableObject, Identifiable, Hashable {
    public static var groupIdentifier: String? = nil
    
    public let url: URL
    let mirrorURL: URL?
    public let name: String
    public let localDestination: URL
    var isFromBackgroundAssetsDownloader: Bool? = nil

    @Published internal var downloadProgress: URLResourceDownloadTaskProgress = .uninitiated
    @Published public var isFailed = false
    @Published public var isActive = false
    @Published public var isFinishedDownloading = false
    @Published public var isFinishedProcessing = false
    
    private var cancellables = Set<AnyCancellable>()
    
    public var id: String {
        return url.absoluteString
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    public var failureMessage: String? {
        switch downloadProgress {
        case .completed(_, let error):
            if let error = error {
                print(error)
                return errorDescription(from: error)
            }
        default: break
        }
        return nil
    }

    public var fractionCompleted: Double {
        return downloadProgress.fractionCompleted
    }
    
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
    
    public init(url: URL, mirrorURL: URL? = nil, name: String, localDestination: URL, isFromBackgroundAssetsDownloader: Bool? = nil) {
        self.url = url
        self.mirrorURL = mirrorURL
        self.name = name
        self.localDestination = localDestination
        self.isFromBackgroundAssetsDownloader = isFromBackgroundAssetsDownloader
    }
    
    public static func == (lhs: Downloadable, rhs: Downloadable) -> Bool {
        return lhs.url == rhs.url && lhs.mirrorURL == rhs.mirrorURL && lhs.name == rhs.name && lhs.localDestination == rhs.localDestination
    }
    
    public var compressedFileURL: URL {
        return localDestination.appendingPathExtension("br")
    }
    
    public var stringContent: String? {
        return try? String(contentsOf: localDestination)
    }
    
    func existsLocally() -> Bool {
        return FileManager.default.fileExists(atPath: localDestination.path) || FileManager.default.fileExists(atPath: compressedFileURL.path)
    }
    
    func download() -> URLResourceDownloadTask {
        let destination = url.pathExtension == "br" ? compressedFileURL : localDestination
        let task = URLResourceDownloadTask(session: URLSession.shared, url: url, destination: destination)
        task.publisher.receive(on: DispatchQueue.main).sink(receiveCompletion: { [weak self] completion in
            switch completion {
            case .failure(let error):
                self?.isFailed = true
                self?.isFinishedDownloading = false
                self?.isActive = false
                self?.downloadProgress = .completed(destinationLocation: nil, error: error)
            case .finished:
                self?.lastDownloaded = Date()
                self?.isFailed = false
                self?.isActive = false
                self?.isFinishedDownloading = true
            }
        }, receiveValue: { [weak self] progress in
            self?.isActive = true
            self?.downloadProgress = progress
            switch progress {
            case .completed(let destinationLocation, let urlError):
                guard urlError == nil, let destinationLocation = destinationLocation else {
                    self?.isFailed = true
                    self?.isFinishedDownloading = false
                    self?.isActive = false
                    return
                }
                self?.lastDownloaded = Date()
                self?.isFinishedDownloading = true
                self?.isActive = false
                self?.isFailed = false
            default:
                break
            }
        }).store(in: &cancellables)
        task.resume()
        return task
    }
    
    func decompressIfNeeded() throws {
        if FileManager.default.fileExists(atPath: compressedFileURL.path) {
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

public extension Downloadable {
    convenience init?(name: String, groupIdentifier: String? = nil, parentDirectoryName: String, filename: String? = nil, downloadMirrors: [URL]) {
        guard let url = downloadMirrors.first else { return nil }
//        let filename = filename ?? url.lastPathComponent.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? url.lastPathComponent
        let filename = filename ?? url.lastPathComponent
        var containerURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        
        if let groupIdentifier = groupIdentifier ?? Self.groupIdentifier, let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) {
            containerURL = sharedContainerURL
        }

        guard let folderURL = containerURL?
            .appendingPathComponent(parentDirectoryName, isDirectory: true) else { return nil }
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
        if Bundle.main.object(forInfoDictionaryKey: "BAInitialDownloadRestrictions") != nil {
            Task.detached { [weak controller] in
                if #available(macOS 13.0, iOS 16.1, *) {
                    BADownloadManager.shared.delegate = controller
                } else { }
            }
        }
        return controller
    }()
    
    @Published public var isPending = false
    @Published public var assuredDownloads = Set<Downloadable>()
    @Published public var activeDownloads = Set<Downloadable>()
    @Published public var finishedDownloads = Set<Downloadable>()
    @Published public var failedDownloads = Set<Downloadable>()
    
    public var unfinishedDownloads: [Downloadable] {
        let downloads: [Downloadable] = Array(Set(activeDownloads).union(Set(failedDownloads)))
        return downloads.sorted(by: { $0.name > $1.name })
    }
    
    private var observation: NSKeyValueObservation?
    private var cancellables = Set<AnyCancellable>()
    
    public override init() {
        super.init()
        
        $activeDownloads.removeDuplicates().combineLatest($failedDownloads.removeDuplicates())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (active, failed) in
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
    
    @MainActor
    func ensureDownloaded(_ downloads: Set<Downloadable>) {
        for download in downloads {
            ensureDownloaded(download: download)
        }
    }
    
    @MainActor
    func delete(download: Downloadable) async throws {
        await cancelInProgressDownloads(matchingDownloadURL: download.url)
        finishedDownloads.remove(download)
        failedDownloads.remove(download)
        activeDownloads.remove(download)
        try FileManager.default.removeItem(at: download.localDestination)
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
    func ensureDownloaded(download: Downloadable) {
        //        for download in assuredDownloads {
        assuredDownloads.insert(download)
        Task.detached { [weak self] in
            if download.existsLocally() {
                self?.finishDownload(download)
                self?.checkFileModifiedAt(download: download) { [weak self] modified, _, etag in
                    if modified {
                        Task { @MainActor [weak self] in
                            self?.download(download, etag: etag)
                        }
                    }
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.download(download)
                }
            }
        }
        //        }
    }
    
    @MainActor
    public func download(_ download: Downloadable, etag: String? = nil) {
        download.$isActive.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] isActive in
            if isActive {
                self?.activeDownloads.insert(download)
            } else {
                self?.activeDownloads.remove(download)
            }
        }.store(in: &cancellables)
        download.$isFailed.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] isFailed in
            if isFailed {
                self?.finishedDownloads.remove(download)
                self?.failedDownloads.insert(download)
                self?.activeDownloads.remove(download)
            } else {
                self?.failedDownloads.remove(download)
            }
        }.store(in: &cancellables)
        download.$isFinishedDownloading.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self, weak download] isFinishedDownloading in
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
                    Task.detached { [weak self] in
                        self?.finishDownload(download, etag: etag)
                    }
                }
            } else if let download = download {
                self?.finishedDownloads.remove(download)
            }
        }.store(in: &cancellables)

        Task.detached {
            let allTasks = await URLSession.shared.allTasks
            if allTasks.first(where: { $0.taskDescription == download.url.absoluteString }) != nil {
                // Task exists.
                return
            }
            
            if Bundle.main.object(forInfoDictionaryKey: "BAInitialDownloadRestrictions") != nil {
                if #available(macOS 13, iOS 16.1, *) {
                    Task.detached {
                        do {
                            if let baDL = download.backgroundAssetDownload(applicationGroupIdentifier: "group.io.manabi.shared"), try await BADownloadManager.shared.currentDownloads.contains(baDL) {
                                if #available(iOS 16.4, macOS 13.3, *) {
                                    if !baDL.isEssential {
                                        try BADownloadManager.shared.startForegroundDownload(baDL)
                                    }
                                } else {
                                    try BADownloadManager.shared.startForegroundDownload(baDL)
                                }
                                return
                            }
                        } catch {
                            print("Unable to download background asset...")
                        }
                    }
                } else { }
            }
            
            download.isFromBackgroundAssetsDownloader = false
            Task { @MainActor in
                _ = download.download()
            }
        }
    }
    
    public func cancelInProgressDownloads(matchingDownloadURL downloadURL: URL? = nil) async {
        let allTasks = await URLSession.shared.allTasks
        for task in allTasks.filter({ task in assuredDownloads.contains(where: {
            if let downloadURL = downloadURL, $0.url != downloadURL {
                return false
            }
            return $0.localDestination.absoluteString == (task.taskDescription ?? "")
        }) }) {
            task.cancel()
        }
    }
    
    func cancelInProgressDownloads(inApp: Bool = false, inDownloadExtension: Bool = false) async throws {
        if inApp {
            let allTasks = await URLSession.shared.allTasks
            for task in allTasks.filter({ task in assuredDownloads.contains(where: { $0.localDestination.absoluteString == (task.taskDescription ?? "") }) }) {
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
    
    public func finishDownload(_ download: Downloadable, etag: String? = nil) {
        do {
            try download.decompressIfNeeded()

            // Confirm non-empty
            let resourceValues = try download.localDestination.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = resourceValues.fileSize, fileSize > 0 else {
                Task { @MainActor [weak self] in
                    download.lastDownloadedETag = etag ?? download.lastDownloadedETag
                    
                    self?.activeDownloads.remove(download)
                    self?.finishedDownloads.remove(download)
                    self?.failedDownloads.insert(download)
                }
                return
            }
//              print("File size = " + ByteCountFormatter().string(fromByteCount: Int64(fileSize)))
            
            Task { @MainActor [weak self] in
                self?.failedDownloads.remove(download)
                self?.activeDownloads.remove(download)
                self?.finishedDownloads.insert(download)
                download.isFinishedProcessing = true
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.failedDownloads.insert(download)
                self?.activeDownloads.remove(download)
                self?.finishedDownloads.remove(download)
                try? FileManager.default.removeItem(at: download.compressedFileURL)
                try? FileManager.default.removeItem(at: download.localDestination)
            }
        }
    }
    
    /// Checks if file at given URL is modified.
    /// Using "Last-Modified" header value to compare it with given date.
    func checkFileModifiedAt(download: Downloadable, completion: @escaping (Bool, Date?, String?) -> Void) {
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
                
                if modifiedDate > download.lastDownloaded ?? Date(timeIntervalSince1970: 0) {
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

@available(macOS 13.0, iOS 16.1, *)
extension DownloadController: BADownloadManagerDelegate {
    @MainActor
    public func download(_ download: BADownload, didWriteBytes bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite totalExpectedBytes: Int64) {
        Task { @MainActor in
            guard let downloadable = assuredDownloads.downloadable(forDownload: download) else { return }
            let progress = Progress(totalUnitCount: totalExpectedBytes)
            progress.completedUnitCount = totalBytesWritten
            downloadable.downloadProgress = .downloading(progress: progress)
            downloadable.isFromBackgroundAssetsDownloader = true
            finishedDownloads.remove(downloadable)
            failedDownloads.remove(downloadable)
            activeDownloads.insert(downloadable)
            do {
                try await cancelInProgressDownloads(inApp: true)
            } catch {
            }
        }
    }
    
    @MainActor
    public func downloadDidBegin(_ download: BADownload) {
        Task { @MainActor in
            guard let downloadable = assuredDownloads.downloadable(forDownload: download) else { return }
            downloadable.downloadProgress = .downloading(progress: Progress())
            downloadable.isFromBackgroundAssetsDownloader = true
            finishedDownloads.remove(downloadable)
            failedDownloads.remove(downloadable)
            activeDownloads.insert(downloadable)
        }
    }
    
    @MainActor
    public func download(_ download: BADownload, finishedWithFileURL fileURL: URL) {
        Task { @MainActor in
            BADownloadManager.shared.withExclusiveControl { [weak self] acquiredLock, error in
                guard acquiredLock, error == nil else { return }
                if let downloadable = self?.assuredDownloads.downloadable(forDownload: download) {
                    downloadable.isFromBackgroundAssetsDownloader = true
                    let destination = downloadable.url.pathExtension == "br" ? downloadable.compressedFileURL : downloadable.localDestination
                    do {
                        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try FileManager.default.moveItem(at: fileURL, to: destination)
                    } catch { }
                    Task.detached { [weak self] in
                        self?.finishDownload(downloadable)
                        Task { @MainActor [weak self] in
                            try await self?.cancelInProgressDownloads(inApp: true)
                        }
                    }
                }
            }
        }
    }
    
    @MainActor
    public func download(_ download: BADownload, failedWithError error: Error) {
        if let downloadable = assuredDownloads.downloadable(forDownload: download) {
            Task { @MainActor in
                downloadable.downloadProgress = .completed(destinationLocation: nil, error: error)
                finishedDownloads.remove(downloadable)
                activeDownloads.remove(downloadable)
                failedDownloads.insert(downloadable)
            }
        }
        if Bundle.main.object(forInfoDictionaryKey: "BAInitialDownloadRestrictions") != nil {
            Task { @MainActor in
                do {
                    if #available(iOS 16.4, macOS 13.3, *) {
                        if !download.isEssential {
                            try BADownloadManager.shared.startForegroundDownload(download)
                        }
                    } else {
                        try BADownloadManager.shared.startForegroundDownload(download)
                    }
                } catch { }
            }
        }
    }
}

@available(macOS 13.0, iOS 16.1, *)
public extension Set<Downloadable> {
    func downloadable(forDownload download: BADownload) -> Downloadable? {
        for downloadable in DownloadController.shared.assuredDownloads {
            if downloadable.localDestination.absoluteString == download.identifier {
                return downloadable
            }
        }
        return nil
    }
}
