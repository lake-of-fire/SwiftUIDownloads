import Combine
import XCTest
@testable import SwiftUIDownloads

private final class ImmediatePayloadURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["ETag": "terminal-test"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("payload".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class URLResourceDownloadTaskTerminalTests: XCTestCase {
    func testExistingDestinationReplacementFailurePublishesExactlyOneFailureTerminalResult() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swiftui-download-terminal-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let installDirectory = tempDirectory.appendingPathComponent(
            "install",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: installDirectory,
            withIntermediateDirectories: true
        )
        let destination = installDirectory.appendingPathComponent("payload.bin")
        let originalPayload = Data("existing-payload".utf8)
        try originalPayload.write(to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: installDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: installDirectory.path
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImmediatePayloadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let task = URLResourceDownloadTask(
            session: session,
            url: URL(string: "https://swiftui-downloads-terminal.test/payload")!,
            destination: destination,
            operationKey: DownloadOperationKey(
                sourceURL: URL(string: "https://swiftui-downloads-terminal.test/payload")!,
                destinationURL: destination
            )
        )
        let completion = expectation(description: "terminal completion")
        var terminalResults: [Error?] = []
        var publisherCompletion: Subscribers.Completion<Error>?
        let cancellable = task.publisher.sink(
            receiveCompletion: { result in
                publisherCompletion = result
                completion.fulfill()
            },
            receiveValue: { progress in
                guard case .completed(_, _, let error) = progress else { return }
                terminalResults.append(error)
            }
        )

        task.resume()
        wait(for: [completion], timeout: 2)
        withExtendedLifetime(cancellable) {}

        XCTAssertEqual(terminalResults.count, 1)
        XCTAssertTrue(terminalResults[0] is URLResourceDownloadInstallError)
        guard case .failure(let error) = publisherCompletion else {
            XCTFail("Expected one failure completion")
            return
        }
        XCTAssertTrue(error is URLResourceDownloadInstallError)
        XCTAssertEqual(
            try Data(contentsOf: destination),
            originalPayload,
            "A failed replacement must preserve the previously installed file"
        )
    }
}
