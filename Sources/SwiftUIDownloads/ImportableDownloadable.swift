import Foundation
import Combine

public final class ImportableDownloadable: Downloadable {
    public typealias ImportProgressHandler = @Sendable (_ progress: Double?, _ status: String?) -> Void
    public typealias ImportHandler = @Sendable (URL, @escaping ImportProgressHandler) async throws -> Void
    public typealias ImportedCheck = @Sendable () async -> Bool
    
    public let importHandler: ImportHandler
    public let isImported: ImportedCheck
    public let deleteAfterImport: Bool
    @MainActor @Published public var lastImportError: Error?
    @MainActor @Published public var importProgress: Double?
    @MainActor @Published public var importStatusText: String?
    
    public init(
        url: URL,
        mirrorURL: URL? = nil,
        name: String,
        localDestination: URL,
        localDestinationChecksum: String? = nil,
        deleteAfterImport: Bool = true,
        metadataStore: (any DownloadableMetadataStore)? = nil,
        isImported: @escaping ImportedCheck,
        importHandler: @escaping ImportHandler
    ) {
        self.importHandler = importHandler
        self.isImported = isImported
        self.deleteAfterImport = deleteAfterImport
        super.init(
            url: url,
            mirrorURL: mirrorURL,
            name: name,
            localDestination: localDestination,
            localDestinationChecksum: localDestinationChecksum,
            metadataStore: metadataStore
        )
    }
}
