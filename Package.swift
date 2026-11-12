// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LVNC",
    platforms: [.macOS(.v14)],
    targets: [
        // POSIX bits Swift cannot call directly: shm_open (variadic), SCM_RIGHTS, sockaddr_un.
        .target(name: "CLVNC"),
        // Wire protocol, socket connection, shared memory region.
        .target(name: "LVNCCore", dependencies: ["CLVNC"],
                linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Carbon"), .linkedFramework("Metal")]),
        // Runs in the session being controlled: captures the screen, injects input.
        .executableTarget(
            name: "lvnc-agent",
            dependencies: ["LVNCCore", "CLVNC"],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Metal"),
            ]
        ),
        // Runs in the controlling session: shows frames, sends input.
        .executableTarget(
            name: "lvnc-viewer",
            dependencies: ["LVNCCore", "CLVNC"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(name: "LVNCCoreTests", dependencies: ["LVNCCore"]),
    ],
    swiftLanguageModes: [.v5]
)
