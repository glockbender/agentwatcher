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
        .library(name: "AgentWatchLookup", targets: ["AgentWatchLookup"]),
    ],
    targets: [
        .target(name: "AgentWatchCore"),
        .executableTarget(
            name: "AgentWatchApp",
            dependencies: ["AgentWatchCore", "AgentWatchIngress", "AgentWatchSender", "AgentWatchLookup"],
            swiftSettings: [.define("AGENT_WATCH_DEBUG_CAPTURE", .when(configuration: .debug))]
        ),
        .executableTarget(
            name: "AgentWatchSend",
            dependencies: ["AgentWatchCore", "AgentWatchSender", "AgentWatchLookup"],
            swiftSettings: [.define("AGENT_WATCH_DEBUG_CAPTURE", .when(configuration: .debug))]
        ),
        // What the hook process says, and how it says it: building a request out of the
        // payload on stdin and handing it to the socket.
        .target(
            name: "AgentWatchSender",
            dependencies: ["AgentWatchCore"],
            swiftSettings: [.define("AGENT_WATCH_DEBUG_CAPTURE", .when(configuration: .debug))]
        ),
        // What the machine says: which agent processes are running, which one launched this
        // hook, and what a session calls itself in its own files. Both the app and the hook
        // command ask these questions; neither of them sends anything to answer one.
        .target(
            name: "AgentWatchLookup",
            dependencies: ["AgentWatchCore"]
        ),
        // The socket server, and nothing else. It is a separate target so that a listening
        // socket never enters AgentWatchCore, where state has to stay testable without one.
        .target(
            name: "AgentWatchIngress",
            dependencies: ["AgentWatchCore"]
        ),
        // Fixtures the session-bearing test targets build their rows from. A library rather
        // than a file in each, because a test target cannot see another's sources and two
        // copies of a fixture drift apart the first time one of them grows a parameter.
        .target(
            name: "AgentWatchTestSupport",
            dependencies: ["AgentWatchCore"],
            path: "Tests/AgentWatchTestSupport"
        ),
        .testTarget(
            name: "AgentWatchCoreTests",
            dependencies: ["AgentWatchCore", "AgentWatchTestSupport"]
        ),
        // Keeps the sender: the socket is checked end to end, from a real send to a
        // decoded request, rather than against a message this test wrote itself.
        .testTarget(
            name: "AgentWatchIngressTests",
            dependencies: ["AgentWatchIngress", "AgentWatchSender"]
        ),
        .testTarget(
            name: "AgentWatchSenderTests",
            dependencies: ["AgentWatchSender"]
        ),
        .testTarget(
            name: "AgentWatchLookupTests",
            dependencies: ["AgentWatchLookup"]
        ),
        .testTarget(
            name: "AgentWatchAppTests",
            dependencies: ["AgentWatchApp", "AgentWatchTestSupport"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
