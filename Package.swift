// swift-tools-version:5.5

import PackageDescription

let package = Package(
  name: "Shwift",
  platforms: [
    .macOS(.v12)
  ],
  products: [
    .library(name: "Script", targets: ["Script"]),
    .library(name: "Shwift", targets: ["Shwift"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-format", .branch("release/5.8")),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-system", from: "1.1.1"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
  ],
  targets: [
    .target(
      name: "Shwift",
      dependencies: [
        .product(name: "SystemPackage", package: "swift-system"),
        .product(name: "NIO", package: "swift-nio"),
        .product(name: "_NIOConcurrency", package: "swift-nio"),
        .target(name: "CLinuxSupport", condition: .when(platforms: [.linux])),
      ]),
    .target(name: "CLinuxSupport"),

    .target(
      name: "Script",
      dependencies: [
        "Shwift",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]),

    .executableTarget(
      name: "ScriptExample",
      dependencies: [
        "Script"
      ]
    ),
    .testTarget(
      name: "ShwiftTests",
      dependencies: ["Shwift"],
      resources: [
        .copy("Cat.txt")
      ]),
  ]
)
