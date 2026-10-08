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
        // getattrlistbulk(2) parsing and copyfile(3) helpers. Only RFFileSystem and RFOperations
        // (the modules that make syscalls on user files) may depend on this.
        .target(name: "CFastFS"),
        // Pure model: no AppKit, no I/O.
        .target(name: "RFModel"),
        // Filesystem access: enumeration, watching, volumes.
        .target(name: "RFFileSystem", dependencies: ["CFastFS", "RFModel"]),
        // File operations: copy, move, rename, trash, delete; conflicts, progress, journal, undo.
        .target(name: "RFOperations", dependencies: ["CFastFS", "RFModel", "RFFileSystem"]),
        // Search planner and backends (Spotlight, crawl).
        .target(name: "RFSearch", dependencies: ["RFModel", "RFFileSystem"]),
        // AppKit views and controllers. Never touches the filesystem directly.
        .target(name: "RFUI", dependencies: ["RFModel", "RFFileSystem", "RFSearch", "RFOperations"], resources: [.copy("Guide")]),
        // App entry point: menus, app delegate.
        .executableTarget(name: "RealFinder", dependencies: ["RFUI"]),
        // Test helper: runs one copy so a test can kill it mid-way (DESIGN.md §9, M2 exit criteria).
        .executableTarget(name: "rf-crash-probe", dependencies: ["RFOperations", "RFFileSystem"]),

        .testTarget(name: "RFModelTests", dependencies: ["RFModel"]),
        .testTarget(name: "RFFileSystemTests", dependencies: ["RFFileSystem"]),
        .testTarget(name: "RFSearchTests", dependencies: ["RFSearch"]),
        .testTarget(name: "RFOperationsTests", dependencies: ["RFOperations", "rf-crash-probe"]),
        .testTarget(name: "RFUITests", dependencies: ["RFUI"]),
    ]
)
