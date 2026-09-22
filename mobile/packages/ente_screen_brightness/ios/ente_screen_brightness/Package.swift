// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ente_screen_brightness",
    platforms: [.iOS("15.1")],
    products: [
        .library(name: "ente-screen-brightness", targets: ["ente_screen_brightness"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "ente_screen_brightness",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ]
        )
    ]
)
