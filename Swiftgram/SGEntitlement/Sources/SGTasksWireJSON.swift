import Foundation

/// Zenlygram — the one JSON codec of the Tasks wire (`SGTasksWire`).
///
/// Foundation's `JSONSerialization` / `JSONDecoder` cannot be the codec here: they accept duplicate
/// object keys (last one wins), silently turn `1.0` and `1e0` into integers, round 19-digit numbers
/// through `Double`, and never say how deep a document is. The wire forbids all of that, so this is a
/// small strict RFC 8259 parser plus the canonical encoder the business hash is defined over
/// (`x-mutation-identity.canonical_json`):
/// - input must be valid UTF-8 with no BOM; insignificant whitespace is only space/tab/LF/CR;
/// - duplicate keys in one object, lone surrogates, raw control characters and any trailing bytes
///   are rejected;
/// - numbers must be plain integers that fit `Int64` (`-?(0|[1-9][0-9]*)`): no fraction, no exponent;
/// - nesting deeper than `maxDepth` is rejected before it is built.
///
/// The encoder writes compact JSON with raw UTF-8 (U+2028/U+2029 included), unescaped `/`, escaped
/// quote and backslash, the five short escapes and lowercase `\u00xx` for every other C0 control.
/// Object members are written in the order given, so encoding is deterministic.
enum SGTasksJSON {
    struct Member: Equatable {
        let name: String
        let value: Value
    }

    indirect enum Value: Equatable {
        case null
        case bool(Bool)
        case integer(Int64)
        case string(String)
        case array([Value])
        case object([Member])
    }

    enum ParseError: Error, Equatable {
        case invalidUTF8
        case tooLarge
        case tooDeep
        case syntax
        case duplicateKey
        case numberOutOfRange
    }

    // MARK: - Parse

    /// `lenientNumbers` is for ERROR bodies only (`SGTasksErrorClassifier.envelope`): a number with a
    /// fraction or exponent, or outside `Int64`, is consumed by the full RFC 8259 grammar and read as
    /// `.null` instead of failing the whole document. Every other rule — size, depth, UTF-8,
    /// duplicate keys, trailing bytes — is unchanged. Success bodies never use it.
    static func parse(_ data: Data, maxBytes: Int, maxDepth: Int, lenientNumbers: Bool = false) throws -> Value {
        guard data.count <= maxBytes else {
            throw ParseError.tooLarge
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw ParseError.invalidUTF8
        }
        var parser = Parser(bytes: [UInt8](data), maxDepth: maxDepth, lenientNumbers: lenientNumbers)
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.isAtEnd else {
            throw ParseError.syntax
        }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        let maxDepth: Int
        let lenientNumbers: Bool
        var index = 0

        init(bytes: [UInt8], maxDepth: Int, lenientNumbers: Bool) {
            self.bytes = bytes
            self.maxDepth = maxDepth
            self.lenientNumbers = lenientNumbers
        }

        var isAtEnd: Bool {
            return self.index >= self.bytes.count
        }

        mutating func skipWhitespace() {
            while self.index < self.bytes.count {
                switch self.bytes[self.index] {
                case 0x20, 0x09, 0x0a, 0x0d:
                    self.index += 1
                default:
                    return
                }
            }
        }

        mutating func peek() throws -> UInt8 {
            guard self.index < self.bytes.count else {
                throw ParseError.syntax
            }
            return self.bytes[self.index]
        }

        mutating func expect(_ literal: String) throws {
            for byte in literal.utf8 {
                guard try self.peek() == byte else {
                    throw ParseError.syntax
                }
                self.index += 1
            }
        }

        mutating func parseValue(depth: Int) throws -> Value {
            switch try self.peek() {
            case UInt8(ascii: "{"):
                return try self.parseObject(depth: depth + 1)
            case UInt8(ascii: "["):
                return try self.parseArray(depth: depth + 1)
            case UInt8(ascii: "\""):
                return .string(try self.parseString())
            case UInt8(ascii: "t"):
                try self.expect("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try self.expect("false")
                return .bool(false)
            case UInt8(ascii: "n"):
                try self.expect("null")
                return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0") ... UInt8(ascii: "9"):
                return try self.parseNumber()
            default:
                throw ParseError.syntax
            }
        }

        mutating func parseObject(depth: Int) throws -> Value {
            guard depth <= self.maxDepth else {
                throw ParseError.tooDeep
            }
            self.index += 1
            var members: [Member] = []
            var names = Set<String>()
            self.skipWhitespace()
            if try self.peek() == UInt8(ascii: "}") {
                self.index += 1
                return .object(members)
            }
            while true {
                self.skipWhitespace()
                guard try self.peek() == UInt8(ascii: "\"") else {
                    throw ParseError.syntax
                }
                let name = try self.parseString()
                guard names.insert(name).inserted else {
                    throw ParseError.duplicateKey
                }
                self.skipWhitespace()
                try self.expect(":")
                self.skipWhitespace()
                let value = try self.parseValue(depth: depth)
                members.append(Member(name: name, value: value))
                self.skipWhitespace()
                let separator = try self.peek()
                self.index += 1
                if separator == UInt8(ascii: "}") {
                    return .object(members)
                }
                guard separator == UInt8(ascii: ",") else {
                    throw ParseError.syntax
                }
            }
        }

        mutating func parseArray(depth: Int) throws -> Value {
            guard depth <= self.maxDepth else {
                throw ParseError.tooDeep
            }
            self.index += 1
            var elements: [Value] = []
            self.skipWhitespace()
            if try self.peek() == UInt8(ascii: "]") {
                self.index += 1
                return .array(elements)
            }
            while true {
                self.skipWhitespace()
                elements.append(try self.parseValue(depth: depth))
                self.skipWhitespace()
                let separator = try self.peek()
                self.index += 1
                if separator == UInt8(ascii: "]") {
                    return .array(elements)
                }
                guard separator == UInt8(ascii: ",") else {
                    throw ParseError.syntax
                }
            }
        }

        mutating func parseNumber() throws -> Value {
            guard self.lenientNumbers else {
                return .integer(try self.parseInteger())
            }
            let start = self.index
            if try self.peek() == UInt8(ascii: "-") {
                self.index += 1
            }
            let firstDigit = try self.peek()
            guard self.isDigit(firstDigit) else {
                throw ParseError.syntax
            }
            self.index += 1
            if firstDigit != UInt8(ascii: "0") {
                self.skipDigits()
            }
            var isInteger = true
            if self.index < self.bytes.count, self.bytes[self.index] == UInt8(ascii: ".") {
                isInteger = false
                self.index += 1
                try self.requireDigits()
            }
            if self.index < self.bytes.count, self.bytes[self.index] == UInt8(ascii: "e") || self.bytes[self.index] == UInt8(ascii: "E") {
                isInteger = false
                self.index += 1
                if self.index < self.bytes.count, self.bytes[self.index] == UInt8(ascii: "+") || self.bytes[self.index] == UInt8(ascii: "-") {
                    self.index += 1
                }
                try self.requireDigits()
            }
            if self.index < self.bytes.count, self.isDigit(self.bytes[self.index]) {
                // A leading zero followed by a digit is not JSON.
                throw ParseError.syntax
            }
            let text = String(decoding: self.bytes[start ..< self.index], as: UTF8.self)
            if isInteger, text != "-0", let value = Int64(text) {
                return .integer(value)
            }
            return .null
        }

        func isDigit(_ byte: UInt8) -> Bool {
            return byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
        }

        mutating func skipDigits() {
            while self.index < self.bytes.count, self.isDigit(self.bytes[self.index]) {
                self.index += 1
            }
        }

        mutating func requireDigits() throws {
            guard self.index < self.bytes.count, self.isDigit(self.bytes[self.index]) else {
                throw ParseError.syntax
            }
            self.skipDigits()
        }

        mutating func parseInteger() throws -> Int64 {
            let start = self.index
            if try self.peek() == UInt8(ascii: "-") {
                self.index += 1
            }
            let firstDigit = try self.peek()
            guard firstDigit >= UInt8(ascii: "0"), firstDigit <= UInt8(ascii: "9") else {
                throw ParseError.syntax
            }
            self.index += 1
            if firstDigit != UInt8(ascii: "0") {
                while self.index < self.bytes.count, self.bytes[self.index] >= UInt8(ascii: "0"), self.bytes[self.index] <= UInt8(ascii: "9") {
                    self.index += 1
                }
            }
            if self.index < self.bytes.count {
                switch self.bytes[self.index] {
                case UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"), UInt8(ascii: "0") ... UInt8(ascii: "9"):
                    // A fraction or exponent is not an integer on this wire, and a leading zero
                    // followed by a digit is not JSON.
                    throw ParseError.syntax
                default:
                    break
                }
            }
            let text = String(decoding: self.bytes[start ..< self.index], as: UTF8.self)
            guard text != "-0", let value = Int64(text) else {
                throw ParseError.numberOutOfRange
            }
            return value
        }

        mutating func parseString() throws -> String {
            self.index += 1
            var output: [UInt8] = []
            while true {
                let byte = try self.peek()
                self.index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    return String(decoding: output, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    try self.parseEscape(into: &output)
                case 0x00 ..< 0x20:
                    throw ParseError.syntax
                default:
                    output.append(byte)
                }
            }
        }

        mutating func parseEscape(into output: inout [UInt8]) throws {
            let byte = try self.peek()
            self.index += 1
            switch byte {
            case UInt8(ascii: "\""):
                output.append(0x22)
            case UInt8(ascii: "\\"):
                output.append(0x5c)
            case UInt8(ascii: "/"):
                output.append(0x2f)
            case UInt8(ascii: "b"):
                output.append(0x08)
            case UInt8(ascii: "f"):
                output.append(0x0c)
            case UInt8(ascii: "n"):
                output.append(0x0a)
            case UInt8(ascii: "r"):
                output.append(0x0d)
            case UInt8(ascii: "t"):
                output.append(0x09)
            case UInt8(ascii: "u"):
                let first = try self.parseHex4()
                let scalarValue: UInt32
                switch first {
                case 0xd800 ... 0xdbff:
                    try self.expect("\\u")
                    let second = try self.parseHex4()
                    guard (0xdc00 ... 0xdfff).contains(second) else {
                        throw ParseError.syntax
                    }
                    scalarValue = 0x10000 + ((first - 0xd800) << 10) + (second - 0xdc00)
                case 0xdc00 ... 0xdfff:
                    throw ParseError.syntax
                default:
                    scalarValue = first
                }
                guard let scalar = Unicode.Scalar(scalarValue) else {
                    throw ParseError.syntax
                }
                output.append(contentsOf: Array(String(Character(scalar)).utf8))
            default:
                throw ParseError.syntax
            }
        }

        mutating func parseHex4() throws -> UInt32 {
            var value: UInt32 = 0
            for _ in 0 ..< 4 {
                let byte = try self.peek()
                self.index += 1
                let digit: UInt32
                switch byte {
                case UInt8(ascii: "0") ... UInt8(ascii: "9"):
                    digit = UInt32(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a") ... UInt8(ascii: "f"):
                    digit = UInt32(byte - UInt8(ascii: "a")) + 10
                case UInt8(ascii: "A") ... UInt8(ascii: "F"):
                    digit = UInt32(byte - UInt8(ascii: "A")) + 10
                default:
                    throw ParseError.syntax
                }
                value = value << 4 | digit
            }
            return value
        }
    }

    // MARK: - Encode

    static func encode(_ value: Value) -> Data {
        var output: [UInt8] = []
        self.append(value, to: &output)
        return Data(output)
    }

    static func append(_ value: Value, to output: inout [UInt8]) {
        switch value {
        case .null:
            output.append(contentsOf: Array("null".utf8))
        case let .bool(flag):
            output.append(contentsOf: Array((flag ? "true" : "false").utf8))
        case let .integer(number):
            output.append(contentsOf: Array(String(number).utf8))
        case let .string(text):
            self.appendString(text, to: &output)
        case let .array(elements):
            output.append(UInt8(ascii: "["))
            for (index, element) in elements.enumerated() {
                if index > 0 {
                    output.append(UInt8(ascii: ","))
                }
                self.append(element, to: &output)
            }
            output.append(UInt8(ascii: "]"))
        case let .object(members):
            output.append(UInt8(ascii: "{"))
            for (index, member) in members.enumerated() {
                if index > 0 {
                    output.append(UInt8(ascii: ","))
                }
                self.appendString(member.name, to: &output)
                output.append(UInt8(ascii: ":"))
                self.append(member.value, to: &output)
            }
            output.append(UInt8(ascii: "}"))
        }
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    static func appendString(_ text: String, to output: inout [UInt8]) {
        output.append(UInt8(ascii: "\""))
        for byte in text.utf8 {
            switch byte {
            case 0x22:
                output.append(contentsOf: [0x5c, 0x22])
            case 0x5c:
                output.append(contentsOf: [0x5c, 0x5c])
            case 0x08:
                output.append(contentsOf: [0x5c, UInt8(ascii: "b")])
            case 0x09:
                output.append(contentsOf: [0x5c, UInt8(ascii: "t")])
            case 0x0a:
                output.append(contentsOf: [0x5c, UInt8(ascii: "n")])
            case 0x0c:
                output.append(contentsOf: [0x5c, UInt8(ascii: "f")])
            case 0x0d:
                output.append(contentsOf: [0x5c, UInt8(ascii: "r")])
            case 0x00 ..< 0x20:
                output.append(contentsOf: Array("\\u00".utf8))
                output.append(self.hexDigits[Int(byte >> 4)])
                output.append(self.hexDigits[Int(byte & 0x0f)])
            default:
                // Multi-byte UTF-8 sequences pass through unchanged: raw Unicode, U+2028/U+2029 too.
                output.append(byte)
            }
        }
        output.append(UInt8(ascii: "\""))
    }
}
