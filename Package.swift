// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UGOSSync",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "UGOSSyncCore", targets: ["UGOSSyncCore"]),
        .executable(name: "UGOSSync", targets: ["UGOSSyncApp"]),
        .executable(name: "UGOSSyncDaemon", targets: ["UGOSSyncDaemon"]),
        .executable(name: "UGOSSyncEngine", targets: ["UGOSSyncEngine"])
    ],
    targets: [
        .target(name: "UGOSSyncCore"),
        .executableTarget(name: "UGOSSyncApp", dependencies: ["UGOSSyncCore"]),
        .executableTarget(name: "UGOSSyncDaemon", dependencies: ["UGOSSyncCore"]),
        .executableTarget(name: "UGOSSyncEngine"),
        .testTarget(name: "UGOSSyncCoreTests", dependencies: ["UGOSSyncCore"])
    ]
)
