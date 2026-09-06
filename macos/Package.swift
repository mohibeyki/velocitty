// swift-tools-version: 6.0
import PackageDescription

// Private configuration model and tests used by the AppKit application.
let package = Package(
    name: "VelocittyConfiguration",
    platforms: [.macOS(.v13)],
    products: [.library(name: "VelocittyConfiguration", targets: ["VelocittyConfiguration"])],
    dependencies: [.package(url: "https://github.com/dduan/TOMLDecoder.git", exact: "0.4.5")],
    targets: [
        .target(name: "VelocittyConfiguration", dependencies: ["TOMLDecoder"], path: "Configuration", resources: [.process("Themes")]),
        .testTarget(name: "VelocittyConfigurationTests", dependencies: ["VelocittyConfiguration"], path: "Tests"),
    ]
)
