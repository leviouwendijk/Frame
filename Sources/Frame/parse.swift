import Foundation
import enum Grammar.Grammar
import GrammarParsing
import Parsing
import Position

public extension Frame {
    struct SyntaxFailure: Error, Sendable, CustomStringConvertible {
        public let diagnostic: Diagnostic
        public init(_ diagnostic: Diagnostic) { self.diagnostic = diagnostic }
        public var description: String { diagnostic.description }
    }

    static func tree(_ source: String, filePath: String? = nil) throws -> GrammarParser.Node {
        try native.get().parse(source, filePath: filePath)
    }

    static func parse(_ source: String, filePath: String? = nil) throws -> Document {
        let root: GrammarParser.Node
        do {
            root = try tree(source, filePath: filePath)
        } catch GrammarParser.Failure.syntax(let diagnostic) {
            throw SyntaxFailure(diagnostic)
        } catch GrammarParser.Failure.lexical(let error) {
            let range = try? Position.TextMap(source: source).legacyRange(error.range)
            throw SyntaxFailure(Diagnostic(error.message, range: range, utf8Range: error.range))
        }
        return Document(entries: try Adapter(source: source).entries(in: root))
    }

    private static let native: Result<GrammarParser, any Error> = Result {
        try GrammarParser(language: language())
    }
}

private struct Adapter {
    let map: Position.TextMap
    init(source: String) { map = Position.TextMap(source: source) }

    func entries(in node: GrammarParser.Node) throws -> [Frame.Entry] {
        try node.children.filter { $0.name == "entry" }.map(entry)
    }

    func entry(_ node: GrammarParser.Node) throws -> Frame.Entry {
        guard let name = node.children.first(where: { $0.field == "name" })?.text,
              let value = node.children.first(where: { $0.field == "value" }) else {
            throw failure("Missing Frame entry field", at: node)
        }
        let kind: Frame.Entry.Kind = node.children.contains(where: { $0.text == "=" })
            ? .assignment : .declaration
        return Frame.Entry(name: name, value: try self.value(value), kind: kind,
                           range: try map.legacyRange(node.range))
    }

    func value(_ node: GrammarParser.Node) throws -> Frame.Value {
        switch node.name {
        case "value":
            guard let child = node.children.first else { throw failure("Missing Frame value", at: node) }
            return try value(child)
        case "quoted":
            guard let raw = node.text else { throw failure("Missing string literal", at: node) }
            return .string(try unescape(raw, at: node))
        case "number":
            guard let raw = node.text else { throw failure("Missing numeric literal", at: node) }
            if raw.contains(".") {
                guard let decimal = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else {
                    throw failure("Invalid decimal literal", at: node)
                }
                return .decimal(decimal)
            }
            guard let integer = Int(raw) else { throw failure("Integer out of range", at: node) }
            return .integer(integer)
        case "reference":
            let components = node.children.compactMap { child in
                child.name == "identifier" ? child.text : nil
            }
            if components == ["true"] { return .boolean(true) }
            if components == ["false"] { return .boolean(false) }
            if components == ["null"] { return .null }
            return .reference(try Frame.Reference(components: components))
        case "object":
            return .object(try entries(in: node))
        case "array":
            guard let items = node.children.first(where: { $0.name == "array_items" }) else {
                return .array([])
            }
            return .array(try arrayItems(items))
        default:
            throw failure("Unexpected Frame node '\(node.name)'", at: node)
        }
    }

    func arrayItems(_ node: GrammarParser.Node) throws -> [Frame.Value] {
        var values: [Frame.Value] = []
        for child in node.children {
            if child.name == "value" { values.append(try value(child)) }
            if child.name == "array_items" { values.append(contentsOf: try arrayItems(child)) }
        }
        return values
    }

    func unescape(_ raw: String, at node: GrammarParser.Node) throws -> String {
        let scalars = Array(raw.unicodeScalars)
        guard scalars.count >= 2 else { throw failure("Invalid string literal", at: node) }
        var result = String.UnicodeScalarView()
        var index = 1
        while index < scalars.count - 1 {
            if scalars[index] != "\\" {
                result.append(scalars[index])
                index += 1
                continue
            }
            index += 1
            guard index < scalars.count - 1 else { throw failure("Incomplete string escape", at: node) }
            switch scalars[index] {
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "\"": result.append("\"")
            case "\\": result.append("\\")
            case "u":
                guard index + 1 < scalars.count - 1, scalars[index + 1] == "{" else {
                    throw failure("Expected '{' after unicode escape", at: node)
                }
                index += 2
                var digits = ""
                while index < scalars.count - 1 && scalars[index] != "}" {
                    digits.unicodeScalars.append(scalars[index])
                    index += 1
                }
                guard index < scalars.count - 1, digits.count <= 8,
                      let number = UInt32(digits, radix: 16),
                      let unicode = Unicode.Scalar(number) else {
                    throw failure("Invalid unicode escape", at: node)
                }
                result.append(unicode)
            default: throw failure("Unsupported string escape", at: node)
            }
            index += 1
        }
        return String(result)
    }

    func failure(_ message: String, at node: GrammarParser.Node) -> Frame.SyntaxFailure {
        Frame.SyntaxFailure(Diagnostic(message, range: try? map.legacyRange(node.range), utf8Range: node.range))
    }
}
