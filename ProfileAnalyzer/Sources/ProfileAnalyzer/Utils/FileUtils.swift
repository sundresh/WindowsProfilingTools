import Foundation

enum FileUtilsError: Error {
    case invalidJson(file: URL)
}

func list(directory: URL) throws -> [URL] {
    let fm = FileManager.default

    return try fm.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )
}

func readJson(fromFile file: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: file)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw FileUtilsError.invalidJson(file: file)
    }
    return json
}
