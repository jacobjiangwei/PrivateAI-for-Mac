// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ExecutionKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ExecutionKit", targets: ["ExecutionKit"]),
        .executable(
            name: "PrivateAIExecutionWorker",
            targets: ["PrivateAIExecutionWorker"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-subprocess.git",
            exact: "1.0.0"
        )
    ],
    targets: [
        .target(
            name: "ExecutionKit",
            dependencies: [
                .product(name: "Subprocess", package: "swift-subprocess")
            ]
        ),
        .executableTarget(
            name: "PrivateAIExecutionWorker",
            dependencies: ["ExecutionKit"]
        ),
        .testTarget(name: "ExecutionKitTests", dependencies: ["ExecutionKit"])
    ]
)