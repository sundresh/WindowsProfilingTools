import Foundation
import ArgumentParser

struct GetSwiftProfileLinesFromETLDump: ParsableCommand {
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
        let columns = splitColumns(line)
        guard columns.count >= 2 else {
            currentKey = nil
            return
        }

        let firstCol = Data(trimSpaces(columns[0]))
        let secondCol = Data(trimSpaces(columns[1]))
        let thirdCol = columns.count >= 3 ? Data(trimSpaces(columns[2])) : Data()

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

    private static let sampledProfileBytes = Data("SampledProfile".utf8)
    private static let swiftBytes = Data("swift".utf8)
    private static let endHeaderBytes = Data("EndHeader".utf8)
}
