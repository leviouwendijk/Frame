import Foundation
import Position

public extension Frame {
    struct Reference: Hashable, Sendable, Codable {
        public let components: [String]

        public init(components: [String]) throws {
            guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty }) else {
                throw ResolutionFailure.invalid_reference
            }
            self.components = components
        }

        public var description: String { components.joined(separator: ".") }

        public init(from decoder: Decoder) throws {
            let parts = try decoder.singleValueContainer().decode([String].self)
            try self.init(components: parts)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(components)
        }
    }

    struct Entry: Sendable, Equatable {
        public enum Kind: Sendable { case assignment, declaration }
        public let name: String
        public let value: Value
        public let kind: Kind
        public let range: PositionRange
    }

    indirect enum Value: Sendable, Equatable {
        case string(String)
        case integer(Int)
        case decimal(Decimal)
        case boolean(Bool)
        case null
        case object([Entry])
        case array([Value])
        case reference(Reference)
    }

    struct Document: Sendable, Equatable {
        public let entries: [Entry]

        public init(entries: [Entry]) { self.entries = entries }
        public func entries(named name: String) -> [Entry] { entries.filter { $0.name == name } }

        /// Resolve a qualified accessor without coercing it into a string.
        public func resolve(_ reference: Reference) throws -> Value {
            var visited: Set<Reference> = []
            return try resolve(reference, visited: &visited)
        }

        private func resolve(_ reference: Reference, visited: inout Set<Reference>) throws -> Value {
            guard visited.insert(reference).inserted else { throw ResolutionFailure.cycle(reference) }
            defer { _ = visited.remove(reference) }
            var entries = self.entries
            for (index, component) in reference.components.enumerated() {
                let matches = entries.filter { $0.name == component }
                guard let entry = matches.first else { throw ResolutionFailure.missing(reference) }
                guard matches.count == 1 else { throw ResolutionFailure.ambiguous(reference) }
                var resolved = entry.value
                if case .reference(let nested) = resolved {
                    resolved = try resolve(nested, visited: &visited)
                }
                if index == reference.components.count - 1 { return resolved }
                guard case .object(let members) = resolved else {
                    throw ResolutionFailure.not_object(reference)
                }
                entries = members
            }
            throw ResolutionFailure.invalid_reference
        }
    }

    enum ResolutionFailure: Error, Sendable, Equatable {
        case invalid_reference
        case missing(Reference)
        case ambiguous(Reference)
        case not_object(Reference)
        case cycle(Reference)
    }
}
