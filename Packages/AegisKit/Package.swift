// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AegisKit",
    defaultLocalization: "zh-Hans",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AegisCore", targets: ["AegisCore"]),
        .library(name: "AegisStorage", targets: ["AegisStorage"]),
        .library(name: "AegisSync", targets: ["AegisSync"]),
        .library(name: "AegisMarkdown", targets: ["AegisMarkdown"])
    ],
    dependencies: [.package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0")],
    targets: [
        .target(name: "CArgon2", exclude: ["LICENSE"], publicHeadersPath: "include",
                cSettings: [.define("ARGON2_NO_THREADS"), .headerSearchPath("include")]),
        .target(name: "AegisCore", dependencies: ["CArgon2"], exclude: ["Resources/Localizable.xcstrings"], resources: [.process("Resources")]),
        .target(name: "AegisStorage", dependencies: ["AegisCore"]),
        .target(name: "AegisSync", dependencies: ["AegisCore", "AegisStorage"]),
        .target(name: "AegisMarkdown", dependencies: ["AegisCore", .product(name: "Markdown", package: "swift-markdown")]),
        .testTarget(name: "AegisCoreTests", dependencies: ["AegisCore", "AegisStorage", "AegisMarkdown", "CArgon2"])
    ],
    swiftLanguageModes: [.v6]
)
