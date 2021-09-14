// swift-tools-version:5.5

import PackageDescription

let package = Package(
  name: "Shwift",
  platforms: [
    .macOS(.v12)
  ],
  products: [
    .library(
      name: "Script",
      targets: ["Script"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-system", from: "0.0.1"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0")
  ],
  targets: [
    .target(
      name: "Shell",
      dependencies: [
        .product(name: "SystemPackage", package: "swift-system"),
        .product(name: "NIO", package: "swift-nio"),
      ]),
    .target(
      name: "Script",
      dependencies: [
        "Shell",
      ]),
    
    .testTarget(
      name: "ShwiftTests",
      dependencies: [
        "Script",
      ]),
  ]
)
