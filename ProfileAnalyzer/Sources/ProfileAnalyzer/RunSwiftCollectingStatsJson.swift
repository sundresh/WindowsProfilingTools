import ArgumentParser
import Foundation

struct RunSwiftCollectingStatsJson: ParsableCommand {
    enum RunSwiftCollectingStatsJsonError: Error {
        case directoryExists(directory: URL)
    }

    static func invokeRuns(
        baseDir: URL,
        numWarmupRuns: Int,
        numMeasuredRuns: Int,
        runFunction: (URL) throws -> ()
    ) throws {
        let fm = FileManager.default

        let warmupDir = baseDir.appending(path: "warmup")
        defer {
            try? fm.removeItem(at: warmupDir)
        }

        for i in (1 - numWarmupRuns)...numMeasuredRuns {
            let runDir: URL

            if i <= 0 {
                print("Warming up...")            
                runDir = warmupDir
                try? fm.removeItem(at: runDir)
            } else {
                print("Measured run \(i)...")
                runDir = baseDir.appending(path: String(i))
                if fm.fileExists(atPath: runDir.path) {
                    throw RunSwiftCollectingStatsJsonError.directoryExists(directory: runDir)
                }
            }

            try fm.createDirectory(at: runDir, withIntermediateDirectories: true)
            try runFunction(runDir)
        }
    }

    static func runSwiftBuild(statsDir: URL) throws {
        let fm = FileManager.default
        let buildDir = URL(fileURLWithPath: ".build", isDirectory: true)

        try? fm.removeItem(at: buildDir)
        // We use `-j 1` for two reasons:
        // 1. Minimize the effect of concurrent passes on the timing of a pass
        // 2. Avoid differences in what source files' compilations each json file describes duie to job scheduling differences
        try runSubprocess("swift", "build", "-j", "1", "-Xswiftc", "-stats-output-dir", "-Xswiftc", statsDir.path)
    }

    static func runMultipleSwiftBuilds() throws {
        try invokeRuns(
            baseDir: URL(fileURLWithPath: "stats"),
            numWarmupRuns: 2,
            numMeasuredRuns: 20,
            runFunction: { try runSwiftBuild(statsDir: $0) }
        )
    }
}
