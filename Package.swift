// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
    .library(name: "MacCleanerCore", targets: ["MacCleanerCore"])
]

var targets: [Target] = [
    .target(name: "MacCleanerCore"),
    .testTarget(name: "MacCleanerCoreTests", dependencies: ["MacCleanerCore"])
]

#if os(macOS)
products.append(.executable(name: "MacCleaner", targets: ["MacCleanerApp"]))
targets.append(
    .executableTarget(
        name: "MacCleanerApp",
        dependencies: ["MacCleanerCore"]
    )
)
#endif

let package = Package(
    name: "MacCleanerHybridBase",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
