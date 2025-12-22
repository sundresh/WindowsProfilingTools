import Foundation

// MARK: - Data Model (Classes for reference sharing via id/ref)

/// Binary/library information from a stack frame
final class Binary: @unchecked Sendable {
    let name: String
    let uuid: String?
    let arch: String?
    let loadAddress: UInt64?
    let path: String?

    init(name: String, uuid: String?, arch: String?, loadAddress: UInt64?, path: String?) {
        self.name = name
        self.uuid = uuid
        self.arch = arch
        self.loadAddress = loadAddress
        self.path = path
    }
}

/// Source file location for a symbolicated frame
final class SourceLocation: @unchecked Sendable {
    let path: String
    let line: Int

    init(path: String, line: Int) {
        self.path = path
        self.line = line
    }
}

/// A single stack frame
final class Frame: @unchecked Sendable {
    let name: String
    let address: UInt64
    let binary: Binary?
    let source: SourceLocation?

    init(name: String, address: UInt64, binary: Binary?, source: SourceLocation?) {
        self.name = name
        self.address = address
        self.binary = binary
        self.source = source
    }
}

/// A complete backtrace (list of frames from top to bottom of stack)
final class Backtrace: @unchecked Sendable {
    let frames: [Frame]

    init(frames: [Frame]) {
        self.frames = frames
    }
}

/// Process information
final class SampledProcess: @unchecked Sendable {
    let name: String
    let pid: Int

    init(name: String, pid: Int) {
        self.name = name
        self.pid = pid
    }
}

/// Thread information
final class SampledThread: @unchecked Sendable {
    let name: String
    let tid: Int
    let process: SampledProcess

    init(name: String, tid: Int, process: SampledProcess) {
        self.name = name
        self.tid = tid
        self.process = process
    }
}

/// CPU core information
final class Core: @unchecked Sendable {
    let number: Int
    let name: String

    init(number: Int, name: String) {
        self.number = number
        self.name = name
    }
}

/// Thread execution state
final class ThreadState: @unchecked Sendable {
    let state: String

    init(state: String) {
        self.state = state
    }
}

/// Sample timestamp
final class SampleTime: @unchecked Sendable {
    let nanoseconds: UInt64
    let formatted: String

    init(nanoseconds: UInt64, formatted: String) {
        self.nanoseconds = nanoseconds
        self.formatted = formatted
    }
}

/// Sample weight (duration)
final class Weight: @unchecked Sendable {
    let nanoseconds: UInt64
    let formatted: String

    init(nanoseconds: UInt64, formatted: String) {
        self.nanoseconds = nanoseconds
        self.formatted = formatted
    }
}

/// A single CPU sample row from the time profile
struct Sample: Sendable {
    let time: SampleTime
    let thread: SampledThread
    let process: SampledProcess
    let core: Core
    let threadState: ThreadState
    let weight: Weight
    let backtrace: Backtrace?  // nil if sentinel marker was present
}

// MARK: - Main Parser

struct InstrumentsTrace: Sendable {
    let samples: [Sample]

    /// Parse an Instruments trace XML file using SAX-style streaming parser
    init(from url: URL) throws {
        let parser = InstrumentsTraceXMLParser(processFilter: nil)
        try parser.parse(url: url)
        self.samples = parser.samples
    }

    /// Parse an Instruments trace XML file, filtering samples by process
    /// - Parameters:
    ///   - url: Path to the XML file
    ///   - processFilter: Predicate to filter which samples to retain based on process.
    ///                    Only samples where this returns true are kept.
    init(from url: URL, processFilter: @escaping (SampledProcess) -> Bool) throws {
        let parser = InstrumentsTraceXMLParser(processFilter: processFilter)
        try parser.parse(url: url)
        self.samples = parser.samples
    }
}

// MARK: - XMLParser Delegate Implementation

private final class InstrumentsTraceXMLParser: NSObject, XMLParserDelegate {
    var samples: [Sample] = []

    // Optional filter predicate for processes
    private let processFilter: ((SampledProcess) -> Bool)?

    init(processFilter: ((SampledProcess) -> Bool)?) {
        self.processFilter = processFilter
        super.init()
    }

    // MARK: - Builder Structs (mirror final class field order)

    /// Builder for Binary: name, uuid, arch, loadAddress, path
    private struct BinaryBuilder {
        var id: String?
        var name: String?
        var uuid: String?
        var arch: String?
        var loadAddress: String?
        var path: String?

        mutating func reset() {
            id = nil; name = nil; uuid = nil; arch = nil; loadAddress = nil; path = nil
        }
    }

    /// Builder for Frame: name, address, binary, source
    private struct FrameBuilder {
        var id: String?
        var name: String?
        var address: String?
        var binary: Binary?
        var source: SourceLocation?

        mutating func reset() {
            id = nil; name = nil; address = nil; binary = nil; source = nil
        }
    }

    /// Builder for Backtrace: frames
    private struct BacktraceBuilder {
        var id: String?
        var frames: [Frame] = []

        mutating func reset() {
            id = nil; frames.removeAll(keepingCapacity: true)
        }
    }

    /// Builder for SampledProcess: name, pid
    private struct ProcessBuilder {
        var id: String?
        var name: String?
        var pid: Int?

        mutating func reset() {
            id = nil; name = nil; pid = nil
        }
    }

    /// Builder for SampledThread: name, tid, process
    private struct ThreadBuilder {
        var id: String?
        var name: String?
        var tid: Int?
        var process: SampledProcess?

        mutating func reset() {
            id = nil; name = nil; tid = nil; process = nil
        }
    }

    /// Current row fields matching Sample: time, thread, process, core, threadState, weight, backtrace
    private struct RowBuilder {
        var time: SampleTime?
        var thread: SampledThread?
        var process: SampledProcess?
        var core: Core?
        var threadState: ThreadState?
        var weight: Weight?
        var backtrace: Backtrace?
        var hasSentinel: Bool = false

        mutating func reset() {
            time = nil; thread = nil; process = nil; core = nil
            threadState = nil; weight = nil; backtrace = nil; hasSentinel = false
        }
    }

    // MARK: - ID -> Object Caches

    // Always cached (small objects needed for ref resolution across rows)
    private var sampleTimeById: [String: SampleTime] = [:]
    private var processById: [String: SampledProcess] = [:]
    private var threadById: [String: SampledThread] = [:]
    private var coreById: [String: Core] = [:]
    private var threadStateById: [String: ThreadState] = [:]
    private var weightById: [String: Weight] = [:]
    private var binaryById: [String: Binary] = [:]
    private var sourcePathById: [String: String] = [:]

    // Large objects - only cached for matching processes when filter is set
    private var frameById: [String: Frame] = [:]
    private var backtraceById: [String: Backtrace] = [:]

    // Pending cache entries for large objects (committed only if process matches filter)
    private var pendingFrameCaches: [(String, Frame)] = []
    private var pendingBacktraceCache: (String, Backtrace)?

    // MARK: - Parser State

    private var elementStack: [String] = []
    private var currentText = ""
    private var parseError: Error?

    // Track nesting depth inside thread element (to know if process belongs to thread)
    private var threadNestingDepth = 0

    // Pending id/fmt for simple elements (sample-time, core, thread-state, weight, path)
    private var pendingId: String?
    private var pendingFmt: String?

    // Pending source line (for building SourceLocation)
    private var pendingSourceLine: Int?

    // MARK: - Current Builders

    private var currentRow = RowBuilder()
    private var currentProcess = ProcessBuilder()
    private var currentThread = ThreadBuilder()
    private var currentBacktrace = BacktraceBuilder()
    private var currentFrame = FrameBuilder()
    private var currentBinary = BinaryBuilder()

    func parse(url: URL) throws {
        guard let parser = XMLParser(contentsOf: url) else {
            throw NSError(domain: "InstrumentsTraceParser", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Could not open file: \(url.path)"])
        }

        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false

        // Pre-allocate samples array (estimate based on typical trace size)
        samples.reserveCapacity(200_000)

        let success = parser.parse()

        if let error = parseError {
            throw error
        }
        if !success, let error = parser.parserError {
            throw error
        }
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        elementStack.append(elementName)
        currentText = ""

        let id = attributeDict["id"]
        let ref = attributeDict["ref"]
        let fmt = attributeDict["fmt"]

        switch elementName {
        case "row":
            resetCurrentRow()

        case "sample-time":
            if let ref = ref, let existing = sampleTimeById[ref] {
                currentRow.time = existing
            } else {
                pendingId = id
                pendingFmt = fmt
            }

        case "thread":
            threadNestingDepth += 1
            if let ref = ref, let existing = threadById[ref] {
                currentRow.thread = existing
            } else {
                currentThread.id = id
                currentThread.name = fmt
                currentThread.tid = nil
                currentThread.process = nil
            }

        case "tid":
            break  // Text content parsed in didEndElement

        case "process":
            if let ref = ref, let existing = processById[ref] {
                if threadNestingDepth > 0 {
                    currentThread.process = existing
                } else {
                    currentRow.process = existing
                }
            } else {
                currentProcess.id = id
                currentProcess.name = fmt
                currentProcess.pid = nil
            }

        case "pid":
            break  // Text content parsed in didEndElement

        case "device-session":
            break  // Skipped - always "TODO" per spec

        case "core":
            if let ref = ref, let existing = coreById[ref] {
                currentRow.core = existing
            } else {
                pendingId = id
                pendingFmt = fmt
            }

        case "thread-state":
            if let ref = ref, let existing = threadStateById[ref] {
                currentRow.threadState = existing
            } else {
                pendingId = id
            }

        case "weight":
            if let ref = ref, let existing = weightById[ref] {
                currentRow.weight = existing
            } else {
                pendingId = id
                pendingFmt = fmt
            }

        case "backtrace":
            if let ref = ref, let existing = backtraceById[ref] {
                currentRow.backtrace = existing
            } else {
                currentBacktrace.id = id
                currentBacktrace.frames.removeAll(keepingCapacity: true)
            }

        case "sentinel":
            currentRow.hasSentinel = true

        case "frame":
            if let ref = ref, let existing = frameById[ref] {
                currentBacktrace.frames.append(existing)
            } else {
                currentFrame.id = id
                currentFrame.name = attributeDict["name"]
                currentFrame.address = attributeDict["addr"]
                currentFrame.binary = nil
                currentFrame.source = nil
            }

        case "binary":
            if let ref = ref, let existing = binaryById[ref] {
                currentFrame.binary = existing
            } else {
                currentBinary.id = id
                currentBinary.name = attributeDict["name"]
                currentBinary.uuid = attributeDict["UUID"]
                currentBinary.arch = attributeDict["arch"]
                currentBinary.loadAddress = attributeDict["load-addr"]
                currentBinary.path = attributeDict["path"]
            }

        case "source":
            if let lineStr = attributeDict["line"], let line = Int(lineStr) {
                pendingSourceLine = line
            }

        case "path":
            if let ref = ref, let existing = sourcePathById[ref] {
                if let line = pendingSourceLine {
                    currentFrame.source = SourceLocation(path: existing, line: line)
                }
            } else {
                pendingId = id
            }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        defer {
            _ = elementStack.popLast()
            currentText = ""
        }

        switch elementName {
        case "row":
            finalizeCurrentRow()

        case "sample-time":
            if currentRow.time == nil {
                let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let nanoseconds = UInt64(text) {
                    let sampleTime = SampleTime(nanoseconds: nanoseconds, formatted: pendingFmt ?? "")
                    if let id = pendingId {
                        sampleTimeById[id] = sampleTime
                    }
                    currentRow.time = sampleTime
                }
            }
            clearPending()

        case "tid":
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let tid = Int(text) {
                currentThread.tid = tid
            }

        case "pid":
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let pid = Int(text) {
                currentProcess.pid = pid
            }

        case "process":
            if currentProcess.id != nil {
                let process = SampledProcess(name: currentProcess.name ?? "", pid: currentProcess.pid ?? 0)
                if let id = currentProcess.id {
                    processById[id] = process
                }
                if threadNestingDepth > 0 {
                    currentThread.process = process
                } else {
                    currentRow.process = process
                }
            }
            currentProcess.reset()

        case "thread":
            if currentThread.id != nil {
                let process = currentThread.process ?? SampledProcess(name: "", pid: 0)
                let thread = SampledThread(name: currentThread.name ?? "", tid: currentThread.tid ?? 0, process: process)
                if let id = currentThread.id {
                    threadById[id] = thread
                }
                currentRow.thread = thread
            }
            currentThread.reset()
            threadNestingDepth -= 1

        case "core":
            if currentRow.core == nil {
                let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let number = Int(text) {
                    let core = Core(number: number, name: pendingFmt ?? "")
                    if let id = pendingId {
                        coreById[id] = core
                    }
                    currentRow.core = core
                }
            }
            clearPending()

        case "thread-state":
            if currentRow.threadState == nil {
                let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                let threadState = ThreadState(state: text)
                if let id = pendingId {
                    threadStateById[id] = threadState
                }
                currentRow.threadState = threadState
            }
            clearPending()

        case "weight":
            if currentRow.weight == nil {
                let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let nanoseconds = UInt64(text) {
                    let weight = Weight(nanoseconds: nanoseconds, formatted: pendingFmt ?? "")
                    if let id = pendingId {
                        weightById[id] = weight
                    }
                    currentRow.weight = weight
                }
            }
            clearPending()

        case "binary":
            if currentFrame.binary == nil && currentBinary.name != nil {
                let loadAddr = currentBinary.loadAddress.flatMap { parseHexOrDecimal($0) }
                let binary = Binary(
                    name: currentBinary.name ?? "",
                    uuid: currentBinary.uuid,
                    arch: currentBinary.arch,
                    loadAddress: loadAddr,
                    path: currentBinary.path
                )
                if let id = currentBinary.id {
                    binaryById[id] = binary
                }
                currentFrame.binary = binary
            }
            currentBinary.reset()

        case "path":
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                if let id = pendingId {
                    sourcePathById[id] = text
                }
                if let line = pendingSourceLine {
                    currentFrame.source = SourceLocation(path: text, line: line)
                }
            }
            clearPending()

        case "source":
            pendingSourceLine = nil

        case "frame":
            if currentFrame.id != nil {
                let address = parseHexOrDecimal(currentFrame.address ?? "0") ?? 0
                let frame = Frame(
                    name: currentFrame.name ?? "",
                    address: address,
                    binary: currentFrame.binary,
                    source: currentFrame.source
                )
                if let id = currentFrame.id {
                    pendingFrameCaches.append((id, frame))
                }
                currentBacktrace.frames.append(frame)
            }
            currentFrame.reset()

        case "backtrace":
            if currentBacktrace.id != nil {
                let backtrace = Backtrace(frames: currentBacktrace.frames)
                if let id = currentBacktrace.id {
                    pendingBacktraceCache = (id, backtrace)
                }
                currentRow.backtrace = backtrace
            }
            currentBacktrace.id = nil
            // Don't reset frames - removeAll(keepingCapacity:) called at start

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }

    // MARK: - Helpers

    private func resetCurrentRow() {
        currentRow.reset()
        pendingFrameCaches.removeAll(keepingCapacity: true)
        pendingBacktraceCache = nil
    }

    private func finalizeCurrentRow() {
        guard let time = currentRow.time,
              let thread = currentRow.thread,
              let core = currentRow.core,
              let threadState = currentRow.threadState,
              let weight = currentRow.weight else {
            return
        }

        // Process can come from thread or directly from row
        let process = currentRow.process ?? thread.process

        // Apply process filter if present
        if let filter = processFilter, !filter(process) {
            // Don't cache large objects (frames/backtraces) for non-matching processes
            return
        }

        // Process matches filter (or no filter) - commit pending large object caches
        for (id, frame) in pendingFrameCaches {
            frameById[id] = frame
        }
        if let (id, backtrace) = pendingBacktraceCache {
            backtraceById[id] = backtrace
        }

        // Backtrace is nil if we saw a sentinel
        let backtrace = currentRow.hasSentinel ? nil : currentRow.backtrace

        let sample = Sample(
            time: time,
            thread: thread,
            process: process,
            core: core,
            threadState: threadState,
            weight: weight,
            backtrace: backtrace
        )
        samples.append(sample)
    }

    private func clearPending() {
        pendingId = nil
        pendingFmt = nil
    }

    private func parseHexOrDecimal(_ string: String) -> UInt64? {
        if string.hasPrefix("0x") || string.hasPrefix("0X") {
            return UInt64(string.dropFirst(2), radix: 16)
        } else {
            return UInt64(string)
        }
    }
}
