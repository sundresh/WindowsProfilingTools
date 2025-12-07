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

    static func getPerSourceFileWallTimesForOneRun(passName: String, directory: URL) throws -> [String: Double] {
        var perSourceFile: [String: Double] = [:]
        let keyForPassNameWallTime = "time.swift.\(passName).wall"
        for file in try list(directory: directory) where file.pathExtension == "json" {
            let json = try readJson(fromFile: file)
            if let value = json[keyForPassNameWallTime] {
                perSourceFile[getSourceFileName(jsonFileName: file.lastPathComponent)] = (value as! Double)
            }
        }
        return perSourceFile
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

    static func getPerSourceFileWallTimesForAllRuns(passName: String, baseDir: URL) throws -> [[String: Double]] {
        var allPerSourceFile: [[String: Double]] = []
        for dirEntry in try list(directory: baseDir) {
            if !dirEntry.lastPathComponent.isEmpty && dirEntry.lastPathComponent.allSatisfy({ $0.isNumber }) {
                allPerSourceFile.append(try getPerSourceFileWallTimesForOneRun(passName: passName, directory: dirEntry))
            }
        }
        return allPerSourceFile
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

    static func getPerSourceFileWallTimeDistributionsForAllRuns(passName: String, baseDir: URL) throws -> [PassWallTimeDistribution] {
        var allDistributions: [PassWallTimeDistribution] = []
        for (passName, value) in transpose(try getPerSourceFileWallTimesForAllRuns(passName: passName, baseDir: baseDir)) {
            allDistributions.append(PassWallTimeDistribution(passName: passName, mean: mean(value)!, median: median(value)!, stdDev: stdDev(value)!))
        }
        return allDistributions
    }

    static func convertToCsv(rows: [PassWallTimeDistribution]) -> String {
        var csv = "passName,mean,median,stdDev\n"
        for row in rows.sorted(by: { $0.passName < $1.passName }) {
            // Escape commas / quotes in the pass name if necessary
            let safeName = row.passName.contains(",") || row.passName.contains("\"")
                ? "\"\(row.passName.replacingOccurrences(of: "\"", with: "\"\""))\""
                : row.passName

            csv += "\(safeName),\(row.mean),\(row.median),\(row.stdDev)\n"
        }
        return csv
    }

    static func writeCsv(toFile url: URL, of rows: [PassWallTimeDistribution]) throws {
        try convertToCsv(rows: rows)
            .write(to: url, atomically: true, encoding: .utf8)
    }

    func run() {
        let statsDir = URL(fileURLWithPath: ".")  // TODO: Make this an optional arg

        do {
            let totalDistributions = try AnalyzeSwiftStatsJson.getTotalWallTimeDistributionsForAllRuns(baseDir: statsDir)
            print("Total wall time distributions for all runs:")
            print()
            print(AnalyzeSwiftStatsJson.convertToCsv(rows: totalDistributions))
            print()

            for passName in ["Import resolution", "parse-and-resolve-imports", "load-stdlib"] {
                let passDistributions = try AnalyzeSwiftStatsJson.getPerSourceFileWallTimeDistributionsForAllRuns(passName: passName, baseDir: statsDir)
                print("\(passName) distributions for all runs:")
                print()
                print(AnalyzeSwiftStatsJson.convertToCsv(rows: passDistributions))
                print()
            }
        } catch {
            print("Error: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }
}
