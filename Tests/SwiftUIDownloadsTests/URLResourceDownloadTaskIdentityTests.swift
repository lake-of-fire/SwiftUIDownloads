import Combine
import XCTest
@testable import SwiftUIDownloads

private final class IdentityPayloadURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["ETag": "identity-test"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("owned-payload".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class URLResourceDownloadTaskIdentityTests: XCTestCase {
    func testForeignTaskCompletionCannotTerminateOwnedDownload() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftui-download-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let destination = tempDirectory.appendingPathComponent("payload.bin")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IdentityPayloadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let owned = URLResourceDownloadTask(
            session: session,
            url: URL(string: "https://swiftui-downloads-identity.test/owned")!,
            destination: destination
        )
        let completion = expectation(description: "owned terminal completion")
        var terminalErrors: [Error?] = []
        var publisherCompletion: Subscribers.Completion<Error>?
        let cancellable = owned.publisher.sink(
            receiveCompletion: { result in
                publisherCompletion = result
                completion.fulfill()
            },
            receiveValue: { progress in
                guard case .completed(_, _, let error) = progress else { return }
                terminalErrors.append(error)
            }
        )

        let foreign = session.dataTask(
            with: URL(string: "https://swiftui-downloads-identity.test/foreign")!
        )
        owned.urlSession(
            session,
            task: foreign,
            didCompleteWithError: URLError(.cancelled)
        )

        owned.resume()
        wait(for: [completion], timeout: 2)
        withExtendedLifetime(cancellable) {}

        XCTAssertEqual(terminalErrors.count, 1)
        XCTAssertNil(terminalErrors[0], "A foreign task must not publish this download's terminal error")
        guard case .finished = publisherCompletion else {
            XCTFail("The owned download should still finish successfully")
            return
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("owned-payload".utf8))
    }
}
