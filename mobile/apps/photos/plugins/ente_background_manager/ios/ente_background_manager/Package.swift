// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "ente_background_manager",
  platforms: [.iOS("15.1")],
  products: [
    .library(name: "ente-background-manager", targets: ["ente_background_manager"])
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework")
  ],
  targets: [
    .target(
      name: "ente_background_manager",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework")
      ],
      linkerSettings: [.linkedFramework("BackgroundTasks")]
    )
  ]
)
