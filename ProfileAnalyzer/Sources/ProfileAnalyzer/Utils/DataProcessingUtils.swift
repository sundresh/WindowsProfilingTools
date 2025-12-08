import Foundation

func transpose(_ data: [[String: Double]]) -> [String: [Double]] {
    var transposed: [String: [Double]] = [:]
    for dict in data {
        for (key, value) in dict {
            transposed[key, default: []].append(value)
        }
    }
    return transposed
}

func mean(_ values: [Double]) -> Double? {
    if values.isEmpty { return nil }
    return values.reduce(0, +) / Double(values.count)
}

func median(_ values: [Double]) -> Double? {
    if values.isEmpty { return nil }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    return sorted.count % 2 == 1
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2
}

func stdDev(_ values: [Double]) -> Double? {
    guard let m = mean(values) else { return nil }
    let variance = values.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(values.count)
    return sqrt(variance)
}

func csvEscape(_ value: String) -> String {
    if value.contains(",") || value.contains("\"") {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    } else {
        value
    }
}
