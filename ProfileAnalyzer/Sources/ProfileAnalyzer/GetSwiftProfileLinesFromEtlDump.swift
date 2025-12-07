import Foundation
import ArgumentParser

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

struct GetSwiftProfileLinesFromEtlDump: ParsableCommand {
    @Argument(help: "Path to the ETL dump text file.")
    var etlDumpFilePath: String
    @Option(name: [.short, .long])
    var outputFilePath: String?

    private enum State {
        case beforeHeader
        case needOsVersionLine
        case scanning
    }

    mutating func run() throws {
        guard let reader = LineReader(path: etlDumpFilePath) else {
            throw ValidationError("Failed to open file at path: \(etlDumpFilePath)")
        }

        // Set up output: stdout or file handle
        let outputHandle: FileHandle
        if let output = outputFilePath {
            //FileManager.default.createFile(atPath: output, contents: nil)
            guard let h = FileHandle(forWritingAtPath: output) else {
                throw ValidationError("Failed to open output file: \(output)")
            }
            outputHandle = h
        } else {
            outputHandle = FileHandle.standardOutput
        }

        var state: State = .beforeHeader
        var currentKey: Data? = nil

        func writeLine(_ line: Data) {
            var dataToWrite = line
            dataToWrite.append(0x0A) // newline
            try? outputHandle.write(contentsOf: dataToWrite)
        }

        while let line = reader.nextLine() {
            switch state {
            case .beforeHeader:
                if line.range(of: Self.endHeaderBytes) != nil {
                    writeLine(line)
                    state = .needOsVersionLine
                }

            case .needOsVersionLine:
                writeLine(line)
                state = .scanning

            case .scanning:
                Self.processLine(line, currentKey: &currentKey, writeLine: writeLine)
            }
        }

        if outputHandle !== FileHandle.standardOutput {
            try? outputHandle.close()
        }
    }

    /// Process a line after the header and OS Version line.
    ///
    /// - We want:
    ///   1. `SampledProfile` lines whose *third* column starts with "swift".
    ///   2. Any following lines whose *second* column matches the selected SampledProfile's
    ///      second column (e.g. "1806292" in your sample).
    private static func processLine(
        _ line: Data,
        currentKey: inout Data?,
        writeLine: (Data) -> Void
    ) {
        let columns = Self.splitColumns(line)
        guard columns.count >= 2 else {
            currentKey = nil
            return
        }

        let firstCol = Data(Self.trimSpaces(columns[0]))
        let secondCol = Data(Self.trimSpaces(columns[1]))
        let thirdCol = columns.count >= 3 ? Data(Self.trimSpaces(columns[2])) : Data()

        if firstCol.count == Self.sampledProfileBytes.count,
           firstCol.elementsEqual(Self.sampledProfileBytes),
           thirdCol.starts(with: Self.swiftBytes) {
            currentKey = secondCol
            writeLine(line)
            return
        }

        if let key = currentKey {
            if secondCol == key {
                writeLine(line)
            } else {
                currentKey = nil
            }
        }
    }

    // MARK: - Byte helpers

    private static func trimSpaces(_ slice: Data.SubSequence) -> Data.SubSequence {
        var start = slice.startIndex
        var end = slice.endIndex

        while start < end, isAsciiSpace(slice[start]) {
            start = slice.index(after: start)
        }

        while start < end {
            let prev = slice.index(before: end)
            if isAsciiSpace(slice[prev]) {
                end = prev
            } else {
                break
            }
        }

        return slice[start..<end]
    }

    private static func isAsciiSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 // space or tab
    }

    private static func splitColumns(_ data: Data, delimiter: UInt8 = 0x2C) -> [Data.SubSequence] {
        var result: [Data.SubSequence] = []
        var start = data.startIndex
        var idx = start

        while idx < data.endIndex {
            if data[idx] == delimiter {
                result.append(data[start..<idx])
                start = data.index(after: idx)
            }
            idx = data.index(after: idx)
        }

        result.append(data[start..<data.endIndex])
        return result
    }

    private static let sampledProfileBytes = Data("SampledProfile".utf8)
    private static let swiftBytes = Data("swift".utf8)
    private static let endHeaderBytes = Data("EndHeader".utf8)
}
