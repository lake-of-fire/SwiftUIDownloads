import Foundation
import Combine

/// Validators from the successful GET which supplied this import's bytes.
/// Nil context denotes local/recovered input without an authoritative response.
public struct DownloadImportResponse: Sendable {
    public let sourceURL: URL
    public let finalResponseURL: URL?
    public let checkedAt: Date
    public let etag: String?
    public let lastModifiedAt: Date?

    public init(
        sourceURL: URL, finalResponseURL: URL?, checkedAt: Date,
        etag: String?, lastModifiedAt: Date?
    ) {
        self.sourceURL = sourceURL
        self.finalResponseURL = finalResponseURL
        self.checkedAt = checkedAt
        self.etag = etag
        self.lastModifiedAt = lastModifiedAt
    }
}

public final class ImportableDownloadable: Downloadable, @unchecked Sendable {
    public typealias ImportProgressHandler = @Sendable (_ progress: Double?, _ status: String?) -> Void
    public typealias ImportHandler = @Sendable (URL, @escaping ImportProgressHandler) async throws -> Void
    public typealias ResponseImportHandler = @Sendable (
        URL, DownloadImportResponse?, @escaping ImportProgressHandler
    ) async throws -> Void
    public typealias ImportedCheck = @Sendable () async -> Bool
    
    public let importHandler: ImportHandler
    public let responseImportHandler: ResponseImportHandler?
    public let isImported: ImportedCheck
    public let deleteAfterImport: Bool
    public let glossaryFTSEnabled: Bool
    public let importOperationIdentifier: String?
    @MainActor @Published public var lastImportError: Error?
    @MainActor @Published public var importProgress: Double?
    @MainActor @Published public var importStatusText: String?
    
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
        responseImportHandler: ResponseImportHandler? = nil,
        isImported: @escaping ImportedCheck,
        importHandler: @escaping ImportHandler
    ) {
        self.importHandler = importHandler
        self.responseImportHandler = responseImportHandler
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
            ),
            usesResponseImportHandler: responseImportHandler != nil
        )
    }
}
