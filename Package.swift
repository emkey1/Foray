// swift-tools-version: 6.2
// RealFinder. See DESIGN.md §5.2 for the module layout and dependency rules.
import PackageDescription

let package = Package(
    name: "RealFinder",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "RealFinder", targets: ["RealFinder"]),
    ],
    targets: [
        // getattrlistbulk(2) parsing. Only RFFileSystem may depend on this.
        .target(name: "CFastFS"),
        // Pure model: no AppKit, no I/O.
        .target(name: "RFModel"),
        // Filesystem access: enumeration, watching, volumes.
        .target(name: "RFFileSystem", dependencies: ["CFastFS", "RFModel"]),
        // Search planner and backends (Spotlight, crawl).
        .target(name: "RFSearch", dependencies: ["RFModel", "RFFileSystem"]),
        // AppKit views and controllers. Never touches the filesystem directly.
        .target(name: "RFUI", dependencies: ["RFModel", "RFFileSystem", "RFSearch"], resources: [.copy("Guide")]),
        // App entry point: menus, app delegate.
        .executableTarget(name: "RealFinder", dependencies: ["RFUI"]),

        .testTarget(name: "RFModelTests", dependencies: ["RFModel"]),
        .testTarget(name: "RFFileSystemTests", dependencies: ["RFFileSystem"]),
        .testTarget(name: "RFSearchTests", dependencies: ["RFSearch"]),
        .testTarget(name: "RFUITests", dependencies: ["RFUI"]),
    ]
)
