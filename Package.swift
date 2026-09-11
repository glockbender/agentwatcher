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
        // Fixtures both test targets build their sessions from. A library rather than a file
        // in each, because a test target cannot see another's sources and two copies of a
        // fixture drift apart the first time one of them grows a parameter.
        .target(
            name: "AgentWatchTestSupport",
            dependencies: ["AgentWatchCore"],
            path: "Tests/AgentWatchTestSupport"
        ),
        .testTarget(
            name: "AgentWatchCoreTests",
            dependencies: ["AgentWatchCore", "AgentWatchTestSupport"]
        ),
        .testTarget(
            name: "AgentWatchIngressTests",
            dependencies: ["AgentWatchIngress", "AgentWatchSender"]
        ),
        .testTarget(
            name: "AgentWatchAppTests",
            dependencies: ["AgentWatchApp", "AgentWatchTestSupport"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
