// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PrivateAITools",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PrivateAITools", targets: ["PrivateAITools"])
    ],
    dependencies: [
        .package(path: "../LLMCore"),
        .package(path: "../ExecutionKit"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.9")
    ],
    targets: [
        .target(
            name: "PrivateAITools",
            dependencies: ["ExecutionKit", "LLMCore", "SwiftSoup"]
        ),
        .testTarget(
            name: "PrivateAIToolsTests",
            dependencies: ["ExecutionKit", "PrivateAITools", "LLMCore"],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)