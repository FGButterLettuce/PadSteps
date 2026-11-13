// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PadStepsCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "PadStepsCore", targets: ["PadStepsCore"])],
    targets: [
        .target(name: "PadStepsCore"),
        .testTarget(name: "PadStepsCoreTests", dependencies: ["PadStepsCore"])
    ]
)
