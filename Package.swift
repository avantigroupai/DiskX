// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DiskX",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .target(
            name: "DiskXCore",
            path: "Sources/DiskXCore",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]),
        .executableTarget(
            name: "DiskX",
            dependencies: ["DiskXCore"],
            path: "Sources/DiskX",
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]),
        .executableTarget(
            name: "diskx-bench",
            dependencies: ["DiskXCore"],
            path: "Sources/diskx-bench",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]),
        .testTarget(
            name: "DiskXTests",
            dependencies: ["DiskXCore"],
            path: "Tests/DiskXTests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]),
    ]
)
