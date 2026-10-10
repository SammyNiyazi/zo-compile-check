import Foundation

/// A bounded syntax preflight before Foundation decoding. It rejects duplicate
/// object keys (including escaped aliases) and excessive nesting instead of
/// relying on a decoder's arbitrary choice of value or recursive parse limits.
struct ImportJSONSyntax {
    private let bytes: [UInt8]
    private var index = 0
    private var values = 0

    init(data: Data) { bytes = Array(data) }

    mutating func validate() throws {
        guard bytes.count <= WorkoutHistoryImportDecoder.maximumFileBytes else {
            throw WorkoutHistoryImportError.oversizedFile
        }
        try value(depth: 0)
        whitespace()
        guard index == bytes.count else { throw WorkoutHistoryImportError.invalidFile }
    }

    private mutating func value(depth: Int) throws {
        values += 1
        guard depth <= 32, values <= 1_000_000 else { throw WorkoutHistoryImportError.invalidFile }
        whitespace()
        guard index < bytes.count else { throw WorkoutHistoryImportError.invalidFile }
        switch bytes[index] {
        case 123: // object
            index += 1
            whitespace()
            if consume(125) { return }
            var keys = Set<String>()
            while true {
                whitespace()
                let range = try string()
                let key = try JSONDecoder().decode(String.self, from: Data(bytes[range]))
                guard keys.insert(key).inserted else { throw WorkoutHistoryImportError.invalidFile }
                whitespace()
                guard consume(58) else { throw WorkoutHistoryImportError.invalidFile }
                try value(depth: depth + 1)
                whitespace()
                if consume(125) { return }
                guard consume(44) else { throw WorkoutHistoryImportError.invalidFile }
            }
        case 91: // array
            index += 1
            whitespace()
            if consume(93) { return }
            while true {
                try value(depth: depth + 1)
                whitespace()
                if consume(93) { return }
                guard consume(44) else { throw WorkoutHistoryImportError.invalidFile }
            }
        case 34:
            _ = try string()
        default:
            let start = index
            while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start, index - start <= 128 else { throw WorkoutHistoryImportError.invalidFile }
            // Foundation validates numeric and literal grammar after this preflight.
        }
    }

    private mutating func string() throws -> Range<Int> {
        let start = index
        guard consume(34) else { throw WorkoutHistoryImportError.invalidFile }
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 34 { return start..<index }
            guard byte >= 32 else { throw WorkoutHistoryImportError.invalidFile }
            if byte == 92 {
                guard index < bytes.count else { throw WorkoutHistoryImportError.invalidFile }
                index += 1 // escaped byte, including an escaped quote
            }
        }
        throw WorkoutHistoryImportError.invalidFile
    }

    private mutating func whitespace() {
        while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }
}
