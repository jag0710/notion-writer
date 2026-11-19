// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "NotionWriter", platforms: [.macOS(.v13)], products: [
    .executable(name: "NotionWriter", targets: ["NotionWriter"])
], targets: [
    .target(name: "NotionWriterCore"),
    .executableTarget(name: "NotionWriter", dependencies: ["NotionWriterCore"]),
    .executableTarget(name: "NotionWriterVerify", dependencies: ["NotionWriterCore"], path: "Tests/NotionWriterCoreTests")
], swiftLanguageModes: [.v5])
