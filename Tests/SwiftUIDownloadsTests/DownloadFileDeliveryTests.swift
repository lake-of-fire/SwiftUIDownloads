import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SwiftUIDownloads

final class DownloadFileDeliveryTests: XCTestCase {
    private let requestedURL = URL(string: "https://download.test/book")!
    private let finalURL = URL(string: "https://cdn.test/books/book.epub")!

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func response(_ status: Int = 200, headers: [String: String] = [:]) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: finalURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers))
    }

    private func candidate(in root: URL, text: String = "complete-book") throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString + ".part")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func receive(
        _ delivery: DownloadFileDelivery, file: URL, to destination: URL,
        response: URLResponse?, taskIsCancelling: Bool = false
    ) -> DownloadFileDelivery.TerminalResult? {
        delivery.receiveFile(at: file, destination: destination, requestedURL: requestedURL,
                             response: response, taskIsCancelling: taskIsCancelling)
    }

    func testSuccessfulDeliveryCreatesParentAndRetainsResponseMetadata() throws {
        let root = try fixture(), file = try candidate(in: root)
        let destination = root.appendingPathComponent("library/日本語.epub")
        let delivery = DownloadFileDelivery()
        let result = try XCTUnwrap(receive(delivery, file: file, to: destination,
            response: try response(headers: ["ETag": "book-v2", "Last-Modified": "Sun, 06 Nov 1994 08:49:37 GMT"])))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.destinationLocation, destination)
        XCTAssertEqual(result.etag, "book-v2")
        XCTAssertEqual(result.lastModified, Date(timeIntervalSince1970: 784111777))
        XCTAssertEqual(result.finalResponseURL, finalURL)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "complete-book")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(delivery.terminalResult?.etag, "book-v2")
    }

    func testSuccessfulReplacementUsesNativeFoundation() throws {
#if os(Linux)
        throw XCTSkip("swift-corelibs-foundation replaceItemAt is not implemented equivalently; run this case on Apple Foundation")
#else
        let root = try fixture(), file = try candidate(in: root)
        let destination = root.appendingPathComponent("book.epub")
        try Data("old".utf8).write(to: destination)
        let result = try XCTUnwrap(receive(DownloadFileDelivery(), file: file, to: destination, response: try response()))
        XCTAssertNil(result.error)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "complete-book")
#endif
    }

    func testPartialResponsePreservesExistingDestinationAndCandidate() throws {
        let root = try fixture(), file = try candidate(in: root, text: "partial")
        let destination = root.appendingPathComponent("book.epub")
        try Data("previous-complete-book".utf8).write(to: destination)
        let delivery = DownloadFileDelivery()
        let result = try XCTUnwrap(receive(delivery, file: file, to: destination,
            response: try response(206, headers: ["Content-Range": "bytes 0-6/1000", "ETag": "partial-v2"])))
        XCTAssertEqual((result.error as? URLResourceDownloadHTTPError)?.statusCode, 206)
        XCTAssertNil(result.destinationLocation)
        XCTAssertNil(result.etag)
        XCTAssertNil(result.lastModified)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "previous-complete-book")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "partial")
        XCTAssertNil(delivery.complete(requestedURL: requestedURL, response: try response(206), error: nil))
    }

    func testPartialResponseDoesNotCreateDestinationDirectories() throws {
        let root = try fixture(), file = try candidate(in: root)
        let destination = root.appendingPathComponent("absent/library/book.epub")
        _ = receive(DownloadFileDelivery(), file: file, to: destination, response: try response(206))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("absent").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testWholeLookingRangeStillRequiresAnUnsupportedRangeProtocol() throws {
        let root = try fixture(), file = try candidate(in: root, text: "book")
        let result = try XCTUnwrap(receive(DownloadFileDelivery(), file: file, to: root.appendingPathComponent("book.epub"),
            response: try response(206, headers: ["Content-Range": "bytes 0-3/4"])))
        XCTAssertEqual((result.error as? URLResourceDownloadHTTPError)?.statusCode, 206)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testMultipartAndMalformedPartialResponsesAreRejected() throws {
        for headers in [["Content-Type": "multipart/byteranges; boundary=example"], [:]] {
            let root = try fixture(), file = try candidate(in: root)
            let destination = root.appendingPathComponent("book.epub")
            let result = try XCTUnwrap(receive(DownloadFileDelivery(), file: file, to: destination, response: try response(206, headers: headers)))
            XCTAssertEqual((result.error as? URLResourceDownloadHTTPError)?.statusCode, 206)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testMislabeledRangeEnvelopesAreNotInstalledAs200Files() throws {
        for headers in [["Content-Range": "bytes 0-5/100"], ["Content-Type": "multipart/byteranges; boundary=example"]] {
            let root = try fixture(), file = try candidate(in: root)
            let destination = root.appendingPathComponent("book.epub")
            let result = try XCTUnwrap(receive(DownloadFileDelivery(), file: file, to: destination, response: try response(headers: headers)))
            XCTAssertTrue(result.error is DownloadResponseAdmissionError)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testHTTPFailuresRetainStatusAndRetryAfterWithoutInstalling() throws {
        for status in [304, 404, 429, 503] {
            let root = try fixture(), file = try candidate(in: root)
            let destination = root.appendingPathComponent("book.epub")
            let result = try XCTUnwrap(receive(DownloadFileDelivery(), file: file, to: destination,
                response: try response(status, headers: ["Retry-After": "12"])))
            let error = try XCTUnwrap(result.error as? URLResourceDownloadHTTPError)
            XCTAssertEqual(error.statusCode, status)
            XCTAssertEqual(error.url, requestedURL)
            XCTAssertEqual(error.retryAfterSeconds, 12)
            XCTAssertEqual(result.finalResponseURL, finalURL)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testHTTPDownloadRequiresAnHTTPResponse() throws {
        let root = try fixture()
        let nonHTTP = URLResponse(url: finalURL, mimeType: nil, expectedContentLength: 5, textEncodingName: nil)
        for response in [nil, nonHTTP] as [URLResponse?] {
            let file = try candidate(in: root), destination = root.appendingPathComponent(UUID().uuidString)
            let result = try XCTUnwrap(receive(DownloadFileDelivery(), file: file, to: destination, response: response))
            XCTAssertEqual((result.error as? URLError)?.code, .badServerResponse)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testNonHTTPFileResponseRemainsSupported() throws {
        let root = try fixture(), file = try candidate(in: root)
        let destination = root.appendingPathComponent("book.epub")
        let response = URLResponse(url: file, mimeType: nil, expectedContentLength: -1, textEncodingName: nil)
        let result = try XCTUnwrap(DownloadFileDelivery().receiveFile(at: file, destination: destination,
            requestedURL: file, response: response))
        XCTAssertNil(result.error)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "complete-book")
    }

    func testUnknownContentLengthDoesNotPreventDelivery() throws {
        let root = try fixture(), file = try candidate(in: root)
        let result = try XCTUnwrap(receive(DownloadFileDelivery(), file: file, to: root.appendingPathComponent("book.epub"),
            response: try response(headers: ["Transfer-Encoding": "chunked"])))
        XCTAssertNil(result.error)
    }

    func testContentCodingLengthIsNotComparedToDecodedFileLength() throws {
        let root = try fixture(), file = try candidate(in: root)
        let result = try XCTUnwrap(receive(DownloadFileDelivery(), file: file, to: root.appendingPathComponent("book.epub"),
            response: try response(headers: ["Content-Encoding": "gzip", "Content-Length": "2"])))
        XCTAssertNil(result.error)
    }

    func testEmpty200FileRemainsTheProcessorsValidationResponsibility() throws {
        let root = try fixture(), file = try candidate(in: root, text: "")
        let destination = root.appendingPathComponent("empty.txt")
        let result = try XCTUnwrap(receive(DownloadFileDelivery(), file: file, to: destination, response: try response()))
        XCTAssertNil(result.error)
        XCTAssertEqual(try Data(contentsOf: destination), Data())
    }

    func testCompleteWithoutFileCannotPublishSuccess() throws {
        let result = try XCTUnwrap(DownloadFileDelivery().complete(requestedURL: requestedURL, response: try response(), error: nil))
        guard case .completedWithoutDownloadedFile(let url) = result.error as? URLResourceDownloadInstallError else {
            return XCTFail("Expected missing downloaded file, got \(String(describing: result.error))")
        }
        XCTAssertEqual(url, requestedURL)
    }

    func testCompleteWithoutFileUsesTheSameHTTPAdmission() throws {
        for status in [206, 404, 503] {
            let result = try XCTUnwrap(DownloadFileDelivery().complete(requestedURL: requestedURL,
                response: try response(status, headers: ["Retry-After": "4"]), error: nil))
            XCTAssertEqual((result.error as? URLResourceDownloadHTTPError)?.statusCode, status)
            XCTAssertEqual((result.error as? URLResourceDownloadHTTPError)?.retryAfterSeconds, 4)
        }
    }

    func testTransportErrorTakesPrecedenceOverResponseStatus() throws {
        let result = try XCTUnwrap(DownloadFileDelivery().complete(requestedURL: requestedURL,
            response: try response(503), error: URLError(.networkConnectionLost)))
        XCTAssertEqual((result.error as? URLError)?.code, .networkConnectionLost)
    }

    func testLateFileAfterTerminalFailureDoesNotCreateOrReplaceAnything() throws {
        let root = try fixture(), file = try candidate(in: root)
        let destination = root.appendingPathComponent("not-created/book.epub")
        let delivery = DownloadFileDelivery()
        _ = delivery.complete(requestedURL: requestedURL, response: nil, error: URLError(.timedOut))
        XCTAssertNil(receive(delivery, file: file, to: destination, response: try response()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "complete-book")
        XCTAssertEqual((delivery.terminalResult?.error as? URLError)?.code, .timedOut)
    }

    func testDuplicateFileCallbackCannotReplaceTheWinningBytesOrMetadata() throws {
        let root = try fixture(), first = try candidate(in: root, text: "first"), second = try candidate(in: root, text: "second")
        let destination = root.appendingPathComponent("book.epub")
        let delivery = DownloadFileDelivery()
        _ = receive(delivery, file: first, to: destination, response: try response(headers: ["ETag": "first"]))
        XCTAssertNil(receive(delivery, file: second, to: destination, response: try response(headers: ["ETag": "second"])))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second")
        XCTAssertEqual(delivery.terminalResult?.etag, "first")
    }

    func testCompletionAfterSuccessfulFileIsAnIdempotentNoOp() throws {
        let root = try fixture(), file = try candidate(in: root)
        let delivery = DownloadFileDelivery()
        let destination = root.appendingPathComponent("book.epub")
        _ = receive(delivery, file: file, to: destination, response: try response())
        XCTAssertNil(delivery.complete(requestedURL: requestedURL, response: try response(), error: nil))
        XCTAssertNil(delivery.complete(requestedURL: requestedURL, response: nil, error: URLError(.cancelled)))
        XCTAssertNil(delivery.terminalResult?.error)
        XCTAssertEqual(delivery.terminalResult?.destinationLocation, destination)
    }

    func testCancellationBeforeFilePreservesExistingDestination() throws {
        let root = try fixture(), file = try candidate(in: root)
        let destination = root.appendingPathComponent("book.epub")
        try Data("existing".utf8).write(to: destination)
        let delivery = DownloadFileDelivery()
        delivery.cancel()
        let result = try XCTUnwrap(receive(delivery, file: file, to: destination, response: try response()))
        XCTAssertEqual((result.error as? URLError)?.code, .cancelled)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "existing")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "complete-book")
    }

    func testCancellationBeforeSubscriberDoesNotConsumeTheTerminalResult() throws {
        let delivery = DownloadFileDelivery()
        delivery.cancel()
        XCTAssertNil(delivery.terminalResult)
        let result = try XCTUnwrap(delivery.complete(requestedURL: requestedURL, response: nil, error: nil))
        XCTAssertEqual((result.error as? URLError)?.code, .cancelled)
        XCTAssertNil(delivery.complete(requestedURL: requestedURL, response: nil, error: nil))
    }

    func testURLSessionCancellationStateAlsoPreventsFileHandoff() throws {
        let root = try fixture(), file = try candidate(in: root)
        let destination = root.appendingPathComponent("not-created/book.epub")
        let result = try XCTUnwrap(receive(DownloadFileDelivery(), file: file, to: destination,
            response: try response(), taskIsCancelling: true))
        XCTAssertEqual((result.error as? URLError)?.code, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testCancellationAfterCommitCannotUndoASuccessfulDelivery() throws {
        let root = try fixture(), file = try candidate(in: root)
        let destination = root.appendingPathComponent("book.epub"), delivery = DownloadFileDelivery()
        _ = receive(delivery, file: file, to: destination, response: try response())
        delivery.cancel()
        XCTAssertNil(delivery.complete(requestedURL: requestedURL, response: nil, error: URLError(.cancelled)))
        XCTAssertNil(delivery.terminalResult?.error)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "complete-book")
    }

    func testInstallFailureIsTerminalAndDoesNotConsumeTheInput() throws {
        let root = try fixture(), file = try candidate(in: root)
        let nonDirectory = root.appendingPathComponent("ordinary-file")
        try Data("keep".utf8).write(to: nonDirectory)
        let delivery = DownloadFileDelivery()
        let result = try XCTUnwrap(receive(delivery, file: file, to: nonDirectory.appendingPathComponent("book.epub"), response: try response()))
        XCTAssertTrue(result.error is URLResourceDownloadInstallError)
        XCTAssertEqual(try String(contentsOf: nonDirectory, encoding: .utf8), "keep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(receive(delivery, file: file, to: root.appendingPathComponent("other.epub"), response: try response()))
    }

    func testConcurrentFileCallbacksDeliverOnlyOneCandidate() throws {
        let root = try fixture(), first = try candidate(in: root, text: "first"), second = try candidate(in: root, text: "second")
        let destination = root.appendingPathComponent("book.epub"), response = try response()
        let delivery = DownloadFileDelivery(), results = ResultRecorder()
        let source = requestedURL
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            if let result = delivery.receiveFile(at: index == 0 ? first : second, destination: destination,
                requestedURL: source, response: response) { results.record(result) }
        }
        XCTAssertEqual(results.values.count, 1)
        XCTAssertNil(results.values.first?.error)
        let text = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(text == "first" || text == "second")
        XCTAssertNotEqual(FileManager.default.fileExists(atPath: first.path), FileManager.default.fileExists(atPath: second.path))
    }

    func testCancellationRacingFileDeliveryHasAConsistentFilesystemOutcome() throws {
        let root = try fixture(), response = try response(), source = requestedURL
        for _ in 0..<50 {
            let file = try candidate(in: root), destination = root.appendingPathComponent(UUID().uuidString + ".epub")
            let delivery = DownloadFileDelivery(), results = ResultRecorder()
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                if index == 0 { delivery.cancel() }
                else if let result = delivery.receiveFile(at: file, destination: destination, requestedURL: source, response: response) {
                    results.record(result)
                }
            }
            let result = try XCTUnwrap(results.values.first)
            XCTAssertEqual(results.values.count, 1)
            if result.error == nil {
                XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "complete-book")
                XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            } else {
                XCTAssertEqual((result.error as? URLError)?.code, .cancelled)
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            }
        }
    }

    func testAdmittedMoveOwnsCompletionWithoutBlockingCancellation() throws {
        let root = try fixture(), file = try candidate(in: root), response = try response()
        let destination = root.appendingPathComponent("book.epub"), source = requestedURL
        let admitted = expectation(description: "Delivery admitted")
        let delivered = expectation(description: "Delivery finished")
        let cancellationReturned = expectation(description: "Cancel returns without waiting for file I/O")
        let completionReturned = expectation(description: "Losing completion returns during file I/O")
        let release = DispatchSemaphore(value: 0)
        let delivery = DownloadFileDelivery(didAdmitDelivery: {
            admitted.fulfill()
            release.wait()
        })
        let results = ResultRecorder()
        DispatchQueue.global().async {
            if let result = delivery.receiveFile(at: file, destination: destination, requestedURL: source, response: response) {
                results.record(result)
            }
            delivered.fulfill()
        }
        wait(for: [admitted], timeout: 2)
        // Cancellation does not consume or overtake an already-admitted move.
        DispatchQueue.global().async {
            delivery.cancel()
            cancellationReturned.fulfill()
        }
        DispatchQueue.global().async {
            XCTAssertNil(delivery.complete(requestedURL: source, response: response, error: URLError(.cancelled)))
            XCTAssertNil(delivery.terminalResult)
            completionReturned.fulfill()
        }
        // Always release after this bounded wait, even if a regression holds a
        // delivery lock across I/O and blocks either competing callback.
        wait(for: [cancellationReturned, completionReturned], timeout: 2)
        release.signal()
        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(results.values.count, 1)
        XCTAssertNil(results.values.first?.error)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "complete-book")
    }

    func testUnknownTransferProgressDoesNotBecomeFinishedAtFirstBytes() {
        let progress = downloadTransferProgress(
            expectedByteCount: -1,
            receivedByteCount: 1024
        )
        XCTAssertEqual(progress.totalUnitCount, -1)
        XCTAssertEqual(progress.completedUnitCount, 1024)
        XCTAssertFalse(progress.isFinished)
        XCTAssertEqual(progress.fractionCompleted, 0)
    }

    func testKnownTransferProgressKeepsExpectedFraction() {
        let progress = downloadTransferProgress(
            expectedByteCount: 4096,
            receivedByteCount: 1024
        )
        XCTAssertEqual(progress.totalUnitCount, 4096)
        XCTAssertEqual(progress.completedUnitCount, 1024)
        XCTAssertFalse(progress.isFinished)
        XCTAssertEqual(progress.fractionCompleted, 0.25, accuracy: 0.0001)
    }

    func testEmptyKnownTransferWaitsForTerminalCallback() {
        let progress = downloadTransferProgress(
            expectedByteCount: 0,
            receivedByteCount: 0
        )
        XCTAssertEqual(progress.totalUnitCount, 0)
        XCTAssertFalse(progress.isFinished)
    }

    func testRetryHeadersAndDatesKeepTheirExistingInterpretation() throws {
        let now = Date(timeIntervalSince1970: 784111777)
        XCTAssertEqual(parseRetryAfterSeconds(" 12.5 ", now: now), 12.5)
        XCTAssertEqual(parseRetryAfterSeconds("Sun, 06 Nov 1994 08:49:47 GMT", now: now), 10)
        XCTAssertEqual(parseRetryAfterSeconds("Sun, 06 Nov 1994 08:49:27 GMT", now: now), 0)
        for value in ["", "NaN", "Infinity", "-1", "garbage"] {
            XCTAssertNil(parseRetryAfterSeconds(value, now: now))
        }
        XCTAssertNil(URLResourceDownloadHTTPError(statusCode: 503, url: nil, retryAfterSeconds: .nan).retryAfterSeconds)
        XCTAssertFalse(URLResourceDownloadHTTPError(statusCode: 503, url: nil, retryAfterSeconds: Double.greatestFiniteMagnitude).localizedDescription.isEmpty)
    }
}

private final class ResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [DownloadFileDelivery.TerminalResult] = []
    func record(_ result: DownloadFileDelivery.TerminalResult) {
        lock.lock(); defer { lock.unlock() }
        stored.append(result)
    }
    var values: [DownloadFileDelivery.TerminalResult] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}
