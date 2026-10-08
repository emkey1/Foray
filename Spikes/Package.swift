// swift-tools-version: 6.2
// M0 spikes for RealFinder (see ../DESIGN.md §10). Throwaway code: answers questions, not production.
import PackageDescription

let package = Package(
    name: "Spikes",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "CFastFS"),
        .executableTarget(name: "enumbench", dependencies: ["CFastFS"]),
        .executableTarget(name: "searchfs-spike", dependencies: ["CFastFS"]),
        .executableTarget(name: "uttype-spike"),
        .executableTarget(name: "indexprobe-spike"),
        .executableTarget(name: "tags-spike"),
        .executableTarget(name: "trash-spike"),
        .executableTarget(name: "thumb-spike"),
        .executableTarget(name: "sortbench"),
    ]
)
