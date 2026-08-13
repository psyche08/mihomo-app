// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "mihomo-daemon",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "mihomo-daemon", targets: ["MihomoDaemon"]),
        .executable(name: "mihomo-agent", targets: ["MihomoAgent"]),
        .executable(name: "mihomoboxctl", targets: ["MihomoBoxCLI"]),
        .library(name: "MihomoBoxUI", type: .static, targets: ["MihomoBoxUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
    ],
    targets: [
        .target(name: "CMihomoDNSSystem"),
        .target(
            name: "MihomoControl",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .target(
            name: "MihomoDNSCore",
            dependencies: [
                "CMihomoDNSSystem",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .executableTarget(
            name: "MihomoDaemon",
            dependencies: ["MihomoControl", "MihomoDNSCore"]
        ),
        .executableTarget(
            name: "MihomoAgent",
            dependencies: ["MihomoDNSCore"]
        ),
        .executableTarget(name: "MihomoBoxCLI", dependencies: ["MihomoControl"]),
        .target(
            name: "MihomoBoxUI",
            dependencies: ["MihomoControl"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .testTarget(
            name: "MihomoDNSCoreTests",
            dependencies: ["MihomoControl", "MihomoDNSCore"]
        ),
        .testTarget(
            name: "MihomoBoxUITests",
            dependencies: ["MihomoBoxUI", "MihomoControl"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
