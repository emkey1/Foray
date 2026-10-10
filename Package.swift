// swift-tools-version: 6.2
// Foray. See DESIGN.md §5.2 for the module layout and dependency rules.
import PackageDescription

let package = Package(
    name: "Foray",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Foray", targets: ["Foray"]),
        // What the Xcode project (Xcode/Foray.xcodeproj, used for signed, notarized releases) links.
        .library(name: "ForayKit", targets: ["RFUI", "RFModel"]),
        // The `foray` command-line tool. (Its SwiftPM product is "foray-cli": "foray" would
        // collide with "Foray" on a case-insensitive disk. It's installed in the app as "foray".)
        .executable(name: "foray-cli", targets: ["foray-cli"]),
        .library(name: "ForayCLIKit", targets: ["ForayCLI", "RFOperations"]),
        // The privileged helper (a root launchd daemon inside the app; DESIGN.md §5.11).
        .executable(name: "foray-helper", targets: ["foray-helper"]),
        .library(name: "ForayOperations", targets: ["RFOperations"]),
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
        .executableTarget(name: "Foray", dependencies: ["RFUI"]),
        // The `foray` command-line tool: its logic (testable) and the thin executable.
        .target(name: "ForayCLI", dependencies: ["RFModel", "RFFileSystem", "RFSearch", "RFOperations"]),
        .executableTarget(name: "foray-cli", dependencies: ["ForayCLI", "RFOperations"]),
        // The privileged helper: a thin XPC listener over RFOperations' PrivilegedExecutor.
        .executableTarget(name: "foray-helper", dependencies: ["RFOperations"]),
        // Test helper: runs one copy so a test can kill it mid-way (DESIGN.md §9, M2 exit criteria).
        .executableTarget(name: "rf-crash-probe", dependencies: ["RFOperations", "RFFileSystem"]),

        .testTarget(name: "RFModelTests", dependencies: ["RFModel"]),
        .testTarget(name: "RFFileSystemTests", dependencies: ["RFFileSystem"]),
        .testTarget(name: "RFSearchTests", dependencies: ["RFSearch"]),
        .testTarget(name: "RFOperationsTests", dependencies: ["RFOperations", "rf-crash-probe"]),
        .testTarget(name: "RFUITests", dependencies: ["RFUI"]),
        .testTarget(name: "ForayCLITests", dependencies: ["ForayCLI"]),
    ]
)
