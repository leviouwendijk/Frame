// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Frame",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Frame", targets: ["Frame"]),
        .executable(name: "frame_generate", targets: ["FrameGenerate"]),
        .executable(name: "t_frame", targets: ["FrameTestFlows"])
    ],
    dependencies: [
        .package(url: "https://github.com/leviouwendijk/Grammar.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Parsing.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Position.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Testing.git", branch: "master")
    ],
    targets: [
        .target(name: "Frame", dependencies: [
            .product(name: "Grammar", package: "Grammar"),
            .product(name: "GrammarParsing", package: "Parsing"),
            .product(name: "Parsing", package: "Parsing"),
            .product(name: "Position", package: "Position")
        ]),
        .executableTarget(name: "FrameGenerate", dependencies: [
            "Frame", .product(name: "GrammarTreeSitter", package: "Grammar")
        ]),
        .executableTarget(name: "FrameTestFlows", dependencies: [
            "Frame",
            .product(name: "Grammar", package: "Grammar"),
            .product(name: "GrammarParsing", package: "Parsing"),
            .product(name: "GrammarTreeSitter", package: "Grammar"),
            .product(name: "Testing", package: "Testing"),
            .product(name: "Position", package: "Position")
        ], path: "Testing/FrameTestFlows")
    ]
)
