import Foundation

enum DownloadProgressMetrics {
    static func knownByteCount(totalUnitCount: Int64, completedUnitCount: Int64) -> UInt64? {
        guard totalUnitCount >= 0 else { return nil }
        // The URLSession adapter clamps an unknown total to zero. Once bytes arrive,
        // zero cannot describe the whole response and remains unknown.
        if totalUnitCount == 0 {
            return completedUnitCount == 0 ? 0 : nil
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

    static func determinateFraction(for transfer: URLResourceDownloadTaskProgress) -> Double? {
        switch transfer {
        case .uninitiated, .waitingForResponse:
            return nil
        case .downloading(let progress):
            return determinateFraction(for: progress)
        case .completed:
            return transfer.fractionCompleted
        }
    }

    static func statusText(for progress: Progress) -> String {
        let completedCount = progress.completedUnitCount
        let completed = megabytes(completedCount)
        let totalText: String
        if let total = knownByteCount(
            totalUnitCount: progress.totalUnitCount,
            completedUnitCount: completedCount
        ) {
            totalText = "\(completed)MB of \(megabytes(Int64(total)))MB"
        } else {
            totalText = "\(completed)MB downloaded"
        }
        guard let throughput = progress.throughput, throughput >= 0 else { return totalText }
        return totalText + " at \(megabytes(Int64(throughput)))MB/s"
    }

    private static func megabytes(_ bytes: Int64) -> String {
        let value = round((Double(max(0, bytes)) / 1_000_000) * 10) / 10
        return String(value)
    }
}
