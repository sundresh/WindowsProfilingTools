import Foundation
import ArgumentParser

enum ETLFileError: Error {
    case traceStartTicksNotFound
}

struct ProfileSample: Decodable {
    var timeOffset: Int64
    var program: String
    var stack: [String]
    var numSamples: Int
}

struct ProgramAndFunction: Decodable, Hashable {
    let program: String
    let function: String
}

struct ProgramAndFunctionInfo {
    var numSamples: Int = 0
    var calledFunctionToNumnSamples: [String: Int] = [:]
}

struct GetSwiftProfileStatsFromETLDump: ParsableCommand {
    @Argument(help: "Path to the ETL dump text file.")
    var etlDumpFilePath: String

    @Option(help: "Show up to the top N most frequently occurring functions in samples")
    var topN: Int = 100

    @Option(help: "Do not show functions that spend at least a certain percentage of their time directly calling a single other function")
    var pruneThreshold: Double = 99

    func run() throws {
        let swiftEtlDump = try SwiftProfileETLDump(etlDumpFilePath: etlDumpFilePath)
        var programAndFunctionToInfo: [ProgramAndFunction: ProgramAndFunctionInfo] = [:]
        var numProgramSamplesSeen = 0
        for profileSample in try swiftEtlDump.getProfileSamples() {
            let programName = profileSample.program.split(separator: " ", maxSplits: 1).first.map(String.init) ?? profileSample.program
            for (i, function) in Set(profileSample.stack).enumerated() {
                let programAndFunction = ProgramAndFunction(program: programName, function: function)
                programAndFunctionToInfo[programAndFunction, default: ProgramAndFunctionInfo()].numSamples += profileSample.numSamples
                if i > 0 {
                    programAndFunctionToInfo[programAndFunction].calledFunctionToNumnSamples[profileSample.stack[i-1], default: 0] += profileSample.numSamples
                }
            }
            numProgramSamplesSeen += 1
            if numProgramSamplesSeen % 100 == 0 {
                print(".", terminator: "")
            }
        }
        print("")
        print("")
        print("program,function,frequency")
        for element in programAndFunctionToNumSamples.sorted(by: { $0.value > $1.value })[..<topN] {
            // Skip if there is a single directly called function that appears in >{pruneThreshold}% of the function's samples.
            if programAndFunctionToCalledFunctionsToNumSamples[element.key]?.values.max() ?? 0 < element.value - Int(Double(element.value) * (1 - pruneThreshold/100)) {
                let frequency = Double(element.value) / Double(numProgramSamplesSeen)
                print("\(csvEscape(element.key.program)),\(csvEscape(element.key.function)),\(frequency)")
            }
        }
    }
}

class SwiftProfileETLDump {
    private static let sampledProfileBytes = Data("SampledProfile".utf8)
    private static let stackBytes = Data("Stack".utf8)
    private static let swiftBytes = Data("swift".utf8)
    private static let endHeaderBytes = Data("EndHeader".utf8)
    private static let traceStartPrefix = Data("Trace Start:".utf8)

    private var traceStartTicks: Int64
    private let lineReader: LineReader
    private var pendingSample: ProfileSample? = nil

    init(etlDumpFilePath: String) throws {
        guard let lineReader = LineReader(path: etlDumpFilePath) else {
            throw ValidationError("Failed to open file at path: \(etlDumpFilePath)")
        }
        self.lineReader = lineReader
        var inHeader = true
        var traceStartTicks: Int64?
        while let line = lineReader.nextLine() {
            if inHeader {
                if line.range(of: Self.endHeaderBytes) != nil {
                    inHeader = false
                }
            } else {
                if let ticks = Self.extractTraceStartTicks(from: line) {
                    traceStartTicks = ticks
                }
                break
            }
        }
        if let traceStartTicks {
            self.traceStartTicks = traceStartTicks
        } else {
            throw ETLFileError.traceStartTicksNotFound
        }
    }

    func getProfileSamples() throws -> AnyIterator<ProfileSample> {
        return AnyIterator {
            while let line = self.lineReader.nextLine() {
                if let sample = Self.processLine(line, pendingSample: &self.pendingSample) {
                    return sample
                }
            }

            if let sample = self.pendingSample {
                self.pendingSample = nil
                return sample
            }

            return nil
        }
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
    private static func processLine(_ line: Data, pendingSample: inout ProfileSample?) -> ProfileSample? {
        let columns = splitColumns(line)
        guard columns.count >= 2 else {
            return finalizePendingSample(&pendingSample)
        }

        let eventType = Self.getDataColumn(columns[0])

        guard let timeOffset = Self.parseInt64(Self.getDataColumn(columns[1])) else {
            return finalizePendingSample(&pendingSample)
        }

        if let sample = pendingSample, timeOffset != sample.timeOffset {
            return finalizePendingSample(&pendingSample)
        }

        if eventType == Self.sampledProfileBytes {
            if let sample = finalizePendingSample(&pendingSample) {
                return sample
            }
            pendingSample = Self.parseSampleProfile(timeOffset: timeOffset, columns: columns)
        } else if eventType == Self.stackBytes,
                  var sample = pendingSample,
                  timeOffset == sample.timeOffset {
            appendStackFrames(columns: columns, from: 3, to: &sample.stack)
            pendingSample = sample
            return finalizePendingSample(&pendingSample)
        }

        return nil
    }

    private static func parseSampleProfile(timeOffset: Int64, columns: [Data.SubSequence]) -> ProfileSample? {
        guard columns.count > 6 else { return nil }
        let programCol = trimSpaces(columns[2])
        guard programCol.starts(with: swiftBytes) else {
            return nil
        }

        guard let program = getStringColumn(programCol),
              let firstFrame = getStringColumn(columns[6]),
              let numSamples = parseInt(columns[columns.count - 2]) else {
            return nil
        }

        return ProfileSample(
            timeOffset: timeOffset,
            program: program,
            stack: [firstFrame],
            numSamples: numSamples
        )
    }

    private static func appendStackFrames(columns: [Data.SubSequence], from startIndex: Int, to stack: inout [String]) {
        for column in columns[startIndex...] {
            if let value = getStringColumn(column) {
                stack.append(value)
            }
        }
    }

    private static func finalizePendingSample(_ pendingSample: inout ProfileSample?) -> ProfileSample? {
        defer { pendingSample = nil }
        return pendingSample
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
