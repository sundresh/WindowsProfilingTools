import ArgumentParser

@main
struct ProfileAnalyzer: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Profile analyzer for the Swift toolchain",
        subcommands: [RunSwiftCollectingStatsJson.self, AnalyzeSwiftStatsJson.self])
}
