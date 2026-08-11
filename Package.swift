// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIMixAssistant",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AI Mix Assistant", targets: ["AIMixAssistant"])],
    targets: [
        .executableTarget(name: "AIMixAssistant", path: "Sources"),
        .testTarget(name: "AIMixAssistantTests", dependencies: ["AIMixAssistant"], path: "Tests")
    ]
)
