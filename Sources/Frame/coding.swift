import Foundation

/// A typed decoder for Frame values. References remain distinct unless resolution is opted into.
public struct FrameCoding: Sendable {
    public enum DuplicateKeys: Sendable { case reject, first_wins, last_wins }
    public enum References: Sendable { case preserve, resolve }

    public let duplicateKeys: DuplicateKeys
    public let references: References

    public init(duplicateKeys: DuplicateKeys = .reject, references: References = .preserve) {
        self.duplicateKeys = duplicateKeys
        self.references = references
    }

    public func decode<T: Decodable>(_ type: T.Type, from document: Frame.Document) throws -> T {
        try FrameDecoder(value: .object(document.entries), document: document,
                         codingPath: [], duplicateKeys: duplicateKeys,
                         references: references).unbox(type)
    }
}

public extension Frame.Document {
    func decode<T: Decodable>(_ type: T.Type, using coding: FrameCoding = .init()) throws -> T {
        try coding.decode(type, from: self)
    }
}

public extension Frame {
    static func decode<T: Decodable>(_ type: T.Type, from source: String,
                                     filePath: String? = nil,
                                     using coding: FrameCoding = .init()) throws -> T {
        try coding.decode(type, from: parse(source, filePath: filePath))
    }
}

private struct FrameDecoder: Decoder {
    let value: Frame.Value
    let document: Frame.Document
    let codingPath: [CodingKey]
    let duplicateKeys: FrameCoding.DuplicateKeys
    let references: FrameCoding.References
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func effectiveValue() throws -> Frame.Value {
        guard case .reference(let reference) = value, references == .resolve else { return value }
        return try document.resolve(reference)
    }

    func mismatch(_ type: Any.Type) -> DecodingError {
        .typeMismatch(type, .init(codingPath: codingPath,
                                  debugDescription: "Frame value is not compatible with \(type)"))
    }

    func corruption(_ message: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: codingPath, debugDescription: message))
    }

    func child(_ value: Frame.Value, key: CodingKey) -> Self {
        .init(value: value, document: document, codingPath: codingPath + [key],
              duplicateKeys: duplicateKeys, references: references)
    }

    func unbox<T: Decodable>(_ type: T.Type) throws -> T {
        if type == Frame.Value.self, let result = value as? T { return result }
        if type == Frame.Reference.self, case .reference(let reference) = value,
           let result = reference as? T { return result }
        if type == Decimal.self {
            let result: Decimal
            switch try effectiveValue() {
            case .integer(let integer): result = Decimal(integer)
            case .decimal(let decimal): result = decimal
            default: throw mismatch(type)
            }
            if let cast = result as? T { return cast }
            throw mismatch(type)
        }
        return try T(from: self)
    }

    func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> where Key: CodingKey {
        guard case .object(let entries) = try effectiveValue() else { throw mismatch([String: Any].self) }
        return KeyedDecodingContainer(try FrameKeyedContainer(decoder: self, entries: entries))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard case .array(let values) = try effectiveValue() else { throw mismatch([Any].self) }
        return FrameUnkeyedContainer(decoder: self, values: values)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer { FrameSingleContainer(decoder: self) }
}

private struct FrameIndexKey: CodingKey {
    let intValue: Int?
    let stringValue: String
    init(_ index: Int) { intValue = index; stringValue = String(index) }
    init?(intValue: Int) { self.init(intValue) }
    init?(stringValue: String) {
        guard let index = Int(stringValue) else { return nil }
        self.init(index)
    }
}

private struct FrameFieldKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init(_ string: String) { stringValue = string; intValue = Int(string) }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { self.init(String(intValue)) }
}

private struct FrameKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let decoder: FrameDecoder
    let entries: [String: Frame.Entry]
    let allKeys: [Key]
    var codingPath: [CodingKey] { decoder.codingPath }

    init(decoder: FrameDecoder, entries raw: [Frame.Entry]) throws {
        self.decoder = decoder
        var selected: [String: Frame.Entry] = [:]
        var names: [String] = []
        for entry in raw {
            if selected[entry.name] != nil {
                switch decoder.duplicateKeys {
                case .reject:
                    throw decoder.child(entry.value, key: FrameFieldKey(entry.name))
                        .corruption("Duplicate Frame field '\(entry.name)'")
                case .first_wins: continue
                case .last_wins: break
                }
            } else {
                names.append(entry.name)
            }
            selected[entry.name] = entry
        }
        self.entries = selected
        self.allKeys = names.compactMap(Key.init(stringValue:))
    }

    func contains(_ key: Key) -> Bool { entries[key.stringValue] != nil }
    func decodeNil(forKey key: Key) throws -> Bool {
        guard let entry = entries[key.stringValue] else { return true }
        if case .null = try decoder.child(entry.value, key: key).effectiveValue() { return true }
        return false
    }

    private func require(_ key: Key) throws -> FrameDecoder {
        guard let entry = entries[key.stringValue] else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath,
                debugDescription: "Missing Frame field '\(key.stringValue)'"))
        }
        return decoder.child(entry.value, key: key)
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try require(key).unbox(type) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try require(key).unbox(type) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try require(key).unbox(type) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try require(key).unbox(type) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try require(key).unbox(type) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try require(key).unbox(type) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try require(key).unbox(type) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try require(key).unbox(type) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try require(key).unbox(type) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try require(key).unbox(type) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try require(key).unbox(type) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try require(key).unbox(type) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try require(key).unbox(type) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try require(key).unbox(type) }
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T { try require(key).unbox(type) }
    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type,
                                               forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        try require(key).container(keyedBy: type)
    }
    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        try require(key).unkeyedContainer()
    }
    func superDecoder() throws -> Decoder {
        let key = FrameFieldKey("super")
        return decoder.child(entries[key.stringValue]?.value ?? .object([]), key: key)
    }
    func superDecoder(forKey key: Key) throws -> Decoder { try require(key) }
}

private struct FrameUnkeyedContainer: UnkeyedDecodingContainer {
    let decoder: FrameDecoder
    let values: [Frame.Value]
    var currentIndex = 0
    var codingPath: [CodingKey] { decoder.codingPath }
    var count: Int? { values.count }
    var isAtEnd: Bool { currentIndex >= values.count }

    private mutating func take() throws -> FrameDecoder {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(Frame.Value.self, .init(codingPath: codingPath,
                debugDescription: "End of Frame array"))
        }
        let index = currentIndex
        currentIndex += 1
        return decoder.child(values[index], key: FrameIndexKey(index))
    }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else { return true }
        if case .null = try decoder.child(values[currentIndex], key: FrameIndexKey(currentIndex)).effectiveValue() {
            currentIndex += 1
            return true
        }
        return false
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool { try take().unbox(type) }
    mutating func decode(_ type: String.Type) throws -> String { try take().unbox(type) }
    mutating func decode(_ type: Double.Type) throws -> Double { try take().unbox(type) }
    mutating func decode(_ type: Float.Type) throws -> Float { try take().unbox(type) }
    mutating func decode(_ type: Int.Type) throws -> Int { try take().unbox(type) }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try take().unbox(type) }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try take().unbox(type) }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try take().unbox(type) }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try take().unbox(type) }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try take().unbox(type) }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try take().unbox(type) }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try take().unbox(type) }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try take().unbox(type) }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try take().unbox(type) }
    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T { try take().unbox(type) }
    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        try take().container(keyedBy: type)
    }
    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer { try take().unkeyedContainer() }
    mutating func superDecoder() throws -> Decoder { try take() }
}

private struct FrameSingleContainer: SingleValueDecodingContainer {
    let decoder: FrameDecoder
    var codingPath: [CodingKey] { decoder.codingPath }

    func decodeNil() -> Bool {
        if case .null = try? decoder.effectiveValue() { return true }
        return false
    }
    func decode(_ type: Bool.Type) throws -> Bool {
        guard case .boolean(let result) = try decoder.effectiveValue() else { throw decoder.mismatch(type) }
        return result
    }
    func decode(_ type: String.Type) throws -> String {
        guard case .string(let result) = try decoder.effectiveValue() else { throw decoder.mismatch(type) }
        return result
    }
    func decode(_ type: Int.Type) throws -> Int {
        guard case .integer(let result) = try decoder.effectiveValue() else { throw decoder.mismatch(type) }
        return result
    }
    private func exact<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        guard let result = T(exactly: try decode(Int.self)) else { throw decoder.mismatch(type) }
        return result
    }
    func decode(_ type: Int8.Type) throws -> Int8 { try exact(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try exact(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try exact(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try exact(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try exact(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try exact(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try exact(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try exact(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try exact(type) }
    func decode(_ type: Double.Type) throws -> Double {
        let result: Double
        switch try decoder.effectiveValue() {
        case .integer(let number): result = Double(number)
        case .decimal(let number): result = NSDecimalNumber(decimal: number).doubleValue
        default: throw decoder.mismatch(type)
        }
        guard result.isFinite else { throw decoder.mismatch(type) }
        return result
    }
    func decode(_ type: Float.Type) throws -> Float {
        let result = Float(try decode(Double.self))
        guard result.isFinite else { throw decoder.mismatch(type) }
        return result
    }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try decoder.unbox(type) }
}
