import Foundation
import ArgumentParser

struct ProfileSample: Decodable {
    var timeOffset: Int64
    var program: String
    var stack: [String]
    var numSamples: Int
}

struct GetSwiftProfileStatsFromEtlDump: ParsableCommand {
    @Argument(help: "Path to the ETL dump text file.")
    var etlDumpFilePath: String

    func run() throws {
        var getSwiftProfileSamplesFromEtlDump = GetSwiftProfileSamplesFromEtlDump()
        let profileSamples = try getSwiftProfileSamplesFromEtlDump.run(etlDumpFilePath: etlDumpFilePath)
    }
}

struct GetSwiftProfileSamplesFromEtlDump {
    private enum State {
        case beforeHeader
        case needOsVersionLine
        case scanning
    }

    private var traceStartTicks: Int64?
    private var profileSamples: [ProfileSample] = []
    private var state: State = .beforeHeader
    private var pendingSample: ProfileSample? = nil

    private static let sampledProfileBytes = Data("SampledProfile".utf8)
    private static let stackBytes = Data("Stack".utf8)
    private static let swiftBytes = Data("swift".utf8)
    private static let endHeaderBytes = Data("EndHeader".utf8)
    private static let traceStartPrefix = Data("Trace Start:".utf8)

    mutating func run(etlDumpFilePath: String) throws -> [ProfileSample] {
        guard let reader = LineReader(path: etlDumpFilePath) else {
            throw ValidationError("Failed to open file at path: \(etlDumpFilePath)")
        }

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
                processLine(line)
            }
        }

        finalizePendingSample()

        return profileSamples
    }

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

    /// Process a line after the header and OS Version line, building ProfileSample records.
    private mutating func processLine(_ line: Data) {
        let columns = splitColumns(line)
        guard columns.count >= 2 else {
            finalizePendingSample()
            return
        }

        let eventType = Self.getDataColumn(columns[0])

        guard let timeOffset = Self.parseInt64(Self.getDataColumn(columns[1])) else {
            finalizePendingSample()
            return
        }

        if let pendingSample, timeOffset != pendingSample.timeOffset {
            finalizePendingSample()
        }

        if eventType == Self.sampledProfileBytes {
            finalizePendingSample()
            pendingSample = Self.parseSampleProfile(timeOffset: timeOffset, columns: columns)
        } else if eventType == Self.stackBytes, var pendingSample, timeOffset == pendingSample.timeOffset {
            Self.appendStackFrames(columns: columns, from: 3, to: &pendingSample.stack)
            self.pendingSample = pendingSample
            finalizePendingSample()
        }
    }

    private static func parseSampleProfile(timeOffset: Int64, columns: [Data.SubSequence]) -> ProfileSample? {
        let programCol = trimSpaces(columns[2])
        guard programCol.starts(with: swiftBytes) else {
            return nil
        }

        return ProfileSample(
            timeOffset: timeOffset,
            program: getStringColumn(programCol)!,
            stack: [getStringColumn(columns[6])!],
            numSamples: parseInt(columns[columns.count - 2])!
        )
    }

    private static func appendStackFrames(columns: [Data.SubSequence], from startIndex: Int, to stack: inout [String]) {
        for column in columns[startIndex...] {
            stack.append(getStringColumn(column)!)
        }
    }

    private mutating func finalizePendingSample() {
        if let pendingSample {
            profileSamples.append(pendingSample)
        }
        pendingSample = nil
    }

    private static func parseInt64(_ slice: Data.SubSequence) -> Int64? {
        guard let stringValue = getStringColumn(slice) else { return nil }
        return Int64(stringValue)
    }

    private static func parseInt(_ slice: Data.SubSequence) -> Int? {
        guard let stringValue = getStringColumn(slice) else { return nil }
        return Int(stringValue)
    }

    private static func getDataColumn(_ data: Data.SubSequence) -> Data {
        Data(trimSpaces(data))
    }

    private static func getStringColumn(_ data: Data.SubSequence) -> String? {
        String(data: getDataColumn(data), encoding: .utf8)
    }
}
