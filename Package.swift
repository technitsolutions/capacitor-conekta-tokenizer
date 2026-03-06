// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CapacitorConektaTokenizer",
    platforms: [.iOS(.v15)],
    products: [
        .library(
            name: "ConektaTokenizerPlugin",
            targets: ["ConektaTokenizerPlugin"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ConektaTokenizerPlugin",
            dependencies: [],
            path: "ios/Sources/ConektaTokenizerPlugin"),
        .testTarget(
            name: "ConektaTokenizerPluginTests",
            dependencies: ["ConektaTokenizerPlugin"],
            path: "ios/Tests/ConektaTokenizerPluginTests")
    ]
)
