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
    private var hasStartedInitialLoad = false
    private var initialLoadTask: Task<Void, Never>?
    private var observationRelays: [DownloadMetadataObservationRelay] = []
    private var isSaveScheduled = false
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
        let loadState = withLock {
            observationRelays.removeAll { $0.owner == nil }
            observationRelays.append(observationRelay)
            if hasCompletedInitialLoad {
                return (shouldStart: false, shouldNotify: true)
            }
            guard !hasStartedInitialLoad else {
                return (shouldStart: false, shouldNotify: false)
            }
            hasStartedInitialLoad = true
            return (shouldStart: true, shouldNotify: false)
        }
        if loadState.shouldNotify {
            notifyObservers([observationRelay])
        }
        guard loadState.shouldStart else { return }

        let task = Task { @DownloadActor [weak self] in
            guard let self else { return }
            do {
                mergeInitialMetadata(try store.loadMetadata(for: url))
            } catch {
                finishInitialLoadWithoutStoredMetadata()
            }
            notifyObservers()
        }
        withLock {
            initialLoadTask = task
        }
    }

    func waitForInitialLoad() async {
        while true {
            let state = withLock {
                (hasCompletedInitialLoad, initialLoadTask)
            }
            if state.0 { return }
            if let task = state.1 {
                await task.value
                return
            }
            await Task.yield()
        }
    }

    func currentMetadata() -> DownloadMetadata {
        withLock { metadata }
    }

    func waitForPendingSaves() async throws {
        await waitForInitialLoad()
        while true {
            let state = withLock {
                (task: saveTask, isScheduled: isSaveScheduled, error: latestSaveError)
            }
            if let task = state.task {
                try await task.value
                continue
            }
            if let error = state.error {
                throw error
            }
            if state.isScheduled {
                await Task.yield()
                continue
            }
            return
        }
    }

    func setLastDownloadedETag(_ value: String?) {
        update(.lastDownloadedETag) { $0.lastDownloadedETag = value }
    }

    func setLastCheckedETagAt(_ value: Date?) {
        update(.lastCheckedETagAt) { $0.lastCheckedETagAt = value }
    }

    func setLastDownloadedAt(_ value: Date?) {
        update(.lastDownloadedAt) { $0.lastDownloadedAt = value }
    }

    func setLastModifiedAt(_ value: Date?) {
        update(.lastModifiedAt) { $0.lastModifiedAt = value }
    }

    private func update(
        _ field: DownloadMetadataFields,
        mutation: (inout DownloadMetadata) -> Void
    ) {
        let shouldStartSaveTask = withLock {
            mutation(&metadata)
            mutationRevision &+= 1
            dirtyFields.insert(field)
            latestSaveError = nil
            if !hasCompletedInitialLoad {
                fieldsChangedBeforeInitialLoad.insert(field)
            }
            guard !isSaveScheduled else { return false }
            isSaveScheduled = true
            return true
        }
        notifyObservers()
        guard shouldStartSaveTask else { return }

        let task = Task { @DownloadActor [self] in
            try await savePendingChanges()
        }
        withLock {
            if isSaveScheduled {
                saveTask = task
            }
        }
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
            hasCompletedInitialLoad = true
        }
    }

    private func finishInitialLoadWithoutStoredMetadata() {
        withLock {
            fieldsChangedBeforeInitialLoad = []
            hasCompletedInitialLoad = true
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
            } catch {
                let persistenceError = DownloadMetadataPersistenceError(error)
                withLock {
                    dirtyFields.formUnion(pending.1)
                    latestSaveError = persistenceError
                    isSaveScheduled = false
                    saveTask = nil
                }
                throw persistenceError
            }

            let isCurrent = withLock {
                guard mutationRevision == pending.2 else { return false }
                isSaveScheduled = false
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
