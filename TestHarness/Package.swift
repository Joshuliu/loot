// swift-tools-version: 5.9
//
// Headless SPM test harness for the Loot domain layer.
//
// Lets us run pure-Swift domain unit tests via `swift test` without xcodebuild.
// Sources are referenced in-place from `../Loot MessagesExtension/Domain/`, so
// there's no duplicate copy of the code — the same Money.swift compiled here
// is the one shipped in the iOS extension.
//
// Run from this directory: `swift test`
//
import PackageDescription

let package = Package(
    name: "LootDomainHarness",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "LootDomain",
            path: "Sources/LootDomain"
        ),
        .testTarget(
            name: "LootDomainTests",
            dependencies: ["LootDomain"],
            path: "Tests/LootDomainTests"
        )
    ]
)
