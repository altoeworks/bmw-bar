// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BMWBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BMWBar", targets: ["BMWBar"]),
        .library(name: "BMWBarKit", targets: ["BMWBarKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/emqx/CocoaMQTT.git", from: "2.4.0"),
    ],
    targets: [
        // Thin entry point: dispatches to the CLI or launches the SwiftUI app.
        .executableTarget(
            name: "BMWBar",
            dependencies: ["BMWBarKit"],
            path: "Sources/BMWBar"
        ),
        // Everything testable lives here.
        .target(
            name: "BMWBarKit",
            dependencies: [.product(name: "CocoaMQTT", package: "CocoaMQTT")],
            path: "Sources/BMWBarKit"
        ),
        .testTarget(
            name: "BMWBarKitTests",
            dependencies: ["BMWBarKit"],
            path: "Tests/BMWBarKitTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
