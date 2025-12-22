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

    // ID -> object lookup tables for ref resolution
    // Always cached (small objects, needed for ref resolution across rows)
    private var sampleTimeById: [String: SampleTime] = [:]
    private var threadById: [String: SampledThread] = [:]
    private var processById: [String: SampledProcess] = [:]
    private var weightById: [String: Weight] = [:]
    private var coreById: [String: Core] = [:]
    private var threadStateById: [String: ThreadState] = [:]
    private var binaryById: [String: Binary] = [:]
    private var sourcePathById: [String: String] = [:]

    // Large objects - only cached for matching processes when filter is set
    private var backtraceById: [String: Backtrace] = [:]
    private var frameById: [String: Frame] = [:]

    // Pending cache entries for large objects (committed only if process matches filter)
    private var pendingBacktraceCache: (String, Backtrace)?
    private var pendingFrameCaches: [(String, Frame)] = []

    // Element stack for tracking nesting
    private var elementStack: [String] = []
    private var currentText = ""

    // Track if we're inside a thread element (optimization: avoid scanning stack)
    private var parsingThreadDepth = 0

    // Current row being parsed
    private var currentRowSampleTime: SampleTime?
    private var currentRowThread: SampledThread?
    private var currentRowProcess: SampledProcess?
    private var currentRowCore: Core?
    private var currentRowThreadState: ThreadState?
    private var currentRowWeight: Weight?
    private var currentRowBacktrace: Backtrace?
    private var currentRowHasSentinel = false

    // Current element attributes (saved when element starts)
    private var pendingId: String?
    private var pendingFmt: String?
    private var pendingBinaryName: String?
    private var pendingBinaryUUID: String?
    private var pendingBinaryArch: String?
    private var pendingBinaryLoadAddr: String?
    private var pendingBinaryPath: String?
    private var pendingSourceLine: Int?

    // Current backtrace being built
    private var currentBacktraceFrames: [Frame] = []
    private var currentBacktraceId: String?

    // Current frame being built
    private var currentFrameBinary: Binary?
    private var currentFrameSource: SourceLocation?
    private var currentFrameId: String?
    private var currentFrameName: String?
    private var currentFrameAddr: String?

    // Current thread being built
    private var currentThreadId: String?
    private var currentThreadFmt: String?
    private var currentThreadTid: Int?
    private var currentThreadProcess: SampledProcess?

    // Current process being built (when nested in thread)
    private var currentProcessId: String?
    private var currentProcessFmt: String?
    private var currentProcessPid: Int?

    // Error tracking
    private var parseError: Error?

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
                currentRowSampleTime = existing
            } else {
                pendingId = id
                pendingFmt = fmt
            }

        case "thread":
            parsingThreadDepth += 1
            if let ref = ref, let existing = threadById[ref] {
                currentRowThread = existing
            } else {
                currentThreadId = id
                currentThreadFmt = fmt
                currentThreadTid = nil
                currentThreadProcess = nil
            }

        case "tid":
            pendingId = id
            pendingFmt = fmt

        case "process":
            if let ref = ref, let existing = processById[ref] {
                // Process reference
                if parsingThreadDepth > 0 {
                    currentThreadProcess = existing
                } else {
                    currentRowProcess = existing
                }
            } else {
                currentProcessId = id
                currentProcessFmt = fmt
                currentProcessPid = nil
            }

        case "pid":
            pendingId = id

        case "device-session":
            // We skip device-session as it's always "TODO" per the spec
            break

        case "core":
            if let ref = ref, let existing = coreById[ref] {
                currentRowCore = existing
            } else {
                pendingId = id
                pendingFmt = fmt
            }

        case "thread-state":
            if let ref = ref, let existing = threadStateById[ref] {
                currentRowThreadState = existing
            } else {
                pendingId = id
                pendingFmt = fmt
            }

        case "weight":
            if let ref = ref, let existing = weightById[ref] {
                currentRowWeight = existing
            } else {
                pendingId = id
                pendingFmt = fmt
            }

        case "backtrace":
            if let ref = ref, let existing = backtraceById[ref] {
                currentRowBacktrace = existing
            } else {
                currentBacktraceId = id
                currentBacktraceFrames.removeAll(keepingCapacity: true)
            }

        case "sentinel":
            currentRowHasSentinel = true

        case "frame":
            if let ref = ref, let existing = frameById[ref] {
                currentBacktraceFrames.append(existing)
            } else {
                currentFrameId = id
                currentFrameName = attributeDict["name"]
                currentFrameAddr = attributeDict["addr"]
                currentFrameBinary = nil
                currentFrameSource = nil
            }

        case "binary":
            if let ref = ref, let existing = binaryById[ref] {
                currentFrameBinary = existing
            } else {
                pendingId = id
                pendingBinaryName = attributeDict["name"]
                pendingBinaryUUID = attributeDict["UUID"]
                pendingBinaryArch = attributeDict["arch"]
                pendingBinaryLoadAddr = attributeDict["load-addr"]
                pendingBinaryPath = attributeDict["path"]
            }

        case "source":
            if let lineStr = attributeDict["line"], let line = Int(lineStr) {
                pendingSourceLine = line
            }

        case "path":
            // Source path element - check for ref
            if let ref = ref, let existing = sourcePathById[ref] {
                if let line = pendingSourceLine {
                    currentFrameSource = SourceLocation(path: existing, line: line)
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
            if currentRowSampleTime == nil {
                let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let nanoseconds = UInt64(text) {
                    let sampleTime = SampleTime(nanoseconds: nanoseconds, formatted: pendingFmt ?? "")
                    if let id = pendingId {
                        sampleTimeById[id] = sampleTime
                    }
                    currentRowSampleTime = sampleTime
                }
            }
            clearPending()

        case "tid":
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let tid = Int(text) {
                currentThreadTid = tid
            }
            clearPending()

        case "pid":
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let pid = Int(text) {
                currentProcessPid = pid
            }
            clearPending()

        case "process":
            if currentProcessId != nil {
                // We're finishing a process definition
                let process = SampledProcess(name: currentProcessFmt ?? "", pid: currentProcessPid ?? 0)
                if let id = currentProcessId {
                    processById[id] = process
                }
                if parsingThreadDepth > 0 {
                    currentThreadProcess = process
                } else {
                    currentRowProcess = process
                }
            }
            currentProcessId = nil
            currentProcessFmt = nil
            currentProcessPid = nil

        case "thread":
            if currentThreadId != nil {
                // We're finishing a thread definition
                let process = currentThreadProcess ?? SampledProcess(name: "", pid: 0)
                let thread = SampledThread(name: currentThreadFmt ?? "", tid: currentThreadTid ?? 0, process: process)
                if let id = currentThreadId {
                    threadById[id] = thread
                }
                currentRowThread = thread
            }
            currentThreadId = nil
            currentThreadFmt = nil
            currentThreadTid = nil
            currentThreadProcess = nil
            parsingThreadDepth -= 1

        case "core":
            if currentRowCore == nil {
                let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let number = Int(text) {
                    let core = Core(number: number, name: pendingFmt ?? "")
                    if let id = pendingId {
                        coreById[id] = core
                    }
                    currentRowCore = core
                }
            }
            clearPending()

        case "thread-state":
            if currentRowThreadState == nil {
                let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                let threadState = ThreadState(state: text)
                if let id = pendingId {
                    threadStateById[id] = threadState
                }
                currentRowThreadState = threadState
            }
            clearPending()

        case "weight":
            if currentRowWeight == nil {
                let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let nanoseconds = UInt64(text) {
                    let weight = Weight(nanoseconds: nanoseconds, formatted: pendingFmt ?? "")
                    if let id = pendingId {
                        weightById[id] = weight
                    }
                    currentRowWeight = weight
                }
            }
            clearPending()

        case "binary":
            if currentFrameBinary == nil && pendingBinaryName != nil {
                let loadAddr: UInt64?
                if let addrStr = pendingBinaryLoadAddr {
                    loadAddr = parseHexOrDecimal(addrStr)
                } else {
                    loadAddr = nil
                }
                let binary = Binary(
                    name: pendingBinaryName ?? "",
                    uuid: pendingBinaryUUID,
                    arch: pendingBinaryArch,
                    loadAddress: loadAddr,
                    path: pendingBinaryPath
                )
                if let id = pendingId {
                    binaryById[id] = binary
                }
                currentFrameBinary = binary
            }
            clearPending()
            pendingBinaryName = nil
            pendingBinaryUUID = nil
            pendingBinaryArch = nil
            pendingBinaryLoadAddr = nil
            pendingBinaryPath = nil

        case "path":
            // Source path text
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                if let id = pendingId {
                    sourcePathById[id] = text
                }
                if let line = pendingSourceLine {
                    currentFrameSource = SourceLocation(path: text, line: line)
                }
            }
            clearPending()

        case "source":
            pendingSourceLine = nil

        case "frame":
            if currentFrameId != nil {
                // We're finishing a frame definition
                let address = parseHexOrDecimal(currentFrameAddr ?? "0") ?? 0
                let frame = Frame(
                    name: currentFrameName ?? "",
                    address: address,
                    binary: currentFrameBinary,
                    source: currentFrameSource
                )
                if let id = currentFrameId {
                    pendingFrameCaches.append((id, frame))
                }
                currentBacktraceFrames.append(frame)
            }
            currentFrameId = nil
            currentFrameName = nil
            currentFrameAddr = nil
            currentFrameBinary = nil
            currentFrameSource = nil

        case "backtrace":
            if currentBacktraceId != nil {
                // We're finishing a backtrace definition
                let backtrace = Backtrace(frames: currentBacktraceFrames)
                if let id = currentBacktraceId {
                    pendingBacktraceCache = (id, backtrace)
                }
                currentRowBacktrace = backtrace
            }
            currentBacktraceId = nil
            // Don't clear frames here - removeAll(keepingCapacity:) is called at start

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }

    // MARK: - Helpers

    private func resetCurrentRow() {
        currentRowSampleTime = nil
        currentRowThread = nil
        currentRowProcess = nil
        currentRowCore = nil
        currentRowThreadState = nil
        currentRowWeight = nil
        currentRowBacktrace = nil
        currentRowHasSentinel = false

        // Reset pending caches for large objects
        pendingBacktraceCache = nil
        pendingFrameCaches.removeAll(keepingCapacity: true)
    }

    private func finalizeCurrentRow() {
        guard let time = currentRowSampleTime,
              let thread = currentRowThread,
              let core = currentRowCore,
              let threadState = currentRowThreadState,
              let weight = currentRowWeight else {
            return
        }

        // Process can come from thread or directly from row
        let process = currentRowProcess ?? thread.process

        // Apply process filter if present
        if let filter = processFilter, !filter(process) {
            // Don't cache large objects (frames/backtraces) for non-matching processes
            return
        }

        // Process matches filter (or no filter) - commit pending large object caches
        for (id, obj) in pendingFrameCaches {
            frameById[id] = obj
        }
        if let (id, obj) = pendingBacktraceCache {
            backtraceById[id] = obj
        }

        // Backtrace is nil if we saw a sentinel
        let backtrace = currentRowHasSentinel ? nil : currentRowBacktrace

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
