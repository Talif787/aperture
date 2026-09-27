// swift-tools-version: 6.0
import PackageDescription

// AperturePlatform contains every module that legitimately depends on an Apple framework:
// persistence, secure storage, telemetry, design system, and feature UI.
//
// These targets build only on macOS and iOS. They are excluded from the Linux CI job and
// from local development in Cloud Shell, and that exclusion is the reason the split
// exists: it keeps the Linux-buildable surface honest rather than aspirational.
//
// Targets are added to this package in the phase that gives them content. Declaring an
// empty module to reserve a name produces a package that does not build and a directory
// that teaches nothing.

let package = Package(
    name: "AperturePlatform",
    platforms: [
        // String form rather than .v26: the enum case exists only in newer SwiftPM
        // versions, and this manifest must also parse under the Linux toolchain.
        // iOS 18.0 is the floor set by Synchronization.Mutex, and the ceiling set by the
        // test device: an iPhone XR is an A12 and cannot run iOS 26.
        .iOS("18.0"),
        .macOS("15.0")
    ],
    products: [
        .library(name: "ApertureData", targets: ["ApertureData"]),
        .library(name: "ApertureSecurity", targets: ["ApertureSecurity"]),
        .library(name: "ApertureTelemetry", targets: ["ApertureTelemetry"]),
        .library(name: "ApertureDesignSystem", targets: ["ApertureDesignSystem"]),
        .library(name: "ApertureCapture", targets: ["ApertureCapture"]),
        .library(name: "FeatureInspection", targets: ["FeatureInspection"])
    ],
    dependencies: [
        .package(path: "../ApertureCore")
    ],
    targets: [
        .target(
            name: "ApertureData",
            dependencies: [
                .product(name: "ApertureDomain", package: "ApertureCore"),
                .product(name: "ApertureSync", package: "ApertureCore"),
                .product(name: "ApertureNetworking", package: "ApertureCore")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ApertureSecurity",
            dependencies: [
                .product(name: "ApertureDomain", package: "ApertureCore"),
                .product(name: "ApertureAuth", package: "ApertureCore")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ApertureTelemetry",
            dependencies: [
                .product(name: "ApertureDomain", package: "ApertureCore")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ApertureDesignSystem",
            dependencies: [],
            // Declaring resources is what synthesizes Bundle.module. Without it, the
            // asset-catalog colour lookups in DesignTokens do not compile.
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // AVFoundation and the file system, behind the ports the domain declares.
        //
        // Separate from FeatureInspection so the view layer depends on the protocol rather
        // than on AVFoundation, which is what lets a preview and a test substitute
        // something that does not need a camera.
        .target(
            name: "ApertureCapture",
            dependencies: [
                .product(name: "ApertureDomain", package: "ApertureCore")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FeatureInspection",
            dependencies: [
                .product(name: "ApertureDomain", package: "ApertureCore"),
                "ApertureCapture",
                "ApertureDesignSystem"
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AperturePlatformTests",
            dependencies: [
                "ApertureCapture",
                "ApertureData",
                "ApertureSecurity",
                "ApertureTelemetry",
                "FeatureInspection",
                .product(name: "ApertureTestSupport", package: "ApertureCore")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
