import Foundation

enum DownloadProgressMetrics {
    static func knownByteCount(
        totalUnitCount: Int64,
        completedUnitCount: Int64
    ) -> UInt64? {
        guard totalUnitCount >= 0 else { return nil }
        // The hardened URLSession adapter clamps Foundation's unknown -1
        // total to zero so Progress remains well-behaved. Once bytes arrive,
        // zero cannot describe the whole response and remains unknown.
        if totalUnitCount == 0, completedUnitCount > 0 {
            return nil
        }
        return UInt64(totalUnitCount)
    }
}
