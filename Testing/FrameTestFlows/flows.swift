import Foundation
import Frame
import GrammarParsing
import GrammarTreeSitter
import Position
import Testing

enum FrameTestSuite {
    static let suite = TestSuite("frame", title: "Frame language integration") {
        Test("assignments, blocks, accessors, decimals and unicode preserve types and ranges") {
            let source = """
                // Frame is not Pkl: assignments end with semicolons.
                packages {
                    runtime = "AgenticRuntime";
                    timeout = 1.25;
                }
                workflows {
                    agentic_debug {
                        package = packages.runtime;
                        enabled = true;
                        skipped = null;
                        retry = -2;
                        stages = [{ id = "runtime"; }, { id = "host"; },];
                        label = "é\\nnext";
                    }
                }
                """
            let document = try Frame.parse(source, filePath: "/repo/workflows.frame")
            try Expect.equal(document.entries.map(\.name), ["packages", "workflows"], "top-level order")
            try Expect.equal(document.entries[0].kind, .declaration, "block declaration")
            guard case .object(let packages) = document.entries[0].value else {
                throw Frame.SyntaxFailure(.init("Expected packages object"))
            }
            try Expect.equal(packages[0].value, .string("AgenticRuntime"), "first package")
            try Expect.equal(packages[1].value, .decimal(Decimal(125) / Decimal(100)), "decimal literal")
            let ref = try Frame.Reference(components: ["packages", "runtime"])
            try Expect.equal(try document.resolve(ref), .string("AgenticRuntime"), "accessor resolution")
            guard case .object(let workflows) = document.entries[1].value,
                  case .object(let config) = workflows.first?.value else {
                throw Frame.SyntaxFailure(.init("Expected workflow object"))
            }
            try Expect.equal(config[0].value, .reference(ref), "accessor remains typed")
            try Expect.equal(config[1].value, .boolean(true), "boolean literal")
            try Expect.equal(config[2].value, .null, "null literal")
            try Expect.equal(config[3].value, .integer(-2), "negative integer")
            guard case .array(let stages) = config[4].value else {
                throw Frame.SyntaxFailure(.init("Expected array"))
            }
            try Expect.equal(stages.count, 2, "comma-separated objects, trailing comma")
            try Expect.equal(config[5].value, .string("é\nnext"), "string decoding")
            let map = Position.TextMap(source: source)
            let bytes = try map.range(document.entries[1].range, as: Position.Unit.UTF8.self)
            try Expect.equal(bytes.upperBound.offset, source.utf8.count, "byte alignment")
        }

        Test("FrameCoding decodes arbitrary domain structs without importing consumer types") {
            struct Package: Decodable, Equatable { let runtime: String; let enabled: Bool }
            struct Stage: Decodable, Equatable { let package: String; let test: String }
            struct Workflow: Decodable, Equatable { let stages: [Stage] }
            struct Configuration: Decodable, Equatable {
                let packages: Package
                let workflow: Workflow
            }
            let source = """
                packages { runtime = "AgenticRuntime"; enabled = true; }
                workflow {
                    stages = [{ package = packages.runtime; test = "t_runtime"; }];
                }
                """
            let document = try Frame.parse(source)
            try Expect.throwsError("references must not become strings implicitly") {
                _ = try document.decode(Configuration.self)
            }
            let resolved = try document.decode(Configuration.self, using: .init(references: .resolve))
            try Expect.equal(resolved.packages.runtime, "AgenticRuntime", "decoded package")
            try Expect.equal(resolved.workflow.stages[0].package, "AgenticRuntime", "resolved accessor")
            try Expect.equal(resolved.workflow.stages[0].test, "t_runtime", "decoded stage")
        }

        Test("syntax failures reject missing semicolons, array separators and invalid escapes") {
            let invalid = [
                "name = \"missing-semicolon\"",
                "names = [\"a\" \"b\"];",
                "name = [1, 2;",
                "name = \"bad\\q\";",
                "name = \"bad\\u{XYZ}\";",
                "package = packages.;",
                "config { x = true;",
                "value = 01;",
                "name = \"a\"; }"
            ]
            for (index, source) in invalid.enumerated() {
                try Expect.throwsError("invalid Frame fixture \(index)") {
                    _ = try Frame.parse(source)
                }
            }
            let valid = "name = \"ok\";"
            try Expect.equal(try Frame.parse(valid).entries.count, 1, "valid terminator")
        }

        Test("duplicate keys and cyclic references are rejected explicitly") {
            struct Model: Decodable { let name: String }
            let duplicate = try Frame.parse("name = \"first\"; name = \"second\";")
            try Expect.equal(duplicate.entries(named: "name").count, 2, "AST retains duplicates")
            try Expect.throwsError("reject duplicates by default") {
                _ = try duplicate.decode(Model.self)
            }
            let first = try duplicate.decode(Model.self, using: .init(duplicateKeys: .first_wins))
            let last = try duplicate.decode(Model.self, using: .init(duplicateKeys: .last_wins))
            try Expect.equal(first.name, "first", "first_wins")
            try Expect.equal(last.name, "second", "last_wins")
            let cyclic = try Frame.parse("a = b; b = a;")
            let ref = try Frame.Reference(components: ["a"])
            try Expect.throwsError("reference cycle") { _ = try cyclic.resolve(ref) }
            let missing = try Frame.Reference(components: ["nonexistent"])
            try Expect.throwsError("unknown reference") { _ = try cyclic.resolve(missing) }
        }

        Test("native parser and generated Tree-sitter recognize identical Frame syntax") {
            try FrameParity.run()
        }
    }
}

private enum FrameParity {
    static func run() throws {
        let language = try Frame.language()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("frame-grammar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let src = workspace.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let artifacts = try GrammarTreeSitter.emit(language)
        try write(artifacts.grammarJSON, at: src.appendingPathComponent("grammar.json"))
        try write(#"{"name":"tree-sitter-frame","version":"0.1.0"}"#,
                  at: workspace.appendingPathComponent("package.json"))
        let metadata = #"""
        {
            "grammars": [{
                "name": "frame",
                "scope": "source.frame",
                "path": ".",
                "file-types": ["frame"]
            }],
            "metadata": { "version": "0.1.0", "authors": [{"name": "Frame Conformance"}] }
        }
        """#
        try write(metadata, at: workspace.appendingPathComponent("tree-sitter.json"))
        let generated = try command(["generate", "src/grammar.json"], in: workspace)
        try Expect.equal(generated.status, 0, "Tree-sitter generation: \(generated.output)")
        let native = try GrammarParser(language: language)
        let samples: [(String, Bool)] = [
            ("name = \"Frame\";", true),
            ("packages { runtime = \"AgenticRuntime\"; }", true),
            ("workflow { package = packages.runtime; enabled = true; }", true),
            ("values = [1, 2, 3,];", true),
            ("stages = [{ id = \"a\"; }, { id = \"b\"; }];", true),
            ("threshold = -1.25;", true),
            ("empty = []; object = {};", true),
            ("name = \"missing semicolon\"", false),
            ("names = [\"a\" \"b\"];", false),
            ("package = packages.;", false),
            ("name = \"x\"; }", false)
        ]
        for (index, fixture) in samples.enumerated() {
            let path = workspace.appendingPathComponent("case-\(index).frame")
            try write(fixture.0, at: path)
            let nativeAccepted = (try? native.parse(fixture.0)) != nil
            let parsed = try command(["parse", "--grammar-path", workspace.path, path.path], in: workspace)
            let sitterAccepted = parsed.status == 0
                && !parsed.output.contains("(ERROR")
                && !parsed.output.contains("(MISSING")
            try Expect.equal(nativeAccepted, fixture.1, "native fixture \(index)")
            try Expect.equal(sitterAccepted, fixture.1, "Tree-sitter fixture \(index): \(parsed.output)")
        }
    }

    static func write(_ text: String, at path: URL) throws {
        try text.write(to: path, atomically: true, encoding: .utf8)
    }

    static func command(_ arguments: [String], in workspace: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tree-sitter"] + arguments
        process.currentDirectoryURL = workspace
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}
