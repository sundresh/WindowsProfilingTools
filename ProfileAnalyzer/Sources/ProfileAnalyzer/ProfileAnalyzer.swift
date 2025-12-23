import ArgumentParser

@main
struct ProfileAnalyzer: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Profile analyzer for the Swift toolchain",
        subcommands: [
            RunSwiftBuildCollectingStatsJson.self,
            AnalyzeSwiftStatsJson.self,
            GetSwiftProfileLinesFromETLDump.self,
            GetSwiftProfileStatsFromETLDump.self,
            GetSwiftProfileStatsFromInstrumentsTrace.self
        ])
}
