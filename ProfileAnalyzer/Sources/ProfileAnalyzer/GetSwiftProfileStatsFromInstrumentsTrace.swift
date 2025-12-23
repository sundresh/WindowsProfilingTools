import Foundation
import ArgumentParser

struct GetSwiftProfileStatsFromInstrumentsTrace: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Analyze function frequency from an Instruments trace XML file for Swift processes."
    )

    enum WeightingError: Error {
        case tooManyWeightFlags
    }

    @Argument(help: "Path to the Instruments trace XML file.")
    var xmlFilePath: String

    @Option(help: "Show up to the top N most frequently occurring functions in samples.")
    var topN: Int = 100

    @Option(help: "Do not show functions that spend at least this percentage of their time directly calling a single other function.")
    var pruneThreshold: Double = 99

    @Flag(help: "Weight by sample count (uniform weighting).")
    var sampleFrequencyWeighted = false

    @Flag(help: "Weight by time since previous sample in same thread.")
    var timeWeighted = false

    mutating func validate() throws {
        switch [sampleFrequencyWeighted, timeWeighted].count(where: { $0 }) {
        case 0: sampleFrequencyWeighted = true
        case 1: break
        default: throw WeightingError.tooManyWeightFlags
        }
    }

    func run() throws {
        let url = URL(fileURLWithPath: xmlFilePath)

        // Parse trace, filtering to swift processes
        let trace = try InstrumentsTrace(from: url) { process in
            process.name.localizedCaseInsensitiveContains("swiftc") || process.name.localizedCaseInsensitiveContains("swift-driver") || process.name.localizedCaseInsensitiveContains("swift-frontend")
        }

        print("Loaded \(trace.samples.count) samples from swift processes")

        // First pass: collect all unsymbolicated addresses grouped by binary
        // Key: (binaryPath, loadAddress), Value: set of addresses to symbolicate
        var addressesByBinary: [BinaryKey: Set<UInt64>] = [:]

        for sample in trace.samples {
            guard let backtrace = sample.backtrace else { continue }
            for frame in backtrace.frames {
                // Only collect unsymbolicated frames that have binary info
                guard isUnsymbolicated(frame.name),
                      let binary = frame.binary,
                      let binaryPath = binary.path,
                      !binaryPath.isEmpty,
                      let loadAddress = binary.loadAddress else {
                    continue
                }

                let binaryKey = BinaryKey(path: binaryPath, loadAddress: loadAddress)
                addressesByBinary[binaryKey, default: []].insert(frame.address)
            }
        }

        // Batch symbolicate all addresses for each binary
        print("Symbolicating \(addressesByBinary.values.map { $0.count }.reduce(0, +)) addresses from \(addressesByBinary.count) binaries...")
        var symbolicationMap: [SymbolicationKey: String] = [:]

        for (binaryKey, addresses) in addressesByBinary {
            let symbolicated = batchSymbolicate(
                binaryPath: binaryKey.path,
                loadAddress: binaryKey.loadAddress,
                addresses: Array(addresses)
            )
            for (address, name) in symbolicated {
                let key = SymbolicationKey(binaryPath: binaryKey.path, address: address)
                symbolicationMap[key] = name
            }
        }
        print("Successfully symbolicated \(symbolicationMap.count) addresses")

        // Track function statistics
        var functionStats: [FunctionKey: FunctionStats] = [:]
        var totalSamplesProcessed = 0

        // Track last sample time per thread for time-weighted mode
        var lastSampleTimeByThread: [Int: UInt64] = [:]

        // Second pass: build function statistics using symbolication map
        for sample in trace.samples {
            guard let backtrace = sample.backtrace else { continue }
            guard !backtrace.frames.isEmpty else { continue }

            let processName = sample.process.name.prefix { $0 != " " && $0 != "(" }.description
            let threadId = sample.thread.tid

            // Calculate weight for this sample
            let weight: Int64
            if timeWeighted {
                let currentTime = sample.time.nanoseconds
                let lastTime = lastSampleTimeByThread[threadId] ?? (currentTime > 0 ? currentTime - 1_000_000 : 0)
                weight = Int64(currentTime) - Int64(lastTime)
                lastSampleTimeByThread[threadId] = currentTime
            } else {
                weight = 1
            }

            // Get unique functions in this stack (a function may appear multiple times due to recursion)
            let frames = backtrace.frames
            var seenFunctions = Set<String>()

            // print("[[ \(frames.map { "\($0.binary?.name ?? "")!\($0.name)" }.joined(separator: " --> ")) ]]")

            for (frameIndex, frame) in frames.enumerated() {
                let binaryPath = frame.binary?.path ?? ""
                let loadAddress = frame.binary?.loadAddress ?? 0

                // Apply symbolication from the pre-built map
                let functionName: String
                if isUnsymbolicated(frame.name), !binaryPath.isEmpty {
                    let symbolicationKey = SymbolicationKey(binaryPath: binaryPath, address: frame.address)
                    functionName = symbolicationMap[symbolicationKey] ?? frame.name
                } else {
                    functionName = frame.name
                }

                guard !functionName.isEmpty else { continue }

                // Only count each function once per sample (even if recursive)
                guard !seenFunctions.contains(functionName) else { continue }
                seenFunctions.insert(functionName)

                let key = FunctionKey(
                    process: processName,
                    function: functionName,
                    binaryPath: binaryPath,
                    loadAddress: loadAddress,
                    address: frame.address
                )
                var stats = functionStats[key, default: FunctionStats()]

                stats.sampleCount += 1
                stats.cumulativeWeight += weight

                // Track which function this one directly calls (next frame in stack)
                // frames[0] is top of stack, frames[n] is bottom, so frames[i+1] is the caller
                // We want to track what this function calls, which is frames[i-1] if it exists
                if frameIndex > 0 {
                    let calledBinaryPath = frames[frameIndex - 1].binary?.path ?? ""
                    let calledFrameName = frames[frameIndex - 1].name
                    let calledFunction: String
                    if isUnsymbolicated(calledFrameName), !calledBinaryPath.isEmpty {
                        let calledSymbolicationKey = SymbolicationKey(binaryPath: calledBinaryPath, address: frames[frameIndex - 1].address)
                        calledFunction = symbolicationMap[calledSymbolicationKey] ?? calledFrameName
                    } else {
                        calledFunction = calledFrameName
                    }
                    if !calledFunction.isEmpty {
                        var calledStats = stats.calledFunctions[calledFunction, default: CalledFunctionStats()]
                        calledStats.sampleCount += 1
                        calledStats.cumulativeWeight += weight
                        stats.calledFunctions[calledFunction] = calledStats
                    }
                }

                functionStats[key] = stats
            }

            totalSamplesProcessed += 1
            if totalSamplesProcessed % 100 == 0 {
                print(".", terminator: "")
                fflush(stdout)
            }
        }

        print("")
        print("")

        // Sort and output results
        if sampleFrequencyWeighted {
            printSampleFrequencyResults(
                functionStats: functionStats,
                totalSamples: totalSamplesProcessed,
                topN: topN,
                pruneThreshold: pruneThreshold
            )
        } else if timeWeighted {
            printTimeWeightedResults(
                functionStats: functionStats,
                topN: topN,
                pruneThreshold: pruneThreshold
            )
        }
    }

    private func printSampleFrequencyResults(
        functionStats: [FunctionKey: FunctionStats],
        totalSamples: Int,
        topN: Int,
        pruneThreshold: Double
    ) {
        // print("process,binary,function,frequency")
        print("process,function,frequency")

        // Coalesce entries by function name (handles ASLR differences)
        let coalesced = coalesceByFunctionName(
            functionStats: functionStats,
            maxEntriesToProcess: topN * 3
        )

        let sorted = coalesced.sorted { $0.value.sampleCount > $1.value.sampleCount }
        var printed = 0

        for (key, stats) in sorted {
            guard printed < topN else { break }

            // Check prune threshold: skip if a single called function dominates
            let maxCalledSamples = stats.calledFunctions.values.map { $0.sampleCount }.max() ?? 0
            let threshold = stats.sampleCount - Int(Double(stats.sampleCount) * (1 - pruneThreshold / 100))
            if maxCalledSamples >= threshold {
                continue
            }

            let frequency = Double(stats.sampleCount) / Double(totalSamples)
            // print("\(csvEscape(key.process)),\(csvEscape(key.binaryPath)),\(csvEscape(key.function)),\(frequency)")
            print("\(csvEscape(key.process)),\(csvEscape(key.function)),\(frequency)")
            printed += 1
        }
    }

    private func printTimeWeightedResults(
        functionStats: [FunctionKey: FunctionStats],
        topN: Int,
        pruneThreshold: Double
    ) {
        // print("process,binary,function,seconds")
        print("process,function,seconds")

        // Coalesce entries by function name (handles ASLR differences)
        let coalesced = coalesceByFunctionName(
            functionStats: functionStats,
            maxEntriesToProcess: topN * 3,
            sortByWeight: true
        )

        let sorted = coalesced.sorted { $0.value.cumulativeWeight > $1.value.cumulativeWeight }
        var printed = 0

        for (key, stats) in sorted {
            guard printed < topN else { break }

            // Check prune threshold: skip if a single called function dominates
            let maxCalledWeight = stats.calledFunctions.values.map { $0.cumulativeWeight }.max() ?? 0
            let threshold = stats.cumulativeWeight - Int64(Double(stats.cumulativeWeight) * (1 - pruneThreshold / 100))
            if maxCalledWeight >= threshold {
                continue
            }

            let seconds = Double(stats.cumulativeWeight) / 1_000_000_000  // nanoseconds to seconds
            // print("\(csvEscape(key.process)),\(csvEscape(key.binaryPath)),\(csvEscape(key.function)),\(seconds)")
            print("\(csvEscape(key.process)),\(csvEscape(key.function)),\(seconds)")
            printed += 1
        }
    }

    /// Coalesce function stats by function name to handle ASLR differences
    /// (Symbolication is already done upfront, so we just need to merge by name)
    private func coalesceByFunctionName(
        functionStats: [FunctionKey: FunctionStats],
        maxEntriesToProcess: Int,
        sortByWeight: Bool = false
    ) -> [CoalescedKey: FunctionStats] {
        // Sort by the appropriate metric
        let sorted: [(FunctionKey, FunctionStats)]
        if sortByWeight {
            sorted = functionStats.sorted { $0.value.cumulativeWeight > $1.value.cumulativeWeight }
        } else {
            sorted = functionStats.sorted { $0.value.sampleCount > $1.value.sampleCount }
        }

        var coalesced: [CoalescedKey: FunctionStats] = [:]
        var processed = 0

        for (key, stats) in sorted {
            guard processed < maxEntriesToProcess else { break }
            processed += 1

            let coalescedKey = CoalescedKey(
                process: key.process,
                function: key.function,
                binaryPath: key.binaryPath
            )

            if var existing = coalesced[coalescedKey] {
                existing.sampleCount += stats.sampleCount
                existing.cumulativeWeight += stats.cumulativeWeight
                // Merge called functions
                for (calledFunc, calledStats) in stats.calledFunctions {
                    if var existingCalled = existing.calledFunctions[calledFunc] {
                        existingCalled.sampleCount += calledStats.sampleCount
                        existingCalled.cumulativeWeight += calledStats.cumulativeWeight
                        existing.calledFunctions[calledFunc] = existingCalled
                    } else {
                        existing.calledFunctions[calledFunc] = calledStats
                    }
                }
                coalesced[coalescedKey] = existing
            } else {
                coalesced[coalescedKey] = stats
            }
        }

        return coalesced
    }
}

// MARK: - Supporting Types

private struct FunctionKey: Hashable {
    let process: String
    let function: String
    let binaryPath: String
    let loadAddress: UInt64  // Binary load address for atos
    let address: UInt64      // Runtime address of function
}

/// Key for coalesced function stats (after symbolication, without address info)
private struct CoalescedKey: Hashable {
    let process: String
    let function: String
    let binaryPath: String
}

/// Key for grouping addresses by binary (path + load address)
private struct BinaryKey: Hashable {
    let path: String
    let loadAddress: UInt64
}

private struct CalledFunctionStats {
    var sampleCount: Int = 0
    var cumulativeWeight: Int64 = 0
}

private struct FunctionStats {
    var sampleCount: Int = 0
    var cumulativeWeight: Int64 = 0
    var calledFunctions: [String: CalledFunctionStats] = [:]
}

// MARK: - Symbolication

/// Key for looking up symbolicated names by binary path and address
private struct SymbolicationKey: Hashable {
    let binaryPath: String
    let address: UInt64
}

/// Check if a function name looks unsymbolicated (hex address)
private func isUnsymbolicated(_ name: String) -> Bool {
    // Check for patterns like "0x1234abcd" or just hex digits
    if name.hasPrefix("0x") {
        let hex = name.dropFirst(2)
        return !hex.isEmpty && hex.allSatisfy { $0.isHexDigit }
    }
    return false
}

/// Batch symbolicate multiple addresses for a single binary using atos
/// - Parameters:
///   - binaryPath: Path to the binary
///   - loadAddress: Load address of the binary
///   - addresses: Array of addresses to symbolicate
/// - Returns: Dictionary mapping addresses to symbolicated names (only includes successful symbolicaitons)
private func batchSymbolicate(binaryPath: String, loadAddress: UInt64, addresses: [UInt64]) -> [UInt64: String] {
    guard !binaryPath.isEmpty, !addresses.isEmpty else {
        return [:]
    }

    // Build arguments: atos -o <binary> -l <load_address> <addr1> <addr2> ...
    var arguments = [
        "-o", binaryPath,
        "-l", String(format: "0x%llx", loadAddress)
    ]
    arguments.append(contentsOf: addresses.map { String(format: "0x%llx", $0) })

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/atos")
    process.arguments = arguments

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return [:]
        }

        // atos outputs one line per address, in the same order as input
        let lines = output.components(separatedBy: .newlines)
        var result: [UInt64: String] = [:]

        for (index, address) in addresses.enumerated() {
            guard index < lines.count else { break }
            var symbolicated = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if !symbolicated.isEmpty && !isUnsymbolicated(symbolicated) {
                // Strip " (in <binary>)" suffix if present
                if let inRange = symbolicated.range(of: " (in ") {
                    symbolicated = String(symbolicated[..<inRange.lowerBound])
                }
                result[address] = symbolicated
            }
        }

        return result
    } catch {
        return [:]
    }
}
