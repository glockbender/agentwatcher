// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentWatch",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AgentWatch", targets: ["AgentWatchApp"]),
        .executable(name: "AgentWatchSend", targets: ["AgentWatchSend"]),
        .library(name: "AgentWatchCore", targets: ["AgentWatchCore"]),
        .library(name: "AgentWatchIngress", targets: ["AgentWatchIngress"]),
        .library(name: "AgentWatchSender", targets: ["AgentWatchSender"]),
    ],
    targets: [
        .target(name: "AgentWatchCore"),
        .executableTarget(
            name: "AgentWatchApp",
            dependencies: ["AgentWatchCore", "AgentWatchIngress", "AgentWatchSender"],
            swiftSettings: [.define("AGENT_WATCH_DEBUG_CAPTURE", .when(configuration: .debug))]
        ),
        .executableTarget(
            name: "AgentWatchSend",
            dependencies: ["AgentWatchCore", "AgentWatchSender"],
            swiftSettings: [.define("AGENT_WATCH_DEBUG_CAPTURE", .when(configuration: .debug))]
        ),
        .target(
            name: "AgentWatchSender",
            dependencies: ["AgentWatchCore"],
            swiftSettings: [.define("AGENT_WATCH_DEBUG_CAPTURE", .when(configuration: .debug))]
        ),
        .target(
            name: "AgentWatchIngress",
            dependencies: ["AgentWatchCore"]
        ),
        .testTarget(
            name: "AgentWatchCoreTests",
            dependencies: ["AgentWatchCore"]
        ),
        .testTarget(
            name: "AgentWatchIngressTests",
            dependencies: ["AgentWatchIngress", "AgentWatchSender"]
        ),
        .testTarget(
            name: "AgentWatchAppTests",
            dependencies: ["AgentWatchApp"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
