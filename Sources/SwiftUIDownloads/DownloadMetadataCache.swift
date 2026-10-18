import Foundation

final class DownloadMetadataObservationRelay: @unchecked Sendable {
    weak var owner: Downloadable?

    @MainActor
    func metadataDidChange() {
        owner?.objectWillChange.send()
    }
}

public struct DownloadMetadataPersistenceError: Error, Equatable, Sendable {
    public let description: String

    init(_ error: any Error) {
        description = String(describing: error)
    }
}

private struct DownloadMetadataCacheIdentity: Hashable {
    let namespace: String
    let sourceURL: URL
    let destinationURL: URL
}

private final class WeakDownloadMetadataCache {
    weak var value: DownloadMetadataCache?

    init(_ value: DownloadMetadataCache) {
        self.value = value
    }
}

private final class DownloadMetadataCacheRegistry: @unchecked Sendable {
    static let shared = DownloadMetadataCacheRegistry()

    private let lock = NSLock()
    private var caches: [DownloadMetadataCacheIdentity: WeakDownloadMetadataCache] = [:]

    func cache(
        store: any DownloadableMetadataStore,
        sourceURL: URL,
        destinationURL: URL
    ) -> DownloadMetadataCache {
        let identity = DownloadMetadataCacheIdentity(
            namespace: store.metadataCacheNamespace,
            sourceURL: DownloadOperationKey.standardizedSourceURL(sourceURL),
            destinationURL: destinationURL.absoluteURL.standardizedFileURL
        )
        lock.lock()
        defer { lock.unlock() }
        if let cache = caches[identity]?.value {
            return cache
        }
        let cache = DownloadMetadataCache(
            store: store,
            sourceURL: sourceURL,
            destinationURL: destinationURL
        )
        caches[identity] = WeakDownloadMetadataCache(cache)
        if caches.count > 64 {
            caches = caches.filter { $0.value.value != nil }
        }
        return cache
    }
}

final class DownloadMetadataCache: @unchecked Sendable {
    private let store: any DownloadableMetadataStore
    private let sourceURL: URL
    private let destinationURL: URL
    private let lock = NSLock()
    private var metadata = DownloadMetadata()
    private var fieldsChangedBeforeInitialLoad: DownloadMetadataFields = []
    private var dirtyFields: DownloadMetadataFields = []
    private var hasCompletedInitialLoad = false
    private var knownStoredFields: DownloadMetadataFields = []
    private var initialLoadTask: Task<Void, Never>?
    private var observationRelays: [DownloadMetadataObservationRelay] = []
    private var saveTask: Task<Void, Error>?
    private var latestSaveError: (any Error)?
    private var persistenceSnapshot: DownloadMetadataSnapshot?
    private var mutationRevision: UInt64 = 0

    static func shared(
        store: any DownloadableMetadataStore,
        sourceURL: URL,
        destinationURL: URL
    ) -> DownloadMetadataCache {
        DownloadMetadataCacheRegistry.shared.cache(
            store: store,
            sourceURL: sourceURL,
            destinationURL: destinationURL
        )
    }

    init(
        store: any DownloadableMetadataStore,
        sourceURL: URL,
        destinationURL: URL
    ) {
        self.store = store
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
    }

    func startLoading(observationRelay: DownloadMetadataObservationRelay) {
        let shouldNotify = withLock {
            observationRelays.removeAll { $0.owner == nil }
            observationRelays.append(observationRelay)
            if hasCompletedInitialLoad { return true }
            _ = initialLoadTaskIfNeededLocked()
            return false
        }
        if shouldNotify {
            notifyObservers([observationRelay])
        }
    }

    /// Called only while holding lock. The task cannot merge/retire its state
    /// before the same critical section has registered its handle.
    private func initialLoadTaskIfNeededLocked() -> Task<Void, Never>? {
        guard !hasCompletedInitialLoad else { return nil }
        if let initialLoadTask { return initialLoadTask }
        let task = Task { @DownloadActor [self] in
            do {
                mergeInitialMetadata(try store.loadMetadataSnapshot(
                    sourceURL: sourceURL,
                    destinationURL: destinationURL
                ))
            } catch {
                finishInitialLoadWithoutStoredMetadata()
            }
            notifyObservers()
        }
        initialLoadTask = task
        return task
    }

    func waitForInitialLoad() async {
        // Loading is independent of UI observation. A write made before a
        // relay is attached must still be able to load and persist its fields.
        let task = withLock { initialLoadTaskIfNeededLocked() }
        await task?.value
    }

    func currentMetadata() -> DownloadMetadata {
        withLock { metadata }
    }

    func waitForPendingSaves() async throws {
        await waitForInitialLoad()
        while true {
            let state = withLock {
                (task: saveTask, error: latestSaveError)
            }
            if let task = state.task {
                // Re-read the current owner/error after this owner retires.
                // A newer retry may already have superseded its failure.
                _ = await task.result
                continue
            }
            if let error = state.error {
                if let snapshotError = error as? DownloadMetadataSnapshotError,
                   case .superseded = snapshotError {
                    withLock {
                        if saveTask == nil, latestSaveError is DownloadMetadataSnapshotError {
                            latestSaveError = nil
                        }
                    }
                }
                throw error
            }
            return
        }
    }

    @DownloadActor
    func remoteCheckSnapshot() async throws -> DownloadMetadataSnapshot {
        try await waitForPendingSaves()
        return try store.loadMetadataSnapshot(sourceURL: sourceURL, destinationURL: destinationURL)
    }

    @DownloadActor
    func remoteCheckSnapshotIsCurrent(_ expected: DownloadMetadataSnapshot) async throws -> Bool {
        try await waitForPendingSaves()
        try Task.checkCancellation()
        let current = try store.loadMetadataSnapshot(sourceURL: sourceURL, destinationURL: destinationURL)
        guard current.persistenceIdentity != expected.persistenceIdentity || current.metadata != expected.metadata else {
            return true
        }
        withLock {
            if dirtyFields.isEmpty, saveTask == nil {
                metadata = current.metadata
                persistenceSnapshot = current
                knownStoredFields = .all
            }
        }
        notifyObservers()
        return false
    }

    @DownloadActor
    func publishUnchangedRemoteCheck(
        snapshot: DownloadMetadataSnapshot, checkedAt: Date, etag: String?, lastModifiedAt: Date?
    ) async throws {
        try await waitForPendingSaves()
        var checked = snapshot.metadata
        checked.lastCheckedETagAt = checkedAt
        var fields: DownloadMetadataFields = [.lastCheckedETagAt]
        if let etag { checked.lastDownloadedETag = etag; fields.insert(.lastDownloadedETag) }
        if let lastModifiedAt { checked.lastModifiedAt = lastModifiedAt; fields.insert(.lastModifiedAt) }
        defer {
            // A stale HEAD is discarded, never merged into a newer cache owner
            // or retained as dirty data for a later save retry.
            if let stored = try? store.loadMetadataSnapshot(sourceURL: sourceURL, destinationURL: destinationURL) {
                withLock {
                    if dirtyFields.isEmpty, saveTask == nil {
                        metadata = stored.metadata
                        persistenceSnapshot = stored
                        knownStoredFields = .all
                    }
                }
                notifyObservers()
            }
        }
        try Task.checkCancellation()
        try store.saveMetadata(
            checked, fields: fields, sourceURL: sourceURL, destinationURL: destinationURL,
            expectedSnapshot: snapshot
        )
    }

    @DownloadActor
    func adoptCommittedImport(_ receipt: DownloadImportReceipt) async throws {
        do { try await waitForPendingSaves() }
        catch { throw DownloadImportReceiptError.metadataNotReady }
        do { try receipt.validate() }
        catch {
            if let stored = try? store.loadMetadataSnapshot(sourceURL: sourceURL, destinationURL: destinationURL) {
                withLock {
                    if dirtyFields.isEmpty, saveTask == nil {
                        metadata = stored.metadata
                        persistenceSnapshot = stored
                        knownStoredFields = .all
                    }
                }
                notifyObservers()
            }
            throw error
        }
        try withLock {
            guard dirtyFields.isEmpty, saveTask == nil else {
                throw DownloadImportReceiptError.metadataNotReady
            }
            metadata = receipt.metadata
            persistenceSnapshot = DownloadMetadataSnapshot(
                metadata: receipt.metadata, persistenceIdentity: receipt.generationIdentifier
            )
            knownStoredFields = .all
            latestSaveError = nil
            mutationRevision &+= 1
        }
        notifyObservers()
    }

    func setLastDownloadedETag(_ value: String?) {
        update(.lastDownloadedETag) { metadata, isStoredFieldKnown in
            guard !isStoredFieldKnown || metadata.lastDownloadedETag != value else { return false }
            metadata.lastDownloadedETag = value
            return true
        }
    }

    func setLastCheckedETagAt(_ value: Date?) {
        update(.lastCheckedETagAt) { metadata, isStoredFieldKnown in
            guard !isStoredFieldKnown || metadata.lastCheckedETagAt != value else { return false }
            metadata.lastCheckedETagAt = value
            return true
        }
    }

    func setLastDownloadedAt(_ value: Date?) {
        update(.lastDownloadedAt) { metadata, isStoredFieldKnown in
            guard !isStoredFieldKnown || metadata.lastDownloadedAt != value else { return false }
            metadata.lastDownloadedAt = value
            return true
        }
    }

    func setLastModifiedAt(_ value: Date?) {
        update(.lastModifiedAt) { metadata, isStoredFieldKnown in
            guard !isStoredFieldKnown || metadata.lastModifiedAt != value else { return false }
            metadata.lastModifiedAt = value
            return true
        }
    }

    private func update(
        _ field: DownloadMetadataFields,
        mutation: (inout DownloadMetadata, _ isStoredFieldKnown: Bool) -> Bool
    ) {
        let didMutate = withLock {
            let changed = mutation(&metadata, knownStoredFields.contains(field))
            guard changed || (latestSaveError != nil && !dirtyFields.isEmpty) else { return false }
            mutationRevision &+= 1
            dirtyFields.insert(field)
            latestSaveError = nil
            if !hasCompletedInitialLoad {
                fieldsChangedBeforeInitialLoad.insert(field)
            }
            if saveTask == nil {
                // Register before releasing the lock. A fast older save can
                // otherwise finish, let a successor start, then overwrite that
                // successor's handle when the original setter finally resumes.
                saveTask = Task { @DownloadActor [self] in
                    try await savePendingChanges()
                }
            }
            return true
        }
        if didMutate { notifyObservers() }
    }

    private func mergeInitialMetadata(_ snapshot: DownloadMetadataSnapshot) {
        let storedMetadata = snapshot.metadata
        withLock {
            persistenceSnapshot = snapshot
            let changedFields = fieldsChangedBeforeInitialLoad
            if !changedFields.contains(.lastDownloadedETag) {
                metadata.lastDownloadedETag = storedMetadata.lastDownloadedETag
            }
            if !changedFields.contains(.lastCheckedETagAt) {
                metadata.lastCheckedETagAt = storedMetadata.lastCheckedETagAt
            }
            if !changedFields.contains(.lastDownloadedAt) {
                metadata.lastDownloadedAt = storedMetadata.lastDownloadedAt
            }
            if !changedFields.contains(.lastModifiedAt) {
                metadata.lastModifiedAt = storedMetadata.lastModifiedAt
            }
            fieldsChangedBeforeInitialLoad = []
            knownStoredFields = .all
            hasCompletedInitialLoad = true
            initialLoadTask = nil
        }
    }

    private func finishInitialLoadWithoutStoredMetadata() {
        withLock {
            fieldsChangedBeforeInitialLoad = []
            hasCompletedInitialLoad = true
            initialLoadTask = nil
        }
    }

    @DownloadActor
    private func savePendingChanges() async throws {
        await waitForInitialLoad()
        while true {
            let pending = withLock {
                let fields = dirtyFields
                dirtyFields = []
                return (metadata, fields, mutationRevision, persistenceSnapshot)
            }
            do {
                if let snapshot = pending.3 {
                    try store.saveMetadata(
                        pending.0, fields: pending.1, sourceURL: sourceURL, destinationURL: destinationURL,
                        expectedSnapshot: snapshot
                    )
                } else {
                    try store.saveMetadata(
                        pending.0, fields: pending.1, sourceURL: sourceURL, destinationURL: destinationURL
                    )
                }
                withLock {
                    knownStoredFields.formUnion(pending.1)
                    if let snapshot = pending.3 {
                        var stored = snapshot.metadata
                        if pending.1.contains(.lastDownloadedETag) { stored.lastDownloadedETag = pending.0.lastDownloadedETag }
                        if pending.1.contains(.lastCheckedETagAt) { stored.lastCheckedETagAt = pending.0.lastCheckedETagAt }
                        if pending.1.contains(.lastDownloadedAt) { stored.lastDownloadedAt = pending.0.lastDownloadedAt }
                        if pending.1.contains(.lastModifiedAt) { stored.lastModifiedAt = pending.0.lastModifiedAt }
                        persistenceSnapshot = DownloadMetadataSnapshot(
                            metadata: stored, persistenceIdentity: snapshot.persistenceIdentity
                        )
                    }
                }
            } catch DownloadMetadataSnapshotError.superseded {
                let current = try? store.loadMetadataSnapshot(sourceURL: sourceURL, destinationURL: destinationURL)
                withLock {
                    // Retire the old owner and every dirty mutation captured
                    // against it. Never retry those fields against a new token.
                    dirtyFields = []
                    fieldsChangedBeforeInitialLoad = []
                    persistenceSnapshot = current
                    if let current { metadata = current.metadata; knownStoredFields = .all }
                    latestSaveError = DownloadMetadataSnapshotError.superseded
                    saveTask = nil
                    mutationRevision &+= 1
                }
                notifyObservers()
                throw DownloadMetadataSnapshotError.superseded
            } catch {
                let persistenceError = DownloadMetadataPersistenceError(error)
                let shouldRetryNewerMutation = withLock {
                    dirtyFields.formUnion(pending.1)
                    guard mutationRevision != pending.2 else {
                        latestSaveError = persistenceError
                        saveTask = nil
                        return false
                    }

                    // A mutation arrived while this save was in flight. That
                    // mutation observed an owned save task and therefore did
                    // not create another one. Keep this task as the owner and
                    // immediately retry the complete dirty snapshot instead of
                    // stranding the newer value until some unrelated mutation.
                    latestSaveError = nil
                    return true
                }
                if shouldRetryNewerMutation {
                    continue
                }
                throw persistenceError
            }

            let isCurrent = withLock {
                guard mutationRevision == pending.2 else { return false }
                saveTask = nil
                return true
            }
            if isCurrent { return }
        }
    }

    private func notifyObservers(_ relays: [DownloadMetadataObservationRelay]? = nil) {
        let relays = relays ?? withLock {
            observationRelays.removeAll { $0.owner == nil }
            return observationRelays
        }
        Task { @MainActor in
            for relay in relays {
                relay.metadataDidChange()
            }
        }
    }

    private func withLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
