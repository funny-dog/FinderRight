// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "FinderRightKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "FinderRightKit",
            targets: ["FinderRightKit"]
        ),
        .executable(
            name: "FinderRightKitTests",
            targets: ["FinderRightKitTests"]
        ),
    ],
    targets: [
        .target(
            name: "FinderRightKit",
            path: "Sources/FinderRightKit"
        ),
        .executableTarget(
            name: "FinderRightKitTests",
            dependencies: ["FinderRightKit"],
            path: "Tests/FinderRightKitTests"
        ),
    ]
)
