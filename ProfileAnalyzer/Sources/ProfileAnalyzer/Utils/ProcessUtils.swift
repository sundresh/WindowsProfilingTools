import Foundation

#if os(Windows)
let pathEnvVar = "Path"
let pathEnvVarSeparator: Character = ";"
let executableFileExtension = ".exe"
#else
let pathEnvVar = "PATH"
let pathEnvVarSeparator: Character = ":"
let executableFileExtension = ""
#endif

enum ProcessUtilsError: Error {
    case commandNotFound(program: String)
    case commandFailed(args: [String], terminationStatus: Int32)
}

func findExecutable(_ program: String) -> URL? {
    if program.contains("/") {
        return URL(fileURLWithPath: program)
    }

    let program = program + executableFileExtension

    let paths = (ProcessInfo.processInfo.environment[pathEnvVar] ?? "")
        .split(separator: pathEnvVarSeparator)
        .map(String.init)

    for dir in paths {
        let candidate = URL(fileURLWithPath: dir).appendingPathComponent(program)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }

    return nil
}

func runSubprocess(_ program: String, _ args: [String]) throws {
    guard let programPath = findExecutable(program) else {
        throw ProcessUtilsError.commandNotFound(program: program)
    }

    let process = try Process.run(
        programPath,
        arguments: args
    )
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw ProcessUtilsError.commandFailed(args: [programPath.path] + args, terminationStatus: process.terminationStatus) 
    }
}

func runSubprocess(_ program: String, _ args: String...) throws {
    try runSubprocess(program, args)
}
