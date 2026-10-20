// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
    .library(name: "MacCleanerCore", targets: ["MacCleanerCore"]),
    // Performance benchmark tool used by .github/workflows/benchmarks.yml; never shipped.
    .executable(name: "macmint-bench", targets: ["MacMintBench"]),
]

var dependencies: [Package.Dependency] = []

var targets: [Target] = [
    .target(name: "MacCleanerCore"),
    .testTarget(name: "MacCleanerCoreTests", dependencies: ["MacCleanerCore"]),
    .executableTarget(name: "MacMintBench", dependencies: ["MacCleanerCore"]),
]

#if os(macOS)
// Sparkle 2 in-app updates (docs/UPDATES.md). Pinned exactly; build_app.sh embeds and signs it.
dependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"))
products.append(.executable(name: "MacMint", targets: ["MacCleanerApp"]))
targets.append(
    .executableTarget(
        name: "MacCleanerApp",
        dependencies: ["MacCleanerCore", .product(name: "Sparkle", package: "Sparkle")]
    )
)
targets.append(.testTarget(name: "MacCleanerAppTests", dependencies: ["MacCleanerApp"]))
#endif

let package = Package(
    name: "MacMint",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
