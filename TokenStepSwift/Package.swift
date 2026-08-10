// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TokenFleet",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TokenFleet", targets: ["TokenStepSwift"])
    ],
    targets: [
        // TokenFleetHelper is bundled by script/build_swiftui_and_run.sh because it
        // intentionally shares internal app sources that SwiftPM cannot own twice.
        .executableTarget(
            name: "TokenStepSwift",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("LocalAuthentication")
            ]
        ),
        .testTarget(
            name: "TokenStepSwiftTests",
            dependencies: ["TokenStepSwift"]
        )
    ]
)
