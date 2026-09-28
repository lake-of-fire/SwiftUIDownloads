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
    let url: URL
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

    func cache(store: any DownloadableMetadataStore, url: URL) -> DownloadMetadataCache {
        let identity = DownloadMetadataCacheIdentity(
            namespace: store.metadataCacheNamespace,
            url: url
        )
        lock.lock()
        defer { lock.unlock() }
        if let cache = caches[identity]?.value {
            return cache
        }
        let cache = DownloadMetadataCache(store: store, url: url)
        caches[identity] = WeakDownloadMetadataCache(cache)
        if caches.count > 64 {
            caches = caches.filter { $0.value.value != nil }
        }
        return cache
    }
}

final class DownloadMetadataCache: @unchecked Sendable {
    private let store: any DownloadableMetadataStore
    private let url: URL
    private let lock = NSLock()
    private var metadata = DownloadMetadata()
    private var fieldsChangedBeforeInitialLoad: DownloadMetadataFields = []
    private var dirtyFields: DownloadMetadataFields = []
    private var hasCompletedInitialLoad = false
    private var knownStoredFields: DownloadMetadataFields = []
    private var initialLoadTask: Task<Void, Never>?
    private var observationRelays: [DownloadMetadataObservationRelay] = []
    private var saveTask: Task<Void, Error>?
    private var latestSaveError: DownloadMetadataPersistenceError?
    private var mutationRevision: UInt64 = 0

    static func shared(store: any DownloadableMetadataStore, url: URL) -> DownloadMetadataCache {
        DownloadMetadataCacheRegistry.shared.cache(store: store, url: url)
    }

    init(store: any DownloadableMetadataStore, url: URL) {
        self.store = store
        self.url = url
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
                mergeInitialMetadata(try store.loadMetadata(for: url))
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
                throw error
            }
            return
        }
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

    private func mergeInitialMetadata(_ storedMetadata: DownloadMetadata) {
        withLock {
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
                return (metadata, fields, mutationRevision)
            }
            do {
                try store.saveMetadata(pending.0, fields: pending.1, for: url)
                withLock {
                    knownStoredFields.formUnion(pending.1)
                }
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

    private func withLock<Result>(_ operation: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
