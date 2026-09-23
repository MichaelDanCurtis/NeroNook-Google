// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "NeroNookGoogle", platforms: [.macOS(.v14)], products: [
    .executable(name: "ModuleApp", targets: ["ModuleApp"]),
    .executable(name: "PluginCheck", targets: ["PluginCheck"])
], dependencies: [.package(path: "Vendor/NookPluginSDK")], targets: [
    .executableTarget(name: "ModuleApp", dependencies: [.product(name: "NookPluginSDK", package: "NookPluginSDK")]),
    .executableTarget(name: "PluginCheck", dependencies: [.product(name: "NookPluginSDK", package: "NookPluginSDK")]),
    .testTarget(name: "ModuleCoreTests", dependencies: ["ModuleApp"])
], swiftLanguageModes: [.v5])
