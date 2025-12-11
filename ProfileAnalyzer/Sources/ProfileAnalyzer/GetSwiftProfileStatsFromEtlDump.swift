import Foundation
import ArgumentParser

enum ETLFileError: Error {
    case traceStartTicksNotFound
}

struct ProfileSample {
    var timeOffset: Int64
    var program: String
    var processId: Int
    var threadId: Int
    var stack: [String]
    var numSamples: Int
}

struct ProgramAndFunction: Hashable {
    let program: String
    let function: String
}

struct ProcessIdAndThreadId: Hashable {
    let processId: Int
    let threadId: Int
}

struct NumSamplesAndCumulativeTime {
    var numSamples: Int = 0
    var cumulativeTime: Int64 = 0
}

struct ProgramAndFunctionInfo {
    var numSamplesAndCumulativeTime: NumSamplesAndCumulativeTime = NumSamplesAndCumulativeTime()
    var calledFunctionToNumSamplesAndCumulativeTime: [String: NumSamplesAndCumulativeTime] = [:]
}

struct GetSwiftProfileStatsFromETLDump: ParsableCommand {
    enum CommandLineArgumentsError: Error {
        case tooManyWeightFlags
    }

    @Argument(help: "Path to the ETL dump text file.")
    var etlDumpFilePath: String

    @Option(help: "Show up to the top N most frequently occurring functions in samples")
    var topN: Int = 100

    @Option(help: "Do not show functions that spend at least a certain percentage of their time directly calling a single other function")
    var pruneThreshold: Double = 99

    @Flag var sampleFrequencyWeighted = false
    @Flag var timeWeighted = false

    mutating func validate() throws {
        switch [sampleFrequencyWeighted, timeWeighted].count(where: { $0 }) {
            case 0: sampleFrequencyWeighted = true
            case 1: break
            case _: throw CommandLineArgumentsError.tooManyWeightFlags
        }
    }

    func run() throws {
        let swiftEtlDump = try SwiftProfileETLDump(etlDumpFilePath: etlDumpFilePath)
        var programAndFunctionToInfo: [ProgramAndFunction: ProgramAndFunctionInfo] = [:]
        var numProgramSamplesSeen = 0
        var processIdAndThreadIdToLastTimeOffset: [ProcessIdAndThreadId: Int64] = [:]
        for profileSample in try swiftEtlDump.getProfileSamples() {
            let processIdAndThreadId = ProcessIdAndThreadId(processId: profileSample.processId, threadId: profileSample.threadId)
            let timeSinceLastSampleInThisThread = profileSample.timeOffset - (processIdAndThreadIdToLastTimeOffset[processIdAndThreadId] ?? (profileSample.timeOffset - 1))
            processIdAndThreadIdToLastTimeOffset[processIdAndThreadId] = profileSample.timeOffset
            for (i, function) in Set(profileSample.stack).enumerated() {
                let programAndFunction = ProgramAndFunction(program: profileSample.program, function: function)
                var programAndFunctionInfo = programAndFunctionToInfo[programAndFunction, default: ProgramAndFunctionInfo()]
                programAndFunctionInfo.numSamplesAndCumulativeTime.numSamples += profileSample.numSamples
                programAndFunctionInfo.numSamplesAndCumulativeTime.cumulativeTime += timeSinceLastSampleInThisThread
                if i > 0 {
                    let calledFunction = profileSample.stack[i-1]
                    var numSamplesAndCumulativeTime = programAndFunctionInfo.calledFunctionToNumSamplesAndCumulativeTime[calledFunction, default: NumSamplesAndCumulativeTime()]
                    numSamplesAndCumulativeTime.numSamples += profileSample.numSamples
                    numSamplesAndCumulativeTime.cumulativeTime += timeSinceLastSampleInThisThread
                    programAndFunctionInfo.calledFunctionToNumSamplesAndCumulativeTime[calledFunction] = numSamplesAndCumulativeTime
                }
                programAndFunctionToInfo[programAndFunction] = programAndFunctionInfo
            }
            numProgramSamplesSeen += 1
            if numProgramSamplesSeen % 100 == 0 {
                print(".", terminator: "")
            }
        }
        print("")
        print("")
        if sampleFrequencyWeighted {
            print("program,function,frequency")
            for element in programAndFunctionToInfo.sorted(by: { $0.value.numSamplesAndCumulativeTime.numSamples > $1.value.numSamplesAndCumulativeTime.numSamples })[..<topN] {
                let programAndFunctionInfo = element.value
                let numSamples = programAndFunctionInfo.numSamplesAndCumulativeTime.numSamples
                // Skip if there is a single directly called function that appears in >{pruneThreshold}% of the function's samples.
                if programAndFunctionInfo.calledFunctionToNumSamplesAndCumulativeTime.values.map(\.numSamples).max() ?? 0 < numSamples - Int(Double(numSamples) * (1 - pruneThreshold/100)) {
                    let frequency = Double(numSamples) / Double(numProgramSamplesSeen)
                    print("\(csvEscape(element.key.program)),\(csvEscape(element.key.function)),\(frequency)")
                }
            }
        } else if timeWeighted {
            print("program,function,seconds")
            for element in programAndFunctionToInfo.sorted(by: { $0.value.numSamplesAndCumulativeTime.cumulativeTime > $1.value.numSamplesAndCumulativeTime.cumulativeTime })[..<topN] {
                let programAndFunctionInfo = element.value
                let cumulativeTime = programAndFunctionInfo.numSamplesAndCumulativeTime.cumulativeTime
                // Skip if there is a single directly called function that takes up >{pruneThreshold}% of the function's time.
                if programAndFunctionInfo.calledFunctionToNumSamplesAndCumulativeTime.values.map(\.cumulativeTime).max() ?? 0 < cumulativeTime - Int64(Double(cumulativeTime) * (1 - pruneThreshold/100)) {
                    let seconds = Double(cumulativeTime) / 1_000_000
                    print("\(csvEscape(element.key.program)),\(csvEscape(element.key.function)),\(seconds)")
                }
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

        guard let timeOffset = Self.getInt64Column(columns[1]) else {
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
        let programAndPidCol = trimSpaces(columns[2])
        guard programAndPidCol.starts(with: swiftBytes) else {
            return nil
        }

        guard let programAndPid = getStringColumn(programAndPidCol),
              let openParenIndex = programAndPid.lastIndex(of: "("),
              let closeParenIndex = programAndPid.lastIndex(of: ")"),
              openParenIndex < closeParenIndex else {
            return nil
        }

        let program = programAndPid[..<openParenIndex].trimmingCharacters(in: .whitespaces)
        let processIdString = programAndPid[programAndPid.index(after: openParenIndex)..<closeParenIndex]
            .trimmingCharacters(in: .whitespaces)
        guard let processId = Int(processIdString) else {
            return nil
        }

        guard let threadId = getIntColumn(columns[3]),
              let firstFrame = getStringColumn(columns[6]),
              let numSamples = getIntColumn(columns[columns.count - 2]) else {
            return nil
        }

        return ProfileSample(
            timeOffset: timeOffset,
            program: program,
            processId: processId,
            threadId: threadId,
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

    private static func getDataColumn(_ data: Data.SubSequence) -> Data {
        Data(trimSpaces(data))
    }

    private static func getStringColumn(_ data: Data.SubSequence) -> String? {
        String(data: getDataColumn(data), encoding: .utf8)
    }

    private static func getInt64Column(_ slice: Data.SubSequence) -> Int64? {
        getStringColumn(slice).flatMap { Int64($0) }
    }

    private static func getIntColumn(_ slice: Data.SubSequence) -> Int? {
        getStringColumn(slice).flatMap { Int($0) }
    }
}
