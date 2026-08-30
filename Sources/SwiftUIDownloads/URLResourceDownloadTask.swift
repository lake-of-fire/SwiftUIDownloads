// Forked from: https://github.com/yukonblue/URLResourceKit/blob/0dda2eadcdf2ccf8323280bb4b3f5a430972134e/Sources/URLResourceKit/URLResourceDownloadTask.swift
import Foundation
import Combine

private func makeRetryAfterDateFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter
}

func parseHTTPDate(_ value: String) -> Date? {
    makeRetryAfterDateFormatter().date(
        from: value.trimmingCharacters(in: .whitespacesAndNewlines)
    )
}

func parseRetryAfterSeconds(_ value: String, now: Date = Date()) -> Double? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let deltaSeconds = Double(trimmed) {
        return max(0, deltaSeconds)
    }
    if let retryDate = makeRetryAfterDateFormatter().date(from: trimmed) {
        return max(0, retryDate.timeIntervalSince(now))
    }
    return nil
}

func retryAfterSeconds(from response: HTTPURLResponse, now: Date = Date()) -> Double? {
    if let headerValue = response.value(forHTTPHeaderField: "Retry-After") {
        return parseRetryAfterSeconds(headerValue, now: now)
    }
    return nil
}

public struct URLResourceDownloadHTTPError: LocalizedError, Sendable {
    public let statusCode: Int
    public let url: URL?
    public let retryAfterSeconds: Double?

    public init(statusCode: Int, url: URL?, retryAfterSeconds: Double? = nil) {
        self.statusCode = statusCode
        self.url = url
        self.retryAfterSeconds = retryAfterSeconds
    }

    public var errorDescription: String? {
        let status = HTTPURLResponse.localizedString(forStatusCode: statusCode)
        if let url {
            if let retryAfterSeconds {
                return "HTTP \(statusCode) (\(status)) for \(url.absoluteString), Retry-After \(Int(retryAfterSeconds))s"
            }
            return "HTTP \(statusCode) (\(status)) for \(url.absoluteString)"
        }
        if let retryAfterSeconds {
            return "HTTP \(statusCode) (\(status)), Retry-After \(Int(retryAfterSeconds))s"
        }
        return "HTTP \(statusCode) (\(status))"
    }
}

public enum URLResourceDownloadTaskProgress { //}: Equatable, CustomStringConvertible {
//    public static func == (lhs: URLResourceDownloadTaskProgress, rhs: URLResourceDownloadTaskProgress) -> Bool {
//        return lhs.description == rhs.de
//    }
    
//    public var id: Int {
//        return description.hashValue
//    }
    
//    public var id: ObjectIdentifier
    
//    public var id: UUID {
//        return uuid
//    }
//
//    public var description: String {
//        switch self {
//        case .uninitiated:
//            return "uninitiated"
//        case .waitingForResponse:
//            return "waitingForResponse"
//        case .downloading(let progress):
//            return "download:\(progress.description)"
//        case .completed(let destinationLocation, let error):
//            return "completed:\(destinationLocation?.absoluteString ?? error?.localizedDescription ?? "unknown")"
//        }
//    }
//
    case uninitiated
    case waitingForResponse
    case downloading(progress: Progress)
    case completed(destinationLocation: URL?, etag: String?, error: Error?)
    
    public var fractionCompleted: Double {
        switch self {
        case .uninitiated:
            return 0
        case .waitingForResponse:
            return 0
        case .downloading(let progress):
            return progress.fractionCompleted
        case .completed(_, _, let error):
            guard error == nil else { return 0 }
            return 1
        }
    }
}

public protocol URLResourceDownloadTaskProtocol {

    typealias PublisherType = AnyPublisher<URLResourceDownloadTaskProgress, Error>

    var taskIdentifier: Int { get }

    var publisher: PublisherType { get }

    func resume()
}

public enum URLResourceDownloadInstallError: LocalizedError {
    case destinationInstallFailed(destination: URL, underlyingError: Error)
    case completedWithoutDownloadedFile(URL)

    public var errorDescription: String? {
        switch self {
        case let .destinationInstallFailed(destination, underlyingError):
            return "Unable to install download at \(destination.path): \(underlyingError.localizedDescription)"
        case let .completedWithoutDownloadedFile(url):
            return "Download completed without producing a file for \(url.absoluteString)"
        }
    }
}

public class URLResourceDownloadTask: NSObject, URLResourceDownloadTaskProtocol, @unchecked Sendable {

    private let session: URLSession
    private let url: URL
    private let destination: URL

    private let downloadTask: URLSessionDownloadTask

    public typealias PublisherType = AnyPublisher<URLResourceDownloadTaskProgress, Error>

    fileprivate let subject: PassthroughSubject<PublisherType.Output, PublisherType.Failure>
    private let terminalLock = NSLock()
    private var didPublishTerminalResult = false
    private var terminalLastModified: Date?

    var responseLastModified: Date? {
        terminalLock.lock()
        defer { terminalLock.unlock() }
        return terminalLastModified
    }

    public var taskIdentifier: Int {
        self.downloadTask.taskIdentifier
    }

    public var publisher: PublisherType {
        self.subject.eraseToAnyPublisher()
    }

    public init(session: URLSession, url: URL, destination: URL) {
        self.session = session
        self.url = url
        self.destination = destination

        self.subject = PassthroughSubject<PublisherType.Output, PublisherType.Failure>()

        self.downloadTask = session.downloadTask(with: self.url)
        self.downloadTask.taskDescription = self.url.absoluteString

        self.subject.send(.uninitiated)
    }

    public func resume() {
        self.downloadTask.delegate = self
        self.subject.send(.waitingForResponse)
        self.downloadTask.resume()
    }

    public func cancel() {
        self.downloadTask.cancel()
    }

    private func publishTerminalResult(
        destinationLocation: URL?,
        etag: String?,
        lastModified: Date?,
        error: Error?
    ) {
        terminalLock.lock()
        guard !didPublishTerminalResult else {
            terminalLock.unlock()
            return
        }
        didPublishTerminalResult = true
        terminalLastModified = lastModified
        terminalLock.unlock()

        subject.send(.completed(
            destinationLocation: destinationLocation,
            etag: etag,
            error: error
        ))
        if let error {
            subject.send(completion: .failure(error))
        } else {
            subject.send(completion: .finished)
        }
    }
}

extension URLResourceDownloadTask: URLSessionDownloadDelegate {
    private func makeHTTPError(from response: HTTPURLResponse) -> URLResourceDownloadHTTPError {
        URLResourceDownloadHTTPError(
            statusCode: response.statusCode,
            url: self.url,
            retryAfterSeconds: retryAfterSeconds(from: response)
        )
    }

    /// Tells the delegate that a download task has finished downloading.
    public func urlSession(_ session: URLSession,
                           downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL
    ) {
        guard session == self.session, downloadTask == self.downloadTask else {
            return
        }

        if let httpResponse = downloadTask.response as? HTTPURLResponse, httpResponse.statusCode < 200 || httpResponse.statusCode > 299 {
            let error = makeHTTPError(from: httpResponse)
            publishTerminalResult(
                destinationLocation: nil,
                etag: nil,
                lastModified: nil,
                error: error
            )
        } else {
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(
                        destination,
                        withItemAt: location
                    )
                } else {
                    try FileManager.default.moveItem(at: location, to: destination)
                }
                publishTerminalResult(
                    destinationLocation: destination,
                    etag: (downloadTask.response as? HTTPURLResponse)?
                        .value(forHTTPHeaderField: "ETag"),
                    lastModified: (downloadTask.response as? HTTPURLResponse)?
                        .value(forHTTPHeaderField: "Last-Modified")
                        .flatMap(parseHTTPDate),
                    error: nil
                )
            } catch {
                publishTerminalResult(
                    destinationLocation: nil,
                    etag: nil,
                    lastModified: nil,
                    error: URLResourceDownloadInstallError
                        .destinationInstallFailed(
                            destination: destination,
                            underlyingError: error
                        )
                )
            }
        }
    }

    /// Periodically informs the delegate about the download’s progress.
    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard session == self.session, downloadTask == self.downloadTask else {
            return
        }
        
#if false
        // This is not very accurate ..
        subject.send(.downloading(progress: downloadTask.progress))
#else
        let progress = Progress(totalUnitCount: max(0, downloadTask.countOfBytesExpectedToReceive))
        progress.completedUnitCount = downloadTask.countOfBytesReceived
        subject.send(.downloading(progress: progress))
#endif
    }
}

extension URLResourceDownloadTask: URLSessionTaskDelegate {

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard session == self.session, downloadTask == self.downloadTask else {
            return
        }

        if let error {
            publishTerminalResult(
                destinationLocation: nil,
                etag: nil,
                lastModified: nil,
                error: error
            )
        } else if let httpResponse = task.response as? HTTPURLResponse, httpResponse.statusCode < 200 || httpResponse.statusCode > 299 {
            let error = URLResourceDownloadHTTPError(
                statusCode: httpResponse.statusCode,
                url: self.url,
                retryAfterSeconds: retryAfterSeconds(from: httpResponse)
            )
            publishTerminalResult(
                destinationLocation: nil,
                etag: nil,
                lastModified: nil,
                error: error
            )
        } else {
            publishTerminalResult(
                destinationLocation: nil,
                etag: nil,
                lastModified: nil,
                error: URLResourceDownloadInstallError
                    .completedWithoutDownloadedFile(url)
            )
        }
    }
}
