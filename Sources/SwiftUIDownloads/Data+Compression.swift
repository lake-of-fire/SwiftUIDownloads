// Forked from: https://gist.github.com/insidegui/0338b6cff4454ecaa24c315b8e2a11fd
/// Created by Gui Rambo
/// This wraps Apple's Compression framework to compress/decompress Data objects.
/// It will use Compression's modern API for iOS 13+ and its old API for older versions.
/// For more information, check out Apple's documentation: https://developer.apple.com/documentation/compression
/* Copyright 2020 Guilherme Rambo

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE. */

import Foundation
import Compression

public extension Data {
    /// Compresses the data using the specified compression algorithm.
    func compressed(using algo: compression_algorithm = COMPRESSION_LZMA, pageSize: Int = 128) throws -> Data {
        var outputData = Data()
        let filter = try OutputFilter(.compress, using: Algorithm(rawValue: algo)!, bufferCapacity: pageSize, writingTo: { $0.flatMap({ outputData.append($0) }) })

        var index = 0
        let bufferSize = count

        while true {
            let rangeLength = Swift.min(pageSize, bufferSize - index)

            let subdata = self.subdata(in: index ..< index + rangeLength)
            index += rangeLength

            try filter.write(subdata)

            if (rangeLength == 0) { break }
        }

        return outputData
    }
    
    /// Decompresses the data using the specified compression algorithm.
    func decompressed(from algo: compression_algorithm = COMPRESSION_LZMA, pageSize: Int = 128) throws -> Data {
        var outputData = Data()
        let bufferSize = count
        var decompressionIndex = 0

        let filter = try InputFilter(.decompress, using: Algorithm(rawValue: algo)!) { (length: Int) -> Data? in
            let rangeLength = Swift.min(length, bufferSize - decompressionIndex)
            let subdata = self.subdata(in: decompressionIndex ..< decompressionIndex + rangeLength)
            decompressionIndex += rangeLength

            return subdata
        }

        while let page = try filter.readData(ofLength: pageSize) {
            outputData.append(page)
        }

        return outputData
    }
}
