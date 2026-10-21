// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScrollStitch",
    platforms: [.iOS("27.0"), .macOS(.v14)],
    products: [
        .library(name: "ScrollStitchCore", targets: ["ScrollStitchCore"]),
        .library(name: "ScrollStitchImaging", targets: ["ScrollStitchImaging"])
    ],
    targets: [
        .target(name: "ScrollStitchCore"),
        .target(name: "ScrollStitchImaging", dependencies: ["ScrollStitchCore"]),
        .target(name: "CaptureTestSupport", dependencies: ["ScrollStitchCore"], path: "Tests/Support/CaptureFixtures"),
        .executableTarget(name: "StoreProbe", dependencies: ["ScrollStitchCore"], path: "Tools/StoreProbe"),
        .executableTarget(name: "BenchmarkSmoke", dependencies: ["ScrollStitchCore", "ScrollStitchImaging"], path: "Tools/BenchmarkSmoke"),
        .executableTarget(name: "ProductFixtures", dependencies: ["ScrollStitchCore", "ScrollStitchImaging", "CaptureTestSupport"], path: "Tools/ProductFixtures"),
        .executableTarget(name: "ScrollReplay", dependencies: ["ScrollStitchCore", "ScrollStitchImaging"], path: "Tools/ScrollReplay"),
        .testTarget(name: "ScrollStitchCoreTests", dependencies: ["ScrollStitchCore", "StoreProbe", "CaptureTestSupport"]),
        .testTarget(name: "ScrollStitchImagingTests", dependencies: ["ScrollStitchImaging", "ScrollStitchCore", "CaptureTestSupport"])
    ]
)
