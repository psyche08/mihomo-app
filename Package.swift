// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "mihomo-daemon",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "mihomo-daemon", targets: ["MihomoDaemon"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
    ],
    targets: [
        .target(name: "CMihomoDNSSystem"),
        .target(
            name: "MihomoDNSCore",
            dependencies: [
                "CMihomoDNSSystem",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            linkerSettings: [
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .executableTarget(
            name: "MihomoDaemon",
            dependencies: ["MihomoDNSCore"]
        ),
        .testTarget(
            name: "MihomoDNSCoreTests",
            dependencies: ["MihomoDNSCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
