// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "T3Proxy",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "T3ProxyCore"),
        .target(name: "T3ProxyUI", dependencies: ["T3ProxyCore"], resources: [.copy("Resources")]),
        .executableTarget(name: "T3Proxy", dependencies: ["T3ProxyCore", "T3ProxyUI"]),
        .testTarget(name: "T3ProxyCoreTests", dependencies: ["T3ProxyCore"]),
    ]
)
