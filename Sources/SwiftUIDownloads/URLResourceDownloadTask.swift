// Forked from: https://github.com/yukonblue/URLResourceKit/blob/0dda2eadcdf2ccf8323280bb4b3f5a430972134e/Sources/URLResourceKit/URLResourceDownloadTask.swift
import Foundation
import Combine

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
    case completed(destinationLocation: URL?, error: Error?)
}

public protocol URLResourceDownloadTaskProtocol {

    typealias PublisherType = AnyPublisher<URLResourceDownloadTaskProgress, URLError>

    var taskIdentifier: Int { get }

    var publisher: PublisherType { get }

    func resume()
}

public class URLResourceDownloadTask: NSObject, URLResourceDownloadTaskProtocol {

    private let session: URLSession
    private let url: URL
    private let destination: URL

    private let downloadTask: URLSessionDownloadTask

    public typealias PublisherType = AnyPublisher<URLResourceDownloadTaskProgress, URLError>

    fileprivate let subject: PassthroughSubject<PublisherType.Output, PublisherType.Failure>

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
        self.downloadTask.resume()
        self.subject.send(.waitingForResponse)
    }
}

extension URLResourceDownloadTask: URLSessionDownloadDelegate {

    /// Tells the delegate that a download task has finished downloading.
    public func urlSession(_ session: URLSession,
                           downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL
    ) {
        guard session == self.session, downloadTask == self.downloadTask else {
            return
        }

        if let httpResponse = downloadTask.response as? HTTPURLResponse, httpResponse.statusCode < 200 || httpResponse.statusCode > 299 {
            let error = URLError(.fileDoesNotExist)
            subject.send(.completed(destinationLocation: location, error: error))
            subject.send(completion: .failure(error))
        } else {
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: location)
            } catch {
                print("Error moving: \(error)")
            }
            subject.send(.completed(destinationLocation: location, error: nil))
            subject.send(completion: .finished)
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
        let progress = Progress(totalUnitCount: downloadTask.countOfBytesExpectedToReceive)
        progress.completedUnitCount = downloadTask.countOfBytesReceived
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

        if let urlError: URLError = error as? URLError {
            subject.send(.completed(destinationLocation: nil, error: urlError))
            subject.send(completion: .failure(urlError))
        } else if let httpResponse = task.response as? HTTPURLResponse, httpResponse.statusCode < 200 || httpResponse.statusCode > 299 {
            let error = URLError(.fileDoesNotExist)
            subject.send(.completed(destinationLocation: nil, error: error))
            subject.send(completion: .failure(error))
        }
    }
}
