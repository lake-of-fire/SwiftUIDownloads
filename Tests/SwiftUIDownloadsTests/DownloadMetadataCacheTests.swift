import Foundation
@testable import SwiftUIDownloads
import XCTest

private final class RecordingDownloadMetadataStore: DownloadableMetadataStore, @unchecked Sendable {
    private enum StoreError: Error {
        case requested
    }

    private let lock = NSLock()
    let metadataCacheNamespace = "RecordingDownloadMetadataStore:\(UUID().uuidString)"
    private var metadata: DownloadMetadata
    private let failsBulkLoad: Bool
    private var remainingSaveFailures: Int
    private(set) var bulkLoadCount = 0
    private(set) var scalarReadCount = 0

    init(
        metadata: DownloadMetadata,
        failsBulkLoad: Bool = false,
        saveFailureCount: Int = 0
    ) {
        self.metadata = metadata
        self.failsBulkLoad = failsBulkLoad
        self.remainingSaveFailures = saveFailureCount
    }

    func loadMetadata(for _: URL) throws -> DownloadMetadata {
        if failsBulkLoad {
            throw StoreError.requested
        }
        return withLock {
            bulkLoadCount += 1
            return metadata
        }
    }

    func saveMetadata(
        _ metadata: DownloadMetadata,
        fields: DownloadMetadataFields,
        for _: URL
    ) throws {
        try withLock {
            if remainingSaveFailures > 0 {
                remainingSaveFailures -= 1
                throw StoreError.requested
            }
            if fields.contains(.lastDownloadedETag) {
                self.metadata.lastDownloadedETag = metadata.lastDownloadedETag
            }
            if fields.contains(.lastCheckedETagAt) {
                self.metadata.lastCheckedETagAt = metadata.lastCheckedETagAt
            }
            if fields.contains(.lastDownloadedAt) {
                self.metadata.lastDownloadedAt = metadata.lastDownloadedAt
            }
            if fields.contains(.lastModifiedAt) {
                self.metadata.lastModifiedAt = metadata.lastModifiedAt
            }
        }
    }

    func lastDownloadedETag(for _: URL) -> String? { scalarRead { metadata.lastDownloadedETag } }
    func setLastDownloadedETag(_ value: String?, for _: URL) { withLock { metadata.lastDownloadedETag = value } }
    func lastCheckedETagAt(for _: URL) -> Date? { scalarRead { metadata.lastCheckedETagAt } }
    func setLastCheckedETagAt(_ value: Date?, for _: URL) { withLock { metadata.lastCheckedETagAt = value } }
    func lastDownloaded(for _: URL) -> Date? { scalarRead { metadata.lastDownloadedAt } }
    func setLastDownloaded(_ value: Date?, for _: URL) { withLock { metadata.lastDownloadedAt = value } }
    func lastModifiedAt(for _: URL) -> Date? { scalarRead { metadata.lastModifiedAt } }
    func setLastModifiedAt(_ value: Date?, for _: URL) { withLock { metadata.lastModifiedAt = value } }

    var storedMetadata: DownloadMetadata {
        withLock { metadata }
    }

    private func scalarRead<Value>(_ value: () -> Value) -> Value {
        withLock {
            scalarReadCount += 1
            return value()
        }
    }

    private func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

final class DownloadMetadataCacheTests: XCTestCase {
    @MainActor
    func testDownloadableHydratesMetadataWithOneBulkStoreRead() async {
        let checkedAt = Date(timeIntervalSince1970: 100)
        let downloadedAt = Date(timeIntervalSince1970: 200)
        let modifiedAt = Date(timeIntervalSince1970: 300)
        let store = RecordingDownloadMetadataStore(
            metadata: DownloadMetadata(
                lastDownloadedETag: "etag",
                lastCheckedETagAt: checkedAt,
                lastDownloadedAt: downloadedAt,
                lastModifiedAt: modifiedAt
            )
        )
        let download = Downloadable(
            url: URL(string: "https://example.com/dictionary.zip")!,
            name: "Dictionary",
            localDestination: URL(fileURLWithPath: "/tmp/dictionary.zip"),
            metadataStore: store
        )

        await download.waitForDownloadMetadata()

        XCTAssertEqual(download.lastDownloadedETag, "etag")
        XCTAssertEqual(download.lastCheckedETagAt, checkedAt)
        XCTAssertEqual(download.lastDownloaded, downloadedAt)
        XCTAssertEqual(download.lastModifiedAt, modifiedAt)
        XCTAssertEqual(store.bulkLoadCount, 1)
        XCTAssertEqual(store.scalarReadCount, 0)
    }

    @MainActor
    func testFailedBulkLoadDoesNotClearUnchangedStoredFields() async throws {
        let originalCheckedAt = Date(timeIntervalSince1970: 100)
        let store = RecordingDownloadMetadataStore(
            metadata: DownloadMetadata(
                lastDownloadedETag: "old",
                lastCheckedETagAt: originalCheckedAt
            ),
            failsBulkLoad: true
        )
        let download = Downloadable(
            url: URL(string: "https://example.com/dictionary.zip")!,
            name: "Dictionary",
            localDestination: URL(fileURLWithPath: "/tmp/dictionary.zip"),
            metadataStore: store
        )

        await download.waitForDownloadMetadata()
        download.lastDownloadedETag = "new"
        try await download.waitForDownloadMetadataPersistence()

        XCTAssertEqual(store.storedMetadata.lastDownloadedETag, "new")
        XCTAssertEqual(store.storedMetadata.lastCheckedETagAt, originalCheckedAt)
    }

    @MainActor
    func testSeparateDownloadablesDoNotOverwriteEachOthersMetadataFields() async throws {
        let store = RecordingDownloadMetadataStore(metadata: DownloadMetadata())
        let url = URL(string: "https://example.com/dictionary.zip")!
        let first = Downloadable(
            url: url,
            name: "First",
            localDestination: URL(fileURLWithPath: "/tmp/first.zip"),
            metadataStore: store
        )
        let second = Downloadable(
            url: url,
            name: "Second",
            localDestination: URL(fileURLWithPath: "/tmp/second.zip"),
            metadataStore: store
        )
        await first.waitForDownloadMetadata()
        await second.waitForDownloadMetadata()
        XCTAssertEqual(store.bulkLoadCount, 1)

        let modifiedAt = Date(timeIntervalSince1970: 300)
        first.lastDownloadedETag = "etag"
        second.lastModifiedAt = modifiedAt
        XCTAssertEqual(second.lastDownloadedETag, "etag")
        XCTAssertEqual(first.lastModifiedAt, modifiedAt)
        try await first.waitForDownloadMetadataPersistence()
        try await second.waitForDownloadMetadataPersistence()

        XCTAssertEqual(store.storedMetadata.lastDownloadedETag, "etag")
        XCTAssertEqual(store.storedMetadata.lastModifiedAt, modifiedAt)
    }

    @MainActor
    func testPersistenceFailureIsReportedAndLaterMutationRetriesDirtyFields() async throws {
        let store = RecordingDownloadMetadataStore(
            metadata: DownloadMetadata(),
            saveFailureCount: 1
        )
        let download = Downloadable(
            url: URL(string: "https://example.com/retry.zip")!,
            name: "Retry",
            localDestination: URL(fileURLWithPath: "/tmp/retry.zip"),
            metadataStore: store
        )
        await download.waitForDownloadMetadata()

        download.lastDownloadedETag = "etag"
        do {
            try await download.waitForDownloadMetadataPersistence()
            XCTFail("Expected the failed metadata save to be reported")
        } catch is DownloadMetadataPersistenceError {
        }

        let modifiedAt = Date(timeIntervalSince1970: 400)
        download.lastModifiedAt = modifiedAt
        try await download.waitForDownloadMetadataPersistence()

        XCTAssertEqual(store.storedMetadata.lastDownloadedETag, "etag")
        XCTAssertEqual(store.storedMetadata.lastModifiedAt, modifiedAt)
    }
}
