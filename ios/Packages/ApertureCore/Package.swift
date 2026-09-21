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
        // String form rather than .v26: the enum case exists only in newer SwiftPM
        // versions, and this manifest must also parse under the Linux toolchain.
        .iOS("26.0"),
        .macOS("15.0")
    ],
    products: [
        .library(name: "ApertureDomain", targets: ["ApertureDomain"]),
        .library(name: "ApertureSync", targets: ["ApertureSync"]),
        .library(name: "ApertureNetworking", targets: ["ApertureNetworking"]),
        .library(name: "ApertureAuth", targets: ["ApertureAuth"]),
        .library(name: "ApertureContracts", targets: ["ApertureContracts"]),
        .library(name: "ApertureTestSupport", targets: ["ApertureTestSupport"])
    ],
    dependencies: [
        // swift-crypto is Apple's own package and exposes the CryptoKit API on Linux, so
        // the PKCE digest runs the same code on a device, on a Linux CI runner, and in the
        // Cloud Shell container. The alternative was a hand-written SHA-256, which would
        // have avoided a dependency at the cost of putting a security-relevant primitive
        // in code nobody has audited. For a digest on the authentication path that is the
        // wrong trade.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
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
            name: "ApertureAuth",
            dependencies: [
                "ApertureDomain",
                .product(name: "Crypto", package: "swift-crypto")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ApertureNetworking",
            dependencies: ["ApertureDomain", "ApertureSync"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ApertureContracts",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ApertureTestSupport",
            dependencies: ["ApertureDomain", "ApertureSync", "ApertureNetworking", "ApertureAuth"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // A development tool, not part of the application. It is in this package so it
        // compiles on Linux alongside the logic it exercises.
        .executableTarget(
            name: "ApertureScenarios",
            dependencies: ["ApertureDomain", "ApertureSync", "ApertureTestSupport"],
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
        ),
        .testTarget(
            name: "ApertureNetworkingTests",
            dependencies: ["ApertureNetworking", "ApertureTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ApertureAuthTests",
            dependencies: ["ApertureAuth", "ApertureTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
