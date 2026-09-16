// swift-tools-version: 6.0
import PackageDescription

// ApertureCore contains every module that is free of Apple-framework dependencies.
//
// This is not a stylistic boundary. It is the boundary that makes the hardest logic in
// the product (conflict resolution, hybrid logical clocks, the sync queue state machine)
// compile and test on Linux, which means it runs in Cloud Shell, in a container, and on
// a cheap ubuntu CI runner instead of only on a macOS runner.
//
// Rule enforced by scripts/check_module_boundaries.py on every pull request:
// no target in this package may import SwiftUI, UIKit, SwiftData, CoreData, AVFoundation,
// CoreML, ARKit, Combine, or any other Apple-platform framework.

let package = Package(
    name: "ApertureCore",
    platforms: [
        .iOS("26.0"),
        .macOS("15.0")
    ],
    products: [
        .library(name: "ApertureDomain", targets: ["ApertureDomain"]),
        .library(name: "ApertureSync", targets: ["ApertureSync"]),
        .library(name: "ApertureContracts", targets: ["ApertureContracts"]),
        .library(name: "ApertureTestSupport", targets: ["ApertureTestSupport"])
    ],
    targets: [
        .target(
            name: "ApertureDomain",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ApertureSync",
            dependencies: ["ApertureDomain"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ApertureContracts",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ApertureTestSupport",
            dependencies: ["ApertureDomain", "ApertureSync"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ApertureDomainTests",
            dependencies: ["ApertureDomain", "ApertureTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ApertureSyncTests",
            dependencies: ["ApertureSync", "ApertureTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
