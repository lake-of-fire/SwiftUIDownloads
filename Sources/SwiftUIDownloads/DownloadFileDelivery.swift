import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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

/// Owns the file handoff and its terminal result together. A file callback
/// reserves delivery before I/O; losing callbacks cannot write or publish.
/// Cancellation stops unadmitted work, not an already-admitted filesystem move.
final class DownloadFileDelivery: @unchecked Sendable {
    struct TerminalResult {
        let destinationLocation: URL?
        let etag: String?
        let lastModified: Date?
        let finalResponseURL: URL?
        let error: (any Error)?

        static func failure(_ error: any Error, responseURL: URL?) -> Self {
            Self(destinationLocation: nil, etag: nil, lastModified: nil,
                 finalResponseURL: responseURL, error: error)
        }
    }

    private enum State {
        case awaitingDelivery
        case deliveringFile
        case terminal(TerminalResult)
    }

    private let lock = NSLock()
    private var state: State = .awaitingDelivery
    private var cancellationRequested = false
    // Internal concurrency seam; production I/O below is never substituted.
    private let didAdmitDelivery: (@Sendable () -> Void)?

    init(didAdmitDelivery: (@Sendable () -> Void)? = nil) {
        self.didAdmitDelivery = didAdmitDelivery
    }

    var terminalResult: TerminalResult? {
        lock.lock()
        defer { lock.unlock() }
        guard case .terminal(let result) = state else { return nil }
        return result
    }

    /// Record intent before URLSession cancellation. Do not publish here: the
    /// controller can cancel before attaching its terminal subscriber. A later
    /// delegate callback will publish the cancellation exactly once.
    func cancel() {
        lock.lock()
        cancellationRequested = true
        lock.unlock()
    }

    func receiveFile(
        at location: URL,
        destination: URL,
        requestedURL: URL,
        response: URLResponse?,
        taskIsCancelling: Bool = false
    ) -> TerminalResult? {
        lock.lock()
        guard case .awaitingDelivery = state else {
            lock.unlock()
            return nil
        }
        if cancellationRequested || taskIsCancelling {
            let terminal = TerminalResult.failure(URLError(.cancelled), responseURL: response?.url)
            state = .terminal(terminal)
            lock.unlock()
            return terminal
        }
        state = .deliveringFile
        lock.unlock()

        // FileManager can perform a cross-volume copy. Do not hold the lock
        // across I/O or make cancel() block the thread requesting cancellation.
        didAdmitDelivery?()
        let terminal: TerminalResult = {
            if let error = downloadResponseAdmissionError(response: response, requestedURL: requestedURL) {
                return .failure(error, responseURL: response?.url)
            }
            do {
                let fileManager = FileManager.default
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: destination.path) {
                    _ = try fileManager.replaceItemAt(destination, withItemAt: location)
                } else {
                    try fileManager.moveItem(at: location, to: destination)
                }
                let httpResponse = response as? HTTPURLResponse
                return TerminalResult(
                    destinationLocation: destination,
                    etag: httpResponse?.value(forHTTPHeaderField: "ETag"),
                    lastModified: httpResponse?.value(forHTTPHeaderField: "Last-Modified").flatMap(parseHTTPDate),
                    finalResponseURL: response?.url,
                    error: nil
                )
            } catch {
                return .failure(
                    URLResourceDownloadInstallError.destinationInstallFailed(
                        destination: destination, underlyingError: error
                    ),
                    responseURL: response?.url
                )
            }
        }()
        lock.lock()
        state = .terminal(terminal)
        lock.unlock()
        return terminal
    }

    func complete(
        requestedURL: URL,
        response: URLResponse?,
        error: (any Error)?
    ) -> TerminalResult? {
        lock.lock()
        defer { lock.unlock() }
        guard case .awaitingDelivery = state else { return nil }
        let failure = error
            ?? (cancellationRequested ? URLError(.cancelled) : nil)
            ?? downloadResponseAdmissionError(response: response, requestedURL: requestedURL)
            ?? URLResourceDownloadInstallError.completedWithoutDownloadedFile(requestedURL)
        let terminal = TerminalResult.failure(failure, responseURL: response?.url)
        state = .terminal(terminal)
        return terminal
    }
}
