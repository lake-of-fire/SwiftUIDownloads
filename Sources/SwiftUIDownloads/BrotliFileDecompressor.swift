import Foundation
import Compression
import Brotli

enum BrotliFileDecompressionError: LocalizedError {
    case failedToCreateOutputFile(URL)
    case invalidBrotliData

    var errorDescription: String? {
        switch self {
        case .failedToCreateOutputFile(let url):
            return "Failed to create decompression output file at \(url.path)"
        case .invalidBrotliData:
            return "Invalid Brotli data"
        }
    }
}

enum BrotliFileDecompressor {
    private static let inputChunkSize = 64 * 1024
    private static let outputChunkSize = 64 * 1024

    static func decompressFile(at sourceURL: URL, to destinationURL: URL) throws {
        if #available(iOS 16.1, macOS 13.1, *) {
            try decompressWithCompressionFramework(sourceURL: sourceURL, destinationURL: destinationURL)
            return
        }

        // iOS 15/macOS 12 fallback still avoids Data(contentsOf:) by reading incrementally.
        try decompressWithLegacyNSData(sourceURL: sourceURL, destinationURL: destinationURL)
    }

    @available(iOS 16.1, macOS 13.1, *)
    private static func decompressWithCompressionFramework(sourceURL: URL, destinationURL: URL) throws {
        try createDestinationDirectory(for: destinationURL)
        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw BrotliFileDecompressionError.failedToCreateOutputFile(destinationURL)
        }

        let inputHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? inputHandle.close() }
        let outputHandle = try FileHandle(forWritingTo: destinationURL)
        defer { try? outputHandle.close() }

        var readError: Error?
        var reachedEOF = false

        let algorithm = Algorithm(rawValue: COMPRESSION_BROTLI)!
        let filter = try InputFilter<Data>(.decompress, using: algorithm) { requestedLength in
            if reachedEOF {
                return nil
            }

            let chunkLength = max(1, min(requestedLength, inputChunkSize))
            do {
                guard let chunk = try inputHandle.read(upToCount: chunkLength), !chunk.isEmpty else {
                    reachedEOF = true
                    return nil
                }
                return chunk
            } catch {
                readError = error
                reachedEOF = true
                return nil
            }
        }

        do {
            while let decompressedChunk = try filter.readData(ofLength: outputChunkSize) {
                if !decompressedChunk.isEmpty {
                    try outputHandle.write(contentsOf: decompressedChunk)
                }
            }
            if let readError {
                throw readError
            }
        } catch {
            throw readError ?? error
        }
    }

    private static func decompressWithLegacyNSData(sourceURL: URL, destinationURL: URL) throws {
        try createDestinationDirectory(for: destinationURL)
        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw BrotliFileDecompressionError.failedToCreateOutputFile(destinationURL)
        }

        let inputHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? inputHandle.close() }

        let compressedData = NSMutableData()
        while true {
            let chunk = try inputHandle.read(upToCount: inputChunkSize)
            guard let chunk, !chunk.isEmpty else { break }
            compressedData.append(chunk)
        }

        guard let decompressedData = (compressedData as NSData).brotliDecompressed() else {
            throw BrotliFileDecompressionError.invalidBrotliData
        }
        try decompressedData.write(to: destinationURL, options: .atomic)
    }

    private static func createDestinationDirectory(for destinationURL: URL) throws {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}
