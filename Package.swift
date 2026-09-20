// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JevDesktop",
    platforms: [.macOS("14.2")],
    products: [.library(name: "JevCore", targets: ["JevCore"]), .executable(name: "JevDesktop", targets: ["JevDesktop"])],
    dependencies: [.package(url: "https://github.com/MrKai77/DynamicNotchKit", exact: "1.1.0")],
    targets: [
        .target(name: "JevCore"),
        .executableTarget(name: "JevDesktop", dependencies: ["JevCore", .product(name: "DynamicNotchKit", package: "DynamicNotchKit")]),
        .testTarget(name: "JevCoreTests", dependencies: ["JevCore"])
    ]
)
