import Foundation

enum ProcessUtilsError: Error {
    case commandFailed(args: [String], terminationStatus: Int32)    
}

func runSubprocess(_ program: String, _ args: String...) throws {
    let process = try Process.run(
        URL(fileURLWithPath: program),
        arguments: args
    )
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ProcessUtilsError.commandFailed(args: [program] + args, terminationStatus: process.terminationStatus) 
    }
}
