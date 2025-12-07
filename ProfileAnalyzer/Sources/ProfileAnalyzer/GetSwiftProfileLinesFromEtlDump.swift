import Foundation
import ArgumentParser

/// Streaming line reader for very large files.
/// Reads in chunks and returns one UTF-8 line at a time without loading the whole file.
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
    func nextLine() -> String? {
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

                return String(data: trimmedData, encoding: .utf8) ?? ""
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

                return String(data: trimmedData, encoding: .utf8) ?? ""
            }

            // Truly no more data.
            return nil
        }
    }
}

// Helper to trim just spaces/tabs around columns.
extension StringProtocol {
    var trimmedSpaces: String {
        self.trimmingCharacters(in: .whitespaces)
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
            FileManager.default.createFile(atPath: output, contents: nil)
            guard let h = FileHandle(forWritingAtPath: output) else {
                throw ValidationError("Failed to open output file: \(output)")
            }
            outputHandle = h
        } else {
            outputHandle = FileHandle.standardOutput
        }

        var state: State = .beforeHeader
        var currentKey: String? = nil

        func writeLine(_ s: String) {
            if let data = (s + "\n").data(using: .utf8) {
                try? outputHandle.write(contentsOf: data)
            }
        }

        while let line = reader.nextLine() {
            switch state {
            case .beforeHeader:
                if line.contains("EndHeader") {
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
        _ line: String,
        currentKey: inout String?,
        writeLine: (String) -> Void
    ) {
        let columns = line.split(separator: ",", omittingEmptySubsequences: false)
        guard columns.count >= 2 else {
            currentKey = nil
            return
        }

        let firstCol = columns[0].trimmedSpaces
        let secondCol = columns[1].trimmedSpaces
        let thirdCol = columns.count >= 3 ? columns[2].trimmedSpaces : ""

        if firstCol == "SampledProfile", thirdCol.hasPrefix("swift") {
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
}
