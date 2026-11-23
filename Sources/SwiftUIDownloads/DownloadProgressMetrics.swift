import Foundation

enum DownloadProgressMetrics {
    static func knownByteCount(
        totalUnitCount: Int64,
        completedUnitCount: Int64
    ) -> UInt64? {
        guard totalUnitCount >= 0 else { return nil }
        // A zero total cannot describe a transfer that has already delivered bytes.
        if totalUnitCount == 0, completedUnitCount > 0 {
            return nil
        }
        return UInt64(totalUnitCount)
    }

    static func determinateFraction(for progress: Progress) -> Double? {
        guard knownByteCount(
            totalUnitCount: progress.totalUnitCount,
            completedUnitCount: progress.completedUnitCount
        ) != nil else { return nil }
        return progress.fractionCompleted
    }

    static func statusText(for progress: Progress) -> String {
        let completedCount = progress.completedUnitCount
        let completed = megabytes(completedCount)
        var text: String
        if let knownTotal = knownByteCount(
            totalUnitCount: progress.totalUnitCount,
            completedUnitCount: completedCount
        ) {
            text = completed + "MB of " + megabytes(Int64(knownTotal)) + "MB"
        } else {
            text = completed + "MB downloaded"
        }
        if let throughput = progress.throughput, throughput >= 0 {
            text += " at " + megabytes(Int64(throughput)) + "MB/s"
        }
        return text
    }

    private static func megabytes(_ bytes: Int64) -> String {
        let nonnegative = max(0, bytes)
        let value = round((Double(nonnegative) / 1_000_000) * 10) / 10
        return String(value)
    }

}
