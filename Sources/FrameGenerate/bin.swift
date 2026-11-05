import Foundation
import Frame
import GrammarTreeSitter

@main
enum FrameGenerateCLI {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let directory: URL
        if arguments.count == 2, arguments[0] == "--output" {
            directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        } else if arguments.isEmpty {
            directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        } else {
            throw InvocationFailure.invalid_arguments
        }
        let artifacts = try GrammarTreeSitter.emit(Frame.language())
        let src = directory.appendingPathComponent("src", isDirectory: true)
        let queries = directory.appendingPathComponent("queries", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: queries, withIntermediateDirectories: true)
        try artifacts.grammarJSON.write(to: src.appendingPathComponent("grammar.json"),
                                        atomically: true, encoding: .utf8)
        for (filename, query) in artifacts.queries {
            try query.write(to: queries.appendingPathComponent(filename),
                            atomically: true, encoding: .utf8)
        }
        let manifest = #"{"name":"tree-sitter-frame","version":"0.1.0"}"#
        try manifest.write(to: directory.appendingPathComponent("package.json"),
                           atomically: true, encoding: .utf8)
        let metadata = #"""
        {
            "grammars": [{
                "name": "frame",
                "scope": "source.frame",
                "path": ".",
                "file-types": ["frame"]
            }],
            "metadata": {
                "version": "0.1.0",
                "authors": [{"name": "Frame Contributors"}]
            }
        }
        """#
        try metadata.write(to: directory.appendingPathComponent("tree-sitter.json"),
                           atomically: true, encoding: .utf8)
    }

    enum InvocationFailure: Error { case invalid_arguments }
}
