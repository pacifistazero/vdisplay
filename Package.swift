// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "vdisplay",
    platforms: [.macOS(.v12)],
    targets: [
        // Objective-C shim declaring the private CoreGraphics virtual-display API.
        .target(
            name: "CGVirtualDisplayShim"
        ),
        // Shared core: display manager + saved profiles.
        .target(
            name: "VirtualDisplayKit",
            dependencies: ["CGVirtualDisplayShim"],
            linkerSettings: [
                .linkedFramework("CoreGraphics")
            ]
        ),
        // Command-line tool.
        .executableTarget(
            name: "vdisplay",
            dependencies: ["VirtualDisplayKit"]
        ),
        // Menu-bar app.
        .executableTarget(
            name: "vdisplaybar",
            dependencies: ["VirtualDisplayKit"],
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
    ]
)
