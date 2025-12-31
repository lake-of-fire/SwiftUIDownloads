import Foundation

public protocol DownloadableMetadataStore: Sendable {
    func lastDownloadedETag(for url: URL) -> String?
    func setLastDownloadedETag(_ etag: String?, for url: URL)
    func lastCheckedETagAt(for url: URL) -> Date?
    func setLastCheckedETagAt(_ date: Date?, for url: URL)
    func lastDownloaded(for url: URL) -> Date?
    func setLastDownloaded(_ date: Date?, for url: URL)
    func lastModifiedAt(for url: URL) -> Date?
    func setLastModifiedAt(_ date: Date?, for url: URL)
}

public struct UserDefaultsDownloadableMetadataStore: DownloadableMetadataStore, @unchecked Sendable {
    private let userDefaults: UserDefaults
    
    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
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
}
