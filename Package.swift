// swift-tools-version:5.5

import PackageDescription

let package = Package(
  name: "Shwift",
  platforms: [
    .macOS(.v12)
  ],
  dependencies: [
//    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-system", .branch("main")),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
  ],
  targets: [
    .executableTarget(
      name: "ScriptExample",
      dependencies: [
        "Shell",
      ]
    ),
    .target(
      name: "Shell",
      dependencies: [
        .product(name: "SystemPackage", package: "swift-system"),
        .product(name: "NIO", package: "swift-nio"),
        .product(name: "_NIOConcurrency", package: "swift-nio"),
        .target(name: "CLinuxSupport", condition: .when(platforms: [.linux])),
      ]),
    .target(name: "CLinuxSupport")
//    .testTarget(
//      name: "ShwiftTests",
//      dependencies: ["Shwift"]),
  ]
)
