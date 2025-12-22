import Testing
import Foundation
@testable import ProfileAnalyzer
import Darwin

let instrumentsTraceXMLFile = "symbolicated_trace.xml"

/// Returns the current memory usage in bytes using mach_task_info
func getCurrentMemoryUsage() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.resident_size : 0
}

/// Formats bytes as a human-readable string
func formatBytes(_ bytes: UInt64) -> String {
    let mb = Double(bytes) / (1024 * 1024)
    if mb >= 1024 {
        return String(format: "%.2f GB", mb / 1024)
    }
    return String(format: "%.1f MB", mb)
}

/// Parses the test XML file and reports time and memory usage.
@Test(.disabled("Requires a symbolicated XML trace from Instruments"))
func testParse() async throws {
    let url = URL(fileURLWithPath: instrumentsTraceXMLFile)

    // Force GC before measuring
    autoreleasepool {
        let _ = [Int](repeating: 0, count: 1000)
    }

    let memBefore = getCurrentMemoryUsage()
    let start = CFAbsoluteTimeGetCurrent()

    let trace = try InstrumentsTrace(from: url)

    let elapsed = CFAbsoluteTimeGetCurrent() - start
    let memAfter = getCurrentMemoryUsage()
    let memUsed = memAfter > memBefore ? memAfter - memBefore : 0

    print("Parse: \(trace.samples.count) samples, \(String(format: "%.2f", elapsed))s, mem: +\(formatBytes(memUsed))")

    #expect(trace.samples.count > 0)
}

/// Parses the test XML file with a process filter and reports time and memory usage.
@Test(.disabled("Requires a symbolicated XML trace from Instruments"))
func testParseFiltered() async throws {
    let url = URL(fileURLWithPath: instrumentsTraceXMLFile)

    let memBefore = getCurrentMemoryUsage()
    let start = CFAbsoluteTimeGetCurrent()

    let trace = try InstrumentsTrace(from: url) { process in
        process.name.localizedCaseInsensitiveContains("swift")
    }

    let elapsed = CFAbsoluteTimeGetCurrent() - start
    let memAfter = getCurrentMemoryUsage()
    let memUsed = memAfter > memBefore ? memAfter - memBefore : 0

    print("Parse filtered: \(trace.samples.count) samples, \(String(format: "%.2f", elapsed))s, mem: +\(formatBytes(memUsed))")

    #expect(trace.samples.count > 0)
}
