// Forked from: https://github.com/yukonblue/URLResourceKit/blob/0dda2eadcdf2ccf8323280bb4b3f5a430972134e/Sources/URLResourceKit/URLResourceDownloadTask.swift
import Foundation
import Combine

public enum URLResourceDownloadTaskProgress {
    case uninitiated
    case waitingForResponse
    case downloading(progress: Progress)
    case completed(destinationLocation: URL?, etag: String?, error: Error?)

    public var fractionCompleted: Double {
        switch self {
        case .uninitiated, .waitingForResponse:
            return 0
        case .downloading(let progress):
            return progress.fractionCompleted
        case .completed(_, _, let error):
            return error == nil ? 1 : 0
        }
    }
}

public protocol URLResourceDownloadTaskProtocol {
    typealias PublisherType = AnyPublisher<URLResourceDownloadTaskProgress, Error>
    var taskIdentifier: Int { get }
    var publisher: PublisherType { get }
    func resume()
}

public class URLResourceDownloadTask: NSObject, URLResourceDownloadTaskProtocol, @unchecked Sendable {
    private let session: URLSession
    private let url: URL
    private let destination: URL
    let downloadTask: URLSessionDownloadTask
    private let delivery = DownloadFileDelivery()
    private let resumeLock = NSLock()
    private var didResume = false

    // A deterministic seam for cancellation while activation is in progress.
    var didInstallDelegate: (() -> Void)?

    public typealias PublisherType = AnyPublisher<URLResourceDownloadTaskProgress, Error>
    fileprivate let subject: PassthroughSubject<PublisherType.Output, PublisherType.Failure>

    var responseLastModified: Date? { delivery.terminalResult?.lastModified }
    var finalResponseURL: URL? { delivery.terminalResult?.finalResponseURL }

    public var taskIdentifier: Int { downloadTask.taskIdentifier }
    public var publisher: PublisherType { subject.eraseToAnyPublisher() }

    public init(
        session: URLSession,
        url: URL,
        destination: URL,
        operationKey: DownloadOperationKey
    ) {
        self.session = session
        self.url = url
        self.destination = destination
        self.subject = PassthroughSubject<PublisherType.Output, PublisherType.Failure>()
        self.downloadTask = session.downloadTask(with: url)
        self.downloadTask.taskDescription = operationKey.taskDescription
        self.subject.send(.uninitiated)
    }

    public func resume() {
        resumeLock.lock()
        guard !didResume else {
            resumeLock.unlock()
            return
        }
        didResume = true
        resumeLock.unlock()

        subject.send(.waitingForResponse)
        if publishCancellationIfNeeded() { return }

        downloadTask.delegate = self
        didInstallDelegate?()
        if publishCancellationIfNeeded() { return }

        downloadTask.resume()
        // cancel() may have reached a still-suspended native task between the
        // check above and resume(). Such a task need not produce a delegate
        // completion, so settle it through the same file-delivery owner.
        _ = publishCancellationIfNeeded()
    }

    public func cancel() {
        delivery.cancel()
        downloadTask.cancel()
    }

    @discardableResult
    private func publishCancellationIfNeeded() -> Bool {
        guard delivery.isCancellationRequested else { return false }
        publish(delivery.complete(
            requestedURL: url,
            response: downloadTask.response,
            error: URLError(.cancelled)
        ))
        return true
    }

    private func publish(_ terminal: DownloadFileDelivery.TerminalResult?) {
        guard let terminal else { return }
        downloadTask.delegate = nil
        // The result and response metadata are committed before calling any
        // subscriber. Never invoke publishers while holding the delivery lock.
        subject.send(.completed(
            destinationLocation: terminal.destinationLocation,
            etag: terminal.etag,
            error: terminal.error
        ))
        if let error = terminal.error {
            subject.send(completion: .failure(error))
        } else {
            subject.send(completion: .finished)
        }
    }
}

extension URLResourceDownloadTask: URLSessionDownloadDelegate {
    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard session == self.session, downloadTask == self.downloadTask else { return }
        publish(delivery.receiveFile(
            at: location,
            destination: destination,
            requestedURL: url,
            response: downloadTask.response,
            taskIsCancelling: downloadTask.state == .canceling
        ))
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard session == self.session, downloadTask == self.downloadTask else { return }
        guard delivery.terminalResult == nil else { return }
        subject.send(.downloading(progress: downloadTransferProgress(
            expectedByteCount: downloadTask.countOfBytesExpectedToReceive,
            receivedByteCount: downloadTask.countOfBytesReceived
        )))
    }
}

extension URLResourceDownloadTask: URLSessionTaskDelegate {
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard session == self.session, task == self.downloadTask else { return }
        publish(delivery.complete(requestedURL: url, response: task.response, error: error))
    }
}
