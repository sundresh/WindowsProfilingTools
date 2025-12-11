import Foundation

func trimSpaces(_ slice: Data.SubSequence) -> Data.SubSequence {
    var start = slice.startIndex
    var end = slice.endIndex

    while start < end, isAsciiSpace(slice[start]) {
        start = slice.index(after: start)
    }

    while start < end {
        let prev = slice.index(before: end)
        if isAsciiSpace(slice[prev]) {
            end = prev
        } else {
            break
        }
    }

    return slice[start..<end]
}

func isAsciiSpace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 // space or tab
}

func splitColumns(_ data: Data, delimiter: UInt8 = 0x2C) -> [Data.SubSequence] {
    var result: [Data.SubSequence] = []
    var start = data.startIndex
    var idx = start

    while idx < data.endIndex {
        if data[idx] == delimiter {
            result.append(data[start..<idx])
            start = data.index(after: idx)
        }
        idx = data.index(after: idx)
    }

    result.append(data[start..<data.endIndex])
    return result
}
