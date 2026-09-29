import Foundation

enum DownloadProgressMetrics {
    static func knownByteCount(totalUnitCount: Int64) -> UInt64? {
        guard totalUnitCount >= 0 else { return nil }
        return UInt64(totalUnitCount)
    }
}
