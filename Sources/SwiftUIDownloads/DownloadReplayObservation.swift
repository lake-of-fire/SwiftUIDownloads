import Combine
import Foundation

/// Mirrors current values while a compatible descriptor participates in an
/// operation. Publication is observation only: it never decides work ownership.
@MainActor
final class DownloadReplayObservation {
    private let owner: Downloadable
    private let replay: Downloadable
    private var subscription: AnyCancellable?
    private var isStopped = false

    init(owner: Downloadable, replay: Downloadable) {
        self.owner = owner
        self.replay = replay
        subscription = owner.objectWillChange.sink { [weak self] in
            // ObservableObject emits before mutation. Read after the current
            // main-actor transition, never forward the captured intermediate value.
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped else { return }
                Self.copyState(from: self.owner, to: self.replay)
            }
        }
        Self.copyState(from: owner, to: replay)
    }

    func stop(copyFinalState: Bool) {
        isStopped = true
        subscription?.cancel()
        subscription = nil
        if copyFinalState {
            Self.copyState(from: owner, to: replay)
        }
    }

    static func copyState(from owner: Downloadable, to replay: Downloadable) {
        replay.downloadProgress = owner.downloadProgress
        replay.isFailed = owner.isFailed
        replay.isActive = owner.isActive
        replay.isFinishedDownloading = owner.isFinishedDownloading
        replay.isFinishedProcessing = owner.isFinishedProcessing
        replay.fileSize = owner.fileSize
        if let replayImportable = replay as? ImportableDownloadable,
           let ownerImportable = owner as? ImportableDownloadable {
            replayImportable.lastImportError = ownerImportable.lastImportError
            replayImportable.importProgress = ownerImportable.importProgress
            replayImportable.importStatusText = ownerImportable.importStatusText
        }
    }
}
