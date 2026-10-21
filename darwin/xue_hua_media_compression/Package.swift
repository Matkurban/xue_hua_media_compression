// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "xue_hua_media_compression",
  platforms: [
    .iOS("13.0"),
    .macOS("10.15"),
  ],
  products: [
    .library(
      name: "xue-hua-media-compression",
      targets: ["xue_hua_media_compression"])
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework")
  ],
  targets: [
    .target(
      name: "xue_hua_media_compression",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework")
      ],
      resources: [
        .process("PrivacyInfo.xcprivacy")
      ]
    )
  ]
)
