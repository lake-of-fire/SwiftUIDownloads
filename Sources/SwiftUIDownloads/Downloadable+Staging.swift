import Foundation
import CryptoKit

extension Downloadable {
    var stagingPaths: DownloadStagingPaths {
        let ownerID = SHA256.hash(data: Data(id.taskDescription.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return DownloadStagingPaths(destination: localDestination, ownerID: ownerID)
    }

    func decompressionStagingURL(operationID: UUID) -> URL {
        stagingPaths.url(for: .expanded, operationID: operationID)
    }
}
