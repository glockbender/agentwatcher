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
    // The one dependency: the update window, its progress and its list of changes. Pinned to an
    // exact version because it replaces the running app, and a minor release of the code that
    // does that is a change to review, not to pick up on the next resolve.
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "AgentWatchCore"),
        .executableTarget(
            name: "AgentWatchApp",
            dependencies: [
                "AgentWatchCore", "AgentWatchIngress", "AgentWatchSender", "AgentWatchLookup",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: [.define("AGENT_WATCH_DEBUG_CAPTURE", .when(configuration: .debug))],
            // Where Sparkle.framework is found: in the bundle (`build-app.sh` copies it there),
            // and beside the executable in a build folder. SwiftPM adds the second by itself and
            // Xcode does not — its Run passes the folder in DYLD_FRAMEWORK_PATH instead, so the
            // executable it builds failed to start from a terminal (measured on Xcode 16.4).
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path",
                ])
            ]
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
        // The socket server, and nothing else — one file, and deliberately its own target so
        // that a listening socket never enters AgentWatchCore, where state has to stay
        // testable without one. docs/adr/0006-the-socket-server-stays-out-of-core.md.
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
        // The app's own flag, so a test sees the menu a debug build shows — the recording lines
        // included — and a stand-in for the app can supply what those lines ask of it.
        .testTarget(
            name: "AgentWatchAppTests",
            dependencies: ["AgentWatchApp", "AgentWatchTestSupport"],
            swiftSettings: [.define("AGENT_WATCH_DEBUG_CAPTURE", .when(configuration: .debug))]
        ),
    ],
    swiftLanguageModes: [.v6]
)
