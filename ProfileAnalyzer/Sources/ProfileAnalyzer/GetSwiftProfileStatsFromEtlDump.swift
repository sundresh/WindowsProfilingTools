import Foundation
import ArgumentParser

struct ProfileSample: Decodable {
    let timeOffset: Int64
    let program: String
    let stack: [String]
    let numSamples: Int
}

struct GetSwiftProfileStatsFromEtlDump: ParsableCommand {
    @Argument(help: "Path to the ETL dump text file.")
    var etlDumpFilePath: String
    // @Option(name: [.short, .long])
    // var outputFilePath: String?

    var traceStartTicks: Int64?
    var profileSamples: [ProfileSample] = []

    private enum State {
        case beforeHeader
        case needOsVersionLine
        case scanning
    }

    mutating func run() throws {
        guard let reader = LineReader(path: etlDumpFilePath) else {
            throw ValidationError("Failed to open file at path: \(etlDumpFilePath)")
        }

        var state: State = .beforeHeader
        var currentSample: PendingSample? = nil
        while let line = reader.nextLine() {
            switch state {
            case .beforeHeader:
                if line.range(of: Self.endHeaderBytes) != nil {
                    state = .needOsVersionLine
                }

            case .needOsVersionLine:
                if let ticks = Self.extractTraceStartTicks(from: line) {
                    traceStartTicks = ticks
                }
                state = .scanning

            case .scanning:
                Self.processLine(line, currentSample: &currentSample, samples: &profileSamples)
            }
        }

        if let pending = currentSample {
            profileSamples.append(pending.finalizedSample())
        }
    }

    /// Process a line after the header and OS Version line, building ProfileSample records.
    private static func processLine(
        _ line: Data,
        currentSample: inout PendingSample?,
        samples: inout [ProfileSample]
    ) {
        let columns = splitColumns(line)
        guard columns.count >= 2 else {
            if let pending = currentSample {
                samples.append(pending.finalizedSample())
            }
            currentSample = nil
            return
        }

        let firstCol = Data(trimSpaces(columns[0]))
        let secondCol = Data(trimSpaces(columns[1]))

        if let pending = currentSample, secondCol != pending.key {
            samples.append(pending.finalizedSample())
            currentSample = nil
        }

        if firstCol.count == Self.sampledProfileBytes.count,
           firstCol.elementsEqual(Self.sampledProfileBytes) {
            guard columns.count >= 3 else { return }
            let programCol = Data(trimSpaces(columns[2]))
            guard programCol.starts(with: Self.swiftBytes),
                  let timeOffset = parseInt64(columns[1]),
                  let program = decode(programCol) else {
                return
            }

            let numSamples = parseInt(columns[columns.count - 2]) ?? 0
            var stackFrames: [String] = []
            if columns.count > 6, let frame = decode(trimSpaces(columns[6])), !frame.isEmpty {
                stackFrames.append(frame)
            }

            var eighthFrame: String? = nil
            if columns.count > 7, let frame = decode(trimSpaces(columns[7])), !frame.isEmpty {
                stackFrames.append(frame)
                eighthFrame = frame
            }

            currentSample = PendingSample(
                key: secondCol,
                timeOffset: timeOffset,
                program: program,
                stack: stackFrames,
                numSamples: numSamples,
                eighthFrame: eighthFrame
            )
            return
        }

        if let pending = currentSample,
           secondCol == pending.key,
           firstCol.count == Self.stackBytes.count,
           firstCol.elementsEqual(Self.stackBytes) {
            var startIndex = 3
            if let expected = pending.eighthFrame,
               columns.count > 3,
               let firstStack = decode(trimSpaces(columns[3])),
               firstStack == expected {
                startIndex = 4
            }

            var updated = pending
            if columns.count > startIndex {
                for column in columns[startIndex...] {
                    let trimmed = trimSpaces(column)
                    if let frame = decode(trimmed), !frame.isEmpty {
                        updated.stack.append(frame)
                    }
                }
            }

            samples.append(updated.finalizedSample())
            currentSample = nil
        }
    }

    private static func parseInt64(_ slice: Data.SubSequence) -> Int64? {
        parseInt(slice).flatMap { Int64($0) }
    }

    private static func parseInt(_ slice: Data.SubSequence) -> Int? {
        if let stringValue = decode(trimSpaces(slice)) {
            return Int(stringValue)
        }
        return nil
    }

    private static func decode(_ data: Data.SubSequence) -> String? {
        String(data: Data(data), encoding: .utf8)
    }

    private struct PendingSample {
        let key: Data
        let timeOffset: Int64
        let program: String
        var stack: [String]
        let numSamples: Int
        let eighthFrame: String?

        func finalizedSample() -> ProfileSample {
            ProfileSample(
                timeOffset: timeOffset,
                program: program,
                stack: stack,
                numSamples: numSamples
            )
        }
    }

    private static let sampledProfileBytes = Data("SampledProfile".utf8)
    private static let stackBytes = Data("Stack".utf8)
    private static let swiftBytes = Data("swift".utf8)
    private static let endHeaderBytes = Data("EndHeader".utf8)
    private static let traceStartPrefix = Data("Trace Start:".utf8)

    private static func extractTraceStartTicks(from line: Data) -> Int64? {
        // The OS version line is comma-separated; look for the "Trace Start" field.
        let columns = splitColumns(line)
        for column in columns {
            let trimmed = trimSpaces(column)
            guard trimmed.starts(with: traceStartPrefix) else { continue }

            let numberSlice = trimSpaces(trimmed.dropFirst(traceStartPrefix.count))
            if let stringValue = String(data: Data(numberSlice), encoding: .utf8),
               let ticks = Int64(stringValue) {
                return ticks
            }
        }

        return nil
    }
}
