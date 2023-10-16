// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftUIDownloads",
    platforms: [.macOS(.v12), .iOS(.v15)],
    products: [
        .library(
            name: "SwiftUIDownloads",
            targets: ["SwiftUIDownloads"]),
    ],
    dependencies: [
//        .package(url: "https://github.com/L1MeN9Yu/Elva.git", branch: "main"),
        .package(url: "https://github.com/NghiaTranUIT/Brotli.git", branch: "master"),
    ],
    targets: [
        .target(
            name: "SwiftUIDownloads",
            dependencies: [
//                .product(name: "Brotli", package: "Elva"), // Only needed for iOS 15 Brotli (somehow missing in simulator at least)
                .product(name: "Brotli", package: "Brotli"), // Only needed for iOS 15 Brotli (somehow missing in simulator at least)
            ]),
//        .testTarget(
//            name: "SwiftUIDownloadsTests",
//            dependencies: ["SwiftUIDownloads"]),
    ]
)
