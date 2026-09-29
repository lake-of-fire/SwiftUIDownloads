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

    static func statusText(for progress: Progress) -> String {
        let completed = megabytes(progress.completedUnitCount)
        var text: String
        if progress.totalUnitCount >= 0 {
            text = completed + "MB of " + megabytes(progress.totalUnitCount) + "MB"
        } else {
            text = completed + "MB downloaded"
        }
        if let throughput = progress.throughput, throughput >= 0 {
            text += " at " + megabytes(throughput) + "MB/s"
        }
        return text
    }

    private static func megabytes(_ bytes: Int64) -> String {
        let nonnegative = max(0, bytes)
        let value = round((Double(nonnegative) / 1_000_000) * 10) / 10
        return String(value)
    }

}
