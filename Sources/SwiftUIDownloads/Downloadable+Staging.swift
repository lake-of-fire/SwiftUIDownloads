import Foundation
import CryptoKit

extension Downloadable {
    var uiTestArtifactCache: UITestDictionaryArtifactCache? {
        // Importers may mutate their input, so only ordinary downloads can
        // opt in to reuse. Production and signed CloudKit gates never reuse it.
        guard !(self is ImportableDownloadable), localDestinationChecksum != nil else { return nil }
        return UITestDictionaryArtifactCache.isolatedCache(
            enabled: allowsUITestArtifactReuse,
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment,
            temporaryDirectory: FileManager.default.temporaryDirectory,
            destination: localDestination
        )
    }

    var stagingPaths: DownloadStagingPaths {
        let ownerID = SHA256.hash(data: Data(id.taskDescription.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return DownloadStagingPaths(destination: localDestination, ownerID: ownerID)
    }

    func decompressionStagingURL(operationID: UUID) -> URL {
        stagingPaths.url(for: .expanded, operationID: operationID)
    }
}
