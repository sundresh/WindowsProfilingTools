import ArgumentParser
import Foundation

struct AnalyzeSwiftStatsJson: ParsableCommand {
    static func getSourceFileName(jsonFileName: String) -> String {
        var name = jsonFileName
        if let r = name.range(of: #"^stats-\d+-swift-frontend-"#, options: .regularExpression) {
            name.removeSubrange(r)
        }
        if let r = name.range(of: #"(\.swift-.*?\.json|-all-.*)$"#, options: .regularExpression) {
            name.replaceSubrange(r, with: ".swift")
        }
        return name
    }

    static func getTotalWallTimesForOneRun(directory: URL) throws -> [String: Double] {
        var totals: [String: Double] = [:]
        for file in try list(directory: directory) where file.pathExtension == "json" {
            var numPasses = 0
            for (key, value) in try readJson(fromFile: file) {
                if key.hasPrefix("time.swift.") && key.hasSuffix(".wall") {
                    let passName = key.dropPrefix("time.swift.").dropSuffix(".wall")
                    totals["time.\(passName)", default: 0.0] += value as! Double
                    totals["count.\(passName)", default: 0.0] += 1.0
                    numPasses += 1
                }
            }
        }
        return totals
    }

    static func getperBuildJobWallTimesForOneRun(passName: String, directory: URL) throws -> [String: Double] {
        var perBuildJob: [String: Double] = [:]
        let keyForPassNameWallTime = "time.swift.\(passName).wall"
        for file in try list(directory: directory) where file.pathExtension == "json" {
            let json = try readJson(fromFile: file)
            if let value = json[keyForPassNameWallTime] {
                perBuildJob[getSourceFileName(jsonFileName: file.lastPathComponent)] = (value as! Double)
            }
        }
        return perBuildJob
    }

    static func getTotalWallTimesForAllRuns(baseDir: URL) throws -> [[String: Double]] {
        var allTotals: [[String: Double]] = []
        for dirEntry in try list(directory: baseDir) {
            if !dirEntry.lastPathComponent.isEmpty && dirEntry.lastPathComponent.allSatisfy({ $0.isNumber }) {
                allTotals.append(try getTotalWallTimesForOneRun(directory: dirEntry))
            }
        }
        return allTotals
    }

    static func getperBuildJobWallTimesForAllRuns(passName: String, baseDir: URL) throws -> [[String: Double]] {
        var allperBuildJob: [[String: Double]] = []
        for dirEntry in try list(directory: baseDir) {
            if !dirEntry.lastPathComponent.isEmpty && dirEntry.lastPathComponent.allSatisfy({ $0.isNumber }) {
                allperBuildJob.append(try getperBuildJobWallTimesForOneRun(passName: passName, directory: dirEntry))
            }
        }
        return allperBuildJob
    }

    struct PassWallTimeDistribution {
        let passName: String
        let mean: Double
        let median: Double
        let stdDev: Double
    }

    static func getTotalWallTimeDistributionsForAllRuns(baseDir: URL) throws -> [PassWallTimeDistribution] {
        var allDistributions: [PassWallTimeDistribution] = []
        for (passName, value) in transpose(try getTotalWallTimesForAllRuns(baseDir: baseDir)) {
            allDistributions.append(PassWallTimeDistribution(passName: passName, mean: mean(value)!, median: median(value)!, stdDev: stdDev(value)!))
        }
        return allDistributions
    }

    static func getperBuildJobWallTimeDistributionsForAllRuns(passName: String, baseDir: URL) throws -> [PassWallTimeDistribution] {
        var allDistributions: [PassWallTimeDistribution] = []
        for (passName, value) in transpose(try getperBuildJobWallTimesForAllRuns(passName: passName, baseDir: baseDir)) {
            allDistributions.append(PassWallTimeDistribution(passName: passName, mean: mean(value)!, median: median(value)!, stdDev: stdDev(value)!))
        }
        return allDistributions
    }

    static func convertToCsv(rows: [PassWallTimeDistribution]) -> String {
        var csv = "passName,mean,median,stdDev\n"
        for row in rows.sorted(by: { $0.passName < $1.passName }) {
            let safeName = csvEscape(row.passName)
            csv += "\(safeName),\(row.mean),\(row.median),\(row.stdDev)\n"
        }
        return csv
    }

    static func writeCsv(toFile url: URL, of rows: [PassWallTimeDistribution]) throws {
        try convertToCsv(rows: rows)
            .write(to: url, atomically: true, encoding: .utf8)
    }

    @Option(name: [.short, .long], help: "Directory containing stats json files emitted by Swift compiler")
    var inputStatsDir: String = "."

    @Option(name: [.short, .long], help: "Directory in which to store CSV files (otherwise write to stdout)")
    var outputCsvDir: String? = nil

    @Option(name: [.short, .customLong("pass")], help: "Include per build job wall time distribution for a specific pass (repeatable argument)")
    var passes: [String] = []

    // Example: ProfileAnalyzer analyze-swift-stats-json -i stats2 -p "Import resolution" -p parse-and-resolve-imports -p load-stdlib
    func run() throws {
        let inputStatsDir = URL(fileURLWithPath: self.inputStatsDir).absoluteURL
        let outputCsvDir = self.outputCsvDir.map { URL(fileURLWithPath: $0).absoluteURL }

        if let outputCsvDir {
            try FileManager.default.createDirectory(at: outputCsvDir, withIntermediateDirectories: true)
        }

        let totalDistributions = try AnalyzeSwiftStatsJson.getTotalWallTimeDistributionsForAllRuns(baseDir: inputStatsDir)
        if let outputCsvDir {
            try AnalyzeSwiftStatsJson.writeCsv(
                toFile: outputCsvDir.appendingPathComponent("total_wall_time_distributions_for_all_runs.csv"),
                of: totalDistributions)
        } else {
            print("Total wall time distributions for all runs:")
            print()
            print(AnalyzeSwiftStatsJson.convertToCsv(rows: totalDistributions))
            print()
        }

        for passName in passes {
            let passDistributions = try AnalyzeSwiftStatsJson.getperBuildJobWallTimeDistributionsForAllRuns(passName: passName, baseDir: inputStatsDir)
            if let outputCsvDir {
                try AnalyzeSwiftStatsJson.writeCsv(
                    toFile: outputCsvDir.appendingPathComponent(passName.replacingOccurrences(of: " ", with: "_") + ".csv"),
                    of: passDistributions)
            } else {
                print("\(passName) distributions for all runs:")
                print()
                print(AnalyzeSwiftStatsJson.convertToCsv(rows: passDistributions))
                print()
            }
        }
    }
}
