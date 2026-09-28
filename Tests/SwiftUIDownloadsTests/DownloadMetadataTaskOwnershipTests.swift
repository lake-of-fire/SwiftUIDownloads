import Foundation
import XCTest
@testable import SwiftUIDownloads

private final class MetadataTaskStore: DownloadableMetadataStore, @unchecked Sendable {
    let metadataCacheNamespace = UUID().uuidString
    private let lock = NSLock()
    private var metadata: DownloadMetadata
    private var loads = 0
    private var saves = 0
    private var activeSaves = 0
    private var maximumActiveSaves = 0
    private var nextSaveAction: (@Sendable () throws -> Void)?

    init(metadata: DownloadMetadata = DownloadMetadata()) { self.metadata = metadata }

    func beforeNextSave(_ action: @escaping @Sendable () throws -> Void) {
        withLock { nextSaveAction = action }
    }

    var snapshot: (metadata: DownloadMetadata, loads: Int, saves: Int, peak: Int) {
        withLock { (metadata, loads, saves, maximumActiveSaves) }
    }

    func loadMetadata(for _: URL) -> DownloadMetadata {
        withLock { loads += 1; return metadata }
    }

    func saveMetadata(_ value: DownloadMetadata, fields: DownloadMetadataFields, for _: URL) throws {
        let action = withLock {
            saves += 1
            activeSaves += 1
            maximumActiveSaves = max(maximumActiveSaves, activeSaves)
            let action = nextSaveAction
            nextSaveAction = nil
            return action
        }
        defer { withLock { activeSaves -= 1 } }
        // Deliberately outside the store lock: a persistence callback may
        // synchronously mutate the cache while its old snapshot is in flight.
        try action?()
        withLock {
            if fields.contains(.lastDownloadedETag) { metadata.lastDownloadedETag = value.lastDownloadedETag }
            if fields.contains(.lastCheckedETagAt) { metadata.lastCheckedETagAt = value.lastCheckedETagAt }
            if fields.contains(.lastDownloadedAt) { metadata.lastDownloadedAt = value.lastDownloadedAt }
            if fields.contains(.lastModifiedAt) { metadata.lastModifiedAt = value.lastModifiedAt }
        }
    }

    func lastDownloadedETag(for _: URL) -> String? { withLock { metadata.lastDownloadedETag } }
    func setLastDownloadedETag(_ value: String?, for _: URL) { withLock { metadata.lastDownloadedETag = value } }
    func lastCheckedETagAt(for _: URL) -> Date? { withLock { metadata.lastCheckedETagAt } }
    func setLastCheckedETagAt(_ value: Date?, for _: URL) { withLock { metadata.lastCheckedETagAt = value } }
    func lastDownloaded(for _: URL) -> Date? { withLock { metadata.lastDownloadedAt } }
    func setLastDownloaded(_ value: Date?, for _: URL) { withLock { metadata.lastDownloadedAt = value } }
    func lastModifiedAt(for _: URL) -> Date? { withLock { metadata.lastModifiedAt } }
    func setLastModifiedAt(_ value: Date?, for _: URL) { withLock { metadata.lastModifiedAt = value } }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

/// Native package tests: these exercise the actual cache/DownloadActor and
/// store protocol, not the Foundation-only staging runner.
final class DownloadMetadataTaskOwnershipTests: XCTestCase, @unchecked Sendable {
    private enum TestError: Error { case requested, timedOut }

    private func cache(_ store: MetadataTaskStore) -> DownloadMetadataCache {
        DownloadMetadataCache(store: store, url: URL(string: "https://metadata.test/\(UUID().uuidString)")!)
    }

    private func waitForSaves(_ cache: DownloadMetadataCache) async throws {
        let finished = expectation(description: "Metadata producer retired")
        let task = Task { @DownloadActor in
            defer { finished.fulfill() }
            try await cache.waitForPendingSaves()
        }
        let result = await XCTWaiter.fulfillment(of: [finished], timeout: 5)
        guard result == .completed else {
            task.cancel()
            XCTFail("Waiting for metadata persistence did not complete")
            throw TestError.timedOut
        }
        try await task.value
    }

    func testFirstReadersShareLoadWithoutAnObservationRelay() async throws {
        let store = MetadataTaskStore(metadata: DownloadMetadata(lastDownloadedETag: "stored"))
        let cache = cache(store)
        let finished = expectation(description: "All initial readers returned")
        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<100 { group.addTask { await cache.waitForInitialLoad() } }
            }
            finished.fulfill()
        }
        let result = await XCTWaiter.fulfillment(of: [finished], timeout: 5)
        guard result == .completed else {
            task.cancel()
            throw TestError.timedOut
        }
        await task.value
        XCTAssertEqual(store.snapshot.loads, 1)
        XCTAssertEqual(cache.currentMetadata().lastDownloadedETag, "stored")
    }

    func testWriteBeforeObservationLoadsOtherFieldsAndPersists() async throws {
        let originalDate = Date(timeIntervalSince1970: 123)
        let store = MetadataTaskStore(metadata: DownloadMetadata(lastDownloadedETag: "old", lastModifiedAt: originalDate))
        let cache = cache(store)
        cache.setLastDownloadedETag("new")
        try await waitForSaves(cache)
        XCTAssertEqual(store.snapshot.loads, 1)
        XCTAssertEqual(store.snapshot.metadata.lastDownloadedETag, "new")
        XCTAssertEqual(store.snapshot.metadata.lastModifiedAt, originalDate)
        XCTAssertEqual(cache.currentMetadata(), store.snapshot.metadata)
    }

    func testReentrantMutationDuringSuccessfulSaveIsDrainedByItsOwner() async throws {
        let store = MetadataTaskStore()
        let cache = cache(store)
        await cache.waitForInitialLoad()
        let later = Date(timeIntervalSince1970: 456)
        store.beforeNextSave { cache.setLastModifiedAt(later) }
        cache.setLastDownloadedETag("etag")
        try await waitForSaves(cache)
        XCTAssertEqual(store.snapshot.saves, 2)
        XCTAssertEqual(store.snapshot.peak, 1)
        XCTAssertEqual(store.snapshot.metadata.lastDownloadedETag, "etag")
        XCTAssertEqual(store.snapshot.metadata.lastModifiedAt, later)
    }

    func testNewerMutationDuringFailedSaveStillRetriesCompleteSnapshot() async throws {
        let store = MetadataTaskStore()
        let cache = cache(store)
        await cache.waitForInitialLoad()
        let later = Date(timeIntervalSince1970: 789)
        store.beforeNextSave {
            cache.setLastModifiedAt(later)
            throw TestError.requested
        }
        cache.setLastDownloadedETag("etag")
        try await waitForSaves(cache)
        XCTAssertEqual(store.snapshot.saves, 2)
        XCTAssertEqual(store.snapshot.peak, 1)
        XCTAssertEqual(store.snapshot.metadata.lastDownloadedETag, "etag")
        XCTAssertEqual(store.snapshot.metadata.lastModifiedAt, later)
    }

    func testFailureRetiresAndIdenticalAssignmentCanRetry() async throws {
        let store = MetadataTaskStore()
        let cache = cache(store)
        await cache.waitForInitialLoad()
        store.beforeNextSave { throw TestError.requested }
        cache.setLastDownloadedETag("etag")
        do {
            try await waitForSaves(cache)
            XCTFail("Expected persistence failure")
        } catch is DownloadMetadataPersistenceError {}
        XCTAssertEqual(store.snapshot.saves, 1)
        cache.setLastDownloadedETag("etag")
        try await waitForSaves(cache)
        XCTAssertEqual(store.snapshot.saves, 2)
        XCTAssertEqual(store.snapshot.metadata.lastDownloadedETag, "etag")
    }

    func testConcurrentFastMutationsCannotLeaveAStaleCompletedTaskRegistered() async throws {
        let store = MetadataTaskStore()
        let cache = cache(store)
        await cache.waitForInitialLoad()
        for round in 0..<6 {
            await withTaskGroup(of: Void.self) { group in
                for worker in 0..<12 {
                    group.addTask {
                        for value in 0..<24 {
                            cache.setLastDownloadedETag("\(round)-\(worker)-\(value)")
                            cache.setLastModifiedAt(Date(timeIntervalSince1970: Double(value)))
                        }
                    }
                }
            }
            let finalTag = "final-\(round)"
            let finalDate = Date(timeIntervalSince1970: Double(10_000 + round))
            cache.setLastDownloadedETag(finalTag)
            cache.setLastModifiedAt(finalDate)
            try await waitForSaves(cache)
            XCTAssertEqual(store.snapshot.metadata.lastDownloadedETag, finalTag)
            XCTAssertEqual(store.snapshot.metadata.lastModifiedAt, finalDate)
            XCTAssertEqual(cache.currentMetadata(), store.snapshot.metadata)
        }
        XCTAssertEqual(store.snapshot.loads, 1)
        XCTAssertEqual(store.snapshot.peak, 1)
    }

    func testLoadedUnchangedValuesDoNotStartASave() async throws {
        let store = MetadataTaskStore(metadata: DownloadMetadata(lastDownloadedETag: "unchanged"))
        let cache = cache(store)
        await cache.waitForInitialLoad()
        cache.setLastDownloadedETag("unchanged")
        cache.setLastModifiedAt(nil)
        try await waitForSaves(cache)
        XCTAssertEqual(store.snapshot.saves, 0)
    }
}
