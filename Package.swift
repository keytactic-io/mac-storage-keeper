// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "StorageKeeper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "skeeper", targets: ["skeeper"]),
        .executable(name: "StorageKeeper", targets: ["StorageKeeperApp"]),
    ],
    targets: [
        .target(
            name: "StorageKeeperCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "skeeper",
            dependencies: ["StorageKeeperCore"]
        ),
        .executableTarget(
            name: "StorageKeeperApp",
            dependencies: ["StorageKeeperCore"]
        ),
    ]
)
