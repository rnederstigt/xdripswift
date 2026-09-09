// swift-tools-version: 5.9
import PackageDescription

// Small host-test harness; the application continues to use its existing Xcode targets.
let package = Package(
    name: "Libre2Experiment",
    platforms: [.macOS(.v12)],
    products: [.library(name: "Libre2ExperimentCore", targets: ["Libre2ExperimentCore"])],
    targets: [
        .target(name: "Libre2ExperimentCore", path: "Shared/Libre2"),
        .testTarget(name: "DirectLibreTests", dependencies: ["Libre2ExperimentCore"], path: "Tests/DirectLibreTests")
    ]
)
