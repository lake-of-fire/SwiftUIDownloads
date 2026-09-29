import Foundation
import Combine

public final class ImportableDownloadable: Downloadable, @unchecked Sendable {
    public typealias ImportProgressHandler = @Sendable (_ progress: Double?, _ status: String?) -> Void
    public typealias ImportHandler = @Sendable (URL, @escaping ImportProgressHandler) async throws -> Void
    public typealias ImportedCheck = @Sendable () async -> Bool
    
    public let importHandler: ImportHandler
    public let isImported: ImportedCheck
    public let deleteAfterImport: Bool
    public let glossaryFTSEnabled: Bool
    public let importOperationIdentifier: String?
    @MainActor @Published public var lastImportError: Error?
    @MainActor @Published public var importProgress: Double?
    @MainActor @Published public var importStatusText: String?

    private let importObservationLock = NSLock()
    private var importObservationGeneration = UUID()
    
    public init(
        url: URL,
        mirrorURL: URL? = nil,
        name: String,
        localDestination: URL,
        localDestinationChecksum: String? = nil,
        preservedLocalArtifactDirectories: Set<URL> = [],
        deleteAfterImport: Bool = true,
        glossaryFTSEnabled: Bool = false,
        importOperationIdentifier: String? = nil,
        metadataStore: (any DownloadableMetadataStore)? = nil,
        isImported: @escaping ImportedCheck,
        importHandler: @escaping ImportHandler
    ) {
        self.importHandler = importHandler
        self.isImported = isImported
        self.deleteAfterImport = deleteAfterImport
        self.glossaryFTSEnabled = glossaryFTSEnabled
        self.importOperationIdentifier = DownloadExecutionConfigurationSignature
            .normalizedOptionalString(importOperationIdentifier)
        super.init(
            url: url,
            mirrorURL: mirrorURL,
            name: name,
            localDestination: localDestination,
            localDestinationChecksum: localDestinationChecksum,
            preservedLocalArtifactDirectories: preservedLocalArtifactDirectories,
            metadataStore: metadataStore
        )
    }

    func beginImportObservation() -> UUID {
        importObservationLock.lock()
        defer { importObservationLock.unlock() }
        importObservationGeneration = UUID()
        return importObservationGeneration
    }

    func importObservationIsCurrent(_ generation: UUID) -> Bool {
        importObservationLock.lock()
        defer { importObservationLock.unlock() }
        return importObservationGeneration == generation
    }

    func endImportObservation(_ generation: UUID) {
        importObservationLock.lock()
        defer { importObservationLock.unlock() }
        guard importObservationGeneration == generation else { return }
        importObservationGeneration = UUID()
    }

    public override var executionConfigurationSignature: DownloadExecutionConfigurationSignature {
        DownloadExecutionConfigurationSignature(
            mirrorURL: mirrorURL,
            localDestinationChecksum: localDestinationChecksum,
            preservedLocalArtifactDirectories: preservedLocalArtifactDirectories,
            metadataCacheNamespace: metadataStore.metadataCacheNamespace,
            kind: .importable(
                deleteAfterImport: deleteAfterImport,
                glossaryFTSEnabled: glossaryFTSEnabled,
                importOperationIdentifier: importOperationIdentifier
            )
        )
    }
}
