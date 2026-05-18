// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OCRBench",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "OCRCore", targets: ["OCRCore"]),
        .executable(name: "ocrbench", targets: ["OCRBench"])
    ],
    targets: [
        .target(
            name: "OCRCore",
            path: "OCRCore/Sources"
        ),
        .executableTarget(
            name: "OCRBench",
            dependencies: ["OCRCore"],
            path: "OCRBench/Sources"
        )
    ]
)
