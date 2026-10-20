// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "FerryKit",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "BaiduKit", targets: ["BaiduKit"]),
        .library(name: "DownloadKit", targets: ["DownloadKit"]),
    ],
    targets: [
        .target(name: "BaiduKit"),
        .target(name: "DownloadKit"),
        .testTarget(name: "BaiduKitTests", dependencies: ["BaiduKit"]),
        .testTarget(name: "DownloadKitTests", dependencies: ["DownloadKit"]),
    ]
)
