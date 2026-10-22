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
            type: .static,
            targets: ["FinderRightKit"]
        ),
        .executable(
            name: "FinderRightKitTests",
            targets: ["FinderRightKitTests"]
        ),
    ],
    targets: [
        .systemLibrary(
            name: "CArchive",
            path: "Sources/CArchive"
        ),
        .target(
            name: "FinderRightKit",
            dependencies: ["CArchive"],
            path: "Sources/FinderRightKit"
        ),
        .executableTarget(
            name: "FinderRightKitTests",
            dependencies: ["FinderRightKit"],
            path: "Tests/FinderRightKitTests"
        ),
    ]
)
