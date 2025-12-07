import Foundation

/// Streaming line reader for very large files.
/// Reads in chunks and returns one line of raw bytes (ASCII assumed) at a time without loading the whole file.
final class LineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private let chunkSize: Int

    init?(path: String, chunkSize: Int = 64 * 1024) {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        self.handle = handle
        self.chunkSize = chunkSize
    }

    deinit {
        try? handle.close()
    }

    /// Returns the next line (without trailing newline), or nil at EOF.
    func nextLine() -> Data? {
        while true {
            // Look for '\n' in the existing buffer.
            if let newlineIndex = buffer.firstIndex(of: 0x0A) { // '\n'
                let lineData = buffer[..<newlineIndex]
                buffer.removeSubrange(..<buffer.index(after: newlineIndex))

                // Handle Windows-style "\r\n" by trimming trailing '\r' if present.
                let trimmedData: Data
                if let last = lineData.last, last == 0x0D { // '\r'
                    trimmedData = lineData.dropLast()
                } else {
                    trimmedData = Data(lineData)
                }

                return trimmedData
            }

            // Need more data from the file.
            let chunk = try? handle.read(upToCount: chunkSize)
            if let chunk = chunk, !chunk.isEmpty {
                buffer.append(chunk)
                continue
            }

            // EOF: return any remaining data as a final line.
            if !buffer.isEmpty {
                let lineData = buffer
                buffer.removeAll(keepingCapacity: true)

                let trimmedData: Data
                if let last = lineData.last, last == 0x0D {
                    trimmedData = lineData.dropLast()
                } else {
                    trimmedData = lineData
                }

                return trimmedData
            }

            // Truly no more data.
            return nil
        }
    }
}
