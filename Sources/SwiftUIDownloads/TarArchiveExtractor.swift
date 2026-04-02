import Foundation

public enum TarArchiveExtractorError: LocalizedError {
    case invalidArchive
    case pathTraversalDetected

    public var errorDescription: String? {
        switch self {
        case .invalidArchive:
            return "Invalid tar archive"
        case .pathTraversalDetected:
            return "Tar archive contains invalid path traversal entries"
        }
    }
}

public enum TarArchiveExtractor {
    private static let blockSize = 512
    private static let streamChunkSize = 64 * 1024

    public static func extract(archiveURL: URL, to destinationURL: URL) throws {
        let input = try FileHandle(forReadingFrom: archiveURL)
        defer { try? input.close() }

        while true {
            guard let header = try readExactly(blockSize, from: input, allowEOF: true) else {
                break
            }
            if header.allSatisfy({ $0 == 0 }) {
                break
            }

            guard let name = parseString(header, offset: 0, length: 100) else {
                throw TarArchiveExtractorError.invalidArchive
            }
            let prefix = parseString(header, offset: 345, length: 155)
            let fullName = [prefix, name]
                .compactMap { value in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
                .joined(separator: "/")
            guard let relativePath = sanitizedRelativePath(fullName) else {
                throw TarArchiveExtractorError.pathTraversalDetected
            }

            let size = parseOctal(header, offset: 124, length: 12)
            let typeflag = header[156]
            let isDirectory = typeflag == 53
            let isRegularFile = typeflag == 0 || typeflag == 48
            let outputURL = destinationURL.appendingPathComponent(relativePath, isDirectory: isDirectory)

            if isDirectory {
                try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
            } else if isRegularFile {
                let parentURL = outputURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: outputURL.path, contents: nil)
                let output = try FileHandle(forWritingTo: outputURL)
                defer { try? output.close() }
                try copyExactly(size, from: input, to: output)
            } else {
                try skipExactly(size, from: input)
            }

            let padding = paddingByteCount(forPayloadSize: size)
            if padding > 0 {
                try skipExactly(padding, from: input)
            }
        }
    }

    private static func paddingByteCount(forPayloadSize payloadSize: Int) -> Int {
        let remainder = payloadSize % blockSize
        return remainder == 0 ? 0 : (blockSize - remainder)
    }

    private static func readExactly(
        _ byteCount: Int,
        from handle: FileHandle,
        allowEOF: Bool = false
    ) throws -> Data? {
        if byteCount == 0 {
            return Data()
        }

        var data = Data()
        data.reserveCapacity(byteCount)

        while data.count < byteCount {
            let remaining = byteCount - data.count
            guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else {
                if allowEOF && data.isEmpty {
                    return nil
                }
                throw TarArchiveExtractorError.invalidArchive
            }
            data.append(chunk)
        }

        return data
    }

    private static func copyExactly(_ byteCount: Int, from input: FileHandle, to output: FileHandle) throws {
        var remaining = byteCount
        while remaining > 0 {
            let chunkSize = min(streamChunkSize, remaining)
            guard let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty else {
                throw TarArchiveExtractorError.invalidArchive
            }
            try output.write(contentsOf: chunk)
            remaining -= chunk.count
        }
    }

    private static func skipExactly(_ byteCount: Int, from handle: FileHandle) throws {
        var remaining = byteCount
        while remaining > 0 {
            let chunkSize = min(streamChunkSize, remaining)
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                throw TarArchiveExtractorError.invalidArchive
            }
            remaining -= chunk.count
        }
    }

    private static func parseString(_ header: Data, offset: Int, length: Int) -> String? {
        let slice = header.subdata(in: offset..<(offset + length))
        guard let raw = String(bytes: slice, encoding: .ascii) else { return nil }
        return raw.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)
    }

    private static func parseOctal(_ header: Data, offset: Int, length: Int) -> Int {
        let slice = header.subdata(in: offset..<(offset + length))
        let raw = String(bytes: slice, encoding: .ascii) ?? ""
        let upToNul = raw.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? raw
        let trimmed = upToNul.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0"))
        )
        return Int(trimmed, radix: 8) ?? 0
    }

    private static func sanitizedRelativePath(_ path: String) -> String? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty, !normalized.hasPrefix("/") else { return nil }

        var sanitizedComponents: [String] = []
        for component in normalized.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." {
                continue
            }
            if component == ".." {
                return nil
            }
            sanitizedComponents.append(String(component))
        }

        guard !sanitizedComponents.isEmpty else { return nil }
        return sanitizedComponents.joined(separator: "/")
    }
}
