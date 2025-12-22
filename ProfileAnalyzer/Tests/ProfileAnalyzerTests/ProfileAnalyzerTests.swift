import Testing
import Foundation
@testable import ProfileAnalyzer

@Test func testSAXParser() async throws {
    let url = URL(fileURLWithPath: "/Users/sameer.sundresh/bydate/2025/12/11/symbolicated_trace.xml")

    let start = CFAbsoluteTimeGetCurrent()
    let trace = try InstrumentsTrace(from: url, strategy: .sax)
    let elapsed = CFAbsoluteTimeGetCurrent() - start

    print("SAX: Parsed \(trace.samples.count) samples in \(String(format: "%.2f", elapsed)) seconds")

    #expect(trace.samples.count > 0)

    if let first = trace.samples.first {
        print("First sample: time=\(first.time.formatted), process=\(first.process.name), pid=\(first.process.pid)")
    }
    if let last = trace.samples.last {
        print("Last sample: time=\(last.time.formatted), process=\(last.process.name), pid=\(last.process.pid)")
    }

    // Check reference sharing works (same process object should be reused)
    let processes = Set(trace.samples.map { ObjectIdentifier($0.process) })
    print("Unique process objects: \(processes.count)")
}

@Test func testDOMParser() async throws {
    let url = URL(fileURLWithPath: "/Users/sameer.sundresh/bydate/2025/12/11/symbolicated_trace.xml")

    let start = CFAbsoluteTimeGetCurrent()
    let trace = try InstrumentsTrace(from: url, strategy: .dom)
    let elapsed = CFAbsoluteTimeGetCurrent() - start

    print("DOM: Parsed \(trace.samples.count) samples in \(String(format: "%.2f", elapsed)) seconds")

    #expect(trace.samples.count > 0)

    if let first = trace.samples.first {
        print("First sample: time=\(first.time.formatted), process=\(first.process.name), pid=\(first.process.pid)")
    }
    if let last = trace.samples.last {
        print("Last sample: time=\(last.time.formatted), process=\(last.process.name), pid=\(last.process.pid)")
    }

    // Check reference sharing works
    let processes = Set(trace.samples.map { ObjectIdentifier($0.process) })
    print("Unique process objects: \(processes.count)")
}

@Test func testXMLDecoderParser() async throws {
    let url = URL(fileURLWithPath: "/Users/sameer.sundresh/bydate/2025/12/11/symbolicated_trace.xml")

    let start = CFAbsoluteTimeGetCurrent()
    let trace = try InstrumentsTrace(from: url, strategy: .xmlDecoder)
    let elapsed = CFAbsoluteTimeGetCurrent() - start

    print("XMLDecoder: Parsed \(trace.samples.count) samples in \(String(format: "%.2f", elapsed)) seconds")

    #expect(trace.samples.count > 0)

    if let first = trace.samples.first {
        print("First sample: time=\(first.time.formatted), process=\(first.process.name), pid=\(first.process.pid)")
    }
    if let last = trace.samples.last {
        print("Last sample: time=\(last.time.formatted), process=\(last.process.name), pid=\(last.process.pid)")
    }

    // Check reference sharing works
    let processes = Set(trace.samples.map { ObjectIdentifier($0.process) })
    print("Unique process objects: \(processes.count)")
}
