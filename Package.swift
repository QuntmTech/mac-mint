// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
    .library(name: "MacCleanerCore", targets: ["MacCleanerCore"]),
    // Performance benchmark tool used by .github/workflows/benchmarks.yml; never shipped.
    .executable(name: "macmint-bench", targets: ["MacMintBench"]),
]

var targets: [Target] = [
    .target(name: "MacCleanerCore"),
    .testTarget(name: "MacCleanerCoreTests", dependencies: ["MacCleanerCore"]),
    .executableTarget(name: "MacMintBench", dependencies: ["MacCleanerCore"]),
]

#if os(macOS)
products.append(.executable(name: "MacMint", targets: ["MacCleanerApp"]))
targets.append(
    .executableTarget(
        name: "MacCleanerApp",
        dependencies: ["MacCleanerCore"]
    )
)
#endif

let package = Package(
    name: "MacMint",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
