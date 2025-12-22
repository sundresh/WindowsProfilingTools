import Foundation
import XMLCoder

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

// MARK: - Parsing Strategy

enum InstrumentsTraceParsingStrategy {
    /// SAX-style streaming parser using XMLParser. More memory efficient for large files
    /// as it doesn't load the entire DOM into memory.
    case sax

    /// DOM-style parser using XMLDocument. Simpler implementation but loads the entire
    /// XML tree into memory before processing. Only available on macOS.
    case dom

    /// Uses XMLCoder/XMLDecoder to decode the XML into Decodable structs, then
    /// post-processes to resolve id/ref relationships.
    case xmlDecoder
}

// MARK: - Main Parser

struct InstrumentsTrace: Sendable {
    let samples: [Sample]

    /// Parse using SAX-style XMLParser (default, more memory efficient)
    init(from url: URL) throws {
        try self.init(from: url, strategy: .sax)
    }

    /// Parse using the specified strategy
    init(from url: URL, strategy: InstrumentsTraceParsingStrategy) throws {
        switch strategy {
        case .sax:
            let parser = InstrumentsTraceXMLParser()
            try parser.parse(url: url)
            self.samples = parser.samples
        case .dom:
            let parser = InstrumentsTraceDOMParser()
            try parser.parse(url: url)
            self.samples = parser.samples
        case .xmlDecoder:
            let parser = InstrumentsTraceXMLDecoderParser()
            try parser.parse(url: url)
            self.samples = parser.samples
        }
    }
}

// MARK: - XMLParser Delegate Implementation

private final class InstrumentsTraceXMLParser: NSObject, XMLParserDelegate {
    var samples: [Sample] = []

    // ID -> object lookup tables for ref resolution
    private var sampleTimeById: [String: SampleTime] = [:]
    private var threadById: [String: SampledThread] = [:]
    private var processById: [String: SampledProcess] = [:]
    private var coreById: [String: Core] = [:]
    private var threadStateById: [String: ThreadState] = [:]
    private var weightById: [String: Weight] = [:]
    private var backtraceById: [String: Backtrace] = [:]
    private var frameById: [String: Frame] = [:]
    private var binaryById: [String: Binary] = [:]
    private var sourcePathById: [String: String] = [:]

    // Element stack for tracking nesting
    private var elementStack: [String] = []
    private var currentText = ""

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
    private var pendingName: String?
    private var pendingAddr: String?
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
                if isParsingThread() {
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
                currentBacktraceFrames = []
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
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "row":
            finalizeCurrentRow()

        case "sample-time":
            if currentRowSampleTime == nil {
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
            if let tid = Int(text) {
                currentThreadTid = tid
            }
            clearPending()

        case "pid":
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
                if isParsingThread() {
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

        case "core":
            if currentRowCore == nil {
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
                let threadState = ThreadState(state: text)
                if let id = pendingId {
                    threadStateById[id] = threadState
                }
                currentRowThreadState = threadState
            }
            clearPending()

        case "weight":
            if currentRowWeight == nil {
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
                    frameById[id] = frame
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
                    backtraceById[id] = backtrace
                }
                currentRowBacktrace = backtrace
            }
            currentBacktraceId = nil
            currentBacktraceFrames = []

        default:
            break
        }

        _ = elementStack.popLast()
        currentText = ""
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
        pendingName = nil
        pendingAddr = nil
    }

    private func isParsingThread() -> Bool {
        return elementStack.contains("thread")
    }

    private func parseHexOrDecimal(_ string: String) -> UInt64? {
        if string.hasPrefix("0x") || string.hasPrefix("0X") {
            return UInt64(string.dropFirst(2), radix: 16)
        } else {
            return UInt64(string)
        }
    }
}

// MARK: - XMLDocument DOM Parser Implementation

private final class InstrumentsTraceDOMParser {
    var samples: [Sample] = []

    // ID -> object lookup tables for ref resolution
    private var sampleTimeById: [String: SampleTime] = [:]
    private var threadById: [String: SampledThread] = [:]
    private var processById: [String: SampledProcess] = [:]
    private var coreById: [String: Core] = [:]
    private var threadStateById: [String: ThreadState] = [:]
    private var weightById: [String: Weight] = [:]
    private var backtraceById: [String: Backtrace] = [:]
    private var frameById: [String: Frame] = [:]
    private var binaryById: [String: Binary] = [:]
    private var sourcePathById: [String: String] = [:]

    func parse(url: URL) throws {
        let document = try XMLDocument(contentsOf: url, options: [])

        // Navigate to the rows: /trace-query-result/node/row
        guard let root = document.rootElement() else {
            throw NSError(domain: "InstrumentsTraceDOMParser", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "No root element found"])
        }

        // Find the node element containing rows
        guard let nodeElement = root.elements(forName: "node").first else {
            throw NSError(domain: "InstrumentsTraceDOMParser", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "No node element found"])
        }

        // Parse each row
        for rowElement in nodeElement.elements(forName: "row") {
            if let sample = parseRow(rowElement) {
                samples.append(sample)
            }
        }
    }

    private func parseRow(_ row: XMLElement) -> Sample? {
        var sampleTime: SampleTime?
        var thread: SampledThread?
        var process: SampledProcess?
        var core: Core?
        var threadState: ThreadState?
        var weight: Weight?
        var backtrace: Backtrace?
        var hasSentinel = false

        for child in row.children ?? [] {
            guard let element = child as? XMLElement else { continue }

            switch element.name {
            case "sample-time":
                sampleTime = parseSampleTime(element)
            case "thread":
                thread = parseThread(element)
            case "process":
                process = parseProcess(element)
            case "core":
                core = parseCore(element)
            case "thread-state":
                threadState = parseThreadState(element)
            case "weight":
                weight = parseWeight(element)
            case "backtrace":
                backtrace = parseBacktrace(element)
            case "sentinel":
                hasSentinel = true
            default:
                break
            }
        }

        guard let time = sampleTime,
              let t = thread,
              let c = core,
              let ts = threadState,
              let w = weight else {
            return nil
        }

        // Process can come from thread or directly
        let p = process ?? t.process

        return Sample(
            time: time,
            thread: t,
            process: p,
            core: c,
            threadState: ts,
            weight: w,
            backtrace: hasSentinel ? nil : backtrace
        )
    }

    private func parseSampleTime(_ element: XMLElement) -> SampleTime? {
        if let ref = element.attribute(forName: "ref")?.stringValue,
           let existing = sampleTimeById[ref] {
            return existing
        }

        guard let text = element.stringValue,
              let nanoseconds = UInt64(text) else {
            return nil
        }

        let fmt = element.attribute(forName: "fmt")?.stringValue ?? ""
        let sampleTime = SampleTime(nanoseconds: nanoseconds, formatted: fmt)

        if let id = element.attribute(forName: "id")?.stringValue {
            sampleTimeById[id] = sampleTime
        }

        return sampleTime
    }

    private func parseThread(_ element: XMLElement) -> SampledThread? {
        if let ref = element.attribute(forName: "ref")?.stringValue,
           let existing = threadById[ref] {
            return existing
        }

        let fmt = element.attribute(forName: "fmt")?.stringValue ?? ""
        var tid: Int = 0
        var process: SampledProcess?

        for child in element.children ?? [] {
            guard let childElement = child as? XMLElement else { continue }
            switch childElement.name {
            case "tid":
                if let text = childElement.stringValue, let value = Int(text) {
                    tid = value
                }
            case "process":
                process = parseProcess(childElement)
            default:
                break
            }
        }

        let thread = SampledThread(name: fmt, tid: tid, process: process ?? SampledProcess(name: "", pid: 0))

        if let id = element.attribute(forName: "id")?.stringValue {
            threadById[id] = thread
        }

        return thread
    }

    private func parseProcess(_ element: XMLElement) -> SampledProcess? {
        if let ref = element.attribute(forName: "ref")?.stringValue,
           let existing = processById[ref] {
            return existing
        }

        let fmt = element.attribute(forName: "fmt")?.stringValue ?? ""
        var pid: Int = 0

        for child in element.children ?? [] {
            guard let childElement = child as? XMLElement else { continue }
            if childElement.name == "pid" {
                if let text = childElement.stringValue, let value = Int(text) {
                    pid = value
                }
            }
        }

        let process = SampledProcess(name: fmt, pid: pid)

        if let id = element.attribute(forName: "id")?.stringValue {
            processById[id] = process
        }

        return process
    }

    private func parseCore(_ element: XMLElement) -> Core? {
        if let ref = element.attribute(forName: "ref")?.stringValue,
           let existing = coreById[ref] {
            return existing
        }

        guard let text = element.stringValue,
              let number = Int(text) else {
            return nil
        }

        let fmt = element.attribute(forName: "fmt")?.stringValue ?? ""
        let core = Core(number: number, name: fmt)

        if let id = element.attribute(forName: "id")?.stringValue {
            coreById[id] = core
        }

        return core
    }

    private func parseThreadState(_ element: XMLElement) -> ThreadState? {
        if let ref = element.attribute(forName: "ref")?.stringValue,
           let existing = threadStateById[ref] {
            return existing
        }

        let state = element.stringValue ?? ""
        let threadState = ThreadState(state: state)

        if let id = element.attribute(forName: "id")?.stringValue {
            threadStateById[id] = threadState
        }

        return threadState
    }

    private func parseWeight(_ element: XMLElement) -> Weight? {
        if let ref = element.attribute(forName: "ref")?.stringValue,
           let existing = weightById[ref] {
            return existing
        }

        guard let text = element.stringValue,
              let nanoseconds = UInt64(text) else {
            return nil
        }

        let fmt = element.attribute(forName: "fmt")?.stringValue ?? ""
        let weight = Weight(nanoseconds: nanoseconds, formatted: fmt)

        if let id = element.attribute(forName: "id")?.stringValue {
            weightById[id] = weight
        }

        return weight
    }

    private func parseBacktrace(_ element: XMLElement) -> Backtrace? {
        if let ref = element.attribute(forName: "ref")?.stringValue,
           let existing = backtraceById[ref] {
            return existing
        }

        var frames: [Frame] = []

        for child in element.children ?? [] {
            guard let frameElement = child as? XMLElement,
                  frameElement.name == "frame" else { continue }
            if let frame = parseFrame(frameElement) {
                frames.append(frame)
            }
        }

        let backtrace = Backtrace(frames: frames)

        if let id = element.attribute(forName: "id")?.stringValue {
            backtraceById[id] = backtrace
        }

        return backtrace
    }

    private func parseFrame(_ element: XMLElement) -> Frame? {
        if let ref = element.attribute(forName: "ref")?.stringValue,
           let existing = frameById[ref] {
            return existing
        }

        let name = element.attribute(forName: "name")?.stringValue ?? ""
        let addrStr = element.attribute(forName: "addr")?.stringValue ?? "0"
        let address = parseHexOrDecimal(addrStr) ?? 0

        var binary: Binary?
        var source: SourceLocation?

        for child in element.children ?? [] {
            guard let childElement = child as? XMLElement else { continue }
            switch childElement.name {
            case "binary":
                binary = parseBinary(childElement)
            case "source":
                source = parseSource(childElement)
            default:
                break
            }
        }

        let frame = Frame(name: name, address: address, binary: binary, source: source)

        if let id = element.attribute(forName: "id")?.stringValue {
            frameById[id] = frame
        }

        return frame
    }

    private func parseBinary(_ element: XMLElement) -> Binary? {
        if let ref = element.attribute(forName: "ref")?.stringValue,
           let existing = binaryById[ref] {
            return existing
        }

        let name = element.attribute(forName: "name")?.stringValue ?? ""
        let uuid = element.attribute(forName: "UUID")?.stringValue
        let arch = element.attribute(forName: "arch")?.stringValue
        let loadAddrStr = element.attribute(forName: "load-addr")?.stringValue
        let loadAddress = loadAddrStr.flatMap { parseHexOrDecimal($0) }
        let path = element.attribute(forName: "path")?.stringValue

        let binary = Binary(name: name, uuid: uuid, arch: arch, loadAddress: loadAddress, path: path)

        if let id = element.attribute(forName: "id")?.stringValue {
            binaryById[id] = binary
        }

        return binary
    }

    private func parseSource(_ element: XMLElement) -> SourceLocation? {
        guard let lineStr = element.attribute(forName: "line")?.stringValue,
              let line = Int(lineStr) else {
            return nil
        }

        var path: String?

        for child in element.children ?? [] {
            guard let pathElement = child as? XMLElement,
                  pathElement.name == "path" else { continue }

            if let ref = pathElement.attribute(forName: "ref")?.stringValue,
               let existing = sourcePathById[ref] {
                path = existing
            } else if let text = pathElement.stringValue {
                path = text
                if let id = pathElement.attribute(forName: "id")?.stringValue {
                    sourcePathById[id] = text
                }
            }
            break
        }

        guard let sourcePath = path else { return nil }
        return SourceLocation(path: sourcePath, line: line)
    }

    private func parseHexOrDecimal(_ string: String) -> UInt64? {
        if string.hasPrefix("0x") || string.hasPrefix("0X") {
            return UInt64(string.dropFirst(2), radix: 16)
        } else {
            return UInt64(string)
        }
    }
}

// MARK: - XMLDecoder-based Parser Implementation

// Intermediate Decodable structs for XMLCoder
// These capture the raw XML structure including id/ref attributes

private struct DecodableTraceQueryResult: Decodable {
    let node: DecodableNode

    enum CodingKeys: String, CodingKey {
        case node
    }
}

private struct DecodableNode: Decodable {
    let rows: [DecodableRow]

    enum CodingKeys: String, CodingKey {
        case rows = "row"
    }
}

private struct DecodableRow: Decodable {
    let sampleTime: DecodableSampleTime?
    let thread: DecodableThread?
    let process: DecodableProcess?
    let core: DecodableCore?
    let threadState: DecodableThreadState?
    let weight: DecodableWeight?
    let backtrace: DecodableBacktrace?
    let sentinel: DecodableSentinel?

    enum CodingKeys: String, CodingKey {
        case sampleTime = "sample-time"
        case thread
        case process
        case core
        case threadState = "thread-state"
        case weight
        case backtrace
        case sentinel
    }
}

private struct DecodableSentinel: Decodable {}

private struct DecodableSampleTime: Decodable, DynamicNodeDecoding {
    let id: String?
    let ref: String?
    let fmt: String?
    let value: String?

    enum CodingKeys: String, CodingKey {
        case id, ref, fmt
        case value = ""
    }

    static func nodeDecoding(for key: CodingKey) -> XMLDecoder.NodeDecoding {
        switch key {
        case CodingKeys.value: return .element
        default: return .attribute
        }
    }
}

private struct DecodableThread: Decodable, DynamicNodeDecoding {
    let id: String?
    let ref: String?
    let fmt: String?
    let tid: DecodableTid?
    let process: DecodableProcess?

    enum CodingKeys: String, CodingKey {
        case id, ref, fmt, tid, process
    }

    static func nodeDecoding(for key: CodingKey) -> XMLDecoder.NodeDecoding {
        switch key {
        case CodingKeys.id, CodingKeys.ref, CodingKeys.fmt: return .attribute
        default: return .element
        }
    }
}

private struct DecodableTid: Decodable, DynamicNodeDecoding {
    let id: String?
    let fmt: String?
    let value: String?

    enum CodingKeys: String, CodingKey {
        case id, fmt
        case value = ""
    }

    static func nodeDecoding(for key: CodingKey) -> XMLDecoder.NodeDecoding {
        switch key {
        case CodingKeys.value: return .element
        default: return .attribute
        }
    }
}

private struct DecodableProcess: Decodable, DynamicNodeDecoding {
    let id: String?
    let ref: String?
    let fmt: String?
    let pid: DecodablePid?

    enum CodingKeys: String, CodingKey {
        case id, ref, fmt, pid
    }

    static func nodeDecoding(for key: CodingKey) -> XMLDecoder.NodeDecoding {
        switch key {
        case CodingKeys.id, CodingKeys.ref, CodingKeys.fmt: return .attribute
        default: return .element
        }
    }
}

private struct DecodablePid: Decodable, DynamicNodeDecoding {
    let id: String?
    let fmt: String?
    let value: String?

    enum CodingKeys: String, CodingKey {
        case id, fmt
        case value = ""
    }

    static func nodeDecoding(for key: CodingKey) -> XMLDecoder.NodeDecoding {
        switch key {
        case CodingKeys.value: return .element
        default: return .attribute
        }
    }
}

private struct DecodableCore: Decodable, DynamicNodeDecoding {
    let id: String?
    let ref: String?
    let fmt: String?
    let value: String?

    enum CodingKeys: String, CodingKey {
        case id, ref, fmt
        case value = ""
    }

    static func nodeDecoding(for key: CodingKey) -> XMLDecoder.NodeDecoding {
        switch key {
        case CodingKeys.value: return .element
        default: return .attribute
        }
    }
}

private struct DecodableThreadState: Decodable, DynamicNodeDecoding {
    let id: String?
    let ref: String?
    let fmt: String?
    let value: String?

    enum CodingKeys: String, CodingKey {
        case id, ref, fmt
        case value = ""
    }

    static func nodeDecoding(for key: CodingKey) -> XMLDecoder.NodeDecoding {
        switch key {
        case CodingKeys.value: return .element
        default: return .attribute
        }
    }
}

private struct DecodableWeight: Decodable, DynamicNodeDecoding {
    let id: String?
    let ref: String?
    let fmt: String?
    let value: String?

    enum CodingKeys: String, CodingKey {
        case id, ref, fmt
        case value = ""
    }

    static func nodeDecoding(for key: CodingKey) -> XMLDecoder.NodeDecoding {
        switch key {
        case CodingKeys.value: return .element
        default: return .attribute
        }
    }
}

private struct DecodableBacktrace: Decodable, DynamicNodeDecoding {
    let id: String?
    let ref: String?
    let frames: [DecodableFrame]?

    enum CodingKeys: String, CodingKey {
        case id, ref
        case frames = "frame"
    }

    static func nodeDecoding(for key: CodingKey) -> XMLDecoder.NodeDecoding {
        switch key {
        case CodingKeys.id, CodingKeys.ref: return .attribute
        default: return .element
        }
    }
}

private struct DecodableFrame: Decodable, DynamicNodeDecoding {
    let id: String?
    let ref: String?
    let name: String?
    let addr: String?
    let binary: DecodableBinary?
    let source: DecodableSource?

    enum CodingKeys: String, CodingKey {
        case id, ref, name, addr, binary, source
    }

    static func nodeDecoding(for key: CodingKey) -> XMLDecoder.NodeDecoding {
        switch key {
        case CodingKeys.id, CodingKeys.ref, CodingKeys.name, CodingKeys.addr: return .attribute
        default: return .element
        }
    }
}

private struct DecodableBinary: Decodable, DynamicNodeDecoding {
    let id: String?
    let ref: String?
    let name: String?
    let uuid: String?
    let arch: String?
    let loadAddr: String?
    let path: String?

    enum CodingKeys: String, CodingKey {
        case id, ref, name, arch, path
        case uuid = "UUID"
        case loadAddr = "load-addr"
    }

    static func nodeDecoding(for key: CodingKey) -> XMLDecoder.NodeDecoding {
        return .attribute
    }
}

private struct DecodableSource: Decodable, DynamicNodeDecoding {
    let line: String?
    let path: DecodableSourcePath?

    enum CodingKeys: String, CodingKey {
        case line, path
    }

    static func nodeDecoding(for key: CodingKey) -> XMLDecoder.NodeDecoding {
        switch key {
        case CodingKeys.line: return .attribute
        default: return .element
        }
    }
}

private struct DecodableSourcePath: Decodable, DynamicNodeDecoding {
    let id: String?
    let ref: String?
    let value: String?

    enum CodingKeys: String, CodingKey {
        case id, ref
        case value = ""
    }

    static func nodeDecoding(for key: CodingKey) -> XMLDecoder.NodeDecoding {
        switch key {
        case CodingKeys.value: return .element
        default: return .attribute
        }
    }
}

// The XMLDecoder-based parser
private final class InstrumentsTraceXMLDecoderParser {
    var samples: [Sample] = []

    // ID -> object lookup tables for ref resolution
    private var sampleTimeById: [String: SampleTime] = [:]
    private var threadById: [String: SampledThread] = [:]
    private var processById: [String: SampledProcess] = [:]
    private var coreById: [String: Core] = [:]
    private var threadStateById: [String: ThreadState] = [:]
    private var weightById: [String: Weight] = [:]
    private var backtraceById: [String: Backtrace] = [:]
    private var frameById: [String: Frame] = [:]
    private var binaryById: [String: Binary] = [:]
    private var sourcePathById: [String: String] = [:]

    func parse(url: URL) throws {
        let data = try Data(contentsOf: url)
        let decoder = XMLDecoder()
        decoder.shouldProcessNamespaces = false

        let result = try decoder.decode(DecodableTraceQueryResult.self, from: data)

        // Post-process: resolve refs and build final objects
        for decodableRow in result.node.rows {
            if let sample = resolveRow(decodableRow) {
                samples.append(sample)
            }
        }
    }

    private func resolveRow(_ row: DecodableRow) -> Sample? {
        guard let sampleTime = resolveSampleTime(row.sampleTime),
              let thread = resolveThread(row.thread),
              let core = resolveCore(row.core),
              let threadState = resolveThreadState(row.threadState),
              let weight = resolveWeight(row.weight) else {
            return nil
        }

        // Process can come from thread or directly from row
        let process = resolveProcess(row.process) ?? thread.process

        // Backtrace is nil if we saw a sentinel
        let backtrace = row.sentinel != nil ? nil : resolveBacktrace(row.backtrace)

        return Sample(
            time: sampleTime,
            thread: thread,
            process: process,
            core: core,
            threadState: threadState,
            weight: weight,
            backtrace: backtrace
        )
    }

    private func resolveSampleTime(_ st: DecodableSampleTime?) -> SampleTime? {
        guard let st = st else { return nil }

        if let ref = st.ref, let existing = sampleTimeById[ref] {
            return existing
        }

        guard let valueStr = st.value, let nanoseconds = UInt64(valueStr) else {
            return nil
        }

        let sampleTime = SampleTime(nanoseconds: nanoseconds, formatted: st.fmt ?? "")
        if let id = st.id {
            sampleTimeById[id] = sampleTime
        }
        return sampleTime
    }

    private func resolveThread(_ t: DecodableThread?) -> SampledThread? {
        guard let t = t else { return nil }

        if let ref = t.ref, let existing = threadById[ref] {
            return existing
        }

        let tid = t.tid?.value.flatMap { Int($0) } ?? 0
        let process = resolveProcess(t.process) ?? SampledProcess(name: "", pid: 0)
        let thread = SampledThread(name: t.fmt ?? "", tid: tid, process: process)

        if let id = t.id {
            threadById[id] = thread
        }
        return thread
    }

    private func resolveProcess(_ p: DecodableProcess?) -> SampledProcess? {
        guard let p = p else { return nil }

        if let ref = p.ref, let existing = processById[ref] {
            return existing
        }

        let pid = p.pid?.value.flatMap { Int($0) } ?? 0
        let process = SampledProcess(name: p.fmt ?? "", pid: pid)

        if let id = p.id {
            processById[id] = process
        }
        return process
    }

    private func resolveCore(_ c: DecodableCore?) -> Core? {
        guard let c = c else { return nil }

        if let ref = c.ref, let existing = coreById[ref] {
            return existing
        }

        guard let valueStr = c.value, let number = Int(valueStr) else {
            return nil
        }

        let core = Core(number: number, name: c.fmt ?? "")
        if let id = c.id {
            coreById[id] = core
        }
        return core
    }

    private func resolveThreadState(_ ts: DecodableThreadState?) -> ThreadState? {
        guard let ts = ts else { return nil }

        if let ref = ts.ref, let existing = threadStateById[ref] {
            return existing
        }

        let state = ts.value ?? ""
        let threadState = ThreadState(state: state)

        if let id = ts.id {
            threadStateById[id] = threadState
        }
        return threadState
    }

    private func resolveWeight(_ w: DecodableWeight?) -> Weight? {
        guard let w = w else { return nil }

        if let ref = w.ref, let existing = weightById[ref] {
            return existing
        }

        guard let valueStr = w.value, let nanoseconds = UInt64(valueStr) else {
            return nil
        }

        let weight = Weight(nanoseconds: nanoseconds, formatted: w.fmt ?? "")
        if let id = w.id {
            weightById[id] = weight
        }
        return weight
    }

    private func resolveBacktrace(_ bt: DecodableBacktrace?) -> Backtrace? {
        guard let bt = bt else { return nil }

        if let ref = bt.ref, let existing = backtraceById[ref] {
            return existing
        }

        var frames: [Frame] = []
        for decodableFrame in bt.frames ?? [] {
            if let frame = resolveFrame(decodableFrame) {
                frames.append(frame)
            }
        }

        let backtrace = Backtrace(frames: frames)
        if let id = bt.id {
            backtraceById[id] = backtrace
        }
        return backtrace
    }

    private func resolveFrame(_ f: DecodableFrame) -> Frame? {
        if let ref = f.ref, let existing = frameById[ref] {
            return existing
        }

        let address = parseHexOrDecimal(f.addr ?? "0") ?? 0
        let binary = resolveBinary(f.binary)
        let source = resolveSource(f.source)

        let frame = Frame(name: f.name ?? "", address: address, binary: binary, source: source)
        if let id = f.id {
            frameById[id] = frame
        }
        return frame
    }

    private func resolveBinary(_ b: DecodableBinary?) -> Binary? {
        guard let b = b else { return nil }

        if let ref = b.ref, let existing = binaryById[ref] {
            return existing
        }

        let loadAddress = b.loadAddr.flatMap { parseHexOrDecimal($0) }
        let binary = Binary(
            name: b.name ?? "",
            uuid: b.uuid,
            arch: b.arch,
            loadAddress: loadAddress,
            path: b.path
        )

        if let id = b.id {
            binaryById[id] = binary
        }
        return binary
    }

    private func resolveSource(_ s: DecodableSource?) -> SourceLocation? {
        guard let s = s, let lineStr = s.line, let line = Int(lineStr) else {
            return nil
        }

        var path: String?
        if let pathObj = s.path {
            if let ref = pathObj.ref, let existing = sourcePathById[ref] {
                path = existing
            } else if let value = pathObj.value {
                path = value
                if let id = pathObj.id {
                    sourcePathById[id] = value
                }
            }
        }

        guard let sourcePath = path else { return nil }
        return SourceLocation(path: sourcePath, line: line)
    }

    private func parseHexOrDecimal(_ string: String) -> UInt64? {
        if string.hasPrefix("0x") || string.hasPrefix("0X") {
            return UInt64(string.dropFirst(2), radix: 16)
        } else {
            return UInt64(string)
        }
    }
}
