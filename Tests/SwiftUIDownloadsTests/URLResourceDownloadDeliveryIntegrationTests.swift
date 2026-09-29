import Combine
import Foundation
import XCTest
@testable import SwiftUIDownloads

private final class DeliveryScenarioURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        var headers = ["ETag": "delivery-v1", "Last-Modified": "Sun, 06 Nov 1994 08:49:37 GMT"]
        var status = 200
        switch url.lastPathComponent {
        case "partial":
            status = 206
            headers["Content-Range"] = "bytes 0-6/1000"
        case "mislabeled":
            headers["Content-Range"] = "bytes 0-6/1000"
        case "retry":
            status = 503
            headers["Retry-After"] = "7"
        default: break
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("payload".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Uses Apple URLSession download tasks and Combine, not the portable runner.
final class URLResourceDownloadDeliveryIntegrationTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let destination: URL
        let session: URLSession
        let task: URLResourceDownloadTask
    }

    private func fixture(_ scenario: String, existing: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("library/book.epub")
        if existing {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("previous-complete-book".utf8).write(to: destination)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeliveryScenarioURLProtocol.self]
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel() }
        let url = URL(string: "https://delivery.test/" + scenario)!
        let task = URLResourceDownloadTask(session: session, url: url, destination: destination,
            operationKey: DownloadOperationKey(sourceURL: url, destinationURL: destination))
        return Fixture(root: root, destination: destination, session: session, task: task)
    }

    private func subscribe(_ task: URLResourceDownloadTask, recorder: DeliveryTerminalRecorder,
                           completion: XCTestExpectation) -> AnyCancellable {
        task.publisher.sink(receiveCompletion: { result in
            recorder.complete(result)
            completion.fulfill()
        }, receiveValue: { value in
            if case let .completed(destination, etag, error) = value {
                // The real controller reads these from inside its terminal subscriber.
                recorder.record(destination: destination, etag: etag, modifiedAt: task.responseLastModified,
                                responseURL: task.finalResponseURL, error: error)
            }
        })
    }

    func testPartialHTTPDownloadCannotReplaceTheExistingFile() async throws {
        let fixture = try fixture("partial", existing: true), recorder = DeliveryTerminalRecorder()
        let done = expectation(description: "Partial response rejected")
        let subscription = subscribe(fixture.task, recorder: recorder, completion: done)
        fixture.task.resume()
        await fulfillment(of: [done], timeout: 5)
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(recorder.results.count, 1)
        XCTAssertEqual((recorder.results.first?.error as? URLResourceDownloadHTTPError)?.statusCode, 206)
        XCTAssertTrue(recorder.failed)
        XCTAssertEqual(try String(contentsOf: fixture.destination, encoding: .utf8), "previous-complete-book")
    }

    func testMislabeledPartialResponseDoesNotCreateTheLibraryDirectory() async throws {
        let fixture = try fixture("mislabeled"), recorder = DeliveryTerminalRecorder()
        let done = expectation(description: "Range envelope rejected")
        let subscription = subscribe(fixture.task, recorder: recorder, completion: done)
        fixture.task.resume()
        await fulfillment(of: [done], timeout: 5)
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(recorder.results.count, 1)
        XCTAssertTrue(recorder.results.first?.error is DownloadResponseAdmissionError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.deletingLastPathComponent().path))
    }

    func testSuccessfulFileCallbackCannotBeReplayedToOverwriteItsDestination() async throws {
        let fixture = try fixture("complete"), recorder = DeliveryTerminalRecorder()
        let nativeTasks = await fixture.session.allTasks
        let native = try XCTUnwrap(nativeTasks.first { $0.taskIdentifier == fixture.task.taskIdentifier } as? URLSessionDownloadTask)
        let done = expectation(description: "Complete download")
        let subscription = subscribe(fixture.task, recorder: recorder, completion: done)
        fixture.task.resume()
        await fulfillment(of: [done], timeout: 5)
        let late = fixture.root.appendingPathComponent("late.part")
        try Data("must-not-replace-the-winner".utf8).write(to: late)
        fixture.task.urlSession(fixture.session, downloadTask: native, didFinishDownloadingTo: late)
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(recorder.results.count, 1)
        XCTAssertFalse(recorder.failed)
        XCTAssertEqual(try String(contentsOf: fixture.destination, encoding: .utf8), "payload")
        XCTAssertEqual(try String(contentsOf: late, encoding: .utf8), "must-not-replace-the-winner")
        XCTAssertEqual(recorder.results.first?.etag, "delivery-v1")
        XCTAssertEqual(recorder.results.first?.modifiedAt, Date(timeIntervalSince1970: 784111777))
        XCTAssertEqual(recorder.results.first?.responseURL, URL(string: "https://delivery.test/complete"))
    }

    func testLateFileAfterFailureCannotCreateAFileOrPublishAgain() async throws {
        let fixture = try fixture("complete"), recorder = DeliveryTerminalRecorder()
        let nativeTasks = await fixture.session.allTasks
        let native = try XCTUnwrap(nativeTasks.first { $0.taskIdentifier == fixture.task.taskIdentifier } as? URLSessionDownloadTask)
        let done = expectation(description: "Failure terminal")
        let subscription = subscribe(fixture.task, recorder: recorder, completion: done)
        fixture.task.urlSession(fixture.session, task: native, didCompleteWithError: URLError(.timedOut))
        await fulfillment(of: [done], timeout: 5)
        let late = fixture.root.appendingPathComponent("late.part")
        try Data("late".utf8).write(to: late)
        fixture.task.urlSession(fixture.session, downloadTask: native, didFinishDownloadingTo: late)
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(recorder.results.count, 1)
        XCTAssertEqual((recorder.results.first?.error as? URLError)?.code, .timedOut)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.deletingLastPathComponent().path))
        XCTAssertEqual(try String(contentsOf: late, encoding: .utf8), "late")
    }

    func testCancellationBeforeResumeStillDeliversOneObservableTerminal() async throws {
        let fixture = try fixture("complete", existing: true), recorder = DeliveryTerminalRecorder()
        fixture.task.cancel()
        let done = expectation(description: "Cancellation after subscription")
        let subscription = subscribe(fixture.task, recorder: recorder, completion: done)
        fixture.task.resume()
        await fulfillment(of: [done], timeout: 5)
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(recorder.results.count, 1)
        XCTAssertEqual((recorder.results.first?.error as? URLError)?.code, .cancelled)
        XCTAssertTrue(recorder.failed)
        XCTAssertEqual(try String(contentsOf: fixture.destination, encoding: .utf8), "previous-complete-book")
    }

    func testHTTPErrorKeepsTheExistingRetryAfterContract() async throws {
        let fixture = try fixture("retry"), recorder = DeliveryTerminalRecorder()
        let done = expectation(description: "HTTP retry metadata")
        let subscription = subscribe(fixture.task, recorder: recorder, completion: done)
        fixture.task.resume()
        await fulfillment(of: [done], timeout: 5)
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(recorder.results.count, 1)
        let error = try XCTUnwrap(recorder.results.first?.error as? URLResourceDownloadHTTPError)
        XCTAssertEqual(error.statusCode, 503)
        XCTAssertEqual(error.retryAfterSeconds, 7)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }
}

private final class DeliveryTerminalRecorder: @unchecked Sendable {
    struct Result {
        let destination: URL?
        let etag: String?
        let modifiedAt: Date?
        let responseURL: URL?
        let error: (any Error)?
    }
    private let lock = NSLock()
    private var stored: [Result] = []
    private var failure = false
    func record(destination: URL?, etag: String?, modifiedAt: Date?, responseURL: URL?, error: (any Error)?) {
        lock.lock(); defer { lock.unlock() }
        stored.append(Result(destination: destination, etag: etag, modifiedAt: modifiedAt, responseURL: responseURL, error: error))
    }
    func complete(_ completion: Subscribers.Completion<Error>) {
        lock.lock(); defer { lock.unlock() }
        if case .failure = completion { failure = true }
    }
    var results: [Result] { lock.lock(); defer { lock.unlock() }; return stored }
    var failed: Bool { lock.lock(); defer { lock.unlock() }; return failure }
}
