// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "MihomoBox",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "mihomo-app", targets: ["MihomoBoxApp"]),
    .executable(name: "mihomo-daemon", targets: ["MihomoDaemon"]),
    .executable(name: "mihomo-agent", targets: ["MihomoAgent"]),
    .executable(name: "mihomoboxctl", targets: ["MihomoBoxCLI"]),
    // Xcode Cloud cannot archive a standalone Swift package. These library
    // products let the thin Xcode application and helper targets reuse the
    // package-owned implementation without creating a second source tree.
    .library(name: "MihomoControl", type: .static, targets: ["MihomoControl"]),
    .library(name: "MihomoDNSCore", type: .static, targets: ["MihomoDNSCore"]),
    .library(name: "MihomoBoxUI", type: .static, targets: ["MihomoBoxUI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
    .package(
      url: "https://github.com/sparkle-project/Sparkle.git",
      exact: "2.9.4"
    ),
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
      dependencies: ["CMihomoDNSSystem", "MihomoControl", "MihomoDNSCore"]
    ),
    .executableTarget(
      name: "MihomoAgent",
      dependencies: ["MihomoDNSCore"]
    ),
    .executableTarget(name: "MihomoBoxCLI", dependencies: ["MihomoControl"]),
    .executableTarget(
      name: "MihomoBoxApp",
      dependencies: [
        "MihomoBoxUI",
        "MihomoControl",
        "MihomoDNSCore",
        .product(name: "Sparkle", package: "Sparkle"),
      ],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("Security"),
        .unsafeFlags([
          "-Xlinker", "-rpath",
          "-Xlinker", "@executable_path/../Frameworks",
        ]),
      ]
    ),
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
    .testTarget(
      name: "MihomoBoxAppTests",
      dependencies: ["MihomoBoxApp", "MihomoBoxUI", "MihomoControl"]
    ),
    .testTarget(name: "MihomoControlTests", dependencies: ["MihomoControl"]),
  ],
  swiftLanguageModes: [.v5]
)
