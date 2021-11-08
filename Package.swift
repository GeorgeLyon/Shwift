// swift-tools-version:5.5

import PackageDescription

let package = Package(
  name: "Shwift",
  platforms: [
    .macOS(.v12)
  ],
  products: [
    .library(name: "Script", targets: ["Script"]),
    .library(name: "Shell", targets: ["Shell"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-system", .branch("main")),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
  ],
  targets: [
    .target(
      name: "Shell",
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
        "Shell",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]),
    
    .executableTarget(
      name: "ScriptExample",
      dependencies: [
        "Script",
      ]
    ),
    .testTarget(
      name: "ShellTests",
      dependencies: ["Shell"],
      resources: [
        .copy("Cat.txt")
      ]),
  ]
)
